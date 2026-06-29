import SwiftUI

struct CPSLFileBrowserView: View {
    @ObservedObject var model: CPSLChatModel
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            header
            .padding(.horizontal, CPSLTheme.chromeHorizontalInset)
            .padding(.top, topInset)
            .padding(.bottom, CPSLTheme.medium)

            filePane
                .padding(.horizontal, CPSLTheme.contentHorizontalInset)
                .padding(.bottom, CPSLTheme.medium)
        }
        .padding(.bottom, bottomInset)
    }

    private var isAtRoot: Bool {
        model.browserPath == "/"
    }

    private var header: some View {
        HStack(spacing: CPSLTheme.medium) {
            if !isAtRoot {
                Button {
                    model.navigateToParentDirectory()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.text)
                .cpslGlassBackground(
                    in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                    tint: CPSLTheme.background.opacity(0.36),
                    strokeOpacity: 0.06
                )
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
            }

            pathBadge

            Button {
                model.closeFileBrowser()
            } label: {
                HStack(spacing: CPSLTheme.small) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Close")
                        .font(CPSLTheme.controlFont)
                }
                .lineLimit(1)
                .padding(.horizontal, CPSLTheme.medium)
                .frame(height: CPSLTheme.controlSize)
                .fixedSize(horizontal: true, vertical: false)
                .cpslGlassBackground(
                    in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                    tint: CPSLTheme.background.opacity(0.36),
                    strokeOpacity: 0.06
                )
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(CPSLTheme.text)
            .accessibilityLabel("Close Files")
        }
    }

    private var pathBadge: some View {
        HStack(spacing: CPSLTheme.small) {
            Image(systemName: "folder.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CPSLTheme.mauve)
            Text(model.browserPath)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(CPSLTheme.text)
        }
        .padding(.horizontal, CPSLTheme.medium)
        .frame(height: CPSLTheme.controlSize)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLTheme.elevated.opacity(0.40),
            strokeOpacity: 0.06
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .lineLimit(1)
    }

    private var filePane: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let error = model.fileBrowserError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(CPSLTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(CPSLTheme.medium)
                }

                if model.isLoading(model.browserPath) && model.browserEntries.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CPSLTheme.large)
                } else if model.browserEntries.isEmpty && model.fileBrowserError == nil {
                    Text("Empty")
                        .font(.callout)
                        .foregroundStyle(CPSLTheme.mutedText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CPSLTheme.large)
                } else {
                    CPSLFileRowsView(model: model, entries: model.browserEntries)
                }
            }
            .padding(.vertical, CPSLTheme.small)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
            tint: CPSLTheme.card.opacity(0.62),
            strokeOpacity: 0.045
        )
    }
}

private struct CPSLFileRowsView: View {
    @ObservedObject var model: CPSLChatModel
    let entries: [CPSLFileEntry]

    var body: some View {
        ForEach(entries) { entry in
            CPSLFileRowView(model: model, entry: entry)

            if entry.isDirectory && model.isExpanded(entry) {
                if model.isLoading(entry.path) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading")
                            .font(.caption)
                            .foregroundStyle(CPSLTheme.mutedText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 28)
                    .padding(.vertical, CPSLTheme.small)
                } else {
                    CPSLFileRowsView(
                        model: model,
                        entries: model.children(for: entry.path)
                    )
                }
            }
        }
    }
}

private struct CPSLFileRowView: View {
    @ObservedObject var model: CPSLChatModel
    let entry: CPSLFileEntry

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            disclosureControl

            Button {
                model.openFileEntry(entry)
            } label: {
                HStack(spacing: CPSLTheme.medium) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(entry.isDirectory ? CPSLTheme.mauve : CPSLTheme.secondaryText)
                        .frame(width: 20)

                    Text(entry.name)
                        .font(CPSLTheme.rowTitleFont)
                        .lineLimit(1)
                        .foregroundStyle(CPSLTheme.text)

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.horizontal, CPSLTheme.small)
        .padding(.vertical, CPSLTheme.small)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var disclosureControl: some View {
        if entry.isDirectory {
            Button {
                model.toggleExpansion(for: entry)
            } label: {
                Image(systemName: model.isExpanded(entry) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CPSLTheme.secondaryText)
        } else {
            Color.clear.frame(width: 24, height: 28)
        }
    }
}
