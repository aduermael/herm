import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

    @State private var showsTagFilter = false
    @State private var tagSheetConversationID: String?
    @State private var renamingConversation: CPSLConversationSummary?
    @State private var renameText = ""
    @State private var keyboardOverlap: CGFloat = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        let activeTags = model.allTags.filter { model.activeTagIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            CPSLDrawerToolbar(
                title: model.showingArchived ? "Archived" : "Conversations",
                isBusy: model.isBusy,
                isArchivedScope: model.showingArchived,
                onBack: { searchFocused = false; model.closeDrawer() },
                onNewChat: { searchFocused = false; model.startNewConversation() },
                onToggleArchived: { searchFocused = false; model.setArchivedScope(!model.showingArchived) }
            )
            .padding(.horizontal, CPSLTheme.medium)
            .padding(.bottom, CPSLTheme.small)

            CPSLConversationListView(
                model: model,
                tagSheetConversationID: $tagSheetConversationID,
                renamingConversation: $renamingConversation
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Kept as a stable sibling (not a .safeAreaInset on the list): the
            // list swaps between its populated and empty subtrees while typing,
            // and hanging the search field off that swap would drop first
            // responder and dismiss the keyboard.
            CPSLConversationSearchDock(
                text: $model.searchText,
                activeTags: activeTags,
                hasActiveFilter: !model.activeTagIDs.isEmpty,
                searchFocused: $searchFocused,
                onFilter: { searchFocused = false; showsTagFilter = true },
                onRemoveTag: { model.toggleActiveTag($0) }
            )
        }
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = false }
        .padding(.top, topInset)
        .padding(.bottom, keyboardOverlap > 0 ? keyboardOverlap + CPSLTheme.small : bottomInset)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .modifier(CPSLKeyboardHeightModifier(height: $keyboardOverlap, isActive: searchFocused))
        .alert("Rename conversation", isPresented: Binding(
            get: { renamingConversation != nil },
            set: { if !$0 { renamingConversation = nil } }
        ), presenting: renamingConversation) { conversation in
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renamingConversation = nil }
            Button("Save") {
                model.renameConversation(id: conversation.id, title: renameText)
                renamingConversation = nil
            }
        } message: { _ in EmptyView() }
        .onChange(of: renamingConversation?.id) { _, _ in
            renameText = renamingConversation?.title ?? ""
        }
        .animation(.easeOut(duration: 0.2), value: model.activeTagIDs)
        .animation(.easeOut(duration: 0.2), value: model.showingArchived)
        .sheet(isPresented: $showsTagFilter) {
            CPSLTagFilterSheet(model: model)
        }
        .sheet(item: Binding(
            get: { tagSheetConversationID.map { CPSLIdentifiedString(id: $0) } },
            set: { tagSheetConversationID = $0?.id }
        )) { wrapper in
            CPSLTagAssignmentSheet(model: model, conversationID: wrapper.id)
        }
    }
}

private struct CPSLIdentifiedString: Identifiable { let id: String }

/// Lifts bottom-anchored chrome above the keyboard. SwiftUI's automatic
/// keyboard avoidance is suppressed by the drawer's root GeometryReader, so
/// the overlap is tracked manually and matched to the keyboard's own timing.
private struct CPSLKeyboardHeightModifier: ViewModifier {
    @Binding var height: CGFloat
    let isActive: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                // Keyboard notifications are global: ignore the ones raised by
                // text fields in presented sheets so the dock only lifts for our
                // own search field.
                guard isActive else { return }
                let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                withAnimation(.easeOut(duration: duration)) { height = frame?.height ?? 0 }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
                withAnimation(.easeOut(duration: duration)) { height = 0 }
            }
        #else
        content
        #endif
    }
}

private struct CPSLConversationSearchDock: View {
    @Binding var text: String
    let activeTags: [CPSLTag]
    let hasActiveFilter: Bool
    @FocusState.Binding var searchFocused: Bool
    let onFilter: () -> Void
    let onRemoveTag: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            if !activeTags.isEmpty {
                CPSLFlowLayout(spacing: CPSLTheme.small, lineSpacing: CPSLTheme.small) {
                    ForEach(activeTags) { tag in
                        Button { onRemoveTag(tag.id) } label: {
                            HStack(spacing: CPSLTheme.small / 2) {
                                Circle().fill(CPSLTagPalette.color(for: tag.color)).frame(width: 7, height: 7)
                                Text(tag.name).font(CPSLTheme.captionMediumFont).foregroundStyle(CPSLTheme.text)
                                Image(systemName: "xmark").font(CPSLTheme.iconSmallFont).foregroundStyle(CPSLTheme.secondaryText)
                            }
                            .padding(.horizontal, CPSLTheme.small)
                            .padding(.vertical, CPSLTheme.small / 2)
                            .background(Capsule().fill(CPSLTagPalette.color(for: tag.color).opacity(0.14)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove filter \(tag.name)")
                    }
                }
                .transition(.opacity)
            }

            CPSLConversationSearchBar(text: $text, focused: $searchFocused, onFilter: onFilter, hasActiveFilter: hasActiveFilter)
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.top, CPSLTheme.small)
    }
}

private struct CPSLConversationSearchBar: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    let onFilter: () -> Void
    let hasActiveFilter: Bool

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            Image(systemName: "magnifyingglass")
                .font(CPSLTheme.iconSmallFont)
                .foregroundStyle(CPSLTheme.secondaryText)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(CPSLTheme.supportingFont)
                .foregroundStyle(CPSLTheme.text)
                .focused($focused)
            Button(action: onFilter) {
                Image(systemName: hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(CPSLTheme.iconMediumFont)
                    .foregroundStyle(hasActiveFilter ? CPSLTheme.mauve : CPSLTheme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, CPSLTheme.medium)
        .frame(height: CPSLTheme.controlSize)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.elevated, opacity: 0.44),
            strokeOpacity: 0.06
        )
    }
}

private struct CPSLDrawerToolbar: View {
    let title: String
    let isBusy: Bool
    let isArchivedScope: Bool
    let onBack: () -> Void
    let onNewChat: () -> Void
    let onToggleArchived: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            Button(action: onBack) {
                chip("chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to chat")

            Text(title)
                .font(CPSLTheme.userFont(size: CPSLTheme.FontSize.body, weight: .semibold))
                .foregroundStyle(CPSLTheme.text)
                .lineLimit(1)
                .padding(.leading, CPSLTheme.small / 2)

            Spacer(minLength: CPSLTheme.small)

            Button(action: onToggleArchived) {
                chip(isArchivedScope ? "archivebox.fill" : "archivebox", isActive: isArchivedScope)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isArchivedScope ? "Show active conversations" : "Show archived conversations")

            Button(action: onNewChat) {
                chip("square.and.pencil")
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .opacity(isBusy ? 0.45 : 1)
            .accessibilityLabel("New conversation")
        }
        .frame(height: CPSLTheme.controlSize)
    }

    private func chip(_ systemName: String, isActive: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
            .foregroundStyle(isActive ? CPSLTheme.mauve : CPSLTheme.text)
            .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
            .cpslGlassBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
                tint: isActive
                    ? CPSLGlassTuning.tint(CPSLTheme.mauve, opacity: 0.16)
                    : CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.34),
                strokeOpacity: 0.045
            )
            .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLConversationListView: View {
    @ObservedObject var model: CPSLChatModel
    @Binding var tagSheetConversationID: String?
    @Binding var renamingConversation: CPSLConversationSummary?

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty || !model.activeTagIDs.isEmpty
    }

    var body: some View {
        let groups = model.sectionGroups
        if groups.isEmpty {
            emptyState
        } else {
            list(groups)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching {
            CPSLDrawerEmptyState(
                art: { CPSLDrawerEmptyArt.logo },
                title: "No matches",
                message: "Try a different search, or clear the filter."
            )
        } else if model.showingArchived {
            CPSLDrawerEmptyState(
                art: { CPSLDrawerEmptyArt.symbol("archivebox") },
                title: "Nothing archived",
                message: "Conversations you archive will show up here."
            )
        } else {
            CPSLDrawerEmptyState(
                art: { CPSLDrawerEmptyArt.logo },
                title: "No conversations yet",
                message: "Start a chat with Herm and it'll appear here.",
                actionTitle: "New conversation",
                isActionDisabled: model.isBusy,
                action: { model.startNewConversation() }
            )
        }
    }

    private func list(_ groups: [CPSLConversationSectionGroup]) -> some View {
        List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.conversations) { conversation in
                            row(for: conversation)
                        }
                    } header: {
                        Text(group.title)
                            .font(CPSLTheme.captionMediumFont)
                            .foregroundStyle(CPSLTheme.secondaryText)
                            .padding(.horizontal, CPSLTheme.medium)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .listRowInsets(EdgeInsets(top: 0, leading: CPSLTheme.medium, bottom: CPSLTheme.small, trailing: CPSLTheme.medium))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
        }
        .listStyle(.plain)
        #if !os(macOS)
        .listSectionSpacing(CPSLTheme.large)
        #endif
        .environment(\.defaultMinListRowHeight, 0)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, CPSLTheme.small, for: .scrollContent)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .background(Color.clear)
    }

    @ViewBuilder
    private func row(for conversation: CPSLConversationSummary) -> some View {
        CPSLConversationRowView(
            title: conversation.title,
            isSelected: conversation.id == model.selectedConversationID
        ) {
            model.selectConversation(id: conversation.id)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                model.deleteConversation(id: conversation.id)
            } label: { Text("Delete") }
            .tint(CPSLTheme.danger)
            .disabled(model.isBusy)

            if model.showingArchived {
                Button {
                    model.unarchiveConversation(id: conversation.id)
                } label: { Text("Unarchive") }
                .tint(CPSLTheme.secondaryText)
            } else {
                Button {
                    model.archiveConversation(id: conversation.id)
                } label: { Text("Archive") }
                .tint(CPSLTheme.secondaryText)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.setPinned(id: conversation.id, pinned: !conversation.pinned)
            } label: { Text(conversation.pinned ? "Unpin" : "Pin") }
            .tint(CPSLTheme.mauve)
        }
        .contextMenu {
            Button { renamingConversation = conversation } label: { Label("Rename", systemImage: "pencil") }
            Button { model.setPinned(id: conversation.id, pinned: !conversation.pinned) } label: {
                Label(conversation.pinned ? "Unpin" : "Pin", systemImage: conversation.pinned ? "pin.slash" : "pin")
            }
            Button { tagSheetConversationID = conversation.id } label: { Label("Tags…", systemImage: "tag") }
            if model.showingArchived {
                Button { model.unarchiveConversation(id: conversation.id) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
            } else {
                Button { model.archiveConversation(id: conversation.id) } label: { Label("Archive", systemImage: "archivebox") }
            }
            Button(role: .destructive) { model.deleteConversation(id: conversation.id) } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.isBusy)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

private enum CPSLDrawerEmptyArt {
    static var logo: some View {
        Image("herm")
            .resizable()
            .scaledToFit()
            .frame(width: 104, height: 104)
    }

    static func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(CPSLTheme.emptyStateIconFont)
            .foregroundStyle(CPSLTheme.mauve.opacity(0.30))
    }
}

private struct CPSLDrawerEmptyState<Art: View>: View {
    @ViewBuilder let art: () -> Art
    let title: String
    let message: String
    var actionTitle: String? = nil
    var isActionDisabled: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: CPSLTheme.large) {
            art()

            VStack(spacing: CPSLTheme.small) {
                Text(title)
                    .font(CPSLTheme.headerFont)
                    .foregroundStyle(CPSLTheme.text)
                Text(message)
                    .font(CPSLTheme.supportingFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 280)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(CPSLTheme.controlFont)
                        .foregroundStyle(CPSLTheme.text)
                        .padding(.horizontal, CPSLTheme.large)
                        .frame(height: CPSLTheme.controlSize)
                        .cpslGlassBackground(
                            in: Capsule(),
                            tint: CPSLGlassTuning.tint(CPSLTheme.mauve, opacity: 0.18),
                            strokeOpacity: 0.06
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isActionDisabled)
                .opacity(isActionDisabled ? 0.45 : 1)
                .padding(.top, CPSLTheme.small)
            }
        }
        .padding(.horizontal, CPSLTheme.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CPSLConversationRowView: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(CPSLTheme.supportingMediumFont)
                .foregroundStyle(CPSLTheme.text)
                .lineLimit(2)
                .padding(.horizontal, CPSLTheme.medium)
                .padding(.vertical, CPSLTheme.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? CPSLTheme.elevated : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.vertical, 2)
    }
}
