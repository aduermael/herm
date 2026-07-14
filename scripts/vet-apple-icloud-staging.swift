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

        try checkBoundedCopy(in: testRoot)
        try checkCoordinatedSnapshots(in: testRoot)
        try checkMaterializationFailureCleanup(in: testRoot)
        try checkChangedFileRejection(in: testRoot)
        try checkSymbolicLinkRejection(in: testRoot)
        try checkSpecialFileRejection(in: testRoot)
        try await checkCancellation(in: testRoot)
    }

    private static func checkCoordinatedSnapshots(in testRoot: URL) throws {
        let source = testRoot.appendingPathComponent("coordinated-source", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        let snapshots = testRoot.appendingPathComponent("coordinated-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)

        let firstSource = source.appendingPathComponent("first.txt")
        let secondSource = nested.appendingPathComponent("second.txt")
        let firstSnapshot = snapshots.appendingPathComponent("first.txt")
        let secondSnapshot = snapshots.appendingPathComponent("second.txt")
        try Data("old1".utf8).write(to: firstSource)
        try Data("old2".utf8).write(to: secondSource)
        try Data("new1".utf8).write(to: firstSnapshot)
        try Data("new2".utf8).write(to: secondSnapshot)

        let coordination = CoordinatedReadRecorder(
            snapshotsBySourcePath: [
                firstSource.path: firstSnapshot,
                secondSource.path: secondSnapshot,
            ]
        )
        let destination = testRoot.appendingPathComponent(
            "coordinated-destination",
            isDirectory: true
        )
        let usage = try CPSLICloudStagingStorage.stageDirectory(
            CPSLICloudStagingRequest(
                sourceRoot: source,
                destinationRoot: destination,
                permit: CPSLICloudStagingImportPermit(
                    remainingUsage: CPSLICloudStagingUsage(bytes: 8, items: 4),
                    availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 8
                ),
                coordinateFileRead: { sourceURL, accessor in
                    try coordination.coordinate(sourceURL, accessor: accessor)
                }
            )
        )

        try require(usage == CPSLICloudStagingUsage(bytes: 8, items: 4), "snapshot usage was wrong")
        try require(
            try Data(contentsOf: destination.appendingPathComponent("first.txt")) == Data("new1".utf8),
            "top-level copy ignored the coordinated snapshot URL"
        )
        try require(
            try Data(contentsOf: destination.appendingPathComponent("nested/second.txt")) ==
                Data("new2".utf8),
            "nested copy ignored the coordinated snapshot URL"
        )
        try require(
            coordination.callCount(for: firstSource) == 1,
            "top-level file was not coordinated exactly once"
        )
        try require(
            coordination.callCount(for: secondSource) == 1,
            "nested file was not coordinated exactly once"
        )
        try require(coordination.totalCallCount == 2, "non-file items were unexpectedly coordinated")
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
        let materialization = MaterializationRecorder()
        let usage = try CPSLICloudStagingStorage.stageDirectory(
            CPSLICloudStagingRequest(
                sourceRoot: source,
                destinationRoot: exactDestination,
                permit: CPSLICloudStagingImportPermit(
                    remainingUsage: CPSLICloudStagingUsage(bytes: 7, items: 4),
                    availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 7
                ),
                materializeFile: { url in
                    try materialization.materialize(url)
                }
            ),
            progress: { value in
                progress.append(value)
            }
        )
        try require(usage == CPSLICloudStagingUsage(bytes: 7, items: 4), "exact-limit usage was wrong")
        try require(progress.contains(.downloading), "download progress was not reported")
        try require(progress.last?.fractionCompleted == 1, "copy progress did not complete")
        try require(
            materialization.callCount(for: source.appendingPathComponent("a.bin")) == 2,
            "top-level file was not materialized before manifest and copy"
        )
        try require(
            materialization.callCount(for: nested.appendingPathComponent("b.bin")) == 2,
            "nested file was not materialized before manifest and copy"
        )
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
        try require(
            try CPSLICloudStagingStorage.currentUsage(of: [exactDestination]) == usage,
            "root usage did not count the root and descendants"
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)

        let writableDestination = testRoot.appendingPathComponent("writable", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o440], ofItemAtPath: sourceFile.path)
        _ = try CPSLICloudStagingStorage.stageDirectory(
            CPSLICloudStagingRequest(
                sourceRoot: source,
                destinationRoot: writableDestination,
                permit: CPSLICloudStagingImportPermit(
                    remainingUsage: CPSLICloudStagingUsage(bytes: 7, items: 4),
                    availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 7
                ),
                isWritable: true
            )
        )
        let writableAttributes = try FileManager.default.attributesOfItem(
            atPath: writableDestination.appendingPathComponent("a.bin").path
        )
        let writablePermissions = (writableAttributes[.posixPermissions] as? NSNumber)?.intValue
        try require(
            writablePermissions.map { $0 & 0o200 == 0o200 } == true,
            "writable staging did not add owner write access"
        )
        try FileManager.default.removeItem(at: writableDestination)

        try expect(
            .folderTooLarge,
            destination: testRoot.appendingPathComponent("too-large", isDirectory: true)
        ) { destination in
            _ = try CPSLICloudStagingStorage.stageDirectory(
                CPSLICloudStagingRequest(
                    sourceRoot: source,
                    destinationRoot: destination,
                    permit: CPSLICloudStagingImportPermit(
                        remainingUsage: CPSLICloudStagingUsage(bytes: 6, items: 4),
                        availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 7
                    )
                )
            )
        }
        try expect(
            .tooManyItems,
            destination: testRoot.appendingPathComponent("too-many", isDirectory: true)
        ) { destination in
            _ = try CPSLICloudStagingStorage.stageDirectory(
                CPSLICloudStagingRequest(
                    sourceRoot: source,
                    destinationRoot: destination,
                    permit: CPSLICloudStagingImportPermit(
                        remainingUsage: CPSLICloudStagingUsage(bytes: 7, items: 3),
                        availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 7
                    )
                )
            )
        }
        try expect(
            .insufficientStorage,
            destination: testRoot.appendingPathComponent("low-space", isDirectory: true)
        ) { destination in
            _ = try CPSLICloudStagingStorage.stageDirectory(
                CPSLICloudStagingRequest(
                    sourceRoot: source,
                    destinationRoot: destination,
                    permit: CPSLICloudStagingImportPermit(
                        remainingUsage: CPSLICloudStagingUsage(bytes: 7, items: 4),
                        availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 6
                    )
                )
            )
        }

        try FileManager.default.removeItem(at: exactDestination)
        try require(
            !FileManager.default.fileExists(atPath: exactDestination.path),
            "restrictive staged directory could not be removed"
        )
    }

    private static func checkMaterializationFailureCleanup(in testRoot: URL) throws {
        let source = testRoot.appendingPathComponent("materialization-source", isDirectory: true)
        let destination = testRoot.appendingPathComponent("materialization-destination", isDirectory: true)
        let file = source.appendingPathComponent("remote.bin")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        let materialization = MaterializationRecorder { _, call in
            if call == 2 {
                throw CPSLICloudStagingError.downloadFailed
            }
        }

        try expect(.downloadFailed, destination: destination) { destination in
            _ = try CPSLICloudStagingStorage.stageDirectory(
                CPSLICloudStagingRequest(
                    sourceRoot: source,
                    destinationRoot: destination,
                    permit: CPSLICloudStagingImportPermit(
                        remainingUsage: CPSLICloudStagingUsage(bytes: 3, items: 2),
                        availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 3
                    ),
                    materializeFile: { url in
                        try materialization.materialize(url)
                    }
                )
            )
        }
        try require(
            materialization.callCount(for: file) == 2,
            "pre-copy materialization failure did not occur on the second check"
        )
    }

    private static func checkChangedFileRejection(in testRoot: URL) throws {
        let source = testRoot.appendingPathComponent("changed-source", isDirectory: true)
        let destination = testRoot.appendingPathComponent("changed-destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("changing.bin"))
        let materialization = MaterializationRecorder { url, call in
            if call == 2 {
                try Data([9]).write(to: url)
            }
        }

        try expect(.incompleteCopy, destination: destination) { destination in
            _ = try CPSLICloudStagingStorage.stageDirectory(
                CPSLICloudStagingRequest(
                    sourceRoot: source,
                    destinationRoot: destination,
                    permit: CPSLICloudStagingImportPermit(
                        remainingUsage: CPSLICloudStagingUsage(bytes: 3, items: 2),
                        availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 3
                    ),
                    materializeFile: { url in
                        try materialization.materialize(url)
                    }
                )
            )
        }
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
                    CPSLICloudStagingRequest(
                        sourceRoot: source,
                        destinationRoot: destination,
                        permit: CPSLICloudStagingImportPermit(
                            remainingUsage: CPSLICloudStagingUsage(
                                bytes: 3 * 1_024 * 1_024,
                                items: 2
                            ),
                            availableCapacityBytes:
                                CPSLICloudStagingStorage.freeSpaceReserveBytes + 3 * 1_024 * 1_024
                        )
                    )
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

    private static func checkSymbolicLinkRejection(in testRoot: URL) throws {
        let source = testRoot.appendingPathComponent("symlink-source", isDirectory: true)
        let destination = testRoot.appendingPathComponent("symlink-destination", isDirectory: true)
        let outside = testRoot.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("link.txt").path,
            withDestinationPath: outside.path
        )

        try expect(.unsupportedItem, destination: destination) { destination in
            _ = try CPSLICloudStagingStorage.stageDirectory(
                CPSLICloudStagingRequest(
                    sourceRoot: source,
                    destinationRoot: destination,
                    permit: CPSLICloudStagingImportPermit(
                        remainingUsage: CPSLICloudStagingUsage(bytes: 1, items: 2),
                        availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 1
                    )
                )
            )
        }
        do {
            _ = try CPSLICloudStagingStorage.currentUsage(of: [source])
            throw CheckFailure("root usage accepted a symbolic link")
        } catch let error as CPSLICloudStagingError {
            try require(error == .unsupportedItem, "root usage returned the wrong symbolic-link error")
        }
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
                CPSLICloudStagingRequest(
                    sourceRoot: source,
                    destinationRoot: destination,
                    permit: CPSLICloudStagingImportPermit(
                        remainingUsage: CPSLICloudStagingUsage(bytes: 1, items: 2),
                        availableCapacityBytes: CPSLICloudStagingStorage.freeSpaceReserveBytes + 1
                    )
                )
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

    func contains(_ phase: CPSLICloudImportPhase) -> Bool {
        lock.withLock {
            values.contains { $0.phase == phase }
        }
    }
}

nonisolated private final class MaterializationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let onCall: @Sendable (URL, Int) throws -> Void
    private var callsByPath: [String: Int] = [:]

    init(onCall: @escaping @Sendable (URL, Int) throws -> Void = { _, _ in }) {
        self.onCall = onCall
    }

    func materialize(_ url: URL) throws {
        let call = lock.withLock {
            let nextCall = callsByPath[url.path, default: 0] + 1
            callsByPath[url.path] = nextCall
            return nextCall
        }
        try onCall(url, call)
    }

    func callCount(for url: URL) -> Int {
        lock.withLock {
            callsByPath[url.path, default: 0]
        }
    }
}

nonisolated private final class CoordinatedReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshotsBySourcePath: [String: URL]
    private var callsByPath: [String: Int] = [:]

    init(snapshotsBySourcePath: [String: URL]) {
        self.snapshotsBySourcePath = snapshotsBySourcePath
    }

    var totalCallCount: Int {
        lock.withLock {
            callsByPath.values.reduce(0, +)
        }
    }

    func coordinate(_ sourceURL: URL, accessor: (URL) throws -> Void) throws {
        let snapshot = try lock.withLock {
            guard let snapshot = snapshotsBySourcePath[sourceURL.path] else {
                throw CheckFailure("unexpected coordinated source: \(sourceURL.path)")
            }
            callsByPath[sourceURL.path, default: 0] += 1
            return snapshot
        }
        try accessor(snapshot)
    }

    func callCount(for sourceURL: URL) -> Int {
        lock.withLock {
            callsByPath[sourceURL.path, default: 0]
        }
    }
}
