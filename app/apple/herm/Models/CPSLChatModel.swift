import Combine
import Foundation

private enum CPSLTransientActivity {
    case file
    case calendar
    case location
}

@MainActor
final class CPSLChatModel: ObservableObject {
    @Published var promptText = ""
    @Published private(set) var composerAttachments: [CPSLAttachment] = []
    @Published private(set) var isImportingAttachment = false
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
    @Published private(set) var isWebBrowserOpen = false
    @Published private(set) var isFileActivityActive = false
    @Published private(set) var isCalendarOpen = false
    @Published private(set) var isCalendarActivityActive = false
    @Published private(set) var isLocationOpen = false
    @Published private(set) var isLocationActivityActive = false
    @Published private(set) var iCloudMounts: [CPSLICloudMount] = []
    @Published private(set) var isUpdatingICloudMounts = false
    @Published private(set) var iCloudImportProgress: CPSLICloudImportProgress?

    var isBusy: Bool {
        isRunning || isUpdatingICloudMounts
    }

    let service: CPSLDebugService
    let webBrowser: CPSLWebBrowserService
    let calendar = CPSLCalendarService()
    let location = CPSLLocationService()
    let dictation = CPSLDictationService()
    private let fileActivityNotifier = CPSLFileActivityNotifier()
    private let calendarActivityNotifier = CPSLCalendarActivityNotifier()
    private var store: CPSLConversationStore?
    private var storeLoadTask: Task<CPSLConversationStore, Error>?
    private var activeRunTask: Task<Void, Never>?
    var currentNodeID: String?
    private var currentSystemPrompt: String?
    var streamingAssistantMessageID: UUID?
    var isSuppressingAssistantStream = false
    var typewriterBuffer = ""
    var typewriterTask: Task<Void, Never>?
    private var iCloudImportTask: Task<Void, Never>?
    private var activeICloudImportID: UUID?
    let estimatedBytesPerToken = 4
    let toolResultClearThreshold = 0.80
    let recentToolResultsToKeep = 4
    var activeToolStatusNodeID: String?
    var activeToolStatusPayload: CPSLToolStatusPayload?
    var activeToolStatusStore: CPSLConversationStore?
    private var fileActivityClearTask: Task<Void, Never>?
    private var calendarActivityClearTask: Task<Void, Never>?
    private var locationActivityClearTask: Task<Void, Never>?
    private var draftConversationID = UUID().uuidString
    private var attachmentImportCount = 0
    private let activityPulseDuration: TimeInterval = 1.6

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
    For tasks involving a website or online service—including account actions, private messages, posts, forms, and file uploads or downloads—the webbrowser skill is relevant and you must read it before deciding how to proceed. The native browser uses persistent WebKit state, so the user may already be signed in. When the user explicitly requests a specific action, try to complete it through the site's normal browser interface on their behalf. Keep ordinary browser work in the background; hand the browser to the user only when authentication, consent, CAPTCHA, payment, or subjective confirmation requires them.
    Use authenticated websites only through their normal browser flow. Do not unhide, relabel, restyle, or inject page controls to manufacture an interaction target. Do not replace normal browser typing with stacked JavaScript input, paste, or synthetic keyboard-event strategies. After a consequential action is confirmed, do not repeat it or send a corrective follow-up unless the user explicitly asks; report every side effect accurately. Never extract, print, copy, or reuse authentication tokens, cookies, or other session secrets from browser storage or page JavaScript, and never use those secrets to call a site's private API.
    Every local_sandbox_exec call must include intent: one short high-level user-facing action phrase, such as "Preparing document", "Checking export", or "Saving result". Do not mention code, sandbox details, paths, module names, tool names, API names, file extensions, HTTP, or implementation details in intent.
    When you call tools, assistant content may contain the same kind of high-level status phrase, but never code or implementation details.
    local_sandbox_exec runs Luau source in CPSL. The current CPSL directory is supplied in each request. Never guess CPSL API signatures: call help() and each module's help function, such as fs.help(), before using APIs.
    Treat CPSL as its own Luau ecosystem. APIs from other Lua/Luau environments may be popular elsewhere but are not expected to exist here. Use only the built-in globals shown by help(); for files use fs, for documents use doc. Do not use require or package-style imports for filesystem or document work.
    Treat help output as human-readable documentation. Call help() or module.help() as its own sandbox invocation and read the printed text; do not assign help output to a variable or parse it with string.find, string.sub, #, or tostring().
    Follow documented return shapes exactly. For example, fs.list(path) returns an array of entry name strings; it does not return records with name or size fields. Use fs.size(path .. "/" .. entry) only when sizes are needed.
    Calendar and location are available through CPSL only when compiled into the app sandbox and authorized by the user. Use calendar or location only when the user's request materially needs schedule, event, availability, or current-place context. EventKit does not expose native calendar file attachments. When files should be associated with an event, use calendar.attach: it copies them to durable storage and makes them openable from Herm's Calendar view. Describe these as attached in Herm, not as native Calendar.app attachments. Access states are granted, denied, or undefined. If access is undefined, the relevant CPSL request/current function may prompt the user. If access is denied, stop using that capability and tell the user to enable access for Herm in iOS Settings or macOS System Settings.
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
            "- **\($0.name)**: \($0.description) Read: `\($0.path)`"
        }.joined(separator: "\n")
        return systemPrompt + """


        ## Skills

        The following skills are available. Their full instructions are not loaded into this prompt. When a skill is relevant to the user's task, you must read its skill file before acting or claiming the task cannot be completed, then follow that file's instructions and read any referenced support files from the same folder as needed.

        \(skillLines)
        """
    }

    func addingICloudMountContext(to basePrompt: String) -> String {
        guard !iCloudMounts.isEmpty else {
            return basePrompt
        }
        let mountLines = iCloudMounts.map { mount in
            "- `\(mount.virtualPath)`: read-only staged iCloud Drive snapshot"
        }.joined(separator: "\n")
        return basePrompt + """


        ## iCloud Mounts

        The user selected staged iCloud Drive folders. They are available in CPSL:

        \(mountLines)

        Treat content under `/icloud/*` as personal data. Read from those mounts only as needed for the task. Write outputs to `/home/herm` or `/tmp`; iCloud mounts are staged snapshots and do not sync changes back to iCloud. Network access is disabled while these mounts are active.
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
            await service.prepareICloudStaging()
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

#if DEBUG
    func makeConversationJSONTraceShareFile() async -> URL? {
        let conversationID = selectedConversationID
        do {
            let json = try await conversationDebugJSON(conversationID: conversationID)
            return try Self.writeConversationJSONTraceFile(json, conversationID: conversationID)
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
        isFileBrowserOpen = false
        isCalendarOpen = false
        isLocationOpen = false
        filePreview = nil
        closeWebBrowser()
        isDrawerOpen = false
        isRunning = true
        activeRunTask = Task {
            await runAgent(prompt: prompt)
        }
    }

    func stopAgent() {
        guard isRunning else {
            return
        }
        activeRunTask?.cancel()
        isSuppressingAssistantStream = true
        typewriterTask?.cancel()
        typewriterTask = nil
        typewriterBuffer = ""
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
        isFileBrowserOpen = true
        filePreview = nil

        Task {
            let lookup = await service.fileEntry(at: normalized)
            guard let entry = lookup.entry else {
                loadBrowserPath(parentPath(of: normalized))
                fileBrowserError = "\(normalized): \(lookup.error ?? "File does not exist.")"
                return
            }

            if entry.isDirectory {
                loadBrowserPath(entry.path)
            } else {
                loadBrowserPath(parentPath(of: entry.path))
                await loadPreview(for: entry)
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
        Task {
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
        isLocationOpen = true
        Task {
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

    func importICloudDirectory(_ url: URL) {
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
                let mount = try await service.stageICloudDirectory(from: url) { [weak self] progress in
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

    func cancelICloudImport() {
        if let progress = iCloudImportProgress {
            iCloudImportProgress = progress.cancelling
        }
        iCloudImportTask?.cancel()
    }

    deinit {
        iCloudImportTask?.cancel()
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
        if let current = iCloudImportProgress, current.phase == .copying {
            guard progress.phase == .copying,
                progress.completedBytes >= current.completedBytes,
                progress.completedItems >= current.completedItems
            else {
                return
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

    func isExpanded(_ entry: CPSLFileEntry) -> Bool {
        expandedFilePaths.contains(entry.path)
    }

    func isLoading(_ path: String) -> Bool {
        loadingFilePaths.contains(path)
    }

    private func bootstrap() async {
        do {
            try await service.prepareSandbox()
        } catch {
            appendErrorMessage(title: "Files", body: error.localizedDescription)
        }
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
            messages = conversation.nodes.compactMap(\.chatMessage)
            conversations = try await store.loadSummaries()
            isDrawerOpen = false
            isFileBrowserOpen = false
            isCalendarOpen = false
            isLocationOpen = false
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
            await service.removeAttachmentScope(conversationID: id)
            conversations = try await store.loadSummaries()
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
            let availableSkills = await service.availableSkills()
            let promptForConversation = systemPrompt(with: availableSkills)

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
                currentSystemPrompt = promptForConversation
                if let message = created.userNode.chatMessage {
                    messages.append(message)
                }
                activeConversationID = conversationID
                activeParentID = parentID
            }
            conversations = try await store.loadSummaries()
            try Task.checkCancellation()

            let config = try CPSLAgentConfig.load()
            let client = CPSLOpenAIClient(config: config)
            activeModel = config.model
            try await store.updateConversationModelIfMissing(conversationID: conversationID, model: config.model)
            let providerMessages = try await store.providerMessages(conversationID: conversationID)
            // Stored prompts may advertise capabilities that are deliberately
            // unavailable while personal mounts are connected. Use the live
            // catalog for an isolated run instead of replaying stale skills.
            let replayBasePrompt = iCloudMounts.isEmpty
                ? currentSystemPrompt ?? promptForConversation
                : systemPrompt(with: availableSkills.filter { skill in
                    skill.name.caseInsensitiveCompare("webbrowser") != .orderedSame
                })
            let replaySystemPrompt = addingICloudMountContext(to: replayBasePrompt)
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
            try Task.checkCancellation()
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
            if Task.isCancelled {
                await markActiveToolStatusStopped()
                currentNodeID = activeParentID
            } else {
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
            if let summaries = try? await store.loadSummaries() {
                conversations = summaries
            }
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

    private func loadPreview(for entry: CPSLFileEntry) async {
        let result = await service.previewFile(entry)
        if let preview = result.preview {
            filePreview = preview
            return
        }

        let message = result.error ?? "Preview is not available for this file."
        fileBrowserError = "\(entry.path): \(message)"
    }

    func appendErrorMessage(title: String?, body: String) {
        messages.append(CPSLChatMessage(role: .error, title: title, body: body))
    }

    func appendWebSearchVisit(_ visit: CPSLWebSearchVisit) {
        guard let nodeID = activeToolStatusNodeID,
              let store = activeToolStatusStore,
              var payload = activeToolStatusPayload
        else {
            return
        }
        payload.webVisits.append(visit)
        activeToolStatusPayload = payload
        let body = payload.encodedBody()
        if let messageID = UUID(uuidString: nodeID),
           let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].body = body
        }
        Task {
            try? await store.updateNodeBody(id: nodeID, body: body)
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
    let messages: [CPSLChatMessage]
}
#endif
