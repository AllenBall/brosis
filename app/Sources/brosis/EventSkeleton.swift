import AppKit
import ApplicationServices
import BrosisCore
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
/// kAXDocument、kAXURL、CGEventSource 空闲秒数、锁屏、屏保与睡眠。
///
/// **M1 相对 M0 的四处改动**：
/// 1. 写入走 `Recorder` → `BrosisCore.Store`（加密库），不再有明文库；
/// 2. **AX 正文本身入库**（`text_versions` / `occurrences`，`region` 记 AX 角色），
///    入库前先过 `Redactor`；
/// 3. 每条观察先过 3.12 的三档策略：`不采集` 连事件都不记、连 AX 都不附着，
///    `只记事件` 不读正文；
/// 4. **窗口标题、URL、文件路径也过 `Redactor`**，私密浏览命中时这三样连同正文一起不存。
@MainActor
final class EventSkeleton {

    private let recorder: Recorder
    private let policy: CapturePolicyStore
    /// 适配器 / 视口 OCR 的协调者（M1 R2 / T8）。事件骨架只往里推上下文，
    /// 真正跑 OCR 的是 `CaptureController.analyze` 那一侧——两边不用互相认识。
    private let coordinator: CaptureCoordinator
    private let onFocusChanged: @MainActor (UInt32?) -> Void
    /// 每写一条应用级观察记录 / 系统唤醒 / 切换回来时调用，参数是 trigger 名；
    /// AppDelegate 用它触发一次按需截图。
    private let onContentChanged: @MainActor (String) -> Void

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observedElement: AXUIElement?
    private var lastFingerprint: String?
    private var lastElementScanAt: Double = 0
    private var throttledElementNotifications = 0
    /// 每个 bundle id 命中 BFS 限额的次数，用来控制 `ax_bfs_limit_hit` 的写入频次。
    private var bfsLimitHits: [String: Int] = [:]
    /// 累计脱敏命中数，按类型分。`stop()` 时汇总写一条事件。
    private var redactionTotals: [RedactionType: Int] = [:]
    private var redactionSinceFlush = 0

    /// 距上次输入超过这么多秒视为未活动（报告 3.4 第 3 条）。
    static let idleThreshold: Double = 30

    /// `AXFocusedUIElementChanged` 的节流窗口，单位秒。
    ///
    /// 在编辑器 / 浏览器里这个通知一秒可能来几十次，每次都做完整 AX 遍历
    /// （≤1500 节点的正文遍历 + ≤400 节点的 AXWebArea URL 搜索，都在主线程）
    /// 既会写出大量重复行，也会污染 E7 的资源占用口径。这里只对它节流：
    /// 距上次遍历不足 2 秒的焦点元素变化直接丢弃（只计数）。
    /// 应用切换、焦点**窗口**变化、标题变化是另外的通知，**不受节流影响**。
    static let elementScanThrottle: Double = 2.0

    /// 锁屏判定用两路信号，任一路先到都算数，靠 `screenIsLocked` 去重：
    /// ① **前台应用 = `com.apple.loginwindow`**——直接观测，不依赖通知投递；
    /// ② 分布式通知 `com.apple.screenIsLocked` / `Unlocked`——私有通知，不保证投递，只作补充。
    /// `NSWorkspace.sessionDidResignActive` / `DidBecomeActive` **不是锁屏通知**，
    /// 它们只在快速用户切换时触发，记成 `user_switched_away` / `_back`。
    static let loginWindowBundleID = "com.apple.loginwindow"
    private var screenIsLocked = false

    init(recorder: Recorder,
         policy: CapturePolicyStore = .shared,
         coordinator: CaptureCoordinator = .shared,
         onFocusChanged: @escaping @MainActor (UInt32?) -> Void,
         onContentChanged: @escaping @MainActor (String) -> Void = { _ in }) {
        self.recorder = recorder
        self.policy = policy
        self.coordinator = coordinator
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
        // 锁屏第二路信号 + 屏保（M1 新增）：都是分布式通知（私有、不保证投递，只作补充）。
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(distributedScreenLocked(_:)),
                        name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(distributedScreenUnlocked(_:)),
                        name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screensaverDidStart(_:)),
                        name: Notification.Name("com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(screensaverDidStop(_:)),
                        name: Notification.Name("com.apple.screensaver.didstop"), object: nil)

        recorder.logEvent(kind: "event_skeleton_started",
                          detail: "ax_timeout=\(AX.messagingTimeout)s(全局) "
                                + "element_throttle=\(Self.elementScanThrottle)s "
                                + "idle_threshold=\(Self.idleThreshold)s "
                                + "max_chars_per_role=\(AX.maxCharsPerRole) "
                                + "redaction_rules=\(Redactor.ruleCount)")
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
            recorder.logEvent(kind: "ax_element_notifications_throttled",
                              detail: "累计丢弃 \(throttledElementNotifications) 次"
                                    + "（节流窗口 \(Self.elementScanThrottle) s）")
        }
        flushRedactionTotals()
    }

    // MARK: - NSWorkspace

    @objc private func applicationActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        // 锁屏第一路信号，也是最可靠的一路：锁屏 / 登录窗口时前台应用恒为 loginwindow。
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
        recorder.logEvent(kind: locked ? "screen_locked_detected" : "screen_unlocked_detected",
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

    @objc private func systemWillSleep(_ note: Notification) { recordSystem(trigger: .systemWillSleep) }
    @objc private func systemDidWake(_ note: Notification) { recordSystem(trigger: .systemDidWake) }

    @objc private func distributedScreenLocked(_ note: Notification) {
        updateLockState(true, source: "com.apple.screenIsLocked", reattach: false)
    }

    @objc private func distributedScreenUnlocked(_ note: Notification) {
        updateLockState(false, source: "com.apple.screenIsUnlocked", reattach: true)
    }

    /// 屏保（M1 新增的暂停触发器）。锁定状态机在 `LockController` 里订阅同一对通知并进入
    /// `paused`；这里只负责把它记成一条运行期事件，两边互不依赖。
    @objc private func screensaverDidStart(_ note: Notification) {
        recordSystem(trigger: .screensaverStarted)
    }

    @objc private func screensaverDidStop(_ note: Notification) {
        recordSystem(trigger: .screensaverStopped)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Self.loginWindowBundleID {
            attach(to: frontmost, trigger: .appActivated)
        }
    }

    /// 快速用户切换离开 / 回来。**不是锁屏**——锁屏时这两个通知根本不触发。
    @objc private func userSwitchedAway(_ note: Notification) { recordSystem(trigger: .userSwitchedAway) }

    @objc private func userSwitchedBack(_ note: Notification) {
        recordSystem(trigger: .userSwitchedBack)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Self.loginWindowBundleID {
            attach(to: frontmost, trigger: .appActivated)
        }
    }

    /// 系统级事件**只写运行期事件**，不写 `observations`（理由见 `ObservationTrigger.isSystemLevel`）。
    private func recordSystem(trigger: ObservationTrigger) {
        let permissions = Permissions.snapshot()
        let state = SystemState.sourceState(permissions: permissions, idleThreshold: Self.idleThreshold)
        recorder.logEvent(kind: trigger.rawValue,
                          detail: "source_state=\(state.rawValue) "
                                + "idle_s=\(String(format: "%.1f", SystemState.idleSeconds()))")
        if trigger == .systemDidWake || trigger == .userSwitchedBack
            || trigger == .screenUnlocked || trigger == .screensaverStopped {
            onContentChanged(trigger.rawValue)
        }
    }

    // MARK: - AXObserver

    private func attach(to app: NSRunningApplication, trigger: ObservationTrigger) {
        // 3.12「不采集」：连 AX 都不附着——这是"生效方式在采集时"最硬的一条。
        let resolution = policy.resolve(bundleID: app.bundleIdentifier)
        guard CapturePolicyStore.gate(for: resolution.mode).recordsEvents else {
            detachObserver()
            return
        }
        let pid = app.processIdentifier
        if observedPID != pid {
            detachObserver()
            // Chromium / Electron 系必须先打开手动无障碍再读树（报告 3.2）。
            let manual = AX.enableManualAccessibilityIfNeeded(bundleID: app.bundleIdentifier,
                                                              bundleURL: app.bundleURL,
                                                              pid: pid)
            if manual.firstSeen {
                recorder.logEvent(kind: "ax_manual_accessibility", detail: manual.detail)
            }
            attachObserver(pid: pid)
        }
        record(app: app, trigger: trigger, collectText: true)
    }

    private func attachObserver(pid: pid_t) {
        guard Permissions.snapshot().accessibility else {
            recorder.logEvent(kind: "ax_observer_skipped", detail: "缺辅助功能权限，pid=\(pid)")
            return
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, axNotificationCallback, &created) == .success,
              let created else {
            recorder.logEvent(kind: "ax_observer_create_failed", detail: "pid=\(pid)")
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
                    recorder.logEvent(kind: "ax_element_notifications_throttled",
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
        // —— 3.12 第一道闸：模式判定在采集时，不是入库后过滤 ——
        let resolution = policy.resolve(bundleID: app.bundleIdentifier)
        let gate = CapturePolicyStore.gate(for: resolution.mode)
        guard gate.recordsEvents else { return }

        let permissions = Permissions.snapshot()
        var sourceState = SystemState.sourceState(permissions: permissions,
                                                  idleThreshold: Self.idleThreshold)
        let pid = app.processIdentifier

        var info = AX.WindowInfo(title: nil, url: nil, document: nil, frame: nil, timedOut: false)
        var windowElement: AXUIElement?
        if permissions.accessibility && sourceState != .locked {
            // 一次调用同时拿到窗口元素与定位信息：适配规则要在同一个窗口上跑，
            // 各读各的就会多发一次 kAXFocusedWindow（访达 22% 的超时就发生在那一次）。
            let read = AX.focusedWindowInfo(pid: pid, bundleID: app.bundleIdentifier)
            windowElement = read.element
            info = read.info
            if info.timedOut && sourceState == .ok { sourceState = .timeout }
        }

        let displayID = DisplayResolver.displayID(forWindowFrame: info.frame)

        // 同一 (app, 窗口标题, url, trigger) 在同一秒内重复时只写一条。
        let fingerprint = "\(pid)|\(info.title ?? "")|\(info.url ?? "")|\(trigger.rawValue)|\(Int(Date().timeIntervalSince1970))"
        if fingerprint == lastFingerprint { return }
        lastFingerprint = fingerprint

        // —— 第二道闸：正文读不读 ——
        let privateBrowsing = PrivateBrowsing.isPrivate(bundleID: app.bundleIdentifier,
                                                        windowTitle: info.title)
        let shouldReadText = collectText
            && gate.readsContent
            && !privateBrowsing
            && permissions.accessibility
            && (sourceState == .ok || sourceState == .userIdle)

        var fragments: [TextFragment] = []
        var completeness: Completeness
        var axChars = 0
        var captureMethod: CaptureMethod = .ax
        var visibleRange: String?
        var adapterScan: AdapterScan?
        let rule = AdapterRegistry.rule(for: app.bundleIdentifier)
        if shouldReadText, let windowElement {
            // 任何一次真正的遍历都重置节流时钟。
            lastElementScanAt = Date().timeIntervalSince1970
            // —— M1 R2 / T8：正文读取走适配规则，不再是"全窗口四个角色 BFS" ——
            // 三个输入决定这次要不要顺带排 OCR（计划 3.3 的三类触发条件）：
            // 规则本身、上一次同区域读到的文本（AX 值有没有变）、帧门控与覆盖检查的结论。
            let scan = AdapterEngine.scan(
                rule: rule,
                window: LiveAXNode(windowElement),
                windowFrame: info.frame,
                previousRegionTexts: coordinator.previousRegionTexts(bundleID: app.bundleIdentifier),
                frameChanged: coordinator.consumeFrameChanged(bundleID: app.bundleIdentifier),
                coverageFailed: coordinator.consumeCoverageFailed(bundleID: app.bundleIdentifier))
            adapterScan = scan
            axChars = scan.totalChars
            for fragment in scan.fragments where !fragment.text.isEmpty {
                // —— 入库前脱敏（2.2 硬约束 2）：库里从一开始就没有这些明文 ——
                let redacted = Redactor.redact(fragment.text)
                noteRedaction(redacted)
                fragments.append(TextFragment(text: redacted.text, region: fragment.region))
            }
            completeness = scan.completeness
            captureMethod = scan.captureMethod
            visibleRange = scan.visibleRange
            if scan.truncated || scan.regions.contains(where: { $0.truncated }) {
                noteAdapterLimitHit(bundleID: app.bundleIdentifier, scan: scan)
            }
        } else if shouldReadText {
            // 读不到焦点窗口（AX 超时 / 应用没有窗口）：不是"策略排除"，是"读不到"。
            completeness = .unavailable
        } else if privateBrowsing {
            // 私密浏览：事件照记（不然台账凭空少一段），正文、标题、URL、文件路径一个都不存。
            completeness = .excluded
        } else if !gate.readsContent {
            // 3.12「只记事件」：不读正文是**策略排除**，不是"读不到"，所以是 excluded 不是 unavailable。
            completeness = .excluded
        } else {
            completeness = .unavailable
        }

        // —— 元数据同样过入库前脱敏 ——
        // 标题与 URL 不是"正文之外的安全字段"：邮件 / 浏览器标签标题里常见
        // 「Your verification code is 482913」，URL 查询串里常见 `?access_token=…`。
        // 只脱敏正文的话，这些明文照样进 windows.title / urls。
        //
        // 私密浏览命中时更进一步：**标题、URL、文件路径一个都不记**——
        // 页面标题与地址正是私密浏览要保护的东西，只留 app + 时间 + completeness=excluded，
        // 台账上仍然有这一段时间，但没有"在看什么"。
        var storedTitle: String?
        var storedURL: URLRef?
        var storedPath: String?
        if !privateBrowsing {
            storedTitle = redactedForStorage(info.title)
            storedURL = Self.urlRef(info.url,
                                    storedLocator: redactedForStorage(info.url))
            storedPath = redactedForStorage(Self.filePath(info.document))
        }

        let observationID = recorder.record(ObservationInput(
            ts: Recorder.milliseconds(),
            displayID: displayID.map(Int64.init),
            app: AppRef(bundleID: app.bundleIdentifier ?? "(unknown)",
                        name: app.localizedName ?? app.bundleIdentifier ?? "(unknown)"),
            windowTitle: storedTitle,
            url: storedURL,
            filePath: storedPath,
            trigger: trigger.coreTrigger,
            captureMethod: captureMethod,
            completeness: completeness,
            visibleRange: visibleRange,
            sourceState: sourceState,
            texts: fragments))

        if observationID != nil, axChars > 0 || privateBrowsing {
            recorder.recordCaptureStat(status: privateBrowsing ? "private_browsing" : "ax",
                                       trigger: trigger.rawValue,
                                       axChars: axChars)
        }

        // —— 把这次扫描的结果交给协调者：下一帧的视口 OCR 与采样审计要用 ——
        // **没有扫描的三支（AX 超时 / 读不到焦点窗口、私密浏览、「只记事件」档）必须把上下文清掉**：
        // 截图那条通路不知道这一轮没读正文，照样会调 `handleFrame`，留着上下文就等于
        // 拿上一个应用的 OCR 请求去认新应用（含私密浏览窗口）的画面。
        if let adapterScan {
            coordinator.noteScan(CaptureCoordinator.Context(
                bundleID: app.bundleIdentifier ?? "(unknown)",
                appName: app.localizedName ?? app.bundleIdentifier ?? "(unknown)",
                ruleID: adapterScan.ruleID,
                displayID: displayID,
                windowFrame: info.frame,
                windowTitle: storedTitle,
                observationID: observationID,
                axText: fragments.map(\.text).joined(separator: "\n"),
                regionTexts: adapterScan.regionTexts,
                ocrRequests: adapterScan.ocrRequests,
                chatLayout: rule.chatLayout,
                completeness: completeness,
                captureMethod: captureMethod,
                at: Date().timeIntervalSince1970))
        } else {
            coordinator.clearContext()
        }

        onFocusChanged(displayID)
        if trigger != .appDeactivated { onContentChanged(trigger.rawValue) }
    }

    // MARK: - 规范化对象的取值推断

    /// `kAXURL` 读到的可能是网页地址、`file://` 路径，也可能是应用自己的 deeplink。
    ///
    /// `storedLocator` 是**脱敏后**真正入库的定位串；`kind` 与 `host` 仍然用原始 URL 判定——
    /// 占位符里的 `[` `]` 会让 `URL(string:)` 解析失败，而 host 段本身不会被规则命中。
    nonisolated static func urlRef(_ raw: String?, storedLocator: String? = nil) -> URLRef? {
        guard let raw, !raw.isEmpty else { return nil }
        let locator = storedLocator ?? raw
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return URLRef(rawLocator: locator, canonicalURL: locator,
                          host: URL(string: raw)?.host, kind: .web)
        }
        if lower.hasPrefix("file://") || raw.hasPrefix("/") {
            return URLRef(rawLocator: locator, canonicalURL: locator, host: nil, kind: .file)
        }
        if lower.contains("://") {
            return URLRef(rawLocator: locator, canonicalURL: locator,
                          host: URL(string: raw)?.host, kind: .deeplink)
        }
        return URLRef(rawLocator: locator, canonicalURL: locator, host: nil, kind: .other)
    }

    /// `kAXDocument` 通常是 `file://` URL；`files.path` 存的是文件系统路径。
    nonisolated static func filePath(_ document: String?) -> String? {
        guard let document, !document.isEmpty else { return nil }
        if document.lowercased().hasPrefix("file://") {
            return URL(string: document)?.path
        }
        return document.hasPrefix("/") ? document : nil
    }

    // MARK: - 事件频次控制

    /// 标题 / URL / 文件路径的入库前脱敏。命中计进同一份 `redaction` 统计。
    /// 空串按 nil 处理（core 侧不该收到空标题）。
    private func redactedForStorage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let result = Redactor.redact(raw)
        noteRedaction(result)
        return result.text
    }

    private func noteRedaction(_ result: RedactionResult) {
        guard result.hit else { return }
        for (type, count) in result.counts {
            redactionTotals[type, default: 0] += count
        }
        // 每次命中都写一条会把事件表刷满；每累计 20 条写一次，`stop()` 时再冲一次。
        redactionSinceFlush += result.total
        if redactionSinceFlush >= 20 {
            redactionSinceFlush = 0
            flushRedactionTotals()
        }
    }

    private func flushRedactionTotals() {
        guard !redactionTotals.isEmpty else { return }
        let detail = RedactionType.allCases
            .compactMap { type in redactionTotals[type].map { "\(type.rawValue)=\($0)" } }
            .joined(separator: " ")
        recorder.logEvent(kind: "redaction", detail: "累计 " + detail)
    }

    /// BFS 命中限额时写运行期事件，**不动 `completeness`**。两条理由：
    /// ① `completeness` 是计划 3.2 的固定枚举，M1 还只是「非空 = partial」的占位值，
    ///    不该为了「这次没遍历完」新增取值；
    /// ② 一次遍历产出 4 个角色的片段，把同一个事实重复四遍没有意义。
    /// 频次：每个 bundle id 第一次写，之后每 50 次写一条。
    private func noteBFSLimitHit(bundleID: String?, scan: AX.TextScan) {
        let key = bundleID ?? "(unknown)"
        let count = (bfsLimitHits[key] ?? 0) + 1
        bfsLimitHits[key] = count
        guard count == 1 || count % 50 == 0 else { return }
        recorder.logEvent(kind: "ax_bfs_limit_hit",
                          detail: "bundle=\(key) \(scan.detail) count=\(count)")
    }

    /// 适配规则版的同一件事（限额 / frame 探测预算 / 区域字符上限）。频次规则相同。
    private func noteAdapterLimitHit(bundleID: String?, scan: AdapterScan) {
        let key = bundleID ?? "(unknown)"
        let count = (bfsLimitHits[key] ?? 0) + 1
        bfsLimitHits[key] = count
        guard count == 1 || count % 50 == 0 else { return }
        recorder.logEvent(kind: "adapter_limit_hit",
                          detail: "bundle=\(key) \(scan.detail) count=\(count)")
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
