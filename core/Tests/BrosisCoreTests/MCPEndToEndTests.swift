import Foundation
import XCTest
@testable import BrosisCore
import BrosisIPC

/// M1 / T5 端到端：**四个真进程**串起来跑一遍整条链路。
///
/// ```text
/// XCTest ── spawn ──▶ python3 core/Tests/mcp_client.py   （只用标准库的 MCP 客户端）
///                          │ stdio：换行分隔 JSON-RPC 2.0
///                          ▼
///                     brosis-mcp                          （薄接口，不持钥、不开库）
///                          │ Unix domain socket：换行分隔 JSON
///                          ▼
///                     brosis-store serve                  （持钥进程，产品路径在 brosis.app 里）
///                          │
///                     SQLCipher 加密库
/// ```
///
/// 对端签名校验：`swift test` 编出来的进程没有 Developer ID，同 Team 校验必然过不去，
/// 所以 serve 那一侧用 `BROSIS_IPC_SKIP_CODESIGN=1` 换成 `.skip`。
/// **这个环境变量只有 `brosis-store serve` 读**（core 的 CLI），
/// `brosis.app` 的 `MCPIPCService` 里策略是写死的 `.requireSameTeam`，没有这个口子。
final class MCPEndToEndTests: XCTestCase {

    private var root: URL!
    private var dataDirectory: URL!
    private var keyFile: URL!
    private var stateFile: URL!
    private var socketURL: URL!
    private var serve: Process?
    private var serveLog: URL!
    /// 合成数据的时间锚点：现在往回一小时。
    private var baseTS: Int64 = 0
    private static let bundles = ["com.apple.Safari", "com.microsoft.VSCode", "com.electron.lark"]
    /// 只出现在长正文尾部（第 200 个字符之外）的标记：摘要里看不到，原文里看得到。
    private static let tailMarker = "尾部标记E2E自检串"

    private var storeBinary: URL!
    private var mcpBinary: URL!
    private var clientScript: URL!

    // MARK: - 起停

    override func setUpWithError() throws {
        storeBinary = try XCTUnwrap(Products.brosisStore, "找不到 brosis-store（先 swift build）")
        mcpBinary = try XCTUnwrap(Products.brosisMCP, "找不到 brosis-mcp（先 swift build）")
        clientScript = try XCTUnwrap(Products.mcpClientScript, "找不到 core/Tests/mcp_client.py")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
                          "本机没有 /usr/bin/python3")

        root = Fixture.testRoot.appendingPathComponent("mcp-e2e-\(UUID().uuidString.prefix(6))",
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dataDirectory = root.appendingPathComponent("db", isDirectory: true)
        keyFile = root.appendingPathComponent("db.key", isDirectory: false)
        stateFile = root.appendingPathComponent("state", isDirectory: false)
        serveLog = root.appendingPathComponent("serve.log", isDirectory: false)
        try "unlocked".write(to: stateFile, atomically: true, encoding: .utf8)

        // socket 放临时目录：sockaddr_un.sun_path 只有 104 字节，测试目录顶得慢。
        let socketDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bt5e-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
        socketURL = socketDir.appendingPathComponent("s.sock", isDirectory: false)

        try seedDatabase()
    }

    override func tearDownWithError() throws {
        stopServer()
        if let socketURL { try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent()) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// 先在**本进程**里把库建好、写好数据、关掉；serve 之后再打开它。
    private func seedDatabase() throws {
        let provider = FileKeyProvider(url: keyFile, createIfMissing: true)
        var options = StoreOptions()
        options.deviceID = "t5-e2e"
        let store = try Store.open(directory: dataDirectory, keyProvider: provider, options: options)
        defer { store.close() }
        store.retrieval.timeZone = TimeZone(identifier: "UTC")!
        baseTS = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        var inputs: [ObservationInput] = []
        for i in 0..<30 {
            let bundle = Self.bundles[i % Self.bundles.count]
            inputs.append(Synth.observation(
                ts: baseTS + Int64(i) * 10_000, bundle: bundle,
                appName: bundle.components(separatedBy: ".").last ?? bundle,
                window: "窗口 \(i % 3)", host: "docs.internal",
                texts: ["段落#\(i) 知识图谱 与 存储服务 的说明，序号 \(i)。"]))
        }
        // 一条**长正文**：`fields = summary` 的摘要口径是 ≤ 100 token（= 200 个字符），
        // 只有正文比它长，"摘要 vs 原文"的差别才验得出来。
        // 尾部标记落在 200 字符之外，摘要里一定看不到它。
        let filler = String(repeating: "长文段落内容填充，", count: 40)   // 360 个字符
        try store.record(batch: [Synth.observation(
            ts: baseTS + 305_000, bundle: Self.bundles[0], appName: "Safari",
            window: "长文窗口", host: "docs.internal",
            texts: ["长文档开头 知识图谱 " + filler + Self.tailMarker])])
        try store.record(batch: inputs)
        _ = try store.buildSessions(force: true)
        try store.checkpoint()
    }

    private func startServer(rate: Int = 60) throws {
        let process = Process()
        process.executableURL = storeBinary
        process.arguments = ["serve",
                             "--dir", dataDirectory.path,
                             "--key-file", keyFile.path,
                             "--socket", socketURL.path,
                             "--state-file", stateFile.path,
                             "--tz", "UTC",
                             "--rate", String(rate),
                             "--seconds", "120",
                             "--verbose"]
        process.environment = ProcessInfo.processInfo.environment
            .merging(["BROSIS_IPC_SKIP_CODESIGN": "1"]) { _, new in new }
        FileManager.default.createFile(atPath: serveLog.path, contents: nil)
        let handle = try FileHandle(forWritingTo: serveLog)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        serve = process

        // 等 socket 出现（服务端 bind 完就有文件了）
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketURL.path) { return }
            if !process.isRunning {
                let log = (try? String(contentsOf: serveLog, encoding: .utf8)) ?? ""
                XCTFail("brosis-store serve 提前退出（\(process.terminationStatus)）：\(log)")
                return
            }
            usleep(50_000)
        }
        XCTFail("等 \(socketURL.lastPathComponent) 超过 15 s")
    }

    private func stopServer() {
        guard let process = serve, process.isRunning else { return }
        process.terminate()                       // SIGTERM → 干净退出（关 socket、关库）
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        // 等 socket 文件消失（serve 退出时会删掉它），必要时兜底删掉。
        // 不等的话，下一次 `startServer` 会把「上一条已经死了的 socket 文件」
        // 当成「新服务端起来了」，客户端连上去只会拿到 ECONNREFUSED。
        while FileManager.default.fileExists(atPath: socketURL.path) && Date() < deadline {
            usleep(20_000)
        }
        try? FileManager.default.removeItem(at: socketURL)
        serve = nil
    }

    private func setState(_ state: String) throws {
        try state.write(to: stateFile, atomically: true, encoding: .utf8)
    }

    // MARK: - 跑一次 MCP 会话

    struct MCPStep {
        var tool: String
        var isError: Bool
        var text: String
        var payload: [String: Any]?
    }

    struct MCPRun {
        var toolNames: [String]
        var serverName: String
        var protocolVersion: String
        var steps: [MCPStep]
        var reportPath: String
        var transcriptPath: String
    }

    /// 在第 `index` 次调用之前停下来：先建 `reached`，再等 `go` 出现。
    /// 中间这段时间连接是闲置的，调用方可以把服务端停掉 / 重启。
    struct MCPGateFile {
        var index: Int
        var reached: URL
        var go: URL
    }

    /// 一条 MCP 会话的命令行与产物路径。
    private func mcpInvocation(client: String, calls: [(String, [String: Any])],
                               label: String, gate: MCPGateFile?) throws
        -> (arguments: [String], report: URL, transcript: URL) {
        let reportURL = root.appendingPathComponent("\(label)-report.json", isDirectory: false)
        let transcriptURL = root.appendingPathComponent("\(label)-transcript.json", isDirectory: false)
        var arguments = ["python3", clientScript.path,
                         "--bin", mcpBinary.path,
                         "--env", "BROSIS_IPC_SOCKET=\(socketURL.path)",
                         "--client-name", client,
                         "--out", reportURL.path,
                         "--transcript", transcriptURL.path,
                         "--stderr", root.appendingPathComponent("\(label)-mcp.err").path]
        if let gate {
            arguments += ["--gate", "\(gate.index),\(gate.reached.path),\(gate.go.path)"]
        }
        for (tool, args) in calls {
            let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
            arguments += ["--call", tool, String(decoding: data, as: UTF8.self)]
        }
        return (arguments, reportURL, transcriptURL)
    }

    /// 把客户端写的 JSON 报告读成断言好用的形状。
    private func parseMCPReport(report reportURL: URL, transcript transcriptURL: URL) throws -> MCPRun {
        let report = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: reportURL)) as? [String: Any] ?? [:]
        XCTAssertNil(report["error"], "MCP 会话出错：\(report["error"] ?? "")")
        let initialize = (report["initialize"] as? [String: Any])?["result"] as? [String: Any] ?? [:]
        let steps = (report["steps"] as? [[String: Any]] ?? []).map { step in
            MCPStep(tool: step["tool"] as? String ?? "?",
                    isError: step["is_error"] as? Bool ?? false,
                    text: step["text"] as? String ?? "",
                    payload: step["payload"] as? [String: Any])
        }
        return MCPRun(
            toolNames: report["tool_names"] as? [String] ?? [],
            serverName: ((initialize["serverInfo"] as? [String: Any])?["name"] as? String) ?? "",
            protocolVersion: initialize["protocolVersion"] as? String ?? "",
            steps: steps,
            reportPath: reportURL.path, transcriptPath: transcriptURL.path)
    }

    /// 拉起 `python3 mcp_client.py`（它自己再拉起 `brosis-mcp`），走完 initialize → tools/list → N 次 tools/call。
    @discardableResult
    private func runMCP(client: String, calls: [(String, [String: Any])],
                        label: String = "run") throws -> MCPRun {
        let (arguments, reportURL, transcriptURL) =
            try mcpInvocation(client: client, calls: calls, label: label, gate: nil)
        let result = try Products.run(URL(fileURLWithPath: "/usr/bin/env"), arguments,
                                      environment: ["PYTHONDONTWRITEBYTECODE": "1"])
        XCTAssertEqual(result.status, 0, "MCP 客户端失败：\(result.out)\n\(result.err)")
        return try parseMCPReport(report: reportURL, transcript: transcriptURL)
    }

    /// 同样一条会话，但**不等它跑完**——调用方要在两次调用中间做点事（重启服务端）。
    private func launchMCP(client: String, calls: [(String, [String: Any])],
                           label: String, gate: MCPGateFile) throws
        -> (process: Process, report: URL, transcript: URL) {
        let (arguments, reportURL, transcriptURL) =
            try mcpInvocation(client: client, calls: calls, label: label, gate: gate)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(["PYTHONDONTWRITEBYTECODE": "1"]) { _, new in new }
        let log = root.appendingPathComponent("\(label)-client.log", isDirectory: false)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return (process, reportURL, transcriptURL)
    }

    /// 等一个文件出现（gate 用）。
    private func waitForFile(_ url: URL, seconds: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            usleep(50_000)
        }
        return false
    }

    private func admin(_ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
        try Products.run(mcpBinary, ["admin"] + arguments + ["--socket", socketURL.path])
    }

    private func storeCLI(_ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
        try Products.run(storeBinary,
                         arguments + ["--dir", dataDirectory.path, "--key-file", keyFile.path])
    }

    private func day(_ ts: Int64) -> String {
        DayCalendar(TimeZone(identifier: "UTC")!).dayString(ts)
    }

    /// 每个工具各一次调用（v1 的六个 + M2 / T14 的三个）。
    private var allToolCalls: [(String, [String: Any])] {
        [("search", ["q": "知识图谱", "limit": 3]),
         ("get_evidence", ["ids": [1]]),
         ("get_context", ["hours": 2, "max_tokens": 500]),
         ("get_timeline", ["start": baseTS, "end": baseTS + 3_600_000, "granularity": "hour"]),
         ("get_day_ledger", ["date": day(baseTS)]),
         ("get_item", ["app": Self.bundles[0]]),
         ("get_week_ledger", ["week": day(baseTS)]),
         ("get_patterns", ["start": baseTS - 3_600_000, "end": baseTS + 3_600_000]),
         ("recent_activity", ["minutes": 180, "max_items": 5]),
         ("list_activity", ["period": day(baseTS), "max_items": 5])]
    }

    // MARK: - 1. initialize / tools/list / 没有 grant 全拒

    func testInitializeListsEveryToolAndDeniesEverythingWithoutGrant() throws {
        try startServer()
        let run = try runMCP(client: "claude-code", calls: allToolCalls, label: "no-grant")

        XCTAssertEqual(run.serverName, "brosis")
        XCTAssertEqual(run.protocolVersion, "2025-06-18")
        XCTAssertEqual(run.toolNames, ["get_context", "get_day_ledger", "get_evidence",
                                       "get_item", "get_patterns", "get_timeline",
                                       "get_week_ledger", "list_activity", "recent_activity",
                                       "search"])
        XCTAssertEqual(run.steps.count, 10)
        for step in run.steps {
            XCTAssertTrue(step.isError, "\(step.tool) 在没有 grant 时必须报错")
            XCTAssertTrue(step.text.contains("no_grant"), step.tool)
            XCTAssertTrue(step.text.contains("admin grant add"), "错误里要告诉用户怎么授权")
            XCTAssertFalse(step.text.contains("知识图谱 与 存储服务"), "被拒时不能漏出正文")
        }

        // tools/list 的 readOnlyHint（3.6：只是提示，不是隔离；真正的只读在服务端）
        let listed = try JSONSerialization.jsonObject(
            with: try Data(contentsOf: URL(fileURLWithPath: run.reportPath))) as? [String: Any] ?? [:]
        let tools = ((listed["tools_list"] as? [String: Any])?["result"] as? [String: Any])?["tools"]
            as? [[String: Any]] ?? []
        XCTAssertEqual(tools.count, 10)
        for tool in tools {
            let annotations = tool["annotations"] as? [String: Any] ?? [:]
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true, "\(tool["name"] ?? "?")")
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any], "\(tool["name"] ?? "?")")
        }

        // 审计：十条 no_grant
        let audit = try storeCLI(["mcp-audit", "--limit", "20"])
        XCTAssertEqual(audit.status, 0, audit.err)
        XCTAssertEqual(audit.out.components(separatedBy: "\"no_grant\"").count - 1, 10, audit.out)
    }

    // MARK: - 1b. M2 的三个工具走完整条链路（M2 c / T14）

    /// 四个真进程（XCTest → python3 客户端 → `brosis-mcp` → `brosis-store serve`）上，
    /// `get_week_ledger` / `get_patterns` / `recent_activity` 各真实调用一次。
    func testM2ToolsThroughMCP() throws {
        try startServer()
        XCTAssertEqual(try admin(["grant", "add", "--client", "claude-code",
                                  "--fields", "evidence", "--apps", "*",
                                  "--time-window", "30"]).status, 0)

        let run = try runMCP(client: "claude-code", calls: [
            ("get_week_ledger", ["week": day(baseTS)]),
            ("get_patterns", ["start": baseTS - 3_600_000, "end": baseTS + 3_600_000]),
            ("recent_activity", ["minutes": 180, "max_items": 5]),
        ], label: "m2-tools")
        XCTAssertEqual(run.steps.count, 3)
        for step in run.steps { XCTAssertFalse(step.isError, "\(step.tool)：\(step.text)") }

        // ① 周台账：包含 baseTS 那一天，7 天的按天分布都在，narrative 是 null（3.7）
        let week = try XCTUnwrap(run.steps[0].payload)
        XCTAssertEqual((week["days"] as? [String])?.count, 7)
        XCTAssertTrue((week["days"] as? [String] ?? []).contains(day(baseTS)))
        XCTAssertEqual((week["dayTotals"] as? [[String: Any]])?.count, 7)
        XCTAssertGreaterThan((week["observations"] as? Int) ?? 0, 0)
        XCTAssertNil(week["narrative"] as? String, "3.7：台账与叙述分开标注")
        XCTAssertNotNil(week["grant"])

        // ② 活动模式：热力格子非空，且把算它用到的常量一起回来了
        let patterns = try XCTUnwrap(run.steps[1].payload)
        XCTAssertGreaterThan((patterns["heatmap"] as? [[String: Any]])?.count ?? 0, 0)
        XCTAssertEqual((patterns["byHour"] as? [[String: Any]])?.count, 24)
        XCTAssertEqual((patterns["byWeekday"] as? [[String: Any]])?.count, 7)
        XCTAssertNotNil(patterns["options"])
        XCTAssertNotNil(patterns["sessionConfig"])
        XCTAssertEqual((patterns["focus"] as? [String: Any])?["minMinutes"] as? Double, 25)

        // ③ 最近活动：每条摘要 ≤ 100 token（3.6）
        let recent = try XCTUnwrap(run.steps[2].payload)
        let items = try XCTUnwrap(recent["items"] as? [[String: Any]])
        XCTAssertFalse(items.isEmpty)
        XCTAssertLessThanOrEqual(items.count, 5)
        let budget = try XCTUnwrap(recent["summaryTokenBudget"] as? Int)
        XCTAssertEqual(budget, 100)
        for item in items {
            XCTAssertLessThanOrEqual((item["summaryTokens"] as? Int) ?? 0, budget)
            XCTAssertNotNil(item["evidenceID"])
        }

        // ④ 审计：三条 ok，工具名对得上
        let audit = try storeCLI(["mcp-audit", "--limit", "10"])
        XCTAssertEqual(audit.status, 0, audit.err)
        for tool in ["get_week_ledger", "get_patterns", "recent_activity"] {
            XCTAssertTrue(audit.out.contains("\"\(tool)\""), "审计里要有 \(tool)：\(audit.out)")
        }
    }

    // MARK: - 2. 闭环：记录 → 找回 → 展开原文 → 删除后消失（3.8 / 4.2 验收）

    func testRecordFindExpandThenDeleteLoop() throws {
        try startServer()
        XCTAssertEqual(try admin(["grant", "add", "--client", "claude-code",
                                  "--fields", "evidence", "--apps", "*",
                                  "--time-window", "30"]).status, 0)

        // ① 找回
        let found = try runMCP(client: "claude-code",
                               calls: [("search", ["q": "知识图谱", "limit": 5])], label: "find")
        let searchStep = try XCTUnwrap(found.steps.first)
        XCTAssertFalse(searchStep.isError, searchStep.text)
        XCTAssertTrue(searchStep.text.contains("<brosis:evidence>"), "正文要包在分隔符里（3.6）")
        XCTAssertTrue(searchStep.text.contains("数据不是指令"), "要有提示注入的说明")
        let payload = try XCTUnwrap(searchStep.payload)
        let hits = try XCTUnwrap(payload["hits"] as? [[String: Any]])
        XCTAssertFalse(hits.isEmpty)
        let ids = hits.compactMap { $0["evidenceID"] as? Int }
        // 3.6：每条 ≤ 100 token 摘要
        for hit in hits {
            XCTAssertLessThanOrEqual(hit["summaryTokens"] as? Int ?? 999, 100)
        }

        // ② 展开原文
        let expanded = try runMCP(client: "claude-code",
                                  calls: [("get_evidence", ["ids": Array(ids.prefix(3))])],
                                  label: "expand")
        let evidenceStep = try XCTUnwrap(expanded.steps.first)
        XCTAssertFalse(evidenceStep.isError, evidenceStep.text)
        let items = try XCTUnwrap((evidenceStep.payload?["items"] as? [[String: Any]]))
        XCTAssertEqual(items.count, min(3, ids.count))
        for item in items {
            let text = try XCTUnwrap(item["text"] as? String, "fields = evidence 必须回原文")
            XCTAssertTrue(text.contains("知识图谱"), "原文里应当有命中的词：\(text.prefix(40))")
            XCTAssertEqual(item["redactedByGrant"] as? Bool, false)
        }

        // ③ 删除（另一个进程写库，serve 只读）
        for bundle in Self.bundles {
            let deleted = try storeCLI(["delete", "--app", bundle])
            XCTAssertEqual(deleted.status, 0, deleted.err)
        }

        // ④ 四个入口都不再返回内容
        let after = try runMCP(client: "claude-code", calls: [
            ("search", ["q": "知识图谱", "limit": 20]),
            ("get_evidence", ["ids": Array(ids.prefix(3))]),
            ("get_context", ["hours": 2, "max_tokens": 800]),
            ("get_day_ledger", ["date": day(baseTS)]),
        ], label: "deleted")
        XCTAssertEqual(after.steps.count, 4)
        for step in after.steps {
            XCTAssertFalse(step.isError, "\(step.tool)：\(step.text)")
            // 正文里的两个特征串一个都不能再出现（查询串本身会在 query 字段里回显，不能拿它当判据）
            XCTAssertFalse(step.text.contains("的说明，序号"), "\(step.tool) 删除后还能看到正文")
            XCTAssertFalse(step.text.contains(Self.tailMarker), "\(step.tool) 删除后还能看到长正文")
        }
        XCTAssertEqual((after.steps[0].payload?["hits"] as? [Any])?.count, 0)
        XCTAssertEqual((after.steps[1].payload?["items"] as? [Any])?.count, 0)
        XCTAssertEqual((after.steps[1].payload?["missing"] as? [Any])?.count, min(3, ids.count))
        XCTAssertEqual((after.steps[2].payload?["snippets"] as? [Any])?.count, 0)
        XCTAssertEqual(after.steps[3].payload?["observations"] as? Int, 0)
    }

    // MARK: - 3. fields = summary 不回原文

    func testSummaryGrantDoesNotLeakRawTextThroughMCP() throws {
        try startServer()
        XCTAssertEqual(try admin(["grant", "add", "--client", "claude-code",
                                  "--fields", "summary"]).status, 0)
        let run = try runMCP(client: "claude-code", calls: [
            ("search", ["q": "长文档开头", "limit": 3]),
        ], label: "summary")
        let search = try XCTUnwrap(run.steps.first)
        XCTAssertFalse(search.isError, search.text)
        let hits = try XCTUnwrap(search.payload?["hits"] as? [[String: Any]])
        let longID = try XCTUnwrap(hits.first?["evidenceID"] as? Int)
        // search 的摘要本来就只有 ≤ 100 token，长正文的尾巴看不到
        XCTAssertFalse(search.text.contains(Self.tailMarker),
                       "search 的摘要不该带出正文尾部（3.6：每条 ≤ 100 token）")

        let redacted = try runMCP(client: "claude-code",
                                  calls: [("get_evidence", ["ids": [longID]])], label: "summary2")
        let evidence = try XCTUnwrap(redacted.steps.first)
        XCTAssertFalse(evidence.isError, evidence.text)
        XCTAssertEqual(evidence.payload?["redacted"] as? Bool, true)
        let items = try XCTUnwrap(evidence.payload?["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        for item in items {
            XCTAssertNil(item["text"], "fields = summary 不能回原文")
            XCTAssertEqual(item["redactedByGrant"] as? Bool, true)
            for occurrence in item["occurrences"] as? [[String: Any]] ?? [] {
                XCTAssertNil(occurrence["text"])
            }
            // 摘要还是要有的（3.6：summary 档给摘要），但必须在 100 token 以内
            let summary = try XCTUnwrap(item["summary"] as? String)
            XCTAssertFalse(summary.isEmpty)
            XCTAssertLessThanOrEqual(TokenBudget.tokens(of: summary), 100)
        }
        XCTAssertFalse(evidence.text.contains(Self.tailMarker),
                       "fields = summary 时正文尾部不能出现在响应里")

        // 换成 evidence 之后，同一个 id 就回原文了（尾部标记出现）
        XCTAssertEqual(try admin(["grant", "add", "--client", "claude-code",
                                  "--fields", "evidence"]).status, 0)
        let full = try runMCP(client: "claude-code",
                              calls: [("get_evidence", ["ids": [longID]])], label: "summary3")
        let fullStep = try XCTUnwrap(full.steps.first)
        XCTAssertTrue(fullStep.text.contains(Self.tailMarker), "fields = evidence 必须回完整原文")
        XCTAssertEqual((fullStep.payload?["items"] as? [[String: Any]])?.first?["redactedByGrant"]
                        as? Bool, false)
    }

    // MARK: - 4. 应用白名单与时间窗

    func testWhitelistAndTimeWindowThroughMCP() throws {
        try startServer()
        XCTAssertEqual(try admin(["grant", "add", "--client", "claude-code",
                                  "--fields", "evidence",
                                  "--apps", Self.bundles[0],
                                  "--time-window", "30"]).status, 0)
        let run = try runMCP(client: "claude-code", calls: [
            ("search", ["q": "知识图谱", "limit": 30]),
            ("get_item", ["app": Self.bundles[1]]),
            ("get_day_ledger", ["date": day(baseTS - 365 * 86_400_000)]),
        ], label: "scoped")

        let search = run.steps[0]
        XCTAssertFalse(search.isError, search.text)
        let bundles = (search.payload?["hits"] as? [[String: Any]] ?? [])
            .compactMap { $0["appBundleID"] as? String }
        XCTAssertFalse(bundles.isEmpty)
        XCTAssertEqual(Set(bundles), [Self.bundles[0]])
        let grant = try XCTUnwrap(search.payload?["grant"] as? [String: Any])
        XCTAssertEqual(grant["filteredByGrant"] as? Bool, true)

        XCTAssertTrue(run.steps[1].isError, "白名单外的应用要被拒")
        XCTAssertTrue(run.steps[1].text.contains("denied_by_grant"))

        XCTAssertTrue(run.steps[2].isError, "时间窗外的日期要被拒")
        XCTAssertTrue(run.steps[2].text.contains("denied_by_grant"))

        // get_evidence 的**出现上下文**也要按白名单裁：before / after 带 bundle id 与窗口标题，
        // 漏一条就等于绕过白名单（M1 第一轮验收在这条真链路上抓到过 4 个白名单外的应用）。
        let ids = (search.payload?["hits"] as? [[String: Any]] ?? [])
            .compactMap { $0["evidenceID"] as? Int }.sorted()
        let middle = try XCTUnwrap(ids.dropFirst().first, "要挑一条前后都有邻居的观察")
        let expand = try runMCP(client: "claude-code", calls: [
            ("get_evidence", ["ids": [middle], "neighbors": 3]),
        ], label: "scoped_evidence")
        let evidence = expand.steps[0]
        XCTAssertFalse(evidence.isError, evidence.text)
        let items = (evidence.payload?["items"] as? [[String: Any]]) ?? []
        let around = ((items.first?["before"] as? [[String: Any]]) ?? [])
                   + ((items.first?["after"] as? [[String: Any]]) ?? [])
        XCTAssertFalse(around.isEmpty, "这条观察前后应当有白名单内的邻居")
        XCTAssertEqual(Set(around.compactMap { $0["appBundleID"] as? String }), [Self.bundles[0]])
        for outside in Self.bundles.dropFirst() {
            XCTAssertFalse(evidence.text.contains(outside),
                           "整段响应里都不该出现白名单外的 bundle id：\(outside)")
        }
    }

    // MARK: - 5. 锁定 / 暂停（3.5）

    func testLockedAndPausedRejectAndAuditIsFlushed() throws {
        try startServer()
        XCTAssertEqual(try admin(["grant", "add", "--client", "claude-code",
                                  "--fields", "evidence"]).status, 0)

        try setState("locked")
        let locked = try runMCP(client: "claude-code",
                                calls: [("search", ["q": "知识图谱"])], label: "locked")
        XCTAssertTrue(locked.steps[0].isError)
        XCTAssertTrue(locked.steps[0].text.contains("[locked]"), locked.steps[0].text)
        XCTAssertTrue(locked.steps[0].text.contains("锁定"), locked.steps[0].text)

        try setState("paused")
        let paused = try runMCP(client: "claude-code",
                                calls: [("search", ["q": "知识图谱"])], label: "paused")
        XCTAssertTrue(paused.steps[0].isError)
        XCTAssertTrue(paused.steps[0].text.contains("[paused]"), paused.steps[0].text)

        try setState("unlocked")
        let ok = try runMCP(client: "claude-code",
                            calls: [("search", ["q": "知识图谱"])], label: "unlocked")
        XCTAssertFalse(ok.steps[0].isError, ok.steps[0].text)

        // 锁定期间那条审计是攒在内存里、解锁后补写的（MCPGate）
        let audit = try storeCLI(["mcp-audit", "--limit", "20"])
        XCTAssertEqual(audit.status, 0, audit.err)
        XCTAssertTrue(audit.out.contains("\"locked\""), "锁定期间被拒的调用也要留审计：\(audit.out)")
        XCTAssertTrue(audit.out.contains("\"paused\""), audit.out)
    }

    // MARK: - 6. 限流（2.2 硬约束 4）

    func testRateLimitThroughMCP() throws {
        try startServer(rate: 3)
        XCTAssertEqual(try admin(["grant", "add", "--client", "claude-code",
                                  "--fields", "evidence"]).status, 0)
        // 一条 MCP 会话里连发 5 次：前 3 次放行，后 2 次被限流
        let calls = (0..<5).map { _ in ("search", ["q": "知识图谱", "limit": 1] as [String: Any]) }
        let run = try runMCP(client: "claude-code", calls: calls, label: "rate")
        XCTAssertEqual(run.steps.count, 5)
        XCTAssertFalse(run.steps[0].isError)
        XCTAssertFalse(run.steps[1].isError)
        XCTAssertFalse(run.steps[2].isError)
        for i in 3..<5 {
            XCTAssertTrue(run.steps[i].isError, "第 \(i + 1) 次应该被限流")
            XCTAssertTrue(run.steps[i].text.contains("rate_limited"), run.steps[i].text)
            XCTAssertFalse(run.steps[i].text.contains("evidenceID"), "被限流时不能带任何数据")
        }
        // 换个 client_id 就是另一份配额——但它没有 grant，照样一个字都拿不到
        let other = try runMCP(client: "another-client",
                               calls: [("search", ["q": "知识图谱"])], label: "rate-other")
        XCTAssertTrue(other.steps[0].isError)
        XCTAssertTrue(other.steps[0].text.contains("no_grant"), other.steps[0].text)

        let audit = try storeCLI(["mcp-audit", "--limit", "20"])
        XCTAssertTrue(audit.out.contains("\"rate_limited\""), audit.out)
    }

    // MARK: - 7. admin 与审计内容

    func testAdminCommandsAndAuditShape() throws {
        try startServer()
        let empty = try admin(["grant", "list"])
        XCTAssertEqual(empty.status, 0, empty.err)
        XCTAssertTrue(empty.out.contains("\"count\" : 0"), empty.out)

        XCTAssertEqual(try admin(["grant", "add", "--client", "claude-code",
                                  "--mode", "remote_allowed", "--fields", "evidence",
                                  "--apps", "\(Self.bundles[0]),\(Self.bundles[1])",
                                  "--time-window", "14"]).status, 0)
        let listed = try admin(["grant", "list"])
        XCTAssertTrue(listed.out.contains("remote_allowed"), listed.out)
        XCTAssertTrue(listed.out.contains("无法技术上验证"), "strict_local 的口径要如实写出来")

        let status = try admin(["status"])
        XCTAssertTrue(status.out.contains("\"schemaVersion\" : \(Schema.version)"), status.out)

        _ = try runMCP(client: "claude-code",
                       calls: [("search", ["q": "知识图谱", "limit": 2])], label: "audit")

        let tail = try admin(["audit", "--limit", "5"])
        XCTAssertEqual(tail.status, 0, tail.err)
        XCTAssertTrue(tail.out.contains("\"tool\" : \"search\""), tail.out)
        XCTAssertTrue(tail.out.contains("q_sha="), tail.out)
        XCTAssertFalse(tail.out.contains("知识图谱"), "审计里不能出现查询串本身：\(tail.out)")
        XCTAssertTrue(tail.out.contains("uid=\(getuid())"), tail.out)

        XCTAssertEqual(try admin(["grant", "remove", "--client", "claude-code"]).status, 0)
        XCTAssertTrue(try admin(["grant", "list"]).out.contains("\"count\" : 0"))
    }

    // MARK: - 8. 连不上时的行为

    func testMCPReportsClearErrorWhenServerIsAbsent() throws {
        // 不起 serve，直接跑客户端
        let run = try runMCP(client: "claude-code",
                             calls: [("search", ["q": "知识图谱"])], label: "no-server")
        XCTAssertEqual(run.toolNames.count, 10, "连不上服务端也要能 tools/list（清单是本地的）")
        XCTAssertTrue(run.steps[0].isError)
        XCTAssertTrue(run.steps[0].text.contains("连不上"), run.steps[0].text)
        XCTAssertTrue(run.steps[0].text.contains("brosis.app"), run.steps[0].text)
    }

    // MARK: - 9. 连接层的抗打击：对端提前挂断、服务端重启

    /// 客户端**发完请求就挂断、不读响应**，持钥的那个进程不能因此死掉。
    ///
    /// 产品路径上这个服务端就在 `brosis.app` 里，被打死意味着采集和锁定状态机一起没。
    /// 这里用真进程（`brosis-store serve`）复现，因为这正是本轮验收发现的问题：
    /// 修之前 serve 被信号 13（SIGPIPE）干掉，退出码 -13。
    func testServeSurvivesClientHangUpMidRequest() throws {
        try startServer()
        XCTAssertEqual(try admin(["grant", "add", "--client", "claude-code",
                                  "--fields", "evidence"]).status, 0)
        let process = try XCTUnwrap(serve)

        for i in 0..<3 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(fd, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketURL.path.utf8)
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: bytes); raw[bytes.count] = 0
            }
            addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            XCTAssertEqual(connected, 0)
            // 要一份**大**结果：服务端那一侧写得越久，越贴近"用户按了取消"的真实时序。
            let line = try IPCCodec.line(IPCRequest(
                client: "claude-code", op: .tool, name: "search",
                args: ["q": .string("知识图谱"), "limit": .int(20)]))
            _ = line.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
            Darwin.close(fd)                      // 不读响应，直接挂断
            usleep(400_000)
            XCTAssertTrue(process.isRunning,
                          "第 \(i + 1) 次挂断之后 brosis-store serve 没了"
                          + "（退出码 \(process.terminationStatus)，-13 = SIGPIPE）")
        }

        // 确认真的撞上了写失败——否则这个用例什么都没验到
        let log = (try? String(contentsOf: serveLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("ipc_write_error"),
                      "serve 日志里没有 ipc_write_error，说明没验到对端挂断：\(log)")

        // 挂断只该掐掉那一条连接：服务端照常服务
        let run = try runMCP(client: "claude-code",
                             calls: [("search", ["q": "知识图谱", "limit": 2])], label: "after-hangup")
        XCTAssertFalse(run.steps[0].isError, run.steps[0].text)
    }

    /// 收到 SIGTERM 时 `serve` 要走完收尾：删掉 socket 文件、checkpoint、关库、清零密钥。
    ///
    /// 修之前它在信号队列上直接 `SIGTRAP`（退出码 133）：Swift 6 语言模式下 `main.swift`
    /// 顶层代码是 `@MainActor` 隔离的，`setEventHandler` 的闭包跟着带上隔离检查，
    /// libdispatch 在自己的队列上调它就 `dispatch_assert_queue` 失败。
    /// 后果是收尾一行都没跑到——socket 文件留在原地，下一次起来的客户端会连到一个死文件上
    /// （ECONNREFUSED）。
    func testServeShutsDownCleanlyOnSIGTERM() throws {
        try startServer()
        let process = try XCTUnwrap(serve)

        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        XCTAssertFalse(process.isRunning, "SIGTERM 之后 5 s 还没退出")
        XCTAssertEqual(process.terminationReason, .exit,
                       "被信号打死了，收尾没跑（terminationStatus = \(process.terminationStatus)，"
                       + "133 - 128 = 5 = SIGTRAP）")
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path),
                       "退出时要把 ipc.sock 删掉")
        let log = (try? String(contentsOf: serveLog, encoding: .utf8)) ?? ""
        XCTAssertTrue(log.contains("\"stopped\" : true"), "没跑到收尾那一行：\(log)")
        serve = nil
    }

    /// `brosis.app` **退出 / 重启 / 崩溃**时 `IPCServer.stop()` 会对每条存活连接
    /// `shutdown(SHUT_RDWR)`，而 Claude Code 那侧的 `brosis-mcp` 是长期挂着的。
    /// 一个长时间挂着的会话必须扛得过这个循环：`brosis-mcp` 不能死，
    /// 下一次 `tools/call` 要自己重连上来。
    ///
    /// （**不包括锁定**：`LockController.beginLock()` 只调 `ipc.detach()`，socket 与既有连接
    /// 都留着，客户端拿到的是 `[locked]` 响应——那条路径由本文件的
    /// `testLockedAndPausedRejectAndAuditIsFlushed`（服务端一直跑着，只切状态文件）
    /// 与 `MCPServiceTests.testGateRefusesWhenLockedAndFlushesAuditAfterUnlock` 覆盖。）
    func testMCPSurvivesServerRestartMidSession() throws {
        try startServer()
        XCTAssertEqual(try admin(["grant", "add", "--client", "claude-code",
                                  "--fields", "evidence"]).status, 0)

        let reached = root.appendingPathComponent("gate-reached", isDirectory: false)
        let go = root.appendingPathComponent("gate-go", isDirectory: false)
        let calls: [(String, [String: Any])] = [
            ("search", ["q": "知识图谱", "limit": 2]),
            ("search", ["q": "知识图谱", "limit": 2]),
        ]
        let session = try launchMCP(client: "claude-code", calls: calls, label: "restart",
                                    gate: MCPGateFile(index: 1, reached: reached, go: go))
        defer { if session.process.isRunning { session.process.terminate() } }

        XCTAssertTrue(waitForFile(reached), "MCP 客户端没跑到 gate")
        // = brosis.app 退出（IPCServer.stop()：关监听、shutdown 存活连接、删 socket）→ 重新启动并解锁
        stopServer()
        try startServer()
        FileManager.default.createFile(atPath: go.path, contents: nil)

        session.process.waitUntilExit()
        XCTAssertEqual(session.process.terminationStatus, 0,
                       "MCP 客户端退出码 \(session.process.terminationStatus)："
                       + "brosis-mcp 多半死在服务端重启上了（SIGPIPE）")
        let run = try parseMCPReport(report: session.report, transcript: session.transcript)
        XCTAssertEqual(run.steps.count, 2)
        // brosis-mcp 死在半路时报告里就只有第一步。上面几条断言已经把原因说清楚了，
        // 这里直接收工——再往下索引会越界崩掉整个测试进程，把别的用例一起带走。
        guard run.steps.count == 2 else { return }
        XCTAssertFalse(run.steps[0].isError, run.steps[0].text)
        XCTAssertFalse(run.steps[1].isError,
                       "服务端重启之后这次调用应该自己重连成功：\(run.steps[1].text)")
        XCTAssertTrue(run.steps[1].text.contains("evidenceID"), run.steps[1].text)
    }
}
