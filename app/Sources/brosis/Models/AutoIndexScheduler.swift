import BrosisCore
import BrosisModels
import Foundation

/// 自动建索引（2026-09-08 用户要求）：**app 打开（库解锁）时跑一次，之后每小时再跑一次**，
/// 只要有可用的嵌入模型，就把待办的块自动嵌完。
///
/// **不重复实现任何嵌入逻辑**：踢的是「现在开始建索引」那条任务（`OvernightIndexJob`）。
/// 它的门控恰好是用户当天定的那套（`OvernightIndexPolicy`）：
///   * 锁库 / 暂停 / 没模型 / 待办为空 / 温度 serious 或 critical → **停**；
///   * 用电池、温度 fair → **暂停**（每 60 s 复查，期间把权重卸掉），来电或降温后自己接着跑；
///   * 跑到待办清空为止，不受夜间增量那条「空闲 5 分钟」与日均 GPU 预算的限制。
///
/// 与另外两条路的关系：
///   * `EmbeddingScheduler`（夜间增量，键 `embedding.enabled`）——四道门齐全，默认关，互不影响；
///   * 面板的「现在开始建索引」——同一个 `OvernightIndexJob`，手点与自动踢是同一条路，
///     所以正在跑时自动触发会被 `start` 返回 false 挡掉，不会叠加。
final class AutoIndexScheduler: @unchecked Sendable {

    static let shared = AutoIndexScheduler()

    /// 总开关。**默认开**（这就是用户要的行为）；不想要就设成 false。
    static let enabledKey = "embedding.autoIndex"
    /// 间隔（分钟）。默认 60。下限 5 分钟，免得填 0 变成死循环。
    static let intervalKey = "embedding.autoIndexIntervalMinutes"
    static let minimumIntervalMinutes = 5.0
    static let defaultIntervalMinutes = 60.0

    /// 解锁后延迟多久跑第一次。给启动阶段（授权、起流、首帧采集）让开一会儿。
    static let launchDelaySeconds: TimeInterval = 20

    /// 总开关。**setter 自己写键并自己起停**（与 `EmbeddingScheduler.isEnabled` 同一写法），
    /// 免得每个 UI 各写一遍"写 UserDefaults + if on { start() } else { stop() }"。
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue { shared.start() } else { shared.stop() }
        }
    }

    /// 间隔（分钟）。setter 会重建定时器——`start()` 是在建 timer 时快照 interval 的，
    /// 不重建的话改完要等下一次锁屏 / 解锁才生效。
    static var intervalMinutes: Double {
        get {
            let configured = UserDefaults.standard.double(forKey: intervalKey)
            guard configured > 0 else { return defaultIntervalMinutes }
            return max(minimumIntervalMinutes, configured)
        }
        set {
            UserDefaults.standard.set(max(minimumIntervalMinutes, newValue), forKey: intervalKey)
            guard isEnabled else { return }
            shared.stop()
            shared.start()
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.brosis.auto-index", qos: .utility)
    private var timer: DispatchSourceTimer?
    private weak var recorder: Recorder?
    private var _lastDecision = "还没跑过"

    var lastDecision: String { lock.lock(); defer { lock.unlock() }; return _lastDecision }

    func configure(recorder: Recorder) {
        lock.lock()
        self.recorder = recorder
        lock.unlock()
    }

    /// 库解锁时调（AppDelegate）。已经在跑就什么都不做。
    func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let interval = Self.intervalMinutes * 60
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.launchDelaySeconds, repeating: interval,
                   leeway: .seconds(300))   // 小时级任务，让系统合并唤醒
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        lock.unlock()
    }

    /// 锁库 / 关库时调。只停"踢"，正在跑的任务由它自己的门控（`locked_*`）收尾。
    func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    /// 一次判定。返回值只用于自检与状态行。
    ///
    /// **收 `EmbeddingGateInput` 整个，不再把字段拆成参数列表**：另外两道门
    /// （`EmbeddingGatePolicy` / `OvernightIndexPolicy`）本来就收它，唯一的调用点也早就
    /// 拿着一份。拆成参数的写法让「还有没有活」在这里被第三次拼出来，加一个新判据就要
    /// 手动穿一遍并补一个默认值——而默认值的含义恰好是"当作没活"，正是 2026-09-09 那个
    /// 死锁的形状。`autoEnabled` 与 `alreadyRunning` 不属于环境快照，留作具名参数。
    static func decide(_ input: EmbeddingGateInput,
                       autoEnabled: Bool, alreadyRunning: Bool) -> String? {
        if !autoEnabled { return "auto_disabled" }
        if !input.modelInstalled { return "model_not_installed" }
        if input.lockPhase != .unlocked { return "locked_" + input.lockPhase.rawValue }
        if input.paused { return "paused" }
        if alreadyRunning { return "already_running" }
        if !input.hasWork { return "nothing_pending" }
        return nil
    }

    private func tick() {
        let recorder = lock.withLock { self.recorder }
        guard let recorder else { return }
        let scheduler = EmbeddingScheduler.shared
        guard let root = scheduler.modelsRootURL() else {
            note("model_not_installed")
            return
        }
        let input = scheduler.currentInput(modelsRoot: root)
        // modelInstalled 就是 currentModelID(...) != nil，currentInput 已经算过一次；
        // 再算一次等于多读一遍 catalog.json 并 stat 一遍权重文件。
        let reason = Self.decide(input, autoEnabled: Self.isEnabled,
                                 alreadyRunning: OvernightIndexJob.shared.isRunning)
        if let reason {
            note(reason)
            return
        }
        note("started")
        _ = recorder.withStore {
            try $0.recordRuntimeEvent(
                kind: "auto_index_started",
                detail: "{\"pending_chunks\":\(input.pendingChunks),"
                      + "\"unchunked_text_versions\":\(input.unchunkedTextVersions),"
                      + "\"interval_minutes\":\(Int(Self.intervalMinutes))}")
        }
        // 跑到待办清空为止；接电与温度的门控在 OvernightIndexPolicy 里。
        OvernightIndexJob.shared.start(modelsRoot: root, recorder: recorder)
    }

    private func note(_ reason: String) {
        lock.lock()
        _lastDecision = reason
        lock.unlock()
    }
}
