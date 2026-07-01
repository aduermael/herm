import Foundation

nonisolated enum CPSLAgentToolFormatting {
    static func source(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.sorted() == ["source"],
              let source = object["source"] as? String,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        return source
    }

    static func toolCallsBody(_ toolCalls: [CPSLOpenAIToolCall]) -> String {
        toolCalls.map { call in
            let source = source(from: call.function.arguments) ?? call.function.arguments
            return "\(call.function.name)\n\n\(source)"
        }
        .joined(separator: "\n\n---\n\n")
    }

    static func providerContent(_ output: CPSLAgentToolOutput) -> String {
        var payload: [String: Any] = [
            "ok": output.ok ?? false,
            "stdout": truncatedText(output.stdout),
            "stderr": truncatedText(output.stderr)
        ]
        if let exitCode = output.exitCode {
            payload["exit_code"] = exitCode
        }
        if let errorCode = output.errorCode {
            payload["error_code"] = errorCode
        }
        if let errorMessage = output.errorMessage {
            payload["error_message"] = errorMessage
        }
        if let ffiError = output.ffiError {
            payload["ffi_error"] = ffiError
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":"Could not encode tool result."}"#
        }
        return json
    }

    static func displayBody(_ output: CPSLAgentToolOutput) -> String {
        var sections: [String] = []
        appendTrimmed(output.stdout, to: &sections)
        appendTrimmed(output.stderr, to: &sections)
        if let errorMessage = output.errorMessage {
            let prefix = output.errorCode.map { "error[\($0)]" } ?? "error"
            sections.append("\(prefix): \(errorMessage)")
        }
        if let ffiError = output.ffiError {
            sections.append(ffiError)
        }
        if sections.isEmpty {
            sections.append(output.exitCode.map { "exit \($0)" } ?? "done")
        }
        return truncatedText(sections.joined(separator: "\n\n"))
    }

    static func truncatedText(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let lineLimited: String
        if lines.count > 80 {
            lineLimited = (Array(lines.prefix(40)) + ["... truncated ..."] + Array(lines.suffix(40))).joined(separator: "\n")
        } else {
            lineLimited = text
        }

        guard lineLimited.utf8.count > 12_288 else {
            return lineLimited
        }

        let prefix = lineLimited.prefix(6_000)
        let suffix = lineLimited.suffix(6_000)
        return "\(prefix)\n... truncated ...\n\(suffix)"
    }

    private static func appendTrimmed(_ text: String, to sections: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else {
            return
        }
        sections.append(trimmed)
    }
}

nonisolated struct CPSLAgentToolOutput: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int?
    let ok: Bool?
    let errorCode: String?
    let errorMessage: String?
    let ffiError: String?
}

nonisolated struct CPSLToolExecutionResult {
    let providerContent: String
    let displayBody: String
    let isError: Bool
}
