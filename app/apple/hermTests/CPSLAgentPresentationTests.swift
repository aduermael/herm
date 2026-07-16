import Testing
@testable import herm

struct CPSLAgentPresentationTests {
    private let toolCall = CPSLOpenAIToolCall(
        id: "call-1",
        type: "function",
        function: CPSLOpenAIFunctionCall(
            name: CPSLAgentToolFormatting.localSandboxExecName,
            arguments: #"{"intent":"Checking available skills","source":"print(help())"}"#
        )
    )

    @Test func redundantToolCommentaryIsNotShownAsThought() {
        let thought = CPSLAgentToolFormatting.uniqueThought(
            from: "I'll check the available skills now.",
            toolCalls: [toolCall]
        )
        #expect(thought == nil)
    }

    @Test func uniqueCommentarySurvivesAlongsideRedundantStatus() {
        let thought = CPSLAgentToolFormatting.uniqueThought(
            from: "Checking available skills\nThe document needs current venue hours before it can be finalized.",
            toolCalls: [toolCall]
        )
        #expect(thought == "The document needs current venue hours before it can be finalized.")
    }

    @Test func providerStatusFallbackIsNotRepeatedAsThought() {
        let fallbackToolCall = CPSLOpenAIToolCall(
            id: "call-2",
            type: "function",
            function: CPSLOpenAIFunctionCall(name: "unknown", arguments: "{}")
        )
        let thought = CPSLAgentToolFormatting.uniqueThought(
            from: "I’ll inspect the remaining details.",
            toolCalls: [fallbackToolCall]
        )
        #expect(thought == nil)
    }

    @Test func agentStatusUsesItsSpecificIntent() {
        let agentCall = CPSLOpenAIToolCall(
            id: "call-agent",
            type: "function",
            function: CPSLOpenAIFunctionCall(
                name: CPSLAgentToolFormatting.agentName,
                arguments: #"{"intent":"Comparing venue options","task":"Research the candidate venues.","mode":"explore"}"#
            )
        )

        #expect(CPSLAgentToolFormatting.summary(for: agentCall) == "Comparing venue options")
    }

    @Test func legacyAgentStatusFallsBackToItsTask() {
        let agentCall = CPSLOpenAIToolCall(
            id: "call-agent-legacy",
            type: "function",
            function: CPSLOpenAIFunctionCall(
                name: CPSLAgentToolFormatting.agentName,
                arguments: #"{"task":"Compare the candidate venues","mode":"explore"}"#
            )
        )

        #expect(CPSLAgentToolFormatting.summary(for: agentCall) == "Compare the candidate venues")
    }

    @Test func presentationProjectionDoesNotAlterPersistedDiagnostics() {
        let invocations = (0..<6).map { index in
            CPSLToolStatusInvocation(
                id: "invocation-\(index)",
                name: "tool",
                summary: "Invocation \(index)",
                input: "input-\(index)",
                output: "output-\(index)",
                isError: false
            )
        }
        let visits = (0..<14).map { index in
            CPSLWebSearchVisit(
                id: "visit-\(index)",
                browserID: "browser-\(index)",
                url: "https://example.com/\(index)",
                title: "Visit \(index)",
                host: "example.com",
                faviconURL: nil
            )
        }
        let payload = CPSLToolStatusPayload(
            state: .succeeded,
            summary: "Finished",
            invocations: invocations,
            webVisits: visits
        )

        let persisted = CPSLToolStatusPayload.decode(from: payload.encodedBody())
        let presentation = CPSLToolStatusPayload.decode(from: payload.presentationEncodedBody())

        #expect(persisted?.invocations.count == 6)
        #expect(persisted?.webVisits.count == 14)
#if DEBUG
        #expect(presentation?.invocations.map(\.id) == [
            "invocation-2", "invocation-3", "invocation-4", "invocation-5",
        ])
#else
        #expect(presentation?.invocations.isEmpty == true)
#endif
        #expect(presentation?.webVisits.first?.id == "visit-2")
        #expect(presentation?.webVisits.count == 12)
    }
}
