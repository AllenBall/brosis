import BrosisCore
import Foundation

// =============================================================================
// MCP 查询嵌入器的本地实现（M2 d 批 / T15；计划 3.4 / 3.6 / 3.11 / D27）
//
// core 定协议与规矩（`BrosisCore/QueryEmbedder.swift`），这里是**唯一**真的加载权重的地方。
// 放在 `BrosisModels` 而不是 `brosis` 目标里，是因为两个进程要用同一份实现：
//   * 产品路径：`brosis.app` 的 `MCPIPCService` 在库解锁后注入它（`QueryEmbedderService`）；
//   * 验收路径：`brosis-embed serve-search` 起一个同样注入了它的 IPC 服务端，
//     让 `tools/eval/d8_mcp_compare.py` 能在没有 GUI 的机器上量「经 MCP 的数字」。
// 两条路走的是同一个类、同一套门控，所以验收量到的就是产品行为。
//
// 生命周期（4.3.2 T15「常驻 + 空闲卸载」）：
//   首次用时加载 → 空闲 10 分钟卸载并 `clearCache()` → 锁屏 / 关库 / 用户关开关立刻卸载。
//   判定全在 core 的 `QueryEmbedderPolicy`（纯函数，`swift test` 里钉着）；
//   这个类只负责"按判定去做"，外加记两个事件与一组统计。
//
// D27：加载**之前**设 `MLX.Memory.cacheLimit = 256 MiB`，卸载时 `clearCache()`。
// =============================================================================

public final class MLXQueryEmbedder: QueryEmbedder, @unchecked Sendable {

    /// 事件出口。`kind` 是机器可读的事件名，`detail` 是一行 JSON。
    /// app 侧接到 `Recorder.logEvent`（进 `jobs` 的运行时事件），命令行侧打到 stderr。
    public var onEvent: (@Sendable (_ kind: String, _ detail: String) -> Void)?

    /// 统计。界面、`--self-check` 与结果文件都读它。
    public struct Stats: Sendable, Codable {
        public var loaded = false
        public var enabled = false
        public var loads = 0
        public var unloads = 0
        public var queries = 0
        public var failures = 0
        /// 最近一次加载耗时（秒）。
        public var lastLoadSeconds: Double?
        /// 最近一次加载时的 peak footprint（MiB）。
        public var lastLoadPeakFootprintMiB: Double?
        /// 最近一次查询嵌入耗时（毫秒）。
        public var lastQueryMS: Double?
        /// **热**查询（不含触发加载的那一次）的耗时，用来对 3.4 的 ≤ 150 ms 目标。
        public var hotQueryMS: [Double] = []
        public var lastUnloadReason: String?

        /// 热查询的 p50 / p95（毫秒）。
        public var hotP50MS: Double? { Self.percentile(hotQueryMS, 0.50) }
        public var hotP95MS: Double? { Self.percentile(hotQueryMS, 0.95) }

        static func percentile(_ values: [Double], _ p: Double) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let index = Swift.min(sorted.count - 1, Int(Double(sorted.count) * p))
            return sorted[index]
        }
    }

    /// init 钉死的模型 id；nil = 跟随当前选择。
    public let pinnedModelID: String?
    /// 当前生效的模型 id。空串表示一个嵌入模型都没装（`queryVector` 一律返回 nil）。
    public private(set) var modelID: String
    public let cacheLimitMiB: Int
    public let idleUnloadSeconds: Double
    /// 每条查询串最多几个 token（超出截断）。查询串本来就短，1024 用不满。
    public let maxTokensPerText: Int

    private let lock = NSLock()
    private var state = QueryEmbedderState()
    private var provider: MLXEmbeddingProvider?
    private var modelsRoot: URL?
    private var stats = Stats()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.brosis.query-embedder", qos: .userInitiated)

    /// `modelID` 传 nil = **跟随面板里的当前选择**（D30 多尺寸可切换）；
    /// 传具体 id 就钉死（CLI 与验收脚本要可复现）。
    public init(modelID: String? = nil,
                cacheLimitMiB: Int = MLXMemoryPolicy.defaultCacheLimitMiB,
                idleUnloadSeconds: Double = QueryEmbedderPolicy.idleUnloadSeconds,
                maxTokensPerText: Int = 1024) {
        self.pinnedModelID = modelID
        self.modelID = modelID ?? ""
        self.cacheLimitMiB = cacheLimitMiB
        self.idleUnloadSeconds = idleUnloadSeconds
        self.maxTokensPerText = maxTokensPerText
    }

    // MARK: - 开关

    /// 允许算查询向量。`modelsRoot` 是模型根目录（D18：数据目录旁的 `models/`）。
    ///
    /// **只是允许，不加载**：真正的加载在第一次查询时（`QueryEmbedderPolicy` 的 `.load`）。
    /// 模型没装时这里照样可以调，`queryVector` 会返回 nil（3.11 降级表）。
    public func enable(modelsRoot: URL) {
        lock.lock()
        self.modelsRoot = modelsRoot
        // D30：每次 enable 都重新解析当前选择——用户在面板里换了模型之后，
        // 服务层会 disable + enable 走一遍，这里就把新模型接上。
        let resolved = pinnedModelID
            ?? EmbeddingSelection.effectiveID(catalog: try? Catalog.load(), root: modelsRoot)
            ?? ""
        if resolved != modelID {
            // 换模型 = 旧权重立刻扔掉。向量不能跨模型比较，索引由面板提示重建。
            provider = nil
            modelID = resolved
        }
        stats.enabled = true
        lock.unlock()
    }

    /// 停止服务并**立刻**卸载（锁屏 / 关库 / 用户关掉向量检索开关）。
    public func disable(event: QueryEmbedderEvent) {
        lock.lock()
        stats.enabled = false
        let step = QueryEmbedderPolicy.next(state, on: event, idleUnloadSeconds: idleUnloadSeconds)
        state = step.state
        let release = applyUnloadLocked(step.action)
        lock.unlock()
        emitUnload(release)
    }

    /// 空闲检查。定时器每分钟调一次，也可以由测试直接给时刻。
    public func tick(now: Date = Date()) {
        lock.lock()
        let step = QueryEmbedderPolicy.next(state, on: .tick(at: now.timeIntervalSince1970),
                                            idleUnloadSeconds: idleUnloadSeconds)
        state = step.state
        let release = applyUnloadLocked(step.action)
        lock.unlock()
        emitUnload(release)
    }

    /// 起空闲定时器。默认 60 s 检查一次（空闲门槛是 600 s，60 s 的粒度足够）。
    public func startIdleTimer(interval: TimeInterval = 60) {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    public func stopIdleTimer() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    public var currentStats: Stats {
        lock.lock(); defer { lock.unlock() }
        var out = stats
        out.loaded = provider != nil
        return out
    }

    /// 模型装了没（`queryVector` 返回 nil 的头号原因）。
    public var modelInstalled: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let root = modelsRoot, !modelID.isEmpty else { return false }
        return ModelStore.isInstalled(root: root, id: modelID)
    }

    // MARK: - QueryEmbedder

    /// 算一条查询向量。**批构造固定为 1**（理由见 core 的 `ProviderQueryEmbedder` 注释：
    /// E9 已知限制，换批大小会改动 1e-3 量级；查询侧必须自己逐位可复现）。
    ///
    /// 返回 nil 的三种情况，都不是错误，调用方按「没有查询向量」降级：
    ///   * 没 `enable`（库锁着 / 用户没开开关）；
    ///   * 模型目录不在（3.11「未安装时显示未启用」）；
    ///   * 加载失败（会记一次 `embedder_failed` 事件并把失败计数 +1）。
    public func queryVector(for text: String) throws -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }
        guard stats.enabled, let root = modelsRoot else { return nil }
        guard !modelID.isEmpty else { return nil }
        let directory = ModelStore.weightsDirectory(root: root, id: modelID)
        guard ModelStore.isInstalled(root: root, id: modelID) else { return nil }

        let step = QueryEmbedderPolicy.next(state, on: .query(at: Date().timeIntervalSince1970),
                                            idleUnloadSeconds: idleUnloadSeconds)
        state = step.state
        var loadedNow = false
        if step.action == .load || provider == nil {
            do {
                let t0 = Date()
                let loaded = try MLXEmbeddingProvider.load(
                    directory: directory, modelID: modelID,
                    cacheLimitMiB: cacheLimitMiB, maxTokensPerText: maxTokensPerText)
                provider = loaded
                loadedNow = true
                let seconds = Date().timeIntervalSince(t0)
                let peak = Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib
                stats.loads += 1
                stats.lastLoadSeconds = seconds
                stats.lastLoadPeakFootprintMiB = peak
                // 「首次加载单独记事件」（4.3.2 T15）
                onEvent?("embedder_loaded",
                         "{\"model\":\"\(modelID)\","
                         + "\"load_seconds\":\(String(format: "%.3f", seconds)),"
                         + "\"provider_load_seconds\":\(String(format: "%.3f", loaded.loadSeconds)),"
                         + "\"peak_footprint_mib\":\(String(format: "%.1f", peak)),"
                         + "\"footprint_mib\":"
                         + "\(String(format: "%.1f", Double(ModelProc.footprintBytes()) / ModelBytes.mib)),"
                         + "\"cache_limit_mib\":\(cacheLimitMiB),"
                         + "\"idle_unload_seconds\":\(Int(idleUnloadSeconds)),"
                         + "\"thermal\":\"\(ModelProc.thermalState)\"}")
            } catch {
                state = QueryEmbedderState()
                stats.failures += 1
                onEvent?("embedder_failed", "{\"stage\":\"load\",\"error\":\"\(error)\"}")
                return nil
            }
        }
        guard let provider else { return nil }
        do {
            let t0 = Date()
            let vector = try provider.embed([trimmed]).first
            let ms = Date().timeIntervalSince(t0) * 1000
            stats.queries += 1
            stats.lastQueryMS = ms
            // 触发加载的那一次不算"热"：3.4 的 ≤ 150 ms 目标说的是热延迟。
            if !loadedNow {
                stats.hotQueryMS.append(ms)
                if stats.hotQueryMS.count > 512 { stats.hotQueryMS.removeFirst() }
            }
            return vector
        } catch {
            stats.failures += 1
            onEvent?("embedder_failed", "{\"stage\":\"embed\",\"error\":\"\(error)\"}")
            return nil
        }
    }

    // MARK: - 私有

    /// **必须在持锁时调**。返回非 nil 表示真的卸载了（事件在放锁之后发）。
    private func applyUnloadLocked(_ action: QueryEmbedderAction)
        -> (reason: String, release: MLXMemoryPolicy.Release)? {
        guard case .unload(let reason) = action else { return nil }
        guard provider != nil else { return nil }
        let release = provider?.unload() ?? MLXMemoryPolicy.releaseCache()
        provider = nil
        stats.unloads += 1
        stats.lastUnloadReason = reason
        return (reason, release)
    }

    private func emitUnload(_ unloaded: (reason: String, release: MLXMemoryPolicy.Release)?) {
        guard let unloaded else { return }
        let r = unloaded.release
        onEvent?("embedder_unloaded",
                 "{\"reason\":\"\(unloaded.reason)\","
                 + "\"gpu_cache_before_mib\":\(String(format: "%.1f", r.gpuCacheBeforeMiB)),"
                 + "\"gpu_cache_after_mib\":\(String(format: "%.1f", r.gpuCacheAfterMiB)),"
                 + "\"footprint_before_mib\":\(String(format: "%.1f", r.footprintBeforeMiB)),"
                 + "\"footprint_after_mib\":\(String(format: "%.1f", r.footprintAfterMiB)),"
                 + "\"peak_footprint_mib\":\(String(format: "%.1f", r.peakFootprintMiB))}")
    }
}
