import Foundation

/// 问答编排：端侧检索片段 → system 上下文 → 云端 DeepSeek 流式生成。
final class ChatService {
    private let storage: WikiStorage
    private let index: LocalSearchIndex
    private let embedder: OnnxEmbedder
    private let client = DeepSeekClient()

    init(storage: WikiStorage, index: LocalSearchIndex, embedder: OnnxEmbedder) {
        self.storage = storage
        self.index = index
        self.embedder = embedder
    }

    func stream(
        question: String,
        history: [ChatMessage],
        onDelta: @escaping (String) -> Void,
        onSources: @escaping ([ChatSource]) -> Void
    ) async throws -> String {
        let version = storage.loadState()?.version ?? "local"
        _ = try await index.ensureIndex(version: version, storage: storage, embedder: embedder)
        let hits = try await index.search(question, topK: AppConfig.shared.topK, embedder: embedder)

        let sources = hits.map {
            ChatSource(
                path: $0.path,
                name: ($0.path as NSString).lastPathComponent
                    .replacingOccurrences(of: ".md", with: ""),
                score: $0.score
            )
        }
        onSources(sources)

        let messages = buildMessages(question: question, history: history, hits: hits)
        var full = ""
        try await client.stream(
            messages: messages,
            apiKey: AppConfig.shared.deepseekKey,
            model: AppConfig.shared.deepseekModel
        ) { chunk in
            full += chunk
            onDelta(chunk)
        }
        return full
    }

    private func buildMessages(question: String, history: [ChatMessage], hits: [SearchHit]) -> [DeepSeekClient.Message] {
        let context: String
        if hits.isEmpty {
            context = "（本次未检索到知识库片段，请基于通用知识回答，并说明未命中知识库。）"
        } else {
            context = hits.enumerated().map { pair in
                "[\(pair.offset + 1)] \(pair.element.path)（相似度 \(String(format: "%.2f", pair.element.score))）\n\(pair.element.content)"
            }.joined(separator: "\n\n")
        }

        let system = "你是用户的个人知识库问答助手。请优先依据下面的检索片段作答，" +
            "并在句末用 [1][2] 的形式标注引用；若片段不足，请明确说明。\n\n【检索片段】\n\(context)"

        var messages: [DeepSeekClient.Message] = [.init(role: "system", content: system)]
        for message in history.filter({ $0.role == "user" || $0.role == "assistant" })
            .filter({ !$0.content.isEmpty })
            .suffix(6) {
            messages.append(.init(role: message.role, content: message.content))
        }
        messages.append(.init(role: "user", content: question))
        return messages
    }
}
