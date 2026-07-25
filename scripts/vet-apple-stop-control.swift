import Foundation

/// Structural + pure-logic gates for Stop control appearance, cooperative cancel
/// paths, and file-explorer iCloud row layout. Compiles against shipped sources
/// where possible; otherwise asserts required contracts in source.
@main
private struct CPSLStopControlChecks {
    static func main() async throws {
        let composer = try source("app/apple/herm/Views/Composer/CPSLPromptComposerView.swift")
        let chatModel = try source("app/apple/herm/Models/CPSLChatModel.swift")
        let runtime = try source("app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift")
        let openAI = try source("app/apple/herm/Services/Agent/CPSLOpenAIClient.swift")
        let debugService = try source("app/apple/herm/Services/CPSLDebugService.swift")
        let fileBrowser = try source("app/apple/herm/Views/Files/CPSLFileBrowserView.swift")
        let theme = try source("app/apple/herm/Design/CPSLTheme.swift")

        try assertStopControlAppearance(composer: composer, theme: theme)
        try assertStopCancelsRun(chatModel: chatModel, runtime: runtime)
        try assertNestedPathsObserveCancel(
            runtime: runtime,
            openAI: openAI,
            debugService: debugService
        )
        try assertFileExplorerICloudRow(fileBrowser: fileBrowser)
        try await assertEvalRaceCancelBehavior()

        print("vet-apple-stop-control: all checks passed")
    }

    private static func assertStopControlAppearance(composer: String, theme: String) throws {
        try require(
            theme.contains("static let danger = Color(red: 0.86, green: 0.28, blue: 0.32)"),
            "theme must define a vivid danger color for active stop styling"
        )
        try require(
            theme.contains("static let error = Color(red: 0.36, green: 0.16, blue: 0.20)"),
            "theme error surface must remain the muted background token"
        )

        let stopSlice = try requireSlice(
            in: composer,
            startingWith: "if model.isRunning {",
            endingWith: "} else if canSubmit {"
        )
        try require(stopSlice.contains("model.stopAgent()"), "running composer must call stopAgent on tap")
        try require(stopSlice.contains("stop.fill"), "stop control must use the stop glyph")
        try require(stopSlice.contains(".background(CPSLTheme.danger)"), "stop fill must use vivid danger, not muted error")
        try require(!stopSlice.contains("CPSLTheme.error"), "stop must not use muted error surface (reads disabled)")
        try require(stopSlice.contains(".foregroundStyle(CPSLTheme.text)"), "stop glyph must be high-contrast on danger")
        try require(!stopSlice.contains(".disabled("), "stop must stay enabled while isRunning")
        try require(!stopSlice.contains(".opacity("), "stop must not dim via opacity while running")
        try require(stopSlice.contains("accessibilityLabel(\"Stop\")"), "stop must expose accessibility label")
    }

    private static func assertStopCancelsRun(chatModel: String, runtime: String) throws {
        let stopSlice = try requireSlice(
            in: chatModel,
            startingWith: "func stopAgent() {",
            endingWith: "func addAttachment(from url: URL)"
        )
        try require(stopSlice.contains("activeRunTask?.cancel()"), "stopAgent must cancel the active run task")
        try require(stopSlice.contains("isSuppressingAssistantStream = true"), "stop must suppress further stream deltas")
        try require(stopSlice.contains("typewriterTask?.cancel()"), "stop must cancel typewriter animation")
        try require(stopSlice.contains("discardStreamingAssistantIfNeeded()"), "stop must drop partial streaming UI")

        try require(
            chatModel.contains("if Task.isCancelled {\n                await markActiveToolStatusStopped()"),
            "cancelled agent run must mark active tool status stopped/interrupted"
        )
        try require(
            runtime.contains("as: .interrupted") && runtime.contains("String(localized: \"Stopped\")"),
            "tool status finish path for stop must use interrupted/Stopped"
        )
        try require(
            chatModel.contains("defer {\n            isRunning = false\n            activeRunTask = nil\n        }"),
            "agent run must clear isRunning when the cancelled task unwinds"
        )
    }

    private static func assertNestedPathsObserveCancel(
        runtime: String,
        openAI: String,
        debugService: String
    ) throws {
        try require(
            runtime.contains("try Task.checkCancellation()") &&
                runtime.occurrences(of: "try Task.checkCancellation()") >= 8,
            "provider + sub-agent loops must check cancellation at multiple points"
        )
        try require(
            runtime.contains("if Task.isCancelled {\n            return cancelledToolExecutionResult(for: toolCall)"),
            "tool execution must short-circuit when already cancelled"
        )
        try require(
            runtime.contains("if Task.isCancelled || result.errorCode == \"cancelled\""),
            "sandbox/code-exec path must treat cancelled eval as stop"
        )
        try require(
            runtime.contains("} catch is CancellationError {\n            return (") &&
                runtime.contains("textParts: textParts + [\"Stopped.\"]"),
            "sub-agent cancellation must surface Stopped rather than a generic failure"
        )

        let streamSlice = try requireSlice(
            in: openAI,
            startingWith: "func streamChat(",
            endingWith: "private func validate(response:"
        )
        try require(
            streamSlice.occurrences(of: "try Task.checkCancellation()") >= 3,
            "provider stream must observe cancellation before/during/after SSE reads"
        )

        try require(
            debugService.contains("withTaskCancellationHandler"),
            "eval must race cancellation against native cpsl_eval"
        )
        try require(
            debugService.contains("race.resume(.cancelled)"),
            "eval race must resume cancelled for Stop"
        )
        try require(
            debugService.contains("errorCode: \"cancelled\""),
            "cancelled eval must return a cancelled outcome to the agent loop"
        )
        try require(
            debugService.contains("catch is CancellationError {\n            return Self.cancellationFailure()"),
            "eval setup cancellation must not be converted into a generic ffi failure"
        )
    }

    private static func assertFileExplorerICloudRow(fileBrowser: String) throws {
        try require(
            fileBrowser.contains("title: \"Add iCloud Folder\""),
            "Add iCloud Folder row must remain available"
        )
        try require(
            fileBrowser.contains("accessory: .none"),
            "iCloud connect rows must use single-line .none accessory"
        )
        try require(
            !fileBrowser.contains("case singleIcon") && !fileBrowser.contains(".singleIcon"),
            "outline singleIcon accessory under the title must be removed"
        )
        try require(
            fileBrowser.contains("case none") && fileBrowser.contains("case providerIcons"),
            "cloud accessory must only be none or inline provider icons"
        )

        let cloudRow = try requireSlice(
            in: fileBrowser,
            startingWith: "private struct CPSLCloudConnectionRow: View {",
            endingWith: "private enum CPSLCloudProvider {"
        )
        try require(
            !cloudRow.contains("Image(systemName: \"icloud\")"),
            "cloud connection row must not render a secondary outline icloud under the title"
        )
        try require(
            cloudRow.contains("Text(title)") && cloudRow.contains("Button(actionTitle, action: action)"),
            "title and action must share one horizontal cloud connection row"
        )
        try require(
            cloudRow.contains("padding(.leading, CPSLFileRowMetrics.leading)") &&
                cloudRow.contains("padding(.trailing, CPSLFileRowMetrics.trailing)"),
            "cloud rows must share file-row leading/trailing metrics"
        )

        let locationRow = try requireSlice(
            in: fileBrowser,
            startingWith: "private struct CPSLFileLocationRow: View {",
            endingWith: "private enum CPSLCloudAccessory {"
        )
        try require(
            locationRow.contains("padding(.leading, CPSLFileRowMetrics.leading)") &&
                locationRow.contains("padding(.trailing, CPSLFileRowMetrics.trailing)"),
            "location rows must share file-row leading/trailing metrics"
        )
        try require(
            fileBrowser.contains("static let leading: CGFloat = CPSLTheme.medium") &&
                fileBrowser.contains("static let iconWidth: CGFloat = 20"),
            "shared CPSLFileRowMetrics must define icon column and leading padding"
        )
    }

    private static func assertEvalRaceCancelBehavior() async throws {
        // Drive the real shipped CPSLEvalRaceBox (compiled in via integration, or
        // duplicated runtime path when this script is compiled with EvalTypes).
        // When run alone as source-only structural checks, still validate race box
        // if the type is present in-process; otherwise re-run pure logic below.

        let startState = CPSLEvalRaceBox()
        try require(!startState.didStartEvaluation, "new evaluation was marked as started")
        try require(startState.startEvaluationIfPending(), "evaluation did not start")
        try require(startState.didStartEvaluation, "evaluation start was not recorded")
        try require(!startState.startEvaluationIfPending(), "evaluation started twice")

        let cancelledBeforeStart = CPSLEvalRaceBox()
        let cancellationResult = await withCheckedContinuation { continuation in
            cancelledBeforeStart.resume(.cancelled, continuation: continuation)
        }
        guard case .cancelled = cancellationResult else {
            throw CheckFailure("pre-start cancellation did not win the race")
        }
        try require(
            !cancelledBeforeStart.startEvaluationIfPending(),
            "evaluation started after cancellation"
        )
        try require(
            !cancelledBeforeStart.didStartEvaluation,
            "cancelled evaluation was marked as started"
        )
        try require(
            !cancelledBeforeStart.isDetachedEvaluationRunning,
            "pre-start cancellation left detached work"
        )

        let cancelledAfterStart = CPSLEvalRaceBox()
        try require(cancelledAfterStart.startEvaluationIfPending(), "evaluation did not start")
        let cancelledResult = await withCheckedContinuation { continuation in
            cancelledAfterStart.resume(.cancelled, continuation: continuation)
        }
        guard case .cancelled = cancelledResult else {
            throw CheckFailure("started evaluation was not cancelled")
        }
        try require(
            cancelledAfterStart.isDetachedEvaluationRunning,
            "cancelled native evaluation was not retained as running"
        )
        try require(
            !cancelledAfterStart.resume(.completed(successResult)),
            "late cancelled completion resumed the continuation twice"
        )
        cancelledAfterStart.finishDetachedEvaluation()
        try require(
            !cancelledAfterStart.isDetachedEvaluationRunning,
            "finished cancelled evaluation remained busy"
        )
    }

    private static let successResult: CPSLEvalServiceResult = (
        rawJSON: nil,
        stdout: "",
        stderr: "",
        exitCode: 0,
        ok: true,
        cwd: "/home/herm",
        errorCode: nil,
        errorMessage: nil,
        warnings: [],
        ffiError: nil
    )

    private static func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CheckFailure("could not read \(relativePath): \(error.localizedDescription)")
        }
    }

    private static func requireSlice(
        in source: String,
        startingWith start: String,
        endingWith end: String
    ) throws -> String {
        guard let startRange = source.range(of: start) else {
            throw CheckFailure("missing slice start: \(start)")
        }
        let fromStart = source[startRange.lowerBound...]
        guard let endRange = fromStart.range(of: end) else {
            throw CheckFailure("missing slice end after \(start): \(end)")
        }
        return String(fromStart[..<endRange.lowerBound])
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw CheckFailure(message)
        }
    }
}

private extension String {
    func occurrences(of needle: String) -> Int {
        guard !needle.isEmpty else {
            return 0
        }
        var count = 0
        var searchRange = startIndex..<endIndex
        while let range = range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<endIndex
        }
        return count
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
