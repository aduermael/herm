import Foundation

nonisolated extension String {
    func localizedSearchContains(_ query: String) -> Bool {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let needle = query.folding(options: opts, locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return folding(options: opts, locale: .current).contains(needle)
    }
}

nonisolated enum CPSLConversationDateSection: Int, CaseIterable {
    case today, last7Days, last30Days, older

    var title: String {
        switch self {
        case .today: return "Today"
        case .last7Days: return "Previous 7 days"
        case .last30Days: return "Previous 30 days"
        case .older: return "Older"
        }
    }

    static func section(for date: Date, now: Date, calendar: Calendar) -> CPSLConversationDateSection {
        let startDate = calendar.startOfDay(for: date)
        let startNow = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: startDate, to: startNow).day ?? 0
        switch days {
        case ..<1: return .today       // 0 or negative (clock skew)
        case 1...7: return .last7Days
        case 8...30: return .last30Days
        default: return .older
        }
    }
}

nonisolated struct CPSLConversationSectionGroup: Identifiable {
    enum Kind: Equatable {
        case pinned
        case date(CPSLConversationDateSection)
    }
    let kind: Kind
    let title: String
    let conversations: [CPSLConversationSummary]

    var id: String {
        switch kind {
        case .pinned: return "pinned"
        case .date(let s): return "date-\(s.rawValue)"
        }
    }
}

nonisolated enum CPSLConversationGrouping {
    static func sections(
        summaries: [CPSLConversationSummary],
        searchText: String,
        now: Date,
        calendar: Calendar
    ) -> [CPSLConversationSectionGroup] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.isEmpty
            ? summaries
            : summaries.filter { $0.title.localizedSearchContains(trimmed) }

        let sorted = filtered.sorted { $0.updatedAt > $1.updatedAt }

        var groups: [CPSLConversationSectionGroup] = []

        let pinned = sorted.filter(\.pinned)
        if !pinned.isEmpty {
            groups.append(.init(kind: .pinned, title: "Pinned", conversations: pinned))
        }

        let rest = sorted.filter { !$0.pinned }
        let bucketed = Dictionary(grouping: rest) {
            CPSLConversationDateSection.section(for: $0.updatedAt, now: now, calendar: calendar)
        }
        for section in CPSLConversationDateSection.allCases {
            if let inSection = bucketed[section], !inSection.isEmpty {
                groups.append(.init(kind: .date(section), title: section.title, conversations: inSection))
            }
        }
        return groups
    }
}
