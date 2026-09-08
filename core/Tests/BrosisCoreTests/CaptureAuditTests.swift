import XCTest
@testable import BrosisCore

/// schema v3（M1 R2 / T8）：`capture_audit` 采样审计表、`occurrences` 的 `confidence` / `note`
/// 两个可空列、以及覆盖率口径 `CaptureCoverage`。
///
/// 对应计划 3.3「采样审计」与 D24「短哈希 / 十六进制 / 内存地址标记低置信不作证据」的存储侧。
final class CaptureAuditTests: XCTestCase {

    // MARK: - 覆盖率口径

    /// 完全一致的两段文本覆盖率 = 1。
    func testCoverageIdentical() {
        let text = "本周主线是把采集守护进程跑通：AX 优先，OCR 兜底。errno = -25300"
        let result = CaptureCoverage.coverage(axText: text, ocrText: text)
        XCTAssertEqual(result.coverage, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(result.axTokens, 10)
        XCTAssertEqual(result.hitTokens, result.axTokens)
    }

    /// **口径的核心**：OCR 侧把半角标点识别成全角、换行位置不同、空白多寡不同，
    /// 都不该扣覆盖率（NFKC 折叠 + 去空白去标点之后两边一样）。
    func testCoverageIgnoresPunctuationAndWhitespace() {
        let ax = "func record(_ input: ObservationInput) throws -> RecordResult\n覆盖率 100%"
        let ocr = "func record（_ input：ObservationInput） throws -> RecordResult   覆盖率  100％"
        let result = CaptureCoverage.coverage(axText: ax, ocrText: ocr)
        XCTAssertEqual(result.coverage, 1.0, accuracy: 1e-9)
    }

    /// **NFKC 这一步单独有用例**：口径的第一步是折叠全角，可上一条用例里全角的只有标点——
    /// 标点无论折不折叠都会在第二步被当分隔符丢掉，所以那条用例**测不出折叠**
    /// （把 `normalize` 里的 `TextPipeline.foldForIndex(text)` 换成 `text` 它照样通过）。
    /// 这里用全角**字母与数字**：它们是"内容"字符，不折叠就对不上，折叠了才命中。
    func testCoverageFoldsFullWidthLettersAndDigits() {
        let ax = "OCR 100 capture_audit"
        let ocr = "ＯＣＲ １００ ｃａｐｔｕｒｅ＿ａｕｄｉｔ"
        let result = CaptureCoverage.coverage(axText: ax, ocrText: ocr)
        XCTAssertEqual(result.coverage, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.axTokens, 4)          // OCR / 100 / capture / audit
        XCTAssertEqual(result.hitTokens, 4)
        // 阳性对照：折叠确实发生在 normalize 里——原文里没有半角 "OCR"，规范化之后有。
        XCTAssertFalse(ocr.contains("OCR"))
        XCTAssertTrue(CaptureCoverage.normalize(ocr).contains("OCR"))
    }

    /// OCR 侧多出 AX 读不到的内容（图片里的字）不扣分。
    func testCoverageExtraOCRTextDoesNotPenalize() {
        let ax = "只有这一行是 AX 读到的"
        let ocr = "屏幕上还有一堆别的东西\n只有这一行是 AX 读到的\n以及一张图片里的字"
        XCTAssertEqual(CaptureCoverage.coverage(axText: ax, ocrText: ocr).coverage,
                       1.0, accuracy: 1e-9)
    }

    /// AX 读到一半（视口外的内容 OCR 也看不到）时覆盖率介于 0 和 1 之间，且方向正确。
    func testCoveragePartial() {
        let ax = "第一段在视口内 第二段在视口外 abcdef"
        let ocr = "第一段在视口内"
        let result = CaptureCoverage.coverage(axText: ax, ocrText: ocr)
        XCTAssertGreaterThan(result.coverage, 0.2)
        XCTAssertLessThan(result.coverage, 0.8)
        XCTAssertEqual(result.axChars, ax.count)
        XCTAssertEqual(result.ocrChars, ocr.count)
    }

    /// AX 全空时覆盖率定义为 0（不是 NaN、不是 1）。
    func testCoverageEmptyAX() {
        let result = CaptureCoverage.coverage(axText: "   \n  ", ocrText: "OCR 读到了一些字")
        XCTAssertEqual(result.axTokens, 0)
        XCTAssertEqual(result.coverage, 0)
    }

    /// 重复 token 只计一票：AX 侧把同一个词刷 50 遍不该稀释别的词。
    func testCoverageDeduplicatesTokens() {
        let ax = String(repeating: "重复 ", count: 50) + "唯一"
        let hitAll = CaptureCoverage.coverage(axText: ax, ocrText: "重复 唯一")
        XCTAssertEqual(hitAll.coverage, 1.0, accuracy: 1e-9)
        let missOne = CaptureCoverage.coverage(axText: ax, ocrText: "重复")
        XCTAssertEqual(missOne.axTokens, 2)          // "重复" 与 "唯一" 两个 bigram
        XCTAssertEqual(missOne.hitTokens, 1)
    }

    // MARK: - capture_audit 表

    func testAppendAndReadCaptureAudit() throws {
        let fixture = try Fixture("capture-audit")
        let store = fixture.store!
        let result = CaptureCoverage.coverage(axText: "飞书消息列表第一条", ocrText: "飞书消息列表第一条 还有别的")
        XCTAssertTrue(store.appendCaptureAudit(CaptureAuditRow(
            ts: Synth.baseTS, observationID: 7, app: "com.electron.lark",
            coverage: result, method: .adapter, region: "feishu.message_list", elapsedMS: 42.5)))
        XCTAssertTrue(store.appendCaptureAudit(CaptureAuditRow(
            ts: Synth.baseTS + 1000, observationID: nil, app: "com.apple.Safari",
            coverage: CaptureCoverage.coverage(axText: "网页正文", ocrText: "网页正文"),
            method: .ax, region: "window")))

        XCTAssertEqual(try store.captureAuditCount(), 2)
        let tail = try store.captureAuditTail(limit: 10)
        XCTAssertEqual(tail.count, 2)
        XCTAssertEqual(tail[0].app, "com.apple.Safari")          // 倒序
        XCTAssertNil(tail[0].observationID)
        XCTAssertEqual(tail[1].observationID, 7)
        XCTAssertEqual(tail[1].method, .adapter)
        XCTAssertEqual(tail[1].region, "feishu.message_list")
        XCTAssertEqual(tail[1].elapsedMS, 42.5, accuracy: 1e-9)
        XCTAssertEqual(tail[1].coverage, 1.0, accuracy: 1e-9)

        let scoped = try store.captureAuditTail(limit: 10, app: "com.electron.lark")
        XCTAssertEqual(scoped.count, 1)

        let byApp = store.captureCoverageByApp()
        XCTAssertEqual(byApp.count, 2)
        XCTAssertTrue(byApp.allSatisfy { $0.samples == 1 })
    }

    /// 审计行**不是证据**：观察被删掉之后它照样在（弱引用，没有外键级联）。
    func testCaptureAuditSurvivesObservationDeletion() throws {
        let fixture = try Fixture("capture-audit-delete")
        let store = fixture.store!
        let written = try store.record(Synth.observation(ts: Synth.baseTS, texts: ["一段正文"]))
        XCTAssertTrue(store.appendCaptureAudit(CaptureAuditRow(
            ts: Synth.baseTS, observationID: written.observationID, app: "com.apple.Safari",
            coverage: CaptureCoverage.coverage(axText: "一段正文", ocrText: "一段正文"),
            method: .ax)))
        _ = try store.expire(toBytes: 0)
        XCTAssertEqual(try store.captureAuditCount(), 1)
        XCTAssertEqual(try store.captureAuditTail().first?.observationID, written.observationID)
    }

    /// `maintenance()` 按保留天数滚动清理，与 capture_stats / mcp_audit 同一个口径。
    func testCaptureAuditPruned() throws {
        var options = StoreOptions()
        options.captureAuditRetentionDays = 7
        let fixture = try Fixture("capture-audit-prune", options: options)
        let store = fixture.store!
        let now = Synth.baseTS
        let old = now - 8 * 86_400_000
        for ts in [old, now] {
            XCTAssertTrue(store.appendCaptureAudit(CaptureAuditRow(
                ts: ts, app: "com.apple.Safari",
                coverage: CaptureCoverage.coverage(axText: "正文", ocrText: "正文"), method: .ax)))
        }
        let report = try store.maintenance(now: now)
        XCTAssertEqual(report.captureAuditPruned, 1)
        XCTAssertEqual(try store.captureAuditCount(), 1)
    }

    // MARK: - occurrences 的两个新列

    func testFragmentConfidenceAndNoteRoundTrip() throws {
        let fixture = try Fixture("fragment-confidence")
        let store = fixture.store!
        let written = try store.record(ObservationInput(
            ts: Synth.baseTS, app: AppRef(bundleID: "com.tencent.xinWeChat", name: "微信"),
            trigger: .frameDirty, captureMethod: .mixed, completeness: .partial,
            texts: [
                TextFragment(text: "AX 读到的一段", region: "ax:AXStaticText"),
                TextFragment(text: "OCR 读到的一段 0x7ffee4b2", region: "ocr:wechat.chat_panel",
                             confidence: 0.72, note: "lowconf=1 rect=0,0,800,600"),
            ]))
        let evidence = try store.getEvidence(ids: [written.observationID],
                                             grant: nil, neighbors: 0)
        let occurrences = try XCTUnwrap(evidence.items.first?.occurrences)
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertNil(occurrences[0].confidence)          // AX 片段没有置信度
        XCTAssertNil(occurrences[0].note)
        XCTAssertEqual(occurrences[1].confidence ?? 0, 0.72, accuracy: 1e-9)
        XCTAssertEqual(occurrences[1].note, "lowconf=1 rect=0,0,800,600")
        XCTAssertEqual(occurrences[1].region, "ocr:wechat.chat_panel")
    }

    /// 向后兼容：老写法 `TextFragment(text:region:)` 一字不改，读回来两列是 nil。
    func testLegacyFragmentInitStillCompiles() throws {
        let fixture = try Fixture("fragment-legacy")
        let store = fixture.store!
        let written = try store.record(ObservationInput(
            ts: Synth.baseTS, app: AppRef(bundleID: "com.apple.Safari", name: "Safari"),
            trigger: .timer, captureMethod: .ax, completeness: .partial,
            texts: [TextFragment(text: "老写法的一段正文", region: "AXWebArea")]))
        let occurrence = try XCTUnwrap(
            try store.getEvidence(ids: [written.observationID], grant: nil, neighbors: 0)
                .items.first?.occurrences.first)
        XCTAssertNil(occurrence.confidence)
        XCTAssertNil(occurrence.note)
    }

    // MARK: - v2 → v3 就地迁移

    /// 把一个 v3 库**改回 v2 的形状**（删表、删列、改 meta），关库再开，
    /// 确认 `migrateIfNeeded` 就地补上而不是重建库：老数据一行不少、一字不改。
    func testMigrationV2ToV3() throws {
        let fixture = try Fixture("migrate-v3")
        let store = fixture.store!
        let written = try store.record(Synth.observation(ts: Synth.baseTS, texts: ["迁移前写进去的正文"]))

        try store.withLock { conn in
            try conn.exec("DROP TABLE capture_audit;")
            try conn.exec("ALTER TABLE occurrences DROP COLUMN confidence;")
            try conn.exec("ALTER TABLE occurrences DROP COLUMN note;")
            // 夹具的库是按当前 schema 建的：要装成 v2，v3 及之后的审计行都得抹掉。
            try conn.run("DELETE FROM migrations WHERE version >= 3;")
            try conn.run("UPDATE meta SET value = '2' WHERE key = 'schema_version';")
        }
        try fixture.reopen()
        let reopened = fixture.store!

        let version = try reopened.withLock { conn in
            try conn.scalarText("SELECT value FROM meta WHERE key = 'schema_version';")
        }
        // 迁移会从 v2 一路补到**当前** schema 版本，所以这里跟着 Schema.version 走，
        // 不写死版本号（M2 c 批同时有 v4 / v5 两个新版本落地）。
        XCTAssertEqual(version, String(Schema.version))
        let columns = try reopened.withLock { conn in
            try conn.textColumn("SELECT name FROM pragma_table_info('occurrences');")
        }
        XCTAssertTrue(columns.contains("confidence"))
        XCTAssertTrue(columns.contains("note"))
        let notes = try reopened.withLock { conn in
            try conn.textColumn("SELECT note FROM migrations ORDER BY version;")
        }
        // 重开时 migrateIfNeeded 从 v2 一路补到当前版本，每版留一条审计行。
        XCTAssertEqual(notes.count, Schema.version)
        XCTAssertTrue(notes[2].contains("capture_audit"))

        // 老数据原样在，新表可写
        XCTAssertEqual(try reopened.evidenceText(observationID: written.observationID),
                       "迁移前写进去的正文")
        XCTAssertEqual(try reopened.captureAuditCount(), 0)
        XCTAssertTrue(reopened.appendCaptureAudit(CaptureAuditRow(
            ts: Synth.baseTS, app: "com.apple.Safari",
            coverage: CaptureCoverage.coverage(axText: "a", ocrText: "a"), method: .ax)))
        XCTAssertEqual(try reopened.captureAuditCount(), 1)
    }
}
