import AppKit
import BrosisCore
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 采集器的对外事件。
enum CaptureEvent: Sendable {
    /// 已武装：权限齐备，开始响应触发；不代表已经截过图。
    case started(displayID: UInt32)
    case stopped(reason: String, permissionLost: Bool)
}

/// 按需截图（2026-09-07 用户决定，取代常驻 SCStream）。
///
/// 为什么改：macOS 14.4 起只要有 SCStream 在跑，菜单栏就常亮紫色"正在共享"图标，
/// 用户觉得打扰。`SCScreenshotManager.captureImage` 是一次性截图，图标只在截图瞬间出现。
///
/// 触发来源（都经 `requestCapture(reason:)`，0.35 s 合并、两次截图至少间隔 1 s）：
/// - 事件骨架每写一条应用级观察记录（切应用、切窗口、标题变化、节流后的焦点元素变化）；
/// - 焦点窗口换到另一台显示器；
/// - 系统唤醒 / 解锁回来；
/// - 定时兜底：默认每 12 s 一次（2026-09-07 由 5 s 放宽，见 `periodicInterval`），
///   只在 `source_state == ok`（有输入、未锁屏、非安全输入）时截，
///   且距最近一次事件触发的截图不足一个兜底间隔时**跳过本次兜底**（计入 `stats.skippedRecent`）。
/// 锁屏、安全键盘输入时一律不截；用户空闲（≥30 s 无输入）时只响应事件、不做定时兜底。
///
/// 每张图只算一次 dHash 与 32×32 网格亮度差，随即丢弃，不保存图像。`frame_stats` 口径：
/// `dirty_area_ratio` = 网格里亮度变化 > 24/255 的格子占比（替代流才有的 dirtyRects），
/// `dirty_rects` = 变化格子数；门控阈值与流时代相同（汉明 ≤ 6 且面积 < 2% → gated=1，只表示
/// "不触发内容检查"，不是丢证据，评审 F5）。
final class CaptureController: NSObject, @unchecked Sendable {

    enum CaptureError: LocalizedError {
        case screenRecordingMissing
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .screenRecordingMissing: return "缺少屏幕录制权限，未武装截图"
            case .noDisplay: return "未找到可用显示器"
            }
        }
    }

    /// 帧门控阈值（报告 3.4）。
    static let gateHammingThreshold = 6
    static let gateDirtyAreaThreshold = 0.02
    /// 网格亮度差阈值（0–255）。
    static let gridDiffThreshold = 24

    /// 定时兜底间隔（秒），默认 **12 s**。
    ///
    /// 为什么从 5 s 放宽：M0 实测（`tools/bench/results/m0_closeout_2026-09-07.md` 2.3）
    /// 11.8 分钟出 129 张 `periodic` 截图，其中 **111 张（86%）被门控**、平均变化面积只有 0.73%，
    /// 也就是绝大多数定时兜底没有新信息；同一段时间事件触发的 50 张平均变化面积 4.5%、门控率 60%。
    /// 配合下面「刚因为事件截过图就跳过这次兜底」的规则，兜底张数还能再降。
    ///
    /// 需要临时改回去（例如复现 M0 的口径）用 UserDefaults，不必重新编译：
    /// `defaults write com.brosis.app capture.periodicInterval -float 5`
    /// 值会被夹到下限 3 s 以上；没设或设成非法值（≤ 0 / NaN）时用默认 12 s。
    static let periodicIntervalKey = "capture.periodicInterval"
    static let periodicIntervalDefault: TimeInterval = 12
    static let periodicIntervalMinimum: TimeInterval = 3

    private static let periodicIntervalResolution = resolvePeriodicInterval()
    static var periodicInterval: TimeInterval { periodicIntervalResolution.value }
    /// `default` / `defaults` / `defaults_clamped` / `defaults_invalid`，写进 `capture_armed`。
    static var periodicIntervalSource: String { periodicIntervalResolution.source }

    static func resolvePeriodicInterval(_ defaults: UserDefaults = .standard)
        -> (value: TimeInterval, source: String) {
        guard defaults.object(forKey: periodicIntervalKey) != nil else {
            return (periodicIntervalDefault, "default")
        }
        let raw = defaults.double(forKey: periodicIntervalKey)
        guard raw.isFinite, raw > 0 else { return (periodicIntervalDefault, "defaults_invalid") }
        let clamped = max(periodicIntervalMinimum, raw)
        return (clamped, clamped == raw ? "defaults" : "defaults_clamped")
    }

    /// 两次截图的最小间隔（秒）。
    static let minimumInterval: TimeInterval = 1.0
    /// 事件合并窗口（秒）。
    static let debounceInterval: TimeInterval = 0.35
    /// 每累计这么多张写一条进度事件。
    static let progressEvery = 50

    struct Stats: Sendable {
        var captures = 0
        var failures = 0
        var gated = 0
        var skippedLocked = 0
        var skippedSecureInput = 0
        var skippedIdle = 0
        /// 定时兜底因为「刚因为事件截过图」而跳过的次数。
        var skippedRecent = 0
        /// 3.12：前台应用不是「事件 + 内容」档，本次不做截图内容检查。
        var skippedPolicy = 0
        var lastCaptureAt: Double = 0
        /// 最近一次**事件触发**截图的时间（`armed` 也算），定时兜底用它判断「刚截过图就别再截一张」。
        /// 判定见 `CaptureController.isEventTrigger(_:)`：合并后的触发集合里去掉
        /// `periodic` / `queued` 之后还有东西才算事件。
        var lastEventCaptureAt: Double = 0
        var lastDurationMs: Double = 0
        var totalDurationMs: Double = 0

        var summary: String {
            let avg = captures > 0 ? totalDurationMs / Double(captures) : 0
            return "截图 \(captures) 张（门控 \(gated)，失败 \(failures)）"
                 + "，平均 \(Int(avg)) ms，跳过 锁屏 \(skippedLocked) / 安全输入 \(skippedSecureInput)"
                 + " / 空闲 \(skippedIdle) / 刚截过 \(skippedRecent) / 策略 \(skippedPolicy)"
        }
    }

    private let recorder: Recorder
    private let policy: CapturePolicyStore
    private let hasher = DHasher()
    private let onEvent: @Sendable (CaptureEvent) -> Void
    private let queue = DispatchQueue(label: "com.brosis.app.capture", qos: .utility)

    private let lock = NSLock()
    private var armed = false
    private var paused = false
    private var activeDisplayID: UInt32?
    private var pendingWork: DispatchWorkItem?
    private var pendingReasons: [String] = []
    private var periodicTimer: DispatchSourceTimer?
    private var captureInFlight = false
    private var stats = Stats()
    private var previousHash: DHash?
    private var previousGrid: [UInt8]?
    /// 前台应用与它的采集档位。由 `AppDelegate` 在焦点变化时推进来——
    /// 截图跑在 utility 队列上，不能在那里去问 `NSWorkspace.frontmostApplication`。
    private var frontmostBundleID: String?
    private var frontmostMode: CapturePolicyMode = CapturePolicyStore.globalDefault

    init(recorder: Recorder,
         policy: CapturePolicyStore = .shared,
         onEvent: @escaping @Sendable (CaptureEvent) -> Void) {
        self.recorder = recorder
        self.policy = policy
        self.onEvent = onEvent
        super.init()
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var currentDisplayID: UInt32? { withStateLock { activeDisplayID } }
    var isRunning: Bool { withStateLock { armed } }
    var currentStats: Stats { withStateLock { stats } }

    /// 暂停 / 恢复。**只在状态真的变了的时候写事件**（R2 修正）。
    ///
    /// `AppDelegate.syncSubsystems()` 每次菜单展开、每次权限复查、每次进 `unlocked` 都会调一次
    /// `setPaused(false)`；无条件写事件的话 `capture_resumed` 会在 `jobs` 里刷屏，
    /// 把真正的暂停 / 恢复淹掉。
    func setPaused(_ value: Bool) {
        let changed = withStateLock { () -> Bool in
            guard paused != value else { return false }
            paused = value
            return true
        }
        guard changed else { return }
        recorder.logEvent(kind: value ? "capture_paused" : "capture_resumed")
    }

    /// 3.12：前台应用换了 / 它的档位变了。`AppDelegate` 在焦点变化与改档时调。
    func setFrontmostApp(bundleID: String?, mode: CapturePolicyMode) {
        let changed = withStateLock { () -> Bool in
            guard frontmostBundleID != bundleID || frontmostMode != mode else { return false }
            frontmostBundleID = bundleID
            frontmostMode = mode
            return true
        }
        guard changed else { return }
        recorder.logEvent(kind: "capture_policy_frontmost",
                          detail: "bundle=\(bundleID ?? "(unknown)") mode=\(mode.rawValue)")
    }

    /// 焦点换屏：只换目标显示器，不重建任何东西。
    func setDisplay(_ displayID: UInt32?) {
        guard let displayID else { return }
        let changed = withStateLock { () -> Bool in
            guard activeDisplayID != displayID else { return false }
            activeDisplayID = displayID
            previousHash = nil          // 换屏后第一张图没有可比对象
            previousGrid = nil
            return true
        }
        if changed { recorder.logEvent(kind: "capture_display_changed", detail: "display=\(displayID)") }
    }

    // MARK: - 武装 / 解除

    /// 武装。调用前必须已确认屏幕录制权限，否则直接抛错——绝不在这里触发弹窗。
    /// 保留 `start(displayID:)` 的签名是为了让 AppDelegate 的调用点不变。
    func start(displayID: UInt32?) async throws {
        guard Permissions.snapshot().screenRecording else { throw CaptureError.screenRecordingMissing }
        let display = displayID ?? CGMainDisplayID()
        withStateLock {
            armed = true
            activeDisplayID = display
            previousHash = nil
            previousGrid = nil
            stats = Stats()
        }
        startPeriodicTimer()
        recorder.logEvent(kind: "capture_armed",
                       detail: "mode=on_demand display=\(display) periodic=\(Self.periodicInterval)s "
                             + "periodic_source=\(Self.periodicIntervalSource) "
                             + "min_interval=\(Self.minimumInterval)s debounce=\(Self.debounceInterval)s")
        onEvent(.started(displayID: display))
        requestCapture(reason: "armed")
    }

    func stop(reason: String) async {
        let wasArmed = withStateLock { () -> Bool in
            let was = armed
            armed = false
            activeDisplayID = nil
            pendingWork?.cancel()
            pendingWork = nil
            pendingReasons.removeAll()
            return was
        }
        stopPeriodicTimer()
        guard wasArmed else { return }
        let stats = currentStats
        recorder.logEvent(kind: "capture_disarmed", detail: "\(reason)；\(stats.summary)")
    }

    private func startPeriodicTimer() {
        stopPeriodicTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.periodicInterval, repeating: Self.periodicInterval)
        timer.setEventHandler { [weak self] in self?.periodicTick() }
        timer.resume()
        withStateLock { periodicTimer = timer }
    }

    private func stopPeriodicTimer() {
        let timer = withStateLock { () -> DispatchSourceTimer? in
            let t = periodicTimer
            periodicTimer = nil
            return t
        }
        timer?.cancel()
    }

    private func periodicTick() {
        // 定时兜底只在用户活跃时截；空闲 / 锁屏 / 安全输入都跳过。
        let state = SystemState.sourceState(permissions: Permissions.snapshot())
        switch state {
        case .ok:
            // 距最近一次事件触发的截图不足一个兜底间隔就跳过：那一张刚拍过，
            // 这次兜底大概率还是被门控的那 86%（m0_closeout 2.3）。
            let skip = withStateLock { () -> Bool in
                guard stats.lastEventCaptureAt > 0,
                      Date().timeIntervalSince1970 - stats.lastEventCaptureAt < Self.periodicInterval
                else { return false }
                stats.skippedRecent += 1
                return true
            }
            if !skip { requestCapture(reason: "periodic") }
        case .locked:      withStateLock { stats.skippedLocked += 1 }
        case .secureInput: withStateLock { stats.skippedSecureInput += 1 }
        case .userIdle:    withStateLock { stats.skippedIdle += 1 }
        default:           break
        }
    }

    // MARK: - 触发

    /// 唯一的截图入口：合并 0.35 s 内的多次触发，保证两次截图至少间隔 1 s。
    func requestCapture(reason: String) {
        let accepted = withStateLock { () -> Bool in
            guard armed, !paused else { return false }
            pendingReasons.append(reason)
            return true
        }
        guard accepted else { return }
        schedulePending()
    }

    /// 把已经攒下的触发排进队列。**不新增触发原因**——`finish()` 的重排队走这里，
    /// 所以被延后的那次截图仍然带着它自己的原始触发集合（R2 修正，见 `isEventTrigger`）。
    private func schedulePending() {
        let work = withStateLock { () -> DispatchWorkItem? in
            guard armed, !paused, !pendingReasons.isEmpty else { return nil }
            pendingWork?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.runPending() }
            pendingWork = item
            return item
        }
        guard let work else { return }
        let delay = withStateLock { () -> TimeInterval in
            let sinceLast = Date().timeIntervalSince1970 - stats.lastCaptureAt
            return max(Self.debounceInterval, Self.minimumInterval - sinceLast)
        }
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 合并后的触发串（`"app_activated+periodic"`）算不算**事件触发**。
    ///
    /// 纯函数，自检直接跑。口径：去掉 `periodic`（纯定时兜底）与 `queued`
    /// （历史上 `finish()` 重排队时加的内部标记）之后还剩下东西才算事件。
    ///
    /// 为什么要有它（R2 修正的问题）：`finish()` 以前用 `requestCapture(reason: "queued")`
    /// 重排队，被延后的**纯定时**截图于是变成 `"periodic+queued"`，
    /// 旧口径 `reason != "periodic"` 把它当成事件触发写进 `lastEventCaptureAt`，
    /// 于是下一个兜底窗口被"刚截过图"压掉——纯定时截图反而抑制了下一次纯定时截图。
    /// 现在 `finish()` 不再追加原因，`capture_stats.trigger` 里也不会再出现 `queued`；
    /// 这里保留对 `queued` 的过滤只是为了兼容老库里的历史值。
    static let nonEventTriggers: Set<String> = ["periodic", "queued"]

    static func isEventTrigger(_ reason: String) -> Bool {
        reason.split(separator: "+").contains { !nonEventTriggers.contains(String($0)) }
    }

    private func runPending() {
        let job = withStateLock { () -> String? in
            guard armed, !paused, !captureInFlight, !pendingReasons.isEmpty else { return nil }
            let reason = Set(pendingReasons).sorted().joined(separator: "+")
            pendingReasons.removeAll()
            pendingWork = nil
            captureInFlight = true
            return reason
        }
        guard let reason = job else {
            // 有截图在进行中：等它结束后由 finish() 重新调度。
            return
        }
        // 锁屏与安全输入时绝不截（用户空闲时事件触发的仍然截）。
        if SystemState.screenLocked() {
            withStateLock { stats.skippedLocked += 1; captureInFlight = false }
            return
        }
        if SystemState.secureInputEnabled() {
            withStateLock { stats.skippedSecureInput += 1; captureInFlight = false }
            return
        }
        // 3.12「生效方式在采集时」：前台应用不是「事件 + 内容」档就不做内容检查。
        // 「不采集」的应用还会另外进 SCContentFilter 的排除列表（见 capture(reason:)），
        // 两道是互补的——排除列表挡的是"别的窗口在前台时它露出来的那部分"。
        let mode = withStateLock { frontmostMode }
        if CapturePolicyStore.gate(for: mode).readsContent == false {
            withStateLock { stats.skippedPolicy += 1; captureInFlight = false }
            recorder.recordCaptureStat(status: "skipped", trigger: reason)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            await self?.capture(reason: reason)
        }
    }

    private func finish() {
        let reschedule = withStateLock { () -> Bool in
            captureInFlight = false
            return armed && !paused && !pendingReasons.isEmpty && pendingWork == nil
        }
        // 重排队不追加任何原因：被延后的那次截图保留它自己的原始触发集合。
        if reschedule { schedulePending() }
    }

    // MARK: - 截图

    private func capture(reason: String) async {
        defer { finish() }
        let started = Date()
        let displayID = currentDisplayID ?? CGMainDisplayID()

        guard Permissions.snapshot().screenRecording else {
            handleFailure(reason: reason, displayID: displayID,
                          message: "preflight=false", permissionLost: true)
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                    ?? content.displays.first else {
                throw CaptureError.noDisplay
            }
            // 3.12：排除列表 = 所有解析结果为「不采集」的运行中应用
            // （内置默认清单 + 用户改档 + 今日临时暂停都在 resolve 里合过了）。
            // 顺带把没见过的 bundle id 登记进 app_policies，第二轮的应用清单窗口要用。
            let excluded = content.applications.filter {
                self.policy.resolve(bundleID: $0.bundleIdentifier).mode == .none
            }
            let filter = SCContentFilter(display: display,
                                         excludingApplications: excluded,
                                         exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = display.width           // 点尺寸 = 1x
            configuration.height = display.height
            configuration.captureDynamicRange = .SDR
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.showsCursor = false
            configuration.scalesToFit = true

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: configuration)
            let elapsedMs = Date().timeIntervalSince(started) * 1000
            analyze(image, displayID: display.displayID, reason: reason,
                    pointWidth: display.width, elapsedMs: elapsedMs)
        } catch {
            let nsError = error as NSError
            let permissionLost = !Permissions.snapshot().screenRecording
                || (nsError.domain == SCStreamErrorDomain && nsError.code == -3801)
            handleFailure(reason: reason, displayID: displayID,
                          message: "domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)",
                          permissionLost: permissionLost)
        }
    }

    /// 像素只在这里用一次：dHash + 32×32 网格，然后随 CGImage 一起丢弃。
    private func analyze(_ image: CGImage, displayID: UInt32, reason: String,
                         pointWidth: Int, elapsedMs: Double) {
        let hash = hasher.hash(cgImage: image)
        let grid = hasher.luminanceGrid(cgImage: image)

        let (hamming, changedCells, changedRatio, gated, count) = withStateLock {
            () -> (Int?, Int?, Double?, Bool, Int) in
            let hamming = (hash != nil && previousHash != nil) ? previousHash!.hamming(to: hash!) : nil
            var cells: Int? = nil
            var ratio: Double? = nil
            if let grid, let previousGrid, grid.count == previousGrid.count {
                let diff = DHasher.changedCells(grid, previousGrid, threshold: Self.gridDiffThreshold)
                cells = diff
                ratio = Double(diff) / Double(grid.count)
            }
            if let hash { previousHash = hash }
            if let grid { previousGrid = grid }
            let gated: Bool = {
                guard let hamming, let ratio else { return false }
                return hamming <= Self.gateHammingThreshold && ratio < Self.gateDirtyAreaThreshold
            }()
            stats.captures += 1
            if gated { stats.gated += 1 }
            stats.lastCaptureAt = Date().timeIntervalSince1970
            // 合并后的 reason 里只要还有**别的**触发（"app_activated+periodic"）才算事件触发；
            // 纯定时与内部重排队标记不算（`isEventTrigger` 是纯函数，自检覆盖）。
            if Self.isEventTrigger(reason) { stats.lastEventCaptureAt = stats.lastCaptureAt }
            stats.lastDurationMs = elapsedMs
            stats.totalDurationMs += elapsedMs
            return (hamming, cells, ratio, gated, stats.captures)
        }

        recorder.recordCaptureStat(displayID: displayID,
                                   status: "complete",
                                   trigger: reason,
                                   width: image.width,
                                   height: image.height,
                                   contentScale: pointWidth > 0
                                       ? Double(image.width) / Double(pointWidth) : nil,
                                   dhash: hash?.hex,
                                   hamming: hamming,
                                   dirtyRects: changedCells,
                                   dirtyAreaRatio: changedRatio,
                                   gated: gated)

        if count % Self.progressEvery == 0 {
            recorder.logEvent(kind: "capture_progress", detail: currentStats.summary)
        }
    }

    private func handleFailure(reason: String, displayID: UInt32, message: String, permissionLost: Bool) {
        withStateLock { stats.failures += 1 }
        recorder.recordCaptureStat(displayID: displayID, status: "failed", trigger: reason)
        recorder.logEvent(kind: "capture_failed",
                       detail: "\(message) permission_lost=\(permissionLost) trigger=\(reason)")
        guard permissionLost else { return }
        // 权限被收回 / 月度再授权到期：解除武装，交给 AppDelegate 弹引导。
        Task { await stop(reason: "permission_lost") }
        onEvent(.stopped(reason: message, permissionLost: true))
    }
}
