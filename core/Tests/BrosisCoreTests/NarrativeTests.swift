import XCTest
@testable import BrosisCore

/// M2 c / T12：可选叙述（计划 4.3、3.7、3.10、D19、schema v6）。
///
/// 这一组**不加载任何模型**：生成侧用 `ScriptedGenerationProvider`，
/// 所以整条路（构造 → 裁剪 → 生成 → 忠实度核对 → 入库 / 丢弃）能在几毫秒里跑完，
/// 而且在没装 2.85 GiB 权重的机器上照样全过。
/// 真实模型那一次跑在 app 的 `--narrative-smoke` 里（30 s 级，不进默认自检）。
final class NarrativeTests: XCTestCase {

    static let dayStart: Int64 = 1_756_944_000_000        // 2025-09-04T00:00:00Z（周四）
    static let day = "2025-09-04"

    private func makeFixture(_ name: String) throws -> Fixture {
        let f = try Fixture(name)
        f.store.retrieval.timeZone = TimeZone(identifier: "UTC")!
        return f
    }

    /// 一条观察。`app` 用真实应用名，好让别名词表那条规则有东西可判。
    private func observation(_ offsetS: Int64, bundle: String, app: String,
                             window: String, text: String) -> ObservationInput {
        ObservationInput(
            ts: Self.dayStart + offsetS * 1000, displayID: 1,
            app: AppRef(bundleID: bundle, name: app),
            windowTitle: window, url: nil, filePath: nil,
            trigger: .timer, captureMethod: .ax, completeness: .complete, sourceState: .ok,
            texts: [TextFragment(text: text, region: nil)])
    }

    /// 一天：上午飞书 + 上午 Xcode（含 TODO）+ 下午 Safari。与 D19 那份合成台账同构。
    private func seedDay(_ store: Store) throws {
        var batch: [ObservationInput] = []
        // 09:00–09:20 飞书
        for i in 0..<5 {
            batch.append(observation(9 * 3600 + Int64(i) * 300, bundle: "com.electron.lark",
                                     app: "飞书", window: "群聊 · 采集器",
                                     text: "采集器在 Air 上跑了 6 小时没崩，内存峰值 1.6 GiB。"))
        }
        // 10:00–10:20 Xcode，正文里带 TODO
        for i in 0..<5 {
            batch.append(observation(10 * 3600 + Int64(i) * 300, bundle: "com.apple.dt.Xcode",
                                     app: "Xcode", window: "FrontmostObserver.swift",
                                     text: "// TODO: 切换事件在锁屏之后会漏一条，需要补一个监听。"))
        }
        // 14:00–14:20 Safari
        for i in 0..<5 {
            batch.append(observation(14 * 3600 + Int64(i) * 300, bundle: "com.apple.Safari",
                                     app: "Safari", window: "Metal 缓冲池讨论",
                                     text: "论坛里在讨论 Metal 缓冲池的上限设置与内存占用。"))
        }
        try store.record(batch: batch)
        try store.buildSessions(force: true)
    }

    // MARK: - 1. token 估算与提示构造

    func testTokenEstimatorIsDeterministicAndConservative() {
        let text = "上午在飞书确认采集器 Air 端运行稳定，内存峰值 1.6 GiB。"
        XCTAssertEqual(NarrativeTokens.estimate(text), NarrativeTokens.estimate(text))
        XCTAssertGreaterThan(NarrativeTokens.estimate(text), 0)
        XCTAssertEqual(NarrativeTokens.estimate(""), 0)
        // 汉字 1 token、ASCII 字母数字半个、空白三分之一
        XCTAssertEqual(NarrativeTokens.estimate("汉字"), 2)
        XCTAssertEqual(NarrativeTokens.estimate("abcd"), 2)
        // 单调：文本变长，估算不减
        XCTAssertGreaterThanOrEqual(NarrativeTokens.estimate(text + text),
                                    NarrativeTokens.estimate(text))
        // D19 的三份真实提示上估算器必须**高估**（校准点见 NarrativeTokens 的注释）。
        // 这里只钉住方向：同样字符构成下，估算 ≥ 真值 837 / 3,664 / 5,354 的比例关系。
        let sample = String(repeating: "台账 ledger 2026-09-05 ", count: 100)
        XCTAssertGreaterThan(NarrativeTokens.estimate(sample), sample.count / 3)
    }

    func testPromptIsDeterministicAndCarriesTheThreeProhibitions() throws {
        let f = try makeFixture("narrative-prompt")
        try seedDay(f.store)
        let input = try f.store.narrativeDayInput(date: Self.day)
        let a = NarrativePromptBuilder.build(input)
        let b = NarrativePromptBuilder.build(input)
        XCTAssertEqual(a.user, b.user, "同一份输入两次构造必须逐字相同（没有随机数）")
        XCTAssertEqual(a.compression, .full, "三段会话的一天不需要压缩")
        XCTAssertLessThanOrEqual(a.estimatedTokens, NarrativeConfig().maxInputTokens)
        XCTAssertFalse(a.hardTruncated)

        // 系统指令里三条禁令都在（D19 的两处偏差 + 禁止编造）
        XCTAssertTrue(a.system.contains("禁止"))
        XCTAssertTrue(a.system.contains("待办（未完成）"))
        XCTAssertTrue(a.system.contains("上午"))
        // 正文里有台账的关键事实
        XCTAssertTrue(a.user.contains("飞书"))
        XCTAssertTrue(a.user.contains("Xcode"))
        XCTAssertTrue(a.user.contains("待办（未完成）"), "带 TODO 的会话要在提示里显式标出来")
    }

    /// 大台账逐级压缩：最终一定落在 8,000 token 闸门内，且等级比 `full` 低。
    func testCompressionKeepsPromptUnderEightThousandTokens() {
        var apps: [NarrativeAppLine] = []
        var sessions: [NarrativeSessionLine] = []
        for i in 0..<120 {
            apps.append(NarrativeAppLine(
                bundleID: "com.example.app\(i)", name: "示例应用编号\(i)",
                dwellS: Double(3600 - i * 10), activeS: Double(1800 - i * 5), switches: i + 1,
                firstTS: Self.dayStart + Int64(i) * 60_000,
                lastTS: Self.dayStart + Int64(i) * 60_000 + 600_000))
            sessions.append(NarrativeSessionLine(
                start: Self.dayStart + Int64(i) * 300_000,
                end: Self.dayStart + Int64(i) * 300_000 + 240_000,
                bundleID: "com.example.app\(i)", appName: "示例应用编号\(i)",
                dwellS: Double(240 - i), interruptions: i % 3,
                windowTitles: ["很长的窗口标题用来把提示撑大一点点编号\(i)"],
                excerpt: String(repeating: "这是一段用来把提示撑得很长的合成屏幕正文。", count: 6),
                hasTODO: i % 17 == 0))
        }
        let input = NarrativeInput(
            level: "day", period: Self.day, timeZone: "UTC",
            start: Self.dayStart, end: Self.dayStart + 86_400_000,
            totalDwellS: 40_000, totalActiveS: 20_000, totalUnknownS: 100, onlineUnionS: 39_000,
            switches: 900, interruptions: 40, sessionCount: 120, observations: 8_000,
            apps: apps, sites: [], files: [], sessions: sessions, days: [],
            ledgerComputedAt: 1, stale: false)

        let config = NarrativeConfig()
        let prompt = NarrativePromptBuilder.build(input, config: config)
        XCTAssertLessThanOrEqual(prompt.estimatedTokens, config.maxInputTokens,
                                 "裁剪之后必须落在 8,000 token 闸门内（D19）")
        XCTAssertGreaterThan(prompt.compression, .full, "这么大的台账必须被压过")

        // 逐级压缩确实是单调变短的
        var previous = Int.max
        for level in NarrativeCompression.allCases {
            let rendered = NarrativePromptBuilder.render(input, level: level, config: config)
            XCTAssertLessThan(rendered.count, previous, "\(level.label) 必须比上一级短")
            previous = rendered.count
        }
    }

    /// 闸门收到极小值时也不能突破：兜底等级之后还超就硬截断。
    func testHardTruncationWhenEvenMinimalOverflows() {
        var config = NarrativeConfig()
        config.maxInputTokens = 200
        let input = NarrativeInput(
            level: "day", period: Self.day, timeZone: "UTC",
            start: Self.dayStart, end: Self.dayStart + 86_400_000,
            totalDwellS: 100, totalActiveS: 50, totalUnknownS: 0, onlineUnionS: 100,
            switches: 5, interruptions: 0, sessionCount: 1, observations: 10,
            apps: (0..<5).map {
                NarrativeAppLine(bundleID: "com.example.\($0)",
                                 name: String(repeating: "长应用名", count: 20),
                                 dwellS: 100, activeS: 50, switches: 1)
            },
            sites: [], files: [], sessions: [], days: [], ledgerComputedAt: 1, stale: false)
        let prompt = NarrativePromptBuilder.build(input, config: config)
        XCTAssertTrue(prompt.hardTruncated)
        XCTAssertEqual(prompt.compression, .minimal)
    }

    // MARK: - 2. 忠实度自检：正例

    func testFaithfulNarrativePasses() throws {
        let f = try makeFixture("narrative-ok")
        try seedDay(f.store)
        let input = try f.store.narrativeDayInput(date: Self.day)
        let prompt = NarrativePromptBuilder.build(input)
        // 只用台账里有的应用与数字，待办说成"待补"，时段说对。
        let text = "上午先在飞书跟进采集器在 Air 上的运行情况，随后在 Xcode 里看 FrontmostObserver，"
                 + "锁屏后漏事件的问题仍待处理。下午在 Safari 上查了 Metal 缓冲池的资料。"
        let report = NarrativeFaithfulness.check(text, facts: prompt.facts)
        XCTAssertTrue(report.passed, "违规：\(report.violations)")
        XCTAssertFalse(report.truncated)
        XCTAssertGreaterThan(report.checkedApps, 0)
    }

    // MARK: - 3. 忠实度自检：反例（每条规则一个）

    func testFabricatedNumberIsRejected() throws {
        let f = try makeFixture("narrative-number")
        try seedDay(f.store)
        let prompt = NarrativePromptBuilder.build(try f.store.narrativeDayInput(date: Self.day))
        let report = NarrativeFaithfulness.check("上午在飞书处理了 987654 条消息。", facts: prompt.facts)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.violations.map(\.rule), ["fabricated_number"])
        XCTAssertTrue(report.violations[0].detail.contains("987654"))
    }

    func testFabricatedAppIsRejected() throws {
        let f = try makeFixture("narrative-app")
        try seedDay(f.store)
        let prompt = NarrativePromptBuilder.build(try f.store.narrativeDayInput(date: Self.day))
        let report = NarrativeFaithfulness.check("上午在飞书沟通，随后切到 Slack 继续讨论。",
                                                 facts: prompt.facts)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.violations.contains { $0.rule == "fabricated_app" })
    }

    /// D19 的偏差 1：把 `// TODO: 切换事件在锁屏之后会漏一条` 写成"解决了锁屏切换漏事件"。
    func testTODOClaimedDoneIsRejected() throws {
        let f = try makeFixture("narrative-todo")
        try seedDay(f.store)
        let prompt = NarrativePromptBuilder.build(try f.store.narrativeDayInput(date: Self.day))
        let report = NarrativeFaithfulness.check(
            "上午在 Xcode 里完善 FrontmostObserver，解决了锁屏切换漏事件的问题。",
            facts: prompt.facts)
        XCTAssertFalse(report.passed, "D19 实测到的那处偏差必须被抓住")
        XCTAssertTrue(report.violations.contains { $0.rule == "todo_claimed_done" },
                      "\(report.violations)")
    }

    /// 单个 2 字词的重合**不算**违规——不然正确的叙述会被大面积误杀。
    func testSingleShortTermOverlapIsNotAViolation() throws {
        let f = try makeFixture("narrative-todo-fp")
        try seedDay(f.store)
        let prompt = NarrativePromptBuilder.build(try f.store.narrativeDayInput(date: Self.day))
        let report = NarrativeFaithfulness.check("下午在 Safari 上完成了资料查阅。", facts: prompt.facts)
        XCTAssertTrue(report.passed, "违规：\(report.violations)")
    }

    /// D19 的偏差 2：把上午的会话说成下午。
    func testWrongTimeBandIsRejected() throws {
        let f = try makeFixture("narrative-band")
        try seedDay(f.store)
        let prompt = NarrativePromptBuilder.build(try f.store.narrativeDayInput(date: Self.day))
        let report = NarrativeFaithfulness.check("下午在飞书跟进采集器的运行情况。", facts: prompt.facts)
        XCTAssertFalse(report.passed, "飞书只在上午出现过")
        XCTAssertTrue(report.violations.contains { $0.rule == "wrong_time_band" },
                      "\(report.violations)")

        // 说对了就不该报
        let ok = NarrativeFaithfulness.check("上午在飞书跟进采集器的运行情况。", facts: prompt.facts)
        XCTAssertTrue(ok.passed, "违规：\(ok.violations)")
    }

    /// 时段核对要覆盖**词表外**的应用：台账里那个叫「Code」的应用（VS Code 的展示名）
    /// 别名词表认不出来，但它在台账里，所以时段照样要核。
    func testTimeBandCoversLedgerAppsOutsideTheLexicon() {
        let morning = Self.dayStart + 9 * 3_600_000
        let input = NarrativeInput(
            level: "day", period: Self.day, timeZone: "UTC",
            start: Self.dayStart, end: Self.dayStart + 86_400_000,
            totalDwellS: 3600, totalActiveS: 1800, totalUnknownS: 0, onlineUnionS: 3600,
            switches: 3, interruptions: 0, sessionCount: 1, observations: 12,
            apps: [NarrativeAppLine(bundleID: "com.microsoft.VSCode", name: "Code",
                                    dwellS: 3600, activeS: 1800, switches: 3,
                                    firstTS: morning, lastTS: morning + 3_600_000)],
            sites: [], files: [],
            sessions: [NarrativeSessionLine(start: morning, end: morning + 3_600_000,
                                            bundleID: "com.microsoft.VSCode", appName: "Code",
                                            dwellS: 3600, interruptions: 0, windowTitles: [],
                                            excerpt: "编辑器里在改一段解析代码。", hasTODO: false)],
            days: [], ledgerComputedAt: 1, stale: false)
        let facts = NarrativePromptBuilder.build(input).facts
        // 展示名「Code」词表认不出来，但 bundle id 认得出来 ⇒ 归到 VS Code 那一组；
        // 时段核对就是靠这条把「Code」和那一组的活动小时对上的。
        XCTAssertEqual(facts.appNameToGroup["Code"], "VS Code")
        let wrong = NarrativeFaithfulness.check("下午在 Code 里改代码。", facts: facts)
        XCTAssertFalse(wrong.passed, "Code 只在上午出现过")
        XCTAssertTrue(wrong.violations.contains { $0.rule == "wrong_time_band" })
        let right = NarrativeFaithfulness.check("上午在 Code 里改代码。", facts: facts)
        XCTAssertTrue(right.passed, "违规：\(right.violations)")
        // 台账里的名字只开启时段核对，不会被判成编造
        XCTAssertFalse(right.violations.contains { $0.rule == "fabricated_app" })
    }

    /// 跨午夜的会话不能把「这个应用今天在哪些小时活跃」撑成几乎全天，
    /// 否则时段那条规则形同虚设。
    func testCrossMidnightSessionIsClippedToTheLedgerWindow() {
        let dayEnd = Self.dayStart + 86_400_000
        // 一段 23:41（前一天）→ 00:01（今天）的会话，再加一段今天 09:00–10:00 的。
        let crossing = NarrativeSessionLine(
            start: Self.dayStart - 19 * 60_000, end: Self.dayStart + 60_000,
            bundleID: "com.electron.lark", appName: "飞书", dwellS: 1200, interruptions: 0,
            windowTitles: [], excerpt: "群里在对齐口径。", hasTODO: false)
        let morning = NarrativeSessionLine(
            start: Self.dayStart + 9 * 3_600_000, end: Self.dayStart + 10 * 3_600_000,
            bundleID: "com.electron.lark", appName: "飞书", dwellS: 3600, interruptions: 0,
            windowTitles: [], excerpt: "继续对齐口径。", hasTODO: false)
        let input = NarrativeInput(
            level: "day", period: Self.day, timeZone: "UTC", start: Self.dayStart, end: dayEnd,
            totalDwellS: 4800, totalActiveS: 4800, totalUnknownS: 0, onlineUnionS: 4800,
            switches: 2, interruptions: 0, sessionCount: 2, observations: 20,
            apps: [NarrativeAppLine(bundleID: "com.electron.lark", name: "飞书",
                                    dwellS: 4800, activeS: 4800, switches: 2,
                                    firstTS: Self.dayStart, lastTS: Self.dayStart + 10 * 3_600_000)],
            sites: [], files: [], sessions: [crossing, morning], days: [],
            ledgerComputedAt: 1, stale: false)
        let facts = NarrativePromptBuilder.build(input).facts
        let hours = try? XCTUnwrap(facts.appHours["飞书"])
        XCTAssertEqual(hours, [0, 9, 10], "只应覆盖窗口内的小时，23 点那一格要被裁掉")
        // 于是「下午在飞书…」仍然是违规
        let report = NarrativeFaithfulness.check("下午在飞书对齐口径。", facts: facts)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.violations.contains { $0.rule == "wrong_time_band" })
    }

    func testThinkingDetectedIsRejected() throws {
        let f = try makeFixture("narrative-think")
        try seedDay(f.store)
        let prompt = NarrativePromptBuilder.build(try f.store.narrativeDayInput(date: Self.day))
        let report = NarrativeFaithfulness.check("上午在飞书沟通。", facts: prompt.facts,
                                                 thinkingDetected: true)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.violations.contains { $0.rule == "thinking_detected" })
    }

    func testEmptyNarrativeIsRejected() throws {
        let f = try makeFixture("narrative-empty")
        try seedDay(f.store)
        let prompt = NarrativePromptBuilder.build(try f.store.narrativeDayInput(date: Self.day))
        let report = NarrativeFaithfulness.check("   \n ", facts: prompt.facts)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.violations.map(\.rule), ["empty"])
    }

    /// D19 结论 5：长度约束要在代码里截断，不能只写在提示词里。
    func testClampCutsAtSentenceBoundary() {
        var config = NarrativeConfig()
        config.maxHanCharacters = 10
        let text = "第一句写了十个汉字整。第二句还要再写很多很多字。第三句更长。"
        let clamped = NarrativeText.clampHan(text, limit: config.maxHanCharacters)
        XCTAssertTrue(clamped.truncated)
        XCTAssertTrue(clamped.text.hasSuffix("。"), "要切在句号上：\(clamped.text)")
        XCTAssertLessThanOrEqual(clamped.hanCharacters, config.maxHanCharacters)
        // 一个句号都没有时硬截并补省略号
        let noStop = NarrativeText.clampHan(String(repeating: "字", count: 40), limit: 10)
        XCTAssertTrue(noStop.text.hasSuffix("…"))
        XCTAssertEqual(noStop.hanCharacters, 10)
        // 没超限就原样返回
        let short = NarrativeText.clampHan("很短。", limit: 10)
        XCTAssertFalse(short.truncated)
        XCTAssertEqual(short.text, "很短。")
    }

    /// 别名词表的词边界：`search` 里不能找出 `Arc`、`keyword` 里不能找出 `Word`。
    func testLexiconRequiresWordBoundaryForASCIIAliases() {
        XCTAssertTrue(NarrativeLexicon.mentionedGroups(in: "在 Safari 上查资料").contains("Safari"))
        XCTAssertFalse(NarrativeLexicon.mentionedGroups(in: "用 search 查资料").contains("Arc"))
        XCTAssertFalse(NarrativeLexicon.mentionedGroups(in: "整理 keywords 列表").contains("Excel"))
        XCTAssertEqual(NarrativeLexicon.group(for: "com.apple.dt.Xcode"), "Xcode")
        XCTAssertEqual(NarrativeLexicon.group(for: "飞书"), "飞书")
        XCTAssertNil(NarrativeLexicon.group(for: "某个没进词表的自研工具"))
    }

    // MARK: - 4. 端到端（脚本化提供方）

    func testRunNarrativeSavesAndTagsTheLedger() throws {
        let f = try makeFixture("narrative-run")
        let store = f.store!
        try seedDay(store)
        let answer = "上午先在飞书跟进采集器的运行情况，随后在 Xcode 查看 FrontmostObserver，"
                   + "锁屏漏事件仍待处理。下午在 Safari 上查阅了 Metal 缓冲池资料。"
        let provider = ScriptedGenerationProvider(modelID: "Qwen3.5-4B-MLX-4bit", answers: [answer])
        let report = try store.runNarrative(.day(Self.day), provider: provider,
                                            thermalState: "nominal", peakFootprintMiB: 3_500)
        XCTAssertTrue(report.saved, "\(report.outcome) / \(report.check?.violations ?? [])")
        XCTAssertEqual(report.attempts, 1)
        XCTAssertEqual(report.compression, "full")
        XCTAssertGreaterThan(report.inputTokens, 0)

        // 台账读回来带叙述与标注（3.7：分开标注）
        let ledger = try store.getDayLedger(date: Self.day)
        XCTAssertEqual(ledger.narrative, answer)
        XCTAssertEqual(ledger.model, "Qwen3.5-4B-MLX-4bit")
        let meta = try XCTUnwrap(ledger.narrativeMeta)
        XCTAssertEqual(meta.generatedBy, "model")
        XCTAssertTrue(meta.faithfulnessChecked)
        XCTAssertEqual(meta.ledgerComputedAt, ledger.computedAt)
        XCTAssertEqual(meta.thermalState, "nominal")
        XCTAssertEqual(meta.peakFootprintMiB, 3_500)
        XCTAssertFalse(ledger.narrativeIsStale)

        // 记录里也读得到
        let record = try XCTUnwrap(store.narrativeRecord(level: "day", period: Self.day))
        XCTAssertFalse(record.stale)
        XCTAssertEqual(record.text, answer)

        // 事件写了一行（不含正文）
        let events = try store.runtimeEventDetails(kind: "narrative_run")
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].contains("\"model\":\"Qwen3.5-4B-MLX-4bit\""))
        XCTAssertFalse(events[0].contains("飞书"), "事件里不许出现正文")

        // 已经写过的日子不再进待办清单
        let backlog = try store.narrativeBacklog(now: Date(timeIntervalSince1970:
            Double(Self.dayStart) / 1000 + 86_400 * 2))
        XCTAssertFalse(backlog.contains(.day(Self.day)))
    }

    /// 台账一重算，叙述作废、重新进待办清单（4.3「台账变 stale 时叙述也标 stale 并重算」）。
    func testLedgerRecomputeInvalidatesNarrative() throws {
        let f = try makeFixture("narrative-stale")
        let store = f.store!
        try seedDay(store)
        let provider = ScriptedGenerationProvider(
            modelID: "m", answers: ["上午在飞书跟进采集器。下午在 Safari 查资料。"])
        XCTAssertTrue(try store.runNarrative(.day(Self.day), provider: provider).saved)
        XCTAssertNotNil(try store.narrativeRecord(level: "day", period: Self.day))

        // 强制重算台账
        _ = try store.getDayLedger(date: Self.day, recompute: true)
        XCTAssertNil(try store.narrativeRecord(level: "day", period: Self.day),
                     "台账重算之后 narrative / model / narrative_meta 必须一起置回 NULL")
        let ledger = try store.getDayLedger(date: Self.day)
        XCTAssertNil(ledger.narrative)
        XCTAssertNil(ledger.narrativeMeta)

        let backlog = try store.narrativeBacklog(now: Date(timeIntervalSince1970:
            Double(Self.dayStart) / 1000 + 86_400 * 2))
        XCTAssertTrue(backlog.contains(.day(Self.day)), "重算之后这一天要重新进待办清单")
    }

    /// `ledgerComputedAt` 对不上时 `narrativeIsStale` 要报 true（第二道保险）。
    func testNarrativeStaleWhenLedgerComputedAtMismatches() throws {
        let f = try makeFixture("narrative-mismatch")
        let store = f.store!
        try seedDay(store)
        let provider = ScriptedGenerationProvider(modelID: "m", answers: ["上午在飞书跟进采集器。"])
        XCTAssertTrue(try store.runNarrative(.day(Self.day), provider: provider).saved)
        // 绕过 upsertLedger 直接改 computed_at：模拟"有人动了台账但没清叙述"
        try store.rawExecForTests("UPDATE ledgers SET computed_at = computed_at + 1;")
        let record = try XCTUnwrap(store.narrativeRecord(level: "day", period: Self.day))
        XCTAssertTrue(record.stale)
        XCTAssertFalse(record.ledgerStale, "台账行本身没被标脏，脏的是叙述")
    }

    /// 没通过核对的叙述**一个字都不入库**，只留一行事件。
    func testRejectedNarrativeIsNotStored() throws {
        let f = try makeFixture("narrative-reject")
        let store = f.store!
        try seedDay(store)
        let provider = ScriptedGenerationProvider(
            modelID: "m", answers: ["上午在飞书沟通后切到 Slack 继续讨论了 987654 条消息。"])
        let report = try store.runNarrative(.day(Self.day), provider: provider)
        XCTAssertFalse(report.saved)
        XCTAssertEqual(report.outcome, "rejected")
        XCTAssertGreaterThanOrEqual(report.check?.violations.count ?? 0, 2)

        XCTAssertNil(try store.narrativeRecord(level: "day", period: Self.day))
        XCTAssertNil(try store.getDayLedger(date: Self.day).narrative)
        let events = try store.runtimeEventDetails(kind: "narrative_rejected")
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].contains("fabricated_app"))
        XCTAssertFalse(events[0].contains("Slack"), "事件里不许出现被丢弃的正文")
    }

    /// 3.10「失败重试一次」。
    func testProviderFailureIsRetriedOnce() throws {
        let f = try makeFixture("narrative-retry")
        let store = f.store!
        try seedDay(store)
        let provider = ScriptedGenerationProvider(
            modelID: "m", answers: ["上午在飞书跟进采集器。"], failFirst: true)
        let report = try store.runNarrative(.day(Self.day), provider: provider)
        XCTAssertTrue(report.saved, "\(report.outcome) \(report.error ?? "")")
        XCTAssertEqual(report.attempts, 2)

        // 重试次数配成 0 时第一次失败就放弃
        var config = NarrativeConfig()
        config.generation.retries = 0
        let g = try makeFixture("narrative-retry0")
        try seedDay(g.store)
        let always = ScriptedGenerationProvider(modelID: "m", answers: [], failFirst: true)
        let failed = try g.store.runNarrative(.day(Self.day), provider: always, config: config)
        XCTAssertFalse(failed.saved)
        XCTAssertEqual(failed.outcome, "failed")
        XCTAssertEqual(failed.attempts, 1)
    }

    /// 空的一天不生成（省掉一次白跑的 GPU）。
    func testEmptyDayIsSkipped() throws {
        let f = try makeFixture("narrative-empty-day")
        let provider = ScriptedGenerationProvider(modelID: "m", answers: ["随便"])
        let report = try f.store.runNarrative(.day("2025-09-01"), provider: provider)
        XCTAssertFalse(report.saved)
        XCTAssertEqual(report.outcome, "skipped_empty")
        XCTAssertEqual(provider.callCount, 0, "空台账连模型都不该叫")
    }

    // MARK: - 5. 周叙述

    func testWeekNarrativeInputAggregatesSevenDays() throws {
        let f = try makeFixture("narrative-week")
        let store = f.store!
        try seedDay(store)
        let input = try store.narrativeWeekInput(week: Self.day)
        XCTAssertEqual(input.level, "week")
        XCTAssertEqual(input.days.count, 7, "周输入要带 7 天的分布")
        XCTAssertTrue(input.period.contains("-W"))
        XCTAssertGreaterThan(input.totalDwellS, 0)
        let prompt = NarrativePromptBuilder.build(input)
        XCTAssertTrue(prompt.user.contains("【周台账】"))
        XCTAssertTrue(prompt.user.contains("【每天】"))
        XCTAssertLessThanOrEqual(prompt.estimatedTokens, NarrativeConfig().maxInputTokens)

        let provider = ScriptedGenerationProvider(
            modelID: "m", answers: ["本周主要时间花在飞书与 Xcode 上，Safari 用于查阅资料。"])
        // **故意用周内的一天当参数**：`getWeekLedger` 允许这么写，而 `ledgers` 行的 period
        // 存的是规范化之后的 `YYYY-Www`。不规范化就会 UPDATE 到零行、悄悄存不进去。
        let report = try store.runNarrative(.week(Self.day), provider: provider)
        XCTAssertTrue(report.saved, "\(report.outcome) \(report.error ?? "") "
                                  + "\(report.check?.violations ?? [])")
        XCTAssertEqual(report.target.period, input.period, "目标要被规范化成 ISO 周")
        let record = try XCTUnwrap(store.narrativeRecord(level: "week", period: input.period))
        XCTAssertEqual(record.model, "m")
        XCTAssertFalse(record.stale)
    }

    // MARK: - 6. schema v6

    func testSchemaV6ColumnAndMigrationFromV5() throws {
        let f = try makeFixture("narrative-v6")
        let columns = try f.store.tableColumnsForTests("ledgers")
        XCTAssertTrue(columns.contains("narrative_meta"))
        let notes = try f.store.migrationNotes()
        XCTAssertTrue(notes.contains { $0.version == 6 && $0.note.contains("narrative_meta") },
                      "migrations 表里要有 v6 的行：\(notes)")

        // 把库降级成 v5 的样子，重开必须就地补列、不重建、不丢数据。
        try f.store.record(Synth.observation(ts: Self.dayStart, texts: ["迁移之前写进去的一段正文。"]))
        try f.store.rawExecForTests("ALTER TABLE ledgers DROP COLUMN narrative_meta;")
        try f.store.rawExecForTests("UPDATE meta SET value = '5' WHERE key = 'schema_version';")
        try f.store.rawExecForTests("DELETE FROM migrations WHERE version >= 6;")
        try f.reopen()
        f.store.retrieval.timeZone = TimeZone(identifier: "UTC")!

        XCTAssertTrue(try f.store.tableColumnsForTests("ledgers").contains("narrative_meta"))
        XCTAssertEqual(try f.store.count(table: "observations"), 1, "迁移不能动已有数据")
        XCTAssertTrue(try f.store.migrationNotes().contains { $0.version == 6 })
        XCTAssertTrue(try f.store.integrityReport().allPassed)
    }
}

// MARK: - 测试用的小工具

extension Store {
    /// 一张表有哪些列（迁移用例用）。
    func tableColumnsForTests(_ table: String) throws -> [String] {
        try withLock { conn in
            try conn.textColumn("SELECT name FROM pragma_table_info('\(table)');")
        }
    }

    /// `jobs` 里某一类运行事件的 `input_ref`（按 id 升序）。
    func runtimeEventDetails(kind: String) throws -> [String] {
        try withLock { conn in
            try conn.textColumn("""
                SELECT COALESCE(input_ref, '') FROM jobs WHERE type = ? ORDER BY id;
                """, [.text("runtime_event:" + kind)])
        }
    }
}
