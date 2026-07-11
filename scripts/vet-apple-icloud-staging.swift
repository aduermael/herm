import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
private struct CPSLICloudStagingChecks {
    static func main() async throws {
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "herm-staging-check-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: testRoot)
        }

        try checkStaleRootCleanup(in: testRoot)
        try checkBoundedCopy(in: testRoot)
        try checkSpecialFileRejection(in: testRoot)
        try await checkCancellation(in: testRoot)
    }

    private static func checkStaleRootCleanup(in testRoot: URL) throws {
        let temporaryRoot = testRoot.appendingPathComponent("cleanup", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)

        let nearMatch = temporaryRoot.appendingPathComponent("herm-icloud-not-a-uuid", isDirectory: true)
        let unrelated = temporaryRoot.appendingPathComponent("unrelated", isDirectory: true)
        let activeRoot = CPSLICloudStagingStorage.makeProcessRoot(in: temporaryRoot)
        let activeLease = try CPSLICloudStagingProcessLease(
            processRoot: activeRoot,
            temporaryRoot: temporaryRoot
        )
        let staleRoot = temporaryRoot.appendingPathComponent(
            "herm-icloud-\(UUID().uuidString)",
            isDirectory: true
        )
        let processRoot = CPSLICloudStagingStorage.makeProcessRoot(in: temporaryRoot)
        let serviceRoot = CPSLICloudStagingStorage.makeServiceRoot(in: processRoot)
        for url in [staleRoot, nearMatch, unrelated, processRoot] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let lease = try CPSLICloudStagingProcessLease(
            processRoot: processRoot,
            temporaryRoot: temporaryRoot
        )
        try lease.prepareServiceRoot(serviceRoot)
        try require(!FileManager.default.fileExists(atPath: staleRoot.path), "stale root was not removed")
        try require(FileManager.default.fileExists(atPath: nearMatch.path), "near-match root was removed")
        try require(FileManager.default.fileExists(atPath: unrelated.path), "unrelated root was removed")
        try require(FileManager.default.fileExists(atPath: activeRoot.path), "active process root was removed")
        try require(FileManager.default.fileExists(atPath: serviceRoot.path), "current service root is missing")

        try lease.prepareServiceRoot(serviceRoot)
        try require(FileManager.default.fileExists(atPath: serviceRoot.path), "cleanup was not idempotent")
        withExtendedLifetime(activeLease) {}
    }

    private static func checkBoundedCopy(in testRoot: URL) throws {
        let source = testRoot.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: source.appendingPathComponent("a.bin"))
        try Data([5, 6, 7]).write(to: nested.appendingPathComponent("b.bin"))
        let sourceFile = source.appendingPathComponent("a.bin")
        let modificationDate = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640, .modificationDate: modificationDate],
            ofItemAtPath: sourceFile.path
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: nested.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
        }

        let exactDestination = testRoot.appendingPathComponent("exact", isDirectory: true)
        let progress = ProgressRecorder()
        let usage = try CPSLICloudStagingStorage.stageDirectory(
            from: source,
            to: exactDestination,
            remainingUsage: CPSLICloudStagingUsage(bytes: 7, items: 4),
            availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 7,
            progress: { value in
                progress.append(value)
            }
        )
        try require(usage == CPSLICloudStagingUsage(bytes: 7, items: 4), "exact-limit usage was wrong")
        try require(progress.last?.fractionCompleted == 1, "copy progress did not complete")
        try require(
            try Data(contentsOf: exactDestination.appendingPathComponent("nested/b.bin")) == Data([5, 6, 7]),
            "staged file contents changed"
        )
        let copiedAttributes = try FileManager.default.attributesOfItem(
            atPath: exactDestination.appendingPathComponent("a.bin").path
        )
        try require(
            (copiedAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o640,
            "staged file permissions changed"
        )
        let copiedDate = copiedAttributes[.modificationDate] as? Date
        try require(
            copiedDate.map { abs($0.timeIntervalSince(modificationDate)) < 1 } == true,
            "staged file modification date changed"
        )
        let copiedRootAttributes = try FileManager.default.attributesOfItem(
            atPath: exactDestination.path
        )
        let copiedRootPermissions = (copiedRootAttributes[.posixPermissions] as? NSNumber)?.intValue
        try require(
            copiedRootPermissions.map { $0 & 0o700 == 0o700 } == true,
            "staged directory was not kept removable"
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)

        let processRoot = testRoot.appendingPathComponent("usage-process", isDirectory: true)
        let serviceRoot = CPSLICloudStagingStorage.makeServiceRoot(in: processRoot)
        try FileManager.default.createDirectory(at: serviceRoot, withIntermediateDirectories: true)
        let orphan = serviceRoot.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.copyItem(at: exactDestination, to: orphan)
        let processUsage = try CPSLICloudStagingStorage.currentUsage(in: processRoot)
        try require(
            processUsage == CPSLICloudStagingUsage(bytes: 7, items: 4),
            "process-wide staging usage did not include orphaned data"
        )

        try expect(
            .folderTooLarge,
            destination: testRoot.appendingPathComponent("too-large", isDirectory: true)
        ) { destination in
            _ = try CPSLICloudStagingStorage.stageDirectory(
                from: source,
                to: destination,
                remainingUsage: CPSLICloudStagingUsage(bytes: 6, items: 4),
                availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 7
            )
        }
        try expect(
            .tooManyItems,
            destination: testRoot.appendingPathComponent("too-many", isDirectory: true)
        ) { destination in
            _ = try CPSLICloudStagingStorage.stageDirectory(
                from: source,
                to: destination,
                remainingUsage: CPSLICloudStagingUsage(bytes: 7, items: 3),
                availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 7
            )
        }
        try expect(
            .insufficientStorage,
            destination: testRoot.appendingPathComponent("low-space", isDirectory: true)
        ) { destination in
            _ = try CPSLICloudStagingStorage.stageDirectory(
                from: source,
                to: destination,
                remainingUsage: CPSLICloudStagingUsage(bytes: 7, items: 4),
                availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 6
            )
        }

        try FileManager.default.removeItem(at: exactDestination)
        try require(
            !FileManager.default.fileExists(atPath: exactDestination.path),
            "restrictive staged directory could not be removed"
        )
    }

    private static func checkCancellation(in testRoot: URL) async throws {
        let source = testRoot.appendingPathComponent("cancel-source", isDirectory: true)
        let destination = testRoot.appendingPathComponent("cancel-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 0x5a, count: 2 * 1_024 * 1_024).write(
            to: source.appendingPathComponent("large.bin")
        )

        let wasCancelled = await Task { () -> Bool in
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            do {
                _ = try CPSLICloudStagingStorage.stageDirectory(
                    from: source,
                    to: destination,
                    remainingUsage: CPSLICloudStagingUsage(bytes: 3 * 1_024 * 1_024, items: 2),
                    availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 3 * 1_024 * 1_024
                )
                return false
            } catch is CancellationError {
                return !FileManager.default.fileExists(atPath: destination.path)
            } catch {
                return false
            }
        }.value
        try require(wasCancelled, "cancelled staging left output or returned the wrong error")
    }

    private static func checkSpecialFileRejection(in testRoot: URL) throws {
        let source = testRoot.appendingPathComponent("special-source", isDirectory: true)
        let destination = testRoot.appendingPathComponent("special-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let fifo = source.appendingPathComponent("pipe")
#if canImport(Darwin)
        let result = Darwin.mkfifo(fifo.path, 0o600)
#elseif canImport(Glibc)
        let result = Glibc.mkfifo(fifo.path, 0o600)
#else
        let result = -1
#endif
        try require(result == 0, "could not create special-file fixture")
        try expect(.unsupportedItem, destination: destination) { destination in
            _ = try CPSLICloudStagingStorage.stageDirectory(
                from: source,
                to: destination,
                remainingUsage: CPSLICloudStagingUsage(bytes: 1, items: 2),
                availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 1
            )
        }
    }

    private static func expect(
        _ expected: CPSLICloudStagingError,
        destination: URL,
        operation: (URL) throws -> Void
    ) throws {
        do {
            try operation(destination)
            throw CheckFailure("expected \(expected), but staging succeeded")
        } catch let error as CPSLICloudStagingError {
            try require(error == expected, "expected \(expected), got \(error)")
            try require(
                !FileManager.default.fileExists(atPath: destination.path),
                "failed staging left partial output"
            )
        }
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else {
            throw CheckFailure(message)
        }
    }
}

private struct CheckFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

nonisolated private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CPSLICloudImportProgress] = []

    var last: CPSLICloudImportProgress? {
        lock.withLock {
            values.last
        }
    }

    func append(_ value: CPSLICloudImportProgress) {
        lock.withLock {
            values.append(value)
        }
    }
}
