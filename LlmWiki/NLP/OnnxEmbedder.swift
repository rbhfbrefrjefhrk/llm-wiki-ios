import Foundation
import onnxruntime_objc

enum EmbedderError: LocalizedError {
    case resourceMissing(String)
    case outputMissing
    case badShape

    var errorDescription: String? {
        switch self {
        case .resourceMissing(let n): return "缺少模型资源：\(n)"
        case .outputMissing: return "模型未返回 last_hidden_state"
        case .badShape: return "输出维度异常"
        }
    }
}

/// 端侧 bge-small-zh-v1.5 int8 推理：batch 内动态 padding，取 CLS 向量并做 L2 归一化。
final class OnnxEmbedder {
    static let dim = 512

    private let env: ORTEnv
    private let session: ORTSession
    private let tokenizer: BertTokenizer
    private let batchSize = 8

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "bge-small-zh-int8", withExtension: "onnx") else {
            throw EmbedderError.resourceMissing("bge-small-zh-int8.onnx")
        }
        guard let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "txt") else {
            throw EmbedderError.resourceMissing("vocab.txt")
        }
        env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(4)
        session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        tokenizer = try BertTokenizer(vocabURL: vocabURL)
    }

    func embed(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)

        var cursor = 0
        while cursor < texts.count {
            let upper = min(cursor + batchSize, texts.count)
            let batch = Array(texts[cursor..<upper])
            result.append(contentsOf: try embedBatch(batch))
            cursor = upper
        }
        return result
    }

    func embedOne(_ text: String) throws -> [Float]? {
        try embed([text]).first
    }

    private func embedBatch(_ batch: [String]) throws -> [[Float]] {
        let encoded = batch.map { tokenizer.encode($0) }
        let seqLen = max(encoded.map { $0.count }.max() ?? 1, 1)
        let b = encoded.count

        var ids = [Int64]()
        var masks = [Int64]()
        var types = [Int64]()
        ids.reserveCapacity(b * seqLen)

        for row in encoded {
            for j in 0..<seqLen {
                if j < row.count {
                    ids.append(Int64(row[j]))
                    masks.append(1)
                } else {
                    ids.append(0)
                    masks.append(0)
                }
                types.append(0)
            }
        }

        let shape: [NSNumber] = [NSNumber(value: b), NSNumber(value: seqLen)]
        let idsValue = try ORTValue(tensorData: Self.tensorData(ids), elementType: .int64, shape: shape)
        let maskValue = try ORTValue(tensorData: Self.tensorData(masks), elementType: .int64, shape: shape)
        let typeValue = try ORTValue(tensorData: Self.tensorData(types), elementType: .int64, shape: shape)

        let outputs = try session.run(
            withInputs: [
                "input_ids": idsValue,
                "attention_mask": maskValue,
                "token_type_ids": typeValue,
            ],
            outputNames: ["last_hidden_state"],
            runOptions: nil
        )
        guard let out = outputs["last_hidden_state"] else { throw EmbedderError.outputMissing }

        let raw = try out.tensorData()
        let data = raw as Data
        let floats: [Float] = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard floats.count >= b * seqLen * Self.dim else { throw EmbedderError.badShape }

        var vectors: [[Float]] = []
        vectors.reserveCapacity(b)
        for j in 0..<b {
            let base = j * seqLen * Self.dim
            var vec = Array(floats[base..<(base + Self.dim)])
            Self.normalize(&vec)
            vectors.append(vec)
        }
        return vectors
    }

    private static func tensorData(_ values: [Int64]) -> NSMutableData {
        values.withUnsafeBufferPointer { buf in
            let data = Data(bytes: buf.baseAddress!, count: buf.count * MemoryLayout<Int64>.size)
            return NSMutableData(data: data)
        }
    }

    private static func normalize(_ v: inout [Float]) {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sqrt(sum) + 1e-9
        for i in v.indices { v[i] /= norm }
    }
}
