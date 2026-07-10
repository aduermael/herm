import SwiftUI
#if canImport(CoreLocation)
@preconcurrency import CoreLocation
#endif

struct CPSLToolStripView: View {
    @ObservedObject var model: CPSLChatModel
    @ObservedObject private var calendar: CPSLCalendarService
    @ObservedObject private var location: CPSLLocationService

    init(model: CPSLChatModel) {
        self.model = model
        _calendar = ObservedObject(wrappedValue: model.calendar)
        _location = ObservedObject(wrappedValue: model.location)
    }

    private func controlTint(isActive: Bool) -> Color {
        isActive ? CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.52) : CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.40)
    }

    private func controlStrokeOpacity(isActive: Bool) -> Double {
        isActive ? 0.10 : 0.045
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CPSLTheme.medium) {
                CPSLToolStripLabeledButton(
                    title: "Files",
                    systemName: "folder.fill",
                    color: CPSLTheme.IconPalette.folder,
                    tint: controlTint(isActive: model.isFileBrowserOpen),
                    strokeOpacity: controlStrokeOpacity(isActive: model.isFileBrowserOpen),
                    isActive: model.isFileBrowserOpen,
                    isActivityActive: model.isFileActivityActive
                ) {
                    model.toggleFileBrowser()
                }

                CPSLToolStripIconButton(
                    accessibilityLabel: "Browser",
                    systemName: "globe",
                    color: CPSLTheme.success,
                    tint: controlTint(isActive: model.isWebBrowserOpen),
                    strokeOpacity: controlStrokeOpacity(isActive: model.isWebBrowserOpen),
                    isActive: model.isWebBrowserOpen,
                    isActivityActive: model.webBrowser.isActivityActive
                ) {
                    model.toggleWebBrowser()
                }

                CPSLToolStripIconButton(
                    accessibilityLabel: "Calendar",
                    systemName: "calendar",
                    color: CPSLTheme.IconPalette.calendar,
                    tint: controlTint(isActive: model.isCalendarOpen),
                    strokeOpacity: controlStrokeOpacity(isActive: model.isCalendarOpen),
                    isActive: model.isCalendarOpen,
                    isActivityActive: model.isCalendarActivityActive
                ) {
                    model.toggleCalendar()
                }

                CPSLLocationToolStripButton(
                    access: location.access,
                    location: location.currentLocation,
                    isOpen: model.isLocationOpen,
                    isActivityActive: model.isLocationActivityActive
                ) {
                    model.toggleLocation()
                }

                CPSLDisabledToolIcon(systemName: "envelope.fill", color: CPSLTheme.IconPalette.mail)
            }
            .padding(.horizontal, CPSLTheme.chromeHorizontalInset)
        }
        .frame(height: CPSLTheme.controlSize)
        .padding(.bottom, CPSLTheme.medium)
    }
}

private struct CPSLLocationToolStripButton: View {
    let access: CPSLFeatureAccessState
    let location: CLLocation?
    let isOpen: Bool
    let isActivityActive: Bool
    let action: () -> Void

    private var hasMapBackground: Bool {
        access.isGranted && location != nil
    }

    var body: some View {
        Button(action: action) {
            if hasMapBackground, let location {
                CPSLLocationToolStripMapLabel(
                    location: location,
                    isOpen: isOpen,
                    isActivityActive: isActivityActive
                )
            } else {
                CPSLToolStripIconLabel(
                    systemName: "location.fill",
                    color: CPSLTheme.success,
                    tint: isOpen || access.isGranted
                        ? CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.52)
                        : CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.40),
                    strokeOpacity: isOpen || access.isGranted ? 0.10 : 0.045,
                    isActive: isOpen,
                    isActivityActive: isActivityActive
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .accessibilityLabel("Location")
        .help("Location")
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLLocationToolStripMapLabel: View {
    let location: CLLocation
    let isOpen: Bool
    let isActivityActive: Bool

    var body: some View {
        CPSLLocationMapView(location: location, markerSize: 9)
        .frame(width: CPSLTheme.controlSize * 1.45, height: CPSLTheme.controlSize)
        .background {
            CPSLTheme.background.opacity(0.18)
        }
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous)
                .stroke(CPSLTheme.text.opacity(isOpen ? 0.14 : 0.10), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .cpslAnimatedPastelRainbowBorder(
            when: isOpen,
            duringActivity: isActivityActive,
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLToolStripLabeledButton: View {
    let title: LocalizedStringKey
    let systemName: String
    let color: Color
    let tint: Color
    let strokeOpacity: Double
    let isActive: Bool
    var isActivityActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CPSLToolStripButtonLabel(
                title: title,
                systemName: systemName,
                color: color,
                tint: tint,
                strokeOpacity: strokeOpacity,
                isActive: isActive,
                isActivityActive: isActivityActive
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLToolStripIconButton: View {
    let accessibilityLabel: String
    let systemName: String
    let color: Color
    let tint: Color
    let strokeOpacity: Double
    let isActive: Bool
    var isActivityActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CPSLToolStripIconLabel(
                systemName: systemName,
                color: color,
                tint: tint,
                strokeOpacity: strokeOpacity,
                isActive: isActive,
                isActivityActive: isActivityActive
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLToolStripButtonLabel: View {
    let title: LocalizedStringKey
    let systemName: String
    let color: Color
    let tint: Color
    let strokeOpacity: Double
    let isActive: Bool
    let isActivityActive: Bool

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(CPSLTheme.controlFont)
        }
        .padding(.horizontal, CPSLTheme.medium)
        .frame(height: CPSLTheme.controlSize)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
            tint: tint,
            strokeOpacity: strokeOpacity
        )
        .cpslAnimatedPastelRainbowBorder(
            when: isActive,
            duringActivity: isActivityActive,
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLToolStripIconLabel: View {
    let systemName: String
    let color: Color
    let tint: Color
    let strokeOpacity: Double
    let isActive: Bool
    let isActivityActive: Bool

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
            .cpslGlassBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
                tint: tint,
                strokeOpacity: strokeOpacity
            )
            .cpslAnimatedPastelRainbowBorder(
                when: isActive,
                duringActivity: isActivityActive,
                in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLDisabledToolIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
            .cpslGlassBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
                tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.34),
                strokeOpacity: 0.035
            )
            .opacity(0.62)
    }
}
