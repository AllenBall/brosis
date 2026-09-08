import AppKit
import BrosisCore
import BrosisModels
import Foundation

// =============================================================================
// 夜间叙述任务的调度器（计划 4.3「夜间日 / 周叙述（接电、空闲、热状态门控）」、3.10、D19、D27）
//
// **门控与预算都复用 T11 的那一套**（`Models/EmbeddingScheduler.swift`）：
//   * 环境采集用 `EmbeddingEnvironment`（IOKit 电源 + `CGEventSource` 空闲，都不触发 TCC）；
//   * 每日 GPU 预算用同一个 `GPUBudgetLedger`、同一组 UserDefaults 键——
//     4.3 的验收写的是「日均 GPU < 10 分钟（**若启用嵌入与叙述**）」，
//     那是**两个任务合起来**的一个预算，不是各给 10 分钟，所以必须共用一本账。
//   * 判定条件与报告原因的**顺序**也照抄，这样两组门控用例能逐条对照。
//
// 与嵌入任务的差别只有三处：
//   1. 待办的定义不同（`Store.narrativeBacklog`：过完的日 / 周里还没写叙述的）；
//   2. 用的是生成模型（Qwen3.5-4B，2.85 GiB）而不是嵌入模型；
//   3. 一次 tick 最多跑 `maxTargetsPerRun` 个目标，每个之间重新过一遍门控。
// =============================================================================

// MARK: - 纯判定

/// 一次叙述门控判定要看的全部输入。全是值，方便自检直接构造。
struct NarrativeGateInput: Sendable, Equatable {
    var onACPower: Bool
    var idleSeconds: Double
    /// `nominal` / `fair` / `serious` / `critical`
    var thermalState: String
    var lockPhase: LockPhase
    var paused: Bool
    /// 生成模型装了没有。没装时功能显示「未启用」（3.11 的降级表）。
    var modelInstalled: Bool
    var enabledByUser: Bool
    var usedGPUSecondsToday: Double
    var budgetGPUSeconds: Double
    /// 还欠几天 / 几周的叙述。
    var pendingTargets: Int
}

enum NarrativeGatePolicy {
    /// 空闲门槛（秒）。与嵌入任务同一个口径（4.3「≥ 5 分钟无输入」）。
    static let idleThresholdSeconds = EmbeddingGatePolicy.idleThresholdSeconds
    /// UserDefaults 键。预算键**故意与嵌入任务共用**（同一本 GPU 账，见文件头）。
    static let enabledKey = "narrative.enabled"
    static let dailyEnabledKey = "narrative.daily"
    static let weeklyEnabledKey = "narrative.weekly"
    static let maxInputTokensKey = "narrative.maxInputTokens"

    /// 顺序与 `EmbeddingGatePolicy.decide` 逐条对齐：
    /// 先报"用户没开"、再报"模型没装"，最后才报环境条件——
    /// 界面上用户看到的第一条永远是他自己能改的那一条。
    static func decide(_ input: NarrativeGateInput) -> EmbeddingGateDecision {
        if !input.enabledByUser { return .skip("disabled_by_user") }
        if !input.modelInstalled { return .skip("model_not_installed") }
        if input.pendingTargets == 0 { return .skip("nothing_pending") }
        if input.lockPhase != .unlocked { return .skip("locked_" + input.lockPhase.rawValue) }
        if input.paused { return .skip("paused") }
        if !input.onACPower { return .skip("on_battery") }
        if input.idleSeconds < idleThresholdSeconds { return .skip("not_idle") }
        if input.thermalState != "nominal" { return .skip("thermal_" + input.thermalState) }
        if input.usedGPUSecondsToday >= input.budgetGPUSeconds {
            return .skip("gpu_budget_exhausted")
        }
        return .run
    }

    /// 门控原因翻译成界面上那一行中文。
    static func statusText(_ decision: EmbeddingGateDecision, pending: Int) -> String {
        guard let reason = decision.reason else { return "条件满足，待下一次检查（还欠 \(pending) 篇）" }
        switch reason {
        case "disabled_by_user": return "未启用（在「模型」面板里打开夜间叙述）"
        case "model_not_installed":
            return "未启用（没装生成模型 \(Catalog.generationModelID)）"
        case "nothing_pending": return "没有待写的叙述"
        case "paused": return "已暂停（锁屏或用户暂停）"
        case "on_battery": return "等待接电"
        case "not_idle": return "等待空闲 5 分钟"
        case "gpu_budget_exhausted": return "今日 GPU 预算已用完"
        default:
            if reason.hasPrefix("locked_") { return "库已锁定（\(reason.dropFirst(7))）" }
            if reason.hasPrefix("thermal_") { return "机器偏热（\(reason.dropFirst(8))），暂停" }
            return reason
        }
    }
}

// MARK: - 调度器

/// 夜间叙述任务的调度器。**默认不启动**：只有生成模型装了、用户在面板里打开开关，
/// `start()` 才会真的排定时器。
///
/// 接入方式（不改 `AppDelegate.swift`，见结果文件）：
/// ```swift
/// NarrativeScheduler.shared.configure(recorder: recorder, lockSnapshot: { lock.snapshot })
/// NarrativeScheduler.shared.start()
/// ```
final class NarrativeScheduler: @unchecked Sendable {

    static let shared = NarrativeScheduler()

    /// 多久检查一次门控。与嵌入任务同一个节奏。
    static let pollInterval: TimeInterval = EmbeddingScheduler.pollInterval
    /// 一次 tick 最多写几篇（每篇之间重新过门控）。
    /// D19 实测一次叙述 7 s，4 篇约半分钟，远小于 10 分钟的日预算。
    static let maxTargetsPerRun = 4

    private let lock = NSLock()
    private var recorder: Recorder?
    private var lockSnapshot: (@Sendable () -> LockSnapshot)?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.brosis.narrative", qos: .utility)
    private var running = false

    private(set) var lastDecision: EmbeddingGateDecision = .skip("not_started")
    private(set) var lastRunSummary: String?

    func configure(recorder: Recorder, lockSnapshot: @escaping @Sendable () -> LockSnapshot) {
        lock.lock(); defer { lock.unlock() }
        self.recorder = recorder
        self.lockSnapshot = lockSnapshot
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: NarrativeGatePolicy.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: NarrativeGatePolicy.enabledKey)
            if newValue { start() } else { stop() }
        }
    }

    /// 从 UserDefaults 读出来的可配置项（4.3「每天一次日叙述、每周一次周叙述（可配置）」）。
    static func configuration(defaults: UserDefaults = .standard) -> NarrativeConfig {
        var config = NarrativeConfig()
        // 没写过这两个键时 `object(forKey:)` 是 nil ⇒ 用默认值（都开）。
        if let daily = defaults.object(forKey: NarrativeGatePolicy.dailyEnabledKey) as? Bool {
            config.dailyEnabled = daily
        }
        if let weekly = defaults.object(forKey: NarrativeGatePolicy.weeklyEnabledKey) as? Bool {
            config.weeklyEnabled = weekly
        }
        let tokens = defaults.integer(forKey: NarrativeGatePolicy.maxInputTokensKey)
        // 上限只允许往**小**里调：8,000 是 D19 实测的 TTFT 上界（约 23.5 s），不能加大。
        if tokens > 0 { config.maxInputTokens = min(tokens, config.maxInputTokens) }
        return config
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 比嵌入任务晚 60 s 起跑：两个任务都要 GPU，错开一点免得同一分钟里抢。
        t.schedule(deadline: .now() + 90, repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    func modelsRootURL() -> URL? {
        guard let directory = recorder?.withStore({ $0.directory }) else { return nil }
        return ModelStore.resolveRoot(dataDirectory: directory).url
    }

    /// 采集一次真实环境。界面与自检都用它。
    func currentInput(modelsRoot: URL?, config: NarrativeConfig = configuration())
        -> NarrativeGateInput {
        let snapshot = lockSnapshot?() ?? LockSnapshot()
        let installed = modelsRoot.map {
            ModelStore.isInstalled(root: $0, id: Catalog.generationModelID)
        } ?? false
        let pending = recorder?.withStore { store -> Int in
            (try? store.narrativeBacklog(config: config).count) ?? 0
        } ?? 0
        let ledger = GPUBudgetLedger()
        return NarrativeGateInput(
            onACPower: EmbeddingEnvironment.onACPower(),
            idleSeconds: EmbeddingEnvironment.idleSeconds(),
            thermalState: ModelProc.thermalState,
            lockPhase: snapshot.phase,
            paused: snapshot.isPaused,
            modelInstalled: installed,
            enabledByUser: isEnabled,
            usedGPUSecondsToday: ledger.usedToday(),
            budgetGPUSeconds: ledger.budgetSeconds,
            pendingTargets: pending)
    }

    /// 界面上那一行状态。模型没装时显示「未启用」（3.11 的降级表）。
    func statusLine() -> String {
        let config = Self.configuration()
        let input = currentInput(modelsRoot: modelsRootURL(), config: config)
        let decision = NarrativeGatePolicy.decide(input)
        var text = NarrativeGatePolicy.statusText(decision, pending: input.pendingTargets)
        if let summary = lastRunSummary { text += "；上次：" + summary }
        return text
    }

    private func tick() {
        let config = Self.configuration()
        let root = modelsRootURL()
        let decision = NarrativeGatePolicy.decide(currentInput(modelsRoot: root, config: config))
        lastDecision = decision
        guard decision.canRun, let root else { return }
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }
        runOnce(modelsRoot: root, config: config, budget: GPUBudgetLedger())
    }

    /// 跑一轮（定时器与手动触发共用）。返回一行给界面显示的摘要。
    @discardableResult
    func runOnce(modelsRoot: URL, config: NarrativeConfig = configuration(),
                 budget: GPUBudgetLedger = GPUBudgetLedger(),
                 limit: Int = maxTargetsPerRun) -> String {
        guard let recorder else { return "存储服务没接上" }
        let directory = ModelStore.directory(root: modelsRoot, id: Catalog.generationModelID)
        guard budget.remaining() > 1 else {
            let text = "今日 GPU 预算已用完（\(Int(budget.budgetSeconds)) s）"
            lastRunSummary = text
            _ = recorder.withStore { try $0.recordRuntimeEvent(kind: "narrative_skipped",
                                                               detail: "gpu_budget_exhausted") }
            return text
        }
        let targets = recorder.withStore { store -> [NarrativeTarget] in
            (try? store.narrativeBacklog(config: config)) ?? []
        } ?? []
        guard !targets.isEmpty else {
            let text = "没有待写的叙述"
            lastRunSummary = text
            return text
        }

        let t0 = Date()
        do {
            // D27：加载前设 256 MiB 缓冲池，任务结束 clearCache()。
            let provider = try MLXGenerationProvider.load(directory: directory)
            var saved = 0
            var rejected = 0
            var done = 0
            for target in targets.prefix(limit) {
                // 每篇之前重新问一次环境：转 fair、拔电、用户回来动鼠标都要当场停。
                let now = NarrativeGatePolicy.decide(currentInput(modelsRoot: modelsRoot,
                                                                  config: config))
                guard now.canRun else { break }
                let report = recorder.withStore { store -> NarrativeRunReport? in
                    try store.runNarrative(target, provider: provider, config: config,
                                           thermalState: ModelProc.thermalState,
                                           peakFootprintMiB:
                                            Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib)
                } ?? nil
                done += 1
                if report?.saved == true { saved += 1 }
                else if report?.outcome == "rejected" { rejected += 1 }
            }
            let seconds = Date().timeIntervalSince(t0)
            let total = budget.add(seconds: seconds)
            // D27：任务结束把缓冲池还给系统。这是这条路径上**唯一**一次 unload
            // （`load` 之后到这里之间没有会抛的调用，`withStore` 自己吞 throw）。
            let release = provider.unload()
            let text = "写了 \(saved) 篇、丢弃 \(rejected) 篇（共尝试 \(done) 篇），"
                     + "GPU \(String(format: "%.1f", seconds)) s"
                     + "（今日累计 \(String(format: "%.1f", total)) s / \(Int(budget.budgetSeconds)) s）"
            lastRunSummary = text
            _ = recorder.withStore {
                try $0.recordRuntimeEvent(
                    kind: "narrative_batch",
                    detail: "{\"saved\":\(saved),\"rejected\":\(rejected),\"attempted\":\(done),"
                          + "\"pending\":\(targets.count),"
                          + "\"gpu_seconds\":\(String(format: "%.3f", seconds)),"
                          + "\"gpu_seconds_today\":\(String(format: "%.3f", total)),"
                          + "\"budget_seconds\":\(Int(budget.budgetSeconds)),"
                          + "\"load_seconds\":\(String(format: "%.3f", provider.loadSeconds)),"
                          + "\"peak_footprint_mib\":"
                          + "\(String(format: "%.1f", release.peakFootprintMiB)),"
                          + "\"thermal\":\"\(ModelProc.thermalState)\"}")
            }
            return text
        } catch {
            let text = "叙述任务失败：\(error)"
            lastRunSummary = text
            _ = recorder.withStore {
                try $0.recordRuntimeEvent(kind: "narrative_failed", detail: "\(error)")
            }
            return text
        }
    }
}
