import Foundation

// =============================================================================
// 周台账（计划 3.6「周台账放 M2」、3.7 台账口径）
//
// 口径三句话：
//   ① 周 = **7 个日台账之和**，不在一条连续的周观察流上重算。
//   ② 因此「周 = 7 天逐字段之和」是可断言的不变量（`WeekLedgerPatternsTests` 断言了它）。
//   ③ 也因此增量成立：只有变过的那几天要重算，其余天读 `ledgers` 表的缓存。
//
// 已知的定义差异（不是误差，写在这里免得被当成 bug）：
//   - `switches`：7 天各自「切入次数」的和。跨午夜连续使用同一个应用时，两天各记一次切入。
//   - `sessions`：7 天各自会话数的和。跨午夜的会话在相邻两天各记一次（与日台账同一口径，
//     `sessionRows` 按「start 落在窗口内 或 尾巴伸进窗口」取行）。
//   - `onlineUnionS`：7 天并集之和。天与天不重叠，所以它**等于**整周的并集，没有差异。
// =============================================================================

extension Store {

    /// 3.6 的 `get_week_ledger`。`weekStart` 可以写 `YYYY-Www`，也可以写周内任意一天的
    /// `YYYY-MM-DD`（内部对齐到那一周的周一）。
    ///
    /// - `recompute = true`：7 天全部强制重算，周台账也重算。
    @discardableResult
    public func getWeekLedger(weekStart: String, recompute: Bool = false) throws -> WeekLedger {
        let options = retrieval
        let t0 = Int64(Date().timeIntervalSince1970 * 1000)
        return try withLock { conn in
            let cal = DayCalendar(options.timeZone)
            let weekCal = PatternCalendar(options.timeZone)
            let bounds = try weekCal.weekBounds(weekStart)
            let period = weekCal.weekString(bounds.start)
            let dayStarts = weekCal.daysOfWeek(bounds.start)
            let dayStrings = dayStarts.map { weekCal.dayString($0) }

            // ① 先把 7 天各自的日台账拿到手（缓存有效的直接读回，指纹不符或被标脏的重算）。
            var days: [DayLedger] = []
            var recomputed: [String] = []
            days.reserveCapacity(7)
            for date in dayStrings {
                let ledger = try dayLedgerUnlocked(date: date, recompute: recompute,
                                                   cal: cal, conn: conn)
                if ledger.computedAt >= t0 { recomputed.append(date) }
                days.append(ledger)
            }

            // ② 缓存里那份周台账还对得上吗：7 天的 computedAt 一个都没变才算数。
            if !recompute, var cached = try cachedWeekLedger(period: period, conn: conn) {
                let current = Dictionary(uniqueKeysWithValues:
                    zip(dayStrings, days.map(\.computedAt)))
                let inCache = Dictionary(uniqueKeysWithValues:
                    cached.dayTotals.map { ($0.date, $0.dayComputedAt) })
                if current == inCache {
                    cached.servedFromCache = true
                    cached.daysRecomputed = []
                    return cached
                }
            }

            let ledger = Self.aggregateWeek(period: period, timeZone: cal.timeZone.identifier,
                                            start: bounds.start, end: bounds.end,
                                            dayStrings: dayStrings, dayStarts: dayStarts,
                                            days: days, weekCal: weekCal,
                                            sessionConfig: sessionConfig,
                                            daysRecomputed: recomputed)
            try conn.transaction { try upsertWeekLedger(ledger, conn: conn) }
            return ledger
        }
    }

    /// 库里有观察的所有 ISO 周（`YYYY-Www`）。CLI 的 `week-ledger --weeks` 用它列清单。
    public func observationWeeks() throws -> [String] {
        let options = retrieval
        return try withLock { conn in
            let weekCal = PatternCalendar(options.timeZone)
            let bounds = try conn.intPairs("""
                SELECT COALESCE(MIN(ts),0), COALESCE(MAX(ts),-1) FROM observations
                 WHERE device_id = ? AND origin_device IS NULL AND deleted_at IS NULL;
                """, [.text(deviceID)])
            guard let (lo, hi) = bounds.first, hi >= lo else { return [] }
            var out: [String] = []
            var cursor = weekCal.weekStart(lo)
            while cursor <= hi {
                out.append(weekCal.weekString(cursor))
                let next = weekCal.weekEnd(cursor)
                // `weekEnd` 在日历算不出来时会回退成"原样返回"，那会让这个循环转不出去。
                // 正常数据走不到这里；写上是因为它是本文件里唯一一个上界靠数据决定的循环。
                guard next > cursor else { break }
                cursor = next
            }
            return out
        }
    }

    // MARK: - 聚合

    /// 纯函数：7 份日台账 → 一份周台账。没有 I/O，测试可以直接喂构造好的日台账。
    static func aggregateWeek(period: String, timeZone: String, start: Int64, end: Int64,
                              dayStrings: [String], dayStarts: [Int64], days: [DayLedger],
                              weekCal: PatternCalendar, sessionConfig: SessionConfig,
                              daysRecomputed: [String]) -> WeekLedger {
        var apps: [String: LedgerAccumulator] = [:]
        var sites: [String: LedgerAccumulator] = [:]
        var files: [String: LedgerAccumulator] = [:]
        var perDisplay: [String: Double] = [:]
        var dwell = 0.0, active = 0.0, unknown = 0.0, focus = 0.0, online = 0.0
        var switches = 0, interruptions = 0, sessions = 0, observations = 0
        var evidence: [[Int64]] = []
        var dayTotals: [WeekDayTotal] = []
        var activeDays = 0

        func merge(_ into: inout [String: LedgerAccumulator], _ entries: [LedgerEntry]) {
            for e in entries {
                var acc = into[e.key] ?? LedgerAccumulator(name: e.name)
                if acc.name == nil { acc.name = e.name }
                acc.dwellMS += Int64((e.dwellS * 1000).rounded())
                acc.activeMS += Int64((e.activeS * 1000).rounded())
                acc.unknownMS += Int64((e.unknownS * 1000).rounded())
                acc.switches += e.switches
                acc.observations += e.observations
                into[e.key] = acc
            }
        }

        for (index, day) in days.enumerated() {
            merge(&apps, day.apps)
            merge(&sites, day.sites)
            merge(&files, day.files)
            for (k, v) in day.perDisplayDwellS { perDisplay[k, default: 0] += v }
            dwell += day.totalDwellS
            active += day.totalActiveS
            unknown += day.totalUnknownS
            focus += day.focusDwellS
            online += day.onlineUnionS
            switches += day.switches
            interruptions += day.interruptions
            sessions += day.sessions
            observations += day.observations
            evidence += day.evidence
            let hasData = day.observations > 0
            if hasData { activeDays += 1 }
            dayTotals.append(WeekDayTotal(
                date: dayStrings[index], weekday: weekCal.weekdayIndex(dayStarts[index]),
                dwellS: day.totalDwellS, activeS: day.totalActiveS, unknownS: day.totalUnknownS,
                onlineUnionS: day.onlineUnionS, switches: day.switches,
                interruptions: day.interruptions, sessions: day.sessions,
                observations: day.observations, hasData: hasData,
                dayComputedAt: day.computedAt))
        }

        return WeekLedger(
            week: period, timeZone: timeZone, start: start, end: end, days: dayStrings,
            totalDwellS: dwell, totalActiveS: active, totalUnknownS: unknown,
            focusDwellS: focus, onlineUnionS: online, perDisplayDwellS: perDisplay,
            apps: Self.sortedEntries(apps), sites: Self.sortedEntries(sites),
            files: Self.sortedEntries(files),
            switches: switches, interruptions: interruptions, sessions: sessions,
            observations: observations, activeDays: activeDays, dayTotals: dayTotals,
            evidence: Self.mergeIntervals(evidence),
            narrative: nil, model: nil,            // 3.7：台账与叙述分开标注
            sessionConfig: sessionConfig, stale: false,
            computedAt: Int64(Date().timeIntervalSince1970 * 1000),
            daysRecomputed: daysRecomputed, servedFromCache: false)
    }

    /// D23 的区间表示：把若干组 `[[lo, hi], …]` 合并成一组不重叠、不相邻的区间。
    static func mergeIntervals(_ intervals: [[Int64]]) -> [[Int64]] {
        let valid = intervals.filter { $0.count == 2 && $0[1] >= $0[0] }
            .sorted { $0[0] == $1[0] ? $0[1] < $1[1] : $0[0] < $1[0] }
        guard !valid.isEmpty else { return [] }
        var out: [[Int64]] = [valid[0]]
        for pair in valid.dropFirst() {
            let last = out[out.count - 1]
            // `lo <= hi + 1`：观察 id 是整数，[1,3] 与 [4,5] 相邻，合成 [1,5]。
            if pair[0] <= last[1] + 1 {
                out[out.count - 1] = [last[0], max(last[1], pair[1])]
            } else {
                out.append(pair)
            }
        }
        return out
    }

    // MARK: - 读写 ledgers 表

    private func cachedWeekLedger(period: String, conn: SQLiteConnection) throws -> WeekLedger? {
        let st = try conn.prepare("""
            SELECT ledger, stale, narrative, model, narrative_meta FROM ledgers
             WHERE device_id = ? AND level = 'week' AND period = ?;
            """)
        defer { st.finalize() }
        try st.bind([.text(deviceID), .text(period)])
        guard try st.step(), let json = st.text(0), (st.int(1) ?? 0) == 0 else { return nil }
        guard var ledger = try? JSONDecoder().decode(WeekLedger.self, from: Data(json.utf8)) else {
            return nil
        }
        // 与日台账同一处理：叙述与它的标注写在列上、不在 JSON 里，读回来要合进去（3.7 分开标注）。
        // `narrative_meta` 解不出来就当没有，不让一段坏 JSON 挡住整份台账。
        ledger.narrative = st.text(2)
        ledger.model = st.text(3)
        if let metaJSON = st.text(4) {
            ledger.narrativeMeta = try? JSONDecoder().decode(NarrativeMeta.self,
                                                             from: Data(metaJSON.utf8))
        }
        return ledger
    }

    private func upsertWeekLedger(_ ledger: WeekLedger, conn: SQLiteConnection) throws {
        var toStore = ledger
        // 存进去的那份不带"这次是不是走缓存"的运行时标记，也不带叙述
        // （叙述在独立列上，3.7 要求与台账分开标注）。
        toStore.servedFromCache = false
        toStore.narrative = nil
        toStore.model = nil
        toStore.narrativeMeta = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ledgerJSON = String(decoding: try encoder.encode(toStore), as: UTF8.self)
        let evidenceJSON = String(decoding: try JSONSerialization.data(
            withJSONObject: ledger.evidence, options: []), as: UTF8.self)
        let now = ledger.computedAt
        let existing = try conn.scalarInt("""
            SELECT id FROM ledgers WHERE device_id = ? AND level = 'week' AND period = ?;
            """, [.text(deviceID), .text(ledger.week)])
        if let existing {
            // narrative / model / narrative_meta 一并置回 NULL：台账重算了，
            // 旧叙述不再对得上这份台账（与日台账 `upsertLedger` 同一条规矩）。
            try conn.run("""
                UPDATE ledgers SET ledger = ?, narrative = NULL, model = NULL,
                                   narrative_meta = NULL,
                                   evidence = ?, stale = 0, computed_at = ?
                 WHERE device_id = ? AND id = ?;
                """, [.text(ledgerJSON), .text(evidenceJSON), .int(now),
                      .text(deviceID), .int(existing)])
        } else {
            let id = (try conn.scalarInt("SELECT COALESCE(MAX(id),0) FROM ledgers WHERE device_id = ?;",
                                         [.text(deviceID)]) ?? 0) + 1
            try conn.run("""
                INSERT INTO ledgers(device_id, id, level, period, ledger, narrative, model,
                                    narrative_meta, evidence, stale, computed_at)
                VALUES (?,?, 'week', ?, ?, NULL, NULL, NULL, ?, 0, ?);
                """, [.text(deviceID), .int(id), .text(ledger.week), .text(ledgerJSON),
                      .text(evidenceJSON), .int(now)])
        }
    }
}
