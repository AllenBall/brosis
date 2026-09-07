import XCTest
@testable import BrosisCore

/// 会话化与日台账（计划 3.7）。三个常量的边界、双屏并集、增量构建、删除后 stale 重算。
final class SessionLedgerTests: XCTestCase {

    static let dayStart: Int64 = 1_756_944_000_000        // 2025-09-04T00:00:00Z
    static let day = "2025-09-04"

    private func makeFixture(_ name: String) throws -> Fixture {
        let f = try Fixture(name)
        f.store.retrieval.timeZone = TimeZone(identifier: "UTC")!
        return f
    }

    private func observation(_ offsetS: Int64, app: String = "A", display: Int64 = 1,
                             sourceState: SourceState = .ok,
                             host: String? = nil, file: String? = nil) -> ObservationInput {
        let url: URLRef? = host.map {
            URLRef(rawLocator: "https://\($0)/p", canonicalURL: "https://\($0)/p", host: $0, kind: .web)
        }
        return ObservationInput(
            ts: Self.dayStart + offsetS * 1000, displayID: display,
            app: AppRef(bundleID: "com.test." + app, name: app),
            windowTitle: "窗口 " + app, url: url, filePath: file,
            trigger: .timer, captureMethod: .ax, completeness: .complete,
            sourceState: sourceState,
            texts: [TextFragment(text: "应用 \(app) 在 \(offsetS) 秒的一屏正文。", region: nil)])
    }

    // MARK: - 三个常量的边界

    /// 间隔上限 300 s：小于它接同一个会话，大于等于它切开。
    func testGapConstantBoundary() throws {
        let f = try makeFixture("gap")
        let store = f.store!
        try store.record(batch: [observation(0), observation(299)])
        try store.buildSessions(force: true)
        XCTAssertEqual(try store.sessionCount(), 1, "299 s < 300 s 应当是一个会话")

        let g = try makeFixture("gap2")
        try g.store.record(batch: [observation(0), observation(300)])
        try g.store.buildSessions(force: true)
        XCTAssertEqual(try g.store.sessionCount(), 2, "300 s ≥ 300 s 应当切成两个会话")

        // 常量可配置：把间隔上限调大，同样的数据又变回一个会话
        let h = try makeFixture("gap3")
        h.store.sessionConfig.gapSeconds = 600
        try h.store.record(batch: [observation(0), observation(300)])
        try h.store.buildSessions(force: true)
        XCTAssertEqual(try h.store.sessionCount(), 1)
    }

    /// 停留上限 90 s：一条观察最多代表 90 s。
    func testMaxDwellConstantBoundary() throws {
        let f = try makeFixture("dwell")
        let store = f.store!
        try store.record(batch: [observation(0), observation(200), observation(260)])
        try store.buildSessions(force: true)
        let rows = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(rows.count, 1)
        // 0→200 记 90（封顶），200→260 记 60，最后一条没有下一条记 0
        XCTAssertEqual(rows[0].dwellS, 150, accuracy: 0.001)
        XCTAssertEqual(rows[0].activeS, 150, accuracy: 0.001)
        XCTAssertEqual(rows[0].unknownS, 0, accuracy: 0.001)

        let g = try makeFixture("dwell2")
        g.store.sessionConfig.maxDwellSeconds = 30
        try g.store.record(batch: [observation(0), observation(200), observation(260)])
        try g.store.buildSessions(force: true)
        let rows2 = try g.store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(rows2[0].dwellS, 60, accuracy: 0.001, "上限 30 s 时两段各记 30 s")
    }

    /// 打断上限 20 s：A→B→A，离开 ≤ 20 s 记一次打断且不切会话；> 20 s 切成两个会话。
    /// **20 s 整算打断**（闭区间）——10 s 一次采集时，一条观察的外出往返正好 20 s，
    /// 用严格小于的话默认常量下一次打断都观测不到，见 `splitSessions` 里的注释。
    func testInterruptionConstantBoundary() throws {
        let short = try makeFixture("interrupt-short")
        try short.store.record(batch: [observation(0, app: "A"), observation(5, app: "B"),
                                       observation(15, app: "A"), observation(30, app: "A")])
        try short.store.buildSessions(force: true)
        let shortRows = try short.store.sessions(from: Self.dayStart,
                                                 to: Self.dayStart + 86_400_000)
        let aShort = shortRows.filter { $0.appBundleID == "com.test.A" }
        XCTAssertEqual(aShort.count, 1, "离开 15 s ≤ 20 s，A 应当还是一个会话")
        XCTAssertEqual(aShort[0].interruptions, 1)
        XCTAssertEqual(aShort[0].observationIDs, [1, 3, 4])

        // 边界：10 s 采集节奏下一条观察的外出往返，delta 正好 20 s
        let edge = try makeFixture("interrupt-edge")
        try edge.store.record(batch: [observation(0, app: "A"), observation(10, app: "B"),
                                      observation(20, app: "A"), observation(30, app: "A")])
        try edge.store.buildSessions(force: true)
        let aEdge = try edge.store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
            .filter { $0.appBundleID == "com.test.A" }
        XCTAssertEqual(aEdge.count, 1, "离开正好 20 s 应当算打断")
        XCTAssertEqual(aEdge[0].interruptions, 1)

        let long = try makeFixture("interrupt-long")
        try long.store.record(batch: [observation(0, app: "A"), observation(5, app: "B"),
                                      observation(25, app: "A"), observation(40, app: "A")])
        try long.store.buildSessions(force: true)
        let longRows = try long.store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        let aLong = longRows.filter { $0.appBundleID == "com.test.A" }
        XCTAssertEqual(aLong.count, 2, "离开 25 s > 20 s，A 应当切成两个会话")
        XCTAssertEqual(aLong.map(\.interruptions), [0, 0])

        // 常量可配置：把打断上限调到 30 s，25 s 的离开也变成打断
        let wide = try makeFixture("interrupt-wide")
        wide.store.sessionConfig.interruptionSeconds = 30
        try wide.store.record(batch: [observation(0, app: "A"), observation(5, app: "B"),
                                      observation(25, app: "A"), observation(40, app: "A")])
        try wide.store.buildSessions(force: true)
        let aWide = try wide.store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
            .filter { $0.appBundleID == "com.test.A" }
        XCTAssertEqual(aWide.count, 1)
        XCTAssertEqual(aWide[0].interruptions, 1)
    }

    // MARK: - 三类时间分列

    func testThreeTimeBucketsAreSeparate() throws {
        let f = try makeFixture("buckets")
        let store = f.store!
        try store.record(batch: [
            observation(0, sourceState: .ok),            // 0→10 计入 dwell + active
            observation(10, sourceState: .userIdle),     // 10→20 只计入 dwell
            observation(20, sourceState: .permissionLost), // 20→30 计入 unknown
            observation(30, sourceState: .locked),       // 30→40 计入 unknown
            observation(40, sourceState: .ok),           // 最后一条记 0
        ])
        try store.buildSessions(force: true)
        let rows = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].dwellS, 20, accuracy: 0.001)
        XCTAssertEqual(rows[0].activeS, 10, accuracy: 0.001)
        XCTAssertEqual(rows[0].unknownS, 20, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rows[0].activeS, rows[0].dwellS, "active 是 dwell 的子集")
    }

    // MARK: - 双屏：焦点归属计时 + 区间并集

    func testDualDisplayFocusVersusUnion() throws {
        let f = try makeFixture("dual-display")
        let store = f.store!
        // 两块屏各两条观察，时间完全重叠：焦点归属各记 30 s，区间并集只有 30 s。
        try store.record(batch: [
            observation(0, app: "A", display: 1), observation(0, app: "B", display: 2),
            observation(30, app: "A", display: 1), observation(30, app: "B", display: 2),
        ])
        try store.buildSessions(force: true)
        let rows = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(rows.count, 2, "两块屏各自一个会话")
        XCTAssertEqual(Set(rows.map { $0.displayID ?? -1 }), [1, 2])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.dwellS }, 60, accuracy: 0.001)

        let ledger = try store.getDayLedger(date: Self.day, recompute: true)
        XCTAssertEqual(ledger.focusDwellS, 60, accuracy: 0.001, "按焦点归属求和会重复计")
        XCTAssertEqual(ledger.onlineUnionS, 30, accuracy: 0.001, "区间并集是「总在线」，不重复计")
        XCTAssertEqual(ledger.perDisplayDwellS["1"], 30)
        XCTAssertEqual(ledger.perDisplayDwellS["2"], 30)
        XCTAssertEqual(IntervalMath.unionMilliseconds([(0, 10), (5, 20), (30, 40)]), 30)
        XCTAssertEqual(IntervalMath.unionMilliseconds([]), 0)
    }

    // MARK: - 增量构建

    func testIncrementalBuildOnlyScansNewObservations() throws {
        let f = try makeFixture("incremental")
        let store = f.store!
        try store.record(batch: (0..<10).map { observation(Int64($0) * 1000) })  // 每条隔 1000 s
        let first = try store.buildSessions()
        XCTAssertFalse(first.incremental)
        XCTAssertNil(first.fromTS)
        XCTAssertEqual(first.observationsScanned, 10)
        XCTAssertEqual(first.sessionsInserted, 10)

        try store.record(batch: (10..<13).map { observation(Int64($0) * 1000) })
        let second = try store.buildSessions()
        XCTAssertTrue(second.incremental)
        XCTAssertNotNil(second.fromTS)
        XCTAssertLessThan(second.observationsScanned, 13, "增量构建不该把全部观察重扫一遍")
        XCTAssertEqual(try store.sessionCount(), 13)

        // 增量结果必须和全量重算一致
        let incrementalRows = try store.sessions(from: Self.dayStart,
                                                 to: Self.dayStart + 86_400_000)
        try store.buildSessions(force: true)
        let fullRows = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(incrementalRows.map(\.start), fullRows.map(\.start))
        XCTAssertEqual(incrementalRows.map(\.dwellS), fullRows.map(\.dwellS))
        XCTAssertEqual(incrementalRows.map(\.observationIDs), fullRows.map(\.observationIDs))
    }

    /// **增量构建必须与全量重建逐字段相等**——两块屏边界不对齐 + 一次打断的场景。
    ///
    /// 这是 R1 验收发现的阻断项：重算起点只按 `start >= rebuildFrom` 删会话时，
    /// 起点更早、尾巴伸进重算区间的会话被原样留下，它里面 `ts >= rebuildFrom` 的观察
    /// 又被重扫分进新会话，同一条观察进了两个会话（1 个月库上的表现是
    /// `--force` 8,189 段、紧接着零新观察的 `--build` 变成 8,190 段）。
    /// 现在起点按 `"end" >= rebuildFrom` 取不动点，留下的会话与重扫区间不相交。
    func testIncrementalBuildMatchesFullRebuildWithTwoDisplaysAndInterruption() throws {
        let f = try makeFixture("incremental-two-displays")
        let store = f.store!
        // 屏 1：A@0 →（离开 20 s，正好算一次打断）→ B@10 → A@20 回到 A → A@30，
        //       于是会话 A（start 0）里有 ts = 20 / 30 两条观察，排在会话 B（start 10）之后。
        // 屏 2：C@40 / C@50 —— 屏 2 最后一个会话的起点（40）比屏 1 的（10）晚，
        //       增量锚点 min(10, 40) = 10 就落在了会话 A 的中间。
        try store.record(batch: [
            observation(0, app: "A", display: 1),
            observation(10, app: "B", display: 1),
            observation(20, app: "A", display: 1),
            observation(30, app: "A", display: 1),
            observation(40, app: "C", display: 2),
            observation(50, app: "C", display: 2),
        ])
        try store.buildSessions(force: true)
        let full = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(full.count, 3)
        XCTAssertEqual(full.map(\.observationIDs), [[1, 3, 4], [2], [5, 6]])
        XCTAssertEqual(full[0].interruptions, 1)

        // ① 零新观察的增量构建必须幂等
        let report = try store.buildSessions()
        XCTAssertTrue(report.incremental)
        let again = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(again.count, full.count, "零新观察的增量构建不能凭空多出会话")
        XCTAssertEqual(again.map(\.start), full.map(\.start))
        XCTAssertEqual(again.map(\.end), full.map(\.end))
        XCTAssertEqual(again.map(\.observationIDs), full.map(\.observationIDs))
        XCTAssertEqual(again.map(\.dwellS), full.map(\.dwellS))
        XCTAssertEqual(again.map(\.activeS), full.map(\.activeS))
        XCTAssertEqual(again.map(\.unknownS), full.map(\.unknownS))
        XCTAssertEqual(again.map(\.interruptions), full.map(\.interruptions))
        // 一条观察只能进一个会话，时长也不能重复计
        let ids = again.flatMap(\.observationIDs)
        XCTAssertEqual(Set(ids).count, ids.count, "同一条观察不能同时出现在两个会话里")
        XCTAssertEqual(Set(ids), Set((1 as Int64)...6))
        XCTAssertEqual(again.reduce(0) { $0 + $1.dwellS },
                       full.reduce(0) { $0 + $1.dwellS }, accuracy: 0.001)

        // ② 追加新观察之后，增量结果仍与全量重建逐字段相等
        try store.record(batch: [observation(60, app: "A", display: 1),
                                 observation(70, app: "C", display: 2)])
        try store.buildSessions()
        let incremental = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        try store.buildSessions(force: true)
        let rebuilt = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(incremental.map(\.start), rebuilt.map(\.start))
        XCTAssertEqual(incremental.map(\.end), rebuilt.map(\.end))
        XCTAssertEqual(incremental.map(\.observationIDs), rebuilt.map(\.observationIDs))
        XCTAssertEqual(incremental.map(\.dwellS), rebuilt.map(\.dwellS))
        XCTAssertEqual(incremental.map(\.interruptions), rebuilt.map(\.interruptions))
        let ids2 = incremental.flatMap(\.observationIDs)
        XCTAssertEqual(Set(ids2).count, ids2.count)
        XCTAssertEqual(Set(ids2), Set((1 as Int64)...8))
    }

    /// **同一块屏上两条观察的 ts 完全相同**（毫秒时间戳，记录器取 `Date()`，schema 上也没有
    /// `(device_id, display_id, ts)` 唯一约束，所以真实采集里是可能的）。
    ///
    /// 这是 R1 第二轮验收发现的阻断项：前一条观察的时间片长度是 0（`end == ts`），
    /// 它所在的会话满足 `"end" == 重算起点` 且 `start < 重算起点`，于是被留下，
    /// 可它含着 `ts == 起点` 的那条观察，重扫又把这条观察分进一个新会话——
    /// 零新观察的 `--build` 从 3 段变 4 段、`id 3` 出现两次，而且再 `--build` 也不自愈。
    /// 修法见 `Store.boundaryStartToInclude`：不动点收敛后再查一次边界。
    func testIncrementalBuildWithSameMillisecondObservationsOnOneDisplay() throws {
        let f = try makeFixture("incremental-same-ms")
        let store = f.store!
        // 同一块屏：A@0、A@10、A@20、**B@20（与上一条同一毫秒，且换了应用）**、B@30、C@120、C@130
        try store.record(batch: [
            observation(0, app: "A", display: 1),
            observation(10, app: "A", display: 1),
            observation(20, app: "A", display: 1),
            observation(20, app: "B", display: 1),
            observation(30, app: "B", display: 1),
            observation(120, app: "C", display: 1),
            observation(130, app: "C", display: 1),
        ])
        try store.buildSessions(force: true)
        let full = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(full.count, 3)
        XCTAssertEqual(full.map(\.observationIDs), [[1, 2, 3], [4, 5], [6, 7]])

        // 零新观察的增量构建连跑两次：都必须与全量重建逐字段相等，且证据 id 不重复。
        for round in 1...2 {
            let report = try store.buildSessions()
            XCTAssertTrue(report.incremental, "第 \(round) 轮应当走增量")
            let again = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
            XCTAssertEqual(again.count, full.count, "第 \(round) 轮凭空多出了会话")
            XCTAssertEqual(again.map(\.start), full.map(\.start))
            XCTAssertEqual(again.map(\.end), full.map(\.end))
            XCTAssertEqual(again.map(\.observationIDs), full.map(\.observationIDs))
            XCTAssertEqual(again.map(\.dwellS), full.map(\.dwellS))
            XCTAssertEqual(again.map(\.activeS), full.map(\.activeS))
            XCTAssertEqual(again.map(\.unknownS), full.map(\.unknownS))
            XCTAssertEqual(again.map(\.interruptions), full.map(\.interruptions))
            let ids = again.flatMap(\.observationIDs)
            XCTAssertEqual(Set(ids).count, ids.count, "同一条观察不能同时出现在两个会话里")
            XCTAssertEqual(Set(ids), Set((1 as Int64)...7))
        }

        // 两块屏上各有一对同毫秒观察，边界又不对齐时也必须成立。
        let g = try makeFixture("incremental-same-ms-two-displays")
        try g.store.record(batch: [
            observation(0, app: "A", display: 1),
            observation(20, app: "A", display: 1),
            observation(20, app: "B", display: 1),
            observation(40, app: "C", display: 2),
            observation(40, app: "D", display: 2),
            observation(60, app: "D", display: 2),
        ])
        try g.store.buildSessions(force: true)
        let fullTwo = try g.store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        try g.store.buildSessions()
        let againTwo = try g.store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(againTwo.map(\.observationIDs), fullTwo.map(\.observationIDs))
        XCTAssertEqual(againTwo.map(\.dwellS), fullTwo.map(\.dwellS))
        let idsTwo = againTwo.flatMap(\.observationIDs)
        XCTAssertEqual(Set(idsTwo).count, idsTwo.count)
        XCTAssertEqual(Set(idsTwo), Set((1 as Int64)...6))
    }

    /// 会话延长的场景：新观察落在老会话的间隔以内，增量构建必须把那个会话重算而不是新建一个。
    func testIncrementalBuildExtendsLastSession() throws {
        let f = try makeFixture("incremental-extend")
        let store = f.store!
        try store.record(batch: [observation(0), observation(10)])
        try store.buildSessions()
        XCTAssertEqual(try store.sessionCount(), 1)
        try store.record(observation(20))
        let report = try store.buildSessions()
        XCTAssertTrue(report.incremental)
        XCTAssertEqual(try store.sessionCount(), 1, "同一个会话应当被重算并延长，不是多出一个")
        let rows = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(rows[0].observationIDs, [1, 2, 3])
        XCTAssertEqual(rows[0].dwellS, 20, accuracy: 0.001)
    }

    // MARK: - 删除后标 stale、重算后清掉

    func testDeleteMarksSessionsStaleAndRebuildRecomputes() throws {
        let f = try makeFixture("stale")
        let store = f.store!
        try store.record(batch: (0..<6).map { observation(Int64($0) * 10) })
        try store.buildSessions(force: true)
        XCTAssertEqual(try store.sessionCount(), 1)
        XCTAssertEqual(try store.staleFlags(table: "sessions").filter(\.stale).count, 0)

        let summary = try store.deleteObservations([3])
        XCTAssertEqual(summary.sessionsStale, 1)
        XCTAssertEqual(try store.staleFlags(table: "sessions").filter(\.stale).count, 1)
        // stale 的会话不进区间查询结果（等重算）
        XCTAssertTrue(try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000).isEmpty)

        let report = try store.buildSessions()
        XCTAssertEqual(report.staleRecomputed, 1)
        XCTAssertEqual(try store.staleFlags(table: "sessions").filter(\.stale).count, 0)
        let rows = try store.sessions(from: Self.dayStart, to: Self.dayStart + 86_400_000)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].observationIDs.contains(3), "被删的观察不能再出现在证据里")
        XCTAssertEqual(rows[0].observationIDs, [1, 2, 4, 5, 6])
    }

    // MARK: - 日台账

    func testDayLedgerShape() throws {
        let f = try makeFixture("ledger")
        let store = f.store!
        try store.record(batch: [
            observation(0, app: "A", host: "docs.internal", file: "/tmp/a.md"),
            observation(30, app: "A", host: "docs.internal", file: "/tmp/a.md"),
            observation(60, app: "B", host: "example.com"),
            observation(120, app: "A", host: "docs.internal", file: "/tmp/a.md"),
            observation(150, app: "A", host: "docs.internal", file: "/tmp/a.md"),
        ])
        try store.buildSessions(force: true)
        let ledger = try store.getDayLedger(date: Self.day, recompute: true)

        XCTAssertEqual(ledger.date, Self.day)
        XCTAssertEqual(ledger.timeZone, "GMT")
        XCTAssertEqual(ledger.start, Self.dayStart)
        XCTAssertEqual(ledger.observations, 5)
        XCTAssertNil(ledger.narrative, "3.7：台账与叙述分开标注，M1 不产叙述")
        XCTAssertNil(ledger.model)
        XCTAssertEqual(ledger.sessionConfig, store.sessionConfig)
        XCTAssertEqual(ledger.evidence, [[1, 5]], "D23：证据用区间表示")

        let appA = try XCTUnwrap(ledger.apps.first { $0.key == "com.test.A" })
        XCTAssertEqual(appA.observations, 4)
        XCTAssertEqual(appA.switches, 2, "A → B → A 是两次切入 A")
        // 0→30、30→60 各 30 s；120→150 30 s；最后一条 0 s
        XCTAssertEqual(appA.dwellS, 90, accuracy: 0.001)
        let site = try XCTUnwrap(ledger.sites.first { $0.key == "docs.internal" })
        XCTAssertEqual(site.observations, 4)
        let file = try XCTUnwrap(ledger.files.first { $0.key == "/tmp/a.md" })
        XCTAssertEqual(file.observations, 4)
        XCTAssertEqual(ledger.totalDwellS, ledger.focusDwellS, accuracy: 0.001)

        // 台账是确定性的：重算两次除了 computedAt 完全一样
        let again = try store.getDayLedger(date: Self.day, recompute: true)
        XCTAssertEqual(again.apps.map(\.dwellS), ledger.apps.map(\.dwellS))
        XCTAssertEqual(again.evidence, ledger.evidence)
        // 缓存命中：不重算时读回的是同一份
        let cached = try store.getDayLedger(date: Self.day)
        XCTAssertEqual(cached.computedAt, again.computedAt)
        XCTAssertEqual(try store.observationDays(), [Self.day])
    }

    /// 跨日边界：一条观察的时间片伸进第二天时，时长按天裁开，观察数只算它自己那天的。
    func testDayLedgerClipsAcrossMidnight() throws {
        let f = try makeFixture("ledger-midnight")
        let store = f.store!
        try store.record(batch: [
            observation(86_400 - 40),        // 前一天 23:59:20，片段 40 s 里有 40 s 落在当天
            observation(86_400 + 50),        // 第二天 00:00:50
        ])
        try store.buildSessions(force: true)
        let d1 = try store.getDayLedger(date: Self.day, recompute: true)
        let d2 = try store.getDayLedger(date: "2025-09-05", recompute: true)
        XCTAssertEqual(d1.observations, 1)
        XCTAssertEqual(d2.observations, 1)
        // 第一条封顶 90 s：40 s 在当天，50 s 落到第二天
        XCTAssertEqual(d1.totalDwellS, 40, accuracy: 0.001)
        XCTAssertEqual(d2.totalDwellS, 50, accuracy: 0.001)
    }
}
