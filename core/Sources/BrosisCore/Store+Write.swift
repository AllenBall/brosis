import Foundation

extension Store {

    // MARK: - 写入一次观察

    /// 记录一次观察：规范化对象 upsert → observation → 文本版本（**按原文** sha256 去重）
    /// → occurrences → FTS 行（折叠后 bigram 预处理）。整体一个事务。
    @discardableResult
    public func record(_ input: ObservationInput) throws -> RecordResult {
        try withLock { conn in
            try conn.transaction { try recordUnlocked(input, conn: conn) }
        }
    }

    /// 批量写入，一个事务包住全部。合成流导入与压测用。
    @discardableResult
    public func record(batch: [ObservationInput]) throws -> [RecordResult] {
        try withLock { conn in
            try conn.transaction {
                var out: [RecordResult] = []
                out.reserveCapacity(batch.count)
                for input in batch { out.append(try recordUnlocked(input, conn: conn)) }
                return out
            }
        }
    }

    func recordUnlocked(_ input: ObservationInput, conn: SQLiteConnection) throws -> RecordResult {
        let appID = try input.app.map { try upsertApp($0, conn: conn) }
        let windowID: Int64?
        if let title = input.windowTitle, let appID {
            windowID = try upsertWindow(appID: appID, title: title, conn: conn)
        } else {
            windowID = nil
        }
        let urlID = try input.url.map { try upsertURL($0, conn: conn) }
        let fileID = try input.filePath.map { try upsertFile($0, conn: conn) }

        let obsID = counters.observation
        counters.observation += 1
        try conn.run("""
            INSERT INTO observations
              (device_id, id, ts, display_id, app_id, window_id, url_id, file_id,
               "trigger", capture_method, completeness, visible_range, source_state,
               frame_hash, thumb_ref, deleted_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL);
            """, [
                .text(deviceID), .int(obsID), .int(input.ts),
                .optionalInt(input.displayID), .optionalInt(appID), .optionalInt(windowID),
                .optionalInt(urlID), .optionalInt(fileID),
                .text(input.trigger.rawValue), .text(input.captureMethod.rawValue),
                .text(input.completeness.rawValue), .optionalText(input.visibleRange),
                .text(input.sourceState.rawValue), .optionalText(input.frameHash),
                .optionalText(input.thumbRef),
            ])

        var versionIDs: [Int64] = []
        var newCount = 0
        var reusedCount = 0
        for (ord, fragment) in input.texts.enumerated() {
            let (tvID, isNew) = try upsertTextVersion(fragment.text, conn: conn)
            if isNew { newCount += 1 } else { reusedCount += 1 }
            versionIDs.append(tvID)
            let occID = counters.occurrence
            counters.occurrence += 1
            try conn.run("""
                INSERT INTO occurrences
                  (device_id, id, observation_id, text_version_id, region, ord, confidence, note)
                VALUES (?,?,?,?,?,?,?,?);
                """, [
                    .text(deviceID), .int(occID), .int(obsID), .int(tvID),
                    .optionalText(fragment.region), .int(Int64(ord)),
                    fragment.confidence.map { SQLValue.double($0) } ?? .null,
                    .optionalText(fragment.note),
                ])
        }
        try persistCounters()
        return RecordResult(observationID: obsID, textVersionIDs: versionIDs,
                            newTextVersions: newCount, reusedTextVersions: reusedCount)
    }

    // MARK: - 规范化对象（对象身份 ≠ 内容版本）

    func upsertApp(_ app: AppRef, conn: SQLiteConnection) throws -> Int64 {
        if let id = try conn.scalarInt("SELECT id FROM apps WHERE bundle_id = ?;", [.text(app.bundleID)]) {
            return id
        }
        try conn.run("INSERT INTO apps(bundle_id, name) VALUES (?, ?);",
                     [.text(app.bundleID), .text(app.name)])
        return conn.lastInsertRowID
    }

    func upsertWindow(appID: Int64, title: String, conn: SQLiteConnection) throws -> Int64 {
        if let id = try conn.scalarInt("SELECT id FROM windows WHERE app_id = ? AND title = ?;",
                                       [.int(appID), .text(title)]) {
            return id
        }
        try conn.run("INSERT INTO windows(app_id, title) VALUES (?, ?);",
                     [.int(appID), .text(title)])
        return conn.lastInsertRowID
    }

    func upsertURL(_ ref: URLRef, conn: SQLiteConnection) throws -> Int64 {
        if let id = try conn.scalarInt("SELECT id FROM urls WHERE raw_locator = ?;",
                                       [.text(ref.rawLocator)]) {
            return id
        }
        try conn.run("INSERT INTO urls(raw_locator, canonical_url, host, kind) VALUES (?,?,?,?);",
                     [.text(ref.rawLocator), .text(ref.canonicalURL),
                      .optionalText(ref.host), .text(ref.kind.rawValue)])
        return conn.lastInsertRowID
    }

    func upsertFile(_ path: String, conn: SQLiteConnection) throws -> Int64 {
        if let id = try conn.scalarInt("SELECT id FROM files WHERE path = ?;", [.text(path)]) {
            return id
        }
        try conn.run("INSERT INTO files(path) VALUES (?);", [.text(path)])
        return conn.lastInsertRowID
    }

    // MARK: - 文本版本 + FTS（D22 / D23）

    /// **原文** sha256 → 同设备内按 sha256 复用；新版本才写 FTS 行。
    ///
    /// 口径（M1 R1 之后定案）：`text` / `sha256` / `byte_len` 全部按**原文**，一个字节都不改——
    /// 证据必须原样。NFKC 折叠只发生在 FTS 那一行（`TextPipeline.bigramForIndex`）。
    /// 去重因此是**逐字节相同才复用**：同一段内容的全角写法与半角写法是两个版本，
    /// 这是有意的，代价是这类内容会各占一行原文（`text_versions` 行数与净载荷都会略高）。
    ///
    /// 返回 `(text_versions.id, 是否新建)`。
    /// - Parameter createdAt: 只有 D17 的**入站**路径会传（用源设备上的创建时刻，
    ///   好让"这段正文是什么时候第一次出现的"跨设备保持一致）；本机写入路径不传，用当前时刻。
    func upsertTextVersion(_ text: String, conn: SQLiteConnection,
                           createdAt: Int64? = nil) throws -> (id: Int64, isNew: Bool) {
        let digest = TextPipeline.sha256(text)
        if let id = try conn.scalarInt("SELECT id FROM text_versions WHERE device_id = ? AND sha256 = ?;",
                                       [.text(deviceID), .blob(digest)]) {
            return (id, false)
        }
        let tvID = counters.textVersion
        counters.textVersion += 1
        let vrow = counters.vrow
        counters.vrow += 1
        let now = createdAt ?? Int64(Date().timeIntervalSince1970 * 1000)
        try conn.run("""
            INSERT INTO text_versions(vrow, device_id, id, sha256, text, byte_len, created_at)
            VALUES (?,?,?,?,?,?,?);
            """, [
                .int(vrow), .text(deviceID), .int(tvID), .blob(digest), .text(text),
                .int(Int64(TextPipeline.byteLength(text))), .int(now),
            ])
        // D22：FTS 是 contentless，写进去的是**折叠后再 bigram 预处理**的文本，rowid 用 vrow。
        // 折叠只到这一列为止（索引侧），上面那行存的仍是原文。
        // 没有触发器，增删都在这里显式做；夜间 maintenance() 对账（用同一个 indexBody）。
        let index = TextPipeline.indexBody(text)
        try conn.run("INSERT INTO text_fts(rowid, body) VALUES (?, ?);",
                     [.int(vrow), .text(index.body)])
        // 折叠改动了原文 ⇒ 这个库里有全角 / 兼容区正文，扫描通道以后要展开查询串才不会漏。
        if index.foldedDiffers { try markCompatibilityText(conn: conn) }
        return (tvID, true)
    }

    // MARK: - 运行期事件与遥测

    /// 运行期事件（权限变化、暂停 / 继续、锁定状态机转移、登录项注册）写 `jobs`：
    /// `type = 'runtime_event:<kind>'`、`state = 'done'`、`input_ref` 放细节 JSON。
    ///
    /// 为什么不另立一张表：3.2 的 `jobs` 就是"可停止、可重建的处理任务"，运行期事件是它的
    /// 零工作量特例；多一张表就多一处删除级联与同步口径要维护。真正的遥测（帧门控、dHash）
    /// 走 `capture_stats`，那是另一回事。
    @discardableResult
    public func recordRuntimeEvent(kind: String, detail: String? = nil,
                                   at ts: Int64? = nil) throws -> Int64 {
        try withLock { conn in
            let now = ts ?? Int64(Date().timeIntervalSince1970 * 1000)
            try conn.run("""
                INSERT INTO jobs(type, state, input_ref, output_ref, created_at, updated_at, error)
                VALUES (?, 'done', ?, NULL, ?, ?, NULL);
                """, [.text("runtime_event:" + kind), .optionalText(detail), .int(now), .int(now)])
            return conn.lastInsertRowID
        }
    }

    /// 采集遥测（承接 M0 的 `frame_stats`）。不是 3.2 的表、不同步、不进删除级联。
    @discardableResult
    public func recordCaptureStat(ts: Int64,
                                  displayID: Int64? = nil,
                                  status: String,
                                  trigger: String? = nil,
                                  width: Int? = nil,
                                  height: Int? = nil,
                                  contentScale: Double? = nil,
                                  dhash: String? = nil,
                                  hamming: Int? = nil,
                                  dirtyRects: Int? = nil,
                                  dirtyAreaRatio: Double? = nil,
                                  gated: Bool = false,
                                  axChars: Int? = nil,
                                  ocrRegions: Int? = nil) throws -> Int64 {
        try withLock { conn in
            try conn.run("""
                INSERT INTO capture_stats
                  (ts, display_id, status, "trigger", width, height, content_scale,
                   dhash, hamming, dirty_rects, dirty_area_ratio, gated, ax_chars, ocr_regions)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """, [
                    .int(ts), .optionalInt(displayID), .text(status), .optionalText(trigger),
                    .optionalInt(width.map(Int64.init)), .optionalInt(height.map(Int64.init)),
                    contentScale.map { SQLValue.double($0) } ?? .null,
                    .optionalText(dhash), .optionalInt(hamming.map(Int64.init)),
                    .optionalInt(dirtyRects.map(Int64.init)),
                    dirtyAreaRatio.map { SQLValue.double($0) } ?? .null,
                    .int(gated ? 1 : 0), .optionalInt(axChars.map(Int64.init)),
                    .optionalInt(ocrRegions.map(Int64.init)),
                ])
            return conn.lastInsertRowID
        }
    }

    // MARK: - 3.12 应用采集策略

    public func setAppPolicy(bundleID: String, mode: CapturePolicyMode,
                             source: CapturePolicySource = .user) throws {
        try withLock { conn in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try conn.run("""
                INSERT INTO app_policies(bundle_id, mode, source, updated_at) VALUES (?,?,?,?)
                ON CONFLICT(bundle_id) DO UPDATE
                  SET mode = excluded.mode, source = excluded.source, updated_at = excluded.updated_at;
                """, [.text(bundleID), .text(mode.rawValue), .text(source.rawValue), .int(now)])
        }
    }

    public func appPolicy(bundleID: String) throws -> (mode: CapturePolicyMode, source: CapturePolicySource)? {
        try withLock { conn in
            let st = try conn.prepare("SELECT mode, source FROM app_policies WHERE bundle_id = ?;")
            defer { st.finalize() }
            try st.bind([.text(bundleID)])
            guard try st.step(),
                  let mode = st.text(0).flatMap(CapturePolicyMode.init(rawValue:)),
                  let source = st.text(1).flatMap(CapturePolicySource.init(rawValue:)) else { return nil }
            return (mode, source)
        }
    }

    // MARK: - 派生结果（T3 会用；这里只提供写入与 stale 标记所需的最小面）

    @discardableResult
    public func insertSession(start: Int64, end: Int64, displayID: Int64?, primaryAppID: Int64?,
                              dwellS: Double, activeS: Double, unknownS: Double,
                              interruptions: Int, evidenceObservationIDs: [Int64]) throws -> Int64 {
        try withLock { conn in
            let id = (try conn.scalarInt("SELECT COALESCE(MAX(id),0) FROM sessions WHERE device_id = ?;",
                                         [.text(deviceID)]) ?? 0) + 1
            let evidence = try jsonString(evidenceObservationIDs)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try conn.run("""
                INSERT INTO sessions(device_id, id, start, "end", display_id, primary_app_id,
                                     dwell_s, active_s, unknown_s, interruptions, evidence, stale, computed_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,0,?);
                """, [
                    .text(deviceID), .int(id), .int(start), .int(end),
                    .optionalInt(displayID), .optionalInt(primaryAppID),
                    .double(dwellS), .double(activeS), .double(unknownS),
                    .int(Int64(interruptions)), .text(evidence), .int(now),
                ])
            return id
        }
    }

    @discardableResult
    public func insertLedger(level: String, period: String, ledgerJSON: String,
                             narrative: String? = nil, model: String? = nil,
                             evidenceObservationIDs: [Int64]) throws -> Int64 {
        try withLock { conn in
            let id = (try conn.scalarInt("SELECT COALESCE(MAX(id),0) FROM ledgers WHERE device_id = ?;",
                                         [.text(deviceID)]) ?? 0) + 1
            let evidence = try jsonString(evidenceObservationIDs)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try conn.run("""
                INSERT INTO ledgers(device_id, id, level, period, ledger, narrative, model,
                                    evidence, stale, computed_at)
                VALUES (?,?,?,?,?,?,?,?,0,?);
                """, [
                    .text(deviceID), .int(id), .text(level), .text(period), .text(ledgerJSON),
                    .optionalText(narrative), .optionalText(model), .text(evidence), .int(now),
                ])
            return id
        }
    }

    func jsonString(_ ids: [Int64]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ids, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 崩溃恢复测试专用

    /// **只给崩溃恢复测试用**（`brosis-store crash-after`）：开一个事务写入若干条观察但
    /// **不提交**就返回，把连接留在事务中间，让调用方紧接着 `kill -9` 自己。
    ///
    /// 目的是把 SIGKILL 精确打在未提交事务里，验证重开库后整批回滚、
    /// `integrity_check` / `foreign_key_check` / 13 项悬空检查仍然干净（E3 的 S6）。
    /// 产品路径永远不要调用它。
    public func writeUncommittedForCrashTest(_ inputs: [ObservationInput]) throws {
        try withLock { conn in
            try conn.begin()
            for input in inputs { _ = try recordUnlocked(input, conn: conn) }
            // 故意不 commit
        }
    }
}
