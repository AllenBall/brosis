import BrosisCore
import Foundation

/// `brosis --mcp <list|enable|disable|auto> [--harness <id>] [--set on|off]`（D33）。
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
        case "auto":
            guard let setting = value(of: "--set", in: arguments) else {
                printAutoStatus()
                return 0
            }
            return auto(setting)
        default:
            FileHandle.standardError.write(Data(
                "用法：--mcp list|enable|disable|auto [--harness <id>] [--set on|off]\n".utf8))
            return 2
        }
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let next = arguments[index + 1]
        return next.hasPrefix("--") ? nil : next
    }

    /// `--mcp auto [--set on|off]`。不带 `--set` 就只读。
    ///
    /// 这个进程和常驻的 app 是**同一个 bundle**，所以写的是同一个 UserDefaults 域；
    /// 常驻进程的定时器每次 tick 都重读 `isEnabled`，所以这里改完下一轮就生效，
    /// 不需要（也没法）去戳它的定时器。
    private static func auto(_ setting: String) -> Int32 {
        let on: Bool
        switch setting {
        case "on":  on = true
        case "off": on = false
        default:
            FileHandle.standardError.write(Data("--set 只认 on / off\n".utf8))
            return 2
        }
        MCPAutoIntegration.isEnabled = on
        printAutoStatus()
        return 0
    }

    /// `list` 与 `auto` 共用的那两行。**间隔从调度器里取**，改了那个常量这里跟着变——
    /// 写死一个「30 分钟」迟早会变成对用户说假话。
    private static func printAutoStatus() {
        let optedOut = MCPIntegration.optedOut.sorted()
        print("自动集成：\(MCPAutoIntegration.isEnabled ? "开" : "关")"
              + " · 手动关过的：\(optedOut.isEmpty ? "无" : optedOut.joined(separator: " "))")
        print("说明：开着时每 \(Int(MCPAutoIntegration.intervalSeconds / 60)) 分钟扫一遍，"
              + "装了但没接的自动写配置 + 发 grant；"
              + "手动关过的永远跳过；关掉它不会撤销已经接好的集成。")
    }

    private static func list() -> Int32 {
        let grants = grantedClients()
        print("服务器路径：\(HarnessCatalog.serverCommand())")
        printAutoStatus()
        // 状态判定只有一份：`MCPIntegration.status` + `Status.stateText`（窗口用的也是它），
        // 以前 CLI 自己又推了一遍，措辞已经和窗口不一致。
        // CLI 进程开不了库（钥匙串 + 库被跑着的 app 占着），grant 只能隔着
        // `brosis-mcp admin grant list` 问，所以 store 传 nil 之后要把答案补回去——
        // 否则 stateText 会一口咬定"没有授权"，和后面 grant= 那列自相矛盾。
        for var status in MCPIntegration.allStatuses(store: nil) {
            status.hasGrant = grants.contains(status.harness.id)
            let harness = status.harness
            // 中日文在终端里是双宽，`%-N@` 按字符数补空格永远对不齐，所以用分隔符不用列宽。
            print(String(format: "%-12@ %@ · grant=%@ · cli=%@ · %@",
                         harness.id as NSString, status.stateText as NSString,
                         (status.hasGrant ? "有" : "无") as NSString,
                         (status.cliPath.map { ($0 as NSString).lastPathComponent } ?? "无") as NSString,
                         (harness.expandedConfigPath() as NSString).abbreviatingWithTildeInPath as NSString))
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
                                                        manualToggle: true,
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
        let executable = HarnessCatalog.serverCommand()
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
        let executable = HarnessCatalog.serverCommand()
        guard FileManager.default.isExecutableFile(atPath: executable) else { return [] }
        let result = MCPIntegration.runProcess(executable, ["admin", "grant", "list"])
        guard let start = result.output.firstIndex(of: "{"),
              let data = String(result.output[start...]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["grants"] as? [[String: Any]] else { return [] }
        return Set(rows.compactMap { $0["clientID"] as? String ?? $0["client_id"] as? String })
    }
}
