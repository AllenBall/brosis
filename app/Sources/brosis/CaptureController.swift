import AppKit
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
/// - 定时兜底：每 5 s 一次，只在 `source_state == ok`（有输入、未锁屏、非安全输入）时截。
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

    /// 定时兜底间隔（秒）。
    static let periodicInterval: TimeInterval = 5
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
        var lastCaptureAt: Double = 0
        var lastDurationMs: Double = 0
        var totalDurationMs: Double = 0

        var summary: String {
            let avg = captures > 0 ? totalDurationMs / Double(captures) : 0
            return "截图 \(captures) 张（门控 \(gated)，失败 \(failures)）"
                 + "，平均 \(Int(avg)) ms，跳过 锁屏 \(skippedLocked) / 安全输入 \(skippedSecureInput) / 空闲 \(skippedIdle)"
        }
    }

    private let store: Store
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

    init(store: Store, onEvent: @escaping @Sendable (CaptureEvent) -> Void) {
        self.store = store
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

    func setPaused(_ value: Bool) {
        withStateLock { paused = value }
        store.logEvent(kind: value ? "capture_paused" : "capture_resumed")
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
        if changed { store.logEvent(kind: "capture_display_changed", detail: "display=\(displayID)") }
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
        store.logEvent(kind: "capture_armed",
                       detail: "mode=on_demand display=\(display) periodic=\(Self.periodicInterval)s "
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
        store.logEvent(kind: "capture_disarmed", detail: "\(reason)；\(stats.summary)")
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
        case .ok:          requestCapture(reason: "periodic")
        case .locked:      withStateLock { stats.skippedLocked += 1 }
        case .secureInput: withStateLock { stats.skippedSecureInput += 1 }
        case .userIdle:    withStateLock { stats.skippedIdle += 1 }
        default:           break
        }
    }

    // MARK: - 触发

    /// 唯一的截图入口：合并 0.35 s 内的多次触发，保证两次截图至少间隔 1 s。
    func requestCapture(reason: String) {
        let work = withStateLock { () -> DispatchWorkItem? in
            guard armed, !paused else { return nil }
            pendingReasons.append(reason)
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
        Task.detached(priority: .utility) { [weak self] in
            await self?.capture(reason: reason)
        }
    }

    private func finish() {
        let reschedule = withStateLock { () -> Bool in
            captureInFlight = false
            return armed && !paused && !pendingReasons.isEmpty && pendingWork == nil
        }
        if reschedule { requestCapture(reason: "queued") }
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
            let excluded = content.applications.filter {
                ExclusionList.shared.contains(bundleID: $0.bundleIdentifier)
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
            stats.lastDurationMs = elapsedMs
            stats.totalDurationMs += elapsedMs
            return (hamming, cells, ratio, gated, stats.captures)
        }

        store.insertFrameStat(FrameStat(displayID: displayID,
                                        status: "complete",
                                        width: image.width,
                                        height: image.height,
                                        contentScale: pointWidth > 0 ? Double(image.width) / Double(pointWidth) : nil,
                                        dHashHex: hash?.hex,
                                        hamming: hamming,
                                        dirtyRectCount: changedCells,
                                        dirtyAreaRatio: changedRatio,
                                        gated: gated,
                                        trigger: reason))

        if count % Self.progressEvery == 0 {
            store.logEvent(kind: "capture_progress", detail: currentStats.summary)
        }
    }

    private func handleFailure(reason: String, displayID: UInt32, message: String, permissionLost: Bool) {
        withStateLock { stats.failures += 1 }
        store.insertFrameStat(FrameStat(displayID: displayID, status: "failed", trigger: reason))
        store.logEvent(kind: "capture_failed",
                       detail: "\(message) permission_lost=\(permissionLost) trigger=\(reason)")
        guard permissionLost else { return }
        // 权限被收回 / 月度再授权到期：解除武装，交给 AppDelegate 弹引导。
        Task { await stop(reason: "permission_lost") }
        onEvent(.stopped(reason: message, permissionLost: true))
    }
}

/// 排除清单（报告 3.4）。默认写死一份最小集合，Resources/exclusions.txt 存在时覆盖。
final class ExclusionList: @unchecked Sendable {
    static let shared = ExclusionList()

    private let bundleIDs: Set<String>
    /// true = 从 Contents/Resources/exclusions.txt 读到；false = 用代码内默认集合。
    let loadedFromResource: Bool

    private init() {
        var ids: Set<String> = [
            "com.apple.keychainaccess",
            "com.apple.Passwords",
            "com.agilebits.onepassword7", "com.1password.1password",
            "com.lastpass.LastPass", "org.keepassxc.keepassxc",
            "com.apple.ScreenSharing", "com.apple.iPhoneMirroring"
        ]
        var fromResource = false
        if let url = Bundle.main.url(forResource: "exclusions", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            let parsed = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            if !parsed.isEmpty {
                ids = Set(parsed)
                fromResource = true
            }
        }
        bundleIDs = ids
        loadedFromResource = fromResource
    }

    func contains(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }

    var count: Int { bundleIDs.count }
}
