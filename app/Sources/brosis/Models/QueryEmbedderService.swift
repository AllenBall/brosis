import BrosisCore
import BrosisModels
import Foundation

// =============================================================================
// 产品路径上的查询嵌入器接线（M2 d 批 / T15；计划 3.4 / 3.5 / 3.6 / 3.11）
//
// c 批留下的洞：`StoreMCPService.search` 没有查询向量，所以经 `brosis-mcp` 过来的查询
// 一律 `no_query_vector`（c 批结果文件第 9 节第 1 条）。补法是「app 侧的 IPC 服务端
// 在收到 search 时算查询向量」——本文件就是那一段，`MCPIPCService` 里只加三处调用。
//
// **三道门都在这一层之外**：
//   * 库锁着 / 采集暂停 → `MCPGate` 根本不会把调用交给 `StoreMCPService`（3.5）；
//   * `retrieval.vectorsEnabled` 关着 → `StoreMCPService` 连嵌入器都不问（core 的四道门）；
//   * 模型没装 → 这里的 `enable` 照样调，但 `MLXQueryEmbedder.queryVector` 返回 nil。
// 所以「模型未装 / 开关关 / 锁定时零模型调用」是**结构性**保证，不是靠 if 堆出来的。
//
// **不改 AppDelegate**（并行约束）：接线点在 `IPCService.swift` 的 attach / detach / setPaused，
// 那三处本来就是「库交给 MCP / 摘掉 / 暂停」的唯一入口。
// =============================================================================

final class QueryEmbedderService: @unchecked Sendable {

    static let shared = QueryEmbedderService()

    /// 向量检索开关的 UserDefaults 键（「模型」面板写它）。
    static let vectorsEnabledKey = "retrieval.vectorsEnabled"

    let embedder = MLXQueryEmbedder()

    private let lock = NSLock()
    private weak var recorder: Recorder?
    private var attached = false
    private var lastNote: String?

    private init() {
        embedder.onEvent = { [weak self] kind, detail in
            self?.recorder?.logEvent(kind: kind, detail: detail)
        }
    }

    // MARK: - 生命周期（由 MCPIPCService 调）

    /// 进入 `unlocked`：把开关从 UserDefaults 恢复到 `store.retrieval`，再允许算查询向量。
    ///
    /// **开关的持久化在这里补上**（c 批只写了 UserDefaults，重启后 `store.retrieval` 回默认关，
    /// 面板显示与实际一致但用户上次的选择丢了）。恢复时仍然尊重 3.11 的
    /// 「未安装模型时强制关」：模型不在就不恢复，`search` 继续走 `disabled`。
    /// 装了模型且用户没显式关过时**默认开**（2026-09-08 用户要求）。
    func attach(recorder: Recorder, store: Store) {
        let root = ModelStore.resolveRoot(dataDirectory: store.directory).url
        // D30：装了哪个尺寸由面板的当前选择决定，这里只问"有没有一个能用的"。
        let modelID = EmbeddingSelection.effectiveID(catalog: try? Catalog.load(), root: root)
        let installed = modelID.map { ModelStore.isInstalled(root: root, id: $0) } ?? false
        // 2026-09-08 用户要求：**有可用模型时默认打开**。
        // 用户显式关过就尊重那次选择（键里有值），从没设过就当开；
        // 3.11「未安装模型时强制关」仍然守着，所以还要 && installed。
        let wanted = UserDefaults.standard.object(forKey: Self.vectorsEnabledKey) as? Bool ?? true
        store.retrieval.vectorsEnabled = wanted && installed

        lock.lock()
        self.recorder = recorder
        attached = true
        lastNote = "enabled=\(store.retrieval.vectorsEnabled) installed=\(installed)"
        lock.unlock()

        embedder.enable(modelsRoot: root)
        embedder.startIdleTimer()
        recorder.logEvent(
            kind: "query_embedder_attached",
            detail: "vectors_enabled=\(store.retrieval.vectorsEnabled) model_installed=\(installed) "
                  + "model=\(modelID ?? "(未选定)") "
                  + "idle_unload_s=\(Int(QueryEmbedderPolicy.idleUnloadSeconds)) "
                  + "cache_limit_mib=\(MLXMemoryPolicy.defaultCacheLimitMiB)")
    }

    /// 离开 `unlocked`（关库）：**立刻**卸载权重并清 GPU 缓冲池。
    func storeClosed() {
        embedder.stopIdleTimer()
        embedder.disable(event: .storeClosed)
        lock.lock()
        attached = false
        lock.unlock()
    }

    /// 锁屏 / 用户暂停：库还开着，但 MCP 已经在拒绝了，权重没有理由继续占内存。
    func setPaused(_ paused: Bool, store: Store?) {
        if paused {
            embedder.disable(event: .paused)
        } else if let store, attachedNow {
            embedder.enable(modelsRoot: ModelStore.resolveRoot(dataDirectory: store.directory).url)
        }
    }

    /// 用户在「模型」面板里关掉向量检索：立刻卸载（不等 10 分钟空闲）。
    func setVectorsEnabled(_ on: Bool, store: Store?) {
        if on {
            guard let store else { return }
            embedder.enable(modelsRoot: ModelStore.resolveRoot(dataDirectory: store.directory).url)
        } else {
            embedder.disable(event: .disabledByUser)
        }
    }

    private var attachedNow: Bool {
        lock.lock(); defer { lock.unlock() }
        return attached
    }

    // MARK: - 显示

    /// 菜单 / 面板里那一行。
    /// D30：当前生效的嵌入模型（自检与状态行打印用）。
    var currentModelDescription: String {
        let id = embedder.modelID
        return id.isEmpty ? "（未选定）" : id
    }

    /// 用户在面板里换了模型：把权重扔掉，按新选择重新挂上。
    /// 向量索引是否重建由面板负责问（向量不能跨模型比较）。
    func modelSelectionChanged(store: Store?) {
        embedder.disable(event: .disabledByUser)
        guard let store else { return }
        embedder.enable(modelsRoot: ModelStore.resolveRoot(dataDirectory: store.directory).url)
    }

    var statusDescription: String {
        let stats = embedder.currentStats
        guard stats.enabled else { return "查询嵌入器：未启用" }
        let loaded = stats.loaded ? "已加载" : "未加载（首次查询时载入）"
        var text = "查询嵌入器：\(loaded) · 已算 \(stats.queries) 条"
        if let p50 = stats.hotP50MS {
            text += String(format: " · 热 p50 %.0f ms", p50)
        }
        if let seconds = stats.lastLoadSeconds {
            text += String(format: " · 加载 %.2f s", seconds)
        }
        if stats.unloads > 0 { text += " · 卸载 \(stats.unloads) 次" }
        return text
    }
}
