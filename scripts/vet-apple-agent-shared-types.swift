import Foundation

nonisolated struct CPSLWebSearchVisit: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let browserID: String
    let url: String
    let title: String
    let host: String
    let faviconURL: String?
}
