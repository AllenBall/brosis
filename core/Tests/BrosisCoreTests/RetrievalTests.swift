import XCTest
@testable import BrosisCore

/// 三通道检索（计划 3.4）、证据展开与 3.6 的工具签名。
final class RetrievalTests: XCTestCase {

    // 2025-09-04T00:00:00Z，固定的 UTC 日边界，台账与时间线的断言都挂在它上面。
    static let dayStart: Int64 = 1_756_944_000_000
    static let dayMS: Int64 = 86_400_000

    private func makeFixture(_ name: String) throws -> Fixture {
        let f = try Fixture(name)
        f.store.retrieval.timeZone = TimeZone(identifier: "UTC")!
        return f
    }

    private func observation(ts: Int64, bundle: String = "com.apple.Safari",
                             appName: String = "Safari", window: String = "窗口甲",
                             display: Int64 = 1, host: String? = nil, locator: String? = nil,
                             file: String? = nil, sourceState: SourceState = .ok,
                             texts: [String]) -> ObservationInput {
        let url: URLRef? = host.map {
            let raw = locator ?? "https://\($0)/doc/1"
            return URLRef(rawLocator: raw, canonicalURL: raw, host: $0, kind: .web)
        }
        return ObservationInput(
            ts: ts, displayID: display, app: AppRef(bundleID: bundle, name: appName),
            windowTitle: window, url: url, filePath: file,
            trigger: .timer, captureMethod: .ax, completeness: .complete,
            sourceState: sourceState,
            texts: texts.enumerated().map { TextFragment(text: $1, region: "{\"ord\":\($0)}") })
    }

    // MARK: - 1. FTS 通道：bigram 命中 / 未命中 / 子串复核

    func testBigramChannelHitAndMiss() throws {
        let f = try makeFixture("fts-hit-miss")
        let store = f.store!
        try store.record(observation(ts: Self.dayStart + 1000,
                                     texts: ["这一轮把知识图谱的口径写进了文档，M0 结束前不再改。"]))
        try store.record(observation(ts: Self.dayStart + 2000, window: "窗口乙",
                                     texts: ["采集覆盖率这周从百分之六十一提到百分之七十八。"]))

        // 命中：多字中文短语走 bigram phrase
        let hit = try store.search(q: "知识图谱")
        XCTAssertEqual(hit.channels, [.fts])
        XCTAssertEqual(hit.hits.count, 1)
        XCTAssertEqual(hit.hits.first?.channel, .fts)
        XCTAssertTrue(hit.hits.first?.snippet.contains("知识图谱") == true)

        // 未命中：语料里不存在的词
        let miss = try store.search(q: "蟠桃调度器")
        XCTAssertTrue(miss.hits.isEmpty)
        XCTAssertEqual(miss.ftsCandidates, 0)

        // 跨句边界不应命中：bigram 不跨非汉字片段
        XCTAssertTrue(try store.search(q: "文档采集").hits.isEmpty)
    }

    /// 子串复核只作用于 FTS 通道候选（3.4）：`unicode61` 会把 `abc-def` 切成两个 token，
    /// phrase 查询于是命中了正文里的 `abc def`，但正文并不含 `abc-def` 这个子串。
    func testSubstringRecheckDropsTokenizerFalsePositive() throws {
        let f = try makeFixture("fts-recheck")
        let store = f.store!
        try store.record(observation(ts: Self.dayStart + 1000,
                                     texts: ["brosis abc def ghi 这一段是给评审看的。"]))
        XCTAssertFalse(store.hasCompatibilityText,
                       "这段正文折叠后不变，库标志不置位，扫描通道就不用展开查询串")
        let result = try store.search(q: "abc-def")
        XCTAssertGreaterThanOrEqual(result.ftsCandidates, 1, "分词器应当把它当成 phrase 命中")
        XCTAssertEqual(result.ftsVerified, 0, "子串复核必须把它滤掉")
        XCTAssertTrue(result.hits.isEmpty)

        // 反向对照：正文里真的有这个子串时必须命中。
        try store.record(observation(ts: Self.dayStart + 2000, window: "窗口乙",
                                     texts: ["brosis abc-def ghi 这一段是给评审看的。"]))
        let good = try store.search(q: "abc-def")
        XCTAssertEqual(good.ftsVerified, 1)
        XCTAssertEqual(good.hits.count, 1)
    }

    /// NFKC 口径（M1 R1 定案：折叠只用于索引、正文存原文）在 FTS 通道上的两条：
    /// ① 全角正文原样入库；② 它的 FTS 行是折叠后的形式，半角与全角查询都能 MATCH 到，
    /// 而**子串复核必须对候选正文现折叠再比**，否则会把全角正文误杀。
    func testFTSChannelMatchesFullwidthBodyWithEitherWidth() throws {
        let f = try makeFixture("fts-fullwidth")
        let store = f.store!
        // OCR 真实会产出的写法：全角冒号 / 括号 / 字母（tools/bench/ocr_report_conclusions.md §2）
        let body = "第三季度评审：ＳＱＬＣｉｐｈｅｒ（加密存储）的对账口径。"
        let r = try store.record(observation(ts: Self.dayStart + 1000, texts: [body]))
        XCTAssertEqual(try store.evidenceText(observationID: r.observationID), body,
                       "正文原样入库，一个字节都没折")

        for q in ["SQLCipher", "ＳＱＬＣｉｐｈｅｒ"] {
            let result = try store.search(q: q)
            XCTAssertEqual(result.hits.count, 1, "「\(q)」应当命中这条全角正文")
            XCTAssertEqual(result.hits.first?.channel, .fts)
            XCTAssertGreaterThanOrEqual(result.ftsCandidates, 1)
            XCTAssertEqual(result.ftsVerified, 1, "子串复核不能把全角正文误杀")
        }
        // 反向对照：正文里真的没有的串，复核照旧滤掉
        XCTAssertTrue(try store.search(q: "SQLite").hits.isEmpty)
    }

    /// 扫描通道在**原文**上做 `LIKE`。正文不再折叠之后，「半角查询 → 全角原文」这一路
    /// 只把查询串折叠是命中不了的（折叠只会让查询串更半角），所以要把查询串展开成
    /// 兼容区的写法一起 LIKE（`Store.scanPatterns`）。
    func testScanChannelMatchesFullwidthBodyWithHalfwidthQuery() throws {
        let f = try makeFixture("scan-fullwidth")
        let store = f.store!
        let ts = Self.dayStart + 1000
        // 全角字母嵌在更长的标识符里：unicode61 只会切出 `abcd`，phrase「AB」命中不了，
        // 所以这条只能由扫描通道的子串 LIKE 召回。
        let body = "运行日志：错误码ＡＢＣＤ－７７。"
        let r = try store.record(observation(ts: ts, texts: [body]))
        XCTAssertEqual(try store.evidenceText(observationID: r.observationID), body)

        let half = try store.search(q: "AB", start: ts - 1000, end: ts + 1000)
        XCTAssertEqual(half.channels, [.scan], "FTS 通道对这条正文命中不了，只能靠扫描")
        XCTAssertEqual(half.hits.map(\.evidenceID), [r.observationID],
                       "半角查询必须命中全角原文")
        let full = try store.search(q: "ＡＢ", start: ts - 1000, end: ts + 1000)
        XCTAssertEqual(full.hits.map(\.evidenceID), [r.observationID], "全角查询同样")

        // 写进了全角正文，库上的标志必须置位——扫描通道靠它决定展不展开查询串。
        XCTAssertTrue(store.hasCompatibilityText)

        // 「折叠 / 不折叠各试一次」这两种写法都只会给出 `AB`，原文里不存在，一定落空；
        // 前像展开把 `ＡＢ`（以及全角小写 `ａｂ`）补进 LIKE 列表，这才是上面那条能过的原因。
        let patterns = Store.scanPatterns(term: "AB", rawTerm: "AB")
        XCTAssertEqual(patterns.first, "AB", "折叠后的写法排第一（绝大多数正文是半角）")
        XCTAssertTrue(patterns.contains("ＡＢ"))
        XCTAssertTrue(patterns.contains("ａｂ"),
                      "LIKE 只对 ASCII 大小写不敏感，全角两种大小写都要展开")
        XCTAssertEqual(Store.scanPatterns(term: "熵", rawTerm: "熵"), ["熵"],
                       "纯汉字查询展开后仍是一个 LIKE，最贵的那档扫描代价不变")

        // 展开是按模式条数线性变慢的，所以没有兼容区正文的库不展开。
        XCTAssertEqual(
            Store.scanPredicate(term: "AB", rawTerm: "AB", expandCompatibility: false).binds.count, 1)
        XCTAssertEqual(
            Store.scanPredicate(term: "AB", rawTerm: "AB", expandCompatibility: true).binds.count, 9)
    }

    // MARK: - 2. 1–2 字扫描通道（限时 / 限应用）

    func testShortQueryUsesTimeLimitedScan() throws {
        let f = try makeFixture("scan-short")
        let store = f.store!
        let now = Self.dayStart + 20 * Self.dayMS
        // 30 天前的一条 + 最近 1 天的一条，正文都含单字「会」
        try store.record(observation(ts: now - 30 * Self.dayMS, window: "旧窗口",
                                     texts: ["去年的会前准备材料。"]))
        try store.record(observation(ts: now - Self.dayMS, window: "新窗口",
                                     texts: ["今天的会前准备材料。"]))

        // 默认 7 天窗口：只召回最近那条
        let recent = try store.search(q: "会")
        XCTAssertTrue(recent.channels.contains(.scan))
        XCTAssertEqual(recent.hits.map(\.evidenceID), [2])
        // 锚点是「库里最新一条观察」，不是此刻——离线库上这才是唯一有意义的锚点。
        XCTAssertEqual(recent.scanToTS, now - Self.dayMS + 1)
        XCTAssertEqual(recent.scanFromTS,
                       (now - Self.dayMS) - Int64(store.retrieval.scanWindowDays) * Self.dayMS)

        // 显式给区间就按区间扫，旧的那条也回来了
        let ranged = try store.search(q: "会", start: now - 40 * Self.dayMS, end: now + 1)
        XCTAssertEqual(Set(ranged.hits.map(\.evidenceID)), [1, 2])

        // **纯汉字两字不开扫描通道**：`会前` 本身就是一个 bigram token，FTS 通道 MATCH 到它
        // 再用 LIKE 复核，语义已经是精确子串，扫描通道零召回增益却要扫窗口内全部正文。
        let two = try store.search(q: "会前", start: now - 40 * Self.dayMS, end: now + 1)
        XCTAssertFalse(two.channels.contains(.scan), "纯汉字两字不该再扫窗口内全部正文")
        XCTAssertTrue(two.channels.contains(.fts))
        XCTAssertNil(two.scanFromTS)
        XCTAssertEqual(Set(two.hits.map(\.evidenceID)), [1, 2], "召回不能因此变差")

        // 对照口径（`bench --scan-all-short` 用的就是它）：关掉这条策略又会走扫描通道，
        // **召回一模一样**——这正是「零召回增益」的单测证据。
        store.retrieval.scanSkipsPureCJKBigram = false
        let forced = try store.search(q: "会前", start: now - 40 * Self.dayMS, end: now + 1)
        XCTAssertTrue(forced.channels.contains(.scan))
        XCTAssertEqual(Set(forced.hits.map(\.evidenceID)), Set(two.hits.map(\.evidenceID)))
        store.retrieval.scanSkipsPureCJKBigram = true

        // 限应用：换一个 bundle 就一条都不该有
        let other = try store.search(q: "会", start: now - 40 * Self.dayMS, end: now + 1,
                                     app: "com.microsoft.VSCode")
        XCTAssertTrue(other.hits.isEmpty)
    }

    /// ≤2 字但**含非汉字**的查询仍然要扫：`unicode61` 按词切，
    /// `sq` 这个 token 在索引里根本不存在，FTS 命中不了 `SQLCipher` 里的子串。
    func testShortNonCJKQueryStillUsesScanChannel() throws {
        let f = try makeFixture("scan-ascii")
        let store = f.store!
        let now = Self.dayStart + 20 * Self.dayMS
        try store.record(observation(ts: now, texts: ["今天在读 SQLCipher 的文档。"]))
        let hit = try store.search(q: "sq")
        XCTAssertTrue(hit.channels.contains(.scan))
        XCTAssertFalse(hit.channels.contains(.fts), "整词 token 命中不了两字前缀")
        XCTAssertEqual(hit.hits.map(\.evidenceID), [1])
    }

    /// 显式给了 `end`，扫描窗口上界就是 `end`（半开区间），
    /// 与精确字段 / FTS 两条通道的 `ts < end` 一致。
    func testScanWindowUpperBoundIsExclusive() throws {
        let f = try makeFixture("scan-end")
        let store = f.store!
        let now = Self.dayStart + 20 * Self.dayMS
        try store.record(observation(ts: now, texts: ["边界上的会。"]))
        let excluded = try store.search(q: "会", end: now)
        XCTAssertEqual(excluded.scanToTS, now)
        XCTAssertTrue(excluded.hits.isEmpty, "ts == end 的那一毫秒不该被扫进来")
        let included = try store.search(q: "会", end: now + 1)
        XCTAssertEqual(included.scanToTS, now + 1)
        XCTAssertEqual(included.hits.map(\.evidenceID), [1])
    }

    func testScanWindowIsConfigurable() throws {
        let f = try makeFixture("scan-window")
        let store = f.store!
        let now = Self.dayStart + 20 * Self.dayMS
        try store.record(observation(ts: now - 10 * Self.dayMS, texts: ["十天前的会。"]))
        try store.record(observation(ts: now, window: "窗口乙", texts: ["今天的会。"]))
        XCTAssertEqual(try store.search(q: "会").hits.count, 1)
        store.retrieval.scanWindowDays = 14
        XCTAssertEqual(try store.search(q: "会").hits.count, 2)
    }

    // MARK: - 3. 精确字段两步式

    func testExactFieldChannelsAreTwoStep() throws {
        let f = try makeFixture("exact-two-step")
        let store = f.store!
        try store.record(observation(ts: Self.dayStart + 1000, window: "季度复盘 — 文档",
                                     host: "docs.internal",
                                     locator: "https://docs.internal/report/7?tab=1",
                                     file: "/tmp/brosis/report-7.md",
                                     texts: ["正文与查询串完全无关的一段话。"]))
        try store.record(observation(ts: Self.dayStart + 2000, bundle: "com.microsoft.VSCode",
                                     appName: "Code", window: "别的窗口",
                                     host: "example.com", texts: ["另一段话。"]))

        let host = try store.search(q: "host:docs.internal")
        XCTAssertEqual(host.channels, [.exactURL])
        XCTAssertEqual(host.hits.map(\.evidenceID), [1])
        let urlPrefix = try store.search(q: "url:https://docs.internal/report")
        XCTAssertEqual(urlPrefix.hits.map(\.evidenceID), [1])
        let path = try store.search(q: "path:report-7.md")
        XCTAssertEqual(path.channels, [.exactPath])
        XCTAssertEqual(path.hits.map(\.evidenceID), [1])
        let title = try store.search(q: "title:季度复盘")
        XCTAssertEqual(title.channels, [.exactTitle])
        XCTAssertEqual(title.hits.map(\.evidenceID), [1])
        let app = try store.search(q: "app:com.microsoft.VSCode")
        XCTAssertEqual(app.channels, [.exactApp])
        XCTAssertEqual(app.hits.map(\.evidenceID), [2])

        // 带字段前缀时不经 FTS（3.4 第一条）
        XCTAssertFalse(host.channels.contains(.fts))

        // ★ 两步式的关键：谓词命中 0 行时第一步就返回空集，第二步根本不跑。
        try store.withLock { conn in
            let miss = try store.exactChannel(field: "path", term: "tools/bench/does-not-exist.py",
                                              request: SearchRequest(q: "x"), appID: nil,
                                              limit: 20, conn: conn)
            XCTAssertEqual(miss.objectCount, 0)
            XCTAssertTrue(miss.ids.isEmpty)
        }
        XCTAssertTrue(try store.search(q: "path:tools/bench/does-not-exist.py").hits.isEmpty)
    }

    /// 带路径的 URL **不能**退回 host 等值：那会把同域名下别的页面全带进来，
    /// 前 10 条被同域名的噪声挤满。本轮评估里 `url-03` 就是这么掉到 Recall@10 0.4 的。
    func testURLChannelDistinguishesBareHostFromPathURL() throws {
        let f = try makeFixture("url-shape")
        let store = f.store!
        for i in 0..<12 {   // 同域名下的其他页面，时间更靠后，会抢占前 10 条
            try store.record(observation(ts: Self.dayStart + 10_000 + Int64(i) * 1000,
                                         window: "别的页面 \(i)", host: "docs.internal",
                                         locator: "https://docs.internal/page/\(i)",
                                         texts: ["与查询无关的一段。"]))
        }
        for i in 0..<3 {
            try store.record(observation(ts: Self.dayStart + Int64(i) * 1000,
                                         window: "规格 \(i)", host: "docs.internal",
                                         locator: "https://docs.internal/spec/\(i)",
                                         texts: ["规格页 \(i)。"]))
        }
        let byPath = try store.search(q: "url:https://docs.internal/spec/", limit: 10)
        XCTAssertEqual(Set(byPath.hits.map(\.evidenceID)), [13, 14, 15],
                       "带路径的 URL 只应命中 /spec/ 那三条")
        let byHost = try store.search(q: "host:docs.internal", limit: 20)
        XCTAssertEqual(byHost.hits.count, 15, "裸域名应当命中该域名下全部 15 条")
        XCTAssertTrue(Store.hasPath("https://docs.internal/spec/"))
        XCTAssertFalse(Store.hasPath("docs.internal"))
        XCTAssertEqual(Store.bareHost("https://docs.internal/spec/1"), "docs.internal")
    }

    /// E7 §10.1 的查询形状对照：一条 JOIN + `ORDER BY ts DESC LIMIT` 会被规划成
    /// **倒序扫 observations**（命中 0 行时要扫完整张表）；两步式则是按主键 / 索引取行。
    /// 这里用 `EXPLAIN QUERY PLAN` 把两种形状的差别钉死，不依赖计时。
    func testTwoStepQueryPlanAvoidsObservationScan() throws {
        let f = try makeFixture("exact-plan")
        let store = f.store!
        for i in 0..<50 {
            try store.record(observation(ts: Self.dayStart + Int64(i) * 1000,
                                         file: "/tmp/brosis/doc-\(i).md", texts: ["第 \(i) 段。"]))
        }
        try store.withLock { conn in
            try conn.exec("ANALYZE;")
            let naive = try Self.queryPlan(conn, """
                SELECT o.id, o.ts FROM files f JOIN observations o ON o.file_id = f.id
                 WHERE f.path LIKE ? ESCAPE '\\' AND o.deleted_at IS NULL
                 ORDER BY o.ts DESC LIMIT 20;
                """, [.text("%nope%")])
            let twoStep = try Self.queryPlan(conn, """
                SELECT id, ts FROM observations
                 WHERE device_id = ? AND file_id IN (?,?) AND deleted_at IS NULL
                 ORDER BY ts DESC LIMIT 20;
                """, [.text(store.deviceID), .int(1), .int(2)])
            XCTAssertTrue(naive.contains { $0.contains("SCAN o") },
                          "一条 JOIN 的写法应当退化成扫 observations，实际计划：\(naive)")
            XCTAssertFalse(twoStep.contains { $0.contains("SCAN observations") },
                           "两步式不应扫 observations，实际计划：\(twoStep)")
        }
    }

    static func queryPlan(_ conn: SQLiteConnection, _ sql: String,
                          _ binds: [SQLValue]) throws -> [String] {
        let st = try conn.prepare("EXPLAIN QUERY PLAN " + sql)
        defer { st.finalize() }
        try st.bind(binds)
        var out: [String] = []
        while try st.step() { out.append(st.text(3) ?? "") }
        return out
    }

    // MARK: - 4. 摘要 token 预算（3.6：每条 ≤ 100 token）

    func testHitSummaryFitsTokenBudget() throws {
        let f = try makeFixture("summary-budget")
        let store = f.store!
        let long = String(repeating: "这是一段很长的正文，用来把摘要撑爆。", count: 60)
        for i in 0..<5 {
            try store.record(observation(ts: Self.dayStart + Int64(i) * 1000,
                                         window: "窗口\(i)" + String(repeating: "标题很长", count: 30),
                                         texts: [long + "知识图谱\(i)"]))
        }
        let result = try store.search(q: "知识图谱")
        XCTAssertEqual(result.hits.count, 5)
        for hit in result.hits {
            XCTAssertLessThanOrEqual(hit.summaryTokens, 100, "摘要超过 100 token")
            XCTAssertLessThanOrEqual(hit.summary.count, 200, "100 token = 200 字符（口径见 TokenBudget）")
        }
        XCTAssertEqual(TokenBudget.tokens(of: "1234"), 2)
        XCTAssertEqual(TokenBudget.tokens(of: "12345"), 3)
        XCTAssertEqual(TokenBudget.truncate("123456", toTokens: 2).count, 4)
    }

    // MARK: - 5. 时间与应用过滤

    func testSearchFiltersByTimeAndApp() throws {
        let f = try makeFixture("filters")
        let store = f.store!
        try store.record(observation(ts: Self.dayStart + 1000, texts: ["会议纪要第一版。"]))
        try store.record(observation(ts: Self.dayStart + 2000, bundle: "com.electron.lark",
                                     appName: "飞书", window: "窗口乙", texts: ["会议纪要第二版。"]))
        XCTAssertEqual(try store.search(q: "会议纪要").hits.count, 2)
        XCTAssertEqual(try store.search(q: "会议纪要", app: "com.electron.lark").hits.map(\.evidenceID), [2])
        XCTAssertEqual(try store.search(q: "会议纪要",
                                        start: Self.dayStart, end: Self.dayStart + 2000)
                        .hits.map(\.evidenceID), [1], "区间是半开的 [start, end)")
        XCTAssertTrue(try store.search(q: "会议纪要", app: "com.nonexistent").hits.isEmpty)
    }

    /// **FTS 候选截断 + 早期时间窗**：候选是 `ORDER BY rowid DESC LIMIT candidateLimit` 取的
    /// （≈ 时间倒序），时间过滤在候选**之后**做。所以当一个词的文本版本数超过候选上限、
    /// 而查询窗口又落在更早的时间时，早期的命中根本进不了复核——会漏召回。
    ///
    /// 这一条量的就是那个悬崖在哪儿：把候选上限调到 3（默认带过滤是 2000），
    /// 20 个版本里只有最新的 3 个进候选，查最早那段窗口就一条都召回不到，
    /// 且 `ftsCandidatesTruncated` **必须报 true**（调用方能看出结果不完整）；
    /// 用默认上限同一条查询召回完整。本轮 54 → 55 题的查询集里最多的一题 120 个版本，
    /// 离 2000 还很远，`eval.json` 的 `fts_candidates_truncated_queries` 是空的。
    func testFTSCandidateTruncationOnEarlyWindowIsReported() throws {
        let f = try makeFixture("fts-truncation")
        let store = f.store!
        for i in 0..<20 {
            try store.record(observation(ts: Self.dayStart + Int64(i) * 60_000,
                                         window: "窗口\(i)",
                                         texts: ["第 \(i) 段里写了跨周高频标记这个词。"]))
        }
        let early = (start: Self.dayStart, end: Self.dayStart + 5 * 60_000)   // 前 5 条

        // 默认候选上限：全部 20 个版本都进候选，早期窗口召回完整。
        let full = try store.search(q: "跨周高频标记", start: early.start, end: early.end)
        XCTAssertEqual(full.hits.map(\.evidenceID), [5, 4, 3, 2, 1])
        XCTAssertFalse(full.ftsCandidatesTruncated)

        // 候选上限调到 3：只有最新的 3 个版本进候选，它们都不在早期窗口里 → 漏召回，
        // 但结果里 truncated = true，调用方知道这不是「确实没有」。
        store.retrieval.filteredFTSCandidateLimit = 3
        let truncated = try store.search(q: "跨周高频标记", start: early.start, end: early.end)
        XCTAssertTrue(truncated.ftsCandidatesTruncated, "候选被截断必须报出来")
        XCTAssertEqual(truncated.ftsCandidates, 3)
        XCTAssertTrue(truncated.hits.isEmpty, "被截断掉的早期命中确实漏了——这是已知限制")

        // 同一个上限，窗口挪到最新那段就不受影响（截断丢的永远是更老的那头）。
        let late = try store.search(q: "跨周高频标记",
                                    start: Self.dayStart + 17 * 60_000,
                                    end: Self.dayStart + 20 * 60_000)
        XCTAssertEqual(late.hits.map(\.evidenceID), [20, 19, 18])
    }

    // MARK: - 6. 删除后各入口都不再返回内容（3.8 验收）

    func testDeletedObservationDisappearsFromEveryEntry() throws {
        let f = try makeFixture("delete-entries")
        let store = f.store!
        try store.record(observation(ts: Self.dayStart + 1000, texts: ["需要被删掉的知识图谱一段。"]))
        try store.record(observation(ts: Self.dayStart + 2000, window: "窗口乙",
                                     texts: ["留下来的知识图谱另一段。"]))
        try store.buildSessions(force: true)
        _ = try store.getDayLedger(date: "2025-09-04", recompute: true)

        XCTAssertEqual(try store.search(q: "知识图谱").hits.count, 2)
        XCTAssertEqual(try store.getEvidence(ids: [1, 2]).items.count, 2)

        _ = try store.deleteObservations([1])

        let after = try store.search(q: "知识图谱")
        XCTAssertEqual(after.hits.map(\.evidenceID), [2])
        let evidence = try store.getEvidence(ids: [1, 2])
        XCTAssertEqual(evidence.items.map(\.evidenceID), [2])
        XCTAssertEqual(evidence.missing, [1])
        let context = try store.getContext(hours: 24, maxTokens: 4000,
                                           endingAt: Self.dayStart + 3000)
        XCTAssertFalse(context.text.contains("需要被删掉"))
        XCTAssertEqual(context.snippets.map(\.evidenceID), [2])
        // 台账被标 stale：重算之后不再包含被删的观察
        XCTAssertEqual(try store.staleFlags(table: "ledgers").filter(\.stale).count, 1)
        let ledger = try store.getDayLedger(date: "2025-09-04", recompute: true)
        XCTAssertEqual(ledger.observations, 1)
        XCTAssertEqual(ledger.evidence, [[2, 2]])
    }

    // MARK: - 7. grant 字段级限制（3.6 的钩子）

    func testGrantLimitsFieldsAppsAndWindow() throws {
        let f = try makeFixture("grant")
        let store = f.store!
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try store.record(observation(ts: now - 3600_000, texts: ["Safari 上的一段正文。"]))
        try store.record(observation(ts: now - 3600_000 + 1, bundle: "com.electron.lark",
                                     appName: "飞书", window: "窗口乙", texts: ["飞书上的一段正文。"]))
        try store.record(observation(ts: now - 90 * Self.dayMS, window: "很旧的窗口",
                                     texts: ["90 天前的一段正文。"]))

        // 没有 grant：原文照给
        XCTAssertNotNil(try store.getEvidence(ids: [1]).items.first?.text)

        // fields = summary：不给原文
        try store.setGrant(Grant(clientID: "claude-code", apps: ["*"], timeWindowDays: 30,
                                 fields: .summary))
        let summaryGrant = try XCTUnwrap(try store.grant(clientID: "claude-code"))
        let redacted = try store.getEvidence(ids: [1], grant: summaryGrant)
        XCTAssertNil(redacted.items.first?.text)
        XCTAssertTrue(redacted.items.first?.redactedByGrant == true)
        XCTAssertNil(redacted.items.first?.occurrences.first?.text)
        XCTAssertFalse(redacted.items.first?.summary.isEmpty == true)

        // 应用白名单
        try store.setGrant(Grant(clientID: "narrow", apps: ["com.apple.Safari"],
                                 timeWindowDays: 30, fields: .evidence))
        let narrow = try XCTUnwrap(try store.grant(clientID: "narrow"))
        let filtered = try store.getEvidence(ids: [1, 2], grant: narrow)
        XCTAssertEqual(filtered.items.map(\.evidenceID), [1])
        XCTAssertEqual(filtered.deniedByGrant, [2])
        XCTAssertNotNil(filtered.items.first?.text)

        // 时间窗
        let old = try store.getEvidence(ids: [3], grant: narrow)
        XCTAssertTrue(old.items.isEmpty)
        XCTAssertEqual(old.deniedByGrant, [3])
    }

    // MARK: - 8. get_item / get_context / get_timeline

    func testGetItemAggregates() throws {
        let f = try makeFixture("item")
        let store = f.store!
        for i in 0..<6 {
            try store.record(observation(ts: Self.dayStart + Int64(i) * 20_000,
                                         host: "docs.internal",
                                         locator: "https://docs.internal/report/\(i)",
                                         file: "/tmp/brosis/doc.md", texts: ["第 \(i) 段。"]))
        }
        try store.buildSessions(force: true)
        let host = try store.getItem(.url("docs.internal"))
        XCTAssertEqual(host.kind, "url")
        XCTAssertEqual(host.observations, 6)
        XCTAssertEqual(host.days["2025-09-04"], 6)
        XCTAssertEqual(host.firstSeen, Self.dayStart)
        XCTAssertEqual(host.recentEvidenceIDs.first, 6)
        let path = try store.getItem(.path("doc.md"))
        XCTAssertEqual(path.observations, 6)
        let app = try store.getItem(.app("com.apple.Safari"))
        XCTAssertEqual(app.observations, 6)
        XCTAssertEqual(app.dwellS, 100, accuracy: 0.001)   // 5 段 × 20 s，最后一条不记
        XCTAssertEqual(try store.getItem(.url("nowhere.example")).observations, 0)
    }

    func testGetContextRespectsTokenBudget() throws {
        let f = try makeFixture("context")
        let store = f.store!
        let body = String(repeating: "这是一段用来撑爆预算的正文。", count: 40)
        for i in 0..<40 {
            try store.record(observation(ts: Self.dayStart + Int64(i) * 60_000,
                                         window: "窗口\(i)", texts: [body + "\(i)"]))
        }
        try store.buildSessions(force: true)
        for budget in [200, 800, 3000] {
            let bundle = try store.getContext(hours: 24, maxTokens: budget,
                                              endingAt: Self.dayStart + 40 * 60_000)
            XCTAssertLessThanOrEqual(bundle.usedTokens, budget, "预算 \(budget) 被突破")
            XCTAssertEqual(bundle.usedTokens, TokenBudget.tokens(of: bundle.text))
            XCTAssertTrue(bundle.truncated, "40 段长正文不可能塞进 \(budget) token")
        }

        // 片段一多，**每条片段前的换行**就会累计成好几个 token。逐条计费时漏掉分隔符的话，
        // `usedTokens`（按拼好的全文重算）会越过预算——这是 R1 验收指出的边界。
        let g = try makeFixture("context-many-short")
        for i in 0..<120 {
            try g.store.record(observation(ts: Self.dayStart + Int64(i) * 60_000,
                                           window: "窗口\(i)", texts: ["短正文\(i)"]))
        }
        try g.store.buildSessions(force: true)
        for budget in [120, 199, 240, 501, 777] {
            let bundle = try g.store.getContext(hours: 24, maxTokens: budget,
                                                endingAt: Self.dayStart + 120 * 60_000)
            XCTAssertLessThanOrEqual(bundle.usedTokens, budget, "预算 \(budget) 被突破")
            XCTAssertEqual(bundle.usedTokens, TokenBudget.tokens(of: bundle.text))
        }
    }

    func testTimelineBuckets() throws {
        let f = try makeFixture("timeline")
        let store = f.store!
        // 第 0 小时 3 条 Safari，第 2 小时 2 条飞书
        for i in 0..<3 {
            try store.record(observation(ts: Self.dayStart + Int64(i) * 60_000, texts: ["A\(i)"]))
        }
        for i in 0..<2 {
            try store.record(observation(ts: Self.dayStart + 2 * 3_600_000 + Int64(i) * 60_000,
                                         bundle: "com.electron.lark", appName: "飞书",
                                         window: "窗口乙", texts: ["B\(i)"]))
        }
        let timeline = try store.getTimeline(start: Self.dayStart,
                                             end: Self.dayStart + 4 * 3_600_000,
                                             granularity: .hour)
        XCTAssertEqual(timeline.buckets.count, 4)
        XCTAssertEqual(timeline.buckets.map(\.observations), [3, 0, 2, 0])
        XCTAssertEqual(timeline.buckets[0].topApp, "com.apple.Safari")
        XCTAssertEqual(timeline.buckets[2].topApp, "com.electron.lark")
        XCTAssertEqual(timeline.buckets[0].label, "2025-09-04 00")
        // 第 0 小时 3 条：0→60 记 60 s、60→120 记 60 s、第三条到下一条隔 1 h 46 min，
        // 被「停留上限 90 s」封顶记 90 s，合计 210 s。
        XCTAssertEqual(timeline.buckets[0].dwellS, 210, accuracy: 0.001)
        let byDay = try store.getTimeline(start: Self.dayStart, end: Self.dayStart + Self.dayMS,
                                          granularity: .day)
        XCTAssertEqual(byDay.buckets.count, 1)
        XCTAssertEqual(byDay.buckets[0].observations, 5)
    }

    // MARK: - 9. 查询路由

    func testQueryRouting() throws {
        XCTAssertEqual(QueryRouter.route("https://sqlite.org/fts5.html"), .url)
        XCTAssertEqual(QueryRouter.route("sqlite.org"), .url)
        XCTAssertEqual(QueryRouter.route("docs.internal/report/7"), .url)
        XCTAssertEqual(QueryRouter.route("/tmp/brosis/doc.md"), .path)
        XCTAssertEqual(QueryRouter.route("~/Library/Caches"), .path)
        XCTAssertEqual(QueryRouter.route("tools/bench/fts_compare.py"), .path)
        XCTAssertEqual(QueryRouter.route("知识图谱"), .text)
        XCTAssertEqual(QueryRouter.route("fts_compare.py"), .text)   // 下划线不是域名字符
        XCTAssertEqual(QueryRouter.route("WAL checkpoint"), .text)   // 带空格一律当正文
        XCTAssertEqual(QueryRouter.parseField("host:example.com").field, "host")
        XCTAssertEqual(QueryRouter.parseField("host:example.com").term, "example.com")
        XCTAssertNil(QueryRouter.parseField("https://example.com").field)
        XCTAssertNil(QueryRouter.parseField("会议:纪要").field)
    }
}
