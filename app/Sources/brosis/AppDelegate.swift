import AppKit
import Foundation
import ServiceManagement

/// 菜单栏状态项的三种状态。
enum RunState {
    case running
    case paused
    case permissionMissing(String)

    var title: String {
        switch self {
        case .running:                  return "运行中"
        case .paused:                   return "已暂停"
        case .permissionMissing(let m): return "权限缺失（\(m)）"
        }
    }

    var symbolName: String {
        switch self {
        case .running:           return "record.circle"
        case .paused:            return "pause.circle"
        case .permissionMissing: return "exclamationmark.triangle"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var store: Store?
    private var capture: CaptureController?
    private var events: EventSkeleton?
    private var state: RunState = .running
    private var userPaused = false
    private var lastCaptureError: String?
    private var guide: PermissionGuide?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 必须在任何 AX 读取之前装上进程级全局 0.5 s 超时（见 AXSupport 的说明）：
        // 只对应用元素/窗口元素设超时管不到 BFS 里的子元素。这一步不弹窗、不需要权限。
        let axTimeoutError = AX.installGlobalMessagingTimeout()

        do {
            let store = try Store()
            self.store = store
            store.logEvent(kind: "app_launched",
                           detail: "version=\(BuildInfo.version) db=\(store.url.path)")
            store.logEvent(kind: "ax_global_timeout_installed",
                           detail: "timeout=\(AX.messagingTimeout)s scope=process(system-wide) "
                                 + "AXError=\(axTimeoutError.rawValue)"
                                 + (axTimeoutError == .success ? "(success)" : "(FAILED)"))
        } catch {
            presentFatal("无法打开测试库：\(error)")
            return
        }

        buildStatusItem()

        let permissions = Permissions.snapshot()
        if !permissions.allGranted {
            // 2026-09-07 起：启动时权限缺失就直接触发系统授权框并显示引导窗口（用户要求），
            // 不再只是在菜单里显示「权限缺失」等用户来点。
            state = .permissionMissing(permissions.missingDescription)
            store?.logEvent(kind: "permission_missing", detail: permissions.missingDescription)
            refreshMenu()
            startEventSkeletonIfPossible()
            promptForPermissions(reason: "launch")
            return
        }

        startEventSkeletonIfPossible()
        startCapture(displayID: nil)
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        events?.stop()
        store?.logEvent(kind: "app_terminating")
        guard let capture else { return }
        // 注意：这里不能写 `Task { await capture.stop() }`——在 @MainActor 上下文里创建的 Task
        // 继承 MainActor 隔离，而主线程正被 semaphore.wait 挡住，任务根本没机会开始，
        // 结果是白等 2 秒且 stop 没执行。CaptureController.stop 是 nonisolated async，
        // 用 Task.detached 放到后台执行器上跑，主线程只等它发信号。
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await capture.stop(reason: "app_terminating")
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // MARK: - 子系统

    private func startEventSkeletonIfPossible() {
        guard let store else { return }
        let skeleton = EventSkeleton(store: store,
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
        guard let store else { return }
        if capture == nil {
            capture = CaptureController(store: store) { [weak self] event in
                Task { @MainActor in self?.handleCaptureEvent(event) }
            }
        }
        guard let capture else { return }
        Task { @MainActor in
            do {
                try await capture.start(displayID: displayID)
                self.lastCaptureError = nil
                if !self.userPaused { self.state = .running }
            } catch {
                self.lastCaptureError = "\(error)"
                let permissions = Permissions.snapshot()
                if !permissions.screenRecording {
                    self.state = .permissionMissing(permissions.missingDescription)
                }
            }
            self.refreshMenu()
        }
    }

    /// 焦点换到另一台显示器：按需截图只需换目标显示器并补一张（不再重建流）。
    private func focusMovedToDisplay(_ displayID: UInt32?) {
        guard let displayID, !userPaused else { return }
        guard case .running = state else { return }
        guard let capture, capture.currentDisplayID != displayID else { return }
        capture.setDisplay(displayID)
        capture.requestCapture(reason: "display_changed")
    }

    private func handleCaptureEvent(_ event: CaptureEvent) {
        switch event {
        case .started:
            if !userPaused { state = .running }
        case .stopped(let reason, let permissionLost):
            lastCaptureError = reason
            if permissionLost {
                // 月度再授权到期或用户撤销：状态改为权限缺失，并立刻弹出引导（与启动时同一套）。
                state = .permissionMissing(Permissions.snapshot().missingDescription)
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
        store?.logEvent(kind: "permission_request_started",
                        detail: "reason=\(reason) missing=\(before.missingDescription)")
        triggerSystemPrompts(before)

        if guide == nil {
            guide = PermissionGuide(
                onAllGranted: { [weak self] in self?.permissionsBecameComplete(source: "guide") },
                onRerequest: { [weak self] in
                    guard let self else { return }
                    self.triggerSystemPrompts(Permissions.snapshot())
                },
                log: { [weak self] kind, detail in self?.store?.logEvent(kind: kind, detail: detail) })
        }
        guide?.show()

        let after = Permissions.snapshot()
        store?.logEvent(kind: "permission_request_finished",
                        detail: "screen=\(after.screenRecording) ax=\(after.accessibility)")
        if after.allGranted {
            permissionsBecameComplete(source: reason)
        } else {
            state = .permissionMissing(after.missingDescription)
            store?.logEvent(kind: "permission_request_pending",
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
            // 请求会异步触发系统对话框（见 Permissions.requestScreenRecording 的说明），
            // 所以再等 2 s 仍未授权才打开设置面板，免得面板压在系统框上面。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                if !Permissions.requestScreenRecording() {
                    try? await Task.sleep(for: .seconds(2))
                    if !Permissions.snapshot().screenRecording { Permissions.openScreenRecordingSettings() }
                }
            }
        }
    }

    /// 两项权限齐了（引导窗口轮询到、菜单展开时发现、或请求后立即就绪）：起流、收起引导。
    private func permissionsBecameComplete(source: String) {
        if case .permissionMissing = state {
            store?.logEvent(kind: "permission_regained", detail: "source=\(source)")
        }
        state = userPaused ? .paused : .running
        if events == nil { startEventSkeletonIfPossible() }
        if !userPaused, capture?.isRunning != true { startCapture(displayID: nil) }
        guide?.close()
        refreshMenu()
    }

    // MARK: - 菜单栏

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "record.circle",
                                     accessibilityDescription: "brosis")
        let menu = NSMenu()
        // 权限是在系统设置里改的，app 收不到通知：每次菜单打开前重新取一次快照，
        // 否则用户在设置里打开开关后回到菜单，看到的还是「未授权」。
        menu.delegate = self
        item.menu = menu
        statusItem = item
        refreshMenu()
    }

    /// 菜单即将展开：重新取权限快照刷新两行状态；如果权限已经补齐而采集流还没起来，
    /// 顺手把它拉起来——这样用户在系统设置里打开开关后，回到菜单就直接是「运行中」，
    /// 不必再点一次「请求权限…」。
    func menuWillOpen(_ menu: NSMenu) {
        let permissions = Permissions.snapshot()
        if permissions.allGranted {
            if case .permissionMissing = state {
                permissionsBecameComplete(source: "menu")
            } else {
                if events == nil { startEventSkeletonIfPossible() }
                if !userPaused, capture?.isRunning != true { startCapture(displayID: nil) }
            }
        } else if case .permissionMissing = state {
            state = .permissionMissing(permissions.missingDescription)
        } else if !userPaused {
            state = .permissionMissing(permissions.missingDescription)
        }
        refreshMenu()
    }

    private func refreshMenu() {
        guard let statusItem, let menu = statusItem.menu else { return }
        statusItem.button?.image = NSImage(systemSymbolName: state.symbolName,
                                           accessibilityDescription: "brosis")
        menu.removeAllItems()

        let permissions = Permissions.snapshot()
        menu.addItem(disabledItem("brosis \(BuildInfo.version) · M0 采集骨架"))
        menu.addItem(disabledItem("状态：\(state.title)"))
        menu.addItem(disabledItem("屏幕录制：\(permissions.screenRecording ? "已授权" : "未授权")"))
        menu.addItem(disabledItem("辅助功能：\(permissions.accessibility ? "已授权" : "未授权")"))
        if let capture, capture.isRunning, let displayID = capture.currentDisplayID {
            let stats = capture.currentStats
            let ago = stats.lastCaptureAt > 0
                ? "\(Int(Date().timeIntervalSince1970 - stats.lastCaptureAt)) s 前" : "尚未截图"
            menu.addItem(disabledItem("按需截图：显示器 \(displayID)，已截 \(stats.captures) 张，上次 \(ago)"))
        } else {
            menu.addItem(disabledItem("按需截图：未武装（缺权限或已暂停）"))
        }
        if let lastCaptureError {
            menu.addItem(disabledItem("最近错误：\(lastCaptureError.prefix(60))"))
        }
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: userPaused ? "继续采集" : "暂停采集",
                                action: #selector(togglePause), keyEquivalent: "p")
        toggle.target = self
        menu.addItem(toggle)

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

        let reveal = NSMenuItem(title: "打开测试库目录",
                                action: #selector(revealDatabase), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 brosis", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - 菜单动作

    @objc private func togglePause() {
        userPaused.toggle()
        capture?.setPaused(userPaused)
        if userPaused {
            state = .paused
        } else {
            let permissions = Permissions.snapshot()
            state = permissions.allGranted ? .running
                                           : .permissionMissing(permissions.missingDescription)
            if permissions.screenRecording, capture?.isRunning != true {
                startCapture(displayID: capture?.currentDisplayID)
            }
        }
        refreshMenu()
    }

    /// 菜单「请求权限…」：与启动时同一套（系统授权框 + 引导窗口）。
    @objc private func requestPermissions() {
        promptForPermissions(reason: "menu")
    }

    @objc private func toggleLoginItem() {
        do {
            switch LoginItem.status() {
            case .enabled:
                try LoginItem.unregister()
                store?.logEvent(kind: "login_item_unregistered")
            case .requiresApproval:
                LoginItem.openSettings()
            default:
                try LoginItem.register()
                store?.logEvent(kind: "login_item_registered")
            }
        } catch {
            store?.logEvent(kind: "login_item_error", detail: "\(error)")
            presentFatal("登录项操作失败：\(error.localizedDescription)")
        }
        refreshMenu()
    }

    @objc private func revealDatabase() {
        guard let store else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
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
