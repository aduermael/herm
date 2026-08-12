import Foundation

nonisolated enum CPSLOpenAIError: LocalizedError {
    case httpStatus(Int, String)
    case invalidStreamData
    case invalidToolCall
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "Provider request failed with HTTP \(status)."
            }
            return "Provider request failed with HTTP \(status): \(trimmed)"
        case .invalidStreamData:
            return "Provider returned an invalid streaming response."
        case .invalidToolCall:
            return "Provider returned an incomplete tool call."
        case .provider(let message):
            return message
        }
    }
}

nonisolated struct CPSLOpenAIMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String?
    var toolCalls: [CPSLOpenAIToolCall]?
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    init(
        role: String,
        content: String? = nil,
        toolCalls: [CPSLOpenAIToolCall]? = nil,
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    static func system(_ content: String) -> CPSLOpenAIMessage {
        CPSLOpenAIMessage(role: "system", content: content)
    }

    static func user(_ content: String) -> CPSLOpenAIMessage {
        CPSLOpenAIMessage(role: "user", content: content)
    }

    static func assistant(_ content: String) -> CPSLOpenAIMessage {
        CPSLOpenAIMessage(role: "assistant", content: content)
    }

    static func assistant(toolCalls: [CPSLOpenAIToolCall]) -> CPSLOpenAIMessage {
        CPSLOpenAIMessage(role: "assistant", content: nil, toolCalls: toolCalls)
    }

    static func assistant(content: String?, toolCalls: [CPSLOpenAIToolCall]) -> CPSLOpenAIMessage {
        CPSLOpenAIMessage(role: "assistant", content: content, toolCalls: toolCalls)
    }

    static func tool(id: String, content: String) -> CPSLOpenAIMessage {
        CPSLOpenAIMessage(role: "tool", content: content, toolCallID: id)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        if let content {
            try container.encode(content, forKey: .content)
        } else if role == "assistant", toolCalls?.isEmpty == false {
            try container.encodeNil(forKey: .content)
        }

        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
    }
}

nonisolated struct CPSLOpenAIToolCall: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let function: CPSLOpenAIFunctionCall
}

nonisolated struct CPSLOpenAIFunctionCall: Codable, Equatable, Sendable {
    let name: String
    let arguments: String
}

nonisolated struct CPSLOpenAICompletion: Equatable, Sendable {
    var text: String
    var toolCalls: [CPSLOpenAIToolCall]
    var finishReason: String?
    var model: String
}

nonisolated enum CPSLOpenAIStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case toolCallDelta
}

nonisolated struct CPSLOpenAIChatRequest: Encodable, Sendable {
    let model: String
    let messages: [CPSLOpenAIMessage]
    let tools: [CPSLOpenAITool]?
    let toolChoice: String?
    let maxCompletionTokens: Int?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case toolChoice = "tool_choice"
        case maxCompletionTokens = "max_completion_tokens"
        case stream
    }
}

nonisolated struct CPSLOpenAITool: Codable, Sendable {
    let type: String
    let function: CPSLOpenAIToolFunction

    static func localSandboxExec(currentDirectory: String) -> CPSLOpenAITool {
        let directory = CPSLAgentToolFormatting.promptPathLiteral(
            normalizedToolDirectory(currentDirectory)
        )
        return CPSLOpenAITool(
            type: "function",
            function: CPSLOpenAIToolFunction(
                name: "local_sandbox_exec",
                description: "Execute Luau source in a Unix-like local sandbox with a filesystem, current directory, and command-style capabilities exposed through Luau APIs. Current directory for this request: \(directory). Relative paths resolve from that directory. Use /home/herm for durable user-created files, /tmp for temporary files, and the user-provided paths under /attachments when present; other Unix-style directories under / remain available when the task calls for them. Luau is the command interface instead of Bash and the only supported execution language. Include intent: a short high-level user-facing action phrase like Exploring files, Reading settings, or Checking results. Intent must not mention code, sandbox details, paths, tool names, or implementation details. Never guess API signatures: call help() and each module's help function, such as fs.help(), before using APIs. Declare variables with local; Luau uses 1-based indexing, .. string concatenation, ~= not-equal, and pcall(fn) for recoverable errors. Do not try to launch external lua/luau interpreters, Bash, Python, shell commands, package managers, background services, host Lua APIs, or files outside the sandbox virtual filesystem.",
                parameters: CPSLOpenAIToolParameters(
                    type: "object",
                    properties: [
                        "intent": CPSLOpenAIToolParameter(
                            type: "string",
                            description: "Short high-level status phrase shown to the user, such as Exploring files or Checking results. Do not mention code, sandbox details, paths, tool names, or implementation details."
                        ),
                        "source": CPSLOpenAIToolParameter(
                            type: "string",
                            description: "Luau source to execute directly in the sandbox. Relative paths resolve from the current directory in the tool description."
                        )
                    ],
                    required: ["intent", "source"],
                    additionalProperties: false
                )
            )
        )
    }

    static let agent = CPSLOpenAITool(
        type: "function",
        function: CPSLOpenAIToolFunction(
            name: "agent",
            description: "Spawn a focused sub-agent with its own turn budget. Include intent: a short user-facing description of the expected work, without mentioning helpers, agents, tools, code, paths, or implementation details. Use mode explore for research and reading. Use mode general for sandbox execution cycles or implementation-style work. Sub-agents return a concise result to this conversation and cannot access host shell tools.",
            parameters: CPSLOpenAIToolParameters(
                type: "object",
                properties: [
                    "intent": CPSLOpenAIToolParameter(
                        type: "string",
                        description: "Short user-facing action phrase shown as status, such as Comparing venue options or Verifying document details. Do not mention helpers, agents, tools, code, paths, or implementation details."
                    ),
                    "task": CPSLOpenAIToolParameter(
                        type: "string",
                        description: "A clear, self-contained task for the sub-agent."
                    ),
                    "mode": CPSLOpenAIToolParameter(
                        type: "string",
                        description: "Either explore or general. Explore is for research; general is for execution-heavy work."
                    )
                ],
                required: ["intent", "task", "mode"],
                additionalProperties: false
            )
        )
    )

    static func availableTools(allowsSubagents: Bool, currentDirectory: String) -> [CPSLOpenAITool] {
        let localSandboxExec = localSandboxExec(currentDirectory: currentDirectory)
        return allowsSubagents ? [localSandboxExec, .agent] : [localSandboxExec]
    }

    private static func normalizedToolDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }
}

nonisolated struct CPSLOpenAIToolFunction: Codable, Sendable {
    let name: String
    let description: String
    let parameters: CPSLOpenAIToolParameters
}

nonisolated struct CPSLOpenAIToolParameters: Codable, Sendable {
    let type: String
    let properties: [String: CPSLOpenAIToolParameter]
    let required: [String]
    let additionalProperties: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
        case additionalProperties = "additionalProperties"
    }
}

nonisolated struct CPSLOpenAIToolParameter: Codable, Sendable {
    let type: String
    let description: String
}

nonisolated final class CPSLOpenAIStreamAccumulator {
    private var text = ""
    private var finishReason: String?
    private var model: String
    private var toolCallBuilders: [Int: CPSLOpenAIToolCallBuilder] = [:]

    init(model: String) {
        self.model = model
    }

    func consume(line: String) throws -> CPSLOpenAIStreamEvent? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLine.hasPrefix("data:") else {
            return nil
        }

        let payload = trimmedLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else {
            return nil
        }
        guard let data = payload.data(using: .utf8) else {
            throw CPSLOpenAIError.invalidStreamData
        }

        let decoder = JSONDecoder()
        let chunk: CPSLOpenAIChatChunk
        do {
            chunk = try decoder.decode(CPSLOpenAIChatChunk.self, from: data)
        } catch {
            if let envelope = try? decoder.decode(CPSLOpenAIErrorEnvelope.self, from: data),
                    let message = envelope.error.message?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !message.isEmpty {
                throw CPSLOpenAIError.provider(message)
            }
            throw CPSLOpenAIError.invalidStreamData
        }
        if let chunkModel = chunk.model, !chunkModel.isEmpty {
            model = chunkModel
        }

        var emittedToolDelta = false
        var emittedText = ""
        for choice in chunk.choices {
            if let reason = choice.finishReason {
                finishReason = reason
            }
            if let deltaText = choice.delta.content, !deltaText.isEmpty {
                text += deltaText
                emittedText += deltaText
            }
            for toolCall in choice.delta.toolCalls ?? [] {
                let index = toolCall.index ?? 0
                var builder = toolCallBuilders[index] ?? CPSLOpenAIToolCallBuilder()
                builder.apply(toolCall)
                toolCallBuilders[index] = builder
                emittedToolDelta = true
            }
        }

        if !emittedText.isEmpty {
            return .textDelta(emittedText)
        }
        return emittedToolDelta ? .toolCallDelta : nil
    }

    func completion() -> CPSLOpenAICompletion {
        let calls = (try? toolCalls()) ?? []
        return CPSLOpenAICompletion(
            text: text,
            toolCalls: calls,
            finishReason: finishReason,
            model: model
        )
    }

    func validatedCompletion() throws -> CPSLOpenAICompletion {
        CPSLOpenAICompletion(
            text: text,
            toolCalls: try toolCalls(),
            finishReason: finishReason,
            model: model
        )
    }

    private func toolCalls() throws -> [CPSLOpenAIToolCall] {
        try toolCallBuilders
            .sorted { $0.key < $1.key }
            .map { _, builder in
                guard let toolCall = builder.toolCall() else {
                    throw CPSLOpenAIError.invalidToolCall
                }
                return toolCall
            }
    }
}

private nonisolated struct CPSLOpenAIToolCallBuilder {
    var id = ""
    var type = "function"
    var name = ""
    var arguments = ""

    mutating func apply(_ delta: CPSLOpenAIResponseToolCall) {
        if let deltaID = delta.id {
            id = deltaID
        }
        if let deltaType = delta.type {
            type = deltaType
        }
        if let functionName = delta.function?.name {
            name += functionName
        }
        if let functionArguments = delta.function?.arguments {
            arguments += functionArguments
        }
    }

    func toolCall() -> CPSLOpenAIToolCall? {
        guard !id.isEmpty, !name.isEmpty else {
            return nil
        }
        return CPSLOpenAIToolCall(
            id: id,
            type: type,
            function: CPSLOpenAIFunctionCall(name: name, arguments: arguments)
        )
    }
}

private nonisolated struct CPSLOpenAIChatChunk: Decodable {
    let model: String?
    let choices: [CPSLOpenAIChoice]
}

private nonisolated struct CPSLOpenAIChoice: Decodable {
    let delta: CPSLOpenAIResponseMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

private nonisolated struct CPSLOpenAIResponseMessage: Decodable {
    let content: String?
    let toolCalls: [CPSLOpenAIResponseToolCall]?

    enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
    }
}

private nonisolated struct CPSLOpenAIResponseToolCall: Decodable {
    let index: Int?
    let id: String?
    let type: String?
    let function: CPSLOpenAIResponseFunction?
}

private nonisolated struct CPSLOpenAIResponseFunction: Decodable {
    let name: String?
    let arguments: String?
}

private nonisolated struct CPSLOpenAIErrorEnvelope: Decodable {
    let error: CPSLOpenAIResponseError
}

private nonisolated struct CPSLOpenAIResponseError: Decodable {
    let message: String?
}
