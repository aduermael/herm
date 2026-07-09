import SwiftUI

enum CPSLConversationDrawerLayout {
    static func width(in availableWidth: CGFloat) -> CGFloat {
        availableWidth
    }
}

struct CPSLConversationDrawerView: View {
    @ObservedObject var model: CPSLChatModel
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            CPSLConversationDrawerContent(
                model: model,
                width: CPSLConversationDrawerLayout.width(in: proxy.size.width),
                topInset: topInset,
                bottomInset: bottomInset
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct CPSLConversationDrawerContent: View {
    @ObservedObject var model: CPSLChatModel
    let width: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CPSLDrawerAppHeader()

            Spacer()
                .frame(height: CPSLTheme.medium)

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

            Spacer()
                .frame(height: CPSLTheme.medium)

            CPSLConversationListView(model: model)
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset + CPSLTheme.medium)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CPSLDrawerAppHeader: View {
    var body: some View {
        Text("Herm 🐚")
            .font(CPSLTheme.headerFont)
            .foregroundStyle(CPSLTheme.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: CPSLTheme.controlSize, alignment: .bottom)
    }
}

private struct CPSLConversationListView: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        if model.conversations.isEmpty {
            CPSLEmptyConversationListView()
        } else {
            List {
                ForEach(model.conversations) { conversation in
                    CPSLConversationRowView(
                        title: conversation.title,
                        updatedAt: conversation.updatedAt,
                        isSelected: conversation.id == model.selectedConversationID
                    ) {
                        model.selectConversation(id: conversation.id)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.deleteConversation(id: conversation.id)
                        } label: {
                            Text("Remove")
                        }
                        .tint(CPSLTheme.danger)
                        .disabled(model.isRunning)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
    }
}

private struct CPSLEmptyConversationListView: View {
    var body: some View {
        Text("No conversations")
            .font(CPSLTheme.supportingFont)
            .foregroundStyle(CPSLTheme.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, CPSLTheme.medium)
    }
}

private struct CPSLConversationRowView: View {
    let title: String
    let updatedAt: Date
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(updatedAt, format: .dateTime.month().day().year().hour().minute())
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
    }
}
