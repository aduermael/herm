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
                            .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
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

                CPSLDisabledToolIcon(systemName: "envelope.fill")
                CPSLDisabledToolIcon(systemName: "calendar")
            }
            .padding(.horizontal, CPSLTheme.chromeHorizontalInset)
        }
        .padding(.bottom, CPSLTheme.medium)
    }
}

private struct CPSLDisabledToolIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
            .foregroundStyle(CPSLTheme.mutedText)
            .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
            .cpslGlassBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
                tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.34),
                strokeOpacity: 0.035
            )
            .opacity(0.62)
    }
}
