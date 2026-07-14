import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

nonisolated struct CPSLICloudStagingUsage: Equatable, Sendable {
    let bytes: Int64
    let items: Int
}

nonisolated enum CPSLICloudImportPhase: Equatable, Sendable {
    case preparing
    case downloading
    case copying
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
        if totalBytes > 0 {
            return min(1, Double(completedBytes) / Double(totalBytes))
        }
        if totalItems > 0 {
            return min(1, Double(completedItems) / Double(totalItems))
        }
        return nil
    }
}

nonisolated enum CPSLICloudStagingError: LocalizedError, Equatable {
    case cannotCreateFile
    case cannotEnumerateFolder
    case cannotCleanUp
    case downloadFailed
    case downloadTimedOut
    case folderTooLarge
    case incompleteCopy
    case insufficientStorage
    case tooManyItems
    case unresolvedConflict
    case unsupportedItem

    var errorDescription: String? {
        switch self {
        case .cannotCreateFile:
            return "Herm could not create the staged iCloud copy."
        case .cannotEnumerateFolder:
            return "Herm could not read the selected iCloud folder."
        case .cannotCleanUp:
            return "Herm could not remove an incomplete staged iCloud copy."
        case .downloadFailed:
            return "Herm could not download an iCloud file."
        case .downloadTimedOut:
            return "iCloud did not finish downloading a file in time."
        case .folderTooLarge:
            let megabytes = CPSLICloudStagingStorage.maximumActiveUsage.bytes / (1_024 * 1_024)
            return "Connected iCloud folders are limited to \(megabytes) MB in total."
        case .incompleteCopy:
            return "An iCloud file changed before Herm could finish copying it."
        case .insufficientStorage:
            return "There is not enough free space to stage this iCloud folder."
        case .tooManyItems:
            let items = CPSLICloudStagingStorage.maximumActiveUsage.items.formatted()
            return "Connected iCloud folders are limited to \(items) items in total."
        case .unresolvedConflict:
            return "Resolve iCloud file conflicts before connecting this folder."
        case .unsupportedItem:
            return "The selected iCloud folder contains an unsupported file type."
        }
    }
}

nonisolated struct CPSLICloudStagingImportPermit: Sendable {
    let remainingUsage: CPSLICloudStagingUsage
    let availableCapacityBytes: Int64
}

typealias CPSLICloudCoordinatedFileRead = @Sendable (
    _ sourceURL: URL,
    _ accessor: (URL) throws -> Void
) throws -> Void

nonisolated struct CPSLICloudStagingRequest: Sendable {
    let sourceRoot: URL
    let destinationRoot: URL
    let permit: CPSLICloudStagingImportPermit
    let isWritable: Bool
    let materializeFile: @Sendable (URL) throws -> Void
    let coordinateFileRead: CPSLICloudCoordinatedFileRead

    init(
        sourceRoot: URL,
        destinationRoot: URL,
        permit: CPSLICloudStagingImportPermit,
        isWritable: Bool = false,
        materializeFile: @escaping @Sendable (URL) throws -> Void = {
            try CPSLICloudStagingStorage.materializeUbiquitousFile(at: $0)
        },
        coordinateFileRead: @escaping CPSLICloudCoordinatedFileRead = { sourceURL, accessor in
            try accessor(sourceURL)
        }
    ) {
        self.sourceRoot = sourceRoot
        self.destinationRoot = destinationRoot
        self.permit = permit
        self.isWritable = isWritable
        self.materializeFile = materializeFile
        self.coordinateFileRead = coordinateFileRead
    }
}

nonisolated enum CPSLICloudStagingStorage {
    static let maximumActiveUsage = CPSLICloudStagingUsage(
        bytes: 512 * 1_024 * 1_024,
        items: 10_000
    )
    static let freeSpaceReserveBytes: Int64 = 256 * 1_024 * 1_024

    private static let copyChunkBytes = 1 * 1_024 * 1_024
    private static let materializationPollInterval: TimeInterval = 0.1
    private static let materializationTimeout: TimeInterval = 10 * 60
    private static let progressByteInterval: Int64 = 4 * 1_024 * 1_024
    private static let progressItemInterval = 100

    static func currentUsage(
        of roots: [URL],
        fileManager: FileManager = .default
    ) throws -> CPSLICloudStagingUsage {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        var bytes: Int64 = 0
        var items = 0

        func include(_ values: URLResourceValues) throws {
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true
            else {
                throw CPSLICloudStagingError.unsupportedItem
            }
            let (nextItems, itemOverflow) = items.addingReportingOverflow(1)
            guard !itemOverflow else {
                throw CPSLICloudStagingError.tooManyItems
            }
            items = nextItems
            guard values.isRegularFile == true else {
                return
            }
            let size = Int64(max(0, values.fileSize ?? 0))
            let (nextBytes, byteOverflow) = bytes.addingReportingOverflow(size)
            guard !byteOverflow else {
                throw CPSLICloudStagingError.folderTooLarge
            }
            bytes = nextBytes
        }

        for root in roots {
            let rootValues = try root.resourceValues(forKeys: keys)
            try include(rootValues)
            guard rootValues.isDirectory == true else {
                continue
            }
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                }
            ) else {
                throw CPSLICloudStagingError.cannotEnumerateFolder
            }
            while let url = enumerator.nextObject() as? URL {
                try include(url.resourceValues(forKeys: keys))
            }
            if enumerationError != nil {
                throw CPSLICloudStagingError.cannotEnumerateFolder
            }
        }
        return CPSLICloudStagingUsage(bytes: bytes, items: items)
    }

    static func availableCapacity(
        at destination: URL,
        fileManager: FileManager = .default
    ) throws -> Int64 {
        let attributes = try fileManager.attributesOfFileSystem(forPath: destination.path)
        guard let freeSize = attributes[.systemFreeSize] as? NSNumber else {
            throw CPSLICloudStagingError.insufficientStorage
        }
        return max(0, freeSize.int64Value)
    }

    static func materializeUbiquitousFile(
        at url: URL,
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
        let deadline = ProcessInfo.processInfo.systemUptime + materializationTimeout
        var requestedDownload = false
        while true {
            try Task.checkCancellation()
            var refreshedURL = url
            refreshedURL.removeAllCachedResourceValues()
            let values: URLResourceValues
            do {
                values = try refreshedURL.resourceValues(forKeys: keys)
            } catch {
                throw CPSLICloudStagingError.downloadFailed
            }
            guard values.ubiquitousItemHasUnresolvedConflicts != true else {
                throw CPSLICloudStagingError.unresolvedConflict
            }
            guard values.ubiquitousItemDownloadingError == nil else {
                throw CPSLICloudStagingError.downloadFailed
            }
            if values.ubiquitousItemDownloadingStatus == .current {
                return
            }
            if !requestedDownload {
                do {
                    try fileManager.startDownloadingUbiquitousItem(at: url)
                } catch {
                    throw CPSLICloudStagingError.downloadFailed
                }
                requestedDownload = true
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CPSLICloudStagingError.downloadTimedOut
            }
            Thread.sleep(forTimeInterval: materializationPollInterval)
        }
#else
        _ = url
        _ = fileManager
        try Task.checkCancellation()
#endif
    }

    static func stageDirectory(
        _ request: CPSLICloudStagingRequest,
        fileManager: FileManager = .default,
        progress: @Sendable (CPSLICloudImportProgress) -> Void = { _ in }
    ) throws -> CPSLICloudStagingUsage {
        progress(.preparing)
        try Task.checkCancellation()

        let sourceRoot = request.sourceRoot
        let destinationRoot = request.destinationRoot
        let remainingUsage = request.permit.remainingUsage
        let availableCapacityBytes = request.permit.availableCapacityBytes

        guard availableCapacityBytes > freeSpaceReserveBytes else {
            throw CPSLICloudStagingError.insufficientStorage
        }
        let capacityForCopy = availableCapacityBytes - freeSpaceReserveBytes
        let actualByteLimit = min(remainingUsage.bytes, capacityForCopy)
        let actualByteLimitError: CPSLICloudStagingError =
            remainingUsage.bytes <= capacityForCopy ? .folderTooLarge : .insufficientStorage
        let manifest = try makeManifest(
            sourceRoot: sourceRoot,
            itemLimit: remainingUsage.items,
            byteLimit: actualByteLimit,
            byteLimitError: actualByteLimitError,
            isWritable: request.isWritable,
            materializeFile: request.materializeFile,
            fileManager: fileManager,
            progress: progress
        )
        guard manifest.usage.bytes <= remainingUsage.bytes else {
            throw CPSLICloudStagingError.folderTooLarge
        }

        guard manifest.usage.bytes <= capacityForCopy else {
            throw CPSLICloudStagingError.insufficientStorage
        }

        do {
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: false)
            var completedBytes: Int64 = 0
            var completedItems = 1
            var lastReportedBytes: Int64 = 0
            var lastReportedItems = 0

            func reportProgress(bytes: Int64? = nil, force: Bool = false) {
                let currentBytes = bytes ?? completedBytes
                let shouldReport = force ||
                    currentBytes - lastReportedBytes >= progressByteInterval ||
                    completedItems - lastReportedItems >= progressItemInterval
                guard shouldReport else {
                    return
                }
                progress(
                    CPSLICloudImportProgress(
                        phase: .copying,
                        completedBytes: currentBytes,
                        totalBytes: manifest.usage.bytes,
                        completedItems: completedItems,
                        totalItems: manifest.usage.items
                    )
                )
                lastReportedBytes = currentBytes
                lastReportedItems = completedItems
            }

            reportProgress(force: true)
            for item in manifest.items {
                try Task.checkCancellation()
                let destination = destinationURL(
                    root: destinationRoot,
                    relativeComponents: item.relativeComponents
                )
                switch item.kind {
                case .directory:
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
                case .file:
                    try request.materializeFile(item.sourceURL)
                    try Task.checkCancellation()
                    var nextCompletedBytes: Int64?
                    try request.coordinateFileRead(item.sourceURL) { coordinatedURL in
                        nextCompletedBytes = try copyFile(
                            FileCopyRequest(
                                source: coordinatedURL,
                                destination: destination,
                                byteLimit: actualByteLimit,
                                byteLimitError: actualByteLimitError,
                                expectedBytes: item.expectedBytes,
                                startingBytes: completedBytes
                            ),
                            fileManager: fileManager,
                            onChunk: { bytes in
                                reportProgress(bytes: bytes)
                            }
                        )
                    }
                    guard let nextCompletedBytes else {
                        throw CPSLICloudStagingError.incompleteCopy
                    }
                    completedBytes = nextCompletedBytes
                    try applyMetadata(item.metadata, to: destination, fileManager: fileManager)
                }
                completedItems += 1
                reportProgress()
            }

            // Directory dates change while children are created, so restore
            // their supported metadata from the leaves back to the root.
            for item in manifest.items.reversed() where item.kind == .directory {
                try Task.checkCancellation()
                try applyMetadata(
                    item.metadata,
                    to: destinationURL(
                        root: destinationRoot,
                        relativeComponents: item.relativeComponents
                    ),
                    fileManager: fileManager
                )
            }
            try Task.checkCancellation()
            try applyMetadata(manifest.rootMetadata, to: destinationRoot, fileManager: fileManager)

            try Task.checkCancellation()
            guard completedBytes == manifest.usage.bytes else {
                throw CPSLICloudStagingError.incompleteCopy
            }
            reportProgress(force: true)
            return CPSLICloudStagingUsage(bytes: completedBytes, items: completedItems)
        } catch {
            let originalError = error
            if fileManager.fileExists(atPath: destinationRoot.path) {
                do {
                    try fileManager.removeItem(at: destinationRoot)
                } catch {
                    throw CPSLICloudStagingError.cannotCleanUp
                }
            }
            throw originalError
        }
    }

    private enum ItemKind: Equatable {
        case directory
        case file
    }

    private struct ManifestItem {
        let sourceURL: URL
        let relativeComponents: [String]
        let kind: ItemKind
        let metadata: [FileAttributeKey: Any]
        let expectedBytes: Int64
    }

    private struct ManifestSeed {
        let sourceURL: URL
        let relativeComponents: [String]
        let kind: ItemKind
    }

    private struct Manifest {
        let items: [ManifestItem]
        let usage: CPSLICloudStagingUsage
        let rootMetadata: [FileAttributeKey: Any]
    }

    private struct FileCopyRequest {
        let source: URL
        let destination: URL
        let byteLimit: Int64
        let byteLimitError: CPSLICloudStagingError
        let expectedBytes: Int64
        let startingBytes: Int64
    }

    private static func makeManifest(
        sourceRoot: URL,
        itemLimit: Int,
        byteLimit: Int64,
        byteLimitError: CPSLICloudStagingError,
        isWritable: Bool,
        materializeFile: @Sendable (URL) throws -> Void,
        fileManager: FileManager,
        progress: @Sendable (CPSLICloudImportProgress) -> Void
    ) throws -> Manifest {
        guard itemLimit >= 1 else {
            throw CPSLICloudStagingError.tooManyItems
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let rootValues = try sourceRoot.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CPSLICloudStagingError.unsupportedItem
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CPSLICloudStagingError.cannotEnumerateFolder
        }

        let rootComponents = sourceRoot.standardizedFileURL.pathComponents
        var seeds: [ManifestSeed] = []
        var itemCount = 1

        while let sourceURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            itemCount += 1
            guard itemCount <= itemLimit else {
                throw CPSLICloudStagingError.tooManyItems
            }

            let values = try sourceURL.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                throw CPSLICloudStagingError.unsupportedItem
            }
            let kind: ItemKind
            if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .file
            } else {
                throw CPSLICloudStagingError.unsupportedItem
            }

            let components = sourceURL.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents), components.count > rootComponents.count else {
                throw CPSLICloudStagingError.cannotEnumerateFolder
            }
            seeds.append(
                ManifestSeed(
                    sourceURL: sourceURL,
                    relativeComponents: Array(components.dropFirst(rootComponents.count)),
                    kind: kind
                )
            )
        }

        if enumerationError != nil {
            throw CPSLICloudStagingError.cannotEnumerateFolder
        }

        let fileCount = seeds.lazy.filter { $0.kind == .file }.count
        var materializedFiles = 0
        if fileCount > 0 {
            progress(
                CPSLICloudImportProgress(
                    phase: .downloading,
                    completedBytes: 0,
                    totalBytes: 0,
                    completedItems: 0,
                    totalItems: fileCount
                )
            )
        }

        var items: [ManifestItem] = []
        var expectedBytes: Int64 = 0
        for seed in seeds {
            try Task.checkCancellation()
            var fileSize: Int64 = 0
            if seed.kind == .file {
                try materializeFile(seed.sourceURL)
                try Task.checkCancellation()
                let values = try seed.sourceURL.resourceValues(forKeys: [.fileSizeKey])
                guard let sourceFileSize = values.fileSize else {
                    throw CPSLICloudStagingError.cannotEnumerateFolder
                }
                fileSize = Int64(max(0, sourceFileSize))
                let (nextBytes, overflow) = expectedBytes.addingReportingOverflow(fileSize)
                guard !overflow, nextBytes <= byteLimit else {
                    throw byteLimitError
                }
                expectedBytes = nextBytes
                materializedFiles += 1
                progress(
                    CPSLICloudImportProgress(
                        phase: .downloading,
                        completedBytes: 0,
                        totalBytes: 0,
                        completedItems: materializedFiles,
                        totalItems: fileCount
                    )
                )
            }
            items.append(
                ManifestItem(
                    sourceURL: seed.sourceURL,
                    relativeComponents: seed.relativeComponents,
                    kind: seed.kind,
                    metadata: try copyableMetadata(
                        at: seed.sourceURL,
                        isDirectory: seed.kind == .directory,
                        isWritable: isWritable,
                        fileManager: fileManager
                    ),
                    expectedBytes: fileSize
                )
            )
        }
        let rootMetadata = try copyableMetadata(
            at: sourceRoot,
            isDirectory: true,
            isWritable: isWritable,
            fileManager: fileManager
        )
        return Manifest(
            items: items,
            usage: CPSLICloudStagingUsage(bytes: expectedBytes, items: itemCount),
            rootMetadata: rootMetadata
        )
    }

    private static func destinationURL(root: URL, relativeComponents: [String]) -> URL {
        relativeComponents.reduce(root) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }
    }

    private static func copyableMetadata(
        at url: URL,
        isDirectory: Bool,
        isWritable: Bool,
        fileManager: FileManager
    ) throws -> [FileAttributeKey: Any] {
        let source = try fileManager.attributesOfItem(atPath: url.path)
        var metadata: [FileAttributeKey: Any] = [:]
        if let permissions = source[.posixPermissions] as? NSNumber {
            let access = isDirectory ? 0o700 : (isWritable ? 0o600 : 0o400)
            metadata[.posixPermissions] = permissions.intValue & 0o777 | access
        } else if !isDirectory {
            metadata[.posixPermissions] = isWritable ? 0o600 : 0o400
        }
        metadata[.modificationDate] = source[.modificationDate]
#if canImport(Darwin)
        // Darwin supports restoring the creation date as well. Extended
        // attributes are intentionally excluded: CPSL does not expose them,
        // and file-provider metadata should not cross into the staging tree.
        metadata[.creationDate] = source[.creationDate]
#endif
        return metadata.compactMapValues { $0 }
    }

    private static func applyMetadata(
        _ metadata: [FileAttributeKey: Any],
        to destination: URL,
        fileManager: FileManager
    ) throws {
        guard !metadata.isEmpty else {
            return
        }
        try fileManager.setAttributes(metadata, ofItemAtPath: destination.path)
    }

    private static func copyFile(
        _ request: FileCopyRequest,
        fileManager: FileManager,
        onChunk: (Int64) -> Void
    ) throws -> Int64 {
        guard fileManager.createFile(atPath: request.destination.path, contents: nil) else {
            throw CPSLICloudStagingError.cannotCreateFile
        }

        let descriptor: Int32
#if canImport(Darwin)
        descriptor = Darwin.open(
            request.source.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
#elseif canImport(Glibc)
        descriptor = Glibc.open(
            request.source.path,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
#else
        descriptor = -1
#endif
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            _ = close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            _ = close(descriptor)
            throw CPSLICloudStagingError.unsupportedItem
        }

        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let output = try FileHandle(forWritingTo: request.destination)
        defer {
            try? input.close()
            try? output.close()
        }

        var completedBytes = request.startingBytes
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: copyChunkBytes), !data.isEmpty else {
                break
            }
            let (nextBytes, overflow) = completedBytes.addingReportingOverflow(Int64(data.count))
            guard !overflow, nextBytes <= request.byteLimit else {
                throw request.byteLimitError
            }
            try output.write(contentsOf: data)
            completedBytes = nextBytes
            onChunk(completedBytes)
        }
        guard completedBytes - request.startingBytes == request.expectedBytes else {
            throw CPSLICloudStagingError.incompleteCopy
        }
        return completedBytes
    }
}
