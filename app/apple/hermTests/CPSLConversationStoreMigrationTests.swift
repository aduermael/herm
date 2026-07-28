import Foundation
import Testing
@testable import herm

struct CPSLConversationStoreMigrationTests {
    @Test func reopeningJSONLStoreIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-test-\(UUID().uuidString).jsonl")
        _ = try CPSLConversationStore(logURL: url, usesICloudContainer: false)
        // Reopening the same append-only log leaves it intact.
        _ = try CPSLConversationStore(logURL: url, usesICloudContainer: false)
    }

    @Test func mutationsAppendJSONLinesAndExportStructuredJSON() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-test-\(UUID().uuidString).jsonl")
        let store = try CPSLConversationStore(logURL: url, usesICloudContainer: false)
        let created = try await store.createConversation(
            userText: "hello",
            model: "test-model",
            systemPrompt: "test prompt"
        )
        let sizeAfterCreate = try Data(contentsOf: url).count
        try await store.setPinned(conversationID: created.summary.id, pinned: true)
        let log = try Data(contentsOf: url)

        #expect(log.count > sizeAfterCreate)
        #expect(log.filter { $0 == 0x0A }.count == 2)

        try await store.recordToolInvocation(
            conversationID: created.summary.id,
            nodeID: created.userNode.id,
            invocation: CPSLToolTraceInvocation(
                id: "call-1",
                name: "test",
                summary: "Testing",
                input: "input",
                output: "output",
                isError: false
            )
        )
        let projectedInvocations = try await store.toolStatusInvocations(
            conversationID: created.summary.id,
            nodeIDs: [created.userNode.id]
        )
        #expect(projectedInvocations[created.userNode.id]?.map(\.id) == ["call-1"])

#if DEBUG
        let json = try await store.exportConversationJSON(id: created.summary.id)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        #expect(object["format"] as? String == "herm.debug-export")
        #expect((object["conversationEvents"] as? [[String: Any]])?.count == 2)
        #expect((object["traceEvents"] as? [[String: Any]])?.count == 1)
#endif
    }

    @Test func incompleteTailIsDiscardedBeforeNextAppend() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-test-\(UUID().uuidString).jsonl")
        let store = try CPSLConversationStore(logURL: url, usesICloudContainer: false)
        let created = try await store.createConversation(
            userText: "hello",
            model: nil,
            systemPrompt: ""
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"partial":"#.utf8))
        try handle.close()

        try await store.setPinned(conversationID: created.summary.id, pinned: true)
        let reopened = try CPSLConversationStore(logURL: url, usesICloudContainer: false)
        let summary = try await reopened.fetchConversationSummaries(
            archiveScope: .active,
            tagIDs: []
        ).first
        #expect(summary?.pinned == true)
    }
}
