import SwiftUI

/// Replaces the composer while dictation is active: cancel on the left, a live
/// waveform in the middle, and confirm on the right.
struct CPSLDictationBarView: View {
    var dictation: CPSLDictationService
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            cancelButton

            CPSLDictationStatusView(dictation: dictation)
                .frame(maxWidth: .infinity)
                .frame(height: CPSLTheme.controlSize)

            confirmButton
        }
        .animation(.easeOut(duration: 0.15), value: dictation.state)
        .padding(CPSLTheme.composerPadding)
        .cpslGlassBackground(
            in: Capsule(),
            tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.54),
            strokeOpacity: 0.055
        )
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(CPSLTheme.iconMediumFont)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .cpslGlassBackground(
            in: Circle(),
            tint: CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.38),
            strokeOpacity: 0.045
        )
        .accessibilityLabel("Cancel dictation")
    }

    private var confirmButton: some View {
        Button(action: onConfirm) {
            Image(systemName: "arrow.up")
                .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconLarge, weight: .semibold))
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.background)
        .background(CPSLTheme.text)
        .clipShape(Circle())
        .disabled(dictation.state != .recording)
        .opacity(dictation.state == .recording ? 1 : 0.45)
        .accessibilityLabel("Finish dictation")
    }
}
