import Foundation

@MainActor
extension CPSLChatModel {
    func runProviderLoop(_ context: inout CPSLProviderLoopContext) async throws {
        var pendingFailures: [CPSLToolStatusInvocation] = []
        clearActiveToolStatus()

        for iteration in 0..<context.config.maxToolRounds {
            try Task.checkCancellation()
            let sandboxDirectory = await service.currentDirectory()
            let requestMessages = await preparedRequestMessages(
                CPSLRequestPreparation(
                    systemPrompt: context.systemPrompt,
                    providerMessages: context.providerMessages,
                    config: context.config,
                    sandboxDirectory: sandboxDirectory,
                    iteration: iteration,
                    maxIterations: context.config.maxToolRounds
                )
            )
            try Task.checkCancellation()
            let tools = CPSLOpenAITool.availableTools(
                allowsSubagents: context.config.maxAgentDepth > 0,
                currentDirectory: sandboxDirectory
            )
            isSuppressingAssistantStream = !tools.isEmpty
            let request = CPSLOpenAIStreamRequest(
                messages: requestMessages,
                tools: tools,
                maxTokens: context.config.maxOutputTokens
            )
            try await context.store.recordProviderRequest(
                conversationID: context.conversationID,
                model: context.config.model,
                messages: request.messages,
                tools: tools,
                maxTokens: request.maxTokens,
                scope: "main.turn.\(iteration + 1)"
            )
            let completion = try await context.client.streamChat(request) { event in
                self.handleProviderStreamEvent(event)
            }
            try await context.store.recordProviderResponse(
                conversationID: context.conversationID,
                completion: completion,
                scope: "main.turn.\(iteration + 1)"
            )
            try Task.checkCancellation()

            presentCompletedAssistantIfNeeded(completion)
            await finishTypewriter()
            if !completion.toolCalls.isEmpty {
                discardStreamingAssistantIfNeeded()
                try await appendUniqueThoughtIfNeeded(
                    completion.text,
                    toolCalls: completion.toolCalls,
                    model: completion.model,
                    context: &context
                )
            }

            if !completion.text.isEmpty && completion.toolCalls.isEmpty {
                let providerMessage = CPSLOpenAIMessage.assistant(completion.text)
                context.providerMessages.append(providerMessage)
                let assistantNode = try await context.store.appendNode(
                    conversationID: context.conversationID,
                    parentID: context.parentID,
                    draft: CPSLNodeAppendDraft(
                        role: .assistant,
                        title: nil,
                        body: completion.text,
                        model: completion.model,
                        providerMessage: providerMessage
                    )
                )
                context.parentID = assistantNode.id
                context.onParentIDChange(context.parentID)
                if let message = assistantNode.chatMessage {
                    reconcileStreamingAssistant(with: message)
                }
                streamingAssistantMessageID = nil
            }

            guard !completion.toolCalls.isEmpty else {
                if !pendingFailures.isEmpty {
                    try await finishActiveToolStatus(as: .failed)
                }
                if completion.text.isEmpty {
                    try await appendProviderLoopError("Provider returned an empty response.", context: &context)
                }
                clearActiveToolStatus()
                return
            }

            var statusSummary = CPSLAgentToolFormatting.defaultStatusSummary
            let assistantToolMessage = CPSLOpenAIMessage.assistant(
                content: completion.text.isEmpty ? nil : completion.text,
                toolCalls: completion.toolCalls
            )
            var executedToolCalls: [(toolCall: CPSLOpenAIToolCall, result: CPSLToolExecutionResult)] = []

            for toolCall in completion.toolCalls {
                try Task.checkCancellation()
                let retryPresentation: (webVisits: [CPSLWebSearchVisit], activityID: UUID)
                if pendingFailures.isEmpty {
                    retryPresentation = ([], UUID())
                } else {
                    retryPresentation = try await supersedeActiveToolStatus()
                }
                statusSummary = CPSLAgentToolFormatting.statusSummary(
                    for: toolCall,
                    assistantText: completion.text
                )
                var toolStatus = CPSLToolStatusPayload(
                    state: .running,
                    summary: statusSummary,
                    invocations: pendingFailures,
                    webVisits: retryPresentation.webVisits,
                    activityID: retryPresentation.activityID
                )
                let toolStatusNodeID = try await appendToolStatus(
                    toolStatus,
                    model: completion.model,
                    context: &context
                )

                let toolResult = await executeToolCall(
                    toolCall,
                    context: CPSLToolExecutionContext(
                        client: context.client,
                        config: context.config,
                        agentDepth: 0,
                        requestDirectory: sandboxDirectory,
                        traceStore: context.store,
                        conversationID: context.conversationID
                    )
                )
                try Task.checkCancellation()
                executedToolCalls.append((toolCall, toolResult))
                toolStatus.invocations.append(
                    CPSLToolStatusInvocation(traceInvocation: toolResult.traceInvocation)
                )
                toolStatus.invocations = Array(toolStatus.invocations.suffix(recentToolResultsToKeep))
                if toolResult.isError {
                    pendingFailures = toolStatus.invocations
                    toolStatus.state = .running
                } else {
                    pendingFailures.removeAll(keepingCapacity: true)
                    toolStatus.state = .succeeded
                }
                toolStatus.summary = statusSummary
                try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: context.store)
                if !toolResult.isError {
                    clearActiveToolStatus()
                }
                try await context.store.recordToolInvocation(
                    conversationID: context.conversationID,
                    nodeID: toolStatusNodeID,
                    invocation: toolResult.traceInvocation
                )
            }

            try await appendToolReplayBlock(
                CPSLToolReplayDraft(
                    assistantToolMessage: assistantToolMessage,
                    statusSummary: statusSummary,
                    executedToolCalls: executedToolCalls,
                    model: completion.model
                ),
                context: &context
            )
        }

        try Task.checkCancellation()
        if !pendingFailures.isEmpty {
            try await finishActiveToolStatus(as: .failed)
        }
        try await synthesizeAfterToolLimit(&context)
        clearActiveToolStatus()
    }

    private func appendToolStatus(
        _ payload: CPSLToolStatusPayload,
        model: String,
        context: inout CPSLProviderLoopContext
    ) async throws -> String {
        let statusNode = try await context.store.appendNode(
            conversationID: context.conversationID,
            parentID: context.parentID,
            draft: CPSLNodeAppendDraft(
                role: .toolStatus,
                title: nil,
                body: payload.encodedBody(),
                model: model,
                providerMessage: nil
            )
        )
        activeToolStatusNodeID = statusNode.id
        activeToolStatusConversationID = context.conversationID
        activeToolStatusPayload = payload
        activeToolStatusStore = context.store
        context.parentID = statusNode.id
        context.onParentIDChange(statusNode.id)
        if let message = statusNode.chatMessage {
            messages.append(message)
        }
        return statusNode.id
    }

    private func supersedeActiveToolStatus() async throws -> (
        webVisits: [CPSLWebSearchVisit],
        activityID: UUID
    ) {
        guard let nodeID = activeToolStatusNodeID,
              var payload = activeToolStatusPayload,
              let store = activeToolStatusStore
        else {
            clearActiveToolStatus()
            return ([], UUID())
        }
        payload.isSuperseded = true
        try await updateToolStatus(payload, nodeID: nodeID, store: store)
        let presentation = (
            webVisits: payload.webVisits,
            activityID: payload.activityID ?? UUID(uuidString: nodeID) ?? UUID()
        )
        return presentation
    }

    private func appendToolReplayBlock(
        _ draft: CPSLToolReplayDraft,
        context: inout CPSLProviderLoopContext
    ) async throws {
        var drafts = [
            CPSLNodeAppendDraft(
                role: .hidden,
                title: nil,
                body: draft.statusSummary,
                model: draft.model,
                providerMessage: draft.assistantToolMessage
            )
        ]
        drafts += draft.executedToolCalls.map { executed in
            CPSLNodeAppendDraft(
                role: .hidden,
                title: executed.toolCall.function.name,
                body: executed.result.displayBody,
                model: draft.model,
                providerMessage: CPSLOpenAIMessage.tool(
                    id: executed.toolCall.id,
                    content: executed.result.providerContent
                )
            )
        }

        let nodes = try await context.store.appendNodes(
            conversationID: context.conversationID,
            parentID: context.parentID,
            drafts: drafts
        )
        if let lastNode = nodes.last {
            context.parentID = lastNode.id
            context.onParentIDChange(context.parentID)
        }

        context.providerMessages.append(draft.assistantToolMessage)
        for executed in draft.executedToolCalls {
            context.providerMessages.append(
                CPSLOpenAIMessage.tool(
                    id: executed.toolCall.id,
                    content: executed.result.providerContent
                )
            )
        }
    }

    private func synthesizeAfterToolLimit(_ context: inout CPSLProviderLoopContext) async throws {
        let synthesisPrompt = """
        Tool iteration limit reached. Produce a concise final response from the work completed so far. Do not request tools.
        """
        let synthesisMessage = CPSLOpenAIMessage.user(synthesisPrompt)
        context.providerMessages.append(synthesisMessage)
        let hiddenNode = try await context.store.appendNode(
            conversationID: context.conversationID,
            parentID: context.parentID,
            draft: CPSLNodeAppendDraft(
                role: .hidden,
                title: "Agent",
                body: synthesisPrompt,
                model: context.config.model,
                providerMessage: synthesisMessage
            )
        )
        context.parentID = hiddenNode.id
        context.onParentIDChange(context.parentID)

        let sandboxDirectory = await service.currentDirectory()
        let requestMessages = await preparedRequestMessages(
            CPSLRequestPreparation(
                systemPrompt: context.systemPrompt,
                providerMessages: context.providerMessages,
                config: context.config,
                sandboxDirectory: sandboxDirectory,
                iteration: context.config.maxToolRounds,
                maxIterations: context.config.maxToolRounds
            )
        )
        isSuppressingAssistantStream = false
        let request = CPSLOpenAIStreamRequest(
            messages: requestMessages,
            tools: [],
            maxTokens: context.config.maxOutputTokens
        )
        try await context.store.recordProviderRequest(
            conversationID: context.conversationID,
            model: context.config.model,
            messages: request.messages,
            tools: [],
            maxTokens: request.maxTokens,
            scope: "main.synthesis"
        )
        let completion = try await context.client.streamChat(request) { event in
            self.handleProviderStreamEvent(event)
        }
        try await context.store.recordProviderResponse(
            conversationID: context.conversationID,
            completion: completion,
            scope: "main.synthesis"
        )
        presentCompletedAssistantIfNeeded(completion)
        await finishTypewriter()

        guard !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try await appendProviderLoopError(
                "Reached maximum tool rounds (\(context.config.maxToolRounds)) and provider returned no final response.",
                context: &context
            )
            return
        }

        let providerMessage = CPSLOpenAIMessage.assistant(completion.text)
        context.providerMessages.append(providerMessage)
        let assistantNode = try await context.store.appendNode(
            conversationID: context.conversationID,
            parentID: context.parentID,
            draft: CPSLNodeAppendDraft(
                role: .assistant,
                title: nil,
                body: completion.text,
                model: completion.model,
                providerMessage: providerMessage
            )
        )
        context.parentID = assistantNode.id
        context.onParentIDChange(context.parentID)
        if let message = assistantNode.chatMessage {
            reconcileStreamingAssistant(with: message)
        }
        streamingAssistantMessageID = nil
    }

    private func updateToolStatus(
        _ payload: CPSLToolStatusPayload,
        nodeID: String,
        store: CPSLConversationStore
    ) async throws {
        var effectivePayload = payload
        if nodeID == activeToolStatusNodeID,
           let activeToolStatusPayload,
           !activeToolStatusPayload.webVisits.isEmpty {
            effectivePayload.webVisits = activeToolStatusPayload.webVisits
        }
        activeToolStatusNodeID = nodeID
        activeToolStatusPayload = effectivePayload
        activeToolStatusStore = store
        activeToolStatusRevision += 1
        let revision = activeToolStatusRevision
        let body = effectivePayload.encodedBody()
        guard let conversationID = activeToolStatusConversationID else {
            return
        }
        try await store.updateNodeBody(
            conversationID: conversationID,
            id: nodeID,
            body: body
        )
        guard activeToolStatusNodeID == nodeID,
              activeToolStatusRevision == revision
        else {
            return
        }
        guard let messageID = UUID(uuidString: nodeID),
                let index = messages.firstIndex(where: { $0.id == messageID })
        else {
            return
        }
        messages[index].body = body
    }

    private func appendUniqueThoughtIfNeeded(
        _ assistantText: String,
        toolCalls: [CPSLOpenAIToolCall],
        model: String,
        context: inout CPSLProviderLoopContext
    ) async throws {
        guard let thought = CPSLAgentToolFormatting.uniqueThought(
            from: assistantText,
            toolCalls: toolCalls
        ) else {
            return
        }
        let node = try await context.store.appendNode(
            conversationID: context.conversationID,
            parentID: context.parentID,
            draft: CPSLNodeAppendDraft(
                role: .thought,
                title: nil,
                body: thought,
                model: model,
                providerMessage: nil
            )
        )
        context.parentID = node.id
        context.onParentIDChange(node.id)
        if let message = node.chatMessage {
            messages.append(message)
        }
    }

    private func clearActiveToolStatus() {
        activeToolStatusRevision += 1
        activeToolStatusNodeID = nil
        activeToolStatusConversationID = nil
        activeToolStatusPayload = nil
        activeToolStatusStore = nil
    }

    private func finishActiveToolStatus(
        as state: CPSLToolStatusState,
        summary: String? = nil
    ) async throws {
        guard let nodeID = activeToolStatusNodeID,
              var payload = activeToolStatusPayload,
              let store = activeToolStatusStore
        else {
            clearActiveToolStatus()
            return
        }
        payload.state = state
        payload.isSuperseded = false
        if let summary {
            payload.summary = summary
        }
        try await updateToolStatus(payload, nodeID: nodeID, store: store)
        clearActiveToolStatus()
    }

    func markActiveToolStatusStopped() async {
        do {
            try await finishActiveToolStatus(
                as: .interrupted,
                summary: String(localized: "Stopped")
            )
        } catch {
            clearActiveToolStatus()
        }
    }

    func markActiveToolStatusFailed() async {
        guard activeToolStatusPayload?.invocations.last?.isError == true else {
            clearActiveToolStatus()
            return
        }
        do {
            try await finishActiveToolStatus(as: .failed)
        } catch {
            clearActiveToolStatus()
        }
    }

    private func preparedRequestMessages(_ preparation: CPSLRequestPreparation) async -> [CPSLOpenAIMessage] {
        let estimatedBytesPerTokenValue = estimatedBytesPerToken
        let toolResultClearThresholdValue = toolResultClearThreshold
        let recentToolResultsToKeepValue = recentToolResultsToKeep
        return await Task.detached(priority: .userInitiated) {
            CPSLAgentRequestPreparationBuilder.preparedRequestMessages(
                preparation,
                estimatedBytesPerToken: estimatedBytesPerTokenValue,
                toolResultClearThreshold: toolResultClearThresholdValue,
                recentToolResultsToKeep: recentToolResultsToKeepValue
            )
        }.value
    }

    private func appendProviderLoopError(
        _ body: String,
        context: inout CPSLProviderLoopContext
    ) async throws {
        let errorNode = try await context.store.appendNode(
            conversationID: context.conversationID,
            parentID: context.parentID,
            draft: CPSLNodeAppendDraft(
                role: .error,
                title: "Agent",
                body: body,
                model: context.config.model,
                providerMessage: nil
            )
        )
        context.parentID = errorNode.id
        context.onParentIDChange(context.parentID)
        if let message = errorNode.chatMessage {
            messages.append(message)
        }
    }

    func persistStreamingAssistantIfNeeded(_ context: CPSLPendingConversationContext) async -> String? {
        await finishTypewriter()
        guard let conversationID = context.conversationID,
                let parentID = context.parentID,
                let id = streamingAssistantMessageID,
                let index = messages.firstIndex(where: { $0.id == id })
        else {
            return context.parentID
        }

        let body = messages[index].body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return context.parentID
        }

        do {
            let node = try await context.store.appendNode(
                conversationID: conversationID,
                parentID: parentID,
                draft: CPSLNodeAppendDraft(
                    role: .assistant,
                    title: nil,
                    body: messages[index].body,
                    model: context.model,
                    providerMessage: nil
                )
            )
            currentNodeID = node.id
            streamingAssistantMessageID = nil
            if let message = node.chatMessage {
                messages[index] = message
            }
            return node.id
        } catch {
            return parentID
        }
    }

    func appendAgentError(_ body: String, context: CPSLPendingConversationContext) async {
        guard let conversationID = context.conversationID, let parentID = context.parentID else {
            appendErrorMessage(title: "Agent", body: body)
            return
        }

        do {
            let node = try await context.store.appendNode(
                conversationID: conversationID,
                parentID: parentID,
                draft: CPSLNodeAppendDraft(
                    role: .error,
                    title: "Agent",
                    body: body,
                    model: context.model,
                    providerMessage: nil
                )
            )
            currentNodeID = node.id
            if let message = node.chatMessage {
                messages.append(message)
            }
        } catch {
            appendErrorMessage(title: "Agent", body: body)
        }
    }

    private func queueAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }

        if streamingAssistantMessageID == nil {
            let message = CPSLChatMessage(role: .assistant, title: nil, body: "")
            streamingAssistantMessageID = message.id
            messages.append(message)
        }

        typewriterBuffer.append(delta)
        guard typewriterTask == nil else {
            return
        }

        typewriterTask = Task { @MainActor in
            await drainTypewriterBuffer()
        }
    }

    private func presentCompletedAssistantIfNeeded(_ completion: CPSLOpenAICompletion) {
        guard completion.toolCalls.isEmpty,
              streamingAssistantMessageID == nil,
              !completion.text.isEmpty
        else {
            return
        }
        isSuppressingAssistantStream = false
        queueAssistantDelta(completion.text)
    }

    private func handleProviderStreamEvent(_ event: CPSLOpenAIStreamEvent) {
        switch event {
        case .textDelta(let delta):
            guard !isSuppressingAssistantStream, !delta.isEmpty else {
                return
            }
            queueAssistantDelta(delta)
        case .toolCallDelta:
            isSuppressingAssistantStream = true
            discardStreamingAssistantIfNeeded()
        }
    }

    private func drainTypewriterBuffer() async {
        defer {
            typewriterTask = nil
        }

        while !Task.isCancelled {
            if typewriterBuffer.isEmpty {
                return
            }

            let chunkSize = min(typewriterBuffer.count, typewriterChunkSize)
            let chunk = String(typewriterBuffer.prefix(chunkSize))
            typewriterBuffer.removeFirst(chunk.count)
            appendToStreamingAssistant(chunk)
            try? await Task.sleep(nanoseconds: 24_000_000)
        }
    }

    private var typewriterChunkSize: Int {
        if typewriterBuffer.count > 1_024 {
            return 96
        }
        if typewriterBuffer.count > 240 {
            return 48
        }
        return 16
    }

    func finishTypewriter() async {
        while typewriterTask != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func appendToStreamingAssistant(_ text: String) {
        guard let id = streamingAssistantMessageID,
                let index = messages.firstIndex(where: { $0.id == id })
        else {
            return
        }
        messages[index].body.append(text)
    }

    private func reconcileStreamingAssistant(with persistedMessage: CPSLChatMessage) {
        guard let id = streamingAssistantMessageID,
                let index = messages.firstIndex(where: { $0.id == id })
        else {
            if !persistedMessage.body.isEmpty {
                messages.append(persistedMessage)
            }
            return
        }
        messages[index] = persistedMessage
    }

    private func discardStreamingAssistantIfNeeded() {
        guard let id = streamingAssistantMessageID else {
            return
        }
        messages.removeAll { $0.id == id }
        streamingAssistantMessageID = nil
        typewriterBuffer = ""
        typewriterTask?.cancel()
        typewriterTask = nil
    }

    private func executeToolCall(
        _ toolCall: CPSLOpenAIToolCall,
        context: CPSLToolExecutionContext
    ) async -> CPSLToolExecutionResult {
        if let requestDirectory = context.requestDirectory,
            let restoreError = await restoreCurrentDirectory(requestDirectory, for: toolCall) {
            return restoreError
        }

        switch toolCall.function.name {
        case CPSLAgentToolFormatting.localSandboxExecName:
            return await executeSandboxToolCall(toolCall)
        case CPSLAgentToolFormatting.agentName:
            return await executeAgentToolCall(
                toolCall,
                context: context
            )
        default:
            return CPSLToolExecutionResult(
                providerContent: #"{"ok":false,"error":"Unsupported tool."}"#,
                displayBody: "Unsupported tool: \(toolCall.function.name)",
                isError: true,
                traceInvocation: traceInvocation(
                    for: toolCall,
                    displayBody: "Unsupported tool: \(toolCall.function.name)",
                    isError: true
                )
            )
        }
    }

    private func restoreCurrentDirectory(
        _ directory: String,
        for toolCall: CPSLOpenAIToolCall
    ) async -> CPSLToolExecutionResult? {
        guard let message = await service.restoreCurrentDirectory(directory) else {
            return nil
        }
        let displayBody = message.isEmpty ? "Could not restore current directory." : message
        return CPSLToolExecutionResult(
            providerContent: providerToolContent(ok: false, output: nil, error: displayBody),
            displayBody: displayBody,
            isError: true,
            traceInvocation: traceInvocation(for: toolCall, displayBody: displayBody, isError: true)
        )
    }

    private func executeSandboxToolCall(_ toolCall: CPSLOpenAIToolCall) async -> CPSLToolExecutionResult {
        guard let source = CPSLAgentToolFormatting.source(from: toolCall.function.arguments) else {
            return CPSLToolExecutionResult(
                providerContent: #"{"ok":false,"error":"Missing source argument."}"#,
                displayBody: "Missing source argument.",
                isError: true,
                traceInvocation: traceInvocation(
                    for: toolCall,
                    displayBody: "Missing source argument.",
                    isError: true
                )
            )
        }

        let result = await service.evaluateLuau(source)
        let output = CPSLAgentToolOutput(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            ok: result.ok,
            errorCode: result.errorCode,
            errorMessage: result.errorMessage,
            ffiError: result.ffiError
        )
        let displayBody = CPSLAgentToolFormatting.displayBody(output)
        let isError = result.ok == false || result.errorMessage != nil || result.ffiError != nil
        return CPSLToolExecutionResult(
            providerContent: CPSLAgentToolFormatting.providerContent(output),
            displayBody: displayBody,
            isError: isError,
            traceInvocation: traceInvocation(
                for: toolCall,
                displayBody: CPSLAgentToolFormatting.completeBody(output),
                isError: isError
            )
        )
    }

    private func executeAgentToolCall(
        _ toolCall: CPSLOpenAIToolCall,
        context: CPSLToolExecutionContext
    ) async -> CPSLToolExecutionResult {
        guard let input = CPSLAgentToolFormatting.agentInput(from: toolCall.function.arguments) else {
            let message = "Invalid agent arguments."
            return CPSLToolExecutionResult(
                providerContent: providerToolContent(ok: false, output: nil, error: message),
                displayBody: message,
                isError: true,
                traceInvocation: traceInvocation(for: toolCall, displayBody: message, isError: true)
            )
        }

        let childDepth = context.agentDepth + 1
        guard childDepth <= context.config.maxAgentDepth else {
            let message = "Sub-agent depth limit reached."
            return CPSLToolExecutionResult(
                providerContent: providerToolContent(ok: false, output: nil, error: message),
                displayBody: message,
                isError: true,
                traceInvocation: traceInvocation(for: toolCall, displayBody: message, isError: true)
            )
        }

        let result = await runSubAgent(
            input: input,
            context: CPSLToolExecutionContext(
                client: context.client,
                config: context.config,
                agentDepth: childDepth,
                requestDirectory: nil,
                traceStore: context.traceStore,
                conversationID: context.conversationID
            )
        )
        return CPSLToolExecutionResult(
            providerContent: providerToolContent(
                ok: !result.isError,
                output: result.output,
                error: result.isError ? result.output : nil
            ),
            displayBody: result.output,
            isError: result.isError,
            traceInvocation: traceInvocation(for: toolCall, displayBody: result.output, isError: result.isError)
        )
    }

    private func runSubAgent(
        input: CPSLAgentToolInput,
        context: CPSLToolExecutionContext
    ) async -> (output: String, isError: Bool) {
        let maxTurns = input.mode == .explore
            ? context.config.exploreSubAgentTurns
            : context.config.generalSubAgentTurns
        let subAgentSystemPrompt = subAgentSystemPrompt(
            mode: input.mode,
            maxTurns: maxTurns,
            context: context
        )
        var providerMessages: [CPSLOpenAIMessage] = [.user(input.task)]
        var textParts: [String] = []
        var turnsUsed = 0

        do {
            for turn in 0..<maxTurns {
                turnsUsed = turn + 1
                let isFinalTurn = turn == maxTurns - 1
                let sandboxDirectory = await service.currentDirectory()
                let turnGuidance: String
                if isFinalTurn {
                    turnGuidance = "Budget: turn \(turn + 1)/\(maxTurns). FINAL: return the best usable result now; no tools."
                } else if turn >= maxTurns - 3 {
                    turnGuidance = "Budget: turn \(turn + 1)/\(maxTurns). Synthesize usable findings now; use another tool only for an essential missing fact."
                } else {
                    turnGuidance = "Budget: turn \(turn + 1)/\(maxTurns)."
                }
                let requestMessages = [
                    CPSLOpenAIMessage.system(
                        subAgentSystemPrompt
                            + "\n\n<system-reminder>\n"
                            + "\(turnGuidance)\n"
                            + "Current CPSL directory: \(CPSLAgentToolFormatting.promptPathLiteral(sandboxDirectory)).\n"
                            + "</system-reminder>"
                    )
                ] + providerMessages
                let tools = isFinalTurn ? [] : CPSLOpenAITool.availableTools(
                    allowsSubagents: context.agentDepth < context.config.maxAgentDepth,
                    currentDirectory: sandboxDirectory
                )
                let request = CPSLOpenAIStreamRequest(
                    messages: requestMessages,
                    tools: tools,
                    maxTokens: context.config.maxOutputTokens
                )
                let scope = "subagent.\(input.mode.rawValue).turn.\(turn + 1)"
                if let traceStore = context.traceStore,
                   let conversationID = context.conversationID {
                    try await traceStore.recordProviderRequest(
                        conversationID: conversationID,
                        model: context.config.model,
                        messages: request.messages,
                        tools: tools,
                        maxTokens: request.maxTokens,
                        scope: scope
                    )
                }
                let completion = try await context.client.streamChat(request) { _ in }
                if let traceStore = context.traceStore,
                   let conversationID = context.conversationID {
                    try await traceStore.recordProviderResponse(
                        conversationID: conversationID,
                        completion: completion,
                        scope: scope
                    )
                }

                if !completion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textParts.append(completion.text)
                }

                if isFinalTurn {
                    return (
                        subAgentOutput(
                            CPSLSubAgentOutputDraft(
                                mode: input.mode,
                                turnsUsed: turnsUsed,
                                maxTurns: maxTurns,
                                textParts: textParts
                            )
                        ),
                        false
                    )
                }

                guard !completion.toolCalls.isEmpty else {
                    return (
                        subAgentOutput(
                            CPSLSubAgentOutputDraft(
                                mode: input.mode,
                                turnsUsed: turnsUsed,
                                maxTurns: maxTurns,
                                textParts: textParts
                            )
                        ),
                        false
                    )
                }

                providerMessages.append(
                    CPSLOpenAIMessage.assistant(
                        content: completion.text.isEmpty ? nil : completion.text,
                        toolCalls: completion.toolCalls
                    )
                )
                for toolCall in completion.toolCalls {
                    let toolResult = await executeToolCall(
                        toolCall,
                        context: CPSLToolExecutionContext(
                            client: context.client,
                            config: context.config,
                            agentDepth: context.agentDepth,
                            requestDirectory: sandboxDirectory,
                            traceStore: context.traceStore,
                            conversationID: context.conversationID
                        )
                    )
                    if let traceStore = context.traceStore,
                       let conversationID = context.conversationID {
                        try await traceStore.recordToolInvocation(
                            conversationID: conversationID,
                            nodeID: nil,
                            invocation: toolResult.traceInvocation
                        )
                    }
                    providerMessages.append(
                        CPSLOpenAIMessage.tool(id: toolCall.id, content: toolResult.providerContent)
                    )
                }
            }

            return (
                subAgentOutput(
                    CPSLSubAgentOutputDraft(
                        mode: input.mode,
                        turnsUsed: turnsUsed,
                        maxTurns: maxTurns,
                        textParts: textParts
                    )
                ),
                false
            )
        } catch {
            if let traceStore = context.traceStore,
               let conversationID = context.conversationID {
                try? await traceStore.recordError(
                    conversationID: conversationID,
                    message: error.localizedDescription,
                    scope: "subagent.\(input.mode.rawValue)"
                )
            }
            let output = subAgentOutput(
                CPSLSubAgentOutputDraft(
                    mode: input.mode,
                    turnsUsed: turnsUsed,
                    maxTurns: maxTurns,
                    textParts: textParts + ["Sub-agent failed: \(error.localizedDescription)"]
                )
            )
            return (output, true)
        }
    }

    private func subAgentSystemPrompt(
        mode: CPSLSubAgentMode,
        maxTurns: Int,
        context: CPSLToolExecutionContext
    ) -> String {
        let basePrompt = """
        You are a Herm sub-agent running inside the same iOS/macOS app.
        Complete the assigned task, then return a concise result. Do not ask questions.
        Start collecting useful findings immediately and preserve them in your response. Do not spend the whole budget on discovery. For browser research, reuse one browser across queries and return the best verified result you have before the final turn.
        Mode: \(mode.rawValue). Turn budget: \(maxTurns). Agent depth: \(context.agentDepth)/\(context.config.maxAgentDepth).
        CPSL is your execution environment: a Unix-like local environment with Luau as the command interface instead of Bash. Luau is the only supported execution language.
        Use /home/herm as the default home for durable user-created files and /tmp for temporary files. User-added files remain available under /attachments/<conversation-id>. Other Unix-style directories under / remain available when the task calls for them.
        You may use local_sandbox_exec for CPSL work, including the sandbox webbrowser module when it is available. You have no host shell, package manager, or provider-hosted capabilities.
        Calendar and location are available only through CPSL when compiled into the app sandbox and authorized by the user. Use them only when the assigned task materially needs schedule, event, availability, or current-place context. EventKit does not expose native calendar file attachments. Use calendar.attach to associate durable file copies with an event in Herm, and do not describe them as native Calendar.app attachments. Access states are granted, denied, or undefined; undefined access may prompt, and denied access must be fixed in iOS Settings or macOS System Settings.
        """
        return addingICloudMountContext(to: basePrompt)
    }

    private func subAgentOutput(_ draft: CPSLSubAgentOutputDraft) -> String {
        let body = draft.textParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let output = body.isEmpty ? "Sub-agent completed without text output." : body
        return "[agent mode:\(draft.mode.rawValue) turns:\(draft.turnsUsed)/\(draft.maxTurns)]\n\n\(output)"
    }

    private func traceInvocation(
        for toolCall: CPSLOpenAIToolCall,
        displayBody: String,
        isError: Bool
    ) -> CPSLToolTraceInvocation {
        CPSLToolTraceInvocation(
            id: toolCall.id,
            name: toolCall.function.name,
            summary: CPSLAgentToolFormatting.summary(for: toolCall),
            input: CPSLAgentToolFormatting.inputPreview(for: toolCall),
            output: displayBody,
            isError: isError
        )
    }

    private func providerToolContent(ok: Bool, output: String?, error: String?) -> String {
        var payload: [String: Any] = ["ok": ok]
        if let output {
            payload["output"] = CPSLAgentToolFormatting.truncatedText(output)
        }
        if let error {
            payload["error"] = error
        }
        guard JSONSerialization.isValidJSONObject(payload),
                let data = try? JSONSerialization.data(withJSONObject: payload),
                let json = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":"Could not encode tool result."}"#
        }
        return json
    }
}

private nonisolated enum CPSLAgentRequestPreparationBuilder {
    static func preparedRequestMessages(
        _ preparation: CPSLRequestPreparation,
        estimatedBytesPerToken: Int,
        toolResultClearThreshold: Double,
        recentToolResultsToKeep: Int
    ) -> [CPSLOpenAIMessage] {
        let compactedMessages = compactedProviderMessagesIfNeeded(
            preparation.providerMessages,
            systemPrompt: preparation.systemPrompt,
            config: preparation.config,
            estimatedBytesPerToken: estimatedBytesPerToken,
            toolResultClearThreshold: toolResultClearThreshold,
            recentToolResultsToKeep: recentToolResultsToKeep
        )
        let estimatedTokens = estimatedTokenCount(
            systemPrompt: preparation.systemPrompt,
            messages: compactedMessages,
            estimatedBytesPerToken: estimatedBytesPerToken
        )
        let prompt = systemPromptWithBudgetReminder(
            preparation,
            estimatedTokens: estimatedTokens
        )
        return [CPSLOpenAIMessage.system(prompt)] + compactedMessages
    }

    private static func compactedProviderMessagesIfNeeded(
        _ messages: [CPSLOpenAIMessage],
        systemPrompt: String,
        config: CPSLAgentConfig,
        estimatedBytesPerToken: Int,
        toolResultClearThreshold: Double,
        recentToolResultsToKeep: Int
    ) -> [CPSLOpenAIMessage] {
        let estimatedTokens = estimatedTokenCount(
            systemPrompt: systemPrompt,
            messages: messages,
            estimatedBytesPerToken: estimatedBytesPerToken
        )
        let replayThreshold = min(config.maxOutputTokens, Int.max / 4) * 4
        let contextThreshold = config.contextWindowTokens.flatMap { contextWindowTokens in
            contextWindowTokens > 0
                ? Int(Double(contextWindowTokens) * toolResultClearThreshold)
                : nil
        }
        let threshold = min(contextThreshold ?? replayThreshold, replayThreshold)
        guard estimatedTokens >= threshold else {
            return messages
        }

        var compacted = messages
        let toolIndices = compacted.indices.filter { compacted[$0].role == "tool" }
        let keepIndices = Set(toolIndices.suffix(recentToolResultsToKeep))
        for index in toolIndices where !keepIndices.contains(index) {
            compacted[index].content = clearedToolResultContent(from: compacted[index].content)
        }
        return compacted
    }

    private static func clearedToolResultContent(from content: String?) -> String {
        let summary = toolResultSummary(from: content)
        var payload: [String: Any] = [
            "ok": summary.ok,
            "stdout": summary.ok ? "[output cleared to reduce context]" : "",
            "stderr": ""
        ]
        if !summary.ok {
            payload["error"] = summary.failureText.isEmpty
                ? "[error output cleared to reduce context]"
                : "[error output cleared to reduce context]\n\(summary.failureText)"
        }
        guard JSONSerialization.isValidJSONObject(payload),
                let data = try? JSONSerialization.data(withJSONObject: payload),
                let json = String(data: data, encoding: .utf8)
        else {
            return summary.ok
                ? #"{"ok":true,"stdout":"[output cleared to reduce context]","stderr":""}"#
                : #"{"ok":false,"stdout":"","stderr":"","error":"[error output cleared to reduce context]"}"#
        }
        return json
    }

    private static func toolResultSummary(from content: String?) -> (ok: Bool, failureText: String) {
        guard let content,
                let data = content.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (false, "")
        }
        let ok = object["ok"] as? Bool ?? false
        guard !ok else {
            return (true, "")
        }

        let detailKeys = [
            "error",
            "error_message",
            "ffi_error",
            "stderr",
            "output",
            "exit_code",
            "error_code"
        ]
        let details = detailKeys.compactMap { key -> String? in
            guard let value = object[key] else {
                return nil
            }
            let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            return "\(key): \(text)"
        }
        let failureText = CPSLAgentToolFormatting.truncatedText(details.joined(separator: "\n"))
        return (false, failureText)
    }

    private static func systemPromptWithBudgetReminder(
        _ preparation: CPSLRequestPreparation,
        estimatedTokens: Int
    ) -> String {
        let currentIteration = preparation.iteration + 1
        var lines = [
            "Session: approximately \(estimatedTokens) replay tokens in the current request.",
            "Tool round: \(currentIteration)/\(preparation.maxIterations)."
        ]
        lines.append(
            "Current CPSL directory: \(CPSLAgentToolFormatting.promptPathLiteral(preparation.sandboxDirectory))."
        )
        if let contextWindowTokens = preparation.config.contextWindowTokens, contextWindowTokens > 0 {
            let percent = Int((Double(estimatedTokens) * 100 / Double(contextWindowTokens)).rounded())
            lines.append("Context: approximately \(percent)% full (\(estimatedTokens)/\(contextWindowTokens) tokens).")
        }
        if currentIteration >= 12 {
            lines.append("Use the evidence already gathered and finish now unless one essential action is still missing.")
        } else if currentIteration >= 8 {
            lines.append("Avoid repeating discovery. Start synthesizing the result and use more tools only for specific gaps.")
        }
        return preparation.systemPrompt
            + "\n\n<system-reminder>\n"
            + lines.joined(separator: "\n")
            + "\n</system-reminder>"
    }

    private static func estimatedTokenCount(
        systemPrompt: String,
        messages: [CPSLOpenAIMessage],
        estimatedBytesPerToken: Int
    ) -> Int {
        var bytes = systemPrompt.utf8.count
        for message in messages {
            bytes += message.role.utf8.count
            bytes += message.content?.utf8.count ?? 0
            bytes += message.toolCallID?.utf8.count ?? 0
            for toolCall in message.toolCalls ?? [] {
                bytes += toolCall.id.utf8.count
                bytes += toolCall.function.name.utf8.count
                bytes += toolCall.function.arguments.utf8.count
            }
        }
        return max(1, bytes / estimatedBytesPerToken)
    }
}
