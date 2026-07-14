import Foundation

nonisolated enum CPSLVirtualPath {
    static let iCloudRoot = "/icloud"
}

@main
private struct CPSLICloudMountManagerChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "herm-mount-manager-check-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let record = CPSLICloudMountRecord(
            label: "Drafts",
            slug: "drafts",
            accessMode: .readWrite
        )
        let mountRoot = root.appendingPathComponent(record.slug, isDirectory: true)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        try Data("persisted".utf8).write(to: mountRoot.appendingPathComponent("note.txt"))
        try CPSLICloudMountStore.save([record], to: root)

        let sharedManager = CPSLICloudMountManager.shared(stagingRoot: root)
        let equivalentRoot = root.appendingPathComponent(".", isDirectory: true)
        let secondSharedManager = CPSLICloudMountManager.shared(stagingRoot: equivalentRoot)
        try require(
            sharedManager === secondSharedManager,
            "equivalent staging roots did not share one mount manager"
        )

        try sharedManager.prepare()
        try secondSharedManager.prepare()
        let restored = try requireOnlyMount(secondSharedManager.mounts)
        try require(restored.accessMode == .readWrite, "restored mount lost read-write mode")
        try require(
            try String(contentsOf: restored.hostURL.appendingPathComponent("note.txt"), encoding: .utf8) ==
                "persisted",
            "restored mount lost staged contents"
        )

        guard let useLease = sharedManager.beginUse() else {
            throw CheckFailure("mount use lease was not admitted")
        }
        let initialRevision = useLease.revision
        try require(
            !secondSharedManager.beginUpdate(),
            "mount update was admitted while a use lease was active"
        )
        do {
            try secondSharedManager.removeMount(at: restored.virtualPath)
            throw CheckFailure("mount removal succeeded while a use lease was active")
        } catch CPSLICloudMountError.sessionBusy {
            // Expected: mutation methods acquire the process-wide update gate.
        }
        try require(
            secondSharedManager.mounts == [restored],
            "blocked mount removal changed shared state"
        )

        useLease.release()
        useLease.release()
        try require(
            secondSharedManager.beginUpdate(),
            "mount update stayed blocked after the use lease was released"
        )
        try require(
            sharedManager.beginUse() == nil,
            "mount use was admitted while an update was active"
        )
        secondSharedManager.finishUpdate()

        guard let unchangedLease = sharedManager.beginUse() else {
            throw CheckFailure("mount use did not resume after the update gate cleared")
        }
        try require(
            unchangedLease.revision == initialRevision,
            "a blocked mutation advanced the mount revision"
        )
        unchangedLease.release()

        try sharedManager.removeMount(at: restored.virtualPath)
        guard let changedLease = secondSharedManager.beginUse() else {
            throw CheckFailure("mount use did not resume after removal")
        }
        try require(
            changedLease.revision == initialRevision &+ 1,
            "successful mount removal did not advance the revision"
        )
        changedLease.release()
        let relaunchedManager = CPSLICloudMountManager(stagingRoot: root)
        try relaunchedManager.prepare()
        try require(relaunchedManager.mounts.isEmpty, "removed mount returned after relaunch")
    }

    private static func requireOnlyMount(_ mounts: [CPSLICloudMount]) throws -> CPSLICloudMount {
        guard mounts.count == 1, let mount = mounts.first else {
            throw CheckFailure("saved mount was not restored")
        }
        return mount
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

private struct CheckFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
