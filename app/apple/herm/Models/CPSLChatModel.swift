import Combine
import Foundation

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
    private var typewriterBuffer = ""
    private var typewriterTask: Task<Void, Never>?

    private let systemPrompt = """
    You are Herm, an AI agent running inside an iOS/macOS app.
    You support OpenAI-compatible chat completions only. Server-side provider tools, including web search, are not available.
    Your only client-side tool is local_sandbox_exec. Use it only when sandboxed Luau execution is useful.
    local_sandbox_exec runs native Luau source in the local sandbox at /workdir. Never guess sandbox tool signatures: call help() and each tool's help function, such as fs.help(), before using APIs.
    Luau essentials: declare variables with local, use 1-based indexing, concatenate strings with .., use ~= for not-equal, and use pcall(fn) for recoverable errors.
    Do not invoke lua, luau, Bash, Python, shell commands, package managers, background services, host Lua APIs, or paths outside the sandbox.
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
            messages = conversation.nodes.map(\.chatMessage)
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
                messages.append(node.chatMessage)
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
                messages.append(created.userNode.chatMessage)
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
                model: config.model,
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
        model: String,
        systemPrompt: String,
        providerMessages: inout [CPSLOpenAIMessage],
        onParentIDChange: (String) -> Void
    ) async throws {
        let maxToolRounds = 4
        for _ in 0..<maxToolRounds {
            let requestMessages = [CPSLOpenAIMessage.system(systemPrompt)] + providerMessages
            let completion = try await client.streamChat(messages: requestMessages) { event in
                switch event {
                case .textDelta(let delta):
                    await self.queueAssistantDelta(delta)
                case .toolCallDelta:
                    break
                }
            }

            await finishTypewriter()

            if !completion.text.isEmpty {
                let providerMessage = completion.toolCalls.isEmpty ? CPSLOpenAIMessage.assistant(completion.text) : nil
                if let providerMessage {
                    providerMessages.append(providerMessage)
                }
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
                reconcileStreamingAssistant(with: assistantNode.chatMessage)
                streamingAssistantMessageID = nil
            }

            guard !completion.toolCalls.isEmpty else {
                if completion.text.isEmpty {
                    try await appendProviderLoopError(
                        body: "Provider returned an empty response.",
                        store: store,
                        conversationID: conversationID,
                        parentID: &parentID,
                        model: model,
                        onParentIDChange: onParentIDChange
                    )
                }
                return
            }

            let assistantToolMessage = CPSLOpenAIMessage.assistant(
                content: completion.text.isEmpty ? nil : completion.text,
                toolCalls: completion.toolCalls
            )
            providerMessages.append(assistantToolMessage)

            let commandNode = try await store.appendNode(
                conversationID: conversationID,
                parentID: parentID,
                role: .command,
                title: "local_sandbox_exec",
                body: CPSLAgentToolFormatting.toolCallsBody(completion.toolCalls),
                model: completion.model,
                providerMessage: assistantToolMessage
            )
            parentID = commandNode.id
            onParentIDChange(parentID)
            messages.append(commandNode.chatMessage)

            for toolCall in completion.toolCalls {
                let toolResult = await executeToolCall(toolCall)
                let providerToolMessage = CPSLOpenAIMessage.tool(id: toolCall.id, content: toolResult.providerContent)
                providerMessages.append(providerToolMessage)
                let outputNode = try await store.appendNode(
                    conversationID: conversationID,
                    parentID: parentID,
                    role: toolResult.isError ? .error : .output,
                    title: "local_sandbox_exec",
                    body: toolResult.displayBody,
                    model: model,
                    providerMessage: providerToolMessage
                )
                parentID = outputNode.id
                onParentIDChange(parentID)
                messages.append(outputNode.chatMessage)
            }
        }

        try await appendProviderLoopError(
            body: "Stopped after \(maxToolRounds) tool rounds.",
            store: store,
            conversationID: conversationID,
            parentID: &parentID,
            model: model,
            onParentIDChange: onParentIDChange
        )
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
        messages.append(errorNode.chatMessage)
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
            messages[index] = node.chatMessage
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
            messages.append(node.chatMessage)
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

    private func executeToolCall(_ toolCall: CPSLOpenAIToolCall) async -> CPSLToolExecutionResult {
        guard toolCall.function.name == "local_sandbox_exec" else {
            return CPSLToolExecutionResult(
                providerContent: #"{"ok":false,"error":"Unsupported tool."}"#,
                displayBody: "Unsupported tool: \(toolCall.function.name)",
                isError: true
            )
        }

        guard let source = CPSLAgentToolFormatting.source(from: toolCall.function.arguments) else {
            return CPSLToolExecutionResult(
                providerContent: #"{"ok":false,"error":"Missing source argument."}"#,
                displayBody: "Missing source argument.",
                isError: true
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
        return CPSLToolExecutionResult(
            providerContent: CPSLAgentToolFormatting.providerContent(output),
            displayBody: CPSLAgentToolFormatting.displayBody(output),
            isError: result.ok == false || result.errorMessage != nil || result.ffiError != nil
        )
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
