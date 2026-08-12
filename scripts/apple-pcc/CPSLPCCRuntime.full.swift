import Foundation
import FoundationModels

/// Full PCC runtime for SDKs that ship PrivateCloudComputeLanguageModel (iOS/macOS 27+).
/// Tool calls are intercepted so herm's outer provider loop can execute them.
enum CPSLPCCRuntime {
    static var isCompileTimeSupported: Bool { true }

    static var isAvailable: Bool {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        return false
    }

    static func streamChat(
        _ streamRequest: CPSLOpenAIStreamRequest,
        modelID: String,
        onEvent: @escaping (CPSLOpenAIStreamEvent) async -> Void
    ) async throws -> CPSLOpenAICompletion {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return try await CPSLPCCClient(modelID: modelID).streamChat(
                streamRequest,
                onEvent: onEvent
            )
        }
        throw CPSLOpenAIError.provider(
            "Apple Private Cloud Compute requires iOS/macOS 27 or later."
        )
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private struct CPSLPCCClient: Sendable {
    private let modelID: String

    init(modelID: String) {
        self.modelID = modelID
    }

    func streamChat(
        _ streamRequest: CPSLOpenAIStreamRequest,
        onEvent: @escaping (CPSLOpenAIStreamEvent) async -> Void
    ) async throws -> CPSLOpenAICompletion {
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable else {
            throw CPSLOpenAIError.provider(
                "Apple Private Cloud Compute is unavailable on this device."
            )
        }

        let mapped = CPSLPCCMessageMapper.mapPrompt(messages: streamRequest.messages)
        let capture = CPSLPCCToolCapture()
        let tools = makeTools(from: streamRequest.tools, capture: capture)
        let session = LanguageModelSession(
            model: model,
            tools: tools,
            instructions: mapped.instructions
        )

        var options = GenerationOptions()
        if let maxTokens = streamRequest.maxTokens, maxTokens > 0 {
            options.maximumResponseTokens = maxTokens
        }

        do {
            let text = try await streamText(
                StreamTextRequest(session: session, prompt: mapped.prompt, options: options),
                onEvent: onEvent
            )
            return CPSLPCCMessageMapper.completion(
                text: text,
                toolCalls: [],
                model: modelID
            )
        } catch is CPSLPCCOuterLoopSignal {
            let toolCalls = capture.snapshot()
            if !toolCalls.isEmpty {
                await onEvent(.toolCallDelta)
            }
            return CPSLPCCMessageMapper.completion(
                text: "",
                toolCalls: toolCalls,
                model: modelID
            )
        } catch let error as LanguageModelSession.ToolCallError {
            if error.underlyingError is CPSLPCCOuterLoopSignal {
                let toolCalls = capture.snapshot()
                if !toolCalls.isEmpty {
                    await onEvent(.toolCallDelta)
                }
                return CPSLPCCMessageMapper.completion(
                    text: "",
                    toolCalls: toolCalls,
                    model: modelID
                )
            }
            throw CPSLOpenAIError.provider(error.localizedDescription)
        } catch {
            throw CPSLOpenAIError.provider(error.localizedDescription)
        }
    }

    private struct StreamTextRequest {
        let session: LanguageModelSession
        let prompt: String
        let options: GenerationOptions
    }

    private func streamText(
        _ request: StreamTextRequest,
        onEvent: @escaping (CPSLOpenAIStreamEvent) async -> Void
    ) async throws -> String {
        var previous = ""
        let stream = request.session.streamResponse(
            to: request.prompt,
            options: request.options
        )
        for try await snapshot in stream {
            try Task.checkCancellation()
            let current = String(describing: snapshot.content)
            let delta: String
            if current.hasPrefix(previous) {
                delta = String(current.dropFirst(previous.count))
            } else {
                delta = current
            }
            previous = current
            if !delta.isEmpty {
                await onEvent(.textDelta(delta))
            }
        }
        return previous
    }

    private func makeTools(
        from openAITools: [CPSLOpenAITool],
        capture: CPSLPCCToolCapture
    ) -> [any Tool] {
        guard CPSLPCCMessageMapper.shouldAttachTools(openAITools) else {
            return []
        }
        var tools: [any Tool] = []
        for tool in openAITools {
            switch tool.function.name {
            case "local_sandbox_exec":
                tools.append(
                    CPSLPCCLocalSandboxTool(
                        description: tool.function.description,
                        capture: capture
                    )
                )
            case "agent":
                tools.append(
                    CPSLPCCAgentTool(
                        description: tool.function.description,
                        capture: capture
                    )
                )
            default:
                continue
            }
        }
        return tools
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private struct CPSLPCCOuterLoopSignal: Error {}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private final class CPSLPCCToolCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [CPSLOpenAIToolCall] = []
    private var nextID = 0

    func register(name: String, arguments: String) throws {
        lock.lock()
        nextID += 1
        let id = "pcc_call_\(nextID)"
        calls.append(
            CPSLPCCMessageMapper.toolCall(id: id, name: name, arguments: arguments)
        )
        lock.unlock()
        throw CPSLPCCOuterLoopSignal()
    }

    func snapshot() -> [CPSLOpenAIToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private struct CPSLPCCLocalSandboxTool: Tool {
    let name = "local_sandbox_exec"
    let description: String
    let capture: CPSLPCCToolCapture

    @Generable
    struct Arguments {
        var intent: String
        var source: String
    }

    func call(arguments: Arguments) async throws -> String {
        let json = try CPSLPCCMessageMapper.encodeStringFields([
            "intent": arguments.intent,
            "source": arguments.source
        ])
        try capture.register(name: name, arguments: json)
        return ""
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
private struct CPSLPCCAgentTool: Tool {
    let name = "agent"
    let description: String
    let capture: CPSLPCCToolCapture

    @Generable
    struct Arguments {
        var intent: String
        var task: String
        var mode: String
    }

    func call(arguments: Arguments) async throws -> String {
        let json = try CPSLPCCMessageMapper.encodeStringFields([
            "intent": arguments.intent,
            "task": arguments.task,
            "mode": arguments.mode
        ])
        try capture.register(name: name, arguments: json)
        return ""
    }
}
