import Foundation

// =============================================================================
// D17 / 3.9 的库侧：出站取数、入站落库、水位线与对端状态。
//
// 这里不认识文件、不认识密钥、不认识 iCloud——那些在 BrosisSync 里。
// 入站记录落库的口径（本机 id 空间 + origin 两列）写在 SyncSchema.swift 的文件头，
// 改这个文件之前先读那一段。
//
// 会话与台账的口径（3.7）：**只用本机产生的观察构建**。
//   sessions 的 dwell_s / active_s / unknown_s 是"这台机器的屏幕时间"；把另一台机器的
//   观察混进同一条时间线会造出根本没发生过的应用切换，并把同一段墙钟时间记两遍。
//   所以 `Store+Sessions` 的三条取数加了 `origin_device IS NULL`。
//   入站**墓碑**仍然会让本机的 sessions / ledgers 标 stale（被删的可能正是本机的观察，
//   见 `applyImportedTombstone`），这是 3.8 的级联要求。
//   跨设备合并台账（把两台机器的一天并成一张表）不在本任务范围内，见结果文件的"未做"。
// =============================================================================

extension Store {

    // MARK: - 状态

    /// 3.9「状态显示」的库侧数据。
    public func syncState() throws -> SyncStateSnapshot {
        try withLock { conn in
            let nextSeq = try syncStateInt(SyncSchema.StateKey.nextSeq, conn: conn) ?? 1
            let obsWatermark = try syncStateInt(SyncSchema.StateKey.exportedObservationID, conn: conn) ?? 0
            let delWatermark = try syncStateInt(SyncSchema.StateKey.exportedDeletionID, conn: conn) ?? 0
            let pendingObs = Int(try conn.scalarInt("""
                SELECT COUNT(*) FROM observations
                 WHERE device_id = ? AND origin_device IS NULL AND id > ?;
                """, [.text(deviceID), .int(obsWatermark)]) ?? 0)
            let pendingDel = Int(try conn.scalarInt("""
                SELECT COUNT(*) FROM deletions
                 WHERE device_id = ? AND reason = 'user' AND id > ?;
                """, [.text(deviceID), .int(delWatermark)]) ?? 0)
            return SyncStateSnapshot(
                deviceID: deviceID,
                nextSeq: nextSeq,
                exportedObservationID: obsWatermark,
                exportedDeletionID: delWatermark,
                pendingObservations: pendingObs,
                pendingTombstones: pendingDel,
                lastExportAt: try syncStateInt(SyncSchema.StateKey.lastExportAt, conn: conn),
                lastImportAt: try syncStateInt(SyncSchema.StateKey.lastImportAt, conn: conn),
                peers: try syncPeersUnlocked(conn: conn))
        }
    }

    public func syncPeers() throws -> [SyncPeerState] {
        try withLock { conn in try syncPeersUnlocked(conn: conn) }
    }

    private func syncPeersUnlocked(conn: SQLiteConnection) throws -> [SyncPeerState] {
        let st = try conn.prepare("""
            SELECT device_id, name, first_seen, last_seen, imported_seq, imported_at,
                   observations, last_error
              FROM sync_peers ORDER BY device_id;
            """)
        defer { st.finalize() }
        var out: [SyncPeerState] = []
        while try st.step() {
            out.append(SyncPeerState(deviceID: st.text(0) ?? "", name: st.text(1),
                                     firstSeen: st.int(2) ?? 0, lastSeen: st.int(3) ?? 0,
                                     importedSeq: st.int(4) ?? 0, importedAt: st.int(5),
                                     observations: Int(st.int(6) ?? 0), lastError: st.text(7)))
        }
        return out
    }

    /// 记一次"看见了这个设备"（扫描目录时调用），顺带更新设备名。
    public func syncTouchPeer(deviceID peer: String, name: String? = nil,
                              at ts: Int64? = nil) throws {
        guard peer != deviceID else { return }
        try withLock { conn in
            let now = ts ?? Self.nowMS()
            _ = try conn.run("""
                INSERT INTO sync_peers(device_id, name, first_seen, last_seen)
                VALUES (?,?,?,?)
                ON CONFLICT(device_id) DO UPDATE SET
                  last_seen = excluded.last_seen,
                  name = COALESCE(excluded.name, sync_peers.name);
                """, [.text(peer), .optionalText(name), .int(now), .int(now)])
        }
    }

    /// 记一次对端错误（缺段 / 校验失败 / 未下载），`nil` 表示清除。
    public func syncSetPeerError(deviceID peer: String, error: String?) throws {
        try withLock { conn in
            _ = try conn.run("UPDATE sync_peers SET last_error = ? WHERE device_id = ?;",
                             [.optionalText(error), .text(peer)])
        }
    }

    /// 同步密钥指纹：换了一套密钥（重新配对）时要能看出来。
    public func syncKeyID() throws -> String? {
        try withLock { conn in try syncStateText(SyncSchema.StateKey.keyID, conn: conn) }
    }

    public func syncSetKeyID(_ value: String?) throws {
        try withLock { conn in try setSyncState(SyncSchema.StateKey.keyID, value, conn: conn) }
    }

    /// 同步密钥的静态存放处：**加密库里的一行**（`sync_state.sync_key`，base64）。
    ///
    /// 它与库密钥是两把不同的密钥（3.9「同步密钥与本机库密钥分开」）：库密钥在
    /// data-protection 钥匙串里、只开库用；同步密钥只封段文件。之所以把它放进库而不是
    /// 再要一个钥匙串条目：① 钥匙串写入会弹授权框，本轮不允许触发；
    /// ② 库本身已经是 SQLCipher 加密的，静态防护等价于库密钥的防护，而库密钥的存放
    /// 已经按 3.5 定好了；③ 只有一个持钥者（存储服务），不多一个持密者。
    /// 代价：拿到库密钥的人也能拿到同步密钥——但拿到库密钥本来就能读全部原文，
    /// 同步密钥保护的是它的**子集**，没有降低边界。
    public func syncKeyMaterial() throws -> Data? {
        try withLock { conn in
            guard let base64 = try syncStateText("sync_key", conn: conn) else { return nil }
            return Data(base64Encoded: base64)
        }
    }

    public func syncSetKeyMaterial(_ key: Data?, keyID: String?) throws {
        try withLock { conn in
            try conn.transaction {
                try setSyncState("sync_key", key?.base64EncodedString(), conn: conn)
                try setSyncState(SyncSchema.StateKey.keyID, keyID, conn: conn)
            }
        }
    }

    public func syncDirectoryPath() throws -> String? {
        try withLock { conn in try syncStateText(SyncSchema.StateKey.directory, conn: conn) }
    }

    public func syncSetDirectoryPath(_ value: String?) throws {
        try withLock { conn in try setSyncState(SyncSchema.StateKey.directory, value, conn: conn) }
    }

    // MARK: - 出站

    /// 取下一个段的载荷。**只读**：水位线要等段文件真正落盘之后再由 `syncCommitExport` 推进。
    ///
    /// 崩溃语义：写文件之后、推水位线之前掉电，下次会把同一批记录再打成一个**新序号**的段。
    /// 对端按 `(origin_device, origin_id)` 的唯一索引判定，重复的那一份整段跳过，不会重复入库。
    ///
    /// - Parameters:
    ///   - maxObservations: 一个段最多装多少条观察。
    ///   - maxTextBytes: 一个段最多装多少字节原文（软上限：第一条观察永远装得下）。
    ///   - maxTombstones: 一个段最多装多少条墓碑。
    /// - Returns: 没有待出站记录时返回 nil。
    public func syncExportNext(maxObservations: Int = 2_000,
                               maxTextBytes: Int = 8 * 1024 * 1024,
                               maxTombstones: Int = 500) throws -> SyncSegment? {
        try withLock { conn in
            let seq = try syncStateInt(SyncSchema.StateKey.nextSeq, conn: conn) ?? 1
            let obsWatermark = try syncStateInt(SyncSchema.StateKey.exportedObservationID, conn: conn) ?? 0
            let delWatermark = try syncStateInt(SyncSchema.StateKey.exportedDeletionID, conn: conn) ?? 0

            var texts: [String: SyncTextRecord] = [:]      // sha → 记录（段内去重）
            var textOrder: [String] = []
            var textBytes = 0
            var observations: [SyncObservationRecord] = []
            var lastObs = obsWatermark

            let st = try conn.prepare("""
                SELECT o.id, o.ts, o.display_id, a.bundle_id, a.name, w.title,
                       u.raw_locator, u.canonical_url, u.host, u.kind, f.path,
                       o."trigger", o.capture_method, o.completeness, o.visible_range,
                       o.source_state, o.frame_hash, o.deleted_at
                  FROM observations o
                  LEFT JOIN apps    a ON a.id = o.app_id
                  LEFT JOIN windows w ON w.id = o.window_id
                  LEFT JOIN urls    u ON u.id = o.url_id
                  LEFT JOIN files   f ON f.id = o.file_id
                 WHERE o.device_id = ? AND o.origin_device IS NULL AND o.id > ?
                 ORDER BY o.id LIMIT ?;
                """)
            try st.bind([.text(deviceID), .int(obsWatermark), .int(Int64(maxObservations))])
            var rows: [SyncObservationRecord] = []
            while try st.step() {
                let url: SyncURLRecord? = st.text(6).map {
                    SyncURLRecord(raw: $0, canonical: st.text(7) ?? $0,
                                  host: st.text(8), kind: st.text(9) ?? "other")
                }
                rows.append(SyncObservationRecord(
                    id: st.int(0) ?? 0, ts: st.int(1) ?? 0, display: st.int(2),
                    bundle: st.text(3), appName: st.text(4), title: st.text(5),
                    url: url, path: st.text(10),
                    trigger: st.text(11) ?? "manual", method: st.text(12) ?? "ax",
                    completeness: st.text(13) ?? "partial", visible: st.text(14),
                    state: st.text(15) ?? "ok", frame: st.text(16), deletedAt: st.int(17)))
            }
            st.finalize()

            for var row in rows {
                // 软上限：装满了就停，但至少要装下第一条（否则一条大正文会把出站卡死）。
                if !observations.isEmpty && textBytes >= maxTextBytes { break }
                let occ = try conn.prepare("""
                    SELECT oc.ord, oc.region, oc.confidence, oc.note,
                           tv.sha256, tv.text, tv.byte_len, tv.created_at
                      FROM occurrences oc
                      JOIN text_versions tv
                        ON tv.device_id = oc.device_id AND tv.id = oc.text_version_id
                     WHERE oc.device_id = ? AND oc.observation_id = ?
                     ORDER BY oc.ord;
                    """)
                try occ.bind([.text(deviceID), .int(row.id)])
                var fragments: [SyncOccurrenceRecord] = []
                while try occ.step() {
                    guard let digest = occ.blob(4), let text = occ.text(5) else { continue }
                    let sha = Self.hex(digest)
                    if texts[sha] == nil {
                        let record = SyncTextRecord(sha: sha, text: text,
                                                    len: Int(occ.int(6) ?? 0),
                                                    at: occ.int(7) ?? 0)
                        texts[sha] = record
                        textOrder.append(sha)
                        textBytes += record.len
                    }
                    fragments.append(SyncOccurrenceRecord(
                        sha: sha, ord: Int(occ.int(0) ?? 0), region: occ.text(1),
                        conf: occ.double(2), note: occ.text(3)))
                }
                occ.finalize()
                row.texts = fragments
                observations.append(row)
                lastObs = max(lastObs, row.id)
            }

            // —— 墓碑（只发用户删除；配额过期是本机策略，3.8）——
            var tombstones: [SyncTombstoneRecord] = []
            var lastDel = delWatermark
            let ts = try conn.prepare("""
                SELECT id, kind, applied_at, params, targets FROM deletions
                 WHERE device_id = ? AND reason = 'user' AND id > ?
                 ORDER BY id LIMIT ?;
                """)
            try ts.bind([.text(deviceID), .int(delWatermark), .int(Int64(maxTombstones))])
            while try ts.step() {
                let id = ts.int(0) ?? 0
                let targets = Self.decodeTargets(ts.text(4))
                tombstones.append(SyncTombstoneRecord(
                    id: id, kind: ts.text(1) ?? "observation", appliedAt: ts.int(2) ?? 0,
                    params: ts.text(3) ?? "{}", targets: targets))
                lastDel = max(lastDel, id)
            }
            ts.finalize()

            guard !observations.isEmpty || !tombstones.isEmpty else { return nil }
            return SyncSegment(device: deviceID, seq: seq, createdAt: Self.nowMS(),
                               texts: textOrder.compactMap { texts[$0] },
                               observations: observations, tombstones: tombstones,
                               lastObservationID: lastObs, lastDeletionID: lastDel)
        }
    }

    /// 段文件落盘之后推进水位线与序号。必须在写文件**成功之后**调用。
    public func syncCommitExport(_ segment: SyncSegment) throws {
        try withLock { conn in
            try conn.transaction {
                try setSyncState(SyncSchema.StateKey.nextSeq, String(segment.seq + 1), conn: conn)
                try setSyncState(SyncSchema.StateKey.exportedObservationID,
                                 String(segment.lastObservationID), conn: conn)
                try setSyncState(SyncSchema.StateKey.exportedDeletionID,
                                 String(segment.lastDeletionID), conn: conn)
                try setSyncState(SyncSchema.StateKey.lastExportAt, String(Self.nowMS()), conn: conn)
            }
        }
    }

    /// 出站统计（结果文件与状态显示用）。
    public static func exportStats(of segment: SyncSegment) -> SyncExportStats {
        var stats = SyncExportStats()
        stats.observations = segment.observations.count
        stats.texts = segment.texts.count
        stats.occurrences = segment.observations.reduce(0) { $0 + $1.texts.count }
        stats.tombstones = segment.tombstones.count
        stats.textPayloadBytes = segment.textPayloadBytes
        return stats
    }

    // MARK: - 入站

    /// 导入一个段。**整段一个事务**：中途任何一步失败都整体回滚，库不会停在半个段上。
    ///
    /// 幂等：已经导过的观察（按 `(origin_device, origin_id)` 的唯一索引判定）与已经导过的墓碑
    /// （按 `deletions` 的主键判定）都跳过。重放同一个段、或者两个段里有重叠记录，结果一样。
    ///
    /// - Parameter expectedSeq: 调用方（BrosisSync）已经保证按 seq 连续；这里再核一遍，
    ///   `seq != 已导入 + 1` 直接抛 `.syncOutOfOrder`，绝不跳过缺的那一段（3.9「缺段停止」）。
    @discardableResult
    public func syncImport(_ segment: SyncSegment, enforceOrder: Bool = true) throws -> SyncImportStats {
        guard segment.device != deviceID else {
            throw StoreError.invalidUsage("不能导入本机自己的段（device \(segment.device)）")
        }
        return try withLock { conn in
            try conn.transaction {
                let current = try conn.scalarInt(
                    "SELECT imported_seq FROM sync_peers WHERE device_id = ?;",
                    [.text(segment.device)]) ?? 0
                if enforceOrder && segment.seq != current + 1 {
                    throw StoreError.syncOutOfOrder(device: segment.device,
                                                    expected: current + 1, found: segment.seq)
                }
                var stats = SyncImportStats()
                let textIndex = Dictionary(segment.texts.map { ($0.sha, $0) },
                                           uniquingKeysWith: { a, _ in a })

                for record in segment.observations {
                    try importObservation(record, from: segment.device, texts: textIndex,
                                          stats: &stats, conn: conn)
                }
                for tombstone in segment.tombstones {
                    try applyImportedTombstone(tombstone, from: segment.device,
                                               stats: &stats, conn: conn)
                }
                let now = Self.nowMS()
                try conn.run("""
                    INSERT INTO sync_peers(device_id, first_seen, last_seen, imported_seq,
                                           imported_at, observations)
                    VALUES (?,?,?,?,?,?)
                    ON CONFLICT(device_id) DO UPDATE SET
                      last_seen = excluded.last_seen,
                      imported_seq = excluded.imported_seq,
                      imported_at = excluded.imported_at,
                      observations = sync_peers.observations + excluded.observations,
                      last_error = NULL;
                    """, [.text(segment.device), .int(now), .int(now), .int(segment.seq),
                          .int(now), .int(Int64(stats.observationsInserted))])
                try setSyncState(SyncSchema.StateKey.lastImportAt, String(now), conn: conn)
                try persistCounters()
                return stats
            }
        }
    }

    private func importObservation(_ record: SyncObservationRecord, from origin: String,
                                   texts: [String: SyncTextRecord],
                                   stats: inout SyncImportStats,
                                   conn: SQLiteConnection) throws {
        if try conn.scalarInt("""
            SELECT id FROM observations WHERE origin_device = ? AND origin_id = ?;
            """, [.text(origin), .int(record.id)]) != nil {
            stats.observationsSkipped += 1
            return
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

        let localID = counters.observation
        counters.observation += 1
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
                .optionalInt(record.deletedAt), .text(origin), .int(record.id),
            ])
        stats.observationsInserted += 1

        // 源设备上已经打了墓碑的观察：只落观察行，不落正文（源设备那边的 occurrence 早删了）。
        guard record.deletedAt == nil else { return }

        for fragment in record.texts {
            let (tvID, isNew) = try resolveImportedText(sha: fragment.sha, texts: texts, conn: conn)
            if isNew { stats.textVersionsInserted += 1 } else { stats.textVersionsReused += 1 }
            let occID = counters.occurrence
            counters.occurrence += 1
            try conn.run("""
                INSERT INTO occurrences
                  (device_id, id, observation_id, text_version_id, region, ord, confidence, note)
                VALUES (?,?,?,?,?,?,?,?);
                """, [
                    .text(deviceID), .int(occID), .int(localID), .int(tvID),
                    .optionalText(fragment.region), .int(Int64(fragment.ord)),
                    fragment.conf.map { SQLValue.double($0) } ?? .null,
                    .optionalText(fragment.note),
                ])
            stats.occurrencesInserted += 1
        }
    }

    /// sha → 本机 text_version id。本机已有同 sha 的正文就复用（跨设备同一段文字只存一份）；
    /// 没有就用段里带的正文新建（并写 FTS 行）。段里没带、本机也没有 = 段不完整，停。
    private func resolveImportedText(sha: String, texts: [String: SyncTextRecord],
                                     conn: SQLiteConnection) throws -> (id: Int64, isNew: Bool) {
        guard let digest = Self.data(fromHex: sha), digest.count == 32 else {
            throw StoreError.syncCorruptSegment("sha 不是 32 字节十六进制：\(sha.prefix(16))…")
        }
        if let existing = try conn.scalarInt("""
            SELECT id FROM text_versions WHERE device_id = ? AND sha256 = ?;
            """, [.text(deviceID), .blob(digest)]) {
            return (existing, false)
        }
        guard let record = texts[sha] else {
            throw StoreError.syncCorruptSegment(
                "段里缺少 sha \(sha.prefix(16))… 的正文，本机也没有同哈希的版本")
        }
        // 校验段里的正文确实是这个哈希（段被改过一个字节但校验和恰好被重算的极端情况）。
        guard TextPipeline.sha256(record.text) == digest else {
            throw StoreError.syncCorruptSegment("正文与 sha \(sha.prefix(16))… 不符")
        }
        let (id, _) = try upsertTextVersion(record.text, conn: conn, createdAt: record.at)
        return (id, true)
    }

    /// 入站墓碑：在**本机的副本**上重放同一次删除的级联（3.8 的顺序），
    /// 审计行按**源设备的身份**写（device_id = 源设备、id = 源设备的 deletion id），
    /// 于是它不会落进本机的出站集合，两台机器之间不会来回转发同一条墓碑。
    private func applyImportedTombstone(_ record: SyncTombstoneRecord, from origin: String,
                                        stats: inout SyncImportStats,
                                        conn: SQLiteConnection) throws {
        if try conn.scalarInt("SELECT 1 FROM deletions WHERE device_id = ? AND id = ?;",
                              [.text(origin), .int(record.id)]) != nil {
            stats.tombstonesSkipped += 1
            return
        }
        // 目标 → 本机 observation id。
        //
        // **按区间走 SQL，不把区间展开成 id 数组**：一次"删除某个应用的全部记录"压成的区间可能是
        // `[[1, 4000000]]`，展开就是 32 MB 的 Int64 数组，而 SQL 里 `BETWEEN` 一句话的事。
        var localIDs: [Int64] = []
        for target in record.targets {
            for range in target.ranges where range.count == 2 && range[0] <= range[1] {
                let rows: [Int64]
                if target.device == deviceID {
                    // 目标本来就是本机产生的记录（对端删掉了它导入的那一份副本）。
                    rows = try conn.intColumn("""
                        SELECT id FROM observations
                         WHERE device_id = ? AND origin_device IS NULL AND id BETWEEN ? AND ?;
                        """, [.text(deviceID), .int(range[0]), .int(range[1])])
                } else {
                    rows = try conn.intColumn("""
                        SELECT id FROM observations
                         WHERE origin_device = ? AND origin_id BETWEEN ? AND ?;
                        """, [.text(target.device), .int(range[0]), .int(range[1])])
                }
                localIDs.append(contentsOf: rows)
            }
        }
        let ts = record.appliedAt
        let ftsBefore = try ftsRowCount(conn)
        var obsMarked = 0, occDeleted = 0, tvDeleted = 0, bytesFreed = 0, thumbsDeleted = 0
        var sessionsStale = 0, ledgersStale = 0

        if !localIDs.isEmpty {
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
            sessionsStale = stale.sessions
            ledgersStale = stale.ledgers
        }
        let ftsDeleted = ftsBefore - (try ftsRowCount(conn))

        try conn.run("""
            INSERT INTO deletions(device_id, id, kind, reason, params, applied_at,
                                  observations_affected, occurrences_deleted, text_versions_deleted,
                                  fts_rows_deleted, sessions_stale, ledgers_stale,
                                  thumbs_deleted, bytes_freed, targets)
            VALUES (?,?,?,'user',?,?,?,?,?,?,?,?,?,?,?);
            """, [
                .text(origin), .int(record.id), .text(record.kind), .text(record.params), .int(ts),
                .int(Int64(obsMarked)), .int(Int64(occDeleted)), .int(Int64(tvDeleted)),
                .int(Int64(ftsDeleted)), .int(Int64(sessionsStale)), .int(Int64(ledgersStale)),
                .int(Int64(thumbsDeleted)), .int(Int64(bytesFreed)),
                .text(Self.encodeTargets(record.targets)),
            ])
        stats.tombstonesApplied += 1
        stats.observationsTombstoned += obsMarked
        stats.occurrencesDeleted += occDeleted
        stats.textVersionsDeleted += tvDeleted
        stats.sessionsStale += sessionsStale
        stats.ledgersStale += ledgersStale
    }

    // MARK: - 墓碑目标（供 Store+Delete 的用户删除路径调用）

    /// 把一批**本机** observation id 翻译成"按来源设备分组的区间"，写进 `deletions.targets`。
    func syncTargets(for ids: [Int64], conn: SQLiteConnection) throws -> String? {
        guard !ids.isEmpty else { return nil }
        var groups: [String: [Int64]] = [:]
        for chunk in ids.chunked(into: 400) {
            let marks = placeholders(chunk.count)
            let st = try conn.prepare("""
                SELECT id, origin_device, origin_id FROM observations
                 WHERE device_id = ? AND id IN (\(marks));
                """)
            defer { st.finalize() }
            try st.bind([.text(deviceID)] + chunk.map { SQLValue.int($0) })
            while try st.step() {
                let localID = st.int(0) ?? 0
                let device = st.text(1) ?? deviceID
                let originID = st.int(2) ?? localID
                groups[device, default: []].append(originID)
            }
        }
        let targets = groups.keys.sorted().map {
            SyncTombstoneTarget.compress(device: $0, ids: groups[$0] ?? [])
        }
        return Self.encodeTargets(targets)
    }

    static func encodeTargets(_ targets: [SyncTombstoneTarget]) -> String {
        guard let data = try? JSONEncoder().encode(targets) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeTargets(_ json: String?) -> [SyncTombstoneTarget] {
        guard let json, let data = json.data(using: .utf8),
              let targets = try? JSONDecoder().decode([SyncTombstoneTarget].self, from: data) else {
            return []
        }
        return targets
    }

    // MARK: - 供测试与状态显示的小查询

    /// 本机某条观察的来源；`nil` 表示本机自己产生的。
    public func syncOrigin(observationID: Int64) throws -> (device: String, id: Int64)? {
        try withLock { conn in
            let st = try conn.prepare("""
                SELECT origin_device, origin_id FROM observations WHERE device_id = ? AND id = ?;
                """)
            defer { st.finalize() }
            try st.bind([.text(deviceID), .int(observationID)])
            guard try st.step(), let device = st.text(0), let id = st.int(1) else { return nil }
            return (device, id)
        }
    }

    /// 来源记录在本机的 id（导入后查证据用）。
    public func syncLocalObservationID(originDevice: String, originID: Int64) throws -> Int64? {
        try withLock { conn in
            try conn.scalarInt("SELECT id FROM observations WHERE origin_device = ? AND origin_id = ?;",
                               [.text(originDevice), .int(originID)])
        }
    }

    /// 本机产生的 / 导入的观察条数（不含墓碑判断）。
    public func syncObservationCounts() throws -> (local: Int, imported: Int) {
        try withLock { conn in
            let local = Int(try conn.scalarInt("""
                SELECT COUNT(*) FROM observations WHERE device_id = ? AND origin_device IS NULL;
                """, [.text(deviceID)]) ?? 0)
            let imported = Int(try conn.scalarInt("""
                SELECT COUNT(*) FROM observations WHERE device_id = ? AND origin_device IS NOT NULL;
                """, [.text(deviceID)]) ?? 0)
            return (local, imported)
        }
    }

    // MARK: - sync_state 读写

    func syncStateText(_ key: String, conn: SQLiteConnection) throws -> String? {
        try conn.scalarText("SELECT value FROM sync_state WHERE key = ?;", [.text(key)])
    }

    func syncStateInt(_ key: String, conn: SQLiteConnection) throws -> Int64? {
        try syncStateText(key, conn: conn).flatMap(Int64.init)
    }

    func setSyncState(_ key: String, _ value: String?, conn: SQLiteConnection) throws {
        guard let value else {
            try conn.run("DELETE FROM sync_state WHERE key = ?;", [.text(key)])
            return
        }
        try conn.run("""
            INSERT INTO sync_state(key, value) VALUES (?,?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """, [.text(key), .text(value)])
    }

    // MARK: - 小工具

    static func nowMS() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(fromHex hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
