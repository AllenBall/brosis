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
    /// 最近一次前台的**非本应用**：菜单里「暂停采集当前应用」要用它。
    /// 不能在菜单打开时现问 `frontmostApplication`——点状态栏图标本身会让本应用成为前台。
    private var foregroundBundleID: String?
    private var foregroundName: String?
    /// `app_launched` 只在本次进程第一次开库成功时写一条（见 `lock.onUnlocked`）。
    private var didLogLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 必须在任何 AX 读取之前装上进程级全局 0.5 s 超时（见 AXSupport 的说明）。
        // 这一步不弹窗、不需要权限。
        let axTimeoutError = AX.installGlobalMessagingTimeout()

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
            }
            self.syncSubsystems()
        }
        lock.onLocking = { [weak self] in self?.stopSubsystems(reason: "locking") }

        buildStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != BuildInfo.bundleIdentifier {
            foregroundBundleID = frontmost.bundleIdentifier
            foregroundName = frontmost.localizedName
        }

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

        if recording && permissions.screenRecording {
            if capture?.isRunning != true { startCapture(displayID: capture?.currentDisplayID) }
            capture?.setPaused(false)
        } else {
            capture?.setPaused(true)
        }
        refreshMenu()
    }

    private func stopSubsystems(reason: String) {
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
        if !permissions.allGranted { return "权限缺失（\(permissions.missingDescription)）" }
        guard let snapshot = lock?.snapshot else { return "锁定" }
        switch snapshot.phase {
        case .locked:    return "锁定"
        case .unlocking: return "解锁中"
        case .locking:   return "锁定中"
        case .unlocked:  return snapshot.isPaused ? "暂停（\(snapshot.pauseDescription)）" : "录制"
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
        menu.addItem(disabledItem("状态：\(statusTitle)"))
        menu.addItem(disabledItem("数据库：\(lock.snapshot.phase.rawValue)"
                                  + "（\(lock.directory.lastPathComponent)，来源 \(lock.directorySource)）"))
        if let error = lock.lastError {
            menu.addItem(disabledItem("开库失败：\(error.prefix(70))"))
        }
        menu.addItem(disabledItem("写入：\(recorder.stats.summary)"))
        menu.addItem(disabledItem("屏幕录制：\(permissions.screenRecording ? "已授权" : "未授权")"))
        menu.addItem(disabledItem("辅助功能：\(permissions.accessibility ? "已授权" : "未授权")"))
        if let capture, capture.isRunning, let displayID = capture.currentDisplayID {
            let stats = capture.currentStats
            let ago = stats.lastCaptureAt > 0
                ? "\(Int(Date().timeIntervalSince1970 - stats.lastCaptureAt)) s 前" : "尚未截图"
            menu.addItem(disabledItem("按需截图：显示器 \(displayID)，已截 \(stats.captures) 张，上次 \(ago)"))
        } else {
            menu.addItem(disabledItem("按需截图：未武装（缺权限 / 已暂停 / 已锁定）"))
        }
        if let lastCaptureError {
            menu.addItem(disabledItem("最近错误：\(lastCaptureError.prefix(60))"))
        }
        menu.addItem(disabledItem("当前应用：\(foregroundLabel)"))
        menu.addItem(.separator())

        let paused = lock.snapshot.pauseReasons.contains(.user)
        let toggle = NSMenuItem(title: paused ? "继续采集" : "暂停采集",
                                action: #selector(togglePause), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)

        let lockedNow = lock.snapshot.phase != .unlocked
        let lockItem = NSMenuItem(title: lockedNow ? "解锁数据库…" : "锁定数据库",
                                  action: #selector(toggleLock), keyEquivalent: "l")
        lockItem.target = self
        lockItem.isEnabled = lock.snapshot.phase == .unlocked || lock.snapshot.phase == .locked
        menu.addItem(lockItem)

        menu.addItem(appPolicyMenuItem())

        if !permissions.allGranted {
            let request = NSMenuItem(title: "请求权限…",
                                     action: #selector(requestPermissions), keyEquivalent: "")
            request.target = self
            menu.addItem(request)
        }

        let loginTitle: String
        switch LoginItem.status() {
        case .enabled:          loginTitle = "取消登录项（已注册）"
        case .requiresApproval: loginTitle = "登录项待批准，打开设置…"
        default:                loginTitle = "注册为登录项"
        }
        let login = NSMenuItem(title: loginTitle,
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        menu.addItem(login)

        let reveal = NSMenuItem(title: "打开数据目录",
                                action: #selector(revealDataDirectory), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 brosis", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var foregroundLabel: String {
        guard let bundleID = foregroundBundleID else { return "（未知）" }
        let mode = CapturePolicyStore.shared.mode(for: bundleID)
        let name = foregroundName ?? bundleID
        var label = "\(name) · \(Self.modeLabel(mode))"
        // 库没开的时候读不到 app_policies，这一档只是"临时判定"，别让菜单看起来像已生效的设置。
        if !CapturePolicyStore.shared.isStoreBacked { label += "（库未打开，临时判定）" }
        if let until = CapturePolicyStore.shared.temporaryPause(bundleID: bundleID) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            label += "（今日暂停至 \(formatter.string(from: until))）"
        }
        return label
    }

    static func modeLabel(_ mode: CapturePolicyMode) -> String {
        switch mode {
        case .none:             return "不采集"
        case .eventsOnly:       return "只记事件"
        case .eventsAndContent: return "事件 + 内容"
        }
    }

    /// 3.12 的菜单快捷项：「暂停采集当前应用（今天 / 永久）」。
    private func appPolicyMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "暂停采集当前应用", action: nil, keyEquivalent: "")
        guard let bundleID = foregroundBundleID else {
            item.isEnabled = false
            return item
        }
        let submenu = NSMenu()
        submenu.addItem(disabledItem(bundleID))
        let today = NSMenuItem(title: "今天（到今日 24:00）",
                               action: #selector(pauseCurrentAppToday), keyEquivalent: "")
        today.target = self
        submenu.addItem(today)
        let forever = NSMenuItem(title: "永久（改档为「不采集」）",
                                 action: #selector(pauseCurrentAppForever), keyEquivalent: "")
        forever.target = self
        submenu.addItem(forever)
        submenu.addItem(.separator())
        let resume = NSMenuItem(title: "恢复采集（改回「事件 + 内容」）",
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
            presentFatal("登录项操作失败：\(error.localizedDescription)")
        }
        refreshMenu()
    }

    @objc private func revealDataDirectory() {
        guard let lock else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lock.directory])
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
