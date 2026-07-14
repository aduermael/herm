import Foundation

nonisolated struct CPSLICloudBookmarkResolution: Sendable {
    let url: URL
    let isStale: Bool
}

nonisolated struct CPSLICloudBookmarkAccess: @unchecked Sendable {
    let create: @Sendable (URL, CPSLICloudMountAccessMode) throws -> Data
    let resolve: @Sendable (Data) throws -> CPSLICloudBookmarkResolution
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void

    static let live = CPSLICloudBookmarkAccess(
        create: { url, accessMode in
#if os(macOS)
            var options: URL.BookmarkCreationOptions = [.withSecurityScope]
            if accessMode == .readOnly {
                options.insert(.securityScopeAllowOnlyReadAccess)
            }
            return try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
#elseif canImport(Darwin)
            _ = accessMode
            return try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
#else
            _ = accessMode
            return Data(url.standardizedFileURL.path.utf8)
#endif
        },
        resolve: { bookmarkData in
#if canImport(Darwin)
            var isStale = false
#if os(macOS)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
#else
            let options: URL.BookmarkResolutionOptions = []
#endif
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return CPSLICloudBookmarkResolution(url: url, isStale: isStale)
#else
            guard let path = String(data: bookmarkData, encoding: .utf8), !path.isEmpty else {
                throw CPSLICloudBookmarkError.cannotResolve
            }
            return CPSLICloudBookmarkResolution(
                url: URL(fileURLWithPath: path, isDirectory: true),
                isStale: false
            )
#endif
        },
        start: { url in
#if canImport(Darwin)
            return url.startAccessingSecurityScopedResource()
#else
            _ = url
            return true
#endif
        },
        stop: { url in
#if canImport(Darwin)
            url.stopAccessingSecurityScopedResource()
#else
            _ = url
#endif
        }
    )
}

nonisolated final class CPSLICloudSecurityScope: @unchecked Sendable {
    let url: URL

    private let access: CPSLICloudBookmarkAccess
    private let lock = NSLock()
    private var isActive = true

    init(url: URL, access: CPSLICloudBookmarkAccess) throws {
        guard access.start(url) else {
            throw CPSLICloudBookmarkError.accessDenied
        }
        self.url = url
        self.access = access
    }

    func stop() {
        let shouldStop = lock.withLock {
            guard isActive else {
                return false
            }
            isActive = false
            return true
        }
        if shouldStop {
            access.stop(url)
        }
    }

    deinit {
        stop()
    }
}

nonisolated enum CPSLICloudBookmarkError: LocalizedError, Equatable {
    case accessDenied
    case cannotResolve

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Herm no longer has access to this iCloud folder. Connect it again."
        case .cannotResolve:
            return "Herm could not find this saved iCloud folder. Connect it again."
        }
    }
}
