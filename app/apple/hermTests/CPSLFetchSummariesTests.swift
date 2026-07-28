import Foundation
import Testing
@testable import herm

struct CPSLFetchSummariesTests {
    private func makeStore() throws -> CPSLConversationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-test-\(UUID().uuidString).jsonl")
        return try CPSLConversationStore(logURL: url, usesICloudContainer: false)
    }

    @Test func activeScopeReturnsCreatedByDefault() async throws {
        let store = try makeStore()
        let a = try await store.createConversation(userText: "one", model: nil, systemPrompt: "")
        let b = try await store.createConversation(userText: "two", model: nil, systemPrompt: "")
        let active = try await store.fetchConversationSummaries(archiveScope: .active, tagIDs: [])
        #expect(Set(active.map(\.id)) == [a.summary.id, b.summary.id])
        let archived = try await store.fetchConversationSummaries(archiveScope: .archived, tagIDs: [])
        #expect(archived.isEmpty)
    }

    @Test func tagFilterIsAND() async throws {
        let store = try makeStore()
        let c1 = try await store.createConversation(userText: "1", model: nil, systemPrompt: "")
        let c2 = try await store.createConversation(userText: "2", model: nil, systemPrompt: "")
        let work = try await store.createTag(name: "Work", color: "mauve")
        let urgent = try await store.createTag(name: "Urgent", color: "red")
        try await store.setTags(conversationID: c1.summary.id, tagIDs: [work.id, urgent.id])
        try await store.setTags(conversationID: c2.summary.id, tagIDs: [work.id])

        let both = try await store.fetchConversationSummaries(archiveScope: .active, tagIDs: [work.id, urgent.id])
        #expect(both.map(\.id) == [c1.summary.id]) // AND: only c1 has both tags

        let workOnly = try await store.fetchConversationSummaries(archiveScope: .active, tagIDs: [work.id])
        #expect(Set(workOnly.map(\.id)) == [c1.summary.id, c2.summary.id])
    }
}
