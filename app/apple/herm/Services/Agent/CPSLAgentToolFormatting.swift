import Foundation

nonisolated enum CPSLAgentToolFormatting {
    static let localSandboxExecName = "local_sandbox_exec"
    static let agentName = "agent"
    static let defaultStatusSummary = "Checking details"

    static func source(from arguments: String) -> String? {
        sandboxInput(from: arguments)?.source
    }

    static func sandboxInput(from arguments: String) -> CPSLSandboxToolInput? {
        guard let data = arguments.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys).isSubset(of: ["source", "intent"]),
                let source = object["source"] as? String,
                !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let intent = sanitizedStatusSentence(from: object["intent"] as? String)
        return CPSLSandboxToolInput(
            source: source,
            intent: intent
        )
    }

    static func agentInput(from arguments: String) -> CPSLAgentToolInput? {
        guard let data = arguments.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                Set(object.keys).isSubset(of: ["task", "mode"]),
                let task = object["task"] as? String,
                !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let mode = (object["mode"] as? String) ?? CPSLSubAgentMode.explore.rawValue
        guard let subAgentMode = CPSLSubAgentMode(rawValue: mode) else {
            return nil
        }

        return CPSLAgentToolInput(
            task: task.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: subAgentMode
        )
    }

    static func toolCallsBody(_ toolCalls: [CPSLOpenAIToolCall]) -> String {
        toolCalls.map { call in
            let source = source(from: call.function.arguments) ?? call.function.arguments
            return "\(call.function.name)\n\n\(source)"
        }
        .joined(separator: "\n\n---\n\n")
    }

    static func summary(for toolCall: CPSLOpenAIToolCall) -> String {
        switch toolCall.function.name {
        case localSandboxExecName:
            guard let input = sandboxInput(from: toolCall.function.arguments) else {
                return defaultStatusSummary
            }
            return input.intent ?? inferredSandboxIntent(from: input.source)
        case agentName:
            guard let input = agentInput(from: toolCall.function.arguments) else {
                return "Checking with a helper"
            }
            return input.mode == .explore
                ? "Asking a helper to inspect this"
                : "Asking a helper to work on this"
        default:
            return defaultStatusSummary
        }
    }

    static func statusSummary(
        for toolCall: CPSLOpenAIToolCall,
        assistantText: String
    ) -> String {
        let toolSummary = summary(for: toolCall)
        guard toolSummary == defaultStatusSummary else {
            return toolSummary
        }
        return statusSentence(from: assistantText, fallback: defaultStatusSummary)
    }

    static func statusSentence(from assistantText: String, fallback: String = defaultStatusSummary) -> String {
        sanitizedStatusSentence(from: assistantText) ?? fallback
    }

    static func promptPathLiteral(_ path: String) -> String {
        var escaped = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"":
                escaped += "\\\""
            case "\\":
                escaped += "\\\\"
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                if CharacterSet.controlCharacters.contains(scalar) {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.append(String(scalar))
                }
            }
        }
        return "\"\(escaped)\""
    }

    static func inputPreview(for toolCall: CPSLOpenAIToolCall) -> String {
        switch toolCall.function.name {
        case localSandboxExecName:
            return source(from: toolCall.function.arguments) ?? toolCall.function.arguments
        case agentName:
            if let input = agentInput(from: toolCall.function.arguments) {
                return "\(input.mode.rawValue): \(input.task)"
            }
            return toolCall.function.arguments
        default:
            return toolCall.function.arguments
        }
    }

    private static func sanitizedStatusSentence(from text: String?) -> String? {
        guard let text else {
            return nil
        }
        let rawLine = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            line.removeFirst(2)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !line.isEmpty, !looksLikeCodeStatus(line) else {
            return nil
        }
        line = line.replacingOccurrences(of: "`", with: "")
        guard !line.isEmpty, !looksLikeCodeStatus(line) else {
            return nil
        }
        if line.count > 160 {
            line = "\(line.prefix(157))..."
        }
        return line
    }

    private static func inferredSandboxIntent(from source: String) -> String {
        let lower = source.lowercased()
        if lower.contains("fs.tree") || lower.contains("fs.list") {
            return "Exploring files"
        }
        if lower.contains("fs.read") || lower.contains("fs.size") {
            return "Reading files"
        }
        if lower.contains("fs.grep") {
            return "Searching files"
        }
        if lower.contains("fs.write")
            || lower.contains("fs.mkdir")
            || lower.contains("fs.copy")
            || lower.contains("fs.rename")
            || lower.contains("fs.remove") {
            return "Updating files"
        }
        if lower.contains("fs.help") {
            return "Checking file actions"
        }
        if lower.contains("help()") {
            return "Checking available actions"
        }
        return defaultStatusSummary
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

    private static func looksLikeCodeStatus(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("```")
            || lower.contains(localSandboxExecName)
            || lower.contains(agentName)
            || lower.contains("fs.")
            || lower.contains("workdir")
            || lower.contains("sandbox")
            || lower.contains("luau")
            || lower.contains("code")
            || lower.contains("script")
            || lower.contains("tool")
            || lower.contains("help()") {
            return true
        }

        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: #"(?:^|\s)(?:/|~/|\./|\.\./|[A-Za-z]:\\|[\w.-]+/)[^\s]*"#, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: #"\b[\w.-]+\.(?:swift|json|md|txt|lua|luau|go|rs|js|ts|tsx|jsx|py|rb|java|kt|m|mm|h|hpp|c|cc|cpp|yml|yaml|toml|plist|sqlite|db)\b"#, options: .regularExpression) != nil {
            return true
        }

        let codePrefixes = ["local ", "function ", "return ", "print(", "require("]
        if codePrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return true
        }

        let symbolCount = text.reduce(0) { count, character in
            "{}[]=;".contains(character) ? count + 1 : count
        }
        return symbolCount >= 3
    }
}

nonisolated enum CPSLSubAgentMode: String, Codable, Equatable, Sendable {
    case explore
    case general
}

nonisolated struct CPSLAgentToolInput: Equatable, Sendable {
    let task: String
    let mode: CPSLSubAgentMode
}

nonisolated struct CPSLSandboxToolInput: Equatable, Sendable {
    let source: String
    let intent: String?
}

nonisolated enum CPSLToolStatusState: String, Codable, Equatable, Sendable {
    case running
    case succeeded
    case failed
}

nonisolated struct CPSLToolStatusInvocation: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let input: String
    let output: String
    let isError: Bool
}

nonisolated struct CPSLToolStatusPayload: Codable, Equatable, Sendable {
    var state: CPSLToolStatusState
    var summary: String
    var invocations: [CPSLToolStatusInvocation]

    static func running(summary: String = "Preparing tools") -> CPSLToolStatusPayload {
        CPSLToolStatusPayload(state: .running, summary: summary, invocations: [])
    }

    static func decode(from body: String) -> CPSLToolStatusPayload? {
        guard let data = body.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(CPSLToolStatusPayload.self, from: data)
    }

    func encodedBody() -> String {
        guard let data = try? JSONEncoder().encode(self) else {
            return summary
        }
        return String(decoding: data, as: UTF8.self)
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
    let debugInvocation: CPSLToolStatusInvocation
}
