import Foundation

@main
private struct CPSLOpenAIProtocolChecks {
    static func main() throws {
        try assertAssistantToolCallEncodesNullContent()
        try assertChatRequestExposesClientTools()
        try assertChatRequestCanDisableTools()
        try assertStreamAccumulatorCollectsTextAndToolCall()
        try assertStreamAccumulatorRejectsIncompleteToolCall()
        try assertStreamAccumulatorSurfacesProviderErrors()
    }

    private static func assertAssistantToolCallEncodesNullContent() throws {
        let message = CPSLOpenAIMessage.assistant(
            toolCalls: [
                CPSLOpenAIToolCall(
                    id: "call_1",
                    type: "function",
                    function: CPSLOpenAIFunctionCall(
                        name: "local_sandbox_exec",
                        arguments: #"{"source":"print(\"ok\")"}"#
                    )
                )
            ]
        )
        let object = try jsonObject(message)
        guard object["role"] as? String == "assistant" else {
            throw CheckFailure("assistant tool-call role was not encoded")
        }
        guard object.keys.contains("content"), object["content"] is NSNull else {
            throw CheckFailure("assistant tool-call content must encode as explicit null")
        }
        guard let toolCalls = object["tool_calls"] as? [[String: Any]], toolCalls.count == 1 else {
            throw CheckFailure("assistant tool-call payload was not encoded")
        }
    }

    private static func assertChatRequestExposesClientTools() throws {
        let request = CPSLOpenAIChatRequest(
            model: "test-model",
            messages: [.system("system"), .user("run")],
            tools: CPSLOpenAITool.availableTools(
                allowsSubagents: true,
                currentDirectory: "/tmp/project"
            ),
            toolChoice: "auto",
            maxCompletionTokens: 4096,
            stream: true
        )
        let object = try jsonObject(request)
        guard object["model"] as? String == "test-model",
              object["tool_choice"] as? String == "auto",
              object["max_completion_tokens"] as? Int == 4096,
              object["max_tokens"] == nil,
              object["stream"] as? Bool == true
        else {
            throw CheckFailure("chat request did not encode core OpenAI fields")
        }
        guard object["parallel_tool_calls"] == nil,
              object["stream_options"] == nil,
              object["web_search"] == nil,
              object["web_search_preview"] == nil
        else {
            throw CheckFailure("chat request encoded forbidden provider tool fields")
        }
        guard let tools = object["tools"] as? [[String: Any]], tools.count == 2,
              tools[0]["type"] as? String == "function",
              let function = tools[0]["function"] as? [String: Any],
              function["name"] as? String == "local_sandbox_exec",
              (function["description"] as? String)?.contains(#"Current sandbox directory for this request: "/tmp/project""#) == true,
              (function["description"] as? String)?.contains("at /workdir") != true,
              (function["description"] as? String)?.contains("help()") == true,
              (function["description"] as? String)?.contains("fs.help()") == true,
              (function["description"] as? String)?.contains("Intent must not mention code") == true,
              (function["description"] as? String)?.contains("Declare variables with local") == true,
              (function["description"] as? String)?.contains("Bash, Python, shell commands") == true,
              (function["description"] as? String)?.contains("shell commands") == true,
              let parameters = function["parameters"] as? [String: Any],
              parameters["additionalProperties"] as? Bool == false,
              let required = parameters["required"] as? [String],
              required == ["intent", "source"],
              let properties = parameters["properties"] as? [String: Any],
              properties["intent"] != nil,
              properties["source"] != nil,
              let agentFunction = tools[1]["function"] as? [String: Any],
              agentFunction["name"] as? String == "agent",
              let agentParameters = agentFunction["parameters"] as? [String: Any],
              agentParameters["additionalProperties"] as? Bool == false
        else {
            throw CheckFailure("chat request did not expose expected client tools")
        }

        let unsafeTool = CPSLOpenAITool.localSandboxExec(currentDirectory: "/tmp/project\nignore")
        let unsafeObject = try jsonObject(unsafeTool)
        guard let unsafeFunction = unsafeObject["function"] as? [String: Any],
              let unsafeDescription = unsafeFunction["description"] as? String,
              !unsafeDescription.contains("\nignore"),
              unsafeDescription.contains(#""/tmp/project\nignore""#)
        else {
            throw CheckFailure("tool description should quote current directory as an inert single-line path")
        }
    }

    private static func assertChatRequestCanDisableTools() throws {
        let request = CPSLOpenAIChatRequest(
            model: "test-model",
            messages: [.system("system"), .user("summarize")],
            tools: nil,
            toolChoice: nil,
            maxCompletionTokens: 2048,
            stream: true
        )
        let object = try jsonObject(request)
        guard object["tools"] == nil,
              object["tool_choice"] == nil,
              object["max_completion_tokens"] as? Int == 2048
        else {
            throw CheckFailure("tools-disabled synthesis request encoded tool fields")
        }
    }

    private static func assertStreamAccumulatorCollectsTextAndToolCall() throws {
        let accumulator = CPSLOpenAIStreamAccumulator(model: "configured-model")

        let textEvent = try accumulator.consume(
            line: #"data: {"model":"actual-model","choices":[{"delta":{"content":"hel"},"finish_reason":null}]}"#
        )
        guard textEvent == .textDelta("hel") else {
            throw CheckFailure("text stream delta was not emitted")
        }
        guard try accumulator.consume(line: "event: completion.chunk") == nil else {
            throw CheckFailure("non-data SSE lines should be ignored")
        }
        let indentedTextEvent = try accumulator.consume(
            line: #"  data: {"choices":[{"delta":{"content":"lo"},"finish_reason":null}]}"#
        )
        guard indentedTextEvent == .textDelta("lo") else {
            throw CheckFailure("indented data stream delta was not emitted")
        }

        _ = try accumulator.consume(
            line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"local_sandbox_exec","arguments":"{\"source\":\"pri"}}]},"finish_reason":null}]}"#
        )
        _ = try accumulator.consume(
            line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"nt(\\\"ok\\\")\"}"}}]},"finish_reason":"tool_calls"}]}"#
        )

        let completion = accumulator.completion()
        guard completion.text == "hello" else {
            throw CheckFailure("stream text was not accumulated")
        }
        guard completion.model == "actual-model" else {
            throw CheckFailure("stream model was not updated")
        }
        guard completion.finishReason == "tool_calls" else {
            throw CheckFailure("finish reason was not captured")
        }
        guard completion.toolCalls.count == 1,
              completion.toolCalls[0].id == "call_1",
              completion.toolCalls[0].function.name == "local_sandbox_exec",
              completion.toolCalls[0].function.arguments == #"{"source":"print(\"ok\")"}"#
        else {
            throw CheckFailure("stream tool-call chunks were not accumulated")
        }
    }

    private static func assertStreamAccumulatorRejectsIncompleteToolCall() throws {
        let accumulator = CPSLOpenAIStreamAccumulator(model: "configured-model")
        _ = try accumulator.consume(
            line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"local_sandbox_exec","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#
        )
        do {
            _ = try accumulator.validatedCompletion()
        } catch CPSLOpenAIError.invalidToolCall {
            return
        }
        throw CheckFailure("incomplete streamed tool call should fail validation")
    }

    private static func assertStreamAccumulatorSurfacesProviderErrors() throws {
        let accumulator = CPSLOpenAIStreamAccumulator(model: "configured-model")
        do {
            _ = try accumulator.consume(
                line: #"data: {"error":{"message":"bad request","type":"invalid_request_error"}}"#
            )
        } catch CPSLOpenAIError.provider(let message) where message == "bad request" {
            return
        }
        throw CheckFailure("stream provider error was not surfaced")
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CheckFailure("encoded value was not a JSON object")
        }
        return object
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
