import AppKit
import BrosisCore
import Foundation

/// 3.12「应用采集清单」窗口（设置里那一页L("应用", "App")）。
///
/// 判定逻辑一行都不在这里——合并 / 分组 / 排序 / 过滤 / 改档状态机全在
/// `PolicyList.swift`（纯函数，自检整段跑）。这个文件只做三件事：
/// **把行画出来、把点击转成一次调用、把结果显示回去**。
///
/// 三条口径写在最前面：
/// 1. **改档要库开着**。`app_policies` 在库里，锁定期间写不进去；这时候整列弹出菜单是灰的，
///    顶部横幅说明原因。（3.12 的「今日暂停」是 UserDefaults，锁定期间照常能用，走菜单栏。）
/// 2. **改为更低档时先写档、再问要不要删已有数据，默认不删**（3.12 最后一条）。
///    删走 `Store.deleteByApp(reason: .policy)`，也就是 3.8 的按应用删除并级联，
///    删完把条数显示出来。
/// 3. **窗口自己不开库**。所有读写都经 `Recorder.withStore`，与采集端同一个 `Store` 实例。
@MainActor
final class PoliciesWindowController: NSObject, NSWindowDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate {

    static let shared = PoliciesWindowController()

    // MARK: - 接入（由 AppDelegate 调一次）

    private var recorder: Recorder?
    private var policyStore: CapturePolicyStore = .shared
    /// 改完档通知 AppDelegate，让它把新档位推给 `CaptureController`（生效方式在采集时）。
    private var onModeChanged: ((String, CapturePolicyMode) -> Void)?

    func configure(recorder: Recorder,
                   policyStore: CapturePolicyStore = .shared,
                   onModeChanged: @escaping (String, CapturePolicyMode) -> Void) {
        self.recorder = recorder
        self.policyStore = policyStore
        self.onModeChanged = onModeChanged
    }

    // MARK: - 界面元素

    private var window: NSWindow?

    /// 界面语言换了就把窗口关掉：contentView 是打开时一次性搭出来的，
    /// 就地把每个控件的文案换一遍既繁琐又容易漏，重开一次就全对了。
    func closeForLanguageChange() {
        window?.close()
        window = nil
    }
    private var tableView: NSTableView?
    private var searchField: NSSearchField?
    private var globalDefaultPopUp: NSPopUpButton?
    private var bannerLabel: NSTextField?
    private var footerLabel: NSTextField?

    /// 表格里真正显示的东西：分组标题行 + 应用行。
    private enum DisplayItem {
        case header(PolicyGroup, count: Int)
        case app(PolicyListRow)
    }

    private var items: [DisplayItem] = []
    private var query: String = ""
    /// 最近一次操作的回显（删除条数、被挡下的改档等）。
    private var lastActionNote: String?

    // MARK: - 打开

    /// 菜单项与新应用提示都调它。`select` 非空时打开后定位到那一行并选中。
    func present(select bundleID: String? = nil) {
        if window == nil { buildWindow() }
        reload(select: bundleID)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 构建窗口

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_140, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("应用采集清单", "App capture list")
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 360)

        // ---- 顶部：全局默认档 + 搜索框 + 刷新
        let defaultLabel = staticLabel(L("新应用的全局默认档：", "Default mode for new apps:"))
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        for mode in CapturePolicyMode.allCases { popUp.addItem(withTitle: mode.label) }
        popUp.target = self
        popUp.action = #selector(globalDefaultChanged(_:))
        popUp.toolTip = L("只影响以后才第一次出现的应用；已经在清单里的应用不受影响。", "Applies only to apps seen for the first time from now on; apps already listed are unaffected.")
        globalDefaultPopUp = popUp

        let search = NSSearchField()
        search.placeholderString = L("按应用名或 bundle id 过滤", "Filter by app name or bundle id")
        search.target = self
        search.action = #selector(searchChanged(_:))
        search.sendsSearchStringImmediately = true
        search.sendsWholeSearchString = false
        searchField = search

        let refresh = NSButton(title: L("刷新", "Refresh"), target: self, action: #selector(refreshClicked(_:)))
        refresh.bezelStyle = .rounded

        // 中间那个空 NSView 是弹簧：把搜索框和刷新按钮推到右边。
        // 它必须是全场最不"抱紧内容"的那个，否则被压成 0 宽，右边两个控件就贴在左边了。
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),
                                                       for: .horizontal)
        let topRow = NSStackView(views: [defaultLabel, popUp, spacer, search, refresh])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        topRow.alignment = .centerY
        topRow.distribution = .fill
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        // ---- 横幅（库锁着 / 权限之类的说明）
        let banner = staticLabel("")
        banner.textColor = .systemOrange
        banner.lineBreakMode = .byWordWrapping
        banner.maximumNumberOfLines = 2
        bannerLabel = banner

        // ---- 表格
        let table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 26
        table.allowsMultipleSelection = false
        table.style = .inset
        // 程序化建的 NSTableView 默认没有表头，列名就不显示了。NSScrollView 会自动
        // 把 documentView 的 headerView 放到滚动区上方，所以只要给它一个就行。
        table.headerView = NSTableHeaderView()
        table.floatsGroupRows = true
        for spec in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.width = spec.width
            column.minWidth = 60
            table.addTableColumn(column)
        }
        tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false

        // ---- 底部：一行说明 + 一行回显
        let footer = staticLabel("")
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byWordWrapping
        footer.maximumNumberOfLines = 3
        footerLabel = footer

        let stack = NSStackView(views: [topRow, banner, scroll, footer])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        topRow.setContentHuggingPriority(.defaultHigh, for: .vertical)
        banner.setContentHuggingPriority(.defaultHigh, for: .vertical)
        footer.setContentHuggingPriority(.defaultHigh, for: .vertical)

        window.contentView = stack
        self.window = window
    }

    private struct ColumnSpec {
        var id: String
        var title: String
        var width: CGFloat
    }

    private static let columns: [ColumnSpec] = [
        ColumnSpec(id: "name", title: L("应用", "App"), width: 180),
        ColumnSpec(id: "bundle", title: "bundle id", width: 230),
        ColumnSpec(id: "group", title: L("分组", "Group"), width: 110),
        ColumnSpec(id: "mode", title: L("采集模式", "Capture mode"), width: 132),
        ColumnSpec(id: "observations", title: L("最近 7 天观察", "Last 7 days"), width: 96),
        ColumnSpec(id: "completeness", title: L("完整性分布", "Completeness"), width: 360),
        ColumnSpec(id: "lastSeen", title: L("最近出现", "Last seen"), width: 96),
        ColumnSpec(id: "status", title: L("状态", "Status"), width: 170),
    ]

    private func staticLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    // MARK: - 取数与刷新

    /// 库开着吗。改档、删数据都以它为准。
    private var isStoreOpen: Bool { recorder?.isOpen == true }

    /// 三处数据源合并成显示行。**只有这一处读库**。
    private func loadRows() -> [PolicyListRow] {
        let since = Recorder.milliseconds(
            Date().addingTimeInterval(-Double(PolicyList.statsWindowDays) * 86_400))
        let loaded = recorder?.withStore { store -> ([AppPolicyRecord], [AppObservationStats],
                                                     [String: String]) in
            (try store.appPolicies(),
             try store.appObservationStats(since: since),
             try store.appNames())
        }
        return PolicyList.build(
            policies: loaded?.0 ?? [],
            stats: loaded?.1 ?? [],
            names: loaded?.2 ?? [:],
            running: Self.runningGUIApps(),
            temporaryPauses: policyStore.temporaryPauses(),
            globalDefault: policyStore.globalDefault,
            query: query,
            isDenylisted: { BuiltinDenylist.shared.contains($0) },
            adapterID: { bundleID in
                let rule = AdapterRegistry.rule(for: bundleID)
                return rule.id == AdapterRegistry.generic.id ? nil : rule.id
            })
    }

    /// 当前运行的 GUI 应用（3.12 的第三个数据源）。
    /// `activationPolicy == .regular` 就是"有 Dock 图标、有菜单栏"的那种，
    /// 后台守护进程与 `LSUIElement`（包括本应用自己）不算。**这个 API 不需要任何权限**。
    static func runningGUIApps() -> [PolicyList.RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
                  bundleID != BuildInfo.bundleIdentifier else { return nil }
            return PolicyList.RunningApp(bundleID: bundleID,
                                         name: app.localizedName ?? bundleID)
        }
    }

    /// 重建 `items`（分组标题 + 应用行）并刷新界面。
    private func reload(select bundleID: String? = nil) {
        let rows = loadRows()
        var built: [DisplayItem] = []
        for group in PolicyGroup.allCases {
            let inGroup = rows.filter { $0.group == group }
            guard !inGroup.isEmpty else { continue }
            built.append(.header(group, count: inGroup.count))
            built.append(contentsOf: inGroup.map { DisplayItem.app($0) })
        }
        items = built

        globalDefaultPopUp?.selectItem(at: CapturePolicyMode.allCases
            .firstIndex(of: policyStore.globalDefault) ?? 0)

        bannerLabel?.stringValue = isStoreOpen
            ? ""
            : L("数据库未打开（锁定 / 解锁中）：读不到 app_policies，下面只有当前运行的应用，"
                + "并且不能改档。先在菜单栏点「解锁数据库…」。",
                "Database not open (locked or unlocking): app_policies is unreadable, so only "
                + "currently running apps are listed and modes cannot be changed. "
                + "Choose “Unlock database…” from the menu bar first.")
        bannerLabel?.isHidden = isStoreOpen

        let total = rows.count
        var footer = L("共 \(total) 个应用；观察数与完整性分布统计的是最近 "
                       + "\(PolicyList.statsWindowDays) 天、未删除的本机观察。"
                       + "改为更低档时会问是否删除该应用已有数据（默认不删）。",
                       "\(total) apps. Counts and completeness cover the last "
                       + "\(PolicyList.statsWindowDays) days of undeleted local observations. "
                       + "Lowering an app’s mode asks whether to delete its existing data "
                       + "(kept by default).")
        if let lastActionNote { footer += "\n" + lastActionNote }
        footerLabel?.stringValue = footer

        tableView?.reloadData()

        guard let bundleID, let index = items.firstIndex(where: {
            if case .app(let row) = $0 { return row.bundleID == bundleID }
            return false
        }) else { return }
        tableView?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView?.scrollRowToVisible(index)
    }

    // MARK: - 动作

    @objc private func refreshClicked(_ sender: Any?) {
        lastActionNote = nil
        reload()
    }

    @objc private func searchChanged(_ sender: Any?) {
        query = searchField?.stringValue ?? ""
        reload()
    }

    @objc private func globalDefaultChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0 && index < CapturePolicyMode.allCases.count else { return }
        let mode = CapturePolicyMode.allCases[index]
        policyStore.setGlobalDefault(mode)
        lastActionNote = L("全局默认档已设为「\(mode.label)」；"
                           + "它只影响以后才第一次出现的应用，已经在清单里的应用不受影响。",
                           "Default mode for new apps is now “\(mode.label)”. It applies only to apps "
                           + "seen for the first time from now on; apps already listed are unaffected.")
        reload()
    }

    /// 某一行的档位弹出菜单。整个 3.12 最后一条（降档时问删数据）都在这里。
    @objc private func rowModeChanged(_ sender: PolicyModePopUpButton) {
        guard let bundleID = sender.bundleID else { return }
        let index = sender.indexOfSelectedItem
        guard index >= 0 && index < CapturePolicyMode.allCases.count else { return }
        let next = CapturePolicyMode.allCases[index]
        let current = sender.currentMode

        // 全库计数只在真要弹框之前问一次（按 app_id 索引，不是全表扫）。
        let existing = recorder?.withStore { try $0.appObservationCount(bundleID: bundleID) } ?? 0
        let plan = PolicyModeChange.plan(current: current, next: next,
                                         storeOpen: isStoreOpen, existingObservations: existing)
        switch plan {
        case .unchanged:
            return
        case .blockedLocked:
            lastActionNote = L("数据库未打开，改档没有生效（app_policies 写不进去）。",
                               "Database not open — the mode change did not take effect "
                               + "(app_policies cannot be written).")
            presentAlert(title: L("数据库未打开", "Database not open"),
                         body: L("「\(bundleID)」的档位没有改动。\n\n"
                                 + "三档存在库里的 app_policies 表，锁定期间写不进去。"
                                 + "先在菜单栏点「解锁数据库…」再来改。\n\n"
                                 + "（想立刻停掉当前应用的采集，可以用菜单栏的"
                                 + "「暂停采集当前应用 → 今天」，它不需要开库。）",
                                 "The mode for “\(bundleID)” was not changed.\n\n"
                                 + "Capture modes live in the app_policies table inside the encrypted "
                                 + "database, which cannot be written while locked. Choose "
                                 + "“Unlock database…” from the menu bar, then try again.\n\n"
                                 + "(To stop capturing the current app right now, use "
                                 + "“Pause capture for the current app → Today” in the menu bar — "
                                 + "that does not need the database.)"))
            reload()
            return
        case .apply:
            applyMode(next, bundleID: bundleID)
            lastActionNote = L("「\(bundleID)」已设为「\(next.label)」。",
                               "“\(bundleID)” set to “\(next.label)”.")
        case .applyThenAskDelete(let count):
            applyMode(next, bundleID: bundleID)
            lastActionNote = L("「\(bundleID)」已从「\(current.label)」改为「\(next.label)」。",
                               "“\(bundleID)” changed from “\(current.label)” to “\(next.label)”.")
            askDeleteExistingData(bundleID: bundleID, from: current, to: next, existing: count)
        }
        reload()
    }

    /// 写档 + 通知采集端。**唯一会覆盖 `app_policies` 已有行的路径**（`source = user`）。
    private func applyMode(_ mode: CapturePolicyMode, bundleID: String) {
        policyStore.setMode(mode, bundleID: bundleID, source: .user)
        onModeChanged?(bundleID, mode)
    }

    /// 3.12：「改为更低档时询问是否删除该应用已有数据，走 3.8 的按应用删除并级联；**默认不删**」。
    ///
    /// 默认按钮是「保留数据」（第一个加进去的按钮就是默认按钮，回车落在它上面）。
    private func askDeleteExistingData(bundleID: String, from: CapturePolicyMode,
                                       to: CapturePolicyMode, existing: Int) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("要一并删除「\(bundleID)」已有的数据吗？",
                              "Also delete the existing data for “\(bundleID)”?")
        alert.informativeText = """
            档位已经从「\(from.label)」改成「\(to.label)」，从现在起按新档采集。

            这个应用在库里还有 \(existing) 条未删除的观察（含它们的正文、索引与缩略图）。
            删除会按 3.8 的按应用删除级联执行，「不可撤销」，并且会把用到这些观察的\
            会话与日台账标为待重建。

            默认不删：以前记下来的东西留着，只是以后不再按旧档采集。
            """
        alert.addButton(withTitle: L("保留数据", "Keep data"))          // 默认按钮（回车）
        alert.addButton(withTitle: L("删除这 \(existing) 条", "Delete \(existing) records"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else {
            lastActionNote = (lastActionNote ?? "") + L("已有的 \(existing) 条数据保留。",
                                                        "Kept the \(existing) existing records.")
            recorder?.logEvent(kind: "app_policy_downgrade_kept_data",
                               detail: "bundle=\(bundleID) from=\(from.rawValue) "
                                     + "to=\(to.rawValue) observations=\(existing)")
            return
        }

        guard let summary = recorder?.withStore({ store -> DeletionSummary in
            try store.deleteByApp(bundleID: bundleID, reason: .policy)
        }) else {
            lastActionNote = L("删除失败：数据库在这一步不可用，数据没有变化。", "Delete failed: the database was unavailable at this step; nothing changed.")
            presentAlert(title: L("删除失败", "Delete failed"),
                         body: L("「\(bundleID)」的数据没有变化。数据库在执行删除时不可用。",
                                 "Nothing changed for “\(bundleID)”. The database was unavailable "
                                 + "while performing the delete."))
            return
        }
        recorder?.logEvent(
            kind: "app_policy_downgrade_deleted",
            detail: "bundle=\(bundleID) from=\(from.rawValue) to=\(to.rawValue) "
                  + "observations=\(summary.observationsAffected) "
                  + "text_versions=\(summary.textVersionsDeleted) "
                  + "fts=\(summary.ftsRowsDeleted) bytes=\(summary.bytesFreed)")
        lastActionNote = (lastActionNote ?? "")
            + "已删除 \(summary.observationsAffected) 条观察、"
            + "\(summary.textVersionsDeleted) 个文本版本、\(summary.ftsRowsDeleted) 行索引，"
            + "释放 \(summary.bytesFreed) 字节；"
            + "\(summary.sessionsStale) 个会话与 \(summary.ledgersStale) 条日台账标为待重建。"
    }

    private func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: L("好", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < items.count, case .header = items[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < items.count else { return nil }
        switch items[row] {
        case .header(let group, let count):
            // 分组标题行。AppKit 一般对 group row 只问一次（tableColumn == nil），
            // 但不同样式下也可能逐列来问——两种都接住，标题只画在第一列，其余列返回 nil，
            // 免得整行重复出现同一句话。
            let isFirstColumn = tableColumn?.identifier.rawValue == Self.columns[0].id
            guard tableColumn == nil || isFirstColumn else { return nil }
            let field = NSTextField(labelWithString: "\(group.title)（\(count)）")
            field.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
            return field
        case .app(let appRow):
            guard let tableColumn else { return nil }
            return view(for: appRow, column: tableColumn.identifier.rawValue)
        }
    }

    private func view(for row: PolicyListRow, column: String) -> NSView? {
        switch column {
        case "name":
            return label(row.name, tooltip: row.name)
        case "bundle":
            let field = label(row.bundleID, tooltip: row.bundleID)
            field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.textColor = .secondaryLabelColor
            return field
        case "group":
            let text = row.adapterID.map { "有适配器 · \($0)" } ?? row.group.title
            return label(text, tooltip: row.adapterID.map {
                "适配规则 \($0)：\(AdapterRegistry.rule(for: row.bundleID).name)"
            })
        case "mode":
            let popUp = PolicyModePopUpButton(frame: .zero, pullsDown: false)
            for mode in CapturePolicyMode.allCases { popUp.addItem(withTitle: mode.label) }
            popUp.bundleID = row.bundleID
            popUp.currentMode = row.mode
            popUp.selectItem(at: CapturePolicyMode.allCases.firstIndex(of: row.mode) ?? 0)
            popUp.target = self
            popUp.action = #selector(rowModeChanged(_:))
            popUp.isEnabled = isStoreOpen
            popUp.toolTip = isStoreOpen
                ? (row.temporaryUntil == nil
                    ? nil
                    : "这个应用现在被「今日暂停」临时压成「不采集」；这里显示的是暂停结束后回到的那一档。")
                : "数据库未打开，改档写不进 app_policies。"
            return popUp
        case "observations":
            let field = label(row.observations == 0 ? "0" : "\(row.observations)")
            field.alignment = .right
            return field
        case "completeness":
            return label(row.completenessLabel, tooltip: row.completenessLabel)
        case "lastSeen":
            return label(row.lastSeenLabel())
        case "status":
            let text = row.statusLabel()
            let field = label(text, tooltip: text)
            if row.temporaryUntil != nil { field.textColor = .systemOrange }
            return field
        default:
            return nil
        }
    }

    private func label(_ text: String, tooltip: String? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = tooltip
        return field
    }
}

/// 每一行的档位弹出菜单。带上它是哪个应用、原来是哪一档——
/// 用 `tag` 记行号在表格重排 / 过滤之后会指错行，改档指错应用是不能接受的错误。
final class PolicyModePopUpButton: NSPopUpButton {
    var bundleID: String?
    var currentMode: CapturePolicyMode = .eventsAndContent
}
