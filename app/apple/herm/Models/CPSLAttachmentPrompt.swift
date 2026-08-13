import Foundation

nonisolated struct CPSLAttachmentPrompt: Equatable, Sendable {
    static let attachedFilesHeading = "Attached files:"

    let displayText: String
    let providerText: String
    let attachments: [CPSLAttachment]

    init(displayText: String, attachments: [CPSLAttachment]) {
        self.displayText = displayText
        self.attachments = attachments
        providerText = Self.makeProviderText(
            displayText: displayText,
            attachments: attachments
        )
    }

    /// Full constructor used when provider text has been adjusted (e.g. clarified end goal).
    init(displayText: String, providerText: String, attachments: [CPSLAttachment]) {
        self.displayText = displayText
        self.providerText = providerText
        self.attachments = attachments
    }

    /// Returns a copy whose provider-facing content embeds a clarified end goal.
    /// Display text (timeline body) is unchanged.
    func embeddingClarifiedGoal(_ goal: String?) -> CPSLAttachmentPrompt {
        let nextProvider = CPSLGoalClarification.providerText(
            baseProviderText: providerText,
            clarifiedGoal: goal
        )
        guard nextProvider != providerText else {
            return self
        }
        return CPSLAttachmentPrompt(
            displayText: displayText,
            providerText: nextProvider,
            attachments: attachments
        )
    }

    static func parse(_ text: String?) -> (displayText: String, attachments: [CPSLAttachment]) {
        guard let text else {
            return ("", [])
        }

        let heading = attachedFilesHeading
        let sectionPrefix = "\n\n\(heading)\n"
        let displayText: String
        let pathText: Substring
        if text.hasPrefix("\(heading)\n") {
            displayText = ""
            pathText = text.dropFirst(heading.count + 1)
        } else if let range = text.range(of: sectionPrefix, options: .backwards) {
            displayText = String(text[..<range.lowerBound])
            pathText = text[range.upperBound...]
        } else {
            return (text, [])
        }

        var seenPaths = Set<String>()
        let attachments = pathText
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> CPSLAttachment? in
                let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.hasPrefix("- ") else {
                    return nil
                }
                let path = String(value.dropFirst(2))
                guard path.hasPrefix("\(CPSLVirtualPath.attachments)/"),
                      seenPaths.insert(path).inserted
                else {
                    return nil
                }
                return CPSLAttachment(
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    path: path
                )
            }

        guard !attachments.isEmpty,
              attachments.count == pathText.split(whereSeparator: \.isNewline).count
        else {
            return (text, [])
        }
        // Provider text may include an End goal block before attachments; display is body only.
        let cleanedDisplay = stripTrailingEndGoal(from: displayText)
        return (cleanedDisplay, attachments)
    }

    private static func makeProviderText(
        displayText: String,
        attachments: [CPSLAttachment]
    ) -> String {
        guard !attachments.isEmpty else {
            return displayText
        }
        let paths = attachments.map { "- \($0.path)" }.joined(separator: "\n")
        let attachmentSection = "\(attachedFilesHeading)\n\(paths)"
        return displayText.isEmpty
            ? attachmentSection
            : "\(displayText)\n\n\(attachmentSection)"
    }

    private static func stripTrailingEndGoal(from text: String) -> String {
        let marker = "\n\n\(CPSLGoalClarification.endGoalHeading)\n"
        guard let range = text.range(of: marker, options: .backwards) else {
            return text
        }
        return String(text[..<range.lowerBound])
    }
}
