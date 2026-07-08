import Combine
import Foundation
#if canImport(CoreLocation)
@preconcurrency import CoreLocation
#endif

@MainActor
final class CPSLLocationService: NSObject, ObservableObject {
    @Published private(set) var access: CPSLFeatureAccessState = .undefined
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var isUpdatingLocation = false

#if canImport(CoreLocation)
    private let manager = CLLocationManager()
    private var accessContinuations: [CheckedContinuation<CPSLFeatureAccessState, Never>] = []
    private var locationContinuations: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]
#endif

    override init() {
        super.init()
#if canImport(CoreLocation)
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        refreshStatus()
        startUpdatingIfAllowed()
#else
        access = .denied
#endif
    }

    func refreshStatus() {
#if canImport(CoreLocation)
        access = Self.accessState(for: manager.authorizationStatus)
#else
        access = .denied
#endif
    }

    func requestAccess() async -> CPSLFeatureAccessState {
#if canImport(CoreLocation)
        refreshStatus()
        guard access == .undefined else {
            startUpdatingIfAllowed()
            return access
        }

        isRequestingAccess = true
        return await withCheckedContinuation { continuation in
            accessContinuations.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
#else
        access = .denied
        return access
#endif
    }

    func handleJSON(_ requestJSON: String) async -> String {
        do {
            guard let data = requestJSON.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["command"] as? String
            else {
                return Self.errorJSON("location: invalid request JSON")
            }

            switch command {
            case "status":
                refreshStatus()
                return Self.successJSON(statusPayload())
            case "request_access":
                _ = await requestAccess()
                return Self.successJSON(statusPayload())
            case "current":
                return await currentLocationJSON()
            default:
                return Self.errorJSON("location: unsupported command \(command)")
            }
        } catch {
            return Self.errorJSON("location: \(error.localizedDescription)")
        }
    }

    private func currentLocationJSON() async -> String {
#if canImport(CoreLocation)
        let requestedAccess = access == .undefined ? await requestAccess() : access
        guard requestedAccess == .granted else {
            return Self.errorJSON(settingsMessage)
        }
        guard CLLocationManager.locationServicesEnabled() else {
            access = .denied
            return Self.errorJSON("location: Location Services are disabled; enable them in iOS Settings or macOS System Settings.")
        }

        startUpdatingIfAllowed()
        let location = await freshestLocation()
        guard let location else {
            return Self.errorJSON("location: current location is not available yet")
        }

        var payload = statusPayload()
        payload["location"] = locationPayload(location)
        return Self.successJSON(payload)
#else
        return Self.errorJSON("location: CoreLocation is unavailable on this platform")
#endif
    }

    private var settingsMessage: String {
        "location: access denied; enable Location access for Herm in iOS Settings or macOS System Settings."
    }

    private func statusPayload() -> [String: Any] {
#if canImport(CoreLocation)
        [
            "ok": true,
            "access": access.rawValue,
            "state": access.rawValue,
            "supported": true,
            "services_enabled": CLLocationManager.locationServicesEnabled()
        ]
#else
        [
            "ok": true,
            "access": CPSLFeatureAccessState.denied.rawValue,
            "state": CPSLFeatureAccessState.denied.rawValue,
            "supported": false,
            "services_enabled": false
        ]
#endif
    }

#if canImport(CoreLocation)
    private func startUpdatingIfAllowed() {
        guard access == .granted, CLLocationManager.locationServicesEnabled() else {
            if isUpdatingLocation {
                manager.stopUpdatingLocation()
                isUpdatingLocation = false
            }
            return
        }
        guard !isUpdatingLocation else {
            return
        }
        manager.startUpdatingLocation()
        isUpdatingLocation = true
    }

    private func freshestLocation() async -> CLLocation? {
        if let currentLocation,
           abs(currentLocation.timestamp.timeIntervalSinceNow) < 60 {
            return currentLocation
        }

        let id = UUID()
        return await withCheckedContinuation { continuation in
            locationContinuations[id] = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let continuation = locationContinuations.removeValue(forKey: id) {
                    continuation.resume(returning: currentLocation)
                }
            }
        }
    }

    private func locationPayload(_ location: CLLocation) -> [String: Any] {
        var payload: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "horizontal_accuracy_meters": location.horizontalAccuracy,
            "timestamp": Self.timestampFormatter.string(from: location.timestamp)
        ]
        if location.verticalAccuracy >= 0 {
            payload["altitude_meters"] = location.altitude
            payload["vertical_accuracy_meters"] = location.verticalAccuracy
        }
        if location.speed >= 0 {
            payload["speed_meters_per_second"] = location.speed
        }
        if location.course >= 0 {
            payload["course_degrees"] = location.course
        }
        return payload
    }

    private func finishAccessRequestIfNeeded() {
        refreshStatus()
        startUpdatingIfAllowed()
        guard access != .undefined else {
            return
        }
        isRequestingAccess = false
        let continuations = accessContinuations
        accessContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: access)
        }
    }

    private func finishLocationWaits(with location: CLLocation?) {
        let continuations = locationContinuations.values
        locationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: location)
        }
    }

    private static func accessState(for status: CLAuthorizationStatus) -> CPSLFeatureAccessState {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return .granted
        case .notDetermined:
            return .undefined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }
#endif

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func successJSON(_ payload: [String: Any]) -> String {
        var object = payload
        object["ok"] = true
        return jsonString(object)
    }

    private static func errorJSON(_ message: String) -> String {
        jsonString(["ok": false, "error": message])
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":"location: could not encode response"}"#
        }
        return string
    }
}

#if canImport(CoreLocation)
extension CPSLLocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        finishAccessRequestIfNeeded()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }
        currentLocation = location
        finishLocationWaits(with: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocationWaits(with: nil)
    }
}
#endif
