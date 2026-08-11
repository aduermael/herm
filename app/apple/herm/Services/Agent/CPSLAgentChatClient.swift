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
            #if canImport(FoundationModels)
            if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                do {
                    return try await CPSLPCCClient(modelID: modelID).streamChat(
                        streamRequest,
                        onEvent: onEvent
                    )
                } catch {
                    // Hard failure on an explicitly selected PCC path — do not
                    // silently send main-agent traffic to Grok. Callers may
                    // construct a client with `.openAI` for forced fallback tests.
                    throw error
                }
            }
            #endif
            throw CPSLOpenAIError.provider(
                "Apple Private Cloud Compute was selected but is not available in this build."
            )
        }
        return try await openAI.streamChat(streamRequest, onEvent: onEvent)
    }
}
