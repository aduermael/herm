import Combine
import Foundation
import WebKit
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
final class CPSLWebBrowserService: ObservableObject {
    @Published private(set) var visibleBrowserID: String?
    @Published private(set) var summaries: [CPSLWebBrowserSummary] = []
    @Published private(set) var isActivityActive = false

    var visibilityChanged: (@MainActor (Bool) -> Void)?
    var webVisitOccurred: (@MainActor (CPSLWebSearchVisit) -> Void)?

    private var browsers: [String: CPSLWebBrowserSession] = [:]
    private var lastBrowserID: String?
    private var sandboxRootURL: URL?
    private var leanRuleListTask: Task<WKContentRuleList?, Never>?
    private var activityClearTask: Task<Void, Never>?
    private let processPool = WKProcessPool()
    private let websiteDataStore = WKWebsiteDataStore.default()

    private let defaultWindowSize = CGSize(width: 900, height: 700)
    private let maxInlineJSONBytes = 16_000
    private let activityDuration: TimeInterval = 1.6

    var visibleWebView: WKWebView? {
        guard let visibleBrowserID else {
            return nil
        }
        return browsers[visibleBrowserID]?.webView
    }

    var visibleSummary: CPSLWebBrowserSummary? {
        guard let visibleBrowserID else {
            return nil
        }
        return summaries.first { $0.id == visibleBrowserID }
    }

    func setSandboxRoot(_ url: URL) {
        sandboxRootURL = url
    }

    func showLastBrowserFromUI() {
        if let visibleBrowserID, browsers[visibleBrowserID] != nil {
            Task {
                await showBrowserFromUI(id: visibleBrowserID)
            }
            return
        }
        if let lastBrowserID, browsers[lastBrowserID] != nil {
            Task {
                await showBrowserFromUI(id: lastBrowserID)
            }
            return
        }
        setOverlayVisible(true, browserID: nil)
    }

    func showBrowserFromUI(id: String) async {
        guard let browser = browsers[id],
              let shown = try? await browserForUserHandoff(browser)
        else {
            return
        }
        shown.isVisible = true
        setOverlayVisible(true, browserID: shown.id)
        refreshSummaries()
    }

    func hideOverlayFromUI() {
        if let visibleBrowserID {
            browsers[visibleBrowserID]?.isVisible = false
        }
        setOverlayVisible(false, browserID: nil)
    }

    func createBrowserFromUI() async {
        do {
            let browser = try await createBrowser(resourceMode: .full, networkPolicy: .unrestricted)
            browser.isVisible = true
            setOverlayVisible(true, browserID: browser.id)
            refreshSummaries()
        } catch {
            refreshSummaries()
        }
    }

    func closeBrowserFromUI(id: String) {
        browsers.removeValue(forKey: id)
        if lastBrowserID == id {
            lastBrowserID = browsers.keys.sorted().first
        }
        if visibleBrowserID == id {
            if let nextID = lastBrowserID, let browser = browsers[nextID] {
                browser.isVisible = true
                setOverlayVisible(true, browserID: nextID)
            } else {
                setOverlayVisible(false, browserID: nil)
            }
        }
        refreshSummaries()
    }

    func navigateVisibleBrowserFromUI(to address: String) async {
        guard let url = normalizedUserURL(address) else {
            return
        }
        let browser: CPSLWebBrowserSession
        if let visibleBrowserID, let visibleBrowser = browsers[visibleBrowserID] {
            browser = visibleBrowser
        } else {
            do {
                browser = try await createBrowser(resourceMode: .full, networkPolicy: .unrestricted)
                browser.isVisible = true
                setOverlayVisible(true, browserID: browser.id)
            } catch {
                refreshSummaries()
                return
            }
        }
        guard browser.networkPolicy.allows(url) else {
            return
        }
        markActivity()
        browser.webView.load(Self.browserRequest(for: url))
        browser.url = url.absoluteString
        lastBrowserID = browser.id
        refreshSummaries()
    }

    func goBackFromUI() {
        guard let visibleBrowserID, let browser = browsers[visibleBrowserID], browser.webView.canGoBack else {
            return
        }
        markActivity()
        browser.webView.goBack()
        refreshSummaries()
    }

    func goForwardFromUI() {
        guard let visibleBrowserID, let browser = browsers[visibleBrowserID], browser.webView.canGoForward else {
            return
        }
        markActivity()
        browser.webView.goForward()
        refreshSummaries()
    }

    func reloadFromUI() {
        guard let visibleBrowserID, let browser = browsers[visibleBrowserID] else {
            return
        }
        markActivity()
        browser.webView.reload()
        refreshSummaries()
    }

    func updateVisibleBrowserViewport(_ size: CGSize) {
        guard let visibleBrowserID, let browser = browsers[visibleBrowserID] else {
            return
        }
        updateBrowserViewport(browser, size: size)
    }

    func handleJSON(_ requestJSON: String) async -> String {
        do {
            let request = try CPSLWebBrowserRequest(json: requestJSON)
            markActivity()
            let response = try await handle(request)
            return encodeResponse(response)
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private func handle(_ request: CPSLWebBrowserRequest) async throws -> [String: Any] {
        switch request.command {
        case "browserCreate":
            let browser = try await createBrowser(
                resourceMode: request.resourceMode ?? .lean,
                networkPolicy: request.networkPolicy ?? .unrestricted
            )
            return success(browser: browser).merging(["message": "created"]) { _, new in new }

        case "browserList":
            refreshSummaries()
            return ["ok": true, "browsers": summaries.map(\.jsonObject)]

        case "browserRemove":
            try removeBrowsers(request)
            return ["ok": true, "message": "removed"]

        case "browserShow":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let shown = try await browserForUserHandoff(browser)
            shown.isVisible = true
            setOverlayVisible(true, browserID: shown.id)
            refreshSummaries()
            return success(browser: shown).merging(["message": "shown"]) { _, new in new }

        case "browserHide":
            let browser = try await requireBrowser(request.browser)
            browser.isVisible = false
            if visibleBrowserID == browser.id {
                setOverlayVisible(false, browserID: nil)
            }
            refreshSummaries()
            return success(browser: browser).merging(["message": "hidden"]) { _, new in new }

        case "browserResize":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            browser.windowSize = CGSize(
                width: CGFloat(request.windowWidth ?? Int(defaultWindowSize.width)),
                height: CGFloat(request.windowHeight ?? Int(defaultWindowSize.height))
            )
            browser.webView.frame = CGRect(origin: .zero, size: browser.windowSize)
            refreshSummaries()
            return success(browser: browser).merging(["message": "resized"]) { _, new in new }

        case "open":
            return try await open(request)

        case "page":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            if request.waitForResources {
                try await waitForResources(browser, timeout: request.resourceTimeout ?? 3)
            }
            let page = try await pageSnapshot(browser, request: request)
            return success(browser: browser).merging(["page": page]) { _, new in new }

        case "waitResources":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            try await waitForResources(browser, timeout: request.resourceTimeout ?? 3)
            let page = try await pageSnapshot(browser, request: request)
            return success(browser: browser).merging(["page": page]) { _, new in new }

        case "click":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let selector = try await selector(for: request.requiredAction(), in: browser)
            try await runActionJavaScript(clickScript(selector: selector), in: browser)
            try await settleAfterInteraction()
            let page = try await pageSnapshot(browser, request: request)
            return success(browser: browser).merging(["page": page]) { _, new in new }

        case "fill":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let selector = try await selector(for: request.requiredAction(), in: browser)
            try await runActionJavaScript(fillScript(selector: selector, value: request.value ?? ""), in: browser)
            try await settleAfterInteraction()
            let page = try await pageSnapshot(browser, request: request)
            return success(browser: browser).merging(["page": page]) { _, new in new }

        case "type":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let selector = try await selector(for: request.requiredAction(), in: browser)
            try await typeText(
                request.value ?? "",
                selector: selector,
                in: browser,
                options: try request.typingOptions()
            )
            try await settleAfterInteraction()
            let page = try await pageSnapshot(browser, request: request)
            return success(browser: browser).merging(["page": page]) { _, new in new }

        case "submit":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let selector = try await selector(for: request.requiredAction(), in: browser)
            try await runActionJavaScript(submitScript(selector: selector), in: browser)
            try await settleAfterInteraction()
            let page = try await pageSnapshot(browser, request: request)
            return success(browser: browser).merging(["page": page]) { _, new in new }

        case "coordinate":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            try await runCoordinateAction(request, in: browser)
            try await settleAfterInteraction()
            let page = try await pageSnapshot(browser, request: request)
            return success(browser: browser).merging(["page": page]) { _, new in new }

        case "eval":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let value = try await evaluateJavaScript(request.evalScript, in: browser)
            return success(browser: browser).merging(["value": renderedJavaScriptValue(value)]) { _, new in new }

        case "screenshot":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            if request.waitForResources {
                try await waitForResources(browser, timeout: request.resourceTimeout ?? 8)
            }
            let path = try request.requiredDestinationPath()
            try await writeScreenshot(browser, to: path, delay: request.screenshotDelay ?? 0.3)
            let displayPath = request.virtualDestinationPath ?? path
            return success(browser: browser).merging(["message": displayPath, "path": displayPath]) { _, new in new }

        default:
            throw CPSLWebBrowserError.message("unsupported webbrowser command \(request.command)")
        }
    }

    private func open(_ request: CPSLWebBrowserRequest) async throws -> [String: Any] {
        guard let rawURL = request.url?.trimmingCharacters(in: .whitespacesAndNewlines), !rawURL.isEmpty else {
            throw CPSLWebBrowserError.message("missing URL")
        }
        guard let url = URL(string: rawURL) else {
            throw CPSLWebBrowserError.message("invalid URL \(rawURL)")
        }

        let resourceMode = request.resourceMode ?? .lean
        let networkPolicy = request.networkPolicy ?? .unrestricted
        guard networkPolicy.allows(url) else {
            throw CPSLWebBrowserError.message("Network access is denied by policy")
        }
        let browser: CPSLWebBrowserSession
        if let id = request.browser {
            browser = try await browserForOpen(
                id: id,
                resourceMode: resourceMode,
                networkPolicy: networkPolicy
            )
        } else {
            browser = try await createBrowser(resourceMode: resourceMode, networkPolicy: networkPolicy)
        }

        browser.webView.load(Self.browserRequest(for: url))
        try await waitForDocumentReady(browser, timeout: 15)
        if request.waitForResources {
            try await waitForResources(browser, timeout: request.resourceTimeout ?? 8)
        }

        let page = try await pageSnapshot(browser)
        try validateNavigation(page: page, requestedURL: url)
        notifyWebVisit(browser: browser, page: page)
        return success(browser: browser).merging(["page": filteredPage(page, request: request)]) { _, new in new }
    }

    private func createBrowser(
        resourceMode: CPSLWebBrowserResourceMode,
        networkPolicy: CPSLWebBrowserNetworkPolicy
    ) async throws -> CPSLWebBrowserSession {
        let id = nextBrowserID()
        let browser = try await makeBrowser(
            id: id,
            resourceMode: resourceMode,
            windowSize: defaultWindowSize,
            networkPolicy: networkPolicy
        )
        browsers[id] = browser
        lastBrowserID = id
        refreshSummaries()
        return browser
    }

    private func makeBrowser(
        id: String,
        resourceMode: CPSLWebBrowserResourceMode,
        windowSize: CGSize,
        networkPolicy: CPSLWebBrowserNetworkPolicy
    ) async throws -> CPSLWebBrowserSession {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = processPool
        // Use the shared persistent WebKit store so cookies, local storage, and
        // logged-in browsing state survive across tabs and app launches.
        configuration.websiteDataStore = websiteDataStore
        let contentController = WKUserContentController()
        if resourceMode == .lean, let ruleList = await leanContentRuleList() {
            contentController.add(ruleList)
        }
        configuration.userContentController = contentController

        let webView = WKWebView(frame: CGRect(origin: .zero, size: windowSize), configuration: configuration)
        webView.customUserAgent = Self.safariUserAgent()
        webView.allowsBackForwardNavigationGestures = true
        let navigationDelegate = CPSLWebBrowserNavigationDelegate(
            policy: networkPolicy,
            onNavigationChanged: { [weak self] webView in
                self?.refreshBrowserNavigation(id: id, webView: webView)
            }
        )
        webView.navigationDelegate = navigationDelegate
        let uiDelegate = CPSLWebBrowserUIDelegate()
        webView.uiDelegate = uiDelegate
        return CPSLWebBrowserSession(
            id: id,
            resourceMode: resourceMode,
            webView: webView,
            windowSize: windowSize,
            networkPolicy: networkPolicy,
            navigationDelegate: navigationDelegate,
            uiDelegate: uiDelegate
        )
    }

    private func browserForOpen(
        id: String,
        resourceMode: CPSLWebBrowserResourceMode,
        networkPolicy: CPSLWebBrowserNetworkPolicy
    ) async throws -> CPSLWebBrowserSession {
        if let browser = browsers[id] {
            if browser.resourceMode == resourceMode {
                applyNetworkPolicy(networkPolicy, to: browser)
                lastBrowserID = id
                return browser
            }
            let replacement = try await replacementBrowser(
                for: browser,
                resourceMode: resourceMode,
                networkPolicy: networkPolicy
            )
            browsers[id] = replacement
            lastBrowserID = id
            refreshSummaries()
            return replacement
        }

        let browser = try await makeBrowser(
            id: id,
            resourceMode: resourceMode,
            windowSize: defaultWindowSize,
            networkPolicy: networkPolicy
        )
        browsers[id] = browser
        lastBrowserID = id
        refreshSummaries()
        return browser
    }

    private func browserForUserHandoff(_ browser: CPSLWebBrowserSession) async throws -> CPSLWebBrowserSession {
        guard browser.resourceMode == .lean else {
            return browser
        }
        let replacement = try await replacementBrowser(
            for: browser,
            resourceMode: .full,
            networkPolicy: browser.networkPolicy
        )
        browsers[browser.id] = replacement
        lastBrowserID = browser.id
        if let urlString = browser.url?.nilIfEmpty ?? browser.webView.url?.absoluteString.nilIfEmpty,
           let url = URL(string: urlString),
           replacement.networkPolicy.allows(url) {
            replacement.webView.load(Self.browserRequest(for: url))
            try? await waitForDocumentReady(replacement, timeout: 15)
        }
        refreshSummaries()
        return replacement
    }

    private func replacementBrowser(
        for browser: CPSLWebBrowserSession,
        resourceMode: CPSLWebBrowserResourceMode,
        networkPolicy: CPSLWebBrowserNetworkPolicy
    ) async throws -> CPSLWebBrowserSession {
        let replacement = try await makeBrowser(
            id: browser.id,
            resourceMode: resourceMode,
            windowSize: browser.windowSize,
            networkPolicy: networkPolicy
        )
        replacement.isVisible = browser.isVisible
        replacement.title = browser.title
        replacement.url = browser.url
        replacement.latestActions = browser.latestActions
        return replacement
    }

    private func requireBrowser(_ id: String?) async throws -> CPSLWebBrowserSession {
        guard let id, let browser = browsers[id] else {
            throw CPSLWebBrowserError.message("unknown browser \(id ?? "")")
        }
        lastBrowserID = id
        return browser
    }

    private func removeBrowsers(_ request: CPSLWebBrowserRequest) throws {
        let ids: [String]
        if request.allBrowsers {
            ids = Array(browsers.keys)
        } else {
            ids = request.browsers
        }
        guard !ids.isEmpty else {
            throw CPSLWebBrowserError.message("missing browser id")
        }
        for id in ids {
            browsers.removeValue(forKey: id)
        }
        if let visibleBrowserID, !browsers.keys.contains(visibleBrowserID) {
            setOverlayVisible(false, browserID: nil)
        }
        if let lastBrowserID, !browsers.keys.contains(lastBrowserID) {
            self.lastBrowserID = browsers.keys.sorted().first
        }
        refreshSummaries()
    }

    private func pageSnapshot(
        _ browser: CPSLWebBrowserSession,
        request: CPSLWebBrowserRequest? = nil
    ) async throws -> [String: Any] {
        let value = try await evaluateJavaScript(Self.pageSnapshotScript, in: browser)
        guard let json = value as? String,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CPSLWebBrowserError.message("page snapshot returned invalid JSON")
        }

        browser.title = object["title"] as? String
        browser.url = object["url"] as? String
        browser.latestActions = actionMap(from: object)
        refreshSummaries()

        var page = object
        page["browser"] = browser.id
        return filteredPage(page, request: request)
    }

    private func validateNavigation(page: [String: Any], requestedURL: URL) throws {
        let pageURL = (page["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard pageURL.isEmpty || pageURL == "about:blank" else {
            return
        }
        throw CPSLWebBrowserError.message(
            "navigation to \(requestedURL.absoluteString) did not commit; browser stayed on \(pageURL.nilIfEmpty ?? "a blank page")"
        )
    }

    private func actionMap(from page: [String: Any]) -> [String: CPSLWebBrowserAction] {
        guard let actions = page["actions"] as? [[String: Any]] else {
            return [:]
        }
        var byID: [String: CPSLWebBrowserAction] = [:]
        for action in actions {
            guard let id = action["id"] as? String,
                  let selector = action["selector"] as? String,
                  !selector.isEmpty
            else {
                continue
            }
            byID[id] = CPSLWebBrowserAction(id: id, selector: selector)
        }
        return byID
    }

    private func filteredPage(
        _ page: [String: Any],
        request: CPSLWebBrowserRequest?
    ) -> [String: Any] {
        var page = page
        if let actions = page["actions"] as? [[String: Any]] {
            page["actions"] = filteredActions(actions, request: request)
        }

        guard let fields = request?.fields, !fields.isEmpty else {
            return page
        }

        var filtered: [String: Any] = ["browser": page["browser"] ?? ""]
        for field in fields {
            if let value = page[field] {
                filtered[field] = value
            }
        }
        return filtered
    }

    private func filteredActions(
        _ actions: [[String: Any]],
        request: CPSLWebBrowserRequest?
    ) -> [[String: Any]] {
        let includeSelectors = request?.includeSelectors ?? true
        let includeDetails = request?.includeActionDetails ?? true
        return actions.map { action in
            var filtered = action
            if !includeDetails {
                filtered = [
                    "id": action["id"] ?? "",
                    "index": action["index"] ?? 0,
                    "label": action["label"] ?? "",
                    "tag": action["tag"] ?? "",
                    "type": action["type"] ?? "",
                ]
            }
            if !includeSelectors {
                filtered.removeValue(forKey: "selector")
            }
            return filtered
        }
    }

    private func updateBrowserViewport(_ browser: CPSLWebBrowserSession, size: CGSize) {
        guard size.width > 1, size.height > 1 else {
            return
        }
        browser.windowSize = size
        browser.webView.frame = CGRect(origin: .zero, size: size)
        refreshSummaries()
    }

    private func refreshBrowserNavigation(id: String, webView: WKWebView) {
        guard let browser = browsers[id], browser.webView === webView else {
            return
        }
        browser.title = webView.title
        browser.url = webView.url?.absoluteString
        refreshSummaries()
    }

    private func applyNetworkPolicy(from request: CPSLWebBrowserRequest, to browser: CPSLWebBrowserSession) {
        guard let networkPolicy = request.networkPolicy else {
            return
        }
        applyNetworkPolicy(networkPolicy, to: browser)
    }

    private func applyNetworkPolicy(
        _ networkPolicy: CPSLWebBrowserNetworkPolicy,
        to browser: CPSLWebBrowserSession
    ) {
        browser.networkPolicy = networkPolicy
        browser.navigationDelegate.policy = networkPolicy
    }

    private func selector(for action: String, in browser: CPSLWebBrowserSession) async throws -> String {
        if browser.latestActions.isEmpty {
            _ = try await pageSnapshot(browser)
        }
        if let action = browser.latestActions[action] {
            return action.selector
        }
        return action
    }

    private func runActionJavaScript(_ script: String, in browser: CPSLWebBrowserSession) async throws {
        let value = try await evaluateJavaScript(script, in: browser)
        guard let json = value as? String,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CPSLWebBrowserError.message("browser action returned invalid JSON")
        }
        if object["ok"] as? Bool == false {
            throw CPSLWebBrowserError.message(object["error"] as? String ?? "browser action failed")
        }
    }

    private func typeText(
        _ text: String,
        selector: String,
        in browser: CPSLWebBrowserSession,
        options: CPSLWebBrowserTypingOptions
    ) async throws {
        try await runActionJavaScript(clearAndFocusScript(selector: selector), in: browser)
        switch options.backend {
        case .native:
            #if os(macOS)
            if browser.webView.window == nil {
                try await typeTextWithJavaScript(text, selector: selector, in: browser, options: options)
            } else {
                try await typeTextWithNativeEvents(text, in: browser, options: options)
            }
            #else
            try await typeTextWithJavaScript(text, selector: selector, in: browser, options: options)
            #endif
        case .javaScript:
            try await typeTextWithJavaScript(text, selector: selector, in: browser, options: options)
        }
    }

    private func typeTextWithJavaScript(
        _ text: String,
        selector: String,
        in browser: CPSLWebBrowserSession,
        options: CPSLWebBrowserTypingOptions
    ) async throws {
        var previousCharacter: Character?
        for character in text {
            try await sleepForTyping(options: options, after: previousCharacter)
            try await runActionJavaScript(appendTextScript(selector: selector, value: String(character)), in: browser)
            previousCharacter = character
        }
    }

    #if os(macOS)
    private func typeTextWithNativeEvents(
        _ text: String,
        in browser: CPSLWebBrowserSession,
        options: CPSLWebBrowserTypingOptions
    ) async throws {
        browser.webView.window?.makeFirstResponder(browser.webView)
        _ = browser.webView.becomeFirstResponder()
        var previousCharacter: Character?
        for character in text {
            try await sleepForTyping(options: options, after: previousCharacter)
            try sendNativeKey(String(character), to: browser.webView)
            previousCharacter = character
        }
    }

    private func sendNativeKey(_ text: String, to webView: WKWebView) throws {
        let key = CPSLWebBrowserNativeKey(text)
        let windowNumber = webView.window?.windowNumber ?? 0
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: key.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: key.keyCode
            ),
            let up = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: key.modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                characters: key.characters,
                charactersIgnoringModifiers: key.charactersIgnoringModifiers,
                isARepeat: false,
                keyCode: key.keyCode
            )
        else {
            throw CPSLWebBrowserError.message("could not create native key event")
        }
        webView.keyDown(with: down)
        webView.keyUp(with: up)
    }
    #endif

    private func sleepForTyping(
        options: CPSLWebBrowserTypingOptions,
        after previousCharacter: Character?
    ) async throws {
        let baseDelay = Double.random(in: options.delayMin...options.delayMax)
        let multiplier = options.rhythm == .natural ? naturalDelayMultiplier(after: previousCharacter) : 1
        let delay = min(CPSLWebBrowserTypingOptions.maxDelay, baseDelay * multiplier / options.speed)
        try await Task.sleep(nanoseconds: UInt64(max(0.001, delay) * 1_000_000_000))
    }

    private func naturalDelayMultiplier(after character: Character?) -> Double {
        guard let character else {
            return 1
        }
        let text = String(character)
        if text == "\n" || text == "\r" {
            return Double.random(in: 3...4.5)
        }
        if ".!?".contains(text) {
            return Double.random(in: 2.6...4)
        }
        if ",;:".contains(text) {
            return Double.random(in: 1.8...2.7)
        }
        if character.isWhitespace {
            return Double.random(in: 1.25...1.9)
        }
        return Double.random(in: 0.85...1.2)
    }

    private func runCoordinateAction(_ request: CPSLWebBrowserRequest, in browser: CPSLWebBrowserSession) async throws {
        let action = request.coordinateAction ?? "click"
        let x = request.x ?? 0
        let y = request.y ?? 0
        if action == "scroll" {
            let script = scrollScript(
                x: x,
                y: y,
                deltaX: request.deltaX ?? 0,
                deltaY: request.deltaY ?? 0
            )
            try await runActionJavaScript(script, in: browser)
            return
        }
        try await runActionJavaScript(coordinateScript(action: action, x: x, y: y), in: browser)
    }

    private func waitForDocumentReady(_ browser: CPSLWebBrowserSession, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let readyState = try? await evaluateJavaScript("document.readyState", in: browser) as? String,
               readyState == "interactive" || readyState == "complete" {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func waitForResources(_ browser: CPSLWebBrowserSession, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        var lastSignature: String?
        var quietSince: Date?
        while Date() < deadline {
            let status = try? await evaluateJavaScript(Self.resourceStatusScript, in: browser) as? String
            if status == lastSignature {
                if quietSince == nil {
                    quietSince = Date()
                }
                if let quietSince, Date().timeIntervalSince(quietSince) >= 0.35 {
                    return
                }
            } else {
                lastSignature = status
                quietSince = nil
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func settleAfterInteraction() async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private func writeScreenshot(
        _ browser: CPSLWebBrowserSession,
        to path: String,
        delay: TimeInterval
    ) async throws {
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: browser.windowSize)
        let image = try await snapshot(browser.webView, configuration: configuration)
        let data = try imageData(image, path: path)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func snapshot(
        _ webView: WKWebView,
        configuration: WKSnapshotConfiguration
    ) async throws -> CPSLPlatformImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CPSLWebBrowserError.message("screenshot returned no image"))
                }
            }
        }
    }

    private func evaluateJavaScript(_ script: String, in browser: CPSLWebBrowserSession) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            browser.webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    private func renderedJavaScriptValue(_ value: Any?) -> String {
        guard let value else {
            return "null"
        }
        if let string = value as? String {
            return string
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: value)
    }

    private func leanContentRuleList() async -> WKContentRuleList? {
        if let leanRuleListTask {
            return await leanRuleListTask.value
        }
        let task = Task<WKContentRuleList?, Never> {
            await Self.compileLeanContentRuleList()
        }
        leanRuleListTask = task
        return await task.value
    }

    private nonisolated static func compileLeanContentRuleList() async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "herm-webbrowser-lean-resource-mode-v1",
                encodedContentRuleList: Self.leanContentRuleListJSON
            ) { ruleList, _ in
                continuation.resume(returning: ruleList)
            }
        }
    }

    private func success(browser: CPSLWebBrowserSession) -> [String: Any] {
        [
            "ok": true,
            "browser": browser.id,
            "resourceMode": browser.resourceMode.rawValue,
            "url": browser.url ?? browser.webView.url?.absoluteString ?? "",
        ]
    }

    private func refreshSummaries() {
        summaries = browsers.values
            .map { $0.summary }
            .sorted { lhs, rhs in
                lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
    }

    private func setOverlayVisible(_ isVisible: Bool, browserID: String?) {
        visibleBrowserID = browserID
        visibilityChanged?(isVisible)
    }

    private func markActivity() {
        activityClearTask?.cancel()
        isActivityActive = true
        let duration = activityDuration
        activityClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await MainActor.run {
                guard !Task.isCancelled else {
                    return
                }
                self?.isActivityActive = false
            }
        }
    }

    private func notifyWebVisit(browser: CPSLWebBrowserSession, page: [String: Any]) {
        let pageURL = (page["url"] as? String)?.nilIfEmpty
            ?? browser.url?.nilIfEmpty
            ?? browser.webView.url?.absoluteString
            ?? ""
        guard !pageURL.isEmpty else {
            return
        }
        let title = (page["title"] as? String)?.nilIfEmpty
            ?? browser.title?.nilIfEmpty
            ?? browser.webView.title?.nilIfEmpty
            ?? pageURL
        let host = URL(string: pageURL)?.host ?? pageURL
        let faviconURL = faviconURL(pageURL: pageURL, rawIconURL: page["faviconURL"] as? String)
        webVisitOccurred?(
            CPSLWebSearchVisit(
                browserID: browser.id,
                url: pageURL,
                title: title,
                host: host,
                faviconURL: faviconURL
            )
        )
    }

    private func faviconURL(pageURL: String, rawIconURL: String?) -> String? {
        guard let baseURL = URL(string: pageURL) else {
            return nil
        }
        if let rawIconURL = rawIconURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawIconURL.isEmpty,
           let iconURL = URL(string: rawIconURL, relativeTo: baseURL)?.absoluteURL {
            return iconURL.absoluteString
        }
        guard let scheme = baseURL.scheme, let host = baseURL.host else {
            return nil
        }
        return "\(scheme)://\(host)/favicon.ico"
    }

    private func normalizedUserURL(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if trimmed.contains(".") && !trimmed.contains(" ") {
            return URL(string: "https://\(trimmed)")
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    private func encodeResponse(_ response: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            if data.count > maxInlineJSONBytes,
               let compact = try saveFullResponse(data, response: response) {
                let compactData = try JSONSerialization.data(withJSONObject: compact, options: [.sortedKeys])
                return String(decoding: compactData, as: UTF8.self)
            }
            return String(decoding: data, as: UTF8.self)
        } catch {
            return errorJSON(error.localizedDescription)
        }
    }

    private func saveFullResponse(_ data: Data, response: [String: Any]) throws -> [String: Any]? {
        guard let sandboxRootURL else {
            return nil
        }
        let tmpURL = sandboxRootURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        let fileName = "webbrowser-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
        let fileURL = tmpURL.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: fileURL, options: .atomic)

        var compact: [String: Any] = [
            "ok": response["ok"] ?? true,
            "message": "full webbrowser response saved to /tmp/\(fileName)",
            "fullJSONPath": "/tmp/\(fileName)",
            "jsonBytes": data.count,
        ]
        if let browser = response["browser"] {
            compact["browser"] = browser
        }
        if let page = response["page"] as? [String: Any] {
            compact["page"] = [
                "browser": page["browser"] ?? response["browser"] ?? "",
                "title": page["title"] ?? "",
                "url": page["url"] ?? "",
                "textPreview": String((page["text"] as? String ?? "").prefix(2000)),
                "actions": page["actions"] ?? [],
                "resourceCount": page["resourceCount"] ?? 0,
            ]
        }
        return compact
    }

    private func errorJSON(_ message: String) -> String {
        let object: [String: Any] = ["ok": false, "error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"ok":false,"error":"webbrowser error"}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func nextBrowserID() -> String {
        var candidate: String
        repeat {
            candidate = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        } while browsers[candidate] != nil
        return candidate
    }

    nonisolated fileprivate static func browserRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        #if os(macOS)
        if #available(macOS 14.0, *) {
            request.attribution = .user
        }
        #elseif os(iOS)
        if #available(iOS 17.0, *) {
            request.attribution = .user
        }
        #endif
        return request
    }

    private static func safariUserAgent() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let safariVersion = "\(version.majorVersion).\(version.minorVersion)"
        #if os(macOS)
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(safariVersion) Safari/605.1.15"
        #elseif canImport(UIKit)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let osComponents = version.patchVersion > 0
            ? [version.majorVersion, version.minorVersion, version.patchVersion]
            : [version.majorVersion, version.minorVersion]
        let osVersion = osComponents
            .map(String.init)
            .joined(separator: "_")
        let cpuToken = device == "iPad" ? "CPU OS" : "CPU iPhone OS"
        return "Mozilla/5.0 (\(device); \(cpuToken) \(osVersion) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(safariVersion) Mobile/15E148 Safari/604.1"
        #else
        return "Mozilla/5.0 AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
        #endif
    }
}

private final class CPSLWebBrowserSession {
    let id: String
    var resourceMode: CPSLWebBrowserResourceMode
    let webView: WKWebView
    var windowSize: CGSize
    var latestActions: [String: CPSLWebBrowserAction] = [:]
    var title: String?
    var url: String?
    var isVisible = false
    var networkPolicy: CPSLWebBrowserNetworkPolicy
    let navigationDelegate: CPSLWebBrowserNavigationDelegate
    let uiDelegate: CPSLWebBrowserUIDelegate

    init(
        id: String,
        resourceMode: CPSLWebBrowserResourceMode,
        webView: WKWebView,
        windowSize: CGSize,
        networkPolicy: CPSLWebBrowserNetworkPolicy,
        navigationDelegate: CPSLWebBrowserNavigationDelegate,
        uiDelegate: CPSLWebBrowserUIDelegate
    ) {
        self.id = id
        self.resourceMode = resourceMode
        self.webView = webView
        self.windowSize = windowSize
        self.networkPolicy = networkPolicy
        self.navigationDelegate = navigationDelegate
        self.uiDelegate = uiDelegate
    }

    var summary: CPSLWebBrowserSummary {
        CPSLWebBrowserSummary(
            id: id,
            title: title ?? webView.title,
            url: url ?? webView.url?.absoluteString,
            resourceMode: resourceMode,
            isVisible: isVisible,
            canGoBack: webView.canGoBack,
            canGoForward: webView.canGoForward,
            isLoading: webView.isLoading
        )
    }
}

struct CPSLWebBrowserSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String?
    let url: String?
    let resourceMode: CPSLWebBrowserResourceMode
    let isVisible: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let isLoading: Bool

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "browser": id,
            "resourceMode": resourceMode.rawValue,
            "canGoBack": canGoBack,
            "canGoForward": canGoForward,
            "loading": isLoading,
            "visible": isVisible,
        ]
        if let title {
            object["title"] = title
        }
        if let url {
            object["url"] = url
        }
        return object
    }
}

enum CPSLWebBrowserResourceMode: String, Equatable, Sendable {
    case full
    case lean
}

private struct CPSLWebBrowserNetworkPolicy: Equatable, Sendable {
    static let unrestricted = CPSLWebBrowserNetworkPolicy(allowDomains: ["*"], denyDomains: [])

    let allowDomains: [String]
    let denyDomains: [String]

    static func parse(_ value: Any?) throws -> CPSLWebBrowserNetworkPolicy? {
        guard let object = value as? [String: Any] else {
            return nil
        }
        return CPSLWebBrowserNetworkPolicy(
            allowDomains: try stringArray(
                object["allowDomains"] ?? object["allow_domains"],
                field: "networkPolicy.allowDomains"
            ),
            denyDomains: try stringArray(
                object["denyDomains"] ?? object["deny_domains"],
                field: "networkPolicy.denyDomains"
            )
        )
    }

    func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else {
            return false
        }
        return !Self.matches(host, entries: denyDomains)
            && Self.matches(host, entries: allowDomains)
    }

    func allowsNavigationAction(_ navigationAction: WKNavigationAction) -> Bool {
        guard let url = navigationAction.request.url else {
            return true
        }
        if Self.isBrowserInternal(url) {
            return true
        }
        return allows(url)
    }

    private static func matches(_ host: String, entries: [String]) -> Bool {
        entries.contains { entry in
            entry == "*" || host == entry || host.hasSuffix(".\(entry)")
        }
    }

    private static func isBrowserInternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return true
        }
        return scheme == "about" || scheme == "blob" || scheme == "data"
    }

    private static func stringArray(_ value: Any?, field: String) throws -> [String] {
        guard let value else {
            return []
        }
        guard let strings = value as? [String] else {
            throw CPSLWebBrowserError.message("\(field) must be an array of strings")
        }
        return strings
    }
}

private final class CPSLWebBrowserNavigationDelegate: NSObject, WKNavigationDelegate {
    var policy: CPSLWebBrowserNetworkPolicy
    let onNavigationChanged: @MainActor (WKWebView) -> Void

    init(
        policy: CPSLWebBrowserNetworkPolicy,
        onNavigationChanged: @escaping @MainActor (WKWebView) -> Void
    ) {
        self.policy = policy
        self.onNavigationChanged = onNavigationChanged
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.request.url != nil else {
            decisionHandler(.cancel)
            return
        }
        if policy.allowsNavigationAction(navigationAction) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        notifyNavigationChanged(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        notifyNavigationChanged(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        notifyNavigationChanged(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        notifyNavigationChanged(webView)
    }

    private func notifyNavigationChanged(_ webView: WKWebView) {
        Task { @MainActor in
            onNavigationChanged(webView)
        }
    }
}

private final class CPSLWebBrowserUIDelegate: NSObject, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url
        else {
            return nil
        }
        webView.load(CPSLWebBrowserService.browserRequest(for: url))
        return nil
    }
}

private enum CPSLWebBrowserTypingBackend: String, Equatable, Sendable {
    case javaScript = "js"
    case native

    static func parse(_ value: String) throws -> CPSLWebBrowserTypingBackend {
        switch value.lowercased() {
        case "js":
            return .javaScript
        case "native":
            return .native
        default:
            throw CPSLWebBrowserError.message("unknown typing backend \(value)")
        }
    }
}

private enum CPSLWebBrowserTypingRhythm: String, Equatable, Sendable {
    case flat
    case natural

    static func parse(_ value: String) throws -> CPSLWebBrowserTypingRhythm {
        switch value.lowercased() {
        case "flat":
            return .flat
        case "natural":
            return .natural
        default:
            throw CPSLWebBrowserError.message("unknown typing rhythm \(value)")
        }
    }
}

private struct CPSLWebBrowserTypingOptions: Sendable {
    static let defaultDelayMin: TimeInterval = 0.03
    static let defaultDelayMax: TimeInterval = 0.12
    static let defaultSpeed = 4.0
    static let maxDelay: TimeInterval = 5

    let backend: CPSLWebBrowserTypingBackend
    let rhythm: CPSLWebBrowserTypingRhythm
    let speed: Double
    let delayMin: TimeInterval
    let delayMax: TimeInterval

    init(
        backend: CPSLWebBrowserTypingBackend,
        rhythm: CPSLWebBrowserTypingRhythm,
        speed: Double?,
        delayMin: TimeInterval?,
        delayMax: TimeInterval?
    ) throws {
        let normalizedSpeed = speed ?? Self.defaultSpeed
        guard normalizedSpeed.isFinite, normalizedSpeed > 0 else {
            throw CPSLWebBrowserError.message("invalid typing speed \(normalizedSpeed)")
        }
        let minDelay = delayMin ?? delayMax.map { min(Self.defaultDelayMin, $0) } ?? Self.defaultDelayMin
        let maxDelay = delayMax ?? delayMin.map { max($0, Self.defaultDelayMax) } ?? Self.defaultDelayMax
        guard minDelay.isFinite, minDelay >= 0, minDelay <= Self.maxDelay else {
            throw CPSLWebBrowserError.message("invalid typing delay minimum \(minDelay)")
        }
        guard maxDelay.isFinite, maxDelay >= 0, maxDelay <= Self.maxDelay else {
            throw CPSLWebBrowserError.message("invalid typing delay maximum \(maxDelay)")
        }
        guard minDelay <= maxDelay else {
            throw CPSLWebBrowserError.message("typing delay minimum must be less than or equal to maximum")
        }

        self.backend = backend
        self.rhythm = rhythm
        self.speed = normalizedSpeed
        self.delayMin = minDelay
        self.delayMax = maxDelay
    }
}

private struct CPSLWebBrowserAction {
    let id: String
    let selector: String
}

private struct CPSLWebBrowserRequest {
    let command: String
    let browser: String?
    let browsers: [String]
    let allBrowsers: Bool
    let resourceMode: CPSLWebBrowserResourceMode?
    let url: String?
    let action: String?
    let value: String?
    let destinationPath: String?
    let virtualDestinationPath: String?
    let coordinateAction: String?
    let x: Double?
    let y: Double?
    let deltaX: Double?
    let deltaY: Double?
    let waitForResources: Bool
    let resourceTimeout: TimeInterval?
    let screenshotDelay: TimeInterval?
    let script: String?
    let functionBody: Bool
    let typingSpeed: Double?
    let typingBackend: CPSLWebBrowserTypingBackend?
    let typingRhythm: CPSLWebBrowserTypingRhythm?
    let typingDelayMin: TimeInterval?
    let typingDelayMax: TimeInterval?
    let windowWidth: Int?
    let windowHeight: Int?
    let fields: [String]?
    let includeSelectors: Bool?
    let includeActionDetails: Bool?
    let networkPolicy: CPSLWebBrowserNetworkPolicy?

    init(json: String) throws {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String
        else {
            throw CPSLWebBrowserError.message("invalid webbrowser request JSON")
        }

        self.command = command
        browser = object["browser"] as? String
        browsers = object["browsers"] as? [String] ?? []
        allBrowsers = object["allBrowsers"] as? Bool ?? false
        if let rawMode = object["resourceMode"] as? String {
            resourceMode = CPSLWebBrowserResourceMode(rawValue: rawMode)
        } else {
            resourceMode = nil
        }
        url = object["url"] as? String
        action = object["action"] as? String
        value = object["value"] as? String
        destinationPath = object["destinationPath"] as? String
        virtualDestinationPath = object["virtualDestinationPath"] as? String
        coordinateAction = object["coordinateAction"] as? String
        x = Self.doubleValue(object["x"])
        y = Self.doubleValue(object["y"])
        deltaX = Self.doubleValue(object["deltaX"])
        deltaY = Self.doubleValue(object["deltaY"])
        waitForResources = object["waitForResources"] as? Bool ?? false
        resourceTimeout = Self.doubleValue(object["resourceTimeout"])
        screenshotDelay = Self.doubleValue(object["screenshotDelay"])
        script = object["script"] as? String
        functionBody = object["functionBody"] as? Bool ?? false
        typingSpeed = Self.doubleValue(object["typingSpeed"])
        if let rawBackend = object["typingBackend"] as? String {
            typingBackend = try CPSLWebBrowserTypingBackend.parse(rawBackend)
        } else {
            typingBackend = nil
        }
        if let rawRhythm = object["typingRhythm"] as? String {
            typingRhythm = try CPSLWebBrowserTypingRhythm.parse(rawRhythm)
        } else {
            typingRhythm = nil
        }
        typingDelayMin = Self.doubleValue(object["typingDelayMin"])
        typingDelayMax = Self.doubleValue(object["typingDelayMax"])
        windowWidth = Self.intValue(object["windowWidth"])
        windowHeight = Self.intValue(object["windowHeight"])
        fields = try Self.stringList(object["fields"], field: "fields")
        includeSelectors = object["selectors"] as? Bool
        includeActionDetails = object["actionDetails"] as? Bool
        networkPolicy = try CPSLWebBrowserNetworkPolicy.parse(object["networkPolicy"])
    }

    var evalScript: String {
        guard let script else {
            return ""
        }
        if functionBody {
            return "(function(){\(script)})()"
        }
        return script
    }

    func requiredAction() throws -> String {
        guard let action, !action.isEmpty else {
            throw CPSLWebBrowserError.message("missing action")
        }
        return action
    }

    func requiredDestinationPath() throws -> String {
        guard let destinationPath, !destinationPath.isEmpty else {
            throw CPSLWebBrowserError.message("missing screenshot destination")
        }
        return destinationPath
    }

    func typingOptions() throws -> CPSLWebBrowserTypingOptions {
        try CPSLWebBrowserTypingOptions(
            backend: typingBackend ?? .native,
            rhythm: typingRhythm ?? .natural,
            speed: typingSpeed,
            delayMin: typingDelayMin,
            delayMax: typingDelayMax
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func stringList(_ value: Any?, field: String) throws -> [String]? {
        guard let value else {
            return nil
        }
        if let value = value as? String {
            return [value]
        }
        if let values = value as? [String] {
            return values
        }
        if let values = value as? [Any] {
            return try values.map { item in
                guard let string = item as? String else {
                    throw CPSLWebBrowserError.message("\(field) must contain only strings")
                }
                return string
            }
        }
        throw CPSLWebBrowserError.message("\(field) must be a string or array of strings")
    }
}

private enum CPSLWebBrowserError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

private extension CPSLWebBrowserService {
    static let leanContentRuleListJSON = """
    [
      {
        "trigger": {
          "url-filter": ".*",
          "resource-type": ["image", "media", "font"]
        },
        "action": {
          "type": "block"
        }
      }
    ]
    """

    static let resourceStatusScript = """
    JSON.stringify({
      readyState: document.readyState,
      loading: document.readyState !== "complete",
      resources: performance.getEntriesByType("resource").length
    })
    """

    static let pageSnapshotScript = """
    (() => {
      function cssEscape(value) {
        if (window.CSS && CSS.escape) return CSS.escape(value);
        return String(value).replace(/[^a-zA-Z0-9_-]/g, "\\\\$&");
      }
      function selectorFor(element) {
        if (element.id) return "#" + cssEscape(element.id);
        const parts = [];
        let current = element;
        while (current && current.nodeType === 1 && current !== document.documentElement && parts.length < 6) {
          let part = current.localName.toLowerCase();
          const parent = current.parentElement;
          if (parent) {
            const siblings = Array.from(parent.children).filter((sibling) => sibling.localName === current.localName);
            if (siblings.length > 1) part += ":nth-of-type(" + (siblings.indexOf(current) + 1) + ")";
          }
          parts.unshift(part);
          current = parent;
        }
        return parts.join(" > ");
      }
      function labelFor(element) {
        return (
          element.getAttribute("aria-label") ||
          element.getAttribute("title") ||
          element.getAttribute("placeholder") ||
          element.innerText ||
          element.value ||
          element.href ||
          element.name ||
          element.id ||
          element.localName ||
          ""
        ).trim().replace(/\\s+/g, " ").slice(0, 240);
      }
      function isVisible(element) {
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.visibility !== "hidden" && style.display !== "none" && rect.width > 0 && rect.height > 0;
      }
      const candidates = Array.from(document.querySelectorAll(
        "a[href],button,input,textarea,select,[role='button'],[role='link'],[contenteditable='true']"
      ));
      const actions = [];
      for (const element of candidates) {
        if (!isVisible(element)) continue;
        const rect = element.getBoundingClientRect();
        const id = "a" + (actions.length + 1);
        actions.push({
          id,
          index: actions.length + 1,
          tag: element.localName,
          type: element.getAttribute("type") || element.getAttribute("role") || "",
          label: labelFor(element),
          text: (element.innerText || "").trim().replace(/\\s+/g, " ").slice(0, 240),
          href: element.href || "",
          selector: selectorFor(element),
          x: Math.round(rect.left + rect.width / 2),
          y: Math.round(rect.top + rect.height / 2),
          width: Math.round(rect.width),
          height: Math.round(rect.height)
        });
        if (actions.length >= 120) break;
      }
      const resources = performance.getEntriesByType("resource").slice(-80).map((entry, index) => ({
        index: index + 1,
        type: entry.initiatorType || "resource",
        url: entry.name
      }));
      const iconElement = document.querySelector(
        "link[rel~='icon'],link[rel='shortcut icon'],link[rel='apple-touch-icon']"
      );
      const html = document.documentElement ? document.documentElement.outerHTML : "";
      const text = document.body ? document.body.innerText || "" : "";
      return JSON.stringify({
        title: document.title || "",
        url: location.href,
        faviconURL: iconElement ? iconElement.href || "" : "",
        text,
        actions,
        resources,
        resourceCount: performance.getEntriesByType("resource").length,
        htmlBytes: html.length,
        textBytes: text.length,
        loading: document.readyState !== "complete",
        readyState: document.readyState
      });
    })()
    """

    func clickScript(selector: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        return """
        (() => {
          const element = document.querySelector(\(selector));
          if (!element) return JSON.stringify({ok:false,error:"action not found"});
          element.scrollIntoView({block:"center", inline:"center"});
          if (element.focus) element.focus({preventScroll:true});
          element.click();
          return JSON.stringify({ok:true});
        })()
        """
    }

    func fillScript(selector: String, value: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        let value = try Self.javaScriptLiteral(value)
        return """
        (() => {
          const element = document.querySelector(\(selector));
          if (!element) return JSON.stringify({ok:false,error:"action not found"});
          element.scrollIntoView({block:"center", inline:"center"});
          if (element.focus) element.focus({preventScroll:true});
          if ("value" in element) {
            element.value = \(value);
          } else {
            element.textContent = \(value);
          }
          element.dispatchEvent(new Event("input", {bubbles:true}));
          element.dispatchEvent(new Event("change", {bubbles:true}));
          return JSON.stringify({ok:true});
        })()
        """
    }

    func clearAndFocusScript(selector: String) throws -> String {
        try fillScript(selector: selector, value: "")
    }

    func appendTextScript(selector: String, value: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        let value = try Self.javaScriptLiteral(value)
        return """
        (() => {
          const element = document.querySelector(\(selector));
          if (!element) return JSON.stringify({ok:false,error:"action not found"});
          const textValue = \(value);
          const key = textValue === "\\n" ? "Enter" : textValue;
          const keyCode = key === "Enter" ? 13 : (key.length === 1 ? key.codePointAt(0) : 0);
          const keyboardOptions = {bubbles:true, cancelable:true, key, code:key.length === 1 ? "" : key, keyCode, which:keyCode};
          if (element.focus) element.focus({preventScroll:true});
          if (!element.dispatchEvent(new KeyboardEvent("keydown", keyboardOptions))) {
            element.dispatchEvent(new KeyboardEvent("keyup", keyboardOptions));
            return JSON.stringify({ok:true});
          }
          element.dispatchEvent(new KeyboardEvent("keypress", keyboardOptions));
          if (window.InputEvent) {
            element.dispatchEvent(new InputEvent("beforeinput", {bubbles:true, cancelable:true, data:textValue, inputType:"insertText"}));
          }
          if ("value" in element) {
            element.value = (element.value || "") + textValue;
          } else {
            element.textContent = (element.textContent || "") + textValue;
          }
          if (window.InputEvent) {
            element.dispatchEvent(new InputEvent("input", {bubbles:true, data:textValue, inputType:"insertText"}));
          } else {
            element.dispatchEvent(new Event("input", {bubbles:true}));
          }
          element.dispatchEvent(new Event("change", {bubbles:true}));
          element.dispatchEvent(new KeyboardEvent("keyup", keyboardOptions));
          return JSON.stringify({ok:true});
        })()
        """
    }

    func submitScript(selector: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        return """
        (() => {
          const element = document.querySelector(\(selector));
          if (!element) return JSON.stringify({ok:false,error:"action not found"});
          const form = element.form || element.closest("form");
          if (form && form.requestSubmit) form.requestSubmit();
          else if (form) form.submit();
          else element.click();
          return JSON.stringify({ok:true});
        })()
        """
    }

    func coordinateScript(action: String, x: Double, y: Double) throws -> String {
        let action = try Self.javaScriptLiteral(action)
        return """
        (() => {
          const x = \(x);
          const y = \(y);
          const element = document.elementFromPoint(x, y);
          if (!element) return JSON.stringify({ok:false,error:"no element at coordinate"});
          const type = \(action);
          const eventType = type === "press" ? "mousedown" : (type === "release" ? "mouseup" : (type === "drag" ? "mousemove" : "click"));
          element.dispatchEvent(new MouseEvent(eventType, {bubbles:true, cancelable:true, clientX:x, clientY:y, view:window}));
          if (type === "click" && element.click) element.click();
          return JSON.stringify({ok:true});
        })()
        """
    }

    func scrollScript(x: Double, y: Double, deltaX: Double, deltaY: Double) -> String {
        """
        (() => {
          const element = document.elementFromPoint(\(x), \(y));
          if (element) {
            element.dispatchEvent(new WheelEvent("wheel", {bubbles:true, cancelable:true, clientX:\(x), clientY:\(y), deltaX:\(deltaX), deltaY:\(deltaY)}));
          }
          window.scrollBy(\(deltaX), \(deltaY));
          return JSON.stringify({ok:true});
        })()
        """
    }

    static func javaScriptLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

#if os(macOS)
private typealias CPSLPlatformImage = NSImage

private func imageData(_ image: NSImage, path: String) throws -> Data {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff)
    else {
        throw CPSLWebBrowserError.message("could not encode screenshot")
    }
    if path.lowercased().hasSuffix(".jpg") || path.lowercased().hasSuffix(".jpeg") {
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw CPSLWebBrowserError.message("could not encode JPEG screenshot")
        }
        return data
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CPSLWebBrowserError.message("could not encode PNG screenshot")
    }
    return data
}
#elseif canImport(UIKit)
private typealias CPSLPlatformImage = UIImage

private func imageData(_ image: UIImage, path: String) throws -> Data {
    if path.lowercased().hasSuffix(".jpg") || path.lowercased().hasSuffix(".jpeg") {
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            throw CPSLWebBrowserError.message("could not encode JPEG screenshot")
        }
        return data
    }
    guard let data = image.pngData() else {
        throw CPSLWebBrowserError.message("could not encode PNG screenshot")
    }
    return data
}
#endif

#if os(macOS)
private struct CPSLWebBrowserNativeKey {
    let characters: String
    let charactersIgnoringModifiers: String
    let modifiers: NSEvent.ModifierFlags
    let keyCode: UInt16

    init(_ text: String) {
        switch text {
        case "\n", "\r":
            characters = "\r"
            charactersIgnoringModifiers = "\r"
            modifiers = []
            keyCode = 36
        case "\t":
            characters = "\t"
            charactersIgnoringModifiers = "\t"
            modifiers = []
            keyCode = 48
        default:
            let lower = text.lowercased()
            characters = text
            charactersIgnoringModifiers = lower
            modifiers = text.count == 1 && text == text.uppercased() && text != lower ? [.shift] : []
            keyCode = Self.keyCodes[lower] ?? 0
        }
    }

    private static let keyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
        "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]
}
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
