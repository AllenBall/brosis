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
    /// 正文写入合并：观察照写，正文攒到这一串扫描停下来再落盘（见 `TextCoalescer`）。
    private let coalescer = TextCoalescer()
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

    // MARK: - Chromium 异步建树的重扫
    //
    // 设了 `AXManualAccessibility` 之后 Chromium 才开始把渲染进程的无障碍树推上来，
    // 这是异步的，而且**比传闻慢得多**：2026-09-09 实测 Claude 桌面版，同一个进程里
    // 连读 4 秒都只有 16 个节点，几次探测之后才涨到几千个（别人的 issue 说等 200 ms）。
    // 所以第一次读到空树时不能就此认命，隔一会儿再读一次。
    //
    // 花销由三件事兜住：① 只对 Chromium 系应用重扫；② 一个进程只要**成功读到过文本**
    // 就永久标记为"已热"，之后再也不重扫（树建起来就不会退回去）；
    // ③ 每个键最多重扫 `maxAXRetries` 次。
    //
    // **规则声明 `axTreePerDocument` 的（Chrome）按"进程 + 页面"记**（2026-09-11 复查 F2，
    // evidence 26135）：浏览器的树是按文档建的，每次导航、每次切回隐藏超过 5 分钟的标签页
    // （Chromium 会撤掉隐藏标签页的无障碍模式）头一秒都是空树；按 pid 记冷热等于只对第一个页面
    // 生效，之后每个新页面的空读都直接落成一次整窗 OCR。页面键不进"已热"集合（同一页面隐藏再
    // 切回照样冷），读到正文就把重扫计数清零。

    /// 曾经读到过正文的键（pid）：树已经建好了，不必再重扫。页面键不进这里。
    private var axWarmedKeys = Set<String>()
    /// 已经排了重扫的键，避免同一个键排一堆。**排着的时候再读到空也不 OCR**——还在等，不是读不到。
    private var pendingAXRetryKeys = Set<String>()
    /// 每个键已经重扫过几次。读到正文就清零。
    private var axRetryCounts: [String: Int] = [:]
    /// 每个进程上一次读到正文的时刻。排了重扫之后若已经读到过（`AXLoadComplete` 往往先到），
    /// 那次补扫就不必跑了——省一次整棵树的遍历和一条观察。
    private var lastAXTextReadAt: [pid_t: Double] = [:]
    /// 计数表的上限：Chrome 每个页面一个键，长时间不重启会一直涨；超了就整个清掉，
    /// 代价只是下一次空读多排一次重扫。
    static let maxAXRetryKeys = 512

    static let axRetryDelays: [Double] = [1.5, 5.0]
    static var maxAXRetries: Int { axRetryDelays.count }
    /// 每个 bundle id 命中 BFS 限额的次数，用来控制 `ax_bfs_limit_hit` 的写入频次。
    private var bfsLimitHits: [String: Int] = [:]
    /// 每个进程上一次挑中的 web area 标题（`.webArea` 定位器）。变了才记一条事件——
    /// Lark 升级把 `messenger-chat` 改名时，从审计里能看出规则落到了别的 web area 上。
    private var lastPickedWebArea: [pid_t: String] = [:]
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
        // 合并器的落盘动作在这里接上：正文挂到**产生它的那条观察**上，
        // 所以时刻是那次扫描的时刻，不是补写时的时刻。
        coalescer.configure { [weak self] observationID, fragments in
            self?.recorder.attachTexts(observationID: observationID, fragments: fragments)
        }
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
        // **先把攒着的正文落盘**，再拆观察者。锁库与退出都走这里，
        // 手上那份不落就真丢了（合并的全部风险就在这几秒里）。
        coalescer.flush()
        coalescer.stop()
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
            // 只给"规则真的会读 AX 树"的应用设私有属性（见 enableManualAccessibilityIfNeeded）。
            let wantsEnhanced = AdapterRegistry.rule(for: app.bundleIdentifier,
                                                     bundleURL: app.bundleURL)
                .enhancedRegions != nil
            let manual = AX.enableManualAccessibilityIfNeeded(bundleID: app.bundleIdentifier,
                                                              bundleURL: app.bundleURL,
                                                              pid: pid,
                                                              wantsEnhanced: wantsEnhanced)
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
            kAXMainWindowChangedNotification,
            // Chromium 对顶层文档加载完成发的通知，注册在应用元素上也收得到。见 `ObservationTrigger.loadComplete`。
            kAXLoadCompleteNotification,
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
        case kAXLoadCompleteNotification:
            trigger = .loadComplete
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

    /// 没走到适配器遍历时，这条观察的完整性记什么。**纯函数，自检逐条盯着它**。
    ///
    /// 分成 `excluded`（策略上就没读）与 `unavailable`（想读却读不成）两类，
    /// 这个区分不是措辞问题：3.12 的「应用采集清单」用完整性分布让人判断
    /// "这个应用值不值得留"，把"从来没尝试"混进"读不到"会让整列失去意义。
    ///
    /// - Parameters:
    ///   - triedToRead: 本来要读正文（`shouldReadText`），但焦点窗口拿不到（AX 超时 / 无窗口）。
    ///   - collectText: 这个触发原因要不要读正文。**只有应用失活是 false**。
    ///   - privateBrowsing: 私密浏览命中。
    ///   - readsContent: 3.12 档位允许读正文吗（「只记事件」为 false）。
    nonisolated static func completenessWithoutScan(triedToRead: Bool, collectText: Bool,
                                                    privateBrowsing: Bool,
                                                    readsContent: Bool,
                                                    titleOnly: Bool = false) -> Completeness {
        // 试过了才轮得到"读不到"。
        if triedToRead { return .unavailable }
        // 规则声明这类窗口只记标题（飞书弹窗）：是规则层面的排除，不是读取失败。
        if titleOnly { return .excluded }
        // 私密浏览：事件照记（不然台账凭空少一段），正文、标题、URL、文件路径一个都不存。
        if privateBrowsing { return .excluded }
        // 3.12「只记事件」：不读正文是策略排除。
        if !readsContent { return .excluded }
        // **应用失活**（唯一一处 `collectText: false`）：这条观察只是"你从这个应用切走了"，
        // 采集端压根没打算读正文——和「只记事件」同理，是策略排除不是读取失败。
        //
        // 2026-09-09 之前它落在下面那个 unavailable 上，后果是「不可用」这一栏混进了大量
        // "从来没尝试过"的行：原生 AX 读得很好的 Safari 也有 17% 不可用，只被切来切去、
        // 从没停留过的应用（Telegram / LM Studio）更是 100%。
        // **已有的历史行不会被改写**，这个口径只对之后的观察生效。
        if !collectText { return .excluded }
        // 剩下的是真想读却读不成：没有辅助功能权限，或 source_state 落在
        // timeout / secure_input / locked / permission_lost。
        return .unavailable
    }

    /// 记下这次 AX 读到没读到东西；读到空树且这个应用是 Chromium 系时排一次重扫。
    ///
    /// 重扫**会写一条新的观察**，这是有意的：它是一次真正的新采样，
    /// 前面那条空的仍然如实记成 unavailable，不做追改。
    /// - Returns: 是不是排了一次重扫。**排了就说明这次的空树可能只是"读早了"**，
    ///   调用方据此把这一帧的 OCR 请求撤掉——OCR 回退的前提是"AX 给不出内容"，
    ///   而不是"AX 还没建好"。等 1.5 s 后重扫；真读不到时那次自然还会排 OCR。
    ///   不这么做的话，Claude 这种高频流式应用每次冷读都要白烧一次整窗 Vision。
    /// - Parameter page: 规则 `axTreePerDocument` 时的页面标识（URL 或标题），键变成"进程 + 页面"，
    ///   不进"已热"集合、读到正文时清零计数；nil = 按进程记。
    @discardableResult
    private func noteAXOutcome(app: NSRunningApplication, pid: pid_t,
                               trigger: ObservationTrigger, chars: Int, page: String?) -> Bool {
        let pageKey = page.map { "\(pid)|\($0)" } ?? "\(pid)"
        let pageScoped = page != nil
        guard chars == 0 else {
            // 读到了 → 这个键的树已经热了，撤掉所有重扫状态。
            pendingAXRetryKeys.remove(pageKey)
            axRetryCounts[pageKey] = nil
            lastAXTextReadAt[pid] = Date().timeIntervalSince1970
            if !pageScoped { axWarmedKeys.insert(pageKey) }
            return false
        }
        if !pageScoped, axWarmedKeys.contains(pageKey) { return false }
        // 重扫还在路上：这一帧照样不 OCR（"读早了"的判定还没出结果）。
        if pendingAXRetryKeys.contains(pageKey) { return true }
        let detection = AX.chromiumDetection(bundleID: app.bundleIdentifier,
                                             bundleURL: app.bundleURL).detection
        guard detection.isChromium else { return false }
        let attempt = axRetryCounts[pageKey] ?? 0
        guard attempt < Self.maxAXRetries else { return false }
        if axRetryCounts.count >= Self.maxAXRetryKeys { axRetryCounts.removeAll() }
        axRetryCounts[pageKey] = attempt + 1
        pendingAXRetryKeys.insert(pageKey)
        let delay = Self.axRetryDelays[attempt]
        let detail = "bundle=\(app.bundleIdentifier ?? "?") 第 \(attempt + 1) 次，\(delay) s 后重扫"
        if pageScoped {
            // 页面键一天能排几百次（每个页面两次），只进内存日志，不刷 runtime_events。
            BrosisLog.capture.info("ax_empty_retry_scheduled \(detail, privacy: .public)")
        } else {
            recorder.logEvent(kind: "ax_empty_retry_scheduled", detail: detail)
        }
        let scheduledAt = Date().timeIntervalSince1970
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pendingAXRetryKeys.remove(pageKey)
            // 排了之后已经读到过正文（AXLoadComplete 通常先到）：补扫只是白跑一次整棵树。
            guard (self.lastAXTextReadAt[pid] ?? 0) < scheduledAt else { return }
            // 应用已经退了、或者用户早就切走了就别补了：补出来的是别人的窗口。
            guard !app.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.record(app: app, trigger: trigger, collectText: true)
        }
        return true
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
            let read = AX.focusedWindowInfo(pid: pid, bundleID: app.bundleIdentifier,
                                            bundleURL: app.bundleURL)
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
                                                        bundleURL: app.bundleURL,
                                                        windowTitle: info.title)
        // 传 bundleURL：采集端是**唯一**手头有它的调用方，所以由它把判定算出来并填进缓存，
        // 之后策略列表、OCR 协调器只查缓存就能拿到同一个答案。
        let rule = AdapterRegistry.rule(for: app.bundleIdentifier, bundleURL: app.bundleURL)
        // 规则声明「这类窗口只记标题」（飞书的 ModalWebViewWidget 弹窗）：不读正文、不 OCR。
        let titleOnly = rule.skipsBody(windowTitle: info.title)
        let shouldReadText = collectText
            && gate.readsContent
            && !privateBrowsing
            && !titleOnly
            && permissions.accessibility
            && (sourceState == .ok || sourceState == .userIdle)

        var fragments: [TextFragment] = []
        var completeness: Completeness
        var axChars = 0
        var captureMethod: CaptureMethod = .ax
        var visibleRange: String?
        var adapterScan: AdapterScan?
        /// 适配规则从 AX 读到的会话名（飞书 `.chatWindow_chatName`）。有它就盖过窗口标题：
        /// 飞书的窗口标题恒为「飞书」（2026-09-11 复查 F2），会话身份只在这儿。
        var axConversationTitle: String?
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
            axConversationTitle = scan.conversationTitle.flatMap(AdapterEngine.firstLine)
            if let picked = scan.pickedWebArea,
               let title = picked.pickedWebAreaTitle, lastPickedWebArea[pid] != title {
                lastPickedWebArea[pid] = title
                recorder.logEvent(kind: "adapter_webarea_picked",
                                  detail: "bundle=\(app.bundleIdentifier ?? "?") title=\(title)"
                                        + " anchored=\(picked.anchored) chars=\(picked.text.count)")
            }
            for fragment in scan.fragments where !fragment.text.isEmpty {
                // —— 入库前脱敏（2.2 硬约束 2）：库里从一开始就没有这些明文 ——
                let redacted = Redactor.redact(fragment.text)
                noteRedaction(redacted)
                fragments.append(TextFragment(text: redacted.text, region: fragment.region))
            }
            completeness = scan.completeness
            captureMethod = scan.captureMethod
            visibleRange = scan.visibleRange
            // 排了重扫就把这一帧的 OCR 请求扔掉：现在还分不清"读不到"和"读早了"。
            // **只对真的读了 AX 的规则算**：纯 OCR 的规则（Chrome / 微信 / 飞书会议）字符数恒为 0，
            // 那不是"读早了"而是"压根没读"，当成前者就会把 OCR 请求白白撤掉。
            // 树按文档建的规则（Chrome）按"进程 + 页面"记冷热（见 `axWarmedKeys`），别的仍按进程。
            let page = rule.axTreePerDocument ? (info.url ?? info.title ?? "") : nil
            if rule.readsAX,
               noteAXOutcome(app: app, pid: pid, trigger: trigger, chars: scan.totalChars, page: page) {
                adapterScan?.ocrRequests = []
            }
            if scan.truncated || scan.regions.contains(where: { $0.truncated }) {
                noteAdapterLimitHit(bundleID: app.bundleIdentifier, scan: scan)
            }
        } else {
            completeness = Self.completenessWithoutScan(
                triedToRead: shouldReadText, collectText: collectText,
                privateBrowsing: privateBrowsing, readsContent: gate.readsContent,
                titleOnly: titleOnly)
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
            // 会话名优先于窗口标题（与 OCR 那条路的 `resolvedTitle?.display ?? windowTitle` 同一口径）。
            storedTitle = redactedForStorage(axConversationTitle ?? info.title)
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
            // **正文不在这里落盘**：交给合并器攒着，等这一串扫描停下来再挂到
            // 最后那条观察上（见 TextCoalescer）。观察本身照写——时间线不能缺段。
            texts: []))
        if let observationID, !fragments.isEmpty {
            coalescer.offer(key: TextCoalescer.Key(bundleID: app.bundleIdentifier ?? "(unknown)",
                                                   windowTitle: storedTitle ?? ""),
                            observationID: observationID, fragments: fragments)
        }

        if observationID != nil, axChars > 0 || privateBrowsing {
            recorder.recordCaptureStat(status: privateBrowsing ? "private_browsing" : "ax",
                                       trigger: trigger.rawValue,
                                       axChars: axChars)
        }

        // 期望走 OCR 的规则每次扫描记一行：请求是**在这里就没生成**，还是生成了没送到。
        // 协调者那边只看得到后半段，这一行补的是前半段（2026-09-09 排查飞书会议时补的）。
        //
        // **`.info` 不是 `.notice`**：这条按扫描频率走，实测 12 分钟 321 条（约 1600 条/小时），
        // 而 `.notice` 会落盘，攒下来会把系统日志的保留期挤短。`.info` 只进内存环形缓冲，
        // 要看时加 `--info`：
        //   log show --last 10m --info --predicate 'subsystem == "com.brosis.app"'
        if rule.declaresOCR {
            let text = "扫描：\(app.bundleIdentifier ?? "?") 规则 \(rule.id)，"
                     + "读正文=\(shouldReadText) 拿到窗口=\(windowElement != nil) "
                     + "AX字符=\(axChars) OCR请求=\(adapterScan?.ocrRequests.count ?? -1) "
                     + "触发=\(trigger.rawValue)"
            BrosisLog.capture.info("\(text, privacy: .public)")
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
            // 只清这个应用自己的那份：失活事件比新应用的激活事件晚到，
            // 不带 id 地清会把新应用刚排好的 OCR 请求抹掉（见 clearContext 的注释）。
            coordinator.clearContext(bundleID: app.bundleIdentifier)
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
