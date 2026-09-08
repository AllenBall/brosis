import BrosisCore
import Foundation

/// `brosis --mcp <list|enable|disable> [--harness <id>]`（D33）。
///
/// 为什么要有命令行入口：brosis 是 `LSUIElement`（菜单栏常驻、没有 Dock 图标），
/// **自动化工具看不见它**——computer-use 的 `request_access` 对 `com.brosis.app` 与 `brosis`
/// 都返回"不是已安装或运行中的应用"，所以窗口和菜单栏图标都点不到，验收只能靠人手点。
/// 这个入口跑的是和窗口**同一套** `MCPIntegration`，于是同一件事既能点也能脚本化。
///
/// 两件事的分工与窗口一致：
///   * 配置文件：本进程直接写（纯文件操作，不需要开库）；
///   * grant：转给同一个 bundle 里的 `brosis-mcp admin grant`，它经 IPC 连正在跑的 app
///     ——**不自己开库**，避免第二个写者。
enum MCPIntegrationCLI {

    static func run(_ arguments: [String]) -> Int32 {
        let action = value(of: "--mcp", in: arguments) ?? "list"
        let harnessID = value(of: "--harness", in: arguments)
        switch action {
        case "list":
            return list()
        case "enable", "disable":
            guard let harnessID else {
                FileHandle.standardError.write(Data("--mcp \(action) 需要 --harness <id>\n".utf8))
                return 2
            }
            return set(action == "enable", harnessID: harnessID)
        default:
            FileHandle.standardError.write(Data("用法：--mcp list|enable|disable [--harness <id>]\n".utf8))
            return 2
        }
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let next = arguments[index + 1]
        return next.hasPrefix("--") ? nil : next
    }

    private static func list() -> Int32 {
        let grants = grantedClients()
        print("服务器路径：\(HarnessCatalog.serverCommand())")
        for harness in HarnessCatalog.all {
            let path = harness.expandedConfigPath()
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let command = (try? MCPConfigWriter.currentCommand(format: harness.format, text: text,
                                                               name: HarnessCatalog.serverName)) ?? nil
            let cli = MCPIntegration.locateCLI(harness.cliName)
            let state = command.map { $0 == HarnessCatalog.serverCommand() ? "已配置" : "已配置(指向别处)" }
                     ?? (FileManager.default.fileExists(atPath: path) ? "未配置" : "无配置文件")
            print(String(format: "%-12@ %-16@ grant=%@ cli=%@ %@",
                         harness.id as NSString, state as NSString,
                         (grants.contains(harness.id) ? "有" : "无") as NSString,
                         (cli.map { ($0 as NSString).lastPathComponent } ?? "无") as NSString,
                         (path as NSString).abbreviatingWithTildeInPath as NSString))
        }
        return 0
    }

    private static func set(_ enabled: Bool, harnessID: String) -> Int32 {
        guard let harness = HarnessCatalog.all.first(where: { $0.id == harnessID }) else {
            FileHandle.standardError.write(Data("没有这个 harness：\(harnessID)\n".utf8))
            return 2
        }
        do {
            // store 传 nil：grant 不在这里发，交给 brosis-mcp（它经 IPC 连正在跑的 app）。
            let outcome = try MCPIntegration.setEnabled(enabled, harness: harness, store: nil,
                                                        grantHandledExternally: true)
            print("配置：\(outcome.summary)")
            if let snippet = outcome.manualSnippet {
                print("写不了，请手动加：\n\(snippet)")
            }
        } catch {
            FileHandle.standardError.write(Data("配置失败：\(error)\n".utf8))
            return 1
        }
        let grantResult = runGrant(enabled ? "add" : "remove", client: harness.id)
        print("grant：\(grantResult)")
        return 0
    }

    /// 转给同 bundle 里的 brosis-mcp。它连的是正在跑的 app，所以库必须已解锁。
    private static func runGrant(_ verb: String, client: String) -> String {
        let executable = Bundle.main.bundleURL.appending(path: "Contents/MacOS/brosis-mcp").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return "找不到 brosis-mcp（\(executable)）"
        }
        var arguments = ["admin", "grant", verb, "--client", client]
        if verb == "add" { arguments += ["--fields", "evidence", "--time-window", "30", "--apps", "*"] }
        let result = MCPIntegration.runProcess(executable, arguments)
        let text = result.output.split(separator: "\n")
            .filter { !$0.contains("NSUserDefaults") }
            .joined(separator: " ")
        return result.status == 0 ? "ok \(text.prefix(160))" : "失败(\(result.status)) \(text.prefix(200))"
    }

    private static func grantedClients() -> Set<String> {
        let executable = Bundle.main.bundleURL.appending(path: "Contents/MacOS/brosis-mcp").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { return [] }
        let result = MCPIntegration.runProcess(executable, ["admin", "grant", "list"])
        guard let start = result.output.firstIndex(of: "{"),
              let data = String(result.output[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["grants"] as? [[String: Any]] else { return [] }
        return Set(rows.compactMap { $0["clientID"] as? String ?? $0["client_id"] as? String })
    }
}
