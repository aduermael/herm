import Foundation

/// Access granted to CPSL for the original selected iCloud Drive folder.
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
    let bookmarkData: Data
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
    static let legacyRegistryFileName = "mounts-v1.json"
    static let didChangeNotification = Notification.Name("CPSLICloudMountStoreDidChange")

    private static let registryVersion = 2
    private static let legacyRegistryVersion = 1

    private struct Registry: Codable {
        let version: Int
        let mounts: [CPSLICloudMountRecord]
    }

    private struct RegistryHeader: Decodable {
        let version: Int
    }

    private struct LegacyRegistry: Decodable {
        let version: Int
        let mounts: [LegacyMountRecord]
    }

    private struct LegacyMountRecord: Decodable {
        let label: String
        let slug: String
        let accessMode: CPSLICloudMountAccessMode
    }

    static func load(
        from storageRoot: URL,
        fileManager: FileManager = .default
    ) throws -> [CPSLICloudMountRecord] {
        let registryURL = storageRoot.appendingPathComponent(registryFileName)
        guard fileManager.fileExists(atPath: registryURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: registryURL)
            let header = try JSONDecoder().decode(RegistryHeader.self, from: data)
            guard header.version == registryVersion else {
                throw CPSLICloudMountStoreError.unsupportedRegistry
            }
            let registry = try JSONDecoder().decode(Registry.self, from: data)
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

    /// Version 1 stored app-private copies without their iCloud source bookmark.
    /// Preserve those copies in the visible CPSL home before starting a v2 registry.
    static func migrateLegacyRegistryIfNeeded(
        from storageRoot: URL,
        recoveryRoot: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let registryURL = storageRoot.appendingPathComponent(registryFileName)
        guard fileManager.fileExists(atPath: registryURL.path) else {
            return false
        }

        let data: Data
        let header: RegistryHeader
        do {
            data = try Data(contentsOf: registryURL)
            header = try JSONDecoder().decode(RegistryHeader.self, from: data)
        } catch {
            throw CPSLICloudMountStoreError.invalidRegistry
        }
        guard header.version == legacyRegistryVersion else {
            return false
        }

        let legacy: LegacyRegistry
        do {
            legacy = try JSONDecoder().decode(LegacyRegistry.self, from: data)
        } catch {
            throw CPSLICloudMountStoreError.invalidRegistry
        }
        guard legacy.version == legacyRegistryVersion else {
            throw CPSLICloudMountStoreError.invalidRegistry
        }
        try validateLegacy(legacy.mounts)

        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        for record in legacy.mounts {
            let source = storageRoot.appendingPathComponent(record.slug, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else {
                continue
            }
            let destination = uniqueRecoveryURL(
                for: record.slug,
                in: recoveryRoot,
                fileManager: fileManager
            )
            try fileManager.moveItem(at: source, to: destination)
        }

        let backupURL = storageRoot.appendingPathComponent(legacyRegistryFileName)
        if !fileManager.fileExists(atPath: backupURL.path) {
            try data.write(to: backupURL, options: .atomic)
        }
        try save([], to: storageRoot, fileManager: fileManager)
        return true
    }

    private static func validated(
        _ records: [CPSLICloudMountRecord]
    ) throws -> [CPSLICloudMountRecord] {
        var slugs: Set<String> = []
        for record in records {
            guard isValidLabel(record.label),
                  isValidSlug(record.slug),
                  !record.bookmarkData.isEmpty,
                  slugs.insert(record.slug).inserted
            else {
                throw CPSLICloudMountStoreError.invalidRegistry
            }
        }
        return records
    }

    private static func validateLegacy(_ records: [LegacyMountRecord]) throws {
        var slugs: Set<String> = []
        for record in records {
            guard isValidLabel(record.label),
                  isValidSlug(record.slug),
                  slugs.insert(record.slug).inserted
            else {
                throw CPSLICloudMountStoreError.invalidRegistry
            }
        }
    }

    private static func isValidLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 120
    }

    private static func isValidSlug(_ slug: String) -> Bool {
        guard !slug.isEmpty,
              slug.count <= 64,
              slug.first != "-",
              slug.last != "-"
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

    private static func uniqueRecoveryURL(
        for slug: String,
        in recoveryRoot: URL,
        fileManager: FileManager
    ) -> URL {
        var candidate = recoveryRoot.appendingPathComponent(slug, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = recoveryRoot.appendingPathComponent(
                "\(slug)-\(suffix)",
                isDirectory: true
            )
            suffix += 1
        }
        return candidate
    }
}

nonisolated enum CPSLICloudMountStoreError: LocalizedError, Equatable {
    case cannotSaveRegistry
    case invalidRegistry
    case unsupportedRegistry

    var errorDescription: String? {
        switch self {
        case .cannotSaveRegistry:
            return "Herm could not save the connected iCloud folders."
        case .invalidRegistry:
            return "Herm's saved iCloud folder list is damaged."
        case .unsupportedRegistry:
            return "Herm's saved iCloud folder list was created by an unsupported version."
        }
    }
}
