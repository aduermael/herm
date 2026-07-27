import Foundation

@main
private struct CPSLBootstrapLoadingChecks {
    static func main() throws {
        try checkLoadingHidesFalseEmpty()
        try checkSearchEmptyUsesVisibleEmptiness()
        try checkParallelBootstrapOrderingContract()
        try checkTrueEmptyAfterLoad()
        print("vet-apple-bootstrap-loading: ok")
    }

    /// While conversations are still loading, UI must not claim "No conversations yet".
    private static func checkLoadingHidesFalseEmpty() throws {
        let presentation = CPSLConversationListPresentation.resolve(
            isLoading: true,
            isSearching: false,
            showingArchived: false,
            hasVisibleConversations: false
        )
        try require(presentation == .loading, "expected loading presentation")
        try require(
            presentation.title == "Loading conversations",
            "loading title missing"
        )
        try require(
            presentation.title != "No conversations yet",
            "false empty title shown while loading"
        )
    }

    /// Search with zero visible hits must show "No matches" even if the store has data.
    private static func checkSearchEmptyUsesVisibleEmptiness() throws {
        let noMatches = CPSLConversationListPresentation.resolve(
            isLoading: false,
            isSearching: true,
            showingArchived: false,
            hasVisibleConversations: false
        )
        try require(noMatches == .emptySearch, "expected emptySearch for zero visible hits")
        try require(noMatches.title == "No matches", "search empty title wrong")
        // Store may still have conversations; visible emptiness drives the pane.
        let stillSearchingWithHits = CPSLConversationListPresentation.resolve(
            isLoading: false,
            isSearching: true,
            showingArchived: false,
            hasVisibleConversations: true
        )
        try require(
            stillSearchingWithHits == .populated,
            "search with visible hits must stay populated"
        )
    }

    /// Source contract: conversation load is not ordered strictly after mounts.
    private static func checkParallelBootstrapOrderingContract() throws {
        let chatModelURL = URL(fileURLWithPath: "app/apple/herm/Models/CPSLChatModel.swift")
        let source = try String(contentsOf: chatModelURL, encoding: .utf8)
        try require(
            source.contains("async let mountsReady"),
            "mount prepare is not launched as an independent async let"
        )
        try require(
            source.contains("async let conversationsReady"),
            "conversation load is not launched as an independent async let"
        )
        try require(
            source.contains("loadConversationsAtLaunch"),
            "launch conversation loader missing"
        )
        try require(
            source.contains("isLoadingConversations = true"),
            "loading flag not initialized true"
        )
        // Conversation load must not sit after a sequential prepareICloudMounts barrier.
        if let bootstrapRange = source.range(of: "private func bootstrap() async") {
            let tail = source[bootstrapRange.lowerBound...]
            let end = tail.range(of: "\n    private func loadStore")?.lowerBound
                ?? tail.index(bootstrapRange.lowerBound, offsetBy: 1200, limitedBy: tail.endIndex)
                ?? tail.endIndex
            let bootstrapBody = String(tail[..<end])
            try require(
                bootstrapBody.contains("async let mountsReady")
                    && bootstrapBody.contains("async let conversationsReady"),
                "bootstrap does not run mounts and conversations in parallel"
            )
            try require(
                !bootstrapBody.contains("iCloudMounts = try await service.prepareICloudMounts()\n        }\n\n        do {\n            try await service.prepareSandbox()\n        } catch {\n            appendErrorMessage(title: \"Files\""),
                "bootstrap still sequences conversations after sequential mount+sandbox"
            )
        } else {
            throw CheckFailure("bootstrap() not found")
        }
    }

    private static func checkTrueEmptyAfterLoad() throws {
        let fresh = CPSLConversationListPresentation.resolve(
            isLoading: false,
            isSearching: false,
            showingArchived: false,
            hasVisibleConversations: false
        )
        try require(fresh == .emptyFresh, "expected true empty after load")
        try require(fresh.title == "No conversations yet", "true empty title wrong")

        let populated = CPSLConversationListPresentation.resolve(
            isLoading: true,
            isSearching: false,
            showingArchived: false,
            hasVisibleConversations: true
        )
        try require(
            populated == .populated,
            "loaded conversations must surface even if other work is still pending"
        )
        try require(populated.title == nil, "populated list should not show empty title")
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw CheckFailure(message)
    }
}
