import Foundation

extension Store {

    // MARK: - 对外的四个删除入口（3.8「用户主动删除」）

    /// 按应用删除（3.12 改档时也走它）。
    @discardableResult
    public func deleteByApp(bundleID: String,
                            start: Int64? = nil,
                            end: Int64? = nil,
                            reason: DeletionReason = .user) throws -> DeletionSummary {
        try withLock { conn in
            var sql = """
                SELECT o.id FROM observations o JOIN apps a ON a.id = o.app_id
                 WHERE o.device_id = ? AND a.bundle_id = ? AND o.deleted_at IS NULL
                """
            var binds: [SQLValue] = [.text(deviceID), .text(bundleID)]
            if let start { sql += " AND o.ts >= ?"; binds.append(.int(start)) }
            if let end { sql += " AND o.ts < ?"; binds.append(.int(end)) }
            let ids = try conn.intColumn(sql + " ORDER BY o.id;", binds)
            var params: [String: Any] = ["bundle_id": bundleID]
            if let start { params["start"] = start }
            if let end { params["end"] = end }
            return try conn.transaction {
                try userDelete(observationIDs: ids, kind: .app, reason: reason,
                               params: params, conn: conn)
            }
        }
    }

    /// 按时间段删除（半开区间 `[start, end)`）。
    @discardableResult
    public func deleteByTimeRange(start: Int64, end: Int64,
                                  reason: DeletionReason = .user) throws -> DeletionSummary {
        guard start < end else { throw StoreError.invalidUsage("时间区间要求 start < end") }
        return try withLock { conn in
            let ids = try conn.intColumn("""
                SELECT id FROM observations
                 WHERE device_id = ? AND ts >= ? AND ts < ? AND deleted_at IS NULL ORDER BY id;
                """, [.text(deviceID), .int(start), .int(end)])
            return try conn.transaction {
                try userDelete(observationIDs: ids, kind: .range, reason: reason,
                               params: ["start": start, "end": end], conn: conn)
            }
        }
    }

    /// 删除对象所指的观察。三种对象各选一个：URL（按 host 或 canonical 前缀）、文件路径、窗口标题。
    public enum DeletionObject: Sendable {
        case host(String)                  // urls.host 等值
        case urlPrefix(String)             // urls.canonical_url 前缀
        case rawLocator(String)            // urls.raw_locator 等值
        case filePath(String)              // files.path 等值
        case filePathPrefix(String)        // files.path 前缀（整个目录）
        case windowTitle(String)           // windows.title 等值
    }

    @discardableResult
    public func deleteByObject(_ object: DeletionObject,
                               reason: DeletionReason = .user) throws -> DeletionSummary {
        try withLock { conn in
            let (sql, binds, params) = objectQuery(object)
            let ids = try conn.intColumn(sql, binds)
            return try conn.transaction {
                try userDelete(observationIDs: ids, kind: .object, reason: reason,
                               params: params, conn: conn)
            }
        }
    }

    private func objectQuery(_ object: DeletionObject) -> (String, [SQLValue], [String: Any]) {
        // 两步式在这里没必要（删除本来就要全量取 id），但谓词都走索引列。
        switch object {
        case .host(let h):
            return ("""
                SELECT o.id FROM observations o JOIN urls u ON u.id = o.url_id
                 WHERE o.device_id = ? AND u.host = ? AND o.deleted_at IS NULL ORDER BY o.id;
                """, [.text(deviceID), .text(h)], ["host": h])
        case .urlPrefix(let p):
            return ("""
                SELECT o.id FROM observations o JOIN urls u ON u.id = o.url_id
                 WHERE o.device_id = ? AND u.canonical_url LIKE ? ESCAPE '\\'
                   AND o.deleted_at IS NULL ORDER BY o.id;
                """, [.text(deviceID), .text(likePrefix(p))], ["url_prefix": p])
        case .rawLocator(let r):
            return ("""
                SELECT o.id FROM observations o JOIN urls u ON u.id = o.url_id
                 WHERE o.device_id = ? AND u.raw_locator = ? AND o.deleted_at IS NULL ORDER BY o.id;
                """, [.text(deviceID), .text(r)], ["raw_locator": r])
        case .filePath(let p):
            return ("""
                SELECT o.id FROM observations o JOIN files f ON f.id = o.file_id
                 WHERE o.device_id = ? AND f.path = ? AND o.deleted_at IS NULL ORDER BY o.id;
                """, [.text(deviceID), .text(p)], ["file_path": p])
        case .filePathPrefix(let p):
            return ("""
                SELECT o.id FROM observations o JOIN files f ON f.id = o.file_id
                 WHERE o.device_id = ? AND f.path LIKE ? ESCAPE '\\'
                   AND o.deleted_at IS NULL ORDER BY o.id;
                """, [.text(deviceID), .text(likePrefix(p))], ["file_path_prefix": p])
        case .windowTitle(let t):
            return ("""
                SELECT o.id FROM observations o JOIN windows w ON w.id = o.window_id
                 WHERE o.device_id = ? AND w.title = ? AND o.deleted_at IS NULL ORDER BY o.id;
                """, [.text(deviceID), .text(t)], ["window_title": t])
        }
    }

    private func likePrefix(_ p: String) -> String {
        p.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    /// 直接按 observation id 删除。
    @discardableResult
    public func deleteObservations(_ ids: [Int64],
                                   reason: DeletionReason = .user) throws -> DeletionSummary {
        try withLock { conn in
            try conn.transaction {
                try userDelete(observationIDs: ids, kind: .observation, reason: reason,
                               params: ["ids": ids], conn: conn)
            }
        }
    }

    // MARK: - 用户删除引擎

    /// 级联顺序按 3.8 写死：
    /// observation（打墓碑）→ occurrences → 无剩余引用的 text_version → FTS 行
    /// → sessions / ledgers 标 stale → 缩略图 → deletions 审计行。
    ///
    /// 用户删除**保留** observations 行并写 `deleted_at` 墓碑：审计要用，D17 的同步也要靠它
    /// 在另一台机器上重放同一次删除。
    func userDelete(observationIDs ids: [Int64], kind: DeletionKind, reason: DeletionReason,
                    params: [String: Any], conn: SQLiteConnection) throws -> DeletionSummary {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let ftsBefore = try ftsRowCount(conn)

        var obsMarked = 0
        var occDeleted = 0
        var tvDeleted = 0
        var bytesFreed = 0
        var thumbsDeleted = 0
        var sessionsStale = 0
        var ledgersStale = 0
        var chunksDeleted = 0

        if !ids.isEmpty {
            for chunk in ids.chunked(into: 400) {
                let marks = placeholders(chunk.count)
                let binds: [SQLValue] = [.text(deviceID)] + chunk.map { SQLValue.int($0) }

                // 受影响的文本版本候选（删 occurrence 之前先取，之后就查不到了）
                let candidates = try conn.intColumn("""
                    SELECT DISTINCT text_version_id FROM occurrences
                     WHERE device_id = ? AND observation_id IN (\(marks));
                    """, binds)
                // 缩略图路径
                let thumbs = try conn.textColumn("""
                    SELECT thumb_ref FROM observations
                     WHERE device_id = ? AND id IN (\(marks)) AND thumb_ref IS NOT NULL;
                    """, binds)

                // 1) observation：打墓碑，清 thumb_ref
                obsMarked += try conn.run("""
                    UPDATE observations SET deleted_at = ?, thumb_ref = NULL
                     WHERE device_id = ? AND id IN (\(marks)) AND deleted_at IS NULL;
                    """, [.int(ts), .text(deviceID)] + chunk.map { SQLValue.int($0) })
                // 2) occurrences
                occDeleted += try conn.run("""
                    DELETE FROM occurrences WHERE device_id = ? AND observation_id IN (\(marks));
                    """, binds)
                // 3) 无剩余引用的 text_version（+ 4) FTS 行 + v4 的 chunks / vec_chunks，
                //    都在同一个函数里显式删）
                let swept = try sweepOrphanVersions(candidates, conn: conn)
                tvDeleted += swept.deleted
                bytesFreed += swept.bytes
                chunksDeleted += swept.chunks
                // 6) 缩略图文件
                thumbsDeleted += removeThumbnails(thumbs)
            }
            // 5) 派生结果标 stale
            let stale = try markDerivedStale(ids, conn: conn)
            sessionsStale = stale.sessions
            ledgersStale = stale.ledgers
        }

        let ftsDeleted = ftsBefore - (try ftsRowCount(conn))

        // 7) 审计行
        let deletionID = counters.deletion
        counters.deletion += 1
        // D17 / 3.9：用户删除要能在另一台机器上作用于**同一批记录**，所以把目标按来源设备
        // 分组、区间压缩后写进 `targets`（schema v5 的新列）。只有 `reason = 'user'` 写它——
        // 配额过期是本机策略，不同步（3.8）。`targets` 在这里算，是因为再往后 `ids` 里
        // 那些观察的 origin 列还在（墓碑只改 deleted_at，不删行）。
        let targets = reason == .user ? try syncTargets(for: ids, conn: conn) : nil
        try conn.run("""
            INSERT INTO deletions(device_id, id, kind, reason, params, applied_at,
                                  observations_affected, occurrences_deleted, text_versions_deleted,
                                  fts_rows_deleted, sessions_stale, ledgers_stale,
                                  thumbs_deleted, bytes_freed, targets)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [
                .text(deviceID), .int(deletionID), .text(kind.rawValue), .text(reason.rawValue),
                .text(try jsonObject(params)), .int(ts),
                .int(Int64(obsMarked)), .int(Int64(occDeleted)), .int(Int64(tvDeleted)),
                .int(Int64(ftsDeleted)), .int(Int64(sessionsStale)), .int(Int64(ledgersStale)),
                .int(Int64(thumbsDeleted)), .int(Int64(bytesFreed)), .optionalText(targets),
            ])
        try persistCounters()

        return DeletionSummary(deletionID: deletionID, kind: kind, reason: reason,
                               observationsAffected: obsMarked, occurrencesDeleted: occDeleted,
                               textVersionsDeleted: tvDeleted, ftsRowsDeleted: ftsDeleted,
                               sessionsStale: sessionsStale, ledgersStale: ledgersStale,
                               thumbsDeleted: thumbsDeleted, bytesFreed: bytesFreed,
                               chunksDeleted: chunksDeleted)
    }

    // MARK: - 配额过期（3.8「自动过期」）

    /// 配额过期：最旧先删，**物理删行**（真正回收空间），只记一条区间审计（`reason = 'quota'`）。
    ///
    /// 与用户删除的语义差别（3.8）：
    /// - observations 行物理删除，不留墓碑——`deletions` 审计行本身就是这段范围的墓碑；
    /// - 因为配额是**本机策略**，这条审计不参与 D17 同步（另一台机器的配额可以不一样）；
    /// - occurrences 随外键 `ON DELETE CASCADE` 自动删。
    ///
    /// - Parameter toBytes: 目标原文净载荷字节；nil 用 `options.quotaBytes`（默认 10 GiB = 10 × 2^30）。
    @discardableResult
    public func expire(toBytes: Int? = nil, batchSize: Int = 200) throws -> ExpireReport {
        let quota = toBytes ?? options.quotaBytes
        return try withLock { conn in
            let before = try contentBytes(conn)
            let warn = Double(before) >= Double(quota) * options.quotaWarnRatio
            if warn { quotaWarningHandler?(before, quota) }
            guard before > quota else {
                return ExpireReport(quotaBytes: quota, beforeBytes: before, afterBytes: before,
                                    warningThresholdCrossed: warn, summary: nil,
                                    oldestDeletedTS: nil, newestDeletedTS: nil, batches: 0)
            }
            return try conn.transaction {
                try expireUnlocked(quota: quota, before: before, warn: warn,
                                   batchSize: batchSize, conn: conn)
            }
        }
    }

    private func expireUnlocked(quota: Int, before: Int, warn: Bool,
                                batchSize: Int, conn: SQLiteConnection) throws -> ExpireReport {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let ftsBefore = try ftsRowCount(conn)
        var remaining = before
        var obsDeleted = 0
        var occDeleted = 0
        var tvDeleted = 0
        var bytesFreed = 0
        var thumbsDeleted = 0
        var sessionsStale = 0
        var ledgersStale = 0
        var chunksDeleted = 0
        var batches = 0
        var oldestTS: Int64?
        var newestTS: Int64?

        while remaining > quota {
            let st = try conn.prepare("""
                SELECT id, ts, thumb_ref FROM observations
                 WHERE device_id = ? ORDER BY ts, id LIMIT ?;
                """)
            try st.bind([.text(deviceID), .int(Int64(batchSize))])
            var ids: [Int64] = []
            var thumbs: [String] = []
            while try st.step() {
                let id = st.int(0) ?? 0
                ids.append(id)
                let t = st.int(1) ?? 0
                if oldestTS == nil { oldestTS = t }
                newestTS = t
                if let ref = st.text(2) { thumbs.append(ref) }
            }
            st.finalize()
            if ids.isEmpty { break }

            let marks = placeholders(ids.count)
            let binds: [SQLValue] = [.text(deviceID)] + ids.map { SQLValue.int($0) }
            let candidates = try conn.intColumn("""
                SELECT DISTINCT text_version_id FROM occurrences
                 WHERE device_id = ? AND observation_id IN (\(marks));
                """, binds)
            let occCount = Int(try conn.scalarInt("""
                SELECT COUNT(*) FROM occurrences
                 WHERE device_id = ? AND observation_id IN (\(marks));
                """, binds) ?? 0)

            thumbsDeleted += removeThumbnails(thumbs)
            // occurrences 随 ON DELETE CASCADE 走
            obsDeleted += try conn.run("""
                DELETE FROM observations WHERE device_id = ? AND id IN (\(marks));
                """, binds)
            occDeleted += occCount
            let swept = try sweepOrphanVersions(candidates, conn: conn)
            tvDeleted += swept.deleted
            bytesFreed += swept.bytes
            chunksDeleted += swept.chunks
            let stale = try markDerivedStale(ids, conn: conn)
            sessionsStale += stale.sessions
            ledgersStale += stale.ledgers
            remaining -= swept.bytes
            batches += 1
        }

        let ftsDeleted = ftsBefore - (try ftsRowCount(conn))
        let deletionID = counters.deletion
        counters.deletion += 1
        var params: [String: Any] = [
            "policy": "oldest_first", "target_bytes": quota, "batches": batches,
            "device_id": deviceID, "synced": false,
        ]
        if let oldestTS { params["ts_from"] = oldestTS }
        if let newestTS { params["ts_to"] = newestTS }
        try conn.run("""
            INSERT INTO deletions(device_id, id, kind, reason, params, applied_at,
                                  observations_affected, occurrences_deleted, text_versions_deleted,
                                  fts_rows_deleted, sessions_stale, ledgers_stale,
                                  thumbs_deleted, bytes_freed)
            VALUES (?,?,'range','quota',?,?,?,?,?,?,?,?,?,?);
            """, [
                .text(deviceID), .int(deletionID), .text(try jsonObject(params)), .int(ts),
                .int(Int64(obsDeleted)), .int(Int64(occDeleted)), .int(Int64(tvDeleted)),
                .int(Int64(ftsDeleted)), .int(Int64(sessionsStale)), .int(Int64(ledgersStale)),
                .int(Int64(thumbsDeleted)), .int(Int64(bytesFreed)),
            ])
        try persistCounters()

        let summary = DeletionSummary(deletionID: deletionID, kind: .range, reason: .quota,
                                      observationsAffected: obsDeleted, occurrencesDeleted: occDeleted,
                                      textVersionsDeleted: tvDeleted, ftsRowsDeleted: ftsDeleted,
                                      sessionsStale: sessionsStale, ledgersStale: ledgersStale,
                                      thumbsDeleted: thumbsDeleted, bytesFreed: bytesFreed,
                                      chunksDeleted: chunksDeleted)
        return ExpireReport(quotaBytes: quota, beforeBytes: before, afterBytes: remaining,
                            warningThresholdCrossed: warn, summary: summary,
                            oldestDeletedTS: oldestTS, newestDeletedTS: newestTS, batches: batches)
    }

    // MARK: - 共用小件

    /// 删掉候选里已经没有任何 occurrence 的文本版本，并**显式**删对应的 FTS 行（D22：没有触发器）
    /// 与向量行（v4：`vec_chunks` 是 `vec0` 虚拟表，外键管不到它）。
    ///
    /// v4 起的级联顺序：`chunks` 靠外键 `ON DELETE CASCADE` 跟着 `text_versions` 走，
    /// 但要**先**把这些块的 `vrow` 取出来删 `vec_chunks`——否则块行没了就再也找不到向量行，
    /// 留下一批永远查得到、却指向不存在的块的向量（`integrityReport` 里那两项就是钉这个的）。
    func sweepOrphanVersions(_ candidates: [Int64], conn: SQLiteConnection) throws
        -> (deleted: Int, bytes: Int, chunks: Int) {
        var deleted = 0
        var bytes = 0
        var chunksDeleted = 0
        for tvID in candidates.sorted() {
            let left = try conn.scalarInt("""
                SELECT COUNT(*) FROM occurrences WHERE device_id = ? AND text_version_id = ?;
                """, [.text(deviceID), .int(tvID)]) ?? 0
            if left > 0 { continue }
            let st = try conn.prepare(
                "SELECT vrow, byte_len FROM text_versions WHERE device_id = ? AND id = ?;")
            try st.bind([.text(deviceID), .int(tvID)])
            guard try st.step(), let vrow = st.int(0) else { st.finalize(); continue }
            let byteLen = Int(st.int(1) ?? 0)
            st.finalize()
            // 先清向量行（虚拟表没有外键），再删版本让 chunks 随 CASCADE 走。
            let chunkRows = try conn.intColumn("""
                SELECT vrow FROM chunks WHERE device_id = ? AND text_version_id = ?;
                """, [.text(deviceID), .int(tvID)])
            for chunkVRow in chunkRows {
                try conn.run("DELETE FROM vec_chunks WHERE chunk_rowid = ?;", [.int(chunkVRow)])
            }
            chunksDeleted += chunkRows.count
            try conn.run("DELETE FROM text_versions WHERE device_id = ? AND id = ?;",
                         [.text(deviceID), .int(tvID)])
            try conn.run("DELETE FROM text_fts WHERE rowid = ?;", [.int(vrow)])
            deleted += 1
            bytes += byteLen
        }
        return (deleted, bytes, chunksDeleted)
    }

    /// 派生结果只要证据命中被删观察就标 `stale` 待重算（3.8）。
    ///
    /// `sessions.evidence` 是观察 id 数组；`ledgers.evidence` 按 D23 用**区间**表示
    /// （`[[lo, hi], …]`），两种形状都认。
    func markDerivedStale(_ deletedIDs: [Int64], conn: SQLiteConnection) throws -> (sessions: Int, ledgers: Int) {
        let target = Set(deletedIDs)
        guard !target.isEmpty else { return (0, 0) }
        var counts = (sessions: 0, ledgers: 0)
        for table in ["sessions", "ledgers"] {
            let st = try conn.prepare("SELECT id, evidence FROM \(table) WHERE device_id = ? AND stale = 0;")
            try st.bind([.text(deviceID)])
            var hits: [Int64] = []
            while try st.step() {
                guard let id = st.int(0), let evidence = st.text(1) else { continue }
                if evidenceIntersects(evidence, target) { hits.append(id) }
            }
            st.finalize()
            for id in hits {
                try conn.run("UPDATE \(table) SET stale = 1 WHERE device_id = ? AND id = ?;",
                             [.text(deviceID), .int(id)])
            }
            if table == "sessions" { counts.sessions = hits.count } else { counts.ledgers = hits.count }
        }
        return counts
    }

    func evidenceIntersects(_ json: String, _ deleted: Set<Int64>) -> Bool {
        guard let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let array = any as? [Any] else { return false }
        for element in array {
            if let n = element as? NSNumber, deleted.contains(n.int64Value) { return true }
            // D23：ledgers.evidence 用区间表示，[[lo, hi], …]
            if let pair = element as? [NSNumber], pair.count == 2 {
                let lo = pair[0].int64Value, hi = pair[1].int64Value
                if deleted.contains(where: { $0 >= lo && $0 <= hi }) { return true }
            }
            if let object = element as? [String: NSNumber],
               let lo = object["start"]?.int64Value, let hi = object["end"]?.int64Value {
                if deleted.contains(where: { $0 >= lo && $0 <= hi }) { return true }
            }
        }
        return false
    }

    func removeThumbnails(_ refs: [String]) -> Int {
        let fm = FileManager.default
        var n = 0
        for ref in refs where !ref.isEmpty {
            let path = thumbnailDirectory.appendingPathComponent(ref, isDirectory: false)
            if fm.fileExists(atPath: path.path), (try? fm.removeItem(at: path)) != nil { n += 1 }
        }
        return n
    }

    /// FTS 行数。contentless 表不能全表扫描，只能数它的 docsize 影子表。
    func ftsRowCount(_ conn: SQLiteConnection) throws -> Int {
        Int(try conn.scalarInt("SELECT COUNT(*) FROM text_fts_docsize;") ?? 0)
    }

    /// 配额口径：原文净载荷（UTF-8 字节），与 2.4 的"原文"一栏一致。
    func contentBytes(_ conn: SQLiteConnection) throws -> Int {
        Int(try conn.scalarInt("SELECT COALESCE(SUM(byte_len),0) FROM text_versions WHERE device_id = ?;",
                               [.text(deviceID)]) ?? 0)
    }

    func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    func jsonObject(_ params: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
