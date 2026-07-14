import Foundation

nonisolated enum CPSLICloudImportPhase: Equatable, Sendable {
    case preparing
    case downloading
    case cancelling
}

nonisolated struct CPSLICloudImportProgress: Equatable, Sendable {
    let phase: CPSLICloudImportPhase
    let completedBytes: Int64
    let totalBytes: Int64
    let completedItems: Int
    let totalItems: Int

    static let preparing = CPSLICloudImportProgress(
        phase: .preparing,
        completedBytes: 0,
        totalBytes: 0,
        completedItems: 0,
        totalItems: 0
    )

    var cancelling: CPSLICloudImportProgress {
        CPSLICloudImportProgress(
            phase: .cancelling,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            completedItems: completedItems,
            totalItems: totalItems
        )
    }

    var fractionCompleted: Double? {
        guard totalItems > 0 else {
            return nil
        }
        return min(1, Double(completedItems) / Double(totalItems))
    }
}

nonisolated enum CPSLICloudFileMaterializer {
    private static let pollInterval: TimeInterval = 0.1
    private static let timeout: TimeInterval = 10 * 60

    static func materializeDirectory(
        at root: URL,
        materialize: @Sendable (URL) throws -> Void = {
            try materializeUbiquitousFile($0)
        },
        progress: @Sendable (CPSLICloudImportProgress) -> Void = { _ in }
    ) throws {
        progress(.preparing)
        try Task.checkCancellation()

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CPSLICloudFileError.unsupportedItem
        }

        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CPSLICloudFileError.cannotEnumerateFolder
        }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw CPSLICloudFileError.unsupportedItem
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                throw CPSLICloudFileError.unsupportedItem
            }
            files.append(url)
        }
        if enumerationError != nil {
            throw CPSLICloudFileError.cannotEnumerateFolder
        }

        progress(downloadProgress(completedItems: 0, totalItems: files.count))
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            try materialize(file)
            progress(downloadProgress(completedItems: index + 1, totalItems: files.count))
        }
    }

    static func materializeUbiquitousFile(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
#if canImport(Darwin)
        try Task.checkCancellation()
        let identity = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
        guard identity.isUbiquitousItem == true else {
            return
        }

        let keys: Set<URLResourceKey> = [
            .ubiquitousItemDownloadingErrorKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemHasUnresolvedConflictsKey,
        ]
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var requestedDownload = false
        while true {
            try Task.checkCancellation()
            var refreshedURL = url
            refreshedURL.removeAllCachedResourceValues()
            let values: URLResourceValues
            do {
                values = try refreshedURL.resourceValues(forKeys: keys)
            } catch {
                throw CPSLICloudFileError.downloadFailed
            }
            guard values.ubiquitousItemHasUnresolvedConflicts != true else {
                throw CPSLICloudFileError.unresolvedConflict
            }
            guard values.ubiquitousItemDownloadingError == nil else {
                throw CPSLICloudFileError.downloadFailed
            }
            if values.ubiquitousItemDownloadingStatus == .current {
                return
            }
            if !requestedDownload {
                do {
                    try fileManager.startDownloadingUbiquitousItem(at: url)
                } catch {
                    throw CPSLICloudFileError.downloadFailed
                }
                requestedDownload = true
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CPSLICloudFileError.downloadTimedOut
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
#else
        _ = url
        _ = fileManager
        try Task.checkCancellation()
#endif
    }

    private static func downloadProgress(
        completedItems: Int,
        totalItems: Int
    ) -> CPSLICloudImportProgress {
        CPSLICloudImportProgress(
            phase: .downloading,
            completedBytes: 0,
            totalBytes: 0,
            completedItems: completedItems,
            totalItems: totalItems
        )
    }
}

nonisolated enum CPSLICloudFileError: LocalizedError, Equatable {
    case cannotEnumerateFolder
    case downloadFailed
    case downloadTimedOut
    case unresolvedConflict
    case unsupportedItem

    var errorDescription: String? {
        switch self {
        case .cannotEnumerateFolder:
            return "Herm could not read the selected iCloud folder."
        case .downloadFailed:
            return "Herm could not download an iCloud file."
        case .downloadTimedOut:
            return "iCloud did not finish downloading a file in time."
        case .unresolvedConflict:
            return "Resolve iCloud file conflicts before using this folder."
        case .unsupportedItem:
            return "The selected iCloud folder contains an unsupported file type."
        }
    }
}
