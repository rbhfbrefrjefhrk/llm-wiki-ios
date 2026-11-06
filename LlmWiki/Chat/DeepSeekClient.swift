import Foundation

enum ChatError: LocalizedError {
    case noKey
    case unauthorized
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey: return "未配置 DeepSeek API Key，请到「设置」页填写"
        case .unauthorized: return "API Key 无效（401）"
        case .http(let c): return "请求失败（HTTP \(c)）"
        case .badResponse: return "响应格式异常"
        }
    }
}

/// DeepSeek（OpenAI 兼容）流式问答客户端。
final class DeepSeekClient {
    struct Message: Codable {
        let role: String
        let content: String
    }

    private let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    func stream(
        messages: [Message],
        apiKey: String,
        model: String,
        onDelta: @escaping (String) -> Void
    ) async throws {
        guard !apiKey.isEmpty else { throw ChatError.noKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatError.badResponse }
        if http.statusCode == 401 { throw ChatError.unauthorized }
        guard http.statusCode == 200 else { throw ChatError.http(http.statusCode) }

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }

            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let text = delta["content"] as? String,
                  !text.isEmpty
            else { continue }

            onDelta(text)
        }
    }
}
