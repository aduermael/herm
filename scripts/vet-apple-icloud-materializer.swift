import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
private struct CPSLICloudMaterializerChecks {
    static func main() async throws {
        let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "herm-icloud-materializer-check-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        try checkDirectoryMaterialization(in: testRoot)
        try checkEmptyDirectoryProgress(in: testRoot)
        try checkMaterializationFailure(in: testRoot)
        try checkUnsupportedItems(in: testRoot)
        try await checkCancellation(in: testRoot)
    }

    private static func checkDirectoryMaterialization(in testRoot: URL) throws {
        let source = testRoot.appendingPathComponent("source", isDirectory: true)
        let nested = source.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = source.appendingPathComponent("first.txt")
        let second = nested.appendingPathComponent("second.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let materialized = URLRecorder()
        let progress = ProgressRecorder()
        try CPSLICloudFileMaterializer.materializeDirectory(
            at: source,
            materialize: { materialized.append($0) },
            progress: { progress.append($0) }
        )

        try require(
            Set(materialized.paths) == Set([first.path, second.path]),
            "materializer did not visit each source file exactly once"
        )
        try require(
            try String(contentsOf: first, encoding: .utf8) == "first" &&
                String(contentsOf: second, encoding: .utf8) == "second",
            "materializing live files changed their contents"
        )
        let updates = progress.values
        try require(updates.first == .preparing, "preparing progress was not reported first")
        try require(
            updates.dropFirst().allSatisfy { $0.phase == .downloading },
            "materializer reported a staging or copying phase"
        )
        try require(
            updates.last?.completedItems == 2 && updates.last?.totalItems == 2,
            "materialization progress did not complete"
        )
        try require(updates.last?.fractionCompleted == 1, "final progress fraction was not one")
    }

    private static func checkEmptyDirectoryProgress(in testRoot: URL) throws {
        let source = testRoot.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let progress = ProgressRecorder()

        try CPSLICloudFileMaterializer.materializeDirectory(
            at: source,
            materialize: { _ in
                throw CheckFailure("empty directory unexpectedly materialized a file")
            },
            progress: { progress.append($0) }
        )
        try require(
            progress.values == [
                .preparing,
                CPSLICloudImportProgress(
                    phase: .downloading,
                    completedBytes: 0,
                    totalBytes: 0,
                    completedItems: 0,
                    totalItems: 0
                ),
            ],
            "empty directory progress was not deterministic"
        )
    }

    private static func checkMaterializationFailure(in testRoot: URL) throws {
        let source = testRoot.appendingPathComponent("failure", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("remote".utf8).write(to: source.appendingPathComponent("remote.txt"))

        do {
            try CPSLICloudFileMaterializer.materializeDirectory(
                at: source,
                materialize: { _ in throw CPSLICloudFileError.downloadFailed }
            )
            throw CheckFailure("file materialization failure was ignored")
        } catch CPSLICloudFileError.downloadFailed {
            // Expected.
        }
        try require(
            FileManager.default.fileExists(atPath: source.appendingPathComponent("remote.txt").path),
            "materialization failure deleted the live source file"
        )
    }

    private static func checkUnsupportedItems(in testRoot: URL) throws {
        let regularFile = testRoot.appendingPathComponent("not-a-directory.txt")
        try Data("file".utf8).write(to: regularFile)
        try expectUnsupported {
            try CPSLICloudFileMaterializer.materializeDirectory(
                at: regularFile,
                materialize: { _ in }
            )
        }

        let source = testRoot.appendingPathComponent("unsupported", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let target = source.appendingPathComponent("target.txt")
        let link = source.appendingPathComponent("link.txt")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try expectUnsupported {
            try CPSLICloudFileMaterializer.materializeDirectory(
                at: source,
                materialize: { _ in }
            )
        }
        try FileManager.default.removeItem(at: link)

        let fifo = source.appendingPathComponent("pipe")
        guard mkfifo(fifo.path, 0o600) == 0 else {
            throw CheckFailure("could not create FIFO fixture")
        }
        try expectUnsupported {
            try CPSLICloudFileMaterializer.materializeDirectory(
                at: source,
                materialize: { _ in }
            )
        }
    }

    private static func checkCancellation(in testRoot: URL) async throws {
        let source = testRoot.appendingPathComponent("cancelled", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: source.appendingPathComponent("file.txt"))

        let task = Task {
            try CPSLICloudFileMaterializer.materializeDirectory(
                at: source,
                materialize: { _ in }
            )
        }
        task.cancel()
        do {
            try await task.value
            throw CheckFailure("cancelled materialization completed")
        } catch is CancellationError {
            // Expected.
        }
    }

    private static func expectUnsupported(_ operation: () throws -> Void) throws {
        do {
            try operation()
            throw CheckFailure("unsupported filesystem item was accepted")
        } catch CPSLICloudFileError.unsupportedItem {
            // Expected.
        }
    }

    private static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) throws {
        guard try condition() else {
            throw CheckFailure(message)
        }
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: [String] = []

    var paths: [String] {
        lock.withLock { storedPaths }
    }

    func append(_ url: URL) {
        lock.withLock {
            storedPaths.append(url.path)
        }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [CPSLICloudImportProgress] = []

    var values: [CPSLICloudImportProgress] {
        lock.withLock { storedValues }
    }

    func append(_ value: CPSLICloudImportProgress) {
        lock.withLock {
            storedValues.append(value)
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
