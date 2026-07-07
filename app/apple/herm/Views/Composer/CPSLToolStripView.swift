import SwiftUI

struct CPSLToolStripView: View {
    @ObservedObject var model: CPSLChatModel

    private func controlTint(isActive: Bool) -> Color {
        isActive ? CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.52) : CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.40)
    }

    private func controlStrokeOpacity(isActive: Bool) -> Double {
        isActive ? 0.10 : 0.045
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CPSLTheme.medium) {
                CPSLToolStripButton(
                    title: "Files",
                    systemName: "folder.fill",
                    color: CPSLTheme.IconPalette.folder,
                    tint: controlTint(isActive: model.isFileBrowserOpen),
                    strokeOpacity: controlStrokeOpacity(isActive: model.isFileBrowserOpen)
                ) {
                    model.toggleFileBrowser()
                }

                CPSLToolStripButton(
                    title: "Browser",
                    systemName: "globe",
                    color: CPSLTheme.success,
                    tint: controlTint(isActive: model.isWebBrowserOpen),
                    strokeOpacity: controlStrokeOpacity(isActive: model.isWebBrowserOpen),
                    isGlowing: model.webBrowser.isActivityActive
                ) {
                    model.toggleWebBrowser()
                }

                CPSLDisabledToolIcon(systemName: "envelope.fill", color: CPSLTheme.IconPalette.mail)
                CPSLDisabledToolIcon(systemName: "calendar", color: CPSLTheme.IconPalette.calendar)
            }
            .padding(.horizontal, CPSLTheme.chromeHorizontalInset)
        }
        .frame(height: CPSLTheme.controlSize)
        .padding(.bottom, CPSLTheme.medium)
    }
}

private struct CPSLToolStripButton: View {
    let title: LocalizedStringKey
    let systemName: String
    let color: Color
    let tint: Color
    let strokeOpacity: Double
    var isGlowing = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CPSLToolStripButtonLabel(
                title: title,
                systemName: systemName,
                color: color,
                tint: tint,
                strokeOpacity: strokeOpacity,
                isGlowing: isGlowing
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLToolStripButtonLabel: View {
    let title: LocalizedStringKey
    let systemName: String
    let color: Color
    let tint: Color
    let strokeOpacity: Double
    let isGlowing: Bool

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
            strokeOpacity: isGlowing ? 0.18 : strokeOpacity
        )
        .overlay {
            if isGlowing {
                CPSLBrowserActivityGlow(color: color)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLBrowserActivityGlow: View {
    let color: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            let opacity = glowOpacity(at: timeline.date)
            RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous)
                .stroke(color.opacity(opacity), lineWidth: 1.6)
                .shadow(color: color.opacity(opacity * 0.9), radius: 8, x: 0, y: 0)
        }
        .allowsHitTesting(false)
    }

    private func glowOpacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
        return 0.35 + (sin(phase * .pi * 2) + 1) * 0.20
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
