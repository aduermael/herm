import Foundation

enum CPSLSeedConversation {
    static func load(from bundle: Bundle = .main) -> [CPSLChatMessage] {
        guard let url = seedURL(in: bundle),
              let data = try? Data(contentsOf: url),
              let conversation = try? JSONDecoder().decode(Conversation.self, from: data)
        else {
            return []
        }

        return conversation.messages.map {
            CPSLChatMessage(role: $0.role, title: $0.title, body: $0.body)
        }
    }

    private static func seedURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "SeedConversation", withExtension: "json")
            ?? bundle.url(forResource: "SeedConversation", withExtension: "json", subdirectory: "Resources")
    }
}

private struct Conversation: Decodable {
    let messages: [Message]
}

private struct Message: Decodable {
    let role: CPSLChatRole
    let title: String?
    let body: String
}
