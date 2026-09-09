import AppKit
import BrosisCore
import Foundation
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private let recorder = Recorder()
    private var lock: LockController?
    private var capture: CaptureController?
    private var events: EventSkeleton?
    private var lastCaptureError: String?
    private var guide: PermissionGuide?
    /// 3.9 跨设备同步（c 批 T13）。挂在锁定状态机上，只在 unlocked 相位跑循环。
    private var sync: SyncController?
    /// d 批 T16：加密导出窗口与配额"先加密导出"联动。
    private var exportController: ExportController?
    /// 最近一次前台的**非本应用**：菜单里「暂停采集当前应用」要用它。
    /// 不能在菜单打开时现问 `frontmostApplication`——点状态栏图标本身会让本应用成为前台。
    private var foregroundBundleID: String?
    private var foregroundName: String?
    /// `app_launched` 只在本次进程第一次开库成功时写一条（见 `lock.onUnlocked`）。
    private var didLogLaunch = false
    /// 最近一次「导出存储统计…」的结果，只在菜单里回显一行。
    private var lastStatsExport: String?

    /// 语言变更观察者的 token，`applicationWillTerminate` 里撤掉。
    private var languageObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 必须在任何 AX 读取之前装上进程级全局 0.5 s 超时（见 AXSupport 的说明）。
        // 这一步不弹窗、不需要权限。
        let axTimeoutError = AX.installGlobalMessagingTimeout()

        // 系统语言变了，`.system` 档的解析结果要跟着变（缓存得作废）。
        // 窗口怎么关不在这里点名——各窗口在搭好时自己向 L10n 登记，见 L10n.onLanguageChange。
        languageObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil) { _ in
            L10n.invalidate()
        }

        let lock = LockController(recorder: recorder)
        self.lock = lock
        lock.onChange = { [weak self] in self?.refreshMenu() }
        lock.onUnlocked = { [weak self] in
            guard let self else { return }
            // 进入 unlocked 的路径不止启动一条（醒来、菜单解锁、屏幕解锁都会再进来一次），
            // 所以「本次进程启动」这两条只写第一次；之后写的是 store_unlocked。
            if self.didLogLaunch {
                self.recorder.logEvent(
                    kind: "store_unlocked",
                    detail: "dir=\(lock.directory.lastPathComponent) "
                          + "dir_source=\(lock.directorySource)")
            } else {
                self.didLogLaunch = true
                self.recorder.logEvent(
                    kind: "app_launched",
                    detail: "version=\(BuildInfo.version) dir=\(lock.directory.lastPathComponent) "
                          + "dir_source=\(lock.directorySource)")
                self.recorder.logEvent(
                    kind: "ax_global_timeout_installed",
                    detail: "timeout=\(AX.messagingTimeout)s scope=process(system-wide) "
                          + "AXError=\(axTimeoutError.rawValue)"
                          + (axTimeoutError == .success ? "(success)" : "(FAILED)"))
                // 模型根目录 2026-09-08 从 `<数据目录>/../models` 挪进 `<数据目录>/models`，
                // 本进程搬一次（幂等；库这时已开，所以事件写得进去）。
                ModelsWindowController.shared.migrateModelsRootIfNeeded()
            }
            self.syncSubsystems()
        }
        lock.onLocking = { [weak self] in self?.stopSubsystems(reason: "locking") }

        // c 批接线（tools/bench/results/m2_c_{vectors,sync,narrative}_2026-09-08.md 各自的「接入方式」）：
        // 同步控制器链式挂到上面两个回调之后（它自己保留原回调，不覆盖）；
        // 模型面板与嵌入调度器只登记依赖，开关默认关，关着时定时器什么都不做。
        // 调度器在 utility 队列上 tick，而 LockController 是 MainActor 的，所以读快照要回主线程。
        let sync = SyncController()
        sync.install(lock: lock, recorder: recorder)
        self.sync = sync
        let lockSnapshot = makeLockSnapshotReader()
        ModelsWindowController.shared.configure(recorder: recorder, lockSnapshot: lockSnapshot)
        // 自动建索引（2026-09-08 用户要求：打开时跑一次、之后每小时一次）。
        // 只登记依赖；真正的启停跟着锁定状态走（见 syncSubsystems / stopSubsystems）。
        AutoIndexScheduler.shared.configure(recorder: recorder)
        // D33：MCP 集成窗口（把 brosis 注册进各家 harness 的用户级配置 + 发 grant）。
        MCPIntegrationWindowController.shared.configure(recorder: recorder)
        // 2026-09-09：同一件事的自动版，默认开。只登记依赖，启停跟着锁定状态走。
        MCPAutoIntegration.shared.configure(recorder: recorder)
        // D34：设置窗口 + 配额执行。配额此前只显示不执行（expireWithNotice 没人调），这里接上。
        SettingsWindowController.shared.configure(recorder: recorder)
        // 2026-09-08：用户决定不要叙述功能，夜间叙述调度器**不再接线、不再启动**，
        // 菜单里也没有入口。core / app 里的叙述代码原样留着（休眠，自检仍跑它的纯逻辑用例），
        // 将来要恢复：装回生成模型、把清单条目加回 catalog.json、恢复这两行与 narrativeMenuItem()。

        // d 批接线（tools/bench/results/m2_d_{export,focus_hotkey}_2026-09-08.md 的「接入方式」）：
        // 加密导出只存一个 weak recorder；全局热键 ⌃⌥⌘P 暂停 / 继续、⌃⌥⌘L 锁定，
        // 处理器只转发到现有 togglePause / lockNow。
        // 2026-09-08：Focus（专注模式）联动整条删除，这里不再有 FocusMonitor。
        let exportController = ExportController()
        exportController.install(recorder: recorder)
        self.exportController = exportController
        // D34：配额执行接在导出控制器之后——到线且通知未确认时它要弹加密导出窗口。
        QuotaScheduler.shared.configure(recorder: recorder, exporter: exportController)
        _ = HotKeys.shared.install(recorder: recorder,
                                   onPause: { [weak lock] in lock?.togglePause() },
                                   onLock: { [weak lock] in lock?.lockNow() })

        // 3.12 的应用采集清单窗口。**这里只是接线，不创建窗口**——
        // 窗口在用户第一次点菜单项时才建（LSUIElement 的进程不该在启动时拉起 AppKit 窗口）。
        PoliciesWindowController.shared.configure(recorder: recorder) { [weak self] bundleID, mode in
            guard let self else { return }
            // 「生效方式在采集时」：改完档立刻把新档位推给截图侧，不等下一次前台切换。
            if bundleID == self.foregroundBundleID {
                self.capture?.setFrontmostApp(bundleID: bundleID, mode: mode)
            }
            self.refreshMenu()
        }

        buildStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != BuildInfo.bundleIdentifier {
            foregroundBundleID = frontmost.bundleIdentifier
            foregroundName = frontmost.localizedName
        }

        BrosisLog.lifecycle.notice(
            "启动 version=\(BuildInfo.version, privacy: .public) pid=\(ProcessInfo.processInfo.processIdentifier)")
        lock.start()
        // 3.5：登录 / 启动 → unlocking（取钥、开库、校验）。
        // 首次运行这一步会弹一次钥匙串授权对话框（data-protection 钥匙串 + ACL 限本应用）。
        lock.apply(.launch)

        let permissions = Permissions.snapshot()
        if !permissions.allGranted {
            // 启动时权限缺失就直接触发系统授权框并显示引导窗口。
            recorder.logEvent(kind: "permission_missing", detail: permissions.missingDescription)
            refreshMenu()
            promptForPermissions(reason: "launch")
            return
        }
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 正常退出留一行：没有这行时"进程不见了"分不清是自己退的还是被杀的（2026-09-08 踩过）。
        BrosisLog.lifecycle.notice("正常退出（applicationWillTerminate）")
        _ = HotKeys.shared.uninstall()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        events?.stop()
        events = nil
        if let capture {
            // 注意：这里不能写 `Task { await capture.stop() }`——在 @MainActor 上下文里创建的 Task
            // 继承 MainActor 隔离，而主线程正被 semaphore.wait 挡住，任务根本没机会开始。
            // CaptureController.stop 是 nonisolated async，用 Task.detached 放到后台执行器上跑。
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await capture.stop(reason: "app_terminating")
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
        }
        // 3.5 locking 的同步版：flush + checkpoint + 关库 + 清零密钥。
        lock?.stop()
        lock?.shutdown()
    }

    @objc private func applicationActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != BuildInfo.bundleIdentifier else { return }
        foregroundBundleID = bundleID
        foregroundName = app.localizedName
        capture?.setFrontmostApp(bundleID: bundleID,
                                 mode: CapturePolicyStore.shared.resolve(bundleID: bundleID).mode)
    }

    // MARK: - 子系统随锁定状态开合

    /// 只有 `unlocked` 且没有任何暂停原因时才采集（3.5：`paused` 子状态下库开着但采集停）。
    private func syncSubsystems() {
        guard let lock else { return }
        let permissions = Permissions.snapshot()
        let recording = lock.snapshot.isRecording

        if recording && permissions.accessibility {
            if events == nil { startEventSkeleton() }
        } else if let running = events {
            running.stop()
            events = nil
        }

        // 自动建索引：库解锁着就让它的定时器跑（首次延迟 20 s，之后每小时）；
        // 其余状态一律停"踢"，正在跑的任务由 OvernightIndexPolicy 的 locked_* / paused 收尾。
        // **只在解锁时起，暂停时不停**：`syncSubsystems` 每次锁屏 / 屏保 / 用户暂停都会跑，
        // 而 start() 是按"现在 + 首次延迟"重排的——停了再起等于把「每小时」变成
        // 「每次解锁后 20 秒」。两个调度器的 tick 自己都会判 locked / paused 直接跳过，
        // 空转一次的代价接近零，所以让 timer 一直挂着更省。关库时由 stopSubsystems 停。
        if lock.snapshot.phase == .unlocked {
            AutoIndexScheduler.shared.start()
            QuotaScheduler.shared.start()
            MCPAutoIntegration.shared.start()
        }

        if recording && permissions.screenRecording {
            if capture?.isRunning != true { startCapture(displayID: capture?.currentDisplayID) }
            capture?.setPaused(false)
        } else {
            capture?.setPaused(true)
        }
        refreshMenu()
    }

    private func stopSubsystems(reason: String) {
        AutoIndexScheduler.shared.stop()
        QuotaScheduler.shared.stop()
        MCPAutoIntegration.shared.stop()
        events?.stop()
        events = nil
        guard let capture else { return }
        Task.detached { await capture.stop(reason: reason) }
    }

    private func startEventSkeleton() {
        let skeleton = EventSkeleton(recorder: recorder,
                                     onFocusChanged: { [weak self] displayID in
                                         self?.focusMovedToDisplay(displayID)
                                     },
                                     onContentChanged: { [weak self] reason in
                                         self?.capture?.requestCapture(reason: reason)
                                     })
        skeleton.start()
        events = skeleton
    }

    private func startCapture(displayID: UInt32?) {
        if capture == nil {
            capture = CaptureController(recorder: recorder) { [weak self] event in
                Task { @MainActor in self?.handleCaptureEvent(event) }
            }
            if let bundleID = foregroundBundleID {
                capture?.setFrontmostApp(bundleID: bundleID,
                                         mode: CapturePolicyStore.shared.mode(for: bundleID))
            }
        }
        guard let capture else { return }
        Task { @MainActor in
            do {
                try await capture.start(displayID: displayID)
                self.lastCaptureError = nil
            } catch {
                self.lastCaptureError = "\(error)"
            }
            self.refreshMenu()
        }
    }

    /// 焦点换到另一台显示器：按需截图只需换目标显示器并补一张。
    private func focusMovedToDisplay(_ displayID: UInt32?) {
        guard let displayID, lock?.snapshot.isRecording == true else { return }
        guard let capture, capture.currentDisplayID != displayID else { return }
        capture.setDisplay(displayID)
        capture.requestCapture(reason: "display_changed")
    }

    private func handleCaptureEvent(_ event: CaptureEvent) {
        switch event {
        case .started:
            break
        case .stopped(let reason, let permissionLost):
            lastCaptureError = reason
            if permissionLost {
                // 月度再授权到期或用户撤销：立刻弹出引导（与启动时同一套）。
                promptForPermissions(reason: "permission_lost")
            }
        }
        refreshMenu()
    }

    // MARK: - 权限引导

    /// 启动 / 权限丢失 / 菜单「请求权限…」共用的入口：先直接触发系统授权框，再显示引导窗口。
    /// 这是本进程里唯一会弹 TCC 框的路径（`--self-check` 与构建流程走不到这里）。
    private func promptForPermissions(reason: String) {
        let before = Permissions.snapshot()
        recorder.logEvent(kind: "permission_request_started",
                          detail: "reason=\(reason) missing=\(before.missingDescription)")
        triggerSystemPrompts(before)

        if guide == nil {
            guide = PermissionGuide(
                onAllGranted: { [weak self] in self?.permissionsBecameComplete(source: "guide") },
                onRerequest: { [weak self] in
                    guard let self else { return }
                    self.triggerSystemPrompts(Permissions.snapshot())
                },
                log: { [weak self] kind, detail in self?.recorder.logEvent(kind: kind, detail: detail) })
        }
        guide?.show()

        let after = Permissions.snapshot()
        recorder.logEvent(kind: "permission_request_finished",
                          detail: "screen=\(after.screenRecording) ax=\(after.accessibility)")
        if after.allGranted {
            permissionsBecameComplete(source: reason)
        } else {
            recorder.logEvent(kind: "permission_request_pending",
                              detail: "引导窗口每 1.5 s 复查；屏幕录制授权后可能要求退出重开 app")
        }
        refreshMenu()
    }

    /// 缺哪项就弹哪项的系统授权框；被拒绝过（系统不再弹）时退回到直接打开设置面板。
    private func triggerSystemPrompts(_ snapshot: Permissions.Snapshot) {
        if !snapshot.accessibility {
            if !Permissions.requestAccessibility() { Permissions.openAccessibilitySettings() }
        }
        if !snapshot.screenRecording {
            // 稍后再弹屏幕录制，避免两个系统对话框完全叠在一起。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                if !Permissions.requestScreenRecording() {
                    try? await Task.sleep(for: .seconds(2))
                    if !Permissions.snapshot().screenRecording { Permissions.openScreenRecordingSettings() }
                }
            }
        }
    }

    private func permissionsBecameComplete(source: String) {
        recorder.logEvent(kind: "permission_regained", detail: "source=\(source)")
        guide?.close()
        syncSubsystems()
    }

    // MARK: - 菜单栏

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle",
                                     accessibilityDescription: "brosis")
        let menu = NSMenu()
        // 权限是在系统设置里改的，app 收不到通知：每次菜单打开前重新取一次快照。
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if Permissions.snapshot().allGranted { syncSubsystems() }
        refreshMenu()
    }

    /// 菜单栏可见状态（2.2 硬约束 2）：**录制 / 暂停 / 锁定 / 权限缺失**四选一。
    private var statusTitle: String {
        let permissions = Permissions.snapshot()
        if !permissions.allGranted { return L("权限缺失（\(permissions.missingDescription)）", "Missing permissions (\(permissions.missingDescription))") }
        guard let snapshot = lock?.snapshot else { return L("锁定", "Locked") }
        switch snapshot.phase {
        case .locked:    return L("锁定", "Locked")
        case .unlocking: return L("解锁中", "Unlocking")
        case .locking:   return L("锁定中", "Locking")
        case .unlocked:  return snapshot.isPaused ? L("暂停（\(snapshot.pauseDescription)）", "Paused (\(snapshot.pauseDescription))") : L("录制", "Recording")
        }
    }

    private var statusSymbol: String {
        let permissions = Permissions.snapshot()
        if !permissions.allGranted { return "exclamationmark.triangle" }
        guard let snapshot = lock?.snapshot else { return "lock.circle" }
        switch snapshot.phase {
        case .unlocked: return snapshot.isPaused ? "pause.circle" : "record.circle"
        default:        return "lock.circle"
        }
    }

    private func refreshMenu() {
        guard let statusItem, let menu = statusItem.menu, let lock else { return }
        statusItem.button?.image = NSImage(systemSymbolName: statusSymbol,
                                           accessibilityDescription: "brosis")
        menu.removeAllItems()

        let permissions = Permissions.snapshot()
        menu.addItem(disabledItem("brosis \(BuildInfo.version) · \(BuildInfo.stage)"))
        // 先取到本地：statusTitle 会再做一次权限 snapshot（CGPreflightScreenCaptureAccess
        // 要走 WindowServer、AXIsProcessTrusted 要走 TCC），放进 L() 会被求值两次。
        let status = statusTitle
        menu.addItem(disabledItem(L("状态：\(status)", "Status: \(status)")))
        menu.addItem(disabledItem(L("数据库：\(lock.snapshot.phase.rawValue)（\(lock.directory.lastPathComponent)，来源 \(lock.directorySource)）",
                                       "Database: \(lock.snapshot.phase.rawValue) (\(lock.directory.lastPathComponent), source \(lock.directorySource))")))
        if let error = lock.lastError {
            menu.addItem(disabledItem(L("开库失败：\(error.prefix(70))", "Could not open database: \(error.prefix(70))")))
        }
        menu.addItem(disabledItem(L("写入：\(recorder.stats.summary)", "Writes: \(recorder.stats.summary)")))
        menu.addItem(disabledItem(L("屏幕录制：", "Screen Recording: ")
                             + (permissions.screenRecording ? L("已授权", "granted") : L("未授权", "not granted"))))
        menu.addItem(disabledItem(L("辅助功能：", "Accessibility: ")
                             + (permissions.accessibility ? L("已授权", "granted") : L("未授权", "not granted"))))
        menu.addItem(disabledItem(HotKeys.shared.menuDescription))
        if let capture, capture.isRunning, let displayID = capture.currentDisplayID {
            let stats = capture.currentStats
            let ago = stats.lastCaptureAt > 0
                ? L("\(Int(Date().timeIntervalSince1970 - stats.lastCaptureAt)) s 前",
                    "\(Int(Date().timeIntervalSince1970 - stats.lastCaptureAt))s ago")
                : L("尚未截图", "no screenshot yet")
            menu.addItem(disabledItem(L("按需截图：显示器 \(displayID)，已截 \(stats.captures) 张，上次 \(ago)",
                                       "On-demand screenshots: display \(displayID), \(stats.captures) taken, last \(ago)")))
        } else {
            menu.addItem(disabledItem(L("按需截图：未武装（缺权限 / 已暂停 / 已锁定）", "On-demand screenshots: not armed (missing permission / paused / locked)")))
        }
        if let lastCaptureError {
            menu.addItem(disabledItem(L("最近错误：\(lastCaptureError.prefix(60))", "Last error: \(lastCaptureError.prefix(60))")))
        }
        // 同理：foregroundLabel 在「今日暂停」时会 new 一个 DateFormatter（实测 16.6 µs）。
        let foreground = foregroundLabel
        menu.addItem(disabledItem(L("当前应用：\(foreground)", "Current app: \(foreground)")))
        // 3.6：MCP 的本地 IPC 服务端状态（socket 起没起、现在服不服务）。
        menu.addItem(disabledItem(lock.ipc.menuDescription))
        menu.addItem(.separator())

        let paused = lock.snapshot.pauseReasons.contains(.user)
        let toggle = NSMenuItem(title: paused ? L("继续采集", "Resume capture") : L("暂停采集", "Pause capture"),
                                action: #selector(togglePause), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)

        let lockedNow = lock.snapshot.phase != .unlocked
        let lockItem = NSMenuItem(title: lockedNow ? L("解锁数据库…", "Unlock database…") : L("锁定数据库", "Lock database"),
                                  action: #selector(toggleLock), keyEquivalent: "l")
        lockItem.target = self
        lockItem.isEnabled = lock.snapshot.phase == .unlocked || lock.snapshot.phase == .locked
        menu.addItem(lockItem)

        menu.addItem(appPolicyMenuItem())

        // 3.12：设置里那一页"应用"。库锁着也能打开（只是改不了档，窗口里有横幅说明）。
        let policies = NSMenuItem(title: L("应用采集清单…", "App capture list…"),
                                  action: #selector(openPoliciesWindow), keyEquivalent: "")
        policies.target = self
        menu.addItem(policies)

        // 3.12「新应用：首次出现时按全局默认处理，菜单栏提示一次，可一键改档」。
        // 一次只挂最早那一条，点掉一条再露下一条——菜单是给人看的，不是队列。
        if let newApp = CapturePolicyStore.shared.pendingNewAppNotices().first {
            let mode = CapturePolicyStore.shared.mode(for: newApp)
            let notice = NSMenuItem(
                title: L("新应用 \(newApp) 已按默认档「\(Self.modeLabel(mode))」记录（点此改档）",
                         "New app \(newApp) is being recorded at the default mode “\(Self.modeLabel(mode))” (click to change)"),
                action: #selector(openNewAppNotice(_:)), keyEquivalent: "")
            notice.target = self
            notice.representedObject = newApp
            menu.addItem(notice)
        }

        if !permissions.allGranted {
            let request = NSMenuItem(title: L("请求权限…", "Request permissions…"),
                                     action: #selector(requestPermissions), keyEquivalent: "")
            request.target = self
            menu.addItem(request)
        }

        let loginTitle: String
        switch LoginItem.status() {
        case .enabled:          loginTitle = L("取消登录项（已注册）", "Remove login item (registered)")
        case .requiresApproval: loginTitle = L("登录项待批准，打开设置…", "Login item awaiting approval — open settings…")
        default:                loginTitle = L("注册为登录项", "Add as login item")
        }
        let login = NSMenuItem(title: loginTitle,
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        let reveal = NSMenuItem(title: L("打开数据目录", "Open data folder"),
                                action: #selector(revealDataDirectory), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        // 库是加密的，外部工具读不了；存储统计只能由本进程导出（见 StatsExport）。
        let exportStats = NSMenuItem(title: L("导出存储统计…", "Export storage stats…"),
                                     action: #selector(exportStats), keyEquivalent: "")
        exportStats.target = self
        exportStats.isEnabled = lock.snapshot.phase == .unlocked
        menu.addItem(exportStats)
        if let lastStatsExport {
            menu.addItem(disabledItem(L("上次导出：\(lastStatsExport)", "Last export: \(lastStatsExport)")))
        }

        // T10（分发管线）留下的入口，按 tools/bench/results/m1_r2b_distribution_2026-09-08.md
        // 第 5 节接进来：菜单项自带 target/action 与可用性判定，默认不联网、fail-closed。
        menu.addItem(UpdaterController.shared.makeMenuItem())

        // c 批：模型与向量检索面板（T11）、跨设备同步（T13）。
        // 夜间叙述（T12）的入口 2026-09-08 按用户决定去掉了。
        menu.addItem(.separator())
        menu.addItem(ModelsMenu.menuItem())
        menu.addItem(MCPIntegrationWindowController.menuItem())
        let syncItem = NSMenuItem(title: L("跨设备同步…（\(LOnOff(sync?.status.enabled == true))）",
                                 "Cross-device sync… (\(LOnOff(sync?.status.enabled == true)))"),
                                  action: #selector(openSyncWindow), keyEquivalent: "")
        syncItem.target = self
        menu.addItem(syncItem)
        let exportItem = NSMenuItem(title: L("加密导出…", "Encrypted export…"), action: #selector(openExport), keyEquivalent: "")
        exportItem.target = self
        menu.addItem(exportItem)
        // 设置排在加密导出下面（用户 2026-09-08 指定的顺序）。
        menu.addItem(SettingsWindowController.menuItem())

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("退出 brosis", "Quit brosis"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var foregroundLabel: String {
        guard let bundleID = foregroundBundleID else { return L("（未知）", "(unknown)") }
        let mode = CapturePolicyStore.shared.mode(for: bundleID)
        let name = foregroundName ?? bundleID
        var label = "\(name) · \(Self.modeLabel(mode))"
        // 库没开的时候读不到 app_policies，这一档只是"临时判定"，别让菜单看起来像已生效的设置。
        if !CapturePolicyStore.shared.isStoreBacked { label += L("（库未打开，临时判定）", " (database closed — provisional)") }
        if let until = CapturePolicyStore.shared.temporaryPause(bundleID: bundleID) {
            let clock = PolicyListRow.clockFormatter.string(from: until)
            label += L("（今日暂停至 \(clock)）", " (paused today until \(clock))")
        }
        return label
    }

    /// 三档的中文名只有一处定义（`CapturePolicyMode.label`，见 Policies/PolicyList.swift），
    /// 菜单与应用清单窗口共用，免得两处文案漂移。
    static func modeLabel(_ mode: CapturePolicyMode) -> String { mode.label }

    /// 3.12 的菜单快捷项：「暂停采集当前应用（今天 / 永久）」。
    private func appPolicyMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("暂停采集当前应用", "Pause capture for the current app"), action: nil, keyEquivalent: "")
        guard let bundleID = foregroundBundleID else {
            item.isEnabled = false
            return item
        }
        let submenu = NSMenu()
        submenu.addItem(disabledItem(bundleID))
        let today = NSMenuItem(title: L("今天（到今日 24:00）", "Today (until 24:00)"),
                               action: #selector(pauseCurrentAppToday), keyEquivalent: "")
        today.target = self
        submenu.addItem(today)
        let forever = NSMenuItem(title: L("永久（改档为「不采集」）", "Permanently (set mode to “Do not capture”)"),
                                 action: #selector(pauseCurrentAppForever), keyEquivalent: "")
        forever.target = self
        submenu.addItem(forever)
        submenu.addItem(.separator())
        let resume = NSMenuItem(title: L("恢复采集（改回「事件 + 内容」）", "Resume capture (back to “Events + content”)"),
                                action: #selector(resumeCurrentApp), keyEquivalent: "")
        resume.target = self
        submenu.addItem(resume)
        item.submenu = submenu
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 菜单动作

    @objc private func togglePause() {
        lock?.togglePause()
        syncSubsystems()
    }

    @objc private func toggleLock() {
        guard let lock else { return }
        if lock.snapshot.phase == .unlocked {
            lock.lockNow()
        } else {
            lock.unlockNow()
        }
        refreshMenu()
    }

    @objc private func pauseCurrentAppToday() {
        guard let bundleID = foregroundBundleID else { return }
        _ = CapturePolicyStore.shared.pauseToday(bundleID: bundleID)
        capture?.setFrontmostApp(bundleID: bundleID, mode: .none)
        refreshMenu()
    }

    @objc private func pauseCurrentAppForever() {
        guard let bundleID = foregroundBundleID else { return }
        CapturePolicyStore.shared.pauseForever(bundleID: bundleID)
        capture?.setFrontmostApp(bundleID: bundleID, mode: .none)
        refreshMenu()
    }

    @objc private func resumeCurrentApp() {
        guard let bundleID = foregroundBundleID else { return }
        CapturePolicyStore.shared.clearTemporaryPause(bundleID: bundleID)
        CapturePolicyStore.shared.setMode(.eventsAndContent, bundleID: bundleID, source: .user)
        capture?.setFrontmostApp(bundleID: bundleID, mode: .eventsAndContent)
        refreshMenu()
    }

    @objc private func openPoliciesWindow() {
        PoliciesWindowController.shared.present()
    }

    /// 点掉「新应用 X …」那一行：划掉提示，打开清单窗口并定位到那一行。
    @objc private func openNewAppNotice(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        CapturePolicyStore.shared.clearNewAppNotice(bundleID: bundleID)
        PoliciesWindowController.shared.present(select: bundleID)
        refreshMenu()
    }

    @objc private func requestPermissions() {
        promptForPermissions(reason: "menu")
    }

    @objc private func toggleLoginItem() {
        do {
            switch LoginItem.status() {
            case .enabled:
                try LoginItem.unregister()
                recorder.logEvent(kind: "login_item_unregistered")
            case .requiresApproval:
                LoginItem.openSettings()
            default:
                try LoginItem.register()
                recorder.logEvent(kind: "login_item_registered")
            }
        } catch {
            recorder.logEvent(kind: "login_item_error", detail: "\(error)")
            presentFatal(L("登录项操作失败：\(error.localizedDescription)", "Login item operation failed: \(error.localizedDescription)"))
        }
        refreshMenu()
    }

    @objc private func revealDataDirectory() {
        guard let lock else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lock.directory])
    }

    /// 「导出存储统计…」：`stats()` + `statsDetail()` → 数据目录下的 `stats-<日期>.json`。
    /// 库没开就什么都不做（菜单项那时是灰的）。导出前先 checkpoint，
    /// 否则 `dbstat` 看不到还在 WAL 里的脏页（core 的 `stats()` 口径）。
    @objc private func exportStats() {
        guard let lock, lock.snapshot.phase == .unlocked else { return }
        let directory = lock.directory
        let outcome = recorder.withStore { store -> StatsExport.Outcome in
            try store.checkpoint()
            return try StatsExport.export(store: store, directory: directory)
        }
        guard let outcome else {
            lastStatsExport = L("失败（见「写入」那一行的错误计数）", "failed (see the error count on the “Writes” line)")
            refreshMenu()
            return
        }
        recorder.logEvent(kind: "stats_exported", detail: outcome.detail)
        lastStatsExport = L("\(outcome.url.lastPathComponent)（\(outcome.fileBytes) 字节）",
                            "\(outcome.url.lastPathComponent) (\(outcome.fileBytes) bytes)")
        NSWorkspace.shared.activateFileViewerSelecting([outcome.url])
        refreshMenu()
    }

    /// 给后台调度器读锁定状态用：调度器在 utility 队列上 tick，`LockController` 是 MainActor 的。
    /// 主线程上直接读；别的线程同步跳回主线程读（读一个小结构体，不会久）。
    private func makeLockSnapshotReader() -> @Sendable () -> LockSnapshot {
        { [weak self] in
            let read: @MainActor () -> LockSnapshot = { self?.lock?.snapshot ?? LockSnapshot() }
            if Thread.isMainThread { return MainActor.assumeIsolated { read() } }
            return DispatchQueue.main.sync { MainActor.assumeIsolated { read() } }
        }
    }

    @objc private func openExport() {
        exportController?.presentWindow()
    }

    @objc private func openSyncWindow() {
        sync?.presentWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "brosis"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// SMAppService LaunchAgent 注册（报告 3.3 结论）。
enum LoginItem {

    static func service() -> SMAppService {
        SMAppService.agent(plistName: BuildInfo.agentPlistName)
    }

    static func status() -> SMAppService.Status {
        service().status
    }

    static func register() throws {
        try service().register()
    }

    static func unregister() throws {
        try service().unregister()
    }

    @MainActor
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
