import Foundation

// =============================================================================
// 3.8「加密导出另有独立口令；删除不能覆盖已导出的副本」+ D7「满后最旧先删且删前通知并可
// 先加密导出」的**库侧**：取数、落库、配额联动。
//
// 文件格式与加密在 ExportArchive.swift / ExportKeyring.swift；那两个文件一行 SQL 都没有，
// 这个文件一个字节的密文都不碰。
//
// -------------------------------------------------------------------------
// 导出期间库照常可用：分段读 + 起始水位线，**不是**快照事务
// -------------------------------------------------------------------------
// `Store` 是单连接 + 一把 `NSLock`，所有公开方法串行。如果导出开一个长读事务，
// 1 个月库要读上几十秒，这段时间采集端一条都写不进来（3.5 的"锁定即暂停"是另一回事，
// 这里库是开着的，只是被占住）。
//
// 所以导出**不开长事务**：
//   1. 开头取一次锁，记下 `MAX(observations.id)` 作为一致性边界（写进 manifest 的
//      `scope.max_observation_id`）；
//   2. 之后每次只取一小批（默认 200 条观察）就放锁，加密与落盘都在锁外做；
//   3. 只导 `id ≤ 边界` 的行。
//
// 于是归档是库的一个**前缀**：导出开始之后写进来的观察不在里面。这是有意的，
// 而且是可核对的——边界写在 manifest 里。反过来，"导出期间正好被删掉的观察"会以
// 已删除的样子（或者根本没被读到）落进归档，这也是前缀语义的一部分。
//
// -------------------------------------------------------------------------
// 导出什么、不导出什么
// -------------------------------------------------------------------------
// 导出：`observations`（含用户删除的墓碑行）、`text_versions`、`occurrences`、
//       `deletions`、`sessions`、`ledgers`，可选 `app_policies` 与运行期事件。
//
// **不导出**，各有各的理由：
//
// | 不导出 | 理由 |
// |---|---|
// | `capture_audit` / `capture_stats` | 本机采集质量的度量，不是证据；恢复到另一台机器上没有意义（3.3） |
// | `mcp_audit` | 授权与访问审计，里面有客户端 id 与对端签名信息。归档是要拿出机器的东西，把访问审计一起带走只会扩大敏感面而不增加证据价值（3.6） |
// | `grants` | 3.9 的同一条：各机独立的可变配置 |
// | `sync_state` / `sync_peers` | 同上，而且 `sync_state` 里存着**同步密钥**——它绝不能进用另一把口令保护的归档 |
// | `chunks` / `vec_chunks` | 本机派生数据，删了能重建（v4 的口径），带走只是白白让归档变大 |
// | 缩略图文件 | D10 默认关；归档只装库里的行 |
//
// 脱敏（3.3 / 2.2）**照常生效但不额外做**：正文在入库前就已经过 app 的 `Redactor`，
// 库里存的就是脱敏后的那一份，归档原样搬——不做二次脱敏、也不还原。
// =============================================================================

/// `export_imports` 的一行（`brosis-store` 与窗口用）。
public struct ExportImportRecord: Sendable, Codable {
    public var archiveID: String
    public var sourceDevice: String
    public var createdAt: Int64
    public var mode: String
    public var blocks: Int
    public var startedAt: Int64
    public var finishedAt: Int64?
    public var observations: Int

    enum CodingKeys: String, CodingKey {
        case mode, blocks, observations
        case archiveID = "archive_id"
        case sourceDevice = "source_device"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

extension Store {

    // MARK: - 导出

    /// 把库（或库的一段）导成一份加密归档。
    ///
    /// - Parameters:
    ///   - root: 归档目录。必须不存在或为空——归档写一次不改。
    ///   - passphrase: **独立口令**，与库密钥、同步密钥都无关；强度门槛见 `ExportKeyring`。
    ///   - request: 时间范围、应用范围与两个可选项。
    ///   - progress: 每写完一块回调一次（UI 进度条）。
    @discardableResult
    public func exportArchive(to root: URL,
                              passphrase: String,
                              request: ExportRequest = ExportRequest(),
                              now: Date = Date(),
                              progress: ((ExportProgress) -> Void)? = nil) throws -> ExportOutcome {
        let t0 = Date()
        if let start = request.start, let end = request.end, start >= end {
            throw ExportError.invalidRequest("时间区间要求 start < end")
        }
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)

        // ① 一致性边界：只取一次锁。
        let bounds = try withLock { conn -> (obs: Int64, del: Int64) in
            let obs = try conn.scalarInt(
                "SELECT COALESCE(MAX(id), 0) FROM observations WHERE device_id = ?;",
                [.text(deviceID)]) ?? 0
            let del = try conn.scalarInt("SELECT COALESCE(MAX(id), 0) FROM deletions;") ?? 0
            return (obs, del)
        }

        let appFilter = request.apps.filter { !$0.isEmpty }
        var notes: [String] = []
        if !appFilter.isEmpty {
            notes.append("限定了应用范围，因此不导出 deletions / sessions / ledgers："
                       + "删除审计的目标是观察 id、会话与台账是整条时间线，两者都无法按应用切开"
                       + "（切开就会在导入端删掉或算错范围外的记录）")
        }
        notes.append("正文是库里那一份：入库前已按 3.3 / 2.2 脱敏，归档不做二次脱敏、也不还原")
        notes.append("不含 capture_audit / capture_stats / mcp_audit / grants / sync_state（见 core/README）")
        notes.append("删除不会影响这份归档：归档写一次不改，删库里的记录不会回头改它")

        let scope = ExportScope(start: request.start, end: request.end, apps: appFilter,
                                includePolicies: request.includePolicies,
                                includeEvents: request.includeEvents,
                                maxObservationID: bounds.obs, maxDeletionID: bounds.del)
        let writer = try ExportArchiveWriter(
            root: root, passphrase: passphrase, sourceDevice: deviceID,
            schemaVersion: Schema.version, scope: scope,
            blockPlainBytes: request.blockPlainBytes, now: nowMS)

        var counts = ExportCounts()
        var emitted = Set<String>()             // 已经写进归档的正文 sha（归档内全局去重）
        var cursor: Int64 = 0
        let batch = max(1, request.batchObservations)

        // ② 观察 + 正文：每批取一次锁，加密与落盘在锁外。
        while true {
            let rows = try withLock { conn in
                try readObservationBatch(conn: conn, after: cursor, limit: batch,
                                         maxID: bounds.obs, start: request.start,
                                         end: request.end, apps: appFilter)
            }
            if rows.isEmpty { break }
            for row in rows {
                for text in row.texts where !emitted.contains(text.sha) {
                    emitted.insert(text.sha)
                    try writer.append(.text, text)
                    counts.textVersions += 1
                    counts.textPayloadBytes += text.len
                }
                try writer.append(.observation, row.observation)
                counts.observations += 1
                if row.observation.deletedAt != nil { counts.tombstonedObservations += 1 }
                counts.occurrences += row.observation.texts.count
                cursor = max(cursor, row.observation.id)
            }
            progress?(ExportProgress(observationsWritten: counts.observations,
                                     blocksWritten: writer.blockCount,
                                     bytesWritten: writer.bytesWritten))
        }

        // ③ 删除审计（3.8）。放在观察之后：合并模式的级联要作用在**已经导进去的**记录上。
        if appFilter.isEmpty {
            let deletions = try withLock { conn in
                try readDeletions(conn: conn, start: request.start, end: request.end,
                                  maxAppliedAt: nowMS)
            }
            for record in deletions {
                try writer.append(.deletion, record)
                counts.deletions += 1
            }

            // ④ 派生结果：会话与台账。
            let sessions = try withLock { conn in
                try readSessions(conn: conn, start: request.start, end: request.end)
            }
            for record in sessions {
                try writer.append(.session, record)
                counts.sessions += 1
            }
            let ledgers = try withLock { conn in
                try readLedgers(conn: conn, start: request.start, end: request.end)
            }
            for record in ledgers {
                try writer.append(.ledger, record)
                counts.ledgers += 1
            }
        }

        // ⑤ 两个可选项。
        if request.includePolicies {
            let policies = try withLock { conn in try readPolicies(conn: conn) }
            for record in policies {
                try writer.append(.policy, record)
                counts.appPolicies += 1
            }
        }
        if request.includeEvents {
            let events = try withLock { conn in
                try readEvents(conn: conn, start: request.start, end: request.end)
            }
            for record in events {
                try writer.append(.event, record)
                counts.events += 1
            }
        }

        let manifest = try writer.finish(counts: counts, notes: notes)
        progress?(ExportProgress(observationsWritten: counts.observations,
                                 blocksWritten: writer.blockCount,
                                 bytesWritten: writer.bytesWritten))

        let archiveBytes = ExportArchive.archiveBytes(root: root, manifest: manifest)
        // 事件（3.8：导出成功写 `export_completed`，范围、记录数、字节数、目标目录，**不含口令**）。
        let detail = "archive=\(manifest.archiveID) dir=\(root.path)"
            + " scope=\(scopeLabel(request))"
            + " observations=\(counts.observations) tombstones=\(counts.tombstonedObservations)"
            + " text_versions=\(counts.textVersions) occurrences=\(counts.occurrences)"
            + " deletions=\(counts.deletions) sessions=\(counts.sessions)"
            + " ledgers=\(counts.ledgers) policies=\(counts.appPolicies) events=\(counts.events)"
            + " payload_bytes=\(counts.textPayloadBytes) archive_bytes=\(archiveBytes)"
            + " blocks=\(manifest.blocks.count)"
        _ = try? recordRuntimeEvent(kind: "export_completed", detail: detail, at: nowMS)
        try withLock { conn in
            try conn.transaction {
                try setMeta(SchemaV8.MetaKey.lastExportAt, String(nowMS), conn: conn)
                try setMeta(SchemaV8.MetaKey.lastExportArchive, manifest.archiveID, conn: conn)
            }
        }

        return ExportOutcome(archiveID: manifest.archiveID, directory: root.path, counts: counts,
                             blocks: manifest.blocks.count, archiveBytes: archiveBytes,
                             plainBytes: writer.plainBytesWritten,
                             elapsedMS: Date().timeIntervalSince(t0) * 1000,
                             eventDetail: detail)
    }

    private func scopeLabel(_ request: ExportRequest) -> String {
        var parts: [String] = []
        parts.append(request.start.map { "start=\($0)" } ?? "start=-")
        parts.append(request.end.map { "end=\($0)" } ?? "end=-")
        parts.append("apps=\(request.apps.isEmpty ? "*" : String(request.apps.count))")
        return parts.joined(separator: ",")
    }

    // MARK: - 导出的六条取数

    private struct ObservationRow {
        var observation: ExportObservationRecord
        var texts: [ExportTextRecord]
    }

    private func readObservationBatch(conn: SQLiteConnection, after cursor: Int64, limit: Int,
                                      maxID: Int64, start: Int64?, end: Int64?,
                                      apps: [String]) throws -> [ObservationRow] {
        var sql = """
            SELECT o.id, o.ts, o.display_id, a.bundle_id, a.name, w.title,
                   u.raw_locator, u.canonical_url, u.host, u.kind, f.path,
                   o."trigger", o.capture_method, o.completeness, o.visible_range,
                   o.source_state, o.frame_hash, o.deleted_at, o.origin_device, o.origin_id
              FROM observations o
              LEFT JOIN apps    a ON a.id = o.app_id
              LEFT JOIN windows w ON w.id = o.window_id
              LEFT JOIN urls    u ON u.id = o.url_id
              LEFT JOIN files   f ON f.id = o.file_id
             WHERE o.device_id = ? AND o.id > ? AND o.id <= ?
            """
        var binds: [SQLValue] = [.text(deviceID), .int(cursor), .int(maxID)]
        if let start { sql += " AND o.ts >= ?"; binds.append(.int(start)) }
        if let end { sql += " AND o.ts < ?"; binds.append(.int(end)) }
        if !apps.isEmpty {
            sql += " AND a.bundle_id IN (\(placeholders(apps.count)))"
            binds.append(contentsOf: apps.map { SQLValue.text($0) })
        }
        sql += " ORDER BY o.id LIMIT ?;"
        binds.append(.int(Int64(limit)))

        let st = try conn.prepare(sql)
        try st.bind(binds)
        var records: [ExportObservationRecord] = []
        while try st.step() {
            let url: ExportURLRecord? = st.text(6).map {
                ExportURLRecord(raw: $0, canonical: st.text(7) ?? $0,
                                host: st.text(8), kind: st.text(9) ?? "other")
            }
            records.append(ExportObservationRecord(
                id: st.int(0) ?? 0, ts: st.int(1) ?? 0, display: st.int(2),
                bundle: st.text(3), appName: st.text(4), title: st.text(5),
                url: url, path: st.text(10),
                trigger: st.text(11) ?? "manual", method: st.text(12) ?? "ax",
                completeness: st.text(13) ?? "partial", visible: st.text(14),
                state: st.text(15) ?? "ok", frame: st.text(16), deletedAt: st.int(17),
                originDevice: st.text(18), originID: st.int(19), texts: []))
        }
        st.finalize()

        var out: [ObservationRow] = []
        out.reserveCapacity(records.count)
        // occurrence 的取数语句**一批只准备一次**，之后 reset + 重新绑定。
        // 每条观察准备一次的话，1 个月库要 25.9 万次 `sqlite3_prepare`——
        // 那既是时间，也是分配器里留下的一大片碎片（实测见结果文件）。
        let occ = try conn.prepare("""
            SELECT oc.ord, oc.region, oc.confidence, oc.note,
                   tv.sha256, tv.text, tv.byte_len, tv.created_at
              FROM occurrences oc
              JOIN text_versions tv
                ON tv.device_id = oc.device_id AND tv.id = oc.text_version_id
             WHERE oc.device_id = ? AND oc.observation_id = ?
             ORDER BY oc.ord;
            """)
        defer { occ.finalize() }
        for var record in records {
            var fragments: [ExportOccurrenceRecord] = []
            var texts: [ExportTextRecord] = []
            occ.reset()
            try occ.bind([.text(deviceID), .int(record.id)])
            while try occ.step() {
                guard let digest = occ.blob(4), let text = occ.text(5) else { continue }
                let sha = Self.hex(digest)
                texts.append(ExportTextRecord(sha: sha, text: text, len: Int(occ.int(6) ?? 0),
                                              at: occ.int(7) ?? 0))
                fragments.append(ExportOccurrenceRecord(sha: sha, ord: Int(occ.int(0) ?? 0),
                                                        region: occ.text(1), conf: occ.double(2),
                                                        note: occ.text(3)))
            }
            record.texts = fragments
            out.append(ObservationRow(observation: record, texts: texts))
        }
        return out
    }

    private func readDeletions(conn: SQLiteConnection, start: Int64?, end: Int64?,
                              maxAppliedAt: Int64) throws -> [ExportDeletionRecord] {
        var sql = """
            SELECT device_id, id, kind, reason, params, applied_at, targets,
                   observations_affected, occurrences_deleted, text_versions_deleted,
                   fts_rows_deleted, sessions_stale, ledgers_stale, thumbs_deleted, bytes_freed
              FROM deletions WHERE applied_at <= ?
            """
        var binds: [SQLValue] = [.int(maxAppliedAt)]
        if let start { sql += " AND applied_at >= ?"; binds.append(.int(start)) }
        if let end { sql += " AND applied_at < ?"; binds.append(.int(end)) }
        sql += " ORDER BY applied_at, device_id, id;"
        let st = try conn.prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        var out: [ExportDeletionRecord] = []
        while try st.step() {
            out.append(ExportDeletionRecord(
                device: st.text(0) ?? deviceID, id: st.int(1) ?? 0,
                kind: st.text(2) ?? "observation", reason: st.text(3) ?? "user",
                params: st.text(4) ?? "{}", appliedAt: st.int(5) ?? 0, targets: st.text(6),
                observationsAffected: Int(st.int(7) ?? 0), occurrencesDeleted: Int(st.int(8) ?? 0),
                textVersionsDeleted: Int(st.int(9) ?? 0), ftsRowsDeleted: Int(st.int(10) ?? 0),
                sessionsStale: Int(st.int(11) ?? 0), ledgersStale: Int(st.int(12) ?? 0),
                thumbsDeleted: Int(st.int(13) ?? 0), bytesFreed: Int(st.int(14) ?? 0)))
        }
        return out
    }

    private func readSessions(conn: SQLiteConnection, start: Int64?,
                             end: Int64?) throws -> [ExportSessionRecord] {
        // 会话按**开始时刻**落在范围内过滤（一条会话是一段连续时间，不切半条）。
        var sql = """
            SELECT s.id, s.start, s."end", s.display_id, a.bundle_id, s.dwell_s, s.active_s,
                   s.unknown_s, s.interruptions, s.evidence, s.stale, s.computed_at
              FROM sessions s LEFT JOIN apps a ON a.id = s.primary_app_id
             WHERE s.device_id = ?
            """
        var binds: [SQLValue] = [.text(deviceID)]
        if let start { sql += " AND s.start >= ?"; binds.append(.int(start)) }
        if let end { sql += " AND s.start < ?"; binds.append(.int(end)) }
        sql += " ORDER BY s.id;"
        let st = try conn.prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        var out: [ExportSessionRecord] = []
        while try st.step() {
            out.append(ExportSessionRecord(
                id: st.int(0) ?? 0, start: st.int(1) ?? 0, end: st.int(2) ?? 0,
                display: st.int(3), primaryApp: st.text(4),
                dwell: st.double(5) ?? 0, active: st.double(6) ?? 0, unknown: st.double(7) ?? 0,
                interruptions: Int(st.int(8) ?? 0), evidence: st.text(9) ?? "[]",
                stale: (st.int(10) ?? 0) == 1, computedAt: st.int(11) ?? 0))
        }
        return out
    }

    private func readLedgers(conn: SQLiteConnection, start: Int64?,
                            end: Int64?) throws -> [ExportLedgerRecord] {
        // 台账按 `period` 过滤：把范围两端换算成当地的日 / ISO 周标签再做字符串比较
        // （两种标签都是字典序 = 时间序）。时区用 `retrieval.timeZone`，与 3.7 台账同一个。
        let cal = PatternCalendar(retrieval.timeZone)
        var sql = "SELECT id, level, period, ledger, narrative, model, narrative_meta,"
                + " evidence, stale, computed_at FROM ledgers WHERE device_id = ?"
        var binds: [SQLValue] = [.text(deviceID)]
        if let start, let end {
            sql += " AND ((level = 'day' AND period >= ? AND period <= ?)"
                 + " OR (level = 'week' AND period >= ? AND period <= ?))"
            binds.append(.text(cal.dayString(start)))
            binds.append(.text(cal.dayString(end - 1)))
            binds.append(.text(cal.weekString(start)))
            binds.append(.text(cal.weekString(end - 1)))
        } else if let start {
            sql += " AND ((level = 'day' AND period >= ?) OR (level = 'week' AND period >= ?))"
            binds.append(.text(cal.dayString(start)))
            binds.append(.text(cal.weekString(start)))
        } else if let end {
            sql += " AND ((level = 'day' AND period <= ?) OR (level = 'week' AND period <= ?))"
            binds.append(.text(cal.dayString(end - 1)))
            binds.append(.text(cal.weekString(end - 1)))
        }
        sql += " ORDER BY id;"
        let st = try conn.prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        var out: [ExportLedgerRecord] = []
        while try st.step() {
            out.append(ExportLedgerRecord(
                id: st.int(0) ?? 0, level: st.text(1) ?? "day", period: st.text(2) ?? "",
                ledger: st.text(3) ?? "{}", narrative: st.text(4), model: st.text(5),
                narrativeMeta: st.text(6), evidence: st.text(7) ?? "[]",
                stale: (st.int(8) ?? 0) == 1, computedAt: st.int(9) ?? 0))
        }
        return out
    }

    private func readPolicies(conn: SQLiteConnection) throws -> [ExportPolicyRecord] {
        let st = try conn.prepare(
            "SELECT bundle_id, mode, source, updated_at FROM app_policies ORDER BY bundle_id;")
        defer { st.finalize() }
        var out: [ExportPolicyRecord] = []
        while try st.step() {
            out.append(ExportPolicyRecord(bundle: st.text(0) ?? "", mode: st.text(1) ?? "none",
                                          source: st.text(2) ?? "user", updatedAt: st.int(3) ?? 0))
        }
        return out
    }

    private func readEvents(conn: SQLiteConnection, start: Int64?,
                           end: Int64?) throws -> [ExportEventRecord] {
        var sql = "SELECT type, state, input_ref, output_ref, created_at, updated_at, error"
                + " FROM jobs WHERE type LIKE 'runtime_event:%'"
        var binds: [SQLValue] = []
        if let start { sql += " AND created_at >= ?"; binds.append(.int(start)) }
        if let end { sql += " AND created_at < ?"; binds.append(.int(end)) }
        sql += " ORDER BY id;"
        let st = try conn.prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        var out: [ExportEventRecord] = []
        while try st.step() {
            out.append(ExportEventRecord(type: st.text(0) ?? "", state: st.text(1) ?? "done",
                                         input: st.text(2), output: st.text(3),
                                         createdAt: st.int(4) ?? 0, updatedAt: st.int(5) ?? 0,
                                         error: st.text(6)))
        }
        return out
    }

    // MARK: - 导入

    /// 导入一份归档：到空库（恢复）或合并进现有库。
    ///
    /// -------------------------------------------------------------------------
    /// 两种模式（`mode` 不给时按目标库自动判定）
    /// -------------------------------------------------------------------------
    /// | | 恢复 `restore` | 合并 `merge` |
    /// |---|---|---|
    /// | 触发 | 目标库没有观察 / 正文 / 删除审计 / 会话 / 台账 | 其他一切情况 |
    /// | observation id | **原样写回**（源 id），来源两列照抄 | 走 T13 口径：本机新 id + `(origin_device, origin_id)`；归档来自本机自己时按源 id 写回 |
    /// | 幂等判据 | 归档粒度（`export_imports.archive_id`） | 归档粒度 + 逐条 `(origin_device, origin_id)` |
    /// | sessions / ledgers | 原样导入（evidence 里的 id 仍然对得上） | **不导**：派生结果各机自算（3.9 的同一条口径），导进来会造出没发生过的时间线 |
    /// | 运行期事件 | 原样导入 | 不导（`jobs` 没有跨库主键，重复导会翻倍） |
    /// | app_policies | 覆盖式写入（恢复的就是那台机器的配置） | 只补缺失的，不覆盖本机已有的策略 |
    /// | 用户删除墓碑 | 原样写审计行（归档里的观察本来就带着 `deleted_at`，状态已经是对的） | 写审计行**并在本机副本上重放级联**（3.8 的顺序） |
    ///
    /// **不复活已删除的记录**：目标库里已经有这条记录（哪怕只剩墓碑）就跳过。
    /// 3.8 的删除是合规动作，导入一份更早的归档不应该把它悄悄撤销。
    @discardableResult
    public func importArchive(from root: URL, passphrase: String,
                              mode requested: ExportImportMode? = nil) throws -> ExportImportStats {
        let t0 = Date()
        let manifest = try ExportArchive.readManifest(root: root)
        guard manifest.schemaVersion == Schema.version else {
            throw ExportError.schemaMismatch(found: manifest.schemaVersion,
                                             supported: Schema.version)
        }
        let reader = try ExportArchiveReader(root: root, manifest: manifest,
                                             passphrase: passphrase)

        var stats = ExportImportStats()
        stats.blocks = manifest.blocks.count

        // ① 归档粒度的幂等 + 模式判定，一次取锁定下来。
        let mode: ExportImportMode = try withLock { conn in
            if let done = try conn.scalarInt("""
                SELECT CASE WHEN finished_at IS NULL THEN 0 ELSE 1 END
                  FROM export_imports WHERE archive_id = ?;
                """, [.text(manifest.archiveID)]), done == 1 {
                stats.alreadyImported = true
                return .merge
            }
            let empty = try isEmptyForRestore(conn: conn)
            let resolved = requested ?? (empty ? .restore : .merge)
            if resolved == .restore && !empty {
                throw ExportError.invalidRequest(
                    "目标库里已经有数据，不能用恢复模式（那会把源 id 直接写进来）；用合并模式")
            }
            return resolved
        }
        if stats.alreadyImported {
            stats.mode = mode.rawValue
            stats.elapsedMS = Date().timeIntervalSince(t0) * 1000
            return stats
        }
        stats.mode = mode.rawValue

        let startedAt = Self.nowMS()
        _ = try withLock { conn in
            try conn.run("""
                INSERT INTO export_imports(archive_id, source_device, created_at, mode, blocks,
                                           started_at, finished_at, observations, stats)
                VALUES (?,?,?,?,?,?,NULL,0,NULL)
                ON CONFLICT(archive_id) DO UPDATE SET
                  mode = excluded.mode, blocks = excluded.blocks, started_at = excluded.started_at,
                  finished_at = NULL;
                """, [.text(manifest.archiveID), .text(manifest.sourceDevice),
                      .int(manifest.createdAt), .text(mode.rawValue),
                      .int(Int64(manifest.blocks.count)), .int(startedAt)])
        }

        // ② 逐块导入，**一块一个事务**：块内失败整块回滚，已提交的块留着，
        //    重跑时按归档 id 找到那一行、按逐条幂等继续（恢复模式下重跑走合并模式）。
        var carried: [String: ExportTextRecord] = [:]   // 跨块携带的正文（块边界可能切在正文与它的观察之间）
        var insertedTexts: [Int64] = []                 // 本次导入新建的正文 id，收尾时扫孤儿
        try reader.forEachBlock { _, payload in
            try withLock { conn in
                try conn.transaction {
                    for text in payload.texts { carried[text.sha] = text }
                    for record in payload.observations {
                        try importObservationRecord(record, manifest: manifest, mode: mode,
                                                    texts: &carried, inserted: &insertedTexts,
                                                    stats: &stats, conn: conn)
                    }
                    for record in payload.deletions {
                        try importDeletionRecord(record, manifest: manifest, mode: mode,
                                                 stats: &stats, conn: conn)
                    }
                    if mode == .restore {
                        for record in payload.sessions {
                            try importSessionRecord(record, manifest: manifest, stats: &stats,
                                                    conn: conn)
                        }
                        for record in payload.ledgers {
                            try importLedgerRecord(record, manifest: manifest, stats: &stats,
                                                   conn: conn)
                        }
                        for record in payload.events {
                            try conn.run("""
                                INSERT INTO jobs(type, state, input_ref, output_ref,
                                                 created_at, updated_at, error)
                                VALUES (?,?,?,?,?,?,?);
                                """, [.text(record.type), .text(record.state),
                                      .optionalText(record.input), .optionalText(record.output),
                                      .int(record.createdAt), .int(record.updatedAt),
                                      .optionalText(record.error)])
                            stats.eventsInserted += 1
                        }
                    } else {
                        stats.sessionsSkipped += payload.sessions.count
                        stats.ledgersSkipped += payload.ledgers.count
                        stats.eventsSkipped += payload.events.count
                    }
                    for record in payload.policies {
                        try importPolicyRecord(record, mode: mode, stats: &stats, conn: conn)
                    }
                    try persistCounters()
                }
            }
        }

        // ③ 收尾：把"插进来却没有任何 occurrence"的正文扫掉（观察被跳过时会出现），
        //    再补一次计数器与审计行。`sweepOrphanVersions` 会一并清 FTS 行与向量行。
        try withLock { conn in
            try conn.transaction {
                if !insertedTexts.isEmpty {
                    _ = try sweepOrphanVersions(insertedTexts, conn: conn)
                }
                if stats.sessionsInserted > 0 { try restoreSessionMeta(conn: conn) }
                try persistCounters()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let blob = (try? encoder.encode(stats)).map { String(decoding: $0, as: UTF8.self) }
                try conn.run("""
                    UPDATE export_imports SET finished_at = ?, observations = ?, stats = ?
                     WHERE archive_id = ?;
                    """, [.int(Self.nowMS()), .int(Int64(stats.observationsInserted)),
                          .optionalText(blob), .text(manifest.archiveID)])
            }
        }
        stats.elapsedMS = Date().timeIntervalSince(t0) * 1000
        _ = try? recordRuntimeEvent(
            kind: "import_completed",
            detail: "archive=\(manifest.archiveID) source=\(manifest.sourceDevice)"
                  + " mode=\(mode.rawValue) blocks=\(stats.blocks)"
                  + " observations_inserted=\(stats.observationsInserted)"
                  + " observations_skipped=\(stats.observationsSkipped)"
                  + " deletions=\(stats.deletionsInserted) sessions=\(stats.sessionsInserted)"
                  + " ledgers=\(stats.ledgersInserted)")
        return stats
    }

    /// 恢复模式导进会话之后，把 `Store+Sessions` 依赖的两个 `meta` 水位线**按导进来的行重算**。
    ///
    /// 这是 1 个月合成库上实测出来的一个洞，不是可有可无的收尾：
    /// `sessionRows` 的区间查询要给 `start` 补下界（E7 §10.3），下界用的就是
    /// `meta.sessions_max_duration_ms`。恢复出来的库只有 `sessions` 表、没有这个键，
    /// 补下界就退化成 0，于是**"起点在窗口之前、终点落在窗口里"的那条会话查不到**——
    /// 表现是日台账的 `sessions` 比源库少 1（30 天里 24 天都少 1），
    /// 而两边的 `sessions` 表逐行相同。
    ///
    /// 两个键都不进归档：它们是从行本身算得出来的派生值，存进去只会多一处要长期兼容的字段，
    /// 还可能与行不一致。`sessions_config` 一并写上，用的是**本机**的三个常量——
    /// 它只是给人看的记录，`buildSessions` 不读它。
    private func restoreSessionMeta(conn: SQLiteConnection) throws {
        let maxDuration = try conn.scalarInt("""
            SELECT COALESCE(MAX("end" - start), 0) FROM sessions WHERE device_id = ?;
            """, [.text(deviceID)]) ?? 0
        try setMeta("sessions_max_duration_ms", String(maxDuration), conn: conn)
        let watermark = try conn.scalarInt("""
            SELECT MAX(ts) FROM observations
             WHERE device_id = ? AND origin_device IS NULL AND deleted_at IS NULL;
            """, [.text(deviceID)])
        try setMeta("sessions_watermark_ts", watermark.map(String.init), conn: conn)
        try setMeta("sessions_config",
                    "maxDwellS=\(sessionConfig.maxDwellSeconds),gapS=\(sessionConfig.gapSeconds),"
                    + "interruptionS=\(sessionConfig.interruptionSeconds)", conn: conn)
    }

    /// 恢复模式的前提：库里一条证据都没有。
    private func isEmptyForRestore(conn: SQLiteConnection) throws -> Bool {
        for table in ["observations", "text_versions", "occurrences", "deletions",
                      "sessions", "ledgers"] {
            if (try conn.scalarInt("SELECT COUNT(*) FROM \(table);") ?? 0) > 0 { return false }
        }
        return true
    }

    /// 归档里某条记录的**全局身份**：来源设备 + 来源 id。
    /// 归档里已经带 origin 两列的（源库从对端导入的副本）用它自己的；其余的用归档的来源设备。
    private func identity(of record: ExportObservationRecord,
                          manifest: ExportManifest) -> (device: String, id: Int64) {
        (record.originDevice ?? manifest.sourceDevice, record.originID ?? record.id)
    }

    private func importObservationRecord(_ record: ExportObservationRecord,
                                         manifest: ExportManifest,
                                         mode: ExportImportMode,
                                         texts: inout [String: ExportTextRecord],
                                         inserted: inout [Int64],
                                         stats: inout ExportImportStats,
                                         conn: SQLiteConnection) throws {
        let who = identity(of: record, manifest: manifest)
        var localID: Int64
        var originDevice: String?
        var originID: Int64?

        switch mode {
        case .restore:
            localID = record.id
            originDevice = record.originDevice
            originID = record.originID
            counters.observation = max(counters.observation, record.id + 1)
        case .merge:
            if who.device == deviceID {
                // 归档来自**本机自己**（例如"删除前先导出，事后再合并回来"）。
                if try conn.scalarInt("""
                    SELECT id FROM observations
                     WHERE device_id = ? AND id = ? AND origin_device IS NULL;
                    """, [.text(deviceID), .int(who.id)]) != nil {
                    try countSkip(observationID: who.id, stats: &stats, conn: conn)
                    return
                }
                localID = who.id
                originDevice = nil
                originID = nil
                counters.observation = max(counters.observation, who.id + 1)
            } else {
                if try conn.scalarInt("""
                    SELECT id FROM observations WHERE origin_device = ? AND origin_id = ?;
                    """, [.text(who.device), .int(who.id)]) != nil {
                    stats.observationsSkipped += 1
                    return
                }
                localID = counters.observation
                counters.observation += 1
                originDevice = who.device
                originID = who.id
            }
        }

        let appID = try record.bundle.map {
            try upsertApp(AppRef(bundleID: $0, name: record.appName ?? $0), conn: conn)
        }
        let windowID: Int64?
        if let title = record.title, let appID {
            windowID = try upsertWindow(appID: appID, title: title, conn: conn)
        } else {
            windowID = nil
        }
        let urlID = try record.url.map {
            try upsertURL(URLRef(rawLocator: $0.raw, canonicalURL: $0.canonical, host: $0.host,
                                 kind: URLKind(rawValue: $0.kind) ?? .other), conn: conn)
        }
        let fileID = try record.path.map { try upsertFile($0, conn: conn) }

        try conn.run("""
            INSERT INTO observations
              (device_id, id, ts, display_id, app_id, window_id, url_id, file_id,
               "trigger", capture_method, completeness, visible_range, source_state,
               frame_hash, thumb_ref, deleted_at, origin_device, origin_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,?,?,?);
            """, [
                .text(deviceID), .int(localID), .int(record.ts),
                .optionalInt(record.display), .optionalInt(appID), .optionalInt(windowID),
                .optionalInt(urlID), .optionalInt(fileID),
                .text(record.trigger), .text(record.method), .text(record.completeness),
                .optionalText(record.visible), .text(record.state), .optionalText(record.frame),
                .optionalInt(record.deletedAt), .optionalText(originDevice), .optionalInt(originID),
            ])
        stats.observationsInserted += 1

        // 源库里已经删掉的观察：只落墓碑行，没有正文（3.8 的级联在源库就跑过了）。
        guard record.deletedAt == nil else { return }

        for fragment in record.texts {
            let resolved = try resolveExportText(sha: fragment.sha, texts: &texts, conn: conn)
            if resolved.isNew {
                stats.textVersionsInserted += 1
                inserted.append(resolved.id)
            } else {
                stats.textVersionsReused += 1
            }
            let occID = counters.occurrence
            counters.occurrence += 1
            try conn.run("""
                INSERT INTO occurrences
                  (device_id, id, observation_id, text_version_id, region, ord, confidence, note)
                VALUES (?,?,?,?,?,?,?,?);
                """, [
                    .text(deviceID), .int(occID), .int(localID), .int(resolved.id),
                    .optionalText(fragment.region), .int(Int64(fragment.ord)),
                    fragment.conf.map { SQLValue.double($0) } ?? .null,
                    .optionalText(fragment.note),
                ])
            stats.occurrencesInserted += 1
        }
    }

    /// 跳过一条已经在库里的观察，顺带分清"它是不是只剩墓碑了"（3.8：不复活）。
    private func countSkip(observationID: Int64, stats: inout ExportImportStats,
                           conn: SQLiteConnection) throws {
        let tombstoned = try conn.scalarInt("""
            SELECT COUNT(*) FROM observations
             WHERE device_id = ? AND id = ? AND deleted_at IS NOT NULL;
            """, [.text(deviceID), .int(observationID)]) ?? 0
        if tombstoned > 0 { stats.observationsSkippedTombstoned += 1 }
        stats.observationsSkipped += 1
    }

    /// sha → 本机 `text_versions.id`。本机已有同 sha 的正文就复用；没有就用归档里带的建。
    /// 归档里也没有 = 归档不完整，停（与 3.9 段文件的同一条判据）。
    private func resolveExportText(sha: String, texts: inout [String: ExportTextRecord],
                                   conn: SQLiteConnection) throws -> (id: Int64, isNew: Bool) {
        guard let digest = Self.data(fromHex: sha), digest.count == 32 else {
            throw ExportError.corruptBlock(seq: -1, detail: "sha 不是 32 字节十六进制")
        }
        if let existing = try conn.scalarInt("""
            SELECT id FROM text_versions WHERE device_id = ? AND sha256 = ?;
            """, [.text(deviceID), .blob(digest)]) {
            return (existing, false)
        }
        guard let record = texts[sha] else {
            throw ExportError.corruptBlock(seq: -1,
                                           detail: "归档里缺少 sha \(sha.prefix(16))… 的正文")
        }
        // 内容层校验：正文被改过一个字节（而块的校验和与 tag 又被重算过）也要拦下。
        guard TextPipeline.sha256(record.text) == digest else {
            throw ExportError.corruptBlock(seq: -1,
                                           detail: "正文与 sha \(sha.prefix(16))… 不符")
        }
        let (id, _) = try upsertTextVersion(record.text, conn: conn, createdAt: record.at)
        texts.removeValue(forKey: sha)      // 用掉就丢，跨块携带的字典不会长大
        return (id, true)
    }

    private func importDeletionRecord(_ record: ExportDeletionRecord, manifest: ExportManifest,
                                      mode: ExportImportMode, stats: inout ExportImportStats,
                                      conn: SQLiteConnection) throws {
        // 归档里 `device_id == 源设备` 的那些行，在恢复出来的库里就是"本机的删除"。
        let device = (record.device == manifest.sourceDevice) ? deviceID : record.device
        if try conn.scalarInt("SELECT 1 FROM deletions WHERE device_id = ? AND id = ?;",
                              [.text(device), .int(record.id)]) != nil {
            stats.deletionsSkipped += 1
            return
        }

        var affected = (obs: record.observationsAffected, occ: record.occurrencesDeleted,
                        tv: record.textVersionsDeleted, fts: record.ftsRowsDeleted,
                        ss: record.sessionsStale, ls: record.ledgersStale,
                        th: record.thumbsDeleted, bytes: record.bytesFreed)

        // 合并模式下，用户删除要在**本机的副本**上重放同一次级联（3.8 的顺序）；
        // 恢复模式不用：归档里的观察本来就带着 `deleted_at`，正文也早就不在归档里了。
        if mode == .merge, record.reason == DeletionReason.user.rawValue,
           let targetsJSON = record.targets {
            let localIDs = try resolveDeletionTargets(targetsJSON, manifest: manifest, conn: conn)
            let cascade = try cascadeDeletion(localIDs: localIDs, at: record.appliedAt, conn: conn)
            affected = cascade
            stats.tombstonesCascaded += cascade.obs
        }

        if device == deviceID {
            counters.deletion = max(counters.deletion, record.id + 1)
        }
        try conn.run("""
            INSERT INTO deletions(device_id, id, kind, reason, params, applied_at,
                                  observations_affected, occurrences_deleted, text_versions_deleted,
                                  fts_rows_deleted, sessions_stale, ledgers_stale,
                                  thumbs_deleted, bytes_freed, targets)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [
                .text(device), .int(record.id), .text(record.kind), .text(record.reason),
                .text(record.params), .int(record.appliedAt),
                .int(Int64(affected.obs)), .int(Int64(affected.occ)), .int(Int64(affected.tv)),
                .int(Int64(affected.fts)), .int(Int64(affected.ss)), .int(Int64(affected.ls)),
                .int(Int64(affected.th)), .int(Int64(affected.bytes)),
                .optionalText(record.targets),
            ])
        stats.deletionsInserted += 1
    }

    /// `deletions.targets`（按来源设备分组的区间）→ 本机 observation id。
    /// **按区间走 SQL，不把区间展开成数组**（与 Store+Sync 的同一条理由）。
    private func resolveDeletionTargets(_ json: String, manifest: ExportManifest,
                                        conn: SQLiteConnection) throws -> [Int64] {
        var out: [Int64] = []
        for target in Self.decodeTargets(json) {
            let device = (target.device == manifest.sourceDevice) ? deviceID : target.device
            for range in target.ranges where range.count == 2 && range[0] <= range[1] {
                if device == deviceID {
                    out.append(contentsOf: try conn.intColumn("""
                        SELECT id FROM observations
                         WHERE device_id = ? AND origin_device IS NULL AND id BETWEEN ? AND ?;
                        """, [.text(deviceID), .int(range[0]), .int(range[1])]))
                } else {
                    out.append(contentsOf: try conn.intColumn("""
                        SELECT id FROM observations
                         WHERE origin_device = ? AND origin_id BETWEEN ? AND ?;
                        """, [.text(device), .int(range[0]), .int(range[1])]))
                }
            }
        }
        return out
    }

    /// 3.8 的级联：observation 打墓碑 → occurrences → 无剩余引用的 text_version → FTS 行
    /// → sessions / ledgers 标 stale → 缩略图。
    private func cascadeDeletion(localIDs: [Int64], at ts: Int64, conn: SQLiteConnection) throws
        -> (obs: Int, occ: Int, tv: Int, fts: Int, ss: Int, ls: Int, th: Int, bytes: Int) {
        guard !localIDs.isEmpty else { return (0, 0, 0, 0, 0, 0, 0, 0) }
        let ftsBefore = try ftsRowCount(conn)
        var obsMarked = 0, occDeleted = 0, tvDeleted = 0, bytesFreed = 0, thumbsDeleted = 0
        for chunk in localIDs.chunked(into: 400) {
            let marks = placeholders(chunk.count)
            let binds: [SQLValue] = [.text(deviceID)] + chunk.map { SQLValue.int($0) }
            let candidates = try conn.intColumn("""
                SELECT DISTINCT text_version_id FROM occurrences
                 WHERE device_id = ? AND observation_id IN (\(marks));
                """, binds)
            let thumbs = try conn.textColumn("""
                SELECT thumb_ref FROM observations
                 WHERE device_id = ? AND id IN (\(marks)) AND thumb_ref IS NOT NULL;
                """, binds)
            obsMarked += try conn.run("""
                UPDATE observations SET deleted_at = ?, thumb_ref = NULL
                 WHERE device_id = ? AND id IN (\(marks)) AND deleted_at IS NULL;
                """, [.int(ts), .text(deviceID)] + chunk.map { SQLValue.int($0) })
            occDeleted += try conn.run("""
                DELETE FROM occurrences WHERE device_id = ? AND observation_id IN (\(marks));
                """, binds)
            let swept = try sweepOrphanVersions(candidates, conn: conn)
            tvDeleted += swept.deleted
            bytesFreed += swept.bytes
            thumbsDeleted += removeThumbnails(thumbs)
        }
        let stale = try markDerivedStale(localIDs, conn: conn)
        let ftsDeleted = ftsBefore - (try ftsRowCount(conn))
        return (obsMarked, occDeleted, tvDeleted, ftsDeleted, stale.sessions, stale.ledgers,
                thumbsDeleted, bytesFreed)
    }

    private func importSessionRecord(_ record: ExportSessionRecord, manifest: ExportManifest,
                                     stats: inout ExportImportStats,
                                     conn: SQLiteConnection) throws {
        if try conn.scalarInt("SELECT 1 FROM sessions WHERE device_id = ? AND id = ?;",
                              [.text(deviceID), .int(record.id)]) != nil {
            stats.sessionsSkipped += 1
            return
        }
        let appID = try record.primaryApp.map {
            try upsertApp(AppRef(bundleID: $0, name: $0), conn: conn)
        }
        try conn.run("""
            INSERT INTO sessions(device_id, id, start, "end", display_id, primary_app_id,
                                 dwell_s, active_s, unknown_s, interruptions, evidence,
                                 stale, computed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """, [
                .text(deviceID), .int(record.id), .int(record.start), .int(record.end),
                .optionalInt(record.display), .optionalInt(appID),
                .double(record.dwell), .double(record.active), .double(record.unknown),
                .int(Int64(record.interruptions)), .text(record.evidence),
                .int(record.stale ? 1 : 0), .int(record.computedAt),
            ])
        stats.sessionsInserted += 1
    }

    private func importLedgerRecord(_ record: ExportLedgerRecord, manifest: ExportManifest,
                                    stats: inout ExportImportStats,
                                    conn: SQLiteConnection) throws {
        if try conn.scalarInt("""
            SELECT 1 FROM ledgers WHERE device_id = ? AND level = ? AND period = ?;
            """, [.text(deviceID), .text(record.level), .text(record.period)]) != nil {
            stats.ledgersSkipped += 1
            return
        }
        try conn.run("""
            INSERT INTO ledgers(device_id, id, level, period, ledger, narrative, model,
                                narrative_meta, evidence, stale, computed_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?);
            """, [
                .text(deviceID), .int(record.id), .text(record.level), .text(record.period),
                .text(record.ledger), .optionalText(record.narrative), .optionalText(record.model),
                .optionalText(record.narrativeMeta), .text(record.evidence),
                .int(record.stale ? 1 : 0), .int(record.computedAt),
            ])
        stats.ledgersInserted += 1
    }

    private func importPolicyRecord(_ record: ExportPolicyRecord, mode: ExportImportMode,
                                    stats: inout ExportImportStats,
                                    conn: SQLiteConnection) throws {
        // 合并模式**不覆盖**本机策略：3.12 的采集档位是这台机器上的用户决定，
        // 一份旧归档不该把它改回去。
        let sql = mode == .restore
            ? """
              INSERT INTO app_policies(bundle_id, mode, source, updated_at) VALUES (?,?,?,?)
              ON CONFLICT(bundle_id) DO UPDATE SET mode = excluded.mode,
                source = excluded.source, updated_at = excluded.updated_at;
              """
            : """
              INSERT INTO app_policies(bundle_id, mode, source, updated_at) VALUES (?,?,?,?)
              ON CONFLICT(bundle_id) DO NOTHING;
              """
        let changed = try conn.run(sql, [.text(record.bundle), .text(record.mode),
                                         .text(record.source), .int(record.updatedAt)])
        if changed > 0 { stats.policiesInserted += 1 } else { stats.policiesSkipped += 1 }
    }

    /// 这个库导入过哪些归档（`brosis-store export-imports` 与窗口的"导入历史"）。
    public func exportImports(limit: Int = 20) throws -> [ExportImportRecord] {
        try withLock { conn in
            let st = try conn.prepare("""
                SELECT archive_id, source_device, created_at, mode, blocks, started_at,
                       finished_at, observations
                  FROM export_imports ORDER BY started_at DESC LIMIT ?;
                """)
            defer { st.finalize() }
            try st.bind([.int(Int64(limit))])
            var out: [ExportImportRecord] = []
            while try st.step() {
                out.append(ExportImportRecord(
                    archiveID: st.text(0) ?? "", sourceDevice: st.text(1) ?? "",
                    createdAt: st.int(2) ?? 0, mode: st.text(3) ?? "merge",
                    blocks: Int(st.int(4) ?? 0), startedAt: st.int(5) ?? 0,
                    finishedAt: st.int(6), observations: Int(st.int(7) ?? 0)))
            }
            return out
        }
    }

    // MARK: - 配额联动（3.8 / D7）

    /// D7 的通知内容：现在什么等级、满了会删掉哪一段、建议先导出什么范围。
    ///
    /// `wouldDeleteObservations` 是**估算**：按"平均每条观察多少字节原文"倒推要删多少条，
    /// 而不是把最旧那几万条逐条模拟一遍（那要对每条观察查一次共享正文的引用计数）。
    /// 真正删多少由 `expire()` 当场决定；这里的数字只用来写通知与建议导出范围。
    ///
    /// - Parameter recordEvent: 等级**跨档**时写一条运行期事件（同一档不会重复写）。
    /// - Parameter quota: 覆盖 `options.quotaBytes`（原文净载荷字节）。设置窗口把用户当前设的值
    ///   传进来，于是改配额不用关库重开、也不用在 `Store` 里留一份可变副本
    ///   （`expire(toBytes:)` / `expireAfterNotice(toBytes:)` 早就是这个路子）。
    public func quotaAction(now: Int64? = nil, recordEvent: Bool = true,
                            quota quotaOverride: Int? = nil) throws -> QuotaAction {
        let nowMS = now ?? Self.nowMS()
        var action: QuotaAction = try withLock { conn in
            let used = try contentBytes(conn)
            let quota = max(1, quotaOverride ?? options.quotaBytes)
            let ratio = Double(used) / Double(quota)
            let level: QuotaLevel = used > quota ? .full
                : (ratio >= options.quotaWarnRatio ? .warning : .ok)

            var wouldDelete = 0
            var wouldFree = 0
            var oldest: Int64?
            var newest: Int64?
            if used > quota {
                wouldFree = used - quota
                let total = Int(try conn.scalarInt(
                    "SELECT COUNT(*) FROM observations WHERE device_id = ?;",
                    [.text(deviceID)]) ?? 0)
                if total > 0 {
                    let average = max(1.0, Double(used) / Double(total))
                    wouldDelete = min(total, Int((Double(wouldFree) / average).rounded(.up)))
                    oldest = try conn.scalarInt("""
                        SELECT ts FROM observations WHERE device_id = ? ORDER BY ts, id LIMIT 1;
                        """, [.text(deviceID)])
                    newest = try conn.scalarInt("""
                        SELECT ts FROM observations WHERE device_id = ?
                         ORDER BY ts, id LIMIT 1 OFFSET ?;
                        """, [.text(deviceID), .int(Int64(max(0, wouldDelete - 1)))]) ?? oldest
                }
            }
            let ackAt = try metaInt(SchemaV8.MetaKey.quotaAcknowledgedAt, conn: conn)
            return QuotaAction(
                level: level, usedBytes: used, quotaBytes: quota, ratio: ratio,
                wouldDeleteObservations: wouldDelete, wouldFreeBytes: wouldFree,
                wouldDeleteOldestTS: oldest, wouldDeleteNewestTS: newest,
                suggestedExportStart: oldest,
                suggestedExportEnd: newest.map { $0 + 1 },
                acknowledgedAt: ackAt,
                acknowledgedArchiveID: try metaText(SchemaV8.MetaKey.quotaAcknowledgedArchive,
                                                    conn: conn),
                lastExportAt: try metaInt(SchemaV8.MetaKey.lastExportAt, conn: conn),
                lastExportArchiveID: try metaText(SchemaV8.MetaKey.lastExportArchive, conn: conn),
                expireAllowed: level == .full && ackAt != nil)
        }

        if recordEvent {
            // 只在**跨档**时写事件：同一档反复查不会把 jobs 表刷爆。
            let crossed: Bool = try withLock { conn in
                let previous = try metaText(SchemaV8.MetaKey.quotaNotifiedLevel, conn: conn)
                guard previous != action.level.rawValue else { return false }
                try conn.transaction {
                    try setMeta(SchemaV8.MetaKey.quotaNotifiedLevel, action.level.rawValue,
                                conn: conn)
                }
                return action.level != .ok
            }
            // 事件走 `recordRuntimeEvent`（它自己取锁），所以放在上面那段之外。
            if crossed {
                _ = try? recordRuntimeEvent(
                    kind: action.level == .full ? "quota_full" : "quota_warning",
                    detail: "used=\(action.usedBytes) quota=\(action.quotaBytes)"
                          + " ratio=\(String(format: "%.4f", action.ratio))"
                          + " would_delete=\(action.wouldDeleteObservations)"
                          + " would_free=\(action.wouldFreeBytes)"
                          + " suggested_export=[\(action.suggestedExportStart.map(String.init) ?? "-"),"
                          + "\(action.suggestedExportEnd.map(String.init) ?? "-"))"
                          + " acknowledged=\(action.acknowledgedAt != nil)",
                    at: nowMS)
            }
        }
        action.expireAllowed = action.level == .full && action.acknowledgedAt != nil
        return action
    }

    /// 用户看过通知并确认（可选地附上"我已经先导出了"的归档 id）。
    /// 确认**只管一次**：`expireAfterNotice` 真的删过之后就清掉，下次满了要重新确认。
    public func acknowledgeQuotaAction(archiveID: String? = nil, at ts: Int64? = nil) throws {
        try withLock { conn in
            let used = try contentBytes(conn)
            try conn.transaction {
                try setMeta(SchemaV8.MetaKey.quotaAcknowledgedAt, String(ts ?? Self.nowMS()),
                            conn: conn)
                try setMeta(SchemaV8.MetaKey.quotaAcknowledgedArchive, archiveID, conn: conn)
                try setMeta(SchemaV8.MetaKey.quotaAcknowledgedBytes, String(used), conn: conn)
            }
        }
        _ = try? recordRuntimeEvent(kind: "quota_acknowledged",
                                    detail: "archive=\(archiveID ?? "-")")
    }

    /// D7 的「满后最旧先删，**删前通知**」：没确认过就不删，把通知交出去。
    ///
    /// `expire()` 本身的语义没有变（它仍然是"到量就删"，夜间任务与压测都还用它）；
    /// 这里是产品路径用的那一层——UI 拿到 `.blocked` 就弹通知，通知里带"先加密导出"。
    public func expireAfterNotice(toBytes: Int? = nil, force: Bool = false) throws
        -> QuotaExpireOutcome {
        // 覆盖值要一路传到判定里去，否则"按新配额删"和"按旧配额判到没到线"会用两个数。
        let action = try quotaAction(quota: toBytes)
        guard action.level == .full else { return .notNeeded(action) }
        guard force || action.acknowledgedAt != nil else { return .blocked(action) }
        let report = try expire(toBytes: toBytes)
        try withLock { conn in
            try conn.transaction {
                try setMeta(SchemaV8.MetaKey.quotaAcknowledgedAt, nil, conn: conn)
                try setMeta(SchemaV8.MetaKey.quotaAcknowledgedArchive, nil, conn: conn)
                try setMeta(SchemaV8.MetaKey.quotaAcknowledgedBytes, nil, conn: conn)
                try setMeta(SchemaV8.MetaKey.quotaNotifiedLevel, nil, conn: conn)
            }
        }
        return .expired(action, report)
    }

    // MARK: - meta 读写
    //
    // `metaInt` / `setMeta` 已经在 Store+Sessions.swift 里（会话增量的水位线用同一对），
    // 这里只补一个读字符串的。

    func metaText(_ key: String, conn: SQLiteConnection) throws -> String? {
        try conn.scalarText("SELECT value FROM meta WHERE key = ?;", [.text(key)])
    }
}
