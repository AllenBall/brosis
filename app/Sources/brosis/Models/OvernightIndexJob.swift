import AppKit
import BrosisCore
import BrosisModels
import Foundation

// =============================================================================
// 「现在开始建索引（连续跑到完成或取消）」——首次全量建索引的一次性动作
// （M2 d 批 / T15；计划 4.3、D8 的条件 3、c 批结果文件第 6 节）
//
// 为什么要有这个动作：c 批实测 1 个月合成库 46,545 块建整套索引 **1 小时 32 分**
// （7.29 块/s、全程 thermalState = fair）。按夜间任务的 10 分钟日预算折算 ≈ 4,374 块/天，
// 本轮语料要 10.6 天、满档语料要 71 天——增量索引解决不了"过去 30 天查不到"这个问题。
// D8 的第三个条件就是「首次全量建索引按用户显式确认后连续跑一晚，日均预算只管增量」。
//
// 与夜间任务（`EmbeddingGatePolicy`）的差别**只有三条**，逐条写明理由：
//
// | 门 | 夜间增量 | 整晚一次性 | 理由 |
// |---|---|---|---|
// | 空闲 ≥ 5 分钟 | 要 | **不要** | 这是用户按下按钮启动的：他知道机器要忙一夜。等空闲会让"睡前点一下"变成"永远等不到" |
// | 接电 | 要 | **要**（拔电则暂停，接回来继续） | 一夜的 GPU 活拿电池跑必然跑不完还会耗干；但拔电通常是临时的，所以是暂停不是终止 |
// | 日均 GPU 预算 | 要 | **不作为门**，单独记一本账 | 一夜就是几小时 GPU，塞进 10 分钟/天的预算里等于永远跑不完；单独记账才不会吞掉夜间增量的预算 |
// | 用户开关（夜间自动） | 要 | 不看 | 这个动作本身就是一次显式的用户动作 |
// | 热状态 | nominal 才跑 | fair **暂停**、serious / critical **停止** | 无风扇 Air 持续负载 2 分 10 秒就转 fair（D27）；要求 nominal 等于永远跑不动，所以 fair 降速待机、真烫了才收工 |
// | 锁定 / 暂停 | 停 | **停**（不放开） | 3.5：库关了就没得跑；锁屏进 paused 属于"用户离开"，但库开着——这里仍按停止处理，理由是这条路径与 MCP / 采集共用一把库锁，宁可保守 |
//
// **判定与执行分开**：`OvernightIndexPolicy.decide` 与 `OvernightProgress.make` 是纯函数，
// `--self-check` 整段跑；`OvernightIndexJob` 只负责采真实输入、起线程、记事件、报进度。
// 面板上的按钮只是调 `start()` / `cancel()`（本轮**不点面板**，屏幕锁着）。
// =============================================================================

// MARK: - 纯判定

/// 三态：跑 / 暂停等条件恢复 / 收工。
enum OvernightDecision: Equatable, Sendable {
    case run
    /// 等一会儿再看（拔电、机器偏热）。字符串是机器可读的原因。
    case pause(String)
    /// 结束这次动作（完成、取消、锁库、太烫、模型没了）。
    case stop(String)

    var reason: String? {
        switch self {
        case .run: nil
        case .pause(let r), .stop(let r): r
        }
    }
}

enum OvernightIndexPolicy {

    /// 暂停之后多久再问一次（秒）。热状态从 fair 回 nominal 实测要静置 5 分钟（D27），
    /// 但拔电 / 插电是秒级的事，所以取 60 s 这个折中：既不空转，也不至于插上电还要等 5 分钟。
    static let retryIntervalSeconds: TimeInterval = 60

    /// 每一小段最多跑多少秒。跑完这一段就回来重新问一次门控（拔电 / 转烫 / 锁屏都要当场反应）。
    static let sliceSeconds: Double = 60

    /// **顺序有意义**：先报"用户自己叫停 / 已经做完"，再报"环境不允许"。
    static func decide(_ input: EmbeddingGateInput, cancelled: Bool) -> OvernightDecision {
        if cancelled { return .stop("cancelled") }
        if !input.modelInstalled { return .stop("model_not_installed") }
        if input.pendingChunks == 0 { return .stop("complete") }
        if input.lockPhase != .unlocked { return .stop("locked_" + input.lockPhase.rawValue) }
        if input.paused { return .stop("paused") }
        // serious / critical：真烫了，收工（D27：critical 时锁定状态机自己也会关库）
        if input.thermalState == "serious" || input.thermalState == "critical" {
            return .stop("thermal_" + input.thermalState)
        }
        if !input.onACPower { return .pause("on_battery") }
        if input.thermalState != "nominal" { return .pause("thermal_" + input.thermalState) }
        return .run
    }
}

// MARK: - 进度（纯函数）

/// 进度：已嵌入 / 总块数、速率、预计剩余（4.3.2 T15）。
struct OvernightProgress: Sendable, Codable, Equatable {
    /// 这次动作已经嵌入的块数。
    var embedded: Int
    /// 还剩多少块。
    var remaining: Int
    /// 总块数 = 已嵌入 + 剩余（这次动作开始时的口径）。
    var total: Int
    /// 墙钟秒数。
    var elapsedSeconds: Double
    /// 只算 provider 调用的秒数（GPU 时间的上界，单独记账用这个）。
    var gpuSeconds: Double
    /// 块/s（按墙钟算；跑不到 1 s 时为 nil）。
    var chunksPerSecond: Double?
    /// 预计还要多少秒（速率为 0 时 nil）。
    var etaSeconds: Double?

    var percent: Double { total > 0 ? Double(embedded) / Double(total) * 100 : 0 }

    static func make(embedded: Int, remaining: Int, elapsedSeconds: Double,
                     gpuSeconds: Double) -> OvernightProgress {
        let total = embedded + remaining
        let rate = (elapsedSeconds >= 1 && embedded > 0) ? Double(embedded) / elapsedSeconds : nil
        let eta = (rate.map { $0 > 0 } ?? false) ? Double(remaining) / rate! : nil
        return OvernightProgress(embedded: embedded, remaining: remaining, total: total,
                                 elapsedSeconds: elapsedSeconds, gpuSeconds: gpuSeconds,
                                 chunksPerSecond: rate, etaSeconds: eta)
    }

    /// 一行人话，面板与事件都用它。
    var text: String {
        var out = "已嵌入 \(embedded) / \(total) 块（\(String(format: "%.1f", percent))%），剩 \(remaining) 块"
        if let rate = chunksPerSecond { out += String(format: "，%.2f 块/s", rate) }
        if let eta = etaSeconds { out += "，预计还要 " + Self.duration(eta) }
        return out
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 小时 \((s % 3600) / 60) 分"
    }
}

// MARK: - 单独的一本 GPU 账

/// 整晚建索引的 GPU 记账。**与夜间增量的预算分开**（4.3.2 T15：不吞掉夜间增量的预算）。
///
/// 只记不拦：这个动作没有预算上限，它的上限是"块跑完"或"用户取消"。
/// 存 UserDefaults，与 `GPUBudgetLedger` 用不同的键，跨日归零口径相同。
struct OvernightGPULedger: @unchecked Sendable {
    static let usedKey = "embedding.overnightGPUSecondsUsed"
    static let dayKey = "embedding.overnightGPUSecondsDay"

    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    func usedToday(now: Date = Date()) -> Double {
        guard defaults.string(forKey: Self.dayKey)
                == GPUBudgetLedger.dayStamp(now, calendar: calendar) else { return 0 }
        return defaults.double(forKey: Self.usedKey)
    }

    @discardableResult
    func add(seconds: Double, now: Date = Date()) -> Double {
        let today = GPUBudgetLedger.dayStamp(now, calendar: calendar)
        let base = defaults.string(forKey: Self.dayKey) == today
            ? defaults.double(forKey: Self.usedKey) : 0
        let total = base + max(0, seconds)
        defaults.set(today, forKey: Self.dayKey)
        defaults.set(total, forKey: Self.usedKey)
        return total
    }
}

// MARK: - 执行

/// 「现在开始建索引」的执行体。可取消、可重复启动（跑着的时候再点是空操作）。
final class OvernightIndexJob: @unchecked Sendable {

    static let shared = OvernightIndexJob()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.brosis.overnight-index", qos: .utility)
    private var running = false
    private var cancelled = false
    private var _progress: OvernightProgress?
    private var _lastSummary: String?
    private var _lastPauseReason: String?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var progress: OvernightProgress? { lock.lock(); defer { lock.unlock() }; return _progress }
    var lastSummary: String? { lock.lock(); defer { lock.unlock() }; return _lastSummary }
    var pauseReason: String? { lock.lock(); defer { lock.unlock() }; return _lastPauseReason }

    /// 面板上那一行。
    var statusText: String {
        if isRunning {
            let base = progress?.text ?? "正在准备…"
            if let reason = pauseReason {
                return "整晚建索引：已暂停（\(Self.reasonText(reason))）· " + base
            }
            return "整晚建索引：进行中 · " + base
        }
        return lastSummary.map { "整晚建索引：" + $0 } ?? "整晚建索引：未开始"
    }

    /// 停 / 暂停原因翻成人话。与 `OvernightIndexPolicy.decide` 的字符串一一对应。
    /// （不复用 `ModelsWindowController.gateText`：那个类是 `@MainActor`，这里在后台线程读。）
    static func reasonText(_ reason: String) -> String {
        switch reason {
        case "cancelled": "你按了取消"
        case "complete": "全部块都嵌完了"
        case "model_not_installed": "嵌入模型未安装"
        case "paused": "采集已暂停（锁屏 / 用户暂停）"
        case "on_battery": "在用电池，插上电源就继续"
        case "load_failed": "模型加载失败"
        case "store_unavailable": "库不可用（已关库）"
        default:
            if reason.hasPrefix("thermal_") { "机器偏热（\(reason.dropFirst(8))）" }
            else if reason.hasPrefix("locked_") { "数据库未解锁（\(reason.dropFirst(7))）" }
            else { reason }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// 启动。已经在跑就返回 false（面板按钮据此变成「取消」）。
    @discardableResult
    func start(modelsRoot: URL, scheduler: EmbeddingScheduler = .shared,
               recorder: Recorder?) -> Bool {
        lock.lock()
        guard !running else { lock.unlock(); return false }
        running = true
        cancelled = false
        _progress = nil
        _lastPauseReason = nil
        lock.unlock()
        queue.async { [weak self] in
            self?.run(modelsRoot: modelsRoot, scheduler: scheduler, recorder: recorder)
        }
        return true
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func run(modelsRoot: URL, scheduler: EmbeddingScheduler, recorder: Recorder?) {
        // D30：用面板当前选中的嵌入模型；没有可用的就直接不跑（3.11 降级表）。
        guard let modelID = scheduler.currentModelID(modelsRoot: modelsRoot) else {
            _ = recorder?.withStore {
                try $0.recordRuntimeEvent(kind: "overnight_index_failed",
                                          detail: "{\"error\":\"没有可用的嵌入模型\"}")
            }
            lock.lock()
            _lastSummary = "没跑：没有可用的嵌入模型（3.11：向量检索显示未启用）"
            _lastPauseReason = nil
            running = false
            lock.unlock()
            return
        }
        let startedAt = Date()
        let ledger = OvernightGPULedger()
        var embedded = 0
        var gpuSeconds = 0.0
        var remaining = scheduler.currentInput(modelsRoot: modelsRoot).pendingChunks
        var stopReason = "unknown"
        var provider: MLXEmbeddingProvider?

        _ = recorder?.withStore {
            try $0.recordRuntimeEvent(
                kind: "overnight_index_started",
                detail: "{\"pending_chunks\":\(remaining),\"model\":\"\(modelID)\","
                      + "\"thermal\":\"\(ModelProc.thermalState)\","
                      + "\"gates\":\"ac_power+thermal+unlocked（放开：空闲、日预算、夜间开关）\"}")
        }

        loop: while true {
            let input = scheduler.currentInput(modelsRoot: modelsRoot)
            // 待办块数由本轮实测值兜底：`currentInput` 每次都查库，慢一点但准。
            remaining = input.pendingChunks
            switch OvernightIndexPolicy.decide(input, cancelled: isCancelled) {
            case .stop(let reason):
                stopReason = reason
                break loop
            case .pause(let reason):
                lock.lock(); _lastPauseReason = reason; lock.unlock()
                _ = recorder?.withStore {
                    try $0.recordRuntimeEvent(kind: "overnight_index_paused",
                                              detail: "{\"reason\":\"\(reason)\","
                                                    + "\"remaining\":\(remaining)}")
                }
                // 暂停期间把权重还回去：等可能是几十分钟，没道理占着 1 GiB。
                if let p = provider { _ = p.unload(); provider = nil }
                Thread.sleep(forTimeInterval: OvernightIndexPolicy.retryIntervalSeconds)
                continue
            case .run:
                lock.lock(); _lastPauseReason = nil; lock.unlock()
            }

            if provider == nil {
                do {
                    provider = try MLXEmbeddingProvider.load(
                        directory: ModelStore.weightsDirectory(root: modelsRoot, id: modelID),
                        modelID: modelID)
                } catch {
                    stopReason = "load_failed"
                    _ = recorder?.withStore {
                        try $0.recordRuntimeEvent(kind: "overnight_index_failed",
                                                  detail: "{\"error\":\"\(error)\"}")
                    }
                    break loop
                }
            }
            guard let handle = provider else { stopReason = "load_failed"; break loop }

            // 一小段（默认 60 s）就回来重新问一次门控。段内每批也再问一次，
            // 这样拔电 / 转烫 / 锁屏最多多跑一批（16 块，约 2 s）。
            let job = self
            let gate: EmbeddingGate = {
                let now = scheduler.currentInput(modelsRoot: modelsRoot)
                return OvernightIndexPolicy.decide(now, cancelled: job.isCancelled).reason
            }
            var options = EmbeddingJobOptions(batchSize: Self.batchSize(),
                                              maxSeconds: OvernightIndexPolicy.sliceSeconds)
            options.planBatch = 2_000
            let report = recorder?.withStore { store in
                try store.runEmbeddingJob(provider: handle, options: options, gate: gate)
            } ?? nil
            guard let report else { stopReason = "store_unavailable"; break loop }

            embedded += report.chunksEmbedded
            gpuSeconds += report.providerSeconds
            remaining = report.chunksRemaining
            let progress = OvernightProgress.make(embedded: embedded, remaining: remaining,
                                                  elapsedSeconds: Date().timeIntervalSince(startedAt),
                                                  gpuSeconds: gpuSeconds)
            lock.lock(); _progress = progress; lock.unlock()
            _ = recorder?.withStore {
                try $0.recordRuntimeEvent(
                    kind: "overnight_index_progress",
                    detail: "{\"embedded\":\(progress.embedded),\"remaining\":\(progress.remaining),"
                          + "\"total\":\(progress.total),"
                          + "\"chunks_per_second\":"
                          + "\(progress.chunksPerSecond.map { String(format: "%.3f", $0) } ?? "null"),"
                          + "\"eta_seconds\":"
                          + "\(progress.etaSeconds.map { String(format: "%.0f", $0) } ?? "null"),"
                          + "\"gpu_seconds\":\(String(format: "%.1f", progress.gpuSeconds)),"
                          + "\"thermal\":\"\(ModelProc.thermalState)\"}")
            }
            if report.chunksRemaining == 0 { stopReason = "complete"; break loop }
            // 一段都没嵌进去（门控在第一批就叫停）：别空转，去 pause 分支等一等。
            if report.chunksEmbedded == 0 {
                Thread.sleep(forTimeInterval: 5)
            }
        }

        let release = provider?.unload()
        provider = nil
        let todayTotal = ledger.add(seconds: gpuSeconds)
        let elapsed = Date().timeIntervalSince(startedAt)
        let progress = OvernightProgress.make(embedded: embedded, remaining: remaining,
                                              elapsedSeconds: elapsed, gpuSeconds: gpuSeconds)
        let summary = "\(stopReason == "complete" ? "已完成" : "已停止（\(stopReason)）")："
                    + progress.text
                    + String(format: "，GPU %.0f s（今日整晚累计 %.0f s，与夜间增量的 %d s 预算分开记）",
                             gpuSeconds, todayTotal, Int(GPUBudgetLedger().budgetSeconds))
        lock.lock()
        _progress = progress
        _lastSummary = summary
        _lastPauseReason = nil
        running = false
        lock.unlock()
        _ = recorder?.withStore {
            try $0.recordRuntimeEvent(
                kind: "overnight_index_finished",
                detail: "{\"stop_reason\":\"\(stopReason)\",\"embedded\":\(embedded),"
                      + "\"remaining\":\(remaining),"
                      + "\"elapsed_seconds\":\(String(format: "%.1f", elapsed)),"
                      + "\"gpu_seconds\":\(String(format: "%.1f", gpuSeconds)),"
                      + "\"gpu_seconds_today_overnight\":\(String(format: "%.1f", todayTotal)),"
                      + "\"peak_footprint_mib\":"
                      + "\(String(format: "%.1f", release?.peakFootprintMiB ?? 0)),"
                      + "\"thermal\":\"\(ModelProc.thermalState)\"}")
        }
    }

    /// 批大小：与夜间任务同一个键、同一个默认值（D27 实测批 16 最快）。
    static func batchSize() -> Int {
        let configured = UserDefaults.standard.integer(forKey: EmbeddingGatePolicy.batchKey)
        return configured > 0 ? configured : 16
    }
}
