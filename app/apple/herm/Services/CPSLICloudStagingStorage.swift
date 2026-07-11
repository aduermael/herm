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
    case folderTooLarge
    case importInProgress
    case insufficientStorage
    case tooManyItems
    case unsupportedItem

    var errorDescription: String? {
        switch self {
        case .cannotCreateFile:
            return "Herm could not create the staged iCloud copy."
        case .cannotEnumerateFolder:
            return "Herm could not read the selected iCloud folder."
        case .cannotCleanUp:
            return "Herm could not remove an incomplete staged iCloud copy."
        case .folderTooLarge:
            let megabytes = CPSLICloudStagingStorage.maximumActiveUsage.bytes / (1_024 * 1_024)
            return "Connected iCloud folders are limited to \(megabytes) MB in total."
        case .importInProgress:
            return "Another iCloud folder is already being added."
        case .insufficientStorage:
            return "There is not enough free space to stage this iCloud folder."
        case .tooManyItems:
            let items = CPSLICloudStagingStorage.maximumActiveUsage.items.formatted()
            return "Connected iCloud folders are limited to \(items) items in total."
        case .unsupportedItem:
            return "The selected iCloud folder contains an unsupported file type."
        }
    }
}

nonisolated struct CPSLICloudStagingImportPermit: Sendable {
    let remainingUsage: CPSLICloudStagingUsage
    let availableCapacityBytes: Int64
}

nonisolated struct CPSLICloudStagingRequest: Sendable {
    let sourceRoot: URL
    let destinationRoot: URL
    let permit: CPSLICloudStagingImportPermit
}

/// Owns the process root's advisory lock for the lifetime of the process.
/// A later process removes only roots whose owner lock is no longer held.
nonisolated final class CPSLICloudStagingProcessLease: @unchecked Sendable {
    let processRoot: URL

    private let ownerHandle: FileHandle
    private let fileManager: FileManager

    init(
        processRoot: URL,
        temporaryRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        self.processRoot = processRoot
        self.fileManager = fileManager

        let cleanupHandle = try Self.openLockFile(
            at: temporaryRoot.appendingPathComponent(".herm-icloud-cleanup.lock"),
            fileManager: fileManager
        )
        try Self.lock(cleanupHandle, operation: LOCK_EX)
        defer {
            Self.unlockAndClose(cleanupHandle)
        }

        try fileManager.createDirectory(at: processRoot, withIntermediateDirectories: true)
        let ownerURL = processRoot.appendingPathComponent(".owner.lock", isDirectory: false)
        let ownerHandle = try Self.openLockFile(at: ownerURL, fileManager: fileManager)
        do {
            try Self.lock(ownerHandle, operation: LOCK_EX | LOCK_NB)
            for staleRoot in try CPSLICloudStagingStorage.staleRoots(
                in: temporaryRoot,
                excluding: processRoot,
                fileManager: fileManager
            ) {
                try Self.removeRootIfInactive(staleRoot, fileManager: fileManager)
            }
        } catch {
            Self.unlockAndClose(ownerHandle)
            try? fileManager.removeItem(at: processRoot)
            throw error
        }
        self.ownerHandle = ownerHandle
    }

    deinit {
        Self.unlockAndClose(ownerHandle)
    }

    func prepareServiceRoot(_ serviceRoot: URL) throws {
        guard serviceRoot.deletingLastPathComponent().standardizedFileURL ==
                processRoot.standardizedFileURL
        else {
            throw CPSLICloudStagingError.cannotCreateFile
        }
        try fileManager.createDirectory(at: serviceRoot, withIntermediateDirectories: true)
    }

    private static func removeRootIfInactive(
        _ root: URL,
        fileManager: FileManager
    ) throws {
        let ownerURL = root.appendingPathComponent(".owner.lock", isDirectory: false)
        guard fileManager.fileExists(atPath: ownerURL.path) else {
            try makeRemovable(root, fileManager: fileManager)
            try fileManager.removeItem(at: root)
            return
        }

        let handle = try FileHandle(forUpdating: ownerURL)
        let lockResult = flock(handle.fileDescriptor, LOCK_EX | LOCK_NB)
        guard lockResult == 0 else {
            let code = errno
            try? handle.close()
            if code == EWOULDBLOCK || code == EAGAIN {
                return
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer {
            unlockAndClose(handle)
        }
        try makeRemovable(root, fileManager: fileManager)
        try fileManager.removeItem(at: root)
    }

    private static func makeRemovable(_ root: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw CPSLICloudStagingError.cannotCleanUp
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: url.path
                )
            }
        }
        if enumerationError != nil {
            throw CPSLICloudStagingError.cannotCleanUp
        }
    }

    private static func openLockFile(at url: URL, fileManager: FileManager) throws -> FileHandle {
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: Data()) else {
                throw CPSLICloudStagingError.cannotCreateFile
            }
        }
        return try FileHandle(forUpdating: url)
    }

    private static func lock(_ handle: FileHandle, operation: Int32) throws {
        guard flock(handle.fileDescriptor, operation) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func unlockAndClose(_ handle: FileHandle) {
        _ = flock(handle.fileDescriptor, LOCK_UN)
        try? handle.close()
    }
}

actor CPSLICloudStagingCoordinator {
    static let shared = CPSLICloudStagingCoordinator()

    private var lease: CPSLICloudStagingProcessLease?
    private var isImporting = false

    func prepare(
        serviceRoot: URL,
        processRoot: URL,
        temporaryRoot: URL
    ) throws {
        let lease = try processLease(processRoot: processRoot, temporaryRoot: temporaryRoot)
        try lease.prepareServiceRoot(serviceRoot)
    }

    func beginImport(
        serviceRoot: URL,
        processRoot: URL,
        temporaryRoot: URL
    ) throws -> CPSLICloudStagingImportPermit {
        guard !isImporting else {
            throw CPSLICloudStagingError.importInProgress
        }
        isImporting = true
        do {
            try prepare(
                serviceRoot: serviceRoot,
                processRoot: processRoot,
                temporaryRoot: temporaryRoot
            )
            let used = try CPSLICloudStagingStorage.currentUsage(in: processRoot)
            let remaining = CPSLICloudStagingUsage(
                bytes: max(0, CPSLICloudStagingStorage.maximumActiveUsage.bytes - used.bytes),
                items: max(0, CPSLICloudStagingStorage.maximumActiveUsage.items - used.items)
            )
            return CPSLICloudStagingImportPermit(
                remainingUsage: remaining,
                availableCapacityBytes: try CPSLICloudStagingStorage.availableCapacity(
                    at: serviceRoot
                )
            )
        } catch {
            isImporting = false
            throw error
        }
    }

    func finishImport() {
        isImporting = false
    }

    private func processLease(
        processRoot: URL,
        temporaryRoot: URL
    ) throws -> CPSLICloudStagingProcessLease {
        if let lease {
            guard lease.processRoot.standardizedFileURL == processRoot.standardizedFileURL else {
                throw CPSLICloudStagingError.cannotCreateFile
            }
            return lease
        }
        let lease = try CPSLICloudStagingProcessLease(
            processRoot: processRoot,
            temporaryRoot: temporaryRoot
        )
        self.lease = lease
        return lease
    }
}

nonisolated enum CPSLICloudStagingStorage {
    static let maximumActiveUsage = CPSLICloudStagingUsage(
        bytes: 512 * 1_024 * 1_024,
        items: 10_000
    )
    static let freeSpaceReserveBytes: Int64 = 256 * 1_024 * 1_024

    private static let rootPrefix = "herm-icloud-"
    private static let copyChunkBytes = 1 * 1_024 * 1_024
    private static let progressByteInterval: Int64 = 4 * 1_024 * 1_024
    private static let progressItemInterval = 100

    static func makeProcessRoot(in temporaryRoot: URL) -> URL {
        temporaryRoot.appendingPathComponent(
            "\(rootPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
    }

    static func makeServiceRoot(in processRoot: URL) -> URL {
        processRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    static func staleRoots(
        in temporaryRoot: URL,
        excluding currentProcessRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let currentPath = currentProcessRoot.standardizedFileURL.path
        let urls = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )

        return try urls.filter { url in
            guard url.standardizedFileURL.path != currentPath,
                url.lastPathComponent.hasPrefix(rootPrefix)
            else {
                return false
            }
            let suffix = String(url.lastPathComponent.dropFirst(rootPrefix.count))
            guard UUID(uuidString: suffix) != nil else {
                return false
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    static func currentUsage(
        in processRoot: URL,
        fileManager: FileManager = .default
    ) throws -> CPSLICloudStagingUsage {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        let serviceRoots = try fileManager.contentsOfDirectory(
            at: processRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        var bytes: Int64 = 0
        var items = 0
        for serviceRoot in serviceRoots {
            guard UUID(uuidString: serviceRoot.lastPathComponent) != nil,
                try serviceRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            else {
                continue
            }
            var enumerationError: Error?
            guard let enumerator = fileManager.enumerator(
                at: serviceRoot,
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
                let (nextItems, itemOverflow) = items.addingReportingOverflow(1)
                guard !itemOverflow else {
                    throw CPSLICloudStagingError.tooManyItems
                }
                items = nextItems
                let values = try url.resourceValues(forKeys: keys)
                if values.isRegularFile == true, values.isSymbolicLink != true {
                    let size = Int64(max(0, values.fileSize ?? 0))
                    let (nextBytes, byteOverflow) = bytes.addingReportingOverflow(size)
                    guard !byteOverflow else {
                        throw CPSLICloudStagingError.folderTooLarge
                    }
                    bytes = nextBytes
                }
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

        let manifest = try makeManifest(
            sourceRoot: sourceRoot,
            itemLimit: remainingUsage.items,
            fileManager: fileManager
        )
        guard manifest.usage.bytes <= remainingUsage.bytes else {
            throw CPSLICloudStagingError.folderTooLarge
        }

        guard availableCapacityBytes > freeSpaceReserveBytes else {
            throw CPSLICloudStagingError.insufficientStorage
        }
        let capacityForCopy = availableCapacityBytes - freeSpaceReserveBytes
        guard manifest.usage.bytes <= capacityForCopy else {
            throw CPSLICloudStagingError.insufficientStorage
        }

        let actualByteLimit = min(remainingUsage.bytes, capacityForCopy)
        let actualByteLimitError: CPSLICloudStagingError =
            remainingUsage.bytes <= capacityForCopy ? .folderTooLarge : .insufficientStorage
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
                case .symbolicLink:
                    let target = try fileManager.destinationOfSymbolicLink(atPath: item.sourceURL.path)
                    try fileManager.createSymbolicLink(
                        atPath: destination.path,
                        withDestinationPath: target
                    )
                case .file:
                    let nextCompletedBytes = try copyFile(
                        FileCopyRequest(
                            source: item.sourceURL,
                            destination: destination,
                            byteLimit: actualByteLimit,
                            byteLimitError: actualByteLimitError,
                            startingBytes: completedBytes
                        ),
                        fileManager: fileManager,
                        onChunk: { bytes in
                            reportProgress(bytes: bytes)
                        }
                    )
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
        case symbolicLink
    }

    private struct ManifestItem {
        let sourceURL: URL
        let relativeComponents: [String]
        let kind: ItemKind
        let metadata: [FileAttributeKey: Any]
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
        let startingBytes: Int64
    }

    private static func makeManifest(
        sourceRoot: URL,
        itemLimit: Int,
        fileManager: FileManager
    ) throws -> Manifest {
        guard itemLimit >= 1 else {
            throw CPSLICloudStagingError.tooManyItems
        }

        let rootMetadata = try copyableMetadata(
            at: sourceRoot,
            isDirectory: true,
            fileManager: fileManager
        )

        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
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
        var items: [ManifestItem] = []
        var expectedBytes: Int64 = 0
        var itemCount = 1

        while let sourceURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            itemCount += 1
            guard itemCount <= itemLimit else {
                throw CPSLICloudStagingError.tooManyItems
            }

            let values = try sourceURL.resourceValues(forKeys: keys)
            let isSymbolicLink = values.isSymbolicLink == true
            let kind: ItemKind
            if isSymbolicLink {
                kind = .symbolicLink
                enumerator.skipDescendants()
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .file
                let fileSize = Int64(max(0, values.fileSize ?? 0))
                let (nextBytes, overflow) = expectedBytes.addingReportingOverflow(fileSize)
                guard !overflow else {
                    throw CPSLICloudStagingError.folderTooLarge
                }
                expectedBytes = nextBytes
            } else {
                throw CPSLICloudStagingError.unsupportedItem
            }

            let components = sourceURL.standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents), components.count > rootComponents.count else {
                throw CPSLICloudStagingError.cannotEnumerateFolder
            }
            items.append(
                ManifestItem(
                    sourceURL: sourceURL,
                    relativeComponents: Array(components.dropFirst(rootComponents.count)),
                    kind: kind,
                    metadata: kind == .symbolicLink
                        ? [:]
                        : try copyableMetadata(
                            at: sourceURL,
                            isDirectory: kind == .directory,
                            fileManager: fileManager
                        )
                )
            )
        }

        if enumerationError != nil {
            throw CPSLICloudStagingError.cannotEnumerateFolder
        }
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
        fileManager: FileManager
    ) throws -> [FileAttributeKey: Any] {
        let source = try fileManager.attributesOfItem(atPath: url.path)
        var metadata: [FileAttributeKey: Any] = [:]
        if let permissions = source[.posixPermissions] as? NSNumber {
            let access = isDirectory ? 0o700 : 0
            metadata[.posixPermissions] = permissions.intValue & 0o777 | access
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
        return completedBytes
    }
}
