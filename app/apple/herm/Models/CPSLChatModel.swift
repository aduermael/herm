import Combine
import Foundation
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
final class CPSLChatModel: ObservableObject {
    @Published var promptText = ""
    @Published var comingSoonMessage: String?
    @Published private(set) var messages: [CPSLChatMessage] = []
    @Published private(set) var conversations: [CPSLConversationSummary] = []
    @Published private(set) var selectedConversationID: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isDrawerOpen = false
    @Published private(set) var isFileBrowserOpen = false
    @Published private(set) var browserPath = "/"
    @Published private(set) var browserEntries: [CPSLFileEntry] = []
    @Published private(set) var childEntriesByPath: [String: [CPSLFileEntry]] = [:]
    @Published private(set) var expandedFilePaths: Set<String> = []
    @Published private(set) var loadingFilePaths: Set<String> = []
    @Published private(set) var fileBrowserError: String?

    private let service = CPSLDebugService()
    private var store: CPSLConversationStore?
    private var storeLoadTask: Task<CPSLConversationStore, Error>?
    private var currentNodeID: String?
    private var currentSystemPrompt: String?
    private var streamingAssistantMessageID: UUID?
    private var isSuppressingAssistantStream = false
    private var typewriterBuffer = ""
    private var typewriterTask: Task<Void, Never>?
    private let estimatedBytesPerToken = 4
    private let toolResultClearThreshold = 0.80
    private let recentToolResultsToKeep = 4

    private let systemPrompt = """
    You are Herm, an AI agent running inside an iOS/macOS app.
    You support OpenAI-compatible chat completions only. Server-side provider tools, including web search, are not available.
    CPSL is your execution environment: a Unix-like local environment with a filesystem, current directory, and command-style capabilities exposed through Luau APIs. Luau is the interface instead of Bash, and it is the only supported execution language.
    Your client-side tools are local_sandbox_exec and agent. Use tools only when they materially help with the user's request.
    Every local_sandbox_exec call must include intent: one short high-level user-facing action phrase, such as "Exploring files", "Reading settings", or "Checking results". Do not mention code, sandbox, workdir, paths, tool names, or implementation details in intent.
    When you call tools, assistant content may contain the same kind of high-level status phrase, but never code or implementation details.
    local_sandbox_exec runs Luau source in CPSL. The current CPSL directory is supplied in each request. Never guess CPSL API signatures: call help() and each module's help function, such as fs.help(), before using APIs.
    agent spawns a focused sub-agent with its own turn budget. Use explore mode for research and reading. Use general mode for execution-heavy or implementation-style work. Keep sub-agent tasks narrow and self-contained.
    Luau essentials: declare variables with local, use 1-based indexing, concatenate strings with .., use ~= for not-equal, and use pcall(fn) for recoverable errors.
    Do not try to launch external lua/luau interpreters, Bash, Python, shell commands, package managers, background services, host Lua APIs, or paths outside CPSL.
    Do not ask the provider to browse the web, do not imply host shell access, and do not share local files unless the user explicitly requests file content.
    """

    init() {
        Task {
            await bootstrap()
        }
    }

    func showComingSoon(_ message: String = "coming soon") {
        comingSoonMessage = message
    }

    func startNewConversation() {
        guard !isRunning else {
            return
        }

        promptText = ""
        comingSoonMessage = nil
        messages = []
        selectedConversationID = nil
        currentNodeID = nil
        currentSystemPrompt = nil
        isFileBrowserOpen = false
        isDrawerOpen = false
    }

    func toggleDrawer() {
        isDrawerOpen.toggle()
        if isDrawerOpen {
            isFileBrowserOpen = false
        }
    }

    func closeDrawer() {
        isDrawerOpen = false
    }

    func selectConversation(id: String) {
        guard !isRunning else {
            return
        }

        Task {
            await loadConversation(id: id)
        }
    }

    func deleteConversation(id: String) {
        guard !isRunning else {
            return
        }

        Task {
            await deleteStoredConversation(id: id)
        }
    }

#if DEBUG
    func copyConversationJSONToPasteboard() {
        Task { @MainActor in
            do {
                let json = try await currentConversationDebugJSON()
                Self.copyToPasteboard(json)
            } catch {
                appendErrorMessage(title: "Debug", body: error.localizedDescription)
            }
        }
    }
#endif

    func submitPrompt() {
        let input = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isRunning else {
            return
        }

        promptText = ""
        isFileBrowserOpen = false
        isDrawerOpen = false
        if input.hasPrefix("!") {
            let command = String(input.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                appendErrorMessage(title: nil, body: "Enter a command after !")
                return
            }
            runCommand(command)
            return
        }

        isRunning = true
        Task {
            await runAgent(userText: input)
        }
    }

    func toggleFileBrowser() {
        isFileBrowserOpen.toggle()
        if isFileBrowserOpen {
            isDrawerOpen = false
        }

        if isFileBrowserOpen && browserEntries.isEmpty && loadingFilePaths.isEmpty {
            loadBrowserPath("/")
        }
    }

    func closeFileBrowser() {
        isFileBrowserOpen = false
    }

    func loadBrowserPath(_ path: String) {
        let normalized = normalizedPath(path)
        browserPath = normalized
        fileBrowserError = nil
        expandedFilePaths.removeAll()
        childEntriesByPath.removeAll()

        Task {
            await loadDirectory(normalized, childOf: nil)
        }
    }

    func navigateToParentDirectory() {
        loadBrowserPath(parentPath(of: browserPath))
    }

    func toggleExpansion(for entry: CPSLFileEntry) {
        guard entry.isDirectory else {
            return
        }

        if expandedFilePaths.contains(entry.path) {
            expandedFilePaths.remove(entry.path)
            return
        }

        expandedFilePaths.insert(entry.path)
        if childEntriesByPath[entry.path] == nil {
            Task {
                await loadDirectory(entry.path, childOf: entry.path)
            }
        }
    }

    func openFileEntry(_ entry: CPSLFileEntry) {
        if entry.isDirectory {
            loadBrowserPath(entry.path)
        } else {
            showComingSoon("coming soon")
        }
    }

    func children(for path: String) -> [CPSLFileEntry] {
        childEntriesByPath[path] ?? []
    }

    func isExpanded(_ entry: CPSLFileEntry) -> Bool {
        expandedFilePaths.contains(entry.path)
    }

    func isLoading(_ path: String) -> Bool {
        loadingFilePaths.contains(path)
    }

    private func bootstrap() async {
        do {
            let store = try await loadStore()
            conversations = try await store.loadSummaries()
            if selectedConversationID == nil, messages.isEmpty, let first = conversations.first {
                await loadConversation(id: first.id)
            }
        } catch {
            appendErrorMessage(title: "Storage", body: error.localizedDescription)
        }
    }

    private func loadStore() async throws -> CPSLConversationStore {
        if let store {
            return store
        }
        if let storeLoadTask {
            return try await storeLoadTask.value
        }

        let task = Task<CPSLConversationStore, Error> {
            try CPSLConversationStore()
        }
        storeLoadTask = task
        do {
            let loadedStore = try await task.value
            store = loadedStore
            storeLoadTask = nil
            return loadedStore
        } catch {
            storeLoadTask = nil
            throw error
        }
    }

    private func loadConversation(id: String) async {
        let store: CPSLConversationStore
        do {
            store = try await loadStore()
        } catch {
            appendErrorMessage(title: "Storage", body: error.localizedDescription)
            return
        }

        do {
            guard let conversation = try await store.loadConversation(id: id) else {
                return
            }
            selectedConversationID = conversation.summary.id
            currentNodeID = conversation.summary.currentNodeID
            currentSystemPrompt = conversation.systemPrompt.isEmpty ? systemPrompt : conversation.systemPrompt
            messages = conversation.nodes.compactMap(\.chatMessage)
            conversations = try await store.loadSummaries()
            isDrawerOpen = false
            isFileBrowserOpen = false
        } catch {
            appendErrorMessage(title: "Conversation", body: error.localizedDescription)
        }
    }

    private func deleteStoredConversation(id: String) async {
        let store: CPSLConversationStore
        do {
            store = try await loadStore()
        } catch {
            appendErrorMessage(title: "Storage", body: error.localizedDescription)
            return
        }

        do {
            try await store.deleteConversation(id: id)
            conversations = try await store.loadSummaries()
            if selectedConversationID == id {
                selectedConversationID = nil
                currentNodeID = nil
                currentSystemPrompt = nil
                messages = []
            }
        } catch {
            appendErrorMessage(title: "Conversation", body: error.localizedDescription)
        }
    }

#if DEBUG
    private func currentConversationDebugJSON() async throws -> String {
        if let selectedConversationID {
            let store = try await loadStore()
            return try await store.exportConversationJSON(id: selectedConversationID)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(CPSLDebugConversationSnapshot(messages: messages))
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func copyToPasteboard(_ string: String) {
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
#elseif canImport(UIKit)
        UIPasteboard.general.string = string
#endif
    }
#endif

    private func runAgent(userText: String) async {
        let store: CPSLConversationStore
        do {
            store = try await loadStore()
        } catch {
            appendErrorMessage(title: "Storage", body: error.localizedDescription)
            isRunning = false
            return
        }

        streamingAssistantMessageID = nil
        typewriterBuffer = ""
        typewriterTask?.cancel()
        typewriterTask = nil
        var activeConversationID: String?
        var activeParentID: String?
        var activeModel: String?

        do {
            var conversationID: String
            var parentID: String

            if let selectedConversationID, let currentNodeID {
                conversationID = selectedConversationID
                let node = try await store.appendNode(
                    conversationID: selectedConversationID,
                    parentID: currentNodeID,
                    role: .user,
                    title: nil,
                    body: userText,
                    model: nil,
                    providerMessage: .user(userText)
                )
                parentID = node.id
                self.currentNodeID = node.id
                if let message = node.chatMessage {
                    messages.append(message)
                }
                activeConversationID = conversationID
                activeParentID = parentID
            } else {
                let created = try await store.createConversation(
                    userText: userText,
                    model: nil,
                    systemPrompt: systemPrompt
                )
                conversationID = created.summary.id
                parentID = created.userNode.id
                selectedConversationID = conversationID
                currentNodeID = parentID
                currentSystemPrompt = systemPrompt
                if let message = created.userNode.chatMessage {
                    messages.append(message)
                }
                activeConversationID = conversationID
                activeParentID = parentID
            }
            conversations = try await store.loadSummaries()

            let config = try CPSLAgentConfig.load()
            let client = CPSLOpenAIClient(config: config)
            activeModel = config.model
            try await store.updateConversationModelIfMissing(conversationID: conversationID, model: config.model)
            var providerMessages = try await store.providerMessages(conversationID: conversationID)
            let replaySystemPrompt = currentSystemPrompt ?? systemPrompt
            try await runProviderLoop(
                client: client,
                store: store,
                conversationID: conversationID,
                parentID: &parentID,
                config: config,
                systemPrompt: replaySystemPrompt,
                providerMessages: &providerMessages
            ) { nodeID in
                activeParentID = nodeID
            }
            currentNodeID = parentID
            conversations = try await store.loadSummaries()
        } catch {
            activeParentID = await persistStreamingAssistantIfNeeded(
                store: store,
                conversationID: activeConversationID,
                parentID: activeParentID,
                model: activeModel
            )
            await appendAgentError(
                error.localizedDescription,
                store: store,
                conversationID: activeConversationID,
                parentID: activeParentID,
                model: activeModel
            )
            if let summaries = try? await store.loadSummaries() {
                conversations = summaries
            }
        }

        await finishTypewriter()
        streamingAssistantMessageID = nil
        isRunning = false
    }

    private func runProviderLoop(
        client: CPSLOpenAIClient,
        store: CPSLConversationStore,
        conversationID: String,
        parentID: inout String,
        config: CPSLAgentConfig,
        systemPrompt: String,
        providerMessages: inout [CPSLOpenAIMessage],
        onParentIDChange: (String) -> Void
    ) async throws {
        var toolStatusNodeID: String?
        var toolStatus = CPSLToolStatusPayload.running()
        var lastToolStatusState: CPSLToolStatusState = .succeeded

        for iteration in 0..<config.maxToolRounds {
            let sandboxDirectory = await service.currentDirectory()
            let requestMessages = preparedRequestMessages(
                systemPrompt: systemPrompt,
                providerMessages: providerMessages,
                config: config,
                sandboxDirectory: sandboxDirectory,
                iteration: iteration,
                maxIterations: config.maxToolRounds
            )
            isSuppressingAssistantStream = false
            let completion = try await client.streamChat(
                messages: requestMessages,
                tools: CPSLOpenAITool.availableTools(
                    allowsSubagents: config.maxAgentDepth > 0,
                    currentDirectory: sandboxDirectory
                ),
                maxTokens: config.maxOutputTokens
            ) { event in
                await self.handleProviderStreamEvent(event)
            }

            await finishTypewriter()
            if !completion.toolCalls.isEmpty {
                discardStreamingAssistantIfNeeded()
            }

            if !completion.text.isEmpty && completion.toolCalls.isEmpty {
                let providerMessage = CPSLOpenAIMessage.assistant(completion.text)
                providerMessages.append(providerMessage)
                let assistantNode = try await store.appendNode(
                    conversationID: conversationID,
                    parentID: parentID,
                    role: .assistant,
                    title: nil,
                    body: completion.text,
                    model: completion.model,
                    providerMessage: providerMessage
                )
                parentID = assistantNode.id
                onParentIDChange(parentID)
                if let message = assistantNode.chatMessage {
                    reconcileStreamingAssistant(with: message)
                }
                streamingAssistantMessageID = nil
            }

            guard !completion.toolCalls.isEmpty else {
                if completion.text.isEmpty {
                    try await appendProviderLoopError(
                        body: "Provider returned an empty response.",
                        store: store,
                        conversationID: conversationID,
                        parentID: &parentID,
                        model: config.model,
                        onParentIDChange: onParentIDChange
                    )
                }
                return
            }

            var statusSummary = completion.toolCalls.first.map {
                CPSLAgentToolFormatting.statusSummary(for: $0, assistantText: completion.text)
            } ?? CPSLAgentToolFormatting.defaultStatusSummary
            let assistantToolMessage = CPSLOpenAIMessage.assistant(
                content: completion.text.isEmpty ? nil : completion.text,
                toolCalls: completion.toolCalls
            )

            if let toolStatusNodeID {
                toolStatus.state = .running
                toolStatus.summary = statusSummary
                try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: store)
            } else {
                toolStatus = CPSLToolStatusPayload.running(summary: statusSummary)
                let statusNode = try await store.appendNode(
                    conversationID: conversationID,
                    parentID: parentID,
                    role: .toolStatus,
                    title: nil,
                    body: toolStatus.encodedBody(),
                    model: completion.model,
                    providerMessage: nil
                )
                toolStatusNodeID = statusNode.id
                parentID = statusNode.id
                onParentIDChange(parentID)
                if let message = statusNode.chatMessage {
                    messages.append(message)
                }
            }

            var executedToolCalls: [(toolCall: CPSLOpenAIToolCall, result: CPSLToolExecutionResult)] = []

            for toolCall in completion.toolCalls {
                statusSummary = CPSLAgentToolFormatting.statusSummary(
                    for: toolCall,
                    assistantText: completion.text
                )
                toolStatus.state = .running
                toolStatus.summary = statusSummary
                if let toolStatusNodeID {
                    try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: store)
                }

                let toolResult = await executeToolCall(
                    toolCall,
                    client: client,
                    config: config,
                    agentDepth: 0,
                    requestDirectory: sandboxDirectory
                )
                executedToolCalls.append((toolCall, toolResult))
                lastToolStatusState = toolResult.isError ? .failed : .succeeded
#if DEBUG
                toolStatus.invocations.append(toolResult.debugInvocation)
                toolStatus.summary = statusSummary
                if let toolStatusNodeID {
                    try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: store)
                }
#endif
            }

            try await appendToolReplayBlock(
                assistantToolMessage: assistantToolMessage,
                statusSummary: statusSummary,
                executedToolCalls: executedToolCalls,
                store: store,
                conversationID: conversationID,
                parentID: &parentID,
                model: completion.model,
                providerMessages: &providerMessages,
                onParentIDChange: onParentIDChange
            )
            toolStatus.summary = statusSummary
            toolStatus.state = lastToolStatusState
            if let toolStatusNodeID {
                try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: store)
            }
        }

        try await synthesizeAfterToolLimit(
            client: client,
            store: store,
            conversationID: conversationID,
            parentID: &parentID,
            config: config,
            systemPrompt: systemPrompt,
            providerMessages: &providerMessages,
            onParentIDChange: onParentIDChange
        )
    }

    private func appendToolReplayBlock(
        assistantToolMessage: CPSLOpenAIMessage,
        statusSummary: String,
        executedToolCalls: [(toolCall: CPSLOpenAIToolCall, result: CPSLToolExecutionResult)],
        store: CPSLConversationStore,
        conversationID: String,
        parentID: inout String,
        model: String,
        providerMessages: inout [CPSLOpenAIMessage],
        onParentIDChange: (String) -> Void
    ) async throws {
        var drafts = [
            CPSLNodeAppendDraft(
                role: .hidden,
                title: nil,
                body: statusSummary,
                model: model,
                providerMessage: assistantToolMessage
            )
        ]
        drafts += executedToolCalls.map { executed in
            CPSLNodeAppendDraft(
                role: .hidden,
                title: executed.toolCall.function.name,
                body: executed.result.displayBody,
                model: model,
                providerMessage: CPSLOpenAIMessage.tool(
                    id: executed.toolCall.id,
                    content: executed.result.providerContent
                )
            )
        }

        let nodes = try await store.appendNodes(
            conversationID: conversationID,
            parentID: parentID,
            drafts: drafts
        )
        if let lastNode = nodes.last {
            parentID = lastNode.id
            onParentIDChange(parentID)
        }

        providerMessages.append(assistantToolMessage)
        for executed in executedToolCalls {
            providerMessages.append(
                CPSLOpenAIMessage.tool(
                    id: executed.toolCall.id,
                    content: executed.result.providerContent
                )
            )
        }
    }

    private func synthesizeAfterToolLimit(
        client: CPSLOpenAIClient,
        store: CPSLConversationStore,
        conversationID: String,
        parentID: inout String,
        config: CPSLAgentConfig,
        systemPrompt: String,
        providerMessages: inout [CPSLOpenAIMessage],
        onParentIDChange: (String) -> Void
    ) async throws {
        let synthesisPrompt = """
        Tool iteration limit reached. Produce a concise final response from the work completed so far. Do not request tools.
        """
        let synthesisMessage = CPSLOpenAIMessage.user(synthesisPrompt)
        providerMessages.append(synthesisMessage)
        let hiddenNode = try await store.appendNode(
            conversationID: conversationID,
            parentID: parentID,
            role: .hidden,
            title: "Agent",
            body: synthesisPrompt,
            model: config.model,
            providerMessage: synthesisMessage
        )
        parentID = hiddenNode.id
        onParentIDChange(parentID)

        let sandboxDirectory = await service.currentDirectory()
        let requestMessages = preparedRequestMessages(
            systemPrompt: systemPrompt,
            providerMessages: providerMessages,
            config: config,
            sandboxDirectory: sandboxDirectory,
            iteration: config.maxToolRounds,
            maxIterations: config.maxToolRounds
        )
        isSuppressingAssistantStream = false
        let completion = try await client.streamChat(
            messages: requestMessages,
            tools: [],
            maxTokens: config.maxOutputTokens
        ) { event in
            await self.handleProviderStreamEvent(event)
        }
        await finishTypewriter()

        guard !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try await appendProviderLoopError(
                body: "Reached maximum tool rounds (\(config.maxToolRounds)) and provider returned no final response.",
                store: store,
                conversationID: conversationID,
                parentID: &parentID,
                model: config.model,
                onParentIDChange: onParentIDChange
            )
            return
        }

        let providerMessage = CPSLOpenAIMessage.assistant(completion.text)
        providerMessages.append(providerMessage)
        let assistantNode = try await store.appendNode(
            conversationID: conversationID,
            parentID: parentID,
            role: .assistant,
            title: nil,
            body: completion.text,
            model: completion.model,
            providerMessage: providerMessage
        )
        parentID = assistantNode.id
        onParentIDChange(parentID)
        if let message = assistantNode.chatMessage {
            reconcileStreamingAssistant(with: message)
        }
        streamingAssistantMessageID = nil
    }

    private func updateToolStatus(
        _ payload: CPSLToolStatusPayload,
        nodeID: String,
        store: CPSLConversationStore
    ) async throws {
        let body = payload.encodedBody()
        try await store.updateNodeBody(id: nodeID, body: body)
        guard let messageID = UUID(uuidString: nodeID),
              let index = messages.firstIndex(where: { $0.id == messageID })
        else {
            return
        }
        messages[index].body = body
    }

    private func preparedRequestMessages(
        systemPrompt: String,
        providerMessages: [CPSLOpenAIMessage],
        config: CPSLAgentConfig,
        sandboxDirectory: String,
        iteration: Int,
        maxIterations: Int
    ) -> [CPSLOpenAIMessage] {
        let compactedMessages = compactedProviderMessagesIfNeeded(
            providerMessages,
            systemPrompt: systemPrompt,
            config: config
        )
        let estimatedTokens = estimatedTokenCount(
            systemPrompt: systemPrompt,
            messages: compactedMessages
        )
        let prompt = systemPromptWithBudgetReminder(
            systemPrompt: systemPrompt,
            estimatedTokens: estimatedTokens,
            contextWindowTokens: config.contextWindowTokens,
            sandboxDirectory: sandboxDirectory,
            iteration: iteration,
            maxIterations: maxIterations
        )
        return [CPSLOpenAIMessage.system(prompt)] + compactedMessages
    }

    private func compactedProviderMessagesIfNeeded(
        _ messages: [CPSLOpenAIMessage],
        systemPrompt: String,
        config: CPSLAgentConfig
    ) -> [CPSLOpenAIMessage] {
        guard let contextWindowTokens = config.contextWindowTokens,
              contextWindowTokens > 0
        else {
            return messages
        }

        let estimatedTokens = estimatedTokenCount(systemPrompt: systemPrompt, messages: messages)
        let threshold = Int(Double(contextWindowTokens) * toolResultClearThreshold)
        guard estimatedTokens >= threshold else {
            return messages
        }

        var compacted = messages
        let toolIndices = compacted.indices.filter { compacted[$0].role == "tool" }
        let keepIndices = Set(toolIndices.suffix(recentToolResultsToKeep))
        for index in toolIndices where !keepIndices.contains(index) {
            compacted[index].content = clearedToolResultContent(from: compacted[index].content)
        }
        return compacted
    }

    private func clearedToolResultContent(from content: String?) -> String {
        let summary = toolResultSummary(from: content)
        var payload: [String: Any] = [
            "ok": summary.ok,
            "stdout": summary.ok ? "[output cleared to reduce context]" : "",
            "stderr": ""
        ]
        if !summary.ok {
            payload["error"] = summary.failureText.isEmpty
                ? "[error output cleared to reduce context]"
                : "[error output cleared to reduce context]\n\(summary.failureText)"
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return summary.ok
                ? #"{"ok":true,"stdout":"[output cleared to reduce context]","stderr":""}"#
                : #"{"ok":false,"stdout":"","stderr":"","error":"[error output cleared to reduce context]"}"#
        }
        return json
    }

    private func toolResultSummary(from content: String?) -> (ok: Bool, failureText: String) {
        guard let content,
              let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (false, "")
        }
        let ok = object["ok"] as? Bool ?? false
        guard !ok else {
            return (true, "")
        }

        let detailKeys = [
            "error",
            "error_message",
            "ffi_error",
            "stderr",
            "output",
            "exit_code",
            "error_code"
        ]
        let details = detailKeys.compactMap { key -> String? in
            guard let value = object[key] else {
                return nil
            }
            let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            return "\(key): \(text)"
        }
        let failureText = CPSLAgentToolFormatting.truncatedText(details.joined(separator: "\n"))
        return (false, failureText)
    }

    private func systemPromptWithBudgetReminder(
        systemPrompt: String,
        estimatedTokens: Int,
        contextWindowTokens: Int?,
        sandboxDirectory: String,
        iteration: Int,
        maxIterations: Int
    ) -> String {
        let remainingIterations = max(0, maxIterations - iteration)
        var lines = ["Session: approximately \(estimatedTokens) replay tokens in the current request."]
        lines.append(
            "Current CPSL directory: \(CPSLAgentToolFormatting.promptPathLiteral(sandboxDirectory))."
        )
        if let contextWindowTokens, contextWindowTokens > 0 {
            let percent = Int((Double(estimatedTokens) * 100 / Double(contextWindowTokens)).rounded())
            lines.append("Context: approximately \(percent)% full (\(estimatedTokens)/\(contextWindowTokens) tokens).")
        }
        let remainingFraction = Double(remainingIterations) / Double(maxIterations)
        if remainingFraction < 0.25 {
            lines.append("Tool budget: \(remainingIterations) of \(maxIterations) rounds remain; wrap up efficiently.")
        } else if remainingFraction < 0.50 {
            lines.append("Tool budget: past halfway with \(remainingIterations) of \(maxIterations) rounds remaining.")
        }
        return systemPrompt + "\n\n<system-reminder>\n" + lines.joined(separator: "\n") + "\n</system-reminder>"
    }

    private func estimatedTokenCount(systemPrompt: String, messages: [CPSLOpenAIMessage]) -> Int {
        var bytes = systemPrompt.utf8.count
        for message in messages {
            bytes += message.role.utf8.count
            bytes += message.content?.utf8.count ?? 0
            bytes += message.toolCallID?.utf8.count ?? 0
            for toolCall in message.toolCalls ?? [] {
                bytes += toolCall.id.utf8.count
                bytes += toolCall.function.name.utf8.count
                bytes += toolCall.function.arguments.utf8.count
            }
        }
        return max(1, bytes / estimatedBytesPerToken)
    }

    private func appendProviderLoopError(
        body: String,
        store: CPSLConversationStore,
        conversationID: String,
        parentID: inout String,
        model: String,
        onParentIDChange: (String) -> Void
    ) async throws {
        let errorNode = try await store.appendNode(
            conversationID: conversationID,
            parentID: parentID,
            role: .error,
            title: "Agent",
            body: body,
            model: model,
            providerMessage: nil
        )
        parentID = errorNode.id
        onParentIDChange(parentID)
        if let message = errorNode.chatMessage {
            messages.append(message)
        }
    }

    private func persistStreamingAssistantIfNeeded(
        store: CPSLConversationStore,
        conversationID: String?,
        parentID: String?,
        model: String?
    ) async -> String? {
        await finishTypewriter()
        guard let conversationID,
              let parentID,
              let id = streamingAssistantMessageID,
              let index = messages.firstIndex(where: { $0.id == id })
        else {
            return parentID
        }

        let body = messages[index].body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return parentID
        }

        do {
            let node = try await store.appendNode(
                conversationID: conversationID,
                parentID: parentID,
                role: .assistant,
                title: nil,
                body: messages[index].body,
                model: model,
                providerMessage: nil
            )
            currentNodeID = node.id
            streamingAssistantMessageID = nil
            if let message = node.chatMessage {
                messages[index] = message
            }
            return node.id
        } catch {
            return parentID
        }
    }

    private func appendAgentError(
        _ body: String,
        store: CPSLConversationStore,
        conversationID: String?,
        parentID: String?,
        model: String?
    ) async {
        guard let conversationID, let parentID else {
            appendErrorMessage(title: "Agent", body: body)
            return
        }

        do {
            let node = try await store.appendNode(
                conversationID: conversationID,
                parentID: parentID,
                role: .error,
                title: "Agent",
                body: body,
                model: model,
                providerMessage: nil
            )
            currentNodeID = node.id
            if let message = node.chatMessage {
                messages.append(message)
            }
        } catch {
            appendErrorMessage(title: "Agent", body: body)
        }
    }

    private func queueAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }

        if streamingAssistantMessageID == nil {
            let message = CPSLChatMessage(role: .assistant, title: nil, body: "")
            streamingAssistantMessageID = message.id
            messages.append(message)
        }

        typewriterBuffer.append(delta)
        guard typewriterTask == nil else {
            return
        }

        typewriterTask = Task { @MainActor in
            await drainTypewriterBuffer()
        }
    }

    private func handleProviderStreamEvent(_ event: CPSLOpenAIStreamEvent) {
        switch event {
        case .textDelta(let delta):
            guard !isSuppressingAssistantStream else {
                return
            }
            queueAssistantDelta(delta)
        case .toolCallDelta:
            isSuppressingAssistantStream = true
            discardStreamingAssistantIfNeeded()
        }
    }

    private func drainTypewriterBuffer() async {
        defer {
            typewriterTask = nil
        }

        while !Task.isCancelled {
            if typewriterBuffer.isEmpty {
                return
            }

            let chunkSize = min(typewriterBuffer.count, typewriterBuffer.count > 240 ? 8 : 3)
            let chunk = String(typewriterBuffer.prefix(chunkSize))
            typewriterBuffer.removeFirst(chunk.count)
            appendToStreamingAssistant(chunk)
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    private func finishTypewriter() async {
        while typewriterTask != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func appendToStreamingAssistant(_ text: String) {
        guard let id = streamingAssistantMessageID,
              let index = messages.firstIndex(where: { $0.id == id })
        else {
            return
        }
        messages[index].body.append(text)
    }

    private func reconcileStreamingAssistant(with persistedMessage: CPSLChatMessage) {
        guard let id = streamingAssistantMessageID,
              let index = messages.firstIndex(where: { $0.id == id })
        else {
            if !persistedMessage.body.isEmpty {
                messages.append(persistedMessage)
            }
            return
        }
        messages[index] = persistedMessage
    }

    private func discardStreamingAssistantIfNeeded() {
        guard let id = streamingAssistantMessageID else {
            return
        }
        messages.removeAll { $0.id == id }
        streamingAssistantMessageID = nil
        typewriterBuffer = ""
        typewriterTask?.cancel()
        typewriterTask = nil
    }

    private func executeToolCall(
        _ toolCall: CPSLOpenAIToolCall,
        client: CPSLOpenAIClient,
        config: CPSLAgentConfig,
        agentDepth: Int,
        requestDirectory: String? = nil
    ) async -> CPSLToolExecutionResult {
        if let requestDirectory,
           let restoreError = await restoreCurrentDirectory(requestDirectory, for: toolCall) {
            return restoreError
        }

        switch toolCall.function.name {
        case CPSLAgentToolFormatting.localSandboxExecName:
            return await executeSandboxToolCall(toolCall)
        case CPSLAgentToolFormatting.agentName:
            return await executeAgentToolCall(
                toolCall,
                client: client,
                config: config,
                agentDepth: agentDepth
            )
        default:
            return CPSLToolExecutionResult(
                providerContent: #"{"ok":false,"error":"Unsupported tool."}"#,
                displayBody: "Unsupported tool: \(toolCall.function.name)",
                isError: true,
                debugInvocation: debugInvocation(
                    for: toolCall,
                    displayBody: "Unsupported tool: \(toolCall.function.name)",
                    isError: true
                )
            )
        }
    }

    private func restoreCurrentDirectory(
        _ directory: String,
        for toolCall: CPSLOpenAIToolCall
    ) async -> CPSLToolExecutionResult? {
        guard let message = await service.restoreCurrentDirectory(directory) else {
            return nil
        }
        let displayBody = message.isEmpty ? "Could not restore current directory." : message
        return CPSLToolExecutionResult(
            providerContent: providerToolContent(ok: false, output: nil, error: displayBody),
            displayBody: displayBody,
            isError: true,
            debugInvocation: debugInvocation(for: toolCall, displayBody: displayBody, isError: true)
        )
    }

    private func executeSandboxToolCall(_ toolCall: CPSLOpenAIToolCall) async -> CPSLToolExecutionResult {
        guard let source = CPSLAgentToolFormatting.source(from: toolCall.function.arguments) else {
            return CPSLToolExecutionResult(
                providerContent: #"{"ok":false,"error":"Missing source argument."}"#,
                displayBody: "Missing source argument.",
                isError: true,
                debugInvocation: debugInvocation(
                    for: toolCall,
                    displayBody: "Missing source argument.",
                    isError: true
                )
            )
        }

        let result = await service.evaluateLuau(source)
        let output = CPSLAgentToolOutput(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            ok: result.ok,
            errorCode: result.errorCode,
            errorMessage: result.errorMessage,
            ffiError: result.ffiError
        )
        let displayBody = CPSLAgentToolFormatting.displayBody(output)
        let isError = result.ok == false || result.errorMessage != nil || result.ffiError != nil
        return CPSLToolExecutionResult(
            providerContent: CPSLAgentToolFormatting.providerContent(output),
            displayBody: displayBody,
            isError: isError,
            debugInvocation: debugInvocation(for: toolCall, displayBody: displayBody, isError: isError)
        )
    }

    private func executeAgentToolCall(
        _ toolCall: CPSLOpenAIToolCall,
        client: CPSLOpenAIClient,
        config: CPSLAgentConfig,
        agentDepth: Int
    ) async -> CPSLToolExecutionResult {
        guard let input = CPSLAgentToolFormatting.agentInput(from: toolCall.function.arguments) else {
            let message = "Invalid agent arguments."
            return CPSLToolExecutionResult(
                providerContent: providerToolContent(ok: false, output: nil, error: message),
                displayBody: message,
                isError: true,
                debugInvocation: debugInvocation(for: toolCall, displayBody: message, isError: true)
            )
        }

        let childDepth = agentDepth + 1
        guard childDepth <= config.maxAgentDepth else {
            let message = "Sub-agent depth limit reached."
            return CPSLToolExecutionResult(
                providerContent: providerToolContent(ok: false, output: nil, error: message),
                displayBody: message,
                isError: true,
                debugInvocation: debugInvocation(for: toolCall, displayBody: message, isError: true)
            )
        }

        let result = await runSubAgent(
            input: input,
            client: client,
            config: config,
            agentDepth: childDepth
        )
        return CPSLToolExecutionResult(
            providerContent: providerToolContent(
                ok: !result.isError,
                output: result.output,
                error: result.isError ? result.output : nil
            ),
            displayBody: result.output,
            isError: result.isError,
            debugInvocation: debugInvocation(for: toolCall, displayBody: result.output, isError: result.isError)
        )
    }

    private func runSubAgent(
        input: CPSLAgentToolInput,
        client: CPSLOpenAIClient,
        config: CPSLAgentConfig,
        agentDepth: Int
    ) async -> (output: String, isError: Bool) {
        let maxTurns = input.mode == .explore ? config.exploreSubAgentTurns : config.generalSubAgentTurns
        let subAgentSystemPrompt = subAgentSystemPrompt(
            mode: input.mode,
            maxTurns: maxTurns,
            agentDepth: agentDepth,
            maxAgentDepth: config.maxAgentDepth
        )
        var providerMessages: [CPSLOpenAIMessage] = [.user(input.task)]
        var textParts: [String] = []
        var turnsUsed = 0

        do {
            for turn in 0..<maxTurns {
                turnsUsed = turn + 1
                let isFinalTurn = turn == maxTurns - 1
                let sandboxDirectory = await service.currentDirectory()
                let turnGuidance = isFinalTurn
                    ? "Budget: turn \(turn + 1)/\(maxTurns). FINAL, produce summary, no tools."
                    : "Budget: turn \(turn + 1)/\(maxTurns)."
                let requestMessages = [
                    CPSLOpenAIMessage.system(
                        subAgentSystemPrompt
                            + "\n\n<system-reminder>\n"
                            + "\(turnGuidance)\n"
                            + "Current CPSL directory: \(CPSLAgentToolFormatting.promptPathLiteral(sandboxDirectory)).\n"
                            + "</system-reminder>"
                    )
                ] + providerMessages
                let completion = try await client.streamChat(
                    messages: requestMessages,
                    tools: isFinalTurn ? [] : CPSLOpenAITool.availableTools(
                        allowsSubagents: agentDepth < config.maxAgentDepth,
                        currentDirectory: sandboxDirectory
                    ),
                    maxTokens: config.maxOutputTokens
                ) { _ in }

                if !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textParts.append(completion.text)
                }

                if isFinalTurn {
                    return (
                        subAgentOutput(
                            mode: input.mode,
                            turnsUsed: turnsUsed,
                            maxTurns: maxTurns,
                            textParts: textParts
                        ),
                        false
                    )
                }

                guard !completion.toolCalls.isEmpty else {
                    return (
                        subAgentOutput(
                            mode: input.mode,
                            turnsUsed: turnsUsed,
                            maxTurns: maxTurns,
                            textParts: textParts
                        ),
                        false
                    )
                }

                providerMessages.append(
                    CPSLOpenAIMessage.assistant(
                        content: completion.text.isEmpty ? nil : completion.text,
                        toolCalls: completion.toolCalls
                    )
                )
                for toolCall in completion.toolCalls {
                    let toolResult = await executeToolCall(
                        toolCall,
                        client: client,
                        config: config,
                        agentDepth: agentDepth,
                        requestDirectory: sandboxDirectory
                    )
                    providerMessages.append(
                        CPSLOpenAIMessage.tool(id: toolCall.id, content: toolResult.providerContent)
                    )
                }
            }

            return (
                subAgentOutput(
                    mode: input.mode,
                    turnsUsed: turnsUsed,
                    maxTurns: maxTurns,
                    textParts: textParts
                ),
                false
            )
        } catch {
            let output = subAgentOutput(
                mode: input.mode,
                turnsUsed: turnsUsed,
                maxTurns: maxTurns,
                textParts: textParts + ["Sub-agent failed: \(error.localizedDescription)"]
            )
            return (output, true)
        }
    }

    private func subAgentSystemPrompt(
        mode: CPSLSubAgentMode,
        maxTurns: Int,
        agentDepth: Int,
        maxAgentDepth: Int
    ) -> String {
        """
        You are a Herm sub-agent running inside the same iOS/macOS app.
        Complete the assigned task, then return a concise result. Do not ask questions.
        Mode: \(mode.rawValue). Turn budget: \(maxTurns). Agent depth: \(agentDepth)/\(maxAgentDepth).
        CPSL is your execution environment: a Unix-like local environment with Luau as the command interface instead of Bash. Luau is the only supported execution language.
        You may use local_sandbox_exec for CPSL work. You have no host shell, package manager, browser, or provider-hosted capabilities.
        """
    }

    private func subAgentOutput(
        mode: CPSLSubAgentMode,
        turnsUsed: Int,
        maxTurns: Int,
        textParts: [String]
    ) -> String {
        let body = textParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let output = body.isEmpty ? "Sub-agent completed without text output." : body
        return "[agent mode:\(mode.rawValue) turns:\(turnsUsed)/\(maxTurns)]\n\n\(output)"
    }

    private func debugInvocation(
        for toolCall: CPSLOpenAIToolCall,
        displayBody: String,
        isError: Bool
    ) -> CPSLToolStatusInvocation {
        CPSLToolStatusInvocation(
            id: toolCall.id,
            name: toolCall.function.name,
            summary: CPSLAgentToolFormatting.summary(for: toolCall),
            input: CPSLAgentToolFormatting.inputPreview(for: toolCall),
            output: displayBody,
            isError: isError
        )
    }

    private func providerToolContent(ok: Bool, output: String?, error: String?) -> String {
        var payload: [String: Any] = ["ok": ok]
        if let output {
            payload["output"] = CPSLAgentToolFormatting.truncatedText(output)
        }
        if let error {
            payload["error"] = error
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":"Could not encode tool result."}"#
        }
        return json
    }

    private func runCommand(_ command: String) {
        let message = CPSLChatMessage(role: .command, title: nil, body: commandBlockBody(command: command))
        messages.append(message)
        isRunning = true

        Task {
            let result = await service.evaluate(command)
            applyCommandResult(result, command: command, messageID: message.id)
            isRunning = false
        }
    }

    private func applyCommandResult(_ result: CPSLEvalServiceResult, command: String, messageID: UUID) {
        let body = commandBlockBody(command: command, result: result)
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            messages.append(CPSLChatMessage(role: .command, title: nil, body: body))
            return
        }
        messages[index].body = body
    }

    private func commandBlockBody(command: String, result: CPSLEvalServiceResult? = nil) -> String {
        var sections = ["!\(command)"]
        guard let result else {
            return sections.joined(separator: "\n\n")
        }

        var outputSections: [String] = []
        outputSections.append(contentsOf: result.warnings.map { "warning: \($0)" })
        appendTrimmed(result.stdout, to: &outputSections)
        appendTrimmed(result.stderr, to: &outputSections)

        if let ffiError = result.ffiError {
            outputSections.append(ffiError)
        }
        if let errorMessage = result.errorMessage {
            let prefix = result.errorCode.map { "error[\($0)]" } ?? "error"
            outputSections.append("\(prefix): \(errorMessage)")
        }
        if result.errorCode == "invalid_response", let rawJSON = result.rawJSON {
            outputSections.append(rawJSON)
        }
        if outputSections.isEmpty {
            let exit = result.exitCode.map { "exit \($0)" } ?? "done"
            outputSections.append(exit)
        }

        sections.append(outputSections.joined(separator: "\n\n"))
        return sections.joined(separator: "\n\n")
    }

    private func appendTrimmed(_ text: String, to sections: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else {
            return
        }
        sections.append(trimmed)
    }

    private func loadDirectory(_ path: String, childOf parent: String?) async {
        guard !loadingFilePaths.contains(path) else {
            return
        }
        loadingFilePaths.insert(path)
        defer {
            loadingFilePaths.remove(path)
        }

        let listing = await service.listDirectory(path)
        if let error = listing.error {
            applyDirectoryLoadFailure(error, path: path, childOf: parent)
            return
        }

        if let parent {
            childEntriesByPath[parent] = listing.entries
        } else {
            browserEntries = listing.entries
        }
    }

    private func applyDirectoryLoadFailure(_ message: String, path: String, childOf parent: String?) {
        if let parent {
            childEntriesByPath[parent] = []
        } else {
            browserEntries = []
        }
        fileBrowserError = "\(path): \(message)"
    }

    private func appendErrorMessage(title: String?, body: String) {
        messages.append(CPSLChatMessage(role: .error, title: title, body: body))
    }

    private func normalizedPath(_ path: String) -> String {
        var normalized = path.isEmpty ? "/" : path
        if !normalized.hasPrefix("/") {
            normalized = "/\(normalized)"
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func parentPath(of path: String) -> String {
        let normalized = normalizedPath(path)
        guard normalized != "/" else {
            return "/"
        }

        let components = normalized.split(separator: "/")
        guard components.count > 1 else {
            return "/"
        }
        return "/" + components.dropLast().joined(separator: "/")
    }
}

#if DEBUG
private nonisolated struct CPSLDebugConversationSnapshot: Encodable {
    let messages: [CPSLChatMessage]
}
#endif
