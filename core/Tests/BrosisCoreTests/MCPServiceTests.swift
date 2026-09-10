import Foundation
import XCTest
@testable import BrosisCore
import BrosisIPC

/// M1 / T5：服务端这一层（`StoreMCPService` + `MCPGate` + `mcp_audit`）。
/// 进程内直接调 `handle`，不起 socket、不起 MCP——那条完整链路在 `MCPEndToEndTests` 里。
final class MCPServiceTests: XCTestCase {

    // MARK: - 夹具

    private var fixture: Fixture!
    private var service: StoreMCPService!
    private var store: Store { fixture.store }
    /// 合成数据的时间锚点：现在往回一小时（grant 默认 30 天窗口内）。
    private var baseTS: Int64 = 0

    private static let bundles = ["com.apple.Safari", "com.microsoft.VSCode", "com.electron.lark"]

    override func setUpWithError() throws {
        fixture = try Fixture("mcp-service")
        store.retrieval.timeZone = TimeZone(identifier: "UTC")!
        service = StoreMCPService(store: store)
        baseTS = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        // 30 条观察，三个应用轮着来，每 10 s 一条；正文里埋了两个可检索的词。
        var inputs: [ObservationInput] = []
        for i in 0..<30 {
            let bundle = Self.bundles[i % Self.bundles.count]
            inputs.append(Synth.observation(
                ts: baseTS + Int64(i) * 10_000,
                bundle: bundle,
                appName: bundle.components(separatedBy: ".").last ?? bundle,
                window: "窗口 \(i % 3)",
                host: "docs.internal",
                texts: ["段落#\(i) 知识图谱 与 存储服务 的说明，序号 \(i)。"]))
        }
        try store.record(batch: inputs)
        _ = try store.buildSessions(force: true)
    }

    override func tearDown() {
        service = nil
        fixture = nil
    }

    // MARK: - 构造一次调用

    private func peer(verified: Bool = true) -> PeerInfo {
        PeerInfo(uid: getuid(), gid: getgid(), pid: getpid(), teamID: "TESTTEAM",
                 signingID: "com.brosis.test", codeSigningVerified: verified,
                 codeSigningNote: verified ? "skipped(test_host)" : "team_mismatch")
    }

    private func tool(_ name: MCPTool, _ args: [String: JSONValue] = [:],
                      client: String = "claude-code") -> IPCResponse {
        service.handle(IPCCall(request: IPCRequest(client: client, op: .tool, name: name.rawValue,
                                                   args: args),
                               peer: peer(), refusal: nil, rateUsed: 1, rateLimit: 60))
    }

    private func admin(_ command: AdminCommand, _ args: [String: JSONValue] = [:],
                       client: String = "admin", verified: Bool = true) -> IPCResponse {
        service.handle(IPCCall(request: IPCRequest(client: client, op: .admin,
                                                   name: command.rawValue, args: args),
                               peer: peer(verified: verified), refusal: nil,
                               rateUsed: 1, rateLimit: 60))
    }

    private func grant(_ fields: GrantFields = .evidence, apps: [String] = ["*"],
                       days: Int = 30, client: String = "claude-code") throws {
        try store.setGrant(Grant(clientID: client, mode: .strictLocal, apps: apps,
                                 timeWindowDays: days, fields: fields))
    }

    private func payload(_ response: IPCResponse) throws -> [String: JSONValue] {
        XCTAssertTrue(response.ok, "期望成功，实际 \(response.error?.code.rawValue ?? "-")："
                                 + (response.error?.message ?? ""))
        return try XCTUnwrap(response.result?.objectValue)
    }

    // MARK: - 没有 grant：所有工具全拒（3.6）

    func testNoGrantDeniesEveryTool() throws {
        let args: [MCPTool: [String: JSONValue]] = [
            .search: ["q": .string("知识图谱")],
            .getEvidence: ["ids": .array([.int(1)])],
            .getContext: ["hours": .int(24)],
            .getTimeline: ["start": .int(baseTS), .init("end"): .int(baseTS + 3_600_000),
                           "granularity": .string("hour")],
            .getDayLedger: ["date": .string(dayString(baseTS))],
            .getItem: ["app": .string(Self.bundles[0])],
            // M2 / T14 的三个
            .getWeekLedger: ["week": .string(dayString(baseTS))],
            .getPatterns: ["start": .int(baseTS), .init("end"): .int(baseTS + 3_600_000)],
            .recentActivity: ["minutes": .int(60)],
            .listActivity: ["period": .string("today")],
        ]
        for tool in MCPTool.allCases {
            let response = self.tool(tool, args[tool] ?? [:])
            XCTAssertFalse(response.ok, "\(tool.rawValue) 在没有 grant 时必须被拒")
            XCTAssertEqual(response.error?.code, .noGrant, tool.rawValue)
            XCTAssertNil(response.result, "\(tool.rawValue) 被拒时不能带任何数据")
        }
        let audit = try store.mcpAuditTail(limit: 20)
        XCTAssertEqual(audit.count, MCPTool.allCases.count)
        XCTAssertEqual(audit.count, 10)
        XCTAssertEqual(Set(audit.map(\.decision)), [.noGrant])
        XCTAssertEqual(Set(audit.map(\.tool)), Set(MCPTool.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(audit.map(\.clientID)), ["claude-code"])
    }

    // MARK: - 字段级别（3.6：默认 summary，只有 evidence 才回原文）

    func testGrantFieldsControlRawText() throws {
        try grant(.evidence)
        let hits = try payload(tool(.search, ["q": .string("知识图谱"), "limit": .int(3)]))
        let ids = try XCTUnwrap(hits["hits"]?.arrayValue?.compactMap { $0["evidenceID"]?.intValue })
        XCTAssertFalse(ids.isEmpty)

        let full = try payload(tool(.getEvidence, ["ids": .array(ids.map { .int($0) })]))
        let firstFull = try XCTUnwrap(full["items"]?.arrayValue?.first)
        XCTAssertEqual(firstFull["redactedByGrant"]?.boolValue, false)
        let text = try XCTUnwrap(firstFull["text"]?.stringValue)
        XCTAssertTrue(text.contains("知识图谱"), "fields = evidence 必须回原文")
        XCTAssertNotNil(firstFull["occurrences"]?.arrayValue?.first?["text"]?.stringValue)

        try grant(.summary)
        let redacted = try payload(tool(.getEvidence, ["ids": .array(ids.map { .int($0) })]))
        XCTAssertEqual(redacted["redacted"]?.boolValue, true)
        let firstRedacted = try XCTUnwrap(redacted["items"]?.arrayValue?.first)
        XCTAssertEqual(firstRedacted["redactedByGrant"]?.boolValue, true)
        XCTAssertNil(firstRedacted["text"], "fields = summary 不能回原文")
        XCTAssertNil(firstRedacted["occurrences"]?.arrayValue?.first?["text"],
                     "fields = summary 时逐片段的正文也不能回")
        // 摘要还是要有的，不然这个模式没意义
        XCTAssertFalse(try XCTUnwrap(firstRedacted["summary"]?.stringValue).isEmpty)
    }

    func testSummaryGrantTruncatesContextSnippets() throws {
        try grant(.summary)
        let bundle = try payload(tool(.getContext, ["hours": .int(2), "max_tokens": .int(4000)]))
        XCTAssertEqual(bundle["redactedByGrant"]?.boolValue, true)
        let budget = store.retrieval.summaryTokenBudget
        for snippet in bundle["snippets"]?.arrayValue ?? [] {
            let tokens = try XCTUnwrap(snippet["tokens"]?.intValue)
            XCTAssertLessThanOrEqual(tokens, Int64(budget),
                                     "fields = summary 时每条片段要截到 ≤ \(budget) token")
        }
        // 拼好的 text 要和裁剪后的片段一致（不能把没裁的那份发出去）
        let text = try XCTUnwrap(bundle["text"]?.stringValue)
        XCTAssertTrue(text.contains("[窗口]"))
        XCTAssertEqual(bundle["usedTokens"]?.intValue, Int64(TokenBudget.tokens(of: text)))
    }

    // MARK: - 应用白名单（3.6）

    func testAppWhitelistFiltersResults() throws {
        try grant(.evidence, apps: [Self.bundles[0]])

        // search：只剩白名单内的应用
        let searched = try payload(tool(.search, ["q": .string("知识图谱"), "limit": .int(20)]))
        let bundles = (searched["hits"]?.arrayValue ?? []).compactMap { $0["appBundleID"]?.stringValue }
        XCTAssertFalse(bundles.isEmpty)
        XCTAssertEqual(Set(bundles), [Self.bundles[0]])
        XCTAssertEqual(searched["grant"]?["filteredByGrant"]?.boolValue, true)
        XCTAssertGreaterThan(try XCTUnwrap(searched["grant"]?["droppedByGrant"]?.intValue), 0)

        // 显式指定白名单外的应用 → 直接拒
        let denied = tool(.search, ["q": .string("知识图谱"), "app": .string(Self.bundles[1])])
        XCTAssertEqual(denied.error?.code, .deniedByGrant)

        // get_evidence：白名单外的 id 进 deniedByGrant，不回内容
        let outside = try store.search(q: "知识图谱", app: Self.bundles[1], limit: 3)
        let outsideIDs = outside.hits.map(\.evidenceID)
        XCTAssertFalse(outsideIDs.isEmpty)
        let evidence = try payload(tool(.getEvidence, ["ids": .array(outsideIDs.map { .int($0) })]))
        XCTAssertEqual(evidence["items"]?.arrayValue?.count, 0)
        XCTAssertEqual(evidence["deniedByGrant"]?.arrayValue?.count, outsideIDs.count)

        // get_evidence：**白名单内 id 的出现上下文**也要按白名单裁。
        // before / after 带 bundle id 与窗口标题，漏一条就等于绕过白名单
        //（M1 第一轮验收就是在这里抓到的：邻居直接透传 store.getEvidence 的结果）。
        let inside = try store.search(q: "知识图谱", app: Self.bundles[0], limit: 5)
        let insideID = try XCTUnwrap(inside.hits.map(\.evidenceID).sorted().dropFirst().first,
                                     "要挑一条前后都有邻居的观察")
        let withNeighbors = try payload(tool(.getEvidence, [
            "ids": .array([.int(insideID)]), "neighbors": .int(3)]))
        let item = try XCTUnwrap(withNeighbors["items"]?.arrayValue?.first)
        let neighbors = (item["before"]?.arrayValue ?? []) + (item["after"]?.arrayValue ?? [])
        for neighbor in neighbors {
            XCTAssertEqual(neighbor["appBundleID"]?.stringValue, Self.bundles[0],
                           "出现上下文里出现了白名单外的应用")
            let summary = try XCTUnwrap(neighbor["summary"]?.stringValue)
            for outside in Self.bundles.dropFirst() {
                let name = outside.components(separatedBy: ".").last ?? outside
                XCTAssertFalse(summary.contains(name),
                               "邻居摘要里出现了白名单外应用的名字：\(summary)")
            }
        }
        // 同一条观察在 apps=["*"] 下前后确实有白名单外的邻居——不然上面的断言是空断言
        try grant(.evidence, apps: ["*"])
        let unscoped = try payload(tool(.getEvidence, [
            "ids": .array([.int(insideID)]), "neighbors": .int(3)]))
        let allItem = try XCTUnwrap(unscoped["items"]?.arrayValue?.first)
        let allNeighbors = (allItem["before"]?.arrayValue ?? []) + (allItem["after"]?.arrayValue ?? [])
        XCTAssertTrue(allNeighbors.contains { $0["appBundleID"]?.stringValue != Self.bundles[0] },
                      "夹具本身要有白名单外的邻居，否则白名单断言验不出东西")
        // 被裁掉的邻居条数要如实报出来
        try grant(.evidence, apps: [Self.bundles[0]])
        let reported = try payload(tool(.getEvidence, [
            "ids": .array([.int(insideID)]), "neighbors": .int(3)]))
        XCTAssertGreaterThan(try XCTUnwrap(reported["grant"]?["droppedByGrant"]?.intValue), 0)

        // get_item(app) 白名单外 → 拒
        XCTAssertEqual(tool(.getItem, ["app": .string(Self.bundles[1])]).error?.code, .deniedByGrant)
        XCTAssertTrue(tool(.getItem, ["app": .string(Self.bundles[0])]).ok)

        // 台账：只剩白名单内的应用，站点 / 文件两张表整段丢掉（回不到"哪个应用打开的"）
        let ledger = try payload(tool(.getDayLedger, ["date": .string(dayString(baseTS))]))
        let keys = (ledger["apps"]?.arrayValue ?? []).compactMap { $0["key"]?.stringValue }
        XCTAssertEqual(Set(keys), [Self.bundles[0]])
        XCTAssertNil(ledger["sites"])
        XCTAssertNil(ledger["files"])
        XCTAssertNotNil(ledger["droppedFields"]?.arrayValue)

        // 时间线：每个桶的应用分布与汇总量都按白名单重算
        let timeline = try payload(tool(.getTimeline, [
            "start": .int(baseTS), "end": .int(baseTS + 3_600_000),
            "granularity": .string("hour")]))
        for bucket in timeline["buckets"]?.arrayValue ?? [] {
            let bucketApps = (bucket["apps"]?.arrayValue ?? []).compactMap { $0["key"]?.stringValue }
            XCTAssertTrue(Set(bucketApps).isSubset(of: [Self.bundles[0]]))
            let dwell = try XCTUnwrap(bucket["dwellS"]?.doubleValue)
            let sum = (bucket["apps"]?.arrayValue ?? [])
                .compactMap { $0["dwellS"]?.doubleValue }.reduce(0, +)
            XCTAssertEqual(dwell, sum, accuracy: 0.001, "桶的 dwell 要按留下的应用重算")
        }
    }

    /// 被 grant 丢掉的相邻观察**不占 `neighbors` 的名额**。
    ///
    /// 夹具里三个应用 10 s 一条轮着来，所以一条 Safari 观察紧邻的前后两条都在白名单外：
    /// `Store.neighborRows` 只按 `limit` 取候选的话，过滤完前后各只剩 1 条邻居，
    /// 白名单客户端拿到的"出现上下文"比该给的少一大截（还看不出少了）。
    ///
    /// **变异检验**：把 `core/Sources/BrosisCore/Store+Evidence.swift` 里的
    /// `let fetch = scoped ? min(limit * 8, 200) : limit` 改成 `let fetch = limit`，
    /// 下面 before / after 各 3 条那两条断言就会红（实际会变成 1 条）。
    func testDroppedNeighborsDoNotConsumeTheNeighborQuota() throws {
        let want = 3
        try grant(.evidence, apps: ["*"])
        // 挑中间那条 Safari 观察：前后都还有 ≥ want 条同应用的观察（夹具里 Safari 共 10 条）
        let safari = try store.search(q: "知识图谱", app: Self.bundles[0], limit: 50)
            .hits.sorted { $0.ts < $1.ts }
        XCTAssertGreaterThanOrEqual(safari.count, 2 * want + 1, "夹具里 Safari 的观察不够挑")
        let middle = safari[safari.count / 2].evidenceID

        // 反向对照：不加白名单时，紧邻的 want 条里最多 1 条是 Safari。
        // 这一步坐实了"白名单外的邻居密集"这个前提——否则下面就是空断言。
        let unscoped = try payload(tool(.getEvidence,
                                        ["ids": .array([.int(middle)]), "neighbors": .int(Int64(want))]))
        let unscopedItem = try XCTUnwrap(unscoped["items"]?.arrayValue?.first)
        for side in ["before", "after"] {
            let rows = try XCTUnwrap(unscopedItem[side]?.arrayValue)
            XCTAssertEqual(rows.count, want, "\(side)：apps = [\"*\"] 时应该拿满 \(want) 条")
            let inWhitelist = rows.filter { $0["appBundleID"]?.stringValue == Self.bundles[0] }
            XCTAssertLessThanOrEqual(inWhitelist.count, 1,
                                     "\(side)：紧邻的 \(want) 条里白名单内的不该超过 1 条，"
                                     + "否则这个用例证明不了「多取候选」是必要的")
        }

        // 白名单只留 Safari：被丢掉的行不占名额，before / after 仍要各拿满 want 条
        try grant(.evidence, apps: [Self.bundles[0]])
        let scoped = try payload(tool(.getEvidence,
                                      ["ids": .array([.int(middle)]), "neighbors": .int(Int64(want))]))
        let item = try XCTUnwrap(scoped["items"]?.arrayValue?.first)
        for side in ["before", "after"] {
            let rows = try XCTUnwrap(item[side]?.arrayValue)
            XCTAssertEqual(rows.count, want,
                           "\(side)：被 grant 丢掉的行不能占 neighbors 的名额（实际 \(rows.count) 条）")
            XCTAssertTrue(rows.allSatisfy { $0["appBundleID"]?.stringValue == Self.bundles[0] })
        }
        XCTAssertGreaterThan(try XCTUnwrap(scoped["grant"]?["droppedByGrant"]?.intValue), 0,
                            "丢掉的条数要如实报出来")

        // 这条规则写在 core 的 Store.neighborRows，不是 MCP 那一层：直接调 core 也是同一个结论
        let narrow = try XCTUnwrap(try store.grant(clientID: "claude-code"))
        let direct = try store.getEvidence(ids: [middle], grant: narrow, neighbors: want)
        XCTAssertEqual(direct.items.first?.before.count, want)
        XCTAssertEqual(direct.items.first?.after.count, want)
        XCTAssertGreaterThan(direct.droppedNeighbors, 0)
    }

    // MARK: - 时间窗（3.6：默认 30 天）

    func testTimeWindowIsAHardLowerBound() throws {
        // 一条一年前的观察：30 天窗口的 grant 不该看得到
        let old = baseTS - 365 * 86_400_000
        _ = try store.record(Synth.observation(ts: old, bundle: Self.bundles[0],
                                               window: "旧窗口", texts: ["去年的 知识图谱 记录"]))
        try grant(.evidence, days: 30)

        // 客户端把 start 写到一年前也没用，服务端按 grant 的窗口下界收紧
        let searched = try payload(tool(.search, ["q": .string("知识图谱"),
                                                  "start": .int(old - 86_400_000),
                                                  "limit": .int(50)]))
        let applied = try XCTUnwrap(searched["appliedStart"]?.intValue)
        XCTAssertGreaterThan(applied, old, "appliedStart 必须被抬到 grant 的窗口起点")
        let timestamps = (searched["hits"]?.arrayValue ?? []).compactMap { $0["ts"]?.intValue }
        XCTAssertFalse(timestamps.isEmpty)
        XCTAssertTrue(timestamps.allSatisfy { $0 >= applied })

        // 一年前那一天的台账：整天都在窗口外 → 拒
        let ledger = tool(.getDayLedger, ["date": .string(dayString(old))])
        XCTAssertEqual(ledger.error?.code, .deniedByGrant)

        // 一年前的证据 id：core 的 getEvidence 按时间窗挡下
        let oldHits = try store.search(q: "知识图谱", start: old - 86_400_000, end: old + 86_400_000,
                                       limit: 5)
        let oldIDs = oldHits.hits.map(\.evidenceID)
        XCTAssertFalse(oldIDs.isEmpty)
        let evidence = try payload(tool(.getEvidence, ["ids": .array(oldIDs.map { .int($0) })]))
        XCTAssertEqual(evidence["items"]?.arrayValue?.count, 0)
        XCTAssertEqual(evidence["deniedByGrant"]?.arrayValue?.count, oldIDs.count)

        // get_context 的 hours 也被窗口封顶
        let context = try payload(tool(.getContext, ["hours": .int(24 * 365)]))
        XCTAssertEqual(context["hoursClampedByGrant"]?.boolValue, true)
        XCTAssertEqual(context["hours"]?.intValue, Int64(30 * 24))
    }

    /// 时间窗起点落在某天**中间**那一天：`get_day_ledger` 返回的仍是整天的数字。
    ///
    /// 台账按自然日预聚合（`ledgers` 表按天存），切不成半天，所以这件事只能如实标注，
    /// 标记就是 `StoreMCPService.runDayLedger` 里的 `coversBeforeWindowStart`
    /// （已知取舍，见 `core/README.md`；本轮不改口径，只把它钉住）。
    ///
    /// **变异检验**：把那一行写死成 `.bool(false)` 或 `.bool(true)`，下面两条断言各红一条。
    func testDayLedgerFlagsTheDayWhereTheGrantWindowStarts() throws {
        // 把时区挪到「此刻正好是当地正午」：窗口起点 = 现在往回整数天，
        // 于是它必定落在某天正中间，跟测试在几点跑无关。
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let offsetS = Int((43_200_000 - now % 86_400_000) / 60_000) * 60   // ∈ (-43200, 43200]
        let tz = try XCTUnwrap(TimeZone(secondsFromGMT: offsetS))
        store.retrieval.timeZone = tz
        let cal = DayCalendar(tz)

        let days = 3
        let windowStart = now - Int64(days) * 86_400_000                   // ≈ 当地正午
        let boundaryDay = cal.dayString(windowStart)
        // 边界日：窗口起点前两小时 6 条、后两小时 6 条，同一个自然日
        var inputs: [ObservationInput] = []
        for i in 0..<6 {
            inputs.append(Synth.observation(ts: windowStart - 2 * 3_600_000 + Int64(i) * 10_000,
                                            bundle: Self.bundles[0], window: "窗口起点之前",
                                            texts: ["边界日 窗口起点之前的记录 \(i)。"]))
            inputs.append(Synth.observation(ts: windowStart + 2 * 3_600_000 + Int64(i) * 10_000,
                                            bundle: Self.bundles[0], window: "窗口起点之后",
                                            texts: ["边界日 窗口起点之后的记录 \(i)。"]))
        }
        try store.record(batch: inputs)
        _ = try store.buildSessions(force: true)
        try grant(.evidence, days: days)

        // ① 边界日：标记为真，而且数字确实覆盖了窗口起点之前那两小时
        let boundary = try payload(tool(.getDayLedger, ["date": .string(boundaryDay)]))
        XCTAssertEqual(boundary["coversBeforeWindowStart"]?.boolValue, true,
                       "窗口起点落在 \(boundaryDay) 中间，必须标出来")
        XCTAssertEqual(boundary["observations"]?.intValue, 12,
                       "台账按自然日预聚合，窗口起点之前的 6 条也在里面——这正是标记存在的原因")
        XCTAssertGreaterThan(try XCTUnwrap(boundary["totalDwellS"]?.doubleValue), 0)

        // 逐条查询的工具能把 start 抬到窗口起点：同一天只回窗口之后的 6 条。
        // 两个数字的差就是 coversBeforeWindowStart 要提醒调用方的那件事。
        let dayEnd = try XCTUnwrap(boundary["end"]?.intValue)
        let timeline = try payload(tool(.getTimeline, [
            "start": .int(windowStart - 6 * 3_600_000),
            "end": .int(dayEnd),
            "granularity": .string("hour")]))
        let counted = (timeline["buckets"]?.arrayValue ?? [])
            .compactMap { $0["observations"]?.intValue }.reduce(0, +)
        XCTAssertEqual(counted, 6, "get_timeline 是逐条查询，只该回窗口起点之后的 6 条")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(timeline["appliedStart"]?.intValue),
                                    windowStart - 1000, "start 要被抬到窗口起点")

        // ② 整天都在窗口里的那天：标记为假（不然这个标记恒为真，等于没标）
        let insideDay = try payload(tool(.getDayLedger, ["date": .string(cal.dayString(now))]))
        XCTAssertEqual(insideDay["coversBeforeWindowStart"]?.boolValue, false,
                       "今天整天都在窗口里，不该标 coversBeforeWindowStart")
        XCTAssertEqual(insideDay["observations"]?.intValue, 30, "今天就是夹具那 30 条")
    }

    // MARK: - 3.8 验收：删除后四个入口都不再返回内容

    func testDeletedObservationsVanishFromEveryTool() throws {
        try grant(.evidence)
        let before = try payload(tool(.search, ["q": .string("知识图谱"), "limit": .int(50)]))
        let ids = try XCTUnwrap(before["hits"]?.arrayValue?.compactMap { $0["evidenceID"]?.intValue })
        XCTAssertGreaterThan(ids.count, 5)
        let day = dayString(baseTS)
        XCTAssertGreaterThan(try XCTUnwrap(
            payload(tool(.getDayLedger, ["date": .string(day)]))["observations"]?.intValue), 0)

        // 全删（三个应用一次一个）
        for bundle in Self.bundles { _ = try store.deleteByApp(bundleID: bundle) }

        let after = try payload(tool(.search, ["q": .string("知识图谱"), "limit": .int(50)]))
        XCTAssertEqual(after["hits"]?.arrayValue?.count, 0, "删除后 search 不能再命中")

        let evidence = try payload(tool(.getEvidence, ["ids": .array(ids.map { .int($0) })]))
        XCTAssertEqual(evidence["items"]?.arrayValue?.count, 0)
        XCTAssertEqual(evidence["missing"]?.arrayValue?.count, ids.count,
                       "删掉的 id 只回 id 本身（3.8）")

        let context = try payload(tool(.getContext, ["hours": .int(24)]))
        XCTAssertEqual(context["snippets"]?.arrayValue?.count, 0)
        XCTAssertFalse(try XCTUnwrap(context["text"]?.stringValue).contains("知识图谱"))

        let ledger = try payload(tool(.getDayLedger, ["date": .string(day)]))
        XCTAssertEqual(ledger["observations"]?.intValue, 0)
        XCTAssertEqual(ledger["apps"]?.arrayValue?.count, 0)
    }

    // MARK: - 审计（3.6 / 2.2 硬约束 4）

    func testAuditRecordsShapeNotContent() throws {
        try grant(.evidence)
        _ = tool(.search, ["q": .string("知识图谱"), "limit": .int(3)])
        _ = tool(.getEvidence, ["ids": .array([.int(1), .int(2)])])
        _ = tool(.getItem, ["url": .string("https://docs.internal/doc/1")])

        let rows = try store.mcpAuditTail(limit: 10)
        XCTAssertEqual(rows.count, 3)
        let all = rows.map { $0.params }.joined(separator: " | ")
        XCTAssertFalse(all.contains("知识图谱"), "审计里不能出现查询串本身")
        XCTAssertFalse(all.contains("docs.internal"), "审计里不能出现 URL 本身")
        XCTAssertTrue(all.contains("q_chars=4"))
        XCTAssertTrue(all.contains("q_sha="))
        XCTAssertTrue(all.contains("ids=2"))

        let search = try XCTUnwrap(rows.first { $0.tool == "search" })
        XCTAssertEqual(search.decision, .ok)
        XCTAssertEqual(search.op, "tool")
        XCTAssertEqual(search.clientID, "claude-code")
        XCTAssertGreaterThan(search.resultCount, 0)
        XCTAssertGreaterThan(search.elapsedMS, 0)
        XCTAssertTrue(try XCTUnwrap(search.peer).contains("uid=\(getuid())"))

        // 参数摘要里的 sha 是可复现的：同一条查询两次，摘要一致
        _ = tool(.search, ["q": .string("知识图谱"), "limit": .int(3)])
        let again = try XCTUnwrap(try store.mcpAuditTail(limit: 1).first)
        XCTAssertEqual(again.params, search.params)
    }

    func testAuditPrunedByMaintenance() throws {
        try grant(.evidence)
        _ = tool(.search, ["q": .string("知识图谱")])
        XCTAssertEqual(try store.mcpAuditCount(), 1)
        // 把"现在"推到 200 天后，保留 90 天 → 这行要被清掉
        let future = Int64(Date().timeIntervalSince1970 * 1000) + 200 * 86_400_000
        let report = try store.maintenance(now: future)
        XCTAssertEqual(report.mcpAuditPruned, 1)
        XCTAssertEqual(try store.mcpAuditCount(), 0)
    }

    // MARK: - 未知工具 / 坏参数

    func testUnknownToolAndBadArguments() throws {
        try grant(.evidence)
        let unknown = service.handle(IPCCall(
            request: IPCRequest(client: "claude-code", op: .tool, name: "drop_database"),
            peer: peer(), refusal: nil, rateUsed: 1, rateLimit: 60))
        XCTAssertEqual(unknown.error?.code, .unknownTool)

        XCTAssertEqual(tool(.search, [:]).error?.code, .badRequest)
        XCTAssertEqual(tool(.getEvidence, ["ids": .array([])]).error?.code, .badRequest)
        XCTAssertEqual(tool(.getEvidence,
                            ["ids": .array((0..<200).map { .int(Int64($0)) })]).error?.code,
                       .badRequest)
        XCTAssertEqual(tool(.getItem, [:]).error?.code, .badRequest)
        XCTAssertEqual(tool(.getItem, ["url": .string("a"), "app": .string("b")]).error?.code,
                       .badRequest)
        XCTAssertEqual(tool(.getTimeline, ["start": .string("昨天"),
                                           "end": .int(baseTS)]).error?.code, .badRequest)
        XCTAssertEqual(tool(.getDayLedger, ["date": .string("2026-13-99")]).error?.code,
                       .badRequest)      // 日期现在由 TimeScope 解析，坏日期是坏参数

        let audit = try store.mcpAuditTail(limit: 20)
        XCTAssertTrue(audit.contains { $0.decision == .unknownTool })
        XCTAssertTrue(audit.contains { $0.decision == .badRequest })
    }

    func testTimeArgumentsAcceptISO8601AndMillisAndDate() throws {
        try grant(.evidence)
        let calendar = DayCalendar(TimeZone(identifier: "UTC")!)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")!
        let iso = formatter.string(from: Date(timeIntervalSince1970: Double(baseTS) / 1000))
        XCTAssertEqual(try StoreMCPService.time(.string(iso), field: "start", calendar: calendar),
                       (baseTS / 1000) * 1000)
        XCTAssertEqual(try StoreMCPService.time(.int(baseTS), field: "start", calendar: calendar),
                       baseTS)
        XCTAssertEqual(try StoreMCPService.time(.string(String(baseTS)), field: "start",
                                                calendar: calendar), baseTS)
        XCTAssertEqual(try StoreMCPService.time(.string("2026-09-07"), field: "start",
                                                calendar: calendar),
                       try calendar.dayBounds("2026-09-07").start)
        XCTAssertNil(try StoreMCPService.time(nil, field: "start", calendar: calendar))
        XCTAssertThrowsError(try StoreMCPService.time(.string("下周三"), field: "start",
                                                      calendar: calendar))
    }

    // MARK: - 锁定门（3.5：locked 与 paused 都拒绝 MCP）

    func testGateRefusesWhenLockedAndFlushesAuditAfterUnlock() throws {
        try grant(.evidence)
        let state = Box(MCPServiceState.locked)
        let live = service!
        let gate = MCPGate { (state.value, state.value == .locked ? nil : live) }
        let call = IPCCall(request: IPCRequest(client: "claude-code", op: .tool,
                                               name: MCPTool.search.rawValue,
                                               args: ["q": .string("知识图谱")]),
                           peer: peer(), refusal: nil, rateUsed: 1, rateLimit: 60)

        let lockedResponse = gate.handle(call)
        XCTAssertEqual(lockedResponse.error?.code, .locked)
        XCTAssertNil(lockedResponse.result)
        XCTAssertEqual(try store.mcpAuditCount(), 0, "库关着的时候写不进审计")
        XCTAssertEqual(gate.pendingAuditCount, 1, "被拒的调用要先攒在内存里")

        // locked 时 ping 仍然要答，并把状态说清楚
        let ping = gate.handle(IPCCall(request: IPCRequest(client: "claude-code", op: .ping),
                                       peer: peer(), refusal: nil, rateUsed: 0, rateLimit: 60))
        XCTAssertTrue(ping.ok)
        XCTAssertEqual(ping.result?["state"]?.stringValue, "locked")

        // paused：库开着，直接写审计，照样拒绝
        state.value = .paused
        let pausedResponse = gate.handle(call)
        XCTAssertEqual(pausedResponse.error?.code, .paused)
        // 这一次 provider 交出了 service，所以锁定期间攒的那条也补写了
        XCTAssertEqual(gate.pendingAuditCount, 0)
        let rows = try store.mcpAuditTail(limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.decision)), [.locked, .paused])

        // 解锁后恢复服务
        state.value = .unlocked
        let ok = gate.handle(call)
        XCTAssertTrue(ok.ok)
        XCTAssertGreaterThan(try XCTUnwrap(ok.result?["hitCount"]?.intValue), 0)
    }

    // MARK: - 传输层拒绝也要进审计

    func testTransportRefusalsAreAudited() throws {
        try grant(.evidence)
        for (refusal, expected) in [
            (IPCFailure(code: .rateLimited, message: "超额"), MCPDecision.rateLimited),
            (IPCFailure(code: .unauthorizedPeer, message: "签名没过"), MCPDecision.unauthorizedPeer),
        ] {
            let response = service.handle(IPCCall(
                request: IPCRequest(client: "claude-code", op: .tool,
                                    name: MCPTool.search.rawValue, args: ["q": .string("x")]),
                peer: peer(verified: false), refusal: refusal, rateUsed: 61, rateLimit: 60))
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error?.code, refusal.code)
            let row = try XCTUnwrap(try store.mcpAuditTail(limit: 1).first)
            XCTAssertEqual(row.decision, expected)
            XCTAssertEqual(row.note, "rate=61/60")
        }
    }

    // MARK: - admin

    func testAdminGrantLifecycle() throws {
        XCTAssertEqual(try payload(admin(.grantList))["count"]?.intValue, 0)

        let added = try payload(admin(.grantAdd, [
            "client_id": .string("claude-code"),
            "mode": .string("remote_allowed"),
            "apps": .array([.string(Self.bundles[0]), .string(Self.bundles[1])]),
            "time_window_days": .int(7),
            "fields": .string("evidence"),
        ]))
        XCTAssertEqual(added["grant"]?["clientID"]?.stringValue, "claude-code")
        XCTAssertEqual(added["grant"]?["mode"]?.stringValue, "remote_allowed")
        XCTAssertEqual(added["grant"]?["timeWindowDays"]?.intValue, 7)

        let listed = try payload(admin(.grantList))
        XCTAssertEqual(listed["count"]?.intValue, 1)
        XCTAssertTrue(try XCTUnwrap(listed["note"]?.stringValue).contains("strict_local"))

        let status = try payload(admin(.status))
        XCTAssertEqual(status["schemaVersion"]?.intValue, Int64(Schema.version))
        XCTAssertEqual(status["grants"]?.intValue, 1)
        XCTAssertEqual(status["tools"]?.arrayValue?.count, MCPTool.allCases.count)

        // 坏参数
        XCTAssertEqual(admin(.grantAdd, ["client_id": .string("x"),
                                         "fields": .string("everything")]).error?.code, .badRequest)
        XCTAssertEqual(admin(.grantAdd, [:]).error?.code, .badRequest)

        // 对端签名没过的连接不能改授权
        XCTAssertEqual(admin(.grantList, verified: false).error?.code, .unauthorizedPeer)

        let removed = try payload(admin(.grantRemove, ["client_id": .string("claude-code")]))
        XCTAssertEqual(removed["removed"]?.boolValue, true)
        XCTAssertEqual(try payload(admin(.grantList))["count"]?.intValue, 0)

        // 全部 admin 调用都留了审计
        let audit = try store.mcpAuditTail(limit: 20)
        XCTAssertTrue(audit.allSatisfy { $0.op == "admin" })
        XCTAssertTrue(audit.contains { $0.tool == "grant_add" && $0.decision == .ok })
        XCTAssertTrue(audit.contains { $0.decision == .unauthorizedPeer })
    }

    func testAdminAuditTail() throws {
        try grant(.evidence)
        for i in 0..<3 { _ = tool(.search, ["q": .string("知识图谱\(i)")]) }
        let result = try payload(admin(.auditTail, ["limit": .int(2)]))
        XCTAssertEqual(result["rows"]?.arrayValue?.count, 2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result["total"]?.intValue), 3)
    }

    // MARK: - schema 迁移 v1 → v2

    func testSchemaMigrationAddsAuditTableToV1Database() throws {
        let migrating = try Fixture("mcp-migrate")
        // 把库改回 v1 的样子：删掉 mcp_audit、schema_version 写回 1
        try migrating.store.withLock { conn in
            try conn.exec("DROP TABLE mcp_audit;")
            try conn.run("UPDATE meta SET value = '1' WHERE key = 'schema_version';")
            try conn.run("DELETE FROM migrations WHERE version >= 2;")
        }
        try migrating.reopen()
        XCTAssertEqual(try migrating.store.mcpAuditCount(), 0, "迁移后 mcp_audit 必须存在")
        let versions = try migrating.store.withLock { conn in
            try conn.intColumn("SELECT version FROM migrations ORDER BY version;")
        }
        // 这个夹具的库是按当前 schema 建的，这里只把 v2 之后的审计痕迹抹掉、把 mcp_audit 删掉；
        // 重开时 migrateIfNeeded 从 v2 一路补到当前版本（表与列大多已经在，按"先查再做"跳过），
        // 每一版各留一条审计行，所以是 1…Schema.version。
        XCTAssertEqual(versions, Schema.migrationVersions.map(Int64.init),
                       "migrations 表要留下每一版的审计（版本号不一定连续，见 Schema.migrationVersions）")
        let note = try migrating.store.withLock { conn in
            try conn.scalarText("SELECT note FROM migrations WHERE version = 2;")
        }
        XCTAssertTrue(try XCTUnwrap(note).contains("就地迁移"))
        // 迁移之后照常能用
        try migrating.store.setGrant(Grant(clientID: "c", fields: .evidence))
        XCTAssertTrue(migrating.store.appendMCPAudit(
            MCPAuditRow(clientID: "c", op: "tool", tool: "search", params: "-", decision: .ok)))
        XCTAssertEqual(try migrating.store.mcpAuditCount(), 1)
    }

    // MARK: - 时间范围统一（2026-09-10：「今天」在工具层不存在的修法，见 TimeScope.swift）

    /// period 的每种写法都按**服务端时区**解析。用 Asia/Shanghai 与一个固定的 now 钉住边界，
    /// 与测试在几点跑、本机什么时区无关：now = 2026-09-10 19:04:40 CST（周四）。
    func testPeriodGrammarResolvesInServerTimeZone() throws {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let now: Int64 = 1_789_038_280_000
        let day: Int64 = 86_400_000
        let today0: Int64 = 1_788_969_600_000            // 2026-09-10 00:00 CST
        let monday0 = today0 - 3 * day                    // 2026-09-07 00:00 CST，ISO 2026-W37
        func scope(_ p: String) throws -> TimeScope { try TimeScope.parsePeriod(p, now: now, timeZone: tz) }

        let today = try scope("today")
        XCTAssertEqual(today.start, today0)
        XCTAssertEqual(today.end, today0 + day)
        XCTAssertEqual(today.label, "2026-09-10")
        XCTAssertEqual(today.source, .period)
        XCTAssertEqual(today.period, "today")

        let yesterday = try scope(" Yesterday ")
        XCTAssertEqual(yesterday.start, today0 - day)
        XCTAssertEqual(yesterday.end, today0)
        XCTAssertEqual(yesterday.label, "2026-09-09")

        let date = try scope("2026-09-08")
        XCTAssertEqual(date.start, today0 - 2 * day)
        XCTAssertEqual(date.end, today0 - day)

        let range = try scope("2026-09-08..2026-09-10")
        XCTAssertEqual(range.start, today0 - 2 * day)
        XCTAssertEqual(range.end, today0 + day, "两端都含：10 号整天也在里面")
        XCTAssertEqual(range.label, "2026-09-08..2026-09-10")

        let week = try scope("2026-W37")
        XCTAssertEqual(week.start, monday0)
        XCTAssertEqual(week.end, monday0 + 7 * day)
        XCTAssertEqual(week.label, "2026-W37")
        let thisWeek = try scope("this_week")
        XCTAssertEqual(thisWeek.start, week.start)
        XCTAssertEqual(thisWeek.end, week.end)
        XCTAssertEqual(thisWeek.label, "2026-W37")
        let lastWeek = try scope("last_week")
        XCTAssertEqual(lastWeek.start, monday0 - 7 * day)
        XCTAssertEqual(lastWeek.end, monday0)
        XCTAssertEqual(lastWeek.label, "2026-W36")

        let hours = try scope("24h")
        XCTAssertEqual(hours.start, now - day)
        XCTAssertEqual(hours.end, now, "相对写法的锚点是 now，不是库里最新一条观察")
        XCTAssertEqual(hours.label, "24h")
        XCTAssertEqual(try scope("90m").start, now - 90 * 60_000)
        XCTAssertEqual(try scope("3d").start, now - 3 * day)

        for bad in ["", "下周三", "2026-13-99", "2026-09-10..2026-09-08", "0h", "2026-W99", "24 hours", "h"] {
            XCTAssertThrowsError(try scope(bad), "应当拒绝：\(bad)")
        }
        // 单日 / 整周的判定（日台账、周台账靠它）
        XCTAssertEqual(today.singleDay(in: tz), "2026-09-10")
        XCTAssertNil(range.singleDay(in: tz))
        XCTAssertNil(hours.singleDay(in: tz))
        XCTAssertEqual(week.singleWeek(in: tz), "2026-W37")
        XCTAssertNil(today.singleWeek(in: tz))
    }

    /// 精确边界：裸日期在 end 位置取当天 24:00；不带时区偏移的 ISO 按服务端时区，不当 UTC。
    func testExplicitBoundsAcceptLocalISOAndBareDateAtEnd() throws {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let now: Int64 = 1_789_038_280_000
        let today0: Int64 = 1_788_969_600_000
        func at(_ v: JSONValue, end: Bool = false) throws -> Int64? {
            try TimeScope.parseInstant(v, field: "t", isEnd: end, timeZone: tz)
        }
        XCTAssertEqual(try at(.string("2026-09-10")), today0)
        XCTAssertEqual(try at(.string("2026-09-10"), end: true), today0 + 86_400_000)
        XCTAssertEqual(try at(.string("2026-09-10T00:00:00")), today0, "不带偏移按服务端时区")
        XCTAssertEqual(try at(.string("2026-09-10T00:00:00+08:00")), today0)
        XCTAssertEqual(try at(.string("2026-09-09T16:00:00Z")), today0)
        XCTAssertEqual(try at(.string("2026-09-10 08:30")), today0 + 8 * 3_600_000 + 30 * 60_000)
        XCTAssertEqual(try at(.int(today0)), today0)
        XCTAssertEqual(try at(.string("\(today0)")), today0)
        XCTAssertNil(try at(.null))
        XCTAssertThrowsError(try at(.string("昨天")))

        // 第 ③ 条规矩：period 与 start / end 不能同时给；只给 start 上不封顶；只给 end 没默认起点就报错
        XCTAssertThrowsError(try TimeScope.resolve(
            args: ["period": .string("today"), "start": .string("2026-09-10")],
            now: now, timeZone: tz, default: nil))
        let open = try TimeScope.resolve(args: ["start": .string("2026-09-10")],
                                         now: now, timeZone: tz, default: nil)
        XCTAssertEqual(open.start, today0)
        XCTAssertNil(open.end)
        XCTAssertEqual(open.source, .explicit)
        XCTAssertThrowsError(try TimeScope.resolve(args: ["end": .string("2026-09-10")],
                                                   now: now, timeZone: tz, default: nil))
        XCTAssertThrowsError(try TimeScope.resolve(
            args: ["start": .string("2026-09-10"), "end": .string("2026-09-09")],
            now: now, timeZone: tz, default: nil), "start < end")
        let fallback = TimeScope(start: 1, end: nil, label: "x", source: .default)
        XCTAssertEqual(try TimeScope.resolve(args: [:], now: now, timeZone: tz, default: fallback), fallback)
        XCTAssertThrowsError(try TimeScope.resolve(args: [:], now: now, timeZone: tz, default: nil))
        // grant 时间窗是硬下界
        let clipped = open.clipped(toGrantStart: today0 + 1)
        XCTAssertEqual(clipped.start, today0 + 1)
        XCTAssertTrue(clipped.clippedByGrant)
        XCTAssertFalse(open.clipped(toGrantStart: today0 - 1).clippedByGrant)
    }

    /// 同一个 period 在每个工具上解析出**同一对边界**，并且每个结果都回显它真正用的窗口与服务端的钟。
    func testEveryToolEchoesTheWindowAndServerClock() throws {
        try grant(.evidence)
        let day = dayString(baseTS)
        let cal = DayCalendar(TimeZone(identifier: "UTC")!)
        let bounds = try cal.dayBounds(day)
        let calls: [(MCPTool, [String: JSONValue])] = [
            (.search, ["q": .string("知识图谱"), "period": .string(day)]),
            (.getContext, ["period": .string(day), "max_tokens": .int(300)]),
            (.getTimeline, ["period": .string(day), "granularity": .string("hour")]),
            (.getDayLedger, ["period": .string(day)]),
            (.getItem, ["app": .string(Self.bundles[0]), "period": .string(day)]),
            (.getPatterns, ["period": .string(day)]),
            (.recentActivity, ["period": .string(day), "max_items": .int(3)]),
            (.listActivity, ["period": .string(day), "max_items": .int(3)]),
        ]
        for (tool, args) in calls {
            let object = try payload(self.tool(tool, args))
            let window = try XCTUnwrap(object["window"]?.objectValue, tool.rawValue)
            XCTAssertEqual(window["start"]?.intValue, bounds.start, tool.rawValue)
            XCTAssertEqual(window["end"]?.intValue, bounds.end, tool.rawValue)
            XCTAssertEqual(window["label"]?.stringValue, day, tool.rawValue)
            XCTAssertEqual(window["period"]?.stringValue, day, tool.rawValue)
            XCTAssertEqual(window["resolvedFrom"]?.stringValue, "period", tool.rawValue)
            // `TimeZone(identifier: "UTC").identifier` 在这个平台上回 "GMT"，按平台给的名字比
            XCTAssertEqual(window["timeZone"]?.stringValue, cal.timeZone.identifier, tool.rawValue)
            XCTAssertEqual(window["clippedByGrant"]?.boolValue, false, tool.rawValue)
            XCTAssertEqual(window["startLocal"]?.stringValue, cal.stamp(bounds.start), tool.rawValue)
            let serverNow = try XCTUnwrap(object["serverNow"]?.intValue, tool.rawValue)
            XCTAssertEqual(object["serverToday"]?.stringValue, cal.dayString(serverNow), tool.rawValue)
            XCTAssertEqual(object["serverTimeZone"]?.stringValue, cal.timeZone.identifier, tool.rawValue)
            XCTAssertEqual(object["serverNowLocal"]?.stringValue, cal.stamp(serverNow), tool.rawValue)
        }
        // 这一天的内容确实是这一天的：list_activity 每条 ts 都落在窗口里，与日台账数的观察条数对得上
        let list = try payload(tool(.listActivity, ["period": .string(day), "max_items": .int(200)]))
        let timestamps = (list["items"]?.arrayValue ?? []).compactMap { $0["ts"]?.intValue }
        XCTAssertFalse(timestamps.isEmpty)
        XCTAssertTrue(timestamps.allSatisfy { $0 >= bounds.start && $0 < bounds.end })
        let ledger = try payload(tool(.getDayLedger, ["period": .string(day)]))
        XCTAssertEqual(ledger["observations"]?.intValue, list["observations"]?.intValue)
        // get_context 按整天算时 hours = 24
        XCTAssertEqual(try payload(tool(.getContext, ["period": .string(day), "max_tokens": .int(100)]))["hours"]?.intValue, 24)

        // get_evidence 没有窗口，但同样报时；周台账给一天 → 回的是整周，标签是 ISO 周
        let evidence = try payload(tool(.getEvidence, ["ids": .array([.int(1)])]))
        XCTAssertNil(evidence["window"])
        XCTAssertNotNil(evidence["serverNow"]?.intValue)
        let week = try payload(tool(.getWeekLedger, ["period": .string(day)]))
        let weekWindow = try XCTUnwrap(week["window"]?.objectValue)
        XCTAssertEqual(weekWindow["start"]?.intValue, cal.bucketStart(baseTS, .week))
        XCTAssertEqual(weekWindow["end"]?.intValue, cal.bucketEnd(cal.bucketStart(baseTS, .week), .week))
        XCTAssertEqual(weekWindow["label"]?.stringValue, cal.bucketLabel(cal.bucketStart(baseTS, .week), .week))
    }

    /// 不给范围时：日历类工具 = 今天（周台账 = 本周），get_context / recent_activity = 从现在往回滚，
    /// search / get_item = 整个 grant 时间窗且上不封顶。三种情况 `resolvedFrom` 都是 `default`。
    func testOmittedRangeDefaultsAreExplicitInTheResult() throws {
        try grant(.evidence, days: 30)
        let cal = DayCalendar(TimeZone(identifier: "UTC")!)
        for tool in [MCPTool.getTimeline, .getDayLedger, .getPatterns, .listActivity] {
            let object = try payload(self.tool(tool, [:]))
            let window = try XCTUnwrap(object["window"]?.objectValue, tool.rawValue)
            let serverNow = try XCTUnwrap(object["serverNow"]?.intValue)
            let today = try cal.dayBounds(cal.dayString(serverNow))
            XCTAssertEqual(window["resolvedFrom"]?.stringValue, "default", tool.rawValue)
            XCTAssertEqual(window["period"]?.stringValue, "today", tool.rawValue)
            XCTAssertEqual(window["start"]?.intValue, today.start, tool.rawValue)
            XCTAssertEqual(window["end"]?.intValue, today.end, tool.rawValue)
        }
        let context = try payload(tool(.getContext, ["max_tokens": .int(300)]))
        let cw = try XCTUnwrap(context["window"]?.objectValue)
        XCTAssertEqual(cw["period"]?.stringValue, "24h")
        XCTAssertEqual(cw["resolvedFrom"]?.stringValue, "default")
        XCTAssertEqual(cw["end"]?.intValue, context["serverNow"]?.intValue, "锚点是现在")
        XCTAssertEqual(try XCTUnwrap(cw["end"]?.intValue) - (try XCTUnwrap(cw["start"]?.intValue)), 86_400_000)
        XCTAssertEqual(context["hours"]?.intValue, 24)
        let recent = try payload(tool(.recentActivity, [:]))
        let rw = try XCTUnwrap(recent["window"]?.objectValue)
        XCTAssertEqual(rw["period"]?.stringValue, "30m")
        XCTAssertEqual(recent["minutes"]?.intValue, 30)
        XCTAssertEqual(rw["end"]?.intValue, recent["serverNow"]?.intValue)

        for (tool, args) in [(MCPTool.search, ["q": JSONValue.string("知识图谱")]),
                             (.getItem, ["app": .string(Self.bundles[0])])] {
            let object = try payload(self.tool(tool, args))
            let window = try XCTUnwrap(object["window"]?.objectValue, tool.rawValue)
            let serverNow = try XCTUnwrap(object["serverNow"]?.intValue)
            XCTAssertEqual(window["resolvedFrom"]?.stringValue, "default", tool.rawValue)
            XCTAssertEqual(window["end"], .null, "\(tool.rawValue)：默认窗口上不封顶")
            XCTAssertEqual(window["start"]?.intValue, serverNow - 30 * 86_400_000, tool.rawValue)
            XCTAssertEqual(object["appliedStart"]?.intValue, serverNow - 30 * 86_400_000, tool.rawValue)
            XCTAssertNil(object["appliedEnd"], tool.rawValue)
        }
        let week = try payload(tool(.getWeekLedger, [:]))
        let ww = try XCTUnwrap(week["window"]?.objectValue)
        XCTAssertEqual(ww["period"]?.stringValue, "this_week")
        XCTAssertEqual(ww["resolvedFrom"]?.stringValue, "default")
        XCTAssertEqual(ww["start"]?.intValue, cal.bucketStart(try XCTUnwrap(week["serverNow"]?.intValue), .week))
    }

    /// 冲突就报错、不猜；老参数（hours / minutes / date / week）还能用且等价于 period。
    func testPeriodConflictsAndLegacyParameters() throws {
        try grant(.evidence)
        let day = dayString(baseTS)
        XCTAssertEqual(tool(.search, ["q": .string("x"), "period": .string("today"),
                                      "start": .int(baseTS)]).error?.code, .badRequest)
        XCTAssertEqual(tool(.getContext, ["hours": .int(2), "period": .string("today")]).error?.code, .badRequest)
        XCTAssertEqual(tool(.recentActivity, ["minutes": .int(5), "start": .int(baseTS)]).error?.code, .badRequest)
        XCTAssertEqual(tool(.getDayLedger, ["date": .string(day), "period": .string("today")]).error?.code, .badRequest)
        XCTAssertEqual(tool(.getWeekLedger, ["week": .string(day), "period": .string("this_week")]).error?.code, .badRequest)
        XCTAssertEqual(tool(.getDayLedger, ["period": .string("3d")]).error?.code, .badRequest, "日台账只认单日")
        XCTAssertEqual(tool(.getDayLedger, ["period": .string("2026-09-01..2026-09-03")]).error?.code, .badRequest)
        XCTAssertEqual(tool(.getWeekLedger, ["period": .string("24h")]).error?.code, .badRequest, "周台账只认整周或周内某天")
        XCTAssertEqual(tool(.getTimeline, ["start": .int(baseTS)]).error?.code, .badRequest, "时间线要有上界")
        XCTAssertEqual(tool(.listActivity, ["period": .string("nonsense")]).error?.code, .badRequest)
        XCTAssertEqual(tool(.listActivity, ["before_id": .int(0)]).error?.code, .badRequest)
        XCTAssertEqual(tool(.getDayLedger, ["date": .string("2026-13-99")]).error?.code, .badRequest)

        let legacy = try payload(tool(.getContext, ["hours": .int(2), "max_tokens": .int(300)]))
        let lw = try XCTUnwrap(legacy["window"]?.objectValue)
        XCTAssertEqual(lw["period"]?.stringValue, "2h")
        XCTAssertEqual(lw["resolvedFrom"]?.stringValue, "period")
        XCTAssertEqual(try XCTUnwrap(lw["end"]?.intValue) - (try XCTUnwrap(lw["start"]?.intValue)), 7_200_000)
        XCTAssertEqual(legacy["hours"]?.intValue, 2)
        XCTAssertFalse(try XCTUnwrap(legacy["snippets"]?.arrayValue).isEmpty, "一小时前的数据在 2 h 窗口里")

        let legacyDate = try payload(tool(.getDayLedger, ["date": .string(day)]))
        XCTAssertEqual(legacyDate["date"]?.stringValue, day)
        XCTAssertEqual(legacyDate["window"]?["label"]?.stringValue, day)
        let legacyMinutes = try payload(tool(.recentActivity, ["minutes": .int(90), "max_items": .int(2)]))
        XCTAssertEqual(legacyMinutes["minutes"]?.intValue, 90)
        XCTAssertEqual(legacyMinutes["window"]?["period"]?.stringValue, "90m")
        XCTAssertEqual(legacyMinutes["items"]?.arrayValue?.count, 2)
        // 精确边界：裸日期在 end 位置取当天 24:00，于是 start = end = 同一天就是"这一整天"
        let bare = try payload(tool(.getTimeline, ["start": .string(day), "end": .string(day)]))
        let bw = try XCTUnwrap(bare["window"]?.objectValue)
        XCTAssertEqual(bw["resolvedFrom"]?.stringValue, "explicit")
        XCTAssertEqual(try XCTUnwrap(bw["end"]?.intValue) - (try XCTUnwrap(bw["start"]?.intValue)), 86_400_000)
        XCTAssertEqual(bare["buckets"]?.arrayValue?.count, 1)
    }

    /// list_activity 按 before_id 翻页：页与页不重叠、合起来正好是窗口里的全部观察、跨页仍是时间倒序，
    /// 应用聚合与 observations 不随页变；游标指到窗口外时退化成 id < before_id。
    func testListActivityPagesThroughTheWindowWithoutOverlap() throws {
        try grant(.evidence)
        // 30 条观察都在 [baseTS, baseTS + 290 s]；窗口用精确边界钉住，不依赖测试在几点跑。
        let args: [String: JSONValue] = ["start": .int(baseTS), "end": .int(baseTS + 300_000),
                                         "max_items": .int(12)]
        var seen: [Int64] = []
        var timestamps: [Int64] = []
        var cursor: Int64? = nil
        var pages = 0
        repeat {
            var a = args
            if let cursor { a["before_id"] = .int(cursor) }
            let page = try payload(tool(.listActivity, a))
            let items = try XCTUnwrap(page["items"]?.arrayValue)
            XCTAssertEqual(page["observations"]?.intValue, 30)
            XCTAssertEqual(page["window"]?["resolvedFrom"]?.stringValue, "explicit")
            XCTAssertEqual(page["window"]?["start"]?.intValue, baseTS)
            XCTAssertEqual(page["apps"]?.arrayValue?.count, 3, "应用聚合是整个窗口的，不随页变")
            XCTAssertEqual(page["beforeID"]?.intValue, cursor)
            let ids = items.compactMap { $0["evidenceID"]?.intValue }
            let ts = items.compactMap { $0["ts"]?.intValue }
            XCTAssertEqual(ts, ts.sorted(by: >), "最近的在前")
            for item in items {
                XCTAssertLessThanOrEqual(item["summaryTokens"]?.intValue ?? 0,
                                         page["summaryTokenBudget"]?.intValue ?? 0)
            }
            seen += ids
            timestamps += ts
            cursor = page["nextBeforeID"]?.intValue
            if cursor != nil {
                XCTAssertEqual(items.count, 12)
                XCTAssertEqual(page["truncated"]?.boolValue, true)
                XCTAssertEqual(cursor, ids.last, "游标就是本页最后一条")
            } else {
                XCTAssertEqual(page["nextBeforeID"], .null, "键永远在")
                XCTAssertEqual(page["truncated"]?.boolValue, false)
            }
            pages += 1
        } while cursor != nil && pages < 10
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(seen.count, 30)
        XCTAssertEqual(Set(seen).count, 30, "页与页不重叠")
        XCTAssertTrue(timestamps.allSatisfy { $0 >= baseTS && $0 < baseTS + 300_000 })
        XCTAssertEqual(timestamps, timestamps.sorted(by: >), "跨页也保持时间倒序")

        let fallback = try payload(tool(.listActivity,
                                        args.merging(["before_id": .int(Int64.max / 2)]) { _, n in n }))
        XCTAssertEqual(fallback["items"]?.arrayValue?.count, 12)
        XCTAssertNotNil(fallback["nextBeforeID"]?.intValue)
        // 白名单下推：只剩一个应用时 observations 与 apps 都按它算
        try grant(.evidence, apps: [Self.bundles[0]])
        let scoped = try payload(tool(.listActivity, args))
        XCTAssertEqual(scoped["observations"]?.intValue, 10)
        XCTAssertEqual(scoped["apps"]?.arrayValue?.count, 1)
        XCTAssertEqual(scoped["appFilter"]?.arrayValue?.compactMap(\.stringValue), [Self.bundles[0]])
        XCTAssertTrue((scoped["items"]?.arrayValue ?? []).allSatisfy { $0["appBundleID"]?.stringValue == Self.bundles[0] })
    }

    /// get_context 的相对窗口锚在**现在**：库里最新一条观察在一小时前时，「最近 30 分钟」就是空的、
    /// 窗口右端就是 serverNow。原来锚在最新一条观察上，会把一小时前那段当成"最近"交出去。
    /// 老入口 `Store.getContext(hours:)` 保持老锚点（离线合成库上它是唯一有意义的锚）。
    func testContextAnchorsAtNowNotAtTheLatestObservation() throws {
        try grant(.evidence)
        let context = try payload(tool(.getContext, ["period": .string("30m"), "max_tokens": .int(500)]))
        XCTAssertEqual(context["snippets"]?.arrayValue?.count, 0)
        XCTAssertEqual(context["apps"]?.arrayValue?.count, 0)
        XCTAssertEqual(context["window"]?["end"]?.intValue, context["serverNow"]?.intValue)
        XCTAssertEqual(context["end"]?.intValue, context["serverNow"]?.intValue)

        let legacy = try store.getContext(hours: 1, maxTokens: 500)
        XCTAssertFalse(legacy.snippets.isEmpty)
        XCTAssertEqual(legacy.end, baseTS + 29 * 10_000 + 1, "老口径：右端 = 最新一条观察（含）")
        XCTAssertEqual(legacy.hours, 1)
        let explicit = try store.getContext(start: baseTS, end: baseTS + 300_000, maxTokens: 500)
        XCTAssertEqual(explicit.snippets.count, legacy.snippets.count)
        XCTAssertEqual(explicit.hours, 0, "5 分钟四舍五入到 0 h，只是标签，边界看 start / end")
    }

    // MARK: - 辅助

    private func dayString(_ ts: Int64) -> String {
        DayCalendar(TimeZone(identifier: "UTC")!).dayString(ts)
    }
}
