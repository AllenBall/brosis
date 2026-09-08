import AppKit
import BrosisCore
import BrosisModels
import Foundation

// =============================================================================
// 「模型」面板（计划 3.11 / D18）与向量检索开关（3.4 / 4.3）
//
// 三条口径写在最前面：
// 1. **默认零模型**（3.11）：app 不内置、不自动下载任何模型。这个面板打开之前，
//    向量检索一律显示"未启用"，其余功能完全不受影响。
// 2. **本轮只放行本地导入**：清单里的两项是用户已批准并下载好的模型；
//    下载器代码在 `BrosisModels/Downloader.swift`（E9 实测过），但这个面板里的
//    「下载」按钮**默认禁用**，要在设置里显式打开 `models.allowDownload`——
//    本轮的硬约束是「不下载未批准的模型」。
// 3. **不改 AppDelegate**：菜单项由 `ModelsMenu.menuItem()` 造好，
//    由主会话在 `refreshMenu()` 里插一行。接入方式见
//    tools/bench/results/m2_c_vectors_2026-09-08.md。
// =============================================================================

/// 菜单接入点。**AppDelegate 一行都不用改**：主会话把下面这两句放进 `refreshMenu()` 即可。
///
/// ```swift
/// ModelsWindowController.shared.configure(recorder: recorder,
///                                         lockSnapshot: { [weak self] in self?.lock.snapshot ?? LockSnapshot() })
/// menu.addItem(ModelsMenu.menuItem())
/// ```
enum ModelsMenu {

    /// 菜单项标题带状态后缀，用户不打开面板也能一眼看出向量检索开没开。
    @MainActor
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "模型与向量检索…（\(shortStatus())）",
                              action: #selector(ModelsWindowController.openFromMenu(_:)),
                              keyEquivalent: "")
        item.target = ModelsWindowController.shared
        return item
    }

    @MainActor
    static func shortStatus() -> String {
        ModelsWindowController.shared.shortStatusText()
    }
}

@MainActor
final class ModelsWindowController: NSObject, NSWindowDelegate,
                                    NSTableViewDataSource, NSTableViewDelegate {

    static let shared = ModelsWindowController()

    /// 允许在面板里下载（默认关，本轮硬约束「不下载未批准的模型」）。
    static let allowDownloadKey = "models.allowDownload"

    private var recorder: Recorder?
    private var lockSnapshot: (@Sendable () -> LockSnapshot)?

    func configure(recorder: Recorder,
                   lockSnapshot: @escaping @Sendable () -> LockSnapshot) {
        self.recorder = recorder
        self.lockSnapshot = lockSnapshot
        EmbeddingScheduler.shared.configure(recorder: recorder, lockSnapshot: lockSnapshot)
        if EmbeddingScheduler.shared.isEnabled { EmbeddingScheduler.shared.start() }
    }

    // MARK: - 状态（纯读，界面与菜单共用）

    struct PanelState {
        var modelsRoot: URL?
        var modelsRootSource: String = "default"
        var entries: [ModelStore.Entry] = []
        var vector: VectorStatus?
        var gate: EmbeddingGateDecision = .skip("not_configured")
        var catalogError: String?
        var storeAvailable = false
    }

    func currentState() -> PanelState {
        var state = PanelState()
        if let directory = recorder?.withStore({ $0.directory }) {
            state.storeAvailable = true
            let resolved = ModelStore.resolveRoot(dataDirectory: directory)
            state.modelsRoot = resolved.url
            state.modelsRootSource = resolved.source
            state.vector = recorder?.withStore { try? $0.vectorStatus() } ?? nil
        }
        do {
            let catalog = try Catalog.load()
            if let root = state.modelsRoot {
                state.entries = ModelStore.entries(catalog: catalog, root: root)
            }
        } catch {
            state.catalogError = "\(error)"
        }
        state.gate = EmbeddingGatePolicy.decide(
            EmbeddingScheduler.shared.currentInput(modelsRoot: state.modelsRoot))
        return state
    }

    /// 菜单标题里的短状态。**"未安装时功能显示未启用"就是这一行**（3.11）。
    func shortStatusText() -> String {
        let state = currentState()
        guard state.storeAvailable else { return "库未打开" }
        let installed = state.entries.first { $0.id == Catalog.embeddingModelID }?.installed ?? false
        guard installed else { return "未启用：未安装嵌入模型" }
        guard let vector = state.vector else { return "未启用" }
        if vector.embeddedChunks == 0 { return "已装模型，尚未建索引" }
        return vector.retrievalEnabled
            ? "向量检索已开（\(vector.embeddedChunks) 块）"
            : "已建索引 \(vector.embeddedChunks) 块，检索开关关着"
    }

    // MARK: - 窗口

    private var window: NSWindow?
    private var tableView: NSTableView?
    private var statusLabel: NSTextField?
    private var vectorSwitch: NSButton?
    private var nightlySwitch: NSButton?
    private var noteLabel: NSTextField?
    private var entries: [ModelStore.Entry] = []
    private var lastAction: String?

    @objc func openFromMenu(_ sender: Any?) { present() }

    func present() {
        if window == nil { buildWindow() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "模型与向量检索"
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 380)

        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 16, y: 470, width: 828, height: 34)
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
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 120, width: 828, height: 340))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        content.addSubview(scroll)
        tableView = table

        let importButton = NSButton(title: "从本地目录导入…", target: self,
                                    action: #selector(importClicked(_:)))
        importButton.frame = NSRect(x: 16, y: 82, width: 160, height: 28)
        importButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(importButton)

        let verifyButton = NSButton(title: "重新校验", target: self,
                                    action: #selector(verifyClicked(_:)))
        verifyButton.frame = NSRect(x: 184, y: 82, width: 96, height: 28)
        verifyButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(verifyButton)

        let removeButton = NSButton(title: "移除", target: self, action: #selector(removeClicked(_:)))
        removeButton.frame = NSRect(x: 288, y: 82, width: 72, height: 28)
        removeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(removeButton)

        let runNow = NSButton(title: "现在跑一次嵌入任务", target: self,
                              action: #selector(runNowClicked(_:)))
        runNow.frame = NSRect(x: 368, y: 82, width: 180, height: 28)
        runNow.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(runNow)

        let rebuild = NSButton(title: "重建索引", target: self, action: #selector(rebuildClicked(_:)))
        rebuild.frame = NSRect(x: 556, y: 82, width: 96, height: 28)
        rebuild.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(rebuild)

        let vectorToggle = NSButton(checkboxWithTitle: "在检索里使用向量（未装模型时强制关）",
                                    target: self, action: #selector(vectorToggled(_:)))
        vectorToggle.frame = NSRect(x: 16, y: 52, width: 400, height: 22)
        vectorToggle.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(vectorToggle)
        vectorSwitch = vectorToggle

        let nightlyToggle = NSButton(
            checkboxWithTitle: "夜间自动建索引（接电 + 空闲 5 分钟 + 温度正常，日均 GPU 预算 10 分钟）",
            target: self, action: #selector(nightlyToggled(_:)))
        nightlyToggle.frame = NSRect(x: 16, y: 28, width: 600, height: 22)
        nightlyToggle.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(nightlyToggle)
        nightlySwitch = nightlyToggle

        let note = NSTextField(labelWithString: "")
        note.frame = NSRect(x: 16, y: 6, width: 828, height: 18)
        note.autoresizingMask = [.width, .minYMargin]
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        content.addSubview(note)
        noteLabel = note

        window.contentView = content
        self.window = window
    }

    private struct ColumnSpec { var id: String; var title: String; var width: CGFloat }
    private static let columns: [ColumnSpec] = [
        ColumnSpec(id: "id", title: "模型", width: 250),
        ColumnSpec(id: "purpose", title: "用途", width: 80),
        ColumnSpec(id: "size", title: "体积", width: 100),
        ColumnSpec(id: "state", title: "状态", width: 150),
        ColumnSpec(id: "note", title: "说明", width: 240),
    ]

    private func reload() {
        let state = currentState()
        entries = state.entries
        tableView?.reloadData()

        var lines: [String] = []
        if let error = state.catalogError {
            lines.append("清单读不出来：\(error)")
        }
        if let vector = state.vector {
            lines.append("向量索引：\(vector.embeddedChunks) / \(vector.chunks) 块已嵌入，"
                         + "待办 \(vector.pendingChunks) 块，未分块的文本版本 \(vector.unchunkedTextVersions) 个，"
                         + "维度 \(vector.dimension)（\(vector.elementType)，sqlite-vec \(vector.sqliteVecVersion)）"
                         + "，模型 \(vector.model ?? "未启用")")
        } else {
            lines.append("库没打开，向量索引状态未知（解锁后再看）。")
        }
        if let reason = state.gate.reason {
            lines.append("夜间任务当前不跑：\(Self.gateText(reason))")
        } else {
            lines.append("夜间任务门控当前满足，下一个检查点会开始。")
        }
        if let action = lastAction { lines.append(action) }
        statusLabel?.stringValue = lines.prefix(2).joined(separator: "\n")
        noteLabel?.stringValue =
            "模型目录：\(state.modelsRoot?.lastPathComponent ?? "?")（来源 \(state.modelsRootSource)；"
            + "D18：数据目录旁的 models/，不加密、不进 iCloud 同步）"
            + (lastAction.map { " · " + $0 } ?? "")

        let installed = entries.first { $0.id == Catalog.embeddingModelID }?.installed ?? false
        vectorSwitch?.state = (state.vector?.retrievalEnabled ?? false) ? .on : .off
        vectorSwitch?.isEnabled = installed && (state.vector?.embeddedChunks ?? 0) > 0
        nightlySwitch?.state = EmbeddingScheduler.shared.isEnabled ? .on : .off
        nightlySwitch?.isEnabled = installed
    }

    /// 门控原因翻成人话。与 `EmbeddingGatePolicy.decide` 的字符串一一对应。
    static func gateText(_ reason: String) -> String {
        switch reason {
        case "disabled_by_user": "夜间自动建索引没打开"
        case "model_not_installed": "嵌入模型未安装（功能显示为未启用）"
        case "nothing_pending": "没有待办的块，索引已经是最新的"
        case "paused": "采集已暂停（锁屏 / 用户暂停）"
        case "on_battery": "在用电池，等接电"
        case "not_idle": "你还在用这台机器，等空闲 5 分钟"
        case "gpu_budget_exhausted": "今天的 GPU 预算已用完"
        default:
            if reason.hasPrefix("thermal_") { "机器偏热（\(reason.dropFirst(8))），等降温" }
            else if reason.hasPrefix("locked_") { "数据库未解锁（\(reason.dropFirst(7))）" }
            else { reason }
        }
    }

    // MARK: - 动作

    private var selectedEntry: ModelStore.Entry? {
        guard let row = tableView?.selectedRow, row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    @objc private func importClicked(_ sender: Any?) {
        guard let entry = selectedEntry else {
            presentAlert(title: "先选一个模型", body: "在上面的清单里选一行，再从本地目录导入。")
            return
        }
        guard let root = currentState().modelsRoot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选一个含有 \(entry.id) 权重文件的目录（会复制进来并逐文件校验 sha256）"
        guard panel.runModal() == .OK, let from = panel.url else { return }
        do {
            let catalog = try Catalog.load()
            let model = try catalog.model(id: entry.id)
            let report = try ModelStore.importLocal(model: model, from: from, root: root,
                                                    schemaVersion: catalog.schemaVersion)
            lastAction = "已导入 \(entry.id)：\(report.fileCount) 个文件、"
                       + "\(ModelBytes.human(report.totalBytes))，sha256 全部通过"
        } catch {
            lastAction = "导入失败：\(error)"
        }
        reload()
    }

    @objc private func verifyClicked(_ sender: Any?) {
        guard let entry = selectedEntry, let root = currentState().modelsRoot else { return }
        do {
            let catalog = try Catalog.load()
            let model = try catalog.model(id: entry.id)
            let digests = try ModelStore.verify(
                model: model, in: ModelStore.directory(root: root, id: entry.id))
            lastAction = "\(entry.id)：\(digests.count) 个文件 sha256 全部通过"
        } catch {
            lastAction = "校验失败：\(error)"
        }
        reload()
    }

    @objc private func removeClicked(_ sender: Any?) {
        guard let entry = selectedEntry, entry.installed,
              let root = currentState().modelsRoot else { return }
        let alert = NSAlert()
        alert.messageText = "移除 \(entry.id)？"
        alert.informativeText = "只删模型权重，不动库里的数据。移除后向量检索会显示为未启用。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ModelStore.remove(root: root, id: entry.id)
            lastAction = "已移除 \(entry.id)"
        } catch {
            lastAction = "移除失败：\(error)"
        }
        reload()
    }

    @objc private func runNowClicked(_ sender: Any?) {
        guard let root = currentState().modelsRoot else { return }
        lastAction = "嵌入任务运行中…"
        reload()
        // 手动触发绕过"接电 / 空闲"两条（用户就在跟前），但**热状态与预算仍然生效**。
        let budget = GPUBudgetLedger()
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = EmbeddingScheduler.shared.runOnce(modelsRoot: root, budget: budget)
            DispatchQueue.main.async {
                self.lastAction = summary
                self.reload()
            }
        }
    }

    @objc private func rebuildClicked(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "重建向量索引？"
        alert.informativeText = "会清掉全部分块与向量，下一次夜间任务从头再来。库里的正文一个字节都不动。"
        alert.addButton(withTitle: "重建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = recorder?.withStore { try? $0.rebuildEmbeddings() } ?? nil
        lastAction = "已清掉 \(removed ?? 0) 个块，索引待重建"
        reload()
    }

    @objc private func vectorToggled(_ sender: NSButton) {
        let on = sender.state == .on
        recorder?.withStore { $0.retrieval.vectorsEnabled = on }
        UserDefaults.standard.set(on, forKey: "retrieval.vectorsEnabled")
        lastAction = on ? "向量通道已打开" : "向量通道已关闭（只走精确字段 + FTS）"
        reload()
    }

    @objc private func nightlyToggled(_ sender: NSButton) {
        EmbeddingScheduler.shared.isEnabled = sender.state == .on
        lastAction = sender.state == .on ? "夜间自动建索引已打开" : "夜间自动建索引已关闭"
        reload()
    }

    private func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < entries.count, let column = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        let text: String
        switch column {
        case "id": text = entry.id
        case "purpose": text = entry.purpose == "embedding" ? "嵌入" : "生成"
        case "size":
            text = entry.installed
                ? ModelBytes.human(entry.diskBytes)
                : (entry.sizeBytes > 0 ? ModelBytes.human(entry.sizeBytes) : "—")
        case "state":
            if entry.installed { text = "已安装" }
            else if entry.unavailableReason != nil { text = "不可用（置灰）" }
            else if entry.approved { text = "未安装" }
            else { text = "未验证（高级入口）" }
        case "note": text = entry.unavailableReason ?? (entry.note ?? "")
        default: text = ""
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = entry.unavailableReason ?? entry.note
        if entry.unavailableReason != nil { label.textColor = .disabledControlTextColor }
        return label
    }
}
