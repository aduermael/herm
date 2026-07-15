import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct CPSLChatTimelineView: View {
    @ObservedObject var model: CPSLChatModel
    let topInset: CGFloat
    let bottomInset: CGFloat
    let isScrollGeometryPaused: Bool
    @State private var isPinnedToBottom = true
    @State private var streamingScrollGeneration = 0
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    private var timelineIdentity: String {
        model.selectedConversationID ?? "draft"
    }

    private var hasTimelineContent: Bool {
        !model.messages.isEmpty || model.isRunning
    }

    var body: some View {
        ZStack {
            if !hasTimelineContent {
                CPSLEmptyChatView()
            }

            ScrollView {
                LazyVStack(spacing: CPSLTheme.messageVerticalSpacing) {
                    ForEach(model.messages) { message in
                        CPSLChatMessageView(
                            message: message,
                            openBrowser: { browserID in
                                model.openWebBrowserFromTimeline(browserID: browserID)
                            },
                            openFilePath: { path in
                                model.openFilePathFromTimeline(path)
                            },
                            loadAttachmentThumbnail: { attachment in
                                await model.attachmentThumbnail(for: attachment)
                            }
                        )
                            .id(message.id)
                    }

                    if model.isRunning {
                        CPSLAgentWorkingIndicatorView()
                            .id("agent-working-indicator")
                    }
                }
                .padding(.horizontal, CPSLTheme.contentHorizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
            }
            .id(timelineIdentity)
            .scrollPosition($scrollPosition)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.top, topInset, for: .scrollIndicators)
            .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
            .opacity(hasTimelineContent ? 1 : 0)
            .onAppear {
                scrollToBottom(animated: false)
            }
            .onChange(of: model.messages.count) { _, _ in
                scrollToBottom(animated: true)
            }
            .onChange(of: model.isRunning) { _, isRunning in
                if isRunning {
                    scrollToBottom(animated: true)
                }
            }
            .onChange(of: model.messages.last?.body) { _, _ in
                followStreamingBottomIfPinned()
            }
            .onChange(of: bottomInset) { _, _ in
                scrollToBottomIfPinned()
            }
            .onChange(of: timelineIdentity) { _, _ in
                resetScrollState()
            }
            .onScrollGeometryChange(
                for: CPSLTimelineScrollState.self,
                of: { geometry in
                    CPSLTimelineScrollState(geometry: geometry)
                },
                action: { oldState, newState in
                    guard !isScrollGeometryPaused else {
                        return
                    }

                    handleScrollGeometryChange(oldState: oldState, newState: newState)
                }
            )
        }
    }

    private func scrollToBottom(animated: Bool) {
        guard hasTimelineContent else {
            return
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        } else {
            updateScrollPositionImmediately {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    private func resetScrollState() {
        streamingScrollGeneration += 1
        isPinnedToBottom = true
        scrollPosition = ScrollPosition(edge: .bottom)
        scrollToBottom(animated: false)
    }

    private func scrollToBottomIfPinned() {
        guard isPinnedToBottom else {
            return
        }
        scrollToBottom(animated: false)
    }

    private func followStreamingBottomIfPinned() {
        guard isPinnedToBottom else {
            return
        }

        streamingScrollGeneration += 1
        let generation = streamingScrollGeneration
        Task { @MainActor in
            await Task.yield()
            guard generation == streamingScrollGeneration, isPinnedToBottom else {
                return
            }
            scrollToBottom(animated: false)
        }
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

        if didResize {
            preserveVisibleScrollPosition(
                CPSLTimelineScrollPreservation(
                    oldState: oldState,
                    newState: newState,
                    pinnedToBottom: shouldPreserveBottom
                )
            )
        } else {
            isPinnedToBottom = newState.isPinnedToBottom
        }
    }

    private func preserveVisibleScrollPosition(_ preservation: CPSLTimelineScrollPreservation) {
        let viewportDelta = preservation.oldState.viewportHeight - preservation.newState.viewportHeight
        let preservedY = preservation.oldState.contentOffsetY + viewportDelta
        let targetY = preservation.pinnedToBottom ? preservation.newState.maxContentOffsetY : min(
            max(preservedY, 0),
            preservation.newState.maxContentOffsetY
        )

        isPinnedToBottom = preservation.pinnedToBottom || preservation.newState.isPinnedToBottom
        updateScrollPositionImmediately {
            scrollPosition.scrollTo(y: targetY)
        }
    }

    private func updateScrollPositionImmediately(_ update: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }
}

private struct CPSLAgentWorkingIndicatorView: View {
    var body: some View {
        CPSLAgentWorkingDotsView()
            .padding(.horizontal, CPSLTheme.medium)
            .padding(.vertical, CPSLTheme.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Herm is working")
    }
}

private struct CPSLAgentWorkingDotsView: View {
    private let dotSize: CGFloat = 5
    private let dotSpacing: CGFloat = 4
    private let cycleDuration: TimeInterval = 0.84
    private let dotStagger = 0.16
    private let bounceWindow = 0.44
    private let bounceHeight: CGFloat = 4

    var body: some View {
        TimelineView(.animation) { timeline in
            HStack(spacing: dotSpacing) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(CPSLTheme.secondaryText.opacity(dotOpacity(index: index, at: timeline.date)))
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: dotBounceOffset(index: index, at: timeline.date))
                }
            }
            .frame(width: dotSize * 3 + dotSpacing * 2, height: CPSLTheme.large, alignment: .center)
        }
        .accessibilityHidden(true)
    }

    private func dotOpacity(index: Int, at date: Date) -> Double {
        0.34 + 0.46 * dotLift(index: index, at: date)
    }

    private func dotBounceOffset(index: Int, at date: Date) -> CGFloat {
        -CGFloat(dotLift(index: index, at: date)) * bounceHeight
    }

    private func dotLift(index: Int, at date: Date) -> Double {
        let phase = dotPhase(index: index, at: date)
        guard phase < bounceWindow else {
            return 0
        }
        return sin((phase / bounceWindow) * Double.pi)
    }

    private func dotPhase(index: Int, at date: Date) -> Double {
        let rawPhase = date.timeIntervalSinceReferenceDate / cycleDuration - Double(index) * dotStagger
        return rawPhase - floor(rawPhase)
    }
}

private struct CPSLTimelineScrollPreservation {
    let oldState: CPSLTimelineScrollState
    let newState: CPSLTimelineScrollState
    let pinnedToBottom: Bool
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
    let openBrowser: (String?) -> Void
    let openFilePath: (String) -> Void
    let loadAttachmentThumbnail: (CPSLAttachment) async -> Data?

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
            if !message.body.isEmpty {
                messageBody
            }
            if !message.attachments.isEmpty {
                CPSLMessageAttachmentList(
                    attachments: message.attachments,
                    openFilePath: openFilePath,
                    loadThumbnail: loadAttachmentThumbnail
                )
            }
        }
    }

    @ViewBuilder
    private var messageBody: some View {
        if message.role == .command {
            CPSLCommandBlockBody(
                text: message.body,
                foreground: message.role.foreground,
                openFilePath: openFilePath
            )
        } else if message.role == .toolStatus {
            if let payload = CPSLToolStatusPayload.decode(from: message.body) {
                CPSLToolStatusBody(payload: payload, openBrowser: openBrowser)
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
                fillsAvailableWidth: message.role.isFullWidth,
                openFilePath: openFilePath
            )
        } else {
            CPSLSelectableText(
                message.body,
                style: message.role.usesMonospaceBody ? .monospacedBody : .body,
                foreground: message.role.foreground,
                fillsAvailableWidth: false,
                lineSpacing: message.role.usesMonospaceBody ? 0 : CPSLTheme.bodyLineSpacing,
                openFilePath: openFilePath
            )
        }
    }
}

private struct CPSLMessageAttachmentList: View {
    let attachments: [CPSLAttachment]
    let openFilePath: (String) -> Void
    let loadThumbnail: (CPSLAttachment) async -> Data?

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            ForEach(attachments) { attachment in
                Button {
                    openFilePath(attachment.path)
                } label: {
                    CPSLAttachmentBadge(
                        attachment: attachment,
                        loadThumbnail: loadThumbnail
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open attachment \(attachment.name)")
            }
        }
    }
}

private struct CPSLToolStatusBody: View {
    let payload: CPSLToolStatusPayload
    let openBrowser: (String?) -> Void

#if DEBUG
    @State private var isExpanded = false
#endif

    var body: some View {
#if DEBUG
        VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
            DisclosureGroup(isExpanded: $isExpanded) {
                CPSLToolStatusDebugDetails(invocations: payload.invocations)
                    .padding(.top, CPSLTheme.small)
            } label: {
                CPSLToolStatusLine(payload: payload)
            }
            .disclosureGroupStyle(.automatic)

            if !payload.webVisits.isEmpty {
                CPSLWebSearchStatusLine(visits: payload.webVisits, openBrowser: openBrowser)
            }
        }
#else
        CPSLToolStatusStack(payload: payload, openBrowser: openBrowser)
#endif
    }
}

private struct CPSLToolStatusStack: View {
    let payload: CPSLToolStatusPayload
    let openBrowser: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
            CPSLToolStatusLine(payload: payload)
            if !payload.webVisits.isEmpty {
                CPSLWebSearchStatusLine(visits: payload.webVisits, openBrowser: openBrowser)
            }
        }
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

private struct CPSLWebSearchStatusLine: View {
    let visits: [CPSLWebSearchVisit]
    let openBrowser: (String?) -> Void

    private var latestVisit: CPSLWebSearchVisit? {
        visits.last
    }

    private var domainVisits: [CPSLWebSearchVisit] {
        var seenDomains = Set<String>()
        var uniqueVisits: [CPSLWebSearchVisit] = []
        for visit in visits {
            let domain = Self.domainKey(for: visit)
            guard seenDomains.insert(domain).inserted else {
                continue
            }
            uniqueVisits.append(visit)
        }
        return uniqueVisits
    }

    var body: some View {
        Button {
            openBrowser(latestVisit?.browserID)
        } label: {
            HStack(spacing: CPSLTheme.small) {
                Image(systemName: "magnifyingglass")
                    .font(CPSLTheme.iconSmallFont)
                    .foregroundStyle(CPSLTheme.success)
                    .frame(width: CPSLTheme.large, height: CPSLTheme.large)

                Text("Web search")
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(1)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(domainVisits) { visit in
                            CPSLWebSearchFavicon(visit: visit)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: CPSLTheme.large, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(latestVisit?.url ?? "Open browser")
    }

    private static func domainKey(for visit: CPSLWebSearchVisit) -> String {
        let rawHost = URL(string: visit.url)?.host ?? visit.host
        let lowercasedHost = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowercasedHost.hasPrefix("www.")
            ? String(lowercasedHost.dropFirst(4))
            : lowercasedHost
    }
}

private struct CPSLWebSearchFavicon: View {
    let visit: CPSLWebSearchVisit

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.34))

            if let faviconURL = visit.faviconURL,
               let url = URL(string: faviconURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(3)
                    default:
                        fallbackIcon
                    }
                }
            } else {
                fallbackIcon
            }
        }
        .frame(width: 22, height: 22)
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(CPSLTheme.text.opacity(0.07), lineWidth: 1)
        )
        .help(visit.title.isEmpty ? visit.host : visit.title)
    }

    private var fallbackIcon: some View {
        Text(String(visit.host.prefix(1)).uppercased())
            .font(CPSLTheme.captionMediumFont)
            .foregroundStyle(CPSLTheme.secondaryText)
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

            CPSLSelectableText(
                text.isEmpty ? "(empty)" : text,
                style: .monospacedBody,
                foreground: CPSLTheme.text,
                fillsAvailableWidth: true,
                lineSpacing: 0
            )
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
    let openFilePath: (String) -> Void

    var body: some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            CPSLSelectableText(
                text,
                style: .body,
                foreground: foreground,
                fillsAvailableWidth: fillsAvailableWidth,
                lineSpacing: CPSLTheme.bodyLineSpacing,
                parsesBlockMarkdown: true,
                openFilePath: openFilePath
            )
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

enum CPSLSelectableTextStyle: Equatable {
    case body
    case monospacedBody
    case supporting
    case caption
    case captionMedium
    case heading
    case heading1
    case heading2
    case heading3

    var swiftUIFont: Font {
        switch self {
        case .body:
            return CPSLTheme.bodyFont
        case .monospacedBody:
            return CPSLTheme.monospacedBodyFont
        case .supporting:
            return CPSLTheme.supportingFont
        case .caption:
            return CPSLTheme.captionFont
        case .captionMedium:
            return CPSLTheme.captionMediumFont
        case .heading:
            return CPSLTheme.userFont(size: CPSLTheme.FontSize.body, weight: .semibold)
        case .heading1:
            return CPSLTheme.headerFont
        case .heading2:
            return CPSLTheme.userFont(size: 19, weight: .semibold)
        case .heading3:
            return CPSLTheme.userFont(size: 17, weight: .semibold)
        }
    }

#if canImport(UIKit)
    var uiFont: UIFont {
        switch self {
        case .body:
            return .systemFont(ofSize: CPSLTheme.FontSize.body)
        case .monospacedBody:
            return .monospacedSystemFont(ofSize: CPSLTheme.FontSize.monospaceBody, weight: .regular)
        case .supporting:
            return .systemFont(ofSize: CPSLTheme.FontSize.supporting)
        case .caption:
            return .systemFont(ofSize: CPSLTheme.FontSize.caption)
        case .captionMedium:
            return .systemFont(ofSize: CPSLTheme.FontSize.caption, weight: .medium)
        case .heading:
            return .systemFont(ofSize: CPSLTheme.FontSize.body, weight: .semibold)
        case .heading1:
            return .systemFont(ofSize: CPSLTheme.FontSize.title, weight: .semibold)
        case .heading2:
            return .systemFont(ofSize: 19, weight: .semibold)
        case .heading3:
            return .systemFont(ofSize: 17, weight: .semibold)
        }
    }
#endif

#if os(macOS)
    var nsFont: NSFont {
        switch self {
        case .body:
            return .systemFont(ofSize: CPSLTheme.FontSize.body)
        case .monospacedBody:
            return .monospacedSystemFont(ofSize: CPSLTheme.FontSize.monospaceBody, weight: .regular)
        case .supporting:
            return .systemFont(ofSize: CPSLTheme.FontSize.supporting)
        case .caption:
            return .systemFont(ofSize: CPSLTheme.FontSize.caption)
        case .captionMedium:
            return .systemFont(ofSize: CPSLTheme.FontSize.caption, weight: .medium)
        case .heading:
            return .systemFont(ofSize: CPSLTheme.FontSize.body, weight: .semibold)
        case .heading1:
            return .systemFont(ofSize: CPSLTheme.FontSize.title, weight: .semibold)
        case .heading2:
            return .systemFont(ofSize: 19, weight: .semibold)
        case .heading3:
            return .systemFont(ofSize: 17, weight: .semibold)
        }
    }
#endif
}

struct CPSLSelectableText: View {
    let text: String
    let style: CPSLSelectableTextStyle
    let foreground: Color
    let fillsAvailableWidth: Bool
    let lineSpacing: CGFloat
    let markdownMode: CPSLSelectableTextMarkdownMode
    let openFilePath: (String) -> Void

    init(
        _ text: String,
        style: CPSLSelectableTextStyle,
        foreground: Color,
        fillsAvailableWidth: Bool,
        lineSpacing: CGFloat = CPSLTheme.bodyLineSpacing,
        parsesInlineMarkdown: Bool = false,
        parsesBlockMarkdown: Bool = false,
        openFilePath: @escaping (String) -> Void = { _ in }
    ) {
        self.text = text
        self.style = style
        self.foreground = foreground
        self.fillsAvailableWidth = fillsAvailableWidth
        self.lineSpacing = lineSpacing
        markdownMode = parsesBlockMarkdown ? .block : (parsesInlineMarkdown ? .inline : .none)
        self.openFilePath = openFilePath
    }

    var body: some View {
#if canImport(UIKit)
        CPSLSelectableUITextView(
            text: text,
            style: style,
            foreground: foreground,
            fillsAvailableWidth: fillsAvailableWidth,
            lineSpacing: lineSpacing,
            markdownMode: markdownMode,
            openFilePath: openFilePath
        )
#elseif os(macOS)
        CPSLSelectableNSTextView(
            text: text,
            style: style,
            foreground: foreground,
            fillsAvailableWidth: fillsAvailableWidth,
            lineSpacing: lineSpacing,
            markdownMode: markdownMode,
            openFilePath: openFilePath
        )
#else
        fallbackText
#endif
    }

    private var fallbackText: some View {
        renderedFallbackText
            .font(style.swiftUIFont)
            .foregroundStyle(foreground)
            .lineSpacing(lineSpacing)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
            .textSelection(.enabled)
    }

    private var renderedFallbackText: Text {
        guard markdownMode != .none,
              let attributedText = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
              )
        else {
            return Text(text)
        }

        return Text(attributedText)
    }
}

enum CPSLSelectableTextMarkdownMode: Equatable {
    case none
    case inline
    case block
}

private struct CPSLSelectableTextRenderKey: Equatable {
    let text: String
    let style: CPSLSelectableTextStyle
    let foregroundDescription: String
    let lineSpacing: CGFloat
    let markdownMode: CPSLSelectableTextMarkdownMode
}

private struct CPSLSelectableTextSizeKey: Equatable {
    let renderKey: CPSLSelectableTextRenderKey
    let width: CGFloat
    let fillsAvailableWidth: Bool
}

private final class CPSLSelectableTextRenderCache {
    private var renderKey: CPSLSelectableTextRenderKey?
    private var renderedText: NSAttributedString?
    private var sizeKey: CPSLSelectableTextSizeKey?
    private var measuredSize: CGSize?

    func attributedText(
        for key: CPSLSelectableTextRenderKey,
        make: () -> NSAttributedString
    ) -> NSAttributedString {
        if renderKey == key, let renderedText {
            return renderedText
        }

        let nextText = make()
        renderKey = key
        renderedText = nextText
        sizeKey = nil
        measuredSize = nil
        return nextText
    }

    func size(for key: CPSLSelectableTextSizeKey) -> CGSize? {
        sizeKey == key ? measuredSize : nil
    }

    func cache(size: CGSize, for key: CPSLSelectableTextSizeKey) {
        sizeKey = key
        measuredSize = size
    }
}

private func normalizedSelectableTextMeasurementWidth(_ width: CGFloat) -> CGFloat {
    max(1, (width * 2).rounded(.toNearestOrAwayFromZero) / 2)
}

private struct CPSLSelectableTextRun {
    var text: String
    var style: CPSLSelectableTextStyle?
    var isBold = false
    var isItalic = false
    var isCode = false
    var isCodeBlock = false
    var isLink = false
    var linkURL: URL?
    var paragraphSpacingBefore: CGFloat = 0
    var paragraphSpacingAfter: CGFloat = 0

    func applying(
        style: CPSLSelectableTextStyle? = nil,
        bold: Bool = false,
        italic: Bool = false,
        code: Bool = false,
        codeBlock: Bool = false,
        link: Bool = false,
        linkURL: URL? = nil,
        paragraphSpacingBefore: CGFloat? = nil,
        paragraphSpacingAfter: CGFloat? = nil
    ) -> Self {
        var run = self
        run.style = style ?? run.style
        run.isBold = run.isBold || bold
        run.isItalic = run.isItalic || italic
        run.isCode = run.isCode || code
        run.isCodeBlock = run.isCodeBlock || codeBlock
        run.isLink = run.isLink || link
        run.linkURL = linkURL ?? run.linkURL
        run.paragraphSpacingBefore = paragraphSpacingBefore ?? run.paragraphSpacingBefore
        run.paragraphSpacingAfter = paragraphSpacingAfter ?? run.paragraphSpacingAfter
        return run
    }
}

private enum CPSLDiscussionPathLinks {
    private static let linkScheme = "herm-file"

    static func runs(from runs: [CPSLSelectableTextRun]) -> [CPSLSelectableTextRun] {
        runs.flatMap { run in
            linkified(run)
        }
    }

    static func filePath(from url: URL) -> String? {
        guard url.scheme == linkScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "open"
        else {
            return nil
        }
        return components.queryItems?.first { $0.name == "path" }?.value
    }

    private static func linkified(_ run: CPSLSelectableTextRun) -> [CPSLSelectableTextRun] {
        guard !run.isCodeBlock else {
            return [run]
        }

        let text = run.text
        var output: [CPSLSelectableTextRun] = []
        var cursor = text.startIndex

        while let match = nextMatch(in: text, from: cursor) {
            if cursor < match.range.lowerBound {
                output.append(run.applying().withText(String(text[cursor..<match.range.lowerBound])))
            }

            if let url = fileURL(for: match.path) {
                output.append(
                    run
                        .applying(link: true, linkURL: url)
                        .withText(displayPath(for: match.path) + match.lineSuffix)
                )
            } else {
                output.append(run.applying().withText(String(text[match.range])))
            }
            cursor = match.range.upperBound
        }

        if cursor < text.endIndex {
            output.append(run.applying().withText(String(text[cursor..<text.endIndex])))
        }
        return output.isEmpty ? [run] : output
    }

    private static func nextMatch(
        in text: String,
        from cursor: String.Index
    ) -> (range: Range<String.Index>, path: String, lineSuffix: String)? {
        let prefixes = ["/attachments", "/home/herm", "/tmp", "~/"]
        var best: (range: Range<String.Index>, prefix: String)?

        for prefix in prefixes {
            guard let range = text.range(of: prefix, range: cursor..<text.endIndex),
                  isValidStart(in: text, range: range, prefix: prefix)
            else {
                continue
            }
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = (range, prefix)
            }
        }

        guard let best else {
            return nil
        }

        let rawEnd = candidateEnd(in: text, from: best.range.lowerBound)
        let trimmedEnd = trimmingTrailingPunctuation(in: text, range: best.range.lowerBound..<rawEnd)
        guard best.range.lowerBound < trimmedEnd else {
            return nil
        }

        let rawCandidate = String(text[best.range.lowerBound..<trimmedEnd])
        let normalized = normalizedPathAndLineSuffix(rawCandidate)
        guard isAllowedPath(normalized.path) else {
            let nextCursor = text.index(after: best.range.lowerBound)
            return nextMatch(in: text, from: nextCursor)
        }

        return (
            range: best.range.lowerBound..<trimmedEnd,
            path: normalized.path,
            lineSuffix: normalized.lineSuffix
        )
    }

    private static func isValidStart(
        in text: String,
        range: Range<String.Index>,
        prefix: String
    ) -> Bool {
        if range.lowerBound > text.startIndex {
            let previous = text[text.index(before: range.lowerBound)]
            if previous.isLetter || previous.isNumber || previous == "_" || previous == "/" {
                return false
            }
        }

        if prefix == "/attachments" || prefix == "/home/herm" || prefix == "/tmp" {
            guard range.upperBound == text.endIndex || text[range.upperBound] == "/" else {
                return false
            }
        }
        return true
    }

    private static func candidateEnd(in text: String, from start: String.Index) -> String.Index {
        var cursor = start
        while cursor < text.endIndex {
            let character = text[cursor]
            if character.isWhitespace || "\"'`<>".contains(character) {
                break
            }
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    private static func trimmingTrailingPunctuation(
        in text: String,
        range: Range<String.Index>
    ) -> String.Index {
        var end = range.upperBound
        while end > range.lowerBound {
            let character = text[text.index(before: end)]
            if ".,;!?)]}".contains(character) {
                end = text.index(before: end)
            } else {
                break
            }
        }
        return end
    }

    private static func normalizedPathAndLineSuffix(_ rawPath: String) -> (path: String, lineSuffix: String) {
        let virtualPath = rawPath.hasPrefix("~/")
            ? CPSLVirtualPath.home + String(rawPath.dropFirst())
            : rawPath
        var parts = virtualPath.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var suffixParts: [String] = []
        while parts.count > 1, let last = parts.last, last.allSatisfy(\.isNumber) {
            suffixParts.insert(last, at: 0)
            parts.removeLast()
            if suffixParts.count == 2 {
                break
            }
        }
        let suffix = suffixParts.isEmpty ? "" : ":" + suffixParts.joined(separator: ":")
        return (parts.joined(separator: ":"), suffix)
    }

    private static func isAllowedPath(_ path: String) -> Bool {
        path == CPSLVirtualPath.attachments ||
            path.hasPrefix("\(CPSLVirtualPath.attachments)/") ||
            path == CPSLVirtualPath.home ||
            path.hasPrefix("\(CPSLVirtualPath.home)/") ||
            path == CPSLVirtualPath.temporary ||
            path.hasPrefix("\(CPSLVirtualPath.temporary)/")
    }

    private static func displayPath(for path: String) -> String {
        if path == CPSLVirtualPath.home {
            return "Home"
        }
        if path.hasPrefix("\(CPSLVirtualPath.home)/") {
            return String(path.dropFirst(CPSLVirtualPath.home.count + 1))
        }
        return path
    }

    private static func fileURL(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = linkScheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url
    }
}

private extension CPSLSelectableTextRun {
    func withText(_ text: String) -> Self {
        var run = self
        run.text = text
        return run
    }
}

private enum CPSLInlineMarkdownRuns {
    static func runs(
        from text: String,
        markdownMode: CPSLSelectableTextMarkdownMode,
        baseStyle: CPSLSelectableTextStyle
    ) -> [CPSLSelectableTextRun] {
        switch markdownMode {
        case .none:
            return [CPSLSelectableTextRun(text: text, style: baseStyle)]
        case .inline:
            return parse(text).map { $0.applying(style: baseStyle) }
        case .block:
            return CPSLBlockMarkdownRuns.runs(from: text, baseStyle: baseStyle)
        }
    }

    private static func parse(_ text: String) -> [CPSLSelectableTextRun] {
        var runs: [CPSLSelectableTextRun] = []
        var cursor = text.startIndex
        var plain = ""

        func flushPlain() {
            guard !plain.isEmpty else {
                return
            }
            runs.append(CPSLSelectableTextRun(text: plain))
            plain.removeAll(keepingCapacity: true)
        }

        while cursor < text.endIndex {
            if text[cursor] == "`",
               let closing = text[text.index(after: cursor)..<text.endIndex].firstIndex(of: "`") {
                flushPlain()
                let start = text.index(after: cursor)
                runs.append(CPSLSelectableTextRun(text: String(text[start..<closing]), isCode: true))
                cursor = text.index(after: closing)
                continue
            }

            if hasMarker("**", in: text, at: cursor),
               let closing = closingMarker("**", in: text, after: text.index(cursor, offsetBy: 2)) {
                flushPlain()
                let start = text.index(cursor, offsetBy: 2)
                runs.append(contentsOf: parse(String(text[start..<closing])).map { $0.applying(bold: true) })
                cursor = text.index(closing, offsetBy: 2)
                continue
            }

            if hasMarker("__", in: text, at: cursor),
               let closing = closingMarker("__", in: text, after: text.index(cursor, offsetBy: 2)) {
                flushPlain()
                let start = text.index(cursor, offsetBy: 2)
                runs.append(contentsOf: parse(String(text[start..<closing])).map { $0.applying(bold: true) })
                cursor = text.index(closing, offsetBy: 2)
                continue
            }

            if text[cursor] == "*",
               let closing = text[text.index(after: cursor)..<text.endIndex].firstIndex(of: "*") {
                flushPlain()
                let start = text.index(after: cursor)
                runs.append(contentsOf: parse(String(text[start..<closing])).map { $0.applying(italic: true) })
                cursor = text.index(after: closing)
                continue
            }

            if text[cursor] == "_",
               let closing = text[text.index(after: cursor)..<text.endIndex].firstIndex(of: "_") {
                flushPlain()
                let start = text.index(after: cursor)
                runs.append(contentsOf: parse(String(text[start..<closing])).map { $0.applying(italic: true) })
                cursor = text.index(after: closing)
                continue
            }

            if text[cursor] == "[",
               let labelEnd = text[text.index(after: cursor)..<text.endIndex].firstIndex(of: "]") {
                let next = text.index(after: labelEnd)
                if next < text.endIndex,
                   text[next] == "(",
                   let urlEnd = text[text.index(after: next)..<text.endIndex].firstIndex(of: ")") {
                    flushPlain()
                    let labelStart = text.index(after: cursor)
                    runs.append(contentsOf: parse(String(text[labelStart..<labelEnd])).map { $0.applying(link: true) })
                    cursor = text.index(after: urlEnd)
                    continue
                }
            }

            plain.append(text[cursor])
            cursor = text.index(after: cursor)
        }

        flushPlain()
        return runs.isEmpty ? [CPSLSelectableTextRun(text: "")] : runs
    }

    private static func hasMarker(_ marker: String, in text: String, at index: String.Index) -> Bool {
        let end = text.index(index, offsetBy: marker.count, limitedBy: text.endIndex) ?? text.endIndex
        return text[index..<end] == marker
    }

    private static func closingMarker(
        _ marker: String,
        in text: String,
        after start: String.Index
    ) -> String.Index? {
        text.range(of: marker, range: start..<text.endIndex)?.lowerBound
    }
}

private enum CPSLBlockMarkdownRuns {
    static func runs(from text: String, baseStyle: CPSLSelectableTextStyle) -> [CPSLSelectableTextRun] {
        var runs: [CPSLSelectableTextRun] = []
        let blocks = CPSLMarkdownBlock.blocks(from: text)
        for block in blocks {
            appendBlock(block, baseStyle: baseStyle, to: &runs)
        }
        return runs.isEmpty ? [CPSLSelectableTextRun(text: text, style: baseStyle)] : runs
    }

    private static func appendBlock(
        _ block: CPSLMarkdownBlock,
        baseStyle: CPSLSelectableTextStyle,
        to runs: inout [CPSLSelectableTextRun]
    ) {
        if !runs.isEmpty {
            runs.append(CPSLSelectableTextRun(text: "\n\n", style: baseStyle))
        }

        switch block.content {
        case .heading(let level, let text):
            appendInline(text, style: headingStyle(for: level), to: &runs)
        case .paragraph(let lines):
            appendInline(lines.joined(separator: "\n"), style: baseStyle, to: &runs)
        case .unorderedList(let items):
            appendList(
                items: items.map { ("\u{2022}", $0) },
                style: baseStyle,
                to: &runs
            )
        case .orderedList(let items):
            appendList(
                items: items.map { ("\($0.number).", $0.text) },
                style: baseStyle,
                to: &runs
            )
        case .table(let table):
            appendTable(table, style: baseStyle, to: &runs)
        case .codeBlock(let language, let text):
            if let language {
                runs.append(CPSLSelectableTextRun(text: "\(language)\n", style: .captionMedium))
            }
            runs.append(CPSLSelectableTextRun(
                text: text,
                style: .monospacedBody,
                isCode: true,
                isCodeBlock: true
            ))
        }
    }

    private static func appendInline(
        _ text: String,
        style: CPSLSelectableTextStyle,
        to runs: inout [CPSLSelectableTextRun]
    ) {
        runs.append(contentsOf: CPSLInlineMarkdownRuns.runs(
            from: text,
            markdownMode: .inline,
            baseStyle: style
        ))
    }

    private static func appendList(
        items: [(marker: String, text: String)],
        style: CPSLSelectableTextStyle,
        to runs: inout [CPSLSelectableTextRun]
    ) {
        for (index, item) in items.enumerated() {
            if index > 0 {
                runs.append(CPSLSelectableTextRun(text: "\n", style: style))
            }
            runs.append(CPSLSelectableTextRun(text: "\(item.marker) ", style: style))
            appendInline(item.text, style: style, to: &runs)
        }
    }

    private static func appendTable(
        _ table: CPSLMarkdownTable,
        style: CPSLSelectableTextStyle,
        to runs: inout [CPSLSelectableTextRun]
    ) {
        let headers = (0..<table.columnCount).map { table.header(at: $0) }
        runs.append(CPSLSelectableTextRun(text: headers.joined(separator: " | "), style: .captionMedium))
        for row in table.rows {
            runs.append(CPSLSelectableTextRun(text: "\n", style: style))
            let cells = (0..<table.columnCount).map { table.cell(in: row, at: $0) }
            runs.append(CPSLSelectableTextRun(text: cells.joined(separator: " | "), style: .caption))
        }
    }

    private static func headingStyle(for level: Int) -> CPSLSelectableTextStyle {
        switch level {
        case 1:
            return .heading1
        case 2:
            return .heading2
        case 3:
            return .heading3
        default:
            return .heading
        }
    }
}

#if canImport(UIKit)
private struct CPSLSelectableUITextView: UIViewRepresentable {
    let text: String
    let style: CPSLSelectableTextStyle
    let foreground: Color
    let fillsAvailableWidth: Bool
    let lineSpacing: CGFloat
    let markdownMode: CPSLSelectableTextMarkdownMode
    let openFilePath: (String) -> Void

    private var renderKey: CPSLSelectableTextRenderKey {
        CPSLSelectableTextRenderKey(
            text: text,
            style: style,
            foregroundDescription: String(describing: foreground),
            lineSpacing: lineSpacing,
            markdownMode: markdownMode
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(openFilePath: openFilePath)
    }

    func makeUIView(context: Context) -> CPSLNativeSelectableUITextView {
        let textView = CPSLNativeSelectableUITextView()
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.panGestureRecognizer.isEnabled = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: CPSLNativeSelectableUITextView, context: Context) {
        context.coordinator.openFilePath = openFilePath
        let nextText = context.coordinator.attributedText(for: self)
        setAttributedText(nextText, on: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView textView: CPSLNativeSelectableUITextView,
        context: Context
    ) -> CGSize? {
        let nextText = context.coordinator.attributedText(for: self)
        setAttributedText(nextText, on: textView)
        let proposedWidth = proposal.width ?? textView.bounds.width
        let rawWidth = proposedWidth > 0 ? proposedWidth : CPSLTheme.framedMessageMaxWidth
        let width = normalizedSelectableTextMeasurementWidth(rawWidth)
        let sizeKey = CPSLSelectableTextSizeKey(
            renderKey: renderKey,
            width: width,
            fillsAvailableWidth: fillsAvailableWidth
        )
        if let cachedSize = context.coordinator.size(for: sizeKey) {
            return cachedSize
        }

        let size = textView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        let measuredSize = CGSize(
            width: fillsAvailableWidth ? width : min(size.width, width),
            height: ceil(size.height)
        )
        context.coordinator.cache(size: measuredSize, for: sizeKey)
        return measuredSize
    }

    private func makeAttributedText() -> NSAttributedString {
        let attributedText = NSMutableAttributedString()
        let runs = CPSLInlineMarkdownRuns.runs(
            from: text,
            markdownMode: markdownMode,
            baseStyle: style
        )
        for run in CPSLDiscussionPathLinks.runs(from: runs) {
            attributedText.append(NSAttributedString(string: run.text, attributes: attributes(for: run)))
        }
        return attributedText
    }

    private func setAttributedText(_ nextText: NSAttributedString, on textView: UITextView) {
        if textView.attributedText?.isEqual(to: nextText) != true {
            textView.attributedText = nextText
        }
    }

    private func attributes(for run: CPSLSelectableTextRun) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacingBefore = run.paragraphSpacingBefore
        paragraphStyle.paragraphSpacing = run.paragraphSpacingAfter
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: run),
            .foregroundColor: UIColor(foreground),
            .paragraphStyle: paragraphStyle,
            .underlineStyle: run.isLink ? NSUnderlineStyle.single.rawValue : 0,
            .backgroundColor: run.isCodeBlock ? UIColor(CPSLTheme.command) : UIColor.clear
        ]
        if let linkURL = run.linkURL {
            attributes[.link] = linkURL
            attributes[.foregroundColor] = UIColor(CPSLTheme.success)
        }
        return attributes
    }

    private func font(for run: CPSLSelectableTextRun) -> UIFont {
        let baseStyle = run.style ?? style
        if run.isCode || baseStyle == .monospacedBody {
            return .monospacedSystemFont(ofSize: baseStyle.uiFont.pointSize, weight: run.isBold ? .semibold : .regular)
        }

        var traits: UIFontDescriptor.SymbolicTraits = []
        if run.isBold {
            traits.insert(.traitBold)
        }
        if run.isItalic {
            traits.insert(.traitItalic)
        }

        guard !traits.isEmpty,
              let descriptor = baseStyle.uiFont.fontDescriptor.withSymbolicTraits(traits)
        else {
            return baseStyle.uiFont
        }
        return UIFont(descriptor: descriptor, size: baseStyle.uiFont.pointSize)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var openFilePath: (String) -> Void
        private let renderCache = CPSLSelectableTextRenderCache()

        init(openFilePath: @escaping (String) -> Void) {
            self.openFilePath = openFilePath
        }

        func attributedText(for view: CPSLSelectableUITextView) -> NSAttributedString {
            renderCache.attributedText(for: view.renderKey) {
                view.makeAttributedText()
            }
        }

        func size(for key: CPSLSelectableTextSizeKey) -> CGSize? {
            renderCache.size(for: key)
        }

        func cache(size: CGSize, for key: CPSLSelectableTextSizeKey) {
            renderCache.cache(size: size, for: key)
        }

        @available(iOS 17.0, macCatalyst 17.0, *)
        func textView(
            _ textView: UITextView,
            primaryActionFor textItem: UITextItem,
            defaultAction: UIAction
        ) -> UIAction? {
            guard case .link(let url) = textItem.content,
                  let path = CPSLDiscussionPathLinks.filePath(from: url)
            else {
                return defaultAction
            }
            return UIAction { [weak self] _ in
                self?.openFilePath(path)
            }
        }

    }
}

private final class CPSLNativeSelectableUITextView: UITextView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            CPSLTransientInteractionReset.unregisterSelectableTextView(self)
        } else {
            CPSLTransientInteractionReset.registerSelectableTextView(self)
        }
    }

    deinit {
        CPSLTransientInteractionReset.unregisterSelectableTextView(self)
    }
}
#endif

#if os(macOS)
private struct CPSLSelectableNSTextView: NSViewRepresentable {
    let text: String
    let style: CPSLSelectableTextStyle
    let foreground: Color
    let fillsAvailableWidth: Bool
    let lineSpacing: CGFloat
    let markdownMode: CPSLSelectableTextMarkdownMode
    let openFilePath: (String) -> Void

    private var renderKey: CPSLSelectableTextRenderKey {
        CPSLSelectableTextRenderKey(
            text: text,
            style: style,
            foregroundDescription: String(describing: foreground),
            lineSpacing: lineSpacing,
            markdownMode: markdownMode
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(openFilePath: openFilePath)
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.delegate = context.coordinator
        CPSLTransientInteractionReset.registerSelectableTextView(textView)
        return textView
    }

    static func dismantleNSView(_ textView: NSTextView, coordinator: Coordinator) {
        CPSLTransientInteractionReset.unregisterSelectableTextView(textView)
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.openFilePath = openFilePath
        let nextText = context.coordinator.attributedText(for: self)
        if !textView.attributedString().isEqual(to: nextText) {
            textView.textStorage?.setAttributedString(nextText)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        let nextText = context.coordinator.attributedText(for: self)
        if !textView.attributedString().isEqual(to: nextText) {
            textView.textStorage?.setAttributedString(nextText)
        }
        let width = normalizedSelectableTextMeasurementWidth(
            proposal.width ?? CPSLTheme.framedMessageMaxWidth
        )
        let sizeKey = CPSLSelectableTextSizeKey(
            renderKey: renderKey,
            width: width,
            fillsAvailableWidth: fillsAvailableWidth
        )
        if let cachedSize = context.coordinator.size(for: sizeKey) {
            return cachedSize
        }

        textView.textContainer?.containerSize = CGSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        if let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let rect = layoutManager.usedRect(for: textContainer)
            let measuredSize = CGSize(
                width: fillsAvailableWidth ? width : min(ceil(rect.width), width),
                height: ceil(rect.height)
            )
            context.coordinator.cache(size: measuredSize, for: sizeKey)
            return measuredSize
        }
        return nil
    }

    private func makeAttributedText() -> NSAttributedString {
        let attributedText = NSMutableAttributedString()
        let runs = CPSLInlineMarkdownRuns.runs(
            from: text,
            markdownMode: markdownMode,
            baseStyle: style
        )
        for run in CPSLDiscussionPathLinks.runs(from: runs) {
            attributedText.append(NSAttributedString(string: run.text, attributes: attributes(for: run)))
        }
        return attributedText
    }

    private func attributes(for run: CPSLSelectableTextRun) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacingBefore = run.paragraphSpacingBefore
        paragraphStyle.paragraphSpacing = run.paragraphSpacingAfter
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: run),
            .foregroundColor: NSColor(foreground),
            .paragraphStyle: paragraphStyle,
            .underlineStyle: run.isLink ? NSUnderlineStyle.single.rawValue : 0,
            .backgroundColor: run.isCodeBlock ? NSColor(CPSLTheme.command) : NSColor.clear
        ]
        if let linkURL = run.linkURL {
            attributes[.link] = linkURL
            attributes[.foregroundColor] = NSColor(CPSLTheme.success)
        }
        return attributes
    }

    private func font(for run: CPSLSelectableTextRun) -> NSFont {
        let baseStyle = run.style ?? style
        if run.isCode || baseStyle == .monospacedBody {
            return .monospacedSystemFont(ofSize: baseStyle.nsFont.pointSize, weight: run.isBold ? .semibold : .regular)
        }

        var font = baseStyle.nsFont
        if run.isBold {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        if run.isItalic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openFilePath: (String) -> Void
        private let renderCache = CPSLSelectableTextRenderCache()

        init(openFilePath: @escaping (String) -> Void) {
            self.openFilePath = openFilePath
        }

        func attributedText(for view: CPSLSelectableNSTextView) -> NSAttributedString {
            renderCache.attributedText(for: view.renderKey) {
                view.makeAttributedText()
            }
        }

        func size(for key: CPSLSelectableTextSizeKey) -> CGSize? {
            renderCache.size(for: key)
        }

        func cache(size: CGSize, for key: CPSLSelectableTextSizeKey) {
            renderCache.cache(size: size, for: key)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL,
                  let path = CPSLDiscussionPathLinks.filePath(from: url)
            else {
                return false
            }
            openFilePath(path)
            return true
        }
    }
}
#endif
