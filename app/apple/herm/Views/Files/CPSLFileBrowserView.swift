import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
    let rows: [CPSLFileBrowserRow]
    let isLoading: Bool
    let error: String?

    init(model: CPSLChatModel) {
        path = model.browserPath
        isRoot = model.browserPath == CPSLVirtualPath.root
        rows = Self.makeRows(
            from: model.browserEntries,
            childEntriesByPath: model.childEntriesByPath,
            expandedFilePaths: model.expandedFilePaths,
            loadingFilePaths: model.loadingFilePaths
        )
        isLoading = model.loadingFilePaths.contains(model.browserPath)
        error = model.fileBrowserError
    }

    private static func makeRows(
        from entries: [CPSLFileEntry],
        childEntriesByPath: [String: [CPSLFileEntry]],
        expandedFilePaths: Set<String>,
        loadingFilePaths: Set<String>,
        depth: Int = 0
    ) -> [CPSLFileBrowserRow] {
        var rows: [CPSLFileBrowserRow] = []
        appendRows(
            to: &rows,
            from: entries,
            childEntriesByPath: childEntriesByPath,
            expandedFilePaths: expandedFilePaths,
            loadingFilePaths: loadingFilePaths,
            depth: depth
        )
        return rows
    }

    private static func appendRows(
        to rows: inout [CPSLFileBrowserRow],
        from entries: [CPSLFileEntry],
        childEntriesByPath: [String: [CPSLFileEntry]],
        expandedFilePaths: Set<String>,
        loadingFilePaths: Set<String>,
        depth: Int
    ) {
        for entry in entries {
            let isExpanded = expandedFilePaths.contains(entry.path)
            rows.append(.entry(entry, depth: depth, isExpanded: isExpanded))
            guard entry.isDirectory, isExpanded else {
                continue
            }
            if loadingFilePaths.contains(entry.path) {
                rows.append(.loading(path: entry.path, depth: depth + 1))
            } else {
                appendRows(
                    to: &rows,
                    from: childEntriesByPath[entry.path] ?? [],
                    childEntriesByPath: childEntriesByPath,
                    expandedFilePaths: expandedFilePaths,
                    loadingFilePaths: loadingFilePaths,
                    depth: depth + 1
                )
            }
        }
    }
}

private enum CPSLFileBrowserRow: Identifiable, Equatable {
    case entry(CPSLFileEntry, depth: Int, isExpanded: Bool)
    case loading(path: String, depth: Int)

    var id: String {
        switch self {
        case .entry(let entry, _, _):
            return "entry:\(entry.path)"
        case .loading(let path, _):
            return "loading:\(path)"
        }
    }
}

private enum CPSLFileBrowserRoute: Identifiable, Equatable {
    case folder(CPSLFileBrowserFolderSnapshot)
    case preview(CPSLFilePreview)
    case fileInfo(CPSLFilePreview)

    var id: String {
        switch self {
        case .folder(let snapshot):
            return "folder:\(snapshot.path)"
        case .preview(let preview):
            return "preview:\(preview.id)"
        case .fileInfo(let preview):
            return "fileinfo:\(preview.id)"
        }
    }

    static func direction(
        from source: CPSLFileBrowserRoute,
        to target: CPSLFileBrowserRoute
    ) -> CPSLFileBrowserNavigationDirection {
        switch (source, target) {
        case (.folder(let source), .folder(let target)):
            return folderDirection(from: source.path, to: target.path)
        case (.folder, .preview), (.folder, .fileInfo), (.preview, .fileInfo):
            return .forward
        case (.preview, .folder), (.fileInfo, .folder), (.fileInfo, .preview):
            return .backward
        case (.preview, .preview), (.fileInfo, .fileInfo):
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

private enum CPSLFileBrowserInteractionMode: Equatable {
    case browsing
    case selecting(selectedCount: Int)
    case moving(itemCount: Int)
}

struct CPSLFileBrowserView: View {
    let model: CPSLChatModel
    @State private var isICloudImporterPresented = false
    @State private var isICloudImporterPending = false
    @State private var isSelectingFiles = false
    @State private var selectedEntriesByPath: [String: CPSLFileEntry] = [:]
    @State private var movingEntries: [CPSLFileEntry] = []
    @State private var pendingDeletionEntries: [CPSLFileEntry] = []
    @State private var isDeleteConfirmationPresented = false
    @State private var shareFile: CPSLShareableFile?
    @State private var isPreparingShare = false

    var body: some View {
        browserPanel
            .cpslShareFile(file: $shareFile)
            .fileImporter(
                isPresented: $isICloudImporterPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        // Herm policy default: read-write. Mode can be changed on the mount later.
                        model.importICloudDirectory(url, accessMode: .readWrite)
                    }
                case .failure(let error):
                    model.reportICloudImportError(error)
                }
            }
            .onChange(of: model.dictation.isActive) { _, isActive in
                if !isActive {
                    presentICloudImporterIfReady()
                }
            }
            .onChange(of: model.browserPath) { _, _ in
                guard movingEntries.isEmpty else {
                    return
                }
                isSelectingFiles = false
                selectedEntriesByPath.removeAll()
            }
            .confirmationDialog(
                deleteConfirmationTitle,
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let entries = pendingDeletionEntries
                    pendingDeletionEntries = []
                    model.deleteFileEntries(entries)
                }
                Button("Cancel", role: .cancel) {
                    pendingDeletionEntries = []
                }
            } message: {
                Text("This permanently deletes the selected items from CPSL storage.")
            }
    }

    private var browserPanel: some View {
        CPSLFileOverlayPanel {
            CPSLFileBrowserHeader(model: model, actions: actions)
        } content: {
            CPSLFileBrowserRouteStack(
                model: model,
                actions: actions
            )
        }
    }

    private var actions: CPSLFileBrowserActions {
        CPSLFileBrowserActions(
            model: model,
            connectICloud: connectICloud,
            isSelecting: isSelectingFiles,
            selectedEntryPaths: Set(selectedEntriesByPath.keys),
            movingEntries: movingEntries,
            beginSelection: beginSelection,
            cancelSelection: cancelSelection,
            toggleSelection: toggleSelection,
            beginMove: beginMove,
            cancelMove: cancelMove,
            completeMove: completeMove,
            requestDelete: requestDelete,
            shareEntry: shareEntry
        )
    }

    private func shareEntry(_ entry: CPSLFileEntry) {
        guard !entry.isDirectory, !isPreparingShare else {
            return
        }
        isPreparingShare = true
        Task { @MainActor in
            defer { isPreparingShare = false }
            shareFile = await model.resolveFileURLForSharing(entry)
        }
    }

    private var deleteConfirmationTitle: String {
        pendingDeletionEntries.count == 1
            ? "Delete this item?"
            : "Delete \(pendingDeletionEntries.count) items?"
    }

    private func beginSelection() {
        movingEntries = []
        selectedEntriesByPath.removeAll()
        isSelectingFiles = true
    }

    private func cancelSelection() {
        isSelectingFiles = false
        selectedEntriesByPath.removeAll()
    }

    private func toggleSelection(_ entry: CPSLFileEntry) {
        if selectedEntriesByPath.removeValue(forKey: entry.path) == nil {
            if selectedEntriesByPath.values.contains(where: {
                $0.isDirectory && entry.path.hasPrefix("\($0.path)/")
            }) {
                return
            }
            if entry.isDirectory {
                selectedEntriesByPath = selectedEntriesByPath.filter {
                    !$0.key.hasPrefix("\(entry.path)/")
                }
            }
            selectedEntriesByPath[entry.path] = entry
        }
    }

    private func beginMove(_ entries: [CPSLFileEntry]) {
        guard !entries.isEmpty else {
            return
        }
        isSelectingFiles = false
        selectedEntriesByPath.removeAll()
        movingEntries = entries.sorted { $0.path < $1.path }
    }

    private func cancelMove() {
        movingEntries = []
    }

    private func completeMove() {
        let entries = movingEntries
        movingEntries = []
        model.moveFileEntries(entries, toDirectory: model.browserPath)
    }

    private func requestDelete(_ entries: [CPSLFileEntry]) {
        guard !entries.isEmpty else {
            return
        }
        isSelectingFiles = false
        selectedEntriesByPath.removeAll()
        pendingDeletionEntries = entries.sorted { $0.path < $1.path }
        isDeleteConfirmationPresented = true
    }

    private func connectICloud() {
        isICloudImporterPending = true
        model.dictation.finish()
        presentICloudImporterIfReady()
    }

    private func presentICloudImporterIfReady() {
        guard isICloudImporterPending, !model.dictation.isActive else {
            return
        }
        isICloudImporterPending = false
        isICloudImporterPresented = true
    }
}

private struct CPSLFileBrowserRouteStack: View {
    let model: CPSLChatModel
    let actions: CPSLFileBrowserActions
    @State private var pages: [CPSLFileBrowserDisplayPage] = []
    @State private var transitionGeneration = 0

    private var currentRoute: CPSLFileBrowserRoute {
        if let preview = model.filePreview {
            if model.isFileInfoOpen {
                return .fileInfo(preview)
            }
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
                        actions: actions
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
        case .fileInfo(let preview):
            CPSLFileInfoPageView(preview: preview)
        }
    }
}

@MainActor
private struct CPSLFileBrowserActions {
    let model: CPSLChatModel
    let connectICloud: () -> Void
    let isSelecting: Bool
    let selectedEntryPaths: Set<String>
    let movingEntries: [CPSLFileEntry]
    let beginSelection: () -> Void
    let cancelSelection: () -> Void
    let toggleSelection: (CPSLFileEntry) -> Void
    let beginMove: ([CPSLFileEntry]) -> Void
    let cancelMove: () -> Void
    let completeMove: () -> Void
    let requestDelete: ([CPSLFileEntry]) -> Void
    let shareEntry: (CPSLFileEntry) -> Void

    var iCloudMounts: [CPSLICloudMount] {
        model.iCloudMounts
    }

    var isBusy: Bool {
        model.isBusy
    }

    var mode: CPSLFileBrowserInteractionMode {
        if !movingEntries.isEmpty {
            return .moving(itemCount: movingEntries.count)
        }
        if isSelecting {
            return .selecting(selectedCount: selectedEntryPaths.count)
        }
        return .browsing
    }

    var canEnterSelection: Bool {
        model.filePreview == nil &&
            model.browserEntries.contains { canModify($0) }
    }

    func loadPath(_ path: String) {
        model.loadBrowserPath(path)
    }

    func openEntry(_ entry: CPSLFileEntry) {
        if isSelecting {
            guard canModify(entry) else {
                return
            }
            toggleSelection(entry)
            return
        }
        if !movingEntries.isEmpty {
            guard entry.isDirectory else {
                return
            }
        }
        model.openFileEntry(entry)
    }

    func toggleExpansion(_ entry: CPSLFileEntry) {
        model.toggleExpansion(for: entry)
    }

    func isSelected(_ entry: CPSLFileEntry) -> Bool {
        selectedEntryPaths.contains(entry.path)
    }

    func isReadOnly(_ entry: CPSLFileEntry) -> Bool {
        model.isFileReadOnly(entry.path)
    }

    func isICloudMountRoot(_ entry: CPSLFileEntry) -> Bool {
        model.isICloudMountRoot(entry.path)
    }

    func canModify(_ entry: CPSLFileEntry) -> Bool {
        !isBusy && !isReadOnly(entry) && !isICloudMountRoot(entry)
    }

    func canCompleteMove() -> Bool {
        !isBusy && model.canMoveFileEntries(movingEntries, toDirectory: model.browserPath)
    }

    func moveSelectedEntries() {
        beginMove(selectedEntries())
    }

    func deleteSelectedEntries() {
        requestDelete(selectedEntries())
    }

    private func selectedEntries() -> [CPSLFileEntry] {
        let entriesByPath = dictionaryOfVisibleEntries()
        return selectedEntryPaths.compactMap { entriesByPath[$0] }
    }

    private func dictionaryOfVisibleEntries() -> [String: CPSLFileEntry] {
        var result = Dictionary(uniqueKeysWithValues: model.browserEntries.map { ($0.path, $0) })
        for entries in model.childEntriesByPath.values {
            for entry in entries {
                result[entry.path] = entry
            }
        }
        return result
    }

    func removeICloudMount(_ entry: CPSLFileEntry) {
        model.removeICloudMount(entry)
    }

    func setICloudAccessMode(
        _ accessMode: CPSLICloudMountAccessMode,
        at path: String
    ) {
        model.setICloudMountAccessMode(accessMode, at: path)
    }

    func setKeepDownloaded(_ keep: Bool, at path: String) {
        model.setKeepDownloaded(keep, at: path)
    }

    func showComingSoon(_ message: String) {
        model.showComingSoon(message)
    }
}

private struct CPSLFileBrowserHeader: View {
    let model: CPSLChatModel
    let actions: CPSLFileBrowserActions

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileBrowserBackButton(
                isAvailable: model.isFileInfoOpen
                    || model.filePreview != nil
                    || model.canNavigateToParentDirectory
            ) {
                if model.isFileInfoOpen {
                    model.closeFileInfo()
                } else if model.filePreview != nil {
                    model.closeFilePreview()
                } else {
                    model.navigateToParentDirectory()
                }
            }

            if model.isFileInfoOpen, let preview = model.filePreview {
                CPSLFileInfoHeaderTitle(preview: preview)
            } else if let preview = model.filePreview {
                CPSLFilePreviewHeaderTitle(
                    preview: preview,
                    accessMode: model.iCloudMount(containing: preview.path)?.accessMode
                )
            } else {
                CPSLFileBrowserHeaderTitle(
                    path: model.browserPath,
                    isRoot: model.isAtFileBrowserRoot,
                    accessMode: model.iCloudMount(containing: model.browserPath)?.accessMode
                )
            }

            switch actions.mode {
            case .browsing:
                if let preview = model.filePreview,
                   preview.showsHeaderInfoButton,
                   !model.isFileInfoOpen {
                    CPSLFilePreviewInfoButton {
                        model.openFileInfo()
                    }
                } else if model.filePreview == nil, actions.canEnterSelection {
                    Button("Select", action: actions.beginSelection)
                        .font(CPSLTheme.controlFont)
                        .buttonStyle(.plain)
                        .foregroundStyle(CPSLTheme.text)
                        .padding(.horizontal, CPSLTheme.small)
                }
            case .selecting:
                Button("Cancel", action: actions.cancelSelection)
                    .font(CPSLTheme.controlFont)
                    .buttonStyle(.plain)
                    .foregroundStyle(CPSLTheme.text)
            case .moving:
                EmptyView()
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

private struct CPSLFilePreviewInfoButton: View {
    let action: () -> Void

    var body: some View {
        CPSLFileOverlayIconButton(
            systemName: "info.circle",
            accessibilityLabel: "File Info",
            action: action
        )
    }
}

/// Full-pane file metadata, pushed one level deeper in the Files stack (not a popover).
struct CPSLFileInfoPageView: View {
    let preview: CPSLFilePreview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CPSLTheme.large) {
                CPSLFilePreviewInfoHeader(preview: preview)
                CPSLFileMetadataList(metadata: preview.metadata)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CPSLTheme.large)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CPSLFilePreviewInfoHeader: View {
    let preview: CPSLFilePreview

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileIcon(
                systemName: preview.metadata.category.systemImageName,
                color: preview.metadata.category.iconColor
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(preview.name)
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(2)

                Text(preview.metadata.category.displayName)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
            }
        }
    }
}

private struct CPSLFileInfoHeaderTitle: View {
    let preview: CPSLFilePreview

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileIcon(
                systemName: "info.circle.fill",
                color: CPSLTheme.IconPalette.secondary
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Info")
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(1)

                Text(preview.name)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CPSLFilePreviewHeaderTitle: View {
    let preview: CPSLFilePreview
    let accessMode: CPSLICloudMountAccessMode?

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileIcon(systemName: iconName, color: iconColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: CPSLTheme.small) {
                    Text(preview.name)
                        .font(CPSLTheme.supportingMediumFont)
                        .foregroundStyle(CPSLTheme.text)
                        .lineLimit(1)

                    if let accessMode {
                        CPSLICloudMountAccessBadge(accessMode: accessMode)
                    }
                }

                Text(preview.path)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iconName: String {
        preview.metadata.category.systemImageName
    }

    private var iconColor: Color {
        preview.metadata.category.iconColor
    }
}

private extension CPSLFilePreview {
    var showsHeaderInfoButton: Bool {
        if case .file = kind {
            return false
        }
        return true
    }
}

private struct CPSLFileBrowserHeaderTitle: View {
    let path: String
    let isRoot: Bool
    let accessMode: CPSLICloudMountAccessMode?

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileIcon(systemName: iconName, color: iconColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: CPSLTheme.small) {
                    Text(displayTitle)
                        .font(CPSLTheme.supportingMediumFont)
                        .foregroundStyle(CPSLTheme.text)
                        .lineLimit(1)

                    if let accessMode {
                        CPSLICloudMountAccessBadge(accessMode: accessMode)
                    }
                }

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
        if path == CPSLVirtualPath.attachments {
            return "Attachments"
        }
        if path == CPSLVirtualPath.iCloudRoot {
            return "iCloud"
        }
        return isRoot ? "Locations" : path
    }

    private var displaySubtitle: String {
        return isRoot ? "Home, attachments, and temporary storage" : path
    }

    private var iconName: String {
        if path == CPSLVirtualPath.home {
            return "house.fill"
        }
        if path == CPSLVirtualPath.temporary {
            return "clock.fill"
        }
        if path == CPSLVirtualPath.attachments {
            return "paperclip"
        }
        if path == CPSLVirtualPath.iCloudRoot || path.hasPrefix("\(CPSLVirtualPath.iCloudRoot)/") {
            return "icloud.fill"
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
        if path == CPSLVirtualPath.iCloudRoot || path.hasPrefix("\(CPSLVirtualPath.iCloudRoot)/") {
            return CPSLTheme.IconPalette.primary
        }
        return CPSLTheme.IconPalette.folder
    }
}

private struct CPSLICloudMountAccessBadge: View {
    let accessMode: CPSLICloudMountAccessMode

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: accessMode.systemImageName)
            Text(accessMode.displayName)
        }
        .font(CPSLTheme.userFont(size: 10, weight: .semibold))
        .foregroundStyle(accessMode == .readOnly ? CPSLTheme.secondaryText : CPSLTheme.success)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(CPSLTheme.elevated, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(accessMode.displayName) iCloud mount"))
    }
}

private struct CPSLFileReadOnlyBadge: View {
    var body: some View {
        Text("Read-only")
            .font(CPSLTheme.userFont(size: 10, weight: .semibold))
            .foregroundStyle(CPSLTheme.secondaryText)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(CPSLTheme.elevated, in: Capsule())
            .fixedSize()
    }
}

private struct CPSLFileBrowserPane: View {
    let snapshot: CPSLFileBrowserFolderSnapshot
    let actions: CPSLFileBrowserActions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = snapshot.error {
                        CPSLFileBrowserErrorView(message: error)
                    }

                    if snapshot.isRoot {
                        CPSLFileLocationsView(actions: actions)
                    } else {
                        if snapshot.isLoading && snapshot.rows.isEmpty {
                            CPSLFileBrowserLoadingView()
                        } else if snapshot.rows.isEmpty && snapshot.error == nil {
                            CPSLFileBrowserEmptyView()
                        } else {
                            ForEach(snapshot.rows) { row in
                                CPSLFileBrowserRowView(row: row, actions: actions)
                            }
                        }

                        if snapshot.path == CPSLVirtualPath.iCloudRoot,
                           !actions.iCloudMounts.isEmpty,
                           actions.mode == .browsing {
                            CPSLAddICloudFolderRow(actions: actions)
                        }
                    }
                }
                .padding(.vertical, CPSLTheme.small)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)

            switch actions.mode {
            case .browsing:
                EmptyView()
            case .selecting(let selectedCount):
                CPSLFileSelectionActionBar(
                    selectedCount: selectedCount,
                    isBusy: actions.isBusy,
                    onMove: actions.moveSelectedEntries,
                    onDelete: actions.deleteSelectedEntries
                )
            case .moving(let itemCount):
                CPSLFileMoveActionBar(
                    itemCount: itemCount,
                    canMoveHere: actions.canCompleteMove(),
                    onCancel: actions.cancelMove,
                    onMoveHere: actions.completeMove
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity)
    }
}

private struct CPSLFileSelectionActionBar: View {
    let selectedCount: Int
    let isBusy: Bool
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            Text("\(selectedCount) selected")
                .font(CPSLTheme.captionFont)
                .foregroundStyle(CPSLTheme.secondaryText)

            Spacer()

            Button(action: onMove) {
                Label("Move", systemImage: "folder")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .font(CPSLTheme.controlFont)
        .buttonStyle(.borderless)
        .disabled(selectedCount == 0 || isBusy)
        .padding(.horizontal, CPSLTheme.medium)
        .frame(minHeight: CPSLTheme.controlSize + CPSLTheme.small)
        .background(CPSLTheme.elevated)
    }
}

private struct CPSLFileMoveActionBar: View {
    let itemCount: Int
    let canMoveHere: Bool
    let onCancel: () -> Void
    let onMoveHere: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            Text(itemCount == 1 ? "Move 1 item" : "Move \(itemCount) items")
                .font(CPSLTheme.captionFont)
                .foregroundStyle(CPSLTheme.secondaryText)

            Spacer()

            Button("Cancel", action: onCancel)
            Button("Move Here", action: onMoveHere)
                .disabled(!canMoveHere)
        }
        .font(CPSLTheme.controlFont)
        .buttonStyle(.borderless)
        .padding(.horizontal, CPSLTheme.medium)
        .frame(minHeight: CPSLTheme.controlSize + CPSLTheme.small)
        .background(CPSLTheme.elevated)
    }
}

private struct CPSLAddICloudFolderRow: View {
    let actions: CPSLFileBrowserActions

    var body: some View {
        CPSLCloudConnectionRow(
            title: "Add iCloud Folder",
            actionTitle: "Add",
            systemName: "icloud.fill",
            color: CPSLTheme.IconPalette.cloud,
            accessory: .none
        ) {
            actions.connectICloud()
        }
        .disabled(actions.isBusy)
        .opacity(actions.isBusy ? 0.45 : 1)
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
                title: "Attachments",
                detail: CPSLVirtualPath.attachments,
                systemName: "paperclip",
                color: CPSLTheme.IconPalette.folder
            ) {
                actions.loadPath(CPSLVirtualPath.attachments)
            }

            CPSLFileLocationRow(
                title: "Temporary",
                detail: CPSLVirtualPath.temporary,
                systemName: "clock.fill",
                color: CPSLTheme.IconPalette.temporary
            ) {
                actions.loadPath(CPSLVirtualPath.temporary)
            }

            if !actions.iCloudMounts.isEmpty {
                CPSLFileLocationRow(
                    title: "iCloud",
                    detail: CPSLVirtualPath.iCloudRoot,
                    systemName: "icloud.fill",
                    color: CPSLTheme.IconPalette.primary
                ) {
                    actions.loadPath(CPSLVirtualPath.iCloudRoot)
                }
            }

            if actions.mode == .browsing {
                if actions.iCloudMounts.isEmpty {
                    CPSLCloudConnectionRow(
                        title: "iCloud",
                        actionTitle: "Add",
                        systemName: "icloud.fill",
                        color: CPSLTheme.IconPalette.cloud,
                        accessory: .none
                    ) {
                        actions.connectICloud()
                    }
                    .disabled(actions.isBusy)
                    .opacity(actions.isBusy ? 0.45 : 1)
                }

                CPSLCloudConnectionRow(
                    title: "Cloud Drives",
                    actionTitle: "Connect",
                    systemName: "externaldrive.fill",
                    color: CPSLTheme.IconPalette.drive,
                    accessory: .providerIcons
                ) {
                    actions.showComingSoon("coming soon")
                }
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
                        .lineLimit(1)
                    Text(detail)
                        .font(CPSLTheme.captionFont)
                        .foregroundStyle(CPSLTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(CPSLTheme.iconSmallFont)
                    .foregroundStyle(CPSLTheme.mutedText)
                    .frame(width: CPSLFileRowMetrics.trailingControlWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, minHeight: CPSLFileRowMetrics.height, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, CPSLFileRowMetrics.leading)
        .padding(.trailing, CPSLFileRowMetrics.trailing)
        .padding(.vertical, CPSLTheme.small)
    }
}

private enum CPSLCloudAccessory {
    case none
    case providerIcons
}

private struct CPSLCloudConnectionRow: View {
    let title: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let systemName: String
    let color: Color
    let accessory: CPSLCloudAccessory
    let action: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLFileIcon(systemName: systemName, color: color)

            Text(title)
                .font(CPSLTheme.rowTitleFont)
                .foregroundStyle(CPSLTheme.text)
                .lineLimit(1)

            if case .providerIcons = accessory {
                cloudProviderMarks
            }

            Spacer(minLength: 0)

            Button(actionTitle, action: action)
                .font(CPSLTheme.controlFont)
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.text)
                .padding(.horizontal, CPSLTheme.medium)
                .frame(height: CPSLTheme.controlSize)
                .cpslSurfaceBackground(
                    in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                    tint: CPSLTheme.background.opacity(0.34),
                    strokeOpacity: 0.045
                )
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
        }
        .frame(minHeight: CPSLFileRowMetrics.height)
        .padding(.leading, CPSLFileRowMetrics.leading)
        .padding(.trailing, CPSLFileRowMetrics.trailing)
        .padding(.vertical, CPSLTheme.small)
    }

    private var cloudProviderMarks: some View {
        HStack(spacing: 4) {
            CPSLCloudProviderMark(provider: .googleDrive)
            CPSLCloudProviderMark(provider: .dropbox)
            CPSLCloudProviderMark(provider: .oneDrive)
            Image(systemName: "ellipsis")
                .font(CPSLTheme.captionFont)
                .foregroundStyle(CPSLTheme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Google Drive, Dropbox, OneDrive, and more")
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
    /// Shared trailing control column so chevrons/actions line up across row types.
    static let trailingControlWidth: CGFloat = CPSLTheme.controlSize

    static func leadingPadding(depth: Int, isDirectory: Bool) -> CGFloat {
        let base = leading + CGFloat(depth) * indent
        if isDirectory {
            return base
        }
        return base + (disclosureWidth - iconWidth) / 2
    }
}

private struct CPSLFileBrowserRowView: View {
    let row: CPSLFileBrowserRow
    let actions: CPSLFileBrowserActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .entry(let entry, let depth, let isExpanded):
                CPSLFileRowView(
                    entry: entry,
                    depth: depth,
                    isExpanded: isExpanded,
                    accessMode: iCloudMountAccessMode(for: entry),
                    isReadOnly: actions.isReadOnly(entry),
                    isSelected: actions.isSelected(entry),
                    mode: actions.mode,
                    canModify: actions.canModify(entry),
                    onOpen: {
                        actions.openEntry(entry)
                    },
                    onToggleExpansion: {
                        actions.toggleExpansion(entry)
                    },
                    onShare: entry.isDirectory ? nil : {
                        actions.shareEntry(entry)
                    },
                    onMove: {
                        actions.beginMove([entry])
                    },
                    onDelete: {
                        actions.requestDelete([entry])
                    },
                    onRemove: iCloudMountRemoval(for: entry),
                    onSetAccessMode: iCloudMountAccessModeSetter(for: entry),
                    onSetKeepDownloaded: iCloudKeepDownloadedSetter(for: entry)
                )
            case .loading(_, let depth):
                CPSLInlineFileLoadingView(depth: depth)
            }
        }
    }
    private func iCloudMountRemoval(for entry: CPSLFileEntry) -> (() -> Void)? {
        guard isICloudMountEntry(entry) else {
            return nil
        }
        return {
            actions.removeICloudMount(entry)
        }
    }

    private func isICloudMountEntry(_ entry: CPSLFileEntry) -> Bool {
        !actions.isBusy &&
            actions.iCloudMounts.contains { $0.virtualPath == entry.path }
    }

    private func iCloudMountAccessMode(
        for entry: CPSLFileEntry
    ) -> CPSLICloudMountAccessMode? {
        actions.iCloudMounts.first { $0.virtualPath == entry.path }?.accessMode
    }

    private func iCloudMountAccessModeSetter(
        for entry: CPSLFileEntry
    ) -> ((CPSLICloudMountAccessMode) -> Void)? {
        guard isICloudMountEntry(entry) else {
            return nil
        }
        return { mode in
            actions.setICloudAccessMode(mode, at: entry.path)
        }
    }

    private func iCloudKeepDownloadedSetter(
        for entry: CPSLFileEntry
    ) -> ((Bool) -> Void)? {
        guard !actions.isBusy else {
            return nil
        }
        // Mount roots and any path under a connected mount can be pinned.
        let underMount = actions.iCloudMounts.contains { mount in
            entry.path == mount.virtualPath
                || entry.path.hasPrefix("\(mount.virtualPath)/")
        }
        guard underMount else {
            return nil
        }
        return { keep in
            actions.setKeepDownloaded(keep, at: entry.path)
        }
    }
}

private struct CPSLFileRowView: View {
    let entry: CPSLFileEntry
    let depth: Int
    let isExpanded: Bool
    let accessMode: CPSLICloudMountAccessMode?
    let isReadOnly: Bool
    let isSelected: Bool
    let mode: CPSLFileBrowserInteractionMode
    let canModify: Bool
    let onOpen: () -> Void
    let onToggleExpansion: () -> Void
    let onShare: (() -> Void)?
    let onMove: () -> Void
    let onDelete: () -> Void
    let onRemove: (() -> Void)?
    let onSetAccessMode: ((CPSLICloudMountAccessMode) -> Void)?
    let onSetKeepDownloaded: ((Bool) -> Void)?

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            if case .selecting = mode {
                CPSLFileSelectionControl(isSelected: isSelected, isEnabled: canModify)
            } else if entry.isDirectory {
                CPSLFileDisclosureControl(
                    isExpanded: isExpanded,
                    onToggle: onToggleExpansion
                )
                .disabled(isMoving)
            }

            Button(action: onOpen) {
                HStack(spacing: CPSLTheme.medium) {
                    CPSLFileIcon(systemName: iconName, color: iconColor)

                    Text(entry.name)
                        .font(CPSLTheme.rowTitleFont)
                        .lineLimit(1)
                        .foregroundStyle(CPSLTheme.text)

                    if let accessMode {
                        CPSLICloudMountAccessBadge(accessMode: accessMode)
                    } else if isReadOnly {
                        CPSLFileReadOnlyBadge()
                    }

                    if let syncState = entry.syncState {
                        CPSLFileSyncStateBadge(state: syncState)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .disabled(isMoving && !entry.isDirectory)

            if case .browsing = mode, let onRemove {
                Menu {
                    if let accessMode, let onSetAccessMode {
                        if accessMode == .readWrite {
                            Button("Make Read Only") {
                                onSetAccessMode(.readOnly)
                            }
                        } else {
                            Button("Make Read & Write") {
                                onSetAccessMode(.readWrite)
                            }
                        }
                    }
                    if let onSetKeepDownloaded {
                        if entry.syncState != .keepDownloaded {
                            Button {
                                onSetKeepDownloaded(true)
                            } label: {
                                Label("Keep Downloaded", systemImage: "pin.circle")
                            }
                        }
                        if entry.syncState == .keepDownloaded {
                            Button {
                                onSetKeepDownloaded(false)
                            } label: {
                                Label("Remove Download", systemImage: "icloud")
                            }
                        }
                    }
                    Button(role: .destructive, action: onRemove) {
                        Label("Disconnect", systemImage: "eject.fill")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(CPSLTheme.iconSmallFont)
                        .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.secondaryText)
                .accessibilityLabel(Text("iCloud Folder Actions"))
            } else if case .browsing = mode, let onSetKeepDownloaded {
                CPSLFileICloudActionMenu(
                    syncState: entry.syncState,
                    onMove: canModify ? onMove : nil,
                    onDelete: canModify ? onDelete : nil,
                    onSetKeepDownloaded: onSetKeepDownloaded
                )
            } else if case .browsing = mode, canModify {
                CPSLFileActionMenu(onMove: onMove, onDelete: onDelete)
            }

            if case .browsing = mode, let onShare {
                CPSLFileShareButton(action: onShare)
            }
        }
        .padding(.leading, leadingPadding)
        .padding(.trailing, CPSLFileRowMetrics.trailing)
        .frame(height: CPSLFileRowMetrics.height)
        .contentShape(Rectangle())
    }

    private var leadingPadding: CGFloat {
        if case .selecting = mode {
            return CPSLFileRowMetrics.leading + CGFloat(depth) * CPSLFileRowMetrics.indent
        }
        return CPSLFileRowMetrics.leadingPadding(depth: depth, isDirectory: entry.isDirectory)
    }

    private var isMoving: Bool {
        if case .moving = mode {
            return true
        }
        return false
    }

    private var iconName: String {
        if entry.isDirectory {
            return "folder.fill"
        }
        return entry.previewCategory.systemImageName
    }

    private var iconColor: Color {
        if entry.isDirectory {
            return CPSLTheme.IconPalette.folder
        }
        return entry.previewCategory.iconColor
    }
}

private struct CPSLFileSelectionControl: View {
    let isSelected: Bool
    let isEnabled: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(CPSLTheme.iconMediumFont)
            .foregroundStyle(isEnabled ? CPSLTheme.mauve : CPSLTheme.mutedText)
            .frame(
                width: CPSLFileRowMetrics.disclosureWidth,
                height: CPSLFileRowMetrics.height
            )
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityHidden(true)
    }
}

private struct CPSLFileShareButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "square.and.arrow.up")
                .font(CPSLTheme.iconSmallFont)
                .frame(
                    width: CPSLFileRowMetrics.trailingControlWidth,
                    height: CPSLTheme.controlSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.secondaryText)
        .accessibilityLabel("Share")
        .help("Share")
    }
}

private struct CPSLFileActionMenu: View {
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Button(action: onMove) {
                Label("Move…", systemImage: "folder")
            }
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(CPSLTheme.iconSmallFont)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.secondaryText)
        .accessibilityLabel("File actions")
    }
}

private struct CPSLFileSyncStateBadge: View {
    let state: CPSLFileSyncState

    var body: some View {
        Image(systemName: state.systemImageName)
            .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.caption, weight: .semibold))
            .foregroundStyle(CPSLTheme.secondaryText)
            .accessibilityLabel(Text(state.accessibilityLabel))
    }
}

private struct CPSLFileICloudActionMenu: View {
    let syncState: CPSLFileSyncState?
    let onMove: (() -> Void)?
    let onDelete: (() -> Void)?
    let onSetKeepDownloaded: (Bool) -> Void

    var body: some View {
        Menu {
            if syncState != .keepDownloaded {
                Button {
                    onSetKeepDownloaded(true)
                } label: {
                    Label("Keep Downloaded", systemImage: "pin.circle")
                }
            }
            if syncState == .keepDownloaded || syncState == .local {
                Button {
                    onSetKeepDownloaded(false)
                } label: {
                    Label("Remove Download", systemImage: "icloud")
                }
            }
            if let onMove {
                Button(action: onMove) {
                    Label("Move…", systemImage: "folder")
                }
            }
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(CPSLTheme.iconSmallFont)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.secondaryText)
        .accessibilityLabel("File actions")
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
