import Foundation

actor CPSLConversationStore {
    private nonisolated static let iso8601FractionalSecondsFormat = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private nonisolated static let iso8601SecondPrecisionFormat = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false
    )

    let conversationLogURL: URL
    let traceLogURL: URL
    let usesICloudContainer: Bool

    init() throws {
        try self.init(location: CPSLConversationLogLocation.resolve())
    }

    init(logURL: URL, usesICloudContainer: Bool) throws {
        let stem = logURL.deletingPathExtension().lastPathComponent
        try self.init(
            location: CPSLConversationLogLocation(
                conversationLogURL: logURL,
                traceLogURL: logURL.deletingLastPathComponent()
                    .appendingPathComponent("\(stem)-traces.jsonl"),
                usesICloudContainer: usesICloudContainer
            )
        )
    }

    private init(location: CPSLConversationLogLocation) throws {
        conversationLogURL = location.conversationLogURL
        traceLogURL = location.traceLogURL
        usesICloudContainer = location.usesICloudContainer
        try Self.prepareLog(at: conversationLogURL)
        try Self.prepareLog(at: traceLogURL)
    }

    func fetchConversationSummaries(
        archiveScope: CPSLArchiveScope,
        tagIDs: Set<String>
    ) throws -> [CPSLConversationSummary] {
        let state = try loadState()
        let isArchived = archiveScope == .archived
        return state.conversations.values
            .filter { conversation in
                conversation.archived == isArchived
                    && tagIDs.isSubset(of: state.conversationTags[conversation.id] ?? [])
            }
            .map(\.summary)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadNodes(conversationID: String) throws -> [CPSLStoredNode] {
        try loadState().conversations[conversationID]?.nodes.sorted(by: Self.nodeOrder) ?? []
    }

    func loadConversation(id: String) throws -> CPSLLoadedConversation? {
        guard let conversation = try loadState().conversations[id] else {
            return nil
        }
        return conversation.loadedConversation
    }

#if DEBUG
    func exportConversationJSON(id: String) throws -> String {
        let conversationEvents = try loadConversationEvents()
        let state = Self.replay(conversationEvents)
        guard let conversation = state.conversations[id] else {
            throw CPSLConversationStoreError.conversationNotFound
        }
        let traceEvents = try Self.readJSONLines(CPSLTraceEvent.self, from: traceLogURL)
            .filter { $0.conversationID == id }
        let relevantConversationEvents = conversationEvents.filter { event in
            if event.conversationID == id {
                return true
            }
            if let tagID = event.tag?.id ?? event.tagID {
                return state.conversationTags[id]?.contains(tagID) == true
            }
            return false
        }
        let export = CPSLConversationDebugExport(
            generatedAt: Date(),
            conversation: conversation.loadedConversation,
            tags: (state.conversationTags[id] ?? []).compactMap { state.tags[$0] }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            conversationEvents: relevantConversationEvents,
            traceEvents: traceEvents
        )
        let encoder = Self.jsonEncoder(prettyPrinted: true)
        return String(decoding: try encoder.encode(export), as: UTF8.self)
    }
#endif

    func createConversation(
        id: String? = nil,
        userText: String,
        providerText: String? = nil,
        model: String?,
        systemPrompt: String
    ) throws -> (summary: CPSLConversationSummary, userNode: CPSLStoredNode) {
        let state = try loadState()
        let now = Date()
        let conversationID = id ?? UUID().uuidString
        let userNodeID = UUID().uuidString
        guard state.conversations[conversationID] == nil else {
            throw CPSLConversationStoreError.conversationAlreadyExists
        }
        let userNode = CPSLStoredNode(
            id: userNodeID,
            conversationID: conversationID,
            parentID: nil,
            role: .user,
            title: nil,
            body: userText,
            model: model,
            providerMessage: .user(providerText ?? userText),
            sequence: 0,
            createdAt: now
        )
        let conversation = CPSLConversationLogRecord(
            id: conversationID,
            title: Self.generateTitle(from: userText),
            currentNodeID: userNodeID,
            model: model,
            systemPrompt: systemPrompt,
            createdAt: now,
            updatedAt: now,
            pinned: false,
            archived: false,
            nodes: [userNode]
        )
        try appendConversationEvent(
            CPSLConversationLogEvent(
                timestamp: now,
                kind: .conversationCreated,
                conversationID: conversationID,
                conversation: conversation
            )
        )
        return (conversation.summary, userNode)
    }

    func appendNode(
        conversationID: String,
        parentID: String?,
        draft: CPSLNodeAppendDraft
    ) throws -> CPSLStoredNode {
        try appendNodes(conversationID: conversationID, parentID: parentID, drafts: [draft])[0]
    }

    func appendNodes(
        conversationID: String,
        parentID: String?,
        drafts: [CPSLNodeAppendDraft]
    ) throws -> [CPSLStoredNode] {
        guard !drafts.isEmpty else {
            return []
        }
        guard let parentID else {
            throw CPSLConversationStoreError.parentRequired
        }
        let state = try loadState()
        guard let conversation = state.conversations[conversationID],
              conversation.nodes.contains(where: { $0.id == parentID })
        else {
            throw CPSLConversationStoreError.parentConversationMismatch
        }

        let now = Date()
        var nextSequence = (conversation.nodes.map(\.sequence).max() ?? -1) + 1
        var currentParentID = parentID
        let nodes = drafts.map { draft in
            defer { nextSequence += 1 }
            let node = CPSLStoredNode(
                id: UUID().uuidString,
                conversationID: conversationID,
                parentID: currentParentID,
                role: draft.role,
                title: draft.title,
                body: draft.body,
                model: draft.model,
                providerMessage: draft.providerMessage,
                sequence: nextSequence,
                createdAt: now
            )
            currentParentID = node.id
            return node
        }
        try appendConversationEvent(
            CPSLConversationLogEvent(
                timestamp: now,
                kind: .nodesAppended,
                conversationID: conversationID,
                nodes: nodes
            )
        )
        return nodes
    }

    func updateNodeBody(conversationID: String, id: String, body: String) throws {
        try appendConversationEvent(
            CPSLConversationLogEvent(
                kind: .nodeBodyUpdated,
                conversationID: conversationID,
                nodeID: id,
                body: body
            )
        )
    }

    func updateConversationModelIfMissing(conversationID: String, model: String) throws {
        guard let conversation = try loadState().conversations[conversationID] else {
            throw CPSLConversationStoreError.conversationNotFound
        }
        guard conversation.model == nil else {
            return
        }
        try appendConversationEvent(
            CPSLConversationLogEvent(
                kind: .conversationModelSet,
                conversationID: conversationID,
                model: model
            )
        )
    }

    func deleteConversation(id: String) throws {
        try appendConversationEvent(
            CPSLConversationLogEvent(kind: .conversationDeleted, conversationID: id)
        )
    }

    func setPinned(conversationID: String, pinned: Bool) throws {
        try appendConversationEvent(
            CPSLConversationLogEvent(
                kind: .conversationPinned,
                conversationID: conversationID,
                flag: pinned
            )
        )
    }

    func setArchived(conversationID: String, archived: Bool) throws {
        try appendConversationEvent(
            CPSLConversationLogEvent(
                kind: .conversationArchived,
                conversationID: conversationID,
                flag: archived
            )
        )
    }

    func renameConversation(id: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CPSLConversationStoreError.invalidTitle
        }
        try appendConversationEvent(
            CPSLConversationLogEvent(
                kind: .conversationRenamed,
                conversationID: id,
                title: trimmed
            )
        )
    }

    static func normalizedTagName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40 else {
            throw CPSLConversationStoreError.invalidTagName
        }
        return trimmed
    }

    func allTags() throws -> [CPSLTag] {
        try loadState().tags.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func createTag(name: String, color: String) throws -> CPSLTag {
        let clean = try Self.normalizedTagName(name)
        let state = try loadState()
        guard !Self.tagNameExists(clean, in: state, excludingID: nil) else {
            throw CPSLConversationStoreError.duplicateTagName
        }
        let tag = CPSLTag(id: UUID().uuidString, name: clean, color: color, createdAt: Date())
        try appendConversationEvent(CPSLConversationLogEvent(kind: .tagCreated, tag: tag))
        return tag
    }

    func renameTag(id: String, name: String) throws {
        let clean = try Self.normalizedTagName(name)
        let state = try loadState()
        guard !Self.tagNameExists(clean, in: state, excludingID: id) else {
            throw CPSLConversationStoreError.duplicateTagName
        }
        try appendConversationEvent(
            CPSLConversationLogEvent(kind: .tagRenamed, title: clean, tagID: id)
        )
    }

    func deleteTag(id: String) throws {
        try appendConversationEvent(CPSLConversationLogEvent(kind: .tagDeleted, tagID: id))
    }

    func tagIDs(forConversation id: String) throws -> Set<String> {
        try loadState().conversationTags[id] ?? []
    }

    func setTags(conversationID: String, tagIDs: Set<String>) throws {
        try appendConversationEvent(
            CPSLConversationLogEvent(
                kind: .conversationTagsSet,
                conversationID: conversationID,
                tagIDs: tagIDs.sorted()
            )
        )
    }

    func providerMessages(conversationID: String) throws -> [CPSLOpenAIMessage] {
        try loadNodes(conversationID: conversationID).compactMap(\.providerMessage)
    }

    func recordProviderRequest(
        conversationID: String,
        model: String,
        messages: [CPSLOpenAIMessage],
        tools: [CPSLOpenAITool],
        maxTokens: Int?,
        scope: String
    ) throws {
        try appendTraceEvent(
            CPSLTraceEvent(
                conversationID: conversationID,
                kind: .providerRequest,
                scope: scope,
                providerRequest: CPSLProviderRequestTrace(
                    model: model,
                    messages: messages,
                    tools: tools,
                    maxTokens: maxTokens
                )
            )
        )
    }

    func recordProviderResponse(
        conversationID: String,
        completion: CPSLOpenAICompletion,
        scope: String
    ) throws {
        try appendTraceEvent(
            CPSLTraceEvent(
                conversationID: conversationID,
                kind: .providerResponse,
                scope: scope,
                providerResponse: CPSLProviderResponseTrace(completion: completion)
            )
        )
    }

    func recordToolInvocation(
        conversationID: String,
        nodeID: String?,
        invocation: CPSLToolTraceInvocation
    ) throws {
        try appendTraceEvent(
            CPSLTraceEvent(
                conversationID: conversationID,
                kind: .toolInvocation,
                nodeID: nodeID,
                toolInvocation: invocation
            )
        )
    }

    func toolStatusInvocations(
        conversationID: String,
        nodeIDs: Set<String>,
        limitPerNode: Int = 4
    ) throws -> [String: [CPSLToolStatusInvocation]] {
        guard !nodeIDs.isEmpty, limitPerNode > 0 else {
            return [:]
        }

        var result: [String: [CPSLToolStatusInvocation]] = [:]
        try Self.forEachJSONLine(CPSLToolInvocationTraceEnvelope.self, from: traceLogURL) { event in
            guard event.conversationID == conversationID,
                  event.kind == .toolInvocation,
                  let nodeID = event.nodeID,
                  nodeIDs.contains(nodeID),
                  let invocation = event.toolInvocation
            else {
                return
            }

            var invocations = result[nodeID, default: []]
            invocations.append(CPSLToolStatusInvocation(traceInvocation: invocation))
            result[nodeID] = Array(invocations.suffix(limitPerNode))
        }
        return result
    }

    func recordWebVisit(
        conversationID: String,
        nodeID: String,
        visit: CPSLWebSearchVisit
    ) throws {
        try appendTraceEvent(
            CPSLTraceEvent(
                conversationID: conversationID,
                kind: .webVisit,
                nodeID: nodeID,
                webVisit: visit
            )
        )
    }

    func recordError(conversationID: String, message: String, scope: String) throws {
        try appendTraceEvent(
            CPSLTraceEvent(
                conversationID: conversationID,
                kind: .error,
                scope: scope,
                message: message
            )
        )
    }

    private func loadState() throws -> CPSLConversationLogState {
        Self.replay(try loadConversationEvents())
    }

    private func loadConversationEvents() throws -> [CPSLConversationLogEvent] {
        try Self.readJSONLines(CPSLConversationLogEvent.self, from: conversationLogURL)
    }

    private func appendConversationEvent(_ event: CPSLConversationLogEvent) throws {
        try Self.appendJSONLine(event, to: conversationLogURL)
    }

    private func appendTraceEvent(_ event: CPSLTraceEvent) throws {
        try Self.appendJSONLine(event, to: traceLogURL)
    }

    private static func replay(_ events: [CPSLConversationLogEvent]) -> CPSLConversationLogState {
        var state = CPSLConversationLogState()
        for event in events {
            switch event.kind {
            case .conversationCreated:
                guard let conversation = event.conversation,
                      let conversationID = event.conversationID
                else { continue }
                state.conversations[conversationID] = conversation
            case .nodesAppended:
                guard let conversationID = event.conversationID,
                      var conversation = state.conversations[conversationID],
                      let nodes = event.nodes,
                      let lastNode = nodes.last
                else { continue }
                conversation.nodes.append(contentsOf: nodes)
                conversation.currentNodeID = lastNode.id
                conversation.updatedAt = event.timestamp
                state.conversations[conversationID] = conversation
            case .nodeBodyUpdated:
                guard let conversationID = event.conversationID,
                      let nodeID = event.nodeID,
                      let body = event.body,
                      var conversation = state.conversations[conversationID],
                      let index = conversation.nodes.firstIndex(where: { $0.id == nodeID })
                else { continue }
                conversation.nodes[index].body = body
                conversation.updatedAt = event.timestamp
                state.conversations[conversationID] = conversation
            case .conversationModelSet:
                guard let conversationID = event.conversationID,
                      let model = event.model,
                      var conversation = state.conversations[conversationID],
                      conversation.model == nil
                else { continue }
                conversation.model = model
                state.conversations[conversationID] = conversation
            case .conversationDeleted:
                guard let conversationID = event.conversationID else { continue }
                state.conversations.removeValue(forKey: conversationID)
                state.conversationTags.removeValue(forKey: conversationID)
            case .conversationPinned:
                guard let conversationID = event.conversationID,
                      let flag = event.flag,
                      var conversation = state.conversations[conversationID]
                else { continue }
                conversation.pinned = flag
                state.conversations[conversationID] = conversation
            case .conversationArchived:
                guard let conversationID = event.conversationID,
                      let flag = event.flag,
                      var conversation = state.conversations[conversationID]
                else { continue }
                conversation.archived = flag
                state.conversations[conversationID] = conversation
            case .conversationRenamed:
                guard let conversationID = event.conversationID,
                      let title = event.title,
                      var conversation = state.conversations[conversationID]
                else { continue }
                conversation.title = title
                state.conversations[conversationID] = conversation
            case .tagCreated:
                guard let tag = event.tag else { continue }
                state.tags[tag.id] = tag
            case .tagRenamed:
                guard let tagID = event.tagID,
                      let name = event.title,
                      var tag = state.tags[tagID]
                else { continue }
                tag.name = name
                state.tags[tagID] = tag
            case .tagDeleted:
                guard let tagID = event.tagID else { continue }
                state.tags.removeValue(forKey: tagID)
                for conversationID in Array(state.conversationTags.keys) {
                    state.conversationTags[conversationID]?.remove(tagID)
                }
            case .conversationTagsSet:
                guard let conversationID = event.conversationID else { continue }
                state.conversationTags[conversationID] = Set(event.tagIDs ?? [])
            }
        }
        return state
    }

    private static func nodeOrder(_ lhs: CPSLStoredNode, _ rhs: CPSLStoredNode) -> Bool {
        lhs.sequence == rhs.sequence ? lhs.createdAt < rhs.createdAt : lhs.sequence < rhs.sequence
    }

    private static func tagNameExists(
        _ name: String,
        in state: CPSLConversationLogState,
        excludingID: String?
    ) -> Bool {
        state.tags.values.contains {
            $0.id != excludingID && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func generateTitle(from text: String) -> String {
        let singleLine = text
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return singleLine.isEmpty ? "Untitled" : singleLine
    }

    private static func prepareLog(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CPSLConversationStoreError.couldNotCreateLog(url.lastPathComponent)
        }
    }

    private static func appendJSONLine<Value: Encodable>(_ value: Value, to url: URL) throws {
        var data = try jsonEncoder().encode(value)
        data.append(0x0A)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try repairPartialTail(in: handle, at: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func repairPartialTail(in handle: FileHandle, at url: URL) throws {
        let endOffset = try handle.seekToEnd()
        guard endOffset > 0 else {
            return
        }
        try handle.seek(toOffset: endOffset - 1)
        guard try handle.read(upToCount: 1) != Data([0x0A]) else {
            return
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let validEnd = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        try handle.truncate(atOffset: UInt64(validEnd))
    }

    private static func readJSONLines<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> [Value] {
        var values: [Value] = []
        try forEachJSONLine(type, from: url) { value in
            values.append(value)
        }
        return values
    }

    private static func forEachJSONLine<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        consume: (Value) -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let decoder = jsonDecoder()
        var buffer = Data()
        var lineNumber = 0

        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            buffer.append(chunk)
            var lineStart = buffer.startIndex

            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                lineNumber += 1
                if lineStart < newline {
                    do {
                        consume(try decoder.decode(type, from: Data(buffer[lineStart..<newline])))
                    } catch {
                        throw CPSLConversationStoreError.corruptLogLine(
                            lineNumber,
                            url.lastPathComponent
                        )
                    }
                }
                lineStart = buffer.index(after: newline)
            }

            if lineStart > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
        }

        guard !buffer.isEmpty else {
            return
        }

        // A valid final line without a newline is accepted. An undecodable tail is an interrupted append.
        if let value = try? decoder.decode(type, from: buffer) {
            consume(value)
        }
    }

    private static func jsonEncoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601FractionalSecondsFormat.format(date))
        }
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return encoder
    }

    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = (try? Self.iso8601FractionalSecondsFormat.parse(value))
                ?? (try? Self.iso8601SecondPrecisionFormat.parse(value))
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO-8601 date.")
                )
            }
            return date
        }
        return decoder
    }
}

nonisolated struct CPSLLoadedConversation: Equatable, Sendable, Codable {
    let summary: CPSLConversationSummary
    let systemPrompt: String
    let nodes: [CPSLStoredNode]
}

nonisolated struct CPSLConversationSummary: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let title: String
    let currentNodeID: String?
    let model: String?
    let createdAt: Date
    let updatedAt: Date
    let pinned: Bool
    let archived: Bool
}

nonisolated struct CPSLTag: Identifiable, Equatable, Sendable, Codable {
    let id: String
    var name: String
    var color: String
    let createdAt: Date
}

nonisolated enum CPSLArchiveScope: Sendable, Equatable {
    case active
    case archived
}

nonisolated struct CPSLStoredNode: Identifiable, Equatable, Sendable, Codable {
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

nonisolated enum CPSLConversationStoreError: LocalizedError {
    case conversationNotFound
    case conversationAlreadyExists
    case parentRequired
    case parentConversationMismatch
    case invalidTagName
    case duplicateTagName
    case invalidTitle
    case couldNotCreateLog(String)
    case corruptLogLine(Int, String)

    var errorDescription: String? {
        switch self {
        case .conversationNotFound:
            return "Conversation was not found."
        case .conversationAlreadyExists:
            return "Conversation already exists."
        case .parentRequired:
            return "Conversation nodes must have a parent node."
        case .parentConversationMismatch:
            return "Parent node does not belong to the conversation."
        case .invalidTagName:
            return "Tag name is empty or too long."
        case .duplicateTagName:
            return "A tag with this name already exists."
        case .invalidTitle:
            return "Conversation title is empty."
        case .couldNotCreateLog(let name):
            return "Could not create JSONL log \(name)."
        case .corruptLogLine(let line, let name):
            return "Could not decode line \(line) of JSONL log \(name)."
        }
    }
}

private nonisolated struct CPSLConversationLogState {
    var conversations: [String: CPSLConversationLogRecord] = [:]
    var tags: [String: CPSLTag] = [:]
    var conversationTags: [String: Set<String>] = [:]
}

private nonisolated struct CPSLConversationLogRecord: Codable {
    let id: String
    var title: String
    var currentNodeID: String?
    var model: String?
    let systemPrompt: String
    let createdAt: Date
    var updatedAt: Date
    var pinned: Bool
    var archived: Bool
    var nodes: [CPSLStoredNode]

    var summary: CPSLConversationSummary {
        CPSLConversationSummary(
            id: id,
            title: title,
            currentNodeID: currentNodeID,
            model: model,
            createdAt: createdAt,
            updatedAt: updatedAt,
            pinned: pinned,
            archived: archived
        )
    }

    var loadedConversation: CPSLLoadedConversation {
        CPSLLoadedConversation(summary: summary, systemPrompt: systemPrompt, nodes: nodes)
    }
}

private nonisolated enum CPSLConversationLogEventKind: String, Codable {
    case conversationCreated = "conversation.created"
    case nodesAppended = "nodes.appended"
    case nodeBodyUpdated = "node.body_updated"
    case conversationModelSet = "conversation.model_set"
    case conversationDeleted = "conversation.deleted"
    case conversationPinned = "conversation.pinned"
    case conversationArchived = "conversation.archived"
    case conversationRenamed = "conversation.renamed"
    case tagCreated = "tag.created"
    case tagRenamed = "tag.renamed"
    case tagDeleted = "tag.deleted"
    case conversationTagsSet = "conversation.tags_set"
}

private nonisolated struct CPSLConversationLogEvent: Codable {
    let schemaVersion: Int
    let id: String
    let timestamp: Date
    let kind: CPSLConversationLogEventKind
    let conversationID: String?
    let conversation: CPSLConversationLogRecord?
    let nodes: [CPSLStoredNode]?
    let nodeID: String?
    let body: String?
    let model: String?
    let flag: Bool?
    let title: String?
    let tag: CPSLTag?
    let tagID: String?
    let tagIDs: [String]?

    init(
        timestamp: Date = Date(),
        kind: CPSLConversationLogEventKind,
        conversationID: String? = nil,
        conversation: CPSLConversationLogRecord? = nil,
        nodes: [CPSLStoredNode]? = nil,
        nodeID: String? = nil,
        body: String? = nil,
        model: String? = nil,
        flag: Bool? = nil,
        title: String? = nil,
        tag: CPSLTag? = nil,
        tagID: String? = nil,
        tagIDs: [String]? = nil
    ) {
        schemaVersion = 1
        id = UUID().uuidString
        self.timestamp = timestamp
        self.kind = kind
        self.conversationID = conversationID
        self.conversation = conversation
        self.nodes = nodes
        self.nodeID = nodeID
        self.body = body
        self.model = model
        self.flag = flag
        self.title = title
        self.tag = tag
        self.tagID = tagID
        self.tagIDs = tagIDs
    }
}

private nonisolated enum CPSLTraceEventKind: String, Codable {
    case providerRequest = "provider.request"
    case providerResponse = "provider.response"
    case toolInvocation = "tool.invocation"
    case webVisit = "web.visit"
    case error
}

private nonisolated struct CPSLProviderRequestTrace: Codable {
    let model: String
    let messages: [CPSLOpenAIMessage]
    let tools: [CPSLOpenAITool]
    let maxTokens: Int?
}

private nonisolated struct CPSLProviderResponseTrace: Codable {
    let text: String
    let toolCalls: [CPSLOpenAIToolCall]
    let finishReason: String?
    let model: String

    init(completion: CPSLOpenAICompletion) {
        text = completion.text
        toolCalls = completion.toolCalls
        finishReason = completion.finishReason
        model = completion.model
    }
}

private nonisolated struct CPSLToolInvocationTraceEnvelope: Decodable {
    let conversationID: String
    let kind: CPSLTraceEventKind
    let nodeID: String?
    let toolInvocation: CPSLToolTraceInvocation?
}

private nonisolated struct CPSLTraceEvent: Codable {
    let schemaVersion: Int
    let id: String
    let timestamp: Date
    let conversationID: String
    let kind: CPSLTraceEventKind
    let scope: String?
    let nodeID: String?
    let providerRequest: CPSLProviderRequestTrace?
    let providerResponse: CPSLProviderResponseTrace?
    let toolInvocation: CPSLToolTraceInvocation?
    let webVisit: CPSLWebSearchVisit?
    let message: String?

    init(
        conversationID: String,
        kind: CPSLTraceEventKind,
        scope: String? = nil,
        nodeID: String? = nil,
        providerRequest: CPSLProviderRequestTrace? = nil,
        providerResponse: CPSLProviderResponseTrace? = nil,
        toolInvocation: CPSLToolTraceInvocation? = nil,
        webVisit: CPSLWebSearchVisit? = nil,
        message: String? = nil
    ) {
        schemaVersion = 1
        id = UUID().uuidString
        timestamp = Date()
        self.conversationID = conversationID
        self.kind = kind
        self.scope = scope
        self.nodeID = nodeID
        self.providerRequest = providerRequest
        self.providerResponse = providerResponse
        self.toolInvocation = toolInvocation
        self.webVisit = webVisit
        self.message = message
    }
}

#if DEBUG
private nonisolated struct CPSLConversationDebugExport: Encodable {
    let format = "herm.debug-export"
    let schemaVersion = 1
    let generatedAt: Date
    let documentation = CPSLConversationDebugExportDocumentation()
    let conversation: CPSLLoadedConversation
    let tags: [CPSLTag]
    let conversationEvents: [CPSLConversationLogEvent]
    let traceEvents: [CPSLTraceEvent]
}

private nonisolated struct CPSLConversationDebugExportDocumentation: Encodable {
    let overview = "Reconstructed conversation plus the append-only JSONL events used to build and debug it."
    let ordering = "conversationEvents and traceEvents are chronological. timestamp is ISO-8601 UTC; schemaVersion versions each entry."
    let conversationEvents = "Durable state mutations from conversations.jsonl. Replay kind in order to reconstruct state."
    let traceEvents = "Detailed provider, tool, web, and error records from traces.jsonl. These are not required to render the conversation."
    let jqExamples = [
        ".conversation.summary",
        ".conversation.nodes[] | {sequence, role, title, body}",
        ".traceEvents[] | select(.kind == \"tool.invocation\") | .toolInvocation",
        ".traceEvents[] | select(.kind == \"provider.response\") | .providerResponse",
    ]
}
#endif

private nonisolated struct CPSLConversationLogLocation {
    let conversationLogURL: URL
    let traceLogURL: URL
    let usesICloudContainer: Bool

    static func resolve() throws -> CPSLConversationLogLocation {
        let fileManager = FileManager.default
        if let ubiquityURL = fileManager.url(forUbiquityContainerIdentifier: nil) {
            let directory = ubiquityURL
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Herm", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return CPSLConversationLogLocation(
                conversationLogURL: directory.appendingPathComponent("conversations.jsonl"),
                traceLogURL: directory.appendingPathComponent("traces.jsonl"),
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
        return CPSLConversationLogLocation(
            conversationLogURL: directory.appendingPathComponent("conversations.jsonl"),
            traceLogURL: directory.appendingPathComponent("traces.jsonl"),
            usesICloudContainer: false
        )
    }
}
