@preconcurrency import AVFoundation
import Foundation
import Speech

/// On-device voice-to-text via Apple's Speech framework.
@MainActor
final class CPSLAppleSpeechRecognizer: CPSLSpeechRecognizer {
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var negotiatedLocale: (spokenID: String, locale: Locale)?
    private var modelReadySpokenID: String?

    // Locale.current is negotiated against the bundle's localizations (en only),
    // so it forces English regardless of the spoken language. Use the user's
    // actual system language preference instead.
    private var spokenID: String {
        Locale.preferredLanguages.first ?? Locale.current.identifier
    }

    func authorize() async throws {
        guard await requestAuthorization() else {
            throw CPSLDictationError.notAuthorized
        }
    }

    func modelNeedsDownload() async throws -> Bool {
        let spokenID = spokenID
        if modelReadySpokenID == spokenID {
            return false
        }
        let locale = try await resolveLocale(for: spokenID)
        try await AssetInventory.reserve(locale: locale)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            modelReadySpokenID = spokenID
            return false
        }
        return true
    }

    func installModel() async throws {
        let spokenID = spokenID
        let locale = try await resolveLocale(for: spokenID)
        let request = try await AssetInventory.assetInstallationRequest(
            supporting: [makeTranscriber(locale: locale)]
        )
        try await request?.downloadAndInstall()
        modelReadySpokenID = spokenID
    }

    func prepare() async throws -> AVAudioFormat {
        let locale = try await resolveLocale(for: spokenID)
        let transcriber = makeTranscriber(locale: locale)
        self.transcriber = transcriber

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw CPSLDictationError.unavailable
        }
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        return format
    }

    func transcribe(_ audio: AsyncStream<AVAudioPCMBuffer>) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task { @MainActor in
                guard let transcriber = self.transcriber, let analyzer = self.analyzer else {
                    continuation.finish(throwing: CPSLDictationError.unavailable)
                    return
                }

                // Read results before start so no early result is missed.
                let results = Task { @MainActor in
                    var finalized = ""
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        if result.isFinal {
                            finalized += text
                            continuation.yield(finalized)
                        } else {
                            continuation.yield(finalized + text)
                        }
                    }
                }

                defer {
                    results.cancel()
                }

                do {
                    try await analyzer.start(inputSequence: audio.map { AnalyzerInput(buffer: $0) })
                    try await results.value
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    func finish() async {
        let analyzer = analyzer
        self.analyzer = nil
        transcriber = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
    }

    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    private func resolveLocale(for spokenID: String) async throws -> Locale {
        if let negotiated = negotiatedLocale, negotiated.spokenID == spokenID {
            return negotiated.locale
        }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: spokenID)
        ) else {
            throw CPSLDictationError.localeUnsupported
        }
        negotiatedLocale = (spokenID, locale)
        return locale
    }
}
