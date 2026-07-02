import Foundation

@main
private struct CPSLAgentToolFormattingChecks {
    static func main() throws {
        try assertToolArgumentsAndDisplayBody()
        try assertAgentToolArguments()
        try assertProviderContentJSON()
        try assertTruncation()
    }

    private static func assertToolArgumentsAndDisplayBody() throws {
        let toolCall = CPSLOpenAIToolCall(
            id: "call_1",
            type: "function",
            function: CPSLOpenAIFunctionCall(
                name: "local_sandbox_exec",
                arguments: #"{"intent":"Checking results","source":"print(\"ok\")"}"#
            )
        )

        guard CPSLAgentToolFormatting.source(from: toolCall.function.arguments) == #"print("ok")"# else {
            throw CheckFailure("tool source was not decoded from JSON arguments")
        }
        guard CPSLAgentToolFormatting.source(from: "{not-json") == nil else {
            throw CheckFailure("invalid JSON tool arguments should not decode")
        }
        guard CPSLAgentToolFormatting.source(from: #"{"source":"print(\"ok\")","path":"/workdir/file"}"#) == nil else {
            throw CheckFailure("tool arguments with unknown fields should not decode")
        }
        guard CPSLAgentToolFormatting.source(from: #"{"source":"   \n"}"#) == nil else {
            throw CheckFailure("blank tool source should not decode")
        }

        let body = CPSLAgentToolFormatting.toolCallsBody([toolCall])
        guard body == "local_sandbox_exec\n\nprint(\"ok\")" else {
            throw CheckFailure("tool call display body was unexpected: \(body)")
        }
        guard CPSLAgentToolFormatting.summary(for: toolCall) == "Checking results" else {
            throw CheckFailure("tool status summary should use the high-level intent")
        }
        let listToolCall = CPSLOpenAIToolCall(
            id: "call_2",
            type: "function",
            function: CPSLOpenAIFunctionCall(
                name: "local_sandbox_exec",
                arguments: #"{"source":"print(fs.list(\"/workdir\"))"}"#
            )
        )
        guard CPSLAgentToolFormatting.summary(for: listToolCall) == "Exploring files" else {
            throw CheckFailure("tool status fallback should infer a high-level file intent")
        }
        guard CPSLAgentToolFormatting.statusSentence(
            from: "I will inspect the relevant files",
            fallback: "Fallback"
        ) == "I will inspect the relevant files" else {
            throw CheckFailure("plain-language status sentence was not normalized")
        }
        guard CPSLAgentToolFormatting.statusSentence(
            from: "local result = fs.read('/workdir/file')",
            fallback: "Fallback"
        ) == "Fallback" else {
            throw CheckFailure("code-like status sentence should be replaced")
        }
        guard CPSLAgentToolFormatting.statusSentence(
            from: "```luau\nprint(\"ok\")\n```",
            fallback: "Fallback"
        ) == "Fallback" else {
            throw CheckFailure("fenced code status sentence should be replaced")
        }
        guard CPSLAgentToolFormatting.statusSentence(
            from: "Calling `agent` to inspect the files",
            fallback: "Fallback"
        ) == "Fallback" else {
            throw CheckFailure("tool-name status sentence should be replaced")
        }
        guard CPSLAgentToolFormatting.statusSentence(
            from: "Reading app/apple/herm/Models/CPSLChatModel.swift",
            fallback: "Fallback"
        ) == "Fallback" else {
            throw CheckFailure("path-like status sentence should be replaced")
        }
        guard CPSLAgentToolFormatting.statusSentence(
            from: "Checking Package.swift",
            fallback: "Fallback"
        ) == "Fallback" else {
            throw CheckFailure("file-name status sentence should be replaced")
        }

        let display = CPSLAgentToolFormatting.displayBody(
            CPSLAgentToolOutput(
                stdout: " out\n",
                stderr: " err\n",
                exitCode: 1,
                ok: false,
                errorCode: "runtime_error",
                errorMessage: "failed",
                ffiError: "ffi failed"
            )
        )
        guard display.contains(" out"),
              display.contains(" err"),
              display.contains("error[runtime_error]: failed"),
              display.contains("ffi failed")
        else {
            throw CheckFailure("tool display body omitted result sections")
        }
    }

    private static func assertAgentToolArguments() throws {
        guard let input = CPSLAgentToolFormatting.agentInput(
            from: #"{"task":"Read the storage code","mode":"explore"}"#
        ),
              input.task == "Read the storage code",
              input.mode == .explore
        else {
            throw CheckFailure("agent tool input was not decoded")
        }
        guard CPSLAgentToolFormatting.agentInput(from: #"{"task":"x","mode":"invalid"}"#) == nil else {
            throw CheckFailure("invalid agent mode should not decode")
        }
        guard CPSLAgentToolFormatting.agentInput(from: #"{"task":"x","mode":"explore","extra":true}"#) == nil else {
            throw CheckFailure("agent tool arguments with unknown fields should not decode")
        }
    }

    private static func assertProviderContentJSON() throws {
        let content = CPSLAgentToolFormatting.providerContent(
            CPSLAgentToolOutput(
                stdout: "ok\n",
                stderr: "",
                exitCode: 0,
                ok: true,
                errorCode: nil,
                errorMessage: nil,
                ffiError: nil
            )
        )
        let data = Data(content.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["ok"] as? Bool == true,
              object["stdout"] as? String == "ok\n",
              object["stderr"] as? String == "",
              object["exit_code"] as? Int == 0
        else {
            throw CheckFailure("provider tool content was not valid result JSON")
        }

        let ffiContent = CPSLAgentToolFormatting.providerContent(
            CPSLAgentToolOutput(
                stdout: "",
                stderr: "",
                exitCode: nil,
                ok: nil,
                errorCode: nil,
                errorMessage: nil,
                ffiError: "cpsl_eval returned NULL"
            )
        )
        let ffiData = Data(ffiContent.utf8)
        guard let ffiObject = try JSONSerialization.jsonObject(with: ffiData) as? [String: Any],
              ffiObject["ok"] as? Bool == false,
              ffiObject["ffi_error"] as? String == "cpsl_eval returned NULL"
        else {
            throw CheckFailure("provider tool content should include FFI errors")
        }
    }

    private static func assertTruncation() throws {
        let lines = (0..<100).map { "line-\($0)" }.joined(separator: "\n")
        let truncatedLines = CPSLAgentToolFormatting.truncatedText(lines)
        guard truncatedLines.contains("line-0"),
              truncatedLines.contains("line-99"),
              truncatedLines.contains("... truncated ..."),
              !truncatedLines.contains("line-50")
        else {
            throw CheckFailure("line truncation did not keep head and tail")
        }

        let longText = String(repeating: "x", count: 14_000)
        let truncatedBytes = CPSLAgentToolFormatting.truncatedText(longText)
        guard truncatedBytes.utf8.count < longText.utf8.count,
              truncatedBytes.contains("... truncated ...")
        else {
            throw CheckFailure("byte truncation did not shorten large output")
        }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
