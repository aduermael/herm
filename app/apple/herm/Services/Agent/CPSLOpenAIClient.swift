import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor CPSLOpenAIClient {
    private let config: CPSLAgentConfig
    private let session: URLSession

    init(config: CPSLAgentConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func streamChat(
        messages: [CPSLOpenAIMessage],
        onEvent: @escaping (CPSLOpenAIStreamEvent) async -> Void
    ) async throws -> CPSLOpenAICompletion {
        let requestBody = CPSLOpenAIChatRequest(
            model: config.model,
            messages: messages,
            tools: [CPSLOpenAITool.localSandboxExec],
            toolChoice: "auto",
            stream: true
        )

        var request = URLRequest(url: chatCompletionsURL())
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        let (bytes, response) = try await session.bytes(for: request)
        try await validate(response: response, bytes: bytes)

        let accumulator = CPSLOpenAIStreamAccumulator(model: config.model)
        for try await line in bytes.lines {
            guard let event = try accumulator.consume(line: line) else {
                continue
            }
            await onEvent(event)
        }
        return try accumulator.validatedCompletion()
    }

    private func validate(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = await errorBodyPreview(from: bytes)
            throw CPSLOpenAIError.httpStatus(httpResponse.statusCode, body)
        }
    }

    private func errorBodyPreview(from bytes: URLSession.AsyncBytes) async -> String {
        var body = ""
        do {
            for try await line in bytes.lines {
                if !body.isEmpty {
                    body.append("\n")
                }
                body.append(line)
                if body.count > 4_096 {
                    return String(body.prefix(4_096))
                }
            }
        } catch {
            return ""
        }
        return body
    }

    private func chatCompletionsURL() -> URL {
        config.baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
    }
}
