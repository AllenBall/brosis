import Foundation

// =============================================================================
// get_patterns / recent_activity（计划 3.6「recent_activity、get_patterns … 放 M2」、4.3）
//
// **全部确定性、全部可解释、一行模型都不用**：
//   - 热力图 = 观察时间片按「当地小时」分桶，再按星期 × 小时归并；
//   - 每应用常用时段 = 同一批桶按应用拆开；
//   - 会话长度与打断率 = `sessions` 表（3.7 的三个常量切出来的）；
//   - 最常切换对 = 同一块屏上相邻两条观察的应用发生变化；
//   - 连续工作块 = 同一块屏上相邻观察间隔 < 打断阈值、且不含 unknown 的极大段。
//
// 每个口径的边界条件都写在下面各自的注释里；`ActivityPatterns` 把用到的常量
// （`options` / `sessionConfig`）一起回给调用方，免得数字离开这个函数就没法复核。
// =============================================================================

extension Store {

    /// 3.6 的 `get_patterns(start, end)`。
    ///
    /// - `apps`：只统计这些 bundle id（grant 的应用白名单）。nil 或含 `"*"` = 全部。
    ///   **白名单生效时口径会变**：热力图、切换对、连续工作块都在"只剩白名单内应用"的
    ///   观察流上算，所以块会更碎、切换对更少。这不是裁剪显示，是换了输入，如实标在
    ///   `appFilter` 上。
    public func getPatterns(start: Int64, end: Int64, apps: [String]? = nil,
                            options patternOptions: PatternOptions = PatternOptions())
        throws -> ActivityPatterns {
        guard start < end else { throw StoreError.invalidUsage("时间区间要求 start < end") }
        let t0 = Date()
        let retrievalOptions = retrieval
        let config = sessionConfig
        let filter = Self.normalizedAppFilter(apps)
        return try withLock { conn in
            let cal = PatternCalendar(retrievalOptions.timeZone)
            let maxDwellMS = Int64(config.maxDwellSeconds * 1000)
            let interruptMS = Int64(config.interruptionSeconds * 1000)
            let margin = maxDwellMS + 1000

            // 只要应用标签，不要 urls / files 的三个 LEFT JOIN（与 `getTimeline` 同一个理由）。
            //
            // **全程按 `app_id`（Int64）算，最后才换成 bundle id**：一个月的窗口有 25.9 万个
            // 时间片，把 bundle id / 应用名填进每个片、再拿 String 当字典键，字符串哈希与
            // 引用计数都要按片付一遍。`apps` 表只有个位数行，最后映射一次就够。
            // （本机实测这一项只省下个位数百分比；真正的大头是下面那个"按桶算日期"，
            //   两项加起来把 30 天窗口的热 p95 从 630 ms 降到 128 ms。）
            let appNames = try appMap(conn: conn)
            let filterIDs: Set<Int64>? = filter.map { wanted in
                Set(appNames.filter { wanted.contains($0.value.bundleID.lowercased()) }.keys)
            }
            var slices = try observationSlices(from: start - margin, to: end + margin,
                                               withLabels: false, conn: conn)
            if let filterIDs {
                slices = slices.filter { s in
                    guard let id = s.appID else { return false }
                    return filterIDs.contains(id)
                }
            }

            // ---- ① 热力图：小时桶 → (星期, 小时) ----
            let boundaries = try cal.hourBoundaries(from: start, to: end)
            var cells: [Int: PatternAccumulator] = [:]          // key = weekday * 100 + hour
            var slots: [Int: Int] = [:]
            var appTotals: [Int64: AppAccumulator] = [:]
            var appHours: [Int64: [Int: Int64]] = [:]
            var totalDwell: Int64 = 0, totalActive: Int64 = 0, totalUnknown: Int64 = 0
            var observations = 0
            var activeDayStrings = Set<String>()

            var lo = 0
            for b in 0..<max(0, boundaries.count - 1) {
                let w0 = max(boundaries[b], start)
                let w1 = min(boundaries[b + 1], end)
                guard w1 > w0 else { continue }
                let weekday = cal.weekdayIndex(boundaries[b])
                let hour = cal.hourOfDay(boundaries[b])
                let key = weekday * 100 + hour
                slots[key, default: 0] += 1

                while lo < slices.count, slices[lo].ts + maxDwellMS <= w0 { lo += 1 }
                var hi = lo
                while hi < slices.count, slices[hi].ts < w1 { hi += 1 }
                guard hi > lo else { continue }
                var bucketObservations = 0
                var cell = cells[key] ?? PatternAccumulator()
                for s in slices[lo..<hi] where s.end > w0 {
                    let ms = s.clipped(w0, w1)
                    let counted = s.ts >= w0 && s.ts < w1
                    switch s.kind {
                    case .dwellActive:
                        cell.dwellMS += ms; cell.activeMS += ms
                        totalDwell += ms; totalActive += ms
                    case .dwellIdle:
                        cell.dwellMS += ms
                        totalDwell += ms
                    case .unknown:
                        cell.unknownMS += ms
                        totalUnknown += ms
                    }
                    if counted {
                        cell.observations += 1
                        observations += 1
                        bucketObservations += 1
                    }
                    if let appID = s.appID {
                        var acc = appTotals[appID] ?? AppAccumulator()
                        switch s.kind {
                        case .dwellActive: acc.dwellMS += ms; acc.activeMS += ms
                        case .dwellIdle: acc.dwellMS += ms
                        case .unknown: acc.unknownMS += ms
                        }
                        if counted {
                            acc.observations += 1
                            acc.firstTS = min(acc.firstTS ?? s.ts, s.ts)
                            acc.lastTS = max(acc.lastTS ?? s.ts, s.ts)
                        }
                        appTotals[appID] = acc
                        if s.kind != .unknown {
                            appHours[appID, default: [:]][hour, default: 0] += ms
                        }
                    }
                }
                // 全零的格子不进热力图：一条起点在桶之前、`end` 又没伸进来的时间片
                // 会让这个桶"有片但没贡献"，写回去就是一格空数据。
                if cell.dwellMS > 0 || cell.unknownMS > 0 || cell.observations > 0 {
                    cells[key] = cell
                }
                // 「有观察的自然日」按**桶**记，不按每条观察记：`Calendar.dateComponents`
                // 一次大约 1 µs，一个月窗口有 25.9 万条观察、却只有 720 个小时桶——
                // 逐条算日期是这个函数**最大的一笔开销**（本机实测：1 个月合成库 30 天窗口的
                // 热 p95 从 609 ms 降到 128 ms，7 天从 135 ms 降到 29 ms）。
                if bucketObservations > 0 { activeDayStrings.insert(cal.dayString(boundaries[b])) }
            }

            // ---- ② 最常切换对（A→B）----
            //
            // 口径：**同一块屏**上相邻两条观察的应用不同，且间隔 ≤ 停留上限（90 s，3.7）。
            // 加这个上界是因为超过它就没有证据说明中间发生了什么——那不是一次"切换"，
            // 是一段没有记录的空白之后重新开始。
            var transitions: [TransitionKey: TransitionAccumulator] = [:]
            var transitionsObserved = 0
            var lastByDisplay: [Int64: (appID: Int64, ts: Int64)] = [:]
            for s in slices {
                guard let appID = s.appID else { continue }
                let display = s.displayID ?? -1
                defer { lastByDisplay[display] = (appID, s.ts) }
                guard s.ts >= start, s.ts < end else { continue }
                guard let last = lastByDisplay[display], last.appID != appID,
                      s.ts - last.ts <= maxDwellMS else { continue }
                let key = TransitionKey(from: last.appID, to: appID)
                var acc = transitions[key] ?? TransitionAccumulator()
                acc.count += 1
                acc.gapMS += s.ts - last.ts
                transitions[key] = acc
                transitionsObserved += 1
            }

            // ---- ③ 连续工作块 ----
            let blocks = Self.focusBlocks(slices: slices, start: start, end: end,
                                          interruptionMS: interruptMS,
                                          minMS: Int64(patternOptions.focusBlockMinMinutes * 60_000),
                                          appNames: appNames)

            // ---- ④ 会话长度与打断率 ----
            var sessionRowsInRange = try sessionRows(from: start, to: end, includeStale: false,
                                                     includeEvidence: false, conn: conn)
            if let filter {
                sessionRowsInRange = sessionRowsInRange.filter {
                    guard let b = $0.appBundleID else { return false }
                    return filter.contains(b.lowercased())
                }
            }
            let sessionStats = Self.sessionStats(sessionRowsInRange)

            // ---- 组装 ----
            let heatmap = cells.keys.sorted().map { key -> PatternCell in
                let acc = cells[key]!
                let n = slots[key] ?? 0
                return PatternCell(
                    weekday: key / 100, hour: key % 100,
                    dwellS: Double(acc.dwellMS) / 1000.0,
                    activeS: Double(acc.activeMS) / 1000.0,
                    unknownS: Double(acc.unknownMS) / 1000.0,
                    observations: acc.observations, slots: n,
                    meanDwellS: n == 0 ? 0 : Double(acc.dwellMS) / 1000.0 / Double(n))
            }
            let peak = heatmap.max { a, b in
                a.dwellS == b.dwellS ? (a.weekday * 100 + a.hour) > (b.weekday * 100 + b.hour)
                                     : a.dwellS < b.dwellS
            }
            let byHour = Self.marginal(cells: cells, slots: slots, indices: 0...23) { $0 % 100 }
            let byWeekday = Self.marginal(cells: cells, slots: slots, indices: 1...7) { $0 / 100 }

            let totalAppDwell = appTotals.values.reduce(Int64(0)) { $0 + $1.dwellMS }
            var appRows: [AppPattern] = []
            appRows.reserveCapacity(appTotals.count)
            for (appID, acc) in appTotals {
                var withName = acc
                withName.name = appNames[appID]?.name
                appRows.append(Self.appPattern(bundle: appNames[appID]?.bundleID ?? "app#\(appID)",
                                               acc: withName,
                                               hours: appHours[appID] ?? [:],
                                               totalDwellMS: totalAppDwell,
                                               topHours: patternOptions.topHoursPerApp))
            }
            appRows.sort { $0.dwellS == $1.dwellS ? $0.key < $1.key : $0.dwellS > $1.dwellS }

            let transitionRows = transitions.map { key, acc in
                AppTransition(from: appNames[key.from]?.bundleID ?? "app#\(key.from)",
                              fromName: appNames[key.from]?.name,
                              to: appNames[key.to]?.bundleID ?? "app#\(key.to)",
                              toName: appNames[key.to]?.name,
                              count: acc.count,
                              meanGapMS: acc.count == 0 ? 0 : Double(acc.gapMS) / Double(acc.count))
            }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.from == $1.from ? $0.to < $1.to : $0.from < $1.from
            }

            return ActivityPatterns(
                start: start, end: end, timeZone: retrievalOptions.timeZone.identifier,
                spanDays: Double(end - start) / 86_400_000.0,
                activeDays: activeDayStrings.count, observations: observations,
                totalDwellS: Double(totalDwell) / 1000.0,
                totalActiveS: Double(totalActive) / 1000.0,
                totalUnknownS: Double(totalUnknown) / 1000.0,
                heatmap: heatmap, peakCell: peak, byHour: byHour, byWeekday: byWeekday,
                apps: Array(appRows.prefix(max(0, patternOptions.maxApps))),
                sessions: sessionStats,
                transitions: Array(transitionRows.prefix(max(0, patternOptions.maxTransitions))),
                transitionsObserved: transitionsObserved, transitionPairs: transitionRows.count,
                focus: Self.focusStats(blocks, options: patternOptions,
                                       interruptionSeconds: config.interruptionSeconds),
                options: patternOptions, sessionConfig: config,
                appFilter: filter == nil ? nil : (apps ?? []),
                computedAt: Int64(Date().timeIntervalSince1970 * 1000),
                elapsedMS: Date().timeIntervalSince(t0) * 1000)
        }
    }

    // MARK: - recent_activity / list_activity

    /// 3.6 的 `recent_activity(minutes, max_items)`：最近 N 分钟的会话 + 观察摘要。
    /// 它是 `listActivity` 的特例：窗口 = `[endingAt - minutes, endingAt)`。
    ///
    /// - `endingAt`：窗口右端（不含）。默认"现在"；测试与验收传一个固定值好有确定性。
    public func recentActivity(minutes: Int, maxItems: Int = 20, apps: [String]? = nil,
                               endingAt: Int64? = nil) throws -> RecentActivity {
        let clampedMinutes = max(1, minutes)
        let end = endingAt ?? Int64(Date().timeIntervalSince1970 * 1000)
        let list = try listActivity(start: end - Int64(clampedMinutes) * 60_000, end: end,
                                    maxItems: maxItems, apps: apps)
        return RecentActivity(minutes: clampedMinutes, list: list)
    }

    /// `list_activity(period | start / end, max_items, before_id)`：半开区间 `[start, end)` 内的
    /// 应用聚合、会话汇总与观察摘要（最近的在前），按游标分页。这是按自然日取**内容**的入口——
    /// `get_day_ledger` 只给数字，Agent 讲「今天做了什么」要的逐条摘要从这里拿。
    ///
    /// - 每条摘要 ≤ `RetrievalOptions.summaryTokenBudget` token（3.6 的 100 token 口径）。
    /// - **只看本机产生的观察**（`origin_device IS NULL`）：这是"这台机器在干什么"，
    ///   D17 从别的设备导入的副本不该混进同一条时间线（与 3.9 里 sessions / ledgers 的
    ///   口径一致；要找别的设备的内容走 `search` / `get_evidence`）。
    /// - `apps`：只统计这些 bundle id（grant 的白名单），nil 或含 `"*"` = 全部。
    /// - `beforeID`：只回这一条**之后**（更早）的观察。游标按窗口内的排序位置找，所以
    ///   ts 相同的几条也不会漏；游标本身不在窗口里（比如刚被删了）时退化成 `id < beforeID`。
    ///   应用聚合与会话汇总永远是整个窗口的，不随页变。
    public func listActivity(start: Int64, end: Int64, maxItems: Int = 50,
                             beforeID: Int64? = nil, apps: [String]? = nil) throws -> ActivityList {
        guard start < end else { throw StoreError.invalidUsage("时间区间要求 start < end") }
        let limit = max(0, maxItems)
        let retrievalOptions = retrieval
        let filter = Self.normalizedAppFilter(apps)
        return try withLock { conn in
            let cal = DayCalendar(retrievalOptions.timeZone)
            let margin = Int64(sessionConfig.maxDwellSeconds * 1000) + 1000

            let appNames = try appMap(conn: conn)
            var slices = try observationSlices(from: start - margin, to: end + margin,
                                               withLabels: false, conn: conn)
            for i in slices.indices {
                if let id = slices[i].appID, let a = appNames[id] {
                    slices[i].appBundleID = a.bundleID
                    slices[i].appName = a.name
                }
            }
            if let filter {
                slices = slices.filter { s in
                    guard let b = s.appBundleID else { return false }
                    return filter.contains(b.lowercased())
                }
            }
            let appEntries = Self.sortedEntries(Self.aggregate(slices, clipTo: (start, end)) { s in
                guard let b = s.appBundleID else { return nil }
                return (b, s.appName)
            })
            var sessions = try sessionRows(from: start, to: end, includeStale: false,
                                           includeEvidence: false, conn: conn)
            if let filter {
                sessions = sessions.filter {
                    guard let b = $0.appBundleID else { return false }
                    return filter.contains(b.lowercased())
                }
            }

            // 窗口内的观察 id（最近的在前）。两步式：先纯索引扫 id，再按 id 取正文与标签
            // （理由与 `getContext` 里那段一样：带 ORDER BY 的单条 SQL 会把正文一起读出来排序）。
            let inWindow = slices.filter { $0.ts >= start && $0.ts < end }
                .sorted { $0.ts == $1.ts ? $0.id > $1.id : $0.ts > $1.ts }
            var page = inWindow
            if let beforeID {
                if let at = inWindow.firstIndex(where: { $0.id == beforeID }) {
                    page = Array(inWindow[(at + 1)...])
                } else {
                    page = inWindow.filter { $0.id < beforeID }
                }
            }
            let picked = Array(page.prefix(limit))
            let hasMore = page.count > picked.count
            let metas = try observationMetas(picked.map(\.id), conn: conn)
            let bodies = try snippetSources(picked.map(\.id), conn: conn)
            let budget = retrievalOptions.summaryTokenBudget
            var items: [RecentItem] = []
            items.reserveCapacity(picked.count)
            for slice in picked {
                guard let meta = metas[slice.id] else { continue }
                let body = (bodies[slice.id] ?? "").replacingOccurrences(of: "\n", with: " ")
                // 摘要格式与 `search` 的命中摘要一致：应用 · 标题 · 时间 · 正文开头。
                let head = [meta.appName ?? meta.appBundleID ?? "?",
                            meta.windowTitle ?? meta.host ?? meta.filePath ?? "",
                            cal.stamp(meta.ts)]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                let summary = TokenBudget.truncate(body.isEmpty ? head : head + " · " + body,
                                                   toTokens: budget)
                items.append(RecentItem(
                    evidenceID: meta.id, ts: meta.ts, appBundleID: meta.appBundleID,
                    appName: meta.appName, windowTitle: meta.windowTitle,
                    url: meta.canonicalURL ?? meta.rawLocator, host: meta.host,
                    filePath: meta.filePath, sourceState: meta.sourceState,
                    summary: summary, summaryTokens: TokenBudget.tokens(of: summary)))
            }

            return ActivityList(
                start: start, end: end, maxItems: limit,
                apps: appEntries, sessions: sessions, items: items,
                observations: inWindow.count, truncated: hasMore,
                nextBeforeID: hasMore ? picked.last?.id : nil, beforeID: beforeID,
                summaryTokenBudget: budget,
                appFilter: filter == nil ? nil : (apps ?? []),
                timeZone: retrievalOptions.timeZone.identifier,
                computedAt: Int64(Date().timeIntervalSince1970 * 1000))
        }
    }

    // MARK: - 内部累加器与纯函数

    struct PatternAccumulator {
        var dwellMS: Int64 = 0
        var activeMS: Int64 = 0
        var unknownMS: Int64 = 0
        var observations: Int = 0
    }

    struct AppAccumulator {
        var name: String?
        var dwellMS: Int64 = 0
        var activeMS: Int64 = 0
        var unknownMS: Int64 = 0
        var observations: Int = 0
        var firstTS: Int64?
        var lastTS: Int64?
    }

    /// 切换对的键用 `app_id` 而不是 bundle id：这一步要在几十万条时间片上做字典查找，
    /// 整数哈希比字符串哈希便宜一个量级（见 `getPatterns` 里那段注释）。
    struct TransitionKey: Hashable {
        var from: Int64
        var to: Int64
    }

    struct TransitionAccumulator {
        var count: Int = 0
        var gapMS: Int64 = 0
    }

    /// 一个应用的模式行。单独成函数是因为写成一整条链式表达式时
    /// Swift 6.3 的类型检查器会超时（`unable to type-check this expression in reasonable time`）。
    static func appPattern(bundle: String, acc: AppAccumulator, hours: [Int: Int64],
                           totalDwellMS: Int64, topHours: Int) -> AppPattern {
        let ordered = hours.sorted { a, b in
            a.value == b.value ? a.key < b.key : a.value > b.value
        }
        var top: [AppHourShare] = []
        for (hour, ms) in ordered.prefix(max(0, topHours)) {
            let share: Double = acc.dwellMS == 0 ? 0 : Double(ms) / Double(acc.dwellMS)
            top.append(AppHourShare(hour: hour, dwellS: Double(ms) / 1000.0, share: share))
        }
        let overall: Double = totalDwellMS == 0 ? 0 : Double(acc.dwellMS) / Double(totalDwellMS)
        return AppPattern(key: bundle, name: acc.name,
                          dwellS: Double(acc.dwellMS) / 1000.0,
                          activeS: Double(acc.activeMS) / 1000.0,
                          unknownS: Double(acc.unknownMS) / 1000.0,
                          observations: acc.observations, share: overall,
                          topHours: top, firstTS: acc.firstTS, lastTS: acc.lastTS)
    }

    /// `["*"]`、空数组、nil 都当作"不过滤"。其余转成小写集合（bundle id 大小写不敏感，
    /// `apps.bundle_id` 列上就是 `COLLATE NOCASE`）。
    static func normalizedAppFilter(_ apps: [String]?) -> Set<String>? {
        guard let apps, !apps.isEmpty, !apps.contains("*") else { return nil }
        return Set(apps.map { $0.lowercased() })
    }

    /// 边际表：按小时（或按星期）把热力格子加起来。恒定长度（24 / 7 行），便于画图。
    static func marginal(cells: [Int: PatternAccumulator], slots: [Int: Int],
                         indices: ClosedRange<Int>, index: (Int) -> Int) -> [PatternMarginal] {
        var acc: [Int: PatternAccumulator] = [:]
        var slotCount: [Int: Int] = [:]
        for (key, value) in cells {
            let i = index(key)
            var a = acc[i] ?? PatternAccumulator()
            a.dwellMS += value.dwellMS
            a.activeMS += value.activeMS
            a.unknownMS += value.unknownMS
            a.observations += value.observations
            acc[i] = a
        }
        for (key, n) in slots { slotCount[index(key), default: 0] += n }
        return indices.map { i in
            let a = acc[i] ?? PatternAccumulator()
            let n = slotCount[i] ?? 0
            return PatternMarginal(index: i, dwellS: Double(a.dwellMS) / 1000.0,
                                   activeS: Double(a.activeMS) / 1000.0,
                                   observations: a.observations, slots: n,
                                   meanDwellS: n == 0 ? 0 : Double(a.dwellMS) / 1000.0 / Double(n))
        }
    }

    /// 连续工作块（4.3「≥ 25 分钟无打断」）。
    ///
    /// 一个块 = **同一块屏**上的一段极大观察序列，满足：
    ///   ① 相邻两条观察的间隔 **< `interruptionMS`**（3.7 的打断阈值，默认 20 s；
    ///      3.7 规定"离开正好 20 s 也算打断"，所以这里是严格小于）；
    ///   ② 序列里**没有** `unknown` 观察（权限丢失 / 读取超时 / 锁定——那段时间没有证据
    ///      说明人在工作）；
    ///   ③ 块长 = 最后一条观察的时间片终点 − 第一条观察的 ts，≥ `minMS`。
    ///
    /// 允许块内换应用：3.7 的"打断"是**离开**，不是换应用；换应用本身记在切换对里。
    /// 想看"全程一个应用"的块，用 `FocusBlockStats.singleAppBlocks`。
    static func focusBlocks(slices: [ObservationSlice], start: Int64, end: Int64,
                            interruptionMS: Int64, minMS: Int64,
                            appNames: [Int64: (bundleID: String, name: String)]) -> [FocusBlock] {
        // 只按下标分屏，不把时间片复制进每块屏的数组（一个月窗口 25.9 万个结构体，
        // 复制一遍就是白花的几十毫秒）。
        var indexByDisplay: [Int64: [Int]] = [:]
        for (i, s) in slices.enumerated() where s.ts >= start && s.ts < end {
            indexByDisplay[s.displayID ?? -1, default: []].append(i)
        }
        var out: [FocusBlock] = []
        for display in indexByDisplay.keys.sorted() {
            var current: [Int] = []
            func flush() {
                defer { current = [] }
                guard let firstIndex = current.first, let lastIndex = current.last else { return }
                let first = slices[firstIndex], last = slices[lastIndex]
                let blockStart = first.ts
                let blockEnd = min(max(last.end, last.ts), end)
                let duration = blockEnd - blockStart
                guard duration >= minMS else { return }
                var dwellByApp: [Int64: Int64] = [:]
                var activeMS: Int64 = 0
                for i in current {
                    let s = slices[i]
                    let ms = s.clipped(start, end)
                    if let id = s.appID { dwellByApp[id, default: 0] += ms }
                    if s.kind == .dwellActive { activeMS += ms }
                }
                let top = dwellByApp.max { a, b in
                    a.value == b.value ? a.key > b.key : a.value < b.value
                }
                out.append(FocusBlock(
                    start: blockStart, end: blockEnd,
                    durationS: Double(duration) / 1000.0,
                    displayID: display < 0 ? nil : display,
                    topApp: top.map { appNames[$0.key]?.bundleID ?? "app#\($0.key)" },
                    topAppName: top.flatMap { appNames[$0.key]?.name },
                    appCount: dwellByApp.count, observations: current.count,
                    activeS: Double(activeMS) / 1000.0,
                    activeRatio: duration == 0 ? 0 : Double(activeMS) / Double(duration)))
            }
            for i in indexByDisplay[display]! {
                let s = slices[i]
                if s.kind == .unknown { flush(); continue }
                if let lastIndex = current.last, s.ts - slices[lastIndex].ts >= interruptionMS {
                    flush()
                }
                current.append(i)
            }
            flush()
        }
        return out.sorted { $0.start == $1.start ? $0.durationS > $1.durationS : $0.start < $1.start }
    }

    static func focusStats(_ blocks: [FocusBlock], options: PatternOptions,
                           interruptionSeconds: Double) -> FocusBlockStats {
        let durations = blocks.map(\.durationS).sorted()
        var byApp: [String: (name: String?, blocks: Int, total: Double)] = [:]
        for b in blocks {
            let key = b.topApp ?? "-"
            var row = byApp[key] ?? (b.topAppName, 0, 0)
            if row.name == nil { row.name = b.topAppName }
            row.blocks += 1
            row.total += b.durationS
            byApp[key] = row
        }
        return FocusBlockStats(
            minMinutes: options.focusBlockMinMinutes, gapSeconds: interruptionSeconds,
            count: blocks.count, totalS: durations.reduce(0, +),
            meanS: durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count),
            medianS: percentile(durations, 0.5), longestS: durations.last ?? 0,
            singleAppBlocks: blocks.filter { $0.appCount == 1 }.count,
            activeMajorityBlocks: blocks.filter { $0.activeRatio >= 0.5 }.count,
            byApp: byApp.map { FocusBlockApp(key: $0.key, name: $0.value.name,
                                             blocks: $0.value.blocks, totalS: $0.value.total) }
                .sorted { $0.totalS == $1.totalS ? $0.key < $1.key : $0.totalS > $1.totalS },
            longest: blocks.sorted { $0.durationS == $1.durationS ? $0.start < $1.start
                                                                  : $0.durationS > $1.durationS }
                .prefix(max(0, options.maxFocusBlockSamples)).map { $0 })
    }

    static func sessionStats(_ rows: [SessionRow]) -> SessionPatternStats {
        let durations = rows.map { Double($0.end - $0.start) / 1000.0 }.sorted()
        let interruptions = rows.reduce(0) { $0 + $1.interruptions }
        let withInterruption = rows.filter { $0.interruptions > 0 }.count
        let totalDwell = rows.reduce(0.0) { $0 + $1.dwellS }
        let n = rows.count
        return SessionPatternStats(
            count: n,
            meanDurationS: n == 0 ? 0 : durations.reduce(0, +) / Double(n),
            medianDurationS: percentile(durations, 0.5),
            p90DurationS: percentile(durations, 0.9),
            longestDurationS: durations.last ?? 0,
            meanDwellS: n == 0 ? 0 : totalDwell / Double(n),
            totalDwellS: totalDwell,
            interruptions: interruptions,
            interruptionsPerSession: n == 0 ? 0 : Double(interruptions) / Double(n),
            sessionsWithInterruption: withInterruption,
            interruptionRate: n == 0 ? 0 : Double(withInterruption) / Double(n))
    }

    /// 最近秩（nearest-rank）分位数：下标 = `ceil(p × n) − 1`，不做插值。
    /// 选它是因为结果一定是**样本里真实存在的一个值**，复核的时候能指着那一条说"就是它"。
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

extension RecentActivity {
    /// `recent_activity` = `list_activity` 的特例：同一份结果，多一个 `minutes` 标签。
    init(minutes: Int, list: ActivityList) {
        self.init(minutes: minutes, start: list.start, end: list.end, maxItems: list.maxItems,
                  apps: list.apps, sessions: list.sessions, items: list.items,
                  observations: list.observations, truncated: list.truncated,
                  summaryTokenBudget: list.summaryTokenBudget, appFilter: list.appFilter,
                  timeZone: list.timeZone, computedAt: list.computedAt)
    }
}
