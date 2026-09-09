import BrosisCore
import Foundation

/// MCP 集成的动作层（D33）：探测、开关、grant、学习模式。界面在 `MCPIntegrationWindow`。
///
/// 开关做**两件事**，缺一不可：
///  1. 往 harness 的用户级配置里增删 `brosis` 这一项——只是让它知道"有这么个服务器可连"；
///  2. 在 `grants` 表里增删对应 client 的授权——**这才是真正的门**（没有 grant 一律全拒）。
/// 所以关的时候两边都撤：只删配置留着 grant，等于凭据还在。
/// 子进程输出的收集盒：读回调在后台队列跑，`runProcess` 在调用线程等，两边共享得加锁。
/// （单独一个类是为了跨并发域传递时不用 `nonisolated(unsafe)` 局部变量。）
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.withLock { data.append(chunk) }
    }
    var value: Data { lock.withLock { data } }
}

enum MCPIntegration {

    struct Status: Sendable {
        var harness: Harness
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
            if let configProblem { return L("配置读不出来：\(configProblem)", "config unreadable: \(configProblem)") }
            if !configured { return installed ? L("已安装，未配置", "installed, not configured") : L("未检测到", "not detected") }
            if pointsElsewhere {
                return L("已配置，但指向 \(currentCommand ?? "?")",
                         "configured, but points to \(currentCommand ?? "?")")
            }
            return hasGrant ? L("已配置并已授权", "configured and granted") : L("已配置，但没有授权（会被全拒）", "configured, but no grant (everything is refused)")
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

    /// 进程环境在本进程内不变，拷一次就够——以前每次探测都全量复制一遍字典。
    static let processEnvironment = ProcessInfo.processInfo.environment

    static func locateCLI(_ name: String?) -> String? {
        guard let name else { return nil }
        let fm = FileManager.default
        var dirs = extraBinaryDirectories
        if let path = processEnvironment["PATH"] {
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
        return Status(harness: harness, installed: exists || probed || cli != nil,
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
        let entry = MCPConfigWriter.entry(for: harness, command: command)
        var notes: [String] = []
        var snippet: String?

        // 1) 官方 CLI 优先：避开与 harness 自己对写（~/.claude.json 是重灾区）。
        if let cliPath = locateCLI(harness.cliName),
           let template = enabled ? harness.cliAdd : harness.cliRemove {
            let args = template.map { $0 == "$NAME" ? HarnessCatalog.serverName
                                    : ($0 == "$CMD" ? command : $0) }
            let result = runProcess(cliPath, args)
            if result.status == 0 {
                notes.append(L("用官方 CLI \(harness.cliName ?? "")（\(cliPath)）",
                               "used the official CLI \(harness.cliName ?? "") (\(cliPath))"))
            } else {
                notes.append(L("官方 CLI 失败（\(result.output.prefix(120))），改为直接改配置文件",
                               "official CLI failed (\(result.output.prefix(120))) — "
                               + "editing the config file directly instead"))
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
                    notes.append(L("已发 grant（client=\(harness.id)，evidence、30 天、全部应用）",
                               "grant issued (client=\(harness.id), evidence, 30 days, all apps)"))
                } else {
                    notes.append(L("grant 已存在（client=\(harness.id)）", "grant already exists (client=\(harness.id))"))
                }
            } else if try store.removeGrant(clientID: harness.id) {
                notes.append(L("已撤销 grant（client=\(harness.id)）", "grant revoked (client=\(harness.id))"))
            }
        } else if !grantHandledExternally {
            notes.append(L("库没开，grant 没动——解锁后再开一次", "database closed, grant unchanged — unlock and toggle again"))
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
            notes.append(L("这个 harness 不允许直接改配置（文件太大且它自己在频繁重写）", "this harness does not allow direct config edits (the file is large and it rewrites it often)"))
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
            notes.append(L("配置已经是目标状态，没动文件", "config already matches the target state; file untouched"))
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
            notes.append(L("已备份到 \((backup as NSString).lastPathComponent)",
                           "backed up to \((backup as NSString).lastPathComponent)"))
        }
        // 原子写：临时文件 + 替换。
        let temporary = path + ".brosis-tmp"
        try updated.write(toFile: temporary, atomically: true, encoding: .utf8)
        _ = try fm.replaceItemAt(URL(filePath: path), withItemAt: URL(filePath: temporary))
        notes.append(enabled
                     ? L("已写入 \((path as NSString).abbreviatingWithTildeInPath)",
                         "written to \((path as NSString).abbreviatingWithTildeInPath)")
                     : L("已从 \((path as NSString).abbreviatingWithTildeInPath) 删除",
                         "removed from \((path as NSString).abbreviatingWithTildeInPath)"))
        return nil
    }

    /// 写不了时给用户手动粘的片段。
    ///
    /// **不再手写三份模板**：空文本喂给 `apply` 走的正是"文件不存在 → 建出来"那条路，
    /// 输出就是要粘的内容。手写模板已经开始漂了（writer 会写 env 子表，模板里写死 `args = []`）。
    static func snippet(for harness: Harness, entry: MCPConfigWriter.Entry) -> String {
        (try? MCPConfigWriter.apply(format: harness.format, text: "",
                                     entry: entry, enabled: true)) ?? ""
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
            return ProcessResult(status: -1, output: L("起不来：\(error)", "could not start: \(error)"))
        }
        // 边跑边读：等进程退出再 readToEnd，输出超过管道缓冲（64 KB）就会双方死等。
        let collected = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        // 超时用一个看门狗，主体走 waitUntilExit（内核等待，没有 50 ms 轮询与尾延迟）。
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let data = collected.value
        return ProcessResult(status: process.terminationStatus,
                             output: String(data: data, encoding: .utf8) ?? "")
    }
}
