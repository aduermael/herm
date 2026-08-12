import Foundation
import Testing
@testable import herm

struct CPSLFileShareTests {
    @Test func sandboxVirtualPathMapsToExistingHostFile() throws {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-share-test-\(UUID().uuidString)", isDirectory: true)
        let home = sandboxRoot.appendingPathComponent("home/herm", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandboxRoot) }

        let noteURL = home.appendingPathComponent("note.txt", isDirectory: false)
        try Data("share-payload".utf8).write(to: noteURL)

        let resolved = CPSLSandboxHostURL.hostFileURL(
            virtualPath: "/home/herm/note.txt",
            sandboxRoot: sandboxRoot
        )
        #expect(resolved.standardizedFileURL.path == noteURL.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(try String(contentsOf: resolved, encoding: .utf8) == "share-payload")
    }

    @Test func sandboxHostURLNormalizesDotSegments() {
        let root = URL(fileURLWithPath: "/tmp/sandbox-root", isDirectory: true)
        let resolved = CPSLSandboxHostURL.hostFileURL(
            virtualPath: "/home/herm/../herm/./docs/a.txt",
            sandboxRoot: root
        )
        let expected = CPSLSandboxHostURL.hostFileURL(
            virtualPath: "/home/herm/docs/a.txt",
            sandboxRoot: root
        )
        #expect(resolved.path == expected.path)
    }

    @Test func shareableFileHoldsURLAndOptionalLifetime() {
        let url = URL(fileURLWithPath: "/tmp/example.txt")
        let file = CPSLShareableFile(url: url, lifetimeToken: nil)
        #expect(file.url == url)
        #expect(file.lifetimeToken == nil)
    }
}
