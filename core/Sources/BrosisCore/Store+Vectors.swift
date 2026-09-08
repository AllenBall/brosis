import Foundation

// =============================================================================
// 分块、嵌入任务与向量 kNN（计划 3.4 向量检索、4.3「若 D8 通过：嵌入任务、sqlite-vec、混合检索」）
//
// 三件事的分工：
//   1. `planChunks`  —— 纯 CPU，把 text_versions 切成 chunks 行（`embedded_at` 为 NULL）。
//      可中断、可续跑：进度是 `meta.embed_chunk_watermark`（推进到的 text_versions.vrow）。
//   2. `runEmbeddingJob` —— 拿一批待办块的正文 → **放开锁** → 调 provider（GPU）→ 拿回锁写向量。
//      幂等：写完就把 `embedded_at` 置上，重跑只会捡剩下的；中途停掉不会留半条向量。
//   3. `vectorSearchChunks` —— vec0 的 kNN。
//
// 为什么嵌入时要放开锁：provider 一批 16 块在 Air 上要一秒上下（E9：16.3 条/s），
// 全程握着 `Store` 那把大锁的话，采集线程写观察会被卡住整晚。
// =============================================================================

extension Store {

    // MARK: - 状态

    /// 向量功能的当前状态（给 UI「未安装时显示未启用」与 `--self-check` 用）。
    public func vectorStatus() throws -> VectorStatus {
        try withLock { conn in try vectorStatusUnlocked(conn) }
    }

    func vectorStatusUnlocked(_ conn: SQLiteConnection) throws -> VectorStatus {
        let tables = Set(try conn.textColumn(
            "SELECT name FROM sqlite_schema WHERE type = 'table';"))
        let hasVec = tables.contains("vec_chunks")
        func count(_ sql: String, _ binds: [SQLValue] = []) throws -> Int {
            Int(try conn.scalarInt(sql, binds) ?? 0)
        }
        let watermark = try metaInt(SchemaV4.MetaKey.chunkWatermark, conn: conn) ?? 0
        return VectorStatus(
            tablePresent: hasVec,
            extensionRegistered: Store.sqliteVecRegistered,
            sqliteVecVersion: Store.sqliteVecVersion,
            dimension: SchemaV4.dimension,
            elementType: SchemaV4.elementType,
            model: try conn.scalarText("SELECT value FROM meta WHERE key = ?;",
                                       [.text(SchemaV4.MetaKey.model)]),
            chunkConfigFingerprint: try conn.scalarText("SELECT value FROM meta WHERE key = ?;",
                                                        [.text(SchemaV4.MetaKey.chunkConfig)]),
            textVersions: try count("SELECT COUNT(*) FROM text_versions;"),
            chunks: try count("SELECT COUNT(*) FROM chunks;"),
            embeddedChunks: try count("SELECT COUNT(*) FROM chunks WHERE embedded_at IS NOT NULL;"),
            pendingChunks: try count("SELECT COUNT(*) FROM chunks WHERE embedded_at IS NULL;"),
            vectorRows: hasVec ? try count("SELECT COUNT(*) FROM vec_chunks;") : 0,
            unchunkedTextVersions: try count(
                "SELECT COUNT(*) FROM text_versions WHERE vrow > ?;", [.int(watermark)]),
            retrievalEnabled: retrieval.vectorsEnabled)
    }

    // `metaInt` / `setMeta` 复用 `Store+Sessions.swift` 里那两个（同一个 `Store` 扩展族）。

    /// `migrations` 表里的迁移审计行（验收「v4 就地迁移过」用；`brosis-store init` 也打印它）。
    public func migrationNotes() throws -> [(version: Int, appliedAt: Int64, note: String)] {
        try withLock { conn in
            let st = try conn.prepare(
                "SELECT version, applied_at, note FROM migrations ORDER BY version;")
            defer { st.finalize() }
            var out: [(Int, Int64, String)] = []
            while try st.step() {
                out.append((Int(st.int(0) ?? 0), st.int(1) ?? 0, st.text(2) ?? ""))
            }
            return out
        }
    }

    /// **只给测试用**的裸 SQL 入口：造"老库"与"坏索引"这两种现场，别的地方一律不要用。
    /// 它是 `internal`，所以只有 `@testable import BrosisCore` 的测试目标看得见。
    func rawExecForTests(_ sql: String) throws {
        try withLock { conn in try conn.exec(sql) }
    }

    // MARK: - 1. 分块

    /// 把还没分块的 `text_versions` 切成 `chunks` 行。可中断、可续跑、幂等。
    ///
    /// 水位是 `meta.embed_chunk_watermark`（已经处理到的 `text_versions.vrow`）。
    /// 每一批一个事务；中途停掉，下次从水位继续。
    /// 已经有块的版本会被跳过（`UNIQUE (device_id, text_version_id, ord)` 兜底）。
    @discardableResult
    public func planChunks(config: ChunkConfig = ChunkConfig(),
                           limit: Int? = nil,
                           batch: Int = 2_000) throws -> ChunkPlanReport {
        let t0 = Date()
        var scanned = 0
        var inserted = 0
        var skipped = 0
        var complete = false
        var watermark: Int64 = 0

        while true {
            let remaining = limit.map { $0 - scanned }
            if let remaining, remaining <= 0 { break }
            let take = min(max(1, batch), remaining ?? batch)
            let step = try withLock { conn -> (rows: Int, inserted: Int, skipped: Int, watermark: Int64) in
                try conn.transaction {
                    try planChunksBatch(config: config, take: take, conn: conn)
                }
            }
            scanned += step.rows
            inserted += step.inserted
            skipped += step.skipped
            watermark = step.watermark
            if step.rows == 0 { complete = true; break }
        }
        if watermark == 0 {
            watermark = try withLock { conn in
                try metaInt(SchemaV4.MetaKey.chunkWatermark, conn: conn) ?? 0
            }
        }
        return ChunkPlanReport(textVersionsScanned: scanned, chunksInserted: inserted,
                               chunksSkippedEmpty: skipped, watermark: watermark,
                               complete: complete,
                               elapsedMS: Date().timeIntervalSince(t0) * 1000)
    }

    private func planChunksBatch(config: ChunkConfig, take: Int,
                                 conn: SQLiteConnection) throws
        -> (rows: Int, inserted: Int, skipped: Int, watermark: Int64) {
        // 分块参数变了就说明库里已有的块作废；这里只负责记录，作废由 rebuildEmbeddings 做。
        let storedFingerprint = try conn.scalarText(
            "SELECT value FROM meta WHERE key = ?;", [.text(SchemaV4.MetaKey.chunkConfig)])
        if storedFingerprint == nil {
            try setMeta(SchemaV4.MetaKey.chunkConfig, config.fingerprint, conn: conn)
        } else if storedFingerprint != config.fingerprint {
            throw StoreError.invalidUsage(
                "分块参数与库里已有的不一致（库 \(storedFingerprint!)，本次 \(config.fingerprint)）；"
                + "先 rebuildEmbeddings() 再跑")
        }

        var watermark = try metaInt(SchemaV4.MetaKey.chunkWatermark, conn: conn) ?? 0
        let st = try conn.prepare("""
            SELECT vrow, id, text FROM text_versions
             WHERE device_id = ? AND vrow > ? ORDER BY vrow LIMIT ?;
            """)
        defer { st.finalize() }
        try st.bind([.text(deviceID), .int(watermark), .int(Int64(take))])
        var pending: [(vrow: Int64, id: Int64, text: String)] = []
        while try st.step() {
            guard let vrow = st.int(0), let id = st.int(1), let text = st.text(2) else { continue }
            pending.append((vrow, id, text))
        }
        guard !pending.isEmpty else { return (0, 0, 0, watermark) }

        var inserted = 0
        var skipped = 0
        for row in pending {
            let chunks = Chunker.split(row.text, config: config)
            if chunks.isEmpty { skipped += 1 }
            for chunk in chunks {
                // `INSERT OR IGNORE` + `UNIQUE (device_id, text_version_id, ord)`：
                // 重跑同一批不会重复插，`conn.run` 返回的 changes 因此就是"真的新插了几条"。
                inserted += try conn.run("""
                    INSERT OR IGNORE INTO chunks
                      (device_id, text_version_id, ord, "offset", len, chars, embedded_at, model, dim)
                    VALUES (?,?,?,?,?,?,NULL,NULL,NULL);
                    """, [.text(deviceID), .int(row.id), .int(Int64(chunk.ord)),
                          .int(Int64(chunk.offset)), .int(Int64(chunk.length)),
                          .int(Int64(chunk.characters))])
            }
            watermark = max(watermark, row.vrow)
        }
        try setMeta(SchemaV4.MetaKey.chunkWatermark, String(watermark), conn: conn)
        return (pending.count, inserted, skipped, watermark)
    }

    // MARK: - 2. 嵌入任务

    /// 跑一次嵌入任务。**可停止、可重建、幂等**（计划 4.3）。
    ///
    /// - 每批之前问一次 `gate`：返回非 nil 就干净地停下（已经写进去的块保留，不回滚）。
    /// - provider 调用**不持锁**，采集线程照常写库。
    /// - 一批的向量与 `embedded_at` 在同一个事务里落，所以不会出现
    ///   「`chunks` 说嵌过了但 `vec_chunks` 没有」的半条状态。
    @discardableResult
    public func runEmbeddingJob(provider: EmbeddingProvider,
                                options: EmbeddingJobOptions = EmbeddingJobOptions(),
                                gate: EmbeddingGate? = nil) throws -> EmbeddingJobReport {
        let t0 = Date()
        let descriptor = provider.descriptor
        guard descriptor.dimension == SchemaV4.dimension else {
            throw StoreError.invalidUsage(
                "模型维度 \(descriptor.dimension) 与 vec_chunks 的 \(SchemaV4.dimension) 不一致")
        }

        // 模型换了 ⇒ 已有向量作废。这里只拦住，不自动删（删是显式动作）。
        try withLock { conn in
            if let existing = try conn.scalarText("SELECT value FROM meta WHERE key = ?;",
                                                  [.text(SchemaV4.MetaKey.model)]),
               existing != descriptor.id {
                throw StoreError.invalidUsage(
                    "库里已有的向量是用 \(existing) 建的，本次是 \(descriptor.id)；"
                    + "先 rebuildEmbeddings() 再跑")
            }
        }

        let jobID = try beginJob(type: "embed", input: [
            "model": descriptor.id, "dim": descriptor.dimension,
            "batch_size": options.batchSize,
            "chunk_config": options.chunkConfig.fingerprint,
        ])

        var plan = ChunkPlanReport(textVersionsScanned: 0, chunksInserted: 0, chunksSkippedEmpty: 0,
                                   watermark: 0, complete: true, elapsedMS: 0)
        var embedded = 0
        var batches = 0
        var providerSeconds = 0.0
        var stopReason = "complete"
        var failure: Error?

        do {
            if options.planBatch > 0 {
                plan = try planChunks(config: options.chunkConfig, batch: options.planBatch)
            }
            loop: while true {
                if let reason = gate?() { stopReason = reason; break loop }
                if let maxChunks = options.maxChunks, embedded >= maxChunks {
                    stopReason = "max_chunks"; break loop
                }
                if let maxSeconds = options.maxSeconds,
                   Date().timeIntervalSince(t0) >= maxSeconds {
                    stopReason = "max_seconds"; break loop
                }
                var size = max(1, options.batchSize)
                if let maxChunks = options.maxChunks { size = min(size, maxChunks - embedded) }

                // ① 取一批待办块的正文（持锁，很快）
                let batch = try withLock { conn in
                    try pendingBatch(size: size, conn: conn)
                }
                if batch.isEmpty { stopReason = "complete"; break loop }

                // ② 调 provider（**不持锁**）
                let p0 = Date()
                let vectors = try provider.embed(batch.map(\.text))
                providerSeconds += Date().timeIntervalSince(p0)
                guard vectors.count == batch.count else {
                    throw StoreError.invalidUsage(
                        "provider 返回 \(vectors.count) 条向量，与入参 \(batch.count) 条不符")
                }

                // ③ 写回（持锁，一个事务）
                try withLock { conn in
                    try conn.transaction {
                        let now = Int64(Date().timeIntervalSince1970 * 1000)
                        for (i, item) in batch.enumerated() {
                            let v = EmbeddingVector.truncateNormalize(vectors[i], SchemaV4.dimension)
                            guard v.count == SchemaV4.dimension else {
                                throw StoreError.invalidUsage(
                                    "第 \(i) 条向量维度 \(vectors[i].count)，截断后仍不是 \(SchemaV4.dimension)")
                            }
                            try conn.run("DELETE FROM vec_chunks WHERE chunk_rowid = ?;",
                                         [.int(item.vrow)])
                            try conn.run("""
                                INSERT INTO vec_chunks(chunk_rowid, embedding)
                                VALUES (?, vec_int8(?));
                                """, [.int(item.vrow), .blob(EmbeddingVector.quantizeInt8(v))])
                            try conn.run("""
                                UPDATE chunks SET embedded_at = ?, model = ?, dim = ? WHERE vrow = ?;
                                """, [.int(now), .text(descriptor.id),
                                      .int(Int64(SchemaV4.dimension)), .int(item.vrow)])
                        }
                        try setMeta(SchemaV4.MetaKey.model, descriptor.id, conn: conn)
                        try setMeta(SchemaV4.MetaKey.dimension, String(SchemaV4.dimension), conn: conn)
                    }
                }
                embedded += batch.count
                batches += 1
            }
        } catch {
            failure = error
            stopReason = "error"
        }

        let remaining = try withLock { conn in
            Int(try conn.scalarInt("SELECT COUNT(*) FROM chunks WHERE embedded_at IS NULL;") ?? 0)
        }
        let state = failure != nil ? "failed" : (stopReason == "complete" ? "done" : "cancelled")
        var report = EmbeddingJobReport(
            jobID: jobID, state: state, model: descriptor.id, dimension: SchemaV4.dimension,
            plan: plan, chunksEmbedded: embedded, chunksRemaining: remaining, batches: batches,
            providerSeconds: providerSeconds,
            elapsedMS: Date().timeIntervalSince(t0) * 1000,
            stopReason: stopReason, error: failure.map { "\($0)" })
        try finishJob(id: jobID, state: state, output: [
            "chunks_embedded": embedded, "chunks_remaining": remaining, "batches": batches,
            "provider_seconds": providerSeconds, "stop_reason": stopReason,
            "elapsed_ms": report.elapsedMS,
        ], error: report.error)
        if let failure { report.error = "\(failure)" }
        return report
    }

    struct PendingChunk {
        var vrow: Int64
        var text: String
    }

    private func pendingBatch(size: Int, conn: SQLiteConnection) throws -> [PendingChunk] {
        let st = try conn.prepare("""
            SELECT c.vrow, c."offset", c.len, tv.text
              FROM chunks c
              JOIN text_versions tv ON tv.device_id = c.device_id AND tv.id = c.text_version_id
             WHERE c.device_id = ? AND c.embedded_at IS NULL
             ORDER BY c.vrow LIMIT ?;
            """)
        defer { st.finalize() }
        try st.bind([.text(deviceID), .int(Int64(max(1, size)))])
        var out: [PendingChunk] = []
        while try st.step() {
            guard let vrow = st.int(0), let offset = st.int(1), let len = st.int(2),
                  let text = st.text(3) else { continue }
            let body = Chunker.slice(text, offset: Int(offset), length: Int(len)) ?? ""
            out.append(PendingChunk(vrow: vrow, text: body))
        }
        return out
    }

    /// 重建：把 `chunks` 与 `vec_chunks` 全清掉、水位归零，下次任务从头再来。
    /// 换模型、改分块参数、或怀疑索引坏了的时候用。返回删掉的块数。
    @discardableResult
    public func rebuildEmbeddings(config: ChunkConfig? = nil) throws -> Int {
        try withLock { conn in
            try conn.transaction {
                let n = Int(try conn.scalarInt("SELECT COUNT(*) FROM chunks;") ?? 0)
                try conn.exec("DELETE FROM vec_chunks;")
                try conn.exec("DELETE FROM chunks;")
                try conn.run("DELETE FROM meta WHERE key IN (?,?,?,?);", [
                    .text(SchemaV4.MetaKey.model), .text(SchemaV4.MetaKey.dimension),
                    .text(SchemaV4.MetaKey.chunkConfig), .text(SchemaV4.MetaKey.chunkWatermark),
                ])
                if let config { try setMeta(SchemaV4.MetaKey.chunkConfig, config.fingerprint, conn: conn) }
                return n
            }
        }
    }

    // MARK: - jobs 表（3.2「可停止、可重建的处理任务」）

    func beginJob(type: String, input: [String: Any]) throws -> Int64 {
        try withLock { conn in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try conn.run("""
                INSERT INTO jobs(type, state, input_ref, output_ref, created_at, updated_at, error)
                VALUES (?, 'running', ?, NULL, ?, ?, NULL);
                """, [.text(type), .text(try jsonObject(input)), .int(now), .int(now)])
            return conn.lastInsertRowID
        }
    }

    func finishJob(id: Int64, state: String, output: [String: Any], error: String?) throws {
        try withLock { conn in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try conn.run("UPDATE jobs SET state = ?, output_ref = ?, updated_at = ?, error = ? WHERE id = ?;",
                         [.text(state), .text(try jsonObject(output)), .int(now),
                          .optionalText(error), .int(id)])
        }
    }

    /// 最近的嵌入任务行（`brosis-store vec-status` 与 app 的模型面板用）。
    public func embeddingJobs(limit: Int = 10) throws -> [[String: String]] {
        try withLock { conn in
            let st = try conn.prepare("""
                SELECT id, state, input_ref, output_ref, created_at, updated_at, error
                  FROM jobs WHERE type = 'embed' ORDER BY id DESC LIMIT ?;
                """)
            defer { st.finalize() }
            try st.bind([.int(Int64(max(1, limit)))])
            var out: [[String: String]] = []
            while try st.step() {
                out.append([
                    "id": String(st.int(0) ?? 0),
                    "state": st.text(1) ?? "",
                    "input": st.text(2) ?? "",
                    "output": st.text(3) ?? "",
                    "created_at": String(st.int(4) ?? 0),
                    "updated_at": String(st.int(5) ?? 0),
                    "error": st.text(6) ?? "",
                ])
            }
            return out
        }
    }

    // MARK: - 3. kNN

    /// 一条 kNN 命中：块、它属于哪个文本版本、余弦距离（0 = 完全一致，2 = 完全相反）。
    public struct VectorHit: Sendable, Codable {
        public var chunkVRow: Int64
        public var textVersionID: Int64
        public var distance: Double
    }

    /// 纯向量 kNN，不做时间 / 应用过滤，也不展开到观察。评估与自检用。
    public func vectorSearchChunks(queryVector: [Float], k: Int = 50) throws -> [VectorHit] {
        try withLock { conn in try knn(queryVector: queryVector, k: k, conn: conn) }
    }

    func knn(queryVector: [Float], k: Int, conn: SQLiteConnection) throws -> [VectorHit] {
        let v = EmbeddingVector.truncateNormalize(queryVector, SchemaV4.dimension)
        guard v.count == SchemaV4.dimension else {
            throw StoreError.invalidUsage("查询向量维度 \(queryVector.count)，需要 \(SchemaV4.dimension)")
        }
        let st = try conn.prepare("""
            SELECT chunk_rowid, distance FROM vec_chunks
             WHERE embedding MATCH vec_int8(?) AND k = ?;
            """)
        defer { st.finalize() }
        try st.bind([.blob(EmbeddingVector.quantizeInt8(v)), .int(Int64(max(1, k)))])
        var rows: [(Int64, Double)] = []
        while try st.step() {
            rows.append((st.int(0) ?? 0, st.double(1) ?? 0))
        }
        guard !rows.isEmpty else { return [] }
        var versionOf: [Int64: Int64] = [:]
        for chunk in rows.map(\.0).chunked(into: 400) {
            let pairs = try conn.intPairs("""
                SELECT vrow, text_version_id FROM chunks WHERE vrow IN (\(placeholders(chunk.count)));
                """, chunk.map { SQLValue.int($0) })
            for (vrow, tv) in pairs { versionOf[vrow] = tv }
        }
        return rows.compactMap { row in
            guard let tv = versionOf[row.0] else { return nil }
            return VectorHit(chunkVRow: row.0, textVersionID: tv, distance: row.1)
        }
    }
}
