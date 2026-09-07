// brosis M0 · E9：嵌入验证与基准
//
// 六项：
//   1) 确定性（同一文本两次向量逐元素相同）
//   2) 语义合理性（中文近义 / 英文近义 / 中英互译 / 无关，各 10 对的余弦均值）
//   3) MRL 截断（1024 vs 512 vs 256 的 Recall@10，以 1024 维为真值）——对应报告 11.2 第 7 条
//   4) 吞吐（批 16、每条约 500 字符中英混排）
//   5) 首次加载时间与内存峰值
//   6) 与 Python 参考对照用的向量导出

import Foundation
import MLX

struct MRLSet: Codable, Sendable {
    let docs: [String]
    let queries: [String]
}

struct Corpus: Codable, Sendable {
    let seed: Int
    let queryInstruction: String
    let pairs: [String: [[String]]]
    let mrl: MRLSet
    let throughput: [String]
    let crosscheck: [String]

    static func load() throws -> Corpus {
        guard let url = Resources.url(named: "corpus.json") else {
            throw E9Error.message("找不到 corpus.json")
        }
        return try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
    }
}

enum Bench {

    // MARK: 1) 确定性

    static func determinism(_ e: Embedder, texts: [String]) async -> [String: Any] {
        let (a, _) = await e.embedAll(texts, batchSize: 8)
        let (b, _) = await e.embedAll(texts, batchSize: 8)
        var identical = 0
        var maxAbsDiff = 0.0
        for i in a.indices {
            if a[i] == b[i] { identical += 1 }
            for j in a[i].indices {
                maxAbsDiff = max(maxAbsDiff, abs(Double(a[i][j]) - Double(b[i][j])))
            }
        }
        // 换个批大小再跑一次：批内 padding 长度不同，看数值是否仍然一致
        let (c, _) = await e.embedAll(texts, batchSize: 1)
        var identicalAcrossBatch = 0
        var maxAbsDiffBatch = 0.0
        for i in a.indices {
            if a[i] == c[i] { identicalAcrossBatch += 1 }
            for j in a[i].indices {
                maxAbsDiffBatch = max(maxAbsDiffBatch, abs(Double(a[i][j]) - Double(c[i][j])))
            }
        }
        return [
            "textCount": texts.count,
            "identicalSameBatchSize": identical,
            "maxAbsDiffSameBatchSize": maxAbsDiff,
            "identicalAcrossBatchSize": identicalAcrossBatch,
            "maxAbsDiffAcrossBatchSize": maxAbsDiffBatch,
            "dimension": a.first?.count ?? 0,
        ]
    }

    // MARK: 2) 语义合理性

    static func semantics(_ e: Embedder, corpus: Corpus) async -> [String: Any] {
        var out: [String: Any] = [:]
        for group in ["zh_synonym", "en_synonym", "cross_lingual", "unrelated"] {
            guard let pairs = corpus.pairs[group] else { continue }
            let lefts = pairs.map { $0[0] }
            let rights = pairs.map { $0[1] }
            let (lv, _) = await e.embedAll(lefts, batchSize: 10)
            let (rv, _) = await e.embedAll(rights, batchSize: 10)
            let cos = zip(lv, rv).map { Vec.cosine($0, $1) }
            out[group] = [
                "pairs": pairs.count,
                "cosineMean": cos.mean,
                "cosineStdev": cos.stdev,
                "cosineMin": cos.min() ?? 0,
                "cosineMax": cos.max() ?? 0,
                "cosines": cos,
            ]
        }
        return out
    }

    // MARK: 3) MRL 截断

    static func mrl(_ e: Embedder, corpus: Corpus, dims: [Int] = [512, 256]) async -> [String: Any] {
        let docs = corpus.mrl.docs
        let queries = corpus.mrl.queries.map { corpus.queryInstruction + $0 }
        let (dv, _) = await e.embedAll(docs, batchSize: 16)
        let (qv, _) = await e.embedAll(queries, batchSize: 16)
        let full = e.dimension

        func ranking(_ d: Int) -> [[Int]] {
            let dd = dv.map { Vec.truncateNormalize($0, d) }
            let qq = qv.map { Vec.truncateNormalize($0, d) }
            return qq.map { Vec.topK(query: $0, docs: dd, k: 10) }
        }

        let truth = ranking(full)
        var perDim: [String: Any] = [:]
        for d in dims {
            let got = ranking(d)
            var r10: [Double] = []
            var r1: [Double] = []
            for i in truth.indices {
                let t = Set(truth[i])
                let g = got[i]
                r10.append(Double(g.filter { t.contains($0) }.count) / 10.0)
                r1.append(g.first == truth[i].first ? 1 : 0)
            }
            perDim["\(d)"] = [
                "recallAt10Mean": r10.mean,
                "recallAt10Min": r10.min() ?? 0,
                "top1AgreementRate": r1.mean,
                "queriesWithPerfectTop10": r10.filter { $0 >= 1.0 }.count,
            ]
        }
        return [
            "docCount": docs.count,
            "queryCount": queries.count,
            "truthDimension": full,
            "queryInstructionUsed": true,
            "byDimension": perDim,
        ]
    }

    // MARK: 4) 吞吐

    static func throughput(_ e: Embedder, corpus: Corpus, repeats: Int = 5) async -> [String: Any] {
        let texts = corpus.throughput
        let chars = texts.map { $0.count }
        // 预热一轮，不计入
        _ = await e.embedBatch(texts)
        var seconds: [Double] = []
        var tokens = 0
        var maxLen = 0
        for _ in 0..<repeats {
            let t0 = Date()
            let (_, s) = await e.embedBatch(texts)
            seconds.append(Date().timeIntervalSince(t0))
            tokens = s.totalTokens
            maxLen = s.maxSeqLen
        }
        let best = seconds.min() ?? 0
        return [
            "batchSize": texts.count,
            "memoryAfter": memorySnapshot(label: "after-throughput"),
            "avgChars": Double(chars.reduce(0, +)) / Double(chars.count),
            "tokensPerBatch": tokens,
            "maxSeqLen": maxLen,
            "repeats": repeats,
            "secondsPerBatch": ["mean": seconds.mean, "min": best, "max": seconds.max() ?? 0,
                                "all": seconds],
            "textsPerSecond": Double(texts.count) / seconds.mean,
            "textsPerSecondBest": Double(texts.count) / best,
            "tokensPerSecond": Double(tokens) / seconds.mean,
            "tokensPerSecondBest": Double(tokens) / best,
        ]
    }

    // MARK: 6) 导出给 Python 对照

    static func crosscheckDump(_ e: Embedder, corpus: Corpus, to url: URL) async throws
        -> [String: Any]
    {
        let (v, _) = await e.embedAll(corpus.crosscheck, batchSize: 8)
        try JSONOut.write(
            [
                "modelDirectory": e.modelDirectory.path,
                "dimension": e.dimension,
                "poolingStrategy": e.poolingStrategy,
                "texts": corpus.crosscheck,
                "vectors": v.map { $0.map { Double($0) } },
            ], to: url)
        return ["count": v.count, "dimension": v.first?.count ?? 0, "path": url.path]
    }

    // MARK: 运行时环境

    static func environment() -> [String: Any] {
        [
            "hardwareModel": Proc.hardwareModel,
            "physicalMemoryGiB": Double(Proc.physicalMemory) / Bytes.gib,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "thermalStateAtStart": Proc.thermalState,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "gpuMemoryLimitMiB": Double(MLX.Memory.memoryLimit) / Bytes.mib,
        ]
    }

    /// 内存快照。**必须同时看 footprint 和 RSS**（评审 F8）：
    /// Metal / MLX 的缓冲池在统一内存里计入 phys_footprint 而不计入 RSS，
    /// 批量推理时两者能差 8 倍，只报 RSS 会得出错误结论。
    static func memorySnapshot(label: String) -> [String: Any] {
        [
            "label": label,
            // ↓ 决策要看这两行
            "footprintMiB": Double(Proc.footprintBytes()) / Bytes.mib,
            "peakFootprintMiB": Double(Proc.peakFootprintBytes()) / Bytes.mib,
            // ↓ RSS：不含 Metal 缓冲，会低估
            "residentMiB": Double(Proc.residentBytes()) / Bytes.mib,
            "peakResidentMiB": Double(Proc.peakResidentBytes()) / Bytes.mib,
            "gpuActiveMiB": Double(MLX.Memory.activeMemory) / Bytes.mib,
            "gpuPeakMiB": Double(MLX.Memory.peakMemory) / Bytes.mib,
            "gpuCacheMiB": Double(MLX.Memory.cacheMemory) / Bytes.mib,
            "thermalState": Proc.thermalState,
            "sinceProcessStartSeconds": Proc.sinceStart,
        ]
    }

    /// MLX 缓冲池的配置（`--cache-limit-mib` 决定）。
    static func gpuMemoryConfig() -> [String: Any] {
        [
            "cacheLimitMiB": Double(MLX.Memory.cacheLimit) / Bytes.mib,
            "memoryLimitMiB": Double(MLX.Memory.memoryLimit) / Bytes.mib,
            "cacheLimitOverridden": MemoryPolicy.applied != nil,
            "cacheLimitRequestedMiB": MemoryPolicy.applied.map { Double($0) / Bytes.mib } as Any,
        ]
    }
}

/// MLX 缓冲池策略。默认不限（MLX 自己把 cacheLimit 设成 memoryLimit），
/// 夜间批处理这类"跑完要立刻还内存"的场景需要显式限制。
enum MemoryPolicy {
    nonisolated(unsafe) private(set) static var applied: Int?

    /// 在加载模型之前调用。`mib = 0` 表示彻底关掉缓冲池。
    static func applyCacheLimit(mib: Int) {
        let bytes = mib * (1 << 20)
        MLX.Memory.cacheLimit = bytes
        applied = bytes
    }

    /// 立刻把缓冲池还给系统，返回释放前后的 footprint。
    static func releaseCache() -> [String: Any] {
        let beforeCache = MLX.Memory.cacheMemory
        let beforeFootprint = Proc.footprintBytes()
        MLX.Memory.clearCache()
        // footprint 的回落不是同步的，给内核一点时间把页还回去
        usleep(200_000)
        return [
            "gpuCacheBeforeMiB": Double(beforeCache) / Bytes.mib,
            "gpuCacheAfterMiB": Double(MLX.Memory.cacheMemory) / Bytes.mib,
            "footprintBeforeMiB": Double(beforeFootprint) / Bytes.mib,
            "footprintAfterMiB": Double(Proc.footprintBytes()) / Bytes.mib,
        ]
    }
}
