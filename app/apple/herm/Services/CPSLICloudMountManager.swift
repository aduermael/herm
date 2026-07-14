import Dispatch
import Foundation

#if canImport(Darwin)
nonisolated private final class CPSLFileCoordinatorCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinator: NSFileCoordinator?
    private var isCancelled = false

    func coordinateFileRead(
        at sourceURL: URL,
        accessor: (URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let wasCancelled = lock.withLock {
            if isCancelled {
                return true
            }
            self.coordinator = coordinator
            return false
        }
        guard !wasCancelled else {
            throw CancellationError()
        }
        defer {
            lock.withLock {
                if self.coordinator === coordinator {
                    self.coordinator = nil
                }
            }
        }

        var coordinatorError: NSError?
        var accessorError: Error?
        var didAccessSnapshot = false
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .forUploading,
            error: &coordinatorError
        ) { snapshotURL in
            didAccessSnapshot = true
            do {
                try accessor(snapshotURL)
            } catch {
                accessorError = error
            }
        }

        try Task.checkCancellation()
        if let accessorError {
            throw accessorError
        }
        if let coordinatorError {
            throw coordinatorError
        }
        guard didAccessSnapshot else {
            throw CPSLICloudStagingError.cannotEnumerateFolder
        }
    }

    func cancel() {
        let coordinator = lock.withLock {
            isCancelled = true
            return self.coordinator
        }
        coordinator?.cancel()
    }
}
#else
nonisolated private final class CPSLFileCoordinatorCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func coordinateFileRead(
        at sourceURL: URL,
        accessor: (URL) throws -> Void
    ) throws {
        guard !lock.withLock({ isCancelled }) else {
            throw CancellationError()
        }
        try accessor(sourceURL)
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
        }
    }
}
#endif

nonisolated private struct CPSLICloudDirectoryCopyRequest: Sendable {
    let sourceURL: URL
    let stagedURL: URL
    let permit: CPSLICloudStagingImportPermit
    let isWritable: Bool
    let progress: @Sendable (CPSLICloudImportProgress) -> Void
}

nonisolated final class CPSLICloudMountUseLease: @unchecked Sendable {
    let revision: UInt64

    private let lock = NSLock()
    private var manager: CPSLICloudMountManager?

    fileprivate init(manager: CPSLICloudMountManager, revision: UInt64) {
        self.manager = manager
        self.revision = revision
    }

    func release() {
        let manager = lock.withLock {
            let manager = self.manager
            self.manager = nil
            return manager
        }
        manager?.finishUse()
    }

    deinit {
        release()
    }
}

nonisolated private final class CPSLICloudMountManagerPool: @unchecked Sendable {
    private let lock = NSLock()
    private var managers: [String: CPSLICloudMountManager] = [:]

    func manager(for stagingRoot: URL) -> CPSLICloudMountManager {
        lock.withLock {
            let key = stagingRoot.resolvingSymlinksInPath().standardizedFileURL.path
            if let manager = managers[key] {
                return manager
            }
            let manager = CPSLICloudMountManager(stagingRoot: stagingRoot)
            managers[key] = manager
            return manager
        }
    }
}

/// Owns the process-wide persistent staged copies and virtual mounts used by CPSL.
nonisolated final class CPSLICloudMountManager: @unchecked Sendable {
    private static let pool = CPSLICloudMountManagerPool()

    static func shared(stagingRoot: URL) -> CPSLICloudMountManager {
        pool.manager(for: stagingRoot)
    }

    var mounts: [CPSLICloudMount] {
        withLock { storedMounts }
    }

    var isUpdating: Bool {
        withLock { updateInProgress }
    }

    var currentRevision: UInt64 {
        withLock { revision }
    }

    private let lock = NSLock()
    private let stagingRoot: URL
    private let fileManager: FileManager
    private var storedMounts: [CPSLICloudMount] = []
    private var updateInProgress = false
    private var activeUseCount = 0
    private var revision: UInt64 = 0
    private var isPrepared = false

    init(stagingRoot: URL, fileManager: FileManager = .default) {
        self.stagingRoot = stagingRoot
        self.fileManager = fileManager
    }

    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isPrepared else {
            return
        }

        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let rootValues = try stagingRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CPSLICloudMountError.savedMountUnavailable
        }

        let restoredMounts = try CPSLICloudMountStore.restoreMounts(
            from: stagingRoot,
            fileManager: fileManager
        )
        try removeUnregisteredItems(keeping: Set(restoredMounts.map(\.slug)))
        storedMounts = restoredMounts
        isPrepared = true
    }

    func stageReservedDirectory(
        from sourceURL: URL,
        accessMode: CPSLICloudMountAccessMode,
        progress: @escaping @Sendable (CPSLICloudImportProgress) -> Void
    ) async throws -> CPSLICloudMount {
        guard beginUpdate() else {
            throw CPSLICloudMountError.sessionBusy
        }
        var didChangeMounts = false
        defer {
            finishUpdate()
            if didChangeMounts {
                NotificationCenter.default.post(
                    name: CPSLICloudMountStore.didChangeNotification,
                    object: nil
                )
            }
        }
        try Task.checkCancellation()

#if canImport(Darwin)
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        guard didAccess else {
            throw CPSLICloudMountError.accessDenied
        }
        defer {
            sourceURL.stopAccessingSecurityScopedResource()
        }
#endif

        let values = try sourceURL.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .isUbiquitousItemKey,
                .localizedNameKey,
            ]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CPSLICloudMountError.notDirectory
        }
        guard values.isUbiquitousItem == true else {
            throw CPSLICloudMountError.unsupportedProvider
        }

        let label = Self.sanitizedMountLabel(values.localizedName ?? sourceURL.lastPathComponent)
        guard !Self.isHostURL(sourceURL, inside: stagingRoot) else {
            throw CPSLICloudMountError.invalidSource
        }

        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let usage = try CPSLICloudStagingStorage.currentUsage(
            of: try stagedContentRoots(),
            fileManager: fileManager
        )
        let permit = CPSLICloudStagingImportPermit(
            remainingUsage: CPSLICloudStagingUsage(
                bytes: max(0, CPSLICloudStagingStorage.maximumActiveUsage.bytes - usage.bytes),
                items: max(0, CPSLICloudStagingStorage.maximumActiveUsage.items - usage.items)
            ),
            availableCapacityBytes: try CPSLICloudStagingStorage.availableCapacity(
                at: stagingRoot,
                fileManager: fileManager
            )
        )
        let slug = uniqueMountSlug(for: label)
        let stagedURL = stagingRoot.appendingPathComponent(slug, isDirectory: true)
        do {
            _ = try await Self.copyDirectory(
                CPSLICloudDirectoryCopyRequest(
                    sourceURL: sourceURL,
                    stagedURL: stagedURL,
                    permit: permit,
                    isWritable: accessMode == .readWrite,
                    progress: progress
                )
            )
            try Task.checkCancellation()
        } catch {
            let originalError = error
            var cleanupFailed = false
            if fileManager.fileExists(atPath: stagedURL.path) {
                do {
                    try fileManager.removeItem(at: stagedURL)
                } catch {
                    cleanupFailed = true
                }
            }
            if cleanupFailed {
                throw CPSLICloudStagingError.cannotCleanUp
            }
            throw originalError
        }

        let mount = CPSLICloudMount(
            label: label,
            slug: slug,
            hostURL: stagedURL,
            accessMode: accessMode
        )
        let updatedMounts = (mounts + [mount]).sorted { $0.virtualPath < $1.virtualPath }
        do {
            try persist(updatedMounts)
        } catch {
            let persistenceError = error
            do {
                try fileManager.removeItem(at: stagedURL)
            } catch {
                throw CPSLICloudStagingError.cannotCleanUp
            }
            throw persistenceError
        }
        withLock {
            storedMounts = updatedMounts
            revision &+= 1
        }
        didChangeMounts = true
        return mount
    }

    func removeMount(at virtualPath: String) throws {
        guard beginUpdate() else {
            throw CPSLICloudMountError.sessionBusy
        }
        var didChangeMounts = false
        defer {
            finishUpdate()
            if didChangeMounts {
                NotificationCenter.default.post(
                    name: CPSLICloudMountStore.didChangeNotification,
                    object: nil
                )
            }
        }
        guard let mount = mounts.first(where: { $0.virtualPath == virtualPath }) else {
            throw CPSLICloudMountError.mountNotFound
        }

        let tombstoneURL = stagingRoot.appendingPathComponent(
            ".removing-\(UUID().uuidString)",
            isDirectory: true
        )
        let movedMount = fileManager.fileExists(atPath: mount.hostURL.path)
        if movedMount {
            try fileManager.moveItem(at: mount.hostURL, to: tombstoneURL)
        }

        let updatedMounts = mounts.filter { $0.virtualPath != virtualPath }
        do {
            try persist(updatedMounts)
        } catch {
            if movedMount {
                try? fileManager.moveItem(at: tombstoneURL, to: mount.hostURL)
            }
            throw error
        }
        withLock {
            storedMounts = updatedMounts
            revision &+= 1
        }
        didChangeMounts = true
        if movedMount {
            try? fileManager.removeItem(at: tombstoneURL)
        }
    }

    func containsHostURL(_ url: URL) -> Bool {
        mounts.contains { mount in
            Self.isHostURL(url, inside: mount.hostURL)
        }
    }

    func hostURL(for normalizedVirtualPath: String) -> URL? {
        for mount in mounts {
            if normalizedVirtualPath == mount.virtualPath {
                return mount.hostURL
            }
            let prefix = "\(mount.virtualPath)/"
            if normalizedVirtualPath.hasPrefix(prefix) {
                let relativePath = normalizedVirtualPath.dropFirst(prefix.count)
                return Self.appendingVirtualPath(relativePath, to: mount.hostURL)
            }
        }
        return nil
    }

    private static func copyDirectory(
        _ request: CPSLICloudDirectoryCopyRequest
    ) async throws -> CPSLICloudStagingUsage {
        let cancellationBox = CPSLFileCoordinatorCancellationBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try CPSLICloudStagingStorage.stageDirectory(
                CPSLICloudStagingRequest(
                    sourceRoot: request.sourceURL,
                    destinationRoot: request.stagedURL,
                    permit: request.permit,
                    isWritable: request.isWritable,
                    coordinateFileRead: { sourceURL, accessor in
                        try cancellationBox.coordinateFileRead(
                            at: sourceURL,
                            accessor: accessor
                        )
                    }
                ),
                progress: request.progress
            )
        } onCancel: {
            // A coordinator can cancel while waiting to vend its local
            // snapshot. Once the accessor starts, the chunked copy observes
            // Task cancellation directly.
            DispatchQueue.global(qos: .utility).async {
                cancellationBox.cancel()
            }
        }
    }

    private func uniqueMountSlug(for label: String) -> String {
        let baseSlug = Self.mountSlug(from: label)
        var slug = baseSlug
        var suffix = 2
        let usedSlugs = Set(mounts.map(\.slug))
        while usedSlugs.contains(slug) ||
            fileManager.fileExists(atPath: stagingRoot.appendingPathComponent(slug).path) {
            slug = "\(baseSlug)-\(suffix)"
            suffix += 1
        }
        return slug
    }

    func beginUpdate() -> Bool {
        withLock {
            guard !updateInProgress, activeUseCount == 0 else {
                return false
            }
            updateInProgress = true
            return true
        }
    }

    func finishUpdate() {
        withLock {
            updateInProgress = false
        }
    }

    func beginUse() -> CPSLICloudMountUseLease? {
        lock.lock()
        guard !updateInProgress else {
            lock.unlock()
            return nil
        }
        activeUseCount += 1
        let lease = CPSLICloudMountUseLease(manager: self, revision: revision)
        lock.unlock()
        return lease
    }

    fileprivate func finishUse() {
        withLock {
            precondition(activeUseCount > 0)
            activeUseCount -= 1
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer {
            lock.unlock()
        }
        return try operation()
    }

    private func persist(_ mounts: [CPSLICloudMount]) throws {
        try CPSLICloudMountStore.save(
            mounts.map {
                CPSLICloudMountRecord(
                    label: $0.label,
                    slug: $0.slug,
                    accessMode: $0.accessMode
                )
            },
            to: stagingRoot,
            fileManager: fileManager
        )
    }

    private func removeUnregisteredItems(keeping slugs: Set<String>) throws {
        let contents = try fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in contents where
            url.lastPathComponent != CPSLICloudMountStore.registryFileName &&
            !slugs.contains(url.lastPathComponent)
        {
            try fileManager.removeItem(at: url)
        }
    }

    private func stagedContentRoots() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.lastPathComponent != CPSLICloudMountStore.registryFileName }
    }

    private static func sanitizedMountLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "iCloud Folder"
        }
        return String(trimmed.prefix(120))
    }

    private static func mountSlug(from label: String) -> String {
        let lowercased = label.lowercased()
        var slug = ""
        var lastWasSeparator = false

        for scalar in lowercased.unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            if isLetter || isDigit {
                slug.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                slug.append("-")
                lastWasSeparator = true
            }
            if slug.count >= 64 {
                break
            }
        }

        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "icloud-folder" : slug
    }

    private static func appendingVirtualPath<T: StringProtocol>(
        _ relativePath: T,
        to baseURL: URL
    ) -> URL {
        var url = baseURL
        for component in relativePath.split(separator: "/") where !component.isEmpty {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private static func isHostURL(_ url: URL, inside rootURL: URL) -> Bool {
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix("\(rootPath)/")
    }
}

nonisolated enum CPSLICloudMountError: LocalizedError {
    case accessDenied
    case invalidSource
    case mountNotFound
    case notDirectory
    case savedMountUnavailable
    case sessionBusy
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Herm could not access the selected iCloud folder."
        case .invalidSource:
            return "Choose a folder outside Herm's staged iCloud storage."
        case .mountNotFound:
            return "iCloud mount is not available."
        case .notDirectory:
            return "Choose a folder from iCloud Drive."
        case .savedMountUnavailable:
            return "A saved iCloud folder copy is no longer available. Remove it and connect the folder again."
        case .sessionBusy:
            return "Wait for the current operation to finish."
        case .unsupportedProvider:
            return "Choose a folder from iCloud Drive, not another Files location."
        }
    }
}

nonisolated enum CPSLFileAccessError: LocalizedError {
    case outsideFilesystem

    var errorDescription: String? {
        switch self {
        case .outsideFilesystem:
            return "Location is outside the CPSL filesystem."
        }
    }
}
