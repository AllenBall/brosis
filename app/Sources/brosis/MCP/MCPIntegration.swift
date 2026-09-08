import BrosisCore
import Foundation

/// MCP 集成的动作层（D33）：探测、开关、grant、学习模式。界面在 `MCPIntegrationWindow`。
///
/// 开关做**两件事**，缺一不可：
///  1. 往 harness 的用户级配置里增删 `brosis` 这一项——只是让它知道"有这么个服务器可连"；
///  2. 在 `grants` 表里增删对应 client 的授权——**这才是真正的门**（没有 grant 一律全拒）。
/// 所以关的时候两边都撤：只删配置留着 grant，等于凭据还在。
enum MCPIntegration {

    struct Status: Sendable {
        var harness: Harness
        /// 配置文件在不在。
        var configExists: Bool
        /// 有没有这个 harness 的其它痕迹（目录、CLI）。
        var installed: Bool
        /// 官方 CLI 的绝对路径（找到才用得上）。
        var cliPath: String?
        /// 配置里 brosis 现在指向哪。nil = 没配。
        var currentCommand: String?
        /// 配置文件读不出来的原因（有值时开关只能给"复制片段"）。
        var configProblem: String?
        var hasGrant: Bool

        var configured: Bool { currentCommand != nil }
        /// 配了但指向别的可执行文件（旧路径 / 构建目录）。
        var pointsElsewhere: Bool {
            guard let currentCommand else { return false }
            return currentCommand != HarnessCatalog.serverCommand()
        }
        var stateText: String {
            if let configProblem { return "配置读不出来：\(configProblem)" }
            if !configured { return installed ? "已安装，未配置" : "未检测到" }
            if pointsElsewhere { return "已配置，但指向 \(currentCommand ?? "?")" }
            return hasGrant ? "已配置并已授权" : "已配置，但没有授权（会被全拒）"
        }
    }

    // MARK: - 探测

    /// GUI 进程的 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin（从 Finder 起的 app 尤其如此），
    /// 所以找 CLI 不能只靠 PATH，还要看几个常见安装位置。
    static let extraBinaryDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.bun/bin",
        NSHomeDirectory() + "/.npm-global/bin",
    ]

    static func locateCLI(_ name: String?) -> String? {
        guard let name else { return nil }
        let fm = FileManager.default
        var dirs = extraBinaryDirectories
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            dirs.append(contentsOf: path.split(separator: ":").map(String.init))
        }
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func status(of harness: Harness, store: Store?) -> Status {
        let fm = FileManager.default
        let configPath = harness.expandedConfigPath()
        let exists = fm.fileExists(atPath: configPath)
        let cli = locateCLI(harness.cliName)
        let probed = harness.probePaths.contains {
            fm.fileExists(atPath: (NSHomeDirectory() as NSString).appendingPathComponent($0))
        }
        var command: String?
        var problem: String?
        if exists {
            do {
                let text = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
                command = try MCPConfigWriter.currentCommand(format: harness.format, text: text,
                                                             name: HarnessCatalog.serverName)
            } catch {
                problem = "\(error)"
            }
        }
        let granted = (try? store?.grant(clientID: harness.id)) ?? nil
        return Status(harness: harness, configExists: exists, installed: exists || probed || cli != nil,
                      cliPath: cli, currentCommand: command, configProblem: problem,
                      hasGrant: granted != nil)
    }

    // MARK: - 开关

    struct Outcome: Sendable {
        var summary: String
        /// 写不了时给用户手动粘的片段。
        var manualSnippet: String?
    }

    /// 打开 / 关闭一个 harness 的集成。
    /// 顺序：先动配置（失败就整个不做），再动 grant——反过来会留下"有授权没入口"的悬空状态。
    /// `grantHandledExternally`：命令行入口把 grant 交给 `brosis-mcp admin grant`（经 IPC 连
    /// 正在跑的 app），所以那边传 `store: nil` 不代表"库没开"，不该提示用户解锁后重来。
    static func setEnabled(_ enabled: Bool, harness: Harness, store: Store?,
                           grantHandledExternally: Bool = false) throws -> Outcome {
        let command = HarnessCatalog.serverCommand()
        let entry = MCPConfigWriter.Entry(name: HarnessCatalog.serverName, command: command,
                                          includeStdioType: harness.format == .mcpServersJSON
                                                         && harness.id == "claude-code")
        var notes: [String] = []
        var snippet: String?

        // 1) 官方 CLI 优先：避开与 harness 自己对写（~/.claude.json 是重灾区）。
        if let cliPath = locateCLI(harness.cliName),
           let template = enabled ? harness.cliAdd : harness.cliRemove {
            let args = template.map { $0 == "$NAME" ? HarnessCatalog.serverName
                                    : ($0 == "$CMD" ? command : $0) }
            let result = runProcess(cliPath, args)
            if result.status == 0 {
                notes.append("用官方 CLI \(harness.cliName ?? "")（\(cliPath)）")
            } else {
                notes.append("官方 CLI 失败（\(result.output.prefix(120))），改为直接改配置文件")
                snippet = try? writeConfig(enabled, harness: harness, entry: entry, notes: &notes)
            }
        } else {
            snippet = try writeConfig(enabled, harness: harness, entry: entry, notes: &notes)
        }

        // 2) grant：配置动完了再动，保证不会出现"有授权没入口"。
        if let store {
            if enabled {
                if (try store.grant(clientID: harness.id)) == nil {
                    try store.setGrant(Grant(clientID: harness.id, mode: .strictLocal,
                                             apps: ["*"], timeWindowDays: 30, fields: .evidence))
                    notes.append("已发 grant（client=\(harness.id)，evidence、30 天、全部应用）")
                } else {
                    notes.append("grant 已存在（client=\(harness.id)）")
                }
            } else if try store.removeGrant(clientID: harness.id) {
                notes.append("已撤销 grant（client=\(harness.id)）")
            }
        } else if !grantHandledExternally {
            notes.append("库没开，grant 没动——解锁后再开一次")
        }
        return Outcome(summary: notes.joined(separator: "；"), manualSnippet: snippet)
    }

    /// 直接改配置文件。返回值不为 nil 表示**没写成**，里面是让用户手动粘的片段。
    private static func writeConfig(_ enabled: Bool, harness: Harness,
                                    entry: MCPConfigWriter.Entry,
                                    notes: inout [String]) throws -> String? {
        let path = harness.expandedConfigPath()
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        guard harness.allowDirectWrite else {
            notes.append("这个 harness 不允许直接改配置（文件太大且它自己在频繁重写）")
            return snippet(for: harness, entry: entry)
        }
        let updated: String?
        do {
            updated = try MCPConfigWriter.apply(format: harness.format, text: text,
                                                entry: entry, enabled: enabled)
        } catch {
            notes.append("\(error)")
            return snippet(for: harness, entry: entry)
        }
        guard let updated else {
            notes.append("配置已经是目标状态，没动文件")
            return nil
        }
        let fm = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        // 备份：只在原来有内容时留，且带时间戳，不覆盖上一份。
        if !text.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "")
            let backup = path + ".brosis-backup-" + stamp
            try? text.write(toFile: backup, atomically: true, encoding: .utf8)
            notes.append("已备份到 \((backup as NSString).lastPathComponent)")
        }
        // 原子写：临时文件 + 替换。
        let temporary = path + ".brosis-tmp"
        try updated.write(toFile: temporary, atomically: true, encoding: .utf8)
        _ = try fm.replaceItemAt(URL(filePath: path), withItemAt: URL(filePath: temporary))
        notes.append(enabled ? "已写入 \((path as NSString).abbreviatingWithTildeInPath)"
                             : "已从 \((path as NSString).abbreviatingWithTildeInPath) 删除")
        return nil
    }

    /// 写不了时给的手动片段。
    static func snippet(for harness: Harness, entry: MCPConfigWriter.Entry) -> String {
        switch harness.format {
        case .mcpServersTOML:
            """
            [mcp_servers.\(entry.name)]
            command = "\(entry.command)"
            args = []
            """
        case .zcodeNestedJSON:
            """
            { "mcp": { "servers": { "\(entry.name)": {
                "command": "\(entry.command)", "args": [] } } } }
            """
        case .mcpServersJSON:
            """
            { "mcpServers": { "\(entry.name)": {
                \(entry.includeStdioType ? "\"type\": \"stdio\", " : "")\
            "command": "\(entry.command)", "args": [] } } }
            """
        }
    }

    // MARK: - 学习模式（连过来的 client 到底自报什么名）

    /// 最近若干秒内、被以 `no_grant` 拒掉的 client 名（去重，去掉已经有 grant 的）。
    /// 依据是 `mcp_audit`——被拒的调用本来就会记一行，学习模式只是把它读出来给你确认。
    static func unknownClients(store: Store?, withinSeconds: Double = 120,
                               limit: Int = 200) -> [String] {
        guard let store else { return [] }
        let since = Int64(Date().addingTimeInterval(-withinSeconds).timeIntervalSince1970 * 1000)
        let rows = (try? store.mcpAuditTail(limit: limit)) ?? []
        let granted = Set(((try? store.allGrants()) ?? []).map(\.clientID))
        var seen: [String] = []
        for row in rows where row.ts >= since && row.decision == .noGrant {
            if !granted.contains(row.clientID), !seen.contains(row.clientID) {
                seen.append(row.clientID)
            }
        }
        return seen
    }

    static func grantClient(_ clientID: String, store: Store?) throws {
        guard let store else { return }
        try store.setGrant(Grant(clientID: clientID, mode: .strictLocal, apps: ["*"],
                                 timeWindowDays: 30, fields: .evidence))
    }

    // MARK: - 跑外部命令

    struct ProcessResult: Sendable { var status: Int32; var output: String }

    static func runProcess(_ executable: String, _ arguments: [String],
                           timeout: TimeInterval = 20) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // 官方 CLI 多半是 node 脚本，需要一个像样的 PATH。
        var environment = ProcessInfo.processInfo.environment
        let path = (environment["PATH"] ?? "") + ":" + extraBinaryDirectories.joined(separator: ":")
        environment["PATH"] = path
        process.environment = environment
        do { try process.run() } catch {
            return ProcessResult(status: -1, output: "起不来：\(error)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return ProcessResult(status: -2, output: "超时") }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return ProcessResult(status: process.terminationStatus,
                             output: String(data: data, encoding: .utf8) ?? "")
    }
}
