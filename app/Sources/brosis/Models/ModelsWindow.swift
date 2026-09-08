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
// 2. **三条来源（D30）**：清单里的条目可联网下载（下载器在 `BrosisModels/Downloader.swift`，
//    E9 实测过；默认允许，把 `models.allowDownload` 设成 false 可彻底禁网），
//    也可以从本地目录导入（复制）或关联外部目录（不复制，例如 LM Studio 的 MLX 模型目录）。
//    只放行已批准家族 `Qwen3-Embedding-*` 的清单项；清单外的目录只能"关联"，标记为未验证。
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
        guard state.storeAvailable else { return "库未打开" }
        // D30：装了哪个尺寸都算，取当前生效的那个。
        guard let current = state.currentModelID,
              state.entries.first(where: { $0.id == current })?.usable == true else {
            return "未启用：未安装嵌入模型"
        }
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
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
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
        status.frame = NSRect(x: 16, y: 510, width: 828, height: 34)
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
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 150, width: 828, height: 350))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        content.addSubview(scroll)
        tableView = table

        // 第一行：模型本身怎么来、用哪一个（D30）。
        let downloadButton = NSButton(title: "下载", target: self,
                                      action: #selector(downloadClicked(_:)))
        downloadButton.frame = NSRect(x: 16, y: 112, width: 72, height: 28)
        downloadButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(downloadButton)
        self.downloadButton = downloadButton

        let importButton = NSButton(title: "从本地目录导入…", target: self,
                                    action: #selector(importClicked(_:)))
        importButton.frame = NSRect(x: 96, y: 112, width: 152, height: 28)
        importButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(importButton)

        let linkButton = NSButton(title: "关联外部目录…", target: self,
                                  action: #selector(linkClicked(_:)))
        linkButton.frame = NSRect(x: 256, y: 112, width: 140, height: 28)
        linkButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(linkButton)

        let selectButton = NSButton(title: "设为当前模型", target: self,
                                    action: #selector(selectClicked(_:)))
        selectButton.frame = NSRect(x: 404, y: 112, width: 128, height: 28)
        selectButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(selectButton)
        self.selectButton = selectButton

        let verifyButton = NSButton(title: "重新校验", target: self,
                                    action: #selector(verifyClicked(_:)))
        verifyButton.frame = NSRect(x: 540, y: 112, width: 96, height: 28)
        verifyButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(verifyButton)

        let removeButton = NSButton(title: "移除", target: self, action: #selector(removeClicked(_:)))
        removeButton.frame = NSRect(x: 644, y: 112, width: 72, height: 28)
        removeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(removeButton)

        // 第二行：索引怎么建。
        let runNow = NSButton(title: "现在跑一次嵌入任务", target: self,
                              action: #selector(runNowClicked(_:)))
        runNow.frame = NSRect(x: 16, y: 78, width: 180, height: 28)
        runNow.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(runNow)

        let rebuild = NSButton(title: "重建索引", target: self, action: #selector(rebuildClicked(_:)))
        rebuild.frame = NSRect(x: 204, y: 78, width: 96, height: 28)
        rebuild.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(rebuild)

        // M2 d / T15：首次全量建索引的一次性动作（D8 的条件 3）。
        let overnight = NSButton(title: "现在开始建索引（连续跑到完成或取消）", target: self,
                                 action: #selector(overnightClicked(_:)))
        overnight.frame = NSRect(x: 308, y: 78, width: 300, height: 28)
        overnight.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(overnight)
        overnightButton = overnight

        let vectorToggle = NSButton(checkboxWithTitle: "在检索里使用向量（未装模型时强制关）",
                                    target: self, action: #selector(vectorToggled(_:)))
        vectorToggle.frame = NSRect(x: 16, y: 50, width: 400, height: 22)
        vectorToggle.autoresizingMask = [.maxXMargin, .minYMargin]
        content.addSubview(vectorToggle)
        vectorSwitch = vectorToggle

        let nightlyToggle = NSButton(
            checkboxWithTitle: "夜间自动建索引（接电 + 空闲 5 分钟 + 温度正常，日均 GPU 预算 10 分钟）",
            target: self, action: #selector(nightlyToggled(_:)))
        nightlyToggle.frame = NSRect(x: 16, y: 26, width: 600, height: 22)
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
        ColumnSpec(id: "current", title: "当前", width: 40),
        ColumnSpec(id: "id", title: "模型", width: 240),
        ColumnSpec(id: "purpose", title: "用途", width: 60),
        ColumnSpec(id: "size", title: "体积", width: 90),
        ColumnSpec(id: "state", title: "状态", width: 170),
        ColumnSpec(id: "note", title: "说明", width: 220),
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
            OvernightIndexJob.shared.statusText + " · " + QueryEmbedderService.shared.statusDescription
            + " · 模型目录 \(state.modelsRoot?.lastPathComponent ?? "?")（来源 \(state.modelsRootSource)）"
            + (lastAction.map { " · " + $0 } ?? "")

        let current = currentState().currentModelID
        let installed = current.flatMap { id in entries.first { $0.id == id }?.usable } ?? false
        vectorSwitch?.state = (state.vector?.retrievalEnabled ?? false) ? .on : .off
        vectorSwitch?.isEnabled = installed && (state.vector?.embeddedChunks ?? 0) > 0
        nightlySwitch?.state = EmbeddingScheduler.shared.isEnabled ? .on : .off
        nightlySwitch?.isEnabled = installed
        let overnightRunning = OvernightIndexJob.shared.isRunning
        overnightButton?.title = overnightRunning
            ? "取消建索引" : "现在开始建索引（连续跑到完成或取消）"
        overnightButton?.isEnabled = installed
            && (overnightRunning || (state.vector?.pendingChunks ?? 0) > 0)
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

    // ---- D30：联网下载 / 关联外部目录 / 切换当前模型

    @objc private func downloadClicked(_ sender: Any?) {
        if downloading {
            downloadCancel?.set()
            lastAction = "正在取消下载（已下好的部分留着，下次接着下）…"
            reload()
            return
        }
        guard let entry = selectedEntry else {
            presentAlert(title: "先选一个模型", body: "在上面的清单里选一行，再点下载。")
            return
        }
        guard let root = currentState().modelsRoot else { return }
        guard Self.allowDownload else {
            presentAlert(title: "联网下载被关掉了",
                         body: "\(Self.allowDownloadKey) 设成了 false。"
                             + "可以改用「从本地目录导入」或「关联外部目录」。")
            return
        }
        do {
            let catalog = try Catalog.load()
            let model = try catalog.model(id: entry.id)
            let alert = NSAlert()
            alert.messageText = "下载 \(model.id)？"
            alert.informativeText =
                "从 \(model.repoId) 下载 \(ModelBytes.human(model.totalBytes ?? 0))"
                + "（\(model.files.count) 个文件）。会先探测直连与镜像选快的那个，"
                + "断了可以接着下，全部文件 sha256 校验通过后才算装好。"
            alert.addButton(withTitle: "下载")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let flag = CancelFlag()
            downloadCancel = flag
            downloading = true
            downloadButton?.title = "取消下载"
            lastAction = "下载 \(model.id)：正在探测源…"
            reload()
            let schema = catalog.schemaVersion
            Task { [weak self] in
                do {
                    let report = try await ModelStore.downloadModel(
                        model, root: root, schemaVersion: schema,
                        isCancelled: { flag.isSet },
                        onFileStart: { file, bytes, index, totalFiles in
                            // 大文件（权重）中途没有细粒度进度，所以先把"正在下哪个、多大"显出来。
                            let text = "下载 \(index)/\(totalFiles)：正在下 \(file)"
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
                            "已下载 \(model.id)：\(report.files.count) 个文件、"
                            + "\(ModelBytes.human(report.totalBytes))，源 \(report.baseUsed)，"
                            + String(format: "%.0f s，sha256 全部通过", report.totalSeconds))
                    }
                } catch {
                    await MainActor.run { self?.finishDownload("下载失败：\(error)") }
                }
            }
        } catch {
            lastAction = "下载没开始：\(error)"
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
        downloadButton?.title = "下载"
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
        panel.prompt = "关联"
        panel.message = "选一个 MLX 格式的模型目录（例如 LM Studio 下的 mlx-community/…）。"
                      + "权重不会被复制，brosis 只记住路径。"
        guard panel.runModal() == .OK, let from = panel.url else { return }
        do {
            let catalog = try Catalog.load()
            let id = from.lastPathComponent
            let info = try ModelStore.linkExternal(
                id: id, from: from, root: root,
                minimumDimension: SchemaV4.dimension,
                schemaVersion: catalog.schemaVersion)
            lastAction = "已关联 \(id)：\(info.modelType)、原生 \(info.hiddenSize) 维"
                       + "（截到 \(SchemaV4.dimension) 维用）、\(info.fileCount) 个文件、"
                       + "\(ModelBytes.human(info.totalBytes))，权重留在原处"
            recorder?.logEvent(kind: "model_linked",
                               detail: "id=\(id) hidden=\(info.hiddenSize) type=\(info.modelType)")
        } catch {
            lastAction = "关联失败：\(error)"
        }
        reload()
    }

    @objc private func selectClicked(_ sender: Any?) {
        guard let entry = selectedEntry else {
            presentAlert(title: "先选一个模型", body: "在上面的清单里选一行，再设为当前模型。")
            return
        }
        guard entry.purpose == "embedding" else {
            presentAlert(title: "只能选嵌入模型", body: "向量检索用的是嵌入模型。")
            return
        }
        guard entry.usable else {
            presentAlert(title: "这个模型还不能用",
                         body: entry.linkProblem ?? "还没装：先「下载」、「从本地目录导入」或「关联外部目录」。")
            return
        }
        let status = recorder?.withStore { try? $0.vectorStatus() } ?? nil
        let indexedModel = status?.model
        let embedded = status?.embeddedChunks ?? 0
        var rebuild = false
        if let indexedModel, indexedModel != entry.id, embedded > 0 {
            // 向量不能跨模型比较：旧索引留着只会给出错的结果。
            let alert = NSAlert()
            alert.messageText = "换成 \(entry.id)？"
            alert.informativeText =
                "现在的 \(embedded) 块向量是用 \(indexedModel) 建的。不同模型的向量不能互相比较，"
                + "换模型必须重建索引（证据、台账、全文检索都不受影响，只是要重新跑一遍嵌入任务）。"
            alert.addButton(withTitle: "换并重建索引")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            rebuild = true
        }
        EmbeddingSelection.select(entry.id)
        var text = "当前模型已设为 \(entry.id)"
        if rebuild {
            let removed = recorder?.withStore { try $0.rebuildEmbeddings() } ?? nil
            text += "，索引已清空（\(removed ?? 0) 块），下次嵌入任务从头建"
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

    /// M2 d / T15：一次性动作「现在开始建索引」。跑着的时候这个按钮就是「取消」。
    @objc private func overnightClicked(_ sender: Any?) {
        if OvernightIndexJob.shared.isRunning {
            OvernightIndexJob.shared.cancel()
            lastAction = "已请求取消整晚建索引（当前这一批跑完就停）"
            reload()
            return
        }
        guard let root = currentState().modelsRoot else { return }
        let alert = NSAlert()
        alert.messageText = "现在开始建索引？"
        alert.informativeText = """
            会连续跑到全部块嵌完或你取消，可能要几小时（1 个月合成库实测 1 小时 32 分）。
            只放开「空闲 5 分钟」这道门：**仍然要求接电**，机器偏热会自动暂停、真烫了会停，\
            锁库 / 暂停采集也会停。这次的 GPU 时间单独记账，不占夜间增量的 10 分钟日预算。
            """
        alert.addButton(withTitle: "开始")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if OvernightIndexJob.shared.start(modelsRoot: root, recorder: recorder) {
            lastAction = "整晚建索引已开始（进度写进 jobs 与事件）"
            startOvernightRefresh()
        } else {
            lastAction = "整晚建索引已经在跑了"
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
