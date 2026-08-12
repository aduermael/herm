import Testing
@testable import herm

struct CPSLGoalClarificationTests {
    @Test func completionContractIsDomainAgnosticAndCompleteThroughEnd() {
        let contract = CPSLGoalClarification.mainAgentCompletionContract
        #expect(CPSLGoalClarification.systemPromptContainsCompletionContract(contract))
        #expect(contract.localizedCaseInsensitiveContains("finished result"))
        #expect(contract.localizedCaseInsensitiveContains("skills"))
        #expect(!contract.localizedCaseInsensitiveContains("barber"))
        #expect(!contract.localizedCaseInsensitiveContains("restaurant"))
        #expect(!contract.localizedCaseInsensitiveContains("nearby places"))
    }

    @Test func mainSystemPromptSourceIncludesCompletionContract() throws {
        // The shipped ChatModel source must embed the generic contract constant.
        let source = try SystemPromptSource.chatModelSource()
        #expect(source.contains("CPSLGoalClarification.mainAgentCompletionContract"))
        #expect(source.contains("clarifyingUserPrompt"))
        #expect(CPSLGoalClarification.systemPromptContainsCompletionContract(
            CPSLGoalClarification.mainAgentCompletionContract
        ))
        // No category-specific cookbooks introduced for this feature.
        #expect(!source.contains("for nearby places:"))
        #expect(!source.contains("barber shop options"))
        #expect(!source.contains("restaurant nearby"))
    }

    @Test func displayTextUnchangedWhenEmbeddingClarifiedGoal() {
        let original = "Can you find a barber shop nearby?"
        let prompt = CPSLAttachmentPrompt(displayText: original, attachments: [])
        let clarified = "Deliver a finished list of options the user can act on from the chat reply."
        let next = prompt.embeddingClarifiedGoal(clarified)

        #expect(next.displayText == original)
        #expect(next.providerText.contains(original))
        #expect(next.providerText.contains(CPSLGoalClarification.endGoalHeading))
        #expect(next.providerText.contains(clarified))
        #expect(next.providerText != original)
    }

    @Test func failOpenLeavesProviderTextUnchanged() {
        let original = "Summarize the open document"
        let prompt = CPSLAttachmentPrompt(displayText: original, attachments: [])
        #expect(prompt.embeddingClarifiedGoal(nil).providerText == original)
        #expect(prompt.embeddingClarifiedGoal("   ").providerText == original)
        let echo = CPSLGoalClarification.normalizedClarifiedGoal(
            original,
            originalDisplayText: original
        )
        #expect(echo == nil)
        #expect(
            CPSLGoalClarification.applyingClarifiedGoal(echo, to: prompt).providerText == original
        )
    }

    @Test func normalizeRejectsEmptyAndEchoes() {
        #expect(
            CPSLGoalClarification.normalizedClarifiedGoal(
                "  \n",
                originalDisplayText: "hello"
            ) == nil
        )
        #expect(
            CPSLGoalClarification.normalizedClarifiedGoal(
                "hello",
                originalDisplayText: "Hello"
            ) == nil
        )
        #expect(
            CPSLGoalClarification.normalizedClarifiedGoal(
                "Deliver the finished answer in chat.",
                originalDisplayText: "hello"
            ) == "Deliver the finished answer in chat."
        )
        #expect(
            CPSLGoalClarification.normalizedClarifiedGoal(
                "```\nUse a concise finished reply.\n```",
                originalDisplayText: "do the thing"
            ) == "Use a concise finished reply."
        )
    }

    @Test func providerTextInsertsGoalBeforeAttachments() {
        let path = "\(CPSLVirtualPath.attachments)/conv/file.txt"
        let prompt = CPSLAttachmentPrompt(
            displayText: "Please review this",
            attachments: [CPSLAttachment(name: "file.txt", path: path)]
        )
        let goal = "Return a finished review of the attached file."
        let next = prompt.embeddingClarifiedGoal(goal)
        #expect(next.displayText == "Please review this")
        #expect(next.providerText.contains("Please review this"))
        #expect(next.providerText.contains(CPSLGoalClarification.endGoalHeading))
        #expect(next.providerText.contains(goal))
        #expect(next.providerText.contains(CPSLAttachmentPrompt.attachedFilesHeading))
        #expect(next.providerText.contains(path))

        let goalRange = next.providerText.range(of: goal)!
        let attachRange = next.providerText.range(of: CPSLAttachmentPrompt.attachedFilesHeading)!
        #expect(goalRange.lowerBound < attachRange.lowerBound)

        let parsed = CPSLAttachmentPrompt.parse(next.providerText)
        #expect(parsed.attachments.map(\.path) == [path])
    }

    @Test func shouldClarifySkipsEmptyDisplay() {
        #expect(CPSLGoalClarification.shouldClarify(displayText: "  ") == false)
        #expect(CPSLGoalClarification.shouldClarify(displayText: "Go") == true)
    }

    @Test func applyingClarifiedGoalHelperMatchesEmbedding() {
        let prompt = CPSLAttachmentPrompt(displayText: "Ship the report", attachments: [])
        let goal = "Produce the finished report content in the reply."
        let a = CPSLGoalClarification.applyingClarifiedGoal(goal, to: prompt)
        let b = prompt.embeddingClarifiedGoal(goal)
        #expect(a == b)
    }
}

/// Locates shipped ChatModel source so tests assert real wiring, not a reimplementation.
private enum SystemPromptSource {
    static func chatModelSource() throws -> String {
        let fileManager = FileManager.default
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("app/apple/herm/Models/CPSLChatModel.swift"),
            cwd.appendingPathComponent("Models/CPSLChatModel.swift"),
            cwd.deletingLastPathComponent().appendingPathComponent("Models/CPSLChatModel.swift"),
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("herm/Models/CPSLChatModel.swift")
        ]
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw SourceLookupError.missingChatModel
    }

    private enum SourceLookupError: Error {
        case missingChatModel
    }
}
