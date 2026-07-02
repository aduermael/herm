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
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
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

    private var horizontalPadding: CGFloat {
        message.role == .toolStatus ? CPSLTheme.small : CPSLTheme.medium
    }

    private var verticalPadding: CGFloat {
        message.role == .toolStatus ? CPSLTheme.small / 2 : CPSLTheme.medium
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
        } else if message.role == .toolStatus {
            if let payload = CPSLToolStatusPayload.decode(from: message.body) {
                CPSLToolStatusBody(payload: payload)
            } else {
                Text(message.body)
                    .font(CPSLTheme.supportingFont)
                    .foregroundStyle(message.role.foreground)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else if message.role.rendersMarkdownBody {
            CPSLMarkdownMessageBody(
                text: message.body,
                foreground: message.role.foreground,
                fillsAvailableWidth: message.role.isFullWidth
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

private struct CPSLToolStatusBody: View {
    let payload: CPSLToolStatusPayload

#if DEBUG
    @State private var isExpanded = false
#endif

    var body: some View {
#if DEBUG
        DisclosureGroup(isExpanded: $isExpanded) {
            CPSLToolStatusDebugDetails(invocations: payload.invocations)
                .padding(.top, CPSLTheme.small)
        } label: {
            CPSLToolStatusLine(payload: payload)
        }
        .disclosureGroupStyle(.automatic)
#else
        CPSLToolStatusLine(payload: payload)
#endif
    }
}

private struct CPSLToolStatusLine: View {
    let payload: CPSLToolStatusPayload

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            CPSLToolStatusIcon(state: payload.state)

            Text(payload.summary)
                .font(CPSLTheme.supportingMediumFont)
                .foregroundStyle(CPSLTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: CPSLTheme.large, alignment: .center)
    }
}

private struct CPSLToolStatusIcon: View {
    let state: CPSLToolStatusState

    var body: some View {
        icon
            .font(CPSLTheme.iconMediumFont)
            .foregroundStyle(iconColor)
            .frame(width: CPSLTheme.large, height: CPSLTheme.large)
    }

    @ViewBuilder
    private var icon: some View {
        if state == .running {
            TimelineView(.animation) { timeline in
                Image(systemName: iconName)
                    .rotationEffect(.degrees(rotation(at: timeline.date)))
            }
        } else {
            Image(systemName: iconName)
        }
    }

    private var iconName: String {
        switch state {
        case .running:
            return "gearshape.fill"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch state {
        case .running:
            return CPSLTheme.secondaryText
        case .succeeded:
            return CPSLTheme.success
        case .failed:
            return CPSLTheme.danger
        }
    }

    private func rotation(at date: Date) -> Double {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9)
        return cycle / 0.9 * 360
    }
}

#if DEBUG
private struct CPSLToolStatusDebugDetails: View {
    let invocations: [CPSLToolStatusInvocation]

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.medium) {
            if invocations.isEmpty {
                Text("No completed tool calls yet.")
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
            } else {
                ForEach(invocations) { invocation in
                    CPSLToolStatusInvocationDebugView(invocation: invocation)
                }
            }
        }
    }
}

private struct CPSLToolStatusInvocationDebugView: View {
    let invocation: CPSLToolStatusInvocation

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            HStack(spacing: CPSLTheme.small) {
                Image(systemName: invocation.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(invocation.isError ? CPSLTheme.danger : CPSLTheme.success)
                Text(invocation.isError ? "Failed step" : "Completed step")
                    .font(CPSLTheme.captionMediumFont)
                    .foregroundStyle(CPSLTheme.text)
            }

            CPSLToolDebugBlock(title: "Input", text: invocation.input)
            CPSLToolDebugBlock(title: "Output", text: invocation.output)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CPSLToolDebugBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
            Text(title)
                .font(CPSLTheme.captionMediumFont)
                .foregroundStyle(CPSLTheme.secondaryText)

            Text(text.isEmpty ? "(empty)" : text)
                .font(CPSLTheme.monospacedBodyFont)
                .foregroundStyle(CPSLTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CPSLTheme.small)
        .background(CPSLTheme.command)
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
    }
}
#endif

private struct CPSLMarkdownMessageBody: View {
    let text: String
    let foreground: Color
    let fillsAvailableWidth: Bool

    var body: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: CPSLTheme.small) {
                ForEach(CPSLMarkdownBlock.blocks(from: text)) { block in
                    CPSLMarkdownBlockView(
                        block: block,
                        foreground: foreground,
                        fillsAvailableWidth: fillsAvailableWidth
                    )
                }
            }
            .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
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
        case table(CPSLMarkdownTable)
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

            if let parsedTable = table(from: lines, startingAt: index) {
                flushParagraph()
                append(.table(parsedTable.table))
                index = parsedTable.nextIndex
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

    private static func table(
        from lines: [String],
        startingAt index: Int
    ) -> (table: CPSLMarkdownTable, nextIndex: Int)? {
        guard index + 1 < lines.count,
              let headerCells = tableCells(from: lines[index]),
              headerCells.contains(where: { !$0.isEmpty }),
              isTableSeparatorLine(lines[index + 1], columnCount: headerCells.count)
        else {
            return nil
        }

        var rows: [CPSLMarkdownTableRow] = []
        var cursor = index + 2
        while cursor < lines.count, let cells = tableCells(from: lines[cursor]) {
            rows.append(CPSLMarkdownTableRow(id: rows.count, cells: cells))
            cursor += 1
        }

        return (CPSLMarkdownTable(headers: headerCells, rows: rows), cursor)
    }

    private static func tableCells(from line: String) -> [String]? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLine.contains("|") else {
            return nil
        }

        var cells: [String] = []
        var currentCell = ""
        var isEscaped = false
        var codeSpanDelimiterLength = 0
        var sawCellSeparator = false
        var lastWasCellSeparator = false
        var index = trimmedLine.startIndex

        while index < trimmedLine.endIndex {
            let character = trimmedLine[index]
            if isEscaped {
                if character != "|" {
                    currentCell.append("\\")
                }
                currentCell.append(character)
                isEscaped = false
                lastWasCellSeparator = false
                index = trimmedLine.index(after: index)
            } else if character == "\\" {
                isEscaped = true
                lastWasCellSeparator = false
                index = trimmedLine.index(after: index)
            } else if character == "`" {
                let delimiterLength = backtickRunLength(in: trimmedLine, startingAt: index)
                currentCell += String(repeating: "`", count: delimiterLength)
                if codeSpanDelimiterLength == 0 {
                    codeSpanDelimiterLength = delimiterLength
                } else if delimiterLength == codeSpanDelimiterLength {
                    codeSpanDelimiterLength = 0
                }
                lastWasCellSeparator = false
                index = trimmedLine.index(index, offsetBy: delimiterLength)
            } else if character == "|", codeSpanDelimiterLength == 0 {
                cells.append(currentCell.trimmingCharacters(in: .whitespaces))
                currentCell = ""
                sawCellSeparator = true
                lastWasCellSeparator = true
                index = trimmedLine.index(after: index)
            } else {
                currentCell.append(character)
                lastWasCellSeparator = false
                index = trimmedLine.index(after: index)
            }
        }

        if isEscaped {
            currentCell.append("\\")
        }
        cells.append(currentCell.trimmingCharacters(in: .whitespaces))

        guard sawCellSeparator else {
            return nil
        }

        if trimmedLine.first == "|", cells.first?.isEmpty == true {
            cells.removeFirst()
        }
        if lastWasCellSeparator, cells.last?.isEmpty == true {
            cells.removeLast()
        }

        return cells.isEmpty ? nil : cells
    }

    private static func backtickRunLength(in line: String, startingAt index: String.Index) -> Int {
        var cursor = index
        var count = 0
        while cursor < line.endIndex, line[cursor] == "`" {
            count += 1
            cursor = line.index(after: cursor)
        }
        return count
    }

    private static func isTableSeparatorLine(_ line: String, columnCount: Int) -> Bool {
        guard let cells = tableCells(from: line),
              cells.count == columnCount,
              columnCount > 0
        else {
            return false
        }

        return cells.allSatisfy { cell in
            let trimmedCell = cell.trimmingCharacters(in: .whitespaces)
            let dashCount = trimmedCell.filter { $0 == "-" }.count
            return dashCount >= 3 && trimmedCell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func isMarkdownWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) }
    }
}

private struct OrderedListItem: Equatable {
    let number: Int
    let text: String
}

private struct CPSLMarkdownTable: Equatable {
    let headers: [String]
    let rows: [CPSLMarkdownTableRow]

    var columnCount: Int {
        headers.count
    }

    func header(at column: Int) -> String {
        cell(in: headers, at: column)
    }

    func cell(in row: CPSLMarkdownTableRow, at column: Int) -> String {
        cell(in: row.cells, at: column)
    }

    private func cell(in cells: [String], at column: Int) -> String {
        guard cells.indices.contains(column) else {
            return ""
        }
        return cells[column]
    }
}

private struct CPSLMarkdownTableRow: Identifiable, Equatable {
    let id: Int
    let cells: [String]
}

private struct CPSLMarkdownBlockView: View {
    let block: CPSLMarkdownBlock
    let foreground: Color
    let fillsAvailableWidth: Bool

    var body: some View {
        switch block.content {
        case .heading(let level, let text):
            CPSLMarkdownInlineText(
                text: text,
                font: headingFont(for: level),
                foreground: foreground,
                fillsAvailableWidth: fillsAvailableWidth
            )
                .padding(.top, level == 1 ? CPSLTheme.small : 0)
        case .paragraph(let lines):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    CPSLMarkdownInlineText(
                        text: line,
                        font: CPSLTheme.bodyFont,
                        foreground: foreground,
                        fillsAvailableWidth: fillsAvailableWidth
                    )
                }
            }
        case .unorderedList(let items):
            CPSLMarkdownListView(
                items: items.map { CPSLMarkdownListItem(marker: "\u{2022}", text: $0) },
                foreground: foreground,
                fillsAvailableWidth: fillsAvailableWidth
            )
        case .orderedList(let items):
            CPSLMarkdownListView(
                items: items.map { CPSLMarkdownListItem(marker: "\($0.number).", text: $0.text) },
                foreground: foreground,
                fillsAvailableWidth: fillsAvailableWidth
            )
        case .table(let table):
            CPSLMarkdownTableView(
                table: table,
                foreground: foreground,
                fillsAvailableWidth: fillsAvailableWidth
            )
        case .codeBlock(let language, let text):
            CPSLMarkdownCodeBlockView(
                language: language,
                text: text,
                foreground: foreground,
                fillsAvailableWidth: fillsAvailableWidth
            )
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

private struct CPSLMarkdownTableView: View {
    let table: CPSLMarkdownTable
    let foreground: Color
    let fillsAvailableWidth: Bool

    var body: some View {
        if fillsAvailableWidth {
            CPSLMarkdownTableScrollView(table: table, foreground: foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ViewThatFits(in: .horizontal) {
                CPSLMarkdownTableGrid(table: table, foreground: foreground)
                CPSLMarkdownTableScrollView(table: table, foreground: foreground)
            }
            .frame(maxWidth: CPSLTheme.framedMessageMaxWidth, alignment: .leading)
        }
    }
}

private struct CPSLMarkdownTableScrollView: View {
    let table: CPSLMarkdownTable
    let foreground: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            CPSLMarkdownTableGrid(table: table, foreground: foreground)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}

private struct CPSLMarkdownTableGrid: View {
    let table: CPSLMarkdownTable
    let foreground: Color

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<table.columnCount, id: \.self) { column in
                    CPSLMarkdownTableCell(
                        text: table.header(at: column),
                        isHeader: true,
                        foreground: foreground
                    )
                }
            }

            ForEach(table.rows) { row in
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        CPSLMarkdownTableCell(
                            text: table.cell(in: row, at: column),
                            isHeader: false,
                            foreground: foreground
                        )
                    }
                }
            }
        }
        .background(CPSLTheme.surface.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
    }
}

private struct CPSLMarkdownTableCell: View {
    let text: String
    let isHeader: Bool
    let foreground: Color

    var body: some View {
        CPSLMarkdownInlineText(
            text: text.isEmpty ? " " : text,
            font: isHeader ? CPSLTheme.captionMediumFont : CPSLTheme.captionFont,
            foreground: foreground,
            fillsAvailableWidth: false
        )
        .padding(.horizontal, CPSLTheme.small)
        .padding(.vertical, CPSLTheme.small / 2)
        .frame(minWidth: 72, maxWidth: 220, alignment: .leading)
        .background(isHeader ? CPSLTheme.elevated.opacity(0.42) : Color.clear)
    }
}

private struct CPSLMarkdownInlineText: View {
    let text: String
    let font: Font
    let foreground: Color
    let fillsAvailableWidth: Bool

    var body: some View {
        renderedText
            .font(font)
            .foregroundStyle(foreground)
            .lineSpacing(CPSLTheme.bodyLineSpacing)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
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
    let fillsAvailableWidth: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: CPSLTheme.small) {
                    Text(item.marker)
                        .font(CPSLTheme.bodyFont)
                        .foregroundStyle(foreground)
                        .frame(minWidth: CPSLTheme.large, alignment: .trailing)

                    CPSLMarkdownInlineText(
                        text: item.text,
                        font: CPSLTheme.bodyFont,
                        foreground: foreground,
                        fillsAvailableWidth: fillsAvailableWidth
                    )
                }
                .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
            }
        }
    }
}

private struct CPSLMarkdownCodeBlockView: View {
    let language: String?
    let text: String
    let foreground: Color
    let fillsAvailableWidth: Bool

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
                .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
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
