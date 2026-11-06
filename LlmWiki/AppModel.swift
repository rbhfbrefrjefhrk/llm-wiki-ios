import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let storage = WikiStorage()
    private let index = LocalSearchIndex()
    private var embedder: OnnxEmbedder?
    private lazy var sync = GiteeSyncManager(storage: storage)

    @Published var categories: [WikiCategory] = []
    @Published var state: SyncState?
    @Published var busy = false
    @Published var status = ""
    @Published var messages: [ChatMessage] = []
    @Published var streamingText = ""
    @Published var streamingSources: [ChatSource] = []

    private static let categoryOrder = ["entities", "topics", "sources", "comparisons", "synthesis"]
    private static let categoryTitles = [
        "entities": "实体",
        "topics": "主题",
        "sources": "来源",
        "comparisons": "对比",
        "synthesis": "综述",
    ]

    init() {
        state = storage.loadState()
        messages = storage.loadChat()
        categories = makeCategories()
    }

    // MARK: - 浏览

    func reload() {
        state = storage.loadState()
        categories = makeCategories()
    }

    func pageContent(_ path: String) -> String {
        storage.read(path) ?? "（本地没有该页面，请先同步）"
    }

    private func makeCategories() -> [WikiCategory] {
        let manifest = storage.loadManifest()
        var buckets: [String: [WikiPageSummary]] = [:]

        for path in manifest.keys where path.hasPrefix("wiki/") && path.hasSuffix(".md") {
            let parts = path.split(separator: "/")
            guard parts.count >= 3 else { continue }
            let category = String(parts[1])
            let name = (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".md", with: "")
            buckets[category, default: []].append(WikiPageSummary(name: name, path: path))
        }

        return AppModel.categoryOrder.map { key in
            WikiCategory(
                key: key,
                title: AppModel.categoryTitles[key] ?? key,
                pages: (buckets[key] ?? []).sorted { $0.name < $1.name }
            )
        }
    }

    // MARK: - 检索

    func search(_ query: String) async throws -> [SearchHit] {
        let embedder = try await embedderOrThrow()
        let version = state?.version ?? "local"
        _ = try await index.ensureIndex(version: version, storage: storage, embedder: embedder)
        return try await index.search(query, topK: AppConfig.shared.topK, embedder: embedder)
    }

    // MARK: - 同步

    func syncNow() async {
        guard !busy else { return }
        busy = true
        status = "正在从 gitee 拉取…"
        do {
            let outcome = try await sync.sync { done, total in
                Task { @MainActor in
                    self.status = "下载中 \(done)/\(total)"
                }
            }
            status = outcome.message
            reload()
        } catch {
            status = "同步失败：\(error.localizedDescription)"
        }
        busy = false
    }

    // MARK: - 问答

    func send(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let history = messages
        messages.append(ChatMessage(role: "user", content: trimmed))
        streamingText = ""
        streamingSources = []

        do {
            let embedder = try await embedderOrThrow()
            let service = ChatService(storage: storage, index: index, embedder: embedder)
            _ = try await service.stream(
                question: trimmed,
                history: history,
                onDelta: { chunk in
                    Task { @MainActor in self.streamingText += chunk }
                },
                onSources: { sources in
                    Task { @MainActor in self.streamingSources = sources }
                }
            )

            let answer = ChatMessage(role: "assistant", content: streamingText, sources: streamingSources)
            messages.append(answer)
            storage.saveChat(messages)
        } catch {
            messages.append(ChatMessage(role: "assistant", content: "出错：\(error.localizedDescription)"))
            storage.saveChat(messages)
        }

        streamingText = ""
        streamingSources = []
    }

    func clearChat() {
        messages = []
        storage.saveChat([])
    }

    // MARK: - 模型

    private func embedderOrThrow() async throws -> OnnxEmbedder {
        if let embedder { return embedder }
        let created = try await Task.detached(priority: .userInitiated) { try OnnxEmbedder() }.value
        embedder = created
        return created
    }
}
