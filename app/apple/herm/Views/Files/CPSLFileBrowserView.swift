import Foundation
import SwiftUI

private enum CPSLFileBrowserPagePlacement: Equatable {
    case entering
    case center
    case exiting
}

private enum CPSLFileBrowserMotion {
    static let duration = 0.2
    static let animation = Animation.easeOut(duration: duration)

    static func offset(
        for placement: CPSLFileBrowserPagePlacement,
        direction: CPSLFileBrowserNavigationDirection,
        width: CGFloat
    ) -> CGFloat {
        switch placement {
        case .center:
            return 0
        case .entering:
            return direction == .forward ? width : -width
        case .exiting:
            return direction == .forward ? -width : width
        }
    }
}

private struct CPSLFileBrowserFolderSnapshot: Equatable {
    let path: String
    let isRoot: Bool
    let entries: [CPSLFileEntry]
    let childEntriesByPath: [String: [CPSLFileEntry]]
    let expandedFilePaths: Set<String>
    let loadingFilePaths: Set<String>
    let error: String?

    init(model: CPSLChatModel) {
        path = model.browserPath
        isRoot = model.browserPath == CPSLVirtualPath.root
        entries = model.browserEntries
        childEntriesByPath = model.childEntriesByPath
        expandedFilePaths = model.expandedFilePaths
        loadingFilePaths = model.loadingFilePaths
        error = model.fileBrowserError
    }

    func children(for path: String) -> [CPSLFileEntry] {
        childEntriesByPath[path] ?? []
    }

    func isExpanded(_ entry: CPSLFileEntry) -> Bool {
        expandedFilePaths.contains(entry.path)
    }

    func isLoading(_ path: String) -> Bool {
        loadingFilePaths.contains(path)
    }
}

private enum CPSLFileBrowserRoute: Identifiable, Equatable {
    case folder(CPSLFileBrowserFolderSnapshot)
    case preview(CPSLFilePreview)

    var id: String {
        switch self {
        case .folder(let snapshot):
            return "folder:\(snapshot.path)"
        case .preview(let preview):
            return "preview:\(preview.id)"
        }
    }

    static func direction(
        from source: CPSLFileBrowserRoute,
        to target: CPSLFileBrowserRoute
    ) -> CPSLFileBrowserNavigationDirection {
        switch (source, target) {
        case (.folder(let source), .folder(let target)):
            return folderDirection(from: source.path, to: target.path)
        case (.folder, .preview):
            return .forward
        case (.preview, .folder):
            return .backward
        case (.preview, .preview):
            return .forward
        }
    }

    private static func folderDirection(
        from sourcePath: String,
        to targetPath: String
    ) -> CPSLFileBrowserNavigationDirection {
        if targetPath == CPSLVirtualPath.root {
            return .backward
        }
        if sourcePath.hasPrefix("\(targetPath)/") {
            return .backward
        }
        return .forward
    }
}

private struct CPSLFileBrowserDisplayPage: Identifiable, Equatable {
    var route: CPSLFileBrowserRoute
    var placement: CPSLFileBrowserPagePlacement
    let direction: CPSLFileBrowserNavigationDirection

    var id: String {
        route.id
    }

    var zIndex: Double {
        placement == .exiting ? 0 : 1
    }
}

struct CPSLFileBrowserView: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        CPSLFileOverlayPanel {
            CPSLFileBrowserHeader(model: model)
        } content: {
            CPSLFileBrowserRouteStack(model: model)
        }
    }
}

private struct CPSLFileBrowserRouteStack: View {
    @ObservedObject var model: CPSLChatModel
    @State private var pages: [CPSLFileBrowserDisplayPage] = []
    @State private var transitionGeneration = 0

    private var currentRoute: CPSLFileBrowserRoute {
        if let preview = model.filePreview {
            return .preview(preview)
        }
        return .folder(CPSLFileBrowserFolderSnapshot(model: model))
    }

    private var visiblePages: [CPSLFileBrowserDisplayPage] {
        if pages.isEmpty {
            return [
                CPSLFileBrowserDisplayPage(
                    route: currentRoute,
                    placement: .center,
                    direction: .forward
                )
            ]
        }
        return pages
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(visiblePages) { page in
                    CPSLFileBrowserRouteContent(
                        route: page.route,
                        actions: CPSLFileBrowserActions(model: model)
                    )
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height,
                        alignment: .topLeading
                    )
                    .background(CPSLTheme.command)
                    .offset(
                        x: CPSLFileBrowserMotion.offset(
                            for: page.placement,
                            direction: page.direction,
                            width: proxy.size.width
                        )
                    )
                    .zIndex(page.zIndex)
                    .allowsHitTesting(page.id == visiblePages.last?.id && page.placement == .center)
                }
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            resetPages(to: currentRoute)
        }
        .onChange(of: currentRoute) { _, route in
            reconcile(with: route)
        }
    }

    private func resetPages(to route: CPSLFileBrowserRoute) {
        transitionGeneration += 1
        pages = [
            CPSLFileBrowserDisplayPage(
                route: route,
                placement: .center,
                direction: .forward
            )
        ]
    }

    private func reconcile(with route: CPSLFileBrowserRoute) {
        guard let currentPage = pages.last else {
            resetPages(to: route)
            return
        }

        if currentPage.route.id == route.id {
            pages[pages.count - 1].route = route
            return
        }

        transition(to: route, from: currentPage.route)
    }

    private func transition(
        to route: CPSLFileBrowserRoute,
        from source: CPSLFileBrowserRoute
    ) {
        let direction = CPSLFileBrowserRoute.direction(from: source, to: route)
        transitionGeneration += 1
        let generation = transitionGeneration

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pages = [
                CPSLFileBrowserDisplayPage(
                    route: source,
                    placement: .center,
                    direction: direction
                ),
                CPSLFileBrowserDisplayPage(
                    route: route,
                    placement: .entering,
                    direction: direction
                )
            ]
        }

        DispatchQueue.main.async {
            guard transitionGeneration == generation else {
                return
            }
            let incomingRoute = pages.last?.route ?? route
            withAnimation(CPSLFileBrowserMotion.animation) {
                pages = [
                    CPSLFileBrowserDisplayPage(
                        route: source,
                        placement: .exiting,
                        direction: direction
                    ),
                    CPSLFileBrowserDisplayPage(
                        route: incomingRoute,
                        placement: .center,
                        direction: direction
                    )
                ]
            }
            pruneTransition(generation: generation, routeID: incomingRoute.id)
        }
    }

    private func pruneTransition(generation: Int, routeID: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + CPSLFileBrowserMotion.duration) {
            guard transitionGeneration == generation, let currentPage = pages.last else {
                return
            }
            guard currentPage.route.id == routeID else {
                return
            }
            pages = [
                CPSLFileBrowserDisplayPage(
                    route: currentPage.route,
                    placement: .center,
                    direction: currentPage.direction
                )
            ]
        }
    }
}

private struct CPSLFileBrowserRouteContent: View {
    let route: CPSLFileBrowserRoute
    let actions: CPSLFileBrowserActions

    var body: some View {
        switch route {
        case .folder(let snapshot):
            CPSLFileBrowserPane(snapshot: snapshot, actions: actions)
        case .preview(let preview):
            CPSLFilePreviewContentView(preview: preview)
        }
    }
}

@MainActor
private struct CPSLFileBrowserActions {
    let loadPath: (String) -> Void
    let openEntry: (CPSLFileEntry) -> Void
    let toggleExpansion: (CPSLFileEntry) -> Void
    let showComingSoon: (String) -> Void

    init(model: CPSLChatModel) {
        loadPath = { path in
            model.loadBrowserPath(path)
        }
        openEntry = { entry in
            model.openFileEntry(entry)
        }
        toggleExpansion = { entry in
            model.toggleExpansion(for: entry)
        }
        showComingSoon = { message in
            model.showComingSoon(message)
        }
    }
}

private struct CPSLFileBrowserHeader: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileBrowserBackButton(
                isAvailable: model.filePreview != nil || model.canNavigateToParentDirectory
            ) {
                if model.filePreview != nil {
                    model.closeFilePreview()
                } else {
                    model.navigateToParentDirectory()
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

private struct CPSLFileBrowserBackButton: View {
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            if isAvailable {
                CPSLFileOverlayIconButton(
                    systemName: "chevron.left",
                    accessibilityLabel: "Back"
                ) { action() }
            } else {
                Color.clear
                    .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct CPSLFilePreviewHeaderTitle: View {
    let preview: CPSLFilePreview

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileIcon(systemName: iconName, color: iconColor)

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

    private var iconColor: Color {
        switch preview.kind {
        case .pdf:
            return CPSLTheme.IconPalette.pdf
        case .text:
            return CPSLTheme.IconPalette.file
        }
    }
}

private struct CPSLFileBrowserHeaderTitle: View {
    let path: String
    let isRoot: Bool

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileIcon(systemName: iconName, color: iconColor)

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

    private var iconColor: Color {
        if path == CPSLVirtualPath.home {
            return CPSLTheme.IconPalette.home
        }
        if path == CPSLVirtualPath.temporary {
            return CPSLTheme.IconPalette.temporary
        }
        return CPSLTheme.IconPalette.folder
    }
}

private struct CPSLFileBrowserPane: View {
    let snapshot: CPSLFileBrowserFolderSnapshot
    let actions: CPSLFileBrowserActions

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let error = snapshot.error {
                    CPSLFileBrowserErrorView(message: error)
                }

                if snapshot.isRoot {
                    CPSLFileLocationsView(actions: actions)
                } else if snapshot.isLoading(snapshot.path) && snapshot.entries.isEmpty {
                    CPSLFileBrowserLoadingView()
                } else if snapshot.entries.isEmpty && snapshot.error == nil {
                    CPSLFileBrowserEmptyView()
                } else {
                    CPSLFileRowsView(
                        snapshot: snapshot,
                        entries: snapshot.entries,
                        actions: actions
                    )
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
    let actions: CPSLFileBrowserActions

    var body: some View {
        VStack(spacing: 0) {
            CPSLFileLocationRow(
                title: "Home",
                detail: CPSLVirtualPath.home,
                systemName: "house.fill",
                color: CPSLTheme.IconPalette.home
            ) {
                actions.loadPath(CPSLVirtualPath.home)
            }

            CPSLFileLocationRow(
                title: "Temporary",
                detail: CPSLVirtualPath.temporary,
                systemName: "clock.fill",
                color: CPSLTheme.IconPalette.temporary
            ) {
                actions.loadPath(CPSLVirtualPath.temporary)
            }

            CPSLCloudConnectionRow(
                title: "iCloud",
                systemName: "icloud.fill",
                color: CPSLTheme.IconPalette.cloud,
                accessory: .singleIcon
            ) {
                actions.showComingSoon("coming soon")
            }

            CPSLCloudConnectionRow(
                title: "Cloud Drives",
                systemName: "externaldrive.fill",
                color: CPSLTheme.IconPalette.drive,
                accessory: .providerIcons
            ) {
                actions.showComingSoon("coming soon")
            }
        }
    }
}

private struct CPSLFileLocationRow: View {
    let title: LocalizedStringKey
    let detail: String
    let systemName: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: CPSLTheme.medium) {
                CPSLFileIcon(systemName: systemName, color: color)

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
    let color: Color
    let accessory: CPSLCloudAccessory
    let action: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileIcon(systemName: systemName, color: color)

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

private enum CPSLFileRowMetrics {
    static let height: CGFloat = 38
    static let leading: CGFloat = CPSLTheme.medium
    static let trailing: CGFloat = CPSLTheme.small
    static let indent: CGFloat = 24
    static let disclosureWidth: CGFloat = 24
    static let iconWidth: CGFloat = 20

    static func leadingPadding(depth: Int, isDirectory: Bool) -> CGFloat {
        let base = leading + CGFloat(depth) * indent
        if isDirectory {
            return base
        }
        return base + (disclosureWidth - iconWidth) / 2
    }
}

private struct CPSLFileRowsView: View {
    let snapshot: CPSLFileBrowserFolderSnapshot
    let entries: [CPSLFileEntry]
    let actions: CPSLFileBrowserActions
    let depth: Int

    init(
        snapshot: CPSLFileBrowserFolderSnapshot,
        entries: [CPSLFileEntry],
        actions: CPSLFileBrowserActions,
        depth: Int = 0
    ) {
        self.snapshot = snapshot
        self.entries = entries
        self.actions = actions
        self.depth = depth
    }

    var body: some View {
        ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 0) {
                CPSLFileRowView(
                    entry: entry,
                    depth: depth,
                    isExpanded: snapshot.isExpanded(entry),
                    onOpen: {
                        actions.openEntry(entry)
                    },
                    onToggleExpansion: {
                        actions.toggleExpansion(entry)
                    }
                )

                if entry.isDirectory && snapshot.isExpanded(entry) {
                    if snapshot.isLoading(entry.path) {
                        CPSLInlineFileLoadingView(depth: depth + 1)
                    } else {
                        CPSLFileRowsView(
                            snapshot: snapshot,
                            entries: snapshot.children(for: entry.path),
                            actions: actions,
                            depth: depth + 1
                        )
                    }
                }
            }
        }
    }
}

private struct CPSLFileRowView: View {
    let entry: CPSLFileEntry
    let depth: Int
    let isExpanded: Bool
    let onOpen: () -> Void
    let onToggleExpansion: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            if entry.isDirectory {
                CPSLFileDisclosureControl(
                    isExpanded: isExpanded,
                    onToggle: onToggleExpansion
                )
            }

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
        .padding(.leading, leadingPadding)
        .padding(.trailing, CPSLFileRowMetrics.trailing)
        .frame(height: CPSLFileRowMetrics.height)
        .contentShape(Rectangle())
    }

    private var leadingPadding: CGFloat {
        CPSLFileRowMetrics.leadingPadding(depth: depth, isDirectory: entry.isDirectory)
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
        if entry.isDirectory {
            return CPSLTheme.IconPalette.folder
        }
        if entry.pathExtension == "pdf" {
            return CPSLTheme.IconPalette.pdf
        }
        return CPSLTheme.IconPalette.file
    }
}

private struct CPSLFileDisclosureControl: View {
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.caption, weight: .bold))
                .frame(
                    width: CPSLFileRowMetrics.disclosureWidth,
                    height: CPSLFileRowMetrics.height
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.secondaryText)
    }
}

private struct CPSLFileIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .font(CPSLTheme.iconMediumFont)
            .foregroundStyle(color)
            .frame(width: CPSLFileRowMetrics.iconWidth, height: CPSLFileRowMetrics.height)
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
    let depth: Int

    var body: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text("Loading")
                .font(CPSLTheme.captionFont)
                .foregroundStyle(CPSLTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, CPSLFileRowMetrics.leading + CGFloat(depth) * CPSLFileRowMetrics.indent)
        .frame(height: CPSLFileRowMetrics.height)
    }
}

private extension CPSLFileEntry {
    var pathExtension: String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }
}
