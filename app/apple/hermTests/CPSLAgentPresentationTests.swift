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

    @Test func statusPayloadRoundTripsPresentationState() {
        let invocation = CPSLToolStatusInvocation(
            traceInvocation: CPSLToolTraceInvocation(
                id: "call-1",
                name: "local_sandbox_exec",
                summary: "Building report",
                input: "print('hello')",
                output: "done",
                isError: false
            )
        )
        let visits = (0..<2).map { index in
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
            invocations: [invocation],
            webVisits: visits
        )

        let decoded = CPSLToolStatusPayload.decode(from: payload.encodedBody())
        #expect(decoded == payload)
    }

    @Test func statusPayloadWithoutInvocationExcerptsStillDecodes() {
        let legacyBody = #"{"state":"succeeded","summary":"Finished","webVisits":[]}"#

        let decoded = CPSLToolStatusPayload.decode(from: legacyBody)
        #expect(decoded?.invocations.isEmpty == true)
    }
}
