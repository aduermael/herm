import Foundation

nonisolated enum CPSLVirtualPath {
    static let iCloudRoot = "/icloud"
}

@main
private struct CPSLICloudMountManagerChecks {
    static func main() async throws {
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "herm-mount-manager-check-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        try checkSecurityScopeBalance(in: testRoot)
        try checkSharedManagerIdentity(in: testRoot)
#if !canImport(Darwin)
        try checkPartialRestore(in: testRoot)
        try await checkLiveSourceMounts(in: testRoot)
#endif
    }

    private static func checkSecurityScopeBalance(in testRoot: URL) throws {
        let recorder = BookmarkAccessRecorder()
        let scope = try CPSLICloudSecurityScope(
            url: testRoot,
            access: recorder.makeAccess()
        )
        try require(recorder.activeScopeCount == 1, "security scope did not start")
        scope.stop()
        scope.stop()
        try require(recorder.activeScopeCount == 0, "security scope was not stopped exactly once")
        try require(recorder.startCount == 1 && recorder.stopCount == 1, "scope calls were unbalanced")
    }

    private static func checkSharedManagerIdentity(in testRoot: URL) throws {
        let storageRoot = testRoot.appendingPathComponent("shared-storage", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("shared-recovery", isDirectory: true)
        let sharedManager = CPSLICloudMountManager.shared(
            storageRoot: storageRoot,
            legacyRecoveryRoot: recoveryRoot
        )
        let equivalentManager = CPSLICloudMountManager.shared(
            storageRoot: storageRoot.appendingPathComponent(".", isDirectory: true),
            legacyRecoveryRoot: recoveryRoot.appendingPathComponent(".", isDirectory: true)
        )
        try require(
            sharedManager === equivalentManager,
            "equivalent storage and recovery roots did not share one mount manager"
        )
    }

#if !canImport(Darwin)
    private static func checkPartialRestore(in testRoot: URL) throws {
        let storageRoot = testRoot.appendingPathComponent("partial-storage", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("partial-recovery", isDirectory: true)
        let sourceRoot = testRoot.appendingPathComponent("Reference", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let recorder = BookmarkAccessRecorder()
        let access = recorder.makeAccess()
        try CPSLICloudMountStore.save(
            [
                CPSLICloudMountRecord(
                    label: "Missing",
                    slug: "missing",
                    accessMode: .readOnly,
                    bookmarkData: Data("invalid".utf8)
                ),
                CPSLICloudMountRecord(
                    label: "Reference",
                    slug: "reference",
                    accessMode: .readOnly,
                    bookmarkData: try access.create(sourceRoot, .readOnly)
                ),
            ],
            to: storageRoot
        )
        let manager = CPSLICloudMountManager(
            storageRoot: storageRoot,
            legacyRecoveryRoot: recoveryRoot,
            bookmarkAccess: access
        )
        do {
            try manager.prepare()
            throw CheckFailure("partial restore did not report the unavailable bookmark")
        } catch CPSLICloudMountError.savedMountUnavailable {
            // Expected.
        }
        try require(manager.hasPreparedState, "partial restore discarded prepared state")
        try require(
            manager.mounts.map(\.slug) == ["reference"],
            "an unavailable bookmark hid a valid saved mount"
        )
        try manager.prepare()
        try require(
            recorder.startCount == recorder.stopCount,
            "partial restore left a security scope active"
        )
    }

    private static func checkLiveSourceMounts(in testRoot: URL) async throws {
        let storageRoot = testRoot.appendingPathComponent("storage", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("recovery", isDirectory: true)
        let sourceRoot = testRoot.appendingPathComponent("Drafts", isDirectory: true)
        let nestedRoot = sourceRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedRoot, withIntermediateDirectories: true)
        let sourceNote = sourceRoot.appendingPathComponent("note.txt")
        try Data("original".utf8).write(to: sourceNote)

        let bookmarkRecorder = BookmarkAccessRecorder()
        let progress = ProgressRecorder()
        let manager = CPSLICloudMountManager(
            storageRoot: storageRoot,
            legacyRecoveryRoot: recoveryRoot,
            bookmarkAccess: bookmarkRecorder.makeAccess()
        )
        try manager.prepare()
        let mount = try await manager.connectDirectory(
            from: sourceRoot,
            accessMode: .readWrite,
            progress: { progress.append($0) }
        )

        try require(mount.accessMode == .readWrite, "connected mount lost read-write mode")
        try require(
            mount.hostURL.standardizedFileURL == sourceRoot.standardizedFileURL,
            "mount host URL was not the selected source folder"
        )
        try require(
            manager.hostURL(for: "\(mount.virtualPath)/note.txt")?.standardizedFileURL ==
                sourceNote.standardizedFileURL,
            "virtual path did not resolve into the selected source folder"
        )
        try require(
            !FileManager.default.fileExists(
                atPath: storageRoot.appendingPathComponent(mount.slug, isDirectory: true).path
            ),
            "connecting a live mount created an app-private staged copy"
        )
        try require(
            progress.values.first == .preparing,
            "connecting did not report prepare progress"
        )
        try require(
            progress.values.allSatisfy { $0.phase == .preparing },
            "connecting eagerly materialize/downloaded the whole tree"
        )
        try require(
            bookmarkRecorder.startCount == bookmarkRecorder.stopCount,
            "connect leaked the picker security scope"
        )

        try Data("edited through mount".utf8).write(to: mount.hostURL.appendingPathComponent("note.txt"))
        try require(
            try String(contentsOf: sourceNote, encoding: .utf8) == "edited through mount",
            "write through a read-write mount did not change the source file"
        )
        let created = mount.hostURL.appendingPathComponent("created.txt")
        let renamed = mount.hostURL.appendingPathComponent("renamed.txt")
        try Data("new".utf8).write(to: created)
        try FileManager.default.moveItem(at: created, to: renamed)
        try require(
            FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("renamed.txt").path),
            "rename through the mount did not change the source folder"
        )
        try FileManager.default.removeItem(at: renamed)
        try require(
            !FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("renamed.txt").path),
            "delete through the mount did not change the source folder"
        )

        let records = try CPSLICloudMountStore.load(from: storageRoot)
        let record = try requireOnlyRecord(records)
        try require(!record.bookmarkData.isEmpty, "connected source did not persist a bookmark")
        try require(record.accessMode == .readWrite, "bookmark record lost access mode")

        bookmarkRecorder.markNextResolutionStale()
        let relaunchedManager = CPSLICloudMountManager(
            storageRoot: storageRoot,
            legacyRecoveryRoot: recoveryRoot,
            bookmarkAccess: bookmarkRecorder.makeAccess()
        )
        let createsBeforeRestore = bookmarkRecorder.createCount
        try relaunchedManager.prepare()
        let restored = try requireOnlyMount(relaunchedManager.mounts)
        try require(
            restored.hostURL.standardizedFileURL == sourceRoot.standardizedFileURL,
            "bookmark did not restore the selected source folder"
        )
        try require(
            bookmarkRecorder.createCount == createsBeforeRestore + 1,
            "stale bookmark was not refreshed"
        )

        guard let writer = try relaunchedManager.beginSessionUse() else {
            throw CheckFailure("read-write session lease was not admitted")
        }
        let initialRevision = writer.revision
        try require(
            try relaunchedManager.beginSessionUse() == nil,
            "second writer was admitted while a writer was active"
        )
        try require(
            try relaunchedManager.beginReadUse() == nil,
            "reader was admitted while a writer was active"
        )
        do {
            try relaunchedManager.removeMount(at: restored.virtualPath)
            throw CheckFailure("mount removal succeeded while a writer lease was active")
        } catch CPSLICloudMountError.sessionBusy {
            // Expected.
        }
        writer.release()
        writer.release()

        guard let firstReader = try relaunchedManager.beginReadUse(),
              let secondReader = try relaunchedManager.beginReadUse()
        else {
            throw CheckFailure("concurrent read leases were not admitted")
        }
        try require(
            try relaunchedManager.beginSessionUse() == nil,
            "writer was admitted while readers were active"
        )
        firstReader.release()
        secondReader.release()

        guard let previewUse = try relaunchedManager.beginReadUse(),
              let previewScope = previewUse.releaseGateRetainingScopes()
        else {
            throw CheckFailure("preview scope could not outlive its read gate")
        }
        try require(
            bookmarkRecorder.activeScopeCount == 1,
            "transferred preview scope was released too early"
        )
        guard let writerAfterPreviewLoad = try relaunchedManager.beginSessionUse() else {
            throw CheckFailure("preview security scope kept the writer gate locked")
        }
        writerAfterPreviewLoad.release()
        previewScope.release()

        do {
            _ = try await relaunchedManager.connectDirectory(
                from: nestedRoot,
                accessMode: .readOnly,
                progress: { _ in }
            )
            throw CheckFailure("overlapping source folder was connected")
        } catch CPSLICloudMountError.alreadyMounted {
            // Expected.
        }

        try relaunchedManager.removeMount(at: restored.virtualPath)
        try require(
            FileManager.default.fileExists(atPath: sourceNote.path),
            "disconnecting the mount deleted a source file"
        )
        try require(
            try String(contentsOf: sourceNote, encoding: .utf8) == "edited through mount",
            "disconnecting the mount changed source contents"
        )
        guard let changedLease = try relaunchedManager.beginReadUse() else {
            throw CheckFailure("read lease did not resume after removal")
        }
        try require(
            changedLease.revision == initialRevision &+ 1,
            "successful removal did not advance the mount revision"
        )
        changedLease.release()

        let finalManager = CPSLICloudMountManager(
            storageRoot: storageRoot,
            legacyRecoveryRoot: recoveryRoot,
            bookmarkAccess: bookmarkRecorder.makeAccess()
        )
        try finalManager.prepare()
        try require(finalManager.mounts.isEmpty, "removed bookmark returned after relaunch")
        try require(
            bookmarkRecorder.startCount == bookmarkRecorder.stopCount,
            "mount operations left a security scope active"
        )
    }
#endif

    private static func requireOnlyMount(_ mounts: [CPSLICloudMount]) throws -> CPSLICloudMount {
        guard mounts.count == 1, let mount = mounts.first else {
            throw CheckFailure("saved mount was not restored")
        }
        return mount
    }

    private static func requireOnlyRecord(
        _ records: [CPSLICloudMountRecord]
    ) throws -> CPSLICloudMountRecord {
        guard records.count == 1, let record = records.first else {
            throw CheckFailure("saved bookmark record was missing")
        }
        return record
    }

    private static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw CheckFailure(message)
        }
    }
}

private final class BookmarkAccessRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCreateCount = 0
    private var storedStartCount = 0
    private var storedStopCount = 0
    private var storedActiveScopeCount = 0
    private var nextResolutionIsStale = false

    var createCount: Int { lock.withLock { storedCreateCount } }
    var startCount: Int { lock.withLock { storedStartCount } }
    var stopCount: Int { lock.withLock { storedStopCount } }
    var activeScopeCount: Int { lock.withLock { storedActiveScopeCount } }

    func markNextResolutionStale() {
        lock.withLock {
            nextResolutionIsStale = true
        }
    }

    func makeAccess() -> CPSLICloudBookmarkAccess {
        CPSLICloudBookmarkAccess(
            create: { [self] url, accessMode in
                lock.withLock {
                    storedCreateCount += 1
                }
                return Data("\(accessMode.rawValue)\n\(url.standardizedFileURL.path)".utf8)
            },
            resolve: { [self] data in
                guard let value = String(data: data, encoding: .utf8),
                      let newline = value.firstIndex(of: "\n")
                else {
                    throw CPSLICloudBookmarkError.cannotResolve
                }
                let path = String(value[value.index(after: newline)...])
                let isStale = lock.withLock {
                    let value = nextResolutionIsStale
                    nextResolutionIsStale = false
                    return value
                }
                return CPSLICloudBookmarkResolution(
                    url: URL(fileURLWithPath: path, isDirectory: true),
                    isStale: isStale
                )
            },
            start: { [self] _ in
                lock.withLock {
                    storedStartCount += 1
                    storedActiveScopeCount += 1
                }
                return true
            },
            stop: { [self] _ in
                lock.withLock {
                    storedStopCount += 1
                    storedActiveScopeCount -= 1
                }
            }
        )
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [CPSLICloudImportProgress] = []

    var values: [CPSLICloudImportProgress] {
        lock.withLock { storedValues }
    }

    func append(_ value: CPSLICloudImportProgress) {
        lock.withLock {
            storedValues.append(value)
        }
    }
}

private struct CheckFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
