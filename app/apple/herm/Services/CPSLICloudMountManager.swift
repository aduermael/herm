import Foundation

nonisolated private enum CPSLICloudMountUseKind: Sendable {
    case reader
    case writer
}

nonisolated final class CPSLICloudMountUseLease: @unchecked Sendable {
    let revision: UInt64

    private let lock = NSLock()
    private var manager: CPSLICloudMountManager?
    private var scopes: [CPSLICloudSecurityScope]
    private let kind: CPSLICloudMountUseKind

    fileprivate init(
        manager: CPSLICloudMountManager,
        revision: UInt64,
        kind: CPSLICloudMountUseKind,
        scopes: [CPSLICloudSecurityScope]
    ) {
        self.manager = manager
        self.revision = revision
        self.kind = kind
        self.scopes = scopes
    }

    func release() {
        let released = takeOwnership()
        for scope in released.1.reversed() {
            scope.stop()
        }
        released.0?.finishUse(kind)
    }

    func releaseGateRetainingScopes() -> CPSLICloudSecurityScopeLease? {
        let released = takeOwnership()
        released.0?.finishUse(kind)
        guard !released.1.isEmpty else {
            return nil
        }
        return CPSLICloudSecurityScopeLease(scopes: released.1)
    }

    deinit {
        release()
    }

    private func takeOwnership() -> (CPSLICloudMountManager?, [CPSLICloudSecurityScope]) {
        lock.withLock {
            let ownership = (manager, scopes)
            manager = nil
            scopes = []
            return ownership
        }
    }
}

nonisolated final class CPSLICloudSecurityScopeLease: @unchecked Sendable {
    private let lock = NSLock()
    private var scopes: [CPSLICloudSecurityScope]

    fileprivate init(scopes: [CPSLICloudSecurityScope]) {
        self.scopes = scopes
    }

    func release() {
        let released = lock.withLock {
            let scopes = self.scopes
            self.scopes = []
            return scopes
        }
        for scope in released.reversed() {
            scope.stop()
        }
    }

    deinit {
        release()
    }
}

nonisolated private final class CPSLICloudMountManagerPool: @unchecked Sendable {
    private let lock = NSLock()
    private var managers: [String: CPSLICloudMountManager] = [:]

    func manager(
        for storageRoot: URL,
        legacyRecoveryRoot: URL
    ) -> CPSLICloudMountManager {
        lock.withLock {
            let storagePath = storageRoot.resolvingSymlinksInPath().standardizedFileURL.path
            let recoveryPath = legacyRecoveryRoot.resolvingSymlinksInPath().standardizedFileURL.path
            let key = "\(storagePath)\n\(recoveryPath)"
            if let manager = managers[key] {
                return manager
            }
            let manager = CPSLICloudMountManager(
                storageRoot: storageRoot,
                legacyRecoveryRoot: legacyRecoveryRoot
            )
            managers[key] = manager
            return manager
        }
    }
}

/// Owns persistent bookmarks and process-wide access to live iCloud Drive mounts.
nonisolated final class CPSLICloudMountManager: @unchecked Sendable {
    private static let pool = CPSLICloudMountManagerPool()

    static func shared(
        storageRoot: URL,
        legacyRecoveryRoot: URL
    ) -> CPSLICloudMountManager {
        pool.manager(for: storageRoot, legacyRecoveryRoot: legacyRecoveryRoot)
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

    var hasPreparedState: Bool {
        withLock { isPrepared }
    }

    private let lock = NSLock()
    private let storageRoot: URL
    private let legacyRecoveryRoot: URL
    private let fileManager: FileManager
    private let bookmarkAccess: CPSLICloudBookmarkAccess
    private var storedMounts: [CPSLICloudMount] = []
    private var storedRecords: [CPSLICloudMountRecord] = []
    private var unavailableRecordSlugs: Set<String> = []
    /// Virtual paths the user asked to keep downloaded (file or folder).
    private var keepDownloadedPaths: Set<String> = []
    private var updateInProgress = false
    private var activeReaderCount = 0
    private var writerInProgress = false
    private var revision: UInt64 = 0
    private var isPrepared = false

    init(
        storageRoot: URL,
        legacyRecoveryRoot: URL,
        fileManager: FileManager = .default,
        bookmarkAccess: CPSLICloudBookmarkAccess = .live
    ) {
        self.storageRoot = storageRoot
        self.legacyRecoveryRoot = legacyRecoveryRoot
        self.fileManager = fileManager
        self.bookmarkAccess = bookmarkAccess
    }

    func prepare() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isPrepared else {
            return
        }

        try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let rootValues = try storageRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CPSLICloudMountError.savedMountUnavailable
        }

        let didMigrate = try CPSLICloudMountStore.migrateLegacyRegistryIfNeeded(
            from: storageRoot,
            recoveryRoot: legacyRecoveryRoot,
            fileManager: fileManager
        )
        let records = try CPSLICloudMountStore.load(
            from: storageRoot,
            fileManager: fileManager
        )

        var restoredMounts: [CPSLICloudMount] = []
        var refreshedRecords: [CPSLICloudMountRecord] = []
        var unavailableSlugs: Set<String> = []
        for record in records {
            do {
                let restored = try restore(record)
                guard !restoredMounts.contains(where: {
                    Self.pathsOverlap($0.hostURL, restored.mount.hostURL)
                }) else {
                    throw CPSLICloudMountError.alreadyMounted
                }
                refreshedRecords.append(restored.record)
                restoredMounts.append(restored.mount)
            } catch {
                refreshedRecords.append(record)
                unavailableSlugs.insert(record.slug)
            }
        }
        restoredMounts.sort { $0.virtualPath < $1.virtualPath }
        refreshedRecords.sort { $0.slug < $1.slug }
        if refreshedRecords != records {
            try persist(refreshedRecords)
        }
        storedMounts = restoredMounts
        storedRecords = refreshedRecords
        unavailableRecordSlugs = unavailableSlugs
        keepDownloadedPaths = (try? Self.loadKeepDownloadedPaths(from: storageRoot)) ?? []
        isPrepared = true

        if didMigrate {
            throw CPSLICloudMountError.legacyMountsNeedReconnect
        }
        if !unavailableSlugs.isEmpty {
            throw CPSLICloudMountError.savedMountUnavailable
        }
    }

    func connectDirectory(
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
                notifyMountsChanged()
            }
        }
        try Task.checkCancellation()
        progress(.preparing)

        let scope = try CPSLICloudSecurityScope(url: sourceURL, access: bookmarkAccess)
        defer { scope.stop() }
        try validateSource(sourceURL, accessMode: accessMode)
        guard !mounts.contains(where: { Self.pathsOverlap($0.hostURL, sourceURL) }) else {
            throw CPSLICloudMountError.alreadyMounted
        }
        // Download-on-demand: connect only persists the bookmark. Content is
        // materialized when a specific path is opened, pinned, or prefetched.
        try Task.checkCancellation()

        let values = try sourceURL.resourceValues(forKeys: [.localizedNameKey])
        let label = Self.sanitizedMountLabel(values.localizedName ?? sourceURL.lastPathComponent)
        let replacement = storedRecords.first {
            unavailableRecordSlugs.contains($0.slug) && $0.label == label
        }
        let slug = replacement?.slug ?? uniqueMountSlug(for: label)
        let record = CPSLICloudMountRecord(
            label: label,
            slug: slug,
            accessMode: accessMode,
            bookmarkData: try bookmarkAccess.create(sourceURL, accessMode)
        )
        let mount = CPSLICloudMount(
            label: label,
            slug: slug,
            hostURL: sourceURL,
            accessMode: accessMode
        )
        let updatedRecords = (storedRecords.filter { $0.slug != slug } + [record])
            .sorted { $0.slug < $1.slug }
        let updatedMounts = (mounts.filter { $0.slug != slug } + [mount])
            .sorted { $0.virtualPath < $1.virtualPath }
        try persist(updatedRecords)
        withLock {
            storedRecords = updatedRecords
            storedMounts = updatedMounts
            unavailableRecordSlugs.remove(slug)
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
                notifyMountsChanged()
            }
        }
        guard let mount = mounts.first(where: { $0.virtualPath == virtualPath }) else {
            throw CPSLICloudMountError.mountNotFound
        }

        let updatedRecords = storedRecords.filter { $0.slug != mount.slug }
        let updatedMounts = mounts.filter { $0.slug != mount.slug }
        let prunedPins = withLock {
            keepDownloadedPaths.filter {
                $0 != mount.virtualPath && !$0.hasPrefix("\(mount.virtualPath)/")
            }
        }
        try persist(updatedRecords)
        try Self.saveKeepDownloadedPaths(prunedPins, to: storageRoot)
        withLock {
            storedRecords = updatedRecords
            storedMounts = updatedMounts
            unavailableRecordSlugs.remove(mount.slug)
            keepDownloadedPaths = prunedPins
            revision &+= 1
        }
        didChangeMounts = true
    }

    func setAccessMode(
        _ accessMode: CPSLICloudMountAccessMode,
        at virtualPath: String
    ) throws {
        guard beginUpdate() else {
            throw CPSLICloudMountError.sessionBusy
        }
        var didChangeMounts = false
        defer {
            finishUpdate()
            if didChangeMounts {
                notifyMountsChanged()
            }
        }
        guard let index = storedMounts.firstIndex(where: { $0.virtualPath == virtualPath }),
              let recordIndex = storedRecords.firstIndex(where: {
                  $0.slug == storedMounts[index].slug
              })
        else {
            throw CPSLICloudMountError.mountNotFound
        }
        let mount = storedMounts[index]
        guard mount.accessMode != accessMode else {
            return
        }
        let scope = try CPSLICloudSecurityScope(url: mount.hostURL, access: bookmarkAccess)
        defer { scope.stop() }
        try validateSource(mount.hostURL, accessMode: accessMode)
        let bookmarkData = try bookmarkAccess.create(mount.hostURL, accessMode)
        var updatedRecords = storedRecords
        updatedRecords[recordIndex] = CPSLICloudMountRecord(
            label: mount.label,
            slug: mount.slug,
            accessMode: accessMode,
            bookmarkData: bookmarkData
        )
        var updatedMounts = storedMounts
        updatedMounts[index] = CPSLICloudMount(
            label: mount.label,
            slug: mount.slug,
            hostURL: mount.hostURL,
            accessMode: accessMode
        )
        try persist(updatedRecords)
        withLock {
            storedRecords = updatedRecords
            storedMounts = updatedMounts
            revision &+= 1
        }
        didChangeMounts = true
    }

    func isKeepDownloaded(_ normalizedVirtualPath: String) -> Bool {
        withLock {
            keepDownloadedPaths.contains { pin in
                normalizedVirtualPath == pin || normalizedVirtualPath.hasPrefix("\(pin)/")
            }
        }
    }

    func setKeepDownloaded(
        _ keep: Bool,
        at normalizedVirtualPath: String
    ) async throws {
        guard beginUpdate() else {
            throw CPSLICloudMountError.sessionBusy
        }
        defer { finishUpdate() }
        guard let url = hostURL(for: normalizedVirtualPath) else {
            throw CPSLICloudMountError.mountNotFound
        }
        let scope = try CPSLICloudSecurityScope(url: url, access: bookmarkAccess)
        defer { scope.stop() }

        var pins = withLock { keepDownloadedPaths }
        if keep {
            pins.insert(normalizedVirtualPath)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try CPSLICloudFileMaterializer.materializeDirectory(at: url)
            } else {
                try CPSLICloudFileMaterializer.materializeUbiquitousFile(url)
            }
        } else {
            pins.remove(normalizedVirtualPath)
#if canImport(Darwin)
            try? fileManager.evictUbiquitousItem(at: url)
#endif
        }
        try Self.saveKeepDownloadedPaths(pins, to: storageRoot)
        withLock { keepDownloadedPaths = pins }
    }

    func beginSessionUse() throws -> CPSLICloudMountUseLease? {
        try beginUse(isReadOnlyUse: false, scopedVirtualPath: nil)
    }

    func beginReadUse(
        for scopedVirtualPath: String? = nil
    ) throws -> CPSLICloudMountUseLease? {
        try beginUse(isReadOnlyUse: true, scopedVirtualPath: scopedVirtualPath)
    }

    /// Materialize only paths the user pinned to keep downloaded (not whole mounts).
    func materializePinnedContent() async throws {
        let pins = withLock { keepDownloadedPaths }
        for path in pins.sorted() {
            try Task.checkCancellation()
            guard let url = hostURL(for: path) else {
                continue
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try CPSLICloudFileMaterializer.materializeDirectory(at: url)
            } else {
                try CPSLICloudFileMaterializer.materializeUbiquitousFile(url)
            }
        }
    }

    func materializeFile(at normalizedVirtualPath: String) async throws {
        guard let url = hostURL(for: normalizedVirtualPath) else {
            throw CPSLICloudMountError.mountNotFound
        }
        try CPSLICloudFileMaterializer.materializeUbiquitousFile(url)
    }

    /// Bounded same-folder prefetch of tiny cloud-only files after a listing.
    func prefetchSmallCloudFiles(at hostURLs: [URL]) throws {
        guard !hostURLs.isEmpty else {
            return
        }
        var candidates: [(URL, Int64)] = []
        var total: Int64 = 0
        for url in hostURLs {
#if canImport(Darwin)
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ])
            guard values.isDirectory != true else {
                continue
            }
            let status = CPSLICloudSyncPolicy.downloadStatus(from: values)
            let state = CPSLICloudSyncPolicy.syncState(
                isUbiquitous: values.isUbiquitousItem,
                downloadStatus: status,
                isPinned: false
            )
            guard state == .cloudOnly,
                  CPSLICloudSyncPolicy.isSmallPrefetchCandidate(
                      fileBytes: Int64(values.fileSize ?? -1)
                  )
            else {
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            candidates.append((url, size))
            total += size
#else
            _ = url
#endif
        }
#if canImport(Darwin)
        guard CPSLICloudSyncPolicy.shouldPrefetchSmallCloudFiles(
            fileCount: candidates.count,
            totalBytes: total
        ) else {
            return
        }
        for (url, _) in candidates {
            try CPSLICloudFileMaterializer.materializeUbiquitousFile(url)
        }
#endif
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

    private func beginUse(
        isReadOnlyUse: Bool,
        scopedVirtualPath: String?
    ) throws -> CPSLICloudMountUseLease? {
        lock.lock()
        let requestsWriteAccess = !isReadOnlyUse &&
            storedMounts.contains { $0.accessMode == .readWrite }
        let kind: CPSLICloudMountUseKind = requestsWriteAccess ? .writer : .reader
        let canBegin = !updateInProgress &&
            !writerInProgress &&
            (!requestsWriteAccess || activeReaderCount == 0)
        guard canBegin else {
            lock.unlock()
            return nil
        }
        let mountURLs: [URL]
        if let scopedVirtualPath {
            guard let mount = storedMounts.first(where: {
                scopedVirtualPath == $0.virtualPath ||
                    scopedVirtualPath.hasPrefix("\($0.virtualPath)/")
            }) else {
                lock.unlock()
                throw CPSLICloudMountError.mountNotFound
            }
            mountURLs = [mount.hostURL]
        } else {
            mountURLs = storedMounts.map(\.hostURL)
        }
        if requestsWriteAccess {
            writerInProgress = true
        } else {
            activeReaderCount += 1
        }
        let revision = revision
        lock.unlock()

        var scopes: [CPSLICloudSecurityScope] = []
        do {
            for url in mountURLs {
                scopes.append(try CPSLICloudSecurityScope(url: url, access: bookmarkAccess))
            }
        } catch {
            for scope in scopes.reversed() {
                scope.stop()
            }
            finishUse(kind)
            throw error
        }
        return CPSLICloudMountUseLease(
            manager: self,
            revision: revision,
            kind: kind,
            scopes: scopes
        )
    }

    fileprivate func finishUse(_ kind: CPSLICloudMountUseKind) {
        withLock {
            switch kind {
            case .reader:
                precondition(activeReaderCount > 0)
                activeReaderCount -= 1
            case .writer:
                precondition(writerInProgress)
                writerInProgress = false
            }
        }
    }

    private func beginUpdate() -> Bool {
        withLock {
            guard !updateInProgress,
                  activeReaderCount == 0,
                  !writerInProgress
            else {
                return false
            }
            updateInProgress = true
            return true
        }
    }

    private func finishUpdate() {
        withLock {
            updateInProgress = false
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func persist(_ records: [CPSLICloudMountRecord]) throws {
        try CPSLICloudMountStore.save(
            records,
            to: storageRoot,
            fileManager: fileManager
        )
    }

    private static let keepDownloadedFileName = "keep-downloaded.json"

    private static func loadKeepDownloadedPaths(
        from storageRoot: URL
    ) throws -> Set<String> {
        let url = storageRoot.appendingPathComponent(keepDownloadedFileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        let paths = try JSONDecoder().decode([String].self, from: data)
        return Set(paths)
    }

    private static func saveKeepDownloadedPaths(
        _ paths: Set<String>,
        to storageRoot: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: storageRoot,
            withIntermediateDirectories: true
        )
        let url = storageRoot.appendingPathComponent(keepDownloadedFileName)
        let data = try JSONEncoder().encode(paths.sorted())
        try data.write(to: url, options: .atomic)
    }

    private func uniqueMountSlug(for label: String) -> String {
        let baseSlug = Self.mountSlug(from: label)
        var slug = baseSlug
        var suffix = 2
        let usedSlugs = Set(storedRecords.map(\.slug))
        while usedSlugs.contains(slug) {
            slug = "\(baseSlug)-\(suffix)"
            suffix += 1
        }
        return slug
    }

    private func validateSource(
        _ url: URL,
        accessMode: CPSLICloudMountAccessMode
    ) throws {
        var keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
#if canImport(Darwin)
        keys.formUnion([
            .isUbiquitousItemKey,
            .ubiquitousSharedItemCurrentUserPermissionsKey,
        ])
#endif
        let values = try url.resourceValues(forKeys: keys)
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CPSLICloudMountError.notDirectory
        }
#if canImport(Darwin)
        guard values.isUbiquitousItem == true else {
            throw CPSLICloudMountError.unsupportedProvider
        }
        if accessMode == .readWrite,
           values.ubiquitousSharedItemCurrentUserPermissions == .readOnly {
            throw CPSLICloudMountError.sourceIsReadOnly
        }
#else
        _ = accessMode
#endif
    }

    private func restoredBookmarkData(
        resolution: CPSLICloudBookmarkResolution,
        record: CPSLICloudMountRecord
    ) throws -> Data {
        guard resolution.isStale else {
            return record.bookmarkData
        }
        return try bookmarkAccess.create(resolution.url, record.accessMode)
    }

    private func restore(
        _ record: CPSLICloudMountRecord
    ) throws -> (record: CPSLICloudMountRecord, mount: CPSLICloudMount) {
        let resolution = try bookmarkAccess.resolve(record.bookmarkData)
        let scope = try CPSLICloudSecurityScope(
            url: resolution.url,
            access: bookmarkAccess
        )
        defer { scope.stop() }
        try validateSource(resolution.url, accessMode: record.accessMode)
        let bookmarkData = try restoredBookmarkData(
            resolution: resolution,
            record: record
        )
        return (
            CPSLICloudMountRecord(
                label: record.label,
                slug: record.slug,
                accessMode: record.accessMode,
                bookmarkData: bookmarkData
            ),
            CPSLICloudMount(
                label: record.label,
                slug: record.slug,
                hostURL: resolution.url,
                accessMode: record.accessMode
            )
        )
    }

    private func notifyMountsChanged() {
        NotificationCenter.default.post(
            name: CPSLICloudMountStore.didChangeNotification,
            object: nil
        )
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

    private static func pathsOverlap(_ first: URL, _ second: URL) -> Bool {
        let firstPath = first.resolvingSymlinksInPath().standardizedFileURL.path
        let secondPath = second.resolvingSymlinksInPath().standardizedFileURL.path
        return firstPath == secondPath ||
            firstPath.hasPrefix("\(secondPath)/") ||
            secondPath.hasPrefix("\(firstPath)/")
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
    case alreadyMounted
    case legacyMountsNeedReconnect
    case mountNotFound
    case notDirectory
    case savedMountUnavailable
    case sessionBusy
    case sourceIsReadOnly
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .alreadyMounted:
            return "This folder overlaps an iCloud folder that is already connected."
        case .legacyMountsNeedReconnect:
            return "Reconnect your iCloud folders. Previous local copies were preserved in /home/herm/recovered-icloud-copies."
        case .mountNotFound:
            return "iCloud mount is not available."
        case .notDirectory:
            return "Choose a folder from iCloud Drive."
        case .savedMountUnavailable:
            return "A saved iCloud folder is unavailable. Connect it again to restore access."
        case .sessionBusy:
            return "Wait for the current file operation to finish."
        case .sourceIsReadOnly:
            return "This shared iCloud folder does not allow you to make changes."
        case .unsupportedProvider:
            return "Choose a folder from iCloud Drive, not another Files location."
        }
    }
}

nonisolated enum CPSLFileAccessError: LocalizedError {
    case outsideFilesystem

    var errorDescription: String? {
        "Location is outside the CPSL filesystem."
    }
}
