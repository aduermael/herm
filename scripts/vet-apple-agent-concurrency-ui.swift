import Foundation

@main
private struct CPSLAgentConcurrencyUIChecks {
    static func main() throws {
        let chatModel = try source("app/apple/herm/Models/CPSLChatModel.swift")
        let runtime = try source("app/apple/herm/Models/CPSLChatModel+AgentRuntime.swift")
        let debugService = try source("app/apple/herm/Services/CPSLDebugService.swift")
        let timeline = try source("app/apple/herm/Views/Chat/CPSLChatTimelineView.swift")
        let protocolSource = try source("app/apple/herm/Services/Agent/CPSLOpenAIProtocol.swift")

        try assertSubagentsAreMainAgentGated(protocolSource: protocolSource, runtime: runtime)
        try assertBlockingWorkIsOffMain(chatModel: chatModel, runtime: runtime, debugService: debugService)
        try assertRunningLifecycleIsBalanced(chatModel: chatModel)
        try assertWorkingIndicatorContract(timeline: timeline)
    }

    private static func assertSubagentsAreMainAgentGated(protocolSource: String, runtime: String) throws {
        try require(protocolSource.contains("return allowsSubagents ? [localSandboxExec, .agent] : [localSandboxExec]"),
                    "availableTools should expose agent only when sub-agents are allowed")
        try require(runtime.contains("allowsSubagents: context.config.maxAgentDepth > 0"),
                    "main provider loop should gate sub-agent tools by maxAgentDepth")
        try require(runtime.contains("guard childDepth <= context.config.maxAgentDepth"),
                    "sub-agent execution should enforce the configured depth limit")
        try require(runtime.contains("allowsSubagents: context.agentDepth < context.config.maxAgentDepth"),
                    "nested sub-agent tool exposure should stop at the depth limit")
        try require(runtime.contains("tools: isFinalTurn ? [] : CPSLOpenAITool.availableTools"),
                    "sub-agents should have no tools on their final synthesis turn")
    }

    private static func assertBlockingWorkIsOffMain(
        chatModel: String,
        runtime: String,
        debugService: String
    ) throws {
        try require(chatModel.contains("Task.detached(priority: .utility)"),
                    "conversation store initialization should not inherit MainActor execution")
        try require(runtime.contains("Task.detached(priority: .userInitiated)"),
                    "large provider request preparation should run away from the MainActor")
        try require(runtime.contains("CPSLAgentRequestPreparationBuilder"),
                    "provider request preparation should be isolated in a non-UI helper")
        try require(debugService.contains("DispatchQueue.global(qos: .default).async"),
                    "blocking CPSL session initialization should run on a background queue")
        try require(debugService.contains("DispatchQueue.global(qos: .userInitiated).async"),
                    "blocking CPSL eval should run on a background queue")
        try require(debugService.contains("DispatchQueue.global().asyncAfter"),
                    "blocking CPSL eval timeout race should not sleep on the main actor")
        try require(debugService.occurrences(of: "guard !Thread.isMainThread else") >= 2,
                    "host callbacks that synchronously wait for MainActor work must reject main-thread entry")
    }

    private static func assertRunningLifecycleIsBalanced(chatModel: String) throws {
        try require(chatModel.contains("@Published private(set) var isRunning = false"),
                    "chat model should publish running state")
        try require(chatModel.contains("private func runAgent(userText: String) async {\n        defer {\n            isRunning = false\n        }"),
                    "agent run should clear running state through a defer")
        try require(chatModel.contains("Task { @MainActor in\n            defer {\n                isRunning = false\n            }"),
                    "direct command runs should clear running state through a MainActor defer")
    }

    private static func assertWorkingIndicatorContract(timeline: String) throws {
        try require(timeline.contains("if model.isRunning {\n                        CPSLAgentWorkingIndicatorView()"),
                    "timeline should show a dots-only working indicator whenever the model is running")
        try require(timeline.contains("private struct CPSLAgentWorkingIndicatorView"),
                    "working indicator should be a distinct SwiftUI view")
        try require(!timeline.contains("CPSLAgentWorkingIndicatorView(summary:"),
                    "working indicator should not duplicate tool status text")
        try require(!timeline.contains("displaySummary"),
                    "working indicator should not render activity text")
        try require(timeline.contains("Text(payload.summary)"),
                    "tool status row should remain the source of visible activity text")
        try require(timeline.contains("TimelineView(.animation)"),
                    "working indicator should animate while the agent is running")
        try require(timeline.contains("cycleDuration: TimeInterval = 0.84"),
                    "working indicator dots should animate faster than the old slow pulse")
        try require(timeline.contains(".offset(y: dotBounceOffset"),
                    "working indicator dots should bounce vertically")
        try require(timeline.contains("!model.messages.isEmpty || model.isRunning"),
                    "timeline should treat the working indicator as visible content before the first persisted message")
        try require(timeline.contains(".accessibilityLabel(\"Herm is working\")"),
                    "working indicator should expose an accessibility label")
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CheckFailure("could not read \(relativePath): \(error.localizedDescription)")
        }
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
