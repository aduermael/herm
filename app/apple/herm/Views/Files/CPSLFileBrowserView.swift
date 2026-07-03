import Foundation
import SwiftUI

struct CPSLFileBrowserView: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        CPSLFileOverlayPanel {
            CPSLFileBrowserHeader(model: model)
        } content: {
            ZStack {
                if let preview = model.filePreview {
                    CPSLFilePreviewContentView(preview: preview)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    CPSLFileBrowserPane(model: model)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.filePreview?.id)
        }
    }
}

private struct CPSLFileBrowserHeader: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            if model.filePreview != nil || model.canNavigateToParentDirectory {
                CPSLFileOverlayIconButton(
                    systemName: "chevron.left",
                    accessibilityLabel: "Back"
                ) {
                    if model.filePreview != nil {
                        model.closeFilePreview()
                    } else {
                        model.navigateToParentDirectory()
                    }
                }
            }

            if let preview = model.filePreview {
                CPSLFilePreviewHeaderTitle(preview: preview)
            } else {
                CPSLFileBrowserHeaderTitle(path: model.browserPath, isRoot: model.isAtFileBrowserRoot)
            }

            CPSLFileOverlayIconButton(
                systemName: "xmark",
                accessibilityLabel: "Close Files"
            ) {
                model.closeFileBrowser()
            }
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.vertical, CPSLTheme.small)
    }
}

private struct CPSLFilePreviewHeaderTitle: View {
    let preview: CPSLFilePreview

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Image(systemName: iconName)
                .font(CPSLTheme.iconMediumFont)
                .foregroundStyle(CPSLTheme.mauve)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(preview.name)
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(1)

                Text(preview.path)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconName: String {
        switch preview.kind {
        case .pdf:
            return "doc.richtext"
        case .text:
            return "doc.text.fill"
        }
    }
}

private struct CPSLFileBrowserHeaderTitle: View {
    let path: String
    let isRoot: Bool

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Image(systemName: iconName)
                .font(CPSLTheme.iconMediumFont)
                .foregroundStyle(CPSLTheme.mauve)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(1)

                Text(displaySubtitle)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayTitle: String {
        if path == CPSLVirtualPath.home {
            return "Home"
        }
        if path == CPSLVirtualPath.temporary {
            return "Temporary"
        }
        return isRoot ? "Locations" : path
    }

    private var displaySubtitle: String {
        return isRoot ? "Home and temporary storage" : path
    }

    private var iconName: String {
        if path == CPSLVirtualPath.home {
            return "house.fill"
        }
        if path == CPSLVirtualPath.temporary {
            return "clock.fill"
        }
        return "folder.fill"
    }
}

private struct CPSLFileBrowserPane: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let error = model.fileBrowserError {
                    CPSLFileBrowserErrorView(message: error)
                }

                if model.isAtFileBrowserRoot {
                    CPSLFileLocationsView(model: model)
                } else if model.isLoading(model.browserPath) && model.browserEntries.isEmpty {
                    CPSLFileBrowserLoadingView()
                } else if model.browserEntries.isEmpty && model.fileBrowserError == nil {
                    CPSLFileBrowserEmptyView()
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
    }
}

private struct CPSLFileLocationsView: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        VStack(spacing: 0) {
            CPSLFileLocationRow(
                title: "Home",
                detail: CPSLVirtualPath.home,
                systemName: "house.fill"
            ) {
                model.loadBrowserPath(CPSLVirtualPath.home)
            }

            CPSLFileLocationRow(
                title: "Temporary",
                detail: CPSLVirtualPath.temporary,
                systemName: "clock.fill"
            ) {
                model.loadBrowserPath(CPSLVirtualPath.temporary)
            }

            CPSLCloudConnectionRow(
                title: "iCloud",
                systemName: "icloud.fill",
                accessory: .singleIcon
            ) {
                model.showComingSoon("coming soon")
            }

            CPSLCloudConnectionRow(
                title: "Cloud Drives",
                systemName: "externaldrive.fill",
                accessory: .providerIcons
            ) {
                model.showComingSoon("coming soon")
            }
        }
    }
}

private struct CPSLFileLocationRow: View {
    let title: LocalizedStringKey
    let detail: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CPSLTheme.medium) {
                CPSLFileIcon(systemName: systemName, color: CPSLTheme.mauve)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(CPSLTheme.rowTitleFont)
                        .foregroundStyle(CPSLTheme.text)
                    Text(detail)
                        .font(CPSLTheme.captionFont)
                        .foregroundStyle(CPSLTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(CPSLTheme.iconSmallFont)
                    .foregroundStyle(CPSLTheme.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.vertical, CPSLTheme.small)
    }
}

private enum CPSLCloudAccessory {
    case singleIcon
    case providerIcons
}

private struct CPSLCloudConnectionRow: View {
    let title: LocalizedStringKey
    let systemName: String
    let accessory: CPSLCloudAccessory
    let action: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileIcon(systemName: systemName, color: CPSLTheme.secondaryText)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CPSLTheme.rowTitleFont)
                    .foregroundStyle(CPSLTheme.text)
                cloudAccessory
            }

            Spacer()

            Button("Connect", action: action)
                .font(CPSLTheme.controlFont)
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.text)
                .padding(.horizontal, CPSLTheme.medium)
                .frame(height: CPSLTheme.controlSize)
                .cpslGlassBackground(
                    in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                    tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.34),
                    strokeOpacity: 0.045
                )
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.vertical, CPSLTheme.small)
    }

    @ViewBuilder
    private var cloudAccessory: some View {
        switch accessory {
        case .singleIcon:
            Image(systemName: "icloud")
                .font(CPSLTheme.captionFont)
                .foregroundStyle(CPSLTheme.secondaryText)
        case .providerIcons:
            HStack(spacing: 4) {
                CPSLCloudProviderMark(provider: .googleDrive)
                CPSLCloudProviderMark(provider: .dropbox)
                CPSLCloudProviderMark(provider: .oneDrive)
                Image(systemName: "ellipsis")
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
            }
        }
    }
}

private enum CPSLCloudProvider {
    case googleDrive
    case dropbox
    case oneDrive
}

private struct CPSLCloudProviderMark: View {
    let provider: CPSLCloudProvider

    var body: some View {
        ZStack {
            CPSLTheme.elevated
            providerIcon
        }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var providerIcon: some View {
        switch provider {
        case .googleDrive:
            Image(systemName: "triangle.fill")
                .font(CPSLTheme.userFont(size: 9, weight: .semibold))
                .foregroundStyle(CPSLTheme.success)
        case .dropbox:
            Image(systemName: "shippingbox.fill")
                .font(CPSLTheme.userFont(size: 9, weight: .semibold))
                .foregroundStyle(CPSLTheme.mauve)
        case .oneDrive:
            Image(systemName: "cloud.fill")
                .font(CPSLTheme.userFont(size: 9, weight: .semibold))
                .foregroundStyle(CPSLTheme.secondaryText)
        }
    }

    private var accessibilityLabel: Text {
        switch provider {
        case .googleDrive:
            return Text("Google Drive")
        case .dropbox:
            return Text("Dropbox")
        case .oneDrive:
            return Text("OneDrive")
        }
    }
}

private struct CPSLFileRowsView: View {
    @ObservedObject var model: CPSLChatModel
    let entries: [CPSLFileEntry]

    var body: some View {
        ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 0) {
                CPSLFileRowView(
                    entry: entry,
                    isExpanded: model.isExpanded(entry),
                    onOpen: {
                        model.openFileEntry(entry)
                    },
                    onToggleExpansion: {
                        model.toggleExpansion(for: entry)
                    }
                )

                if entry.isDirectory && model.isExpanded(entry) {
                    if model.isLoading(entry.path) {
                        CPSLInlineFileLoadingView()
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
}

private struct CPSLFileRowView: View {
    let entry: CPSLFileEntry
    let isExpanded: Bool
    let onOpen: () -> Void
    let onToggleExpansion: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            CPSLFileDisclosureControl(
                isDirectory: entry.isDirectory,
                isExpanded: isExpanded,
                onToggle: onToggleExpansion
            )

            Button(action: onOpen) {
                HStack(spacing: CPSLTheme.medium) {
                    CPSLFileIcon(systemName: iconName, color: iconColor)

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

    private var iconName: String {
        if entry.isDirectory {
            return "folder.fill"
        }
        switch entry.pathExtension {
        case "pdf":
            return "doc.richtext"
        case "txt":
            return "doc.text.fill"
        default:
            return "doc.text"
        }
    }

    private var iconColor: Color {
        entry.isDirectory ? CPSLTheme.mauve : CPSLTheme.secondaryText
    }
}

private struct CPSLFileDisclosureControl: View {
    let isDirectory: Bool
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        if isDirectory {
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.caption, weight: .bold))
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

private struct CPSLFileIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(CPSLTheme.iconMediumFont)
            .foregroundStyle(color)
            .frame(width: 20)
    }
}

private struct CPSLFileBrowserErrorView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(CPSLTheme.captionFont)
            .foregroundStyle(CPSLTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CPSLTheme.medium)
    }
}

private struct CPSLFileBrowserLoadingView: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, CPSLTheme.large)
    }
}

private struct CPSLFileBrowserEmptyView: View {
    var body: some View {
        Text("Empty")
            .font(CPSLTheme.bodyFont)
            .foregroundStyle(CPSLTheme.mutedText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, CPSLTheme.large)
    }
}

private struct CPSLInlineFileLoadingView: View {
    var body: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Loading")
                .font(CPSLTheme.captionFont)
                .foregroundStyle(CPSLTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 28)
        .padding(.vertical, CPSLTheme.small)
    }
}

private extension CPSLFileEntry {
    var pathExtension: String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }
}
