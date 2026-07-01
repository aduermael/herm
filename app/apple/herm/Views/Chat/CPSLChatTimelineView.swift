import Foundation
import SwiftUI

struct CPSLChatTimelineView: View {
    @ObservedObject var model: CPSLChatModel
    let topInset: CGFloat
    let bottomInset: CGFloat
    @State private var isPinnedToBottom = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    var body: some View {
        ZStack {
            if model.messages.isEmpty {
                CPSLEmptyChatView()
            }

            ScrollView {
                LazyVStack(spacing: CPSLTheme.messageVerticalSpacing) {
                    ForEach(model.messages) { message in
                        CPSLChatMessageView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, CPSLTheme.contentHorizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
            .scrollPosition($scrollPosition)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.top, topInset, for: .scrollIndicators)
            .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
            .opacity(model.messages.isEmpty ? 0 : 1)
            .onAppear {
                scrollToBottom(animated: false)
            }
            .onChange(of: model.messages.count) { _, _ in
                scrollToBottom(animated: true)
            }
            .onChange(of: model.messages.last?.body) { _, _ in
                scrollToBottom(animated: true)
            }
            .onChange(of: bottomInset) { _, _ in
                scrollToBottomIfPinned()
            }
            .onScrollGeometryChange(
                for: CPSLTimelineScrollState.self,
                of: { geometry in
                    CPSLTimelineScrollState(geometry: geometry)
                },
                action: { oldState, newState in
                    handleScrollGeometryChange(oldState: oldState, newState: newState)
                }
            )
        }
    }

    private func scrollToBottom(animated: Bool) {
        guard !model.messages.isEmpty else {
            return
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private func scrollToBottomIfPinned() {
        guard isPinnedToBottom else {
            return
        }
        scrollToBottom(animated: false)
    }

    private func handleScrollGeometryChange(
        oldState: CPSLTimelineScrollState,
        newState: CPSLTimelineScrollState
    ) {
        guard oldState.viewportHeight > 0 else {
            isPinnedToBottom = newState.isPinnedToBottom
            return
        }

        let didResize = abs(oldState.viewportHeight - newState.viewportHeight) > 0.5
        let shouldPreserveBottom = oldState.isPinnedToBottom || isPinnedToBottom
        let isViewportExpanding = newState.viewportHeight > oldState.viewportHeight

        if didResize {
            preserveVisibleScrollPosition(
                oldState: oldState,
                newState: newState,
                pinnedToBottom: shouldPreserveBottom,
                animated: isViewportExpanding
            )
        } else {
            isPinnedToBottom = newState.isPinnedToBottom
        }
    }

    private func preserveVisibleScrollPosition(
        oldState: CPSLTimelineScrollState,
        newState: CPSLTimelineScrollState,
        pinnedToBottom: Bool,
        animated: Bool
    ) {
        let viewportDelta = oldState.viewportHeight - newState.viewportHeight
        let preservedY = oldState.contentOffsetY + viewportDelta
        let targetY = pinnedToBottom ? newState.maxContentOffsetY : min(
            max(preservedY, 0),
            newState.maxContentOffsetY
        )

        isPinnedToBottom = pinnedToBottom || newState.isPinnedToBottom
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(y: targetY)
            }
        } else {
            scrollPosition.scrollTo(y: targetY)
        }
    }
}

private struct CPSLTimelineScrollState: Equatable {
    let isPinnedToBottom: Bool
    let viewportHeight: CGFloat
    let contentHeight: CGFloat
    let contentOffsetY: CGFloat

    var maxContentOffsetY: CGFloat {
        max(0, contentHeight - viewportHeight)
    }

    init(geometry: ScrollGeometry) {
        let bottomDistance = geometry.contentSize.height - geometry.visibleRect.maxY
        isPinnedToBottom = bottomDistance <= CPSLTheme.medium
        viewportHeight = geometry.containerSize.height
        contentHeight = geometry.contentSize.height
        contentOffsetY = geometry.contentOffset.y
    }
}

private struct CPSLEmptyChatView: View {
    var body: some View {
        VStack(spacing: CPSLTheme.medium) {
            Image(systemName: "sparkles")
                .font(CPSLTheme.emptyStateIconFont)
                .foregroundStyle(CPSLTheme.mauve.opacity(0.30))

            Text("Herm")
                .font(CPSLTheme.controlFont)
                .foregroundStyle(CPSLTheme.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CPSLChatMessageView: View {
    let message: CPSLChatMessage

    var body: some View {
        HStack {
            if message.role.isTrailingAligned && !message.role.isFullWidth {
                Spacer(minLength: CPSLTheme.framedMessageSideIndent)
            }

            messageContent

            if !message.role.isTrailingAligned && !message.role.isFullWidth {
                Spacer(minLength: CPSLTheme.framedMessageSideIndent)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role.isTrailingAligned ? .trailing : .leading)
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.role.isFramed {
            messageStack
                .padding(CPSLTheme.medium)
                .background(message.role.fill)
                .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.messageRadius, style: .continuous))
                .frame(
                    maxWidth: message.role.isFullWidth ? .infinity : CPSLTheme.framedMessageMaxWidth,
                    alignment: message.role.isTrailingAligned ? .trailing : .leading
                )
        } else {
            messageStack
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var messageStack: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            if message.role.displaysTitle, let title = message.title {
                Text(title)
                    .font(CPSLTheme.captionMediumFont)
                    .foregroundStyle(message.role.foreground.opacity(0.72))
            }
            messageBody
        }
    }

    @ViewBuilder
    private var messageBody: some View {
        if message.role == .command {
            CPSLCommandBlockBody(text: message.body, foreground: message.role.foreground)
        } else if message.role.rendersMarkdownBody {
            CPSLMarkdownMessageBody(
                text: message.body,
                foreground: message.role.foreground
            )
        } else {
            Text(message.body)
                .font(message.role.usesMonospaceBody ? CPSLTheme.monospacedBodyFont : CPSLTheme.bodyFont)
                .foregroundStyle(message.role.foreground)
                .lineSpacing(message.role.usesMonospaceBody ? 0 : CPSLTheme.bodyLineSpacing)
                .textSelection(.enabled)
        }
    }
}

private struct CPSLMarkdownMessageBody: View {
    let text: String
    let foreground: Color

    var body: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: CPSLTheme.small) {
                ForEach(CPSLMarkdownBlock.blocks(from: text)) { block in
                    CPSLMarkdownBlockView(block: block, foreground: foreground)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

private struct CPSLMarkdownBlock: Identifiable, Equatable {
    enum Content: Equatable {
        case heading(level: Int, text: String)
        case paragraph(lines: [String])
        case unorderedList(items: [String])
        case orderedList(items: [OrderedListItem])
        case codeBlock(language: String?, text: String)
    }

    private struct CodeFence {
        let language: String?
    }

    let id: Int
    let content: Content

    static func blocks(from text: String) -> [CPSLMarkdownBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [CPSLMarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func append(_ content: Content) {
            blocks.append(CPSLMarkdownBlock(id: blocks.count, content: content))
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else {
                return
            }
            append(.paragraph(lines: paragraphLines))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if let codeFence = codeFence(from: line) {
                flushParagraph()
                index += 1

                var codeLines: [String] = []
                while index < lines.count {
                    if isClosingCodeFence(lines[index]) {
                        index += 1
                        break
                    }

                    codeLines.append(lines[index])
                    index += 1
                }

                append(.codeBlock(language: codeFence.language, text: codeLines.joined(separator: "\n")))
                continue
            }

            if trimmedLine.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = heading(from: line) {
                flushParagraph()
                append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let item = unorderedListItem(from: line) {
                flushParagraph()

                var items = [item]
                index += 1
                while index < lines.count, let nextItem = unorderedListItem(from: lines[index]) {
                    items.append(nextItem)
                    index += 1
                }

                append(.unorderedList(items: items))
                continue
            }

            if let item = orderedListItem(from: line) {
                flushParagraph()

                var items = [item]
                index += 1
                while index < lines.count, let nextItem = orderedListItem(from: lines[index]) {
                    items.append(nextItem)
                    index += 1
                }

                append(.orderedList(items: items))
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        return blocks.isEmpty ? [CPSLMarkdownBlock(id: 0, content: .paragraph(lines: [""]))] : blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        var level = 0
        var cursor = trimmedLine.startIndex

        while cursor < trimmedLine.endIndex, trimmedLine[cursor] == "#", level < 6 {
            level += 1
            cursor = trimmedLine.index(after: cursor)
        }

        guard level > 0, cursor < trimmedLine.endIndex, isMarkdownWhitespace(trimmedLine[cursor]) else {
            return nil
        }

        let textStart = trimmedLine.index(after: cursor)
        let text = String(trimmedLine[textStart...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func codeFence(from line: String) -> CodeFence? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLine.hasPrefix("```") else {
            return nil
        }

        let language = String(trimmedLine.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return CodeFence(language: language.isEmpty ? nil : language)
    }

    private static func isClosingCodeFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
    }

    private static func unorderedListItem(from line: String) -> String? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmedLine.hasPrefix(marker) {
            return String(trimmedLine.dropFirst(marker.count))
        }

        return nil
    }

    private static func orderedListItem(from line: String) -> OrderedListItem? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        var cursor = trimmedLine.startIndex
        var numberText = ""

        while cursor < trimmedLine.endIndex, trimmedLine[cursor].isWholeNumber {
            numberText.append(trimmedLine[cursor])
            cursor = trimmedLine.index(after: cursor)
        }

        guard !numberText.isEmpty,
              cursor < trimmedLine.endIndex,
              trimmedLine[cursor] == "."
        else {
            return nil
        }

        let afterDot = trimmedLine.index(after: cursor)
        guard afterDot < trimmedLine.endIndex, isMarkdownWhitespace(trimmedLine[afterDot]) else {
            return nil
        }

        let textStart = trimmedLine.index(after: afterDot)
        return OrderedListItem(number: Int(numberText) ?? 1, text: String(trimmedLine[textStart...]))
    }

    private static func isMarkdownWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }
}

private struct OrderedListItem: Equatable {
    let number: Int
    let text: String
}

private struct CPSLMarkdownBlockView: View {
    let block: CPSLMarkdownBlock
    let foreground: Color

    var body: some View {
        switch block.content {
        case .heading(let level, let text):
            CPSLMarkdownInlineText(text: text, font: headingFont(for: level), foreground: foreground)
                .padding(.top, level == 1 ? CPSLTheme.small : 0)
        case .paragraph(let lines):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    CPSLMarkdownInlineText(text: line, font: CPSLTheme.bodyFont, foreground: foreground)
                }
            }
        case .unorderedList(let items):
            CPSLMarkdownListView(
                items: items.map { CPSLMarkdownListItem(marker: "\u{2022}", text: $0) },
                foreground: foreground
            )
        case .orderedList(let items):
            CPSLMarkdownListView(
                items: items.map { CPSLMarkdownListItem(marker: "\($0.number).", text: $0.text) },
                foreground: foreground
            )
        case .codeBlock(let language, let text):
            CPSLMarkdownCodeBlockView(language: language, text: text, foreground: foreground)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            return CPSLTheme.headerFont
        case 2:
            return CPSLTheme.userFont(size: 19, weight: .semibold)
        case 3:
            return CPSLTheme.userFont(size: 17, weight: .semibold)
        default:
            return CPSLTheme.userFont(size: CPSLTheme.FontSize.body, weight: .semibold)
        }
    }
}

private struct CPSLMarkdownInlineText: View {
    let text: String
    let font: Font
    let foreground: Color

    var body: some View {
        renderedText
            .font(font)
            .foregroundStyle(foreground)
            .lineSpacing(CPSLTheme.bodyLineSpacing)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
    }

    private var renderedText: Text {
        guard let attributedText = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) else {
            return Text(text)
        }

        return Text(attributedText)
    }
}

private struct CPSLMarkdownListItem: Equatable {
    let marker: String
    let text: String
}

private struct CPSLMarkdownListView: View {
    let items: [CPSLMarkdownListItem]
    let foreground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: CPSLTheme.small) {
                    Text(item.marker)
                        .font(CPSLTheme.bodyFont)
                        .foregroundStyle(foreground)
                        .frame(minWidth: CPSLTheme.large, alignment: .trailing)

                    CPSLMarkdownInlineText(text: item.text, font: CPSLTheme.bodyFont, foreground: foreground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct CPSLMarkdownCodeBlockView: View {
    let language: String?
    let text: String
    let foreground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
            if let language {
                Text(language)
                    .font(CPSLTheme.captionMediumFont)
                    .foregroundStyle(foreground.opacity(0.62))
            }

            Text(text)
                .font(CPSLTheme.monospacedBodyFont)
                .foregroundStyle(foreground)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CPSLTheme.small)
        .background(CPSLTheme.command)
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
    }
}

private struct CPSLCommandBlockBody: View {
    let text: String
    let foreground: Color

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > CPSLTheme.commandBlockMaxHeight) {
            Text(text)
                .font(CPSLTheme.monospacedBodyFont)
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: CPSLCommandBlockHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(height: contentHeight > 0 ? min(contentHeight, CPSLTheme.commandBlockMaxHeight) : nil)
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(CPSLCommandBlockHeightKey.self) { height in
            contentHeight = height
        }
    }
}

private struct CPSLCommandBlockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
