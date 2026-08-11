import Foundation

@main
private struct CPSLICloudSyncPolicyChecks {
    static func main() throws {
        try checkSyncStateMapping()
        try checkSmallPrefetchBounds()
        try checkBrowserBindsSyncIcons()
        print("vet-apple-icloud-sync-policy: ok")
    }

    private static func checkSyncStateMapping() throws {
        try require(
            CPSLICloudSyncPolicy.syncState(
                isUbiquitous: false,
                downloadStatus: .notDownloaded,
                isPinned: false
            ) == nil,
            "non-ubiquitous items should have no sync badge"
        )
        try require(
            CPSLICloudSyncPolicy.syncState(
                isUbiquitous: true,
                downloadStatus: .notDownloaded,
                isPinned: false
            ) == .cloudOnly,
            "not-downloaded ubiquitous item should be cloudOnly"
        )
        try require(
            CPSLICloudSyncPolicy.syncState(
                isUbiquitous: true,
                downloadStatus: .current,
                isPinned: false
            ) == .local,
            "current ubiquitous item should be local"
        )
        try require(
            CPSLICloudSyncPolicy.syncState(
                isUbiquitous: true,
                downloadStatus: .downloaded,
                isPinned: false
            ) == .local,
            "downloaded ubiquitous item should be local"
        )
        try require(
            CPSLICloudSyncPolicy.syncState(
                isUbiquitous: true,
                downloadStatus: .notDownloaded,
                isPinned: true
            ) == .keepDownloaded,
            "pinned items should report keepDownloaded"
        )
        try require(
            CPSLFileSyncState.cloudOnly.systemImageName == "icloud",
            "cloud-only icon missing"
        )
        try require(
            CPSLFileSyncState.local.systemImageName == "checkmark.icloud",
            "local icon missing"
        )
        try require(
            CPSLFileSyncState.keepDownloaded.systemImageName == "pin.circle.fill",
            "keep-downloaded icon missing"
        )
    }

    private static func checkSmallPrefetchBounds() throws {
        try require(
            CPSLICloudSyncPolicy.shouldPrefetchSmallCloudFiles(fileCount: 3, totalBytes: 1024),
            "small folder should prefetch"
        )
        try require(
            !CPSLICloudSyncPolicy.shouldPrefetchSmallCloudFiles(fileCount: 0, totalBytes: 0),
            "empty folder should not prefetch"
        )
        try require(
            !CPSLICloudSyncPolicy.shouldPrefetchSmallCloudFiles(
                fileCount: CPSLICloudSyncPolicy.smallPrefetchMaxFiles + 1,
                totalBytes: 1024
            ),
            "too many files should not prefetch"
        )
        try require(
            !CPSLICloudSyncPolicy.shouldPrefetchSmallCloudFiles(
                fileCount: 2,
                totalBytes: CPSLICloudSyncPolicy.smallPrefetchMaxTotalBytes + 1
            ),
            "too many bytes should not prefetch"
        )
        try require(
            CPSLICloudSyncPolicy.isSmallPrefetchCandidate(
                fileBytes: CPSLICloudSyncPolicy.smallPrefetchMaxFileBytes
            ),
            "boundary file size should qualify"
        )
        try require(
            !CPSLICloudSyncPolicy.isSmallPrefetchCandidate(
                fileBytes: CPSLICloudSyncPolicy.smallPrefetchMaxFileBytes + 1
            ),
            "oversized file should not qualify"
        )
    }

    private static func checkBrowserBindsSyncIcons() throws {
        let browserURL = URL(fileURLWithPath: "app/apple/herm/Views/Files/CPSLFileBrowserView.swift")
        let source = try String(contentsOf: browserURL, encoding: .utf8)
        try require(
            source.contains("CPSLFileSyncStateBadge"),
            "file browser does not bind sync-state badge"
        )
        try require(
            source.contains("entry.syncState"),
            "file row does not read entry.syncState"
        )
        try require(
            source.contains("state.systemImageName"),
            "sync badge does not use systemImageName"
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
