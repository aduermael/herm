import Foundation
import SQLite3

actor CPSLConversationStore {
    private nonisolated static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    let databaseURL: URL
    let usesICloudContainer: Bool

    private var database: OpaquePointer?

    init() throws {
        let location = try CPSLConversationDatabaseLocation.resolve()
        try self.init(location: location)
    }

    init(databaseURL: URL, usesICloudContainer: Bool) throws {
        try self.init(
            location: CPSLConversationDatabaseLocation(
                url: databaseURL,
                usesICloudContainer: usesICloudContainer
            )
        )
    }

    private init(location: CPSLConversationDatabaseLocation) throws {
        databaseURL = location.url
        usesICloudContainer = location.usesICloudContainer

        if sqlite3_open(location.url.path, &database) != SQLITE_OK {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
            throw CPSLConversationStoreError.openFailed(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        try Self.migrate(database: database)
    }

    deinit {
        sqlite3_close(database)
    }

    func loadSummaries() throws -> [CPSLConversationSummary] {
        try query(
            """
            SELECT id, title, current_node_id, model, created_at, updated_at
            FROM conversations
            ORDER BY updated_at DESC
            """
        ) { statement in
            CPSLConversationSummary(
                id: columnString(statement, 0) ?? "",
                title: columnString(statement, 1) ?? "Untitled",
                currentNodeID: columnString(statement, 2),
                model: columnString(statement, 3),
                createdAt: columnDate(statement, 4),
                updatedAt: columnDate(statement, 5)
            )
        }
    }

    func loadNodes(conversationID: String) throws -> [CPSLStoredNode] {
        try query(
            """
            SELECT id, conversation_id, parent_id, role, title, body, model, provider_message_json, sequence, created_at
            FROM nodes
            WHERE conversation_id = ?
            ORDER BY sequence ASC, created_at ASC
            """,
            bindings: [.text(conversationID)]
        ) { statement in
            storedNode(from: statement)
        }
    }

    func loadConversation(id: String) throws -> CPSLLoadedConversation? {
        let loadedHeaders = try query(
            """
            SELECT id, title, current_node_id, model, system_prompt, created_at, updated_at
            FROM conversations
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id)]
        ) { statement in
            (
                summary: CPSLConversationSummary(
                    id: columnString(statement, 0) ?? "",
                    title: columnString(statement, 1) ?? "Untitled",
                    currentNodeID: columnString(statement, 2),
                    model: columnString(statement, 3),
                    createdAt: columnDate(statement, 5),
                    updatedAt: columnDate(statement, 6)
                ),
                systemPrompt: columnString(statement, 4) ?? ""
            )
        }
        guard let loadedHeader = loadedHeaders.first else {
            return nil
        }
        return CPSLLoadedConversation(
            summary: loadedHeader.summary,
            systemPrompt: loadedHeader.systemPrompt,
            nodes: try loadNodes(conversationID: id)
        )
    }

#if DEBUG
    func exportConversationJSON(id: String) throws -> String {
        guard let conversation = try loadConversation(id: id) else {
            throw CPSLConversationStoreError.conversationNotFound
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(conversation)
        return String(decoding: data, as: UTF8.self)
    }
#endif

    func createConversation(
        id: String? = nil,
        userText: String,
        providerText: String? = nil,
        model: String?,
        systemPrompt: String
    ) throws -> (summary: CPSLConversationSummary, userNode: CPSLStoredNode) {
        let now = Date()
        let conversationID = id ?? UUID().uuidString
        let userNodeID = UUID().uuidString
        let title = Self.generateTitle(from: userText)
        let providerMessage = CPSLOpenAIMessage.user(providerText ?? userText)
        let providerJSON = try encodeProviderMessage(providerMessage)

        try withTransaction {
            try execute(
                """
                INSERT INTO conversations (id, title, root_node_id, current_node_id, model, system_prompt, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(conversationID),
                    .text(title),
                    .text(userNodeID),
                    .text(userNodeID),
                    .nullableText(model),
                    .text(systemPrompt),
                    .date(now),
                    .date(now)
                ]
            )
            try execute(
                """
                INSERT INTO nodes (id, conversation_id, parent_id, role, title, body, model, provider_message_json, sequence, created_at)
                VALUES (?, ?, NULL, ?, NULL, ?, ?, ?, 0, ?)
                """,
                bindings: [
                    .text(userNodeID),
                    .text(conversationID),
                    .text(CPSLChatRole.user.rawValue),
                    .text(userText),
                    .nullableText(model),
                    .text(providerJSON),
                    .date(now)
                ]
            )
        }

        let summary = CPSLConversationSummary(
            id: conversationID,
            title: title,
            currentNodeID: userNodeID,
            model: model,
            createdAt: now,
            updatedAt: now
        )
        let node = CPSLStoredNode(
            id: userNodeID,
            conversationID: conversationID,
            parentID: nil,
            role: .user,
            title: nil,
            body: userText,
            model: model,
            providerMessage: providerMessage,
            sequence: 0,
            createdAt: now
        )
        return (summary, node)
    }

    func appendNode(
        conversationID: String,
        parentID: String?,
        draft: CPSLNodeAppendDraft
    ) throws -> CPSLStoredNode {
        var sequence = 0
        let now = Date()
        let nodeID = UUID().uuidString
        let providerJSON = try draft.providerMessage.map(encodeProviderMessage)

        try withTransaction {
            guard let parentID else {
                throw CPSLConversationStoreError.parentRequired
            }
            try assertParentBelongsToConversation(parentID: parentID, conversationID: conversationID)
            sequence = try nextSequence(conversationID: conversationID)
            try execute(
                """
                INSERT INTO nodes (id, conversation_id, parent_id, role, title, body, model, provider_message_json, sequence, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(nodeID),
                    .text(conversationID),
                    .nullableText(parentID),
                    .text(draft.role.rawValue),
                    .nullableText(draft.title),
                    .text(draft.body),
                    .nullableText(draft.model),
                    .nullableText(providerJSON),
                    .int(sequence),
                    .date(now)
                ]
            )
            try updateConversationCurrentNode(conversationID: conversationID, currentNodeID: nodeID, updatedAt: now)
        }

        return CPSLStoredNode(
            id: nodeID,
            conversationID: conversationID,
            parentID: parentID,
            role: draft.role,
            title: draft.title,
            body: draft.body,
            model: draft.model,
            providerMessage: draft.providerMessage,
            sequence: sequence,
            createdAt: now
        )
    }

    func appendNodes(
        conversationID: String,
        parentID: String?,
        drafts: [CPSLNodeAppendDraft]
    ) throws -> [CPSLStoredNode] {
        guard !drafts.isEmpty else {
            return []
        }

        let now = Date()
        let prepared = try drafts.map { draft in
            (
                id: UUID().uuidString,
                draft: draft,
                providerJSON: try draft.providerMessage.map(encodeProviderMessage)
            )
        }
        var insertedNodes: [CPSLStoredNode] = []

        try withTransaction {
            guard let parentID else {
                throw CPSLConversationStoreError.parentRequired
            }
            try assertParentBelongsToConversation(parentID: parentID, conversationID: conversationID)

            var sequence = try nextSequence(conversationID: conversationID)
            var currentParentID = parentID
            for item in prepared {
                try execute(
                    """
                    INSERT INTO nodes (id, conversation_id, parent_id, role, title, body, model, provider_message_json, sequence, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(item.id),
                        .text(conversationID),
                        .nullableText(currentParentID),
                        .text(item.draft.role.rawValue),
                        .nullableText(item.draft.title),
                        .text(item.draft.body),
                        .nullableText(item.draft.model),
                        .nullableText(item.providerJSON),
                        .int(sequence),
                        .date(now)
                    ]
                )
                insertedNodes.append(
                    CPSLStoredNode(
                        id: item.id,
                        conversationID: conversationID,
                        parentID: currentParentID,
                        role: item.draft.role,
                        title: item.draft.title,
                        body: item.draft.body,
                        model: item.draft.model,
                        providerMessage: item.draft.providerMessage,
                        sequence: sequence,
                        createdAt: now
                    )
                )
                currentParentID = item.id
                sequence += 1
            }

            try updateConversationCurrentNode(
                conversationID: conversationID,
                currentNodeID: currentParentID,
                updatedAt: now
            )
        }

        return insertedNodes
    }

    func updateNodeBody(id: String, body: String) throws {
        try execute(
            "UPDATE nodes SET body = ? WHERE id = ?",
            bindings: [.text(body), .text(id)]
        )
        if let conversationID = try conversationID(forNode: id) {
            try execute(
                "UPDATE conversations SET updated_at = ? WHERE id = ?",
                bindings: [.date(Date()), .text(conversationID)]
            )
        }
    }

    func updateConversationModelIfMissing(conversationID: String, model: String) throws {
        try execute(
            "UPDATE conversations SET model = ? WHERE id = ? AND model IS NULL",
            bindings: [.text(model), .text(conversationID)]
        )
    }

    func deleteConversation(id: String) throws {
        try execute(
            "DELETE FROM conversations WHERE id = ?",
            bindings: [.text(id)]
        )
    }

    func providerMessages(conversationID: String) throws -> [CPSLOpenAIMessage] {
        try loadNodes(conversationID: conversationID).compactMap(\.providerMessage)
    }

    private nonisolated static func migrate(database: OpaquePointer?) throws {
        try execute("PRAGMA journal_mode=DELETE", database: database)
        try execute("PRAGMA synchronous=FULL", database: database)
        try execute("PRAGMA foreign_keys=ON", database: database)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                root_node_id TEXT,
                current_node_id TEXT,
                model TEXT,
                system_prompt TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            database: database
        )
        try addColumnIfMissing(.init(table: "conversations", column: "root_node_id", definition: "TEXT"), database: database)
        try addColumnIfMissing(.init(table: "conversations", column: "current_node_id", definition: "TEXT"), database: database)
        try addColumnIfMissing(.init(table: "conversations", column: "model", definition: "TEXT"), database: database)
        try addColumnIfMissing(.init(table: "conversations", column: "system_prompt", definition: "TEXT"), database: database)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS nodes (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL,
                parent_id TEXT,
                role TEXT NOT NULL,
                title TEXT,
                body TEXT NOT NULL,
                model TEXT,
                provider_message_json TEXT,
                sequence INTEGER NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY(conversation_id) REFERENCES conversations(id) ON DELETE CASCADE,
                FOREIGN KEY(parent_id) REFERENCES nodes(id) ON DELETE SET NULL
            )
            """,
            database: database
        )
        try addColumnIfMissing(.init(table: "nodes", column: "title", definition: "TEXT"), database: database)
        try addColumnIfMissing(.init(table: "nodes", column: "model", definition: "TEXT"), database: database)
        try addColumnIfMissing(.init(table: "nodes", column: "provider_message_json", definition: "TEXT"), database: database)
        try backfillLegacyConversationPointers(database: database)
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_nodes_conversation_sequence_unique ON nodes(conversation_id, sequence)", database: database)
        try execute("CREATE INDEX IF NOT EXISTS idx_nodes_parent ON nodes(parent_id)", database: database)
        try execute("CREATE INDEX IF NOT EXISTS idx_conversations_updated_at ON conversations(updated_at)", database: database)
    }

    private nonisolated static func backfillLegacyConversationPointers(database: OpaquePointer?) throws {
        try execute(
            """
            UPDATE conversations
            SET root_node_id = (
                SELECT id
                FROM nodes
                WHERE nodes.conversation_id = conversations.id
                ORDER BY sequence ASC, created_at ASC
                LIMIT 1
            )
            WHERE NULLIF(root_node_id, '') IS NULL
            """,
            database: database
        )
        try execute(
            """
            UPDATE conversations
            SET current_node_id = (
                SELECT id
                FROM nodes
                WHERE nodes.conversation_id = conversations.id
                ORDER BY sequence DESC, created_at DESC
                LIMIT 1
            )
            WHERE NULLIF(current_node_id, '') IS NULL
            """,
            database: database
        )
        try execute("UPDATE conversations SET system_prompt = '' WHERE system_prompt IS NULL", database: database)
    }

    private nonisolated static func addColumnIfMissing(
        _ column: CPSLSQLiteColumnMigration,
        database: OpaquePointer?
    ) throws {
        guard !column.table.contains("\""),
                !column.name.contains("\""),
                !column.definition.contains(";")
        else {
            throw CPSLConversationStoreError.sqlite("Invalid migration identifier.")
        }

        let columns = try query(.init("PRAGMA table_info(\"\(column.table)\")"), database: database) { statement in
            columnString(statement, 1) ?? ""
        }
        guard !columns.contains(column.name) else {
            return
        }

        try execute(
            "ALTER TABLE \"\(column.table)\" ADD COLUMN \"\(column.name)\" \(column.definition)",
            database: database
        )
    }

    private func nextSequence(conversationID: String) throws -> Int {
        let values = try query(
            "SELECT COALESCE(MAX(sequence), -1) + 1 FROM nodes WHERE conversation_id = ?",
            bindings: [.text(conversationID)]
        ) { statement in
            Int(sqlite3_column_int(statement, 0))
        }
        return values.first ?? 0
    }

    private func assertParentBelongsToConversation(parentID: String, conversationID: String) throws {
        let values = try query(
            "SELECT 1 FROM nodes WHERE id = ? AND conversation_id = ? LIMIT 1",
            bindings: [.text(parentID), .text(conversationID)]
        ) { _ in
            true
        }
        if values.first != true {
            throw CPSLConversationStoreError.parentConversationMismatch
        }
    }

    private func conversationID(forNode id: String) throws -> String? {
        try query(
            "SELECT conversation_id FROM nodes WHERE id = ? LIMIT 1",
            bindings: [.text(id)]
        ) { statement in
            columnString(statement, 0)
        }
        .first ?? nil
    }

    private func updateConversationCurrentNode(
        conversationID: String,
        currentNodeID: String,
        updatedAt: Date
    ) throws {
        try execute(
            "UPDATE conversations SET current_node_id = ?, updated_at = ? WHERE id = ?",
            bindings: [.text(currentNodeID), .date(updatedAt), .text(conversationID)]
        )
    }

    private func encodeProviderMessage(_ message: CPSLOpenAIMessage) throws -> String {
        let data = try JSONEncoder().encode(message)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeProviderMessage(_ json: String?) -> CPSLOpenAIMessage? {
        guard let json, let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(CPSLOpenAIMessage.self, from: data)
    }

    private func execute(_ sql: String, bindings: [CPSLSQLiteBinding] = []) throws {
        try Self.execute(sql, bindings: bindings, database: database)
    }

    private func withTransaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func query<T>(
        _ sql: String,
        bindings: [CPSLSQLiteBinding] = [],
        row: (OpaquePointer?) throws -> T
    ) throws -> [T] {
        try Self.query(.init(sql, bindings: bindings), database: database, row: row)
    }

    private nonisolated static func execute(
        _ sql: String,
        bindings: [CPSLSQLiteBinding] = [],
        database: OpaquePointer?
    ) throws {
        let statement = try prepare(sql, bindings: bindings, database: database)
        defer {
            sqlite3_finalize(statement)
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return
            }
            if result != SQLITE_ROW {
                throw lastError(database: database)
            }
        }
    }

    private nonisolated static func query<T>(
        _ request: CPSLSQLiteStatementRequest,
        database: OpaquePointer?,
        row: (OpaquePointer?) throws -> T
    ) throws -> [T] {
        let statement = try prepare(request.sql, bindings: request.bindings, database: database)
        defer {
            sqlite3_finalize(statement)
        }

        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                values.append(try row(statement))
            } else if result == SQLITE_DONE {
                return values
            } else {
                throw lastError(database: database)
            }
        }
    }

    private nonisolated static func prepare(
        _ sql: String,
        bindings: [CPSLSQLiteBinding],
        database: OpaquePointer?
    ) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError(database: database)
        }
        for (index, binding) in bindings.enumerated() {
            try bind(
                CPSLSQLiteBindOperation(
                    binding: binding,
                    statement: statement,
                    index: Int32(index + 1)
                ),
                database: database
            )
        }
        return statement
    }

    private nonisolated static func bind(
        _ operation: CPSLSQLiteBindOperation,
        database: OpaquePointer?
    ) throws {
        let result: Int32
        switch operation.binding {
        case .null:
            result = sqlite3_bind_null(operation.statement, operation.index)
        case .text(let value):
            result = sqlite3_bind_text(operation.statement, operation.index, value, -1, sqliteTransient)
        case .int(let value):
            result = sqlite3_bind_int(operation.statement, operation.index, Int32(value))
        case .date(let value):
            result = sqlite3_bind_double(operation.statement, operation.index, value.timeIntervalSince1970)
        }
        guard result == SQLITE_OK else {
            throw lastError(database: database)
        }
    }

    private func storedNode(from statement: OpaquePointer?) -> CPSLStoredNode {
        let providerJSON = columnString(statement, 7)
        return CPSLStoredNode(
            id: columnString(statement, 0) ?? "",
            conversationID: columnString(statement, 1) ?? "",
            parentID: columnString(statement, 2),
            role: CPSLChatRole(rawValue: columnString(statement, 3) ?? "") ?? .assistant,
            title: columnString(statement, 4),
            body: columnString(statement, 5) ?? "",
            model: columnString(statement, 6),
            providerMessage: decodeProviderMessage(providerJSON),
            sequence: Int(sqlite3_column_int(statement, 8)),
            createdAt: columnDate(statement, 9)
        )
    }

    private nonisolated static func lastError(database: OpaquePointer?) -> CPSLConversationStoreError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
        return .sqlite(message)
    }

    private static func generateTitle(from text: String) -> String {
        let singleLine = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > 44 else {
            return singleLine.isEmpty ? "Untitled" : singleLine
        }
        return "\(singleLine.prefix(41))..."
    }
}

nonisolated struct CPSLLoadedConversation: Equatable, Sendable, Encodable {
    let summary: CPSLConversationSummary
    let systemPrompt: String
    let nodes: [CPSLStoredNode]
}

nonisolated struct CPSLConversationSummary: Identifiable, Equatable, Sendable, Encodable {
    let id: String
    let title: String
    let currentNodeID: String?
    let model: String?
    let createdAt: Date
    let updatedAt: Date
}

nonisolated struct CPSLStoredNode: Identifiable, Equatable, Sendable, Encodable {
    let id: String
    let conversationID: String
    let parentID: String?
    let role: CPSLChatRole
    let title: String?
    var body: String
    let model: String?
    let providerMessage: CPSLOpenAIMessage?
    let sequence: Int
    let createdAt: Date

    var chatMessage: CPSLChatMessage? {
        guard role.isVisible else {
            return nil
        }
        let providerParts: (displayText: String, attachments: [CPSLAttachment]) = role == .user
            ? CPSLAttachmentPrompt.parse(providerMessage?.content)
            : (displayText: "", attachments: [])
        let bodyParts: (displayText: String, attachments: [CPSLAttachment]) = role == .user
            ? CPSLAttachmentPrompt.parse(body)
            : (displayText: body, attachments: [])
        let attachments = providerParts.attachments.isEmpty
            ? bodyParts.attachments
            : providerParts.attachments
        return CPSLChatMessage(
            id: UUID(uuidString: id) ?? UUID(),
            role: role,
            title: title,
            body: bodyParts.attachments.isEmpty ? body : bodyParts.displayText,
            attachments: attachments
        )
    }
}

nonisolated struct CPSLNodeAppendDraft: Equatable, Sendable {
    let role: CPSLChatRole
    let title: String?
    let body: String
    let model: String?
    let providerMessage: CPSLOpenAIMessage?
}

private nonisolated struct CPSLSQLiteColumnMigration {
    let table: String
    let name: String
    let definition: String

    init(table: String, column: String, definition: String) {
        self.table = table
        name = column
        self.definition = definition
    }
}

private nonisolated struct CPSLSQLiteStatementRequest {
    let sql: String
    let bindings: [CPSLSQLiteBinding]

    init(_ sql: String, bindings: [CPSLSQLiteBinding] = []) {
        self.sql = sql
        self.bindings = bindings
    }
}

private nonisolated struct CPSLSQLiteBindOperation {
    let binding: CPSLSQLiteBinding
    let statement: OpaquePointer?
    let index: Int32
}

nonisolated enum CPSLConversationStoreError: LocalizedError {
    case conversationNotFound
    case openFailed(String)
    case parentRequired
    case parentConversationMismatch
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .conversationNotFound:
            return "Conversation was not found."
        case .openFailed(let message):
            return "Could not open conversations database: \(message)"
        case .parentRequired:
            return "Conversation nodes must have a parent node."
        case .parentConversationMismatch:
            return "Parent node does not belong to the conversation."
        case .sqlite(let message):
            return "SQLite error: \(message)"
        }
    }
}

private nonisolated enum CPSLSQLiteBinding {
    case null
    case text(String)
    case int(Int)
    case date(Date)

    static func nullableText(_ value: String?) -> CPSLSQLiteBinding {
        value.map(CPSLSQLiteBinding.text) ?? .null
    }
}

private nonisolated struct CPSLConversationDatabaseLocation {
    let url: URL
    let usesICloudContainer: Bool

    static func resolve() throws -> CPSLConversationDatabaseLocation {
        let fileManager = FileManager.default
        if let ubiquityURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            let directory = ubiquityURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Herm", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return CPSLConversationDatabaseLocation(
                url: directory.appendingPathComponent("conversations.sqlite"),
                usesICloudContainer: true
            )
        }

        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "herm"
        let directory = supportURL
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Conversations", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return CPSLConversationDatabaseLocation(
            url: directory.appendingPathComponent("conversations.sqlite"),
            usesICloudContainer: false
        )
    }
}

private nonisolated func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let text = sqlite3_column_text(statement, index)
    else {
        return nil
    }
    return String(cString: text)
}

private nonisolated func columnDate(_ statement: OpaquePointer?, _ index: Int32) -> Date {
    Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
}
