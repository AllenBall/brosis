import BrosisCore
import Foundation

/// MCP 集成的自检（D33）。**全程不碰任何真实配置文件**：
/// `MCPConfigWriter` 是纯函数，输入文本输出文本，这里拿写死的样本跑边界。
enum MCPIntegrationSelfCheck {

    static func run() -> Int {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("[\(ok ? "PASS" : "FAIL")] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        let entry = MCPConfigWriter.Entry(name: "brosis", command: "/Applications/brosis.app/Contents/MacOS/brosis-mcp")

        // ---- 描述表本身
        let ids = HarnessCatalog.all.map(\.id)
        check("harness 描述表：6 个、id 不重复、路径都是用户级",
              ids.count == 6 && Set(ids).count == 6
                && HarnessCatalog.all.allSatisfy { !$0.configPath.hasPrefix("/") && !$0.configPath.isEmpty },
              ids.joined(separator: " "))
        check("服务器路径指向本 bundle 里的 brosis-mcp",
              HarnessCatalog.serverCommand().hasSuffix("Contents/MacOS/brosis-mcp"),
              HarnessCatalog.serverCommand())

        // ---- 标准 mcpServers JSON
        var cases: [String] = []
        do {
            // 空文件 → 建出来
            let added = try MCPConfigWriter.apply(format: .mcpServersJSON, text: "",
                                                  entry: entry, enabled: true) ?? ""
            let back = try MCPConfigWriter.current(format: .mcpServersJSON, text: added, name: "brosis").command
            check("JSON：空文件写入后读得回来", back == entry.command, back ?? "nil")

            // 幂等：再写一次不产生改动
            let again = try MCPConfigWriter.apply(format: .mcpServersJSON, text: added,
                                                 entry: entry, enabled: true)
            check("JSON：已经是目标状态时不改文件（幂等）", again == nil,
                  again == nil ? "返回 nil" : "又写了一遍")

            // 别人的服务器必须原样保留
            let others = """
            {"mcpServers":{"other":{"command":"/bin/echo","args":["hi"]}},"unrelatedTopLevel":42}
            """
            let merged = try MCPConfigWriter.apply(format: .mcpServersJSON, text: others,
                                                  entry: entry, enabled: true) ?? ""
            let mergedObject = try JSONSerialization.jsonObject(with: Data(merged.utf8)) as? [String: Any]
            let servers = mergedObject?["mcpServers"] as? [String: Any]
            check("JSON：只加自己那一项，别人的服务器与无关顶层键都留着",
                  servers?.count == 2 && servers?["other"] != nil
                    && (mergedObject?["unrelatedTopLevel"] as? Int) == 42,
                  "servers=\(servers?.keys.sorted() ?? [])")

            // 关掉：只删自己
            let removed = try MCPConfigWriter.apply(format: .mcpServersJSON, text: merged,
                                                   entry: entry, enabled: false) ?? ""
            let afterObject = try JSONSerialization.jsonObject(with: Data(removed.utf8)) as? [String: Any]
            let afterServers = afterObject?["mcpServers"] as? [String: Any]
            check("JSON：关掉只删自己那一项", afterServers?.count == 1 && afterServers?["other"] != nil,
                  "剩 \(afterServers?.keys.sorted() ?? [])")

            // 没装时关掉 = 不动文件
            let noop = try MCPConfigWriter.apply(format: .mcpServersJSON, text: removed,
                                                entry: entry, enabled: false)
            check("JSON：本来就没有时关掉不动文件", noop == nil)
            cases.append("JSON 5 条")
        } catch {
            check("JSON 用例跑完", false, "\(error)")
        }

        // ---- 坏 JSON 必须抛错而不是猜着写
        do {
            _ = try MCPConfigWriter.apply(format: .mcpServersJSON,
                                          text: "{ \"mcpServers\": { // 注释\n } }",
                                          entry: entry, enabled: true)
            check("坏 JSON（带注释）必须抛错，不能猜着写", false, "居然没抛")
        } catch {
            check("坏 JSON（带注释）必须抛错，不能猜着写", true, "\(error)")
        }

        // ---- ZCode 的嵌套 mcp.servers
        do {
            let text = """
            {"mcp":{"servers":{"memory":{"command":"npx","args":[]}}},"theme":"dark"}
            """
            let added = try MCPConfigWriter.apply(format: .zcodeNestedJSON, text: text,
                                                 entry: entry, enabled: true) ?? ""
            let object = try JSONSerialization.jsonObject(with: Data(added.utf8)) as? [String: Any]
            let servers = (object?["mcp"] as? [String: Any])?["servers"] as? [String: Any]
            check("ZCode：写进 mcp.servers（不是 mcpServers），别的键不动",
                  servers?["brosis"] != nil && servers?["memory"] != nil
                    && (object?["theme"] as? String) == "dark",
                  "servers=\(servers?.keys.sorted() ?? [])")
            let back = try MCPConfigWriter.current(format: .zcodeNestedJSON, text: added, name: "brosis").command
            check("ZCode：读得回来", back == entry.command, back ?? "nil")
            cases.append("ZCode 2 条")
        } catch {
            check("ZCode 用例跑完", false, "\(error)")
        }

        // ---- TOML：逐行手术，原文必须原样保留
        let toml = """
        # 这行注释必须留着
        model = "gpt-5"

        [mcp_servers.node_repl]
        command = "/usr/bin/node"
        args = []

        [mcp_servers.node_repl.env]
        FOO = "bar"
        """
        let addedTOML = (try? MCPConfigWriter.apply(format: .mcpServersTOML, text: toml,
                                                   entry: entry, enabled: true)) ?? nil
        if let addedTOML {
            check("TOML：加自己的节，注释与别人的节原样保留",
                  addedTOML.contains("# 这行注释必须留着")
                    && addedTOML.contains("[mcp_servers.node_repl.env]")
                    && addedTOML.contains("[mcp_servers.brosis]"),
                  "\(addedTOML.count) 字符")
            let back = (try? MCPConfigWriter.current(format: .mcpServersTOML,
                                                     text: addedTOML, name: "brosis"))?.command
            check("TOML：读得回 command", back == entry.command, (back ?? nil) ?? "nil")
            let removedTOML = (try? MCPConfigWriter.apply(format: .mcpServersTOML, text: addedTOML,
                                                         entry: entry, enabled: false)) ?? nil
            check("TOML：关掉只摘自己那节，别人的节与子表都在",
                  removedTOML?.contains("[mcp_servers.brosis]") == false
                    && removedTOML?.contains("[mcp_servers.node_repl]") == true
                    && removedTOML?.contains("[mcp_servers.node_repl.env]") == true
                    && removedTOML?.contains("# 这行注释必须留着") == true,
                  "剩 \(removedTOML?.count ?? -1) 字符")
            // 子表也要一起摘：先造一个带 env 子表的自己
            var withEnv = entry
            withEnv.env = ["A": "1"]
            let addedEnv = (try? MCPConfigWriter.apply(format: .mcpServersTOML, text: toml,
                                                      entry: withEnv, enabled: true)) ?? nil
            let strippedEnv = addedEnv.flatMap {
                (try? MCPConfigWriter.apply(format: .mcpServersTOML, text: $0,
                                            entry: withEnv, enabled: false)) ?? nil
            }
            check("TOML：自己的子表 [mcp_servers.brosis.env] 也一起摘干净",
                  addedEnv?.contains("[mcp_servers.brosis.env]") == true
                    && strippedEnv?.contains("mcp_servers.brosis") == false,
                  strippedEnv == nil ? "没摘成" : "已摘")
            cases.append("TOML 4 条")
        } else {
            check("TOML 用例跑完", false, "apply 返回 nil")
        }

        // ---- 条目里必须钉死 BROSIS_CLIENT_ID（自动授权不靠学习模式就全靠它）
        for harness in HarnessCatalog.all {
            let e = MCPConfigWriter.entry(for: harness, command: "/x/brosis-mcp")
            check("\(harness.id)：条目把 client_id 钉成 harness id",
                  e.env[MCPConfigWriter.clientIDEnvKey] == harness.id,
                  e.env.description)
        }
        let jsonWithEnv = (try? MCPConfigWriter.apply(
            format: .mcpServersJSON, text: "",
            entry: MCPConfigWriter.entry(for: harness("cursor"), command: "/x/brosis-mcp"),
            enabled: true)) ?? nil
        check("写出去的 JSON 里带得上 env", jsonWithEnv?.contains("BROSIS_CLIENT_ID") == true)
        let tomlWithEnv = (try? MCPConfigWriter.apply(
            format: .mcpServersTOML, text: "",
            entry: MCPConfigWriter.entry(for: harness("codex"), command: "/x/brosis-mcp"),
            enabled: true)) ?? nil
        check("写出去的 TOML 里带得上 env 子表",
              tomlWithEnv?.contains("[mcp_servers.brosis.env]") == true
                && tomlWithEnv?.contains("BROSIS_CLIENT_ID") == true)
        // 写进去要读得回来：自动集成靠这个判断"条目是不是老版本写的"。
        check("JSON：钉的 client_id 读得回来",
              (try? MCPConfigWriter.current(format: .mcpServersJSON,
                                            text: jsonWithEnv ?? "", name: "brosis"))?.clientID == "cursor")
        check("TOML：钉的 client_id 读得回来",
              (try? MCPConfigWriter.current(format: .mcpServersTOML,
                                            text: tomlWithEnv ?? "", name: "brosis"))?.clientID == "codex")
        // **节被挪到文件中间也照样读得出来**：判据必须落在这一个键上，不能等价于逐字节比整段
        // 文本，否则 harness 自己重排过配置就会被判成"过期"，于是每 30 分钟重写一次、每次留个备份。
        let reordered = "[mcp_servers.brosis]\ncommand = \"/x/brosis-mcp\"\nargs = []\n\n"
            + "[mcp_servers.brosis.env]\nBROSIS_CLIENT_ID = \"codex\"\n\n"
            + "[mcp_servers.node_repl]\ncommand = \"/usr/bin/node\"\n"
        check("TOML：我们的节被 harness 挪到文件中间，依旧算最新",
              (try? MCPConfigWriter.current(format: .mcpServersTOML,
                                            text: reordered, name: "brosis"))?.clientID == "codex")
        check("没钉 env 的老条目读出来是 nil（自动集成据此补写）",
              (try? MCPConfigWriter.current(
                  format: .mcpServersJSON,
                  text: "{\"mcpServers\":{\"brosis\":{\"command\":\"/x\"}}}", name: "brosis"))?.clientID == nil)

        autoIntegrationCases(check)

        // ---- 整表探测要多快（用户 2026-09-09 提的性能问题，30 分钟跑一次的就是这一坨）
        let began = Date()
        let scanned = MCPIntegration.allStatuses(store: nil)
        let elapsed = Date().timeIntervalSince(began) * 1000
        check("整表探测 \(String(format: "%.0f", elapsed)) ms（\(scanned.count) 个 harness，只读）",
              elapsed < 2000, elapsed < 2000 ? "" : "太慢了，自动集成每 30 分钟要跑一次")

        print("      MCP 集成：\(HarnessCatalog.all.map(\.displayName).joined(separator: " / "))"
              + "；用例 \(cases.joined(separator: "、"))"
              + "；开关 = 配置 + grant 两件事，学习模式读 mcp_audit 里 no_grant 的 client 名")
        return failures
    }

    /// 按 id 取一条 harness。**不用下标**：`HarnessCatalog.all` 里插一行或换个顺序，
    /// 下标会让这些用例静静地换成另一个 harness、另一种配置格式，断言还照样通过。
    private static func harness(_ id: String) -> Harness {
        HarnessCatalog.all.first { $0.id == id }!
    }

    /// 自动集成的判定。**全是纯函数**：输入是造出来的 Status，`commandExists` 也注入掉了，
    /// 所以这里不碰任何真实文件、不写任何 UserDefaults。
    /// `check` 由 `run()` 传进来——每个自检文件只该有一份 PASS/FAIL 的打印格式。
    private static func autoIntegrationCases(_ check: (String, Bool, String) -> Void) {
        let direct = harness("codex")        // allowDirectWrite，无 CLI 模板
        let viaCLI = harness("claude-code")  // 只走官方 CLI
        let ours = HarnessCatalog.serverCommand()

        func status(_ harness: Harness, installed: Bool = true, cli: String? = nil,
                    command: String? = nil, clientID: String? = nil, problem: String? = nil,
                    grant: Bool = false, disabled: Bool = false) -> MCPIntegration.Status {
            MCPIntegration.Status(harness: harness, installed: installed, cliPath: cli,
                                  currentCommand: command, currentClientID: clientID,
                                  configProblem: problem, hasGrant: grant,
                                  manuallyDisabled: disabled)
        }
        func plan(_ statuses: [MCPIntegration.Status],
                  exists: @escaping (String) -> Bool = { _ in true }) -> [String] {
            MCPAutoIntegration.decide(statuses: statuses, commandExists: exists).map(\.harness.id)
        }

        check("没装的不动（否则会在别人家目录里建出他没装的东西）",
              plan([status(direct, installed: false)]).isEmpty, "")
        check("装了没配的接进来", plan([status(direct)]) == [direct.id], "")
        check("手动关过的永远跳过", plan([status(direct, disabled: true)]).isEmpty, "")
        check("配置解析不了的不猜", plan([status(direct, problem: "坏了")]).isEmpty, "")
        check("既不能直写又找不到官方 CLI 的跳过（自动跑时给剪贴板片段没有意义）",
              plan([status(viaCLI)]).isEmpty, "")
        check("不能直写但有官方 CLI 的照接",
              plan([status(viaCLI, cli: "/opt/homebrew/bin/claude")]) == [viaCLI.id], "")
        check("配好了、有 grant、client_id 也钉对了 → 什么都不做",
              plan([status(direct, command: ours, clientID: direct.id, grant: true)]).isEmpty, "")
        check("配了但没 grant → 补发（没有 grant 的客户端会被全拒）",
              plan([status(direct, command: ours, clientID: direct.id)]) == [direct.id], "")
        check("配了、有 grant，但条目是老版本写的（没钉 client_id）→ 补写",
              plan([status(direct, command: ours, grant: true)]) == [direct.id], "")
        // 这一条是 09-09 复查时才发现的：grok 同时有 allowDirectWrite 和 cliAdd，条目由
        // `grok mcp add` 写、本来就不带我们的 env。若按 allowDirectWrite 去比 env，它会
        // 永远为假 —— 每 30 分钟重跑一次官方 CLI。判据落在 writeRoute 上才不会。
        check("走官方 CLI 的那家：条目没有我们的 env 也不算过期（否则每轮重跑一次 CLI）",
              plan([status(harness("grok"), cli: "/opt/homebrew/bin/grok",
                           command: ours, grant: true)]).isEmpty, "")
        check("指向别的可执行文件、而那个文件还在 → 不抢方向盘",
              plan([status(direct, command: "/Users/me/build/brosis-mcp",
                           clientID: direct.id, grant: true)]).isEmpty, "")
        check("指向的可执行文件已经没了 → 修（app 挪过位置 / 重装过）",
              plan([status(direct, command: "/old/brosis-mcp", clientID: direct.id, grant: true)],
                   exists: { _ in false }) == [direct.id], "")
    }
}
