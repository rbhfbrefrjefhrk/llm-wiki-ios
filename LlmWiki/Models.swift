import Foundation

struct WikiPageSummary: Identifiable, Hashable {
    let name: String
    let path: String
    var id: String { path }
}

struct WikiCategory: Identifiable {
    let key: String
    let title: String
    let pages: [WikiPageSummary]
    var id: String { key }
}

struct SearchHit: Identifiable {
    let path: String
    let content: String
    let score: Float
    var id: String { path + "#" + String(format: "%.4f", score) }
}

struct SyncState: Codable {
    var version: String
    var syncedAt: Double
    var pageCount: Int
    var totalBytes: Int64
}

struct ChatSource: Codable, Hashable {
    let path: String
    let name: String
    let score: Float
}

struct ChatMessage: Identifiable, Codable {
    let id: String
    var role: String          // "user" / "assistant"
    var content: String
    var sources: [ChatSource]
    var createdAt: Double

    init(id: String = UUID().uuidString, role: String, content: String,
         sources: [ChatSource] = [], createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.role = role
        self.content = content
        self.sources = sources
        self.createdAt = createdAt
    }
}
