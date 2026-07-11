import Dispatch
import Foundation

nonisolated private final class CPSLFileCoordinatorCancellationBox: @unchecked Sendable {
    let coordinator = NSFileCoordinator(filePresenter: nil)

    func cancel() {
        coordinator.cancel()
    }
}

nonisolated private struct CPSLICloudDirectoryCopyRequest: Sendable {
    let sourceURL: URL
    let stagedURL: URL
    let permit: CPSLICloudStagingImportPermit
    let progress: @Sendable (CPSLICloudImportProgress) -> Void
}

/// Owns the staged copies and virtual mounts used by one CPSL debug service.
/// The service actor is the sole caller, so mutations remain actor-isolated.
nonisolated final class CPSLICloudMountManager: @unchecked Sendable {
    private static let processRoot =
        CPSLICloudStagingStorage.makeProcessRoot(in: FileManager.default.temporaryDirectory)

    var mounts: [CPSLICloudMount] {
        withLock { storedMounts }
    }

    var isStaging: Bool {
        withLock { stagingInProgress }
    }

    private let lock = NSLock()
    private let stagingRoot: URL
    private var storedMounts: [CPSLICloudMount] = []
    private var stagingInProgress = false

    init() {
        stagingRoot = CPSLICloudStagingStorage.makeServiceRoot(in: Self.processRoot)
    }

    deinit {
        let stagingRoot = stagingRoot
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: stagingRoot)
        }
    }

    func prepare() async {
        try? await CPSLICloudStagingCoordinator.shared.prepare(
            serviceRoot: stagingRoot,
            processRoot: Self.processRoot,
            temporaryRoot: FileManager.default.temporaryDirectory
        )
    }

    func stageReservedDirectory(
        from sourceURL: URL,
        progress: @escaping @Sendable (CPSLICloudImportProgress) -> Void
    ) async throws -> CPSLICloudMount {
        try Task.checkCancellation()

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        guard didAccess else {
            throw CPSLICloudMountError.accessDenied
        }
        defer {
            sourceURL.stopAccessingSecurityScopedResource()
        }

        let values = try sourceURL.resourceValues(
            forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .localizedNameKey]
        )
        guard values.isDirectory == true else {
            throw CPSLICloudMountError.notDirectory
        }
        guard values.isUbiquitousItem == true else {
            throw CPSLICloudMountError.unsupportedProvider
        }

        let label = Self.sanitizedMountLabel(values.localizedName ?? sourceURL.lastPathComponent)
        guard !Self.isHostURL(sourceURL, inside: stagingRoot) else {
            throw CPSLICloudMountError.invalidSource
        }

        let permit = try await CPSLICloudStagingCoordinator.shared.beginImport(
            serviceRoot: stagingRoot,
            processRoot: Self.processRoot,
            temporaryRoot: FileManager.default.temporaryDirectory
        )
        let slug = uniqueMountSlug(for: label)
        let stagedURL = stagingRoot.appendingPathComponent(slug, isDirectory: true)
        do {
            _ = try await Self.copyDirectory(
                CPSLICloudDirectoryCopyRequest(
                    sourceURL: sourceURL,
                    stagedURL: stagedURL,
                    permit: permit,
                    progress: progress
                )
            )
            try Task.checkCancellation()
        } catch {
            let originalError = error
            var cleanupFailed = false
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                do {
                    try FileManager.default.removeItem(at: stagedURL)
                } catch {
                    cleanupFailed = true
                }
            }
            await CPSLICloudStagingCoordinator.shared.finishImport()
            if cleanupFailed {
                throw CPSLICloudStagingError.cannotCleanUp
            }
            throw originalError
        }

        let mount = CPSLICloudMount(label: label, slug: slug, hostURL: stagedURL)
        withLock {
            storedMounts.append(mount)
            storedMounts.sort { $0.virtualPath < $1.virtualPath }
        }
        await CPSLICloudStagingCoordinator.shared.finishImport()
        return mount
    }

    func removeMount(at virtualPath: String) throws {
        guard let mount = mounts.first(where: { $0.virtualPath == virtualPath }) else {
            throw CPSLICloudMountError.mountNotFound
        }

        if FileManager.default.fileExists(atPath: mount.hostURL.path) {
            try FileManager.default.removeItem(at: mount.hostURL)
        }
        withLock {
            storedMounts.removeAll { $0.virtualPath == virtualPath }
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
        let coordinator = cancellationBox.coordinator
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var coordinatorError: NSError?
            var copyError: Error?
            var stagingUsage: CPSLICloudStagingUsage?

            coordinator.coordinate(
                readingItemAt: request.sourceURL,
                options: [],
                error: &coordinatorError
            ) { coordinatedURL in
                do {
                    stagingUsage = try CPSLICloudStagingStorage.stageDirectory(
                        CPSLICloudStagingRequest(
                            sourceRoot: coordinatedURL,
                            destinationRoot: request.stagedURL,
                            permit: request.permit
                        ),
                        progress: request.progress
                    )
                } catch {
                    copyError = error
                }
            }

            try Task.checkCancellation()
            if let coordinatorError {
                throw coordinatorError
            }
            if let copyError {
                throw copyError
            }
            guard let stagingUsage else {
                throw CPSLICloudStagingError.cannotEnumerateFolder
            }
            return stagingUsage
        } onCancel: {
            // NSFileCoordinator may wait for an active accessor to return.
            // Never make the UI thread pay for that wait.
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
            FileManager.default.fileExists(atPath: stagingRoot.appendingPathComponent(slug).path) {
            slug = "\(baseSlug)-\(suffix)"
            suffix += 1
        }
        return slug
    }

    func beginStaging() -> Bool {
        withLock {
            guard !stagingInProgress else {
                return false
            }
            stagingInProgress = true
            return true
        }
    }

    func finishStaging() {
        withLock {
            stagingInProgress = false
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer {
            lock.unlock()
        }
        return try operation()
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
