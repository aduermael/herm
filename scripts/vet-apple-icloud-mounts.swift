import Foundation

nonisolated enum CPSLVirtualPath {
    static let iCloudRoot = "/icloud"
}

@main
private struct CPSLICloudMountChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "herm-mount-store-check-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let readOnly = CPSLICloudMountRecord(
            label: "Reference",
            slug: "reference",
            accessMode: .readOnly
        )
        let readWrite = CPSLICloudMountRecord(
            label: "Drafts",
            slug: "drafts",
            accessMode: .readWrite
        )

        try CPSLICloudMountStore.save([readOnly, readWrite], to: root)
        try require(
            try CPSLICloudMountStore.load(from: root) == [readWrite, readOnly],
            "mount records or access modes did not survive reload"
        )

        let readOnlyRoot = root.appendingPathComponent(readOnly.slug, isDirectory: true)
        let readWriteRoot = root.appendingPathComponent(readWrite.slug, isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readWriteRoot, withIntermediateDirectories: true)
        try Data("persisted".utf8).write(to: readWriteRoot.appendingPathComponent("note.txt"))

        let restoredMounts = try CPSLICloudMountStore.restoreMounts(from: root)
        try require(restoredMounts.map(\.accessMode) == [.readWrite, .readOnly],
                    "mount restore lost access modes")
        try require(
            try String(
                contentsOf: restoredMounts[0].hostURL.appendingPathComponent("note.txt"),
                encoding: .utf8
            ) == "persisted",
            "mount restore lost staged contents"
        )

        try FileManager.default.removeItem(at: readOnlyRoot)
        try require(
            try CPSLICloudMountStore.restoreMounts(from: root).map(\.slug) == [readWrite.slug],
            "missing staged directory was not pruned on restore"
        )

        try CPSLICloudMountStore.save([readWrite], to: root)
        try require(
            try CPSLICloudMountStore.load(from: root) == [readWrite],
            "removed mount returned after reload"
        )

        let mount = CPSLICloudMount(
            label: readWrite.label,
            slug: readWrite.slug,
            hostURL: root.appendingPathComponent(readWrite.slug),
            accessMode: readWrite.accessMode
        )
        try require(
            CPSLICloudMountResolver.mount(containing: "/icloud/drafts", in: [mount]) == mount,
            "mount resolver missed exact path"
        )
        try require(
            CPSLICloudMountResolver.mount(containing: "/icloud/drafts/file.txt", in: [mount]) == mount,
            "mount resolver missed descendant path"
        )
        try require(
            CPSLICloudMountResolver.mount(containing: "/icloud/drafts-old", in: [mount]) == nil,
            "mount resolver ignored a path-component boundary"
        )

        do {
            try CPSLICloudMountStore.save([readWrite, readWrite], to: root)
            throw CheckFailure("duplicate mount records were accepted")
        } catch CPSLICloudMountStoreError.invalidRegistry {
            // Expected.
        }

        try Data("not-json".utf8).write(
            to: root.appendingPathComponent(CPSLICloudMountStore.registryFileName),
            options: .atomic
        )
        do {
            _ = try CPSLICloudMountStore.load(from: root)
            throw CheckFailure("damaged mount registry was accepted")
        } catch CPSLICloudMountStoreError.invalidRegistry {
            // Expected.
        }
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
