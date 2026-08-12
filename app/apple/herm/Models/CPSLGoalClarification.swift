import Foundation

/// Domain-agnostic completion guidance and internal goal-clarification helpers.
/// Skills own domain procedures; this type never branches on task categories.
nonisolated enum CPSLGoalClarification {
    /// Injected into the main-agent system prompt (generic carry-through-end contract).
    static let mainAgentCompletionContract = """
    Carry each user request through to a finished result in your assistant reply whenever tools and permissions allow. Do not treat intermediate process status alone as completion when you can still obtain and present the outcome yourself (for example only reporting that you opened a page, started a search, or began work). User handoff is appropriate only when the user must act—authentication, CAPTCHA, payment, consent, or they asked to take over—or when a hard limitation blocks further progress. Domain-specific procedures live in skills: load and follow relevant skills instead of inventing category-specific workflows.
    """

    /// Tools-free clarify-step instructions. Restates end goal only; no domain recipes.
    static let clarifyInstructions = """
    You prepare a brief end-goal restatement for another agent. Given the user's message, state what a successful finished assistant reply should deliver. Be concrete about the deliverable when the request implies one. Do not answer the request. Do not invent tools, brands, places, or domain-specific steps. Do not mention skills, sandbox, code, or implementation. Output plain text only: one short paragraph or a few short bullets.
    """

    static let endGoalHeading = "End goal:"
    static let maxOutputTokens = 256
    static let timeoutNanoseconds: UInt64 = 5_000_000_000

    static func shouldClarify(displayText: String) -> Bool {
        !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Normalize model clarify output; returns nil to fail open (use original provider text).
    static func normalizedClarifiedGoal(
        _ raw: String,
        originalDisplayText: String
    ) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        if text.hasPrefix("```") {
            text = stripFence(text)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        if text.count > 800 {
            text = String(text.prefix(797)) + "..."
        }
        let original = originalDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.caseInsensitiveCompare(original) == .orderedSame {
            return nil
        }
        return text
    }

    /// Merge an optional clarified goal into provider-facing user content.
    /// Keeps attachment sections intact; never changes user-visible display text.
    static func providerText(
        baseProviderText: String,
        clarifiedGoal: String?
    ) -> String {
        guard let goal = clarifiedGoal?.trimmingCharacters(in: .whitespacesAndNewlines),
              !goal.isEmpty
        else {
            return baseProviderText
        }

        let goalBlock = "\(endGoalHeading)\n\(goal)"
        let attachmentPrefix = "\n\n\(CPSLAttachmentPrompt.attachedFilesHeading)\n"
        if let range = baseProviderText.range(of: attachmentPrefix, options: .backwards) {
            let before = String(baseProviderText[..<range.lowerBound])
            let after = String(baseProviderText[range.lowerBound...])
            if before.isEmpty {
                return "\(goalBlock)\(after)"
            }
            return "\(before)\n\n\(goalBlock)\(after)"
        }
        if baseProviderText.hasPrefix("\(CPSLAttachmentPrompt.attachedFilesHeading)\n") {
            return "\(goalBlock)\n\n\(baseProviderText)"
        }
        if baseProviderText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return goalBlock
        }
        return "\(baseProviderText)\n\n\(goalBlock)"
    }

    static func applyingClarifiedGoal(
        _ goal: String?,
        to prompt: CPSLAttachmentPrompt
    ) -> CPSLAttachmentPrompt {
        prompt.embeddingClarifiedGoal(goal)
    }

    /// Source/gating check: prompt includes the generic completion contract.
    static func systemPromptContainsCompletionContract(_ systemPrompt: String) -> Bool {
        let haystack = systemPrompt.lowercased()
        let hasCarryThrough = haystack.contains("finished result")
            || haystack.contains("carry each user request")
        let hasHandoffBoundary = haystack.contains("user handoff")
            || haystack.contains("authentication")
        let hasSkillsDeferral = haystack.contains("skills")
        let hasNoCategoryCookbook = !haystack.contains("barber shop")
            && !haystack.contains("restaurant nearby")
            && !haystack.contains("for nearby places:")
        return hasCarryThrough && hasHandoffBoundary && hasSkillsDeferral && hasNoCategoryCookbook
    }

    private static func stripFence(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.hasPrefix("```") == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
