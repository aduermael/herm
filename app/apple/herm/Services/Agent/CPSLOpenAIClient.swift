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
        _ streamRequest: CPSLOpenAIStreamRequest,
        onEvent: @escaping (CPSLOpenAIStreamEvent) async -> Void
    ) async throws -> CPSLOpenAICompletion {
        let requestBody = CPSLOpenAIChatRequest(
            model: config.model,
            messages: streamRequest.messages,
            tools: streamRequest.tools.isEmpty ? nil : streamRequest.tools,
            toolChoice: streamRequest.tools.isEmpty ? nil : "auto",
            maxCompletionTokens: streamRequest.maxTokens,
            stream: true
        )

        var request = URLRequest(url: chatCompletionsURL())
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(requestBody)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")

        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        try await validate(response: response, bytes: bytes)

        let accumulator = CPSLOpenAIStreamAccumulator(model: config.model)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let event = try accumulator.consume(line: line) else {
                continue
            }
            await onEvent(event)
        }
        try Task.checkCancellation()
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

nonisolated struct CPSLOpenAIStreamRequest: Sendable {
    let messages: [CPSLOpenAIMessage]
    let tools: [CPSLOpenAITool]
    let maxTokens: Int?
}

nonisolated struct CPSLVisionInput: Sendable {
    let data: Data
    let mediaType: String
}

actor CPSLVisionClient {
    private let config: CPSLAgentConfig
    private let session: URLSession

    init(config: CPSLAgentConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    func read(inputs: [CPSLVisionInput], query: String) async throws -> String {
        guard !inputs.isEmpty,
              inputs.allSatisfy({ ["image/jpeg", "image/png"].contains($0.mediaType) })
        else {
            throw CPSLOpenAIError.provider(
                "This vision endpoint accepts JPEG and PNG inputs. Use structural mode for other file types."
            )
        }
        var content = [CPSLVisionContentPart(type: "text", text: query, imageURL: nil)]
        content.append(contentsOf: inputs.map { input in
            CPSLVisionContentPart(
                type: "image_url",
                text: nil,
                imageURL: CPSLVisionImageURL(
                    url: "data:\(input.mediaType);base64,\(input.data.base64EncodedString())"
                )
            )
        })
        let body = CPSLVisionChatRequest(
            model: config.visionModel,
            messages: [CPSLVisionMessage(role: "user", content: content)],
            maxCompletionTokens: config.maxOutputTokens
        )
        var request = URLRequest(url: config.visionBaseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.visionToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            throw CPSLOpenAIError.httpStatus(
                httpResponse.statusCode,
                String(decoding: data.prefix(4_096), as: UTF8.self)
            )
        }
        let completion = try JSONDecoder().decode(CPSLVisionChatResponse.self, from: data)
        guard let text = completion.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            throw CPSLOpenAIError.provider("Vision model returned no text.")
        }
        return text
    }
}

nonisolated struct CPSLVisionChatRequest: Encodable, Sendable {
    let model: String
    let messages: [CPSLVisionMessage]
    let maxCompletionTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxCompletionTokens = "max_completion_tokens"
    }
}

nonisolated struct CPSLVisionMessage: Encodable, Sendable {
    let role: String
    let content: [CPSLVisionContentPart]
}

nonisolated struct CPSLVisionContentPart: Encodable, Sendable {
    let type: String
    let text: String?
    let imageURL: CPSLVisionImageURL?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }
}

nonisolated struct CPSLVisionImageURL: Encodable, Sendable {
    let url: String
}

private nonisolated struct CPSLVisionChatResponse: Decodable, Sendable {
    let choices: [CPSLVisionChoice]
}

private nonisolated struct CPSLVisionChoice: Decodable, Sendable {
    let message: CPSLVisionResponseMessage
}

private nonisolated struct CPSLVisionResponseMessage: Decodable, Sendable {
    let content: String?
}
