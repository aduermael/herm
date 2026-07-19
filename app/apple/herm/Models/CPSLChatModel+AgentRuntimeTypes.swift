import Foundation

struct CPSLProviderLoopContext {
    let client: CPSLOpenAIClient
    let store: CPSLConversationStore
    let conversationID: String
    var parentID: String
    let config: CPSLAgentConfig
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
    let client: CPSLOpenAIClient
    let config: CPSLAgentConfig
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
