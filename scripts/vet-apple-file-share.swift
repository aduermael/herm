import Foundation

/// Structural + pure-logic gates for file-browser share control, OS share wiring,
/// and sandbox virtual→host URL resolution used by share.
@main
private struct CPSLFileShareChecks {
    static func main() throws {
        let browser = try source("app/apple/herm/Views/Files/CPSLFileBrowserView.swift")
        let presenter = try source("app/apple/herm/Views/Shared/CPSLSharePresenter.swift")
        let chatScreen = try source("app/apple/herm/Views/Chat/CPSLChatScreen.swift")
        let chatModel = try source("app/apple/herm/Models/CPSLChatModel.swift")
        let debugService = try source("app/apple/herm/Services/CPSLDebugService.swift")
        let types = try source("app/apple/herm/Models/CPSLTypes.swift")

        try assertShareRowControl(browser: browser)
        try assertOSSharePresenter(presenter: presenter, chatScreen: chatScreen)
        try assertResolveWiring(
            chatModel: chatModel,
            debugService: debugService,
            types: types,
            browser: browser
        )
        try assertSandboxHostURLResolution()
        print("vet-apple-file-share: all checks passed")
    }

    private static func assertShareRowControl(browser: String) throws {
        try require(
            !browser.contains("struct CPSLFileShareButton"),
            "file browser must not define a dedicated trailing share button"
        )
        try require(
            browser.contains("Label(\"Share\", systemImage: \"square.and.arrow.up\")"),
            "ellipsis menus must include a Share action with the system share glyph"
        )
        let rowSlice = try requireSlice(
            in: browser,
            startingWith: "private struct CPSLFileRowView: View {",
            endingWith: "private struct CPSLFileSelectionControl: View {"
        )
        try require(
            !rowSlice.contains("CPSLFileShareButton"),
            "browsing file rows must not render a standalone share button"
        )
        try require(
            rowSlice.contains("canModify || onShare != nil") &&
                rowSlice.contains("CPSLFileActionMenu(") &&
                rowSlice.contains("onShare: onShare"),
            "browsing rows must surface Share via the ellipsis action menu"
        )
        try require(
            rowSlice.contains("CPSLFileICloudActionMenu(") &&
                rowSlice.contains("onShare: onShare"),
            "iCloud file ellipsis menu must also receive the share action"
        )
        try require(
            browser.contains("onShare: entry.isDirectory ? nil : {") ||
                browser.contains("onShare: entry.isDirectory ? nil :"),
            "directories must not receive a share action"
        )
        try require(
            !rowSlice.contains("if case .selecting = mode, let onShare") &&
                !rowSlice.contains("if case .moving = mode, let onShare"),
            "share must not be required in selecting/moving modes"
        )

        let actionMenu = try requireSlice(
            in: browser,
            startingWith: "private struct CPSLFileActionMenu: View {",
            endingWith: "private struct CPSLFileSyncStateBadge: View {"
        )
        try require(
            actionMenu.contains("if let onShare") &&
                actionMenu.contains("Label(\"Share\", systemImage: \"square.and.arrow.up\")"),
            "CPSLFileActionMenu must offer Share when onShare is set"
        )
    }

    private static func assertOSSharePresenter(presenter: String, chatScreen: String) throws {
        try require(
            presenter.contains("func cpslShareFile(file: Binding<CPSLShareableFile?>)"),
            "shared share presenter modifier must exist"
        )
        try require(
            presenter.contains("UIActivityViewController"),
            "iOS share path must use UIActivityViewController"
        )
        try require(
            presenter.contains("NSSharingServicePicker"),
            "macOS share path must use NSSharingServicePicker"
        )
        try require(
            presenter.contains("activityItems: [shareFile.url]") ||
                presenter.contains("activityItems: items") ||
                presenter.contains("items: [file.url]"),
            "share presenter must pass the resolved file URL as the share item"
        )
        try require(
            presenter.contains("prewarmIfNeeded") &&
                presenter.contains("UIActivityViewController"),
            "share infrastructure must prewarm UIActivityViewController before first user share"
        )
        try require(
            !presenter.contains("sheet(item: file)"),
            "iOS share must present UIActivityViewController from a host VC, not as a SwiftUI sheet root"
        )
        try require(
            chatScreen.contains(".cpslShareFile(file: $traceShareFile)"),
            "DEBUG JSON-trace share must reuse the shared OS share presenter"
        )
        try require(
            !chatScreen.contains("CPSLJSONTraceActivityView") &&
                !chatScreen.contains("CPSLJSONTraceSharingServicePicker"),
            "one-off DEBUG share UI wrappers must be removed after extraction"
        )
    }

    private static func assertResolveWiring(
        chatModel: String,
        debugService: String,
        types: String,
        browser: String
    ) throws {
        try require(
            debugService.contains("func resolveShareableHostFileURL("),
            "debug service must expose shareable host URL resolution"
        )
        let resolveSlice = try requireSlice(
            in: debugService,
            startingWith: "func resolveShareableHostFileURL(",
            endingWith: "func previewFile(_ entry: CPSLFileEntry)"
        )
        try require(
            resolveSlice.contains("materializeFile(at: entry.path)"),
            "share resolution must materialize iCloud files before sharing"
        )
        try require(
            resolveSlice.contains("hostURL(forVirtualPath: entry.path"),
            "share resolution must use the same hostURL path as preview"
        )
        try require(
            resolveSlice.contains("isBrowserHostURLAllowed"),
            "share resolution must stay inside the CPSL filesystem boundary"
        )
        try require(
            resolveSlice.contains("releaseGateRetainingScopes()"),
            "share resolution must retain iCloud scopes while presenting share"
        )
        try require(
            chatModel.contains("func resolveFileURLForSharing(_ entry: CPSLFileEntry)"),
            "chat model must expose share resolution for the file browser"
        )
        try require(
            chatModel.contains("service.resolveShareableHostFileURL(for: entry)"),
            "chat model share path must call the service resolution API"
        )
        try require(
            browser.contains("model.resolveFileURLForSharing(entry)") &&
                browser.contains(".cpslShareFile(file: $shareFile)"),
            "file browser must resolve via model then present the shared share UI"
        )
        try require(
            types.contains("struct CPSLShareableFile") &&
                types.contains("struct CPSLFileShareResolveResult"),
            "share result types must live with other file types"
        )
        try require(
            debugService.contains("CPSLSandboxHostURL.hostFileURL("),
            "hostURL must use the shared sandbox virtual→host mapper"
        )
    }

    private static func assertSandboxHostURLResolution() throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-file-share-check-\(UUID().uuidString)", isDirectory: true)
        let home = sandboxRoot.appendingPathComponent("home/herm", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let noteURL = home.appendingPathComponent("share-me.txt", isDirectory: false)
        try Data("hello-share".utf8).write(to: noteURL)

        let virtualPath = "/home/herm/share-me.txt"
        let resolved = CPSLSandboxHostURL.hostFileURL(
            virtualPath: virtualPath,
            sandboxRoot: sandboxRoot
        )
        try require(
            resolved.standardizedFileURL.path == noteURL.standardizedFileURL.path,
            "sandbox virtual path did not map to the host file URL"
        )
        try require(
            FileManager.default.fileExists(atPath: resolved.path),
            "resolved host URL must point at an existing file"
        )
        let contents = try String(contentsOf: resolved, encoding: .utf8)
        try require(contents == "hello-share", "resolved host file contents mismatch")

        let nested = CPSLSandboxHostURL.hostFileURL(
            virtualPath: "/home/herm/../herm/./share-me.txt",
            sandboxRoot: sandboxRoot
        )
        try require(
            nested.standardizedFileURL.path == noteURL.standardizedFileURL.path,
            "normalized virtual path mapping must collapse . and .."
        )

        let normalized = CPSLSandboxHostURL.normalize("  home/herm/share-me.txt  ")
        try require(
            normalized == "/home/herm/share-me.txt",
            "normalize must add leading slash and trim whitespace"
        )
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CheckFailure("could not read \(relativePath): \(error.localizedDescription)")
        }
    }

    private static func requireSlice(
        in source: String,
        startingWith start: String,
        endingWith end: String
    ) throws -> String {
        guard let startRange = source.range(of: start) else {
            throw CheckFailure("missing slice start: \(start)")
        }
        let fromStart = source[startRange.lowerBound...]
        guard let endRange = fromStart.range(of: end) else {
            throw CheckFailure("missing slice end after \(start): \(end)")
        }
        return String(fromStart[..<endRange.lowerBound])
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw CheckFailure(message)
        }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
