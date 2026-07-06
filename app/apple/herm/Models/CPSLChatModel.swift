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
    @Published var messages: [CPSLChatMessage] = []
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
    @Published private(set) var filePreview: CPSLFilePreview?

    let service = CPSLDebugService()
    let dictation = CPSLDictationService()
    private var store: CPSLConversationStore?
    private var storeLoadTask: Task<CPSLConversationStore, Error>?
    var currentNodeID: String?
    private var currentSystemPrompt: String?
    var streamingAssistantMessageID: UUID?
    var isSuppressingAssistantStream = false
    var typewriterBuffer = ""
    var typewriterTask: Task<Void, Never>?
    let estimatedBytesPerToken = 4
    let toolResultClearThreshold = 0.80
    let recentToolResultsToKeep = 4

    private let systemPrompt = """
    You are Herm, an AI agent running inside an iOS/macOS app.
    You support OpenAI-compatible chat completions only. Server-side provider tools, including web search, are not available.
    CPSL is your execution environment: a Unix-like local environment with a filesystem, current directory, and command-style capabilities exposed through Luau APIs. Luau is the interface instead of Bash, and it is the only supported execution language.
    Use /home/herm as the default home for durable user-created files and /tmp for temporary files. CPSL still exposes a Unix-like root with system directories such as /etc, /usr, and /var when needed.
    Your client-side tools are local_sandbox_exec and agent. Use tools only when they materially help with the user's request.
    Every local_sandbox_exec call must include intent: one short high-level user-facing action phrase, such as "Preparing document", "Checking export", or "Saving result". Do not mention code, sandbox details, paths, module names, tool names, API names, file extensions, HTTP, or implementation details in intent.
    When you call tools, assistant content may contain the same kind of high-level status phrase, but never code or implementation details.
    local_sandbox_exec runs Luau source in CPSL. The current CPSL directory is supplied in each request. Never guess CPSL API signatures: call help() and each module's help function, such as fs.help(), before using APIs.
    Treat CPSL as its own Luau ecosystem. APIs from other Lua/Luau environments may be popular elsewhere but are not expected to exist here. Use only the built-in globals shown by help(); for files use fs, for documents use doc. Do not use require or package-style imports for filesystem or document work.
    Treat help output as human-readable documentation. Call help() or module.help() as its own sandbox invocation and read the printed text; do not assign help output to a variable or parse it with string.find, string.sub, #, or tostring().
    If an API reports that a feature is not supported, unavailable, policy-denied, or missing required system assets, make at most one targeted confirmation call, then stop using that path and explain the limitation plainly. Do not propose installers, package managers, browser printing, online converters, external renderers, shell commands, or OS-specific tools that are not available through CPSL.
    When a requested artifact cannot be produced, do not claim success. Mention any partial artifact only as a fallback, and make clear it is not the requested output.
    agent spawns a focused sub-agent with its own turn budget. Use explore mode for research and reading. Use general mode for execution-heavy or implementation-style work. Keep sub-agent tasks narrow and self-contained.
    Luau essentials: declare variables with local, use 1-based indexing, concatenate strings with .., use ~= for not-equal, and use pcall(fn) for recoverable errors.
    Do not try to launch external lua/luau interpreters, Bash, Python, shell commands, package managers, background services, host Lua APIs, or paths outside CPSL.
    Do not ask the provider to browse the web, do not imply host shell access, and do not share local files unless the user explicitly requests file content.
    """

    private func systemPrompt(with skills: [CPSLAgentSkill]) -> String {
        guard !skills.isEmpty else {
            return systemPrompt
        }
        let skillLines = skills.map {
            "- **\($0.name)**: \($0.description) Read: `\($0.path)`"
        }.joined(separator: "\n")
        return systemPrompt + """


        ## Skills

        The following skills are available. Their full instructions are not loaded into this prompt. When a skill is relevant to the user's task, read its skill file first, then follow that file's instructions and read any referenced support files from the same folder as needed.

        \(skillLines)
        """
    }

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
        filePreview = nil
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

        if selectedConversationID == id {
            isDrawerOpen = false
            isFileBrowserOpen = false
            filePreview = nil
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

        dictation.cancel()
        promptText = ""
        isFileBrowserOpen = false
        filePreview = nil
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
            filePreview = nil
            loadBrowserPath(browserPath)
        } else {
            filePreview = nil
        }
    }

    func closeFileBrowser() {
        isFileBrowserOpen = false
        filePreview = nil
    }

    func loadBrowserPath(_ path: String) {
        let normalized = scopedBrowserPath(path)
        let isChangingPath = normalized != browserPath
        browserPath = normalized
        fileBrowserError = nil
        expandedFilePaths.removeAll()
        childEntriesByPath.removeAll()

        guard normalized != CPSLVirtualPath.root else {
            browserEntries = []
            return
        }

        if isChangingPath {
            browserEntries = []
        }

        Task {
            await loadDirectory(normalized, childOf: nil)
        }
    }

    var isAtFileBrowserRoot: Bool {
        browserPath == CPSLVirtualPath.root
    }

    var canNavigateToParentDirectory: Bool {
        browserParentPath() != nil
    }

    func navigateToParentDirectory() {
        guard let parentPath = browserParentPath() else {
            return
        }
        loadBrowserPath(parentPath)
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
            Task {
                await loadPreview(for: entry)
            }
        }
    }

    func closeFilePreview() {
        filePreview = nil
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
            filePreview = nil
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
            let promptForConversation = systemPrompt(with: await service.availableSkills())

            if let selectedConversationID, let currentNodeID {
                conversationID = selectedConversationID
                let node = try await store.appendNode(
                    conversationID: selectedConversationID,
                    parentID: currentNodeID,
                    draft: CPSLNodeAppendDraft(
                        role: .user,
                        title: nil,
                        body: userText,
                        model: nil,
                        providerMessage: .user(userText)
                    )
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
                    systemPrompt: promptForConversation
                )
                conversationID = created.summary.id
                parentID = created.userNode.id
                selectedConversationID = conversationID
                currentNodeID = parentID
                currentSystemPrompt = promptForConversation
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
            let providerMessages = try await store.providerMessages(conversationID: conversationID)
            let replaySystemPrompt = currentSystemPrompt ?? promptForConversation
            var providerLoopContext = CPSLProviderLoopContext(
                client: client,
                store: store,
                conversationID: conversationID,
                parentID: parentID,
                config: config,
                systemPrompt: replaySystemPrompt,
                providerMessages: providerMessages
            ) { nodeID in
                activeParentID = nodeID
            }
            try await runProviderLoop(&providerLoopContext)
            parentID = providerLoopContext.parentID
            currentNodeID = parentID
            conversations = try await store.loadSummaries()
        } catch {
            let pendingContext = CPSLPendingConversationContext(
                store: store,
                conversationID: activeConversationID,
                parentID: activeParentID,
                model: activeModel
            )
            activeParentID = await persistStreamingAssistantIfNeeded(pendingContext)
            await appendAgentError(
                error.localizedDescription,
                context: CPSLPendingConversationContext(
                    store: store,
                    conversationID: activeConversationID,
                    parentID: activeParentID,
                    model: activeModel
                )
            )
            if let summaries = try? await store.loadSummaries() {
                conversations = summaries
            }
        }

        await finishTypewriter()
        streamingAssistantMessageID = nil
        isRunning = false
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
        guard isBrowserPathAllowed(path) else {
            applyDirectoryLoadFailure("This location is not available from Files.", path: path, childOf: parent)
            return
        }
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
            guard expandedFilePaths.contains(parent) else {
                return
            }
            childEntriesByPath[parent] = listing.entries
        } else {
            guard browserPath == path else {
                return
            }
            browserEntries = listing.entries
        }
    }

    private func applyDirectoryLoadFailure(_ message: String, path: String, childOf parent: String?) {
        if let parent {
            guard expandedFilePaths.contains(parent) else {
                return
            }
            childEntriesByPath[parent] = []
        } else {
            guard browserPath == path else {
                return
            }
            browserEntries = []
        }
        fileBrowserError = "\(path): \(message)"
    }

    private func loadPreview(for entry: CPSLFileEntry) async {
        let result = await service.previewFile(entry)
        if let preview = result.preview {
            filePreview = preview
            return
        }

        let message = result.error ?? "Preview is not available for this file."
        if message.contains("TXT and PDF") {
            showComingSoon(message)
        } else {
            fileBrowserError = "\(entry.path): \(message)"
        }
    }

    func appendErrorMessage(title: String?, body: String) {
        messages.append(CPSLChatMessage(role: .error, title: title, body: body))
    }

    private func normalizedPath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            normalized = CPSLVirtualPath.root
        }
        if !normalized.hasPrefix("/") {
            normalized = "/\(normalized)"
        }
        var components: [String] = []
        for component in normalized.split(separator: "/") {
            let pathComponent = String(component)
            switch pathComponent {
            case ".", "":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(pathComponent)
            }
        }
        return components.isEmpty ? CPSLVirtualPath.root : "/\(components.joined(separator: "/"))"
    }

    private func scopedBrowserPath(_ path: String) -> String {
        let normalized = normalizedPath(path)
        return isBrowserPathAllowed(normalized) ? normalized : CPSLVirtualPath.root
    }

    private func isBrowserPathAllowed(_ path: String) -> Bool {
        let normalized = normalizedPath(path)
        return normalized == CPSLVirtualPath.root ||
            normalized == CPSLVirtualPath.home ||
            normalized.hasPrefix("\(CPSLVirtualPath.home)/") ||
            normalized == CPSLVirtualPath.temporary ||
            normalized.hasPrefix("\(CPSLVirtualPath.temporary)/")
    }

    private func browserParentPath() -> String? {
        let normalized = normalizedPath(browserPath)
        guard normalized != CPSLVirtualPath.root else {
            return nil
        }
        guard isBrowserPathAllowed(normalized) else {
            return CPSLVirtualPath.root
        }
        if normalized == CPSLVirtualPath.home || normalized == CPSLVirtualPath.temporary {
            return CPSLVirtualPath.root
        }
        return parentPath(of: normalized)
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
