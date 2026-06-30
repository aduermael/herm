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
                .padding(.top, topInset + CPSLTheme.messageVerticalSpacing)
                .padding(.bottom, bottomInset + CPSLTheme.messageVerticalSpacing)
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
        } else {
            Text(message.body)
                .font(message.role.usesMonospaceBody ? CPSLTheme.monospacedBodyFont : CPSLTheme.bodyFont)
                .foregroundStyle(message.role.foreground)
                .lineSpacing(message.role.usesMonospaceBody ? 0 : CPSLTheme.bodyLineSpacing)
                .textSelection(.enabled)
        }
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
