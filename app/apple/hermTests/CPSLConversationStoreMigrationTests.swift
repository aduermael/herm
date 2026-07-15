import Foundation
import Testing
@testable import herm

struct CPSLConversationStoreMigrationTests {
    @Test func migrationIsIdempotent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-test-\(UUID().uuidString).sqlite")
        _ = try CPSLConversationStore(databaseURL: url, usesICloudContainer: false)
        // Reopening the same database replays migrate() without error.
        _ = try CPSLConversationStore(databaseURL: url, usesICloudContainer: false)
    }
}
