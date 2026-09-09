import Foundation

/// 主流 harness 的 MCP 配置描述表（2026-09-08 / D33）。
///
/// **随包写死，不从本机倒推**：别人机器上装了但从没配过 MCP 的，配置文件根本不存在，
/// 所以这张表给的是每个 harness **官方文档里的用户级路径**，开开关时目录与文件都由我们建。
/// 只做**用户级**（用户明确要求）：项目级配置会把活动记录接口提交进仓库，不做。
///
/// 路径与格式的出处（2026-09-08 查证）：
///   * Claude Code：`~/.claude.json` 顶层 `mcpServers`；官方 CLI `claude mcp add -s user`。
///   * Codex CLI：`~/.codex/config.toml` 的 `[mcp_servers.<名字>]`（本机已有 node_repl 等做样板）。
///   * Cursor：`~/.cursor/mcp.json` 的 `mcpServers`（`cursor-agent mcp --help` 里写明读这两个路径）。
///   * Grok CLI：`~/.grok/config.toml`；它**还会读** `~/.claude.json` 与 `.cursor/mcp.json`（优先级更低）。
///   * ZCode：原生 `~/.zcode/cli/config.json` 的 **`mcp.servers`**（嵌套两层）；
///     兼容路径 `~/.agents/mcp.json` 用标准 `mcpServers`——但 `.zcode` 里只要有一个 server，
///     同作用域的 `.agents` 会被**整个跳过、不合并**，所以两者只能选一个，我们写原生那份。
///   * Kimi Code：`~/.kimi-code/mcp.json`（或 `$KIMI_CODE_HOME/mcp.json`）的 `mcpServers`。
enum HarnessFormat: String, Sendable {
    /// 标准 `{"mcpServers": {...}}`。
    case mcpServersJSON
    /// ZCode 原生 `{"mcp": {"servers": {...}}}`。
    case zcodeNestedJSON
    /// `[mcp_servers.<名字>]` TOML。
    case mcpServersTOML
}

struct Harness: Sendable, Identifiable {
    var id: String
    var displayName: String
    /// 用户级配置文件（相对家目录）。第一个是我们要写的那个。
    var configPath: String
    /// 环境变量覆盖家目录下的配置根（例如 Kimi 的 KIMI_CODE_HOME）。
    var homeEnvKey: String?
    var format: HarnessFormat
    /// 官方 CLI 的可执行名（在 PATH 里找）。有就优先用它增删，避开与 harness 自己对写。
    var cliName: String?
    /// 用官方 CLI 增删的命令行（`$NAME` / `$CMD` 占位）。nil = 只能自己写文件。
    var cliAdd: [String]?
    var cliRemove: [String]?
    /// 直接改文件是否安全。`~/.claude.json` 是 100 KB 量级且 Claude Code 自己在频繁重写
    /// （本机见到 3 个 .tmp、5 个 .backup），没有 CLI 时我们**不硬写**，改成让用户复制片段。
    var allowDirectWrite: Bool
    /// 探测用的其它痕迹（存在即认为装了这个 harness）。
    var probePaths: [String]
    /// 界面上要提醒的话。
    var note: String?
    /// 这一家的条目里要不要 `"type": "stdio"`。**差异写进表，不写进 if**——
    /// 之前用 `harness.id == "claude-code"` 判，两个调用点的条件还不一样。
    var entryIncludesStdioType = false

    /// 默认参数用**缓存过的**那份环境：`ProcessInfo.processInfo.environment` 每次求值都
    /// 复制一整份字典，而这个方法每轮探测每个 harness 都调、窗口每重画一行也调。
    /// （`MCPIntegration.processEnvironment` 当初就是为了消掉这种复制才加的，只是没顺手用到这里。）
    func expandedConfigPath(environment: [String: String] = MCPIntegration.processEnvironment,
                            home: String = NSHomeDirectory()) -> String {
        if let homeEnvKey, let root = environment[homeEnvKey], !root.isEmpty {
            return (root as NSString).appendingPathComponent((configPath as NSString).lastPathComponent)
        }
        return (home as NSString).appendingPathComponent(configPath)
    }
}

enum HarnessCatalog {

    /// 服务器在各家配置里的名字，也是 grants 表里 client_id 的**建议值**——
    /// 真正自报什么名只有连过来才知道，所以面板有「学习模式」。
    static let serverName = "brosis"

    static let all: [Harness] = [
        Harness(id: "claude-code", displayName: "Claude Code",
                configPath: ".claude.json", homeEnvKey: nil,
                format: .mcpServersJSON,
                cliName: "claude",
                cliAdd: ["mcp", "add", "--scope", "user", "$NAME", "$CMD"],
                cliRemove: ["mcp", "remove", "--scope", "user", "$NAME"],
                allowDirectWrite: false,
                probePaths: [".claude", ".claude.json"],
                note: "配置文件很大且 Claude Code 自己在频繁重写，所以只用官方 CLI 增删；"
                    + "CLI 不在时改为复制片段手动加。",
                entryIncludesStdioType: true),
        Harness(id: "codex", displayName: "Codex CLI",
                configPath: ".codex/config.toml", homeEnvKey: nil,
                format: .mcpServersTOML,
                cliName: "codex",
                cliAdd: nil, cliRemove: nil,
                allowDirectWrite: true,
                probePaths: [".codex"],
                note: nil),
        Harness(id: "cursor", displayName: "Cursor",
                configPath: ".cursor/mcp.json", homeEnvKey: nil,
                format: .mcpServersJSON,
                cliName: "cursor-agent",
                cliAdd: nil, cliRemove: nil,
                allowDirectWrite: true,
                probePaths: [".cursor"],
                note: nil),
        Harness(id: "grok", displayName: "Grok CLI",
                configPath: ".grok/config.toml", homeEnvKey: nil,
                format: .mcpServersTOML,
                cliName: "grok",
                cliAdd: ["mcp", "add", "$NAME", "-t", "stdio", "-c", "$CMD"],
                cliRemove: ["mcp", "remove", "$NAME"],
                allowDirectWrite: true,
                probePaths: [".grok"],
                note: "Grok 还会读 ~/.claude.json 与 .cursor/mcp.json（优先级低于它自己的 config.toml），"
                    + "所以给 Claude Code 开了之后它可能也能看见——但连过来自报的名字未必一样，"
                    + "grant 对不上会被全拒，用「学习模式」确认。"),
        Harness(id: "zcode", displayName: "ZCode",
                configPath: ".zcode/cli/config.json", homeEnvKey: nil,
                format: .zcodeNestedJSON,
                cliName: nil, cliAdd: nil, cliRemove: nil,
                allowDirectWrite: true,
                probePaths: [".zcode"],
                note: "写的是原生 .zcode 配置。注意 ZCode 的规矩：.zcode 里只要有任何一个 server，"
                    + "同作用域的 ~/.agents/mcp.json 就被整个跳过、不合并。"),
        Harness(id: "kimi", displayName: "Kimi Code",
                configPath: ".kimi-code/mcp.json", homeEnvKey: "KIMI_CODE_HOME",
                format: .mcpServersJSON,
                cliName: "kimi",
                cliAdd: nil, cliRemove: nil,
                allowDirectWrite: true,
                probePaths: [".kimi-code"],
                note: "也可以在 Kimi 的 TUI 里用 /mcp-config 看到这一项。"),
    ]

    /// MCP 服务器的可执行路径：**装着的那份 app 里的 brosis-mcp**。
    /// 用 Bundle 推而不是写死 /Applications，这样从别处运行的构建也能正确注册自己。
    static func serverCommand(bundle: Bundle = .main) -> String {
        bundle.bundleURL.appending(path: "Contents/MacOS/brosis-mcp").path
    }
}
