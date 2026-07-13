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
    private let websiteDataStore = WKWebsiteDataStore.default()
    private let backgroundHost = CPSLWebBrowserBackgroundHost()
    private let keyboardMonitor = CPSLWebBrowserKeyboardMonitor()

    private let defaultWindowSize = CGSize(width: 1200, height: 900)
    private let maxInlineJSONBytes = 16_000
    private let activityDuration: TimeInterval = 1.6
    private static let supportedControlKeys: Set<String> = [
        "Enter", "Escape", "Tab", "Backspace", "Delete",
        "ArrowLeft", "ArrowUp", "ArrowRight", "ArrowDown",
        "Home", "End", "PageUp", "PageDown",
    ]

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

    var visibleBrowserWindowSize: CGSize {
        guard let visibleBrowserID,
              let browser = browsers[visibleBrowserID]
        else {
            return defaultWindowSize
        }
        return browser.windowSize
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
        backgroundHost.detach(shown.webView)
        setOverlayVisible(true, browserID: shown.id)
        refreshSummaries()
    }

    func hideOverlayFromUI() {
        if let visibleBrowserID {
            if let browser = browsers[visibleBrowserID] {
                browser.isVisible = false
                backgroundHost.attach(browser.webView, size: browser.windowSize)
            }
        }
        setOverlayVisible(false, browserID: nil)
    }

    func createBrowserFromUI() async {
        do {
            let browser = try await createBrowser(resourceMode: .full, networkPolicy: .unrestricted)
            browser.isVisible = true
            backgroundHost.detach(browser.webView)
            setOverlayVisible(true, browserID: browser.id)
            refreshSummaries()
        } catch {
            refreshSummaries()
        }
    }

    func closeBrowserFromUI(id: String) {
        if let browser = browsers.removeValue(forKey: id) {
            backgroundHost.detach(browser.webView)
        }
        if lastBrowserID == id {
            lastBrowserID = browsers.keys.sorted().first
        }
        if visibleBrowserID == id {
            if let nextID = lastBrowserID, let browser = browsers[nextID] {
                browser.isVisible = true
                backgroundHost.detach(browser.webView)
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
                backgroundHost.detach(browser.webView)
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

    func updateVisibleBrowserProjection(availableSize: CGSize) {
        guard let visibleBrowserID, let browser = browsers[visibleBrowserID] else {
            return
        }
        updateBrowserProjection(browser, availableSize: availableSize)
    }

    func handleJSON(_ requestJSON: String) async -> String {
        do {
            let request = try CPSLWebBrowserRequest(json: requestJSON)
            markActivity()
            do {
                let response = try await handle(request)
                return encodeResponse(response)
            } catch {
                let browser = request.browser.flatMap { browsers[$0] }
                let interaction: [String: Any]?
                if let browser {
                    interaction = await finishActiveInteraction(in: browser)
                } else {
                    interaction = nil
                }
                return errorJSON(
                    error.localizedDescription,
                    browser: browser,
                    interaction: interaction
                )
            }
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
            backgroundHost.detach(shown.webView)
            setOverlayVisible(true, browserID: shown.id)
            refreshSummaries()
            return success(browser: shown).merging(["message": "shown"]) { _, new in new }

        case "browserHide":
            let browser = try await requireBrowser(request.browser)
            browser.isVisible = false
            backgroundHost.attach(browser.webView, size: browser.windowSize)
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
            if !browser.isVisible {
                backgroundHost.attach(browser.webView, size: browser.windowSize)
            }
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
            let downloadCount = browser.navigationDelegate.completedDownloadCount
            let selector = try await selector(for: request.requiredAction(), in: browser)
            let interaction = await beginInteraction("click", in: browser)
            try await runActionJavaScript(clickScript(selector: selector), in: browser)
            return try await responseAfterInteraction(
                in: browser,
                request: request,
                downloadCount: downloadCount,
                interactionContext: interaction
            )

        case "fill":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let selector = try await selector(for: request.requiredAction(), in: browser)
            let interaction = await beginInteraction("fill", in: browser)
            let targetBefore = try await actionState(selector: selector, in: browser)
            try await runActionJavaScript(fillScript(selector: selector, value: request.value ?? ""), in: browser)
            try await settleAfterInteraction()
            let target = try await actionState(selector: selector, in: browser)
            let page = try await pageSnapshot(browser, request: request)
            let interactionDiagnostics = await finishInteraction(interaction, in: browser)
            return success(browser: browser).merging([
                "page": page,
                "target": target,
                "fill": [
                    "targetBefore": targetBefore,
                    "targetAfter": target,
                    "characterCount": (request.value ?? "").count,
                    "interaction": interactionDiagnostics,
                ],
            ]) { _, new in new }

        case "type":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let action = try request.requiredAction()
            let selector = try await selector(for: action, in: browser)
            let interaction = await beginInteraction("type", in: browser)
            let targetBefore = try await actionState(selector: selector, in: browser)
            let typingResult = try await typeText(
                request.value ?? "",
                selector: selector,
                in: browser,
                options: try request.typingOptions()
            )
            try await settleAfterInteraction()
            let target = try await actionState(selector: selector, in: browser)
            let page = try await pageSnapshot(browser, request: request)
            let interactionDiagnostics = await finishInteraction(interaction, in: browser)
            return success(browser: browser).merging([
                "page": page,
                "typing": typingResult.jsonObject.merging([
                    "action": action,
                    "targetBefore": targetBefore,
                    "target": target,
                    "targetAfter": target,
                    "interaction": interactionDiagnostics,
                ]) { _, new in new },
            ]) { _, new in new }

        case "keyPress":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let action = try request.requiredAction()
            let selector = try await selector(for: action, in: browser)
            let interaction = await beginInteraction("keyPress", in: browser)
            let targetBefore = try await actionState(selector: selector, in: browser)
            let keyResult = try await pressKey(
                request.value ?? "",
                selector: selector,
                in: browser
            )
            try await settleAfterInteraction()
            let target = try await actionState(selector: selector, in: browser)
            let page = try await pageSnapshot(browser, request: request)
            let interactionDiagnostics = await finishInteraction(interaction, in: browser)
            return success(browser: browser).merging([
                "page": page,
                "target": target,
                "keyPress": keyResult.jsonObject.merging([
                    "action": action,
                    "targetBefore": targetBefore,
                    "targetAfter": target,
                    "interaction": interactionDiagnostics,
                ]) { _, new in new },
            ]) { _, new in new }

        case "armUpload":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let host = ensureInteractionHost(browser)
            let urls = try uploadURLs(for: request)
            let trace = CPSLWebBrowserUploadTrace(
                mode: "armedNextChooser",
                action: nil,
                virtualPaths: request.virtualSourcePaths,
                hostAtArm: host
            )
            browser.uploadTrace = trace
            let uploadDelegate = makeUploadDelegate(
                traceID: trace.id,
                fileURLs: urls,
                browser: browser
            )
            installUploadDelegate(uploadDelegate, in: browser)
            uploadDelegate.arm(timeout: 60) { [weak self, weak browser, weak uploadDelegate] in
                guard let self, let browser, let uploadDelegate else {
                    return
                }
                restoreUploadDelegate(uploadDelegate, in: browser)
            }
            return success(browser: browser).merging([
                "message": "armed the next file chooser",
                "paths": request.virtualSourcePaths,
                "expiresInSeconds": 60,
                "upload": browser.uploadTrace?.jsonObject ?? [:],
            ]) { _, new in new }

        case "upload":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let host = ensureInteractionHost(browser)
            let action = try request.requiredAction()
            let selector = try await selector(for: action, in: browser)
            let urls = try uploadURLs(for: request)
            let interaction = await beginInteraction("upload", in: browser)
            let trace = CPSLWebBrowserUploadTrace(
                mode: "atomicAction",
                action: action,
                virtualPaths: request.virtualSourcePaths,
                hostAtArm: host
            )
            browser.uploadTrace = trace
            let uploadDelegate = makeUploadDelegate(
                traceID: trace.id,
                fileURLs: urls,
                browser: browser
            )
            installUploadDelegate(uploadDelegate, in: browser)
            defer {
                restoreUploadDelegate(uploadDelegate, in: browser)
            }
            try await uploadDelegate.chooseFiles { [weak self, weak browser] in
                guard let self, let browser else {
                    throw CPSLWebBrowserError.message("browser was closed before file selection")
                }
                try await self.runActionJavaScript(self.clickScript(selector: selector), in: browser)
            }
            try await settleAfterInteraction()
            let page = try await pageSnapshot(browser, request: request)
            let interactionDiagnostics = await finishInteraction(interaction, in: browser)
            return success(browser: browser).merging([
                "message": request.virtualSourcePaths.joined(separator: ", "),
                "paths": request.virtualSourcePaths,
                "page": page,
                "interaction": interactionDiagnostics,
            ]) { _, new in new }

        case "submit":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let downloadCount = browser.navigationDelegate.completedDownloadCount
            let selector = try await selector(for: request.requiredAction(), in: browser)
            let interaction = await beginInteraction("submit", in: browser)
            try await runActionJavaScript(submitScript(selector: selector), in: browser)
            return try await responseAfterInteraction(
                in: browser,
                request: request,
                downloadCount: downloadCount,
                interactionContext: interaction
            )

        case "coordinate":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let downloadCount = browser.navigationDelegate.completedDownloadCount
            let interaction = await beginInteraction("coordinate", in: browser)
            try await runCoordinateAction(request, in: browser)
            return try await responseAfterInteraction(
                in: browser,
                request: request,
                downloadCount: downloadCount,
                interactionContext: interaction
            )

        case "eval":
            let browser = try await requireBrowser(request.browser)
            applyNetworkPolicy(from: request, to: browser)
            let value = try await evaluateUserJavaScript(request, in: browser)
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

        let previousURL = browser.webView.url
        let downloadCount = browser.navigationDelegate.completedDownloadCount
        browser.webView.load(Self.browserRequest(for: url))
        try await waitForDocumentReady(
            browser,
            requestedURL: url,
            previousURL: previousURL,
            downloadCount: downloadCount,
            timeout: 15
        )
        await waitForActiveDownload(in: browser)
        if browser.navigationDelegate.completedDownloadCount > downloadCount,
           let path = browser.navigationDelegate.completedDownloadPaths.last {
            return success(browser: browser).merging([
                "download": path,
                "message": path,
            ]) { _, new in new }
        }
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
        // Use the shared persistent WebKit store so cookies, local storage, and
        // logged-in browsing state survive across tabs and app launches.
        configuration.websiteDataStore = websiteDataStore
        #if canImport(UIKit)
        if #available(iOS 13.0, *) {
            configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        }
        #endif
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
            downloadDirectory: { [weak self] in
                guard let root = self?.sandboxRootURL else {
                    return nil
                }
                return root.appendingPathComponent("tmp", isDirectory: true)
                    .appendingPathComponent("downloads", isDirectory: true)
            },
            onNavigationChanged: { [weak self] webView in
                self?.refreshBrowserNavigation(id: id, webView: webView)
            }
        )
        webView.navigationDelegate = navigationDelegate
        let uiDelegate = CPSLWebBrowserUIDelegate()
        webView.uiDelegate = uiDelegate
        let browser = CPSLWebBrowserSession(
            id: id,
            resourceMode: resourceMode,
            webView: webView,
            windowSize: windowSize,
            networkPolicy: networkPolicy,
            navigationDelegate: navigationDelegate,
            uiDelegate: uiDelegate
        )
        backgroundHost.attach(webView, size: windowSize)
        return browser
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
            try? await waitForDocumentReady(replacement, requestedURL: url, timeout: 15)
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
        backgroundHost.detach(browser.webView)
        if !replacement.isVisible {
            backgroundHost.attach(replacement.webView, size: replacement.windowSize)
        }
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
            if let browser = browsers.removeValue(forKey: id) {
                backgroundHost.detach(browser.webView)
            }
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
        page["downloads"] = browser.navigationDelegate.completedDownloadPaths
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

    private func refreshBrowserNavigation(id: String, webView: WKWebView) {
        guard let browser = browsers[id], browser.webView === webView else {
            return
        }
        browser.title = webView.title
        browser.url = webView.url?.absoluteString
        refreshSummaries()
    }

    private func updateBrowserProjection(_ browser: CPSLWebBrowserSession, availableSize: CGSize) {
        guard availableSize.width > 1,
              availableSize.height > 1,
              browser.windowSize.width > 1
        else {
            return
        }

        let projectedWidth = max(defaultWindowSize.width, browser.windowSize.width)
        let scale = availableSize.width / projectedWidth
        guard scale > 0 else {
            return
        }
        let projectedHeight = max(defaultWindowSize.height, ceil(availableSize.height / scale))
        let projectedSize = CGSize(width: projectedWidth, height: projectedHeight)
        guard abs(projectedSize.width - browser.windowSize.width) > 1
            || abs(projectedSize.height - browser.windowSize.height) > 1
        else {
            return
        }

        browser.windowSize = projectedSize
        browser.webView.frame = CGRect(origin: .zero, size: projectedSize)
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
        let suffix = action.dropFirst()
        if action.first == "a", !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) {
            throw CPSLWebBrowserError.message(
                "browser action \(action) is stale or absent from the latest page; refresh page actions"
            )
        }
        return action
    }

    private func uploadURLs(for request: CPSLWebBrowserRequest) throws -> [URL] {
        guard !request.sourcePaths.isEmpty else {
            throw CPSLWebBrowserError.message("missing upload source paths")
        }
        guard let sandboxRootURL else {
            throw CPSLWebBrowserError.message("sandbox storage is unavailable")
        }
        let root = sandboxRootURL.resolvingSymlinksInPath().standardizedFileURL
        return try request.sourcePaths.enumerated().map { index, path in
            let displayPath = request.virtualSourcePaths.indices.contains(index)
                ? request.virtualSourcePaths[index]
                : "selected file"
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix("\(root.path)/") else {
                throw CPSLWebBrowserError.message("upload source is outside the sandbox")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                throw CPSLWebBrowserError.message("upload source is not a file: \(displayPath)")
            }
            return url
        }
    }

    private func makeUploadDelegate(
        traceID: String,
        fileURLs: [URL],
        browser: CPSLWebBrowserSession
    ) -> CPSLWebBrowserUploadUIDelegate {
        CPSLWebBrowserUploadUIDelegate(
            traceID: traceID,
            fileURLs: fileURLs
        ) { [weak browser] event in
            guard let browser,
                  var trace = browser.uploadTrace,
                  trace.id == traceID
            else {
                return
            }
            trace.apply(event)
            browser.uploadTrace = trace
        }
    }

    private func installUploadDelegate(
        _ uploadDelegate: CPSLWebBrowserUploadUIDelegate,
        in browser: CPSLWebBrowserSession
    ) {
        browser.uploadUIDelegate?.cancel()
        browser.uploadUIDelegate = uploadDelegate
        browser.webView.uiDelegate = uploadDelegate
    }

    private func restoreUploadDelegate(
        _ uploadDelegate: CPSLWebBrowserUploadUIDelegate,
        in browser: CPSLWebBrowserSession
    ) {
        guard browser.uploadUIDelegate === uploadDelegate else {
            return
        }
        browser.webView.uiDelegate = browser.uiDelegate
        browser.uploadUIDelegate = nil
    }

    @discardableResult
    private func runActionJavaScript(
        _ script: String,
        in browser: CPSLWebBrowserSession
    ) async throws -> [String: Any] {
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
        return object
    }

    private func actionState(
        selector: String,
        in browser: CPSLWebBrowserSession
    ) async throws -> [String: Any] {
        let value = try await evaluateJavaScript(actionStateScript(selector: selector), in: browser)
        guard let json = value as? String,
              let data = json.data(using: .utf8),
              let state = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CPSLWebBrowserError.message("browser action state returned invalid JSON")
        }
        return state
    }

    private func typeText(
        _ text: String,
        selector: String,
        in browser: CPSLWebBrowserSession,
        options: CPSLWebBrowserTypingOptions
    ) async throws -> CPSLWebBrowserTypingResult {
        let hostBefore = ensureInteractionHost(browser)
        var backendUsed: String
        var nativeResponderClass: String?
        var fallbackReason: String?
        var committedCharacterCount = 0
        var nativeAttempted = false
        var interruptionReason: String?
        switch options.backend {
        case .automatic:
            #if os(macOS)
            if browser.webView.window == nil {
                try await typeTextWithJavaScript(text, selector: selector, in: browser, options: options)
                backendUsed = CPSLWebBrowserTypingBackend.javaScript.rawValue
                committedCharacterCount = text.count
                fallbackReason = "the web view could not be attached to a native window"
            } else {
                try await runActionJavaScript(focusScript(selector: selector), in: browser)
                try await typeTextWithNativeEvents(text, in: browser, options: options)
                backendUsed = CPSLWebBrowserTypingBackend.native.rawValue
                committedCharacterCount = text.count
            }
            #elseif canImport(UIKit)
            let canAttemptNative = hostBefore.mode == "backgroundOffscreen"
                && hostBefore.windowIsKey == false
                && hostBefore.windowCanBecomeKey == false
            if canAttemptNative {
                nativeAttempted = true
                do {
                    let outcome = try await typeTextWithUIKitTextInput(
                        text,
                        selector: selector,
                        in: browser,
                        options: options
                    )
                    nativeResponderClass = outcome.responderClass
                    committedCharacterCount = outcome.committedCharacterCount
                    backendUsed = "nativeTextInput"
                } catch let failure as CPSLWebBrowserNativeTypingFailure {
                    committedCharacterCount = failure.committedCharacterCount
                    interruptionReason = failure.message
                    guard failure.committedCharacterCount == 0 else {
                        throw CPSLWebBrowserError.message(
                            "native typing interrupted after \(failure.committedCharacterCount) characters; refusing an unsafe fallback: \(failure.message)"
                        )
                    }
                    fallbackReason = failure.message
                    try await typeTextWithJavaScript(text, selector: selector, in: browser, options: options)
                    committedCharacterCount = text.count
                    backendUsed = CPSLWebBrowserTypingBackend.javaScript.rawValue
                }
            } else {
                fallbackReason = "native text input requires the dedicated non-key background window"
                try await typeTextWithJavaScript(text, selector: selector, in: browser, options: options)
                committedCharacterCount = text.count
                backendUsed = CPSLWebBrowserTypingBackend.javaScript.rawValue
            }
            #else
            try await typeTextWithJavaScript(text, selector: selector, in: browser, options: options)
            backendUsed = CPSLWebBrowserTypingBackend.javaScript.rawValue
            committedCharacterCount = text.count
            fallbackReason = "native text input is unavailable on this platform"
            #endif
        case .native:
            #if os(macOS)
            guard browser.webView.window != nil else {
                throw CPSLWebBrowserError.message("native typing requires an attached browser window")
            }
            try await runActionJavaScript(focusScript(selector: selector), in: browser)
            try await typeTextWithNativeEvents(text, in: browser, options: options)
            backendUsed = CPSLWebBrowserTypingBackend.native.rawValue
            committedCharacterCount = text.count
            #elseif canImport(UIKit)
            guard hostBefore.mode == "backgroundOffscreen",
                  hostBefore.windowIsKey == false,
                  hostBefore.windowCanBecomeKey == false
            else {
                throw CPSLWebBrowserError.message(
                    "native iOS typing requires the dedicated non-key background window"
                )
            }
            nativeAttempted = true
            let outcome = try await typeTextWithUIKitTextInput(
                text,
                selector: selector,
                in: browser,
                options: options
            )
            nativeResponderClass = outcome.responderClass
            committedCharacterCount = outcome.committedCharacterCount
            backendUsed = "nativeTextInput"
            #else
            throw CPSLWebBrowserError.message("native typing is unavailable on this platform")
            #endif
        case .javaScript:
            try await typeTextWithJavaScript(text, selector: selector, in: browser, options: options)
            backendUsed = CPSLWebBrowserTypingBackend.javaScript.rawValue
            committedCharacterCount = text.count
        }
        let hostAfter = backgroundHost.snapshot(for: browser.webView, isVisible: browser.isVisible)
        return CPSLWebBrowserTypingResult(
            requestedBackend: options.backend.rawValue,
            backendUsed: backendUsed,
            rhythm: options.rhythm.rawValue,
            characterCount: text.count,
            committedCharacterCount: committedCharacterCount,
            nativeAttempted: nativeAttempted,
            hostBefore: hostBefore,
            hostAfter: hostAfter,
            nativeResponderClass: nativeResponderClass,
            fallbackReason: fallbackReason,
            interruptionReason: interruptionReason
        )
    }

    private func typeTextWithJavaScript(
        _ text: String,
        selector: String,
        in browser: CPSLWebBrowserSession,
        options: CPSLWebBrowserTypingOptions
    ) async throws {
        try await sleepForTyping(options: options, after: nil)
        try await runActionJavaScript(appendTextScript(selector: selector, value: text), in: browser)
    }

    #if canImport(UIKit)
    private func typeTextWithUIKitTextInput(
        _ text: String,
        selector: String,
        in browser: CPSLWebBrowserSession,
        options: CPSLWebBrowserTypingOptions
    ) async throws -> CPSLWebBrowserNativeTypingOutcome {
        try await runActionJavaScript(controlledFocusScript(selector: selector), in: browser)
        do {
            try await Task.sleep(nanoseconds: 20_000_000)
            let focusedState = try await actionState(selector: selector, in: browser)
            guard focusedState["focused"] as? Bool == true else {
                throw CPSLWebBrowserNativeTypingFailure(
                    message: "WebKit did not focus the requested action in the non-key window",
                    committedCharacterCount: 0
                )
            }
            guard let responder = backgroundHost.firstResponder(in: browser.webView),
                  let keyInput = responder as? UIKeyInput
            else {
                throw CPSLWebBrowserNativeTypingFailure(
                    message: "WebKit did not expose a UIKeyInput responder in the non-key window",
                    committedCharacterCount: 0
                )
            }
            let initialWindow = browser.webView.window
            var committedCharacterCount = 0
            var previousCharacter: Character?
            for character in text {
                let state = try await actionState(selector: selector, in: browser)
                guard state["focused"] as? Bool == true else {
                    throw CPSLWebBrowserNativeTypingFailure(
                        message: "the requested DOM action lost focus",
                        committedCharacterCount: committedCharacterCount
                    )
                }
                guard browser.webView.window === initialWindow,
                      initialWindow?.isKeyWindow == false,
                      initialWindow?.canBecomeKey == false
                else {
                    throw CPSLWebBrowserNativeTypingFailure(
                        message: "the browser left its non-key host window",
                        committedCharacterCount: committedCharacterCount
                    )
                }
                guard backgroundHost.firstResponder(in: browser.webView) === responder else {
                    throw CPSLWebBrowserNativeTypingFailure(
                        message: "the WebKit responder identity changed",
                        committedCharacterCount: committedCharacterCount
                    )
                }
                try await sleepForTyping(options: options, after: previousCharacter)
                keyInput.insertText(String(character))
                committedCharacterCount += 1
                previousCharacter = character
            }
            _ = try? await evaluateJavaScript(controlledBlurScript(selector: selector), in: browser)
            return CPSLWebBrowserNativeTypingOutcome(
                responderClass: String(describing: type(of: responder)),
                committedCharacterCount: committedCharacterCount
            )
        } catch {
            _ = try? await evaluateJavaScript(controlledBlurScript(selector: selector), in: browser)
            if let failure = error as? CPSLWebBrowserNativeTypingFailure {
                throw failure
            }
            throw CPSLWebBrowserNativeTypingFailure(
                message: error.localizedDescription,
                committedCharacterCount: 0
            )
        }
    }
    #endif

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

    private func pressKey(
        _ key: String,
        selector: String,
        in browser: CPSLWebBrowserSession
    ) async throws -> CPSLWebBrowserKeyPressResult {
        guard Self.supportedControlKeys.contains(key) else {
            throw CPSLWebBrowserError.message(
                "unsupported control key \(key.debugDescription); use one of: "
                    + Self.supportedControlKeys.sorted().joined(separator: ", ")
            )
        }
        let hostBefore = ensureInteractionHost(browser)
        var backendUsed = "jsKeyboardEvent"
        var fallbackReason: String?
        var nativeAttempted = false
        var pageConsumed: Bool?
        var eventTrusted: Bool?

        #if os(macOS)
        if browser.webView.window != nil {
            nativeAttempted = true
            try await runActionJavaScript(focusScript(selector: selector), in: browser)
            browser.webView.window?.makeFirstResponder(browser.webView)
            try sendNativeKey(key, to: browser.webView)
            backendUsed = CPSLWebBrowserTypingBackend.native.rawValue
        } else {
            fallbackReason = "the web view could not be attached to a native window"
            let result = try await runActionJavaScript(
                keyPressScript(selector: selector, key: key),
                in: browser
            )
            pageConsumed = result["pageConsumed"] as? Bool
            eventTrusted = result["eventTrusted"] as? Bool
        }
        #elseif canImport(UIKit)
        // UIKeyInput represents text editing, not control-key delivery. Inserting
        // "\n" or "\t" mutates rich editors instead of producing Enter or Tab.
        let result = try await runActionJavaScript(
            keyPressScript(selector: selector, key: key),
            in: browser
        )
        pageConsumed = result["pageConsumed"] as? Bool
        eventTrusted = result["eventTrusted"] as? Bool
        #else
        fallbackReason = "native key input is unavailable on this platform"
        let result = try await runActionJavaScript(
            keyPressScript(selector: selector, key: key),
            in: browser
        )
        pageConsumed = result["pageConsumed"] as? Bool
        eventTrusted = result["eventTrusted"] as? Bool
        #endif

        return CPSLWebBrowserKeyPressResult(
            key: key,
            backendUsed: backendUsed,
            hostBefore: hostBefore,
            hostAfter: backgroundHost.snapshot(for: browser.webView, isVisible: browser.isVisible),
            fallbackReason: fallbackReason,
            nativeAttempted: nativeAttempted,
            pageConsumed: pageConsumed,
            eventTrusted: eventTrusted
        )
    }

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

    private func waitForActiveDownload(in browser: CPSLWebBrowserSession) async {
        guard browser.navigationDelegate.activeDownloadCount > 0 else {
            return
        }
        let deadline = Date().addingTimeInterval(50)
        while browser.navigationDelegate.activeDownloadCount > 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func responseAfterInteraction(
        in browser: CPSLWebBrowserSession,
        request: CPSLWebBrowserRequest,
        downloadCount: Int,
        interactionContext: CPSLWebBrowserInteractionContext
    ) async throws -> [String: Any] {
        try await settleAfterInteraction()
        await waitForActiveDownload(in: browser)
        let page = try await pageSnapshot(browser, request: request)
        var response = success(browser: browser).merging(["page": page]) { _, new in new }
        var interaction = await finishInteraction(interactionContext, in: browser)
        interaction["command"] = request.command
        if let action = request.action {
            interaction["action"] = action
        }
        if let coordinateAction = request.coordinateAction {
            interaction["coordinateAction"] = coordinateAction
            interaction["x"] = request.x ?? 0
            interaction["y"] = request.y ?? 0
            interaction["deltaX"] = request.deltaX ?? 0
            interaction["deltaY"] = request.deltaY ?? 0
        }
        response["interaction"] = interaction
        if browser.navigationDelegate.completedDownloadCount > downloadCount,
           let path = browser.navigationDelegate.completedDownloadPaths.last {
            response["download"] = path
            response["message"] = path
        }
        return response
    }

    private func waitForDocumentReady(
        _ browser: CPSLWebBrowserSession,
        requestedURL: URL? = nil,
        previousURL: URL? = nil,
        downloadCount: Int? = nil,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let downloadCount,
               browser.navigationDelegate.completedDownloadCount > downloadCount {
                return
            }
            if browser.navigationDelegate.activeDownloadCount > 0 {
                return
            }
            let location = try? await evaluateJavaScript("location.href", in: browser) as? String
            if let readyState = try? await evaluateJavaScript("document.readyState", in: browser) as? String,
               isCommittedDocument(
                   browser: browser,
                   requestedURL: requestedURL,
                   previousURL: previousURL,
                   location: location
               ),
               readyState == "interactive" || readyState == "complete" {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func isCommittedDocument(
        browser: CPSLWebBrowserSession,
        requestedURL: URL?,
        previousURL: URL?,
        location: String?
    ) -> Bool {
        let rawURL = location?.nilIfEmpty ?? browser.webView.url?.absoluteString.nilIfEmpty
        guard let rawURL,
              rawURL != "about:blank",
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased()
        else {
            return false
        }
        if let requestedURL {
            if let previousURL,
               previousURL.absoluteString != requestedURL.absoluteString,
               rawURL == previousURL.absoluteString {
                return false
            }
            let requestedScheme = requestedURL.scheme?.lowercased()
            if requestedScheme == "http" || requestedScheme == "https" {
                return scheme == "http" || scheme == "https"
            }
            return requestedScheme == scheme
        }
        return true
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

    private func evaluateUserJavaScript(
        _ request: CPSLWebBrowserRequest,
        in browser: CPSLWebBrowserSession
    ) async throws -> Any? {
        do {
            return try await evaluateJavaScript(
                Self.renderedEvalScript(script: request.script ?? "", functionBody: request.functionBody),
                in: browser
            )
        } catch {
            return try await evaluateJavaScript(request.evalScript, in: browser)
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

    private static func compileLeanContentRuleList() async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "herm-webbrowser-lean-resource-mode-v1",
                encodedContentRuleList: Self.leanContentRuleListJSON
            ) { ruleList, _ in
                continuation.resume(returning: ruleList)
            }
        }
    }

    @discardableResult
    private func ensureInteractionHost(
        _ browser: CPSLWebBrowserSession
    ) -> CPSLWebBrowserHostSnapshot {
        if browser.webView.window == nil || !browser.isVisible {
            backgroundHost.attach(browser.webView, size: browser.windowSize)
        }
        return backgroundHost.snapshot(for: browser.webView, isVisible: browser.isVisible)
    }

    private func beginInteraction(
        _ operation: String,
        in browser: CPSLWebBrowserSession
    ) async -> CPSLWebBrowserInteractionContext {
        _ = await finishActiveInteraction(in: browser)
        let id = UUID().uuidString.lowercased()
        let hostBefore = ensureInteractionHost(browser)
        let keyboardSequence = keyboardMonitor.begin(transactionID: id)
        _ = try? await evaluateJavaScript(
            inputTraceStartScript(transactionID: id),
            in: browser
        )
        let context = CPSLWebBrowserInteractionContext(
            id: id,
            operation: operation,
            keyboardSequence: keyboardSequence,
            hostBefore: hostBefore
        )
        browser.activeInteractionContext = context
        return context
    }

    private func finishInteraction(
        _ context: CPSLWebBrowserInteractionContext,
        in browser: CPSLWebBrowserSession
    ) async -> [String: Any] {
        let value = try? await evaluateJavaScript(
            inputTraceFinishScript(transactionID: context.id),
            in: browser
        )
        let dom: [String: Any]
        if let json = value as? String,
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dom = object
        } else {
            dom = ["error": "input trace was unavailable"]
        }
        if browser.activeInteractionContext?.id == context.id {
            browser.activeInteractionContext = nil
        }
        keyboardMonitor.end(transactionID: context.id)
        return [
            "id": context.id,
            "operation": context.operation,
            "hostBefore": context.hostBefore.jsonObject,
            "hostAfter": backgroundHost.snapshot(
                for: browser.webView,
                isVisible: browser.isVisible
            ).jsonObject,
            "keyboardEvents": keyboardMonitor.events(
                since: context.keyboardSequence,
                transactionID: context.id
            ),
            "dom": dom,
        ]
    }

    private func finishActiveInteraction(
        in browser: CPSLWebBrowserSession
    ) async -> [String: Any]? {
        guard let context = browser.activeInteractionContext else {
            return nil
        }
        return await finishInteraction(context, in: browser)
    }

    private func success(browser: CPSLWebBrowserSession) -> [String: Any] {
        var response: [String: Any] = [
            "ok": true,
            "browser": browser.id,
            "resourceMode": browser.resourceMode.rawValue,
            "url": browser.url ?? browser.webView.url?.absoluteString ?? "",
            "windowWidth": Int(browser.windowSize.width.rounded()),
            "windowHeight": Int(browser.windowSize.height.rounded()),
            "browserHost": backgroundHost.snapshot(
                for: browser.webView,
                isVisible: browser.isVisible
            ).jsonObject,
        ]
        if let uploadTrace = browser.uploadTrace {
            response["upload"] = uploadTrace.jsonObject
        }
        response["keyboard"] = keyboardMonitor.summary()
        return response
    }

    private func refreshSummaries() {
        summaries = browsers.values
            .map { $0.summary }
            .sorted { lhs, rhs in
                lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
    }

    private func setOverlayVisible(_ isVisible: Bool, browserID: String?) {
        if let previousID = visibleBrowserID,
           previousID != browserID,
           let previous = browsers[previousID] {
            previous.isVisible = false
            backgroundHost.attach(previous.webView, size: previous.windowSize)
        }
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
        if let download = response["download"] {
            compact["download"] = download
        }
        if let paths = response["paths"] {
            compact["paths"] = paths
        }
        if let target = response["target"] {
            compact["target"] = target
        }
        if let typing = response["typing"] {
            compact["typing"] = compactOperationDiagnostics(typing)
        }
        if let fill = response["fill"] {
            compact["fill"] = compactOperationDiagnostics(fill)
        }
        if let keyPress = response["keyPress"] {
            compact["keyPress"] = compactOperationDiagnostics(keyPress)
        }
        if let browserHost = response["browserHost"] {
            compact["browserHost"] = browserHost
        }
        if let upload = response["upload"] {
            compact["upload"] = upload
        }
        if let interaction = response["interaction"] {
            compact["interaction"] = compactInteractionDiagnostics(interaction)
        }
        if let keyboard = response["keyboard"] {
            compact["keyboard"] = keyboard
        }
        if let page = response["page"] as? [String: Any] {
            compact["page"] = [
                "browser": page["browser"] ?? response["browser"] ?? "",
                "title": page["title"] ?? "",
                "url": page["url"] ?? "",
                "textPreview": String((page["text"] as? String ?? "").prefix(2000)),
                "actions": compactActions(page["actions"]),
                "actionCandidates": page["actionCandidates"] ?? [:],
                "dialogs": page["dialogs"] ?? [],
                "downloads": page["downloads"] ?? [],
                "viewport": page["viewport"] ?? [:],
                "resourceCount": page["resourceCount"] ?? 0,
            ]
        }
        return compact
    }

    private func compactActions(_ value: Any?) -> [[String: Any]] {
        guard let actions = value as? [[String: Any]] else {
            return []
        }
        return actions.map { action in
            var compact: [String: Any] = [:]
            for key in [
                "id", "index", "tag", "type", "x", "y", "width", "height", "inViewport",
            ] {
                if let value = action[key] {
                    compact[key] = value
                }
            }
            compact["label"] = String((action["label"] as? String ?? "").prefix(120))
            if (compact["label"] as? String)?.isEmpty == true {
                compact["text"] = String((action["text"] as? String ?? "").prefix(120))
            }
            if let href = (action["href"] as? String)?.nilIfEmpty {
                compact["href"] = String(href.prefix(240))
            }
            return compact
        }
    }

    private func compactOperationDiagnostics(_ value: Any) -> Any {
        guard var object = value as? [String: Any] else {
            return value
        }
        if let interaction = object["interaction"] {
            object["interaction"] = compactInteractionDiagnostics(interaction)
        }
        return object
    }

    private func compactInteractionDiagnostics(_ value: Any) -> Any {
        guard var interaction = value as? [String: Any],
              var dom = interaction["dom"] as? [String: Any],
              let events = dom["events"] as? [[String: Any]]
        else {
            return value
        }
        var eventCounts: [String: Int] = [:]
        var trustedEventCount = 0
        for event in events {
            let name = event["event"] as? String ?? "unknown"
            eventCounts[name, default: 0] += 1
            if event["isTrusted"] as? Bool == true {
                trustedEventCount += 1
            }
        }
        let retainedEventCount = 6
        dom["eventCount"] = events.count
        dom["eventCounts"] = eventCounts
        dom["trustedEventCount"] = trustedEventCount
        dom["events"] = Array(events.suffix(retainedEventCount))
        dom["eventsTruncated"] = events.count > retainedEventCount
        interaction["dom"] = dom
        return interaction
    }

    private func errorJSON(
        _ message: String,
        browser: CPSLWebBrowserSession? = nil,
        interaction: [String: Any]? = nil
    ) -> String {
        var object: [String: Any] = ["ok": false, "error": message]
        object["keyboard"] = keyboardMonitor.summary()
        if let interaction {
            object["interaction"] = interaction
        }
        if let browser {
            object["browser"] = browser.id
            object["browserHost"] = backgroundHost.snapshot(
                for: browser.webView,
                isVisible: browser.isVisible
            ).jsonObject
            if let uploadTrace = browser.uploadTrace {
                object["upload"] = uploadTrace.jsonObject
            }
        }
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
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(safariVersion) Safari/605.1.15"
        #else
        return "Mozilla/5.0 AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Safari/605.1.15"
        #endif
    }
}

private struct CPSLWebBrowserHostSnapshot {
    let platform: String
    let mode: String
    let attachedToWindow: Bool
    let windowIsKey: Bool
    let windowIsVisible: Bool
    let webViewIsFirstResponder: Bool
    let descendantFirstResponderClass: String?
    let webViewHidden: Bool
    let webViewAlpha: Double
    let superviewClass: String?
    let hostFrame: CGRect?
    let windowID: String?
    let sceneID: String?
    let mainKeyWindowID: String?
    let windowCanBecomeKey: Bool?

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "platform": platform,
            "mode": mode,
            "attachedToWindow": attachedToWindow,
            "windowIsKey": windowIsKey,
            "windowIsVisible": windowIsVisible,
            "webViewIsFirstResponder": webViewIsFirstResponder,
            "webViewHidden": webViewHidden,
            "webViewAlpha": webViewAlpha,
        ]
        if let descendantFirstResponderClass {
            object["descendantFirstResponderClass"] = descendantFirstResponderClass
        }
        if let superviewClass {
            object["superviewClass"] = superviewClass
        }
        if let hostFrame {
            object["hostFrame"] = [
                "x": Double(hostFrame.origin.x),
                "y": Double(hostFrame.origin.y),
                "width": Double(hostFrame.width),
                "height": Double(hostFrame.height),
            ]
        }
        if let windowID {
            object["windowID"] = windowID
        }
        if let sceneID {
            object["sceneID"] = sceneID
        }
        if let mainKeyWindowID {
            object["mainKeyWindowID"] = mainKeyWindowID
        }
        if let windowCanBecomeKey {
            object["windowCanBecomeKey"] = windowCanBecomeKey
        }
        return object
    }
}

#if canImport(UIKit)
@MainActor
private final class CPSLWebBrowserNonKeyWindow: UIWindow {
    let traceID = UUID().uuidString.lowercased()

    override var canBecomeKey: Bool {
        false
    }
}
#endif

@MainActor
private final class CPSLWebBrowserKeyboardMonitor {
    private var observers: [NSObjectProtocol] = []
    private var events: [[String: Any]] = []
    private var nextSequence = 1
    private var activeTransactionID: String?
    private var isSoftwareKeyboardVisible = false
    private var keyboardEndFrame: CGRect?

    init() {
        #if canImport(UIKit)
        let names: [Notification.Name] = [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillHideNotification,
            UIResponder.keyboardDidHideNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardDidChangeFrameNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    self?.record(notification)
                }
            }
        }
        #endif
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func begin(transactionID: String) -> Int {
        activeTransactionID = transactionID
        return nextSequence
    }

    func end(transactionID: String) {
        if activeTransactionID == transactionID {
            activeTransactionID = nil
        }
    }

    func events(since sequence: Int, transactionID: String) -> [[String: Any]] {
        events.filter {
            ($0["sequence"] as? Int ?? 0) >= sequence
                && ($0["transactionID"] as? String) == transactionID
        }
    }

    func summary() -> [String: Any] {
        var object: [String: Any] = [
            "activeTransactionID": activeTransactionID ?? "",
            "eventCount": events.count,
            "isSoftwareKeyboardVisible": isSoftwareKeyboardVisible,
            "nextSequence": nextSequence,
            "recentEvents": Array(events.suffix(8)),
        ]
        if let keyboardEndFrame {
            object["endFrame"] = Self.rectObject(keyboardEndFrame)
        }
        return object
    }

    #if canImport(UIKit)
    private func record(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        var event: [String: Any] = [
            "sequence": nextSequence,
            "name": notification.name.rawValue,
            "monotonicTime": ProcessInfo.processInfo.systemUptime,
            "wallTime": ISO8601DateFormatter().string(from: Date()),
            "transactionID": activeTransactionID ?? "",
        ]
        nextSequence += 1
        if let frame = (info[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue {
            event["frameBegin"] = Self.rectObject(frame)
        }
        if let frame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            keyboardEndFrame = frame
            event["frameEnd"] = Self.rectObject(frame)
        }
        switch notification.name {
        case UIResponder.keyboardWillShowNotification,
             UIResponder.keyboardDidShowNotification:
            isSoftwareKeyboardVisible = true
        case UIResponder.keyboardWillHideNotification,
             UIResponder.keyboardDidHideNotification:
            isSoftwareKeyboardVisible = false
        default:
            break
        }
        if let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber {
            event["duration"] = duration.doubleValue
        }
        if let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber {
            event["curve"] = curve.intValue
        }
        if let isLocal = info[UIResponder.keyboardIsLocalUserInfoKey] as? NSNumber {
            event["isLocal"] = isLocal.boolValue
        }
        if let keyWindow = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) {
            if let hostWindow = keyWindow as? CPSLWebBrowserNonKeyWindow {
                event["keyWindowID"] = hostWindow.traceID
                event["keyWindowIsBrowserHost"] = true
            } else {
                event["keyWindowID"] = "main-\(ObjectIdentifier(keyWindow).hashValue)"
                event["keyWindowIsBrowserHost"] = false
            }
        }
        events.append(event)
        if events.count > 100 {
            events.removeFirst(events.count - 100)
        }
    }

    #endif

    private static func rectObject(_ rect: CGRect) -> [String: Double] {
        [
            "x": Double(rect.origin.x),
            "y": Double(rect.origin.y),
            "width": Double(rect.width),
            "height": Double(rect.height),
        ]
    }
}

private struct CPSLWebBrowserInteractionContext {
    let id: String
    let operation: String
    let keyboardSequence: Int
    let hostBefore: CPSLWebBrowserHostSnapshot
}

@MainActor
private final class CPSLWebBrowserBackgroundHost {
    #if os(macOS)
    private let container: NSView
    private let window: NSWindow

    init() {
        let frame = NSRect(x: -20_000, y: -20_000, width: 1200, height: 900)
        container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0.001
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
    }

    func attach(_ webView: WKWebView, size: CGSize) {
        let hostSize = CGSize(
            width: max(container.frame.width, size.width),
            height: max(container.frame.height, size.height)
        )
        container.frame = CGRect(origin: .zero, size: hostSize)
        window.setContentSize(hostSize)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        webView.frame = CGRect(origin: .zero, size: size)
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    func detach(_ webView: WKWebView) {
        if webView.superview === container {
            webView.removeFromSuperview()
        }
    }

    func snapshot(for webView: WKWebView, isVisible: Bool) -> CPSLWebBrowserHostSnapshot {
        let responder = webView.window?.firstResponder
        let responderView = responder as? NSView
        let responderIsInside = responderView.map {
            $0 === webView || $0.isDescendant(of: webView)
        } ?? false
        let responderClass = responder.map { String(describing: type(of: $0)) }
        let mode: String
        if webView.superview === container {
            mode = "backgroundOffscreen"
        } else if isVisible, webView.window != nil {
            mode = "visibleOverlay"
        } else if webView.window != nil {
            mode = "externalWindow"
        } else {
            mode = "unattached"
        }
        return CPSLWebBrowserHostSnapshot(
            platform: "macOS",
            mode: mode,
            attachedToWindow: webView.window != nil,
            windowIsKey: webView.window?.isKeyWindow == true,
            windowIsVisible: webView.window?.isVisible == true,
            webViewIsFirstResponder: responderIsInside,
            descendantFirstResponderClass: responderIsInside ? responderClass : nil,
            webViewHidden: webView.isHidden,
            webViewAlpha: Double(webView.alphaValue),
            superviewClass: webView.superview.map { String(describing: type(of: $0)) },
            hostFrame: webView.superview === container ? window.frame : webView.superview?.frame,
            windowID: nil,
            sceneID: nil,
            mainKeyWindowID: nil,
            windowCanBecomeKey: nil
        )
    }
    #elseif canImport(UIKit)
    private let container = UIView(frame: CGRect(x: -20_000, y: -20_000, width: 1200, height: 900))
    private let rootViewController = UIViewController()
    private var window: CPSLWebBrowserNonKeyWindow?

    init() {
        rootViewController.view.backgroundColor = .clear
        container.isHidden = false
        container.alpha = 1
        container.isUserInteractionEnabled = true
        container.clipsToBounds = false
        container.accessibilityElementsHidden = true
    }

    func attach(_ webView: WKWebView, size: CGSize) {
        guard let scene = Self.activeScene() else {
            return
        }
        let window = hostWindow(for: scene)
        let hostSize = CGSize(
            width: max(container.frame.width, size.width),
            height: max(container.frame.height, size.height)
        )
        container.frame = CGRect(
            x: -20_000,
            y: -20_000,
            width: hostSize.width,
            height: hostSize.height
        )
        if container.superview !== rootViewController.view {
            container.removeFromSuperview()
            rootViewController.view.addSubview(container)
        }
        if webView.superview !== container {
            webView.removeFromSuperview()
            container.addSubview(webView)
        }
        webView.frame = CGRect(origin: .zero, size: size)
        if window.isHidden {
            window.isHidden = false
        }
    }

    func detach(_ webView: WKWebView) {
        if webView.superview === container {
            webView.removeFromSuperview()
        }
    }

    func firstResponder(in webView: WKWebView) -> UIResponder? {
        Self.firstResponder(in: webView)
    }

    func snapshot(for webView: WKWebView, isVisible: Bool) -> CPSLWebBrowserHostSnapshot {
        let responder = firstResponder(in: webView)
        let webWindow = webView.window
        let mainKeyWindow = Self.activeKeyWindow(in: webWindow?.windowScene)
        let mode: String
        if webView.superview === container {
            mode = "backgroundOffscreen"
        } else if isVisible, webView.window != nil {
            mode = "visibleOverlay"
        } else if webView.window != nil {
            mode = "externalWindow"
        } else {
            mode = "unattached"
        }
        return CPSLWebBrowserHostSnapshot(
            platform: "iOS",
            mode: mode,
            attachedToWindow: webView.window != nil,
            windowIsKey: webView.window?.isKeyWindow == true,
            windowIsVisible: webView.window?.isHidden == false,
            webViewIsFirstResponder: responder != nil,
            descendantFirstResponderClass: responder.map { String(describing: type(of: $0)) },
            webViewHidden: webView.isHidden,
            webViewAlpha: Double(webView.alpha),
            superviewClass: webView.superview.map { String(describing: type(of: $0)) },
            hostFrame: webView.superview === container ? container.frame : webView.superview?.frame,
            windowID: Self.windowID(webWindow),
            sceneID: webWindow?.windowScene?.session.persistentIdentifier,
            mainKeyWindowID: Self.windowID(mainKeyWindow),
            windowCanBecomeKey: webWindow?.canBecomeKey
        )
    }

    private func hostWindow(for scene: UIWindowScene) -> CPSLWebBrowserNonKeyWindow {
        if let window, window.windowScene === scene {
            return window
        }
        window?.isHidden = true
        window?.rootViewController = nil
        container.removeFromSuperview()
        let window = CPSLWebBrowserNonKeyWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.rootViewController = rootViewController
        window.backgroundColor = .clear
        window.isOpaque = false
        window.alpha = 0.001
        window.isHidden = false
        self.window = window
        return window
    }

    private static func activeScene() -> UIWindowScene? {
        if let scene = activeKeyWindow(in: nil)?.windowScene {
            return scene
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .first
    }

    private static func activeKeyWindow(in scene: UIWindowScene?) -> UIWindow? {
        let scenes: [UIWindowScene]
        if let scene {
            scenes = [scene]
        } else {
            scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        }
        return scenes.flatMap(\.windows).first(where: { window in
            window.isKeyWindow && !(window is CPSLWebBrowserNonKeyWindow)
        })
    }

    private static func windowID(_ window: UIWindow?) -> String? {
        guard let window else {
            return nil
        }
        if let window = window as? CPSLWebBrowserNonKeyWindow {
            return window.traceID
        }
        return "main-\(ObjectIdentifier(window).hashValue)"
    }

    private static func firstResponder(in view: UIView) -> UIResponder? {
        if view.isFirstResponder {
            return view
        }
        for subview in view.subviews {
            if let responder = firstResponder(in: subview) {
                return responder
            }
        }
        return nil
    }
    #endif
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
    var uploadUIDelegate: CPSLWebBrowserUploadUIDelegate?
    var uploadTrace: CPSLWebBrowserUploadTrace?
    var activeInteractionContext: CPSLWebBrowserInteractionContext?

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
            isLoading: webView.isLoading,
            windowWidth: Int(windowSize.width.rounded()),
            windowHeight: Int(windowSize.height.rounded())
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
    let windowWidth: Int
    let windowHeight: Int

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "browser": id,
            "resourceMode": resourceMode.rawValue,
            "canGoBack": canGoBack,
            "canGoForward": canGoForward,
            "loading": isLoading,
            "visible": isVisible,
            "windowWidth": windowWidth,
            "windowHeight": windowHeight,
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

    static func isBrowserInternal(_ url: URL) -> Bool {
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

private final class CPSLWebBrowserNavigationDelegate: NSObject, WKNavigationDelegate, WKDownloadDelegate {
    var policy: CPSLWebBrowserNetworkPolicy
    private(set) var activeDownloadCount = 0
    private(set) var completedDownloadCount = 0
    private(set) var completedDownloadPaths: [String] = []
    let downloadDirectory: @MainActor () -> URL?
    let onNavigationChanged: @MainActor (WKWebView) -> Void
    private var virtualPathsByDownload: [ObjectIdentifier: String] = [:]

    init(
        policy: CPSLWebBrowserNetworkPolicy,
        downloadDirectory: @escaping @MainActor () -> URL?,
        onNavigationChanged: @escaping @MainActor (WKWebView) -> Void
    ) {
        self.policy = policy
        self.downloadDirectory = downloadDirectory
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
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let url = navigationResponse.response.url,
           !CPSLWebBrowserNetworkPolicy.isBrowserInternal(url),
           !policy.allows(url) {
            decisionHandler(.cancel)
        } else if navigationResponse.canShowMIMEType {
            decisionHandler(.allow)
        } else {
            decisionHandler(.download)
        }
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        begin(download)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        begin(download)
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard let directory = downloadDirectory() else {
            activeDownloadCount = max(0, activeDownloadCount - 1)
            completionHandler(nil)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = uniqueDownloadURL(
                suggestedFilename: suggestedFilename,
                directory: directory
            )
            virtualPathsByDownload[ObjectIdentifier(download)] = "/tmp/downloads/\(destination.lastPathComponent)"
            completionHandler(destination)
        } catch {
            activeDownloadCount = max(0, activeDownloadCount - 1)
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let identifier = ObjectIdentifier(download)
        if let path = virtualPathsByDownload.removeValue(forKey: identifier) {
            completedDownloadCount += 1
            completedDownloadPaths.append(path)
            if completedDownloadPaths.count > 20 {
                completedDownloadPaths.removeFirst(completedDownloadPaths.count - 20)
            }
        }
        activeDownloadCount = max(0, activeDownloadCount - 1)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        virtualPathsByDownload.removeValue(forKey: ObjectIdentifier(download))
        activeDownloadCount = max(0, activeDownloadCount - 1)
    }

    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void
    ) {
        guard let url = request.url else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(
            CPSLWebBrowserNetworkPolicy.isBrowserInternal(url) || policy.allows(url)
                ? .allow
                : .cancel
        )
    }

    private func begin(_ download: WKDownload) {
        activeDownloadCount += 1
        download.delegate = self
    }

    private func uniqueDownloadURL(suggestedFilename: String, directory: URL) -> URL {
        let name = safeDownloadName(suggestedFilename)
        let base = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        var url = directory.appendingPathComponent(name, isDirectory: false)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let candidate = fileExtension.isEmpty
                ? "\(base)-\(suffix)"
                : "\(base)-\(suffix).\(fileExtension)"
            url = directory.appendingPathComponent(candidate, isDirectory: false)
            suffix += 1
        }
        return url
    }

    private func safeDownloadName(_ value: String) -> String {
        let source = URL(fileURLWithPath: value).lastPathComponent
        let disallowed = CharacterSet(charactersIn: "/:\\?%*|\"<>\0")
            .union(.controlCharacters)
            .union(.whitespacesAndNewlines)
        let name = source.unicodeScalars.map { scalar in
            disallowed.contains(scalar) ? "-" : String(scalar)
        }
        .joined()
        .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return name.isEmpty ? "download" : name
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

private enum CPSLWebBrowserUploadEvent {
    case selected(allowsMultipleSelection: Bool, selectedCount: Int, initiatedByMainFrame: Bool)
    case expired
    case cancelled
    case failed(String)
}

private struct CPSLWebBrowserUploadTrace {
    let id = UUID().uuidString.lowercased()
    let mode: String
    let action: String?
    let virtualPaths: [String]
    let armedAt = Date()
    let hostAtArm: CPSLWebBrowserHostSnapshot
    var state = "armed"
    var updatedAt = Date()
    var allowsMultipleSelection: Bool?
    var selectedCount: Int?
    var initiatedByMainFrame: Bool?
    var failure: String?

    mutating func apply(_ event: CPSLWebBrowserUploadEvent) {
        updatedAt = Date()
        switch event {
        case let .selected(allowsMultipleSelection, selectedCount, initiatedByMainFrame):
            state = "selected"
            self.allowsMultipleSelection = allowsMultipleSelection
            self.selectedCount = selectedCount
            self.initiatedByMainFrame = initiatedByMainFrame
            failure = nil
        case .expired:
            state = "expired"
        case .cancelled:
            state = "cancelled"
        case let .failed(message):
            state = "failed"
            failure = message
        }
    }

    var jsonObject: [String: Any] {
        let formatter = ISO8601DateFormatter()
        var object: [String: Any] = [
            "id": id,
            "mode": mode,
            "state": state,
            "paths": virtualPaths,
            "armedAt": formatter.string(from: armedAt),
            "updatedAt": formatter.string(from: updatedAt),
            "hostAtArm": hostAtArm.jsonObject,
        ]
        if let action {
            object["action"] = action
        }
        if let allowsMultipleSelection {
            object["allowsMultipleSelection"] = allowsMultipleSelection
        }
        if let selectedCount {
            object["selectedCount"] = selectedCount
        }
        if let initiatedByMainFrame {
            object["initiatedByMainFrame"] = initiatedByMainFrame
        }
        if let failure {
            object["failure"] = failure
        }
        return object
    }
}

@MainActor
private final class CPSLWebBrowserUploadUIDelegate: NSObject, WKUIDelegate {
    let traceID: String
    let fileURLs: [URL]
    private let onEvent: (CPSLWebBrowserUploadEvent) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var onFinish: (() -> Void)?
    private var didFinish = false

    init(
        traceID: String,
        fileURLs: [URL],
        onEvent: @escaping (CPSLWebBrowserUploadEvent) -> Void
    ) {
        self.traceID = traceID
        self.fileURLs = fileURLs
        self.onEvent = onEvent
    }

    func arm(timeout: TimeInterval, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        scheduleTimeout(
            nanoseconds: UInt64(max(0, timeout) * 1_000_000_000),
            event: .expired,
            error: nil
        )
    }

    func chooseFiles(
        trigger: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let error = CPSLWebBrowserError.message(
                "the selected browser action did not open a file input"
            )
            scheduleTimeout(
                nanoseconds: 10_000_000_000,
                event: .failed(error.localizedDescription),
                error: error
            )
            Task { @MainActor [weak self] in
                do {
                    try await trigger()
                } catch {
                    self?.finish(event: .failed(error.localizedDescription), throwing: error)
                }
            }
        }
    }

    func cancel() {
        finish(
            event: .cancelled,
            throwing: CPSLWebBrowserError.message("file selection was replaced or cancelled")
        )
    }

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

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        guard !didFinish else {
            completionHandler(nil)
            return
        }
        let urls = parameters.allowsMultipleSelection
            ? fileURLs
            : Array(fileURLs.prefix(1))
        completionHandler(urls)
        finish(
            event: .selected(
                allowsMultipleSelection: parameters.allowsMultipleSelection,
                selectedCount: urls.count,
                initiatedByMainFrame: frame.isMainFrame
            )
        )
    }

    private func scheduleTimeout(
        nanoseconds: UInt64,
        event: CPSLWebBrowserUploadEvent,
        error: Error?
    ) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else {
                return
            }
            self?.finish(event: event, throwing: error)
        }
    }

    private func finish(
        event: CPSLWebBrowserUploadEvent,
        throwing error: Error? = nil
    ) {
        guard !didFinish else {
            return
        }
        didFinish = true
        onEvent(event)
        let continuation = continuation
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
        let completion = onFinish
        onFinish = nil
        completion?()
    }
}

private enum CPSLWebBrowserTypingBackend: String, Equatable, Sendable {
    case automatic = "auto"
    case javaScript = "js"
    case native

    static func parse(_ value: String) throws -> CPSLWebBrowserTypingBackend {
        switch value.lowercased() {
        case "auto":
            return .automatic
        case "js":
            return .javaScript
        case "native":
            return .native
        default:
            throw CPSLWebBrowserError.message("unknown typing backend \(value)")
        }
    }
}

private struct CPSLWebBrowserTypingResult {
    let requestedBackend: String
    let backendUsed: String
    let rhythm: String
    let characterCount: Int
    let committedCharacterCount: Int
    let nativeAttempted: Bool
    let hostBefore: CPSLWebBrowserHostSnapshot
    let hostAfter: CPSLWebBrowserHostSnapshot
    let nativeResponderClass: String?
    let fallbackReason: String?
    let interruptionReason: String?

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "requestedBackend": requestedBackend,
            "backendUsed": backendUsed,
            "rhythm": rhythm,
            "characterCount": characterCount,
            "committedCharacterCount": committedCharacterCount,
            "nativeAttempted": nativeAttempted,
            "hostBefore": hostBefore.jsonObject,
            "hostAfter": hostAfter.jsonObject,
        ]
        if let nativeResponderClass {
            object["nativeResponderClass"] = nativeResponderClass
        }
        if let fallbackReason {
            object["fallbackReason"] = fallbackReason
        }
        if let interruptionReason {
            object["interruptionReason"] = interruptionReason
        }
        return object
    }
}

#if canImport(UIKit)
private struct CPSLWebBrowserNativeTypingOutcome {
    let responderClass: String
    let committedCharacterCount: Int
}

private struct CPSLWebBrowserNativeTypingFailure: LocalizedError {
    let message: String
    let committedCharacterCount: Int

    var errorDescription: String? {
        message
    }
}
#endif

private struct CPSLWebBrowserKeyPressResult {
    let key: String
    let backendUsed: String
    let hostBefore: CPSLWebBrowserHostSnapshot
    let hostAfter: CPSLWebBrowserHostSnapshot
    let fallbackReason: String?
    let nativeAttempted: Bool
    let pageConsumed: Bool?
    let eventTrusted: Bool?

    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "key": key,
            "backendUsed": backendUsed,
            "hostBefore": hostBefore.jsonObject,
            "hostAfter": hostAfter.jsonObject,
            "nativeAttempted": nativeAttempted,
            "requiresPostconditionCheck": true,
        ]
        if let fallbackReason {
            object["fallbackReason"] = fallbackReason
        }
        if let pageConsumed {
            object["pageConsumed"] = pageConsumed
        }
        if let eventTrusted {
            object["eventTrusted"] = eventTrusted
        }
        return object
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
    let sourcePaths: [String]
    let virtualSourcePaths: [String]
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
        sourcePaths = try Self.stringList(object["sourcePaths"], field: "sourcePaths") ?? []
        virtualSourcePaths = try Self.stringList(
            object["virtualSourcePaths"],
            field: "virtualSourcePaths"
        ) ?? []
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
            backend: typingBackend ?? .automatic,
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
      function actionIDFor(element) {
        const attribute = "data-herm-cpsl-action-id";
        if (!window.__hermCPSLActionState) {
          Object.defineProperty(window, "__hermCPSLActionState", {
            value: {next: 1, ids: new WeakMap()},
            configurable: false,
            enumerable: false,
            writable: false
          });
        }
        const existing = window.__hermCPSLActionState.ids.get(element);
        if (existing) return existing;
        const id = "a" + window.__hermCPSLActionState.next++;
        window.__hermCPSLActionState.ids.set(element, id);
        element.setAttribute(attribute, id);
        return id;
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
      function isInViewport(element) {
        const rect = element.getBoundingClientRect();
        return rect.bottom > 0 && rect.right > 0 && rect.top < window.innerHeight && rect.left < window.innerWidth;
      }
      const candidates = Array.from(document.querySelectorAll(
        "a[href],button,input,textarea,select,[role='button'],[role='link']," +
        "[role='menuitem'],[role='menuitemcheckbox'],[role='menuitemradio'],[role='option']," +
        "[role='tab'],[role='checkbox'],[role='radio'],[role='switch'],[contenteditable='true']"
      ));
      const renderedCandidates = candidates.filter(isVisible);
      const viewportCandidates = renderedCandidates.filter(isInViewport);
      const offscreenCandidates = renderedCandidates.filter((element) => !isInViewport(element));
      const orderedCandidates = viewportCandidates.concat(offscreenCandidates);
      const actionLimit = 120;
      const actions = [];
      for (const element of orderedCandidates) {
        const rect = element.getBoundingClientRect();
        const inViewport = isInViewport(element);
        const id = actionIDFor(element);
        actions.push({
          id,
          index: actions.length + 1,
          tag: element.localName,
          type: element.getAttribute("type") || element.getAttribute("role") || "",
          label: labelFor(element),
          text: (element.innerText || "").trim().replace(/\\s+/g, " ").slice(0, 240),
          href: element.href || "",
          selector: "[data-herm-cpsl-action-id='" + cssEscape(id) + "']",
          x: Math.round(rect.left + rect.width / 2),
          y: Math.round(rect.top + rect.height / 2),
          width: Math.round(rect.width),
          height: Math.round(rect.height),
          inViewport
        });
        if (actions.length >= actionLimit) break;
      }
      const dialogs = Array.from(document.querySelectorAll(
        "dialog[open],[role='dialog'],[aria-modal='true']"
      )).filter(isVisible).map((element, index) => {
        const rect = element.getBoundingClientRect();
        return {
          index: index + 1,
          label: labelFor(element),
          text: (element.innerText || "").trim().replace(/\\s+/g, " ").slice(0, 1200),
          modal: element.getAttribute("aria-modal") === "true" || element.localName === "dialog",
          selector: selectorFor(element),
          x: Math.round(rect.left + rect.width / 2),
          y: Math.round(rect.top + rect.height / 2),
          width: Math.round(rect.width),
          height: Math.round(rect.height)
        };
      }).slice(0, 12);
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
        actionCandidates: {
          rendered: renderedCandidates.length,
          inViewport: viewportCandidates.length,
          returned: actions.length,
          limit: actionLimit
        },
        dialogs,
        viewport: {
          width: window.innerWidth,
          height: window.innerHeight,
          devicePixelRatio: window.devicePixelRatio || 1
        },
        resources,
        resourceCount: performance.getEntriesByType("resource").length,
        htmlBytes: html.length,
        textBytes: text.length,
        loading: document.readyState !== "complete",
        readyState: document.readyState
      });
    })()
    """

    func inputTraceStartScript(transactionID: String) throws -> String {
        let transactionID = try Self.javaScriptLiteral(transactionID)
        return """
        (() => {
          const transactionID = \(transactionID);
          const state = window.__hermCPSLInputTrace || {events: [], installed: false, current: null};
          window.__hermCPSLInputTrace = state;
          function describe(target) {
            if (!target || target.nodeType !== 1) return {};
            const isRich = target.isContentEditable || target.getAttribute("contenteditable") === "true";
            const value = "value" in target && !isRich
              ? target.value || ""
              : target.innerText || target.textContent || "";
            return {
              action: target.getAttribute("data-herm-cpsl-action-id") || "",
              tag: target.localName || "",
              role: target.getAttribute("role") || "",
              type: target.getAttribute("type") || "",
              inputMode: target.getAttribute("inputmode") || "",
              label: target.getAttribute("aria-label") || target.getAttribute("placeholder") || "",
              valueLength: value.length,
              connected: target.isConnected !== false
            };
          }
          if (!state.installed) {
            const record = (event) => {
              const trace = window.__hermCPSLInputTrace;
              if (!trace || !trace.current) return;
              const target = event.target === document ? document.activeElement : event.target;
              trace.events.push(Object.assign({
                transactionID: trace.current,
                event: event.type,
                inputType: event.inputType || "",
                isTrusted: event.isTrusted === true,
                dataLength: typeof event.data === "string" ? event.data.length : 0,
                timestamp: performance.now()
              }, describe(target)));
              if (trace.events.length > 200) trace.events.splice(0, trace.events.length - 200);
            };
            ["focusin", "focusout", "beforeinput", "input", "change", "selectionchange"].forEach((name) => {
              document.addEventListener(name, record, true);
            });
            state.installed = true;
          }
          state.current = transactionID;
          state.events.push(Object.assign({
            transactionID,
            event: "transactionStart",
            timestamp: performance.now()
          }, describe(document.activeElement)));
          return JSON.stringify({ok: true, transactionID});
        })()
        """
    }

    func inputTraceFinishScript(transactionID: String) throws -> String {
        let transactionID = try Self.javaScriptLiteral(transactionID)
        return """
        (() => {
          const transactionID = \(transactionID);
          const state = window.__hermCPSLInputTrace;
          if (!state) return JSON.stringify({events: [], error: "trace state missing"});
          const active = document.activeElement;
          const isRich = !!active && (active.isContentEditable || active.getAttribute?.("contenteditable") === "true");
          const value = active && "value" in active && !isRich
            ? active.value || ""
            : active?.innerText || active?.textContent || "";
          const result = {
            events: state.events.filter((event) => event.transactionID === transactionID).slice(-100),
            activeElement: active ? {
              action: active.getAttribute?.("data-herm-cpsl-action-id") || "",
              tag: active.localName || "",
              role: active.getAttribute?.("role") || "",
              inputMode: active.getAttribute?.("inputmode") || "",
              label: active.getAttribute?.("aria-label") || active.getAttribute?.("placeholder") || "",
              valueLength: value.length
            } : null
          };
          if (state.current === transactionID) state.current = null;
          return JSON.stringify(result);
        })()
        """
    }

    func clickScript(selector: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        return """
        (() => {
          const element = document.querySelector(\(selector));
          if (!element) return JSON.stringify({ok:false,error:"action not found"});
          element.scrollIntoView({block:"center", inline:"center"});
          element.click();
          return JSON.stringify({ok:true});
        })()
        """
    }

    func controlledFocusScript(selector: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        return """
        (() => {
          const prior = window.__hermCPSLControlledFocus;
          if (prior?.element) {
            if (prior.hadInputMode) prior.element.setAttribute("inputmode", prior.inputMode);
            else prior.element.removeAttribute("inputmode");
            if (document.activeElement === prior.element) prior.element.blur();
          }
          const element = document.querySelector(\(selector));
          if (!element) return JSON.stringify({ok:false,error:"action not found"});
          const hadInputMode = element.hasAttribute("inputmode");
          const inputMode = element.getAttribute("inputmode") || "";
          window.__hermCPSLControlledFocus = {element, hadInputMode, inputMode};
          element.setAttribute("inputmode", "none");
          element.scrollIntoView({block:"center", inline:"center"});
          if (element.focus) element.focus({preventScroll:true});
          const active = document.activeElement;
          const focused = active === element || element.contains(active);
          return JSON.stringify({
            ok: focused,
            error: focused ? null : "action did not receive controlled focus",
            inputMode: element.getAttribute("inputmode") || ""
          });
        })()
        """
    }

    func controlledBlurScript(selector: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        return """
        (() => {
          const state = window.__hermCPSLControlledFocus;
          const current = document.querySelector(\(selector));
          const element = state?.element || current;
          if (element) {
            const active = document.activeElement;
            if (active === element || element.contains(active)) {
              if (active?.blur) active.blur();
              else if (element.blur) element.blur();
            }
            if (state?.hadInputMode) element.setAttribute("inputmode", state.inputMode);
            else if (state) element.removeAttribute("inputmode");
          }
          window.__hermCPSLControlledFocus = null;
          return JSON.stringify({ok:true,restored:!!state,connected:element?.isConnected !== false});
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
          const textValue = \(value);
          const isRichText = element.isContentEditable || element.getAttribute("contenteditable") === "true";
          function fireInput(target, data) {
            if (window.InputEvent) {
              target.dispatchEvent(new InputEvent("input", {bubbles:true, data, inputType:"insertReplacementText"}));
            } else {
              target.dispatchEvent(new Event("input", {bubbles:true}));
            }
            target.dispatchEvent(new Event("change", {bubbles:true}));
          }
          const hadInputMode = element.hasAttribute("inputmode");
          const inputMode = element.getAttribute("inputmode") || "";
          element.setAttribute("inputmode", "none");
          try {
            element.scrollIntoView({block:"center", inline:"center"});
            if (element.focus) element.focus({preventScroll:true});
            if ("value" in element && !isRichText) {
              const prototype = element instanceof HTMLTextAreaElement
                ? HTMLTextAreaElement.prototype
                : HTMLInputElement.prototype;
              const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
              if (setter) setter.call(element, textValue);
              else element.value = textValue;
              fireInput(element, textValue);
            } else if (isRichText) {
              const selection = window.getSelection();
              if (!selection) return JSON.stringify({ok:false,error:"editor selection is unavailable"});
              const range = document.createRange();
              range.selectNodeContents(element);
              selection.removeAllRanges();
              selection.addRange(range);
              let edited = textValue.length === 0 && (element.innerText || element.textContent || "").length === 0;
              if (!edited) {
                try {
                  edited = textValue.length === 0
                    ? document.execCommand("delete", false, null)
                    : document.execCommand("insertText", false, textValue);
                } catch (error) {}
              }
              if (!edited) return JSON.stringify({ok:false,error:"browser editor rejected replacement text"});
            } else {
              return JSON.stringify({ok:false,error:"action does not accept text"});
            }
            return JSON.stringify({ok:true});
          } finally {
            const active = document.activeElement;
            if (active === element || element.contains(active)) {
              if (active?.blur) active.blur();
              else if (element.blur) element.blur();
            }
            if (hadInputMode) element.setAttribute("inputmode", inputMode);
            else element.removeAttribute("inputmode");
          }
        })()
        """
    }

    func focusScript(selector: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        return """
        (() => {
          const element = document.querySelector(\(selector));
          if (!element) return JSON.stringify({ok:false,error:"action not found"});
          element.scrollIntoView({block:"center", inline:"center"});
          if (element.focus) element.focus({preventScroll:true});
          const active = document.activeElement;
          const focused = active === element || element.contains(active);
          return JSON.stringify({ok:focused,error:focused ? null : "action did not receive focus"});
        })()
        """
    }

    func appendTextScript(selector: String, value: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        let value = try Self.javaScriptLiteral(value)
        return """
        (() => {
          const element = document.querySelector(\(selector));
          if (!element) return JSON.stringify({ok:false,error:"action not found"});
          const textValue = \(value);
          if (textValue.includes("\\n") || textValue.includes("\\r") || textValue.includes("\\t")) {
            return JSON.stringify({ok:false,error:"use webbrowser.key_press for control keys"});
          }
          const isRichText = element.isContentEditable || element.getAttribute("contenteditable") === "true";
          function fireInput(target) {
            if (window.InputEvent) {
              target.dispatchEvent(new InputEvent("input", {bubbles:true, data:textValue, inputType:"insertText"}));
            } else {
              target.dispatchEvent(new Event("input", {bubbles:true}));
            }
            target.dispatchEvent(new Event("change", {bubbles:true}));
          }
          function collapseSelectionToEnd(target) {
            const selection = window.getSelection();
            if (!selection) return;
            if (selection.rangeCount && target.contains(selection.anchorNode)) return;
            const range = document.createRange();
            range.selectNodeContents(target);
            range.collapse(false);
            selection.removeAllRanges();
            selection.addRange(range);
          }
          const hadInputMode = element.hasAttribute("inputmode");
          const inputMode = element.getAttribute("inputmode") || "";
          element.setAttribute("inputmode", "none");
          try {
            if (element.focus) element.focus({preventScroll:true});
            if ("value" in element && !isRichText) {
              const start = typeof element.selectionStart === "number" ? element.selectionStart : (element.value || "").length;
              const end = typeof element.selectionEnd === "number" ? element.selectionEnd : start;
              if (element.setRangeText) {
                element.setRangeText(textValue, start, end, "end");
              } else {
                const current = element.value || "";
                element.value = current.slice(0, start) + textValue + current.slice(end);
              }
              fireInput(element);
            } else if (isRichText) {
              collapseSelectionToEnd(element);
              let inserted = false;
              try {
                inserted = document.execCommand("insertText", false, textValue);
              } catch (error) {}
              if (!inserted) {
                return JSON.stringify({ok:false,error:"browser editor rejected typed text"});
              }
            } else {
              return JSON.stringify({ok:false,error:"action does not accept text"});
            }
            return JSON.stringify({ok:true});
          } finally {
            const active = document.activeElement;
            if (active === element || element.contains(active)) {
              if (active?.blur) active.blur();
              else if (element.blur) element.blur();
            }
            if (hadInputMode) element.setAttribute("inputmode", inputMode);
            else element.removeAttribute("inputmode");
          }
        })()
        """
    }

    func keyPressScript(selector: String, key: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        let key = try Self.javaScriptLiteral(key)
        return """
        (() => {
          const element = document.querySelector(\(selector));
          if (!element) return JSON.stringify({ok:false,error:"action not found"});
          const key = \(key);
          if (!key) return JSON.stringify({ok:false,error:"missing key"});
          const keyCodes = {Enter:13, Escape:27, Tab:9, Backspace:8, Delete:46, ArrowLeft:37, ArrowUp:38, ArrowRight:39, ArrowDown:40, Home:36, End:35, PageUp:33, PageDown:34};
          const keyCode = keyCodes[key] || 0;
          const options = {bubbles:true, cancelable:true, key, code:key, keyCode, which:keyCode};
          const hadInputMode = element.hasAttribute("inputmode");
          const inputMode = element.getAttribute("inputmode") || "";
          element.setAttribute("inputmode", "none");
          try {
            element.scrollIntoView({block:"center", inline:"center"});
            if (element.focus) element.focus({preventScroll:true});
            const keydown = new KeyboardEvent("keydown", options);
            const accepted = element.dispatchEvent(keydown);
            const keyupTarget = document.activeElement || element;
            keyupTarget.dispatchEvent(new KeyboardEvent("keyup", options));
            const pageConsumed = keydown.defaultPrevented || !accepted;
            return JSON.stringify({
              ok: true,
              dispatched: true,
              pageConsumed,
              defaultPrevented: keydown.defaultPrevented,
              eventTrusted: keydown.isTrusted === true
            });
          } finally {
            const active = document.activeElement;
            if (active === element || element.contains(active)) {
              if (active?.blur) active.blur();
              else if (element.blur) element.blur();
            }
            if (hadInputMode) element.setAttribute("inputmode", inputMode);
            else element.removeAttribute("inputmode");
          }
        })()
        """
    }

    func actionStateScript(selector: String) throws -> String {
        let selector = try Self.javaScriptLiteral(selector)
        return """
        (() => {
          const element = document.querySelector(\(selector));
          if (!element) return JSON.stringify({exists:false,focused:false,value:""});
          const active = document.activeElement;
          const isRichText = element.isContentEditable || element.getAttribute("contenteditable") === "true";
          const value = "value" in element && !isRichText
            ? element.value || ""
            : element.innerText || element.textContent || "";
          return JSON.stringify({
            exists: true,
            focused: active === element || element.contains(active),
            tag: element.localName || "",
            type: element.getAttribute("type") || element.getAttribute("role") || "",
            label: element.getAttribute("aria-label") || element.getAttribute("placeholder") || "",
            value
          });
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
          if (type === "click" && element.click) {
            element.click();
          } else {
            element.dispatchEvent(new MouseEvent(eventType, {bubbles:true, cancelable:true, clientX:x, clientY:y, view:window}));
          }
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

    static func renderedEvalScript(script: String, functionBody: Bool) -> String {
        let valueExpression = functionBody ? "(function(){\(script)})()" : "(\(script))"
        return """
        (() => {
          function render(value) {
            if (value === undefined) return "undefined";
            if (value === null) return "null";
            if (typeof value === "string") return value;
            try {
              return JSON.stringify(value);
            } catch (error) {
              return String(value);
            }
          }
          return render(\(valueExpression));
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
        case "Enter", "\n", "\r":
            characters = "\r"
            charactersIgnoringModifiers = "\r"
            modifiers = []
            keyCode = 36
        case "Tab", "\t":
            characters = "\t"
            charactersIgnoringModifiers = "\t"
            modifiers = []
            keyCode = 48
        case "Escape":
            characters = "\u{1B}"
            charactersIgnoringModifiers = "\u{1B}"
            modifiers = []
            keyCode = 53
        case "Backspace":
            characters = "\u{8}"
            charactersIgnoringModifiers = "\u{8}"
            modifiers = []
            keyCode = 51
        case "Delete":
            characters = "\u{7F}"
            charactersIgnoringModifiers = "\u{7F}"
            modifiers = []
            keyCode = 117
        case "ArrowLeft":
            characters = "\u{F702}"
            charactersIgnoringModifiers = "\u{F702}"
            modifiers = []
            keyCode = 123
        case "ArrowRight":
            characters = "\u{F703}"
            charactersIgnoringModifiers = "\u{F703}"
            modifiers = []
            keyCode = 124
        case "ArrowDown":
            characters = "\u{F701}"
            charactersIgnoringModifiers = "\u{F701}"
            modifiers = []
            keyCode = 125
        case "ArrowUp":
            characters = "\u{F700}"
            charactersIgnoringModifiers = "\u{F700}"
            modifiers = []
            keyCode = 126
        case "Home":
            characters = "\u{F729}"
            charactersIgnoringModifiers = "\u{F729}"
            modifiers = []
            keyCode = 115
        case "End":
            characters = "\u{F72B}"
            charactersIgnoringModifiers = "\u{F72B}"
            modifiers = []
            keyCode = 119
        case "PageUp":
            characters = "\u{F72C}"
            charactersIgnoringModifiers = "\u{F72C}"
            modifiers = []
            keyCode = 116
        case "PageDown":
            characters = "\u{F72D}"
            charactersIgnoringModifiers = "\u{F72D}"
            modifiers = []
            keyCode = 121
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
