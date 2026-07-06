import Accelerate
@preconcurrency import AVFoundation
import Foundation
import Observation

enum CPSLDictationState {
    case idle
    /// Permissions and model checks; capture hasn't started.
    case preparing
    /// First use of a language; capture hasn't started.
    case downloadingModel
    case recording
    /// Capture stopped, transcription finalizing.
    case finishing
}

/// Drives dictation: mic capture, waveform levels and state. Delegates
/// voice-to-text to an injected `CPSLSpeechRecognizer`.
@MainActor
@Observable
final class CPSLDictationService {
    private var isSimulator: Bool {
#if targetEnvironment(simulator)
        true
#else
        false
#endif
    }

    private var microphoneDenied: Bool {
#if os(macOS)
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        return micStatus == .denied || micStatus == .restricted
#else
        return AVAudioApplication.shared.recordPermission == .denied
#endif
    }

    private(set) var state: CPSLDictationState = .idle
    private(set) var transcript = ""
    private(set) var levels: [Float] = []
    var errorMessage: String?

    var isActive: Bool {
        state != .idle
    }

    private static let audioQueue = DispatchQueue(label: "CPSLDictationService.audio")

    @ObservationIgnored private let recognizer: any CPSLSpeechRecognizer
    @ObservationIgnored private let maxLevels = 256
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var audioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    @ObservationIgnored private var levelContinuation: AsyncStream<Float>.Continuation?
    @ObservationIgnored private var transcriptTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(recognizer: (any CPSLSpeechRecognizer)? = nil) {
        self.recognizer = recognizer ?? CPSLAppleSpeechRecognizer()
    }

    func start() {
        guard state == .idle else {
            return
        }
        guard !isSimulator else {
            errorMessage = CPSLDictationError.simulatorUnsupported.errorDescription
            return
        }
        guard !microphoneDenied else {
            errorMessage = CPSLDictationError.notAuthorized.errorDescription
            return
        }
        state = .preparing
        errorMessage = nil
        transcript = ""
        levels = []
        startTask = Task {
            do {
                try await beginRecording()
            } catch {
                if !(error is CancellationError) {
                    self.errorMessage = (error as? CPSLDictationError)?.errorDescription
                        ?? error.localizedDescription
                }
                self.abort()
            }
        }
    }

    /// Stops capture but lets transcription finalize so the complete text lands
    /// in `transcript` before the session closes. Use when keeping the result.
    func finish() {
        switch state {
        case .idle, .finishing:
            return
        case .preparing, .downloadingModel:
            cancel()
            return
        case .recording:
            break
        }
        state = .finishing
        stopCapture()
        let recognizer = recognizer
        Task { [weak self] in
            await self?.startTask?.value
            self?.startTask = nil
            await recognizer.finish()
            await self?.transcriptTask?.value
            self?.transcriptTask = nil
            self?.state = .idle
        }
    }

    func cancel() {
        guard isActive else {
            return
        }
        abort()
    }

    private func beginRecording() async throws {
        guard await requestMicrophoneAccess() else {
            throw CPSLDictationError.notAuthorized
        }
        try await recognizer.authorize()

        if try await recognizer.modelNeedsDownload() {
            state = .downloadingModel
            try await recognizer.installModel()
        }

        guard isActive, !Task.isCancelled else {
            return
        }

        let (audioStream, audioContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.audioContinuation = audioContinuation

        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream(
            bufferingPolicy: .bufferingNewest(maxLevels)
        )
        self.levelContinuation = levelContinuation
        levelTask = Task { [weak self] in
            for await value in levelStream {
                guard let self else {
                    return
                }
                levels.append(value)
                if levels.count > maxLevels {
                    levels.removeFirst(levels.count - maxLevels)
                }
            }
        }

        // Capture starts before the recognizer's per-session setup: the
        // unbounded audio stream buffers whatever is said meanwhile, so the
        // first word isn't lost to analyzer spin-up.
        let engine = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAudioEngine, Error>) in
            Self.audioQueue.async {
                do {
                    try Self.startAudioSession()
                    let engine = try Self.startAudioEngine(
                        audioContinuation: audioContinuation,
                        levelContinuation: levelContinuation
                    )
                    continuation.resume(returning: engine)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        guard isActive, !Task.isCancelled, self.audioContinuation != nil else {
            stopEngineOffMain(engine, deactivateSession: self.audioContinuation == nil)
            return
        }
        self.audioEngine = engine
        state = .recording

        let analyzerFormat = try await recognizer.prepare()

        guard isActive, !Task.isCancelled else {
            return
        }

        let transcripts = recognizer.transcribe(
            Self.convertedStream(from: audioStream, to: analyzerFormat)
        )
        transcriptTask = Task { [weak self] in
            do {
                for try await text in transcripts {
                    self?.transcript = text
                }
            } catch {
                if !(error is CancellationError) {
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
#if os(macOS)
        return await AVCaptureDevice.requestAccess(for: .audio)
#else
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
#endif
    }

    private nonisolated static func startAudioSession() throws {
#if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
#endif
    }

    private nonisolated static func startAudioEngine(
        audioContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        levelContinuation: AsyncStream<Float>.Continuation
    ) throws -> AVAudioEngine {
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            levelContinuation.yield(CPSLDictationService.level(of: buffer))
            audioContinuation.yield(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        return audioEngine
    }

    /// Converts captured buffers to the analyzer's format at consumption, so
    /// capture can start before the recognizer has negotiated its format.
    private nonisolated static func convertedStream(
        from audio: AsyncStream<AVAudioPCMBuffer>,
        to format: AVAudioFormat
    ) -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            let task = Task.detached {
                var converter: AVAudioConverter?
                for await buffer in audio {
                    if converter == nil, buffer.format != format {
                        converter = AVAudioConverter(from: buffer.format, to: format)
                        converter?.primeMethod = .none
                    }
                    if let converted = convert(buffer: buffer, using: converter, to: format) {
                        continuation.yield(converted)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return 0
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else {
            return 0
        }
        var rootMeanSquare: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rootMeanSquare, vDSP_Length(frames))
        guard rootMeanSquare > 0 else {
            return 0
        }
        let decibels = 20 * log10(rootMeanSquare)
        let normalized = (decibels + 50) / 50
        return min(1, max(0, normalized))
    }

    private nonisolated static func convert(
        buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let converter else {
            return buffer
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, statusPointer in
            if consumed {
                statusPointer.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusPointer.pointee = .haveData
            return buffer
        }

        if conversionError != nil || output.frameLength == 0 {
            return nil
        }
        return output
    }

    private func abort() {
        startTask?.cancel()
        startTask = nil
        stopCapture()
        transcriptTask?.cancel()
        transcriptTask = nil
        transcript = ""
        state = .idle
        let recognizer = recognizer
        Task {
            await recognizer.finish()
        }
    }

    private func stopCapture() {
        let engine = audioEngine
        audioEngine = nil

        audioContinuation?.finish()
        audioContinuation = nil
        levelContinuation?.finish()
        levelContinuation = nil

        levelTask?.cancel()
        levelTask = nil

        stopEngineOffMain(engine, deactivateSession: true)
    }

    private func stopEngineOffMain(_ engine: AVAudioEngine?, deactivateSession: Bool) {
        Self.audioQueue.async {
            if let engine {
                if engine.isRunning {
                    engine.stop()
                }
                engine.inputNode.removeTap(onBus: 0)
            }
#if !os(macOS)
            if deactivateSession {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
#endif
        }
    }
}
