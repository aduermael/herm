import Combine
import Foundation
#if canImport(EventKit)
import EventKit
#endif

@MainActor
final class CPSLCalendarService: ObservableObject {
    @Published private(set) var access: CPSLFeatureAccessState = .undefined
    @Published private(set) var isRequestingAccess = false

#if canImport(EventKit)
    private let eventStore = EKEventStore()
#endif

    init() {
        refreshStatus()
    }

    func refreshStatus() {
#if canImport(EventKit)
        access = Self.accessState(for: EKEventStore.authorizationStatus(for: .event))
#else
        access = .denied
#endif
    }

    func requestAccess() async -> CPSLFeatureAccessState {
        refreshStatus()
        guard access == .undefined else {
            return access
        }

#if canImport(EventKit)
        isRequestingAccess = true
        defer {
            isRequestingAccess = false
        }

        do {
            if #available(iOS 17.0, macOS 14.0, *) {
                _ = try await eventStore.requestFullAccessToEvents()
            } else {
                _ = try await eventStore.requestAccess(to: .event)
            }
        } catch {
            access = .denied
            return access
        }
        refreshStatus()
#else
        access = .denied
#endif
        return access
    }

#if canImport(EventKit)
    private static func accessState(for status: EKAuthorizationStatus) -> CPSLFeatureAccessState {
        if #available(iOS 17.0, macOS 14.0, *) {
            switch status {
            case .authorized, .fullAccess:
                return .granted
            case .notDetermined:
                return .undefined
            case .denied, .restricted, .writeOnly:
                return .denied
            @unknown default:
                return .denied
            }
        }

        switch status {
        case .authorized:
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
}
