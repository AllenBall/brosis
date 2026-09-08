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
        let item = NSMenuItem(title: "MCP 集成…", action: #selector(openFromMenu(_:)), keyEquivalent: "")
        item.target = MCPIntegrationWindowController.shared
        return item
    }

    @objc private func openFromMenu(_ sender: Any?) { present() }

    func present() {
        if window == nil { buildWindow() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MCP 集成"
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
        button("开启集成", #selector(enableClicked), 96)
        button("关闭集成", #selector(disableClicked), 96)
        button("打开配置文件", #selector(revealClicked), 120)
        button("复制配置片段", #selector(copyClicked), 120)
        button("学习模式（等 60 s 看谁来连）", #selector(learnClicked), 220)
        button("刷新", #selector(refreshClicked), 72)

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

    private static let columns: [(String, String, Double)] = [
        ("harness", "Harness", 130),
        ("state", "状态", 300),
        ("grant", "授权", 90),
        ("config", "用户级配置文件", 320),
    ]

    private var store: Store? { recorder?.withStore { $0 } ?? nil }

    /// 整表重探：读 6 个 harness 的配置文件 + 找 CLI（每家要 stat 十几个目录）。
    /// 学习模式每 2 秒的心跳**不该**走这里，见 `refreshNote()`。
    private func reload() {
        let store = self.store
        rows = HarnessCatalog.all.map { MCPIntegration.status(of: $0, store: store) }
        tableView?.reloadData()
        var lines: [String] = []
        if store == nil { lines.append("库没打开：能改配置，但发不了 grant——解锁后再开一次开关。") }
        lines.append("开关 = 写这个 harness 的用户级配置 + 发 / 撤 grants 表里的授权。"
                   + "两件事缺一不可：没有 grant 的客户端所有工具都会被拒。")
        if let lastAction { lines.append(lastAction) }
        statusLabel?.stringValue = lines.suffix(2).joined(separator: "\n")
        refreshNote()
    }

    /// 只重画底部那行字（学习模式倒计时走这条，不重探配置）。
    private func refreshNote() {
        var note = "服务器路径：\(HarnessCatalog.serverCommand())"
        if !learned.isEmpty {
            note += " · 学习模式抓到未授权 client：\(learned.joined(separator: " "))（选中行不影响，按钮会问你给哪个发）"
        }
        if let deadline = learnDeadline, deadline > Date() {
            note += " · 学习模式剩 \(Int(deadline.timeIntervalSinceNow)) s"
        }
        note += " · 改完要重启对应的 harness 才生效"
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
            presentAlert(title: "先选一行", body: "在上面的列表里选一个 harness。")
            return
        }
        if on, status.pointsElsewhere {
            let alert = NSAlert()
            alert.messageText = "\(status.harness.displayName) 里已经有 brosis，但指向别处"
            alert.informativeText = "现在指向：\(status.currentCommand ?? "?")\n"
                                  + "要改成这份 app 里的 \(HarnessCatalog.serverCommand()) 吗？"
            alert.addButton(withTitle: "改过来")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let outcome = try MCPIntegration.setEnabled(on, harness: status.harness, store: store)
            lastAction = "\(status.harness.displayName)：\(outcome.summary)"
            if let snippet = outcome.manualSnippet {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(snippet, forType: .string)
                lastAction? += "；写不了，片段已复制到剪贴板，请手动加进配置文件"
            }
            recorder?.logEvent(kind: "mcp_integration_changed",
                               detail: "harness=\(status.harness.id) enabled=\(on)")
        } catch {
            lastAction = "\(status.harness.displayName)：失败 —— \(error)"
        }
        reload()
    }

    @objc private func revealClicked() {
        guard let status = selected else { return }
        let path = status.harness.expandedConfigPath()
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
        } else {
            presentAlert(title: "配置文件还不存在",
                         body: "\(path)\n开启集成时会自动建出来。")
        }
    }

    @objc private func copyClicked() {
        guard let status = selected else { return }
        let entry = MCPConfigWriter.entry(for: status.harness, command: HarnessCatalog.serverCommand())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPIntegration.snippet(for: status.harness, entry: entry),
                                       forType: .string)
        lastAction = "\(status.harness.displayName) 的配置片段已复制"
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
        lastAction = "学习模式开始：现在去那个 harness 里发一条需要 brosis 的请求（例如让它调 brosis 的 search）"
        reload()
    }

    private func learnTick() {
        learned = MCPIntegration.unknownClients(store: store)
        guard let deadline = learnDeadline, Date() >= deadline else { refreshNote(); return }
        stopLearning()
        if learned.isEmpty {
            lastAction = "学习模式结束：这 60 秒里没有未授权的客户端来连过。"
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
            alert.messageText = "给 \(client) 发授权？"
            alert.informativeText = "刚才有个客户端自报 client=\(client) 来连，因为没有 grant 被全拒了。"
                                  + "发一张 grant（evidence、30 天、全部应用）它就能用。"
            alert.addButton(withTitle: "发")
            alert.addButton(withTitle: "跳过")
            guard alert.runModal() == .alertFirstButtonReturn else { continue }
            do {
                try MCPIntegration.grantClient(client, store: store)
                lastAction = "已给 \(client) 发 grant"
                recorder?.logEvent(kind: "mcp_grant_learned", detail: "client=\(client)")
            } catch {
                lastAction = "给 \(client) 发 grant 失败：\(error)"
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
        alert.addButton(withTitle: "好")
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
        case "grant":   text = status.hasGrant ? "已授权" : "无"
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
