import Foundation

/// FTS 通道的一条候选。
public struct FTSHit: Sendable, Hashable {
    public var vrow: Int64
    public var textVersionID: Int64
}

extension Store {

    // MARK: - FTS 通道（D22）

    /// bigram phrase 查 `text_fts`，**按 rowid 倒序取**而不是 bm25 排序
    /// （E7：12 个月库上 225 ms → 1.3 ms），再对候选做子串复核滤掉分词假阳性。
    ///
    /// 复核按索引口径（`TextPipeline.indexContains`）：正文存的是原文、索引存的是折叠后的形式，
    /// 所以复核不中时要把候选正文现折叠一遍再比，否则全角原文会被半角查询误杀。
    ///
    /// 这是 T2 只为自测与 T3 复用而提供的最小实现：完整的三通道 `search`
    /// （精确字段 / FTS / 单字扫描回退）归 T3。
    public func searchFTS(_ query: String, limit: Int = 50, substringRecheck: Bool = true) throws -> [FTSHit] {
        let normalized = TextPipeline.foldForIndex(query)
        guard !normalized.isEmpty else { return [] }
        return try withLock { conn in
            let st = try conn.prepare("""
                SELECT f.rowid, tv.id, tv.text
                  FROM text_fts f JOIN text_versions tv ON tv.vrow = f.rowid
                 WHERE text_fts MATCH ?
                 ORDER BY f.rowid DESC LIMIT ?;
                """)
            defer { st.finalize() }
            try st.bind([.text(TextPipeline.ftsPhrase(normalized)), .int(Int64(limit))])
            var out: [FTSHit] = []
            while try st.step() {
                guard let vrow = st.int(0), let tvID = st.int(1) else { continue }
                if substringRecheck, let text = st.text(2),
                   !TextPipeline.indexContains(text, foldedTerm: normalized) { continue }
                out.append(FTSHit(vrow: vrow, textVersionID: tvID))
            }
            return out
        }
    }

    /// FTS 命中条数（不做子串复核）。测试里用来核对"删除后不再命中"。
    public func ftsMatchCount(_ query: String) throws -> Int {
        try withLock { conn in
            Int(try conn.scalarInt("SELECT COUNT(*) FROM text_fts WHERE text_fts MATCH ?;",
                                   [.text(TextPipeline.ftsPhrase(query))]) ?? 0)
        }
    }

    /// FTS 索引里的总行数（`text_fts_docsize`）。删除审计的独立复核用。
    public func ftsRowCount() throws -> Int {
        try withLock { conn in try ftsRowCount(conn) }
    }

    // MARK: - 三个证据入口的最小版本（T3 会在上面建完整的 MCP 工具）

    /// `get_evidence` 的最小版本：按 ord 重建一次观察的完整正文。
    /// 已打墓碑（用户删除）或已物理删除的观察返回 nil——3.8 的验收要求这个入口不再返回内容。
    public func evidenceText(observationID: Int64) throws -> String? {
        try withLock { conn in
            let live = try conn.scalarInt("""
                SELECT COUNT(*) FROM observations
                 WHERE device_id = ? AND id = ? AND deleted_at IS NULL;
                """, [.text(deviceID), .int(observationID)]) ?? 0
            guard live == 1 else { return nil }
            let parts = try conn.textColumn("""
                SELECT tv.text FROM occurrences o
                  JOIN text_versions tv ON tv.device_id = o.device_id AND tv.id = o.text_version_id
                 WHERE o.device_id = ? AND o.observation_id = ? ORDER BY o.ord;
                """, [.text(deviceID), .int(observationID)])
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
    }

    /// `get_context` 的最小版本：时间窗内**未删除**观察的正文。
    public func contextTexts(from start: Int64, to end: Int64, limit: Int = 500) throws -> [String] {
        try withLock { conn in
            try conn.textColumn("""
                SELECT tv.text FROM observations o
                  JOIN occurrences occ ON occ.device_id = o.device_id AND occ.observation_id = o.id
                  JOIN text_versions tv ON tv.device_id = occ.device_id AND tv.id = occ.text_version_id
                 WHERE o.device_id = ? AND o.ts >= ? AND o.ts < ? AND o.deleted_at IS NULL
                 ORDER BY o.ts DESC, occ.ord LIMIT ?;
                """, [.text(deviceID), .int(start), .int(end), .int(Int64(limit))])
        }
    }

    /// `get_day_ledger` 的最小版本：某条台账的证据区间里还活着的观察正文。
    /// 台账被标 `stale` 时同样不返回内容（等重算）。
    public func dayLedgerTexts(level: String, period: String) throws -> [String] {
        try withLock { conn in
            let st = try conn.prepare("""
                SELECT evidence, stale FROM ledgers WHERE device_id = ? AND level = ? AND period = ?;
                """)
            try st.bind([.text(deviceID), .text(level), .text(period)])
            guard try st.step(), let evidence = st.text(0), (st.int(1) ?? 0) == 0 else {
                st.finalize(); return []
            }
            st.finalize()
            let ids = evidenceObservationIDs(evidence)
            guard !ids.isEmpty else { return [] }
            var out: [String] = []
            for chunk in ids.chunked(into: 400) {
                let marks = placeholders(chunk.count)
                out += try conn.textColumn("""
                    SELECT tv.text FROM observations o
                      JOIN occurrences occ ON occ.device_id = o.device_id AND occ.observation_id = o.id
                      JOIN text_versions tv ON tv.device_id = occ.device_id AND tv.id = occ.text_version_id
                     WHERE o.device_id = ? AND o.id IN (\(marks)) AND o.deleted_at IS NULL
                     ORDER BY o.ts, occ.ord;
                    """, [.text(deviceID)] + chunk.map { SQLValue.int($0) })
            }
            return out
        }
    }

    /// 把 evidence JSON 展开成观察 id 列表（数组或 D23 的区间表示都认）。
    func evidenceObservationIDs(_ json: String) -> [Int64] {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let array = any as? [Any] else { return [] }
        var out: [Int64] = []
        for element in array {
            if let n = element as? NSNumber { out.append(n.int64Value); continue }
            if let pair = element as? [NSNumber], pair.count == 2 {
                let lo = pair[0].int64Value, hi = pair[1].int64Value
                if hi >= lo, hi - lo < 100_000 { out += Array(lo...hi) }
                continue
            }
            if let object = element as? [String: NSNumber],
               let lo = object["start"]?.int64Value, let hi = object["end"]?.int64Value,
               hi >= lo, hi - lo < 100_000 {
                out += Array(lo...hi)
            }
        }
        return out
    }

    // MARK: - 计数与探针（测试与 CLI 用）

    public func count(table: String) throws -> Int {
        // 只允许 schema 里存在的表名，防止把它当成通用 SQL 入口。
        guard Schema.expectedTables.contains(table) else {
            throw StoreError.invalidUsage("未知的表：\(table)")
        }
        return try withLock { conn in
            if table == "text_fts" { return try ftsRowCount(conn) }
            return Int(try conn.scalarInt("SELECT COUNT(*) FROM \(table);") ?? 0)
        }
    }

    public func liveObservationIDs(app bundleID: String? = nil,
                                   from start: Int64? = nil, to end: Int64? = nil) throws -> [Int64] {
        try withLock { conn in
            var sql = "SELECT o.id FROM observations o"
            var binds: [SQLValue] = []
            if bundleID != nil { sql += " JOIN apps a ON a.id = o.app_id" }
            sql += " WHERE o.device_id = ? AND o.deleted_at IS NULL"
            binds.append(.text(deviceID))
            if let bundleID { sql += " AND a.bundle_id = ?"; binds.append(.text(bundleID)) }
            if let start { sql += " AND o.ts >= ?"; binds.append(.int(start)) }
            if let end { sql += " AND o.ts < ?"; binds.append(.int(end)) }
            return try conn.intColumn(sql + " ORDER BY o.id;", binds)
        }
    }

    /// 某个文本版本还有几条 occurrence（共享版本规则的直接观察点）。
    public func occurrenceCount(textVersionID: Int64) throws -> Int {
        try withLock { conn in
            Int(try conn.scalarInt("""
                SELECT COUNT(*) FROM occurrences WHERE device_id = ? AND text_version_id = ?;
                """, [.text(deviceID), .int(textVersionID)]) ?? 0)
        }
    }

    public func textVersionExists(id: Int64) throws -> Bool {
        try withLock { conn in
            (try conn.scalarInt("SELECT COUNT(*) FROM text_versions WHERE device_id = ? AND id = ?;",
                                [.text(deviceID), .int(id)]) ?? 0) == 1
        }
    }

    /// 取一条 text_version 的正文（测试里核对复用与修改用）。
    public func textVersionText(id: Int64) throws -> String? {
        try withLock { conn in
            try conn.scalarText("SELECT text FROM text_versions WHERE device_id = ? AND id = ?;",
                                [.text(deviceID), .int(id)])
        }
    }

    /// 直接对 `text_versions` 做 UPDATE，应当被不可变触发器 ABORT。测试用。
    public func attemptTextVersionUpdate(id: Int64, newText: String) -> Bool {
        (try? withLock { conn in
            try conn.run("UPDATE text_versions SET text = ? WHERE device_id = ? AND id = ?;",
                         [.text(newText), .text(deviceID), .int(id)])
        }) != nil
    }

    /// 直接删一条还被引用的 text_version，应当被外键 RESTRICT 挡住。测试用。
    public func attemptTextVersionDelete(id: Int64) -> Bool {
        (try? withLock { conn in
            try conn.run("DELETE FROM text_versions WHERE device_id = ? AND id = ?;",
                         [.text(deviceID), .int(id)])
        }) != nil
    }

    public func deletionRows() throws -> [(id: Int64, kind: String, reason: String, params: String,
                                           observations: Int, ftsRows: Int, bytes: Int)] {
        try withLock { conn in
            let st = try conn.prepare("""
                SELECT id, kind, reason, params, observations_affected, fts_rows_deleted, bytes_freed
                  FROM deletions WHERE device_id = ? ORDER BY id;
                """)
            defer { st.finalize() }
            try st.bind([.text(deviceID)])
            var out: [(Int64, String, String, String, Int, Int, Int)] = []
            while try st.step() {
                out.append((st.int(0) ?? 0, st.text(1) ?? "", st.text(2) ?? "", st.text(3) ?? "",
                            Int(st.int(4) ?? 0), Int(st.int(5) ?? 0), Int(st.int(6) ?? 0)))
            }
            return out
        }
    }

    public func staleFlags(table: String) throws -> [(id: Int64, stale: Bool)] {
        guard table == "sessions" || table == "ledgers" else {
            throw StoreError.invalidUsage("只支持 sessions / ledgers")
        }
        return try withLock { conn in
            let st = try conn.prepare("SELECT id, stale FROM \(table) WHERE device_id = ? ORDER BY id;")
            defer { st.finalize() }
            try st.bind([.text(deviceID)])
            var out: [(Int64, Bool)] = []
            while try st.step() { out.append((st.int(0) ?? 0, (st.int(1) ?? 0) == 1)) }
            return out
        }
    }
}
