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
    @Published private(set) var isLoadingCurrentLocation = false
    @Published private(set) var locationError: String?
    var activityOccurred: (@MainActor @Sendable () -> Void)?
    private var isOverlayActive = false

    private enum UpdateCadence {
        static let active: TimeInterval = 15
        static let inactive: TimeInterval = 5 * 60
    }

#if canImport(CoreLocation)
    private let manager = CLLocationManager()
    private var accessContinuations: [CheckedContinuation<CPSLFeatureAccessState, Never>] = []
    private var locationContinuations: [UUID: CheckedContinuation<CLLocation?, Never>] = [:]
#endif

    override init() {
        super.init()
#if canImport(CoreLocation)
        manager.delegate = self
        configureUpdatePolicy()
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

    func setOverlayActive(_ isActive: Bool) {
        guard isOverlayActive != isActive else {
            return
        }
        isOverlayActive = isActive
#if canImport(CoreLocation)
        configureUpdatePolicy()
        startUpdatingIfAllowed()
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

    func loadCurrentLocation() async -> CPSLFeatureAccessState {
        // Keep UI responsive: show loading first, then hop for any blocking CoreLocation checks.
        isLoadingCurrentLocation = true
        locationError = nil
        defer {
            isLoadingCurrentLocation = false
        }

        let requestedAccess = await requestAccess()
        guard requestedAccess == .granted else {
            currentLocation = nil
            locationError = settingsMessage
            return requestedAccess
        }

#if canImport(CoreLocation)
        guard await Self.locationServicesEnabled() else {
            currentLocation = nil
            locationError = "Location Services are disabled; enable them in iOS Settings or macOS System Settings."
            return .denied
        }

        startUpdatingIfAllowed()
        // Yield so the location overlay can paint its chrome before we wait on a fix.
        await Task.yield()
        let location = await freshestLocation()
        guard let location else {
            locationError = "Current location is not available yet."
            return requestedAccess
        }

        if currentLocation !== location {
            currentLocation = location
        }
#else
        locationError = "CoreLocation is unavailable on this platform."
#endif
        return requestedAccess
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
                activityOccurred?()
                refreshStatus()
                return Self.successJSON(await statusPayload())
            case "request_access":
                activityOccurred?()
                _ = await requestAccess()
                return Self.successJSON(await statusPayload())
            case "current":
                activityOccurred?()
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
        let requestedAccess = await loadCurrentLocation()
        guard requestedAccess == .granted else {
            return Self.errorJSON("location: \(locationError ?? settingsMessage)")
        }
        guard let location = currentLocation else {
            return Self.errorJSON("location: \(locationError ?? "current location is not available yet")")
        }

        var payload = await statusPayload()
        var coordinates = locationPayload(location)
        if let place = await reverseGeocodedPlace(for: location) {
            coordinates["place"] = place
            if let formatted = place["formatted_address"] as? String {
                coordinates["formatted_address"] = formatted
            }
            // Convenience aliases so agents need not dig only under place.
            for key in ["city", "region", "country", "country_code", "neighborhood", "postal_code"] {
                if let value = place[key] {
                    coordinates[key] = value
                }
            }
        }
        payload["location"] = coordinates
        return Self.successJSON(payload)
#else
        return Self.errorJSON("location: CoreLocation is unavailable on this platform")
#endif
    }

    private var settingsMessage: String {
        "location: access denied; enable Location access for Herm in iOS Settings or macOS System Settings."
    }

    private func statusPayload() async -> [String: Any] {
#if canImport(CoreLocation)
        [
            "ok": true,
            "access": access.rawValue,
            "state": access.rawValue,
            "supported": true,
            "services_enabled": await Self.locationServicesEnabled()
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
    private func configureUpdatePolicy() {
        manager.desiredAccuracy = isOverlayActive
            ? kCLLocationAccuracyHundredMeters
            : kCLLocationAccuracyKilometer
        manager.distanceFilter = isOverlayActive ? kCLDistanceFilterNone : 500
    }

    private func startUpdatingIfAllowed() {
        guard access == .granted else {
            stopUpdatingIfNeeded()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard await Self.locationServicesEnabled() else {
                self.stopUpdatingIfNeeded()
                return
            }
            guard self.access == .granted else {
                self.stopUpdatingIfNeeded()
                return
            }
            guard !self.isUpdatingLocation else {
                return
            }
            self.manager.startUpdatingLocation()
            self.isUpdatingLocation = true
        }
    }

    private func stopUpdatingIfNeeded() {
        guard isUpdatingLocation else {
            return
        }
        manager.stopUpdatingLocation()
        isUpdatingLocation = false
    }

    private func freshestLocation() async -> CLLocation? {
        let freshnessInterval = isOverlayActive ? UpdateCadence.active : 60
        if let currentLocation,
           abs(currentLocation.timestamp.timeIntervalSinceNow) < freshnessInterval {
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

    /// Reverse-geocode via Core Location. Best-effort: coordinate fields always remain
    /// even when geocoding fails or is unavailable.
    private func reverseGeocodedPlace(for location: CLLocation) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, _ in
                guard let placemark = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                var place: [String: Any] = [:]
                if let name = placemark.name, !name.isEmpty {
                    place["name"] = name
                }
                if let neighborhood = placemark.subLocality, !neighborhood.isEmpty {
                    place["neighborhood"] = neighborhood
                }
                if let city = placemark.locality, !city.isEmpty {
                    place["city"] = city
                }
                if let region = placemark.administrativeArea, !region.isEmpty {
                    place["region"] = region
                }
                if let postal = placemark.postalCode, !postal.isEmpty {
                    place["postal_code"] = postal
                }
                if let country = placemark.country, !country.isEmpty {
                    place["country"] = country
                }
                if let countryCode = placemark.isoCountryCode, !countryCode.isEmpty {
                    place["country_code"] = countryCode
                }
                if let thoroughfare = placemark.thoroughfare, !thoroughfare.isEmpty {
                    place["street"] = thoroughfare
                }
                if let subThoroughfare = placemark.subThoroughfare, !subThoroughfare.isEmpty {
                    place["street_number"] = subThoroughfare
                }
                let formatted = [
                    placemark.subThoroughfare,
                    placemark.thoroughfare,
                    placemark.locality,
                    placemark.administrativeArea,
                    placemark.postalCode,
                    placemark.country
                ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
                if !formatted.isEmpty {
                    place["formatted_address"] = formatted
                }
                continuation.resume(returning: place.isEmpty ? nil : place)
            }
        }
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

    private func shouldPublish(_ location: CLLocation) -> Bool {
        guard let currentLocation else {
            return true
        }
        let minimumInterval = isOverlayActive ? UpdateCadence.active : UpdateCadence.inactive
        return location.timestamp.timeIntervalSince(currentLocation.timestamp) >= minimumInterval
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

    private nonisolated static func locationServicesEnabled() async -> Bool {
        await Task.detached(priority: .utility) {
            CLLocationManager.locationServicesEnabled()
        }.value
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
        if !locationContinuations.isEmpty || shouldPublish(location) {
            currentLocation = location
        }
        finishLocationWaits(with: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finishLocationWaits(with: nil)
    }
}
#endif
