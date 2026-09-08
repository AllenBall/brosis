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
        ]
        for tool in MCPTool.allCases {
            let response = self.tool(tool, args[tool] ?? [:])
            XCTAssertFalse(response.ok, "\(tool.rawValue) 在没有 grant 时必须被拒")
            XCTAssertEqual(response.error?.code, .noGrant, tool.rawValue)
            XCTAssertNil(response.result, "\(tool.rawValue) 被拒时不能带任何数据")
        }
        let audit = try store.mcpAuditTail(limit: 20)
        XCTAssertEqual(audit.count, MCPTool.allCases.count)
        XCTAssertEqual(audit.count, 9)
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
                       .internalError)   // core 的日期解析报 StoreError

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

    // MARK: - 辅助

    private func dayString(_ ts: Int64) -> String {
        DayCalendar(TimeZone(identifier: "UTC")!).dayString(ts)
    }
}
