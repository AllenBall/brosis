import Foundation

// =============================================================================
// 日台账与时间线（计划 3.7 / 3.6）
//
// 台账是**确定性**的：同样的观察算出同样的数，不经过任何模型。`narrative` 恒为 NULL，
// 叙述是 M2 的可选夜间任务，与台账分开标注（3.7）。
// =============================================================================

/// 台账聚合器：一个 key（应用 / 站点 / 文件）攒一行。
struct LedgerAccumulator {
    var name: String?
    var dwellMS: Int64 = 0
    var activeMS: Int64 = 0
    var unknownMS: Int64 = 0
    var switches: Int = 0
    var observations: Int = 0

    func entry(key: String) -> LedgerEntry {
        LedgerEntry(key: key, name: name,
                    dwellS: Double(dwellMS) / 1000.0,
                    activeS: Double(activeMS) / 1000.0,
                    unknownS: Double(unknownMS) / 1000.0,
                    switches: switches, observations: observations)
    }
}

extension Store {

    // MARK: - 通用聚合

    /// 把一段时间片按某个 key 聚合，同时数「切换次数」。
    ///
    /// 切换次数的口径：在**每块屏各自的**观察流里，当前 key 从别的值变成这个值算一次切入。
    /// 第一条观察也算一次（一天里第一次用到这个应用）。
    static func aggregate(_ slices: [Store.ObservationSlice], clipTo range: (Int64, Int64)?,
                          key: (Store.ObservationSlice) -> (key: String, name: String?)?)
        -> [String: LedgerAccumulator] {
        var out: [String: LedgerAccumulator] = [:]
        var lastKeyByDisplay: [Int64: String] = [:]
        for slice in slices {
            guard let (k, name) = key(slice) else { continue }
            let ms = range.map { slice.clipped($0.0, $0.1) } ?? slice.durationMS
            // 时长可能被裁成 0（跨日边界），但「这一天在这个应用里出现过」仍然成立，
            // 所以观察数与切换数按观察本身计，不按时长计。
            if range == nil || (slice.ts >= range!.0 && slice.ts < range!.1) {
                var acc = out[k] ?? LedgerAccumulator(name: name)
                if acc.name == nil { acc.name = name }
                acc.observations += 1
                let display = slice.displayID ?? -1
                if lastKeyByDisplay[display] != k {
                    acc.switches += 1
                    lastKeyByDisplay[display] = k
                }
                switch slice.kind {
                case .dwellActive: acc.dwellMS += ms; acc.activeMS += ms
                case .dwellIdle: acc.dwellMS += ms
                case .unknown: acc.unknownMS += ms
                }
                out[k] = acc
            } else if ms > 0 {
                // 观察落在窗口之前，但它的时间片伸进了窗口：只补时长。
                var acc = out[k] ?? LedgerAccumulator(name: name)
                switch slice.kind {
                case .dwellActive: acc.dwellMS += ms; acc.activeMS += ms
                case .dwellIdle: acc.dwellMS += ms
                case .unknown: acc.unknownMS += ms
                }
                out[k] = acc
            }
        }
        return out
    }

    static func sortedEntries(_ map: [String: LedgerAccumulator]) -> [LedgerEntry] {
        map.map { $0.value.entry(key: $0.key) }
            .sorted { $0.dwellS == $1.dwellS ? $0.key < $1.key : $0.dwellS > $1.dwellS }
    }

    // MARK: - get_day_ledger(date)

    /// 3.6 的 `get_day_ledger(date)`。`date` 是 `YYYY-MM-DD`，按 `retrieval.timeZone` 切自然日。
    ///
    /// 已有且不是 `stale` 的台账直接读回（台账是确定性的，重算只是浪费）；
    /// 缺失、`stale`（被删除级联标脏）或 `recompute = true` 时重算并覆盖。
    @discardableResult
    public func getDayLedger(date: String, recompute: Bool = false) throws -> DayLedger {
        let options = retrieval
        return try withLock { conn in
            let cal = DayCalendar(options.timeZone)
            let bounds = try cal.dayBounds(date)
            if !recompute, let cached = try cachedLedger(level: "day", period: date, conn: conn) {
                return cached
            }
            let ledger = try computeDayLedger(date: date, bounds: bounds, cal: cal, conn: conn)
            try conn.transaction { try upsertLedger(ledger, conn: conn) }
            return ledger
        }
    }

    private func cachedLedger(level: String, period: String,
                              conn: SQLiteConnection) throws -> DayLedger? {
        let st = try conn.prepare("""
            SELECT ledger, stale FROM ledgers WHERE device_id = ? AND level = ? AND period = ?;
            """)
        defer { st.finalize() }
        try st.bind([.text(deviceID), .text(level), .text(period)])
        guard try st.step(), let json = st.text(0), (st.int(1) ?? 0) == 0 else { return nil }
        return try? JSONDecoder().decode(DayLedger.self, from: Data(json.utf8))
    }

    private func computeDayLedger(date: String, bounds: (start: Int64, end: Int64),
                                  cal: DayCalendar, conn: SQLiteConnection) throws -> DayLedger {
        let margin = Int64(sessionConfig.maxDwellSeconds * 1000) + 1000
        // 右边界也要多读 margin：窗口里最后一条观察需要「下一条」才能算出时间片，
        // 否则跨日的那一段会被算成 0（时间片再按 [start, end) 裁开）。
        let slices = try observationSlices(from: bounds.start - margin, to: bounds.end + margin,
                                           withLabels: true, conn: conn)
        let range = (bounds.start, bounds.end)

        let apps = Self.aggregate(slices, clipTo: range) { s in
            guard let b = s.appBundleID else { return nil }
            return (b, s.appName)
        }
        let sites = Self.aggregate(slices, clipTo: range) { s in
            guard let h = s.host, !h.isEmpty else { return nil }
            return (h, nil)
        }
        let files = Self.aggregate(slices, clipTo: range) { s in
            guard let p = s.filePath, !p.isEmpty else { return nil }
            return (p, nil)
        }

        // 三类时间与每屏时长
        var dwellMS: Int64 = 0, activeMS: Int64 = 0, unknownMS: Int64 = 0
        var perDisplay: [String: Int64] = [:]
        var dayIDs: [Int64] = []
        for s in slices {
            let ms = s.clipped(bounds.start, bounds.end)
            switch s.kind {
            case .dwellActive: dwellMS += ms; activeMS += ms
            case .dwellIdle: dwellMS += ms
            case .unknown: unknownMS += ms
            }
            if s.kind != .unknown {
                perDisplay[String(s.displayID ?? -1), default: 0] += ms
            }
            if s.ts >= bounds.start && s.ts < bounds.end { dayIDs.append(s.id) }
        }

        // 双屏：区间并集当作「总在线」，不重复计（3.7）
        let onlineUnion = IntervalMath.unionMilliseconds(
            slices.filter { $0.kind != .unknown }
                  .map { (max($0.ts, bounds.start), min($0.end, bounds.end)) })

        let daySessions = try sessionRows(from: bounds.start, to: bounds.end,
                                          includeStale: false, conn: conn)
        let switches = Self.sortedEntries(apps).reduce(0) { $0 + $1.switches }

        return DayLedger(
            date: date, timeZone: cal.timeZone.identifier,
            start: bounds.start, end: bounds.end,
            apps: Self.sortedEntries(apps), sites: Self.sortedEntries(sites),
            files: Self.sortedEntries(files),
            totalDwellS: Double(dwellMS) / 1000.0,
            totalActiveS: Double(activeMS) / 1000.0,
            totalUnknownS: Double(unknownMS) / 1000.0,
            focusDwellS: Double(dwellMS) / 1000.0,
            onlineUnionS: Double(onlineUnion) / 1000.0,
            perDisplayDwellS: perDisplay.mapValues { Double($0) / 1000.0 },
            switches: switches,
            interruptions: daySessions.reduce(0) { $0 + $1.interruptions },
            sessions: daySessions.count,
            observations: dayIDs.count,
            evidence: Self.intervals(dayIDs),
            narrative: nil, model: nil,           // 3.7：台账与叙述分开标注，M1 不产叙述
            sessionConfig: sessionConfig, stale: false,
            computedAt: Int64(Date().timeIntervalSince1970 * 1000))
    }

    static func intervals(_ ids: [Int64]) -> [[Int64]] {
        let sorted = ids.sorted()
        var out: [[Int64]] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count, sorted[j + 1] == sorted[j] + 1 { j += 1 }
            out.append([sorted[i], sorted[j]])
            i = j + 1
        }
        return out
    }

    private func upsertLedger(_ ledger: DayLedger, conn: SQLiteConnection) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ledgerJSON = String(decoding: try encoder.encode(ledger), as: UTF8.self)
        let evidenceJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: ledger.evidence, options: []), as: UTF8.self)
        let now = ledger.computedAt
        let existing = try conn.scalarInt("""
            SELECT id FROM ledgers WHERE device_id = ? AND level = 'day' AND period = ?;
            """, [.text(deviceID), .text(ledger.date)])
        if let existing {
            // narrative / model 一并置回 NULL：台账重算了，旧叙述不再对得上这份台账。
            try conn.run("""
                UPDATE ledgers SET ledger = ?, narrative = NULL, model = NULL,
                                   evidence = ?, stale = 0, computed_at = ?
                 WHERE device_id = ? AND id = ?;
                """, [.text(ledgerJSON), .text(evidenceJSON), .int(now),
                      .text(deviceID), .int(existing)])
        } else {
            let id = (try conn.scalarInt("SELECT COALESCE(MAX(id),0) FROM ledgers WHERE device_id = ?;",
                                         [.text(deviceID)]) ?? 0) + 1
            try conn.run("""
                INSERT INTO ledgers(device_id, id, level, period, ledger, narrative, model,
                                    evidence, stale, computed_at)
                VALUES (?,?, 'day', ?, ?, NULL, NULL, ?, 0, ?);
                """, [.text(deviceID), .int(id), .text(ledger.date), .text(ledgerJSON),
                      .text(evidenceJSON), .int(now)])
        }
    }

    /// 库里有观察的所有自然日（`YYYY-MM-DD`，按 `retrieval.timeZone`）。
    public func observationDays() throws -> [String] {
        let options = retrieval
        return try withLock { conn in
            let cal = DayCalendar(options.timeZone)
            let bounds = try conn.intPairs("""
                SELECT COALESCE(MIN(ts),0), COALESCE(MAX(ts),-1) FROM observations
                 WHERE device_id = ? AND deleted_at IS NULL;
                """, [.text(deviceID)])
            guard let (lo, hi) = bounds.first, hi >= lo else { return [] }
            var out: [String] = []
            var cursor = cal.bucketStart(lo, .day)
            while cursor <= hi {
                out.append(cal.dayString(cursor))
                cursor = cal.bucketEnd(cursor, .day)
            }
            return out
        }
    }

    // MARK: - get_timeline(start, end, granularity)

    public func getTimeline(start: Int64, end: Int64,
                            granularity: TimelineGranularity) throws -> Timeline {
        guard start < end else { throw StoreError.invalidUsage("时间区间要求 start < end") }
        let options = retrieval
        return try withLock { conn in
            let cal = DayCalendar(options.timeZone)
            let margin = Int64(sessionConfig.maxDwellSeconds * 1000) + 1000
            // 时间线只按应用分组，不需要 urls / files，所以不做那三个 LEFT JOIN，
            // 应用名走 apps 小表的内存映射（7 天窗口 6 万条观察上省掉约 40 ms）。
            let apps = try appMap(conn: conn)
            var slices = try observationSlices(from: start - margin, to: end + margin,
                                               withLabels: false, conn: conn)
            for i in slices.indices {
                if let id = slices[i].appID, let a = apps[id] {
                    slices[i].appBundleID = a.bundleID
                    slices[i].appName = a.name
                }
            }
            var buckets: [TimelineBucket] = []
            var cursor = cal.bucketStart(start, granularity)
            // 时间片按 ts 有序、且每片不超过 maxDwell，所以扫一遍就能分桶，
            // 不要对每个桶都 filter 一遍全量（月 × 小时 = 720 个桶 × 25.9 万片）。
            let maxDwellMS = Int64(sessionConfig.maxDwellSeconds * 1000)
            var lo = 0
            while cursor < end {
                let next = cal.bucketEnd(cursor, granularity)
                let window = (max(cursor, start), min(next, end))
                while lo < slices.count, slices[lo].ts + maxDwellMS <= window.0 { lo += 1 }
                var hi = lo
                while hi < slices.count, slices[hi].ts < window.1 { hi += 1 }
                let inBucket = slices[lo..<hi].filter { $0.end > window.0 }
                let apps = Self.aggregate(inBucket, clipTo: window) { s in
                    guard let b = s.appBundleID else { return nil }
                    return (b, s.appName)
                }
                var dwellMS: Int64 = 0, activeMS: Int64 = 0, unknownMS: Int64 = 0
                var count = 0
                for s in inBucket {
                    let ms = s.clipped(window.0, window.1)
                    switch s.kind {
                    case .dwellActive: dwellMS += ms; activeMS += ms
                    case .dwellIdle: dwellMS += ms
                    case .unknown: unknownMS += ms
                    }
                    if s.ts >= window.0 && s.ts < window.1 { count += 1 }
                }
                let entries = Self.sortedEntries(apps)
                let union = IntervalMath.unionMilliseconds(
                    inBucket.filter { $0.kind != .unknown }
                            .map { (max($0.ts, window.0), min($0.end, window.1)) })
                buckets.append(TimelineBucket(
                    label: cal.bucketLabel(cursor, granularity), start: window.0, end: window.1,
                    observations: count, apps: entries, topApp: entries.first?.key,
                    dwellS: Double(dwellMS) / 1000.0, activeS: Double(activeMS) / 1000.0,
                    unknownS: Double(unknownMS) / 1000.0,
                    onlineUnionS: Double(union) / 1000.0,
                    switches: entries.reduce(0) { $0 + $1.switches }))
                cursor = next
            }
            return Timeline(start: start, end: end, granularity: granularity,
                            timeZone: cal.timeZone.identifier, buckets: buckets)
        }
    }
}
