import AppKit
import BrosisCore
import BrosisSync
import Foundation

// =============================================================================
// D17 / 3.9「app 内开关：iCloud 同步」的执行体。
//
// **本文件不改 AppDelegate**（M2 c 批的并行约定）。接入方式只有两行，由主会话加：
//
//     // AppDelegate.applicationDidFinishLaunching(_:) 里，lock 建好之后：
//     sync = SyncController()
//     sync.install(lock: lock, recorder: recorder)
//
//     // 菜单里加一项（可选，窗口也能从 sync.presentWindow() 打开）：
//     menu.addItem(NSMenuItem(title: "跨设备同步…", action: #selector(openSync), keyEquivalent: ""))
//     @objc private func openSync() { sync?.presentWindow() }
//
//   `install` 会**接住并保留** LockController 原有的 `onUnlocked` / `onLocking` 回调
//   （链式调用，不覆盖），所以加这两行不影响现有行为。
//
// 循环什么时候跑（3.5 / 3.9）：
//   - 只在 `phase == .unlocked` 跑——库开着才有得读写。`locked` / `locking` / `unlocking` 全停。
//   - `paused`（屏幕锁定、用户暂停、屏保）**不停同步**：暂停的是"采集新内容"，
//     同步只是把已经采集到的东西搬运出去 / 搬进来，不产生新的观察，也不看屏幕。
//     这一条写在这里是因为它是个判断，不是疏忽。
//   - 默认间隔 5 分钟（3.9「定期（如每 5 分钟或每 N 条）」），UserDefaults 可改。
// =============================================================================

@MainActor
final class SyncController {

    // MARK: - UserDefaults 键

    enum Key {
        static let enabled = "sync.enabled"
        static let directory = "sync.directory"
        static let intervalSeconds = "sync.intervalSeconds"
        static let deviceName = "sync.deviceName"
    }

    nonisolated static let defaultIntervalSeconds: TimeInterval = 300      // 3.9：每 5 分钟
    nonisolated static let minimumIntervalSeconds: TimeInterval = 30

    /// 3.9 的默认目录：`~/Library/Mobile Documents/com~apple~CloudDocs/brosis-sync/`。
    /// 普通文件系统路径，**不需要 iCloud 容器 entitlement**。
    nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/brosis-sync",
                                    isDirectory: true)
    }

    // MARK: - 状态（3.9「状态显示」）

    struct Status: Sendable {
        var enabled = false
        var directory = ""
        var running = false
        var deviceID = ""
        var keyID = ""
        var lastRunAt: Date?
        var lastError: String?
        var pendingExportObservations = 0
        var pendingExportTombstones = 0
        var pendingImportSegments = 0
        var peers: [PeerLine] = []
        var ownSegments = 0
        var segmentBytes = 0

        struct PeerLine: Sendable {
            var deviceID: String
            var name: String?
            var importedSeq: Int64
            var pendingSegments: Int
            var lastSeen: Date?
            var lastError: String?
        }

        /// 菜单栏 / 窗口顶部的一行摘要。
        var summary: String {
            guard enabled else { return "同步：关" }
            if let lastError { return "同步：出错——\(lastError)" }
            let time = lastRunAt.map { Self.timeFormatter.string(from: $0) } ?? "还没跑过"
            return "同步：开 · 上次 \(time) · 待出站 \(pendingExportObservations) 条 / "
                 + "待入站 \(pendingImportSegments) 段 · 其他设备 \(peers.count) 台"
        }

        static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter
        }()
    }

    private(set) var status = Status()
    /// 状态变化时回调（窗口 / 菜单刷新）。
    var onChange: (@MainActor () -> Void)?

    // MARK: - 内部

    private let defaults: UserDefaults
    private weak var lock: LockController?
    private weak var recorder: Recorder?
    private var timer: Timer?
    private var engine: SyncEngine?
    private var busy = false
    /// 同步的文件 I/O 与加密都在这条串行队列上，绝不占主线程。
    private let queue = DispatchQueue(label: "com.brosis.sync", qos: .utility)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        status.enabled = defaults.bool(forKey: Key.enabled)
        status.directory = Self.configuredDirectory(defaults).path
    }

    nonisolated static func configuredDirectory(_ defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: Key.directory), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultDirectory
    }

    nonisolated static func interval(_ defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: Key.intervalSeconds)
        guard value > 0 else { return defaultIntervalSeconds }
        return max(minimumIntervalSeconds, value)
    }

    // MARK: - 接入

    /// 挂到锁定状态机上。**链式**保留原有回调，不覆盖。
    func install(lock: LockController, recorder: Recorder) {
        self.lock = lock
        self.recorder = recorder
        let previousUnlocked = lock.onUnlocked
        lock.onUnlocked = { [weak self] in
            previousUnlocked?()
            self?.startIfEnabled()
        }
        let previousLocking = lock.onLocking
        lock.onLocking = { [weak self] in
            previousLocking?()
            self?.stopLoop()
        }
        if lock.snapshotPhaseIsUnlocked { startIfEnabled() }
    }

    // MARK: - 开关（3.9「设置里一个开关，默认关」）

    /// 打开开关。
    ///
    /// - Parameter passphrase: 目录已经存在（另一台机器建的）时必须给配对口令。
    /// - Returns: 只有"这台机器新建了目录"时才有值——**要显示一次**的配对口令。
    @discardableResult
    func enable(directory: URL? = nil, passphrase: String? = nil) throws -> String? {
        guard let store = currentStore() else {
            throw SyncControllerError.databaseClosed
        }
        let root = directory ?? Self.configuredDirectory(defaults)
        // 3.9 的流程 ①：iCloud Drive 没登录 / 没启用时，默认目录的父目录根本不存在。
        if root.path.contains("com~apple~CloudDocs"),
           !FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path) {
            throw SyncControllerError.iCloudUnavailable
        }
        let opened = try SyncEngine.openOrCreate(store: store, root: root,
                                                 passphrase: passphrase,
                                                 options: makeOptions(),
                                                 logEvent: makeLogger())
        engine = opened.engine
        defaults.set(true, forKey: Key.enabled)
        defaults.set(root.path, forKey: Key.directory)
        status.enabled = true
        status.directory = root.path
        status.lastError = nil
        log("sync_enabled", "dir_kind=\(Self.directoryKind(root)) created=\(opened.created)")
        refreshStatus()
        startLoop()
        return opened.generatedPassphrase
    }

    /// 关开关：停两个循环，**本机已合并的数据保留**（3.9「关闭开关」）。
    /// "退出并删除本机段文件"是另一个独立操作，本轮不做（见结果文件的"未做"）。
    func disable() {
        stopLoop()
        engine = nil
        defaults.set(false, forKey: Key.enabled)
        status.enabled = false
        status.running = false
        log("sync_disabled", "本机已合并的数据保留")
        refreshStatus()
    }

    /// 目录种类，只记类别不记路径——路径里可能有用户名。
    nonisolated static func directoryKind(_ url: URL) -> String {
        let path = url.path
        if path.contains("com~apple~CloudDocs") { return "icloud_drive" }
        if path.contains("Mobile Documents") { return "icloud_container" }
        return "custom"
    }

    // MARK: - 循环

    private func startIfEnabled() {
        guard defaults.bool(forKey: Key.enabled) else { return }
        guard let store = currentStore() else { return }
        let root = Self.configuredDirectory(defaults)
        do {
            // 本机已经有同步密钥了（存在加密库里），所以重新开库之后不需要再问口令。
            engine = try SyncEngine.openOrCreate(store: store, root: root, passphrase: nil,
                                                 options: makeOptions(),
                                                 logEvent: makeLogger()).engine
            status.lastError = nil
            startLoop()
        } catch {
            engine = nil
            status.lastError = "\(error)"
            log("sync_open_failed", "\(error)")
        }
        refreshStatus()
    }

    private func startLoop() {
        stopLoop()
        guard status.enabled, engine != nil else { return }
        status.running = true
        let interval = Self.interval(defaults)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        runNow()          // 3.9：打开后先导入已有段文件，再开始导出
    }

    private func stopLoop() {
        timer?.invalidate()
        timer = nil
        status.running = false
    }

    /// 立即跑一轮（定时器与「立即同步」按钮共用）。
    ///
    /// 引擎**只在 `queue` 这一条串行队列上被碰**（`SyncEngine` 自己没有锁，见它的类注释），
    /// 所以状态刷新也走同一条队列，再跳回主线程更新界面。
    func runNow() {
        guard !busy, let engine, lock?.snapshotPhaseIsUnlocked == true else { return }
        busy = true
        let logger = makeLogger()
        queue.async { [weak self] in
            var failure: String?
            var line = ""
            do {
                let round = try engine.runOnce()
                line = "import=\(round.imported.segments) 段/"
                     + "\(round.imported.stats.observationsInserted) 条 "
                     + "export=\(round.exported.segments) 段/\(round.exported.observations) 条 "
                     + "cleanup=\(round.cleaned)"
                if !round.imported.ok { failure = round.imported.errors.first }
            } catch {
                failure = "\(error)"
            }
            if !line.isEmpty { logger("sync_round", line) }
            let snapshot = try? engine.status()
            let captured = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = false
                    self.status.lastRunAt = Date()
                    self.status.lastError = captured
                    self.apply(snapshot)
                }
            }
        }
    }

    // MARK: - 状态刷新

    /// 异步刷新：读状态也要在 `queue` 上（它会读库与目录）。
    func refreshStatus() {
        guard let engine else {
            status.peers = []
            status.pendingImportSegments = 0
            onChange?()
            return
        }
        queue.async { [weak self] in
            let snapshot = try? engine.status()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot) }
            }
        }
    }

    private func apply(_ snapshot: SyncStatus?) {
        defer { onChange?() }
        guard let snapshot else { return }
        status.deviceID = snapshot.deviceID
        status.keyID = snapshot.keyID
        status.directory = snapshot.directory
        status.pendingExportObservations = snapshot.state.pendingObservations
        status.pendingExportTombstones = snapshot.state.pendingTombstones
        status.pendingImportSegments = snapshot.pendingImports.values.reduce(0, +)
        status.ownSegments = snapshot.ownSegments
        status.segmentBytes = snapshot.segmentBytes
        status.peers = snapshot.state.peers.map { peer in
            Status.PeerLine(deviceID: peer.deviceID, name: peer.name,
                            importedSeq: peer.importedSeq,
                            pendingSegments: snapshot.pendingImports[peer.deviceID] ?? 0,
                            lastSeen: peer.lastSeen > 0
                                ? Date(timeIntervalSince1970: Double(peer.lastSeen) / 1000) : nil,
                            lastError: peer.lastError)
        }
    }

    // MARK: - 窗口

    private lazy var windowController = SyncWindowController()

    func presentWindow() {
        windowController.configure(controller: self)
        windowController.present()
    }

    // MARK: - 小件

    private func makeOptions() -> SyncOptions {
        var options = SyncOptions()
        // 设备名：用户可在 UserDefaults 里改；默认用电脑名（只写进同步目录，不入库）。
        options.deviceName = defaults.string(forKey: Key.deviceName) ?? Host.current().localizedName
        return options
    }

    private func currentStore() -> Store? {
        recorder?.withStore { $0 }
    }

    private func log(_ kind: String, _ detail: String) {
        recorder?.logEvent(kind: kind, detail: detail)
    }

    /// 给引擎用的事件出口。捕获的是 `Recorder`（`@unchecked Sendable`）而不是 `self`——
    /// `SyncController` 是 `@MainActor` 的，从队列上调它的方法会是跨隔离域调用。
    private func makeLogger() -> @Sendable (String, String) -> Void {
        let recorder = self.recorder
        return { kind, detail in recorder?.logEvent(kind: kind, detail: detail) }
    }
}

enum SyncControllerError: Error, CustomStringConvertible {
    case databaseClosed
    case iCloudUnavailable

    var description: String {
        switch self {
        case .databaseClosed:
            return "库没打开（锁定中），先解锁再打开同步"
        case .iCloudUnavailable:
            return "iCloud Drive 没登录或没启用，找不到 iCloud Drive 目录；"
                 + "登录后再打开，或在高级选项里换成别的同步目录（3.9）"
        }
    }
}

extension LockController {
    /// 只读的相位判断，供不该知道 `LockSnapshot` 细节的调用方用。
    /// **`paused` 也算 unlocked**：暂停的是采集，不是同步（见 SyncController 的文件头）。
    var snapshotPhaseIsUnlocked: Bool { snapshot.phase == .unlocked }
}
