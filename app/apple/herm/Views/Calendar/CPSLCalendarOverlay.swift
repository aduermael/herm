import SwiftUI

struct CPSLCalendarOverlay: View {
    @ObservedObject private var model: CPSLChatModel
    @ObservedObject private var calendar: CPSLCalendarService
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(
        model: CPSLChatModel,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) {
        _model = ObservedObject(wrappedValue: model)
        _calendar = ObservedObject(wrappedValue: model.calendar)
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
    @ObservedObject var model: CPSLChatModel
    @ObservedObject var calendar: CPSLCalendarService

    var body: some View {
        CPSLFileOverlayPanel {
            CPSLCalendarHeader(model: model, calendar: calendar)
        } content: {
            CPSLCalendarContent(calendar: calendar)
        }
    }
}

private struct CPSLCalendarHeader: View {
    @ObservedObject var model: CPSLChatModel
    @ObservedObject var calendar: CPSLCalendarService

    private var subtitle: LocalizedStringKey {
        switch calendar.access {
        case .granted:
            return calendar.upcomingEvents.isEmpty ? "No upcoming events loaded" : "Upcoming events"
        case .denied:
            return "Access denied"
        case .undefined:
            return "Access not requested"
        }
    }

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Image(systemName: "calendar")
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.iconMediumFont)
                .foregroundStyle(CPSLTheme.IconPalette.calendar)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)

            VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
                Text("Calendar")
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: CPSLTheme.medium)

            CPSLFileOverlayIconButton(systemName: "arrow.clockwise", accessibilityLabel: "Refresh calendar") {
                Task {
                    await calendar.loadUpcomingEvents()
                }
            }
            .disabled(calendar.isLoadingEvents)
            .opacity(calendar.isLoadingEvents ? 0.45 : 1)

            CPSLFileOverlayIconButton(systemName: "xmark", accessibilityLabel: "Close calendar") {
                model.closeCalendar()
            }
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.vertical, CPSLTheme.small)
        .frame(minHeight: CPSLTheme.controlSize + CPSLTheme.medium)
    }
}

private struct CPSLCalendarContent: View {
    @ObservedObject var calendar: CPSLCalendarService

    var body: some View {
        ScrollView {
            LazyVStack(spacing: CPSLTheme.small) {
                if calendar.isLoadingEvents {
                    CPSLCalendarStatusRow(systemName: "arrow.clockwise", title: "Loading events")
                } else if let eventError = calendar.eventError {
                    CPSLCalendarStatusRow(systemName: "exclamationmark.triangle.fill", title: eventError)
                } else if calendar.upcomingEvents.isEmpty {
                    CPSLCalendarStatusRow(systemName: "calendar.badge.checkmark", title: "No upcoming events")
                } else {
                    ForEach(calendar.upcomingEvents) { event in
                        CPSLCalendarEventRow(event: event)
                    }
                }
            }
            .padding(CPSLTheme.medium)
        }
        .scrollBounceBehavior(.basedOnSize)
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
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.30),
            strokeOpacity: 0.045
        )
    }
}

private struct CPSLCalendarEventRow: View {
    let event: CPSLCalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: CPSLTheme.medium) {
            CPSLCalendarEventTimeBadge(
                startDate: event.startDate,
                isAllDay: event.isAllDay
            )

            VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
                Text(event.title)
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(2)

                Text(event.calendarTitle)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)

                CPSLCalendarEventDetail(event: event)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CPSLTheme.medium)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.30),
            strokeOpacity: 0.045
        )
    }
}

private struct CPSLCalendarEventTimeBadge: View {
    let startDate: Date
    let isAllDay: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(startDate, format: .dateTime.weekday(.abbreviated))
                .font(CPSLTheme.captionMediumFont)
            Text(startDate, format: .dateTime.day())
                .font(CPSLTheme.supportingMediumFont)
            if isAllDay {
                Text("All day")
                    .font(CPSLTheme.captionFont)
            } else {
                Text(startDate, format: .dateTime.hour().minute())
                    .font(CPSLTheme.captionFont)
            }
        }
        .foregroundStyle(CPSLTheme.text)
        .frame(width: 66)
        .padding(.vertical, CPSLTheme.small)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.IconPalette.calendar, opacity: 0.24),
            strokeOpacity: 0.06
        )
    }
}

private struct CPSLCalendarEventDetail: View {
    let event: CPSLCalendarEvent

    private var intervalText: String {
        let start = event.startDate.formatted(.dateTime.month().day().hour().minute())
        let end = event.endDate.formatted(.dateTime.hour().minute())
        return "\(start) - \(end)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if event.isAllDay {
                Text("All day")
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
            } else {
                Text(intervalText)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
            }

            if let location = event.location {
                Text(location)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}
