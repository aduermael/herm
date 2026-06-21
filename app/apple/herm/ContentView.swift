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

struct ContentView: View {
    var body: some View {
        CPSLDebugReplView()
    }
}

private typealias CPSLBootstrapResult = (
    abiVersion: UInt32,
    metadataJSON: String?,
    metadataError: String?,
    workspacePath: String?,
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

private struct CPSLConsoleRow: Identifiable {
    enum Kind {
        case command
        case stdout
        case stderr
        case status
        case warning
        case error
        case metadata
        case raw

        var label: String {
            switch self {
            case .command:
                return "$"
            case .stdout:
                return "out"
            case .stderr:
                return "err"
            case .status:
                return "status"
            case .warning:
                return "warn"
            case .error:
                return "error"
            case .metadata:
                return "meta"
            case .raw:
                return "raw"
            }
        }

        var tint: Color {
            switch self {
            case .command:
                return .accentColor
            case .stdout:
                return .primary
            case .stderr:
                return .orange
            case .status:
                return .secondary
            case .warning:
                return .yellow
            case .error:
                return .red
            case .metadata:
                return .blue
            case .raw:
                return .purple
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

private struct CPSLDebugReplView: View {
    @StateObject private var model = CPSLDebugReplModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            console
            Divider()
            inputArea
        }
        .cpslDebugWindowFrame()
        .task {
            await model.start()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPSL Debug REPL")
                    .font(.headline)
                Spacer(minLength: 12)
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let workspacePath = model.workspacePath {
                Text("mount \(workspacePath) -> /workdir")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let terminalError = model.terminalError {
                Text(terminalError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.rows) { row in
                        CPSLConsoleRowView(row: row)
                            .id(row.id)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.rows.count) { _ in
                guard let lastID = model.rows.last?.id else {
                    return
                }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.command)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 88, maxHeight: 140)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                }

            HStack {
                Button {
                    model.clearRows()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    model.runCommand()
                } label: {
                    if model.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Run", systemImage: "play.fill")
                    }
                }
                .frame(minWidth: 82)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRun)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(16)
    }
}

private struct CPSLConsoleRowView: View {
    let row: CPSLConsoleRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(row.kind.label)
                .font(.caption2.monospaced())
                .foregroundStyle(row.kind.tint)
                .frame(width: 46, alignment: .leading)

            Text(row.text.isEmpty ? "(empty)" : row.text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
private final class CPSLDebugReplModel: ObservableObject {
    @Published var command = "pwd"
    @Published private(set) var rows: [CPSLConsoleRow] = [
        CPSLConsoleRow(kind: .status, text: "Starting CPSL...")
    ]
    @Published private(set) var status = "Initializing"
    @Published private(set) var isRunning = false
    @Published private(set) var workspacePath: String?
    @Published private(set) var terminalError: String?

    private let service = CPSLDebugService()
    private var didStart = false

    var canRun: Bool {
        terminalError == nil && !isRunning && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start() async {
        guard !didStart else {
            return
        }
        didStart = true

        let result = await service.bootstrap()
        workspacePath = result.workspacePath
        if result.abiVersion > 0 {
            rows.append(CPSLConsoleRow(kind: .status, text: "CPSL ABI \(result.abiVersion)"))
        }

        if let metadataJSON = result.metadataJSON {
            rows.append(CPSLConsoleRow(kind: .metadata, text: prettyJSON(metadataJSON)))
        }
        if let metadataError = result.metadataError {
            rows.append(CPSLConsoleRow(kind: .error, text: "Metadata: \(metadataError)"))
        }
        if let sessionError = result.sessionError {
            if sessionError == CPSLDebugMessages.timedOutRestart {
                terminalError = sessionError
                status = "Restart required"
            } else {
                status = "Session failed"
            }
            rows.append(CPSLConsoleRow(kind: .error, text: "Session init: \(sessionError)"))
        } else {
            status = "Ready"
            rows.append(CPSLConsoleRow(kind: .status, text: "Session ready"))
        }
    }

    func runCommand() {
        let input = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, terminalError == nil, !isRunning else {
            return
        }

        rows.append(CPSLConsoleRow(kind: .command, text: input))
        isRunning = true
        status = "Running"

        Task {
            let result = await service.evaluate(input)
            applyEvalResult(result)
            isRunning = false
        }
    }

    func clearRows() {
        rows.removeAll()
    }

    private func applyEvalResult(_ result: CPSLEvalServiceResult) {
        if result.errorCode == "timeout" {
            terminalError = CPSLDebugMessages.timedOutRestart
        }

        if let ffiError = result.ffiError {
            status = "Eval failed"
            rows.append(CPSLConsoleRow(kind: .error, text: ffiError))
            return
        }

        for warning in result.warnings {
            rows.append(CPSLConsoleRow(kind: .warning, text: warning))
        }
        if !result.stdout.isEmpty {
            rows.append(CPSLConsoleRow(kind: .stdout, text: result.stdout))
        }
        if !result.stderr.isEmpty {
            rows.append(CPSLConsoleRow(kind: .stderr, text: result.stderr))
        }
        if let errorMessage = result.errorMessage {
            let prefix = result.errorCode.map { "[\($0)] " } ?? ""
            rows.append(CPSLConsoleRow(kind: .error, text: "\(prefix)\(errorMessage)"))
        }
        if result.errorCode == "invalid_response", let rawJSON = result.rawJSON {
            rows.append(CPSLConsoleRow(kind: .raw, text: rawJSON))
        }

        let summary = statusSummary(for: result)
        status = summary
        rows.append(CPSLConsoleRow(kind: .status, text: summary))
    }

    private func statusSummary(for result: CPSLEvalServiceResult) -> String {
        if result.errorCode == "timeout" {
            return "Restart required"
        }

        var parts: [String] = []
        if let ok = result.ok {
            parts.append(ok ? "ok" : "failed")
        }
        if let exitCode = result.exitCode {
            parts.append("exit \(exitCode)")
        }
        if let cwd = result.cwd, !cwd.isEmpty {
            parts.append("cwd \(cwd)")
        }
        if parts.isEmpty {
            parts.append("completed")
        }
        return parts.joined(separator: " | ")
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

private actor CPSLDebugService {
    private nonisolated static let evalTimeoutMilliseconds: UInt64 = 10_000
    private nonisolated static let poisonState = CPSLProcessPoisonState.shared

    private var session: CPSLSessionHandle?
    private var nextSessionID = 0
    private var evaluatingSessionID: Int?
    private var workspaceURL: URL?

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
                workspacePath: nil,
                sessionError: CPSLDebugMessages.timedOutRestart
            )
        }

        let abiVersion = cpsl_abi_version()
        let metadata = loadMetadataJSON()

        do {
            let workspaceURL = try ensureWorkspaceURL()
            self.workspaceURL = workspaceURL
            let sessionError = initializeSessionIfNeeded(workspaceURL: workspaceURL)
            return (
                abiVersion: abiVersion,
                metadataJSON: metadata.json,
                metadataError: metadata.error,
                workspacePath: workspaceURL.resolvingSymlinksInPath().path,
                sessionError: sessionError
            )
        } catch {
            return (
                abiVersion: abiVersion,
                metadataJSON: metadata.json,
                metadataError: metadata.error,
                workspacePath: nil,
                sessionError: "Workspace setup failed: \(error.localizedDescription)"
            )
        }
    }

    func evaluate(_ command: String) async -> CPSLEvalServiceResult {
        guard !Self.poisonState.isPoisoned() else {
            return Self.poisonedFailure()
        }

        let workspaceURL: URL
        do {
            workspaceURL = try ensureWorkspaceURL()
            self.workspaceURL = workspaceURL
        } catch {
            return Self.ffiFailure("Workspace setup failed: \(error.localizedDescription)")
        }

        if let sessionError = initializeSessionIfNeeded(workspaceURL: workspaceURL) {
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

    private func initializeSessionIfNeeded(workspaceURL: URL) -> String? {
        guard session == nil else {
            return nil
        }
        guard let configJSON = makeSessionConfigJSON(hostPath: workspaceURL.resolvingSymlinksInPath().path) else {
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

    private func ensureWorkspaceURL() throws -> URL {
        if let workspaceURL {
            return workspaceURL
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
        let workspaceURL = appURL.appendingPathComponent("CPSLDebugWorkspace", isDirectory: true)
        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        return workspaceURL
    }

    private func makeSessionConfigJSON(hostPath: String) -> String? {
        let config: [String: Any] = [
            "mounts": [
                [
                    "host": hostPath,
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
            errorMessage: "Command timed out after \(evalTimeoutMilliseconds / 1_000)s. \(CPSLDebugMessages.timedOutRestart)",
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

#Preview {
    ContentView()
}

private extension View {
    @ViewBuilder
    func cpslDebugWindowFrame() -> some View {
        #if os(macOS)
        frame(minWidth: 420, minHeight: 520)
        #else
        frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
