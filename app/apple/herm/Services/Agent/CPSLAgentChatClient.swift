import Foundation

/// Main-agent chat client: prefers Apple PCC on iOS/macOS 27 when available,
/// otherwise the existing OpenAI-compatible (Grok/xAI) path.
actor CPSLAgentChatClient {
    private let config: CPSLAgentConfig
    private let kind: CPSLAgentProviderKind
    private let openAI: CPSLOpenAIClient

    init(config: CPSLAgentConfig, kind: CPSLAgentProviderKind? = nil) {
        self.config = config
        self.kind = kind ?? CPSLPCCAvailability.resolvedKind()
        self.openAI = CPSLOpenAIClient(config: config)
    }

    var providerKind: CPSLAgentProviderKind {
        kind
    }

    /// Model id recorded on conversation nodes and provider traces.
    var modelID: String {
        CPSLAgentProviderSelection.modelID(kind: kind, openAIModel: config.model)
    }

    func streamChat(
        _ streamRequest: CPSLOpenAIStreamRequest,
        onEvent: @escaping (CPSLOpenAIStreamEvent) async -> Void
    ) async throws -> CPSLOpenAICompletion {
        if kind == .applePCC {
            // Implementation is generated for the active SDK (full on 27+, stub on 26.5).
            return try await CPSLPCCRuntime.streamChat(
                streamRequest,
                modelID: modelID,
                onEvent: onEvent
            )
        }
        return try await openAI.streamChat(streamRequest, onEvent: onEvent)
    }
}
