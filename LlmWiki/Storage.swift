import Foundation

/// 知识库文件存储：`Documents/wiki/...`，附 manifest（path → git blob sha）与同步状态。
final class WikiStorage {
    let docs: URL
    private let fm = FileManager.default

    init() {
        docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
    }

    func url(for path: String) -> URL {
        docs.appendingPathComponent(path)
    }

    @discardableResult
    func write(_ content: String, to path: String) throws -> Int64 {
        let u = url(for: path)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(content.utf8)
        try data.write(to: u, options: .atomic)
        return Int64(data.count)
    }

    func read(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: url(for: path)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(_ path: String) {
        try? fm.removeItem(at: url(for: path))
    }

    /// 所有 md 页面（返回形如 `wiki/entities/方阵.md` 的相对路径）。
    func listMarkdown() -> [String] {
        let root = docs.appendingPathComponent("wiki")
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [String] = []
        for case let u as URL in en where u.pathExtension == "md" {
            out.append(u.path.replacingOccurrences(of: docs.path + "/", with: ""))
        }
        return out
    }

    // MARK: - manifest

    private var manifestURL: URL { docs.appendingPathComponent("manifest.json") }
    private var stateURL: URL { docs.appendingPathComponent("sync_state.json") }

    func loadManifest() -> [String: String] {
        guard let data = try? Data(contentsOf: manifestURL),
              let m = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return m
    }

    func saveManifest(_ m: [String: String]) {
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    func loadState() -> SyncState? {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(SyncState.self, from: data) else { return nil }
        return s
    }

    func saveState(_ s: SyncState) {
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    // MARK: - 会话

    private var chatURL: URL { docs.appendingPathComponent("chat_history.json") }

    func loadChat() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: chatURL),
              let m = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return [] }
        return m
    }

    func saveChat(_ m: [ChatMessage]) {
        if let data = try? JSONEncoder().encode(m) {
            try? data.write(to: chatURL, options: .atomic)
        }
    }
}
