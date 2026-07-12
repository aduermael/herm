import Combine
import Foundation
#if canImport(EventKit)
import EventKit
#endif

struct CPSLCalendarEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let calendarTitle: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    let location: String?
    let attachments: [CPSLCalendarAttachment]
}

struct CPSLCalendarAttachment: Identifiable, Equatable, Sendable {
    var id: String { path }

    let name: String
    let path: String
}

@MainActor
final class CPSLCalendarService: ObservableObject {
    @Published private(set) var access: CPSLFeatureAccessState = .undefined
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var isLoadingEvents = false
    @Published private(set) var upcomingEvents: [CPSLCalendarEvent] = []
    @Published private(set) var eventError: String?

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

    func loadUpcomingEvents() async -> CPSLFeatureAccessState {
        let access = await requestAccess()
        guard access == .granted else {
            upcomingEvents = []
            eventError = "Calendar access is denied. Enable Calendar access for Herm in iOS Settings or macOS System Settings."
            return access
        }

#if canImport(EventKit)
        isLoadingEvents = true
        eventError = nil
        defer {
            isLoadingEvents = false
        }

        let now = Date()
        let endDate = Foundation.Calendar.current.date(byAdding: .day, value: 14, to: now)
            ?? now.addingTimeInterval(14 * 24 * 60 * 60)
        let predicate = eventStore.predicateForEvents(
            withStart: now,
            end: endDate,
            calendars: nil
        )
        upcomingEvents = eventStore.events(matching: predicate)
            .sorted { lhs, rhs in
                lhs.startDate < rhs.startDate
            }
            .prefix(12)
            .map(Self.event(from:))
        upcomingEvents = Self.eventsWithUniqueIDs(upcomingEvents)
#else
        upcomingEvents = []
        eventError = "Calendar is unavailable on this platform."
#endif
        return access
    }

#if canImport(EventKit)
    private static func event(from event: EKEvent) -> CPSLCalendarEvent {
        let id = [
            event.eventIdentifier,
            event.calendarItemIdentifier,
            event.calendar?.calendarIdentifier,
            String(event.startDate.timeIntervalSince1970),
            String(event.endDate.timeIntervalSince1970),
            event.title
        ]
        .compactMap { $0?.cpslNilIfEmpty }
        .joined(separator: "|")
        return CPSLCalendarEvent(
            id: id,
            title: event.title?.cpslNilIfEmpty ?? "Untitled event",
            calendarTitle: event.calendar?.title ?? "Calendar",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            location: event.location?.cpslNilIfEmpty,
            attachments: Self.attachments(from: event.notes)
        )
    }

    private static func eventsWithUniqueIDs(_ events: [CPSLCalendarEvent]) -> [CPSLCalendarEvent] {
        var countsByID: [String: Int] = [:]
        return events.map { event in
            let count = countsByID[event.id, default: 0]
            countsByID[event.id] = count + 1
            guard count > 0 else {
                return event
            }
            return CPSLCalendarEvent(
                id: "\(event.id)|duplicate-\(count)",
                title: event.title,
                calendarTitle: event.calendarTitle,
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location,
                attachments: event.attachments
            )
        }
    }

    private static func attachments(from notes: String?) -> [CPSLCalendarAttachment] {
        let attachmentRoot = "/home/herm/calendar-attachments/"
        guard let notes,
              let startRange = notes.range(of: "[Herm attachments]"),
              let endRange = notes.range(
                  of: "[/Herm attachments]",
                  range: startRange.upperBound..<notes.endIndex
              )
        else {
            return []
        }

        var seenPaths = Set<String>()
        return notes[startRange.upperBound..<endRange.lowerBound]
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { path in
                guard path.hasPrefix(attachmentRoot) else {
                    return false
                }
                let relativePath = path.dropFirst(attachmentRoot.count)
                let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
                return components.count == 2 && components.allSatisfy { component in
                    !component.isEmpty && component != "." && component != ".."
                }
            }
            .filter { seenPaths.insert($0).inserted }
            .map { path in
                CPSLCalendarAttachment(
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    path: path
                )
            }
    }

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
        case .fullAccess:
            return .granted
        case .notDetermined:
            return .undefined
        case .denied, .restricted, .writeOnly:
            return .denied
        @unknown default:
            return .denied
        }
    }
#endif
}

private extension String {
    var cpslNilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
