@preconcurrency import AVFoundation
import Foundation

enum CPSLDictationError: LocalizedError {
    case notAuthorized
    case unavailable
    case localeUnsupported
    case simulatorUnsupported

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone or speech access denied"
        case .unavailable:
            return "Dictation isn't available on this device"
        case .localeUnsupported:
            return "Dictation isn't available for this language"
        case .simulatorUnsupported:
            return "Dictation needs a real device — it isn't available in the Simulator"
        }
    }
}

/// Voice-to-text engine, kept separate from capture/waveform/state so the
/// backend can be swapped (Apple today, an LLM later). Authorization and model
/// install are split from `prepare()` so the caller can gate capture on them
/// and surface a download state.
@MainActor
protocol CPSLSpeechRecognizer {
    func authorize() async throws
    func modelNeedsDownload() async throws -> Bool
    func installModel() async throws
    func prepare() async throws -> AVAudioFormat
    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<String, Error>
    func finish() async
}
