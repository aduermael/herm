import Foundation

/// Pure OpenAI ↔ PCC mapping used by the PCC adapter and unit tests.
/// No FoundationModels dependency so Linux vet builds can exercise the real units.
nonisolated enum CPSLPCCMessageMapper {
    struct MappedPrompt: Equatable, Sendable {
        let instructions: String
        let prompt: String
    }

    /// Split OpenAI-shaped messages into session instructions (system) and a
    /// single multi-turn prompt that preserves tool call / tool result history.
    static func mapPrompt(messages: [CPSLOpenAIMessage]) -> MappedPrompt {
        var systemParts: [String] = []
        var turns: [String] = []

        for message in messages {
            switch message.role {
            case "system":
                if let content = trimmed(message.content) {
                    systemParts.append(content)
                }
            case "user":
                if let content = trimmed(message.content) {
                    turns.append("User: \(content)")
                }
            case "assistant":
                appendAssistantTurn(message, into: &turns)
            case "tool":
                let id = message.toolCallID ?? "tool"
                let content = message.content ?? ""
                turns.append("Tool result (\(id)): \(content)")
            default:
                if let content = trimmed(message.content) {
                    turns.append("\(message.role): \(content)")
                }
            }
        }

        let instructions = systemParts.joined(separator: "\n\n")
        let prompt = turns.joined(separator: "\n\n")
        return MappedPrompt(
            instructions: instructions,
            prompt: prompt.isEmpty ? "Continue." : prompt
        )
    }

    /// Build an OpenAI tool call from a captured PCC tool invocation.
    static func toolCall(id: String, name: String, arguments: String) -> CPSLOpenAIToolCall {
        CPSLOpenAIToolCall(
            id: id,
            type: "function",
            function: CPSLOpenAIFunctionCall(name: name, arguments: arguments)
        )
    }

    /// Stable JSON object encoding for string-valued tool arguments.
    static func encodeStringFields(_ fields: [String: String]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: fields,
            options: [.sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw CPSLOpenAIError.invalidToolCall
        }
        return json
    }

    /// Completion returned when PCC tools are intercepted for the outer agent loop.
    static func completion(
        text: String,
        toolCalls: [CPSLOpenAIToolCall],
        model: String
    ) -> CPSLOpenAICompletion {
        let finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"
        return CPSLOpenAICompletion(
            text: text,
            toolCalls: toolCalls,
            finishReason: finishReason,
            model: model
        )
    }

    /// Whether the mapped request should attach PCC tools (outer-loop bridge).
    static func shouldAttachTools(_ tools: [CPSLOpenAITool]) -> Bool {
        !tools.isEmpty
    }

    /// Tool names the PCC bridge understands (herm's fixed agent surface).
    static func supportedToolNames(in tools: [CPSLOpenAITool]) -> [String] {
        tools.map(\.function.name).filter { name in
            name == "local_sandbox_exec" || name == "agent"
        }
    }

    private static func appendAssistantTurn(
        _ message: CPSLOpenAIMessage,
        into turns: inout [String]
    ) {
        if let content = trimmed(message.content) {
            turns.append("Assistant: \(content)")
        }
        for toolCall in message.toolCalls ?? [] {
            turns.append(
                "Assistant tool call \(toolCall.function.name) (\(toolCall.id)): \(toolCall.function.arguments)"
            )
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
