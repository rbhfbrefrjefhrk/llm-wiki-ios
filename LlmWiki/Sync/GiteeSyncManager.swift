import Foundation

struct SyncOutcome {
    let version: String
    let added: Int
    let updated: Int
    let removed: Int
    let pageCount: Int
    let message: String
}

enum SyncError: LocalizedError {
    case noToken
    case unauthorized
    case forbidden
    case rateLimited
    case http(Int)
    case badResponse
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "未配置 gitee 私人令牌（仓库为私有时必须）"
        case .unauthorized: return "gitee 令牌无效或已过期（401），请在设置里重新生成并勾选 projects 权限"
        case .forbidden: return "gitee 拒绝访问（403）：令牌权限不足，或请求频率过高被限流；请确认令牌勾选了 projects 权限后稍等片刻重试"
        case .rateLimited: return "gitee 请求过于频繁（429），已自动降速重试仍然失败，请过几分钟再同步"
        case .http(let c): return "gitee 请求失败（HTTP \(c)）"
        case .badResponse: return "gitee 返回格式异常"
        case .decodeFailed(let p): return "文件解码失败：\(p)"
        }
    }
}

/// 方案 C 的数据源：用 gitee OpenAPI 直拉 `app-wiki` 分支（私有仓库用私人令牌认证）。
/// 之所以不用 git 协议：iOS 上引入 libgit2 成本高，REST 只需 URLSession。
final class GiteeSyncManager {
    private struct TreeEntry {
        let path: String
        let type: String
        let sha: String
    }

    private let cfg = AppConfig.shared
    private let storage: WikiStorage
    private let session: URLSession

    init(storage: WikiStorage) {
        self.storage = storage
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.httpMaximumConnectionsPerHost = 8
        self.session = URLSession(configuration: configuration)
    }

    func sync(progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> SyncOutcome {
        let owner = cfg.giteeOwner
        let repo = cfg.giteeRepo
        let branch = cfg.giteeBranch
        let token = cfg.giteeToken
        guard !token.isEmpty else { throw SyncError.noToken }

        progress(0, 1)
        let commit = try await fetchCommit(owner: owner, repo: repo, branch: branch, token: token)
        let tree = try await fetchTree(owner: owner, repo: repo, sha: commit, token: token)
        let pages = tree.filter { $0.type == "blob" && $0.path.hasPrefix("wiki/") && $0.path.hasSuffix(".md") }
        guard !pages.isEmpty else { throw SyncError.badResponse }

        var downloaded: [String: (sha: String, text: String)] = [:]
        downloaded.reserveCapacity(pages.count)

        var cursor = 0
        // gitee 对 API 有频率限制，8 并发很容易触发 403；降到 3 并在批次间留间隔
        let parallel = 3
        while cursor < pages.count {
            let slice = Array(pages[cursor..<min(cursor + parallel, pages.count)])
            let batch = try await withThrowingTaskGroup(of: (String, String, String).self) { group -> [(String, String, String)] in
                for p in slice {
                    group.addTask { [weak self] in
                        guard let self else { return (p.path, "", "") }
                        return try await self.fetchContent(owner: owner, repo: repo, path: p.path, ref: branch, token: token)
                    }
                }
                var out: [(String, String, String)] = []
                for try await item in group { out.append(item) }
                return out
            }
            for (path, sha, text) in batch { downloaded[path] = (sha, text) }
            cursor += parallel
            progress(min(cursor, pages.count), pages.count)
            if cursor < pages.count {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        let oldManifest = storage.loadManifest()
        var newManifest: [String: String] = [:]
        newManifest.reserveCapacity(downloaded.count)
        var added = 0
        var updated = 0
        var bytes: Int64 = 0

        for (path, value) in downloaded {
            newManifest[path] = value.sha
            if oldManifest[path] != value.sha {
                bytes += (try? storage.write(value.text, to: path)) ?? 0
                if oldManifest[path] == nil { added += 1 } else { updated += 1 }
            }
        }

        var removed = 0
        for path in oldManifest.keys where newManifest[path] == nil {
            storage.remove(path)
            removed += 1
        }

        storage.saveManifest(newManifest)
        let state = SyncState(
            version: commit,
            syncedAt: Date().timeIntervalSince1970,
            pageCount: newManifest.count,
            totalBytes: bytes
        )
        storage.saveState(state)

        return SyncOutcome(
            version: commit,
            added: added,
            updated: updated,
            removed: removed,
            pageCount: newManifest.count,
            message: "同步完成：新增 \(added)，更新 \(updated)，删除 \(removed)"
        )
    }

    // MARK: - gitee API

    private func fetchCommit(owner: String, repo: String, branch: String, token: String) async throws -> String {
        var comps = URLComponents(string: "https://gitee.com/api/v5/repos/\(owner)/\(repo)/branches/\(encodePath(branch))")!
        comps.queryItems = [URLQueryItem(name: "access_token", value: token)]
        let json = try await getJSON(comps.url!)
        guard let commit = json["commit"] as? [String: Any],
              let sha = commit["sha"] as? String else { throw SyncError.badResponse }
        return sha
    }

    private func fetchTree(owner: String, repo: String, sha: String, token: String) async throws -> [TreeEntry] {
        var all: [TreeEntry] = []
        var seen = Set<String>()
        var page = 1

        while page <= 20 {
            var comps = URLComponents(string: "https://gitee.com/api/v5/repos/\(owner)/\(repo)/git/trees/\(sha)")!
            comps.queryItems = [
                URLQueryItem(name: "recursive", value: "1"),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "access_token", value: token),
            ]
            let json = try await getJSON(comps.url!)
            let items = (json["tree"] as? [[String: Any]]) ?? []
            if items.isEmpty { break }

            var fresh = 0
            for item in items {
                guard let path = item["path"] as? String, !seen.contains(path) else { continue }
                seen.insert(path)
                fresh += 1
                all.append(TreeEntry(
                    path: path,
                    type: item["type"] as? String ?? "",
                    sha: item["sha"] as? String ?? ""
                ))
            }
            // 服务端未分页时第二次请求会全重复，fresh==0 即可停止
            if fresh == 0 || items.count < 100 { break }
            page += 1
        }
        return all
    }

    private func fetchContent(owner: String, repo: String, path: String, ref: String, token: String) async throws -> (String, String, String) {
        var comps = URLComponents(string: "https://gitee.com/api/v5/repos/\(owner)/\(repo)/contents/\(encodePath(path))")!
        comps.queryItems = [
            URLQueryItem(name: "ref", value: ref),
            URLQueryItem(name: "access_token", value: token),
        ]
        let json = try await getJSON(comps.url!)
        guard let content = json["content"] as? String,
              let sha = json["sha"] as? String else { throw SyncError.badResponse }

        let cleaned = content
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let data = Data(base64Encoded: cleaned),
              let text = String(data: data, encoding: .utf8) else {
            throw SyncError.decodeFailed(path)
        }
        return (path, sha, text)
    }

    /// 带退避重试的请求入口：403/429 视为可能被限流，指数退避重试 4 次。
    private func getJSON(_ url: URL) async throws -> [String: Any] {
        var backoff: UInt64 = 3_000_000_000
        for attempt in 1...4 {
            do {
                return try await getJSONOnce(url)
            } catch let error as SyncError {
                switch error {
                case .forbidden, .rateLimited:
                    if attempt < 4 {
                        try? await Task.sleep(nanoseconds: backoff)
                        backoff *= 2
                        continue
                    }
                    throw error
                default:
                    throw error
                }
            }
        }
        throw SyncError.badResponse
    }

    private func getJSONOnce(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("LlmWiki-iPad/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.badResponse }

        switch http.statusCode {
        case 200...299:
            break
        case 401:
            throw SyncError.unauthorized
        case 403:
            let body = (String(data: data, encoding: .utf8) ?? "").lowercased()
            if body.contains("rate") || body.contains("limit") || body.contains("频繁") {
                throw SyncError.rateLimited
            }
            throw SyncError.forbidden
        case 429:
            throw SyncError.rateLimited
        default:
            throw SyncError.http(http.statusCode)
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SyncError.badResponse
        }
        return object
    }

    private func encodePath(_ path: String) -> String {
        path.split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }
}
