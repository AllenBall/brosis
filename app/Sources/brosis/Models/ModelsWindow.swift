import AppKit
import BrosisCore
import BrosisModels
import Foundation

// =============================================================================
// 「模型」面板（计划 3.11 / D18）与向量检索开关（3.4 / 4.3）
//
// 三条口径写在最前面：
// 1. **默认零模型**（3.11）：app 不内置、不自动下载任何模型。这个面板打开之前，
//    向量检索一律显示「未启用」，其余功能完全不受影响。
// 2. **三条来源（D30）**：清单里的条目可联网下载（下载器在 `BrosisModels/Downloader.swift`，
//    E9 实测过；默认允许，把 `models.allowDownload` 设成 false 可彻底禁网），
//    也可以从本地目录导入（复制）或关联外部目录（不复制，例如 LM Studio 的 MLX 模型目录）。
//    只放行已批准家族 `Qwen3-Embedding-*` 的清单项；清单外的目录只能「关联」，标记为未验证。
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
        let item = NSMenuItem(title: L("模型与向量检索…", "Models and vector search…") + "（\(shortStatus())）",
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

    /// 允许在面板里联网下载。**D30 起默认开**：用户批准了 Qwen3-Embedding 全系列可下载；
    /// 想彻底禁掉联网下载就把这个键设成 false（清单外的模型仍然一律不下）。
    static let allowDownloadKey = "models.allowDownload"
    static var allowDownload: Bool {
        UserDefaults.standard.object(forKey: allowDownloadKey) as? Bool ?? true
    }

    private var recorder: Recorder?
    private var lockSnapshot: (@Sendable () -> LockSnapshot)?

    func configure(recorder: Recorder,
                   lockSnapshot: @escaping @Sendable () -> LockSnapshot) {
        self.recorder = recorder
        self.lockSnapshot = lockSnapshot
        EmbeddingScheduler.shared.configure(recorder: recorder, lockSnapshot: lockSnapshot)
        if EmbeddingScheduler.shared.isEnabled { EmbeddingScheduler.shared.start() }
    }

    /// 模型根目录搬家（2026-09-08）：默认位置从 `<数据目录>/../models` 挪进 `<数据目录>/models`。
    /// 由 AppDelegate 在**库解锁后**调一次（那时 `logEvent` 才写得进库）；幂等，
    /// 有 `BROSIS_MODELS_DIR` / `models.directory` 覆盖时什么都不做。
    func migrateModelsRootIfNeeded() {
        // 用 DataLocation 而不是打开着的库：解析规则同一套（LockController 也走它），
        // 而且库没开的时候也能算得出来。
        let dataDirectory = DataLocation.resolve().url
        do {
            let moved = try ModelStore.migrateLegacyDefaultRoot(dataDirectory: dataDirectory)
            guard !moved.isEmpty else { return }
            recorder?.logEvent(kind: "models_dir_migrated",
                               detail: "count=\(moved.count) ids=\(moved.joined(separator: ","))")
        } catch {
            recorder?.logEvent(kind: "models_dir_migrate_failed", detail: "\(error)")
        }
    }

    // MARK: - 状态（纯读，界面与菜单共用）

    struct PanelState {
        var modelsRoot: URL?
        var modelsRootSource: String = "default"
        /// D30：当前生效的嵌入模型 id（用户选过的 → 第一个装着的）。nil = 一个都没装。
        var currentModelID: String?
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
                state.entries = ModelStore.entries(catalog: catalog, root: root,
                                                   minimumDimension: SchemaV4.dimension)
                state.currentModelID = EmbeddingSelection.effectiveID(catalog: catalog, root: root)
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
        guard state.storeAvailable else { return L("库未打开", "database closed") }
        // D30：装了哪个尺寸都算，取当前生效的那个。
        guard let current = state.currentModelID,
              state.entries.first(where: { $0.id == current })?.usable == true else {
            return L("未启用：未安装嵌入模型", "off: no embedding model installed")
        }
        guard let vector = state.vector else { return L("未启用", "off") }
        if vector.embeddedChunks == 0 { return L("已装模型，尚未建索引", "model installed, index not built") }
        return vector.retrievalEnabled
            ? L("向量检索已开（\(vector.embeddedChunks) 块）", "vector search on (\(vector.embeddedChunks) chunks)")
            : L("已建索引 \(vector.embeddedChunks) 块，检索开关关着",
                "\(vector.embeddedChunks) chunks indexed, search switch is off")
    }

    // MARK: - 窗口

    private var window: NSWindow?
    private var registeredLanguageHandler = false
    private var tableView: NSTableView?
    private var statusLabel: NSTextField?
    private var vectorSwitch: NSButton?
    private var nightlySwitch: NSButton?
    private var autoSwitch: NSButton?
    /// M2 d / T15：「现在开始建索引」按钮（跑起来之后变成「取消」）。
    private var overnightButton: NSButton?
    /// D30 新增的三个入口。
    private var downloadButton: NSButton?
    private var selectButton: NSButton?
    private var downloading = false
    private var downloadCancel: CancelFlag?
    private var noteLabel: NSTextField?
    private var entries: [ModelStore.Entry] = []
    private var lastAction: String?
    private var overnightTimer: Timer?

    @objc func openFromMenu(_ sender: Any?) { present() }

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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 584),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("模型与向量检索", "Models and vector search")
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 380)

        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]

        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 16, y: 534, width: 828, height: 34)
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
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 174, width: 828, height: 350))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        content.addSubview(scroll)
        tableView = table

        // 第一行：模型本身怎么来、用哪一个（D30）。
        let downloadButton = NSButton(title: L("下载", "Download"), target: self,
                                      action: #selector(downloadClicked(_:)))
        downloadButton.frame = NSRect(x: 16, y: 136, width: 72, height: 28)
        downloadButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(downloadButton)
        self.downloadButton = downloadButton

        let importButton = NSButton(title: L("从本地目录导入…", "Import from folder…"), target: self,
                                    action: #selector(importClicked(_:)))
        importButton.frame = NSRect(x: 96, y: 136, width: 152, height: 28)
        importButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(importButton)

        let linkButton = NSButton(title: L("关联外部目录…", "Link external folder…"), target: self,
                                  action: #selector(linkClicked(_:)))
        linkButton.frame = NSRect(x: 256, y: 136, width: 140, height: 28)
        linkButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(linkButton)

        let selectButton = NSButton(title: L("设为当前模型", "Set as current"), target: self,
                                    action: #selector(selectClicked(_:)))
        selectButton.frame = NSRect(x: 404, y: 136, width: 128, height: 28)
        selectButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(selectButton)
        self.selectButton = selectButton

        let verifyButton = NSButton(title: L("重新校验", "Re-verify"), target: self,
                                    action: #selector(verifyClicked(_:)))
        verifyButton.frame = NSRect(x: 540, y: 136, width: 96, height: 28)
        verifyButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(verifyButton)

        let removeButton = NSButton(title: L("移除", "Remove"), target: self, action: #selector(removeClicked(_:)))
        removeButton.frame = NSRect(x: 644, y: 136, width: 72, height: 28)
        removeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(removeButton)

        // 第二行：索引怎么建。
        let runNow = NSButton(title: L("现在跑一次嵌入任务", "Run one embedding pass"), target: self,
                              action: #selector(runNowClicked(_:)))
        runNow.frame = NSRect(x: 16, y: 102, width: 180, height: 28)
        runNow.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(runNow)

        let rebuild = NSButton(title: L("重建索引", "Rebuild index"), target: self, action: #selector(rebuildClicked(_:)))
        rebuild.frame = NSRect(x: 204, y: 102, width: 96, height: 28)
        rebuild.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(rebuild)

        // M2 d / T15：首次全量建索引的一次性动作（D8 的条件 3）。
        let overnight = NSButton(title: L("现在开始建索引（连续跑到完成或取消）", "Build index now (runs until finished or cancelled)"), target: self,
                                 action: #selector(overnightClicked(_:)))
        overnight.frame = NSRect(x: 308, y: 102, width: 300, height: 28)
        overnight.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(overnight)
        overnightButton = overnight

        let vectorToggle = NSButton(checkboxWithTitle: L("在检索里使用向量（未装模型时强制关）", "Use vectors in search (forced off with no model)"),
                                    target: self, action: #selector(vectorToggled(_:)))
        vectorToggle.frame = NSRect(x: 16, y: 74, width: 400, height: 22)
        vectorToggle.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(vectorToggle)
        vectorSwitch = vectorToggle

        let nightlyToggle = NSButton(
            checkboxWithTitle: L("夜间自动建索引（接电 + 空闲 5 分钟 + 温度正常，日均 GPU 预算 10 分钟）", "Nightly auto-index (on AC + idle 5 min + normal temperature, 10 min GPU budget per day)"),
            target: self, action: #selector(nightlyToggled(_:)))
        nightlyToggle.frame = NSRect(x: 16, y: 50, width: 600, height: 22)
        nightlyToggle.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(nightlyToggle)
        nightlySwitch = nightlyToggle

        // 2026-09-08 用户要求：打开时跑一次、之后每小时一次。默认开。
        let autoToggle = NSButton(
            checkboxWithTitle: L("打开时与每 \(Int(AutoIndexScheduler.intervalMinutes)) 分钟自动建索引"
                                 + "（接电 + 温度正常时跑，跑到待办清空；用电池或转热自动暂停）",
                                 "Auto-index on launch and every \(Int(AutoIndexScheduler.intervalMinutes)) min "
                                 + "(runs on AC at normal temperature until the backlog is empty; "
                                 + "pauses on battery or when hot)"),
            target: self, action: #selector(autoIndexToggled(_:)))
        autoToggle.frame = NSRect(x: 16, y: 26, width: 700, height: 22)
        autoToggle.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(autoToggle)
        autoSwitch = autoToggle

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
    /// **`var` 不是 `let`**：`static let` 一个进程只算一次，表头会冻在第一次开窗时的语言上，
    /// 而这个窗口的设计前提正是"关掉重开就是新语言"。
    private static var columns: [ColumnSpec] = [
        ColumnSpec(id: "current", title: L("当前", "Now"), width: 40),
        ColumnSpec(id: "id", title: L("模型", "Model"), width: 240),
        ColumnSpec(id: "purpose", title: L("用途", "Purpose"), width: 60),
        ColumnSpec(id: "size", title: L("体积", "Size"), width: 90),
        ColumnSpec(id: "state", title: L("状态", "Status"), width: 170),
        ColumnSpec(id: "note", title: L("说明", "Notes"), width: 220),
    ]

    private func reload() {
        let state = currentState()
        entries = state.entries
        tableView?.reloadData()

        var lines: [String] = []
        if let error = state.catalogError {
            lines.append(L("清单读不出来：\(error)", "Could not read the catalog: \(error)"))
        }
        if let vector = state.vector {
            let modelName = vector.model ?? L("未启用", "off")
            lines.append(L("向量索引：\(vector.embeddedChunks) / \(vector.chunks) 块已嵌入，"
                           + "待办 \(vector.pendingChunks) 块，未分块的文本版本 \(vector.unchunkedTextVersions) 个，"
                           + "维度 \(vector.dimension)（\(vector.elementType)，sqlite-vec \(vector.sqliteVecVersion)）"
                           + "，模型 \(modelName)",
                           "Vector index: \(vector.embeddedChunks) / \(vector.chunks) chunks embedded, "
                           + "\(vector.pendingChunks) pending, \(vector.unchunkedTextVersions) text versions "
                           + "not yet chunked, \(vector.dimension) dimensions (\(vector.elementType), "
                           + "sqlite-vec \(vector.sqliteVecVersion)), model \(modelName)"))
        } else {
            lines.append(L("库没打开，向量索引状态未知（解锁后再看）。", "Database not open — vector index status unknown (check again after unlocking)."))
        }
        if let reason = state.gate.reason {
            lines.append(L("夜间任务当前不跑：\(Self.gateText(reason))",
                           "Nightly job is not running: \(Self.gateText(reason))"))
        } else {
            lines.append(L("夜间任务门控当前满足，下一个检查点会开始。", "The nightly job’s conditions are met; it will start at the next checkpoint."))
        }
        if let action = lastAction { lines.append(action) }
        statusLabel?.stringValue = lines.prefix(2).joined(separator: "\n")
        noteLabel?.stringValue =
            OvernightIndexJob.shared.statusText + " · " + QueryEmbedderService.shared.statusDescription
            + L(" · 模型目录 \(state.modelsRoot?.lastPathComponent ?? "?")（来源 \(state.modelsRootSource)）",
                  " · model folder \(state.modelsRoot?.lastPathComponent ?? "?") (source \(state.modelsRootSource))")
            + L(" · 自动建索引：", " · auto-index: ") + LOnOff(AutoIndexScheduler.isEnabled)
            + L("（上次 \(Self.autoText(AutoIndexScheduler.shared.lastDecision))）",
                  " (last: \(Self.autoText(AutoIndexScheduler.shared.lastDecision)))")
            + (lastAction.map { " · " + $0 } ?? "")

        let current = currentState().currentModelID
        let installed = current.flatMap { id in entries.first { $0.id == id }?.usable } ?? false
        vectorSwitch?.state = (state.vector?.retrievalEnabled ?? false) ? .on : .off
        vectorSwitch?.isEnabled = installed && (state.vector?.embeddedChunks ?? 0) > 0
        nightlySwitch?.state = EmbeddingScheduler.shared.isEnabled ? .on : .off
        nightlySwitch?.isEnabled = installed
        autoSwitch?.state = AutoIndexScheduler.isEnabled ? .on : .off
        autoSwitch?.isEnabled = installed
        let overnightRunning = OvernightIndexJob.shared.isRunning
        overnightButton?.title = overnightRunning
            ? L("取消建索引", "Cancel indexing") : L("现在开始建索引（连续跑到完成或取消）", "Build index now (runs until finished or cancelled)")
        overnightButton?.isEnabled = installed
            // 用 workRemaining 而不是 pendingChunks：空库上块数是 0 但有一堆没分块的文本版本，
            // 只看块数会把「现在开始建索引」这个手动出口一起灰掉——正是最需要它的那种库。
            && (overnightRunning || (state.vector?.workRemaining ?? 0) > 0)
    }

    /// 自动建索引上一次判定翻成人话。
    static func autoText(_ reason: String) -> String {
        switch reason {
        case "started": L("已踢起一轮", "started a pass")
        case "auto_disabled": L("开关关着", "switch is off")
        case "already_running": L("上一轮还在跑", "previous pass still running")
        // 其余（model_not_installed / nothing_pending / paused / locked_* …）与门控原因
        // 完全重合，交给 gateText，不维护第二套译文。
        default: gateText(reason)
        }
    }

    /// 换模型时提醒查询嵌入的代价（e 批 ⑪）。
    ///
    /// 这个数**直接加在每一次检索上**，不像建索引那样能挪到夜里：T15 实测 0.6B 查询嵌入
    /// 热 p50 19.4 ms，4B 是 94 ms——都在 3.4 的 150 ms 目标内，但 4B 是 5 倍，
    /// 在这台无风扇的机器上搜索时是感觉得到的。换模型是低频动作，所以把代价放在
    /// 做决定的那一刻说，而不是等用户事后觉得"搜索怎么变慢了"。
    static func queryLatencyNote(for modelID: String) -> String {
        guard modelID.contains("-4B") || modelID.contains("-8B") else { return "" }
        return L("\n\n另外：更大的模型会让**每一次检索**都变慢——查询嵌入要现算，"
                 + "0.6B 实测热 p50 约 19 ms，4B 约 94 ms。建索引可以挪到夜里，这一项不行。",
                 "\n\nAlso: a larger model makes **every search** slower — the query embedding is "
                 + "computed on the spot. Measured warm p50 is about 19 ms for 0.6B and 94 ms for 4B. "
                 + "Index building can be moved to the night; this cannot.")
    }

    /// 门控原因翻成人话。表在 `GateReasonText`（nonisolated，三个调度器共用）。
    static func gateText(_ reason: String) -> String { GateReasonText.text(reason) }

    // MARK: - 动作

    private var selectedEntry: ModelStore.Entry? {
        guard let row = tableView?.selectedRow, row >= 0, row < entries.count else { return nil }
        return entries[row]
    }

    @objc private func importClicked(_ sender: Any?) {
        guard let entry = selectedEntry else {
            presentAlert(title: L("先选一个模型", "Select a model first"), body: L("在上面的清单里选一行，再从本地目录导入。", "Pick a row in the list above, then import from a folder."))
            return
        }
        guard let root = currentState().modelsRoot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("导入", "Import")
        panel.message = L("选一个含有 \(entry.id) 权重文件的目录（会复制进来并逐文件校验 sha256）",
                          "Pick a folder containing the \(entry.id) weight files "
                          + "(they are copied in and every file’s sha256 is verified)")
        guard panel.runModal() == .OK, let from = panel.url else { return }
        do {
            let catalog = try Catalog.load()
            let model = try catalog.model(id: entry.id)
            let report = try ModelStore.importLocal(model: model, from: from, root: root,
                                                    schemaVersion: catalog.schemaVersion)
            lastAction = L("已导入 \(entry.id)：\(report.fileCount) 个文件、"
                           + "\(ModelBytes.human(report.totalBytes))，sha256 全部通过",
                           "Imported \(entry.id): \(report.fileCount) files, "
                           + "\(ModelBytes.human(report.totalBytes)), all sha256 verified")
        } catch {
            lastAction = L("导入失败：\(error)", "Import failed: \(error)")
        }
        reload()
    }

    // ---- D30：联网下载 / 关联外部目录 / 切换当前模型

    @objc private func downloadClicked(_ sender: Any?) {
        if downloading {
            downloadCancel?.set()
            lastAction = L("正在取消下载（已下好的部分留着，下次接着下）…", "Cancelling the download (what is already fetched is kept and resumed next time)…")
            reload()
            return
        }
        guard let entry = selectedEntry else {
            presentAlert(title: L("先选一个模型", "Select a model first"), body: L("在上面的清单里选一行，再点下载。", "Pick a row in the list above, then click Download."))
            return
        }
        guard let root = currentState().modelsRoot else { return }
        guard Self.allowDownload else {
            presentAlert(title: L("联网下载被关掉了", "Downloading is disabled"),
                         body: L("\(Self.allowDownloadKey) 设成了 false。"
                                 + "可以改用「从本地目录导入」或「关联外部目录」。",
                                 "\(Self.allowDownloadKey) is set to false. "
                                 + "Use “Import from folder” or “Link external folder” instead."))
            return
        }
        do {
            let catalog = try Catalog.load()
            let model = try catalog.model(id: entry.id)
            let alert = NSAlert()
            alert.messageText = L("下载 \(model.id)？", "Download \(model.id)?")
            alert.informativeText =
                L("从 \(model.repoId) 下载 \(ModelBytes.human(model.totalBytes ?? 0))"
                + "（\(model.files.count) 个文件）。会先探测直连与镜像选快的那个，"
                + "断了可以接着下，全部文件 sha256 校验通过后才算装好。",
                "Download \(ModelBytes.human(model.totalBytes ?? 0)) from \(model.repoId) "
                + "(\(model.files.count) files). The direct and mirror sources are probed first and the "
                + "faster one is used; interrupted downloads resume, and the model counts as installed "
                + "only after every file passes sha256 verification.")
            alert.addButton(withTitle: L("下载", "Download"))
            alert.addButton(withTitle: L("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let flag = CancelFlag()
            downloadCancel = flag
            downloading = true
            downloadButton?.title = L("取消下载", "Cancel download")
            lastAction = L("下载 \(model.id)：正在探测源…", "Downloading \(model.id): probing sources…")
            reload()
            let schema = catalog.schemaVersion
            Task { [weak self] in
                do {
                    let report = try await ModelStore.downloadModel(
                        model, root: root, schemaVersion: schema,
                        isCancelled: { flag.isSet },
                        onFileStart: { file, bytes, index, totalFiles in
                            // 大文件（权重）中途没有细粒度进度，所以先把"正在下哪个、多大"显出来。
                            let text = L("下载 \(index)/\(totalFiles)：正在下 \(file)",
                                         "Downloading \(index)/\(totalFiles): \(file)")
                                     + "（\(ModelBytes.human(bytes))）…"
                            Task { @MainActor in self?.setDownloadProgress(text) }
                        },
                        onProgress: { file, doneFiles, totalFiles, doneBytes, totalBytes in
                            let text = "下载 \(doneFiles)/\(totalFiles)："
                                     + "\(ModelBytes.human(doneBytes)) / \(ModelBytes.human(totalBytes))"
                                     + "（刚下完 \(file)）"
                            Task { @MainActor in self?.setDownloadProgress(text) }
                        })
                    await MainActor.run {
                        self?.finishDownload(
                            L("已下载 \(model.id)：\(report.files.count) 个文件、"
                              + "\(ModelBytes.human(report.totalBytes))，源 \(report.baseUsed)，"
                              + String(format: "%.0f s，sha256 全部通过", report.totalSeconds),
                              "Downloaded \(model.id): \(report.files.count) files, "
                              + "\(ModelBytes.human(report.totalBytes)) from \(report.baseUsed), "
                              + String(format: "%.0fs, all sha256 verified", report.totalSeconds)))
                    }
                } catch {
                    await MainActor.run { self?.finishDownload(L("下载失败：\(error)", "Download failed: \(error)")) }
                }
            }
        } catch {
            lastAction = L("下载没开始：\(error)", "Download did not start: \(error)")
            reload()
        }
    }

    private func setDownloadProgress(_ text: String) {
        lastAction = text
        reload()
    }

    private func finishDownload(_ text: String) {
        downloading = false
        downloadCancel = nil
        downloadButton?.title = L("下载", "Download")
        lastAction = text
        recorder?.logEvent(kind: "model_download_finished", detail: String(text.prefix(160)))
        reload()
    }

    @objc private func linkClicked(_ sender: Any?) {
        guard let root = currentState().modelsRoot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("关联", "Link")
        panel.message = L("选一个 MLX 格式的模型目录（例如 LM Studio 下的 mlx-community/…）。", "Pick an MLX-format model folder (for example mlx-community/… under LM Studio). ")
                      + L("权重不会被复制，brosis 只记住路径。",
                        "The weights are not copied — brosis only remembers the path.")
        guard panel.runModal() == .OK, let from = panel.url else { return }
        do {
            let catalog = try Catalog.load()
            let id = from.lastPathComponent
            let info = try ModelStore.linkExternal(
                id: id, from: from, root: root,
                minimumDimension: SchemaV4.dimension,
                schemaVersion: catalog.schemaVersion)
            lastAction = L("已关联 \(id)：\(info.modelType)、原生 \(info.hiddenSize) 维"
                           + "（截到 \(SchemaV4.dimension) 维用）、\(info.fileCount) 个文件、"
                           + "\(ModelBytes.human(info.totalBytes))，权重留在原处",
                           "Linked \(id): \(info.modelType), native \(info.hiddenSize) dimensions "
                           + "(truncated to \(SchemaV4.dimension)), \(info.fileCount) files, "
                           + "\(ModelBytes.human(info.totalBytes)); weights stay where they are")
            recorder?.logEvent(kind: "model_linked",
                               detail: "id=\(id) hidden=\(info.hiddenSize) type=\(info.modelType)")
        } catch {
            lastAction = L("关联失败：\(error)", "Linking failed: \(error)")
        }
        reload()
    }

    @objc private func selectClicked(_ sender: Any?) {
        guard let entry = selectedEntry else {
            presentAlert(title: L("先选一个模型", "Select a model first"), body: "在上面的清单里选一行，再设为当前模型。")
            return
        }
        guard entry.purpose == "embedding" else {
            presentAlert(title: L("只能选嵌入模型", "Embedding models only"), body: L("向量检索用的是嵌入模型。", "Vector search uses an embedding model."))
            return
        }
        guard entry.usable else {
            presentAlert(title: L("这个模型还不能用", "This model is not usable yet"),
                         body: entry.linkProblem ?? L("还没装：先「下载」、「从本地目录导入」或「关联外部目录」。", "Not installed yet — use “Download”, “Import from folder” or “Link external folder”."))
            return
        }
        let status = recorder?.withStore { try? $0.vectorStatus() } ?? nil
        let indexedModel = status?.model
        let embedded = status?.embeddedChunks ?? 0
        var rebuild = false
        if let indexedModel, indexedModel != entry.id, embedded > 0 {
            // 向量不能跨模型比较：旧索引留着只会给出错的结果。
            let alert = NSAlert()
            alert.messageText = L("换成 \(entry.id)？", "Switch to \(entry.id)?")
            alert.informativeText =
                L("现在的 \(embedded) 块向量是用 \(indexedModel) 建的。不同模型的向量不能互相比较，"
                + "换模型必须重建索引（证据、台账、全文检索都不受影响，只是要重新跑一遍嵌入任务）。"
                + Self.queryLatencyNote(for: entry.id),
                "The current \(embedded) chunk vectors were built with \(indexedModel). Vectors from "
                + "different models are not comparable, so switching requires rebuilding the index. "
                + "Evidence, ledgers and full-text search are unaffected — only the embedding pass "
                + "has to run again."
                + Self.queryLatencyNote(for: entry.id))
            alert.addButton(withTitle: L("换并重建索引", "Switch and rebuild"))
            alert.addButton(withTitle: L("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            rebuild = true
        }
        EmbeddingSelection.select(entry.id)
        var text = L("当前模型已设为 \(entry.id)", "Current model set to \(entry.id)")
        if rebuild {
            let removed = recorder?.withStore { try $0.rebuildEmbeddings() } ?? nil
            text += L("，索引已清空（\(removed ?? 0) 块），下次嵌入任务从头建",
                      "; index cleared (\(removed ?? 0) chunks) — the next embedding pass starts from scratch")
        }
        QueryEmbedderService.shared.modelSelectionChanged(
            store: recorder?.withStore { $0 } ?? nil)
        recorder?.logEvent(kind: "embedding_model_selected",
                           detail: "id=\(entry.id) rebuilt=\(rebuild)")
        lastAction = text
        reload()
    }

    @objc private func verifyClicked(_ sender: Any?) {
        guard let entry = selectedEntry, let root = currentState().modelsRoot else { return }
        do {
            let catalog = try Catalog.load()
            let model = try catalog.model(id: entry.id)
            let digests = try ModelStore.verify(
                model: model, in: ModelStore.directory(root: root, id: entry.id))
            lastAction = L("\(entry.id)：\(digests.count) 个文件 sha256 全部通过",
                           "\(entry.id): all \(digests.count) files passed sha256")
        } catch {
            lastAction = L("校验失败：\(error)", "Verification failed: \(error)")
        }
        reload()
    }

    @objc private func removeClicked(_ sender: Any?) {
        guard let entry = selectedEntry, entry.installed,
              let root = currentState().modelsRoot else { return }
        let alert = NSAlert()
        alert.messageText = L("移除 \(entry.id)？", "Remove \(entry.id)?")
        alert.informativeText = L("只删模型权重，不动库里的数据。移除后向量检索会显示为未启用。", "Only the model weights are deleted; nothing in the database changes. Vector search will show as off.")
        alert.addButton(withTitle: L("移除", "Remove"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ModelStore.remove(root: root, id: entry.id)
            lastAction = L("已移除 \(entry.id)", "Removed \(entry.id)")
        } catch {
            lastAction = L("移除失败：\(error)", "Removal failed: \(error)")
        }
        reload()
    }

    @objc private func runNowClicked(_ sender: Any?) {
        guard let root = currentState().modelsRoot else { return }
        lastAction = L("嵌入任务运行中…", "Embedding pass running…")
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
        alert.messageText = L("重建向量索引？", "Rebuild the vector index?")
        alert.informativeText = L("会清掉全部分块与向量，下一次夜间任务从头再来。库里的正文一个字节都不动。", "All chunks and vectors are cleared and the next nightly pass starts from scratch. Not a byte of the stored text is touched.")
        alert.addButton(withTitle: L("重建", "Rebuild"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let removed = recorder?.withStore { try? $0.rebuildEmbeddings() } ?? nil
        lastAction = L("已清掉 \(removed ?? 0) 个块，索引待重建",
                       "Cleared \(removed ?? 0) chunks — the index needs rebuilding")
        reload()
    }

    /// M2 d / T15：一次性动作「现在开始建索引」。跑着的时候这个按钮就是「取消」。
    @objc private func overnightClicked(_ sender: Any?) {
        if OvernightIndexJob.shared.isRunning {
            OvernightIndexJob.shared.cancel()
            lastAction = L("已请求取消整晚建索引（当前这一批跑完就停）", "Cancellation requested — overnight indexing stops after the current batch")
            reload()
            return
        }
        guard let root = currentState().modelsRoot else { return }
        let alert = NSAlert()
        alert.messageText = L("现在开始建索引？", "Start building the index now?")
        alert.informativeText = """
            会连续跑到全部块嵌完或你取消，可能要几小时（1 个月合成库实测 1 小时 32 分）。
            只放开「空闲 5 分钟」这道门：**仍然要求接电**，机器偏热会自动暂停、真烫了会停，\
            锁库 / 暂停采集也会停。这次的 GPU 时间单独记账，不占夜间增量的 10 分钟日预算。
            """
        alert.addButton(withTitle: L("开始", "Start"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if OvernightIndexJob.shared.start(modelsRoot: root, recorder: recorder) {
            lastAction = L("整晚建索引已开始（进度写进 jobs 与事件）", "Overnight indexing started (progress is written to jobs and events)")
            startOvernightRefresh()
        } else {
            lastAction = L("整晚建索引已经在跑了", "Overnight indexing is already running")
        }
        reload()
    }

    /// 跑起来之后每 5 s 刷一次面板（只在窗口开着的时候）。
    private func startOvernightRefresh() {
        overnightTimer?.invalidate()
        // `Timer` 的 block 本来就在主 run loop 上跑，`assumeIsolated` 只是把这件事告诉编译器
        // （与 LockController / SyncController 的定时器写法一致）。
        overnightTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !OvernightIndexJob.shared.isRunning {
                    self.overnightTimer?.invalidate()
                    self.overnightTimer = nil
                }
                self.reload()
            }
        }
    }

    @objc private func vectorToggled(_ sender: NSButton) {
        let on = sender.state == .on
        recorder?.withStore { $0.retrieval.vectorsEnabled = on }
        UserDefaults.standard.set(on, forKey: QueryEmbedderService.vectorsEnabledKey)
        // M2 d / T15：关掉就立刻把查询嵌入器卸了，不等 10 分钟空闲。
        QueryEmbedderService.shared.setVectorsEnabled(on, store: recorder?.withStore { $0 })
        lastAction = on ? L("向量通道已打开", "Vector channel turned on") : L("向量通道已关闭（只走精确字段 + FTS）", "Vector channel turned off (exact fields + FTS only)")
        reload()
    }

    /// 自动建索引开关（`embedding.autoIndex`）。关掉之后定时器立刻停，正在跑的那轮不打断。
    @objc private func autoIndexToggled(_ sender: NSButton) {
        let on = sender.state == .on
        AutoIndexScheduler.isEnabled = on   // setter 自己写键、自己起停
        recorder?.logEvent(kind: "auto_index_toggled", detail: "enabled=\(on)")
        lastAction = on
            ? "自动建索引已打开（打开时与每 \(Int(AutoIndexScheduler.intervalMinutes)) 分钟一次）"
            : "自动建索引已关闭"
        reload()
    }

    @objc private func nightlyToggled(_ sender: NSButton) {
        EmbeddingScheduler.shared.isEnabled = sender.state == .on
        lastAction = sender.state == .on ? L("夜间自动建索引已打开", "Nightly auto-index turned on") : L("夜间自动建索引已关闭", "Nightly auto-index turned off")
        reload()
    }

    private func presentAlert(title: String, body: String) {
        // brosis 是 LSUIElement，不激活的话弹窗会出现在别的 app 后面（Updater 与
        // PoliciesWindow 里那两份一直有这句，这里和 MCP 窗口漏了）。
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: L("好", "OK"))
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
        case "current": text = entry.id == currentState().currentModelID ? "●" : ""
        case "id": text = entry.id
        case "purpose": text = entry.purpose == "embedding" ? "嵌入" : "生成"
        case "size":
            text = entry.installed
                ? ModelBytes.human(entry.diskBytes)
                : (entry.sizeBytes > 0 ? ModelBytes.human(entry.sizeBytes) : "—")
        case "state":
            if let problem = entry.linkProblem { text = problem }
            else if entry.isLinked { text = "已关联（不占本地空间）" }
            else if entry.installed { text = "已安装" }
            else if entry.unavailableReason != nil { text = "不可用（置灰）" }
            else if entry.approved { text = "未安装（可下载）" }
            else { text = "未验证（高级入口）" }
        case "note":
            text = entry.linkProblem ?? entry.unavailableReason ?? (entry.note ?? "")
        default: text = ""
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = entry.unavailableReason ?? entry.note
        if entry.unavailableReason != nil { label.textColor = .disabledControlTextColor }
        return label
    }
}

/// 下载取消旗标：下载跑在后台 Task 里，取消由主线程按钮设置，所以要能跨线程读。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
