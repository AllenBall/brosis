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
            let back = try MCPConfigWriter.currentCommand(format: .mcpServersJSON, text: added, name: "brosis")
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
            let back = try MCPConfigWriter.currentCommand(format: .zcodeNestedJSON, text: added, name: "brosis")
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
            let back = try? MCPConfigWriter.currentCommand(format: .mcpServersTOML,
                                                            text: addedTOML, name: "brosis")
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

        print("      MCP 集成：\(HarnessCatalog.all.map(\.displayName).joined(separator: " / "))"
              + "；用例 \(cases.joined(separator: "、"))"
              + "；开关 = 配置 + grant 两件事，学习模式读 mcp_audit 里 no_grant 的 client 名")
        return failures
    }
}
