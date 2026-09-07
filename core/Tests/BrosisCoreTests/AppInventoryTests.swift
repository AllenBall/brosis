import XCTest
@testable import BrosisCore

/// 3.12 应用采集清单窗口的数据层：`appObservationStats` / `appPolicies` / `appNames`。
///
/// 这三个查询的存在理由是"不要让采集端扫全表再自己数"，所以除了数值正确，
/// 还有一条用例盯着 `EXPLAIN QUERY PLAN`：7 天窗口必须走 `idx_obs_live` 部分索引。
final class AppInventoryTests: XCTestCase {

    private let day: Int64 = 24 * 3600 * 1000

    private func input(ts: Int64, bundle: String, name: String,
                       completeness: Completeness,
                       texts: [String] = []) -> ObservationInput {
        ObservationInput(
            ts: ts, displayID: 1,
            app: AppRef(bundleID: bundle, name: name),
            windowTitle: "窗口",
            trigger: .timer, captureMethod: .ax, completeness: completeness,
            sourceState: .ok,
            texts: texts.enumerated().map { TextFragment(text: $1, region: "{\"ord\":\($0)}") })
    }

    // MARK: - 观察数与完整性分布

    /// 三个应用、四种 completeness、一条窗口外的观察、一条已删除的观察：
    /// 计数、分布、最近出现时间、排序全部逐字段核对。
    func testStatsCountsAndDistribution() throws {
        let fixture = try Fixture("app-inventory-stats")
        let store = fixture.store!
        let now = Synth.baseTS
        let since = now - 7 * day

        // Safari：窗口内 4 条（complete 2 / partial 1 / unavailable 1）+ 窗口外 1 条。
        try store.record(input(ts: now - 1 * day, bundle: "com.apple.Safari", name: "Safari",
                               completeness: .complete, texts: ["一"]))
        try store.record(input(ts: now - 2 * day, bundle: "com.apple.Safari", name: "Safari",
                               completeness: .complete, texts: ["二"]))
        try store.record(input(ts: now - 3 * day, bundle: "com.apple.Safari", name: "Safari",
                               completeness: .partial, texts: ["三"]))
        try store.record(input(ts: now - 6 * day, bundle: "com.apple.Safari", name: "Safari",
                               completeness: .unavailable))
        try store.record(input(ts: now - 30 * day, bundle: "com.apple.Safari", name: "Safari",
                               completeness: .complete, texts: ["窗口外，不该被数进来"]))

        // 微信：窗口内 2 条，都是 excluded（「只记事件」那一档写的就是它）。
        try store.record(input(ts: now - 1 * day, bundle: "com.tencent.xinWeChat", name: "微信",
                               completeness: .excluded))
        try store.record(input(ts: now - 4 * day, bundle: "com.tencent.xinWeChat", name: "微信",
                               completeness: .excluded))

        // 访达：窗口内 1 条，稍后删掉——删除后不该再出现在清单里。
        let doomed = try store.record(input(ts: now - 2 * day, bundle: "com.apple.finder",
                                            name: "访达", completeness: .complete,
                                            texts: ["待删除"]))

        let before = try store.appObservationStats(since: since)
        XCTAssertEqual(before.map(\.bundleID),
                       ["com.apple.Safari", "com.tencent.xinWeChat", "com.apple.finder"],
                       "按观察数倒序：4 > 2 > 1")

        let safari = try XCTUnwrap(before.first { $0.bundleID == "com.apple.Safari" })
        XCTAssertEqual(safari.name, "Safari")
        XCTAssertEqual(safari.observations, 4, "窗口外那条不算")
        XCTAssertEqual(safari.complete, 2)
        XCTAssertEqual(safari.partial, 1)
        XCTAssertEqual(safari.unavailable, 1)
        XCTAssertEqual(safari.excluded, 0)
        XCTAssertEqual(safari.complete + safari.partial + safari.unavailable + safari.excluded,
                       safari.observations, "四态之和 == 总数")
        XCTAssertEqual(safari.lastSeenMS, now - 1 * day)

        let wechat = try XCTUnwrap(before.first { $0.bundleID == "com.tencent.xinWeChat" })
        XCTAssertEqual(wechat.observations, 2)
        XCTAssertEqual(wechat.excluded, 2)
        XCTAssertEqual(wechat.complete, 0)

        // 删除之后：访达整行消失（deleted_at IS NULL 过滤掉了它唯一那条观察）。
        _ = try store.deleteObservations([doomed.observationID], reason: .policy)
        let after = try store.appObservationStats(since: since)
        XCTAssertNil(after.first { $0.bundleID == "com.apple.finder" },
                     "墓碑行不进清单统计")
        XCTAssertEqual(after.first { $0.bundleID == "com.apple.Safari" }?.observations, 4)

        // since = 0 就是全库：Safari 变回 5 条。
        let all = try store.appObservationStats(since: 0)
        XCTAssertEqual(all.first { $0.bundleID == "com.apple.Safari" }?.observations, 5)
    }

    /// D17 同步过来的**另一台设备**的观察不参与本机的清单统计
    /// （3.12：`app_policies` 是本机配置，两台机器分别设置，统计口径也必须只看本机）。
    ///
    /// 另一台机器的行只能直接写进去：`Store.deviceID` 是建库时写进 `meta` 的，
    /// 重开库不会换，所以走 `withLock` 直接 INSERT 一行 `device_id = 'another-device'`，
    /// 模拟同步落下来的那一行。
    func testStatsAreDeviceScoped() throws {
        let fixture = try Fixture("app-inventory-device")
        let store = fixture.store!
        let now = Synth.baseTS
        try store.record(input(ts: now, bundle: "com.apple.Safari", name: "Safari",
                               completeness: .complete, texts: ["本机"]))

        try store.withLock { conn in
            let appID = try XCTUnwrap(try conn.scalarInt(
                "SELECT id FROM apps WHERE bundle_id = 'com.apple.Safari';"))
            _ = try conn.run("""
                INSERT INTO observations(device_id, id, ts, display_id, app_id, "trigger",
                                         capture_method, completeness, source_state)
                VALUES ('another-device', 1, ?, 1, ?, 'timer', 'ax', 'complete', 'ok');
                """, [.int(now), .int(appID)])
        }

        XCTAssertEqual(try store.count(table: "observations"), 2, "库里确实有两条")
        let stats = try store.appObservationStats(since: 0)
        XCTAssertEqual(stats.first { $0.bundleID == "com.apple.Safari" }?.observations, 1,
                       "本机只数本机那一条，另一台设备同步下来的那条不算")
    }

    /// 7 天窗口必须走 `idx_obs_live` 部分索引，不能是 `SCAN observations`。
    /// 这是这三个查询存在的理由（不让 app 扫全表），所以单独一条用例盯着它。
    func testStatsUsesPartialIndex() throws {
        let fixture = try Fixture("app-inventory-plan")
        try fixture.store.record(input(ts: Synth.baseTS, bundle: "com.apple.Safari",
                                       name: "Safari", completeness: .complete, texts: ["一"]))
        let plan = try fixture.store.appObservationStatsPlan()
        let joined = plan.joined(separator: " | ")
        XCTAssertTrue(joined.contains("idx_obs_live"), "实际计划：\(joined)")
        XCTAssertFalse(joined.contains("SCAN observations") && !joined.contains("idx_obs_live"),
                       "实际计划：\(joined)")
    }

    // MARK: - app_policies 全表与应用名

    func testAppPoliciesRoundTrip() throws {
        let fixture = try Fixture("app-inventory-policies")
        let store = fixture.store!
        XCTAssertTrue(try store.appPolicies().isEmpty)

        try store.setAppPolicy(bundleID: "com.apple.Safari", mode: .eventsAndContent, source: .default)
        try store.setAppPolicy(bundleID: "com.1password.1password", mode: .none,
                               source: .builtinDenylist)
        try store.setAppPolicy(bundleID: "com.tencent.xinWeChat", mode: .eventsOnly, source: .user)

        let rows = try store.appPolicies()
        XCTAssertEqual(rows.map(\.bundleID),
                       ["com.1password.1password", "com.apple.Safari", "com.tencent.xinWeChat"],
                       "按 bundle id 排序")
        XCTAssertEqual(rows.map(\.mode), [.none, .eventsAndContent, .eventsOnly])
        XCTAssertEqual(rows.map(\.source), [.builtinDenylist, .default, .user])
        XCTAssertTrue(rows.allSatisfy { $0.updatedAt > 0 })

        // 改档是 UPSERT：行数不变，mode / source 变。
        try store.setAppPolicy(bundleID: "com.tencent.xinWeChat", mode: .none, source: .user)
        let after = try store.appPolicies()
        XCTAssertEqual(after.count, 3)
        // 写全名：`.none` 在 Optional 上下文里会被解成 `Optional.none`（= nil），不是这一档。
        XCTAssertEqual(after.first { $0.bundleID == "com.tencent.xinWeChat" }?.mode,
                       CapturePolicyMode.none)
    }

    /// `appNames()` 给"有策略行但最近 7 天没观察"的应用提供显示名。
    func testAppNames() throws {
        let fixture = try Fixture("app-inventory-names")
        let store = fixture.store!
        try store.record(input(ts: Synth.baseTS, bundle: "com.apple.Safari", name: "Safari",
                               completeness: .complete, texts: ["一"]))
        try store.record(input(ts: Synth.baseTS, bundle: "com.tencent.xinWeChat", name: "微信",
                               completeness: .excluded))
        let names = try store.appNames()
        XCTAssertEqual(names["com.apple.Safari"], "Safari")
        XCTAssertEqual(names["com.tencent.xinWeChat"], "微信")
        XCTAssertNil(names["com.1password.1password"], "没写过观察的应用不在 apps 表里")
    }

    /// 3.12「改为更低档时询问是否删除该应用已有数据」走的就是 `deleteByApp(reason: .policy)`：
    /// 删完之后这个应用在清单统计里归零，策略行还在（策略是配置，不是数据）。
    func testDeleteByAppClearsStatsButKeepsPolicy() throws {
        let fixture = try Fixture("app-inventory-delete")
        let store = fixture.store!
        let now = Synth.baseTS
        for i in 0..<3 {
            try store.record(input(ts: now - Int64(i) * day, bundle: "com.tencent.xinWeChat",
                                   name: "微信", completeness: .complete, texts: ["消息 \(i)"]))
        }
        try store.setAppPolicy(bundleID: "com.tencent.xinWeChat", mode: .eventsOnly, source: .user)
        XCTAssertEqual(try store.appObservationStats(since: 0)
                        .first { $0.bundleID == "com.tencent.xinWeChat" }?.observations, 3)
        // 「要不要弹那个删数据的框」看的是全库计数，不是 7 天窗口。
        XCTAssertEqual(try store.appObservationCount(bundleID: "com.tencent.xinWeChat"), 3)
        XCTAssertEqual(try store.appObservationCount(bundleID: "com.apple.Safari"), 0,
                       "从没写过观察的应用是 0，不是报错")

        let summary = try store.deleteByApp(bundleID: "com.tencent.xinWeChat", reason: .policy)
        XCTAssertEqual(summary.observationsAffected, 3)
        XCTAssertEqual(summary.reason, .policy)
        XCTAssertNil(try store.appObservationStats(since: 0)
                        .first { $0.bundleID == "com.tencent.xinWeChat" },
                     "删完之后这个应用不再出现在清单统计里")
        XCTAssertEqual(try store.appObservationCount(bundleID: "com.tencent.xinWeChat"), 0,
                       "墓碑行不算在内")
        XCTAssertEqual(try store.appPolicies().first { $0.bundleID == "com.tencent.xinWeChat" }?.mode,
                       .eventsOnly, "策略行不受数据删除影响")
    }
}
