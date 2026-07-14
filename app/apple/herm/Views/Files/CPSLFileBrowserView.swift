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
    @State private var isICloudImporterPresented = false
    @State private var isICloudImporterPending = false
    @State private var isICloudAccessModePickerPresented = false
    @State private var isICloudAccessModePickerPending = false
    @State private var selectedICloudAccessMode: CPSLICloudMountAccessMode?

    var body: some View {
        browserPanel
            .fileImporter(
                isPresented: $isICloudImporterPresented,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        model.importICloudDirectory(
                            url,
                            accessMode: selectedICloudAccessMode ?? .readOnly
                        )
                    }
                case .failure(let error):
                    model.reportICloudImportError(error)
                }
                selectedICloudAccessMode = nil
            }
            .confirmationDialog(
                "iCloud Folder Access",
                isPresented: $isICloudAccessModePickerPresented,
                titleVisibility: .visible
            ) {
                Button("Read Only") {
                    chooseICloudAccessMode(.readOnly)
                }
                Button("Read & Write") {
                    chooseICloudAccessMode(.readWrite)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Read Only prevents Herm from changing the folder. Read & Write lets Herm add, edit, and delete files in the selected folder; iCloud Drive syncs those changes."
                )
            }
            .onChange(of: model.dictation.isActive) { _, isActive in
                if !isActive {
                    presentICloudAccessModePickerIfReady()
                    presentICloudImporterIfReady()
                }
            }
    }

    private var browserPanel: some View {
        CPSLFileOverlayPanel {
            CPSLFileBrowserHeader(model: model)
        } content: {
            CPSLFileBrowserRouteStack(
                model: model,
                connectICloud: connectICloud
            )
        }
    }

    private func connectICloud() {
        isICloudAccessModePickerPending = true
        model.dictation.finish()
        presentICloudAccessModePickerIfReady()
    }

    private func presentICloudAccessModePickerIfReady() {
        guard isICloudAccessModePickerPending, !model.dictation.isActive else {
            return
        }
        isICloudAccessModePickerPending = false
        isICloudAccessModePickerPresented = true
    }

    private func chooseICloudAccessMode(_ accessMode: CPSLICloudMountAccessMode) {
        selectedICloudAccessMode = accessMode
        isICloudImporterPending = true
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
    @ObservedObject var model: CPSLChatModel
    let connectICloud: () -> Void
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
                        actions: CPSLFileBrowserActions(model: model, connectICloud: connectICloud)
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
    let model: CPSLChatModel
    let connectICloud: () -> Void

    var iCloudMounts: [CPSLICloudMount] {
        model.iCloudMounts
    }

    var isBusy: Bool {
        model.isBusy
    }

    func loadPath(_ path: String) {
        model.loadBrowserPath(path)
    }

    func openEntry(_ entry: CPSLFileEntry) {
        model.openFileEntry(entry)
    }

    func toggleExpansion(_ entry: CPSLFileEntry) {
        model.toggleExpansion(for: entry)
    }

    init(model: CPSLChatModel, connectICloud: @escaping () -> Void) {
        self.model = model
        self.connectICloud = connectICloud
    }

    func removeICloudMount(_ entry: CPSLFileEntry) {
        model.removeICloudMount(entry)
    }

    func showComingSoon(_ message: String) {
        model.showComingSoon(message)
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

            if let preview = model.filePreview, preview.showsHeaderInfoButton {
                CPSLFilePreviewInfoButton(preview: preview)
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
    let preview: CPSLFilePreview
    @State private var isShowingInfo = false

    var body: some View {
        CPSLFileOverlayIconButton(
            systemName: "info.circle",
            accessibilityLabel: "File Info"
        ) {
            isShowingInfo = true
        }
        .popover(isPresented: $isShowingInfo) {
            CPSLFilePreviewInfoPopover(preview: preview)
        }
    }
}

private struct CPSLFilePreviewInfoPopover: View {
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
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380, maxHeight: 360)
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
            return CPSLTheme.IconPalette.cloud
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
                } else if snapshot.isLoading && snapshot.rows.isEmpty {
                    CPSLFileBrowserLoadingView()
                } else if snapshot.rows.isEmpty && snapshot.error == nil {
                    CPSLFileBrowserEmptyView()
                } else {
                    ForEach(snapshot.rows) { row in
                        CPSLFileBrowserRowView(row: row, actions: actions)
                    }
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
                    color: CPSLTheme.IconPalette.cloud
                ) {
                    actions.loadPath(CPSLVirtualPath.iCloudRoot)
                }
            }

            CPSLCloudConnectionRow(
                title: actions.iCloudMounts.isEmpty ? "iCloud" : "Add iCloud Folder",
                systemName: "icloud.fill",
                color: CPSLTheme.IconPalette.cloud,
                accessory: .singleIcon
            ) {
                actions.connectICloud()
            }
            .disabled(actions.isBusy)
            .opacity(actions.isBusy ? 0.45 : 1)

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
                .cpslSurfaceBackground(
                    in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                    tint: CPSLTheme.background.opacity(0.34),
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
                    onOpen: {
                        actions.openEntry(entry)
                    },
                    onToggleExpansion: {
                        actions.toggleExpansion(entry)
                    },
                    onRemove: iCloudMountRemoval(for: entry)
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
}

private struct CPSLFileRowView: View {
    let entry: CPSLFileEntry
    let depth: Int
    let isExpanded: Bool
    let accessMode: CPSLICloudMountAccessMode?
    let onOpen: () -> Void
    let onToggleExpansion: () -> Void
    let onRemove: (() -> Void)?

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

                    if let accessMode {
                        CPSLICloudMountAccessBadge(accessMode: accessMode)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(CPSLTheme.iconSmallFont)
                        .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.danger)
                .accessibilityLabel(Text("Remove iCloud Folder"))
            }
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
        return entry.previewCategory.systemImageName
    }

    private var iconColor: Color {
        if entry.isDirectory {
            return CPSLTheme.IconPalette.folder
        }
        return entry.previewCategory.iconColor
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
