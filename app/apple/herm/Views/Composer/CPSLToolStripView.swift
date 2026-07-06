import SwiftUI

struct CPSLToolStripView: View {
    @ObservedObject var model: CPSLChatModel

    private var filesControlTint: Color {
        model.isFileBrowserOpen ? CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.52) : CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.40)
    }

    private var filesControlStrokeOpacity: Double {
        model.isFileBrowserOpen ? 0.10 : 0.045
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CPSLTheme.medium) {
                Button {
                    model.toggleFileBrowser()
                } label: {
                    HStack(spacing: CPSLTheme.small) {
                        Image(systemName: "folder.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
                            .foregroundStyle(CPSLTheme.IconPalette.folder)
                        Text("Files")
                            .font(CPSLTheme.controlFont)
                    }
                    .padding(.horizontal, CPSLTheme.medium)
                    .frame(height: CPSLTheme.controlSize)
                    .cpslGlassBackground(
                        in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
                        tint: filesControlTint,
                        strokeOpacity: filesControlStrokeOpacity
                    )
                    .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.text)
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))

                CPSLDisabledToolIcon(systemName: "envelope.fill", color: CPSLTheme.IconPalette.mail)
                CPSLDisabledToolIcon(systemName: "calendar", color: CPSLTheme.IconPalette.calendar)
            }
            .padding(.horizontal, CPSLTheme.chromeHorizontalInset)
        }
        .frame(height: CPSLTheme.controlSize)
        .padding(.bottom, CPSLTheme.medium)
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
