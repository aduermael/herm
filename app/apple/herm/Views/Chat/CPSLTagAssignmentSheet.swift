import SwiftUI

struct CPSLTagAssignmentSheet: View {
    let model: CPSLChatModel
    let conversationID: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var newName = ""
    @State private var newColor = CPSLTagPalette.defaultKey
    @State private var loaded = false

    var body: some View {
        CPSLSelfSizingSheet(title: "Assign tags") {
            HStack(spacing: CPSLTheme.small) {
                CPSLSheetChromeButton(title: "Cancel", isProminent: false) { dismiss() }
                CPSLSheetChromeButton(title: "Save") {
                    model.assignTags(conversationID: conversationID, tagIDs: selected)
                    dismiss()
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: CPSLTheme.large) {
                CPSLTagCreateRow(name: $newName, colorKey: $newColor) {
                    let name = newName
                    let color = newColor
                    newName = ""
                    Task {
                        if let tag = await model.createTag(name: name, color: color) {
                            selected.insert(tag.id)
                        }
                    }
                }

                if model.allTags.isEmpty {
                    Text("No tags yet. Create one above to tag this conversation.")
                        .font(CPSLTheme.supportingFont)
                        .foregroundStyle(CPSLTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: CPSLTheme.medium) {
                        Text("Your tags")
                            .font(CPSLTheme.captionMediumFont)
                            .foregroundStyle(CPSLTheme.secondaryText)
                        CPSLFlowLayout {
                            ForEach(model.allTags) { tag in
                                CPSLTagChip(name: tag.name, colorKey: tag.color, isSelected: selected.contains(tag.id))
                                    .onTapGesture {
                                        if selected.contains(tag.id) {
                                            selected.remove(tag.id)
                                        } else {
                                            selected.insert(tag.id)
                                        }
                                    }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityLabel(tag.name)
                            }
                        }
                    }
                }
            }
        }
        .task {
            guard !loaded else { return }
            selected = await model.tagIDs(for: conversationID)
            loaded = true
        }
    }
}
