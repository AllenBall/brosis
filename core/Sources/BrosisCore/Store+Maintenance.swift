import Foundation

extension Store {

    /// 夜间维护（3.8「逻辑删除后的物理清理」+ D22「FTS 与 text_versions 夜间对账」）。
    ///
    /// 顺序：
    /// 1. FTS 对账——孤儿 FTS 行删掉，缺失的 FTS 行按「折叠后再 bigram」补写
    ///    （必须与写入侧同一个 `TextPipeline.bigramForIndex`，否则补出来的行对不上）；
    /// 2. `capture_stats`、`mcp_audit` 与 `capture_audit` 按各自的保留天数滚动清理
    ///    （遥测、调用审计、采样审计都不是证据，不进删除审计）；
    /// 3. `wal_checkpoint(TRUNCATE)`：先把 WAL 落回主库，再量体积才有意义；
    /// 4. `incremental_vacuum`：回收 `auto_vacuum = INCREMENTAL` 攒下的空闲页；
    /// 5. 再 checkpoint 一次，把 vacuum 产生的 WAL 也截掉。
    @discardableResult
    public func maintenance(now: Int64? = nil) throws -> MaintenanceReport {
        try withLock { conn in
            let t0 = Date()
            let walBefore = fileSize(databaseURL.path + "-wal")
            let dbBefore = fileSize(databaseURL.path)
            let freeBefore = Int(try conn.scalarInt("PRAGMA freelist_count;") ?? 0)

            // 1) FTS 对账
            var orphans = 0
            var missing = 0
            try conn.transaction {
                let orphanRows = try conn.intColumn("""
                    SELECT d.id FROM text_fts_docsize d
                     WHERE NOT EXISTS (SELECT 1 FROM text_versions tv WHERE tv.vrow = d.id);
                    """)
                for vrow in orphanRows {
                    try conn.run("DELETE FROM text_fts WHERE rowid = ?;", [.int(vrow)])
                }
                orphans = orphanRows.count

                let st = try conn.prepare("""
                    SELECT tv.vrow, tv.text FROM text_versions tv
                     WHERE NOT EXISTS (SELECT 1 FROM text_fts_docsize d WHERE d.id = tv.vrow);
                    """)
                var pending: [(Int64, String)] = []
                while try st.step() {
                    if let vrow = st.int(0), let text = st.text(1) { pending.append((vrow, text)) }
                }
                st.finalize()
                for (vrow, text) in pending {
                    let index = TextPipeline.indexBody(text)
                    try conn.run("INSERT INTO text_fts(rowid, body) VALUES (?, ?);",
                                 [.int(vrow), .text(index.body)])
                    if index.foldedDiffers { try markCompatibilityText(conn: conn) }
                }
                missing = pending.count
            }

            // 2) 遥测滚动清理
            var pruned = 0
            if options.captureStatsRetentionDays > 0 {
                let nowMS = now ?? Int64(Date().timeIntervalSince1970 * 1000)
                let cutoff = nowMS - Int64(options.captureStatsRetentionDays) * 86_400_000
                pruned = try conn.run("DELETE FROM capture_stats WHERE ts < ?;", [.int(cutoff)])
            }
            var auditPruned = 0
            if options.mcpAuditRetentionDays > 0 {
                let nowMS = now ?? Int64(Date().timeIntervalSince1970 * 1000)
                let cutoff = nowMS - Int64(options.mcpAuditRetentionDays) * 86_400_000
                auditPruned = try conn.run("DELETE FROM mcp_audit WHERE ts < ?;", [.int(cutoff)])
            }
            var captureAuditPruned = 0
            if options.captureAuditRetentionDays > 0 {
                let nowMS = now ?? Int64(Date().timeIntervalSince1970 * 1000)
                let cutoff = nowMS - Int64(options.captureAuditRetentionDays) * 86_400_000
                captureAuditPruned = try conn.run("DELETE FROM capture_audit WHERE ts < ?;",
                                                  [.int(cutoff)])
            }

            // 3–5) 物理回收
            try conn.exec("PRAGMA wal_checkpoint(TRUNCATE);")
            // incremental_vacuum 是一条会返回多行的 PRAGMA，必须把结果读干净才算跑完。
            let vac = try conn.prepare("PRAGMA incremental_vacuum;")
            while try vac.step() {}
            vac.finalize()
            try conn.exec("PRAGMA wal_checkpoint(TRUNCATE);")

            let freeAfter = Int(try conn.scalarInt("PRAGMA freelist_count;") ?? 0)
            return MaintenanceReport(
                orphanFTSRowsDeleted: orphans,
                missingFTSRowsInserted: missing,
                walBytesBefore: walBefore, walBytesAfter: fileSize(databaseURL.path + "-wal"),
                dbBytesBefore: dbBefore, dbBytesAfter: fileSize(databaseURL.path),
                freelistBefore: freeBefore, freelistAfter: freeAfter,
                captureStatsPruned: pruned,
                mcpAuditPruned: auditPruned,
                captureAuditPruned: captureAuditPruned,
                elapsedMS: Date().timeIntervalSince(t0) * 1000)
        }
    }

    /// 只做 checkpoint（`locking` 状态转移里用；不做 vacuum）。
    public func checkpoint() throws {
        try withLock { conn in try conn.exec("PRAGMA wal_checkpoint(TRUNCATE);") }
    }

    func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0
    }
}
