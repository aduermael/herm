import Foundation

/// Pure drawer presentation for conversation list readiness vs true-empty states.
nonisolated enum CPSLConversationListPresentation: Equatable, Sendable {
    case loading
    case emptySearch
    case emptyArchived
    case emptyFresh
    case populated

    /// - Parameter hasVisibleConversations: Whether the *filtered* list (search/tags)
    ///   has rows to show — not the raw store count. Empty search hits must report false.
    static func resolve(
        isLoading: Bool,
        isSearching: Bool,
        showingArchived: Bool,
        hasVisibleConversations: Bool
    ) -> CPSLConversationListPresentation {
        if hasVisibleConversations {
            return .populated
        }
        if isLoading {
            return .loading
        }
        if isSearching {
            return .emptySearch
        }
        if showingArchived {
            return .emptyArchived
        }
        return .emptyFresh
    }

    /// Title shown for empty/loading panes. Nil when the list is populated.
    var title: String? {
        switch self {
        case .loading:
            return "Loading conversations"
        case .emptySearch:
            return "No matches"
        case .emptyArchived:
            return "Nothing archived"
        case .emptyFresh:
            return "No conversations yet"
        case .populated:
            return nil
        }
    }
}
