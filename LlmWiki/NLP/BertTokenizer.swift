import Foundation

/// 纯 Swift 版 Bert WordPiece 分词，行为对齐 tokenizers 的 BertNormalizer + BertPreTokenizer。
/// 词表 `vocab.txt` 的行号即 token id。
final class BertTokenizer {
    static let clsId: Int32 = 101
    static let sepId: Int32 = 102
    static let unkId: Int32 = 100
    private static let maxCharsPerWord = 100

    private let vocab: [String: Int32]

    init(vocabURL: URL) throws {
        let text = try String(contentsOf: vocabURL, encoding: .utf8)
        var map: [String: Int32] = [:]
        map.reserveCapacity(21128)
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let token = line.replacingOccurrences(of: "\r", with: "")
            if token.isEmpty { continue }
            map[token] = Int32(i)
        }
        vocab = map
    }

    func encode(_ text: String, maxLen: Int = 512) -> [Int32] {
        var ids: [Int32] = [BertTokenizer.clsId]
        for token in basicTokenize(text) {
            for piece in wordPiece(token) {
                if ids.count >= maxLen - 1 { break }
                ids.append(vocab[piece] ?? BertTokenizer.unkId)
            }
            if ids.count >= maxLen - 1 { break }
        }
        ids.append(BertTokenizer.sepId)
        return ids
    }

    // MARK: - normalizer + pre-tokenizer

    private func basicTokenize(_ text: String) -> [String] {
        // 1) clean_text：丢弃控制字符与 NUL/替换符，空白归一为单空格
        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0 || v == 0xFFFD { continue }
            if (v >= 0x01 && v <= 0x08) || v == 0x0B || v == 0x0C { continue }
            if v >= 0x0E && v <= 0x1F { continue }
            if v >= 0x7F && v <= 0x9F { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                cleaned.append(" ")
                continue
            }
            cleaned.append(Character(scalar))
        }

        // 2) handle_chinese_chars：汉字两侧补空格，保证单字成 token
        var spaced = ""
        spaced.reserveCapacity(cleaned.count * 2)
        for ch in cleaned {
            if let s = ch.unicodeScalars.first, isChinese(s) {
                spaced.append(" ")
                spaced.append(ch)
                spaced.append(" ")
            } else {
                spaced.append(ch)
            }
        }

        // 3) BertPreTokenizer：按空白切分，再把标点/符号拆成独立 token
        var out: [String] = []
        for piece in spaced.split(separator: " ", omittingEmptySubsequences: true) {
            out.append(contentsOf: splitPunctuation(String(piece)))
        }
        return out
    }

    private func splitPunctuation(_ s: String) -> [String] {
        var out: [String] = []
        var buf = ""
        buf.reserveCapacity(s.count)
        for ch in s {
            if let scalar = ch.unicodeScalars.first,
               CharacterSet.punctuationCharacters.contains(scalar) || isSymbol(scalar) {
                if !buf.isEmpty {
                    out.append(buf)
                    buf = ""
                }
                out.append(String(ch))
            } else {
                buf.append(ch)
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    private func isChinese(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private func isSymbol(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.symbols.contains(s) || CharacterSet.punctuationCharacters.contains(s)
    }

    // MARK: - WordPiece

    private func wordPiece(_ word: String) -> [String] {
        guard !word.isEmpty else { return [] }
        guard word.count <= BertTokenizer.maxCharsPerWord else { return ["[UNK]"] }

        let chars = Array(word)
        var pieces: [String] = []
        var start = 0
        while start < chars.count {
            var end = chars.count
            var found: String?
            while start < end {
                var candidate = String(chars[start..<end])
                if start > 0 { candidate = "##" + candidate }
                if vocab[candidate] != nil {
                    found = candidate
                    break
                }
                end -= 1
            }
            guard let piece = found else { return ["[UNK]"] }
            pieces.append(piece)
            start = end
        }
        return pieces
    }
}
