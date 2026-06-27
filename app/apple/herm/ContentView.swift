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
#if canImport(UIKit)
import UIKit
#endif
import CPSL

struct ContentView: View {
    var body: some View {
        CPSLChatScreen()
    }
}

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
        continuation: CheckedContinuation<CPSLEvalRaceResult, Never>
    ) {
        lock.lock()
        let shouldResume = !didResume
        if shouldResume {
            didResume = true
        }
        lock.unlock()

        if shouldResume {
            continuation.resume(returning: result)
        }
    }
}

private struct CPSLSandboxURLs {
    let root: URL
    let workdir: URL
}

private struct CPSLChatScreen: View {
    @StateObject private var model = CPSLChatModel()
    @State private var promptDismissRequest = 0

    var body: some View {
        ZStack {
            CPSLTheme.background.ignoresSafeArea()

            Group {
                if model.isFileBrowserOpen {
                    CPSLFileBrowserView(model: model)
                        .padding(.top, CPSLTheme.topChromeInset)
                        .padding(.bottom, CPSLTheme.bottomChromeInset)
                } else {
                    CPSLChatTimelineView(
                        model: model,
                        topInset: CPSLTheme.topChromeInset,
                        bottomInset: CPSLTheme.bottomChromeInset
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                promptDismissRequest += 1
            }

            CPSLScrollEdgeBlend(edge: .top, height: CPSLTheme.topBlendHeight)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)

            CPSLScrollEdgeBlend(edge: .bottom, height: CPSLTheme.bottomBlendHeight)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                CPSLHeaderView()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        promptDismissRequest += 1
                    }

                Spacer()

                VStack(spacing: 0) {
                    CPSLToolStripView(model: model)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            promptDismissRequest += 1
                        }

                    CPSLPromptComposerView(
                        model: model,
                        dismissKeyboardRequest: promptDismissRequest
                    ) {
                        promptDismissRequest += 1
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(
            "Coming soon",
            isPresented: Binding(
                get: { model.comingSoonMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.comingSoonMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.comingSoonMessage ?? "Coming soon")
        }
    }
}

private enum CPSLTheme {
    static let background = Color(red: 0.047, green: 0.055, blue: 0.094)
    static let surface = Color(red: 0.067, green: 0.082, blue: 0.125)
    static let card = Color(red: 0.086, green: 0.102, blue: 0.165)
    static let elevated = Color(red: 0.106, green: 0.125, blue: 0.204)
    static let controlPressed = Color(red: 0.16, green: 0.15, blue: 0.25)
    static let text = Color(red: 0.941, green: 0.933, blue: 0.914)
    static let secondaryText = Color(red: 0.604, green: 0.616, blue: 0.698)
    static let mutedText = Color(red: 0.345, green: 0.369, blue: 0.447)
    static let mauve = Color(red: 0.49, green: 0.42, blue: 0.78)
    static let command = Color(red: 0.16, green: 0.24, blue: 0.22)
    static let error = Color(red: 0.36, green: 0.16, blue: 0.20)

    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 20

    static let composerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8
    static let rowRadius: CGFloat = 6

    static let controlSize: CGFloat = 38
    static let fileIndent = Self.small + Self.medium
    static let topChromeInset: CGFloat = 104
    static let bottomChromeInset: CGFloat = 264
    static let topBlendHeight: CGFloat = 128
    static let bottomBlendHeight: CGFloat = 284
    static let commandBlockMaxHeight: CGFloat = 320

    static let normalTextSize: CGFloat = 16
    static let largeTextSize: CGFloat = 22

    static let headerFont = Font.system(size: Self.largeTextSize, weight: .semibold)
    static let bodyFont = Font.system(size: Self.normalTextSize, weight: .regular)
    static let monospacedBodyFont = Font.system(size: Self.normalTextSize, weight: .regular, design: .monospaced)
    static let controlFont = Font.system(size: 14, weight: .medium)
    static let rowTitleFont = Font.system(size: 13, weight: .regular)
}

private enum CPSLChatRole {
    case user
    case command
    case output
    case error

    var isTrailingAligned: Bool {
        self == .user
    }

    var isFullWidth: Bool {
        self == .command
    }

    var usesMonospaceBody: Bool {
        self == .command || self == .output || self == .error
    }

    var fill: Color {
        switch self {
        case .user:
            return CPSLTheme.elevated
        case .command:
            return CPSLTheme.command
        case .output:
            return CPSLTheme.surface
        case .error:
            return CPSLTheme.error
        }
    }

    var foreground: Color {
        CPSLTheme.text
    }
}

private struct CPSLChatMessage: Identifiable {
    let id: UUID
    let role: CPSLChatRole
    let title: String?
    let body: String

    init(id: UUID = UUID(), role: CPSLChatRole, title: String?, body: String) {
        self.id = id
        self.role = role
        self.title = title
        self.body = body
    }
}

private struct CPSLFileEntry: Identifiable, Equatable, Sendable {
    var id: String { path }

    let name: String
    let path: String
    let isDirectory: Bool
}

private struct CPSLDirectoryListing: Sendable {
    let entries: [CPSLFileEntry]
    let error: String?
}

@MainActor
private final class CPSLChatModel: ObservableObject {
    @Published var promptText = ""
    @Published var comingSoonMessage: String?
    @Published private(set) var messages: [CPSLChatMessage] = []
    @Published private(set) var isRunning = false
    @Published private(set) var isFileBrowserOpen = false
    @Published private(set) var browserPath = "/"
    @Published private(set) var browserEntries: [CPSLFileEntry] = []
    @Published private(set) var childEntriesByPath: [String: [CPSLFileEntry]] = [:]
    @Published private(set) var expandedFilePaths: Set<String> = []
    @Published private(set) var loadingFilePaths: Set<String> = []
    @Published private(set) var fileBrowserError: String?

    private let service = CPSLDebugService()

    func showComingSoon(_ message: String = "coming soon") {
        comingSoonMessage = message
    }

    func submitPrompt() {
        let input = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !isRunning else {
            return
        }

        promptText = ""
        isFileBrowserOpen = false
        if input.hasPrefix("!") {
            let command = String(input.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                appendErrorMessage(title: nil, body: "Enter a command after !")
                return
            }
            runCommand(command)
            return
        }

        messages.append(CPSLChatMessage(role: .user, title: nil, body: input))
    }

    func toggleFileBrowser() {
        isFileBrowserOpen.toggle()

        if isFileBrowserOpen && browserEntries.isEmpty && loadingFilePaths.isEmpty {
            loadBrowserPath("/")
        }
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
        messages[index] = CPSLChatMessage(id: messageID, role: .command, title: nil, body: body)
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

private struct CPSLHeaderView: View {
    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            HStack(spacing: CPSLTheme.small) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(CPSLTheme.mauve)
                Text("Herm")
                    .font(CPSLTheme.headerFont)
            }
            .foregroundStyle(CPSLTheme.text)

            Spacer()
        }
        .padding(.horizontal, CPSLTheme.large)
        .padding(.top, CPSLTheme.large)
        .padding(.bottom, CPSLTheme.medium)
    }
}

private struct CPSLScrollEdgeBlend: View {
    let edge: VerticalEdge
    let height: CGFloat

    var body: some View {
        LinearGradient(
            stops: stops,
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: height)
    }

    private var stops: [Gradient.Stop] {
        [
            .init(color: CPSLTheme.background, location: 0),
            .init(color: CPSLTheme.background.opacity(0.88), location: 0.30),
            .init(color: CPSLTheme.background.opacity(0.45), location: 0.70),
            .init(color: CPSLTheme.background.opacity(0), location: 1)
        ]
    }
}

private struct CPSLChatTimelineView: View {
    @ObservedObject var model: CPSLChatModel
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        ZStack {
            if model.messages.isEmpty {
                CPSLEmptyChatView()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: CPSLTheme.medium) {
                        ForEach(model.messages) { message in
                            CPSLChatBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, CPSLTheme.large)
                    .padding(.top, topInset)
                    .padding(.bottom, bottomInset)
                }
                .scrollDismissesKeyboard(.interactively)
                .opacity(model.messages.isEmpty ? 0 : 1)
                .onChange(of: model.messages.count) { _, _ in
                    guard let lastID = model.messages.last?.id else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
                .onChange(of: model.messages.last?.body) { _, _ in
                    guard let lastID = model.messages.last?.id else {
                        return
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct CPSLEmptyChatView: View {
    var body: some View {
        VStack(spacing: CPSLTheme.medium) {
            Image(systemName: "sparkles")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(CPSLTheme.mauve.opacity(0.30))

            Text("Herm")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(CPSLTheme.mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CPSLChatBubbleView: View {
    let message: CPSLChatMessage

    var body: some View {
        HStack {
            if message.role.isTrailingAligned && !message.role.isFullWidth {
                Spacer(minLength: CPSLTheme.large * 2)
            }

            VStack(alignment: .leading, spacing: CPSLTheme.small) {
                if let title = message.title {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(message.role.foreground.opacity(0.72))
                }
                messageBody
            }
            .padding(CPSLTheme.medium)
            .background(message.role.fill)
            .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            .frame(
                maxWidth: message.role.isFullWidth ? .infinity : 720,
                alignment: message.role.isTrailingAligned ? .trailing : .leading
            )

            if !message.role.isTrailingAligned && !message.role.isFullWidth {
                Spacer(minLength: CPSLTheme.large * 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role.isTrailingAligned ? .trailing : .leading)
    }

    @ViewBuilder
    private var messageBody: some View {
        if message.role == .command {
            CPSLCommandBlockBody(text: message.body, foreground: message.role.foreground)
        } else {
            Text(message.body)
                .font(message.role.usesMonospaceBody ? CPSLTheme.monospacedBodyFont : CPSLTheme.bodyFont)
                .foregroundStyle(message.role.foreground)
                .textSelection(.enabled)
        }
    }
}

private struct CPSLCommandBlockBody: View {
    let text: String
    let foreground: Color

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > CPSLTheme.commandBlockMaxHeight) {
            Text(text)
                .font(CPSLTheme.monospacedBodyFont)
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: CPSLCommandBlockHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(height: contentHeight > 0 ? min(contentHeight, CPSLTheme.commandBlockMaxHeight) : nil)
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(CPSLCommandBlockHeightKey.self) { height in
            contentHeight = height
        }
    }
}

private struct CPSLCommandBlockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CPSLFileBrowserView: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: CPSLTheme.medium) {
                Button {
                    model.navigateToParentDirectory()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.browserPath == "/")
                .foregroundStyle(model.browserPath == "/" ? CPSLTheme.mutedText : CPSLTheme.text)

                HStack(spacing: CPSLTheme.small) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(CPSLTheme.mauve)
                    Text(model.browserPath)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(CPSLTheme.text)
                }
                .padding(.horizontal, CPSLTheme.medium)
                .padding(.vertical, CPSLTheme.small)
                .background(CPSLTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .lineLimit(1)

                Text("\(model.browserEntries.count)")
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(CPSLTheme.mutedText)
            }
            .padding(CPSLTheme.medium)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error = model.fileBrowserError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(CPSLTheme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(CPSLTheme.medium)
                    }

                    if model.isLoading(model.browserPath) && model.browserEntries.isEmpty {
                        ProgressView()
                            .padding(.top, CPSLTheme.large)
                    } else if model.browserEntries.isEmpty && model.fileBrowserError == nil {
                        Text("Empty")
                            .font(.callout)
                            .foregroundStyle(CPSLTheme.mutedText)
                            .frame(maxWidth: .infinity)
                            .padding(.top, CPSLTheme.large)
                    } else {
                        CPSLFileRowsView(model: model, entries: model.browserEntries, depth: 0)
                    }
                }
                .padding(.horizontal, CPSLTheme.medium)
                .padding(.bottom, CPSLTheme.medium)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(CPSLTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.composerRadius, style: .continuous))
        .padding(.horizontal, CPSLTheme.large)
        .padding(.bottom, CPSLTheme.medium)
    }
}

private struct CPSLFileRowsView: View {
    @ObservedObject var model: CPSLChatModel
    let entries: [CPSLFileEntry]
    let depth: Int

    var body: some View {
        ForEach(entries) { entry in
            CPSLFileRowView(model: model, entry: entry, depth: depth)

            if entry.isDirectory && model.isExpanded(entry) {
                if model.isLoading(entry.path) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading")
                            .font(.caption)
                            .foregroundStyle(CPSLTheme.mutedText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, CGFloat(depth + 1) * CPSLTheme.fileIndent + 28)
                    .padding(.vertical, CPSLTheme.small)
                } else {
                    CPSLFileRowsView(
                        model: model,
                        entries: model.children(for: entry.path),
                        depth: depth + 1
                    )
                }
            }
        }
    }
}

private struct CPSLFileRowView: View {
    @ObservedObject var model: CPSLChatModel
    let entry: CPSLFileEntry
    let depth: Int

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            disclosureControl

            Button {
                model.openFileEntry(entry)
            } label: {
                HStack(spacing: CPSLTheme.medium) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(entry.isDirectory ? CPSLTheme.mauve : CPSLTheme.secondaryText)
                        .frame(width: 20)

                    Text(entry.name)
                        .font(CPSLTheme.rowTitleFont)
                        .lineLimit(1)
                        .foregroundStyle(CPSLTheme.text)

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        }
        .padding(.leading, CGFloat(depth) * CPSLTheme.fileIndent)
        .padding(.horizontal, CPSLTheme.small)
        .padding(.vertical, CPSLTheme.small)
        .background(CPSLTheme.card.opacity(depth == 0 ? 1 : 0.52))
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
        .padding(.bottom, 1)
    }

    @ViewBuilder
    private var disclosureControl: some View {
        if entry.isDirectory {
            Button {
                model.toggleExpansion(for: entry)
            } label: {
                Image(systemName: model.isExpanded(entry) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CPSLTheme.secondaryText)
        } else {
            Color.clear.frame(width: 24, height: 28)
        }
    }
}

private struct CPSLToolStripView: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CPSLTheme.medium) {
                Button {
                    model.toggleFileBrowser()
                } label: {
                    HStack(spacing: CPSLTheme.small) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Files")
                            .font(CPSLTheme.controlFont)
                    }
                    .padding(.horizontal, CPSLTheme.medium)
                    .frame(height: CPSLTheme.controlSize)
                    .background(model.isFileBrowserOpen ? CPSLTheme.controlPressed : CPSLTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.text)
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))

                CPSLDisabledToolIcon(systemName: "envelope.fill")
                CPSLDisabledToolIcon(systemName: "calendar")
            }
            .padding(.horizontal, CPSLTheme.large)
        }
        .padding(.bottom, CPSLTheme.medium)
    }
}

private struct CPSLDisabledToolIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(CPSLTheme.mutedText)
            .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
            .background(CPSLTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            .opacity(0.62)
    }
}

#if canImport(UIKit)
private struct CPSLPromptTextView: UIViewRepresentable {
    @Binding var text: String
    let isCommandInput: Bool
    let isDisabled: Bool
    let maxHeight: CGFloat
    let dismissKeyboardRequest: Int
    let onHeightChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = UIColor(CPSLTheme.text)
        textView.tintColor = UIColor(CPSLTheme.text)
        textView.font = UIFont.systemFont(ofSize: CPSLTheme.normalTextSize, weight: .regular)
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.returnKeyType = .default
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.dismissKeyboardRequest = dismissKeyboardRequest
        applyInputTraits(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if textView.text != text {
            textView.text = text
        }

        let didChangeTraits = applyInputTraits(to: textView)
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        textView.isScrollEnabled = textView.contentSize.height > maxHeight

        if isDisabled && textView.isFirstResponder {
            textView.resignFirstResponder()
        } else if context.coordinator.dismissKeyboardRequest != dismissKeyboardRequest {
            context.coordinator.dismissKeyboardRequest = dismissKeyboardRequest
            textView.resignFirstResponder()
        }

        if didChangeTraits && textView.isFirstResponder {
            textView.reloadInputViews()
        }

        context.coordinator.reportHeight(for: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @discardableResult
    private func applyInputTraits(to textView: UITextView) -> Bool {
        let keyboardType: UIKeyboardType = isCommandInput ? .asciiCapable : .default
        let autocapitalizationType: UITextAutocapitalizationType = isCommandInput ? .none : .sentences
        let autocorrectionType: UITextAutocorrectionType = isCommandInput ? .no : .yes
        let spellCheckingType: UITextSpellCheckingType = isCommandInput ? .no : .default
        let smartQuotesType: UITextSmartQuotesType = isCommandInput ? .no : .default
        let smartDashesType: UITextSmartDashesType = isCommandInput ? .no : .default
        let smartInsertDeleteType: UITextSmartInsertDeleteType = isCommandInput ? .no : .default

        let didChange = textView.keyboardType != keyboardType ||
            textView.autocapitalizationType != autocapitalizationType ||
            textView.autocorrectionType != autocorrectionType ||
            textView.spellCheckingType != spellCheckingType ||
            textView.smartQuotesType != smartQuotesType ||
            textView.smartDashesType != smartDashesType ||
            textView.smartInsertDeleteType != smartInsertDeleteType

        textView.keyboardType = keyboardType
        textView.autocapitalizationType = autocapitalizationType
        textView.autocorrectionType = autocorrectionType
        textView.spellCheckingType = spellCheckingType
        textView.smartQuotesType = smartQuotesType
        textView.smartDashesType = smartDashesType
        textView.smartInsertDeleteType = smartInsertDeleteType
        return didChange
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CPSLPromptTextView
        var dismissKeyboardRequest = 0

        init(parent: CPSLPromptTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            reportHeight(for: textView)
        }

        func reportHeight(for textView: UITextView) {
            let fittingSize = CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            let height = textView.sizeThatFits(fittingSize).height
            DispatchQueue.main.async {
                self.parent.onHeightChange(height)
            }
        }
    }
}
#endif

private struct CPSLPromptComposerView: View {
    @ObservedObject var model: CPSLChatModel
    let dismissKeyboardRequest: Int
    let dismissKeyboard: () -> Void
    @State private var promptContentHeight: CGFloat = 0

    private var hasPromptInput: Bool {
        !model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isCommandInput: Bool {
        model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("!")
    }

    private var promptLineHeight: CGFloat {
#if canImport(UIKit)
        ceil(UIFont.systemFont(ofSize: CPSLTheme.normalTextSize, weight: .regular).lineHeight)
#else
        ceil(CPSLTheme.normalTextSize * 1.25)
#endif
    }

    private var promptTextHeight: CGFloat {
        min(max(promptContentHeight, promptLineHeight), promptLineHeight * 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.medium) {
            ZStack(alignment: .topLeading) {
                if model.promptText.isEmpty {
                    Text("Ask Anything")
                        .font(CPSLTheme.bodyFont)
                        .foregroundStyle(CPSLTheme.mutedText)
                        .padding(.horizontal, CPSLTheme.medium)
                        .padding(.vertical, CPSLTheme.small)
                }

#if canImport(UIKit)
                CPSLPromptTextView(
                    text: $model.promptText,
                    isCommandInput: isCommandInput,
                    isDisabled: model.isRunning,
                    maxHeight: promptLineHeight * 6,
                    dismissKeyboardRequest: dismissKeyboardRequest
                ) { height in
                    promptContentHeight = height
                }
                .frame(height: promptTextHeight)
                .padding(.horizontal, CPSLTheme.medium)
                .padding(.vertical, CPSLTheme.small)
#else
                TextField("", text: $model.promptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .submitLabel(.return)
                    .lineLimit(1...6)
                    .font(CPSLTheme.bodyFont)
                    .foregroundStyle(CPSLTheme.text)
                    .tint(CPSLTheme.text)
                    .disabled(model.isRunning)
                    .padding(.horizontal, CPSLTheme.medium)
                    .padding(.vertical, CPSLTheme.small)
#endif
            }
            .background {
                RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous)
                    .fill(isCommandInput ? CPSLTheme.command.opacity(0.82) : Color.clear)
            }
            .animation(.easeOut(duration: 0.16), value: isCommandInput)

            HStack(spacing: CPSLTheme.medium) {
                Button {
                    dismissKeyboard()
                    model.showComingSoon("coming soon")
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.text)
                .background(CPSLTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))

                Spacer()

                Button {
                    dismissKeyboard()
                    model.showComingSoon("coming soon")
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.text)
                .background(CPSLTheme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))

                Button {
                    dismissKeyboard()
                    if hasPromptInput {
                        model.submitPrompt()
                    } else {
                        model.showComingSoon("coming soon")
                    }
                } label: {
                    Group {
                        if hasPromptInput {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                        } else {
                            HStack(spacing: CPSLTheme.small) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 15, weight: .medium))
                                Text("Speak")
                                    .font(CPSLTheme.controlFont)
                            }
                            .padding(.horizontal, CPSLTheme.medium)
                            .frame(height: CPSLTheme.controlSize)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.background)
                .background(CPSLTheme.text)
                .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            }
        }
        .padding(CPSLTheme.medium)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: CPSLTheme.composerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: CPSLTheme.composerRadius, style: .continuous)
                    .fill(CPSLTheme.surface.opacity(0.78))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.composerRadius, style: .continuous))
        .padding(.horizontal, CPSLTheme.large)
        .padding(.bottom, CPSLTheme.large)
    }
}

private actor CPSLDebugService {
    private nonisolated static let evalTimeoutMilliseconds: UInt64 = 60_000

    private var session: CPSLSessionHandle?
    private var nextSessionID = 0
    private var evaluatingSessionID: Int?
    private var sandboxURLs: CPSLSandboxURLs?

    deinit {
        if let session {
            cpsl_session_free(session.pointer)
        }
    }

    func listDirectory(_ virtualPath: String) -> CPSLDirectoryListing {
        do {
            let sandboxURLs = try ensureSandboxURLs()
            self.sandboxURLs = sandboxURLs
            let hostURL = hostURL(forVirtualPath: virtualPath, sandboxURLs: sandboxURLs)

            let fileManager = FileManager.default
            let urls = try fileManager.contentsOfDirectory(
                at: hostURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
            let normalizedPath = Self.normalizedVirtualPath(virtualPath)
            let entries = try urls.map { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                return CPSLFileEntry(
                    name: url.lastPathComponent,
                    path: Self.virtualChildPath(parent: normalizedPath, child: url.lastPathComponent),
                    isDirectory: values.isDirectory == true
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return CPSLDirectoryListing(entries: entries, error: nil)
        } catch {
            return CPSLDirectoryListing(entries: [], error: error.localizedDescription)
        }
    }

    func evaluate(_ command: String) async -> CPSLEvalServiceResult {
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
                // cpsl_eval may still be blocked; abandon and intentionally leak this session.
                session = nil
            }
            if evaluatingSessionID == activeSession.id {
                evaluatingSessionID = nil
            }
            return Self.timeoutFailure()
        }
    }

    private func hostURL(forVirtualPath virtualPath: String, sandboxURLs: CPSLSandboxURLs) -> URL {
        let normalized = Self.normalizedVirtualPath(virtualPath)
        if normalized == "/workdir" || normalized.hasPrefix("/workdir/") {
            return Self.appendingVirtualPath(
                normalized.dropFirst("/workdir".count),
                to: sandboxURLs.workdir
            )
        }
        return Self.appendingVirtualPath(normalized.dropFirst(), to: sandboxURLs.root)
    }

    private nonisolated static func normalizedVirtualPath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            normalized = "/"
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
        return components.isEmpty ? "/" : "/\(components.joined(separator: "/"))"
    }

    private nonisolated static func appendingVirtualPath<T: StringProtocol>(_ relativePath: T, to baseURL: URL) -> URL {
        var url = baseURL
        for component in relativePath.split(separator: "/") where !component.isEmpty {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private nonisolated static func virtualChildPath(parent: String, child: String) -> String {
        parent == "/" ? "/\(child)" : "\(parent)/\(child)"
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
            "var",
            "workdir"
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
                race.resume(.timedOut, continuation: continuation)
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
            errorMessage: "Command timed out after \(evalTimeoutMilliseconds / 1_000)s. You can try again.",
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
