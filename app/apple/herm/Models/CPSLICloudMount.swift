import Foundation

/// Access inside CPSL. Both modes use a local staged copy; neither writes back to iCloud Drive.
nonisolated enum CPSLICloudMountAccessMode: String, Codable, Equatable, Sendable {
    case readOnly = "ro"
    case readWrite = "rw"

    var displayName: String {
        switch self {
        case .readOnly:
            return "Read Only"
        case .readWrite:
            return "Read & Write"
        }
    }

    var promptDescription: String {
        switch self {
        case .readOnly:
            return "read-only"
        case .readWrite:
            return "read-write"
        }
    }

    var systemImageName: String {
        switch self {
        case .readOnly:
            return "lock.fill"
        case .readWrite:
            return "lock.open.fill"
        }
    }
}

nonisolated struct CPSLICloudMount: Identifiable, Equatable, Sendable {
    let label: String
    let slug: String
    let hostURL: URL
    let accessMode: CPSLICloudMountAccessMode

    var id: String { slug }
    var virtualPath: String { "\(CPSLVirtualPath.iCloudRoot)/\(slug)" }
}

nonisolated struct CPSLICloudMountRecord: Codable, Equatable, Sendable {
    let label: String
    let slug: String
    let accessMode: CPSLICloudMountAccessMode
}

nonisolated enum CPSLICloudMountResolver {
    static func mount(
        containing virtualPath: String,
        in mounts: [CPSLICloudMount]
    ) -> CPSLICloudMount? {
        mounts
            .filter { mount in
                virtualPath == mount.virtualPath ||
                    virtualPath.hasPrefix("\(mount.virtualPath)/")
            }
            .max { $0.virtualPath.count < $1.virtualPath.count }
    }
}

nonisolated enum CPSLICloudMountStore {
    static let registryFileName = "mounts.json"
    static let didChangeNotification = Notification.Name("CPSLICloudMountStoreDidChange")
    private static let registryVersion = 1

    private struct Registry: Codable {
        let version: Int
        let mounts: [CPSLICloudMountRecord]
    }

    static func load(from storageRoot: URL, fileManager: FileManager = .default) throws
        -> [CPSLICloudMountRecord]
    {
        let registryURL = storageRoot.appendingPathComponent(registryFileName)
        guard fileManager.fileExists(atPath: registryURL.path) else {
            return []
        }

        do {
            let registry = try JSONDecoder().decode(
                Registry.self,
                from: Data(contentsOf: registryURL)
            )
            guard registry.version == registryVersion else {
                throw CPSLICloudMountStoreError.unsupportedRegistry
            }
            return try validated(registry.mounts)
        } catch let error as CPSLICloudMountStoreError {
            throw error
        } catch {
            throw CPSLICloudMountStoreError.invalidRegistry
        }
    }

    static func save(
        _ records: [CPSLICloudMountRecord],
        to storageRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let records = try validated(records).sorted { $0.slug < $1.slug }
        let registry = Registry(version: registryVersion, mounts: records)
        do {
            try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(registry)
            try data.write(
                to: storageRoot.appendingPathComponent(registryFileName),
                options: .atomic
            )
        } catch let error as CPSLICloudMountStoreError {
            throw error
        } catch {
            throw CPSLICloudMountStoreError.cannotSaveRegistry
        }
    }

    static func restoreMounts(
        from storageRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [CPSLICloudMount] {
        let records = try load(from: storageRoot, fileManager: fileManager)
        var mounts: [CPSLICloudMount] = []
        for record in records {
            let hostURL = storageRoot.appendingPathComponent(record.slug, isDirectory: true)
            guard fileManager.fileExists(atPath: hostURL.path) else {
                continue
            }
            let values = try hostURL.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  isHostURL(hostURL, inside: storageRoot)
            else {
                throw CPSLICloudMountStoreError.unavailableMount
            }
            mounts.append(
                CPSLICloudMount(
                    label: record.label,
                    slug: record.slug,
                    hostURL: hostURL,
                    accessMode: record.accessMode
                )
            )
        }
        mounts.sort { $0.virtualPath < $1.virtualPath }

        if mounts.count != records.count {
            try save(
                mounts.map {
                    CPSLICloudMountRecord(
                        label: $0.label,
                        slug: $0.slug,
                        accessMode: $0.accessMode
                    )
                },
                to: storageRoot,
                fileManager: fileManager
            )
        }
        return mounts
    }

    private static func validated(
        _ records: [CPSLICloudMountRecord]
    ) throws -> [CPSLICloudMountRecord] {
        var slugs: Set<String> = []
        for record in records {
            let trimmedLabel = record.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLabel.isEmpty,
                  trimmedLabel.count <= 120,
                  isValidSlug(record.slug),
                  slugs.insert(record.slug).inserted
            else {
                throw CPSLICloudMountStoreError.invalidRegistry
            }
        }
        return records
    }

    private static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty, slug.count <= 64,
              slug.first != "-", slug.last != "-"
        else {
            return false
        }
        return slug.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 97 && value <= 122) ||
                (value >= 48 && value <= 57) ||
                value == 45
        }
    }

    private static func isHostURL(_ url: URL, inside rootURL: URL) -> Bool {
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootPath || path.hasPrefix("\(rootPath)/")
    }
}

nonisolated enum CPSLICloudMountStoreError: LocalizedError, Equatable {
    case cannotSaveRegistry
    case invalidRegistry
    case unavailableMount
    case unsupportedRegistry

    var errorDescription: String? {
        switch self {
        case .cannotSaveRegistry:
            return "Herm could not save the connected iCloud folders."
        case .invalidRegistry:
            return "Herm's saved iCloud folder list is damaged."
        case .unavailableMount:
            return "A saved iCloud folder copy is no longer available."
        case .unsupportedRegistry:
            return "Herm's saved iCloud folder list was created by an unsupported version."
        }
    }
}
