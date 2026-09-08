import XCTest
@testable import BrosisCore

/// E3 的七个场景在**加密库**上复跑（D25 遗留项 / M0 收口清单第 10 条）。
/// 场景编号与 `tools/proto/test_correctness.py` 对齐，只有 S6 换成计划里点名的"应用切换"，
/// 崩溃恢复放到 S7（`CrashRecoveryTests`），因为它要跨进程 `kill -9`。
final class E3ScenarioTests: XCTestCase {

    // MARK: - S1 文本版本复用

    func testS1_TextVersionReuse() throws {
        let f = try Fixture("s1")
        let store = f.store!
        let text = "同一段正文：会议纪要 knowledge graph 2026-09-07"

        var results: [RecordResult] = []
        for i in 0..<5 {
            results.append(try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(i) * 10_000,
                bundle: i % 2 == 0 ? "com.apple.Safari" : "com.microsoft.VSCode",
                appName: i % 2 == 0 ? "Safari" : "Code",
                texts: [text])))
        }

        XCTAssertEqual(try store.count(table: "text_versions"), 1, "同一段文本只应有一个版本")
        XCTAssertEqual(try store.count(table: "occurrences"), 5, "五次出现各留一条 occurrence")
        XCTAssertEqual(try store.count(table: "observations"), 5)
        XCTAssertEqual(try store.ftsRowCount(), 1, "FTS 行与 text_versions 一比一")
        XCTAssertEqual(results.first?.newTextVersions, 1)
        XCTAssertEqual(results.dropFirst().reduce(0) { $0 + $1.reusedTextVersions }, 4)
        let ids = Set(results.flatMap(\.textVersionIDs))
        XCTAssertEqual(ids.count, 1, "五次观察指向同一个 text_version")

        // 同一设备内 sha256 不重复
        let report = try store.integrityReport()
        XCTAssertTrue(report.allPassed, "S1 后一致性检查应全过：\(report.danglingChecks.filter { !$0.ok })")
    }

    // MARK: - S2 正文修改

    func testS2_ContentEdited() throws {
        let f = try Fixture("s2")
        let store = f.store!
        // 口径（M1 R1 定案）：入库**不**折叠，NFKC 只用于索引。全角逗号 U+FF0C 原样入库，
        // 库里存的、检索到的、取证据拿到的都是原文。
        let v1 = "预算 100 万，负责人张三。"
        let v2 = "预算 200 万，负责人张三。"
        XCTAssertNotEqual(TextPipeline.foldForIndex(v1), v1,
                          "这段正文确实是 NFKC 会改写的（全角逗号），所以下面的断言才有意义")

        let r1 = try store.record(Synth.observation(ts: Synth.baseTS, texts: [v1]))
        let r2 = try store.record(Synth.observation(ts: Synth.baseTS + 60_000, texts: [v2]))

        XCTAssertEqual(try store.count(table: "text_versions"), 2, "改一个字就是新版本")
        XCTAssertNotEqual(r1.textVersionIDs, r2.textVersionIDs)

        // 按 observation 能唯一确定当时看到的是哪一版
        XCTAssertEqual(try store.evidenceText(observationID: r1.observationID), v1)
        XCTAssertEqual(try store.evidenceText(observationID: r2.observationID), v2)

        // 两版都可检索
        XCTAssertGreaterThan(try store.ftsMatchCount("预算 100"), 0)
        XCTAssertGreaterThan(try store.ftsMatchCount("预算 200"), 0)

        // text_versions 不可变：UPDATE 必须被触发器 ABORT
        let updated = store.attemptTextVersionUpdate(id: r1.textVersionIDs[0], newText: "篡改")
        XCTAssertFalse(updated, "UPDATE text_versions 必须被 trg_text_versions_immutable 拒绝")
        XCTAssertEqual(try store.textVersionText(id: r1.textVersionIDs[0]), v1, "原文没被改动")
    }

    // MARK: - S3 用户删除级联（FTS 行数独立复核）

    func testS3_UserDeleteCascade() throws {
        let f = try Fixture("s3")
        let store = f.store!
        // 缩略图占位文件，验证删除时一并清理
        try FileManager.default.createDirectory(at: store.thumbnailDirectory,
                                                withIntermediateDirectories: true)
        func makeThumb(_ name: String) throws {
            try Data("thumb".utf8).write(to: store.thumbnailDirectory.appendingPathComponent(name))
        }

        let doomedCanary = "只属于飞书的独占正文 EXCLUSIVE7F3A"
        let survivorCanary = "只属于 Safari 的独占正文 SURVIVOR2D9B"

        try makeThumb("a.png")
        let doomed = try store.record(Synth.observation(
            ts: Synth.baseTS, bundle: "com.electron.lark", appName: "飞书",
            window: "飞书 — 群聊", host: "feishu.example.com", thumb: "a.png",
            texts: [doomedCanary]))
        let survivor = try store.record(Synth.observation(
            ts: Synth.baseTS + 10_000, texts: [survivorCanary]))

        // 派生结果：一个 session 引用被删观察，一个 ledger 用 D23 的区间表示
        let sessionID = try store.insertSession(
            start: Synth.baseTS, end: Synth.baseTS + 20_000, displayID: 1, primaryAppID: nil,
            dwellS: 20, activeS: 12, unknownS: 0, interruptions: 0,
            evidenceObservationIDs: [doomed.observationID, survivor.observationID])
        let ledgerID = try store.insertLedger(
            level: "day", period: "2026-09-04",
            ledgerJSON: "{\"total_s\":20}",
            evidenceObservationIDs: [doomed.observationID, doomed.observationID])

        // 删除前：三个入口都能拿到内容，FTS 能命中
        XCTAssertEqual(try store.evidenceText(observationID: doomed.observationID), doomedCanary)
        XCTAssertEqual(try store.ftsMatchCount(doomedCanary), 1)
        XCTAssertFalse(try store.contextTexts(from: Synth.baseTS - 1, to: Synth.baseTS + 60_000)
            .filter { $0.contains(doomedCanary) }.isEmpty)
        XCTAssertFalse(try store.dayLedgerTexts(level: "day", period: "2026-09-04").isEmpty)

        let ftsBefore = try store.ftsRowCount()
        let summary = try store.deleteByApp(bundleID: "com.electron.lark")

        // 审计字段
        XCTAssertEqual(summary.observationsAffected, 1)
        XCTAssertEqual(summary.occurrencesDeleted, 1)
        XCTAssertEqual(summary.textVersionsDeleted, 1)
        XCTAssertEqual(summary.thumbsDeleted, 1)
        XCTAssertEqual(summary.sessionsStale, 1)
        XCTAssertEqual(summary.ledgersStale, 1)
        XCTAssertEqual(summary.reason, .user)

        // FTS 行数独立复核：审计字段不是照抄 text_versions_deleted，而是实测差值
        let ftsAfter = try store.ftsRowCount()
        XCTAssertEqual(ftsBefore - ftsAfter, summary.ftsRowsDeleted,
                       "deletions.fts_rows_deleted 必须等于实测的 FTS 行减少量")
        XCTAssertEqual(summary.ftsRowsDeleted, 1)

        // 删除后：三个入口都不再返回内容
        XCTAssertNil(try store.evidenceText(observationID: doomed.observationID))
        XCTAssertEqual(try store.ftsMatchCount(doomedCanary), 0, "FTS 行必须真的删掉")
        XCTAssertTrue(try store.contextTexts(from: Synth.baseTS - 1, to: Synth.baseTS + 60_000)
            .filter { $0.contains(doomedCanary) }.isEmpty)
        XCTAssertTrue(try store.dayLedgerTexts(level: "day", period: "2026-09-04").isEmpty,
                      "台账被标 stale 后不再返回内容")

        // 墓碑还在（审计与 D17 同步要用），但没有 occurrence、没有 thumb_ref
        XCTAssertEqual(try store.count(table: "observations"), 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.thumbnailDirectory.appendingPathComponent("a.png").path))

        // 未被删的那条完好
        XCTAssertEqual(try store.evidenceText(observationID: survivor.observationID), survivorCanary)
        XCTAssertEqual(try store.ftsMatchCount(survivorCanary), 1)

        let stale = try store.staleFlags(table: "sessions")
        XCTAssertEqual(stale.first(where: { $0.id == sessionID })?.stale, true)
        XCTAssertEqual(try store.staleFlags(table: "ledgers").first(where: { $0.id == ledgerID })?.stale, true)

        XCTAssertTrue(try store.integrityReport().allPassed)
    }

    // MARK: - S4 共享文本版本

    func testS4_SharedTextVersion() throws {
        let f = try Fixture("s4")
        let store = f.store!
        let shared = "共享正文 SHAREDCANARY5E1C 出现在三个应用里"

        let a = try store.record(Synth.observation(ts: Synth.baseTS, bundle: "com.apple.Safari",
                                                   appName: "Safari", texts: [shared]))
        let b = try store.record(Synth.observation(ts: Synth.baseTS + 10_000,
                                                   bundle: "com.microsoft.VSCode",
                                                   appName: "Code", texts: [shared]))
        let c = try store.record(Synth.observation(ts: Synth.baseTS + 20_000,
                                                   bundle: "com.apple.Terminal",
                                                   appName: "终端", texts: [shared]))
        let tvID = a.textVersionIDs[0]
        XCTAssertEqual(try store.count(table: "text_versions"), 1)
        XCTAssertEqual(try store.occurrenceCount(textVersionID: tvID), 3)

        // 直接删还被引用的版本必须被外键 RESTRICT 挡住
        XCTAssertFalse(store.attemptTextVersionDelete(id: tvID),
                       "occurrences.text_version_id 是 ON DELETE RESTRICT，被引用时删不掉")
        XCTAssertTrue(try store.textVersionExists(id: tvID))

        // 删掉两个 occurrence：版本必须保留，FTS 仍能命中
        _ = try store.deleteObservations([a.observationID])
        XCTAssertTrue(try store.textVersionExists(id: tvID))
        XCTAssertEqual(try store.ftsMatchCount(shared), 1)
        _ = try store.deleteObservations([b.observationID])
        XCTAssertTrue(try store.textVersionExists(id: tvID), "还有一条 occurrence，版本不能删")
        XCTAssertEqual(try store.occurrenceCount(textVersionID: tvID), 1)
        XCTAssertEqual(try store.ftsMatchCount(shared), 1)

        // 删掉最后一个：版本与 FTS 行一起消失
        let last = try store.deleteObservations([c.observationID])
        XCTAssertEqual(last.textVersionsDeleted, 1)
        XCTAssertEqual(last.ftsRowsDeleted, 1)
        XCTAssertFalse(try store.textVersionExists(id: tvID))
        XCTAssertEqual(try store.ftsMatchCount(shared), 0)
        XCTAssertEqual(try store.ftsRowCount(), 0)

        XCTAssertTrue(try store.integrityReport().allPassed)
    }

    // MARK: - S5 配额过期

    func testS5_QuotaExpire() throws {
        var options = StoreOptions()
        options.quotaBytes = 4_000
        let f = try Fixture("s5", options: options)
        let store = f.store!

        let warned = Box<(used: Int, quota: Int)?>(nil)
        store.quotaWarningHandler = { used, quota in warned.value = (used, quota) }

        // 每条一段独占正文（不共享），方便按字节精确判断"最旧先删"
        var ids: [Int64] = []
        for i in 0..<40 {
            let r = try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(i) * 60_000,
                texts: ["独占正文 #\(i) " + String(repeating: "配额", count: 20)]))
            ids.append(r.observationID)
        }
        let payloadBefore = try store.stats().textPayloadBytes
        XCTAssertGreaterThan(payloadBefore, options.quotaBytes)

        // 先做一次用户删除，验证两种语义可区分
        _ = try store.deleteObservations([ids[39]])

        // batch 取小一点，让它删到刚好低于配额就停，而不是一次删光（便于验证"最旧先删"）
        let report = try store.expire(batchSize: 3)
        XCTAssertNotNil(warned.value, "越过 80% 阈值必须回调")
        XCTAssertTrue(report.warningThresholdCrossed)
        XCTAssertLessThanOrEqual(report.afterBytes, options.quotaBytes, "必须降到配额以下")
        XCTAssertEqual(report.summary?.reason, .quota)
        XCTAssertGreaterThan(report.summary?.observationsAffected ?? 0, 0)

        // 最旧先删：留下来的观察 id 全都大于被删掉的最大 id（合成流里 id 与 ts 同序）
        let remaining = try store.liveObservationIDs()
        XCTAssertFalse(remaining.isEmpty, "不应该删光——batch 3 时删到低于配额就该停")
        let deletedCount = Int64(report.summary?.observationsAffected ?? 0)
        XCTAssertEqual(remaining.min(), deletedCount + 1, "被删的正是最旧的那一段连续 id")
        XCTAssertNotNil(report.oldestDeletedTS)
        XCTAssertEqual(report.oldestDeletedTS, Synth.baseTS, "从最旧的那条开始删")

        // 配额过期是物理删除，用户删除留墓碑：两者可区分
        let stats = try store.stats()
        XCTAssertEqual(stats.tombstonedObservations, 1, "只有用户删除那一条留了墓碑")
        XCTAssertEqual(stats.observations, stats.liveObservations + stats.tombstonedObservations)

        // 两条路径各有独立审计行
        let rows = try store.deletionRows()
        XCTAssertEqual(rows.filter { $0.reason == "user" }.count, 1)
        XCTAssertEqual(rows.filter { $0.reason == "quota" }.count, 1)
        let quotaRow = rows.first { $0.reason == "quota" }!
        XCTAssertTrue(quotaRow.params.contains("oldest_first"))
        XCTAssertTrue(quotaRow.params.contains("ts_from"), "配额审计行是区间墓碑，要带时间范围")
        XCTAssertTrue(quotaRow.params.contains("\"synced\":false"), "配额是本机策略，不参与 D17 同步")

        // FTS 行与 text_versions 保持一致
        XCTAssertEqual(try store.ftsRowCount(), try store.count(table: "text_versions"))
        XCTAssertTrue(try store.integrityReport().allPassed)
    }

    // MARK: - S6 应用切换

    func testS6_AppSwitch() throws {
        let f = try Fixture("s6")
        let store = f.store!
        let sequence: [(String, String, String)] = [
            ("com.apple.Safari", "Safari", "Safari — 计划"),
            ("com.electron.lark", "飞书", "飞书 — 群聊"),
            ("com.apple.Safari", "Safari", "Safari — 计划"),      // 回到同一窗口
            ("com.apple.Safari", "Safari", "Safari — 另一个页"),   // 同应用换窗口
            ("com.microsoft.VSCode", "Code", "Code — Store.swift"),
        ]
        for (i, item) in sequence.enumerated() {
            _ = try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(i) * 5_000,
                bundle: item.0, appName: item.1, window: item.2,
                trigger: .appSwitch,
                texts: ["切到 \(item.1)：\(item.2)"]))
        }

        XCTAssertEqual(try store.count(table: "observations"), 5, "每次切换一条观察")
        XCTAssertEqual(try store.count(table: "apps"), 3, "规范化对象按 bundle_id 复用")
        XCTAssertEqual(try store.count(table: "windows"), 4, "同应用的两个标题是两个窗口对象")

        // 按应用取观察
        XCTAssertEqual(try store.liveObservationIDs(app: "com.apple.Safari").count, 3)
        XCTAssertEqual(try store.liveObservationIDs(app: "com.electron.lark").count, 1)

        // 按应用删除只影响该应用
        let summary = try store.deleteByApp(bundleID: "com.electron.lark")
        XCTAssertEqual(summary.observationsAffected, 1)
        XCTAssertEqual(try store.liveObservationIDs(app: "com.apple.Safari").count, 3)
        // 规范化对象本身不删（ON DELETE RESTRICT），只删证据
        XCTAssertEqual(try store.count(table: "apps"), 3)
        XCTAssertTrue(try store.integrityReport().allPassed)
    }

    // MARK: - 13 项悬空引用总检（跑完混合操作之后）

    func testDanglingChecksAfterMixedOperations() throws {
        var options = StoreOptions()
        options.quotaBytes = 6_000
        let f = try Fixture("dangling", options: options)
        let store = f.store!
        try FileManager.default.createDirectory(at: store.thumbnailDirectory,
                                                withIntermediateDirectories: true)

        for i in 0..<60 {
            let shared = i % 4 == 0
            let thumb = "t\(i).png"
            try Data("t".utf8).write(to: store.thumbnailDirectory.appendingPathComponent(thumb))
            _ = try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(i) * 30_000,
                bundle: ["com.apple.Safari", "com.electron.lark", "com.microsoft.VSCode"][i % 3],
                appName: ["Safari", "飞书", "Code"][i % 3],
                window: "窗口 \(i % 5)",
                host: ["example.com", "docs.internal"][i % 2],
                path: "/doc/\(i % 7)",
                file: i % 3 == 0 ? "/tmp/brosis-test/f\(i % 6).md" : nil,
                thumb: thumb,
                texts: [shared ? "共享正文块 A" : "独占正文 #\(i) " + String(repeating: "字", count: 30)]))
        }
        _ = try store.insertSession(start: Synth.baseTS, end: Synth.baseTS + 100_000,
                                    displayID: 1, primaryAppID: nil,
                                    dwellS: 100, activeS: 40, unknownS: 0, interruptions: 1,
                                    evidenceObservationIDs: Array(1...10))
        _ = try store.insertLedger(level: "day", period: "2026-09-04",
                                   ledgerJSON: "{}", evidenceObservationIDs: [1, 20])

        _ = try store.deleteByApp(bundleID: "com.electron.lark")
        _ = try store.deleteByTimeRange(start: Synth.baseTS, end: Synth.baseTS + 300_000)
        _ = try store.deleteByObject(.host("docs.internal"))
        _ = try store.expire()
        _ = try store.maintenance()

        let report = try store.integrityReport()
        // 13 = E3 的 S7 原班项；+3 = v4（M2 c / T11）的 chunks / vec_chunks 悬空检查。
        XCTAssertEqual(report.danglingChecks.count, 16, "E3 的 13 项 + v4 的 3 项悬空检查一项不少")
        for item in report.danglingChecks {
            XCTAssertEqual(item.value, item.expected, "悬空检查未通过：\(item.name) = \(item.value)")
        }
        XCTAssertEqual(report.integrityCheck, "ok")
        XCTAssertEqual(report.ftsIntegrityCheck, "ok")
        XCTAssertEqual(report.foreignKeyViolations, 0)

        // 重开库后仍然一致
        try f.reopen(options: options)
        XCTAssertTrue(try f.store.integrityReport().allPassed)
    }
}
