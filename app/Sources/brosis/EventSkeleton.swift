import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// AXObserver 的 C 回调必须是全局非隔离函数。这里只做一次跳板回 MainActor。
private func axNotificationCallback(_ observer: AXObserver,
                                    _ element: AXUIElement,
                                    _ notification: CFString,
                                    _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let skeleton = Unmanaged<EventSkeleton>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // AXObserver 的 run loop source 挂在主 run loop 上，回调本来就在主线程。
    MainActor.assumeIsolated {
        skeleton.handleAXNotification(name: name)
    }
}

/// 事件骨架（计划 3.3）：NSWorkspace 激活 / 退出、AXFocusedWindowChanged、窗口标题、
/// kAXDocument、kAXURL、CGEventSource 空闲秒数、锁屏与睡眠。
@MainActor
final class EventSkeleton {

    private let store: Store
    private let onFocusChanged: @MainActor (UInt32?) -> Void
    /// 每写一条应用级观察记录 / 系统唤醒 / 切换回来时调用，参数是 trigger 名；
    /// AppDelegate 用它触发一次按需截图（2026-09-07）。
    private let onContentChanged: @MainActor (String) -> Void

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observedElement: AXUIElement?
    private var lastFingerprint: String?
    private var lastElementScanAt: Double = 0
    private var throttledElementNotifications = 0

    /// 距上次输入超过这么多秒视为未活动（报告 3.4 第 3 条）。
    static let idleThreshold: Double = 30

    /// `AXFocusedUIElementChanged` 的节流窗口，单位秒。
    ///
    /// 在编辑器 / 浏览器里这个通知一秒可能来几十次，每次都做完整 AX 遍历
    /// （≤1500 节点的正文统计 + ≤400 节点的 AXWebArea URL 搜索，都在主线程）
    /// 既会写出大量重复行，也会污染 E7 的资源占用口径。这里只对它节流：
    /// 距上次遍历不足 2 秒的焦点元素变化直接丢弃（只计数）。
    /// 应用切换、焦点**窗口**变化、标题变化是另外的通知，**不受节流影响**，
    /// 所以「换了窗口 / 换了标题 / 换了应用」这类真正的位置变化仍然即时记录。
    static let elementScanThrottle: Double = 2.0

    /// 锁屏判定用两路信号，任一路先到都算数，靠 `screenIsLocked` 去重：
    /// ① **前台应用 = `com.apple.loginwindow`**——直接观测，不依赖通知投递，
    ///    进程在锁屏之后启动也成立，是第一优先；
    /// ② 分布式通知 `com.apple.screenIsLocked` / `Unlocked`——私有通知，不保证投递，只作补充。
    /// `NSWorkspace.sessionDidResignActive` / `DidBecomeActive` **不是锁屏通知**，
    /// 它们只在快速用户切换时触发，记成 `user_switched_away` / `_back`。
    /// `source_state = locked` 走的是另一条路（`SystemState.screenLocked()` 现查会话字典），
    /// 不受这里影响。
    static let loginWindowBundleID = "com.apple.loginwindow"
    private var screenIsLocked = false

    init(store: Store,
         onFocusChanged: @escaping @MainActor (UInt32?) -> Void,
         onContentChanged: @escaping @MainActor (String) -> Void = { _ in }) {
        self.store = store
        self.onFocusChanged = onFocusChanged
        self.onContentChanged = onContentChanged
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDeactivated(_:)),
                           name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(systemWillSleep(_:)),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(systemDidWake(_:)),
                           name: NSWorkspace.didWakeNotification, object: nil)
        // 这两个只在**快速用户切换**时触发，锁屏不会触发——记 user_switched_*，不是锁屏。
        center.addObserver(self, selector: #selector(userSwitchedAway(_:)),
                           name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(userSwitchedBack(_:)),
                           name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        // 锁屏第二路信号：分布式通知（私有、不保证投递，所以只作补充）。
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(distributedScreenLocked(_:)),
                        name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(distributedScreenUnlocked(_:)),
                        name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        store.logEvent(kind: "event_skeleton_started",
                       detail: "ax_timeout=\(AX.messagingTimeout)s(全局) "
                             + "element_throttle=\(Self.elementScanThrottle)s "
                             + "idle_threshold=\(Self.idleThreshold)s")
        // 进程可能是在已锁屏的时候启动的：用现查的会话字典初始化，不补记事件。
        screenIsLocked = SystemState.screenLocked()
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Self.loginWindowBundleID {
            attach(to: frontmost, trigger: .appActivated)
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        detachObserver()
        if throttledElementNotifications > 0 {
            store.logEvent(kind: "ax_element_notifications_throttled",
                           detail: "累计丢弃 \(throttledElementNotifications) 次"
                                 + "（节流窗口 \(Self.elementScanThrottle) s）")
        }
    }

    // MARK: - NSWorkspace

    @objc private func applicationActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        // 锁屏第一路信号，也是最可靠的一路：锁屏 / 登录窗口时前台应用恒为 loginwindow。
        // 直接观测，不依赖任何通知投递（tools/probe/appswitch.swift 里已验证过这套判定）。
        if app.bundleIdentifier == Self.loginWindowBundleID {
            updateLockState(true, source: "前台应用 = loginwindow", reattach: false)
            return                       // 登录窗口不做 AX 附着
        }
        updateLockState(false, source: "前台应用离开 loginwindow", reattach: false)
        attach(to: app, trigger: .appActivated)
    }

    /// 锁屏状态变化的唯一入口：两路信号都往这里汇，靠 `screenIsLocked` 去重，
    /// 保证同一次锁屏只记一条 `screen_locked`。
    private func updateLockState(_ locked: Bool, source: String, reattach: Bool) {
        guard locked != screenIsLocked else { return }
        screenIsLocked = locked
        store.logEvent(kind: locked ? "screen_locked_detected" : "screen_unlocked_detected",
                       detail: "来源=\(source)")
        recordSystem(trigger: locked ? .screenLocked : .screenUnlocked)
        if !locked, reattach, let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Self.loginWindowBundleID {
            attach(to: frontmost, trigger: .appActivated)
        }
    }

    @objc private func applicationDeactivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        record(app: app, trigger: .appDeactivated, collectText: false)
    }

    @objc private func systemWillSleep(_ note: Notification) {
        recordSystem(trigger: .systemWillSleep)
    }

    @objc private func systemDidWake(_ note: Notification) {
        recordSystem(trigger: .systemDidWake)
    }

    @objc private func distributedScreenLocked(_ note: Notification) {
        updateLockState(true, source: "com.apple.screenIsLocked", reattach: false)
    }

    @objc private func distributedScreenUnlocked(_ note: Notification) {
        updateLockState(false, source: "com.apple.screenIsUnlocked", reattach: true)
    }

    /// 快速用户切换离开 / 回来。**不是锁屏**——锁屏时这两个通知根本不触发。
    @objc private func userSwitchedAway(_ note: Notification) {
        recordSystem(trigger: .userSwitchedAway)
    }

    @objc private func userSwitchedBack(_ note: Notification) {
        recordSystem(trigger: .userSwitchedBack)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Self.loginWindowBundleID {
            attach(to: frontmost, trigger: .appActivated)
        }
    }

    private func recordSystem(trigger: ObservationTrigger) {
        let permissions = Permissions.snapshot()
        store.insertObservation(ObservationRow(
            app: nil, appName: nil, pid: nil, title: nil, url: nil, document: nil,
            trigger: trigger,
            sourceState: SystemState.sourceState(permissions: permissions,
                                                 idleThreshold: Self.idleThreshold),
            idleSeconds: SystemState.idleSeconds(),
            displayID: nil))
        if trigger == .systemDidWake || trigger == .userSwitchedBack || trigger == .screenUnlocked {
            onContentChanged(trigger.rawValue)
        }
    }

    // MARK: - AXObserver

    private func attach(to app: NSRunningApplication, trigger: ObservationTrigger) {
        let pid = app.processIdentifier
        if observedPID != pid {
            detachObserver()
            // Chromium / Electron 系必须先打开手动无障碍再读树（报告 3.2）。
            AX.enableManualAccessibilityIfNeeded(bundleID: app.bundleIdentifier, pid: pid)
            attachObserver(pid: pid)
        }
        record(app: app, trigger: trigger, collectText: true)
    }

    private func attachObserver(pid: pid_t) {
        guard Permissions.snapshot().accessibility else {
            store.logEvent(kind: "ax_observer_skipped", detail: "缺辅助功能权限，pid=\(pid)")
            return
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, axNotificationCallback, &created) == .success,
              let created else {
            store.logEvent(kind: "ax_observer_create_failed", detail: "pid=\(pid)")
            return
        }
        let element = AX.applicationElement(pid: pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let names = [
            kAXFocusedWindowChangedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXTitleChangedNotification,
            kAXMainWindowChangedNotification
        ]
        for name in names {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(created),
                           CFRunLoopMode.defaultMode)
        observer = created
        observedPID = pid
        observedElement = element
    }

    private func detachObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  CFRunLoopMode.defaultMode)
        }
        observer = nil
        observedPID = nil
        observedElement = nil
    }

    fileprivate func handleAXNotification(name: String) {
        guard let pid = observedPID,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        let trigger: ObservationTrigger
        switch name {
        case kAXFocusedWindowChangedNotification,
             kAXMainWindowChangedNotification:
            trigger = .focusedWindowChanged
        case kAXTitleChangedNotification:
            trigger = .titleChanged
        default:
            trigger = .focusedElementChanged
        }

        // 只对高频的焦点元素变化节流；窗口/标题/应用切换不节流。
        if trigger == .focusedElementChanged {
            let now = Date().timeIntervalSince1970
            guard now - lastElementScanAt >= Self.elementScanThrottle else {
                throttledElementNotifications += 1
                if throttledElementNotifications % 100 == 0 {
                    store.logEvent(kind: "ax_element_notifications_throttled",
                                   detail: "累计丢弃 \(throttledElementNotifications) 次"
                                         + "（节流窗口 \(Self.elementScanThrottle) s）")
                }
                return
            }
            // 放行就立刻推进时钟：即使这次因为 secure_input / 锁屏没走到正文遍历，
            // 也不能让后面每一条通知都去做窗口读取和 AXWebArea 搜索。
            lastElementScanAt = now
        }
        record(app: app, trigger: trigger, collectText: true)
    }

    // MARK: - 写观察记录

    private func record(app: NSRunningApplication, trigger: ObservationTrigger, collectText: Bool) {
        let permissions = Permissions.snapshot()
        var sourceState = SystemState.sourceState(permissions: permissions,
                                                  idleThreshold: Self.idleThreshold)
        let pid = app.processIdentifier

        var info = AX.WindowInfo(title: nil, url: nil, document: nil, frame: nil, timedOut: false)
        if permissions.accessibility && sourceState != .locked {
            info = AX.windowInfo(pid: pid)
            if info.timedOut && sourceState == .ok { sourceState = .timeout }
        }

        let displayID = DisplayResolver.displayID(forWindowFrame: info.frame)

        // 同一 (app, 窗口标题, url, trigger) 在同一秒内重复时只写一条。
        let fingerprint = "\(pid)|\(info.title ?? "")|\(info.url ?? "")|\(trigger.rawValue)|\(Int(Date().timeIntervalSince1970))"
        if fingerprint == lastFingerprint { return }
        lastFingerprint = fingerprint

        let observationID = store.insertObservation(ObservationRow(
            app: app.bundleIdentifier,
            appName: app.localizedName,
            pid: pid,
            title: info.title,
            url: info.url,
            document: info.document,
            trigger: trigger,
            sourceState: sourceState,
            idleSeconds: SystemState.idleSeconds(),
            displayID: displayID))

        if collectText, observationID > 0,
           permissions.accessibility,
           sourceState == .ok || sourceState == .userIdle {
            // 任何一次真正的遍历都重置节流时钟：刚因为换窗口做过全量 BFS 时，
            // 紧随其后的焦点元素变化不必再来一遍。
            lastElementScanAt = Date().timeIntervalSince1970
            for summary in AX.textSummaries(pid: pid) {
                store.insertAXText(observationID: observationID, summary: summary)
            }
        }

        onFocusChanged(displayID)
        if trigger != .appDeactivated { onContentChanged(trigger.rawValue) }
    }
}

/// 焦点窗口 → 显示器。AX 坐标原点在左上、y 向下；NSScreen 原点在主屏左下、y 向上。
enum DisplayResolver {

    @MainActor
    static func displayID(forWindowFrame frame: CGRect?) -> UInt32? {
        guard let frame, frame.width > 0, frame.height > 0 else {
            return displayID(of: NSScreen.main)
        }
        guard let primary = NSScreen.screens.first else { return nil }
        let axCenter = CGPoint(x: frame.midX, y: frame.midY)
        let cocoaCenter = CGPoint(x: axCenter.x,
                                  y: primary.frame.maxY - axCenter.y)
        let screen = NSScreen.screens.first { $0.frame.contains(cocoaCenter) } ?? NSScreen.main
        return displayID(of: screen)
    }

    @MainActor
    static func displayID(of screen: NSScreen?) -> UInt32? {
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return number.uint32Value
    }
}
