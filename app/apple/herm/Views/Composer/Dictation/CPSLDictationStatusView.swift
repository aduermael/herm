import SwiftUI

/// Center of the dictation bar: names the current phase until audio flows,
/// then shows the live waveform.
struct CPSLDictationStatusView: View {
    var dictation: CPSLDictationService

    var body: some View {
        switch dictation.state {
        case .idle:
            Color.clear
        case .preparing:
            phaseLabel("Getting ready…")
        case .downloadingModel:
            phaseLabel("Downloading speech model…")
        case .recording:
            CPSLDictationWaveform(dictation: dictation)
        case .finishing:
            phaseLabel("Transcribing…")
        }
    }

    private func phaseLabel(_ text: String) -> some View {
        HStack(spacing: CPSLTheme.small) {
            ProgressView()
                .controlSize(.small)
                .tint(CPSLTheme.mutedText)
            Text(text)
                .font(CPSLTheme.controlFont)
                .foregroundStyle(CPSLTheme.mutedText)
                .lineLimit(1)
        }
    }
}

/// Reads `levels` in its own body so each level tick only redraws the
/// waveform, not the whole bar.
private struct CPSLDictationWaveform: View {
    var dictation: CPSLDictationService

    var body: some View {
        CPSLWaveformView(levels: dictation.levels, color: CPSLTheme.text)
    }
}
