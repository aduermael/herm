import SwiftUI

struct CPSLConversationDrawerView: View {
    @ObservedObject var model: CPSLChatModel
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                CPSLConversationDrawerPanel(
                    model: model,
                    width: min(proxy.size.width * 0.82, 340),
                    topInset: topInset,
                    bottomInset: bottomInset
                )

                Color.black.opacity(0.26)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.closeDrawer()
                    }
            }
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }
}

private struct CPSLConversationDrawerPanel: View {
    @ObservedObject var model: CPSLChatModel
    let width: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.medium) {
            CPSLDrawerHeader(model: model)

            Button {
                model.startNewConversation()
            } label: {
                Label("New conversation", systemImage: "square.and.pencil")
                    .font(CPSLTheme.controlFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CPSLTheme.medium)
                    .frame(height: CPSLTheme.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CPSLTheme.text)
            .disabled(model.isRunning)
            .opacity(model.isRunning ? 0.45 : 1)
            .cpslGlassBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                tint: CPSLGlassTuning.tint(CPSLTheme.elevated, opacity: 0.44),
                strokeOpacity: 0.06
            )

            ScrollView {
                LazyVStack(spacing: CPSLTheme.small) {
                    if model.conversations.isEmpty {
                        Text("No conversations")
                            .font(CPSLTheme.supportingFont)
                            .foregroundStyle(CPSLTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, CPSLTheme.medium)
                    } else {
                        ForEach(model.conversations) { conversation in
                            CPSLConversationRowView(
                                title: conversation.title,
                                updatedAt: conversation.updatedAt,
                                isSelected: conversation.id == model.selectedConversationID
                            ) {
                                model.selectConversation(id: conversation.id)
                            }
                        }
                    }
                }
                .padding(.vertical, CPSLTheme.small)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset + CPSLTheme.medium)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(CPSLTheme.surface)
    }
}

private struct CPSLDrawerHeader: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Text("Conversations")
                .font(CPSLTheme.headerFont)
                .foregroundStyle(CPSLTheme.text)

            Spacer()

            Button {
                model.closeDrawer()
            } label: {
                Image(systemName: "xmark")
                    .font(CPSLTheme.iconSmallFont)
                    .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CPSLTheme.text)
            .accessibilityLabel("Close conversations")
        }
    }
}

private struct CPSLConversationRowView: View {
    let title: String
    let updatedAt: Date
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(updatedAt, style: .relative)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
            }
            .padding(.horizontal, CPSLTheme.medium)
            .padding(.vertical, CPSLTheme.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? CPSLTheme.elevated : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
        .disabled(isSelected)
    }
}
