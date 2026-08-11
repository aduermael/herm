import Foundation

/// Stub PCC runtime used when the active SDK lacks iOS/macOS 27 PCC APIs
/// (iOS/macOS 26.x and non-Apple hosts). Selection always falls back to OpenAI/Grok.
enum CPSLPCCRuntime {
    static var isCompileTimeSupported: Bool { false }

    static var isAvailable: Bool { false }

    static func streamChat(
        _ streamRequest: CPSLOpenAIStreamRequest,
        modelID: String,
        onEvent: @escaping (CPSLOpenAIStreamEvent) async -> Void
    ) async throws -> CPSLOpenAICompletion {
        _ = streamRequest
        _ = modelID
        _ = onEvent
        throw CPSLOpenAIError.provider(
            "Apple Private Cloud Compute requires building with the iOS/macOS 27 SDK."
        )
    }
}
