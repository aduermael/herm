import Foundation
import Testing
@testable import herm

struct CPSLConversationBrowsingTests {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)!
    }

    @Test func searchIsDiacriticAndCaseInsensitive() {
        #expect("Réunion Éléphant".localizedSearchContains("reunion"))
        #expect("Réunion Éléphant".localizedSearchContains("ELEPHANT"))
        #expect(!"Réunion".localizedSearchContains("xyz"))
    }

    @Test func dateSectionBounds() {
        let now = date("2026-07-11T12:00:00Z")
        #expect(CPSLConversationDateSection.section(for: date("2026-07-11T01:00:00Z"), now: now, calendar: cal) == .today)
        #expect(CPSLConversationDateSection.section(for: date("2026-07-08T12:00:00Z"), now: now, calendar: cal) == .last7Days)
        #expect(CPSLConversationDateSection.section(for: date("2026-07-01T12:00:00Z"), now: now, calendar: cal) == .last30Days)
        #expect(CPSLConversationDateSection.section(for: date("2026-05-01T12:00:00Z"), now: now, calendar: cal) == .older)
    }

    @Test func groupingSeparatesPinnedAndDropsEmpty() {
        let now = date("2026-07-11T12:00:00Z")
        func s(_ id: String, _ updated: String, pinned: Bool, _ title: String = "t") -> CPSLConversationSummary {
            CPSLConversationSummary(id: id, title: title, currentNodeID: nil, model: nil,
                createdAt: date(updated), updatedAt: date(updated), pinned: pinned, archived: false)
        }
        let items = [
            s("p", "2026-07-11T09:00:00Z", pinned: true),
            s("a", "2026-07-11T10:00:00Z", pinned: false),
            s("b", "2026-05-01T10:00:00Z", pinned: false)
        ]
        let groups = CPSLConversationGrouping.sections(summaries: items, searchText: "", now: now, calendar: cal)
        #expect(groups.first?.kind == .pinned)
        #expect(groups.first?.conversations.map(\.id) == ["p"])
        let dated = groups.dropFirst().flatMap { $0.conversations.map(\.id) }
        #expect(!dated.contains("p"))
        #expect(dated == ["a", "b"])
        #expect(!groups.contains { $0.conversations.isEmpty })
    }

    @Test func groupingAppliesTitleSearch() {
        let now = date("2026-07-11T12:00:00Z")
        func s(_ id: String, _ title: String) -> CPSLConversationSummary {
            CPSLConversationSummary(id: id, title: title, currentNodeID: nil, model: nil,
                createdAt: now, updatedAt: now, pinned: false, archived: false)
        }
        let items = [s("a", "Migration Postgres"), s("b", "Brainstorm pricing")]
        let groups = CPSLConversationGrouping.sections(summaries: items, searchText: "postgres", now: now, calendar: cal)
        let ids = groups.flatMap { $0.conversations.map(\.id) }
        #expect(ids == ["a"])
    }

    @Test func loadingPresentationAvoidsFalseEmpty() {
        let loading = CPSLConversationListPresentation.resolve(
            isLoading: true,
            isSearching: false,
            showingArchived: false,
            hasVisibleConversations: false
        )
        #expect(loading == .loading)
        #expect(loading.title == "Loading conversations")
        #expect(loading.title != "No conversations yet")

        let readyWithData = CPSLConversationListPresentation.resolve(
            isLoading: true,
            isSearching: false,
            showingArchived: false,
            hasVisibleConversations: true
        )
        #expect(readyWithData == .populated)

        let trueEmpty = CPSLConversationListPresentation.resolve(
            isLoading: false,
            isSearching: false,
            showingArchived: false,
            hasVisibleConversations: false
        )
        #expect(trueEmpty == .emptyFresh)
        #expect(trueEmpty.title == "No conversations yet")
    }

    @Test func searchWithZeroVisibleHitsShowsNoMatches() {
        // Store may have conversations; filtered groups empty → emptySearch.
        let noMatches = CPSLConversationListPresentation.resolve(
            isLoading: false,
            isSearching: true,
            showingArchived: false,
            hasVisibleConversations: false
        )
        #expect(noMatches == .emptySearch)
        #expect(noMatches.title == "No matches")
    }
}
