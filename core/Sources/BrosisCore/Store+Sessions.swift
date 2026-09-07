import Foundation

// =============================================================================
// 会话化（计划 3.7）
//
// - 三类时间分列：前台停留 dwell、有输入的活跃 active、未知 unknown（权限丢失 / 超时 / 锁定）。
// - 双屏：时长按**焦点窗口归属**（每块屏各自一条焦点流，会话按 (display, app) 切），
//   另算区间**并集**作为「总在线」，两者都报告、不重复计。
// - 三个常量（停留上限 90 s、间隔 300 s、打断 20 s）是 `Store.sessionConfig` 里的可配置参数。
// - 增量构建：只重算水位线之后的观察；被删除标 stale 的会话卷进这次重算。
// =============================================================================

extension Store {

    /// 一条观察折算出的时间片。`[ts, end)` 半开。
    struct ObservationSlice {
        var id: Int64
        var ts: Int64
        var end: Int64
        var displayID: Int64?
        var appID: Int64?
        var kind: TimeBucketKind
        // 台账要按应用 / 站点 / 文件分组，`withLabels: true` 时才填。
        var appBundleID: String?
        var appName: String?
        var host: String?
        var filePath: String?

        var durationMS: Int64 { max(0, end - ts) }
        /// 截到 `[lo, hi)` 之后的毫秒数（台账按自然日切分要用）。
        func clipped(_ lo: Int64, _ hi: Int64) -> Int64 {
            max(0, min(end, hi) - max(ts, lo))
        }
    }

    /// 把观察流折算成时间片。
    ///
    /// **一条观察代表的时长 = 到「同一块屏上的下一条观察」为止，上限 `maxDwellSeconds`**
    /// （3.7 的「停留上限 90 s」就是这个上限；超过它说明中间那段没有证据，不记时长）。
    /// 每块屏最后一条观察没有下一条，记 0——不给未来的时间记账。
    func observationSlices(from: Int64?, to: Int64?, withLabels: Bool = false,
                           conn: SQLiteConnection) throws -> [ObservationSlice] {
        let maxDwellMS = Int64(sessionConfig.maxDwellSeconds * 1000)
        var sql: String
        if withLabels {
            sql = """
                SELECT o.id, o.ts, o.display_id, o.app_id, o.source_state,
                       a.bundle_id, a.name, u.host, f.path
                  FROM observations o
                  LEFT JOIN apps  a ON a.id = o.app_id
                  LEFT JOIN urls  u ON u.id = o.url_id
                  LEFT JOIN files f ON f.id = o.file_id
                 WHERE o.device_id = ? AND o.deleted_at IS NULL
                """
        } else {
            sql = """
                SELECT o.id, o.ts, o.display_id, o.app_id, o.source_state
                  FROM observations o
                 WHERE o.device_id = ? AND o.deleted_at IS NULL
                """
        }
        var binds: [SQLValue] = [.text(deviceID)]
        if let from { sql += " AND o.ts >= ?"; binds.append(.int(from)) }
        if let to { sql += " AND o.ts < ?"; binds.append(.int(to)) }
        sql += " ORDER BY o.ts, o.id;"

        let st = try conn.prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        var slices: [ObservationSlice] = []
        var lastIndexByDisplay: [Int64: Int] = [:]      // display_id（nil 记成 -1）→ 上一条的下标
        while try st.step() {
            guard let id = st.int(0) else { continue }
            let ts = st.int(1) ?? 0
            let display = st.int(2)
            var slice = ObservationSlice(id: id, ts: ts, end: ts, displayID: display,
                                         appID: st.int(3),
                                         kind: TimeBucketKind.of(sourceState: st.text(4) ?? "ok"))
            if withLabels {
                slice.appBundleID = st.text(5)
                slice.appName = st.text(6)
                slice.host = st.text(7)
                slice.filePath = st.text(8)
            }
            let key = display ?? -1
            if let prev = lastIndexByDisplay[key] {
                slices[prev].end = min(ts, slices[prev].ts + maxDwellMS)
            }
            slices.append(slice)
            lastIndexByDisplay[key] = slices.count - 1
        }
        return slices
    }

    // MARK: - 会话切分

    struct SessionAccumulator {
        var displayID: Int64?
        var appID: Int64?
        var start: Int64
        var end: Int64
        var lastTS: Int64
        var dwellMS: Int64 = 0
        var activeMS: Int64 = 0
        var unknownMS: Int64 = 0
        var interruptions: Int = 0
        var ids: [Int64] = []
    }

    /// 按 (display, app) 切会话。两条规则：
    /// 1. 同一 (display, app) 的相邻观察间隔 ≥ `gapSeconds` → 切成两个会话；
    /// 2. 中途切到别的应用又切回来，离开时长 < `interruptionSeconds` → **不切**，记一次打断。
    func splitSessions(_ slices: [ObservationSlice]) -> [SessionAccumulator] {
        let gapMS = Int64(sessionConfig.gapSeconds * 1000)
        let interruptMS = Int64(sessionConfig.interruptionSeconds * 1000)

        // 先按屏分流：双屏的时长按焦点窗口归属，两块屏各自是一条焦点流。
        var byDisplay: [Int64: [ObservationSlice]] = [:]
        for s in slices { byDisplay[s.displayID ?? -1, default: []].append(s) }

        var out: [SessionAccumulator] = []
        for key in byDisplay.keys.sorted() {
            let stream = byDisplay[key]!            // 已经按 ts, id 排好
            var sessions: [SessionAccumulator] = []
            var currentIndex: Int?                  // 时间上「正在进行」的那个会话
            var lastIndexByApp: [Int64: Int] = [:]  // app_id（nil 记成 -1）→ 该应用最近一个会话

            for slice in stream {
                let appKey = slice.appID ?? -1

                // ① 同一应用继续，且间隔没到 gapSeconds → 同一个会话。
                if let ci = currentIndex, (sessions[ci].appID ?? -1) == appKey,
                   slice.ts - sessions[ci].lastTS < gapMS {
                    absorb(slice, into: &sessions[ci])
                    continue
                }
                // ② 切走过别的应用又切回来，离开时长 ≤ interruptionSeconds → 记一次打断，接回原会话。
                //
                // 这里是**闭区间**（`≤`），而 ① 的间隔上限是开区间（`<`），不是笔误：
                // 3.7 的原话是「间隔 300 s、打断 20 s」，"间隔"读作"超过就断开"、
                // "打断"读作"20 秒以内算打断"。而且采集是 10 s 一次（E7 口径），
                // 一条观察的外出往返正好是 20 s——用严格小于的话，默认常量下
                // **一次打断都观测不到**，这条口径就等于没有。3.7 已经写明这三个数是
                // 待校准参数不是结论，真实采样率定下来之后要重标。
                if let idx = lastIndexByApp[appKey], idx != currentIndex,
                   slice.ts - sessions[idx].lastTS <= interruptMS {
                    sessions[idx].interruptions += 1
                    absorb(slice, into: &sessions[idx])
                    currentIndex = idx
                    continue
                }
                // ③ 其余情况开新会话。
                var acc = SessionAccumulator(displayID: slice.displayID, appID: slice.appID,
                                             start: slice.ts, end: slice.end, lastTS: slice.ts)
                account(slice, into: &acc)
                acc.ids.append(slice.id)
                sessions.append(acc)
                currentIndex = sessions.count - 1
                lastIndexByApp[appKey] = sessions.count - 1
            }
            out += sessions
        }
        return out.sorted {
            $0.start == $1.start ? ($0.appID ?? -1) < ($1.appID ?? -1) : $0.start < $1.start
        }
    }

    private func absorb(_ slice: ObservationSlice, into acc: inout SessionAccumulator) {
        acc.end = max(acc.end, slice.end)
        acc.lastTS = slice.ts
        acc.ids.append(slice.id)
        account(slice, into: &acc)
    }

    /// 三类时间分列（3.7）：`active ⊆ dwell`，`dwell + unknown` = 会话总时长。
    private func account(_ slice: ObservationSlice, into acc: inout SessionAccumulator) {
        let d = slice.durationMS
        switch slice.kind {
        case .dwellActive: acc.dwellMS += d; acc.activeMS += d
        case .dwellIdle: acc.dwellMS += d
        case .unknown: acc.unknownMS += d
        }
    }

    // MARK: - 构建（全量 / 增量）

    /// 要重算的会话：与重扫区间 `[from, ∞)` 有交叠的那些。
    ///
    /// 判据是 **`"end" > from` 或 `start >= from`**，两条缺一不可：
    /// - `"end" > from`：起点更早、尾巴伸进重扫区间的会话（打断规则把后面的观察吸回早先的
    ///   会话、或者两块屏边界不对齐时必然出现）必须一起重算，否则它里面 `ts >= from` 的观察
    ///   会被重扫再分进一个新会话，**同一条观察进两个会话**。
    /// - `start >= from`：单条观察的会话可能 `start == "end" == from`，上一条判不到。
    ///
    /// 用严格大于而不是 `>=`：相邻两个会话通常**首尾相接**（前一个的 `"end"` 正好等于后一个
    /// 观察的 `ts`，也就是后一个会话的 `start`），写成 `>=` 会一路把整个月的会话串成一条链，
    /// 不动点退到库首，增量就退化成全量了（实测过）。
    static let overlapPredicate = #"("end" > ? OR start >= ?)"#

    /// 增量重算的起点。
    ///
    /// 从锚点 `anchor` = `min(最早一条 stale 会话的 start, 每块屏最后一个会话的 start)`
    /// 再往前留一个 `maxDwellSeconds` 的余量出发（一条观察的时长最多受它后面 90 s 内的观察
    /// 影响，更早的观察不可能因为重扫区间里的增删而改变时长），**往前推到不切开任何会话为止**：
    /// 起点必须 ≤ 所有要重算的会话的 `MIN(start)`；推早之后可能又圈进更早的会话，所以迭代到不动点。
    ///
    /// 收敛之后要的不变量：**留下的会话与重扫区间 `[起点, ∞)` 的观察集合不相交**，
    /// 增量结果因此与全量重建逐字段相等（`SessionLedgerTests` 三个用例断言了这一点）。
    /// 留下的会话满足 `"end" <= 起点` 且 `start < 起点`，而一个会话里每条观察的 `ts <= "end"`，
    /// 所以唯一能越界的是 **`ts == "end" == 起点` 的观察**——这一条要单独判，见
    /// `boundaryStartToInclude`。
    ///
    /// 返回 `nil` 表示迭代没收敛（正常数据下不会发生），调用方退回全量重建。
    private func incrementalRebuildStart(anchor: Int64, conn: SQLiteConnection) throws -> Int64? {
        var from = anchor - Int64(sessionConfig.maxDwellSeconds * 1000) - 1
        for _ in 0..<Self.rebuildStartMaxIterations {
            // ① 起点不能切开会话：与 `[起点, ∞)` 交叠的会话全都要重算，起点取它们的 `MIN(start)`。
            if let earliest = try conn.scalarInt("""
                SELECT MIN(start) FROM sessions WHERE device_id = ? AND \(Self.overlapPredicate);
                """, [.text(deviceID), .int(from), .int(from)]), earliest < from {
                from = earliest                                     // 严格变小，必然终止
                continue
            }
            // ② 边界上的同毫秒观察（R1 第二轮验收的阻断项）：留下的会话里若有谁含着
            //    `ts == 起点` 的观察，把它也卷进来，起点降到它的 `start` 再迭代。
            if let boundary = try boundaryStartToInclude(from: from, conn: conn) {
                from = boundary                                     // 同样严格变小
                continue
            }
            return from                                             // 两条都到不动点
        }
        return nil
    }

    /// 边界上的**同毫秒观察**：`incrementalRebuildStart` 的 ① 单独跑到不动点还不够。
    ///
    /// 同一块屏上两条观察的 `ts` 完全相同是可能的——时间戳是毫秒（记录器取 `Date()`），
    /// schema 上也没有 `(device_id, display_id, ts)` 唯一约束。这时**前一条的时间片长度是 0**
    /// （`end = min(下一条的 ts, ts + 90 s) = ts`），它所在的会话可以满足
    /// `"end" == 起点` 且 `start < 起点`，于是被 ① 留下；可它里面含着 `ts == 起点` 的观察，
    /// 重扫 `[起点, ∞)` 又把这条观察分进一个新会话——**同一条观察进了两个会话**，
    /// 而且再 `--build` 一次也不会自愈（7 条观察就能复现：同屏 `A@T-20s, A@T-10s, A@T, B@T,
    /// B@T+10s, C@T+100s, C@T+110s`，`--force` 3 段、零新观察 `--build` 4 段）。
    ///
    /// 这里只查「留下的会话」里 `"end" == 起点` 的那几个（**通常一个、可能多个**：
    /// 会话按 `(display, app)` 切，同一块屏上多条同毫秒观察分属不同应用时，
    /// 每个应用各留下一个长度为 0、`"end" == 起点` 的会话），
    /// 展开证据看有没有 `ts == 起点` 的观察；有就返回它们的 `MIN(start)`，没有返回 `nil`。
    /// 所以下面是遍历所有命中行取 `MIN(start)`，而不是取"那一个"。
    /// 代价是每轮一次 `observations(device_id, ts)` 的索引点查——绝大多数库里
    /// 边界上根本没有同毫秒观察，这条点查直接空集返回。
    private func boundaryStartToInclude(from: Int64, conn: SQLiteConnection) throws -> Int64? {
        let atBoundary = try conn.intColumn("""
            SELECT id FROM observations
             WHERE device_id = ? AND ts = ? AND deleted_at IS NULL;
            """, [.text(deviceID), .int(from)])
        guard !atBoundary.isEmpty else { return nil }
        let boundaryIDs = Set(atBoundary)
        // `start` 的下界用最长会话时长（`"end" - start <= maxDuration` 对每个会话都成立），
        // 好让这条查询走 `idx_sessions_range` 而不是把整张 sessions 表扫一遍。
        let maxDuration = try metaInt("sessions_max_duration_ms", conn: conn) ?? 0
        let st = try conn.prepare("""
            SELECT start, evidence FROM sessions
             WHERE device_id = ? AND start >= ? AND start < ? AND "end" = ?;
            """)
        defer { st.finalize() }
        try st.bind([.text(deviceID), .int(from - maxDuration), .int(from), .int(from)])
        var earliest: Int64?
        while try st.step() {
            let start = st.int(0) ?? 0
            let ids = evidenceObservationIDs(st.text(1) ?? "[]")
            guard ids.contains(where: boundaryIDs.contains) else { continue }
            earliest = min(earliest ?? start, start)
        }
        return earliest
    }

    /// 不动点迭代的次数上限。每一轮起点都严格变小，正常数据一两轮就收敛。
    static let rebuildStartMaxIterations = 64

    /// 重建会话。
    ///
    /// - `force = false`（默认）：**增量**。起点由 `incrementalRebuildStart` 定
    ///   （锚点 = 水位线一侧的「每块屏最后一个会话」与最早一条 `stale` 会话里更靠前的那个，
    ///   再往前推到不切开任何会话的不动点）；更早的会话原样保留，结果与全量重建逐字段相等。
    /// - `force = true`：清掉全部会话从头算（改了 `sessionConfig` 之后必须这么做）。
    @discardableResult
    public func buildSessions(force: Bool = false) throws -> SessionBuildReport {
        let t0 = Date()
        return try withLock { conn in
            try conn.transaction { try buildSessionsUnlocked(force: force, t0: t0, conn: conn) }
        }
    }

    private func buildSessionsUnlocked(force: Bool, t0: Date,
                                       conn: SQLiteConnection) throws -> SessionBuildReport {
        let staleMin = try conn.scalarInt(
            "SELECT MIN(start) FROM sessions WHERE device_id = ? AND stale = 1;", [.text(deviceID)])
        let staleCount = Int(try conn.scalarInt(
            "SELECT COUNT(*) FROM sessions WHERE device_id = ? AND stale = 1;", [.text(deviceID)]) ?? 0)
        let watermark = try metaInt("sessions_watermark_ts", conn: conn)

        // 每块屏「最后一个会话」的起点里最早的那个：新观察只可能把这些会话往后延长
        // （每块屏最后一条观察原来记 0 s，来了下一条才算得出时长），所以这些会话必须重算。
        let lastPerDisplay = try conn.scalarInt("""
            SELECT MIN(s) FROM (SELECT MAX(start) AS s FROM sessions WHERE device_id = ?
                                 GROUP BY COALESCE(display_id, -1));
            """, [.text(deviceID)])

        var rebuildFrom: Int64?
        var incremental = false
        if !force, watermark != nil {
            var candidates: [Int64] = []
            if let staleMin { candidates.append(staleMin) }
            if let lastPerDisplay { candidates.append(lastPerDisplay) }
            if let anchor = candidates.min() {
                // 锚点还不能直接当重算起点：**起点必须落在会话边界上**，见上面那两段注释。
                rebuildFrom = try incrementalRebuildStart(anchor: anchor, conn: conn)
                incremental = rebuildFrom != nil          // 没收敛就退回全量（正确但慢）
            } else {
                incremental = true                        // 库里一个会话都没有，等价于全量
            }
        }

        // 删掉要重算的那部分会话：判据与 `incrementalRebuildStart` 里的完全一样。
        var deleted = 0
        if let rebuildFrom {
            deleted = try conn.run(
                "DELETE FROM sessions WHERE device_id = ? AND \(Self.overlapPredicate);",
                [.text(deviceID), .int(rebuildFrom), .int(rebuildFrom)])
            // stale 会话的 start ≥ staleMin ≥ rebuildFrom，上一条已经删掉了；这条是兜底。
            deleted += try conn.run("DELETE FROM sessions WHERE device_id = ? AND stale = 1;",
                                    [.text(deviceID)])
        } else {
            deleted = try conn.run("DELETE FROM sessions WHERE device_id = ?;", [.text(deviceID)])
        }

        let slices = try observationSlices(from: rebuildFrom, to: nil, conn: conn)
        let accs = splitSessions(slices)

        var nextID = (try conn.scalarInt("SELECT COALESCE(MAX(id), 0) FROM sessions WHERE device_id = ?;",
                                         [.text(deviceID)]) ?? 0) + 1
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var maxDuration = try metaInt("sessions_max_duration_ms", conn: conn) ?? 0
        if rebuildFrom == nil { maxDuration = 0 }
        for acc in accs {
            try conn.run("""
                INSERT INTO sessions(device_id, id, start, "end", display_id, primary_app_id,
                                     dwell_s, active_s, unknown_s, interruptions, evidence,
                                     stale, computed_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,0,?);
                """, [
                    .text(deviceID), .int(nextID), .int(acc.start), .int(acc.end),
                    .optionalInt(acc.displayID), .optionalInt(acc.appID),
                    .double(Double(acc.dwellMS) / 1000.0), .double(Double(acc.activeMS) / 1000.0),
                    .double(Double(acc.unknownMS) / 1000.0), .int(Int64(acc.interruptions)),
                    .text(try Self.intervalEvidenceJSON(acc.ids)), .int(now),
                ])
            nextID += 1
            maxDuration = max(maxDuration, acc.end - acc.start)
        }

        let newWatermark = try conn.scalarInt(
            "SELECT MAX(ts) FROM observations WHERE device_id = ? AND deleted_at IS NULL;",
            [.text(deviceID)])
        try setMeta("sessions_watermark_ts", newWatermark.map(String.init), conn: conn)
        // 区间查询要用它给 start 补下界（E7 §10.3），所以必须持久化。
        try setMeta("sessions_max_duration_ms", String(maxDuration), conn: conn)
        try setMeta("sessions_config",
                    "maxDwellS=\(sessionConfig.maxDwellSeconds),gapS=\(sessionConfig.gapSeconds),"
                    + "interruptionS=\(sessionConfig.interruptionSeconds)", conn: conn)

        return SessionBuildReport(fromTS: rebuildFrom, incremental: incremental,
                                  observationsScanned: slices.count,
                                  sessionsDeleted: deleted, sessionsInserted: accs.count,
                                  staleRecomputed: staleCount, watermarkTS: newWatermark,
                                  elapsedMS: Date().timeIntervalSince(t0) * 1000)
    }

    /// D23 的区间表示：把连续的 id 压成 `[[lo, hi], …]`。
    /// `markDerivedStale` / `evidenceObservationIDs` 两边都认这个形状。
    static func intervalEvidenceJSON(_ ids: [Int64]) throws -> String {
        let sorted = ids.sorted()
        var intervals: [[Int64]] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            intervals.append([sorted[i], sorted[j]])
            i = j + 1
        }
        let data = try JSONSerialization.data(withJSONObject: intervals, options: [])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 读

    /// 区间查询。**给 `start` 补下界**（E7 §10.3：不补下界时 12 个月库 6.42 ms，补了 0.07 ms）。
    /// 下界用的是构建时实测的最长会话时长（存在 `meta.sessions_max_duration_ms`），
    /// 不是硬编码的 24 h，也不是 3.7 的 90 s——90 s 是单条观察的停留上限，不是会话长度上界。
    public func sessions(from start: Int64, to end: Int64,
                         includeStale: Bool = false) throws -> [SessionRow] {
        try withLock { conn in try sessionRows(from: start, to: end,
                                               includeStale: includeStale, conn: conn) }
    }

    /// `app_id → (bundle_id, name)`。`apps` 表很小（本轮 6 行），一次读进来比在
    /// 25.9 万行的观察上做 LEFT JOIN 便宜得多——聚合类查询只要应用名，不要 urls / files。
    func appMap(conn: SQLiteConnection) throws -> [Int64: (bundleID: String, name: String)] {
        let st = try conn.prepare("SELECT id, bundle_id, name FROM apps;")
        defer { st.finalize() }
        var out: [Int64: (String, String)] = [:]
        while try st.step() {
            guard let id = st.int(0) else { continue }
            out[id] = (st.text(1) ?? "", st.text(2) ?? "")
        }
        return out
    }

    func sessionRows(from start: Int64, to end: Int64, includeStale: Bool,
                     includeEvidence: Bool = true,
                     conn: SQLiteConnection) throws -> [SessionRow] {
        let maxDuration = try metaInt("sessions_max_duration_ms", conn: conn) ?? 0
        var sql = """
            SELECT s.id, s.start, s."end", s.display_id, s.primary_app_id, a.bundle_id, a.name,
                   s.dwell_s, s.active_s, s.unknown_s, s.interruptions, s.evidence, s.stale
              FROM sessions s LEFT JOIN apps a ON a.id = s.primary_app_id
             WHERE s.device_id = ? AND s.start >= ? AND s.start < ? AND s."end" > ?
            """
        if !includeStale { sql += " AND s.stale = 0" }
        sql += " ORDER BY s.start, s.id;"
        let st = try conn.prepare(sql)
        defer { st.finalize() }
        try st.bind([.text(deviceID), .int(start - maxDuration), .int(end), .int(start)])
        var out: [SessionRow] = []
        while try st.step() {
            // 证据区间展开成 id 数组是有代价的（一天几百段会话、每段几十条观察），
            // 只在调用方真的要用的时候做。
            let ids = includeEvidence ? evidenceObservationIDs(st.text(11) ?? "[]") : []
            out.append(SessionRow(
                id: st.int(0) ?? 0, start: st.int(1) ?? 0, end: st.int(2) ?? 0,
                displayID: st.int(3), appID: st.int(4), appBundleID: st.text(5), appName: st.text(6),
                dwellS: st.double(7) ?? 0, activeS: st.double(8) ?? 0, unknownS: st.double(9) ?? 0,
                interruptions: Int(st.int(10) ?? 0),
                observationIDs: ids,
                stale: (st.int(12) ?? 0) == 1))
        }
        return out
    }

    public func sessionCount(includeStale: Bool = true) throws -> Int {
        try withLock { conn in
            let sql = includeStale
                ? "SELECT COUNT(*) FROM sessions WHERE device_id = ?;"
                : "SELECT COUNT(*) FROM sessions WHERE device_id = ? AND stale = 0;"
            return Int(try conn.scalarInt(sql, [.text(deviceID)]) ?? 0)
        }
    }

    // MARK: - meta 小工具

    func metaInt(_ key: String, conn: SQLiteConnection) throws -> Int64? {
        try conn.scalarText("SELECT value FROM meta WHERE key = ?;", [.text(key)]).flatMap(Int64.init)
    }

    func setMeta(_ key: String, _ value: String?, conn: SQLiteConnection) throws {
        guard let value else {
            try conn.run("DELETE FROM meta WHERE key = ?;", [.text(key)])
            return
        }
        try conn.run("INSERT INTO meta(key, value) VALUES (?, ?) "
                   + "ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                     [.text(key), .text(value)])
    }
}
