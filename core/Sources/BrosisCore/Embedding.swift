import Foundation

// =============================================================================
// 嵌入提供方抽象（计划 3.10「提供方抽象的接口只有两类调用：embed(texts) 和 generate(...)」）
//
// **core 不加载任何模型**。它只定义接口、管分块与向量索引；真正的 mlx-swift 实现在
// app 侧的 `BrosisModels` 目标里（`MLXEmbeddingProvider`），由 app / brosis-embed 注入。
// 这样 core 的 132 个用例、brosis-mcp 与 brosis-store 都不必链接 mlx，
// `swift test --package-path core` 也不会去解析、编译 mlx-swift（那是几分钟与数 GiB 的事）。
//
// 按用户指示（本轮）：**只做本地实现，线上适配器不写**。
// =============================================================================

/// 嵌入模型的自述。`id` 与模型清单（`catalog.json`）里的 id 一致。
public struct EmbeddingModelDescriptor: Sendable, Codable, Equatable {
    /// 清单 id，例如 `Qwen3-Embedding-0.6B-8bit`。
    public var id: String
    /// 写进 `vec_chunks` 的维度。必须等于 `SchemaV4.dimension`（512）。
    public var dimension: Int
    /// 模型原生维度（Qwen3-Embedding-0.6B 是 1024）。只作记录。
    public var nativeDimension: Int

    public init(id: String, dimension: Int, nativeDimension: Int) {
        self.id = id
        self.dimension = dimension
        self.nativeDimension = nativeDimension
    }
}

/// 本地嵌入提供方。**同步接口**：嵌入任务跑在后台线程，不在主线程上，
/// 所以让实现方自己把 async 的 mlx 调用桥成同步比让整条存储路径变 async 便宜得多。
public protocol EmbeddingProvider: AnyObject, Sendable {
    var descriptor: EmbeddingModelDescriptor { get }
    /// 一批文本 → 已 L2 归一化、长度为 `descriptor.dimension` 的向量。
    /// 返回条数必须与入参一致，否则 `Store.runEmbeddingJob` 会当作失败。
    func embed(_ texts: [String]) throws -> [[Float]]
}

// =============================================================================
// MARK: - 向量工具
// =============================================================================

public enum EmbeddingVector {

    /// MRL 截断：取前 `d` 维再重新 L2 归一化（E9 / 报告 11.2 第 7 条）。
    /// `v.count <= d` 时原样返回（只做归一化）。
    public static func truncateNormalize(_ v: [Float], _ d: Int) -> [Float] {
        let head = v.count > d ? Array(v.prefix(d)) : v
        var sum = 0.0
        for x in head { sum += Double(x) * Double(x) }
        let n = sum.squareRoot()
        guard n > 0 else { return head }
        return head.map { Float(Double($0) / n) }
    }

    /// 量化成 int8：**每条向量各自**用 `s = 127 / max|v_i|` 缩放到满量程再取整。
    ///
    /// 为什么可以按条缩放：`vec0` 的 `distance_cosine_int8` 算的是 `1 - dot/(|a||b|)`，
    /// 对整体缩放不敏感（见 `SchemaV4.elementType` 的注释）。
    /// 为什么必须缩放：L2 归一化的 512 维向量分量典型只有 ±0.04，
    /// 直接乘 127 只剩十来个量化档，检索会明显变差。
    public static func quantizeInt8(_ v: [Float]) -> Data {
        var maxAbs: Float = 0
        for x in v { maxAbs = Swift.max(maxAbs, abs(x)) }
        var out = Data(count: v.count)
        guard maxAbs > 0 else { return out }
        let scale = 127.0 / Double(maxAbs)
        out.withUnsafeMutableBytes { raw in
            let buf = raw.bindMemory(to: Int8.self)
            for (i, x) in v.enumerated() {
                let q = (Double(x) * scale).rounded()
                buf[i] = Int8(Swift.max(-127, Swift.min(127, q)))
            }
        }
        return out
    }

    /// 反量化（只给测试与 `vec-search --explain` 用；产品路径不需要）。
    public static func dequantizeInt8(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int8.self).map { Float($0) }
        }
    }

    /// 余弦相似度（[-1, 1]）。两条都归一化时等于点积。
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<Swift.min(a.count, b.count) {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}

// =============================================================================
// MARK: - 任务门控与报告
// =============================================================================

/// 嵌入任务每批之前问一次的门控。返回 `nil` 表示继续；返回一个字符串表示**停下**，
/// 字符串就是停止原因（写进 `jobs.output_ref` 与报告）。
///
/// app 侧的夜间调度器把「接电 / 空闲 ≥ 5 分钟 / `thermalState == nominal` / 未锁屏 /
/// 日均 GPU 预算没超」这几条塞进这个闭包（`EmbeddingScheduler`）；
/// 命令行侧塞的是「Ctrl-C 了没 / 批数到没到 / 秒数到没到」。
public typealias EmbeddingGate = @Sendable () -> String?

/// 嵌入任务的一次运行参数。
public struct EmbeddingJobOptions: Sendable {
    /// 每批多少块。E9 / D27 的实测批大小是 16（Air 上批 16 峰值 footprint 1.61 GiB）。
    public var batchSize: Int = 16
    /// 本次最多处理多少块（nil = 不限）。
    public var maxChunks: Int?
    /// 本次最多跑多少秒（nil = 不限）。日均 GPU 预算折算成它。
    public var maxSeconds: Double?
    /// 分块参数。
    public var chunkConfig = ChunkConfig()
    /// 每轮先补多少个文本版本的分块（0 = 不补，只嵌入已有的块）。
    public var planBatch: Int = 2_000

    public init(batchSize: Int = 16, maxChunks: Int? = nil, maxSeconds: Double? = nil) {
        self.batchSize = batchSize
        self.maxChunks = maxChunks
        self.maxSeconds = maxSeconds
    }
}

/// 分块（不含嵌入）的结果。
public struct ChunkPlanReport: Sendable, Codable {
    public var textVersionsScanned: Int
    public var chunksInserted: Int
    public var chunksSkippedEmpty: Int
    public var watermark: Int64
    public var complete: Bool
    public var elapsedMS: Double
}

/// 一次嵌入任务运行的结果。
public struct EmbeddingJobReport: Sendable, Codable {
    public var jobID: Int64
    /// done / cancelled / failed
    public var state: String
    public var model: String
    public var dimension: Int
    public var plan: ChunkPlanReport
    public var chunksEmbedded: Int
    public var chunksRemaining: Int
    public var batches: Int
    /// 只算 provider 调用的墙钟秒数（= GPU 时间的上界，日均预算按它记）。
    public var providerSeconds: Double
    public var elapsedMS: Double
    /// 停止原因：`complete` / 门控给的字符串 / `max_chunks` / `max_seconds` / `error`。
    public var stopReason: String
    public var error: String?
}

// =============================================================================
// MARK: - 确定性哈希提供方（**只给测试与自检用，不是语义嵌入**）
// =============================================================================

/// 把文本按字符 bigram 哈希进固定维度的"伪嵌入"。
///
/// **它没有任何语义**：只反映字面重叠，所以不能用它出 D8 的结论。
/// 存在的理由有两个：
///  1. core 的测试要能在**没有模型**的机器上（CI）跑通「分块 → 嵌入 → kNN → 删除级联」整条路；
///  2. `brosis-store vec-embed --provider hash` 让验收者不装模型也能重放一遍存储侧的行为。
///
/// 确定性：同一段文本永远得到逐位相同的向量（FNV-1a，没有随机数、不依赖平台字节序以外的东西）。
public final class HashEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public let descriptor: EmbeddingModelDescriptor

    public init(id: String = "hash-test-provider", dimension: Int = SchemaV4.dimension) {
        descriptor = EmbeddingModelDescriptor(id: id, dimension: dimension,
                                              nativeDimension: dimension)
    }

    public func embed(_ texts: [String]) throws -> [[Float]] {
        texts.map { Self.vector(of: $0, dimension: descriptor.dimension) }
    }

    static func vector(of text: String, dimension: Int) -> [Float] {
        var acc = [Double](repeating: 0, count: dimension)
        let scalars = Array(text.lowercased().unicodeScalars)
        guard !scalars.isEmpty else { return [Float](repeating: 0, count: dimension) }
        func bump(_ token: String) {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in token.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
            let index = Int(hash % UInt64(dimension))
            // 符号也从哈希里取，免得所有维度都是正的（那样任意两条向量的余弦都接近 1）。
            acc[index] += (hash & 0x1000_0000) == 0 ? 1 : -1
        }
        for i in 0..<scalars.count {
            bump(String(scalars[i]))
            if i + 1 < scalars.count { bump(String(String.UnicodeScalarView(scalars[i...(i + 1)]))) }
        }
        var norm = 0.0
        for x in acc { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 0 else { return [Float](repeating: 0, count: dimension) }
        return acc.map { Float($0 / norm) }
    }
}

/// `Store.vectorStatus()`：向量功能到底能不能用，给 UI 与 `--self-check` 看。
public struct VectorStatus: Sendable, Codable {
    /// 库里 `vec_chunks` 建好了没（v4 以后一定是 true）。
    public var tablePresent: Bool
    /// sqlite-vec 是否已注册进本进程的连接。
    public var extensionRegistered: Bool
    public var sqliteVecVersion: String
    public var dimension: Int
    public var elementType: String
    /// `meta.embed_model`；nil = 从来没跑过嵌入任务（＝功能未启用）。
    public var model: String?
    public var chunkConfigFingerprint: String?
    public var textVersions: Int
    public var chunks: Int
    public var embeddedChunks: Int
    public var pendingChunks: Int
    public var vectorRows: Int
    /// 还没分块的文本版本数（分块水位之后的）。
    public var unchunkedTextVersions: Int
    /// 检索层开关（`RetrievalOptions.vectorsEnabled`）。
    public var retrievalEnabled: Bool
    /// 三条判据都满足才算"向量检索可用"。
    public var ready: Bool {
        tablePresent && extensionRegistered && model != nil && embeddedChunks > 0
    }
}
