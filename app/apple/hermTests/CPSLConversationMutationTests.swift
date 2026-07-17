import Foundation
import Testing
@testable import herm

struct CPSLConversationMutationTests {
    private func makeStore() throws -> CPSLConversationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-test-\(UUID().uuidString).jsonl")
        return try CPSLConversationStore(logURL: url, usesICloudContainer: false)
    }

    @Test func pinToggles() async throws {
        let store = try makeStore()
        let c = try await store.createConversation(userText: "x", model: nil, systemPrompt: "")
        try await store.setPinned(conversationID: c.summary.id, pinned: true)
        #expect(try await store.fetchConversationSummaries(archiveScope: .active, tagIDs: []).first?.pinned == true)
        try await store.setPinned(conversationID: c.summary.id, pinned: false)
        #expect(try await store.fetchConversationSummaries(archiveScope: .active, tagIDs: []).first?.pinned == false)
    }

    @Test func renameSetsCustomTitle() async throws {
        let store = try makeStore()
        let c = try await store.createConversation(userText: "auto title here", model: nil, systemPrompt: "")
        try await store.renameConversation(id: c.summary.id, title: "  My Title  ")
        let summary = try await store.fetchConversationSummaries(archiveScope: .active, tagIDs: []).first
        #expect(summary?.title == "My Title")
    }

    @Test func renameRejectsEmpty() async throws {
        let store = try makeStore()
        let c = try await store.createConversation(userText: "x", model: nil, systemPrompt: "")
        await #expect(throws: CPSLConversationStoreError.self) {
            try await store.renameConversation(id: c.summary.id, title: "   ")
        }
    }

    @Test func archivedExcludedFromActiveScope() async throws {
        let store = try makeStore()
        let a = try await store.createConversation(userText: "keep", model: nil, systemPrompt: "")
        let b = try await store.createConversation(userText: "hide", model: nil, systemPrompt: "")
        try await store.setArchived(conversationID: b.summary.id, archived: true)
        let active = try await store.fetchConversationSummaries(archiveScope: .active, tagIDs: [])
        #expect(active.map(\.id) == [a.summary.id])
        let archived = try await store.fetchConversationSummaries(archiveScope: .archived, tagIDs: [])
        #expect(archived.map(\.id) == [b.summary.id])
    }

    @Test func fetchReadsPinnedFlag() async throws {
        let store = try makeStore()
        let c = try await store.createConversation(userText: "x", model: nil, systemPrompt: "")
        try await store.setPinned(conversationID: c.summary.id, pinned: true)
        let summaries = try await store.fetchConversationSummaries(archiveScope: .active, tagIDs: [])
        #expect(summaries.first?.pinned == true)
    }
}
