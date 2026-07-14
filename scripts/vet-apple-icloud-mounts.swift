import Foundation

nonisolated enum CPSLVirtualPath {
    static let iCloudRoot = "/icloud"
}

@main
private struct CPSLICloudMountChecks {
    static func main() throws {
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "herm-mount-store-check-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        try checkBookmarkRegistry(in: testRoot)
        try checkLegacyMigration(in: testRoot)
        try checkMountResolver(in: testRoot)
        try checkInvalidRegistries(in: testRoot)
    }

    private static func checkBookmarkRegistry(in testRoot: URL) throws {
        let storageRoot = testRoot.appendingPathComponent("registry", isDirectory: true)
        let readOnly = CPSLICloudMountRecord(
            label: "Reference",
            slug: "reference",
            accessMode: .readOnly,
            bookmarkData: Data("readonly-bookmark".utf8)
        )
        let readWrite = CPSLICloudMountRecord(
            label: "Drafts",
            slug: "drafts",
            accessMode: .readWrite,
            bookmarkData: Data("readwrite-bookmark".utf8)
        )

        try CPSLICloudMountStore.save([readOnly, readWrite], to: storageRoot)
        try require(
            try CPSLICloudMountStore.load(from: storageRoot) == [readWrite, readOnly],
            "bookmark records or access modes did not survive reload"
        )

        let registryData = try Data(
            contentsOf: storageRoot.appendingPathComponent(CPSLICloudMountStore.registryFileName)
        )
        let registry = try JSONSerialization.jsonObject(with: registryData) as? [String: Any]
        try require(registry?["version"] as? Int == 2, "bookmark registry was not version 2")
        try require(
            !(registryData.isEmpty),
            "bookmark registry was unexpectedly empty"
        )

        try CPSLICloudMountStore.save([readWrite], to: storageRoot)
        try require(
            try CPSLICloudMountStore.load(from: storageRoot) == [readWrite],
            "removed bookmark returned after reload"
        )
    }

    private static func checkLegacyMigration(in testRoot: URL) throws {
        let storageRoot = testRoot.appendingPathComponent("legacy", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("recovered", isDirectory: true)
        let stagedRoot = storageRoot.appendingPathComponent("drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: recoveryRoot.appendingPathComponent("drafts", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("old local copy".utf8).write(to: stagedRoot.appendingPathComponent("note.txt"))

        let legacyJSON = """
        {
          "version": 1,
          "mounts": [
            {"label": "Drafts", "slug": "drafts", "accessMode": "rw"}
          ]
        }
        """
        let legacyData = Data(legacyJSON.utf8)
        try legacyData.write(
            to: storageRoot.appendingPathComponent(CPSLICloudMountStore.registryFileName),
            options: .atomic
        )

        try require(
            try CPSLICloudMountStore.migrateLegacyRegistryIfNeeded(
                from: storageRoot,
                recoveryRoot: recoveryRoot
            ),
            "version 1 registry was not migrated"
        )
        try require(
            try CPSLICloudMountStore.load(from: storageRoot).isEmpty,
            "legacy records without bookmarks remained connected"
        )
        try require(
            !FileManager.default.fileExists(atPath: stagedRoot.path),
            "legacy app-private copy stayed hidden in mount storage"
        )
        let recoveredFile = recoveryRoot
            .appendingPathComponent("drafts-2", isDirectory: true)
            .appendingPathComponent("note.txt")
        try require(
            try String(contentsOf: recoveredFile, encoding: .utf8) == "old local copy",
            "legacy app-private copy was not preserved in the recovery folder"
        )
        try require(
            try Data(
                contentsOf: storageRoot.appendingPathComponent(
                    CPSLICloudMountStore.legacyRegistryFileName
                )
            ) == legacyData,
            "legacy registry backup did not preserve the original data"
        )
        try require(
            try !CPSLICloudMountStore.migrateLegacyRegistryIfNeeded(
                from: storageRoot,
                recoveryRoot: recoveryRoot
            ),
            "version 2 registry was migrated more than once"
        )
    }

    private static func checkMountResolver(in testRoot: URL) throws {
        let mount = CPSLICloudMount(
            label: "Drafts",
            slug: "drafts",
            hostURL: testRoot.appendingPathComponent("live-source", isDirectory: true),
            accessMode: .readWrite
        )
        try require(
            CPSLICloudMountResolver.mount(containing: "/icloud/drafts", in: [mount]) == mount,
            "mount resolver missed exact path"
        )
        try require(
            CPSLICloudMountResolver.mount(
                containing: "/icloud/drafts/file.txt",
                in: [mount]
            ) == mount,
            "mount resolver missed descendant path"
        )
        try require(
            CPSLICloudMountResolver.mount(containing: "/icloud/drafts-old", in: [mount]) == nil,
            "mount resolver ignored a path-component boundary"
        )
    }

    private static func checkInvalidRegistries(in testRoot: URL) throws {
        let storageRoot = testRoot.appendingPathComponent("invalid", isDirectory: true)
        let record = CPSLICloudMountRecord(
            label: "Drafts",
            slug: "drafts",
            accessMode: .readWrite,
            bookmarkData: Data("bookmark".utf8)
        )

        do {
            try CPSLICloudMountStore.save([record, record], to: storageRoot)
            throw CheckFailure("duplicate mount records were accepted")
        } catch CPSLICloudMountStoreError.invalidRegistry {
            // Expected.
        }

        let emptyBookmark = CPSLICloudMountRecord(
            label: "Drafts",
            slug: "drafts",
            accessMode: .readWrite,
            bookmarkData: Data()
        )
        do {
            try CPSLICloudMountStore.save([emptyBookmark], to: storageRoot)
            throw CheckFailure("empty bookmark was accepted")
        } catch CPSLICloudMountStoreError.invalidRegistry {
            // Expected.
        }

        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: storageRoot.appendingPathComponent(CPSLICloudMountStore.registryFileName),
            options: .atomic
        )
        do {
            _ = try CPSLICloudMountStore.load(from: storageRoot)
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
