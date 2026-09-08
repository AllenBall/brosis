import XCTest
@testable import BrosisCore

/// M2 c / T11：分块、schema v4 迁移、向量 kNN 往返、删除级联、开关与降级。
///
/// **不需要任何模型**：这里用 `HashEmbeddingProvider`（确定性伪嵌入，没有语义）。
/// 真实模型（Qwen3-Embedding-0.6B-8bit）的那一层在 app 包的 `BrosisModels` 里，
/// 由 `brosis-embed` 与 `tools/eval` 的 D8 实验覆盖；CI / 没装模型的机器跑这一组照样全绿。
final class VectorTests: XCTestCase {

    // MARK: - 1. 分块确定性

    func testChunkerIsDeterministic() {
        let text = (0..<12).map { "第 \($0) 段：这是一段中文正文，混着 identifier_\($0) 与 0x\($0)F。" }
            .joined(separator: "\n")
        let a = Chunker.split(text)
        let b = Chunker.split(text)
        XCTAssertEqual(a, b, "同一段输入必须切出逐位相同的块")
        XCTAssertFalse(a.isEmpty)
        // ord 连续、offset 递增
        for (i, chunk) in a.enumerated() {
            XCTAssertEqual(chunk.ord, i)
            if i > 0 { XCTAssertGreaterThan(chunk.offset, a[i - 1].offset) }
        }
    }

    func testChunkerSliceRoundTrip() {
        let text = "第一段中文。\n第二段 with english words and code identifiers。\n第三段：0x80070005。"
        for chunk in Chunker.split(text) {
            XCTAssertEqual(Chunker.slice(text, offset: chunk.offset, length: chunk.length),
                           chunk.text, "按 offset / len 取回来必须与切出来的那一段逐字节相同")
            XCTAssertLessThanOrEqual(chunk.offset + chunk.length, TextPipeline.byteLength(text))
        }
    }

    func testChunkerSplitsOverlongParagraphIntoWindows() {
        var config = ChunkConfig()
        config.targetCharacters = 100
        config.maxCharacters = 120
        config.overlapCharacters = 20
        // 一整段没有换行的长文：必须走固定字符窗
        let text = String(repeating: "甲乙丙丁", count: 200)   // 800 字符
        let chunks = Chunker.split(text, config: config)
        XCTAssertGreaterThan(chunks.count, 1, "超长段落必须切开")
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.characters, config.maxCharacters)
            XCTAssertEqual(Chunker.slice(text, offset: chunk.offset, length: chunk.length), chunk.text)
        }
        // 相邻窗有重叠 ⇒ 下一块的起点比上一块的终点靠前
        for i in 1..<chunks.count {
            let previousEnd = chunks[i - 1].offset + chunks[i - 1].length
            XCTAssertLessThan(chunks[i].offset, previousEnd, "相邻窗要有重叠，答案才不会被切在缝上")
        }
    }

    func testChunkerDropsWhitespaceAndTooShort() {
        var config = ChunkConfig()
        config.minCharacters = 8
        XCTAssertTrue(Chunker.split("   \n\n \n", config: config).isEmpty)
        XCTAssertTrue(Chunker.split("短", config: config).isEmpty)
        XCTAssertEqual(Chunker.split("这一段刚好够长可以留下来", config: config).count, 1)
    }

    func testChunkerRespectsMaxChunksPerVersion() {
        var config = ChunkConfig()
        config.targetCharacters = 20
        config.maxCharacters = 20
        config.minCharacters = 1
        config.maxChunksPerVersion = 5
        let text = (0..<50).map { "段落编号 \($0) 的内容" }.joined(separator: "\n")
        XCTAssertEqual(Chunker.split(text, config: config).count, 5)
    }

    // MARK: - 2. schema v4

    func testSchemaV4TablesExistAndMigrationRowRecorded() throws {
        let fixture = try Fixture("vec-schema")
        let status = try fixture.store.vectorStatus()
        XCTAssertTrue(status.tablePresent, "vec_chunks 必须建出来")
        XCTAssertTrue(status.extensionRegistered, "sqlite-vec 必须注册成功")
        XCTAssertEqual(status.dimension, 512)
        XCTAssertEqual(status.elementType, "int8")
        XCTAssertEqual(status.sqliteVecVersion, "v0.1.9")
        XCTAssertNil(status.model, "没跑过嵌入任务时 model 必须是 nil（＝功能未启用）")
        XCTAssertFalse(status.ready)
        XCTAssertFalse(status.retrievalEnabled, "向量检索开关默认必须是关")

        // 迁移审计里有 v4 那一行
        let notes = try fixture.store.migrationNotes()
        XCTAssertTrue(notes.contains { $0.version == 4 && $0.note.contains("vec_chunks") },
                      "migrations 表里要有 v4 的行：\(notes)")
    }

    /// v3 的老库开起来要**就地补建**两张表，不重建、不丢数据。
    func testMigrationFromV3AddsChunksAndVectors() throws {
        let fixture = try Fixture("vec-migrate")
        try fixture.store.record(Synth.observation(ts: Synth.baseTS, texts: ["迁移之前就写进去的一段正文，够长，能切出块。"]))
        // 把库降级成 v3 的样子：删掉两张表、把版本号改回去。
        try fixture.store.rawExecForTests("DROP TABLE vec_chunks;")
        try fixture.store.rawExecForTests("DROP TABLE chunks;")
        try fixture.store.rawExecForTests("UPDATE meta SET value = '3' WHERE key = 'schema_version';")
        try fixture.store.rawExecForTests("DELETE FROM migrations WHERE version >= 4;")
        try fixture.reopen()

        let status = try fixture.store.vectorStatus()
        XCTAssertTrue(status.tablePresent)
        XCTAssertEqual(status.textVersions, 1, "迁移不能动已有数据")
        XCTAssertEqual(status.chunks, 0, "迁移只建表，不自动分块")
        let notes = try fixture.store.migrationNotes()
        XCTAssertTrue(notes.contains { $0.version == 4 })
    }

    // MARK: - 3. kNN 往返：写入 → 命中 → 删除后不命中

    func testKNNRoundTripAndDeleteCascade() throws {
        let fixture = try Fixture("vec-knn")
        let store = fixture.store!
        let target = "向量往返用的目标正文：知识图谱与检索评估的那一段，足够长以便切出一块。"
        let ids = try (0..<5).map { i -> Int64 in
            try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(i) * 60_000,
                texts: [i == 2 ? target : "无关正文第 \(i) 段，随便写点东西凑够长度好切块。"])).observationID
        }
        let provider = HashEmbeddingProvider()
        let report = try store.runEmbeddingJob(provider: provider)
        XCTAssertEqual(report.state, "done")
        XCTAssertEqual(report.chunksEmbedded, 5)
        XCTAssertEqual(report.chunksRemaining, 0)

        // 用目标正文自己的向量查：它必须排第一，距离≈0
        let queryVector = try provider.embed([target])[0]
        let hits = try store.vectorSearchChunks(queryVector: queryVector, k: 5)
        XCTAssertEqual(hits.count, 5)
        XCTAssertLessThan(hits[0].distance, 0.01, "自查自必须几乎零距离（int8 量化后仍然）")

        let beforeStatus = try store.vectorStatus()
        XCTAssertEqual(beforeStatus.vectorRows, 5)
        XCTAssertEqual(beforeStatus.embeddedChunks, 5)

        // 删掉那条观察 ⇒ 文本版本没人引用 ⇒ chunks 随外键消失、vec_chunks 被显式删
        let summary = try store.deleteObservations([ids[2]])
        XCTAssertEqual(summary.textVersionsDeleted, 1)
        XCTAssertEqual(summary.chunksDeleted, 1, "删除级联要覆盖 chunks")

        let afterStatus = try store.vectorStatus()
        XCTAssertEqual(afterStatus.chunks, 4)
        XCTAssertEqual(afterStatus.vectorRows, 4, "vec_chunks 是虚拟表，必须显式删干净")

        let afterHits = try store.vectorSearchChunks(queryVector: queryVector, k: 5)
        XCTAssertFalse(afterHits.contains { $0.textVersionID == 3 || $0.distance < 0.01 },
                       "删除之后不能再命中那一块")
        XCTAssertTrue(try store.integrityReport().allPassed)
    }

    /// 配额过期是**物理删观察**，也要把向量带走。
    func testExpireAlsoDropsVectors() throws {
        var options = StoreOptions()
        options.quotaBytes = 400
        let fixture = try Fixture("vec-expire", options: options)
        let store = fixture.store!
        for i in 0..<8 {
            try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(i) * 60_000,
                texts: ["配额过期用的第 \(i) 段正文，写得长一点好触发配额，凑够字节数才有意义。"]))
        }
        try store.runEmbeddingJob(provider: HashEmbeddingProvider())
        let before = try store.vectorStatus()
        XCTAssertEqual(before.vectorRows, before.chunks)

        let report = try store.expire()
        XCTAssertNotNil(report.summary)
        XCTAssertGreaterThan(report.summary?.chunksDeleted ?? 0, 0)

        let after = try store.vectorStatus()
        XCTAssertEqual(after.vectorRows, after.chunks, "过期后向量行与块数必须仍然一一对应")
        XCTAssertLessThan(after.chunks, before.chunks)
        XCTAssertTrue(try store.integrityReport().allPassed)
    }

    // MARK: - 4. 任务：可停止、可重建、幂等

    func testEmbeddingJobIsResumableAndIdempotent() throws {
        let fixture = try Fixture("vec-job")
        let store = fixture.store!
        for i in 0..<10 {
            try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(i) * 60_000,
                texts: ["任务可续跑用的第 \(i) 段正文，长度够切出一块来。"]))
        }
        let provider = HashEmbeddingProvider()
        // 只跑 4 块就停
        var options = EmbeddingJobOptions(batchSize: 2, maxChunks: 4)
        let first = try store.runEmbeddingJob(provider: provider, options: options)
        XCTAssertEqual(first.state, "cancelled")
        XCTAssertEqual(first.stopReason, "max_chunks")
        XCTAssertEqual(first.chunksEmbedded, 4)
        XCTAssertEqual(first.chunksRemaining, 6)

        // 门控直接叫停
        let gated = try store.runEmbeddingJob(provider: provider,
                                              options: EmbeddingJobOptions(batchSize: 2),
                                              gate: { "not_on_power" })
        XCTAssertEqual(gated.stopReason, "not_on_power")
        XCTAssertEqual(gated.chunksEmbedded, 0)

        // 接着跑完
        options = EmbeddingJobOptions(batchSize: 4)
        let second = try store.runEmbeddingJob(provider: provider, options: options)
        XCTAssertEqual(second.state, "done")
        XCTAssertEqual(second.chunksEmbedded, 6)
        XCTAssertEqual(second.chunksRemaining, 0)

        // 幂等：再跑一次一条都不做
        let third = try store.runEmbeddingJob(provider: provider, options: options)
        XCTAssertEqual(third.chunksEmbedded, 0)
        XCTAssertEqual(third.state, "done")

        // jobs 表里四条记录都在
        XCTAssertEqual(try store.embeddingJobs(limit: 10).count, 4)

        // 重建：清空后从头再来
        let removed = try store.rebuildEmbeddings()
        XCTAssertEqual(removed, 10)
        let afterRebuild = try store.vectorStatus()
        XCTAssertEqual(afterRebuild.chunks, 0)
        XCTAssertEqual(afterRebuild.vectorRows, 0)
        XCTAssertNil(afterRebuild.model)
        let fourth = try store.runEmbeddingJob(provider: provider, options: options)
        XCTAssertEqual(fourth.chunksEmbedded, 10)
    }

    func testEmbeddingJobRejectsModelChangeWithoutRebuild() throws {
        let fixture = try Fixture("vec-model-switch")
        let store = fixture.store!
        try store.record(Synth.observation(ts: Synth.baseTS, texts: ["换模型要先重建，这一段正文够长。"]))
        try store.runEmbeddingJob(provider: HashEmbeddingProvider(id: "model-a"))
        XCTAssertThrowsError(try store.runEmbeddingJob(provider: HashEmbeddingProvider(id: "model-b"))) {
            XCTAssertTrue("\($0)".contains("rebuildEmbeddings"), "\($0)")
        }
        try store.rebuildEmbeddings()
        let after = try store.runEmbeddingJob(provider: HashEmbeddingProvider(id: "model-b"))
        XCTAssertEqual(after.model, "model-b")
    }

    // MARK: - 5. 开关与降级

    /// **开关关闭时一次向量调用都不发**。用一个"被调用就失败"的库状态来钉：
    /// 关着的时候即使给了查询向量，`vectorsUnavailable` 也必须是 true、`fusion` 仍是 union。
    func testVectorChannelIsOffByDefault() throws {
        let fixture = try Fixture("vec-off")
        let store = fixture.store!
        try store.record(Synth.observation(ts: Synth.baseTS, texts: ["默认关的那一段正文，写长一点。"]))
        try store.runEmbeddingJob(provider: HashEmbeddingProvider())
        XCTAssertFalse(store.retrieval.vectorsEnabled, "RetrievalOptions.vectorsEnabled 默认必须是 false")

        let vector = try HashEmbeddingProvider().embed(["默认关的那一段正文"])[0]
        let result = try store.search(q: "正文", limit: 10, queryVector: vector)
        XCTAssertTrue(result.vectorsUnavailable)
        XCTAssertEqual(result.vectorUnavailableReason, "disabled")
        XCTAssertEqual(result.fusion, "union")
        XCTAssertEqual(result.vectorCandidates, 0)
        XCTAssertFalse(result.channels.contains(.vector))
    }

    /// 开关开着但调用方没给向量 ⇒ `no_query_vector`；库里没有向量 ⇒ `no_index`。
    /// 两种都是"模型没装"的表现，前三条通道必须照常工作（3.11 的降级表）。
    func testDegradesGracefullyWithoutModel() throws {
        let fixture = try Fixture("vec-degrade")
        let store = fixture.store!
        store.retrieval.vectorsEnabled = true
        try store.record(Synth.observation(ts: Synth.baseTS, texts: ["降级用的正文里有知识图谱这个词。"]))

        // ① 没给查询向量
        let noVector = try store.search(q: "知识图谱", limit: 10)
        XCTAssertTrue(noVector.vectorsUnavailable)
        XCTAssertEqual(noVector.vectorUnavailableReason, "no_query_vector")
        XCTAssertFalse(noVector.hits.isEmpty, "FTS 通道必须照常工作")

        // ② 给了向量但库里一条都没有
        let vector = try HashEmbeddingProvider().embed(["知识图谱"])[0]
        let noIndex = try store.search(q: "知识图谱", limit: 10, queryVector: vector)
        XCTAssertTrue(noIndex.vectorsUnavailable)
        XCTAssertEqual(noIndex.vectorUnavailableReason, "no_index")
        XCTAssertEqual(noIndex.hits.map(\.evidenceID), noVector.hits.map(\.evidenceID),
                       "降级路径与「没给向量」必须给出完全一样的结果")

        // ②b 带字段前缀的查询本来就不该走向量，原因要说清楚
        let prefixed = try store.search(q: "app:com.apple.Safari", limit: 10,
                                        queryVector: vector)
        XCTAssertTrue(prefixed.vectorsUnavailable)
        XCTAssertEqual(prefixed.vectorUnavailableReason, "field_prefix")
        let empty = try store.search(q: "   ", limit: 10, queryVector: vector)
        XCTAssertEqual(empty.vectorUnavailableReason, "empty_query")
        let missingApp = try store.search(q: "知识图谱", app: "com.nowhere.absent",
                                          limit: 10, queryVector: vector)
        XCTAssertEqual(missingApp.vectorUnavailableReason, "app_not_in_database")

        // ③ 跑完嵌入任务之后才真的可用
        try store.runEmbeddingJob(provider: HashEmbeddingProvider())
        let ready = try store.search(q: "知识图谱", limit: 10, queryVector: vector)
        XCTAssertFalse(ready.vectorsUnavailable)
        XCTAssertEqual(ready.fusion, "rrf")
        XCTAssertGreaterThan(ready.vectorCandidates, 0)
    }

    /// **加权 RRF 的权重真的在起作用**：让向量通道把一条**完全不相关**的观察排到第一，
    /// 精确命中（FTS）在向量通道里排最后，混合之后精确命中仍然必须排第一。
    ///
    /// 这一条是钉 `RetrievalOptions.vectorWeight` 的：
    /// 精确命中拿 `1.0 / (60 + 1) = 0.01639`，向量第一名拿 `0.5 / (60 + 1) = 0.00820`，
    /// 所以精确命中赢。把权重调大到 20（`20 / 61 = 0.328`）这条用例立刻失败——
    /// 2026-09-08 在独立 scratch 里实测过这个变异确实会被抓到。
    func testVectorWeightCannotOutrankExactHit() throws {
        let fixture = try Fixture("vec-weight")
        let store = fixture.store!
        // 15 条"向量上与查询完全一致"的干扰项 + 1 条含独特词的真命中。
        // 干扰项要够多（超过 limit），真命中才会被挤出向量通道的前 10，
        // 这样这条用例量的就纯粹是"权重让 FTS 赢"而不是"真命中在两条通道里都靠前"。
        var decoys: [Int64] = []
        for i in 0..<15 {
            decoys.append(try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(200 + i) * 60_000,
                texts: ["干扰项 \(i)：向量上被安排成与查询完全一致，但正文里没有那个独特词。"]))
                .observationID)
        }
        let targetText = "真命中：只有这一条含有独特词 zygomorphic。"
        let target = try store.record(Synth.observation(ts: Synth.baseTS + 60_000,
                                                        texts: [targetText])).observationID
        // 查询向量 = e0；干扰项 = e0（距离 0）；真命中 = e1（正交，距离 1）。
        func unitVector(_ index: Int) -> [Float] {
            var v = [Float](repeating: 0, count: SchemaV4.dimension)
            v[index] = 1
            return v
        }
        let queryVector = unitVector(0)
        let orthogonal = unitVector(1)
        let provider = ScriptedEmbeddingProvider { text in
            text.contains("zygomorphic") ? orthogonal : queryVector
        }
        try store.runEmbeddingJob(provider: provider)

        store.retrieval.vectorsEnabled = true
        store.retrieval.vectorMaxDistance = 2          // 让两条都进候选
        let result = try store.search(q: "zygomorphic", limit: 10, queryVector: queryVector)
        XCTAssertEqual(result.fusion, "rrf")
        XCTAssertEqual(result.vectorBestDistance ?? 1, 0, accuracy: 0.02,
                       "干扰项应当是向量通道的第一名")
        XCTAssertEqual(result.hits.first?.evidenceID, target,
                       "加权 RRF 必须让 FTS 的精确命中排在向量第一名之前，"
                       + "实得顺序 \(result.hits.map(\.evidenceID))")
        // 向量通道每次最多贡献 limit 条，15 个干扰项里进得来哪几个由 ts 倒序决定；
        // 这里只要求"确实有干扰项进来了"，不钉是哪一个。
        XCTAssertTrue(result.hits.map(\.evidenceID).contains(where: { decoys.contains($0) }),
                      "干扰项应当仍然在结果里，只是排在后面")
    }

    /// 向量开着也不能把精确命中挤掉：同一批数据上，混合检索的前 N 条必须仍然包含 FTS 的命中。
    func testHybridKeepsExactHits() throws {
        let fixture = try Fixture("vec-hybrid")
        let store = fixture.store!
        var target: Int64 = 0
        for i in 0..<30 {
            let text = i == 7
                ? "只有这一条含有独特词 zygomorphic 的正文，其余都是干扰项。"
                : "干扰正文第 \(i) 条，写得长一点，好切出一整块来做向量。"
            let r = try store.record(Synth.observation(ts: Synth.baseTS + Int64(i) * 60_000,
                                                       texts: [text]))
            if i == 7 { target = r.observationID }
        }
        let provider = HashEmbeddingProvider()
        try store.runEmbeddingJob(provider: provider)

        let ftsOnly = try store.search(q: "zygomorphic", limit: 10)
        XCTAssertEqual(ftsOnly.hits.first?.evidenceID, target)

        store.retrieval.vectorsEnabled = true
        // 把距离阈值放到最松，让向量通道尽量多塞候选进来
        store.retrieval.vectorMaxDistance = 2
        let vector = try provider.embed(["zygomorphic"])[0]
        let hybrid = try store.search(q: "zygomorphic", limit: 10, queryVector: vector)
        XCTAssertEqual(hybrid.fusion, "rrf")
        XCTAssertEqual(hybrid.hits.first?.evidenceID, target,
                       "加权 RRF 必须让精确命中仍然排第一，否则原 60 题会退化")
        // 逐条命中的距离要交给调用方：向量通道给的命中有值，别的通道是 nil。
        let vectorHits = hybrid.hits.filter { $0.channel == .vector }
        XCTAssertFalse(vectorHits.isEmpty)
        XCTAssertTrue(vectorHits.allSatisfy { ($0.vectorDistance ?? -1) >= 0 },
                      "向量通道的命中必须带上余弦距离（调用方的可信度信号）")
        // 注意语义：`vectorDistance` 是「这条观察在向量通道里的距离」，与最终由哪条通道
        // 标记无关——精确命中同时也被向量通道找到时，它照样有距离，这正是调用方想知道的。
        // 向量通道压根没返回的观察才是 nil。
        store.retrieval.vectorMaxDistance = 0
        let noVectorHits = try store.search(q: "zygomorphic", limit: 10, queryVector: vector)
        XCTAssertNil(noVectorHits.hits.first?.vectorDistance,
                     "向量通道没有返回这条观察时不该有距离")
    }

    /// 向量通道**按文本版本轮转**：一个版本平均被 2–3 条观察引用，
    /// 直接按名次排会让前 10 条被最靠前的两三个版本吃光。
    func testVectorChannelRotatesAcrossVersions() throws {
        let fixture = try Fixture("vec-rotate")
        let store = fixture.store!
        func unitVector(_ components: [(Int, Float)]) -> [Float] {
            var v = [Float](repeating: 0, count: SchemaV4.dimension)
            for (i, x) in components { v[i] = x }
            return v
        }
        // 三段正文，每段被 4 条观察引用（同一段文本 sha256 去重 ⇒ 只有 1 个文本版本）。
        let texts = ["第一段：向量上最靠近查询的那一段正文，长度够切一块。",
                     "第二段：次靠近的那一段正文，长度也够切一块。",
                     "第三段：再次之的那一段正文，长度同样够切一块。"]
        var idsByText: [String: Set<Int64>] = [:]
        for round in 0..<4 {
            for (i, text) in texts.enumerated() {
                let r = try store.record(Synth.observation(
                    ts: Synth.baseTS + Int64(round * 10 + i) * 60_000, texts: [text]))
                idsByText[text, default: []].insert(r.observationID)
            }
        }
        // 余弦 1.0 / 0.9 / 0.8 ⇒ 名次 0 / 1 / 2
        let query = unitVector([(0, 1)])
        let vectors: [String: [Float]] = [
            texts[0]: unitVector([(0, 1)]),
            texts[1]: unitVector([(0, 0.9), (1, 0.435_889_9)]),
            texts[2]: unitVector([(0, 0.8), (1, 0.6)]),
        ]
        let fallback = unitVector([(2, 1)])
        try store.runEmbeddingJob(provider: ScriptedEmbeddingProvider { text in
            vectors[text] ?? fallback
        })

        store.retrieval.vectorsEnabled = true
        store.retrieval.vectorMaxDistance = 2
        // 用一个正文里没有的查询串，让 FTS / 扫描 / 精确通道都空手，只剩向量通道。
        let result = try store.search(q: "zzz-no-such-term", limit: 6, queryVector: query)
        XCTAssertEqual(result.channels, [.vector])
        let top3 = Array(result.hits.prefix(3).map(\.evidenceID))
        XCTAssertEqual(top3.count, 3)
        let coveredTexts = texts.filter { text in top3.contains { idsByText[text]!.contains($0) } }
        XCTAssertEqual(coveredTexts.count, 3,
                       "前 3 条必须来自 3 个**不同的**文本版本，实得 \(top3)")
        // 第一条仍然是最近的那个版本
        XCTAssertTrue(idsByText[texts[0]]!.contains(top3[0]),
                      "最近的版本仍然要排第一，实得 \(top3[0])")
    }

    // MARK: - 6. 维护对账

    func testMaintenanceReconcilesOrphanVectors() throws {
        let fixture = try Fixture("vec-maintenance")
        let store = fixture.store!
        for i in 0..<4 {
            try store.record(Synth.observation(ts: Synth.baseTS + Int64(i) * 60_000,
                                               texts: ["对账用的第 \(i) 段正文，长度够切一块。"]))
        }
        try store.runEmbeddingJob(provider: HashEmbeddingProvider())
        // 人为造两种坏状态：孤儿向量行 + 标了已嵌入却没有向量行
        // 注意：SQLite 的 subtype 不跨子查询传播，所以不能 `SELECT vec_int8(embedding) FROM …`
        // 再插回去（实测报 "expected int8, but float32 was provided"）。
        // 直接在 VALUES 里现造一条 512 字节的 int8 全零向量即可。
        try store.rawExecForTests(
            "INSERT INTO vec_chunks(chunk_rowid, embedding) "
            + "VALUES (999999, vec_int8(zeroblob(\(SchemaV4.dimension))));")
        try store.rawExecForTests("DELETE FROM vec_chunks WHERE chunk_rowid = 1;")

        let report = try store.maintenance()
        XCTAssertEqual(report.orphanVectorRowsDeleted, 1)
        XCTAssertEqual(report.reEnqueuedChunks, 1)
        XCTAssertTrue(try store.integrityReport().allPassed)

        // 重嵌那一块
        let again = try store.runEmbeddingJob(provider: HashEmbeddingProvider())
        XCTAssertEqual(again.chunksEmbedded, 1)
    }

    // MARK: - 7. 量化

    func testInt8QuantizationPreservesCosineOrder() {
        let provider = HashEmbeddingProvider()
        let texts = ["知识图谱与检索", "检索与知识图谱", "完全不相干的另一段文本", "第四段也不相干"]
        let vectors = try! provider.embed(texts)
        func quantizedCosine(_ a: [Float], _ b: [Float]) -> Double {
            EmbeddingVector.cosine(
                EmbeddingVector.dequantizeInt8(EmbeddingVector.quantizeInt8(a)),
                EmbeddingVector.dequantizeInt8(EmbeddingVector.quantizeInt8(b)))
        }
        for i in 1..<texts.count {
            let exact = EmbeddingVector.cosine(vectors[0], vectors[i])
            let quantized = quantizedCosine(vectors[0], vectors[i])
            XCTAssertEqual(exact, quantized, accuracy: 0.01,
                           "int8 量化（按条缩放到满量程）之后余弦相似度不能明显走样")
        }
    }

    func testTruncateNormalizeIsMRL() {
        let v = (0..<1024).map { Float(sin(Double($0))) }
        let t = EmbeddingVector.truncateNormalize(v, 512)
        XCTAssertEqual(t.count, 512)
        var norm = 0.0
        for x in t { norm += Double(x) * Double(x) }
        XCTAssertEqual(norm.squareRoot(), 1.0, accuracy: 1e-5, "截断后必须重新 L2 归一化")
    }
}

/// 按文本挑向量的测试替身：让用例精确控制"谁在向量通道里排第一"。
private final class ScriptedEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    let descriptor = EmbeddingModelDescriptor(id: "scripted-test-provider",
                                              dimension: SchemaV4.dimension,
                                              nativeDimension: SchemaV4.dimension)
    private let map: @Sendable (String) -> [Float]
    init(_ map: @escaping @Sendable (String) -> [Float]) { self.map = map }
    func embed(_ texts: [String]) throws -> [[Float]] { texts.map(map) }
}
