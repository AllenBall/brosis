import BrosisCore
import Foundation

/// 采集端写入 `BrosisCore.Store` 的唯一出口。
///
/// M1 起采集端**不再自己开库**（计划 3.1：单一存储服务是唯一持钥者）。
/// `Recorder` 只是一层薄壳，作用有三个：
///
/// 1. **随锁定状态机开合**（3.5）。库在 `locked` / `locking` 时不存在，此时所有写入
///    调用都必须是安全的空操作，而不是崩溃或抛错——采集端的事件源（AXObserver 回调、
///    DispatchSourceTimer）是异步的，不可能保证它们在关库那一刻全部静默。
///    丢弃的写入按类型计数，重新开库后写一条 `recorder_dropped` 事件，
///    这样"锁定期间丢了多少"是可核对的，而不是悄悄消失。
/// 2. **跨线程**。事件骨架在主线程、截图在 utility 队列、锁定状态机在主线程，
///    三方都要写库。`BrosisCore.Store` 内部本来就是一把 `NSLock` 串行的，
///    这里只需要保护"库指针本身"的替换。
/// 3. **吞掉写入错误**。采集端不能因为一次写库失败就中断采集；错误计数 + 最近一条错误
///    进菜单，并写 `recorder_error` 事件（下一次库可用时）。
final class Recorder: @unchecked Sendable {

    struct Counters: Sendable {
        var observations = 0
        var events = 0
        var captureStats = 0
        var droppedObservations = 0
        var droppedEvents = 0
        var droppedCaptureStats = 0
        var errors = 0

        var droppedTotal: Int { droppedObservations + droppedEvents + droppedCaptureStats }

        var summary: String {
            "观察 \(observations) / 事件 \(events) / 遥测 \(captureStats)"
                + "，锁定期间丢弃 观察 \(droppedObservations) / 事件 \(droppedEvents)"
                + " / 遥测 \(droppedCaptureStats)，写入错误 \(errors)"
        }
    }

    private let lock = NSLock()
    private var store: Store?
    private var counters = Counters()
    private var lastErrorText: String?
    /// 关库期间攒下的、下次开库要补记的说明。
    private var pendingNotes: [String] = []

    init() {}

    // MARK: - 开合（由 LockController 调用）

    /// `unlocking` 成功后挂上库；同时把上一次锁定期间的丢弃计数补记成一条事件。
    func attach(_ store: Store) {
        let notes: [String] = lock.withLock {
            self.store = store
            let out = pendingNotes
            pendingNotes.removeAll()
            return out
        }
        for note in notes { logEvent(kind: "recorder_dropped", detail: note) }
    }

    /// `locking` 时摘掉库指针。**不负责 close**——关库是 `LockController` 的事，
    /// 它要先 checkpoint 再关，顺序不能由这里决定。
    func detach() {
        lock.withLock {
            store = nil
            if counters.droppedTotal > 0 || counters.errors > 0 {
                pendingNotes.append(counters.summary)
            }
        }
    }

    var isOpen: Bool { lock.withLock { store != nil } }
    var stats: Counters { lock.withLock { counters } }
    var lastError: String? { lock.withLock { lastErrorText } }

    /// 只给自检与维护用：拿到底层 store 做一次只读操作。库没开时返回 nil。
    func withStore<T>(_ body: (Store) throws -> T) -> T? {
        let handle: Store? = lock.withLock { store }
        guard let handle else { return nil }
        do {
            return try body(handle)
        } catch {
            noteError(error)
            return nil
        }
    }

    // MARK: - 写入

    /// 一次观察。库没开就丢弃并计数（返回 nil）。
    @discardableResult
    func record(_ input: ObservationInput) -> Int64? {
        let handle: Store? = lock.withLock { store }
        guard let handle else {
            lock.withLock { counters.droppedObservations += 1 }
            return nil
        }
        do {
            let result = try handle.record(input)
            lock.withLock { counters.observations += 1 }
            return result.observationID
        } catch {
            noteError(error)
            return nil
        }
    }

    /// 运行期事件 → core 的 `jobs`（`type = 'runtime_event:<kind>'`）。
    func logEvent(kind: String, detail: String? = nil) {
        let handle: Store? = lock.withLock { store }
        guard let handle else {
            lock.withLock { counters.droppedEvents += 1 }
            return
        }
        do {
            try handle.recordRuntimeEvent(kind: kind, detail: detail)
            lock.withLock { counters.events += 1 }
        } catch {
            noteError(error)
        }
    }

    /// 采集遥测 → core 的 `capture_stats`（承接 M0 的 `frame_stats`）。
    func recordCaptureStat(ts: Date = Date(),
                           displayID: UInt32? = nil,
                           status: String,
                           trigger: String? = nil,
                           width: Int? = nil,
                           height: Int? = nil,
                           contentScale: Double? = nil,
                           dhash: String? = nil,
                           hamming: Int? = nil,
                           dirtyRects: Int? = nil,
                           dirtyAreaRatio: Double? = nil,
                           gated: Bool = false,
                           axChars: Int? = nil) {
        let handle: Store? = lock.withLock { store }
        guard let handle else {
            lock.withLock { counters.droppedCaptureStats += 1 }
            return
        }
        do {
            try handle.recordCaptureStat(ts: Recorder.milliseconds(ts),
                                         displayID: displayID.map(Int64.init),
                                         status: status,
                                         trigger: trigger,
                                         width: width,
                                         height: height,
                                         contentScale: contentScale,
                                         dhash: dhash,
                                         hamming: hamming,
                                         dirtyRects: dirtyRects,
                                         dirtyAreaRatio: dirtyAreaRatio,
                                         gated: gated,
                                         axChars: axChars)
            lock.withLock { counters.captureStats += 1 }
        } catch {
            noteError(error)
        }
    }

    private func noteError(_ error: Error) {
        lock.withLock {
            counters.errors += 1
            lastErrorText = "\(error)"
        }
    }

    /// 全项目统一的时间戳口径：Unix **毫秒**（UTC），与 `observations.ts` 一致。
    static func milliseconds(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// 数据目录（D16）。
///
/// M0 的明文库在 `~/Library/Application Support/brosis-m0/`，**本轮一个字节都不动、不迁移**：
/// 它是 E4 的原始观测数据，schema 与 v1 完全不同，迁移的收益抵不上污染 v1 库的风险。
/// M1 的加密库默认落在 `~/Library/Application Support/brosis/`。
enum DataLocation {

    /// UserDefaults 覆盖键。写绝对路径，例如
    /// `defaults write com.brosis.app data.directory -string /Volumes/Work/brosis-data`。
    /// D16 的同步盘拒绝由 `BrosisCore.DataDirectory.validate` 执行——写了 iCloud 路径会开库失败，
    /// 不会静默降级。
    static let directoryKey = "data.directory"

    /// 默认目录名。用 `brosis` 而不是 bundle id，是为了让用户在 Finder 里一眼认得出。
    static let defaultFolderName = "brosis"

    static func resolve(_ defaults: UserDefaults = .standard) -> (url: URL, source: String) {
        if let custom = defaults.string(forKey: directoryKey),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return (URL(fileURLWithPath: (custom as NSString).expandingTildeInPath,
                        isDirectory: true), "defaults")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return (base.appendingPathComponent(defaultFolderName, isDirectory: true), "default")
    }

    static var defaultURL: URL { resolve().url }

    /// M0 的明文库目录，只用来在 README / 菜单里说明"它还在，但不再写入"。
    static var legacyM0URL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("brosis-m0", isDirectory: true)
    }
}

/// 焦点窗口下某个 AX 角色的正文与统计。
///
/// **M1 与 M0 的关键差别**：M0 只留统计（角色 / 节点数 / 字符数 / 是否为空），
/// M1 起 `text` 里带上真正的正文，经 `Redactor` 脱敏后写进 `text_versions` / `occurrences`，
/// `occurrences.region` 记 AX 角色（计划 3.2 允许 region 是"AX 路径"，角色是它的最粗粒度）。
struct AXTextSummary: Sendable {
    var role: String
    var nodeCount: Int
    var charCount: Int
    var completeness: Completeness
    /// 该角色下按遍历顺序拼接的正文（未脱敏）。M0 时期这里是空串。
    var text: String = ""

    var isEmpty: Bool { charCount == 0 }
}
