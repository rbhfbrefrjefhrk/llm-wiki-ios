import Foundation

private extension Data {
    mutating func appendInt32(_ v: Int32) {
        withUnsafeBytes(of: v) { append(contentsOf: $0) }
    }

    mutating func appendFloat(_ v: Float) {
        withUnsafeBytes(of: v) { append(contentsOf: $0) }
    }

    mutating func appendUTF8(_ s: String) {
        let d = Data(s.utf8)
        appendInt32(Int32(d.count))
        append(d)
    }

    func int32(at offset: inout Int) -> Int32 {
        let v = self[offset..<(offset + 4)].withUnsafeBytes { $0.load(as: Int32.self) }
        offset += 4
        return v
    }

    func float(at offset: inout Int) -> Float {
        let v = self[offset..<(offset + 4)].withUnsafeBytes { $0.load(as: Float.self) }
        offset += 4
        return v
    }

    func string(at offset: inout Int) -> String {
        let len = Int(int32(at: &offset))
        let s = String(data: self[offset..<(offset + len)], encoding: .utf8) ?? ""
        offset += len
        return s
    }
}

/// 端侧语义索引：页面切块 → 逐块嵌入（512 维）→ 落盘；检索用点积（向量已归一化，等价余弦）。
actor LocalSearchIndex {
    private struct Entry {
        let path: String
        let text: String
        let vec: [Float]
    }

    private var entries: [Entry] = []
    private var indexedVersion = ""

    private let fm = FileManager.default
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var indexDir: URL { docs.appendingPathComponent("index", isDirectory: true) }
    private var binURL: URL { indexDir.appendingPathComponent("vectors.bin") }
    private var stampURL: URL { indexDir.appendingPathComponent("stamp.txt") }

    func isReady(_ version: String) -> Bool {
        !version.isEmpty && version == indexedVersion && !entries.isEmpty
    }

    /// 索引与当前知识库版本一致时直接复用；否则重建。
    func ensureIndex(
        version: String,
        storage: WikiStorage,
        embedder: OnnxEmbedder,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) throws -> Int {
        if isReady(version) { return entries.count }
        if loadIfStamped(version) { return entries.count }

        let paths = storage.listMarkdown()
        var built: [Entry] = []
        built.reserveCapacity(paths.count * 2)

        for (i, path) in paths.enumerated() {
            if let content = storage.read(path) {
                for chunk in Self.chunk(content) {
                    if let vec = try? embedder.embedOne(chunk) {
                        built.append(Entry(path: path, text: chunk, vec: vec))
                    }
                }
            }
            progress(i + 1, paths.count)
        }

        entries = built
        indexedVersion = version
        save(version)
        return built.count
    }

    func search(_ query: String, topK: Int, embedder: OnnxEmbedder) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entries.isEmpty, !trimmed.isEmpty else { return [] }
        guard let q = try embedder.embedOne(trimmed) else { return [] }

        var scored: [(Entry, Float)] = entries.map { ($0, Self.dot($0.vec, q)) }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(topK).map {
            SearchHit(path: $0.0.path, content: $0.0.text, score: $0.1)
        }
    }

    // MARK: - 切块

    /// 按行聚合，单块不超过 400 字；超长行硬切。
    static func chunk(_ content: String, limit: Int = 400) -> [String] {
        var chunks: [String] = []
        var buffer = ""

        func flush() {
            if !buffer.isEmpty {
                chunks.append(buffer)
                buffer = ""
            }
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if !buffer.isEmpty, buffer.count + line.count + 1 > limit { flush() }

            if line.count > limit {
                var rest = line
                while rest.count > limit {
                    let cut = rest.index(rest.startIndex, offsetBy: limit)
                    chunks.append(String(rest[..<cut]))
                    rest = String(rest[cut...])
                }
                if !rest.isEmpty {
                    buffer = buffer.isEmpty ? rest : buffer + "\n" + rest
                }
            } else {
                buffer = buffer.isEmpty ? line : buffer + "\n" + line
            }
        }
        flush()
        return chunks
    }

    // MARK: - 持久化

    private func save(_ version: String) {
        do {
            try fm.createDirectory(at: indexDir, withIntermediateDirectories: true)
            var data = Data()
            data.appendInt32(Int32(entries.count))
            data.appendInt32(Int32(OnnxEmbedder.dim))
            for e in entries {
                data.appendUTF8(e.path)
                data.appendUTF8(e.text)
                for f in e.vec { data.appendFloat(f) }
            }
            try data.write(to: binURL, options: .atomic)
            try Data(version.utf8).write(to: stampURL, options: .atomic)
        } catch {
            // 落盘失败不影响本次运行，下次会重建
        }
    }

    private func loadIfStamped(_ version: String) -> Bool {
        guard version.isEmpty == false,
              let stampData = try? Data(contentsOf: stampURL),
              let stamp = String(data: stampData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              stamp == version
        else { return false }
        return load()
    }

    private func load() -> Bool {
        guard let data = try? Data(contentsOf: binURL), data.count > 8 else { return false }
        var offset = 0
        let count = Int(data.int32(at: &offset))
        let dim = Int(data.int32(at: &offset))
        guard dim == OnnxEmbedder.dim, count > 0 else { return false }

        var loaded: [Entry] = []
        loaded.reserveCapacity(count)
        for _ in 0..<count {
            let path = data.string(at: &offset)
            let text = data.string(at: &offset)
            var vec = [Float]()
            vec.reserveCapacity(dim)
            for _ in 0..<dim { vec.append(data.float(at: &offset)) }
            loaded.append(Entry(path: path, text: text, vec: vec))
        }
        entries = loaded
        return true
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var sum: Float = 0
        var i = 0
        while i < n {
            sum += a[i] * b[i]
            i += 1
        }
        return sum
    }
}
