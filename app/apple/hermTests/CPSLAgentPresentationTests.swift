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
        #expect(decoded?.isSuperseded == false)
    }

    @Test func interruptedStatusRoundTrips() {
        let activityID = UUID()
        let payload = CPSLToolStatusPayload(
            state: .interrupted,
            summary: "Stopped",
            activityID: activityID
        )

        #expect(CPSLToolStatusPayload.decode(from: payload.encodedBody()) == payload)
    }

    @Test func retryStatusKeepsItsPresentationIdentity() {
        let activityID = UUID()
        let failedAttempt = CPSLChatMessage(
            role: .toolStatus,
            title: nil,
            body: CPSLToolStatusPayload(
                state: .running,
                summary: "First attempt",
                isSuperseded: true,
                activityID: activityID
            ).encodedBody()
        )
        let retry = CPSLChatMessage(
            role: .toolStatus,
            title: nil,
            body: CPSLToolStatusPayload(
                state: .running,
                summary: "Retrying",
                activityID: activityID
            ).encodedBody()
        )

        #expect(failedAttempt.activityEntryID == retry.activityEntryID)
    }

    @Test func timelineGroupsConsecutiveThoughtsAndVisibleToolStatuses() {
        let user = CPSLChatMessage(role: .user, title: nil, body: "Start")
        let firstThought = CPSLChatMessage(role: .thought, title: nil, body: "First thought")
        let supersededStatus = CPSLChatMessage(
            role: .toolStatus,
            title: nil,
            body: CPSLToolStatusPayload(
                state: .running,
                summary: "Failed attempt",
                isSuperseded: true
            ).encodedBody()
        )
        let secondThought = CPSLChatMessage(role: .thought, title: nil, body: "Second thought")
        let currentStatus = CPSLChatMessage(
            role: .toolStatus,
            title: nil,
            body: CPSLToolStatusPayload.running(summary: "Trying again").encodedBody()
        )
        let assistant = CPSLChatMessage(role: .assistant, title: nil, body: "Done")

        let items = CPSLChatTimelineItem.grouped(
            from: [user, firstThought, supersededStatus, secondThought, currentStatus, assistant]
        )

        #expect(items.count == 3)
        guard case .activity(let group) = items[1] else {
            Issue.record("Expected one activity group between the user and assistant messages")
            return
        }
        #expect(group.id == firstThought.id)
        #expect(group.messages.map(\.id) == [firstThought.id, secondThought.id, currentStatus.id])
    }

    @Test func collapsedActivityKeepsAnExpandedOlderEntryVisible() {
        let messages = (0..<9).map { index in
            CPSLChatMessage(role: .thought, title: nil, body: "Thought \(index)")
        }
        let group = CPSLTimelineActivityGroup(id: messages[0].id, messages: messages)

        let displayItems = CPSLActivityDisplayItem.items(
            for: group,
            expandedEntryIDs: [messages[3].id],
            showsAll: false
        )

        #expect(displayItems.map(\.id) == [
            .omission(messages[0].id),
            .message(messages[3].id),
            .omission(messages[4].id),
            .message(messages[6].id),
            .message(messages[7].id),
            .message(messages[8].id),
        ])
    }

    @Test func expandedActivityOffersOneFoldControlAndEveryEntry() {
        let messages = (0..<4).map { index in
            CPSLChatMessage(role: .thought, title: nil, body: "Thought \(index)")
        }
        let group = CPSLTimelineActivityGroup(id: messages[0].id, messages: messages)

        let displayItems = CPSLActivityDisplayItem.items(
            for: group,
            expandedEntryIDs: [],
            showsAll: true
        )

        #expect(displayItems.map(\.id) == [
            .collapse(group.id),
            .message(messages[0].id),
            .message(messages[1].id),
            .message(messages[2].id),
            .message(messages[3].id),
        ])
    }
}
