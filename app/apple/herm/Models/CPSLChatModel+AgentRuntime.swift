import Foundation

@MainActor
extension CPSLChatModel {
    func runProviderLoop(_ context: inout CPSLProviderLoopContext) async throws {
        var toolStatusNodeID: String?
        var toolStatus = CPSLToolStatusPayload.running()
        var hasUnresolvedToolFailure = false
        clearActiveToolStatus()
        defer {
            clearActiveToolStatus()
        }

        for iteration in 0..<context.config.maxToolRounds {
            let sandboxDirectory = await service.currentDirectory()
            let requestMessages = preparedRequestMessages(
                CPSLRequestPreparation(
                    systemPrompt: context.systemPrompt,
                    providerMessages: context.providerMessages,
                    config: context.config,
                    sandboxDirectory: sandboxDirectory,
                    iteration: iteration,
                    maxIterations: context.config.maxToolRounds
                )
            )
            isSuppressingAssistantStream = false
            let completion = try await context.client.streamChat(
                CPSLOpenAIStreamRequest(
                    messages: requestMessages,
                    tools: CPSLOpenAITool.availableTools(
                        allowsSubagents: context.config.maxAgentDepth > 0,
                        currentDirectory: sandboxDirectory
                    ),
                    maxTokens: context.config.maxOutputTokens
                )
            ) { event in
                self.handleProviderStreamEvent(event)
            }

            await finishTypewriter()
            if !completion.toolCalls.isEmpty {
                discardStreamingAssistantIfNeeded()
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
                if hasUnresolvedToolFailure, let toolStatusNodeID {
                    toolStatus.state = .failed
                    try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: context.store)
                }
                if completion.text.isEmpty {
                    try await appendProviderLoopError("Provider returned an empty response.", context: &context)
                }
                return
            }

            var statusSummary = completion.toolCalls.first.map {
                CPSLAgentToolFormatting.statusSummary(for: $0, assistantText: completion.text)
            } ?? CPSLAgentToolFormatting.defaultStatusSummary
            let assistantToolMessage = CPSLOpenAIMessage.assistant(
                content: completion.text.isEmpty ? nil : completion.text,
                toolCalls: completion.toolCalls
            )

            if let toolStatusNodeID {
                toolStatus.state = .running
                toolStatus.summary = statusSummary
                try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: context.store)
            } else {
                toolStatus = CPSLToolStatusPayload.running(summary: statusSummary)
                let statusNode = try await context.store.appendNode(
                    conversationID: context.conversationID,
                    parentID: context.parentID,
                    draft: CPSLNodeAppendDraft(
                        role: .toolStatus,
                        title: nil,
                        body: toolStatus.encodedBody(),
                        model: completion.model,
                        providerMessage: nil
                    )
                )
                toolStatusNodeID = statusNode.id
                activeToolStatusNodeID = statusNode.id
                activeToolStatusPayload = toolStatus
                activeToolStatusStore = context.store
                context.parentID = statusNode.id
                context.onParentIDChange(context.parentID)
                if let message = statusNode.chatMessage {
                    messages.append(message)
                }
            }

            var executedToolCalls: [(toolCall: CPSLOpenAIToolCall, result: CPSLToolExecutionResult)] = []

            for toolCall in completion.toolCalls {
                statusSummary = CPSLAgentToolFormatting.statusSummary(
                    for: toolCall,
                    assistantText: completion.text
                )
                toolStatus.state = .running
                toolStatus.summary = statusSummary
                if let toolStatusNodeID {
                    try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: context.store)
                }

                let toolResult = await executeToolCall(
                    toolCall,
                    context: CPSLToolExecutionContext(
                        client: context.client,
                        config: context.config,
                        agentDepth: 0,
                        requestDirectory: sandboxDirectory
                    )
                )
                executedToolCalls.append((toolCall, toolResult))
                if toolResult.isError {
                    hasUnresolvedToolFailure = true
                    toolStatus.state = .running
                } else {
                    hasUnresolvedToolFailure = false
                    toolStatus.state = .succeeded
                }
#if DEBUG
                toolStatus.invocations.append(toolResult.debugInvocation)
                toolStatus.summary = statusSummary
                if let toolStatusNodeID {
                    try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: context.store)
                }
#endif
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
            toolStatus.summary = statusSummary
            toolStatus.state = hasUnresolvedToolFailure ? .running : .succeeded
            if let toolStatusNodeID {
                try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: context.store)
            }
        }

        if hasUnresolvedToolFailure, let toolStatusNodeID {
            toolStatus.state = .failed
            try await updateToolStatus(toolStatus, nodeID: toolStatusNodeID, store: context.store)
        }
        try await synthesizeAfterToolLimit(&context)
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
        let requestMessages = preparedRequestMessages(
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
        let completion = try await context.client.streamChat(
            CPSLOpenAIStreamRequest(
                messages: requestMessages,
                tools: [],
                maxTokens: context.config.maxOutputTokens
            )
        ) { event in
            self.handleProviderStreamEvent(event)
        }
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
        let body = effectivePayload.encodedBody()
        try await store.updateNodeBody(id: nodeID, body: body)
        guard let messageID = UUID(uuidString: nodeID),
                let index = messages.firstIndex(where: { $0.id == messageID })
        else {
            return
        }
        messages[index].body = body
    }

    private func clearActiveToolStatus() {
        activeToolStatusNodeID = nil
        activeToolStatusPayload = nil
        activeToolStatusStore = nil
    }

    private func preparedRequestMessages(_ preparation: CPSLRequestPreparation) -> [CPSLOpenAIMessage] {
        let compactedMessages = compactedProviderMessagesIfNeeded(
            preparation.providerMessages,
            systemPrompt: preparation.systemPrompt,
            config: preparation.config
        )
        let estimatedTokens = estimatedTokenCount(
            systemPrompt: preparation.systemPrompt,
            messages: compactedMessages
        )
        let prompt = systemPromptWithBudgetReminder(
            preparation,
            estimatedTokens: estimatedTokens
        )
        return [CPSLOpenAIMessage.system(prompt)] + compactedMessages
    }

    private func compactedProviderMessagesIfNeeded(
        _ messages: [CPSLOpenAIMessage],
        systemPrompt: String,
        config: CPSLAgentConfig
    ) -> [CPSLOpenAIMessage] {
        guard let contextWindowTokens = config.contextWindowTokens,
                contextWindowTokens > 0
        else {
            return messages
        }

        let estimatedTokens = estimatedTokenCount(systemPrompt: systemPrompt, messages: messages)
        let threshold = Int(Double(contextWindowTokens) * toolResultClearThreshold)
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

    private func clearedToolResultContent(from content: String?) -> String {
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

    private func toolResultSummary(from content: String?) -> (ok: Bool, failureText: String) {
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

    private func systemPromptWithBudgetReminder(
        _ preparation: CPSLRequestPreparation,
        estimatedTokens: Int
    ) -> String {
        let remainingIterations = max(0, preparation.maxIterations - preparation.iteration)
        var lines = ["Session: approximately \(estimatedTokens) replay tokens in the current request."]
        lines.append(
            "Current CPSL directory: \(CPSLAgentToolFormatting.promptPathLiteral(preparation.sandboxDirectory))."
        )
        if let contextWindowTokens = preparation.config.contextWindowTokens, contextWindowTokens > 0 {
            let percent = Int((Double(estimatedTokens) * 100 / Double(contextWindowTokens)).rounded())
            lines.append("Context: approximately \(percent)% full (\(estimatedTokens)/\(contextWindowTokens) tokens).")
        }
        let remainingFraction = Double(remainingIterations) / Double(preparation.maxIterations)
        if remainingFraction < 0.25 {
            lines.append("Tool budget: \(remainingIterations) of \(preparation.maxIterations) rounds remain; wrap up efficiently.")
        } else if remainingFraction < 0.50 {
            lines.append("Tool budget: past halfway with \(remainingIterations) of \(preparation.maxIterations) rounds remaining.")
        }
        return preparation.systemPrompt
            + "\n\n<system-reminder>\n"
            + lines.joined(separator: "\n")
            + "\n</system-reminder>"
    }

    private func estimatedTokenCount(systemPrompt: String, messages: [CPSLOpenAIMessage]) -> Int {
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

    private func handleProviderStreamEvent(_ event: CPSLOpenAIStreamEvent) {
        switch event {
        case .textDelta(let delta):
            guard !isSuppressingAssistantStream else {
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
                debugInvocation: debugInvocation(
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
            debugInvocation: debugInvocation(for: toolCall, displayBody: displayBody, isError: true)
        )
    }

    private func executeSandboxToolCall(_ toolCall: CPSLOpenAIToolCall) async -> CPSLToolExecutionResult {
        guard let source = CPSLAgentToolFormatting.source(from: toolCall.function.arguments) else {
            return CPSLToolExecutionResult(
                providerContent: #"{"ok":false,"error":"Missing source argument."}"#,
                displayBody: "Missing source argument.",
                isError: true,
                debugInvocation: debugInvocation(
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
            debugInvocation: debugInvocation(for: toolCall, displayBody: displayBody, isError: isError)
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
                debugInvocation: debugInvocation(for: toolCall, displayBody: message, isError: true)
            )
        }

        let childDepth = context.agentDepth + 1
        guard childDepth <= context.config.maxAgentDepth else {
            let message = "Sub-agent depth limit reached."
            return CPSLToolExecutionResult(
                providerContent: providerToolContent(ok: false, output: nil, error: message),
                displayBody: message,
                isError: true,
                debugInvocation: debugInvocation(for: toolCall, displayBody: message, isError: true)
            )
        }

        let result = await runSubAgent(
            input: input,
            context: CPSLToolExecutionContext(
                client: context.client,
                config: context.config,
                agentDepth: childDepth,
                requestDirectory: nil
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
            debugInvocation: debugInvocation(for: toolCall, displayBody: result.output, isError: result.isError)
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
                let turnGuidance = isFinalTurn
                    ? "Budget: turn \(turn + 1)/\(maxTurns). FINAL, produce summary, no tools."
                    : "Budget: turn \(turn + 1)/\(maxTurns)."
                let requestMessages = [
                    CPSLOpenAIMessage.system(
                        subAgentSystemPrompt
                            + "\n\n<system-reminder>\n"
                            + "\(turnGuidance)\n"
                            + "Current CPSL directory: \(CPSLAgentToolFormatting.promptPathLiteral(sandboxDirectory)).\n"
                            + "</system-reminder>"
                    )
                ] + providerMessages
                let completion = try await context.client.streamChat(
                    CPSLOpenAIStreamRequest(
                        messages: requestMessages,
                        tools: isFinalTurn ? [] : CPSLOpenAITool.availableTools(
                            allowsSubagents: context.agentDepth < context.config.maxAgentDepth,
                            currentDirectory: sandboxDirectory
                        ),
                        maxTokens: context.config.maxOutputTokens
                    )
                ) { _ in }

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
                            requestDirectory: sandboxDirectory
                        )
                    )
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
        """
        You are a Herm sub-agent running inside the same iOS/macOS app.
        Complete the assigned task, then return a concise result. Do not ask questions.
        Mode: \(mode.rawValue). Turn budget: \(maxTurns). Agent depth: \(context.agentDepth)/\(context.config.maxAgentDepth).
        CPSL is your execution environment: a Unix-like local environment with Luau as the command interface instead of Bash. Luau is the only supported execution language.
        Use /home/herm as the default home for durable user-created files and /tmp for temporary files. Other Unix-style directories under / remain available when the task calls for them.
        You may use local_sandbox_exec for CPSL work. You have no host shell, package manager, browser, or provider-hosted capabilities.
        Calendar and location are available only through CPSL when compiled into the app sandbox and authorized by the user. Use them only when the assigned task materially needs schedule, event, availability, or current-place context. Access states are granted, denied, or undefined; undefined access may prompt, and denied access must be fixed in iOS Settings or macOS System Settings.
        """
    }

    private func subAgentOutput(_ draft: CPSLSubAgentOutputDraft) -> String {
        let body = draft.textParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let output = body.isEmpty ? "Sub-agent completed without text output." : body
        return "[agent mode:\(draft.mode.rawValue) turns:\(draft.turnsUsed)/\(draft.maxTurns)]\n\n\(output)"
    }

    private func debugInvocation(
        for toolCall: CPSLOpenAIToolCall,
        displayBody: String,
        isError: Bool
    ) -> CPSLToolStatusInvocation {
        CPSLToolStatusInvocation(
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
