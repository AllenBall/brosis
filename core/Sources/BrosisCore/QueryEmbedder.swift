import Foundation

// =============================================================================
// 查询嵌入器（M2 d 批 / T15；计划 3.4「向量检索」、3.6 `search`、3.11 降级表）
//
// c 批（T11）把**索引**这一半做完了：`chunks` + `vec_chunks` + 混合检索，
// 查询向量由调用方算好塞进 `SearchRequest.queryVector`。
// 缺的是 MCP 这一半：`StoreMCPService.search` 拿到的只有一个查询串，
// 于是经 `brosis-mcp` 过来的查询一律 `vectorsUnavailable = no_query_vector`
// （c 批结果文件第 9 节第 1 条）。
//
// 这个文件补上那个钩子，而且**只补钩子**：
//   * core 仍然**不加载任何模型**（3.10 的分工没变，mlx 在 app 侧的 `BrosisModels` 里）；
//   * 注入的是一个协议实现，`nil` 时行为与 c 批**逐位相同**（`no_query_vector`）；
//   * 「什么时候加载 / 什么时候卸载」是一个**纯函数状态机**（`QueryEmbedderPolicy`），
//     真正持有权重的那个类在 app 侧，core 只定规矩，好让 `swift test` 能把规矩钉住。
// =============================================================================

/// 一条查询串 → 查询向量。**实现方负责模型的生命周期**（加载、空闲卸载、锁定时卸载）。
///
/// 返回 `nil` 不是错误，是「这次不算」：模型没装、用户没开开关、库锁着、正在卸载。
/// 调用方按「没有查询向量」处理，检索照常走精确字段 / 扫描 / FTS 三条通道
/// （3.11 降级表：未安装模型时向量检索显示未启用，其余功能不受影响）。
///
/// **不许持库锁调用它**：算一条查询向量在 Air 上是几十毫秒的 GPU 活，
/// 持锁调用会把采集线程一起卡住。`StoreMCPService.runSearch` 是在
/// `store.search`（那里面才 `withLock`）**之前**调的，`QueryEmbedderTests`
/// 里有一条用例专门钉这件事。
public protocol QueryEmbedder: AnyObject, Sendable {
    func queryVector(for text: String) throws -> [Float]?
}

/// 把任意 `EmbeddingProvider` 包成 `QueryEmbedder`：**一次一条**（批构造固定为 1）。
///
/// 批构造为什么必须固定：E9 已知限制——同一段文本换批大小，向量数值会有
/// 4×10⁻⁴ 量级的差异（`brosis-embed selftest` 里有一条断言钉着它）。
/// 索引侧按批 16 写库、查询侧按批 1 算，两边本来就不是逐位相同的；
/// 但**查询侧自己必须逐位可复现**，否则同一个问题两次问会有两种排序。
/// 所以这里写死 `embed([text])`，评估脚本要对照时也用 `brosis-embed queries --batch 1`。
public final class ProviderQueryEmbedder: QueryEmbedder, @unchecked Sendable {
    private let provider: EmbeddingProvider
    private let lock = NSLock()
    private var calls = 0

    public init(_ provider: EmbeddingProvider) { self.provider = provider }

    /// 调用次数。「开关关 / 模型没装 / 锁定时零模型调用」那几条断言就是数它。
    public var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    public func queryVector(for text: String) throws -> [Float]? {
        lock.lock(); calls += 1; lock.unlock()
        return try provider.embed([text]).first
    }
}

// =============================================================================
// MARK: - 常驻 + 空闲卸载的状态机（纯函数）
// =============================================================================

/// 状态机的五种输入。
///
/// 时间参数用秒（`Date().timeIntervalSince1970` 或单调时钟都行，只做差值）。
public enum QueryEmbedderEvent: Sendable, Equatable {
    /// 来了一次查询。
    case query(at: Double)
    /// 空闲检查（定时器每分钟一次）。
    case tick(at: Double)
    /// 屏幕锁定 / 用户暂停（3.5 的 `paused`：库还开着，但 MCP 已经在拒绝了）。
    case paused
    /// 关库（3.5 的 `locking` / `locked`）。
    case storeClosed
    /// 用户在「模型」面板里关掉了向量检索。
    case disabledByUser
}

public struct QueryEmbedderState: Sendable, Equatable {
    /// 权重现在在内存里吗。
    public var loaded: Bool
    /// 上一次查询的时刻（秒）。
    public var lastQueryAt: Double?

    public init(loaded: Bool = false, lastQueryAt: Double? = nil) {
        self.loaded = loaded
        self.lastQueryAt = lastQueryAt
    }
}

/// 状态机要执行的动作。
public enum QueryEmbedderAction: Sendable, Equatable {
    case none
    /// 先加载再算（首次用时加载）。
    case load
    /// 直接用已经在内存里的那份。
    case reuse
    /// 卸载并 `clearCache()`，字符串是**机器可读**的原因，进事件。
    case unload(String)
}

/// 「常驻 + 空闲卸载」的规矩（4.3.2 T15：常驻 + 空闲 10 min 卸载 + cacheLimit 256 MiB）。
///
/// 为什么是这条曲线而不是「每次查完就卸」或「一直常驻」：
///   * 每次查完就卸：c 批量到冷加载 0.35–1.0 s，每条 MCP 查询都付一次，
///     3.4 的「查询嵌入 ≤ 150 ms」直接不可能达标；
///   * 一直常驻：Air 只有 16 GiB，嵌入模型常驻约 0.6–1.2 GiB footprint，
///     而 MCP 查询是**阵发**的（Agent 问几句然后走），空着占内存不划算。
/// 折中就是「首次用时加载、10 分钟没人问就还回去」，
/// 再加三条**立刻**卸载的边（锁屏 / 关库 / 用户关开关），因为那三种情况下
/// MCP 本来就已经在拒绝服务了（3.5），留着权重纯属白占。
public enum QueryEmbedderPolicy {

    /// 空闲多久卸载（秒）。4.3.2 定的 10 分钟。
    public static let idleUnloadSeconds: Double = 600

    public static func next(_ state: QueryEmbedderState,
                            on event: QueryEmbedderEvent,
                            idleUnloadSeconds: Double = idleUnloadSeconds)
        -> (state: QueryEmbedderState, action: QueryEmbedderAction) {
        switch event {
        case .query(let now):
            var next = state
            next.lastQueryAt = now
            if state.loaded { return (next, .reuse) }
            next.loaded = true
            return (next, .load)

        case .tick(let now):
            guard state.loaded, let last = state.lastQueryAt else { return (state, .none) }
            guard now - last >= idleUnloadSeconds else { return (state, .none) }
            return (QueryEmbedderState(), .unload("idle_\(Int(idleUnloadSeconds))s"))

        case .paused:
            return state.loaded ? (QueryEmbedderState(), .unload("paused")) : (state, .none)

        case .storeClosed:
            return state.loaded ? (QueryEmbedderState(), .unload("store_closed")) : (state, .none)

        case .disabledByUser:
            return state.loaded ? (QueryEmbedderState(), .unload("disabled_by_user")) : (state, .none)
        }
    }
}

// =============================================================================
// MARK: - 一次查询嵌入的记账
// =============================================================================

/// `StoreMCPService.search` 把这一段随结果一起交给调用方（3.4 的分层目标要按它报）。
public struct QueryEmbedTiming: Sendable, Codable, Equatable {
    /// `embedder`（真算了）/ `disabled`（开关关）/ `no_embedder`（没注入）/
    /// `field_prefix`（`app:` 这类查询本来就不该走向量）/
    /// `unavailable`（注入了但这次返回 nil：模型没装 / 正在卸载）/ `error:<原因>`。
    public var source: String
    /// 算这一条查询向量花了多少毫秒（没算时为 nil）。**目标：热 ≤ 150 ms**（4.3.2 T15）。
    public var elapsedMS: Double?
    /// 向量维度（没算时为 nil）。
    public var dimension: Int?

    public init(source: String, elapsedMS: Double? = nil, dimension: Int? = nil) {
        self.source = source
        self.elapsedMS = elapsedMS
        self.dimension = dimension
    }

    /// 4.3.2 的分层目标：查询嵌入热延迟 ≤ 150 ms。
    public static let hotBudgetMS: Double = 150
}
