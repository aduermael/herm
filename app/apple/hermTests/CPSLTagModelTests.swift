import Foundation
import Testing
@testable import herm

struct CPSLTagModelTests {
    @Test func summaryCarriesPinnedAndArchived() {
        let summary = CPSLConversationSummary(
            id: "a", title: "t", currentNodeID: nil, model: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            pinned: true, archived: false
        )
        #expect(summary.pinned)
        #expect(!summary.archived)
    }

    @Test func tagIsIdentifiable() {
        let tag = CPSLTag(id: "1", name: "Work", color: "mauve", createdAt: Date(timeIntervalSince1970: 0))
        #expect(tag.id == "1")
    }
}
