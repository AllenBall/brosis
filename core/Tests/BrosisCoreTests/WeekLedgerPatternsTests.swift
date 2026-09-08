import Foundation
import XCTest
@testable import BrosisCore
import BrosisIPC

/// M2 c / T14：周台账、`get_patterns`、`recent_activity`（计划 3.6 / 3.7 / 4.3）。
///
/// 合成数据都是**手写的确定性观察流**（不用 `gen_synth_m1.py`），因为这些用例断言的是
/// "生成器设定的工作时段"与"人为埋进去的切换 / 工作块"能不能被算出来——
/// 真值必须由测试自己定义，不能由被测代码定义。
final class WeekLedgerPatternsTests: XCTestCase {

    private var fixture: Fixture!
    private var store: Store { fixture.store }

    /// 2026-09-07 是周一，ISO 周 2026-W37（`python3 -c "datetime.date(2026,9,7).isocalendar()"`）。
    private static let mondayTS: Int64 = 1_788_739_200_000
    private static let week = "2026-W37"
    private static let dayMS: Int64 = 86_400_000
    private static let hourMS: Int64 = 3_600_000

    private static let vscode = "com.microsoft.VSCode"
    private static let safari = "com.apple.Safari"
    private static let wechat = "com.tencent.xinWeChat"

    override func setUpWithError() throws {
        fixture = try Fixture("m2-patterns")
        store.retrieval.timeZone = TimeZone(identifier: "UTC")!
    }

    override func tearDown() { fixture = nil }

    // MARK: - 合成流

    private func observation(ts: Int64, bundle: String, display: Int64 = 1,
                             state: SourceState = .ok, text: String? = nil) -> ObservationInput {
        let name = bundle.components(separatedBy: ".").last ?? bundle
        return ObservationInput(
            ts: ts, displayID: display,
            app: AppRef(bundleID: bundle, name: name),
            windowTitle: "\(name) — 窗口",
            url: URLRef(rawLocator: "https://docs.internal/p/1", canonicalURL: "https://docs.internal/p/1",
                        host: "docs.internal", kind: .web),
            filePath: nil, trigger: .timer, captureMethod: .ax, completeness: .complete,
            sourceState: state,
            texts: [TextFragment(text: text ?? "段落 知识图谱 与 存储服务，时刻 \(ts)。",
                                 region: "{\"ord\":0}")])
    }

    /// 一段连续观察：`[from, from + count * step)`，每 `step` 毫秒一条。
    private func run(from: Int64, count: Int, step: Int64, bundle: String,
                     display: Int64 = 1, state: SourceState = .ok) -> [ObservationInput] {
        (0..<count).map { observation(ts: from + Int64($0) * step, bundle: bundle,
                                      display: display, state: state) }
    }

    /// **工作周合成流**（本文件里所有"工作时段"断言的真值来源）：
    ///
    /// | 天 | 09–10 | 10–11 | 11–12 | 14–17 | 20–21 |
    /// |---|---|---|---|---|---|
    /// | 周一 | VSCode | VSCode | VSCode | Safari | — |
    /// | 周二 | VSCode | VSCode | VSCode | Safari | — |
    /// | 周三 | VSCode | VSCode | VSCode | Safari | — |
    /// | 周四 | VSCode | VSCode | VSCode | — | — |
    /// | 周五 | — | VSCode | — | — | — |
    /// | 周六 | — | — | — | — | 微信 |
    /// | 周日 | — | — | — | — | — |
    ///
    /// 关键设计：**10 点是唯一一个五个工作日都在的小时**（5 × 3600 s），
    /// 9 点与 11 点各 4 天、14–16 点各 3 天、20 点 1 天。于是"按小时的边际表"有唯一峰值 10 点，
    /// 而且它落在设定的工作时段里——这就是 4.3「热力峰值落在生成器设定的工作时段」那条断言。
    ///
    /// 采样间隔 60 s（不是产品的 10 s）：热力图只关心时长，60 s 间隔下每条观察代表 60 s
    /// （< 3.7 的停留上限 90 s），1380 条就够铺满一周，测试跑得快。
    @discardableResult
    private func seedWorkWeek() throws -> Int {
        let day = Self.mondayTS
        let h = Self.hourMS
        var inputs: [ObservationInput] = []
        for d in 0..<5 {                                   // 周一…周五
            let base = day + Int64(d) * Self.dayMS
            inputs += run(from: base + 10 * h, count: 60, step: 60_000, bundle: Self.vscode)
            if d <= 3 {
                inputs += run(from: base + 9 * h, count: 60, step: 60_000, bundle: Self.vscode)
                inputs += run(from: base + 11 * h, count: 60, step: 60_000, bundle: Self.vscode)
            }
            if d <= 2 {
                inputs += run(from: base + 14 * h, count: 180, step: 60_000, bundle: Self.safari)
            }
        }
        // 周六晚上刷一小时微信：证明"周末不是零"，但峰值仍在工作日工作时段。
        inputs += run(from: day + 5 * Self.dayMS + 20 * h, count: 60, step: 60_000,
                      bundle: Self.wechat)
        try store.record(batch: inputs)
        _ = try store.buildSessions(force: true)
        return inputs.count
    }

    // MARK: - 1. 日历口径

    /// `PatternCalendar` 是 `DayCalendar` 那三行配置的复制品（它的 `Calendar` 是 private）。
    /// 复制就有配错的风险，这条用例专门兜它。
    func testPatternCalendarAgreesWithDayCalendar() throws {
        for identifier in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
            let tz = try XCTUnwrap(TimeZone(identifier: identifier))
            let day = DayCalendar(tz)
            let pattern = PatternCalendar(tz)
            for step in 0..<140 {
                let ts = Self.mondayTS + Int64(step) * (7 * Self.hourMS + 137)
                XCTAssertEqual(pattern.dayString(ts), day.dayString(ts), identifier)
                XCTAssertEqual(pattern.stamp(ts), day.stamp(ts), identifier)
                XCTAssertEqual(pattern.weekString(ts), day.bucketLabel(day.bucketStart(ts, .week), .week),
                               identifier)
                XCTAssertEqual(pattern.weekStart(ts), day.bucketStart(ts, .week), identifier)
                XCTAssertEqual(pattern.weekEnd(pattern.weekStart(ts)),
                               day.bucketEnd(day.bucketStart(ts, .week), .week), identifier)
            }
        }
    }

    func testWeekBoundsAcceptsBothSpellingsAndRejectsGarbage() throws {
        let cal = PatternCalendar(TimeZone(identifier: "UTC")!)
        let fromWeek = try cal.weekBounds(Self.week)
        let fromMonday = try cal.weekBounds("2026-09-07")
        let fromSunday = try cal.weekBounds("2026-09-13")          // 同一周的最后一天
        XCTAssertEqual(fromWeek.start, Self.mondayTS)
        XCTAssertEqual(fromWeek.end, Self.mondayTS + 7 * Self.dayMS)
        XCTAssertEqual(fromMonday.start, fromWeek.start)
        XCTAssertEqual(fromSunday.start, fromWeek.start)
        XCTAssertEqual(cal.weekdayIndex(Self.mondayTS), 1)
        XCTAssertEqual(cal.weekdayIndex(Self.mondayTS + 6 * Self.dayMS), 7)
        XCTAssertThrowsError(try cal.weekBounds("2026-W99"))
        XCTAssertThrowsError(try cal.weekBounds("不是日期"))
    }

    // MARK: - 2. 周台账 = 7 个日台账之和

    func testWeekLedgerEqualsSumOfSevenDayLedgers() throws {
        try seedWorkWeek()
        let week = try store.getWeekLedger(weekStart: Self.week)
        XCTAssertEqual(week.week, Self.week)
        XCTAssertEqual(week.start, Self.mondayTS)
        XCTAssertEqual(week.end, Self.mondayTS + 7 * Self.dayMS)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.first, "2026-09-07")
        XCTAssertEqual(week.days.last, "2026-09-13")
        XCTAssertEqual(week.dayTotals.map(\.weekday), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(week.activeDays, 6, "周日没有观察")
        XCTAssertFalse(week.dayTotals[6].hasData, "周日 hasData = false，但这一行必须在")
        XCTAssertNil(week.narrative, "3.7：台账与叙述分开标注，本任务不产叙述")

        let days = try week.days.map { try store.getDayLedger(date: $0) }
        XCTAssertEqual(week.totalDwellS, days.reduce(0) { $0 + $1.totalDwellS }, accuracy: 0.001)
        XCTAssertEqual(week.totalActiveS, days.reduce(0) { $0 + $1.totalActiveS }, accuracy: 0.001)
        XCTAssertEqual(week.totalUnknownS, days.reduce(0) { $0 + $1.totalUnknownS }, accuracy: 0.001)
        XCTAssertEqual(week.onlineUnionS, days.reduce(0) { $0 + $1.onlineUnionS }, accuracy: 0.001)
        XCTAssertEqual(week.switches, days.reduce(0) { $0 + $1.switches })
        XCTAssertEqual(week.interruptions, days.reduce(0) { $0 + $1.interruptions })
        XCTAssertEqual(week.sessions, days.reduce(0) { $0 + $1.sessions })
        XCTAssertEqual(week.observations, days.reduce(0) { $0 + $1.observations })

        // 应用排行：逐个 key 对上每天之和
        for entry in week.apps {
            let expectedDwell = days.flatMap(\.apps).filter { $0.key == entry.key }
                .reduce(0.0) { $0 + $1.dwellS }
            XCTAssertEqual(entry.dwellS, expectedDwell, accuracy: 0.001, entry.key)
        }
        XCTAssertEqual(Set(week.apps.map(\.key)), [Self.vscode, Self.safari, Self.wechat])
        // VSCode 每条观察 60 s：5 天 × 60 + 4 天 × 120 = 780 条
        let vscode = try XCTUnwrap(week.apps.first { $0.key == Self.vscode })
        XCTAssertEqual(vscode.observations, 780)

        // 证据区间覆盖全部观察，且是合并过的（D23）
        let covered = week.evidence.reduce(0) { $0 + Int($1[1] - $1[0] + 1) }
        XCTAssertEqual(covered, week.observations)
        for i in 1..<week.evidence.count {
            XCTAssertGreaterThan(week.evidence[i][0], week.evidence[i - 1][1] + 1, "区间应当已合并")
        }
    }

    // MARK: - 3. 增量与缓存

    func testWeekLedgerIsIncrementalAndServesFromCache() throws {
        try seedWorkWeek()
        let first = try store.getWeekLedger(weekStart: Self.week)
        XCTAssertEqual(Set(first.daysRecomputed), Set(first.days), "第一次七天全算")
        XCTAssertFalse(first.servedFromCache)

        // 什么都没变：第二次整份走缓存，一天都不重算
        let second = try store.getWeekLedger(weekStart: Self.week)
        XCTAssertTrue(second.servedFromCache)
        XCTAssertTrue(second.daysRecomputed.isEmpty)
        XCTAssertEqual(second.computedAt, first.computedAt)
        XCTAssertEqual(second.totalDwellS, first.totalDwellS, accuracy: 0.001)

        // 只往周四写新观察：只有周四那天重算，别的六天的 computedAt 一个字节都不动
        let thursday = Self.mondayTS + 3 * Self.dayMS
        try store.record(batch: run(from: thursday + 15 * Self.hourMS, count: 30, step: 60_000,
                                    bundle: Self.safari))
        _ = try store.buildSessions()
        let third = try store.getWeekLedger(weekStart: Self.week)
        XCTAssertEqual(third.daysRecomputed, ["2026-09-10"], "只有周四变了")
        XCTAssertFalse(third.servedFromCache)
        XCTAssertGreaterThan(third.observations, first.observations)
        for (before, after) in zip(first.dayTotals, third.dayTotals) where before.date != "2026-09-10" {
            XCTAssertEqual(after.dayComputedAt, before.dayComputedAt, before.date)
        }
        // 与全量重算逐字段相等
        let forced = try store.getWeekLedger(weekStart: Self.week, recompute: true)
        XCTAssertEqual(forced.totalDwellS, third.totalDwellS, accuracy: 0.001)
        XCTAssertEqual(forced.observations, third.observations)
        XCTAssertEqual(forced.switches, third.switches)
        XCTAssertEqual(forced.apps.map(\.key), third.apps.map(\.key))
    }

    /// M1 的日台账缓存**只在删除时**被标脏，新观察写进来不会碰它——"今天"的台账
    /// 算过一次就被永久缓存。T14 用内容指纹堵上这个洞（`DayLedger.contentFingerprint`）。
    func testDayLedgerCacheIsInvalidatedByNewObservations() throws {
        let monday = "2026-09-07"
        try store.record(batch: run(from: Self.mondayTS + 9 * Self.hourMS, count: 10, step: 60_000,
                                    bundle: Self.vscode))
        _ = try store.buildSessions(force: true)
        let before = try store.getDayLedger(date: monday)
        XCTAssertEqual(before.observations, 10)
        XCTAssertEqual(before.contentFingerprint, "n=10,max=10")

        // 缓存命中：没有新观察时读回同一份（computedAt 不变）
        XCTAssertEqual(try store.getDayLedger(date: monday).computedAt, before.computedAt)

        try store.record(batch: run(from: Self.mondayTS + 11 * Self.hourMS, count: 5, step: 60_000,
                                    bundle: Self.safari))
        let after = try store.getDayLedger(date: monday)
        XCTAssertEqual(after.observations, 15, "新观察必须让缓存失效并重算")
        XCTAssertEqual(after.contentFingerprint, "n=15,max=15")
        XCTAssertGreaterThanOrEqual(after.computedAt, before.computedAt)
    }

    // MARK: - 4. stale 联动（3.8）

    func testDeleteMarksWeekLedgerStaleAndRecomputeDropsIt() throws {
        try seedWorkWeek()
        let before = try store.getWeekLedger(weekStart: Self.week)
        XCTAssertFalse(before.stale)
        let weekRows = try store.staleFlags(table: "ledgers")
        XCTAssertFalse(weekRows.contains { $0.stale })

        // 删掉周一上午的一条观察：日台账与周台账都要被标脏（级联口径见 3.8）
        let summary = try store.deleteObservations([1], reason: .user)
        XCTAssertEqual(summary.observationsAffected, 1)
        XCTAssertGreaterThanOrEqual(summary.ledgersStale, 2, "日台账 + 周台账都要标脏")
        XCTAssertGreaterThanOrEqual(try store.staleFlags(table: "ledgers").filter(\.stale).count, 2)

        let after = try store.getWeekLedger(weekStart: Self.week)
        XCTAssertFalse(after.stale, "读回来的一定是重算过的那份")
        XCTAssertEqual(after.observations, before.observations - 1)
        XCTAssertTrue(after.daysRecomputed.contains("2026-09-07"))
        XCTAssertEqual(try store.staleFlags(table: "ledgers").filter(\.stale).count, 0,
                       "重算之后不该还留着脏行")
    }

    // MARK: - 5. get_patterns：热力

    func testPatternsHeatmapPeaksInsideGeneratedWorkHours() throws {
        try seedWorkWeek()
        let patterns = try store.getPatterns(start: Self.mondayTS,
                                             end: Self.mondayTS + 7 * Self.dayMS)
        XCTAssertEqual(patterns.spanDays, 7, accuracy: 0.001)
        XCTAssertEqual(patterns.activeDays, 6)
        XCTAssertEqual(patterns.timeZone, store.retrieval.timeZone.identifier)

        // ① 按小时的边际表：10 点是唯一峰值（五个工作日都在），而且是设定的工作时段
        let byHour = patterns.byHour
        XCTAssertEqual(byHour.count, 24)
        let peakHour = try XCTUnwrap(byHour.max { $0.dwellS < $1.dwellS })
        XCTAssertEqual(peakHour.index, 10)
        XCTAssertEqual(peakHour.dwellS, 5 * 3600, accuracy: 5, "五天 × 一小时")
        // 9 点与 11 点各 4 天、14–16 点各 3 天，都严格小于 10 点
        XCTAssertEqual(byHour[9].dwellS, 4 * 3600, accuracy: 1)
        // 11 点会多出 30 s：**周五 10:59 那条观察的下一条落在周六**，按 3.7 的停留上限
        // 记 90 s，其中 30 s 落进 11 点这一格。这是停留上限的正常行为，不是误差。
        XCTAssertGreaterThanOrEqual(byHour[11].dwellS, 4 * 3600)
        XCTAssertLessThanOrEqual(byHour[11].dwellS, 4 * 3600 + 90)
        for hour in [14, 15, 16] {
            XCTAssertEqual(byHour[hour].dwellS, 3 * 3600, accuracy: 5)
        }
        XCTAssertLessThan(byHour[9].dwellS, byHour[10].dwellS)
        XCTAssertLessThan(byHour[11].dwellS, byHour[10].dwellS)
        // ② 夜里与清晨没有任何时长（合成流里就没有）
        for hour in [0, 1, 2, 3, 4, 5, 6, 7, 8, 22, 23] {
            XCTAssertEqual(byHour[hour].dwellS, 0, "\(hour) 点不该有时长")
            XCTAssertEqual(byHour[hour].observations, 0, "\(hour) 点不该有观察")
        }
        // ③ 工作时段（9–17）占了绝大部分：其余是 20 点那一小时微信 + 停留上限造成的溢出
        let workDwell = (9...17).reduce(0.0) { $0 + byHour[$1].dwellS }
        XCTAssertGreaterThan(workDwell / patterns.totalDwellS, 0.9)

        // ④ 峰值格子落在工作日的工作时段
        let peak = try XCTUnwrap(patterns.peakCell)
        XCTAssertTrue((1...5).contains(peak.weekday), "峰值格子在周一到周五，实际 \(peak.weekday)")
        XCTAssertTrue((9...17).contains(peak.hour), "峰值格子在 9–17 点，实际 \(peak.hour)")

        // ⑤ 按星期：周日全零，周六只有 20 点那一小时
        let byWeekday = patterns.byWeekday
        XCTAssertEqual(byWeekday.count, 7)
        XCTAssertEqual(byWeekday[6].index, 7)
        XCTAssertEqual(byWeekday[6].dwellS, 0, "周日没有观察")
        XCTAssertEqual(byWeekday[5].dwellS, 3600, accuracy: 90, "周六只有 20–21 点")

        // ⑥ slots：一周里每个 (星期, 小时) 格子只出现一次
        for cell in patterns.heatmap { XCTAssertEqual(cell.slots, 1, "\(cell.weekday)/\(cell.hour)") }
    }

    func testPatternsAppTopHoursMatchGenerator() throws {
        try seedWorkWeek()
        let patterns = try store.getPatterns(start: Self.mondayTS,
                                             end: Self.mondayTS + 7 * Self.dayMS)
        let vscode = try XCTUnwrap(patterns.apps.first { $0.key == Self.vscode })
        let safari = try XCTUnwrap(patterns.apps.first { $0.key == Self.safari })
        let wechat = try XCTUnwrap(patterns.apps.first { $0.key == Self.wechat })
        XCTAssertEqual(Set(vscode.topHours.map(\.hour)), [9, 10, 11], "VSCode 只在上午用")
        XCTAssertEqual(Set(safari.topHours.map(\.hour)), [14, 15, 16], "Safari 只在下午用")
        XCTAssertEqual(wechat.topHours.map(\.hour), [20], "微信只在周六晚上用")
        XCTAssertEqual(vscode.topHours.first?.hour, 10, "常用时段按 dwell 倒序，10 点最多")
        XCTAssertGreaterThan(vscode.share, safari.share)
        XCTAssertEqual(patterns.apps.map(\.share).reduce(0, +), 1.0, accuracy: 0.001)
        XCTAssertEqual(vscode.firstTS, Self.mondayTS + 9 * Self.hourMS)
    }

    // MARK: - 6. get_patterns：切换对

    func testPatternsCountsMostFrequentTransitions() throws {
        // 人为埋：A→B 六次、B→A 五次（末尾停在 B），另一块屏上 C→A 两次。
        var inputs: [ObservationInput] = []
        var ts = Self.mondayTS + 9 * Self.hourMS
        for _ in 0..<6 {
            inputs.append(observation(ts: ts, bundle: Self.vscode)); ts += 10_000
            inputs.append(observation(ts: ts, bundle: Self.safari)); ts += 10_000
        }
        var ts2 = Self.mondayTS + 10 * Self.hourMS
        for _ in 0..<2 {
            inputs.append(observation(ts: ts2, bundle: Self.wechat, display: 2)); ts2 += 10_000
            inputs.append(observation(ts: ts2, bundle: Self.vscode, display: 2)); ts2 += 10_000
        }
        // 一次「隔了两小时才换应用」：超过停留上限 90 s，**不算切换**
        inputs.append(observation(ts: ts + 2 * Self.hourMS, bundle: Self.wechat))
        try store.record(batch: inputs)
        _ = try store.buildSessions(force: true)

        let patterns = try store.getPatterns(start: Self.mondayTS,
                                             end: Self.mondayTS + Self.dayMS)
        let top = try XCTUnwrap(patterns.transitions.first)
        XCTAssertEqual(top.from, Self.vscode)
        XCTAssertEqual(top.to, Self.safari)
        XCTAssertEqual(top.count, 6)
        XCTAssertEqual(top.meanGapMS, 10_000, accuracy: 0.5)
        let back = try XCTUnwrap(patterns.transitions.first { $0.from == Self.safari
                                                           && $0.to == Self.vscode })
        XCTAssertEqual(back.count, 5)
        let secondDisplay = try XCTUnwrap(patterns.transitions.first { $0.from == Self.wechat
                                                                    && $0.to == Self.vscode })
        XCTAssertEqual(secondDisplay.count, 2, "第二块屏各算各的焦点流（3.7 双屏口径）")
        XCTAssertEqual(patterns.transitionsObserved, 6 + 5 + 2 + 1, "含第二块屏的 A→C 那一次")
        XCTAssertNil(patterns.transitions.first { $0.from == Self.safari && $0.to == Self.wechat },
                     "隔了两小时的应用变化不是切换（超过停留上限就没有证据）")
    }

    // MARK: - 7. get_patterns：连续工作块

    func testPatternsFocusBlocksNeedContinuityAndLength() throws {
        // ① 40 分钟连续（10 s 一条，间隔 < 打断阈值 20 s）→ 算一个块
        var inputs = run(from: Self.mondayTS + 9 * Self.hourMS, count: 240, step: 10_000,
                         bundle: Self.vscode)
        // ② 30 分钟里插一次 60 s 的空白 → 断成两段 15 分钟，都不到 25 分钟，一个块都不算
        let broken = Self.mondayTS + 13 * Self.hourMS
        inputs += run(from: broken, count: 90, step: 10_000, bundle: Self.safari)
        inputs += run(from: broken + 90 * 10_000 + 60_000, count: 90, step: 10_000, bundle: Self.safari)
        // ③ 30 分钟连续、但中间一条是 unknown（权限丢失）→ 同样断开
        let withUnknown = Self.mondayTS + 16 * Self.hourMS
        inputs += run(from: withUnknown, count: 90, step: 10_000, bundle: Self.wechat)
        inputs.append(observation(ts: withUnknown + 90 * 10_000, bundle: Self.wechat,
                                  state: .permissionLost))
        inputs += run(from: withUnknown + 91 * 10_000, count: 89, step: 10_000, bundle: Self.wechat)
        try store.record(batch: inputs)
        _ = try store.buildSessions(force: true)

        let patterns = try store.getPatterns(start: Self.mondayTS,
                                             end: Self.mondayTS + Self.dayMS)
        XCTAssertEqual(patterns.focus.minMinutes, 25)
        XCTAssertEqual(patterns.focus.gapSeconds, 20, "口径用 3.7 的打断阈值")
        XCTAssertEqual(patterns.focus.count, 1, "只有第一段够 25 分钟且不含断点")
        let block = try XCTUnwrap(patterns.focus.longest.first)
        XCTAssertEqual(block.topApp, Self.vscode)
        XCTAssertEqual(block.appCount, 1)
        XCTAssertEqual(block.observations, 240)
        // 239 个 10 s 间隔 = 2390 s，**再加最后一条观察自己代表的 90 s**：
        // 它的下一条在两小时后，按 3.7 的停留上限记 90 s（与 dwell 的记账口径完全一致）。
        XCTAssertEqual(block.durationS, 2480, accuracy: 1)
        XCTAssertEqual(block.activeS, block.durationS, accuracy: 1)
        XCTAssertEqual(block.activeRatio, 1.0, accuracy: 0.001)
        XCTAssertEqual(patterns.focus.singleAppBlocks, 1)
        XCTAssertEqual(patterns.focus.activeMajorityBlocks, 1)
        XCTAssertEqual(patterns.focus.byApp.first?.key, Self.vscode)

        // 把下限放宽到 10 分钟：断开的那几段就露出来了（断点判定本身是对的）
        var relaxed = PatternOptions()
        relaxed.focusBlockMinMinutes = 10
        let more = try store.getPatterns(start: Self.mondayTS, end: Self.mondayTS + Self.dayMS,
                                         options: relaxed)
        XCTAssertEqual(more.focus.count, 5, "1 + 2（60 s 空白）+ 2（unknown 断点）")
    }

    // MARK: - 8. get_patterns：会话统计

    func testPatternsSessionStatsMatchSessionsTable() throws {
        try seedWorkWeek()
        let start = Self.mondayTS, end = Self.mondayTS + 7 * Self.dayMS
        let patterns = try store.getPatterns(start: start, end: end)
        let rows = try store.sessions(from: start, to: end)
        XCTAssertEqual(patterns.sessions.count, rows.count)
        XCTAssertEqual(patterns.sessions.interruptions, rows.reduce(0) { $0 + $1.interruptions })
        XCTAssertEqual(patterns.sessions.totalDwellS, rows.reduce(0) { $0 + $1.dwellS },
                       accuracy: 0.001)
        let durations = rows.map { Double($0.end - $0.start) / 1000.0 }
        XCTAssertEqual(patterns.sessions.meanDurationS,
                       durations.reduce(0, +) / Double(durations.count), accuracy: 0.001)
        XCTAssertEqual(patterns.sessions.longestDurationS, durations.max() ?? 0, accuracy: 0.001)
        XCTAssertEqual(patterns.sessions.interruptionRate,
                       Double(rows.filter { $0.interruptions > 0 }.count) / Double(rows.count),
                       accuracy: 0.001)
        XCTAssertEqual(patterns.sessionConfig, store.sessionConfig, "算它用的常量要跟着一起回")
    }

    /// 应用白名单是**下推到 core** 的：只剩白名单内应用的观察流，热力与工作块都在它上面重算。
    func testPatternsAppFilterChangesTheInputNotJustTheOutput() throws {
        try seedWorkWeek()
        let start = Self.mondayTS, end = Self.mondayTS + 7 * Self.dayMS
        let all = try store.getPatterns(start: start, end: end)
        let onlySafari = try store.getPatterns(start: start, end: end, apps: [Self.safari])
        XCTAssertEqual(onlySafari.apps.map(\.key), [Self.safari])
        XCTAssertEqual(onlySafari.appFilter, [Self.safari])
        XCTAssertLessThan(onlySafari.totalDwellS, all.totalDwellS)
        // Safari 只在 14–17 点用：上午的格子必须一格都没有
        XCTAssertTrue(onlySafari.heatmap.allSatisfy { (14...17).contains($0.hour) })
        XCTAssertNil(all.appFilter)
        // 星号与空数组都当作"不过滤"
        XCTAssertNil(try store.getPatterns(start: start, end: end, apps: ["*"]).appFilter)
        XCTAssertNil(try store.getPatterns(start: start, end: end, apps: []).appFilter)
    }

    func testPatternsRejectsEmptyRange() throws {
        XCTAssertThrowsError(try store.getPatterns(start: Self.mondayTS, end: Self.mondayTS))
    }

    // MARK: - 9. recent_activity

    func testRecentActivityReturnsSummariesWithinTokenBudget() throws {
        let long = String(repeating: "很长的正文内容需要被截断，", count: 40)   // 520 个字符
        var inputs = run(from: Self.mondayTS + 9 * Self.hourMS, count: 20, step: 60_000,
                         bundle: Self.vscode)
        inputs.append(observation(ts: Self.mondayTS + 9 * Self.hourMS + 20 * 60_000,
                                  bundle: Self.safari, text: long))
        try store.record(batch: inputs)
        _ = try store.buildSessions(force: true)

        let at = Self.mondayTS + 10 * Self.hourMS
        let recent = try store.recentActivity(minutes: 120, maxItems: 5, endingAt: at)
        XCTAssertEqual(recent.minutes, 120)
        XCTAssertEqual(recent.end, at)
        XCTAssertEqual(recent.start, at - 120 * 60_000)
        XCTAssertEqual(recent.observations, 21)
        XCTAssertEqual(recent.items.count, 5)
        XCTAssertTrue(recent.truncated, "21 条观察、只要 5 条")
        XCTAssertEqual(recent.items.first?.appBundleID, Self.safari, "最近的在前")
        for item in recent.items {
            XCTAssertLessThanOrEqual(item.summaryTokens, recent.summaryTokenBudget, item.summary)
            XCTAssertLessThanOrEqual(item.summary.count,
                                     TokenBudget.characters(forTokens: recent.summaryTokenBudget))
            XCTAssertFalse(item.summary.contains("\n"), "摘要是一行")
        }
        XCTAssertTrue(try XCTUnwrap(recent.items.first).summary.hasSuffix("…"), "长正文要被截断")
        XCTAssertEqual(Set(recent.apps.map(\.key)), [Self.vscode, Self.safari])
        XCTAssertFalse(recent.sessions.isEmpty)
        XCTAssertTrue(recent.sessions.allSatisfy { $0.observationIDs.isEmpty },
                      "会话不展开证据 id（这里只要时长与打断数）")
    }

    func testRecentActivityAppFilterAndEmptyWindow() throws {
        try seedWorkWeek()
        let at = Self.mondayTS + 12 * Self.hourMS
        let all = try store.recentActivity(minutes: 180, maxItems: 10, endingAt: at)
        XCTAssertEqual(Set(all.apps.map(\.key)), [Self.vscode])
        let filtered = try store.recentActivity(minutes: 180, maxItems: 10,
                                                apps: [Self.safari], endingAt: at)
        XCTAssertTrue(filtered.items.isEmpty, "上午没有 Safari")
        XCTAssertEqual(filtered.observations, 0)
        XCTAssertEqual(filtered.appFilter, [Self.safari])
        // 窗口外：周日整天没有观察
        let sunday = try store.recentActivity(minutes: 60, maxItems: 10,
                                              endingAt: Self.mondayTS + 6 * Self.dayMS + 12 * Self.hourMS)
        XCTAssertEqual(sunday.observations, 0)
        XCTAssertTrue(sunday.items.isEmpty)
        XCTAssertFalse(sunday.truncated)
    }

    // MARK: - 10. MCP 服务端：三个新工具的 grant 裁剪与审计（3.6）

    private func service() -> StoreMCPService { StoreMCPService(store: store) }

    private func call(_ service: StoreMCPService, _ tool: MCPTool,
                      _ args: [String: JSONValue]) -> IPCResponse {
        let peer = PeerInfo(uid: getuid(), gid: getgid(), pid: getpid(), teamID: "TESTTEAM",
                            signingID: "com.brosis.test", codeSigningVerified: true,
                            codeSigningNote: "skipped(test_host)")
        return service.handle(IPCCall(request: IPCRequest(client: "claude-code", op: .tool,
                                                          name: tool.rawValue, args: args),
                                      peer: peer, refusal: nil, rateUsed: 1, rateLimit: 60))
    }

    func testMCPWeekLedgerAndPatternsRespectAppWhitelist() throws {
        try seedWorkWeek()
        let service = self.service()
        // 时间窗要够长：合成数据在 2026-09-07 那一周，可能早于"今天"。
        let days = max(30, Int((Int64(Date().timeIntervalSince1970 * 1000) - Self.mondayTS)
                               / Self.dayMS) + 8)
        try store.setGrant(Grant(clientID: "claude-code", mode: .strictLocal,
                                 apps: [Self.safari], timeWindowDays: days, fields: .summary))

        // ① 周台账：只剩白名单里的应用，汇总按留下的应用重算，站点 / 文件 / 按天分布丢掉
        let week = try XCTUnwrap(call(service, .getWeekLedger,
                                      ["week": .string(Self.week)]).result?.objectValue)
        let apps = try XCTUnwrap(week["apps"]?.arrayValue)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?["key"]?.stringValue, Self.safari)
        XCTAssertNil(week["sites"], "站点表回不到应用，白名单生效时整段丢掉")
        XCTAssertNil(week["dayTotals"])
        let dropped = try XCTUnwrap(week["droppedFields"]?.arrayValue).compactMap(\.stringValue)
        XCTAssertTrue(dropped.contains("dayTotals"))
        XCTAssertTrue(dropped.contains("sites"))
        XCTAssertEqual(week["grant"]?["filteredByGrant"]?.boolValue, true)
        XCTAssertEqual(week["grant"]?["droppedByGrant"]?.intValue, 2, "VSCode 与微信被挡掉")
        let fullWeek = try store.getWeekLedger(weekStart: Self.week)
        XCTAssertLessThan(try XCTUnwrap(week["totalDwellS"]?.doubleValue), fullWeek.totalDwellS)

        // ② get_patterns：白名单下推到 core，热力图里只剩下午
        let patterns = try XCTUnwrap(call(service, .getPatterns, [
            "start": .int(Self.mondayTS), "end": .int(Self.mondayTS + 7 * Self.dayMS),
        ]).result?.objectValue)
        let heat = try XCTUnwrap(patterns["heatmap"]?.arrayValue)
        XCTAssertFalse(heat.isEmpty)
        for cell in heat {
            let hour = try XCTUnwrap(cell["hour"]?.intValue)
            XCTAssertTrue((14...17).contains(Int(hour)), "白名单只剩 Safari，只该有下午的格子")
        }
        XCTAssertEqual(patterns["appFilter"]?.arrayValue?.compactMap(\.stringValue), [Self.safari])
        XCTAssertNotNil(patterns["scopeNote"]?.stringValue)

        // ③ recent_activity：白名单同样下推
        let recent = try XCTUnwrap(call(service, .recentActivity,
                                        ["minutes": .int(60)]).result?.objectValue)
        XCTAssertEqual(recent["appFilter"]?.arrayValue?.compactMap(\.stringValue), [Self.safari])
        XCTAssertNotNil(recent["fieldsNote"]?.stringValue)

        // ④ 审计：三条 ok，参数只记形状
        let audit = try store.mcpAuditTail(limit: 10)
        XCTAssertEqual(audit.count, 3)
        XCTAssertEqual(Set(audit.map(\.decision)), [.ok])
        XCTAssertEqual(Set(audit.map(\.tool)),
                       ["get_week_ledger", "get_patterns", "recent_activity"])
        let weekAudit = try XCTUnwrap(audit.first { $0.tool == "get_week_ledger" })
        XCTAssertEqual(weekAudit.params, "week=\(Self.week)")
        let recentAudit = try XCTUnwrap(audit.first { $0.tool == "recent_activity" })
        XCTAssertTrue(recentAudit.params.contains("minutes=60"), recentAudit.params)
    }

    /// T12（schema v6）把叙述写进 `ledgers` 的三个独立列。MCP 这一层要：
    /// ① 键永远在（没有叙述就显式 null）；② 过期的叙述不给正文；
    /// ③ **白名单生效时整段丢掉**——叙述是照整份台账写的，可能点名白名单之外的应用。
    func testMCPPassesThroughNarrativeMetadataAndDropsItUnderWhitelist() throws {
        try seedWorkWeek()
        let service = self.service()
        let days = max(30, Int((Int64(Date().timeIntervalSince1970 * 1000) - Self.mondayTS)
                               / Self.dayMS) + 8)
        try store.setGrant(Grant(clientID: "claude-code", mode: .strictLocal, apps: ["*"],
                                 timeWindowDays: days, fields: .evidence))

        // 没有叙述时：三个键都在，值是 null
        let bare = try XCTUnwrap(call(service, .getWeekLedger,
                                      ["week": .string(Self.week)]).result?.objectValue)
        XCTAssertEqual(bare["narrative"], .null)
        XCTAssertEqual(bare["model"], .null)
        XCTAssertEqual(bare["narrativeMeta"], .null)
        XCTAssertEqual(bare["narrativeGeneratedBy"], .null)
        XCTAssertEqual(bare["narrativeIsStale"]?.boolValue, false)

        // 挂一条叙述上去（走 T12 的入口，computed_at 必须对得上）
        let monday = "2026-09-07"
        let dayLedger = try store.getDayLedger(date: monday)
        let weekLedger = try store.getWeekLedger(weekStart: Self.week)
        func meta(_ computedAt: Int64) -> NarrativeMeta {
            NarrativeMeta(model: "qwen-test", generatedAt: computedAt, inputTokens: 100,
                          inputTokenSource: "estimate", outputTokens: 30, compression: "full",
                          faithfulnessChecked: true, checkedNumbers: 4, checkedApps: 2,
                          truncated: false, ledgerComputedAt: computedAt)
        }
        try store.saveNarrative(level: "day", period: monday, text: "周一上午主要在写代码。",
                                model: "qwen-test", meta: meta(dayLedger.computedAt))
        try store.saveNarrative(level: "week", period: Self.week, text: "这一周以写代码为主。",
                                model: "qwen-test", meta: meta(weekLedger.computedAt))

        let day = try XCTUnwrap(call(service, .getDayLedger,
                                     ["date": .string(monday)]).result?.objectValue)
        XCTAssertEqual(day["narrative"]?.stringValue, "周一上午主要在写代码。")
        XCTAssertEqual(day["model"]?.stringValue, "qwen-test")
        XCTAssertEqual(day["narrativeGeneratedBy"]?.stringValue, "model")
        XCTAssertEqual(day["narrativeIsStale"]?.boolValue, false)
        XCTAssertEqual(day["narrativeMeta"]?["faithfulnessChecked"]?.boolValue, true)
        XCTAssertEqual(day["narrativeMeta"]?["inputTokenSource"]?.stringValue, "estimate")

        let week = try XCTUnwrap(call(service, .getWeekLedger,
                                      ["week": .string(Self.week)]).result?.objectValue)
        XCTAssertEqual(week["narrative"]?.stringValue, "这一周以写代码为主。")
        XCTAssertEqual(week["narrativeMeta"]?["ledgerComputedAt"]?.intValue,
                       weekLedger.computedAt)

        // 换一份带白名单的 grant：叙述整段消失，并且在 droppedFields 里说明
        try store.setGrant(Grant(clientID: "claude-code", mode: .strictLocal,
                                 apps: [Self.safari], timeWindowDays: days, fields: .evidence))
        let scopedDay = try XCTUnwrap(call(service, .getDayLedger,
                                           ["date": .string(monday)]).result?.objectValue)
        XCTAssertEqual(scopedDay["narrative"], .null, "叙述照整天写，白名单裁不动它，只能整段丢")
        let droppedDay = try XCTUnwrap(scopedDay["droppedFields"]?.arrayValue)
            .compactMap(\.stringValue)
        XCTAssertTrue(droppedDay.contains("narrative"))
        XCTAssertTrue(droppedDay.contains("narrativeMeta"))
        let scopedWeek = try XCTUnwrap(call(service, .getWeekLedger,
                                            ["week": .string(Self.week)]).result?.objectValue)
        XCTAssertEqual(scopedWeek["narrative"], .null)
        XCTAssertTrue(try XCTUnwrap(scopedWeek["droppedFields"]?.arrayValue)
            .compactMap(\.stringValue).contains("narrative"))

        // 周台账重算：叙述随之作废（三列一起置 NULL，与日台账同一规矩）
        try store.setGrant(Grant(clientID: "claude-code", mode: .strictLocal, apps: ["*"],
                                 timeWindowDays: days, fields: .evidence))
        _ = try store.getWeekLedger(weekStart: Self.week, recompute: true)
        let afterRecompute = try XCTUnwrap(call(service, .getWeekLedger,
                                                ["week": .string(Self.week)]).result?.objectValue)
        XCTAssertEqual(afterRecompute["narrative"], .null, "台账重算了，旧叙述不再对得上")
        XCTAssertNil(try store.narrativeRecord(level: "week", period: Self.week)?.text)
    }

    func testMCPTimeWindowAndBadArgumentsOnNewTools() throws {
        try seedWorkWeek()
        let service = self.service()
        try store.setGrant(Grant(clientID: "claude-code", mode: .strictLocal, apps: ["*"],
                                 timeWindowDays: 1, fields: .summary))

        // 时间窗只有一天：整周要么被拒、要么带上"覆盖了窗口之前"的标记（台账切不成半周）。
        // 这条**不写死 true / false**——窗口起点是墙钟算出来的，跟合成数据的日期是什么关系
        // 取决于跑测试的那一天与本机时区，写死就是把测试绑在日历上。
        let week = call(service, .getWeekLedger, ["week": .string(Self.week)])
        if week.ok {
            XCTAssertNotNil(week.result?["coversBeforeWindowStart"]?.boolValue,
                            "台账按整周预聚合，切不成半周，这个标记必须永远在")
        } else {
            XCTAssertEqual(week.error?.code, .deniedByGrant)
        }
        // 区间整体落在很久以前 → 被时间窗挡下
        XCTAssertEqual(call(service, .getPatterns, [
            "start": .int(0), "end": .int(Self.dayMS),
        ]).error?.code, .deniedByGrant)

        // 坏参数
        XCTAssertEqual(call(service, .getWeekLedger, [:]).error?.code, .badRequest)
        XCTAssertEqual(call(service, .getWeekLedger, ["week": .string("2026-W99")]).error?.code,
                       .badRequest)
        XCTAssertEqual(call(service, .getPatterns, ["start": .int(Self.mondayTS)]).error?.code,
                       .badRequest)

        // 区间上限（maxPatternDays = 180）：换一份宽时间窗的 grant，免得先被时间窗挡下
        try store.setGrant(Grant(clientID: "claude-code", mode: .strictLocal, apps: ["*"],
                                 timeWindowDays: 3650, fields: .summary))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertEqual(call(service, .getPatterns, [
            "start": .int(now - 300 * Self.dayMS), "end": .int(now),
        ]).error?.code, .badRequest, "区间超过 maxPatternDays")
        XCTAssertEqual(call(service, .getPatterns, [
            "start": .int(now - Self.dayMS), "end": .int(now),
            "focus_block_minutes": .double(0),
        ]).error?.code, .badRequest)
        try store.setGrant(Grant(clientID: "claude-code", mode: .strictLocal, apps: ["*"],
                                 timeWindowDays: 1, fields: .summary))

        // recent_activity 的 minutes 被时间窗封顶
        let recent = try XCTUnwrap(call(service, .recentActivity,
                                        ["minutes": .int(100_000)]).result?.objectValue)
        XCTAssertEqual(recent["minutesClampedByGrant"]?.boolValue, true)
        XCTAssertEqual(recent["minutes"]?.intValue, 1440)
    }
}
