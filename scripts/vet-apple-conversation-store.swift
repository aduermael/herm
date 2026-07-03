import Foundation
import SQLite3

@main
private struct CPSLConversationStoreChecks {
    static func main() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("herm-store-vet-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }

        let store = try CPSLConversationStore(
            databaseURL: directory.appendingPathComponent("conversations.sqlite"),
            usesICloudContainer: false
        )

        let created = try await store.createConversation(
            userText: "Run a sandbox check",
            model: "test-model",
            systemPrompt: "test system prompt"
        )

        let toolCall = CPSLOpenAIToolCall(
            id: "call_1",
            type: "function",
            function: CPSLOpenAIFunctionCall(
                name: "local_sandbox_exec",
                arguments: #"{"source":"print(\"ok\")"}"#
            )
        )
        let assistantToolMessage = CPSLOpenAIMessage.assistant(
            content: nil,
            toolCalls: [toolCall]
        )
        let commandNode = try await store.appendNode(
            conversationID: created.summary.id,
            parentID: created.userNode.id,
            role: .command,
            title: "local_sandbox_exec",
            body: "local_sandbox_exec\n\nprint(\"ok\")",
            model: "test-model",
            providerMessage: assistantToolMessage
        )

        let toolMessage = CPSLOpenAIMessage.tool(
            id: toolCall.id,
            content: #"{"ok":true,"stdout":"ok\n","stderr":""}"#
        )
        let outputNode = try await store.appendNode(
            conversationID: created.summary.id,
            parentID: commandNode.id,
            role: .output,
            title: "local_sandbox_exec",
            body: "ok",
            model: "test-model",
            providerMessage: toolMessage
        )

        let summaries = try await store.loadSummaries()
        guard summaries.count == 1,
              summaries[0].id == created.summary.id,
              summaries[0].currentNodeID == outputNode.id,
              summaries[0].model == "test-model"
        else {
            throw CheckFailure("conversation summary did not track the current node")
        }

        guard let loaded = try await store.loadConversation(id: created.summary.id) else {
            throw CheckFailure("created conversation could not be loaded")
        }
        guard loaded.systemPrompt == "test system prompt" else {
            throw CheckFailure("stored system prompt did not round-trip")
        }
        guard loaded.nodes.map(\.sequence) == [0, 1, 2],
              loaded.nodes.map(\.id) == [created.userNode.id, commandNode.id, outputNode.id],
              loaded.nodes[1].parentID == created.userNode.id,
              loaded.nodes[2].parentID == commandNode.id
        else {
            throw CheckFailure("node order or parent chain was not preserved")
        }

        let providerMessages = try await store.providerMessages(conversationID: created.summary.id)
        guard providerMessages == [
            CPSLOpenAIMessage.user("Run a sandbox check"),
            assistantToolMessage,
            toolMessage
        ] else {
            throw CheckFailure("provider message replay did not round-trip")
        }

        let second = try await store.createConversation(
            userText: "Independent chain",
            model: nil,
            systemPrompt: "test system prompt"
        )
        guard second.userNode.model == nil else {
            throw CheckFailure("pre-config user node should allow missing provider model")
        }
        try await store.updateConversationModelIfMissing(
            conversationID: second.summary.id,
            model: "test-model"
        )
        let secondSummaries = try await store.loadSummaries()
        guard secondSummaries.first(where: { $0.id == second.summary.id })?.model == "test-model" else {
            throw CheckFailure("conversation model was not backfilled after config load")
        }
        let secondNode = try await store.appendNode(
            conversationID: second.summary.id,
            parentID: second.userNode.id,
            role: .assistant,
            title: nil,
            body: "ok",
            model: "test-model",
            providerMessage: .assistant("ok")
        )
        guard secondNode.sequence == 1 else {
            throw CheckFailure("node sequence should be scoped to each conversation")
        }

        do {
            _ = try await store.appendNode(
                conversationID: second.summary.id,
                parentID: nil,
                role: .assistant,
                title: nil,
                body: "orphan",
                model: "test-model",
                providerMessage: .assistant("orphan")
            )
            throw CheckFailure("nil-parent append node was accepted")
        } catch CPSLConversationStoreError.parentRequired {
        }

        do {
            _ = try await store.appendNode(
                conversationID: second.summary.id,
                parentID: commandNode.id,
                role: .assistant,
                title: nil,
                body: "cross-chain parent",
                model: "test-model",
                providerMessage: .assistant("cross-chain parent")
            )
            throw CheckFailure("cross-conversation parent node was accepted")
        } catch CPSLConversationStoreError.parentConversationMismatch {
        }

        try await assertLegacySchemaMigrates(in: directory)
    }

    private static func assertLegacySchemaMigrates(in directory: URL) async throws {
        let databaseURL = directory.appendingPathComponent("legacy.sqlite")
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw CheckFailure("could not create legacy database")
        }
        for sql in [
            """
            CREATE TABLE conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE nodes (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL,
                parent_id TEXT,
                role TEXT NOT NULL,
                body TEXT NOT NULL,
                sequence INTEGER NOT NULL,
                created_at REAL NOT NULL
            )
            """,
            """
            INSERT INTO conversations (id, title, created_at, updated_at)
            VALUES ('legacy-conversation', 'Legacy conversation', 100.0, 102.0)
            """,
            """
            INSERT INTO nodes (id, conversation_id, parent_id, role, body, sequence, created_at)
            VALUES ('legacy-root', 'legacy-conversation', NULL, 'user', 'old user text', 0, 100.0)
            """,
            """
            INSERT INTO nodes (id, conversation_id, parent_id, role, body, sequence, created_at)
            VALUES ('legacy-current', 'legacy-conversation', 'legacy-root', 'assistant', 'old assistant text', 1, 101.0)
            """
        ] {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(database)
                throw CheckFailure("could not create legacy schema")
            }
        }
        sqlite3_close(database)

        let store = try CPSLConversationStore(databaseURL: databaseURL, usesICloudContainer: false)
        guard let loaded = try await store.loadConversation(id: "legacy-conversation"),
              loaded.summary.currentNodeID == "legacy-current",
              loaded.systemPrompt == "",
              loaded.nodes.map(\.id) == ["legacy-root", "legacy-current"],
              loaded.nodes[1].parentID == "legacy-root"
        else {
            throw CheckFailure("legacy conversation pointers did not backfill")
        }

        let columns = try sqliteColumns(databaseURL: databaseURL)
        guard columns["conversations"]?.contains("model") == true,
              columns["conversations"]?.contains("system_prompt") == true,
              columns["nodes"]?.contains("provider_message_json") == true,
              columns["nodes"]?.contains("title") == true
        else {
            throw CheckFailure("legacy schema did not migrate expected columns")
        }
    }

    private static func sqliteColumns(databaseURL: URL) throws -> [String: Set<String>] {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw CheckFailure("could not reopen migrated database")
        }
        defer {
            sqlite3_close(database)
        }

        var result: [String: Set<String>] = [:]
        for table in ["conversations", "nodes"] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "PRAGMA table_info(\"\(table)\")", -1, &statement, nil) == SQLITE_OK else {
                throw CheckFailure("could not inspect migrated table")
            }
            defer {
                sqlite3_finalize(statement)
            }
            var columns = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) {
                    columns.insert(String(cString: name))
                }
            }
            result[table] = columns
        }
        return result
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
