//
//  ContentView.swift
//  herm
//
//  Created by Gaetan de Villele on 6/19/26.
//

import Foundation
import Dispatch
import Combine
import SwiftUI
import CPSL

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    var body: some View {
        CPSLTerminalView()
    }
}

private typealias CPSLBootstrapResult = (
    abiVersion: UInt32,
    metadataJSON: String?,
    metadataError: String?,
    rootPath: String?,
    workdirPath: String?,
    sessionError: String?
)

private typealias CPSLEvalServiceResult = (
    rawJSON: String?,
    stdout: String,
    stderr: String,
    exitCode: Int?,
    ok: Bool?,
    cwd: String?,
    errorCode: String?,
    errorMessage: String?,
    warnings: [String],
    ffiError: String?
)

private nonisolated enum CPSLDebugMessages {
    static let timedOutRestart = "CPSL session timed out. Restart the app to run more commands."
}

private nonisolated struct CPSLSessionHandle {
    let id: Int
    let pointer: OpaquePointer
}

private nonisolated struct CPSLBlockingEvalRequest: @unchecked Sendable {
    let session: OpaquePointer
    let requestJSON: String
}

private nonisolated enum CPSLEvalRaceResult: Sendable {
    case completed(CPSLEvalServiceResult)
    case timedOut
}

private nonisolated final class CPSLEvalRaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ result: CPSLEvalRaceResult,
        continuation: CheckedContinuation<CPSLEvalRaceResult, Never>,
        beforeResume: (@Sendable () -> Void)? = nil
    ) {
        lock.lock()
        let shouldResume = !didResume
        if shouldResume {
            didResume = true
        }
        lock.unlock()

        if shouldResume {
            beforeResume?()
            continuation.resume(returning: result)
        }
    }
}

// Survives view/model recreation after a timed-out cpsl_eval leaks its session.
private nonisolated final class CPSLProcessPoisonState: @unchecked Sendable {
    static let shared = CPSLProcessPoisonState()

    private let lock = NSLock()
    private var poisoned = false

    private init() {}

    func poison() {
        lock.lock()
        poisoned = true
        lock.unlock()
    }

    func isPoisoned() -> Bool {
        lock.lock()
        let value = poisoned
        lock.unlock()
        return value
    }
}

private struct CPSLSandboxURLs {
    let root: URL
    let workdir: URL
}

private struct CPSLTerminalView: View {
    @StateObject private var model = CPSLTerminalModel()

    var body: some View {
        VStack(spacing: 0) {
            CPSLTerminalTextArea(
                text: Binding(
                    get: { model.terminalText },
                    set: { model.handleTerminalTextChange($0) }
                ),
                editableStartUTF16: model.editableStartUTF16,
                isEditable: model.canEdit,
                onReturnKey: {
                    model.handleReturnKey()
                },
                onClear: {
                    model.clearTerminal()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button {
                    model.clearTerminal()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("k", modifiers: [.command])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .cpslTerminalBackground()
        .cpslDebugWindowFrame()
        .task {
            await model.start()
        }
    }
}

@MainActor
private final class CPSLTerminalModel: ObservableObject {
    @Published var terminalText = "Starting CPSL...\n"
    @Published private(set) var editableStartUTF16 = ("Starting CPSL...\n" as NSString).length
    @Published private(set) var isRunning = false

    private let service = CPSLDebugService()
    private var didStart = false
    private var sessionReady = false
    private var terminalError: String?
    private var currentCWD = "/workdir"

    var canEdit: Bool {
        sessionReady && terminalError == nil && !isRunning
    }

    func start() async {
        guard !didStart else {
            return
        }
        didStart = true

        let result = await service.bootstrap()
        if result.abiVersion > 0 {
            appendLogLine("CPSL ABI \(result.abiVersion)")
        }
        if let rootPath = result.rootPath {
            appendLogLine("mount \(rootPath) -> /")
        }
        if let workdirPath = result.workdirPath {
            appendLogLine("mount \(workdirPath) -> /workdir")
        }
        if let metadataJSON = result.metadataJSON {
            appendLogBlock("metadata", prettyJSON(metadataJSON))
        }
        if let metadataError = result.metadataError {
            appendLogLine("error: Metadata: \(metadataError)")
        }
        if let sessionError = result.sessionError {
            if sessionError == CPSLDebugMessages.timedOutRestart {
                terminalError = sessionError
            }
            appendLogLine("error: Session init: \(sessionError)")
            return
        }

        sessionReady = true
        appendLogLine("Session ready")
        appendPrompt()
    }

    func handleTerminalTextChange(_ newText: String) {
        guard canEdit else {
            return
        }

        let lockedPrefix = (terminalText as NSString).substring(
            to: min(editableStartUTF16, (terminalText as NSString).length)
        )
        guard newText.hasPrefix(lockedPrefix) else {
            return
        }

        terminalText = newText
    }

    func handleReturnKey() {
        guard canEdit else {
            return
        }

        if currentInput().hasSuffix("\\") {
            removeTrailingBackslash()
            terminalText.append("\n")
            return
        }

        runCurrentCommand()
    }

    func clearTerminal() {
        terminalText = ""
        editableStartUTF16 = 0
        if canEdit {
            appendPrompt()
        }
    }

    private func runCurrentCommand() {
        let input = currentInput()
        terminalText.append("\n")
        editableStartUTF16 = terminalTextUTF16Length

        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appendPrompt()
            return
        }

        isRunning = true

        Task {
            let result = await service.evaluate(input)
            applyEvalResult(result)
            isRunning = false
            if terminalError == nil {
                appendPrompt()
            }
        }
    }

    private func currentInput() -> String {
        let text = terminalText as NSString
        guard editableStartUTF16 < text.length else {
            return ""
        }
        return text.substring(from: editableStartUTF16)
    }

    private func removeTrailingBackslash() {
        let text = terminalText as NSString
        guard text.length > editableStartUTF16 else {
            return
        }

        let mutable = NSMutableString(string: terminalText)
        mutable.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        terminalText = mutable as String
    }

    private func applyEvalResult(_ result: CPSLEvalServiceResult) {
        if let cwd = result.cwd, !cwd.isEmpty {
            currentCWD = cwd
        }
        if result.errorCode == "timeout" {
            terminalError = CPSLDebugMessages.timedOutRestart
        }

        if let ffiError = result.ffiError {
            appendLogLine("error: \(ffiError)")
            return
        }

        for warning in result.warnings {
            appendLogLine("warn: \(warning)")
        }
        if !result.stdout.isEmpty {
            terminalText.append(result.stdout)
        }
        if !result.stderr.isEmpty {
            terminalText.append(result.stderr)
        }
        if let errorMessage = result.errorMessage {
            let prefix = result.errorCode.map { "error[\($0)]: " } ?? "error: "
            appendLogLine("\(prefix)\(errorMessage)")
        }
        if result.errorCode == "invalid_response", let rawJSON = result.rawJSON {
            appendLogBlock("raw", rawJSON)
        }

    }

    private func appendPrompt() {
        ensureTerminalEndsWithNewline()
        terminalText.append("sandbox:\(currentCWD)$ ")
        editableStartUTF16 = terminalTextUTF16Length
    }

    private func appendLogLine(_ line: String) {
        ensureTerminalEndsWithNewline()
        terminalText.append(line)
        terminalText.append("\n")
        editableStartUTF16 = terminalTextUTF16Length
    }

    private func appendLogBlock(_ label: String, _ block: String) {
        ensureTerminalEndsWithNewline()
        terminalText.append("\(label):\n")
        terminalText.append(block)
        ensureTerminalEndsWithNewline()
        editableStartUTF16 = terminalTextUTF16Length
    }

    private func ensureTerminalEndsWithNewline() {
        if !terminalText.isEmpty && !terminalText.hasSuffix("\n") {
            terminalText.append("\n")
        }
    }

    private var terminalTextUTF16Length: Int {
        (terminalText as NSString).length
    }

    private func prettyJSON(_ raw: String) -> String {
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return raw
        }
        return pretty
    }
}

#if os(macOS)
private struct CPSLTerminalTextArea: NSViewRepresentable {
    @Binding var text: String
    let editableStartUTF16: Int
    let isEditable: Bool
    let onReturnKey: () -> Void
    let onClear: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false

        let textView = CPSLTerminalNSTextView()
        textView.terminalDelegate = context.coordinator
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.insertionPointColor = .textColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))

        scrollView.documentView = textView

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.scrollToEndOfDocument(nil)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? CPSLTerminalNSTextView else {
            return
        }

        textView.isEditable = isEditable
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.scrollToEndOfDocument(nil)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, CPSLTerminalNSTextViewDelegate {
        var parent: CPSLTerminalTextArea

        init(_ parent: CPSLTerminalTextArea) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            parent.text = textView.string
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            parent.isEditable && affectedCharRange.location >= parent.editableStartUTF16
        }

        func terminalTextViewDidRequestReturn(_ textView: NSTextView) {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            parent.onReturnKey()
        }

        func terminalTextViewDidRequestClear(_ textView: NSTextView) {
            parent.onClear()
        }
    }
}

private protocol CPSLTerminalNSTextViewDelegate: AnyObject {
    func terminalTextViewDidRequestReturn(_ textView: NSTextView)
    func terminalTextViewDidRequestClear(_ textView: NSTextView)
}

private final class CPSLTerminalNSTextView: NSTextView {
    weak var terminalDelegate: CPSLTerminalNSTextViewDelegate?

    override func keyDown(with event: NSEvent) {
        if event.isCommandKey("k") {
            terminalDelegate?.terminalTextViewDidRequestClear(self)
            return
        }

        if event.isPlainReturn {
            terminalDelegate?.terminalTextViewDidRequestReturn(self)
            return
        }

        super.keyDown(with: event)
    }
}

private extension NSEvent {
    var isPlainReturn: Bool {
        let flags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad])
        return flags.isEmpty && (keyCode == 36 || keyCode == 76)
    }

    func isCommandKey(_ key: String) -> Bool {
        let flags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock])
        return flags == .command && charactersIgnoringModifiers?.lowercased() == key
    }
}
#elseif canImport(UIKit)
private struct CPSLTerminalTextArea: UIViewRepresentable {
    @Binding var text: String
    let editableStartUTF16: Int
    let isEditable: Bool
    let onReturnKey: () -> Void
    let onClear: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> CPSLTerminalUITextView {
        let textView = CPSLTerminalUITextView()
        textView.delegate = context.coordinator
        textView.onClear = onClear
        textView.text = text
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.smartInsertDeleteType = .no
        textView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.tintColor = .label
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)

        DispatchQueue.main.async {
            textView.becomeFirstResponder()
        }

        return textView
    }

    func updateUIView(_ textView: CPSLTerminalUITextView, context: Context) {
        context.coordinator.parent = self
        textView.onClear = onClear
        textView.isEditable = isEditable
        if textView.text != text {
            textView.text = text
            textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            textView.scrollRangeToVisible(textView.selectedRange)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CPSLTerminalTextArea

        init(_ parent: CPSLTerminalTextArea) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            if text == "\n" {
                textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)
                parent.onReturnKey()
                return false
            }
            return parent.isEditable && range.location >= parent.editableStartUTF16
        }
    }
}

private final class CPSLTerminalUITextView: UITextView {
    var onClear: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                input: "k",
                modifierFlags: .command,
                action: #selector(clearTerminal)
            )
        ]
    }

    @objc private func clearTerminal() {
        onClear?()
    }
}
#endif

private actor CPSLDebugService {
    private nonisolated static let evalTimeoutMilliseconds: UInt64 = 10_000
    private nonisolated static let poisonState = CPSLProcessPoisonState.shared

    private var session: CPSLSessionHandle?
    private var nextSessionID = 0
    private var evaluatingSessionID: Int?
    private var sandboxURLs: CPSLSandboxURLs?

    deinit {
        if let session {
            cpsl_session_free(session.pointer)
        }
    }

    func bootstrap() -> CPSLBootstrapResult {
        guard !Self.poisonState.isPoisoned() else {
            return (
                abiVersion: 0,
                metadataJSON: nil,
                metadataError: nil,
                rootPath: nil,
                workdirPath: nil,
                sessionError: CPSLDebugMessages.timedOutRestart
            )
        }

        let abiVersion = cpsl_abi_version()
        let metadata = loadMetadataJSON()

        do {
            let sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            let sessionError = initializeSessionIfNeeded(sandboxURLs: sandboxURLs)
            return (
                abiVersion: abiVersion,
                metadataJSON: metadata.json,
                metadataError: metadata.error,
                rootPath: sandboxURLs.root.resolvingSymlinksInPath().path,
                workdirPath: sandboxURLs.workdir.resolvingSymlinksInPath().path,
                sessionError: sessionError
            )
        } catch {
            return (
                abiVersion: abiVersion,
                metadataJSON: metadata.json,
                metadataError: metadata.error,
                rootPath: nil,
                workdirPath: nil,
                sessionError: "Workspace setup failed: \(error.localizedDescription)"
            )
        }
    }

    func evaluate(_ command: String) async -> CPSLEvalServiceResult {
        guard !Self.poisonState.isPoisoned() else {
            return Self.poisonedFailure()
        }

        let sandboxURLs: CPSLSandboxURLs
        do {
            sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
        } catch {
            return Self.ffiFailure("Workspace setup failed: \(error.localizedDescription)")
        }

        if let sessionError = initializeSessionIfNeeded(sandboxURLs: sandboxURLs) {
            return Self.ffiFailure("Session init: \(sessionError)")
        }

        guard let requestJSON = makeEvalRequestJSON(command: command) else {
            return Self.ffiFailure("Could not encode eval request JSON")
        }

        guard let activeSession = session else {
            return Self.ffiFailure("CPSL session is not initialized")
        }

        guard evaluatingSessionID != activeSession.id else {
            return Self.ffiFailure("CPSL eval is already running")
        }

        evaluatingSessionID = activeSession.id
        let request = CPSLBlockingEvalRequest(
            session: activeSession.pointer,
            requestJSON: requestJSON
        )

        switch await Self.performBlockingEvalWithTimeout(request) {
        case .completed(let result):
            if evaluatingSessionID == activeSession.id {
                evaluatingSessionID = nil
            }
            return result
        case .timedOut:
            if session?.id == activeSession.id {
                // cpsl_eval may still be blocked; abandon and intentionally leak this debug session.
                session = nil
            }
            return Self.timeoutFailure()
        }
    }

    private func loadMetadataJSON() -> (json: String?, error: String?) {
        guard let pointer = cpsl_backend_metadata_json() else {
            return (nil, Self.lastErrorMessage(fallback: "cpsl_backend_metadata_json returned NULL"))
        }
        defer {
            cpsl_string_free(pointer)
        }
        return (String(cString: pointer), nil)
    }

    private func initializeSessionIfNeeded(sandboxURLs: CPSLSandboxURLs) -> String? {
        guard session == nil else {
            return nil
        }
        guard let configJSON = makeSessionConfigJSON(
            rootPath: sandboxURLs.root.resolvingSymlinksInPath().path,
            workdirPath: sandboxURLs.workdir.resolvingSymlinksInPath().path
        ) else {
            return "Could not encode session config JSON"
        }

        let newSession = configJSON.withCString { configPointer in
            cpsl_session_new(configPointer)
        }
        guard let newSession else {
            return Self.lastErrorMessage(fallback: "cpsl_session_new returned NULL")
        }

        nextSessionID += 1
        session = CPSLSessionHandle(id: nextSessionID, pointer: newSession)
        return nil
    }

    private func ensureSandboxURLs() throws -> CPSLSandboxURLs {
        if let sandboxURLs {
            return sandboxURLs
        }

        let fileManager = FileManager.default
        let supportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "herm"
        let appURL = supportURL.appendingPathComponent(bundleID, isDirectory: true)
        let sandboxURL = appURL.appendingPathComponent("CPSLDebugSandbox", isDirectory: true)
        let rootURL = sandboxURL.appendingPathComponent("root", isDirectory: true)
        let workdirURL = sandboxURL.appendingPathComponent("workdir", isDirectory: true)
        let sandboxURLs = CPSLSandboxURLs(root: rootURL, workdir: workdirURL)

        try ensureSandboxScaffold(sandboxURLs)
        return sandboxURLs
    }

    private func ensureSandboxScaffold(_ sandboxURLs: CPSLSandboxURLs) throws {
        let fileManager = FileManager.default
        let directoryNames = [
            "",
            "bin",
            "etc",
            "home",
            "root",
            "tmp",
            "usr",
            "var"
        ]

        for name in directoryNames {
            let url = name.isEmpty ? sandboxURLs.root : sandboxURLs.root.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: sandboxURLs.workdir, withIntermediateDirectories: true)

        try writeFileIfMissing(
            sandboxURLs.root.appendingPathComponent("etc/hosts", isDirectory: false),
            contents: "127.0.0.1 localhost\n"
        )
        try writeFileIfMissing(
            sandboxURLs.root.appendingPathComponent("etc/passwd", isDirectory: false),
            contents: "root:x:0:0:root:/root:/bin/sh\n"
        )
    }

    private func writeFileIfMissing(_ url: URL, contents: String) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeSessionConfigJSON(rootPath: String, workdirPath: String) -> String? {
        let config: [String: Any] = [
            "mounts": [
                [
                    "host": rootPath,
                    "virtual": "/",
                    "mode": "rw"
                ],
                [
                    "host": workdirPath,
                    "virtual": "/workdir",
                    "mode": "rw"
                ]
            ],
            "initial_cwd": "/workdir",
            "language": "bash",
            "http": [
                "mode": "policy",
                "allow_domains": [] as [String],
                "deny_domains": [] as [String]
            ]
        ]
        return jsonString(config)
    }

    private func makeEvalRequestJSON(command: String) -> String? {
        let request: [String: Any] = [
            "language": "bash",
            "input": command,
            "timeout_ms": Int(Self.evalTimeoutMilliseconds)
        ]
        return jsonString(request)
    }

    private func jsonString(_ object: Any) -> String? {
        guard
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return json
    }

    private nonisolated static func performBlockingEvalWithTimeout(
        _ request: CPSLBlockingEvalRequest
    ) async -> CPSLEvalRaceResult {
        await withCheckedContinuation { continuation in
            let race = CPSLEvalRaceBox()

            DispatchQueue.global(qos: .userInitiated).async {
                let result = performBlockingEval(request)
                race.resume(.completed(result), continuation: continuation)
            }

            DispatchQueue.global().asyncAfter(
                deadline: .now() + .milliseconds(Int(evalTimeoutMilliseconds))
            ) {
                race.resume(.timedOut, continuation: continuation) {
                    poisonState.poison()
                }
            }
        }
    }

    private nonisolated static func performBlockingEval(
        _ request: CPSLBlockingEvalRequest
    ) -> CPSLEvalServiceResult {
        let responsePointer = request.requestJSON.withCString { requestPointer in
            cpsl_eval(request.session, requestPointer)
        }
        guard let responsePointer else {
            return ffiFailure(lastErrorMessage(fallback: "cpsl_eval returned NULL"))
        }
        defer {
            cpsl_string_free(responsePointer)
        }

        let rawJSON = String(cString: responsePointer)
        return parseEvalResponse(rawJSON: rawJSON)
    }

    private nonisolated static func parseEvalResponse(rawJSON: String) -> CPSLEvalServiceResult {
        guard
            let data = rawJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let response = object as? [String: Any]
        else {
            return (
                rawJSON: rawJSON,
                stdout: "",
                stderr: "",
                exitCode: nil,
                ok: false,
                cwd: nil,
                errorCode: "invalid_response",
                errorMessage: "CPSL returned a non-JSON response",
                warnings: [],
                ffiError: nil
            )
        }

        let error = response["error"] as? [String: Any]
        return (
            rawJSON: rawJSON,
            stdout: response["stdout"] as? String ?? "",
            stderr: response["stderr"] as? String ?? "",
            exitCode: intValue(response["exit_code"]),
            ok: boolValue(response["ok"]),
            cwd: response["cwd"] as? String,
            errorCode: error?["code"] as? String,
            errorMessage: error?["message"] as? String,
            warnings: stringArrayValue(response["warnings"]),
            ffiError: nil
        )
    }

    private nonisolated static func timeoutFailure() -> CPSLEvalServiceResult {
        (
            rawJSON: nil,
            stdout: "",
            stderr: "",
            exitCode: nil,
            ok: false,
            cwd: nil,
            errorCode: "timeout",
            errorMessage: "Command timed out after \(evalTimeoutMilliseconds / 1_000)s. "
                + CPSLDebugMessages.timedOutRestart,
            warnings: [],
            ffiError: nil
        )
    }

    private nonisolated static func poisonedFailure() -> CPSLEvalServiceResult {
        (
            rawJSON: nil,
            stdout: "",
            stderr: "",
            exitCode: nil,
            ok: false,
            cwd: nil,
            errorCode: "timeout",
            errorMessage: CPSLDebugMessages.timedOutRestart,
            warnings: [],
            ffiError: nil
        )
    }

    private nonisolated static func ffiFailure(_ message: String) -> CPSLEvalServiceResult {
        (
            rawJSON: nil,
            stdout: "",
            stderr: "",
            exitCode: nil,
            ok: false,
            cwd: nil,
            errorCode: "ffi_error",
            errorMessage: message,
            warnings: [],
            ffiError: message
        )
    }

    private nonisolated static func lastErrorMessage(fallback: String) -> String {
        guard let pointer = cpsl_last_error() else {
            return fallback
        }
        let message = String(cString: pointer)
        return message.isEmpty ? fallback : message
    }

    private nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private nonisolated static func stringArrayValue(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
        }
        if let values = value as? [Any] {
            return values.map { String(describing: $0) }
        }
        return []
    }
}

private extension View {
    func cpslDebugWindowFrame() -> some View {
        #if os(macOS)
        frame(minWidth: 720, minHeight: 520)
        #else
        frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    func cpslTerminalBackground() -> some View {
        #if os(macOS)
        background(Color(NSColor.cpslTerminalBackground))
        #elseif canImport(UIKit)
        background(Color(UIColor.cpslTerminalBackground))
        #else
        background(Color.clear)
        #endif
    }
}

#if os(macOS)
private extension NSColor {
    static var cpslTerminalBackground: NSColor {
        NSColor.textBackgroundColor
    }
}
#elseif canImport(UIKit)
private extension UIColor {
    static var cpslTerminalBackground: UIColor {
        UIColor.systemBackground
    }
}
#endif
