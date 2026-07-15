import SwiftUI

private enum CPSLCalendarMotion {
    static let animation = Animation.easeOut(duration: 0.2)
    static let listTransition = AnyTransition.move(edge: .leading)
    static let detailTransition = AnyTransition.move(edge: .trailing)
}

struct CPSLCalendarOverlay: View {
    private let model: CPSLChatModel
    private let calendar: CPSLCalendarService
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(
        model: CPSLChatModel,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) {
        self.model = model
        calendar = model.calendar
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    var body: some View {
        CPSLFileOverlayStage(
            metrics: CPSLFileOverlayStageMetrics(
                topInset: topInset,
                bottomInset: bottomInset,
                dimOpacity: 0.001
            )
        ) {
            CPSLCalendarPanel(model: model, calendar: calendar)
        }
    }
}

private struct CPSLCalendarPanel: View {
    let model: CPSLChatModel
    let calendar: CPSLCalendarService
    @State private var selectedEvent: CPSLCalendarEvent?

    var body: some View {
        CPSLFileOverlayPanel {
            CPSLCalendarHeader(
                model: model,
                calendar: calendar,
                selectedEvent: selectedEvent,
                onBack: { selectedEvent = nil }
            )
        } content: {
            CPSLCalendarRouteContent(
                calendar: calendar,
                selectedEvent: selectedEvent,
                onSelect: { selectedEvent = $0 },
                onOpenAttachment: model.openFilePathFromTimeline
            )
        }
    }
}

private struct CPSLCalendarRouteContent: View {
    let calendar: CPSLCalendarService
    let selectedEvent: CPSLCalendarEvent?
    let onSelect: (CPSLCalendarEvent) -> Void
    let onOpenAttachment: (String) -> Void

    var body: some View {
        ZStack {
            if let selectedEvent {
                CPSLCalendarEventDetailView(
                    event: selectedEvent,
                    onOpenAttachment: onOpenAttachment
                )
                .transition(CPSLCalendarMotion.detailTransition)
                .zIndex(1)
            } else {
                CPSLCalendarEventList(calendar: calendar, onSelect: onSelect)
                    .transition(CPSLCalendarMotion.listTransition)
                    .zIndex(0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(CPSLTheme.command)
        .clipped()
        .animation(CPSLCalendarMotion.animation, value: selectedEvent?.id)
    }
}

private struct CPSLCalendarHeader: View {
    let model: CPSLChatModel
    @ObservedObject var calendar: CPSLCalendarService
    let selectedEvent: CPSLCalendarEvent?
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            if selectedEvent != nil {
                CPSLFileOverlayIconButton(systemName: "chevron.left", accessibilityLabel: "Back") {
                    onBack()
                }
            } else {
                Image(systemName: "calendar")
                    .symbolRenderingMode(.hierarchical)
                    .font(CPSLTheme.iconMediumFont)
                    .foregroundStyle(CPSLTheme.IconPalette.calendar)
                    .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
            }

            CPSLCalendarHeaderTitle(
                title: selectedEvent?.title,
                startDate: selectedEvent?.startDate,
                fallbackSubtitle: listSubtitle
            )

            if selectedEvent == nil {
                CPSLFileOverlayIconButton(
                    systemName: "arrow.clockwise",
                    accessibilityLabel: "Refresh calendar"
                ) {
                    Task {
                        await calendar.loadUpcomingEvents()
                    }
                }
                .disabled(calendar.isLoadingEvents)
                .opacity(calendar.isLoadingEvents ? 0.45 : 1)
            }

            CPSLFileOverlayIconButton(systemName: "xmark", accessibilityLabel: "Close calendar") {
                model.closeCalendar()
            }
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.vertical, CPSLTheme.small)
        .frame(minHeight: CPSLTheme.controlSize + CPSLTheme.medium)
    }

    private var listSubtitle: LocalizedStringKey {
        switch calendar.access {
        case .granted:
            return calendar.upcomingEvents.isEmpty ? "No upcoming events loaded" : "Upcoming events"
        case .denied:
            return "Access denied"
        case .undefined:
            return "Access not requested"
        }
    }
}

private struct CPSLCalendarHeaderTitle: View {
    let title: String?
    let startDate: Date?
    let fallbackSubtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
            if let title {
                Text(title)
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(1)
            } else {
                Text("Calendar")
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(1)
            }

            if let startDate {
                Text(startDate, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
            } else {
                Text(fallbackSubtitle)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CPSLCalendarEventList: View {
    @ObservedObject var calendar: CPSLCalendarService
    let onSelect: (CPSLCalendarEvent) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: CPSLTheme.large) {
                if calendar.isLoadingEvents {
                    CPSLCalendarStatusRow(systemName: "arrow.clockwise", title: "Loading events")
                } else if let eventError = calendar.eventError {
                    CPSLCalendarStatusRow(systemName: "exclamationmark.triangle.fill", title: eventError)
                } else if calendar.upcomingEventDays.isEmpty {
                    CPSLCalendarStatusRow(systemName: "calendar.badge.checkmark", title: "No upcoming events")
                } else {
                    ForEach(calendar.upcomingEventDays) { day in
                        CPSLCalendarDaySection(
                            date: day.date,
                            events: day.events,
                            onSelect: onSelect
                        )
                    }
                }
            }
            .padding(CPSLTheme.medium)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct CPSLCalendarDaySection: View {
    let date: Date
    let events: [CPSLCalendarEvent]
    let onSelect: (CPSLCalendarEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(CPSLTheme.captionMediumFont)
                .foregroundStyle(CPSLTheme.secondaryText)

            VStack(spacing: CPSLTheme.small) {
                ForEach(events) { event in
                    CPSLCalendarEventRow(
                        title: event.title,
                        calendarColor: event.calendarColor,
                        startDate: event.startDate,
                        isAllDay: event.isAllDay,
                        location: event.location,
                        action: { onSelect(event) }
                    )
                }
            }
        }
    }
}

private struct CPSLCalendarStatusRow: View {
    let systemName: String
    let title: String

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.iconMediumFont)
                .foregroundStyle(CPSLTheme.IconPalette.calendar)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)

            Text(title)
                .font(CPSLTheme.bodyFont)
                .foregroundStyle(CPSLTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CPSLTheme.medium)
        .cpslSurfaceBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLTheme.background.opacity(0.30),
            strokeOpacity: 0.045
        )
    }
}

private struct CPSLCalendarEventRow: View {
    let title: String
    let calendarColor: CPSLCalendarColor?
    let startDate: Date
    let isAllDay: Bool
    let location: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .leading) {
                HStack(alignment: .top, spacing: CPSLTheme.medium) {
                    CPSLCalendarEventTime(startDate: startDate, isAllDay: isAllDay)

                    VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
                        Text(title)
                            .font(CPSLTheme.supportingMediumFont)
                            .foregroundStyle(CPSLTheme.text)
                            .lineLimit(2)

                        if let location {
                            Label(location, systemImage: "location")
                                .font(CPSLTheme.captionFont)
                                .foregroundStyle(CPSLTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(CPSLTheme.iconSmallFont)
                        .foregroundStyle(CPSLTheme.mutedText)
                        .frame(height: CPSLTheme.controlSize)
                }
                .padding(CPSLTheme.medium)

                CPSLCalendarColorBorder(calendarColor: calendarColor)
            }
            .contentShape(Rectangle())
            .cpslSurfaceBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                tint: CPSLTheme.background.opacity(0.30),
                strokeOpacity: 0.045
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CPSLCalendarColorBorder: View {
    let calendarColor: CPSLCalendarColor?

    var body: some View {
        Rectangle()
            .fill(displayColor)
            .frame(width: 4)
            .accessibilityHidden(true)
    }

    private var displayColor: Color {
        guard let calendarColor else {
            return .clear
        }
        return Color(
            .sRGB,
            red: calendarColor.red,
            green: calendarColor.green,
            blue: calendarColor.blue,
            opacity: calendarColor.alpha
        )
    }
}

private struct CPSLCalendarEventTime: View {
    let startDate: Date
    let isAllDay: Bool

    var body: some View {
        Group {
            if isAllDay {
                Text("All day")
            } else {
                Text(startDate, format: .dateTime.hour().minute())
            }
        }
        .font(CPSLTheme.captionMediumFont)
        .foregroundStyle(CPSLTheme.text)
        .frame(width: 64, alignment: .leading)
        .padding(.vertical, CPSLTheme.small)
    }
}

private struct CPSLCalendarEventDetailView: View {
    let event: CPSLCalendarEvent
    let onOpenAttachment: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CPSLTheme.large) {
                CPSLCalendarEventDetailHeader(
                    title: event.title,
                    calendarTitle: event.calendarTitle
                )
                CPSLCalendarEventSchedule(
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay
                )
                if let location = event.location {
                    CPSLCalendarEventDetailField(
                        title: "Location",
                        value: location,
                        systemName: "location.fill"
                    )
                }
                if let notes = event.notes {
                    CPSLCalendarEventNotes(notes: notes)
                }
                if let url = event.url {
                    CPSLCalendarEventLink(url: url)
                }
                if !event.attachments.isEmpty {
                    CPSLCalendarEventAttachments(
                        attachments: event.attachments,
                        onOpen: onOpenAttachment
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CPSLTheme.large)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct CPSLCalendarEventDetailHeader: View {
    let title: String
    let calendarTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            Text(title)
                .font(CPSLTheme.headerFont)
                .foregroundStyle(CPSLTheme.text)
            Label(calendarTitle, systemImage: "calendar")
                .font(CPSLTheme.captionFont)
                .foregroundStyle(CPSLTheme.secondaryText)
                .lineLimit(nil)
                .textSelection(.enabled)
        }
    }
}

private struct CPSLCalendarEventSchedule: View {
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            Label("When", systemImage: "clock.fill")
                .font(CPSLTheme.captionMediumFont)
                .foregroundStyle(CPSLTheme.secondaryText)

            if isAllDay {
                Text(startDate, format: .dateTime.weekday(.wide).month(.wide).day().year())
                Text("All day")
            } else {
                Text(startDate, format: .dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
                Text("Ends \(endDate, format: .dateTime.weekday(.wide).month(.wide).day().year().hour().minute())")
            }
        }
        .font(CPSLTheme.bodyFont)
        .foregroundStyle(CPSLTheme.text)
    }
}

private struct CPSLCalendarEventDetailField: View {
    let title: LocalizedStringKey
    let value: String
    let systemName: String

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            Label(title, systemImage: systemName)
                .font(CPSLTheme.captionMediumFont)
                .foregroundStyle(CPSLTheme.secondaryText)
            Text(value)
                .font(CPSLTheme.bodyFont)
                .foregroundStyle(CPSLTheme.text)
                .textSelection(.enabled)
        }
    }
}

private struct CPSLCalendarEventNotes: View {
    let notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            Label("Notes", systemImage: "note.text")
                .font(CPSLTheme.captionMediumFont)
                .foregroundStyle(CPSLTheme.secondaryText)
            Text(notes)
                .font(CPSLTheme.bodyFont)
                .foregroundStyle(CPSLTheme.text)
                .textSelection(.enabled)
        }
    }
}

private struct CPSLCalendarEventLink: View {
    let url: URL

    var body: some View {
        Link(destination: url) {
            Label(url.absoluteString, systemImage: "link")
                .font(CPSLTheme.bodyFont)
                .lineLimit(2)
        }
    }
}

private struct CPSLCalendarEventAttachments: View {
    let attachments: [CPSLCalendarAttachment]
    let onOpen: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            Label("Attachments", systemImage: "paperclip")
                .font(CPSLTheme.captionMediumFont)
                .foregroundStyle(CPSLTheme.secondaryText)

            ForEach(attachments) { attachment in
                Button {
                    onOpen(attachment.path)
                } label: {
                    HStack(spacing: CPSLTheme.small) {
                        Image(systemName: "doc")
                        Text(attachment.name)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(CPSLTheme.bodyFont)
                    .foregroundStyle(CPSLTheme.text)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open attachment \(attachment.name)")
            }
        }
    }
}
