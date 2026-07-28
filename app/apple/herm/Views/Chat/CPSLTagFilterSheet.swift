import SwiftUI

struct CPSLTagFilterSheet: View {
    let model: CPSLChatModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: CPSLTag?
    @State private var renameText = ""
    @State private var menuTag: CPSLTag?

    var body: some View {
        CPSLSelfSizingSheet(title: "Filter by tags") {
            HStack(spacing: CPSLTheme.small) {
                if !model.activeTagIDs.isEmpty {
                    CPSLSheetChromeButton(title: "Clear", isProminent: false) { model.clearActiveTags() }
                }
                CPSLSheetChromeButton(title: "Done") { dismiss() }
            }
        } content: {
            VStack(alignment: .leading, spacing: CPSLTheme.large) {
                if model.allTags.isEmpty {
                    Text("No tags yet. Tag a conversation to start filtering.")
                        .font(CPSLTheme.supportingFont)
                        .foregroundStyle(CPSLTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    CPSLFlowLayout {
                        ForEach(model.allTags) { tag in
                            CPSLTagChip(name: tag.name, colorKey: tag.color, isSelected: model.activeTagIDs.contains(tag.id))
                                .onTapGesture { model.toggleActiveTag(tag.id) }
                                .onLongPressGesture { menuTag = tag }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityLabel(tag.name)
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            menuTag?.name ?? "Tag",
            isPresented: Binding(
                get: { menuTag != nil },
                set: { if !$0 { menuTag = nil } }
            ),
            titleVisibility: .visible,
            presenting: menuTag
        ) { tag in
            Button("Rename") {
                renameText = tag.name
                renaming = tag
            }
            Button("Delete", role: .destructive) {
                model.deleteTag(id: tag.id)
            }
        }
        .alert("Rename tag", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { tag in
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                model.renameTag(id: tag.id, name: renameText)
                renaming = nil
            }
        }
    }
}
