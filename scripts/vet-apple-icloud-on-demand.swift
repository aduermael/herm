import Foundation

nonisolated enum CPSLVirtualPath {
    static let iCloudRoot = "/icloud"
}

@main
private struct CPSLICloudOnDemandChecks {
    static func main() async throws {
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "herm-icloud-on-demand-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        try await checkConnectDoesNotWholeTreeMaterialize(in: testRoot)
        try checkEvalUsesPinnedOnly()
        try checkDefaultReadWriteImportPath()
        try checkMountRootKeepDownloadedUI()
        print("vet-apple-icloud-on-demand: ok")
    }

    private static func checkConnectDoesNotWholeTreeMaterialize(in testRoot: URL) async throws {
        let storageRoot = testRoot.appendingPathComponent("storage", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("recovery", isDirectory: true)
        let sourceRoot = testRoot.appendingPathComponent("Library", isDirectory: true)
        let nested = sourceRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let big = nested.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 4096).write(to: big)
        try Data("note".utf8).write(to: sourceRoot.appendingPathComponent("note.txt"))

        let recorder = MaterializeRecorder()
        let progress = ProgressRecorder()
        let manager = CPSLICloudMountManager(
            storageRoot: storageRoot,
            legacyRecoveryRoot: recoveryRoot,
            bookmarkAccess: recorder.makeAccess()
        )
        try manager.prepare()

        // Install spy by connecting through normal path — connect must not walk the tree.
        // We detect whole-tree materialize via progress phases (downloading) and by ensuring
        // connect succeeds without enumerating nested files into progress totals.
        let mount = try await manager.connectDirectory(
            from: sourceRoot,
            accessMode: .readWrite,
            progress: { progress.append($0) }
        )
        try require(mount.accessMode == .readWrite, "default connect lost read-write")
        try require(
            progress.values.allSatisfy { $0.phase == .preparing },
            "connect reported downloading/materialize progress for whole tree"
        )
        try require(
            progress.values.contains(where: { $0.totalItems > 0 }) == false,
            "connect enumerated tree files for materialize"
        )

        // Single-path materialize is available for content access.
        try await manager.materializeFile(at: "\(mount.virtualPath)/note.txt")
        try require(
            manager.hostURL(for: "\(mount.virtualPath)/note.txt") != nil,
            "single-path host resolution failed"
        )
    }

    private static func checkEvalUsesPinnedOnly() throws {
        let debugURL = URL(fileURLWithPath: "app/apple/herm/Services/CPSLDebugService.swift")
        let source = try String(contentsOf: debugURL, encoding: .utf8)
        try require(
            source.contains("materializePinnedContent()"),
            "eval path does not call materializePinnedContent"
        )
        try require(
            !source.contains("materializeMountsForAccess"),
            "eval path still whole-tree hydrates mounts"
        )
        try require(
            source.contains("// Metadata listing only"),
            "listDirectory missing metadata-only contract"
        )
        try require(
            source.contains("beginReadUse(for: prefetchPath)"),
            "listDirectory prefetch is not fire-and-forget after listing"
        )
        try require(
            source.contains("let prefetchURLs = urls"),
            "listDirectory does not capture URLs for background prefetch"
        )
        // Prefetch must not gate the return of entries (synchronous try? before return).
        try require(
            !source.contains("try? manager.prefetchSmallCloudFiles(at: urls)"),
            "listDirectory still blocking-calls prefetch before return"
        )
        let managerURL = URL(fileURLWithPath: "app/apple/herm/Services/CPSLICloudMountManager.swift")
        let managerSource = try String(contentsOf: managerURL, encoding: .utf8)
        try require(
            managerSource.contains("Download-on-demand"),
            "connect path missing download-on-demand contract"
        )
        // connectDirectory body must not call materializeDirectory(at: sourceURL)
        try require(
            !managerSource.contains("materializeDirectory(\n            at: sourceURL"),
            "connect still materializes the selected source tree"
        )
        try require(
            !managerSource.contains("materializeDirectory(\n            at: sourceURL,"),
            "connect still materializes the selected source tree (comma form)"
        )
    }

    private static func checkMountRootKeepDownloadedUI() throws {
        let browserURL = URL(fileURLWithPath: "app/apple/herm/Views/Files/CPSLFileBrowserView.swift")
        let source = try String(contentsOf: browserURL, encoding: .utf8)
        try require(
            source.contains("underMount"),
            "keep-downloaded setter does not cover mount roots"
        )
        try require(
            source.contains("entry.path == mount.virtualPath"),
            "mount root path equality missing from pin eligibility"
        )
        // Mount menu (onRemove branch) must offer Keep Downloaded, not only Disconnect.
        try require(
            source.contains("Label(\"Keep Downloaded\", systemImage: \"pin.circle\")"),
            "Keep Downloaded label missing from file browser menus"
        )
        // Mount action menu includes pin before Disconnect.
        let mountMenuHasPin = source.contains("if let onSetKeepDownloaded")
            && source.contains("Label(\"Disconnect\", systemImage: \"eject.fill\")")
        try require(mountMenuHasPin, "mount root menu missing keep-downloaded + disconnect")
    }

    private static func checkDefaultReadWriteImportPath() throws {
        let browserURL = URL(fileURLWithPath: "app/apple/herm/Views/Files/CPSLFileBrowserView.swift")
        let source = try String(contentsOf: browserURL, encoding: .utf8)
        try require(
            source.contains("accessMode: .readWrite"),
            "folder pick does not default to read-write"
        )
        try require(
            !source.contains("isICloudAccessModePickerPresented"),
            "post-pick access-mode dialog still present"
        )
        try require(
            !source.contains("iCloud Folder Access"),
            "post-pick access-mode confirmation copy still present"
        )
        try require(
            source.contains("Make Read Only"),
            "in-mount read-only toggle missing"
        )
        let modelURL = URL(fileURLWithPath: "app/apple/herm/Models/CPSLChatModel.swift")
        let modelSource = try String(contentsOf: modelURL, encoding: .utf8)
        try require(
            modelSource.contains("accessMode: CPSLICloudMountAccessMode = .readWrite"),
            "importICloudDirectory default is not read-write"
        )
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [CPSLICloudImportProgress] = []

    func append(_ value: CPSLICloudImportProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

private final class MaterializeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var createCount = 0
    private var bookmarks: [Data: URL] = [:]

    var activeScopeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func makeAccess() -> CPSLICloudBookmarkAccess {
        CPSLICloudBookmarkAccess(
            create: { [weak self] url, _ in
                guard let self else { return Data() }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.createCount += 1
                let data = Data(url.path.utf8)
                self.bookmarks[data] = url
                return data
            },
            resolve: { [weak self] data in
                guard let self else {
                    throw CPSLICloudBookmarkError.cannotResolve
                }
                self.lock.lock()
                defer { self.lock.unlock() }
                if let resolved = self.bookmarks[data] {
                    return CPSLICloudBookmarkResolution(url: resolved, isStale: false)
                }
                guard let path = String(data: data, encoding: .utf8), !path.isEmpty else {
                    throw CPSLICloudBookmarkError.cannotResolve
                }
                return CPSLICloudBookmarkResolution(
                    url: URL(fileURLWithPath: path),
                    isStale: false
                )
            },
            start: { [weak self] _ in
                guard let self else { return false }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.startCount += 1
                self.active += 1
                return true
            },
            stop: { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.stopCount += 1
                self.active -= 1
            }
        )
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw CheckFailure(message)
    }
}
