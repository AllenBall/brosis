import AppKit
import BrosisCore
import Foundation

/// 3.5 锁定状态机的四个相位。
enum LockPhase: String, Sendable, CaseIterable {
    /// 库关闭、任务停止、采集暂停、MCP 拒绝。
    case locked
    /// 取钥、开库、校验。
    case unlocking
    /// 采集、索引、查询。
    case unlocked
    /// flush、checkpoint、关库、清内存。
    case locking
}

/// `paused` 子状态的原因。几路可以同时成立（用户按了暂停 + 屏幕又锁了），
/// 所以用集合而不是布尔：任何一路还在，就不能恢复采集。
enum PauseReason: String, Sendable, CaseIterable {
    case user                // 菜单「暂停采集」
    case screenLocked        // 屏幕锁定（非严格模式）
    case screensaver         // 屏保启动
    case secureInput         // 安全输入（由采集侧逐次判定，这里只用于显示）
    /// Focus（专注模式）命中暂停名单（M2 d / T18，计划 4.5「Focus 联动」）。
    /// 与上面几路同一个集合、同一条恢复路径：`FocusMonitor` 只负责判"该不该"，
    /// "怎么暂停 / 怎么恢复"仍然是这里这一套。
    case focus
}

/// 状态机的输入。
enum LockTrigger: String, Sendable {
    case launch              // 启动
    case unlockSucceeded     // 内部：取钥 + 开库 + 校验成功
    case unlockFailed        // 内部：上一步失败
    case lockCompleted       // 内部：checkpoint + 关库完成
    case systemWillSleep
    case systemDidWake
    case userWillLogout
    case menuLock
    case menuUnlock
    case lowDisk             // 磁盘剩余 < 2 GiB
    case thermalCritical     // ProcessInfo.thermalState == .critical
    case screenLocked
    case screenUnlocked
    case screensaverStarted
    case screensaverStopped
    case menuPause
    case menuResume
    /// M2 d / T18：Focus 命中暂停名单 / 退出暂停名单。由 `FocusMonitor` 发。
    case focusPauseStarted
    case focusPauseEnded
}

/// 状态机的完整状态。
struct LockSnapshot: Sendable, Equatable {
    var phase: LockPhase = .locked
    var pauseReasons: Set<PauseReason> = []

    /// `paused` 只在 `unlocked` 下有意义：库开着，但采集暂停、MCP 拒绝。
    var isPaused: Bool { phase == .unlocked && !pauseReasons.isEmpty }
    /// 采集端能不能写。
    var isRecording: Bool { phase == .unlocked && pauseReasons.isEmpty }

    var pauseDescription: String {
        pauseReasons.map(\.rawValue).sorted().joined(separator: "+")
    }
}

/// 纯函数形式的状态转移。**自检直接跑它**——不开库、不发通知、不碰 GUI。
///
/// 触发表按计划 3.5：
/// - 启动 → `unlocking`；
/// - 系统睡眠、注销、菜单「锁定」、磁盘剩余 < 2 GiB、热状态 critical → `locking`；
/// - 屏幕锁定 → `paused`（**库保持打开**），解锁 → 恢复；
/// - `UserDefaults` 的 `lock.strict = true` 时，屏幕锁定也走 `locking`。
///
/// 两条实现口径写在这里：
/// 1. **`locking` 期间再来锁定触发是空操作**，不会把 `locking` 打断成第二次关库；
///    但 `unlocking` 期间来的锁定触发会生效——开库中途睡眠是真实场景，不能让它开完再睡。
/// 2. **暂停原因在锁定期间保留**。屏幕锁着的时候睡眠 → 关库；醒来解锁库以后，
///    如果屏幕还锁着，`paused` 必须还在，否则会在锁屏状态下恢复采集。
enum LockPolicy {

    static let strictKey = "lock.strict"
    /// 低磁盘阈值：2 GiB = 2 × 2³⁰ 字节。
    static let lowDiskThresholdBytes: Int64 = 2 * 1024 * 1024 * 1024

    static func strictScreenLock(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: strictKey)
    }

    static func next(_ state: LockSnapshot, on trigger: LockTrigger,
                     strictScreenLock: Bool = false) -> LockSnapshot {
        var next = state
        switch trigger {
        case .launch, .menuUnlock, .systemDidWake:
            if state.phase == .locked { next.phase = .unlocking }
        case .unlockSucceeded:
            if state.phase == .unlocking { next.phase = .unlocked }
        case .unlockFailed:
            if state.phase == .unlocking { next.phase = .locked }
        case .lockCompleted:
            if state.phase == .locking { next.phase = .locked }
        case .systemWillSleep, .userWillLogout, .menuLock, .lowDisk, .thermalCritical:
            if state.phase == .unlocked || state.phase == .unlocking { next.phase = .locking }
        case .screenLocked:
            next.pauseReasons.insert(.screenLocked)
            if strictScreenLock, state.phase == .unlocked || state.phase == .unlocking {
                next.phase = .locking
            }
        case .screenUnlocked:
            next.pauseReasons.remove(.screenLocked)
            if strictScreenLock, state.phase == .locked { next.phase = .unlocking }
        case .screensaverStarted:
            next.pauseReasons.insert(.screensaver)
        case .screensaverStopped:
            next.pauseReasons.remove(.screensaver)
        case .menuPause:
            next.pauseReasons.insert(.user)
        case .menuResume:
            next.pauseReasons.remove(.user)
        case .focusPauseStarted:
            next.pauseReasons.insert(.focus)
        case .focusPauseEnded:
            next.pauseReasons.remove(.focus)
        }
        return next
    }

    /// `locking` 期间到达的「要开库」触发（唤醒 / 菜单解锁 / 严格模式下的屏幕解锁）在
    /// `next` 里是**空操作**——它们只在 `locked` 相位生效。执行体必须把它记下来，
    /// 等 `lockCompleted` 落地之后补做一次。
    ///
    /// 不补做的后果是真实的：合盖睡眠 → `locking`（checkpoint + 关库是异步的）→ 还没回调
    /// `lockCompleted` 就唤醒 → 这次 `systemDidWake` 被丢掉 → 状态停在 `locked`，
    /// 采集一直不恢复，直到用户手动按一次 ⌘L。
    static func deferredUnlock(from state: LockSnapshot, on trigger: LockTrigger,
                               strictScreenLock: Bool = false) -> LockTrigger? {
        guard state.phase == .locking else { return nil }
        switch trigger {
        case .systemDidWake, .menuUnlock, .launch:
            return trigger
        case .screenUnlocked where strictScreenLock:
            return trigger
        default:
            return nil
        }
    }

    /// 反过来：`locking` 期间到达的**锁定类**触发要取消已经攒下的补做——
    /// 用户在关库过程中按了 ⌘L（或屏幕锁了、磁盘满了），就不该因为半分钟前的一次唤醒
    /// 又把库开回来。
    ///
    /// **R2 修正**：`screenLocked` 只在**严格模式**下算锁定类触发。非严格模式下
    /// 屏幕锁定只往 `pauseReasons` 里加一条（库保持打开，见 `next`），
    /// 它不关库，就不该把「睡醒了要开库」这件事取消掉——否则"睡眠 → 唤醒 → 屏幕还锁着"
    /// 这条最常见的路径会把补做吃掉，状态停在 `locked` 直到用户手动 ⌘L。
    static func cancelsDeferredUnlock(_ trigger: LockTrigger,
                                      strictScreenLock: Bool = false) -> Bool {
        switch trigger {
        case .systemWillSleep, .userWillLogout, .menuLock, .lowDisk, .thermalCritical:
            return true
        case .screenLocked:
            return strictScreenLock
        default:
            return false
        }
    }

    /// 自检用的「取消补做」用例表：`(触发, 严格模式, 期望是否取消)`。
    static let cancelDeferredCases: [(trigger: LockTrigger, strict: Bool, expected: Bool)] = [
        (.menuLock, false, true),
        (.systemWillSleep, false, true),
        (.userWillLogout, false, true),
        (.lowDisk, false, true),
        (.thermalCritical, false, true),
        // 非严格模式：锁屏不关库，不取消补做（R2 修正）
        (.screenLocked, false, false),
        // 严格模式：锁屏就是关库，取消
        (.screenLocked, true, true),
        (.systemDidWake, false, false),
        (.menuUnlock, false, false),
        (.screenUnlocked, false, false),
        (.screensaverStarted, false, false),
        // Focus 暂停也不关库，同样不取消补做（M2 d / T18）
        (.focusPauseStarted, false, false),
    ]

    /// 自检用的补做用例表：`(起点相位, 触发, 严格模式, 期望补做的触发)`。
    static let deferredUnlockCases:
        [(from: LockPhase, trigger: LockTrigger, strict: Bool, expected: LockTrigger?)] = [
        (.locking, .systemDidWake, false, .systemDidWake),
        (.locking, .menuUnlock, false, .menuUnlock),
        (.locking, .screenUnlocked, true, .screenUnlocked),
        // 非严格模式下屏幕解锁只清暂停原因，本来就不开库，不需要补
        (.locking, .screenUnlocked, false, nil),
        (.locking, .screensaverStopped, false, nil),
        (.locking, .focusPauseEnded, false, nil),
        // 只有 locking 期间才需要补：unlocked 不需要，locked 时 next 自己就会开库
        (.unlocked, .systemDidWake, false, nil),
        (.locked, .systemDidWake, false, nil),
    ]

    /// 自检用的转移用例表：`(起点, 触发, 严格模式, 期望终点)`。
    /// 覆盖 3.5 里每一条触发，外加两条边界（`locking` 中的重复锁定、锁定期间保留暂停原因）。
    static let transitionCases:
        [(from: LockSnapshot, trigger: LockTrigger, strict: Bool, expected: LockSnapshot)] = [
        (LockSnapshot(phase: .locked), .launch, false, LockSnapshot(phase: .unlocking)),
        (LockSnapshot(phase: .unlocking), .unlockSucceeded, false, LockSnapshot(phase: .unlocked)),
        (LockSnapshot(phase: .unlocking), .unlockFailed, false, LockSnapshot(phase: .locked)),
        (LockSnapshot(phase: .unlocked), .systemWillSleep, false, LockSnapshot(phase: .locking)),
        (LockSnapshot(phase: .unlocked), .userWillLogout, false, LockSnapshot(phase: .locking)),
        (LockSnapshot(phase: .unlocked), .menuLock, false, LockSnapshot(phase: .locking)),
        (LockSnapshot(phase: .unlocked), .lowDisk, false, LockSnapshot(phase: .locking)),
        (LockSnapshot(phase: .unlocked), .thermalCritical, false, LockSnapshot(phase: .locking)),
        (LockSnapshot(phase: .locking), .lockCompleted, false, LockSnapshot(phase: .locked)),
        (LockSnapshot(phase: .locked), .systemDidWake, false, LockSnapshot(phase: .unlocking)),
        // 屏幕锁定：非严格 → 只进 paused，库保持打开
        (LockSnapshot(phase: .unlocked), .screenLocked, false,
         LockSnapshot(phase: .unlocked, pauseReasons: [.screenLocked])),
        (LockSnapshot(phase: .unlocked, pauseReasons: [.screenLocked]), .screenUnlocked, false,
         LockSnapshot(phase: .unlocked)),
        // 屏幕锁定：严格模式 → 同时 locking
        (LockSnapshot(phase: .unlocked), .screenLocked, true,
         LockSnapshot(phase: .locking, pauseReasons: [.screenLocked])),
        (LockSnapshot(phase: .locked, pauseReasons: [.screenLocked]), .screenUnlocked, true,
         LockSnapshot(phase: .unlocking)),
        // 屏保
        (LockSnapshot(phase: .unlocked), .screensaverStarted, false,
         LockSnapshot(phase: .unlocked, pauseReasons: [.screensaver])),
        (LockSnapshot(phase: .unlocked, pauseReasons: [.screensaver]), .screensaverStopped, false,
         LockSnapshot(phase: .unlocked)),
        // Focus 联动（M2 d / T18）：只进 / 出 paused，库始终开着，与屏保 / 锁屏同一个集合
        (LockSnapshot(phase: .unlocked), .focusPauseStarted, false,
         LockSnapshot(phase: .unlocked, pauseReasons: [.focus])),
        (LockSnapshot(phase: .unlocked, pauseReasons: [.focus]), .focusPauseEnded, false,
         LockSnapshot(phase: .unlocked)),
        // Focus 退出时屏幕还锁着：只清 focus 这一条，锁屏那条留着（不能在锁屏下恢复采集）
        (LockSnapshot(phase: .unlocked, pauseReasons: [.focus, .screenLocked]),
         .focusPauseEnded, false,
         LockSnapshot(phase: .unlocked, pauseReasons: [.screenLocked])),
        // 一键暂停与屏幕锁定互不抵消
        (LockSnapshot(phase: .unlocked, pauseReasons: [.screenLocked]), .menuPause, false,
         LockSnapshot(phase: .unlocked, pauseReasons: [.screenLocked, .user])),
        (LockSnapshot(phase: .unlocked, pauseReasons: [.screenLocked, .user]), .menuResume, false,
         LockSnapshot(phase: .unlocked, pauseReasons: [.screenLocked])),
        // locking 期间再来一次锁定触发是空操作
        (LockSnapshot(phase: .locking), .menuLock, false, LockSnapshot(phase: .locking)),
        // unlocking 期间睡眠要生效（不能开完库再睡）
        (LockSnapshot(phase: .unlocking), .systemWillSleep, false, LockSnapshot(phase: .locking)),
        // 锁定期间保留暂停原因
        (LockSnapshot(phase: .unlocked, pauseReasons: [.screenLocked]), .systemWillSleep, false,
         LockSnapshot(phase: .locking, pauseReasons: [.screenLocked])),
    ]
}

/// 3.5 状态机的执行体：把 `LockPolicy` 的判定接到真实的取钥、开库、校验、checkpoint、关库上。
///
/// **钥匙串**：产品路径用 `BrosisCore.KeychainKeyProvider`（data-protection 钥匙串、
/// `WhenUnlockedThisDeviceOnly`、ACL 绑本应用签名）。首次运行会弹**一次**钥匙串授权对话框——
/// 这一步只能由真人点，本轮不跑，列进"需要你在 GUI 里验证"的清单。
@MainActor
final class LockController {

    /// 状态变化时回调（菜单刷新）。
    var onChange: (@MainActor () -> Void)?
    /// 进入 `unlocked` 时回调（拉起采集）。
    var onUnlocked: (@MainActor () -> Void)?
    /// 离开 `unlocked` 时回调（停采集）。
    var onLocking: (@MainActor () -> Void)?

    let recorder: Recorder
    /// 本地 IPC 服务端（3.1 / 3.6）。挂在这里而不是 AppDelegate：
    /// 这一层才是本进程里唯一持有 `Store` 的地方，MCP 的"能不能服务"就是 3.5 的相位。
    let ipc: MCPIPCService
    private(set) var snapshot = LockSnapshot()
    private(set) var lastError: String?
    private(set) var directory: URL
    private(set) var directorySource: String
    private var store: Store?
    private var diskTimer: Timer?
    /// `locking` 期间到达、要等关库完成后才能补做的开库触发。
    private var pendingUnlock: LockTrigger?
    private let defaults: UserDefaults
    /// 上一次关库的小结。关库那一刻库已经不在了，写不进事件表，
    /// 所以攒到下一次 `store_opened` 的 detail 里一起记，不让它凭空消失。
    private var lastCloseSummary: String?

    init(recorder: Recorder, defaults: UserDefaults = .standard) {
        self.recorder = recorder
        self.ipc = MCPIPCService(recorder: recorder)
        self.defaults = defaults
        let resolved = DataLocation.resolve(defaults)
        self.directory = resolved.url
        self.directorySource = resolved.source
    }

    var strictScreenLock: Bool { LockPolicy.strictScreenLock(defaults) }

    // MARK: - 通知订阅

    func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep(_:)),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake(_:)),
                              name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(willPowerOff(_:)),
                              name: NSWorkspace.willPowerOffNotification, object: nil)

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenLocked(_:)),
                                name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenUnlocked(_:)),
                                name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        // 屏保：本轮新增的暂停触发器（计划 4.2「暂停触发器（安全输入、私密浏览、锁屏、屏保、热键）」）。
        distributed.addObserver(self, selector: #selector(screensaverStarted(_:)),
                                name: Notification.Name("com.apple.screensaver.didstart"), object: nil)
        distributed.addObserver(self, selector: #selector(screensaverStopped(_:)),
                                name: Notification.Name("com.apple.screensaver.didstop"), object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalChanged(_:)),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        // 进程可能在已锁屏 / 屏保中启动：用现查的会话字典初始化暂停原因。
        if SystemState.screenLocked() { snapshot.pauseReasons.insert(.screenLocked) }

        // 低磁盘轮询。没有系统通知可用，60 s 一次足够——2 GiB 不会在一分钟内掉光。
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDiskSpace() }
        }
        RunLoop.main.add(timer, forMode: .common)
        diskTimer = timer
    }

    func stop() {
        ipc.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        diskTimer?.invalidate()
        diskTimer = nil
    }

    @objc private func willSleep(_ note: Notification) { apply(.systemWillSleep) }
    @objc private func didWake(_ note: Notification) { apply(.systemDidWake) }
    @objc private func willPowerOff(_ note: Notification) { apply(.userWillLogout) }
    @objc private func screenLocked(_ note: Notification) { apply(.screenLocked) }
    @objc private func screenUnlocked(_ note: Notification) { apply(.screenUnlocked) }
    @objc private func screensaverStarted(_ note: Notification) { apply(.screensaverStarted) }
    @objc private func screensaverStopped(_ note: Notification) { apply(.screensaverStopped) }

    @objc private func thermalChanged(_ note: Notification) {
        let state = ProcessInfo.processInfo.thermalState
        recorder.logEvent(kind: "thermal_state", detail: "state=\(Self.describe(state))")
        if state == .critical { apply(.thermalCritical) }
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: - 磁盘

    /// 数据目录所在卷的可用字节。目录还没建时退回到它最近的已存在祖先。
    func availableBytes() -> Int64? {
        var probe = directory
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func checkDiskSpace() {
        guard let free = availableBytes() else { return }
        guard free < LockPolicy.lowDiskThresholdBytes else { return }
        guard snapshot.phase == .unlocked || snapshot.phase == .unlocking else { return }
        recorder.logEvent(kind: "low_disk",
                          detail: "free=\(free)B threshold=\(LockPolicy.lowDiskThresholdBytes)B")
        apply(.lowDisk)
    }

    // MARK: - 状态转移

    func apply(_ trigger: LockTrigger) {
        // 关库过程中又来了锁定类触发：把之前攒下的补做取消掉。
        if LockPolicy.cancelsDeferredUnlock(trigger, strictScreenLock: strictScreenLock) {
            pendingUnlock = nil
        }
        // locking 期间到的「要开库」触发先记下来，等关库真正落地再补做（见 LockPolicy.deferredUnlock）。
        if let deferred = LockPolicy.deferredUnlock(from: snapshot, on: trigger,
                                                    strictScreenLock: strictScreenLock) {
            pendingUnlock = deferred
            recorder.logEvent(kind: "lock_unlock_deferred",
                              detail: "trigger=\(deferred.rawValue) phase=locking（关库完成后补做）")
        }
        let before = snapshot
        let after = LockPolicy.next(before, on: trigger, strictScreenLock: strictScreenLock)
        guard after != before else { return }
        snapshot = after
        if before.phase != after.phase || before.pauseReasons != after.pauseReasons {
            recorder.logEvent(
                kind: "lock_transition",
                detail: "trigger=\(trigger.rawValue) \(before.phase.rawValue)→\(after.phase.rawValue)"
                      + " pause=[\(after.pauseDescription)] strict=\(strictScreenLock)")
        }
        // 3.5：`paused` 子状态下库开着，但采集暂停、**MCP 拒绝**。
        if before.pauseReasons != after.pauseReasons { ipc.setPaused(after.isPaused) }
        if before.phase == .unlocked && after.phase != .unlocked { onLocking?() }
        switch after.phase {
        case .unlocking where before.phase != .unlocking:
            beginUnlock()
        case .locking where before.phase != .locking:
            beginLock()
        default:
            break
        }
        onChange?()

        // 关库落地了：把 locking 期间攒下的那一次开库触发补上（一层递归，补完就清空）。
        if snapshot.phase == .locked, let pending = pendingUnlock {
            pendingUnlock = nil
            apply(pending)
        }
    }

    // MARK: - unlocking：取钥 → 开库 → 校验

    private func beginUnlock() {
        lastError = nil
        let directory = self.directory
        var options = StoreOptions()
        // E6 实测写入 ×1.38，D25 定为可选严格项；必须在**本进程第一次开库之前**设置才可靠，
        // 所以放在这里（这是采集端唯一的开库点）。
        options.cipherMemorySecurity = defaults.bool(forKey: "store.cipherMemorySecurity")
        let provider = KeychainKeyProvider()
        Task.detached(priority: .userInitiated) {
            do {
                let store = try Store.open(directory: directory, keyProvider: provider, options: options)
                // 3.5 的"校验"：真读一次库，密钥错 / 页大小不匹配在这里就会暴露。
                let build = try store.buildInfo()
                let observations = try store.count(table: "observations")
                await MainActor.run {
                    self.finishUnlock(store: store, build: build, observations: observations)
                }
            } catch {
                await MainActor.run { self.failUnlock(error) }
            }
        }
    }

    private func finishUnlock(store: Store, build: Store.BuildInfo, observations: Int) {
        // 开库期间来过锁定触发（睡眠 / 注销 / 低磁盘）：这把刚开的库直接关掉，不挂上去。
        // 判据用相位本身，不另设标志位——`LockPolicy` 已经保证 unlocking 期间的锁定触发会改相位。
        guard snapshot.phase == .unlocking else {
            Task.detached(priority: .userInitiated) {
                try? store.checkpoint()
                store.close()
            }
            return
        }
        self.store = store
        recorder.attach(store)
        // 3.1：MCP 只经本地 IPC 查询，服务端就在这里。socket 起来之后不再关，
        // 锁定 / 暂停时回明确错误（3.5），而不是让客户端连不上。
        ipc.attach(store: store)
        ipc.setPaused(snapshot.isPaused)
        ipc.startIfNeeded(directory: store.directory, defaults: defaults)
        CapturePolicyStore.shared.invalidateCache()
        CapturePolicyStore.shared.attach(recorder: recorder)
        let flags = DataDirectory.auditFlags(store.directory)
        recorder.logEvent(
            kind: "store_opened",
            detail: "dir_source=\(directorySource) device=\(store.deviceID) "
                  + "observations=\(observations) cipher=\(build.cipherVersion) "
                  + "page=\(build.cipherPageSize) journal=\(build.journalMode) "
                  + "auto_vacuum=\(build.autoVacuum) memsec=\(build.cipherMemorySecurity) "
                  + "mode=\(String(flags.mode, radix: 8)) never_index=\(flags.neverIndex) "
                  + "tm_excluded=\(flags.excludedFromBackup)"
                  + (lastCloseSummary.map { " prev_close=[\($0)]" } ?? ""))
        lastCloseSummary = nil
        apply(.unlockSucceeded)
        onUnlocked?()
    }

    private func failUnlock(_ error: Error) {
        lastError = "\(error)"
        apply(.unlockFailed)
    }

    // MARK: - locking：flush → checkpoint → 关库 → 清内存

    private func beginLock() {
        let store = self.store
        self.store = nil
        recorder.logEvent(kind: "store_closing", detail: recorder.stats.summary)
        // 顺序要紧：先让 MCP 停止服务（之后所有调用回 locked），再摘采集端、再关库。
        ipc.detach()
        recorder.detach()
        CapturePolicyStore.shared.invalidateCache()
        guard let store else {
            Task { @MainActor in self.apply(.lockCompleted) }
            return
        }
        Task.detached(priority: .userInitiated) {
            // flush + checkpoint(TRUNCATE)，再关连接、清零密钥（Store.close 内部做）。
            try? store.checkpoint()
            store.close()
            let zeroized = store.keyIsZeroized
            await MainActor.run { self.finishLock(keyZeroized: zeroized) }
        }
    }

    private func finishLock(keyZeroized: Bool) {
        lastCloseSummary = "key_zeroized=\(keyZeroized)"
        apply(.lockCompleted)
    }

    // MARK: - 供菜单调用

    func lockNow() { apply(.menuLock) }
    func unlockNow() { apply(.menuUnlock) }
    func pause() { apply(.menuPause) }
    func resume() { apply(.menuResume) }
    func togglePause() { snapshot.pauseReasons.contains(.user) ? resume() : pause() }

    /// 退出时同步关库：`applicationWillTerminate` 里主线程不能 await。
    func shutdown() {
        ipc.stop()
        guard let store else { return }
        self.store = nil
        recorder.logEvent(kind: "app_terminating", detail: recorder.stats.summary)
        recorder.detach()
        try? store.checkpoint()
        store.close()
        snapshot.phase = .locked
    }
}
