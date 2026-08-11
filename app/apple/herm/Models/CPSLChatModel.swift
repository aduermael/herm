import Foundation
import Observation

private enum CPSLTransientActivity {
    case file
    case calendar
    case location
}

@MainActor
@Observable
final class CPSLChatModel {
    var promptText = ""
    private(set) var composerAttachments: [CPSLAttachment] = []
    private(set) var isImportingAttachment = false
    var comingSoonMessage: String?
    var messages: [CPSLChatMessage] = []
    private(set) var conversations: [CPSLConversationSummary] = []
    private(set) var selectedConversationID: String?
    private(set) var isRunning = false
    private(set) var isDrawerOpen = false
    private(set) var isFileBrowserOpen = false
    private(set) var browserPath = "/"
    private(set) var browserEntries: [CPSLFileEntry] = []
    private(set) var childEntriesByPath: [String: [CPSLFileEntry]] = [:]
    private(set) var expandedFilePaths: Set<String> = []
    private(set) var loadingFilePaths: Set<String> = []
    private(set) var fileBrowserError: String?
    private(set) var isManagingFiles = false
    private(set) var filePreview: CPSLFilePreview? {
        didSet {
            if filePreview == nil {
                isFileInfoOpen = false
                activeFileNavigationRequestID = nil
                activeFilePreviewRequestID = nil
                filePreviewLoadTask?.cancel()
                filePreviewLoadTask = nil
                retireFilePreviewLifetimeToken()
            } else if oldValue?.path != filePreview?.path {
                isFileInfoOpen = false
            }
        }
    }
    /// File metadata pushed one level deeper in the Files route stack (not a popover/drawer).
    private(set) var isFileInfoOpen = false
    private(set) var isWebBrowserOpen = false
    private(set) var isFileActivityActive = false
    private(set) var isCalendarOpen = false
    private(set) var isCalendarActivityActive = false
    private(set) var isLocationOpen = false
    private(set) var isLocationActivityActive = false
    private(set) var iCloudMounts: [CPSLICloudMount] = []
    /// True only while the user is actively connecting/removing a mount — not during launch prepare.
    private(set) var isUpdatingICloudMounts = false
    /// True until the first conversation store load attempt finishes (success or failure).
    private(set) var isLoadingConversations = true
    private(set) var iCloudImportProgress: CPSLICloudImportProgress?
    private(set) var allTags: [CPSLTag] = []
    var searchText: String = ""
    private(set) var activeTagIDs: Set<String> = []
    private(set) var showingArchived = false

    var isBusy: Bool {
        // Launch mount prepare does not lock chat; only active mutations do.
        isRunning || isUpdatingICloudMounts || isManagingFiles
    }

    var conversationListPresentation: CPSLConversationListPresentation {
        let isSearching = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || !activeTagIDs.isEmpty
        // Use filtered section emptiness so text search with zero hits shows "No matches".
        return .resolve(
            isLoading: isLoadingConversations,
            isSearching: isSearching,
            showingArchived: showingArchived,
            hasVisibleConversations: !sectionGroups.isEmpty
        )
    }

    let service: CPSLDebugService
    let webBrowser: CPSLWebBrowserService
    let calendar = CPSLCalendarService()
    let location = CPSLLocationService()
    let dictation = CPSLDictationService()
    private let fileActivityNotifier = CPSLFileActivityNotifier()
    private let calendarActivityNotifier = CPSLCalendarActivityNotifier()
    @ObservationIgnored private var store: CPSLConversationStore?
    @ObservationIgnored private var storeLoadTask: Task<CPSLConversationStore, Error>?
    @ObservationIgnored private var activeRunTask: Task<Void, Never>?
    @ObservationIgnored var currentNodeID: String?
    @ObservationIgnored private var currentSystemPrompt: String?
    var streamingAssistantMessageID: UUID?
    @ObservationIgnored var isSuppressingAssistantStream = false
    @ObservationIgnored var typewriterBuffer = ""
    @ObservationIgnored var typewriterTask: Task<Void, Never>?
    @ObservationIgnored private var iCloudImportTask: Task<Void, Never>?
    @ObservationIgnored private var activeICloudImportID: UUID?
    @ObservationIgnored private var activeFileNavigationRequestID: UUID?
    @ObservationIgnored private var activeFilePreviewRequestID: UUID?
    @ObservationIgnored private var filePreviewLoadTask: Task<Void, Never>?
    @ObservationIgnored private var filePreviewLifetimeToken: AnyObject?
    @ObservationIgnored private var retiredFilePreviewLifetimeTokens: [UUID: AnyObject] = [:]
    @ObservationIgnored private var attachmentThumbnailCache: [String: Data] = [:]
    @ObservationIgnored private var attachmentsWithoutThumbnails: Set<String> = []
    @ObservationIgnored private var iCloudMountChangeObserver: NSObjectProtocol?
    let estimatedBytesPerToken = 4
    let toolResultClearThreshold = 0.80
    let recentToolResultsToKeep = 4
    var activeToolStatusNodeID: String?
    @ObservationIgnored var activeToolStatusConversationID: String?
    @ObservationIgnored var activeToolStatusPayload: CPSLToolStatusPayload?
    @ObservationIgnored var activeToolStatusStore: CPSLConversationStore?
    @ObservationIgnored var activeToolStatusRevision = 0
    @ObservationIgnored private var fileActivityClearTask: Task<Void, Never>?
    @ObservationIgnored private var calendarActivityClearTask: Task<Void, Never>?
    @ObservationIgnored private var locationActivityClearTask: Task<Void, Never>?
    @ObservationIgnored private var draftConversationID = UUID().uuidString
    @ObservationIgnored private var attachmentImportCount = 0
    private let activityPulseDuration: TimeInterval = 1.6
    private static let filePreviewRetirementNanoseconds: UInt64 = 300_000_000

    var isToolOverlayOpen: Bool {
        isFileBrowserOpen
            || isWebBrowserOpen
            || isCalendarOpen
            || isLocationOpen
    }

    private let systemPrompt = """
    You are Herm, an AI agent running inside an iOS/macOS app.
    You support OpenAI-compatible chat completions only. Server-side provider tools, including web search, are not available.
    CPSL is your execution environment: a Unix-like local environment with a filesystem, current directory, and command-style capabilities exposed through Luau APIs. Luau is the interface instead of Bash, and it is the only supported execution language.
    Use /home/herm as the default home for durable user-created files and /tmp for temporary files. Files added by the user are listed in their message and remain available under /attachments/<conversation-id> so they can be referenced again later in that conversation. Read those files with fs or doc as appropriate. CPSL still exposes a Unix-like root with system directories such as /etc, /usr, and /var when needed.
    Your client-side tools are local_sandbox_exec and agent. Use tools only when they materially help with the user's request.
    Before claiming that you cannot perform a requested action, inspect the available CPSL modules and relevant skills for plausible ways to complete it. The absence of a dedicated service integration does not mean the action is unavailable when the service has a website the browser can use.
    For tasks involving a website or online service—including search, browsing, account actions, private messages, posts, forms, and file uploads or downloads—the webbrowser skill is required: load it into context with local_sandbox_exec and print(fs.read("/skills/webbrowser/SKILL.md")) before the first webbrowser call. Then use the global webbrowser module (never require). Capture open/create return values, read pages with webbrowser.page(browser) while staying in the background, and call webbrowser.show(browser) only for real user handoff (login, CAPTCHA, payment, or the user asked to see the window). Browsers default to mobile layout; use webbrowser.set_layout(browser, "desktop") on the same browser only when needed. The native browser uses persistent WebKit state, so the user may already be signed in. When the user explicitly requests a specific action, try to complete it through the site's normal browser interface on their behalf.
    Use authenticated websites only through their normal browser flow. Do not unhide, relabel, restyle, or inject page controls to manufacture an interaction target. Do not replace normal browser typing with stacked JavaScript input, paste, or synthetic keyboard-event strategies. After a consequential action is confirmed, do not repeat it or send a corrective follow-up unless the user explicitly asks; report every side effect accurately. Never extract, print, copy, or reuse authentication tokens, cookies, or other session secrets from browser storage or page JavaScript, and never use those secrets to call a site's private API.
    Every local_sandbox_exec call must include intent: one short high-level user-facing action phrase, such as "Preparing document", "Checking export", or "Saving result". Do not mention code, sandbox details, paths, module names, tool names, API names, file extensions, HTTP, or implementation details in intent.
    Every agent call must also include intent: a short user-facing description of its expected work. Describe the action itself; never mention a helper, agent, delegation, tool, code, paths, or implementation details.
    When you call tools, assistant content may contain the same kind of high-level status phrase, but never code or implementation details.
    local_sandbox_exec runs Luau source in CPSL. The current CPSL directory is supplied in each request. Never guess CPSL API signatures. Prefer CPSL module.help() or a skill file you already loaded into this conversation. Call help() only when availability or an exact signature is still unclear; do not reload documentation already present in the conversation.
    Treat CPSL as its own Luau ecosystem. APIs from other Lua/Luau environments may be popular elsewhere but are not expected to exist here. Use only the built-in globals shown by help(); for files use fs, for documents use doc. Sandbox modules are globals: do not use require to load them, and do not search the filesystem for a module that help() does not list. require() is only for relative/package module paths (./, ../, @) and never for skills or built-in modules such as location, calendar, or fs.
    Treat help output as human-readable documentation. When help is actually needed, call help() or module.help() as its own sandbox invocation and read the printed text; do not assign help output to a variable or parse it with string.find, string.sub, #, or tostring().
    Follow documented return shapes exactly. For example, fs.list(path) returns an array of entry name strings; it does not return records with name or size fields. Use fs.size(path .. "/" .. entry) only when sizes are needed. print() and tostring() serialize tables as JSON so nested fields are visible; do not assume a bare "table" string means data is missing.
    Calendar and location are available through CPSL only when compiled into the app sandbox and authorized by the user. Use calendar or location only when the user's request materially needs schedule, event, availability, or current-place context. They are globals (calendar, location). For first use of either, load the apple-context skill into this conversation first (see Skills section), then call location.status() / location.current() or calendar.status() as that skill documents. EventKit does not expose native calendar file attachments. When files should be associated with an event, use calendar.attach: it copies them to durable storage and makes them openable from Herm's Calendar view. Describe these as attached in Herm, not as native Calendar.app attachments. Access states are granted, denied, or undefined. If access is undefined, the relevant CPSL request/current function may prompt the user. If access is denied, stop using that capability and tell the user to enable access for Herm in iOS Settings or macOS System Settings.
    If an API reports that a feature is not supported, unavailable, policy-denied, or missing required system assets, make at most one targeted confirmation call, then stop using that path and explain the limitation plainly. Do not propose installers, package managers, browser printing, online converters, external renderers, shell commands, or OS-specific tools that are not available through CPSL.
    When a requested artifact cannot be produced, do not claim success. Mention any partial artifact only as a fallback, and make clear it is not the requested output.
    agent spawns a focused sub-agent with its own turn budget. Use explore mode for research and reading. Use general mode for execution-heavy or implementation-style work. Keep sub-agent tasks narrow and self-contained.
    Luau essentials: declare variables with local, use 1-based indexing, concatenate strings with .., use ~= for not-equal, and use pcall(fn) for recoverable errors. The os, io, dofile, loadfile, and package libraries are unavailable; use sandbox modules such as datetime, fs, doc, and http instead.
    Keep final answers concise: lead with the result, include created paths or limitations, and avoid tables or long step-by-step reports unless the user asks for detail.
    Do not try to launch external lua/luau interpreters, Bash, Python, shell commands, package managers, background services, host Lua APIs, or paths outside CPSL.
    Do not ask the provider to browse the web, do not imply host shell access, and do not share local files unless the user explicitly requests file content.
    """

    private func systemPrompt(with skills: [CPSLAgentSkill]) -> String {
        guard !skills.isEmpty else {
            return systemPrompt
        }
        let skillLines = skills.map {
            """
            - **\($0.name)**: \($0.description)
              Path: `\($0.path)`
              Load into context (mandatory before first use of this skill's domain): call the **local_sandbox_exec** tool with Luau source:
              `print(fs.read("\($0.path)"))`
              Intent example: "Reading skill guide". Do not use require().
            """
        }.joined(separator: "\n")
        return systemPrompt + """


        ## Skills (Herm concept — not a built-in LLM feature)

        A **skill** in Herm is an on-disk markdown guide (a `SKILL.md` file) with step-by-step instructions for a domain (browser, calendar/location, PDFs, vision, …). Skills are **not** automatically in your context. The list below is only a catalog: names, short descriptions, and file paths. The full skill text is **not** included in this system prompt and is **not** available until you load it.

        **How a skill enters your context**
        1. Decide the skill is relevant from the catalog below.
        2. Call the **local_sandbox_exec** tool (this is the only channel that can put sandbox output into the conversation).
        3. In that tool call, run Luau that prints the file, e.g. `print(fs.read("/skills/apple-context/SKILL.md"))`.
        4. Read the tool result: that returned markdown **is** the skill loaded into context for later turns. Then follow it.
        5. If the skill points at support files in the same folder, load those the same way with `fs.read` + `print` through local_sandbox_exec.

        **What does not load a skill**
        - Naming the skill in assistant text without a tool call
        - `require("apple-context")`, `require("/skills/...")`, `require("./skills/...")`, or any `require` of a skill path (skills are not Luau modules; require always fails for them)
        - Assuming the catalog description is enough to skip the file

        **When to load**
        Before acting on a skill's domain—or claiming you cannot complete a related task—load that skill first (unless its full text is already present earlier in this conversation from a previous tool result). Example: calendar/location → load apple-context; websites → load webbrowser.

        ### Catalog

        \(skillLines)
        """
    }

    func addingICloudMountContext(to basePrompt: String) -> String {
        guard !iCloudMounts.isEmpty else {
            return basePrompt
        }
        let mountLines = iCloudMounts.map { mount in
            "- `\(mount.virtualPath)`: \(mount.accessMode.promptDescription) iCloud Drive folder"
        }.joined(separator: "\n")
        return basePrompt + """


        ## iCloud Mounts

        The user connected these original iCloud Drive folders to CPSL:

        \(mountLines)

        Treat content under `/icloud/*` as personal data. Read from those mounts only as needed for the task. Do not modify read-only mounts. Changes made in read-write mounts affect the original files; iCloud Drive uploads those changes asynchronously.
        """
    }

    init() {
        let webBrowser = CPSLWebBrowserService()
        self.webBrowser = webBrowser
        service = CPSLDebugService(
            webBrowser: webBrowser,
            location: location,
            calendarActivityNotifier: calendarActivityNotifier,
            fileActivityNotifier: fileActivityNotifier
        )
        iCloudMountChangeObserver = NotificationCenter.default.addObserver(
            forName: CPSLICloudMountStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshICloudMountsAfterChange()
            }
        }
        fileActivityNotifier.setHandler { [weak self] _ in
            self?.markFileActivity()
        }
        calendarActivityNotifier.setHandler { [weak self] _ in
            self?.markCalendarActivity()
        }
        location.activityOccurred = { [weak self] in
            self?.markLocationActivity()
        }
        webBrowser.visibilityChanged = { [weak self] isVisible in
            guard let self else {
                return
            }
            self.isWebBrowserOpen = isVisible
            if isVisible {
                self.isFileBrowserOpen = false
                self.filePreview = nil
                self.isDrawerOpen = false
                self.isCalendarOpen = false
                self.isLocationOpen = false
            }
        }
        webBrowser.webVisitOccurred = { [weak self] visit in
            self?.appendWebSearchVisit(visit)
        }
        Task {
            await bootstrap()
        }
    }

    func showComingSoon(_ message: String = "coming soon") {
        comingSoonMessage = message
    }

    func startNewConversation() {
        guard !isBusy else {
            return
        }

        let discardedDraftID = selectedConversationID == nil ? draftConversationID : nil
        promptText = ""
        discardComposerAttachments(removingScope: discardedDraftID)
        draftConversationID = UUID().uuidString
        comingSoonMessage = nil
        messages = []
        selectedConversationID = nil
        currentNodeID = nil
        currentSystemPrompt = nil
        isFileBrowserOpen = false
        isCalendarOpen = false
        isLocationOpen = false
        filePreview = nil
        closeWebBrowser()
        isDrawerOpen = false
        setArchivedScope(false)
    }

    func toggleDrawer() {
        setDrawerOpen(!isDrawerOpen)
    }

    func setDrawerOpen(_ isOpen: Bool) {
        guard isDrawerOpen != isOpen else {
            return
        }

        isDrawerOpen = isOpen
        if isOpen {
            isFileBrowserOpen = false
            isCalendarOpen = false
            isLocationOpen = false
            closeWebBrowser()
        }
    }

    func closeDrawer() {
        setDrawerOpen(false)
    }

    func selectConversation(id: String) {
        guard !isBusy else {
            return
        }

        if selectedConversationID == id {
            isDrawerOpen = false
            isFileBrowserOpen = false
            isCalendarOpen = false
            isLocationOpen = false
            filePreview = nil
            return
        }

        Task {
            await loadConversation(id: id)
        }
    }

    func deleteConversation(id: String) {
        guard !isBusy else {
            return
        }

        Task {
            await deleteStoredConversation(id: id)
        }
    }

    private func mutate(
        errorTitle: String,
        _ op: @escaping (CPSLConversationStore) async throws -> Void
    ) {
        Task {
            guard let store = try? await loadStore() else { return }
            do {
                try await op(store)
            } catch {
                appendErrorMessage(title: errorTitle, body: error.localizedDescription)
            }
            await reloadConversations()
        }
    }

    func setPinned(id: String, pinned: Bool) {
        mutate(errorTitle: "Conversation") { try await $0.setPinned(conversationID: id, pinned: pinned) }
    }

    func renameConversation(id: String, title: String) {
        mutate(errorTitle: "Rename") { try await $0.renameConversation(id: id, title: title) }
    }

    func archiveConversation(id: String) {
        // Only block archiving the conversation that is actively running.
        if isRunning, id == selectedConversationID { return }
        Task {
            do {
                let store = try await loadStore()
                try await store.setArchived(conversationID: id, archived: true)
            } catch {
                appendErrorMessage(title: "Conversation", body: error.localizedDescription)
                return
            }

            let archivedActiveConversation = (id == selectedConversationID)
            if archivedActiveConversation {
                discardComposerAttachments(removingScope: nil)
                selectedConversationID = nil
                currentNodeID = nil
                currentSystemPrompt = nil
                messages = []
            }
            await reloadConversations()
            // Select the most recent conversation only when this call deselected the active one.
            if archivedActiveConversation, selectedConversationID == nil, let first = conversations.first {
                await loadConversation(id: first.id)
            }
        }
    }

    func unarchiveConversation(id: String) {
        mutate(errorTitle: "Conversation") { try await $0.setArchived(conversationID: id, archived: false) }
    }

    func assignTags(conversationID: String, tagIDs: Set<String>) {
        mutate(errorTitle: "Tag") { try await $0.setTags(conversationID: conversationID, tagIDs: tagIDs) }
    }

    @discardableResult
    func createTag(name: String, color: String) async -> CPSLTag? {
        guard let store = try? await loadStore() else { return nil }
        do {
            let tag = try await store.createTag(name: name, color: color)
            await reloadConversations()
            return tag
        } catch {
            appendErrorMessage(title: "Tag", body: error.localizedDescription)
            return nil
        }
    }

    func renameTag(id: String, name: String) {
        mutate(errorTitle: "Tag") { try await $0.renameTag(id: id, name: name) }
    }

    func deleteTag(id: String) {
        mutate(errorTitle: "Tag") { try await $0.deleteTag(id: id) }
    }

    func tagIDs(for conversationID: String) async -> Set<String> {
        guard let store = try? await loadStore() else { return [] }
        return (try? await store.tagIDs(forConversation: conversationID)) ?? []
    }

#if DEBUG
    func makeConversationJSONTraceShareFile() async -> URL? {
        let conversationID = selectedConversationID
        do {
            let json = try await conversationDebugJSON(conversationID: conversationID)
            return try await Task.detached(priority: .utility) {
                try Self.writeConversationJSONTraceFile(json, conversationID: conversationID)
            }.value
        } catch {
            appendErrorMessage(title: "Debug", body: error.localizedDescription)
            return nil
        }
    }
#endif

    func submitPrompt() {
        let input = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!input.isEmpty || !composerAttachments.isEmpty), !isBusy else {
            return
        }

        if input.hasPrefix("!") {
            let command = String(input.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                appendErrorMessage(title: nil, body: "Enter a command after !")
                return
            }
            dictation.cancel()
            promptText = ""
            dismissOverlaysForRun()
            runCommand(command)
            return
        }

        let prompt = CPSLAttachmentPrompt(
            displayText: input,
            attachments: composerAttachments
        )

        dictation.cancel()
        promptText = ""
        composerAttachments = []
        dismissOverlaysForRun()
        isRunning = true
        activeRunTask = Task {
            await runAgent(prompt: prompt)
        }
    }

    private func dismissOverlaysForRun() {
        isFileBrowserOpen = false
        isCalendarOpen = false
        isLocationOpen = false
        filePreview = nil
        closeWebBrowser()
        isDrawerOpen = false
    }

    func stopAgent() {
        guard isRunning else {
            return
        }
        // Cancel the run task first so nested awaits (provider streams, sub-agents,
        // eval race) observe cooperative cancellation immediately.
        activeRunTask?.cancel()
        isSuppressingAssistantStream = true
        typewriterTask?.cancel()
        typewriterTask = nil
        typewriterBuffer = ""
        discardStreamingAssistantIfNeeded()
    }

    func addAttachment(from url: URL) {
        guard !isRunning else {
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        let conversationID = attachmentConversationID
        beginAttachmentImport()
        Task {
            defer {
                finishAttachmentImport()
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let attachment = try await service.importAttachment(
                    from: url,
                    conversationID: conversationID
                )
                guard attachmentConversationID == conversationID else {
                    await service.removeAttachment(attachment)
                    return
                }
                composerAttachments.append(attachment)
            } catch {
                comingSoonMessage = "Could not add \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func addAttachment(data: Data, preferredName: String) {
        guard !isRunning else {
            return
        }
        let conversationID = attachmentConversationID
        beginAttachmentImport()
        Task {
            defer {
                finishAttachmentImport()
            }
            do {
                let attachment = try await service.importAttachment(
                    data: data,
                    preferredName: preferredName,
                    conversationID: conversationID
                )
                guard attachmentConversationID == conversationID else {
                    await service.removeAttachment(attachment)
                    return
                }
                composerAttachments.append(attachment)
            } catch {
                comingSoonMessage = "Could not add \(preferredName): \(error.localizedDescription)"
            }
        }
    }

    func removeComposerAttachment(_ attachment: CPSLAttachment) {
        composerAttachments.removeAll { $0.id == attachment.id }
        Task {
            await service.removeAttachment(attachment)
        }
    }

    private var attachmentConversationID: String {
        selectedConversationID ?? draftConversationID
    }

    private func beginAttachmentImport() {
        attachmentImportCount += 1
        isImportingAttachment = true
    }

    private func finishAttachmentImport() {
        attachmentImportCount = max(0, attachmentImportCount - 1)
        isImportingAttachment = attachmentImportCount > 0
    }

    private func discardComposerAttachments(removingScope conversationID: String?) {
        let attachments = composerAttachments
        composerAttachments = []
        Task {
            if let conversationID {
                await service.removeAttachmentScope(conversationID: conversationID)
            } else {
                for attachment in attachments {
                    await service.removeAttachment(attachment)
                }
            }
        }
    }

    func toggleFileBrowser() {
        isFileBrowserOpen.toggle()
        if isFileBrowserOpen {
            isDrawerOpen = false
            closeWebBrowser()
            isCalendarOpen = false
            isLocationOpen = false
            filePreview = nil
            // Directory listing runs async on the debug-service actor; keep open snappy.
            loadBrowserPath(browserPath)
        } else {
            filePreview = nil
        }
    }

    func closeFileBrowser() {
        isFileBrowserOpen = false
        filePreview = nil
    }

    func toggleWebBrowser() {
        if isWebBrowserOpen {
            closeWebBrowser()
            return
        }
        isFileBrowserOpen = false
        filePreview = nil
        isCalendarOpen = false
        isLocationOpen = false
        isDrawerOpen = false
        isWebBrowserOpen = true
        webBrowser.showLastBrowserFromUI()
    }

    func openWebBrowserFromTimeline(browserID: String?) {
        isFileBrowserOpen = false
        filePreview = nil
        isCalendarOpen = false
        isLocationOpen = false
        isDrawerOpen = false
        isWebBrowserOpen = true
        if let browserID {
            Task {
                await webBrowser.showBrowserFromUI(id: browserID)
            }
        } else {
            webBrowser.showLastBrowserFromUI()
        }
    }

    func openFilePathFromTimeline(_ path: String) {
        let normalized = normalizedPath(path)
        guard isBrowserPathAllowed(normalized) else {
            comingSoonMessage = "This file location is not available from Files."
            return
        }

        isDrawerOpen = false
        closeWebBrowser()
        isCalendarOpen = false
        isLocationOpen = false
        filePreview = nil
        let navigationID = UUID()
        activeFileNavigationRequestID = navigationID

        Task { [weak self, service] in
            let lookup = await service.fileEntry(at: normalized)
            guard let self,
                  self.activeFileNavigationRequestID == navigationID
            else {
                return
            }
            guard let entry = lookup.entry else {
                self.activeFileNavigationRequestID = nil
                self.loadBrowserPath(self.parentPath(of: normalized))
                self.fileBrowserError = "\(normalized): \(lookup.error ?? "File does not exist.")"
                self.isFileBrowserOpen = true
                return
            }

            if entry.isDirectory {
                self.activeFileNavigationRequestID = nil
                self.loadBrowserPath(entry.path)
                self.isFileBrowserOpen = true
            } else {
                let previewResult = await service.previewFile(entry)
                guard self.activeFileNavigationRequestID == navigationID else {
                    return
                }
                self.activeFileNavigationRequestID = nil
                self.loadBrowserPath(self.parentPath(of: entry.path))
                if let preview = previewResult.preview {
                    self.filePreviewLifetimeToken = previewResult.lifetimeToken
                    self.filePreview = preview
                } else {
                    let message = previewResult.error ?? "Preview is not available for this file."
                    self.fileBrowserError = "\(entry.path): \(message)"
                }
                self.isFileBrowserOpen = true
            }
        }
    }

    func toggleCalendar() {
        if isCalendarOpen {
            closeCalendar()
            return
        }

        isDrawerOpen = false
        isFileBrowserOpen = false
        filePreview = nil
        isLocationOpen = false
        closeWebBrowser()
        isCalendarOpen = true
        Task(priority: .userInitiated) {
            let access = await calendar.loadUpcomingEvents()
            if access == .denied {
                comingSoonMessage = "Calendar access is denied. Enable Calendar access for Herm in iOS Settings or macOS System Settings."
            }
        }
    }

    func closeCalendar() {
        isCalendarOpen = false
    }

    func toggleLocation() {
        if isLocationOpen {
            closeLocation()
            return
        }

        isDrawerOpen = false
        isFileBrowserOpen = false
        filePreview = nil
        isCalendarOpen = false
        closeWebBrowser()
        // Open chrome immediately; location fetch/MapKit work must not gate presentation.
        isLocationOpen = true
        Task(priority: .userInitiated) {
            let access = await location.loadCurrentLocation()
            if access == .denied {
                comingSoonMessage = location.locationError
                    ?? "Location access is denied. Enable Location access for Herm in iOS Settings or macOS System Settings."
            }
        }
    }

    func closeLocation() {
        isLocationOpen = false
    }

    func closeWebBrowser() {
        isWebBrowserOpen = false
        webBrowser.hideOverlayFromUI()
    }

    func loadBrowserPath(_ path: String) {
        let normalized = scopedBrowserPath(path)
        let isChangingPath = normalized != browserPath
        browserPath = normalized
        fileBrowserError = nil
        expandedFilePaths.removeAll()
        childEntriesByPath.removeAll()

        if isChangingPath {
            filePreview = nil
            browserEntries = []
        }

        guard normalized != CPSLVirtualPath.root else {
            browserEntries = []
            return
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
            requestFilePreview(for: entry)
        }
    }

    func closeFilePreview() {
        isFileInfoOpen = false
        filePreview = nil
    }

    func openFileInfo() {
        guard filePreview != nil else {
            return
        }
        isFileInfoOpen = true
    }

    func closeFileInfo() {
        isFileInfoOpen = false
    }

    func isFileReadOnly(_ path: String) -> Bool {
        iCloudMount(containing: path)?.accessMode == .readOnly
    }

    func isICloudMountRoot(_ path: String) -> Bool {
        iCloudMounts.contains { $0.virtualPath == normalizedPath(path) }
    }

    func canMoveFileEntries(
        _ entries: [CPSLFileEntry],
        toDirectory destinationPath: String
    ) -> Bool {
        let destination = normalizedPath(destinationPath)
        guard !entries.isEmpty,
              destination != CPSLVirtualPath.root,
              destination != CPSLVirtualPath.iCloudRoot,
              isBrowserPathAllowed(destination),
              !isFileReadOnly(destination)
        else {
            return false
        }

        for entry in entries {
            let source = normalizedPath(entry.path)
            if isICloudMountRoot(source) ||
                isFileReadOnly(source) ||
                parentPath(of: source) == destination ||
                source == destination ||
                (entry.isDirectory && destination.hasPrefix("\(source)/")) {
                return false
            }
        }
        return true
    }

    func deleteFileEntries(_ entries: [CPSLFileEntry]) {
        guard !entries.isEmpty, !isBusy else {
            return
        }
        fileBrowserError = nil
        isManagingFiles = true
        Task { [weak self, service] in
            guard let self else {
                return
            }
            defer {
                self.isManagingFiles = false
            }
            let operationError: String?
            do {
                try await service.deleteFileEntries(entries)
                operationError = nil
            } catch {
                operationError = "Files: \(error.localizedDescription)"
            }
            self.loadBrowserPath(self.browserPath)
            self.fileBrowserError = operationError
        }
    }

    func moveFileEntries(
        _ entries: [CPSLFileEntry],
        toDirectory destinationPath: String
    ) {
        guard canMoveFileEntries(entries, toDirectory: destinationPath), !isBusy else {
            return
        }
        fileBrowserError = nil
        isManagingFiles = true
        Task { [weak self, service] in
            guard let self else {
                return
            }
            defer {
                self.isManagingFiles = false
            }
            let operationError: String?
            do {
                try await service.moveFileEntries(entries, toDirectory: destinationPath)
                operationError = nil
            } catch {
                operationError = "Files: \(error.localizedDescription)"
            }
            self.loadBrowserPath(self.browserPath)
            self.fileBrowserError = operationError
        }
    }

    func attachmentThumbnail(for attachment: CPSLAttachment) async -> Data? {
        if let cached = attachmentThumbnailCache[attachment.id] {
            return cached
        }
        guard !attachmentsWithoutThumbnails.contains(attachment.id) else {
            return nil
        }
        guard let data = await service.attachmentThumbnail(for: attachment) else {
            attachmentsWithoutThumbnails.insert(attachment.id)
            return nil
        }
        attachmentThumbnailCache[attachment.id] = data
        return data
    }

    func markFileActivity() {
        markTransientActivity(.file)
    }

    func markCalendarActivity() {
        markTransientActivity(.calendar)
    }

    func markLocationActivity() {
        markTransientActivity(.location)
    }

    private func markTransientActivity(_ activity: CPSLTransientActivity) {
        clearTask(for: activity)?.cancel()
        setActivity(activity, isActive: true)
        let duration = activityPulseDuration
        setClearTask(
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else {
                    return
                }
                self?.setActivity(activity, isActive: false)
            },
            for: activity
        )
    }

    private func setActivity(_ activity: CPSLTransientActivity, isActive: Bool) {
        switch activity {
        case .file:
            isFileActivityActive = isActive
        case .calendar:
            isCalendarActivityActive = isActive
        case .location:
            isLocationActivityActive = isActive
        }
    }

    private func clearTask(for activity: CPSLTransientActivity) -> Task<Void, Never>? {
        switch activity {
        case .file:
            return fileActivityClearTask
        case .calendar:
            return calendarActivityClearTask
        case .location:
            return locationActivityClearTask
        }
    }

    private func setClearTask(_ task: Task<Void, Never>?, for activity: CPSLTransientActivity) {
        switch activity {
        case .file:
            fileActivityClearTask = task
        case .calendar:
            calendarActivityClearTask = task
        case .location:
            locationActivityClearTask = task
        }
    }

    func importICloudDirectory(
        _ url: URL,
        accessMode: CPSLICloudMountAccessMode = .readWrite
    ) {
        guard !isBusy else {
            fileBrowserError = "Wait for the current operation to finish before adding an iCloud folder."
            return
        }

        fileBrowserError = nil
        isUpdatingICloudMounts = true
        iCloudImportProgress = .preparing
        let importID = UUID()
        activeICloudImportID = importID
        iCloudImportTask = Task { [weak self, service] in
            defer {
                if let self, self.activeICloudImportID == importID {
                    self.activeICloudImportID = nil
                    self.iCloudImportTask = nil
                    self.iCloudImportProgress = nil
                    self.isUpdatingICloudMounts = false
                }
            }
            do {
                let mount = try await service.connectICloudDirectory(
                    from: url,
                    accessMode: accessMode
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.applyICloudImportProgress(progress, importID: importID)
                    }
                }
                let mounts = await service.activeICloudMounts()
                self?.iCloudMounts = mounts
                self?.loadBrowserPath(mount.virtualPath)
            } catch is CancellationError {
                return
            } catch {
                self?.fileBrowserError = "iCloud: \(error.localizedDescription)"
            }
        }
    }

    func setICloudMountAccessMode(
        _ accessMode: CPSLICloudMountAccessMode,
        at path: String
    ) {
        guard !isBusy else {
            fileBrowserError = "Wait for the current operation to finish before changing access."
            return
        }
        fileBrowserError = nil
        isUpdatingICloudMounts = true
        Task {
            defer { isUpdatingICloudMounts = false }
            do {
                try await service.setICloudMountAccessMode(accessMode, at: path)
                iCloudMounts = await service.activeICloudMounts()
                if isFileBrowserOpen {
                    loadBrowserPath(browserPath)
                }
            } catch {
                fileBrowserError = "iCloud: \(error.localizedDescription)"
            }
        }
    }

    func setKeepDownloaded(_ keep: Bool, at path: String) {
        guard !isBusy else {
            fileBrowserError = "Wait for the current operation to finish before changing download state."
            return
        }
        fileBrowserError = nil
        isUpdatingICloudMounts = true
        Task {
            defer { isUpdatingICloudMounts = false }
            do {
                try await service.setKeepDownloaded(keep, at: path)
                if isFileBrowserOpen {
                    loadBrowserPath(browserPath)
                }
            } catch {
                fileBrowserError = "iCloud: \(error.localizedDescription)"
            }
        }
    }

    func cancelICloudImport() {
        if let progress = iCloudImportProgress {
            iCloudImportProgress = progress.cancelling
        }
        iCloudImportTask?.cancel()
    }

    deinit {
        iCloudImportTask?.cancel()
        filePreviewLoadTask?.cancel()
        if let iCloudMountChangeObserver {
            NotificationCenter.default.removeObserver(iCloudMountChangeObserver)
        }
    }

    private func refreshICloudMountsAfterChange() async {
        let updatedMounts = await service.activeICloudMounts()
        let previousBrowserPath = browserPath
        let previewPath = filePreview?.path
        iCloudMounts = updatedMounts

        if let previewPath,
           previewPath.hasPrefix("\(CPSLVirtualPath.iCloudRoot)/"),
           CPSLICloudMountResolver.mount(containing: previewPath, in: updatedMounts) == nil {
            filePreview = nil
        }

        guard previousBrowserPath == CPSLVirtualPath.iCloudRoot ||
                previousBrowserPath.hasPrefix("\(CPSLVirtualPath.iCloudRoot)/")
        else {
            return
        }
        if previousBrowserPath != CPSLVirtualPath.iCloudRoot,
           CPSLICloudMountResolver.mount(
               containing: previousBrowserPath,
               in: updatedMounts
           ) == nil {
            loadBrowserPath(CPSLVirtualPath.iCloudRoot)
        } else if isFileBrowserOpen {
            loadBrowserPath(previousBrowserPath)
        }
    }

    private func applyICloudImportProgress(
        _ progress: CPSLICloudImportProgress,
        importID: UUID
    ) {
        guard activeICloudImportID == importID else {
            return
        }
        guard iCloudImportProgress?.phase != .cancelling else {
            return
        }
        if let current = iCloudImportProgress, current.phase == progress.phase {
            switch progress.phase {
            case .downloading:
                guard progress.completedBytes >= current.completedBytes,
                      progress.completedItems >= current.completedItems
                else {
                    return
                }
            case .preparing, .cancelling:
                break
            }
        }
        iCloudImportProgress = progress
    }

    func reportICloudImportError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain &&
            nsError.code == CocoaError.Code.userCancelled.rawValue {
            return
        }
        fileBrowserError = "iCloud: \(error.localizedDescription)"
    }

    func removeICloudMount(_ entry: CPSLFileEntry) {
        guard !isBusy else {
            fileBrowserError = "Wait for the current operation to finish before removing an iCloud folder."
            return
        }

        fileBrowserError = nil
        isUpdatingICloudMounts = true
        Task {
            defer {
                isUpdatingICloudMounts = false
            }
            do {
                try await service.removeICloudMount(at: entry.path)
                iCloudMounts = await service.activeICloudMounts()
                loadBrowserPath(iCloudMounts.isEmpty ? CPSLVirtualPath.root : CPSLVirtualPath.iCloudRoot)
            } catch {
                fileBrowserError = "iCloud: \(error.localizedDescription)"
            }
        }
    }

    func children(for path: String) -> [CPSLFileEntry] {
        childEntriesByPath[path] ?? []
    }

    func iCloudMount(containing path: String) -> CPSLICloudMount? {
        CPSLICloudMountResolver.mount(containing: path, in: iCloudMounts)
    }

    func isExpanded(_ entry: CPSLFileEntry) -> Bool {
        expandedFilePaths.contains(entry.path)
    }

    func isLoading(_ path: String) -> Bool {
        loadingFilePaths.contains(path)
    }

    var sectionGroups: [CPSLConversationSectionGroup] {
        CPSLConversationGrouping.sections(
            summaries: conversations,
            searchText: searchText,
            now: Date(),
            calendar: .current
        )
    }

    func setArchivedScope(_ on: Bool) {
        guard showingArchived != on else { return }
        showingArchived = on
        Task { await reloadConversations() }
    }

    func toggleActiveTag(_ id: String) {
        if activeTagIDs.contains(id) {
            activeTagIDs.remove(id)
        } else {
            activeTagIDs.insert(id)
        }
        Task { await reloadConversations() }
    }

    func clearActiveTags() {
        activeTagIDs = []
        Task { await reloadConversations() }
    }

    private func reloadConversations() async {
        guard let store = try? await loadStore() else { return }
        let scope: CPSLArchiveScope = showingArchived ? .archived : .active
        do {
            conversations = try await store.fetchConversationSummaries(archiveScope: scope, tagIDs: activeTagIDs)
            allTags = try await store.allTags()
            // Reconcile: active tags deleted (locally or via iCloud) are dropped.
            let validIDs = Set(allTags.map(\.id))
            let reconciled = activeTagIDs.intersection(validIDs)
            if reconciled != activeTagIDs {
                activeTagIDs = reconciled
                conversations = try await store.fetchConversationSummaries(archiveScope: scope, tagIDs: reconciled)
            }
        } catch {
            appendErrorMessage(title: "Storage", body: error.localizedDescription)
        }
    }

    private func bootstrap() async {
        // Conversations and mounts load in parallel — neither waits on the other.
        async let mountsReady: Void = prepareMountsAndSandbox()
        async let conversationsReady: Void = loadConversationsAtLaunch()
        _ = await (mountsReady, conversationsReady)
        if selectedConversationID == nil, messages.isEmpty, let first = conversations.first {
            await loadConversation(id: first.id)
        }
    }

    private func prepareMountsAndSandbox() async {
        do {
            iCloudMounts = try await service.prepareICloudMounts()
        } catch {
            iCloudMounts = await service.activeICloudMounts()
            appendErrorMessage(title: "iCloud", body: error.localizedDescription)
        }

        do {
            try await service.prepareSandbox()
        } catch {
            appendErrorMessage(title: "Files", body: error.localizedDescription)
        }
    }

    private func loadConversationsAtLaunch() async {
        defer { isLoadingConversations = false }
        await reloadConversations()
    }

    private func loadStore() async throws -> CPSLConversationStore {
        if let store {
            return store
        }
        if let storeLoadTask {
            return try await storeLoadTask.value
        }

        let task = Task.detached(priority: .utility) {
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
        let discardedDraftID = selectedConversationID == nil ? draftConversationID : nil
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
            discardComposerAttachments(removingScope: discardedDraftID)
            if discardedDraftID != nil {
                draftConversationID = UUID().uuidString
            }
            selectedConversationID = conversation.summary.id
            currentNodeID = conversation.summary.currentNodeID
            currentSystemPrompt = conversation.systemPrompt.isEmpty ? systemPrompt : conversation.systemPrompt
            let nodes = conversation.nodes
            let toolStatusNodeIDs = Self.toolStatusNodeIDsNeedingInvocations(in: nodes)
            let toolStatusInvocations = try? await store.toolStatusInvocations(
                conversationID: conversation.summary.id,
                nodeIDs: toolStatusNodeIDs
            )
            messages = await Task.detached(priority: .userInitiated) {
                Self.chatMessages(
                    from: nodes,
                    toolStatusInvocations: toolStatusInvocations ?? [:]
                )
            }.value
            await reloadConversations()
            isDrawerOpen = false
            isFileBrowserOpen = false
            isCalendarOpen = false
            isLocationOpen = false
            filePreview = nil
        } catch {
            appendErrorMessage(title: "Conversation", body: error.localizedDescription)
        }
    }

    private nonisolated static func toolStatusNodeIDsNeedingInvocations(
        in nodes: [CPSLStoredNode]
    ) -> Set<String> {
        Set(nodes.compactMap { node in
            guard node.role == .toolStatus,
                  let payload = CPSLToolStatusPayload.decode(from: node.body),
                  payload.invocations.isEmpty
            else {
                return nil
            }
            return node.id
        })
    }

    private nonisolated static func chatMessages(
        from nodes: [CPSLStoredNode],
        toolStatusInvocations: [String: [CPSLToolStatusInvocation]]
    ) -> [CPSLChatMessage] {
        nodes.compactMap { node in
            guard var message = node.chatMessage else {
                return nil
            }
            guard node.role == .toolStatus,
                  var payload = CPSLToolStatusPayload.decode(from: message.body),
                  payload.invocations.isEmpty,
                  let invocations = toolStatusInvocations[node.id],
                  !invocations.isEmpty
            else {
                return message
            }
            payload.invocations = invocations
            message.body = payload.encodedBody()
            return message
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
            await service.removeAttachmentScope(conversationID: id)
            await reloadConversations()
            if selectedConversationID == id {
                selectedConversationID = nil
                composerAttachments = []
                draftConversationID = UUID().uuidString
                currentNodeID = nil
                currentSystemPrompt = nil
                messages = []
                isCalendarOpen = false
                isLocationOpen = false
            }
        } catch {
            appendErrorMessage(title: "Conversation", body: error.localizedDescription)
        }
    }

#if DEBUG
    private func conversationDebugJSON(conversationID: String?) async throws -> String {
        if let conversationID {
            let store = try await loadStore()
            return try await store.exportConversationJSON(id: conversationID)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(CPSLDebugConversationSnapshot(messages: messages))
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func writeConversationJSONTraceFile(
        _ json: String,
        conversationID: String?
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermDebugTraces", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let conversationComponent = safeTraceFileComponent(conversationID ?? "draft")
        let fileName = "herm-\(conversationComponent)-trace-\(traceFileTimestamp()).json"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private nonisolated static func traceFileTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private nonisolated static func safeTraceFileComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let component = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
        return component.isEmpty ? "conversation" : component
    }
#endif

    private func runAgent(prompt: CPSLAttachmentPrompt) async {
        defer {
            isRunning = false
            activeRunTask = nil
        }

        let store: CPSLConversationStore
        do {
            store = try await loadStore()
        } catch {
            appendErrorMessage(title: "Storage", body: error.localizedDescription)
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
            // Rebuild every turn so prompt/skill guidance and available skills stay current
            // (do not freeze the first-turn prompt for the life of the conversation).
            let availableSkills = await service.availableSkills()
            let promptForConversation = systemPrompt(with: availableSkills)
            currentSystemPrompt = promptForConversation

            if let selectedConversationID, let currentNodeID {
                conversationID = selectedConversationID
                let node = try await store.appendNode(
                    conversationID: selectedConversationID,
                    parentID: currentNodeID,
                    draft: CPSLNodeAppendDraft(
                        role: .user,
                        title: nil,
                        body: prompt.displayText,
                        model: nil,
                        providerMessage: .user(prompt.providerText)
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
                    id: draftConversationID,
                    userText: prompt.displayText,
                    providerText: prompt.providerText,
                    model: nil,
                    systemPrompt: promptForConversation
                )
                conversationID = created.summary.id
                parentID = created.userNode.id
                selectedConversationID = conversationID
                draftConversationID = UUID().uuidString
                currentNodeID = parentID
                if let message = created.userNode.chatMessage {
                    messages.append(message)
                }
                activeConversationID = conversationID
                activeParentID = parentID
            }
            await reloadConversations()
            try Task.checkCancellation()

            let config = try CPSLAgentConfig.load()
            let client = CPSLAgentChatClient(config: config)
            let modelID = await client.modelID
            activeModel = modelID
            try await store.updateConversationModelIfMissing(conversationID: conversationID, model: modelID)
            let providerMessages = try await store.providerMessages(conversationID: conversationID)
            let replaySystemPrompt = addingICloudMountContext(to: promptForConversation)
            var providerLoopContext = CPSLProviderLoopContext(
                client: client,
                store: store,
                conversationID: conversationID,
                parentID: parentID,
                config: config,
                modelID: modelID,
                systemPrompt: replaySystemPrompt,
                providerMessages: providerMessages
            ) { nodeID in
                activeParentID = nodeID
            }
            try await runProviderLoop(&providerLoopContext)
            try Task.checkCancellation()
            parentID = providerLoopContext.parentID
            currentNodeID = parentID
            await reloadConversations()
        } catch {
            if let activeConversationID {
                try? await store.recordError(
                    conversationID: activeConversationID,
                    message: error.localizedDescription,
                    scope: "agent.run"
                )
            }
            let pendingContext = CPSLPendingConversationContext(
                store: store,
                conversationID: activeConversationID,
                parentID: activeParentID,
                model: activeModel
            )
            activeParentID = await persistStreamingAssistantIfNeeded(pendingContext)
            if Task.isCancelled {
                await markActiveToolStatusStopped()
                currentNodeID = activeParentID
            } else {
                await markActiveToolStatusFailed()
                await appendAgentError(
                    error.localizedDescription,
                    context: CPSLPendingConversationContext(
                        store: store,
                        conversationID: activeConversationID,
                        parentID: activeParentID,
                        model: activeModel
                    )
                )
            }
            await reloadConversations()
        }

        await finishTypewriter()
        streamingAssistantMessageID = nil
    }


    private func runCommand(_ command: String) {
        let message = CPSLChatMessage(role: .command, title: nil, body: commandBlockBody(command: command))
        messages.append(message)
        isRunning = true

        activeRunTask = Task { @MainActor in
            defer {
                isRunning = false
                activeRunTask = nil
            }
            let result = await service.evaluate(command)
            guard !Task.isCancelled else {
                return
            }
            applyCommandResult(result, command: command, messageID: message.id)
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

    private func requestFilePreview(for entry: CPSLFileEntry) {
        filePreview = nil
        let requestID = UUID()
        let requestedBrowserPath = browserPath
        activeFilePreviewRequestID = requestID
        filePreviewLoadTask = Task { [weak self, service] in
            let result = await service.previewFile(entry)
            guard !Task.isCancelled,
                  let self,
                  self.activeFilePreviewRequestID == requestID,
                  self.isFileBrowserOpen,
                  self.browserPath == requestedBrowserPath
            else {
                return
            }
            self.activeFilePreviewRequestID = nil
            self.filePreviewLoadTask = nil
            if let preview = result.preview {
                self.filePreviewLifetimeToken = result.lifetimeToken
                self.filePreview = preview
                return
            }

            self.filePreview = nil
            let message = result.error ?? "Preview is not available for this file."
            self.fileBrowserError = "\(entry.path): \(message)"
        }
    }

    private func retireFilePreviewLifetimeToken() {
        guard let token = filePreviewLifetimeToken else {
            return
        }
        filePreviewLifetimeToken = nil
        let retirementID = UUID()
        retiredFilePreviewLifetimeTokens[retirementID] = token
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.filePreviewRetirementNanoseconds)
            self?.retiredFilePreviewLifetimeTokens.removeValue(forKey: retirementID)
        }
    }

    func appendErrorMessage(title: String?, body: String) {
        messages.append(CPSLChatMessage(role: .error, title: title, body: body))
    }

    func appendWebSearchVisit(_ visit: CPSLWebSearchVisit) {
        guard let nodeID = activeToolStatusNodeID,
              let conversationID = activeToolStatusConversationID,
              let store = activeToolStatusStore,
              var payload = activeToolStatusPayload
        else {
            return
        }
        payload.webVisits.append(visit)
        payload.webVisits = Array(payload.webVisits.suffix(12))
        activeToolStatusPayload = payload
        activeToolStatusRevision += 1
        let revision = activeToolStatusRevision
        let body = payload.encodedBody()
        Task { [weak self] in
            try? await store.recordWebVisit(
                conversationID: conversationID,
                nodeID: nodeID,
                visit: visit
            )
            try? await store.updateNodeBody(
                conversationID: conversationID,
                id: nodeID,
                body: body
            )
            guard let self,
                  self.activeToolStatusNodeID == nodeID,
                  self.activeToolStatusRevision == revision
            else {
                return
            }
            if let messageID = UUID(uuidString: nodeID),
               let index = self.messages.firstIndex(where: { $0.id == messageID }) {
                self.messages[index].body = body
            }
        }
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
            normalized == CPSLVirtualPath.attachments ||
            normalized.hasPrefix("\(CPSLVirtualPath.attachments)/") ||
            normalized == CPSLVirtualPath.home ||
            normalized.hasPrefix("\(CPSLVirtualPath.home)/") ||
            normalized == CPSLVirtualPath.temporary ||
            normalized.hasPrefix("\(CPSLVirtualPath.temporary)/") ||
            normalized == CPSLVirtualPath.iCloudRoot ||
            iCloudMounts.contains { mount in
                normalized == mount.virtualPath || normalized.hasPrefix("\(mount.virtualPath)/")
            }
    }

    private func browserParentPath() -> String? {
        let normalized = normalizedPath(browserPath)
        guard normalized != CPSLVirtualPath.root else {
            return nil
        }
        guard isBrowserPathAllowed(normalized) else {
            return CPSLVirtualPath.root
        }
        if normalized == CPSLVirtualPath.attachments ||
            normalized == CPSLVirtualPath.home ||
            normalized == CPSLVirtualPath.temporary ||
            normalized == CPSLVirtualPath.iCloudRoot {
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
    let format = "herm.debug-export"
    let schemaVersion = 1
    let generatedAt = Date()
    let documentation = [
        "overview": "Unsaved draft snapshot. Persisted exports also contain chronological conversationEvents and traceEvents.",
        "jq": ".conversation.messages[] | {role, title, body}",
    ]
    let messages: [CPSLChatMessage]
    let conversationEvents: [String] = []
    let traceEvents: [String] = []

    private enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion
        case generatedAt
        case documentation
        case conversation
        case conversationEvents
        case traceEvents
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(documentation, forKey: .documentation)
        try container.encode(
            CPSLDebugDraftConversation(state: "draft", messages: messages),
            forKey: .conversation
        )
        try container.encode(conversationEvents, forKey: .conversationEvents)
        try container.encode(traceEvents, forKey: .traceEvents)
    }
}

private nonisolated struct CPSLDebugDraftConversation: Encodable {
    let state: String
    let messages: [CPSLChatMessage]
}
#endif
