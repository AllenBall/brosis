import XCTest
@testable import BrosisCore

/// D22：中文按字符 bigram 预处理写入 unicode61 FTS，查询同样预处理。
final class BigramFTSTests: XCTestCase {

    /// 与 `tools/bench/fts_compare.py` 的 `bigram_join()` 逐字对照的黄金用例。
    /// 这些期望值是按那段 Python 的语义手算的：汉字连续段切重叠 bigram，
    /// 非汉字片段原样保留，全部用单个空格连接（所以汉字段与英文段之间会出现两个空格）。
    func testBigramMatchesPythonReference() {
        let cases: [(String, String)] = [
            ("知识图谱 research", "知识 识图 图谱  research"),
            ("会议纪要", "会议 议纪 纪要"),
            ("中", "中"),                                  // 单字连续段保留该字
            ("hello world", "hello world"),                // 全非汉字：原样
            ("", ""),
            ("A中文B", "A 中文 B"),
            ("数据库SQLCipher加密", "数据 据库 SQLCipher 加密"),
            ("一二三", "一二 二三"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TextPipeline.bigram(input), expected, "bigram(\(input))")
        }
    }

    func testFTSPhraseWrapsAndEscapes() {
        XCTAssertEqual(TextPipeline.ftsPhrase("会议纪要"), "\"会议 议纪 纪要\"")
        XCTAssertEqual(TextPipeline.ftsPhrase("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testSingleCJKCharNeedsScanFallback() {
        XCTAssertTrue(TextPipeline.requiresScanFallback("中"))
        XCTAssertFalse(TextPipeline.requiresScanFallback("中文"))
        XCTAssertFalse(TextPipeline.requiresScanFallback("a"))
    }

    /// 口径（M1 R1 定案）：**入库不折叠**。原文逐字节存，sha256 与 byte_len 都按原文算。
    func testRawTextIsStoredVerbatimAndHashedByRawBytes() throws {
        let f = try Fixture("raw-text")
        let store = f.store!
        // 全角冒号 / 括号 / 字母 / 数字 —— NFKC 会改写的那几类都在里面；真 CJK 标点「。」不受影响
        let body = "第一段：ＳＱＬ（１００）测试，全角标点。"
        XCTAssertNotEqual(TextPipeline.foldForIndex(body), body, "这段正文确实是 NFKC 会改写的")

        let r = try store.record(Synth.observation(ts: Synth.baseTS, texts: [body]))
        let stored = try store.textVersionText(id: r.textVersionIDs[0])
        XCTAssertEqual(stored, body, "读回的正文必须与写入的逐字节相同")
        XCTAssertEqual(Array((stored ?? "").utf8), Array(body.utf8))
        XCTAssertEqual(try store.evidenceText(observationID: r.observationID), body)

        let row = try store.withLock { conn -> (Data?, Int64?) in
            let st = try conn.prepare("SELECT sha256, byte_len FROM text_versions WHERE id = ?;")
            defer { st.finalize() }
            try st.bind([.int(r.textVersionIDs[0])])
            guard try st.step() else { return (nil, nil) }
            return (st.blob(0), st.int(1))
        }
        XCTAssertEqual(row.0, TextPipeline.sha256(body), "sha256 按原文 UTF-8 字节算")
        XCTAssertNotEqual(row.0, TextPipeline.sha256(TextPipeline.foldForIndex(body)),
                          "不能再按折叠后的值算 sha256")
        XCTAssertEqual(row.1, Int64(body.utf8.count), "byte_len 按原文")
    }

    /// 折叠只用于索引：全角写法与半角写法是**两个**版本（去重按原文字节），
    /// 但两者的 FTS 行是同一串 bigram，所以两种写法的查询互相都能命中、子串复核不误杀。
    func testFullwidthAndHalfwidthAreSeparateVersionsButShareIndexForm() throws {
        let f = try Fixture("nfkc")
        let store = f.store!
        let a = try store.record(Synth.observation(ts: Synth.baseTS, texts: ["ＳＱＬ 100"]))
        let b = try store.record(Synth.observation(ts: Synth.baseTS + 1, texts: ["SQL 100"]))
        XCTAssertNotEqual(a.textVersionIDs, b.textVersionIDs, "去重按原文字节：全角与半角是两个版本")
        XCTAssertEqual(try store.count(table: "text_versions"), 2)
        XCTAssertEqual(try store.textVersionText(id: a.textVersionIDs[0]), "ＳＱＬ 100")
        XCTAssertEqual(try store.textVersionText(id: b.textVersionIDs[0]), "SQL 100")
        // 索引侧：两行 FTS 的 body 逐字节相同
        XCTAssertEqual(TextPipeline.bigramForIndex("ＳＱＬ 100"),
                       TextPipeline.bigramForIndex("SQL 100"))
        let both = Set(a.textVersionIDs + b.textVersionIDs)
        XCTAssertEqual(Set(try store.searchFTS("SQL").map(\.textVersionID)), both,
                       "半角查询要同时命中全角与半角两条")
        XCTAssertEqual(Set(try store.searchFTS("ＳＱＬ").map(\.textVersionID)), both,
                       "全角查询同样")
    }

    // MARK: - 往返

    func testBigramRoundTripMixedChineseEnglish() throws {
        let f = try Fixture("fts")
        let store = f.store!
        let body = "第三季度设计评审：SQLCipher 加密存储与 contentless FTS5 的对账口径。"
        let other = "另一段无关正文：模型管理器与断点续传。"

        let hit = try store.record(Synth.observation(ts: Synth.baseTS, texts: [body]))
        _ = try store.record(Synth.observation(ts: Synth.baseTS + 1_000, texts: [other]))

        // 中文短语命中
        for phrase in ["设计评审", "加密存储", "第三季度", "对账口径"] {
            let hits = try store.searchFTS(phrase)
            XCTAssertEqual(hits.count, 1, "短语「\(phrase)」应当命中 1 条")
            XCTAssertEqual(hits.first?.textVersionID, hit.textVersionIDs[0])
        }
        // 英文词命中
        for word in ["SQLCipher", "contentless", "FTS5"] {
            XCTAssertEqual(try store.searchFTS(word).count, 1, "英文词「\(word)」应当命中")
        }
        // 中英混排短语
        XCTAssertEqual(try store.searchFTS("加密存储").count, 1)
        // 不存在的短语
        XCTAssertEqual(try store.searchFTS("量子计算").count, 0)
        // 跨边界的假阳性由子串复核滤掉
        XCTAssertEqual(try store.searchFTS("评审SQLCipher", substringRecheck: true).count, 0)

        // 删除后不再命中
        _ = try store.deleteObservations([hit.observationID])
        for phrase in ["设计评审", "加密存储", "SQLCipher"] {
            XCTAssertEqual(try store.searchFTS(phrase).count, 0, "删除后「\(phrase)」不应再命中")
            XCTAssertEqual(try store.ftsMatchCount(phrase), 0)
        }
        XCTAssertEqual(try store.searchFTS("模型管理器").count, 1, "另一条不受影响")
        XCTAssertEqual(try store.ftsRowCount(), 1)
        XCTAssertTrue(try store.integrityReport().allPassed)
    }

    /// D22 的已知限制：单个汉字在 bigram 索引里命中不了，必须走扫描通道（3.4）。
    func testSingleCJKCharDoesNotMatchViaFTS() throws {
        let f = try Fixture("fts-short")
        let store = f.store!
        _ = try store.record(Synth.observation(ts: Synth.baseTS, texts: ["评"]))
        _ = try store.record(Synth.observation(ts: Synth.baseTS + 1, texts: ["设计评审会议"]))
        // 单字查询：索引里没有单字 token，命中数是 1（那条正文本身就是单字，token 也是它）
        // ——真正的失败模式是"用单字去查长正文"，这里断言的就是它查不到长正文。
        let hits = try store.searchFTS("评", substringRecheck: false)
        XCTAssertFalse(hits.contains { $0.textVersionID == 2 },
                       "单字查询命中不了长正文，必须由 T3 的扫描通道兜底")
        XCTAssertTrue(TextPipeline.requiresScanFallback("评"))
    }

    // MARK: - FTS 对账

    func testMaintenanceReconcilesFTS() throws {
        let f = try Fixture("recon")
        let store = f.store!
        for i in 0..<10 {
            _ = try store.record(Synth.observation(ts: Synth.baseTS + Int64(i),
                                                   texts: ["对账正文 #\(i) 会议纪要"]))
        }
        XCTAssertEqual(try store.ftsRowCount(), 10)

        // 人为制造两种不一致：删一条 FTS 行、插一条孤儿 FTS 行
        try store.withLock { conn in
            try conn.exec("DELETE FROM text_fts WHERE rowid = 3;")
            try conn.run("INSERT INTO text_fts(rowid, body) VALUES (999999, ?);",
                         [.text(TextPipeline.bigram("孤儿 FTS 行"))])
        }
        var report = try store.integrityReport()
        XCTAssertFalse(report.allPassed, "制造出来的不一致必须被 13 项检查抓到")

        let m = try store.maintenance()
        XCTAssertEqual(m.orphanFTSRowsDeleted, 1)
        XCTAssertEqual(m.missingFTSRowsInserted, 1)

        report = try store.integrityReport()
        XCTAssertTrue(report.allPassed, "对账之后必须干净")
        XCTAssertEqual(try store.ftsRowCount(), 10)
        XCTAssertEqual(try store.searchFTS("对账正文").count, 10, "补写的 FTS 行必须能被查到")
    }

    func testMaintenanceReclaimsSpace() throws {
        var options = StoreOptions()
        options.captureStatsRetentionDays = 1
        let f = try Fixture("vacuum", options: options)
        let store = f.store!
        for i in 0..<400 {
            _ = try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(i) * 1_000,
                texts: ["体积正文 #\(i) " + String(repeating: "回收测试 vacuum ", count: 40)]))
        }
        for i in 0..<50 {
            _ = try store.recordCaptureStat(ts: Synth.baseTS - Int64(i) * 86_400_000,
                                            status: "complete", gated: i % 2 == 0)
        }
        // 第一次 maintenance 顺带把过期遥测清掉（后面那次就没得清了，所以断言打在这一次）
        let first = try store.maintenance(now: Synth.baseTS)
        XCTAssertEqual(first.captureStatsPruned, 48,
                       "保留 1 天时，ts 比 now-1d 更旧的 48 行遥测要清掉")
        let before = try store.stats()
        _ = try store.expire(toBytes: 0)
        let m = try store.maintenance(now: Synth.baseTS)
        let after = try store.stats()

        XCTAssertGreaterThan(m.freelistBefore, 0, "删完之后应当有空闲页可回收")
        XCTAssertEqual(m.freelistAfter, 0, "incremental_vacuum 必须把空闲页清零")
        XCTAssertLessThan(after.dbFileBytes, before.dbFileBytes, "主库文件确实变小")
        XCTAssertEqual(m.walBytesAfter, 0, "wal_checkpoint(TRUNCATE) 之后 WAL 为 0")
        XCTAssertTrue(try store.integrityReport().allPassed)
    }
}
