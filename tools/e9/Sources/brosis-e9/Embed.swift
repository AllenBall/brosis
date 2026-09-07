// brosis M0 · E9：嵌入运行时
//
// 用 mlx-swift-lm 的 MLXEmbedders 从本地目录加载（不走它自带的下载器，权重由我们自己的
// 下载器装好并校验过）。TokenizerLoader 适配器手写，等价于 MLXHuggingFace 的
// #huggingFaceTokenizerLoader() 宏展开，省掉 swift-syntax 宏插件依赖。

import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXNN
import Tokenizers

// MARK: - swift-transformers -> MLXLMCommon 适配

struct TransformersTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

// MARK: - 嵌入器

struct EmbedStats: Sendable {
    var totalTokens: Int = 0
    var maxSeqLen: Int = 0
    var batches: Int = 0
}

final class Embedder: @unchecked Sendable {
    let container: EmbedderModelContainer
    let modelDirectory: URL
    /// 加载耗时（进入 load 到 container 返回）
    let loadSeconds: Double
    let poolingStrategy: String
    let padTokenId: Int
    let dimension: Int

    private init(
        container: EmbedderModelContainer, modelDirectory: URL, loadSeconds: Double,
        poolingStrategy: String, padTokenId: Int, dimension: Int
    ) {
        self.container = container
        self.modelDirectory = modelDirectory
        self.loadSeconds = loadSeconds
        self.poolingStrategy = poolingStrategy
        self.padTokenId = padTokenId
        self.dimension = dimension
    }

    static func load(directory: URL) async throws -> Embedder {
        let t0 = Date()
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: directory, using: TransformersTokenizerLoader())
        let dt = Date().timeIntervalSince(t0)
        let strategy = String(describing: await container.poolingStrategy)
        // pad 用 <|endoftext|>；mask 由真实长度构造，不靠比对 pad id，所以 pad 取什么都不影响结果
        let tok = await container.tokenizer
        let pad = tok.convertTokenToId("<|endoftext|>") ?? tok.eosTokenId ?? 0
        // 维度从 config.json 的 hidden_size 读
        var dim = 0
        if let data = try? Data(contentsOf: directory.appending(path: "config.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hs = obj["hidden_size"] as? Int {
            dim = hs
        }
        return Embedder(
            container: container, modelDirectory: directory, loadSeconds: dt,
            poolingStrategy: strategy, padTokenId: pad, dimension: dim)
    }

    func tokenCount(_ text: String) async -> Int {
        await container.perform { ctx in ctx.tokenizer.encode(text: text, addSpecialTokens: true).count }
    }

    /// 一批文本 -> 归一化后的向量。右侧 padding，mask 按真实长度构造，last-token pooling。
    func embedBatch(_ texts: [String], maxTokens: Int = 1024) async -> ([[Float]], EmbedStats) {
        let pad = padTokenId
        return await container.perform { ctx -> ([[Float]], EmbedStats) in
            var ids = texts.map { Array(ctx.tokenizer.encode(text: $0, addSpecialTokens: true).prefix(maxTokens)) }
            let maxLen = max(ids.map(\.count).max() ?? 1, 1)
            var stats = EmbedStats()
            stats.totalTokens = ids.reduce(0) { $0 + $1.count }
            stats.maxSeqLen = maxLen
            stats.batches = 1

            var maskFlat = [Int32](repeating: 0, count: ids.count * maxLen)
            for (i, seq) in ids.enumerated() {
                for j in 0..<maxLen where j < seq.count { maskFlat[i * maxLen + j] = 1 }
            }
            for i in ids.indices {
                if ids[i].count < maxLen {
                    ids[i].append(contentsOf: Array(repeating: pad, count: maxLen - ids[i].count))
                }
            }
            let padded = stacked(ids.map { MLXArray($0.map { Int32($0) }) })
            let mask = MLXArray(maskFlat, [ids.count, maxLen])
            let tokenTypes = MLXArray.zeros(like: padded)
            let out = ctx.model(
                padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask)
            // Qwen3 嵌入不做 layerNorm，只 L2 归一化（1_Pooling/config.json 不存在时
            // MLXEmbedders 回落到模型自带的 .last 策略，dimension = nil）
            let result = ctx.pooling(out, mask: mask, normalize: true, applyLayerNorm: false)
            result.eval()
            let vectors = result.map { $0.asArray(Float.self) }
            return (vectors, stats)
        }
    }

    /// 分批跑一组文本。
    func embedAll(_ texts: [String], batchSize: Int = 16, maxTokens: Int = 1024) async
        -> ([[Float]], EmbedStats)
    {
        var all: [[Float]] = []
        var stats = EmbedStats()
        var i = 0
        while i < texts.count {
            let slice = Array(texts[i..<min(i + batchSize, texts.count)])
            let (v, s) = await embedBatch(slice, maxTokens: maxTokens)
            all.append(contentsOf: v)
            stats.totalTokens += s.totalTokens
            stats.maxSeqLen = max(stats.maxSeqLen, s.maxSeqLen)
            stats.batches += 1
            i += batchSize
        }
        return (all, stats)
    }
}

// MARK: - 向量工具

enum Vec {
    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var s = 0.0
        for i in 0..<Swift.min(a.count, b.count) { s += Double(a[i]) * Double(b[i]) }
        return s
    }

    static func norm(_ a: [Float]) -> Double { dot(a, a).squareRoot() }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let na = norm(a), nb = norm(b)
        guard na > 0, nb > 0 else { return 0 }
        return dot(a, b) / (na * nb)
    }

    /// MRL 截断：取前 d 维再重新 L2 归一化。
    static func truncateNormalize(_ v: [Float], _ d: Int) -> [Float] {
        let head = Array(v.prefix(d))
        let n = norm(head)
        guard n > 0 else { return head }
        return head.map { Float(Double($0) / n) }
    }

    /// 返回 top-k 的下标（按余弦降序）。
    static func topK(query: [Float], docs: [[Float]], k: Int) -> [Int] {
        let scored = docs.enumerated().map { ($0.offset, cosine(query, $0.element)) }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }.prefix(k).map(\.0)
    }
}
