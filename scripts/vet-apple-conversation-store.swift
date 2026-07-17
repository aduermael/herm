import Foundation

@main
private struct CPSLConversationStoreChecks {
    static func main() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("herm-store-vet-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("conversations.jsonl")
        let store = try CPSLConversationStore(logURL: logURL, usesICloudContainer: false)
        let created = try await store.createConversation(
            userText: "Run a sandbox check",
            model: "test-model",
            systemPrompt: "test system prompt"
        )
        let sizeAfterCreate = try Data(contentsOf: logURL).count

        let assistantNode = try await store.appendNode(
            conversationID: created.summary.id,
            parentID: created.userNode.id,
            draft: CPSLNodeAppendDraft(
                role: .assistant,
                title: nil,
                body: "ok",
                model: "test-model",
                providerMessage: .assistant("ok")
            )
        )
        guard try Data(contentsOf: logURL).count > sizeAfterCreate else {
            throw CheckFailure("conversation mutation did not append to JSONL")
        }

        let summaries = try await store.fetchConversationSummaries(archiveScope: .active, tagIDs: [])
        guard summaries.count == 1,
              summaries[0].currentNodeID == assistantNode.id,
              summaries[0].model == "test-model"
        else {
            throw CheckFailure("conversation summary did not replay the current node")
        }

        guard let loaded = try await store.loadConversation(id: created.summary.id),
              loaded.systemPrompt == "test system prompt",
              loaded.nodes.map(\.sequence) == [0, 1],
              loaded.nodes[1].parentID == created.userNode.id
        else {
            throw CheckFailure("conversation JSONL did not replay")
        }

        let providerMessages = try await store.providerMessages(conversationID: created.summary.id)
        guard providerMessages == [
            CPSLOpenAIMessage.user("Run a sandbox check"),
            CPSLOpenAIMessage.assistant("ok"),
        ] else {
            throw CheckFailure("provider messages did not round-trip")
        }

        try await store.recordToolInvocation(
            conversationID: created.summary.id,
            nodeID: assistantNode.id,
            invocation: CPSLToolTraceInvocation(
                id: "call-1",
                name: "test",
                summary: "Testing",
                input: "input",
                output: "output",
                isError: false
            )
        )
        let traceLogURL = await store.traceLogURL
        guard try Data(contentsOf: traceLogURL).contains(0x0A) else {
            throw CheckFailure("trace did not append to JSONL")
        }

        do {
            _ = try await store.appendNode(
                conversationID: created.summary.id,
                parentID: nil,
                draft: CPSLNodeAppendDraft(
                    role: .assistant,
                    title: nil,
                    body: "orphan",
                    model: "test-model",
                    providerMessage: .assistant("orphan")
                )
            )
            throw CheckFailure("nil-parent append node was accepted")
        } catch CPSLConversationStoreError.parentRequired {
        }

        let other = try await store.createConversation(
            userText: "Other",
            model: nil,
            systemPrompt: ""
        )
        do {
            _ = try await store.appendNode(
                conversationID: other.summary.id,
                parentID: assistantNode.id,
                draft: CPSLNodeAppendDraft(
                    role: .assistant,
                    title: nil,
                    body: "cross-chain",
                    model: nil,
                    providerMessage: .assistant("cross-chain")
                )
            )
            throw CheckFailure("cross-conversation parent node was accepted")
        } catch CPSLConversationStoreError.parentConversationMismatch {
        }

        _ = try CPSLConversationStore(logURL: logURL, usesICloudContainer: false)
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
