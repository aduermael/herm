import Foundation
import Testing
@testable import herm

struct CPSLTagStoreTests {
    private func makeStore() throws -> CPSLConversationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-test-\(UUID().uuidString).jsonl")
        return try CPSLConversationStore(logURL: url, usesICloudContainer: false)
    }

    @Test func createAndListTags() async throws {
        let store = try makeStore()
        let tag = try await store.createTag(name: "  Work  ", color: "mauve")
        #expect(tag.name == "Work")
        let all = try await store.allTags()
        #expect(all.map(\.name) == ["Work"])
    }

    @Test func rejectsEmptyName() async throws {
        let store = try makeStore()
        await #expect(throws: CPSLConversationStoreError.self) {
            _ = try await store.createTag(name: "   ", color: "mauve")
        }
    }

    @Test func rejectsCaseInsensitiveDuplicate() async throws {
        let store = try makeStore()
        _ = try await store.createTag(name: "Work", color: "mauve")
        await #expect(throws: CPSLConversationStoreError.self) {
            _ = try await store.createTag(name: "work", color: "green")
        }
    }

    @Test func assignsTagsToConversation() async throws {
        let store = try makeStore()
        let created = try await store.createConversation(userText: "hi", model: nil, systemPrompt: "")
        let a = try await store.createTag(name: "A", color: "mauve")
        let b = try await store.createTag(name: "B", color: "green")
        try await store.setTags(conversationID: created.summary.id, tagIDs: [a.id, b.id])
        let ids = try await store.tagIDs(forConversation: created.summary.id)
        #expect(ids == [a.id, b.id])
    }

    @Test func deletingTagCascadesAssociations() async throws {
        let store = try makeStore()
        let created = try await store.createConversation(userText: "hi", model: nil, systemPrompt: "")
        let a = try await store.createTag(name: "A", color: "mauve")
        try await store.setTags(conversationID: created.summary.id, tagIDs: [a.id])
        try await store.deleteTag(id: a.id)
        let ids = try await store.tagIDs(forConversation: created.summary.id)
        #expect(ids.isEmpty)
    }

    @Test func deletingConversationCascadesAssociations() async throws {
        let store = try makeStore()
        let created = try await store.createConversation(userText: "hi", model: nil, systemPrompt: "")
        let a = try await store.createTag(name: "A", color: "mauve")
        try await store.setTags(conversationID: created.summary.id, tagIDs: [a.id])
        try await store.deleteConversation(id: created.summary.id)
        // The tag survives; the association is cascade-deleted.
        #expect(try await store.allTags().count == 1)
        #expect(try await store.tagIDs(forConversation: created.summary.id).isEmpty)
    }
}
