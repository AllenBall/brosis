import AppKit
import BrosisCore
import BrosisModels
import Foundation
import IOKit.ps

// =============================================================================
// 夜间嵌入任务调度器（计划 3.1「不在电池或高热状态下跑重活」、3.11 / D27、4.3）
//
// 门控条件（全部满足才跑）：
//   1. **接电**（`IOPSCopyPowerSourcesInfo` 报 AC Power）；
//   2. **空闲 ≥ 5 分钟**（`CGEventSource.secondsSinceLastEventType`，不需要任何权限）；
//   3. **thermalState == nominal**（D27：Air 持续负载 2 分 10 秒转 fair，吞吐掉 33.6%）；
//   4. **库开着且没锁**（锁屏进 `paused`，这时候库还开着但不跑重活）；
//   5. **今天的 GPU 预算没用完**（默认 10 分钟，4.3 验收「日均 GPU < 10 分钟」）；
//   6. 模型装了、开关开了。
// 跑起来之后每批再问一次同样的条件，`fair` 就**暂停**（干净停下，已写的块保留）。
//
// 这个文件里**判定与执行分开**：`EmbeddingGateInput` / `EmbeddingGateDecision` 是纯函数，
// `--self-check` 整段跑；`EmbeddingScheduler` 只负责采集真实输入、起线程、记事件。
// =============================================================================

// MARK: - 纯判定

/// 一次门控判定要看的全部输入。全是值，方便自检直接构造。
struct EmbeddingGateInput: Sendable, Equatable {
    var onACPower: Bool
    var idleSeconds: Double
    /// `nominal` / `fair` / `serious` / `critical`
    var thermalState: String
    /// 锁定状态机的相位（`unlocked` 才算库能用）。
    var lockPhase: LockPhase
    /// 是否处于 `paused`（锁屏 / 用户暂停）。
    var paused: Bool
    var modelInstalled: Bool
    var enabledByUser: Bool
    /// 今天已经用掉的 GPU 秒数。
    var usedGPUSecondsToday: Double
    /// 今天的 GPU 预算（秒）。
    var budgetGPUSeconds: Double
    /// 还有没有待办的块。
    var pendingChunks: Int
    /// 还没分块的文本版本数。**它和 `pendingChunks` 一样是"还有活要干"**。
    ///
    /// 分块（`text_versions → chunks`）发生在 `Store.runEmbeddingJob` 里面
    /// （`options.planBatch`），也就是说**只有任务真的跑起来才会分块**。而三道门以前
    /// 只看 `pendingChunks == 0` 就判"没活了"，于是空库里形成死锁：
    /// 没有块 ⇒ 门说没活 ⇒ 任务不跑 ⇒ 没人分块 ⇒ 永远没有块。
    /// 2026-09-09 库被删重建之后就卡在这里：2195 个文本版本一个都没分块，
    /// 面板却显示"索引已经是最新的"。默认 0 是为了让既有调用点不用改。
    var unchunkedTextVersions: Int = 0

    /// 还有没有活要干（分块的活也算）。
    var hasWork: Bool { pendingChunks > 0 || unchunkedTextVersions > 0 }
}

/// 判定结果。`.run` 才跑；其余都带一个**机器可读**的原因，事件与自检都按它对。
enum EmbeddingGateDecision: Equatable, Sendable {
    case run
    case skip(String)

    var reason: String? {
        if case .skip(let r) = self { return r }
        return nil
    }
    var canRun: Bool { self == .run }
}

enum EmbeddingGatePolicy {
    /// 空闲门槛（秒）。4.3 要求"≥ 5 分钟无输入"。
    static let idleThresholdSeconds: Double = 300
    /// 日均 GPU 预算默认值（秒）。4.3 验收「日均 GPU < 10 分钟」。
    static let defaultBudgetSeconds: Double = 600
    /// UserDefaults 键。
    static let enabledKey = "embedding.enabled"
    static let budgetKey = "embedding.dailyGPUSeconds"
    static let batchKey = "embedding.batchSize"

    /// **顺序有意义**：先报"用户根本没开"，再报"模型没装"，最后才报环境条件。
    /// 界面上按这个顺序显示，用户看到的第一条永远是他自己能改的那一条。
    static func decide(_ input: EmbeddingGateInput) -> EmbeddingGateDecision {
        if !input.enabledByUser { return .skip("disabled_by_user") }
        if !input.modelInstalled { return .skip("model_not_installed") }
        if !input.hasWork { return .skip("nothing_pending") }
        if input.lockPhase != .unlocked { return .skip("locked_" + input.lockPhase.rawValue) }
        if input.paused { return .skip("paused") }
        if !input.onACPower { return .skip("on_battery") }
        if input.idleSeconds < idleThresholdSeconds { return .skip("not_idle") }
        if input.thermalState != "nominal" { return .skip("thermal_" + input.thermalState) }
        if input.usedGPUSecondsToday >= input.budgetGPUSeconds { return .skip("gpu_budget_exhausted") }
        return .run
    }
}

// MARK: - 每日 GPU 预算台账

/// 日均 GPU 预算的记账（3.11 / 4.3「日均 GPU 时间预算可配置（默认 10 分钟）并记进事件」）。
///
/// 存 UserDefaults，不进库：它是本机运行策略，不是证据，也不参与 D17 同步。
/// 每天 00:00（本机时区）翻页。
// `UserDefaults` 本身是线程安全的（Apple 文档明说），但它不是 `Sendable`，
// 所以这里显式标 `@unchecked`：这个结构体只读写 UserDefaults，没有别的可变状态。
struct GPUBudgetLedger: @unchecked Sendable {
    static let usedKey = "embedding.gpuSecondsUsed"
    static let dayKey = "embedding.gpuSecondsDay"

    var budgetSeconds: Double
    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard,
         budgetSeconds: Double = EmbeddingGatePolicy.defaultBudgetSeconds,
         calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
        let configured = defaults.double(forKey: EmbeddingGatePolicy.budgetKey)
        self.budgetSeconds = configured > 0 ? configured : budgetSeconds
    }

    static func dayStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 今天已经用掉多少秒（跨日自动归零）。
    func usedToday(now: Date = Date()) -> Double {
        let today = Self.dayStamp(now, calendar: calendar)
        guard defaults.string(forKey: Self.dayKey) == today else { return 0 }
        return defaults.double(forKey: Self.usedKey)
    }

    /// 记一次消耗，返回记完之后今天的累计。
    @discardableResult
    func add(seconds: Double, now: Date = Date()) -> Double {
        let today = Self.dayStamp(now, calendar: calendar)
        let base = defaults.string(forKey: Self.dayKey) == today
            ? defaults.double(forKey: Self.usedKey) : 0
        let total = base + max(0, seconds)
        defaults.set(today, forKey: Self.dayKey)
        defaults.set(total, forKey: Self.usedKey)
        return total
    }

    func remaining(now: Date = Date()) -> Double { max(0, budgetSeconds - usedToday(now: now)) }
}

// MARK: - 环境采集

enum EmbeddingEnvironment {

    /// 是否接电。用 IOKit 的电源信息，不需要任何权限、不触发 TCC。
    static func onACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        // 没有电池的机器（Mac mini / Studio）报 kIOPMUPSPowerKey 或 AC，一律当作接电。
        return type != kIOPSBatteryPowerValue
    }

    /// 距离上一次用户输入过了多少秒。
    ///
    /// `CGEventSource.secondsSinceLastEventType` 不需要辅助功能权限，也不读事件内容，
    /// 只问"多久没动了"。
    ///
    /// `kCGAnyInputEventType`（原始值 `~0`）在 Swift 里**没有对应的 enum case**，
    /// 只能用原始值构造；这个构造在别的 SDK 版本上可能返回 nil，所以**不强解包**——
    /// 拿不到就退回"几种主要输入事件里空闲时间最短的那个"，语义等价、不会崩。
    static func idleSeconds() -> Double {
        if let anyInput = CGEventType(rawValue: ~0) {
            return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
        }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown,
                                    .scrollWheel, .otherMouseDown, .flagsChanged]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? 0
    }
}

// MARK: - 调度器

/// 夜间嵌入任务的调度器。**默认不启动**：只有模型装了、用户在「模型」面板里打开开关，
/// `start()` 才会真的排定时器。
///
/// 接入方式（不改 AppDelegate，见结果文件）：
/// ```swift
/// EmbeddingScheduler.shared.configure(recorder: recorder, lock: lockController)
/// EmbeddingScheduler.shared.start()
/// ```
final class EmbeddingScheduler: @unchecked Sendable {

    static let shared = EmbeddingScheduler()

    /// 多久检查一次门控。默认 5 分钟：与空闲门槛同量级，够灵敏又不费电。
    static let pollInterval: TimeInterval = 300

    private let lock = NSLock()
    private var recorder: Recorder?
    private var lockSnapshot: (@Sendable () -> LockSnapshot)?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.brosis.embedding", qos: .utility)
    private var running = false

    /// 最近一次判定，界面上要显示。
    private(set) var lastDecision: EmbeddingGateDecision = .skip("not_started")
    private(set) var lastRunSummary: String?

    func configure(recorder: Recorder, lockSnapshot: @escaping @Sendable () -> LockSnapshot) {
        lock.lock(); defer { lock.unlock() }
        self.recorder = recorder
        self.lockSnapshot = lockSnapshot
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: EmbeddingGatePolicy.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: EmbeddingGatePolicy.enabledKey)
            if newValue { start() } else { stop() }
        }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// 当前生效的嵌入模型 id（D30：清单里有多个尺寸，面板里可切换）。
    /// 返回 nil = 没有可用的模型（没装，或关联的外部目录失效），向量检索按 3.11 显示未启用。
    func currentModelID(modelsRoot: URL?) -> String? {
        guard let modelsRoot else { return nil }
        guard let id = EmbeddingSelection.effectiveID(catalog: try? Catalog.load(), root: modelsRoot),
              ModelStore.isInstalled(root: modelsRoot, id: id),
              ModelStore.linkedProblem(root: modelsRoot, id: id,
                                       minimumDimension: SchemaV4.dimension) == nil
        else { return nil }
        return id
    }

    /// 采集一次真实环境。界面与自检都用它。
    func currentInput(modelsRoot: URL?) -> EmbeddingGateInput {
        let snapshot = lockSnapshot?() ?? LockSnapshot()
        let installed = currentModelID(modelsRoot: modelsRoot) != nil
        // 一次 vectorStatus() 同时拿"待办块"和"没分块的文本版本"——两个数来自同一张快照，
        // 分开查会在跑着任务时读到互相矛盾的一对。
        let work = recorder?.withStore { store -> (pending: Int, unchunked: Int) in
            guard let status = try? store.vectorStatus() else { return (0, 0) }
            return (status.pendingChunks, status.unchunkedTextVersions)
        } ?? (pending: 0, unchunked: 0)
        let ledger = GPUBudgetLedger()
        return EmbeddingGateInput(
            onACPower: EmbeddingEnvironment.onACPower(),
            idleSeconds: EmbeddingEnvironment.idleSeconds(),
            thermalState: ModelProc.thermalState,
            lockPhase: snapshot.phase,
            paused: snapshot.isPaused,
            modelInstalled: installed,
            enabledByUser: isEnabled,
            usedGPUSecondsToday: ledger.usedToday(),
            budgetGPUSeconds: ledger.budgetSeconds,
            pendingChunks: work.pending,
            unchunkedTextVersions: work.unchunked)
    }

    private func tick() {
        let root = modelsRootURL()
        let input = currentInput(modelsRoot: root)
        let decision = EmbeddingGatePolicy.decide(input)
        lastDecision = decision
        guard decision.canRun, let root else { return }
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }
        runOnce(modelsRoot: root, budget: GPUBudgetLedger())
    }

    func modelsRootURL() -> URL? {
        guard let directory = recorder?.withStore({ $0.directory }) else { return nil }
        return ModelStore.resolveRoot(dataDirectory: directory).url
    }

    /// 跑一次（手动触发与定时器共用）。返回一行给界面显示的摘要。
    @discardableResult
    func runOnce(modelsRoot: URL, budget: GPUBudgetLedger) -> String {
        guard let modelID = currentModelID(modelsRoot: modelsRoot) else {
            let text = "没有可用的嵌入模型（3.11：向量检索显示未启用）"
            lastRunSummary = text
            return text
        }
        // D30：关联进来的模型权重在外部目录，一律走 weightsDirectory。
        let directory = ModelStore.weightsDirectory(root: modelsRoot, id: modelID)
        let remaining = budget.remaining()
        guard remaining > 1 else {
            let text = "今日 GPU 预算已用完（\(Int(budget.budgetSeconds)) s）"
            lastRunSummary = text
            _ = recorder?.withStore { try $0.recordRuntimeEvent(kind: "embedding_skipped",
                                                               detail: "gpu_budget_exhausted") }
            return text
        }
        do {
            let provider = try MLXEmbeddingProvider.load(
                directory: directory, modelID: modelID)
            let configuredBatch = UserDefaults.standard.integer(forKey: EmbeddingGatePolicy.batchKey)
            // 批 16 是 D27 在 Air 上实测过的档（峰值 footprint 1.61 GiB、零 swap）。
            var options = EmbeddingJobOptions(batchSize: configuredBatch > 0 ? configuredBatch : 16,
                                              maxSeconds: remaining)
            options.planBatch = 2_000
            // 每批之前重新问一次环境：转 fair、拔电、用户回来动鼠标都要当场停。
            let scheduler = self
            let gate: EmbeddingGate = {
                let now = scheduler.currentInput(modelsRoot: modelsRoot)
                let decision = EmbeddingGatePolicy.decide(now)
                return decision.reason
            }
            // `Recorder.withStore` 自己吞掉 throw 并返回 nil（库没开 / 出错），所以这里不用 try。
            let report = recorder?.withStore { store in
                try store.runEmbeddingJob(provider: provider, options: options, gate: gate)
            } ?? nil
            let release = provider.unload()
            let seconds = report?.providerSeconds ?? 0
            let embedded = report?.chunksEmbedded ?? 0
            let remainingChunks = report?.chunksRemaining ?? 0
            let stopReason = report?.stopReason ?? "unknown"
            let total = budget.add(seconds: seconds)
            let gpuText = String(format: "%.1f", seconds)
            let todayText = String(format: "%.1f", total)
            let text = "嵌入 \(embedded) 块，剩 \(remainingChunks) 块，GPU \(gpuText) s"
                     + "（今日累计 \(todayText) s / \(Int(budget.budgetSeconds)) s），停因 \(stopReason)"
            lastRunSummary = text
            let detail = "{\"chunks\":\(embedded),\"remaining\":\(remainingChunks),"
                       + "\"gpu_seconds\":\(String(format: "%.3f", seconds)),"
                       + "\"gpu_seconds_today\":\(String(format: "%.3f", total)),"
                       + "\"budget_seconds\":\(Int(budget.budgetSeconds)),"
                       + "\"stop_reason\":\"\(stopReason)\","
                       + "\"peak_footprint_mib\":\(String(format: "%.1f", release.peakFootprintMiB)),"
                       + "\"thermal\":\"\(ModelProc.thermalState)\"}"
            _ = recorder?.withStore { try $0.recordRuntimeEvent(kind: "embedding_run", detail: detail) }
            return text
        } catch {
            let text = "嵌入任务失败：\(error)"
            lastRunSummary = text
            _ = recorder?.withStore {
                try $0.recordRuntimeEvent(kind: "embedding_failed", detail: "\(error)")
            }
            return text
        }
    }
}
