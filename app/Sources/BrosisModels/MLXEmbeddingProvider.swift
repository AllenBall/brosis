import BrosisCore
import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXNN
import Tokenizers

// =============================================================================
// 本地嵌入提供方（计划 3.10「提供方抽象：本地实现走 mlx-swift」，D27 内存策略）
//
// 嵌入器本体逐字搬自 tools/e9/Sources/brosis-e9/Embed.swift（TokenizerLoader 适配器、
// 右侧 padding + 真实长度 mask + last-token pooling + L2 归一化），改动只有：
//   1. 实现 `BrosisCore.EmbeddingProvider`（同步接口，桥到 mlx 的 async）；
//   2. 加载前按 D27 设 `MLX.Memory.cacheLimit`，任务结束 `MLX.Memory.clearCache()`；
//   3. 输出按 MRL 截到 `SchemaV4.dimension`（512）再重新归一化。
//
// **本地实现，不接线上**（本轮用户指示）：这里没有任何网络调用。
// =============================================================================

// MARK: - swift-transformers -> MLXLMCommon 适配（等价于 #huggingFaceTokenizerLoader() 宏展开）

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

// MARK: - D27 内存策略

/// MLX 缓冲池策略（D27）。
///
/// MLX 默认不限缓冲池，而且进程结束前不还给系统：E9 实测同一份批量嵌入，
/// 峰值 `phys_footprint` 不限时 6.21 GiB、限 256 MiB 时 1.95 GiB，吞吐只差 2.8%，
/// 四档的语义 / MRL / 确定性结果**逐位相同**。Air 上复测 1.61 GiB / 5.51 GiB、全程零 swap。
/// 所以：**加载模型前设 256 MiB，任务结束 `clearCache()`**。
public enum MLXMemoryPolicy {
    /// D27 定的默认值。
    public static let defaultCacheLimitMiB = 256

    nonisolated(unsafe) public private(set) static var appliedCacheLimitBytes: Int?

    /// 必须在**加载模型之前**调用。`mib = 0` 表示彻底关掉缓冲池。
    public static func applyCacheLimit(mib: Int = defaultCacheLimitMiB) {
        let bytes = mib * (1 << 20)
        MLX.Memory.cacheLimit = bytes
        appliedCacheLimitBytes = bytes
    }

    public struct Release: Sendable, Codable {
        public var gpuCacheBeforeMiB: Double
        public var gpuCacheAfterMiB: Double
        public var footprintBeforeMiB: Double
        public var footprintAfterMiB: Double
        public var peakFootprintMiB: Double
        public var gpuPeakMiB: Double
    }

    /// 立刻把缓冲池还给系统。任务结束必须调（3.11「任务结束清空缓冲池」）。
    @discardableResult
    public static func releaseCache() -> Release {
        let beforeCache = MLX.Memory.cacheMemory
        let beforeFootprint = ModelProc.footprintBytes()
        MLX.Memory.clearCache()
        // footprint 的回落不是同步的，给内核一点时间把页还回去。
        usleep(200_000)
        return Release(
            gpuCacheBeforeMiB: Double(beforeCache) / ModelBytes.mib,
            gpuCacheAfterMiB: Double(MLX.Memory.cacheMemory) / ModelBytes.mib,
            footprintBeforeMiB: Double(beforeFootprint) / ModelBytes.mib,
            footprintAfterMiB: Double(ModelProc.footprintBytes()) / ModelBytes.mib,
            peakFootprintMiB: Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib,
            gpuPeakMiB: Double(MLX.Memory.peakMemory) / ModelBytes.mib)
    }

    /// 当前 GPU 内存读数（结果文件与自检里要报的那几项）。
    public static var snapshot: [String: Double] {
        [
            "gpu_active_mib": Double(MLX.Memory.activeMemory) / ModelBytes.mib,
            "gpu_peak_mib": Double(MLX.Memory.peakMemory) / ModelBytes.mib,
            "gpu_cache_mib": Double(MLX.Memory.cacheMemory) / ModelBytes.mib,
            "gpu_cache_limit_mib": Double(MLX.Memory.cacheLimit) / ModelBytes.mib,
            "gpu_memory_limit_mib": Double(MLX.Memory.memoryLimit) / ModelBytes.mib,
            "process_footprint_mib": Double(ModelProc.footprintBytes()) / ModelBytes.mib,
            "process_peak_footprint_mib": Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib,
        ]
    }
}

// MARK: - 嵌入提供方

/// mlx-swift 的本地嵌入实现。**加载即占内存**，用完请 `unload()`。
public final class MLXEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {

    public let descriptor: EmbeddingModelDescriptor
    public let modelDirectory: URL
    /// 加载耗时（进入 load 到 container 返回）。
    public let loadSeconds: Double
    public let poolingStrategy: String
    /// 模型原生维度（`config.json` 的 `hidden_size`）。
    public let nativeDimension: Int
    /// 每批的最大 token 数（超出截断）。
    public let maxTokensPerText: Int

    private let container: EmbedderModelContainer
    private let padTokenID: Int

    /// 累计统计（结果文件要报吞吐）。
    public private(set) var totalTexts = 0
    public private(set) var totalTokens = 0
    public private(set) var totalBatches = 0
    public private(set) var totalSeconds = 0.0

    private init(container: EmbedderModelContainer, descriptor: EmbeddingModelDescriptor,
                 modelDirectory: URL, loadSeconds: Double, poolingStrategy: String,
                 padTokenID: Int, nativeDimension: Int, maxTokensPerText: Int) {
        self.container = container
        self.descriptor = descriptor
        self.modelDirectory = modelDirectory
        self.loadSeconds = loadSeconds
        self.poolingStrategy = poolingStrategy
        self.padTokenID = padTokenID
        self.nativeDimension = nativeDimension
        self.maxTokensPerText = maxTokensPerText
    }

    /// 从已装好的模型目录加载。
    ///
    /// - Parameters:
    ///   - cacheLimitMiB: **加载之前**设的 MLX 缓冲池上限（D27，默认 256 MiB）。
    ///   - dimension: 写进 `vec_chunks` 的维度（默认 `SchemaV4.dimension` = 512，MRL 截断）。
    public static func load(directory: URL,
                            modelID: String,
                            dimension: Int = SchemaV4.dimension,
                            cacheLimitMiB: Int = MLXMemoryPolicy.defaultCacheLimitMiB,
                            maxTokensPerText: Int = 1024) throws -> MLXEmbeddingProvider {
        guard FileManager.default.fileExists(atPath: directory.appending(path: "config.json").path) else {
            throw ModelsError("模型目录里没有 config.json：\(directory.lastPathComponent)")
        }
        // D27：一定要在加载之前设，否则第一批权重就已经把缓冲池撑起来了。
        MLXMemoryPolicy.applyCacheLimit(mib: cacheLimitMiB)

        let t0 = Date()
        let loaded = try runBlocking { () async throws -> (EmbedderModelContainer, String, Int) in
            let container = try await EmbedderModelFactory.shared.loadContainer(
                from: directory, using: TransformersTokenizerLoader())
            let strategy = String(describing: await container.poolingStrategy)
            let tokenizer = await container.tokenizer
            // pad 用 <|endoftext|>；mask 由真实长度构造，不靠比对 pad id，所以取什么都不影响结果。
            let pad = tokenizer.convertTokenToId("<|endoftext|>") ?? tokenizer.eosTokenId ?? 0
            return (container, strategy, pad)
        }
        let loadSeconds = Date().timeIntervalSince(t0)

        var native = 0
        if let data = try? Data(contentsOf: directory.appending(path: "config.json")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hidden = obj["hidden_size"] as? Int {
            native = hidden
        }
        guard native >= dimension else {
            throw ModelsError("模型原生维度 \(native) 小于要求的 \(dimension)，无法做 MRL 截断")
        }
        return MLXEmbeddingProvider(
            container: loaded.0,
            descriptor: EmbeddingModelDescriptor(id: modelID, dimension: dimension,
                                                 nativeDimension: native),
            modelDirectory: directory, loadSeconds: loadSeconds, poolingStrategy: loaded.1,
            padTokenID: loaded.2, nativeDimension: native, maxTokensPerText: maxTokensPerText)
    }

    /// `BrosisCore.EmbeddingProvider`：一批文本 → 已按 MRL 截到 `descriptor.dimension`
    /// 并重新 L2 归一化的向量。
    public func embed(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let t0 = Date()
        let (vectors, tokens) = try runBlocking { () async -> ([[Float]], Int) in
            await self.embedBatch(texts)
        }
        totalTexts += texts.count
        totalTokens += tokens
        totalBatches += 1
        totalSeconds += Date().timeIntervalSince(t0)
        return vectors.map { EmbeddingVector.truncateNormalize($0, descriptor.dimension) }
    }

    /// 一批文本 → 归一化后的原生维度向量。右侧 padding，mask 按真实长度构造，last-token pooling。
    private func embedBatch(_ texts: [String]) async -> ([[Float]], Int) {
        let pad = padTokenID
        let limit = maxTokensPerText
        return await container.perform { ctx -> ([[Float]], Int) in
            var ids = texts.map {
                Array(ctx.tokenizer.encode(text: $0, addSpecialTokens: true).prefix(limit))
            }
            let maxLen = max(ids.map(\.count).max() ?? 1, 1)
            let tokenCount = ids.reduce(0) { $0 + $1.count }

            var maskFlat = [Int32](repeating: 0, count: ids.count * maxLen)
            for (i, seq) in ids.enumerated() {
                for j in 0..<maxLen where j < seq.count { maskFlat[i * maxLen + j] = 1 }
            }
            for i in ids.indices where ids[i].count < maxLen {
                ids[i].append(contentsOf: Array(repeating: pad, count: maxLen - ids[i].count))
            }
            let padded = stacked(ids.map { MLXArray($0.map { Int32($0) }) })
            let mask = MLXArray(maskFlat, [ids.count, maxLen])
            let tokenTypes = MLXArray.zeros(like: padded)
            let out = ctx.model(padded, positionIds: nil, tokenTypeIds: tokenTypes,
                                attentionMask: mask)
            // Qwen3 嵌入不做 layerNorm，只 L2 归一化。
            let result = ctx.pooling(out, mask: mask, normalize: true, applyLayerNorm: false)
            result.eval()
            return (result.map { $0.asArray(Float.self) }, tokenCount)
        }
    }

    /// 一条文本的 token 数（预算折算用）。
    public func tokenCount(_ text: String) throws -> Int {
        try runBlocking { () async -> Int in
            await self.container.perform { ctx in
                ctx.tokenizer.encode(text: text, addSpecialTokens: true).count
            }
        }
    }

    /// 吞吐（条/s 与 token/s），只算 provider 调用的墙钟时间。
    public var throughput: (textsPerSecond: Double, tokensPerSecond: Double) {
        guard totalSeconds > 0 else { return (0, 0) }
        return (Double(totalTexts) / totalSeconds, Double(totalTokens) / totalSeconds)
    }

    /// 任务结束：把缓冲池还给系统（3.11 / D27）。
    @discardableResult
    public func unload() -> MLXMemoryPolicy.Release { MLXMemoryPolicy.releaseCache() }
}

// MARK: - async -> sync 桥

/// 把一个 async 调用在当前线程上跑完再返回。
///
/// 嵌入任务跑在后台线程（app 里是夜间调度器的队列，命令行里是主线程），
/// 不在主线程的 run loop 上，所以这样阻塞是安全的；
/// 换成让整条存储路径变 async 的代价要大得多（`Store` 是一把锁的同步类）。
func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Result<T, Error>!
    Task.detached(priority: .userInitiated) {
        do { result = .success(try await body()) } catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
