import Foundation

nonisolated enum CPSLEnvConstants {
    static let values: [String: String] = [:]
}

@main
private struct CPSLAgentPCCChecks {
    static func main() throws {
        try assertSelectsPCCWhenAvailableOnOS27()
        try assertFallsBackWhenPCCUnavailable()
        try assertFallsBackPreOS27()
        try assertFallsBackOffApplePlatform()
        try assertModelIDForKinds()
        try assertMapsSystemAndUserToPrompt()
        try assertMapsToolCallRoundTripIntoPrompt()
        try assertBuildsToolCallCompletion()
        try assertEncodesToolArgumentsJSON()
        try assertSupportedToolNames()
        try assertForcedOpenAIKindDoesNotSelectPCC()
        print("vet-apple-agent-pcc: ok")
    }

    private static func assertSelectsPCCWhenAvailableOnOS27() throws {
        let kind = CPSLAgentProviderSelection.select(
            CPSLAgentProviderSelectionInput(
                isApplePlatform: true,
                isOS27OrNewer: true,
                isPCCAvailable: true
            )
        )
        guard kind == .applePCC else {
            throw CheckFailure("expected applePCC when OS 27+ and PCC available")
        }
    }

    private static func assertFallsBackWhenPCCUnavailable() throws {
        let kind = CPSLAgentProviderSelection.select(
            CPSLAgentProviderSelectionInput(
                isApplePlatform: true,
                isOS27OrNewer: true,
                isPCCAvailable: false
            )
        )
        guard kind == .openAI else {
            throw CheckFailure("expected openAI fallback when PCC unavailable")
        }
    }

    private static func assertFallsBackPreOS27() throws {
        let kind = CPSLAgentProviderSelection.select(
            CPSLAgentProviderSelectionInput(
                isApplePlatform: true,
                isOS27OrNewer: false,
                isPCCAvailable: true
            )
        )
        guard kind == .openAI else {
            throw CheckFailure("expected openAI fallback before OS 27")
        }
    }

    private static func assertFallsBackOffApplePlatform() throws {
        let kind = CPSLAgentProviderSelection.select(
            CPSLAgentProviderSelectionInput(
                isApplePlatform: false,
                isOS27OrNewer: true,
                isPCCAvailable: true
            )
        )
        guard kind == .openAI else {
            throw CheckFailure("expected openAI when not on Apple platforms")
        }
    }

    private static func assertModelIDForKinds() throws {
        let pcc = CPSLAgentProviderSelection.modelID(kind: .applePCC, openAIModel: "grok-4.5")
        let openAI = CPSLAgentProviderSelection.modelID(kind: .openAI, openAIModel: "grok-4.5")
        guard pcc == CPSLAgentProviderSelection.pccModelID else {
            throw CheckFailure("PCC model id should be apple/pcc, got \(pcc)")
        }
        guard openAI == "grok-4.5" else {
            throw CheckFailure("OpenAI model id should pass through, got \(openAI)")
        }
    }

    private static func assertMapsSystemAndUserToPrompt() throws {
        let mapped = CPSLPCCMessageMapper.mapPrompt(messages: [
            .system("You are herm."),
            .user("List files")
        ])
        guard mapped.instructions == "You are herm." else {
            throw CheckFailure("system message should become instructions")
        }
        guard mapped.prompt == "User: List files" else {
            throw CheckFailure("user message should become prompt, got \(mapped.prompt)")
        }
    }

    /// Proves multi-message + tools history maps so a tool-result follow-up can
    /// yield assistant text — using the shipped mapper, not a re-implementation.
    private static func assertMapsToolCallRoundTripIntoPrompt() throws {
        let toolCall = CPSLPCCMessageMapper.toolCall(
            id: "pcc_call_1",
            name: "local_sandbox_exec",
            arguments: #"{"intent":"Exploring files","source":"print(fs.list(\"/\"))"}"#
        )
        let completion = CPSLPCCMessageMapper.completion(
            text: "",
            toolCalls: [toolCall],
            model: CPSLAgentProviderSelection.pccModelID
        )
        guard completion.finishReason == "tool_calls",
              completion.toolCalls.count == 1,
              completion.toolCalls[0].function.name == "local_sandbox_exec",
              completion.model == "apple/pcc"
        else {
            throw CheckFailure("tool-call completion shape was wrong: \(completion)")
        }

        let followUp = CPSLPCCMessageMapper.mapPrompt(messages: [
            .system("You are herm."),
            .user("List the top-level directory."),
            .assistant(content: nil, toolCalls: completion.toolCalls),
            .tool(id: toolCall.id, content: #"{"ok":true,"output":"home\ntmp"}"#)
        ])
        guard followUp.instructions.contains("You are herm.") else {
            throw CheckFailure("follow-up should keep system instructions")
        }
        guard followUp.prompt.contains("Assistant tool call local_sandbox_exec") else {
            throw CheckFailure("follow-up prompt missing tool call history: \(followUp.prompt)")
        }
        guard followUp.prompt.contains("Tool result (pcc_call_1)") else {
            throw CheckFailure("follow-up prompt missing tool result: \(followUp.prompt)")
        }
        guard followUp.prompt.contains(#"{"ok":true,"output":"home\ntmp"}"#) else {
            throw CheckFailure("follow-up prompt missing tool result body: \(followUp.prompt)")
        }

        let finalCompletion = CPSLPCCMessageMapper.completion(
            text: "Top-level entries: home, tmp.",
            toolCalls: [],
            model: CPSLAgentProviderSelection.pccModelID
        )
        guard finalCompletion.finishReason == "stop",
              finalCompletion.toolCalls.isEmpty,
              finalCompletion.text.contains("home")
        else {
            throw CheckFailure("final assistant completion was wrong: \(finalCompletion)")
        }
    }

    private static func assertBuildsToolCallCompletion() throws {
        let call = CPSLPCCMessageMapper.toolCall(
            id: "pcc_call_2",
            name: "agent",
            arguments: #"{"intent":"Research","task":"Find X","mode":"explore"}"#
        )
        let completion = CPSLPCCMessageMapper.completion(
            text: "Working",
            toolCalls: [call],
            model: "apple/pcc"
        )
        guard completion.toolCalls[0].type == "function",
              completion.toolCalls[0].function.name == "agent",
              completion.text == "Working"
        else {
            throw CheckFailure("agent tool-call completion malformed")
        }
    }

    private static func assertEncodesToolArgumentsJSON() throws {
        let json = try CPSLPCCMessageMapper.encodeStringFields([
            "source": "print(1)",
            "intent": "Checking results"
        ])
        guard json.contains("\"intent\":\"Checking results\""),
              json.contains("\"source\":\"print(1)\"")
        else {
            throw CheckFailure("encodeStringFields missing fields: \(json)")
        }
        // sortedKeys → intent before source
        guard json == #"{"intent":"Checking results","source":"print(1)"}"# else {
            throw CheckFailure("encodeStringFields unstable JSON: \(json)")
        }
    }

    private static func assertSupportedToolNames() throws {
        let tools = CPSLOpenAITool.availableTools(
            allowsSubagents: true,
            currentDirectory: "/home/herm"
        )
        let names = CPSLPCCMessageMapper.supportedToolNames(in: tools)
        guard names == ["local_sandbox_exec", "agent"] else {
            throw CheckFailure("supported tool names = \(names)")
        }
        guard CPSLPCCMessageMapper.shouldAttachTools(tools) else {
            throw CheckFailure("non-empty tools should attach")
        }
        guard !CPSLPCCMessageMapper.shouldAttachTools([]) else {
            throw CheckFailure("empty tools should not attach")
        }
    }

    private static func assertForcedOpenAIKindDoesNotSelectPCC() throws {
        // Mirrors CPSLAgentChatClient(config:kind: .openAI) construction path.
        let kind = CPSLAgentProviderKind.openAI
        let model = CPSLAgentProviderSelection.modelID(kind: kind, openAIModel: "grok-4.5")
        guard kind == .openAI, model == "grok-4.5" else {
            throw CheckFailure("forced openAI kind must keep Grok model id")
        }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
