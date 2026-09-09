import AppKit
import BrosisCore
import Foundation

/// 「MCP 集成」窗口（D33）：一行一个 harness，开关 = 写配置 + 发 grant。
///
/// 只做**用户级**配置（用户要求）。项目级会把活动记录接口提交进仓库，不做。
@MainActor
final class MCPIntegrationWindowController: NSObject, NSWindowDelegate,
                                            NSTableViewDataSource, NSTableViewDelegate {

    static let shared = MCPIntegrationWindowController()

    private weak var recorder: Recorder?
    private var window: NSWindow?
    private var registeredLanguageHandler = false
    private var tableView: NSTableView?
    private var statusLabel: NSTextField?
    private var noteLabel: NSTextField?
    private var rows: [MCPIntegration.Status] = []
    private var lastAction: String?
    /// 学习模式：定时轮询审计里被 `no_grant` 拒掉的 client 名。
    private var learnTimer: Timer?
    private var learnDeadline: Date?
    private var learned: [String] = []

    func configure(recorder: Recorder) { self.recorder = recorder }

    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("MCP 集成…", "MCP integration…"), action: #selector(openFromMenu(_:)), keyEquivalent: "")
        item.target = MCPIntegrationWindowController.shared
        return item
    }

    @objc private func openFromMenu(_ sender: Any?) { present() }

    func present() {
        if window == nil { buildWindow() }
        // 语言换了就把窗口关掉：contentView 是搭窗口时一次性造出来的，
        // 就地把每个控件的文案换一遍既繁琐又容易漏，重开一次全对。
        // **谁搭窗口谁登记**——不靠 AppDelegate 点名，那份名单结构上补不齐。
        if !registeredLanguageHandler {
            registeredLanguageHandler = true
            L10n.onLanguageChange { [weak self] in
                self?.window?.close()
                self?.window = nil
            }
        }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("MCP 集成", "MCP integration")
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 360)

        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 16, y: 404, width: 868, height: 40)
        status.autoresizingMask = [.width, .minYMargin]
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 2
        content.addSubview(status)
        statusLabel = status

        let table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        for spec in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.0))
            column.title = spec.1
            column.width = spec.2
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 88, width: 868, height: 308))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        content.addSubview(scroll)
        tableView = table

        var x = 16.0
        func button(_ title: String, _ action: Selector, _ width: Double) {
            let b = NSButton(title: title, target: self, action: action)
            b.frame = NSRect(x: x, y: 50, width: width, height: 28)
            b.autoresizingMask = [.maxXMargin, .minYMargin]
            content.addSubview(b)
            x += width + 8
        }
        button(L("开启集成", "Enable"), #selector(enableClicked), 96)
        button(L("关闭集成", "Disable"), #selector(disableClicked), 96)
        button(L("打开配置文件", "Reveal config file"), #selector(revealClicked), 120)
        button(L("复制配置片段", "Copy config snippet"), #selector(copyClicked), 120)
        button(L("学习模式（等 60 s 看谁来连）", "Learn mode (watch 60s for connections)"), #selector(learnClicked), 220)
        button(L("刷新", "Refresh"), #selector(refreshClicked), 72)

        let note = NSTextField(labelWithString: "")
        note.frame = NSRect(x: 16, y: 8, width: 868, height: 34)
        note.autoresizingMask = [.width, .minYMargin]
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        content.addSubview(note)
        noteLabel = note

        window.contentView = content
        self.window = window
    }

    /// **`var` 不是 `let`**：`static let` 一个进程只算一次，表头会冻在第一次开窗时的语言上，
    /// 而这个窗口的设计前提正是"关掉重开就是新语言"。
    private static var columns: [(String, String, Double)] = [
        ("harness", "Harness", 130),
        ("state", L("状态", "Status"), 300),
        ("grant", L("授权", "Grant"), 90),
        ("config", L("用户级配置文件", "User-level config file"), 320),
    ]

    private var store: Store? { recorder?.withStore { $0 } ?? nil }

    /// 整表重探：读 6 个 harness 的配置文件 + 找 CLI（每家要 stat 十几个目录）。
    /// 学习模式每 2 秒的心跳**不该**走这里，见 `refreshNote()`。
    private func reload() {
        let store = self.store
        rows = HarnessCatalog.all.map { MCPIntegration.status(of: $0, store: store) }
        tableView?.reloadData()
        var lines: [String] = []
        if store == nil { lines.append(L("库没打开：能改配置，但发不了 grant——解锁后再开一次开关。", "Database not open: the config can be written but no grant can be issued — unlock and toggle again.")) }
        lines.append(L("开关 = 写这个 harness 的用户级配置 + 发 / 撤 grants 表里的授权。"
                       + "两件事缺一不可：没有 grant 的客户端所有工具都会被拒。",
                       "Toggling does two things: writes this harness’s user-level config, and issues or "
                       + "revokes the grant in the database. Both are required — a client without a "
                       + "grant is refused on every tool."))
        if let lastAction { lines.append(lastAction) }
        statusLabel?.stringValue = lines.suffix(2).joined(separator: "\n")
        refreshNote()
    }

    /// 只重画底部那行字（学习模式倒计时走这条，不重探配置）。
    private func refreshNote() {
        var note = L("服务器路径：\(HarnessCatalog.serverCommand())",
                     "Server path: \(HarnessCatalog.serverCommand())")
        if !learned.isEmpty {
            note += L(" · 学习模式抓到未授权 client：\(learned.joined(separator: " "))（选中行不影响，按钮会问你给哪个发）",
                      " · learn mode saw ungranted clients: \(learned.joined(separator: " ")) "
                      + "(the selected row is unaffected; you will be asked which one to grant)")
        }
        if let deadline = learnDeadline, deadline > Date() {
            note += L(" · 学习模式剩 \(Int(deadline.timeIntervalSinceNow)) s",
                      " · learn mode: \(Int(deadline.timeIntervalSinceNow))s left")
        }
        note += L(" · 改完要重启对应的 harness 才生效",
                  " · restart the harness for changes to take effect")
        noteLabel?.stringValue = note
    }

    private var selected: MCPIntegration.Status? {
        guard let row = tableView?.selectedRow, row >= 0, row < rows.count else { return nil }
        return rows[row]
    }

    // MARK: - 动作

    @objc private func refreshClicked() { reload() }

    @objc private func enableClicked() { toggle(true) }
    @objc private func disableClicked() { toggle(false) }

    private func toggle(_ on: Bool) {
        guard let status = selected else {
            presentAlert(title: L("先选一行", "Select a row first"), body: L("在上面的列表里选一个 harness。", "Pick a harness in the list above."))
            return
        }
        if on, status.pointsElsewhere {
            let alert = NSAlert()
            alert.messageText = L("\(status.harness.displayName) 里已经有 brosis，但指向别处",
                                  "\(status.harness.displayName) already has brosis, pointing elsewhere")
            alert.informativeText = L("现在指向：\(status.currentCommand ?? "?")\n"
                                      + "要改成这份 app 里的 \(HarnessCatalog.serverCommand()) 吗？",
                                      "Currently points to: \(status.currentCommand ?? "?")\n"
                                      + "Change it to \(HarnessCatalog.serverCommand()) from this app?")
            alert.addButton(withTitle: L("改过来", "Point it here"))
            alert.addButton(withTitle: L("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let outcome = try MCPIntegration.setEnabled(on, harness: status.harness, store: store)
            lastAction = "\(status.harness.displayName)：\(outcome.summary)"
            if let snippet = outcome.manualSnippet {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet, forType: .string)
                lastAction? += L("；写不了，片段已复制到剪贴板，请手动加进配置文件",
                                 "; could not write — the snippet was copied to the clipboard, "
                                 + "please add it to the config file manually")
            }
            recorder?.logEvent(kind: "mcp_integration_changed",
                               detail: "harness=\(status.harness.id) enabled=\(on)")
        } catch {
            lastAction = L("\(status.harness.displayName)：失败 —— \(error)",
                           "\(status.harness.displayName): failed — \(error)")
        }
        reload()
    }

    @objc private func revealClicked() {
        guard let status = selected else { return }
        let path = status.harness.expandedConfigPath()
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
        } else {
            presentAlert(title: L("配置文件还不存在", "Config file does not exist yet"),
                         body: L("\(path)\n开启集成时会自动建出来。",
                                 "\(path)\nIt is created automatically when you enable the integration."))
        }
    }

    @objc private func copyClicked() {
        guard let status = selected else { return }
        let entry = MCPConfigWriter.entry(for: status.harness, command: HarnessCatalog.serverCommand())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPIntegration.snippet(for: status.harness, entry: entry),
                                       forType: .string)
        lastAction = L("\(status.harness.displayName) 的配置片段已复制",
                       "Copied the config snippet for \(status.harness.displayName)")
        reload()
    }

    /// 学习模式：60 秒内谁连过来被 `no_grant` 拒了，就把它自报的名字捞出来给你确认。
    @objc private func learnClicked() {
        learned = []
        learnTimer?.invalidate()
        learnDeadline = Date().addingTimeInterval(60)
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.learnTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        learnTimer = timer
        lastAction = L("学习模式开始：现在去那个 harness 里发一条需要 brosis 的请求（例如让它调 brosis 的 search）",
                       "Learn mode started: now send a request that needs brosis from that harness "
                       + "(for example, ask it to call brosis’s search).")
        reload()
    }

    private func learnTick() {
        learned = MCPIntegration.unknownClients(store: store)
        guard let deadline = learnDeadline, Date() >= deadline else { refreshNote(); return }
        stopLearning()
        if learned.isEmpty {
            lastAction = L("学习模式结束：这 60 秒里没有未授权的客户端来连过。",
                               "Learn mode finished: no ungranted client connected during those 60 seconds.")
        } else {
            askToGrant()
        }
        reload()
    }

    private func stopLearning() {
        learnTimer?.invalidate()
        learnTimer = nil
        learnDeadline = nil
    }

    /// 窗口关了还每 2 秒扫一次 grants 表没有意义。
    func windowWillClose(_ notification: Notification) { stopLearning() }

    private func askToGrant() {
        for client in learned {
            let alert = NSAlert()
            alert.messageText = L("给 \(client) 发授权？", "Grant access to \(client)?")
            alert.informativeText = L("刚才有个客户端自报 client=\(client) 来连，因为没有 grant 被全拒了。"
                                      + "发一张 grant（evidence、30 天、全部应用）它就能用。",
                                      "A client identifying itself as client=\(client) just connected and "
                                      + "was refused because it has no grant. Issuing a grant "
                                      + "(evidence, 30 days, all apps) will let it through.")
            alert.addButton(withTitle: L("发", "Grant"))
            alert.addButton(withTitle: L("跳过", "Skip"))
            guard alert.runModal() == .alertFirstButtonReturn else { continue }
            do {
                try MCPIntegration.grantClient(client, store: store)
                lastAction = L("已给 \(client) 发 grant", "Granted access to \(client)")
                recorder?.logEvent(kind: "mcp_grant_learned", detail: "client=\(client)")
            } catch {
                lastAction = L("给 \(client) 发 grant 失败：\(error)", "Granting \(client) failed: \(error)")
            }
        }
        learned = []
        reload()
    }

    private func presentAlert(title: String, body: String) {
        NSApp.activate(ignoringOtherApps: true)   // LSUIElement：不激活弹窗会藏到别的 app 后面
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: L("好", "OK"))
        alert.runModal()
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < rows.count, let column = tableColumn?.identifier.rawValue else { return nil }
        let status = rows[row]
        let text: String
        switch column {
        case "harness": text = status.harness.displayName
        case "state":   text = status.stateText
        case "grant":   text = status.hasGrant ? L("已授权", "Granted") : L("无", "None")
        case "config":  text = (status.harness.expandedConfigPath() as NSString)
                                   .abbreviatingWithTildeInPath
        default:        text = ""
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = status.harness.note ?? status.stateText
        if !status.installed { label.textColor = .disabledControlTextColor }
        return label
    }
}
