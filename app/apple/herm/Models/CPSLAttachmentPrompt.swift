import Foundation

nonisolated struct CPSLAttachmentPrompt: Equatable, Sendable {
    private static let heading = "Attached files:"

    let displayText: String
    let providerText: String
    let attachments: [CPSLAttachment]

    init(displayText: String, attachments: [CPSLAttachment]) {
        self.displayText = displayText
        self.attachments = attachments
        guard !attachments.isEmpty else {
            providerText = displayText
            return
        }

        let paths = attachments.map { "- \($0.path)" }.joined(separator: "\n")
        let attachmentSection = "\(Self.heading)\n\(paths)"
        providerText = displayText.isEmpty
            ? attachmentSection
            : "\(displayText)\n\n\(attachmentSection)"
    }

    static func parse(_ text: String?) -> (displayText: String, attachments: [CPSLAttachment]) {
        guard let text else {
            return ("", [])
        }

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
        return (displayText, attachments)
    }
}
