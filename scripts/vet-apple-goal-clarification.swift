import Foundation

// Minimal host types so this vet compiles without SwiftUI (CPSLTypes.swift).
nonisolated enum CPSLVirtualPath {
    static let attachments = "/attachments"
}

nonisolated struct CPSLAttachment: Equatable, Sendable {
    let name: String
    let path: String
}

@main
private struct CPSLGoalClarificationChecks {
    static func main() throws {
        try assertCompletionContractDomainAgnostic()
        try assertNormalizeAndFailOpen()
        try assertDisplayVsProviderSplit()
        try assertProviderTextKeepsAttachments()
        try assertShippedChatModelWiresHelpers()
        try assertWriteBeforeClarifyOrder()
        print("vet-apple-goal-clarification: ok")
    }

    private static func assertCompletionContractDomainAgnostic() throws {
        let contract = CPSLGoalClarification.mainAgentCompletionContract
        guard CPSLGoalClarification.systemPromptContainsCompletionContract(contract) else {
            throw CheckFailure("completion contract missing carry-through / handoff / skills guidance")
        }
        let lower = contract.lowercased()
        for banned in ["barber", "restaurant nearby", "for nearby places:"] {
            guard !lower.contains(banned) else {
                throw CheckFailure("completion contract must not hard-code task types (\(banned))")
            }
        }
    }

    private static func assertNormalizeAndFailOpen() throws {
        guard CPSLGoalClarification.normalizedClarifiedGoal(
            "  \n",
            originalDisplayText: "hello"
        ) == nil else {
            throw CheckFailure("empty clarify output should fail open")
        }
        guard CPSLGoalClarification.normalizedClarifiedGoal(
            "hello",
            originalDisplayText: "Hello"
        ) == nil else {
            throw CheckFailure("echo of original should fail open")
        }
        let goal = CPSLGoalClarification.normalizedClarifiedGoal(
            "```\nDeliver a finished answer in the reply.\n```",
            originalDisplayText: "do it"
        )
        guard goal == "Deliver a finished answer in the reply." else {
            throw CheckFailure("fenced clarify output was not normalized: \(goal ?? "nil")")
        }
        guard CPSLGoalClarification.shouldClarify(displayText: "  ") == false else {
            throw CheckFailure("blank display text should skip clarify")
        }
        guard CPSLGoalClarification.shouldClarify(displayText: "Go") else {
            throw CheckFailure("non-empty display text should allow clarify")
        }
    }

    private static func assertDisplayVsProviderSplit() throws {
        let original = "Please handle this request"
        let prompt = CPSLAttachmentPrompt(displayText: original, attachments: [])
        let clarified = "Return the finished result in the assistant reply."
        let next = prompt.embeddingClarifiedGoal(clarified)
        guard next.displayText == original else {
            throw CheckFailure("display text must stay the user's original message")
        }
        guard next.providerText.contains(original),
              next.providerText.contains(CPSLGoalClarification.endGoalHeading),
              next.providerText.contains(clarified)
        else {
            throw CheckFailure("provider text must embed original + end goal")
        }
        let failed = CPSLGoalClarification.applyingClarifiedGoal(nil, to: prompt)
        guard failed.providerText == original, failed.displayText == original else {
            throw CheckFailure("fail-open must leave display and provider as original")
        }
    }

    private static func assertProviderTextKeepsAttachments() throws {
        let path = "\(CPSLVirtualPath.attachments)/conv/note.txt"
        let prompt = CPSLAttachmentPrompt(
            displayText: "Review this",
            attachments: [CPSLAttachment(name: "note.txt", path: path)]
        )
        let goal = "Provide a finished review in the reply."
        let next = prompt.embeddingClarifiedGoal(goal)
        guard next.displayText == "Review this" else {
            throw CheckFailure("attachment prompt display text changed")
        }
        guard let goalRange = next.providerText.range(of: goal),
              let attachRange = next.providerText.range(of: CPSLAttachmentPrompt.attachedFilesHeading),
              goalRange.lowerBound < attachRange.lowerBound
        else {
            throw CheckFailure("end goal must appear before attached files section")
        }
        let parsed = CPSLAttachmentPrompt.parse(next.providerText)
        guard parsed.attachments.map(\.path) == [path] else {
            throw CheckFailure("attachment parse lost paths after end-goal embed")
        }
    }

    private static func assertShippedChatModelWiresHelpers() throws {
        let source = try loadChatModelSource()
        for needle in [
            "CPSLGoalClarification.mainAgentCompletionContract",
            "clarifyingUserPrompt",
            "clarifyEndGoal",
            "updateNodeProviderMessage"
        ] {
            guard source.contains(needle) else {
                throw CheckFailure("CPSLChatModel.swift must wire \(needle)")
            }
        }
        for banned in ["for nearby places:", "barber shop options", "restaurant nearby"] {
            guard !source.contains(banned) else {
                throw CheckFailure("ChatModel must not hard-code task category \(banned)")
            }
        }
    }

    private static func assertWriteBeforeClarifyOrder() throws {
        let source = try loadChatModelSource()
        guard CPSLGoalClarification.runAgentSourcePersistsUserBeforeClarify(source) else {
            throw CheckFailure(
                "runAgent must persist user turn (prompt.displayText) before clarifyingUserPrompt, then updateNodeProviderMessage"
            )
        }
        // Config load must not gate the user write.
        guard let createRange = source.range(of: "createConversation("),
              let configRange = source.range(of: "CPSLAgentConfig.load()"),
              createRange.lowerBound < configRange.lowerBound
        else {
            throw CheckFailure("createConversation must run before CPSLAgentConfig.load()")
        }
        guard CPSLGoalClarification.submitPhaseOrder.first == .persistUserTurn,
              CPSLGoalClarification.submitPhaseOrder.contains(.clarifyEndGoal)
        else {
            throw CheckFailure("submit phase order must start with persistUserTurn")
        }
    }

    private static func loadChatModelSource() throws -> String {
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let url = cwd.appendingPathComponent("app/apple/herm/Models/CPSLChatModel.swift")
        guard fileManager.fileExists(atPath: url.path) else {
            throw CheckFailure("could not find CPSLChatModel.swift from \(cwd.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
