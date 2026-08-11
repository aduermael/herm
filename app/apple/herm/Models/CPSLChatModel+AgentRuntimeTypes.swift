import Foundation

struct CPSLProviderLoopContext {
    let client: CPSLAgentChatClient
    let store: CPSLConversationStore
    let conversationID: String
    var parentID: String
    let config: CPSLAgentConfig
    /// Resolved provider model id (e.g. apple/pcc or the OpenAI model).
    let modelID: String
    let systemPrompt: String
    var providerMessages: [CPSLOpenAIMessage]
    let onParentIDChange: (String) -> Void
}

struct CPSLRequestPreparation: Sendable {
    let systemPrompt: String
    let providerMessages: [CPSLOpenAIMessage]
    let config: CPSLAgentConfig
    let sandboxDirectory: String
    let iteration: Int
    let maxIterations: Int
}

struct CPSLToolReplayDraft {
    let assistantToolMessage: CPSLOpenAIMessage
    let statusSummary: String
    let executedToolCalls: [(toolCall: CPSLOpenAIToolCall, result: CPSLToolExecutionResult)]
    let model: String
}

struct CPSLPendingConversationContext {
    let store: CPSLConversationStore
    let conversationID: String?
    let parentID: String?
    let model: String?
}

struct CPSLToolExecutionContext {
    let client: CPSLAgentChatClient
    let config: CPSLAgentConfig
    let modelID: String
    let agentDepth: Int
    let requestDirectory: String?
    let traceStore: CPSLConversationStore?
    let conversationID: String?
}

struct CPSLSubAgentOutputDraft {
    let mode: CPSLSubAgentMode
    let turnsUsed: Int
    let maxTurns: Int
    let textParts: [String]
}
