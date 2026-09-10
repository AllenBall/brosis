import Foundation

// =============================================================================
// 周台账、活动模式、最近活动（计划 3.6「recent_activity、get_patterns、周台账放 M2」、3.7 台账口径）
//
// 三样东西共同的口径：**全部是确定性的**。同样的观察算出同样的数，不经过任何模型，
// 每个数字都能顺着 `evidence` 里的观察 id 走回原始证据。`narrative` 恒为 nil——
// 3.7 要求台账与叙述分开标注，叙述是另一条（可选的）夜间任务。
// =============================================================================

// MARK: - 周台账（3.7）

/// 周台账里「按天分布」的一行。7 天各一行，**没有观察的那天也在**（`hasData = false`），
/// 否则"这一周有两天没开机"这件事就从结果里消失了。
public struct WeekDayTotal: Sendable, Codable {
    /// `YYYY-MM-DD`。
    public var date: String
    /// 1 = 周一 … 7 = 周日（ISO 8601 的编号，与 `DayCalendar` 的 `firstWeekday = 2` 一致）。
    public var weekday: Int
    public var dwellS: Double
    public var activeS: Double
    public var unknownS: Double
    /// 这一天会话区间并集的「总在线」。天与天不重叠，所以整周的并集 = 7 天之和。
    public var onlineUnionS: Double
    public var switches: Int
    public var interruptions: Int
    public var sessions: Int
    public var observations: Int
    public var hasData: Bool
    /// 这一天的日台账是什么时候算出来的（`ledgers.computed_at`）。
    /// 周台账的增量判定就是拿它跟缓存里存的这一份比（见 `Store.getWeekLedger`）。
    public var dayComputedAt: Int64
}

/// `get_week_ledger` 的产物：**7 个日台账的聚合**，不是在一条连续的周观察流上重算。
///
/// 为什么按天聚合而不是直接算一周：日台账已经是 `ledgers` 表里的预聚合结果，
/// 按天聚合让「周 = 7 天之和」这条不变量可验证（`WeekLedgerTests` 逐字段断言），
/// 也让增量成立——只有变过的那几天要重算。
///
/// **代价要写明**：`switches`（切换次数）是 7 天各自「切入次数」的和。
/// 一个应用如果跨过午夜连续使用，两天各记一次切入，整周就比"在连续周流上重算"多一次。
/// 这是定义差异不是误差；3.7 的台账口径按自然日切分，跨日的段本来就属于两天。
public struct WeekLedger: Sendable, Codable {
    /// ISO 周标识 `YYYY-Www`（周一开始）。
    public var week: String
    public var timeZone: String
    /// 周一 00:00（含）。
    public var start: Int64
    /// 下周一 00:00（不含）。
    public var end: Int64
    /// 组成这一周的 7 个 `YYYY-MM-DD`，按周一到周日排。
    public var days: [String]

    // ---- 三类时间（3.7：分列，不相加当总数）----
    public var totalDwellS: Double
    public var totalActiveS: Double
    public var totalUnknownS: Double
    /// 双屏：按焦点归属的时长之和（可能重复计）。
    public var focusDwellS: Double
    /// 双屏：区间并集的「总在线」，不重复计。
    public var onlineUnionS: Double
    public var perDisplayDwellS: [String: Double]

    // ---- 排行（3.7 的应用 / 站点 / 文件三张表）----
    public var apps: [LedgerEntry]
    public var sites: [LedgerEntry]
    public var files: [LedgerEntry]

    public var switches: Int
    public var interruptions: Int
    public var sessions: Int
    public var observations: Int
    /// 有观察的天数（0…7）。
    public var activeDays: Int
    /// 按天分布，7 行。
    public var dayTotals: [WeekDayTotal]

    /// D23：证据用区间表示 `[[lo, hi], …]`，7 天的区间合并去重之后的结果。
    public var evidence: [[Int64]]
    /// 3.7：台账与叙述分开标注。周叙述由 M2 c / T12 的夜间任务写进 `ledgers` 的
    /// `narrative` / `model` / `narrative_meta` 三个**独立列**（不在这份 JSON 里），
    /// 读回来时合进这三个字段；周台账一重算就一起置回 NULL。
    public var narrative: String?
    public var model: String?
    public var sessionConfig: SessionConfig
    public var stale: Bool
    public var computedAt: Int64

    /// 这一次聚合里**真正重算**的日期（其余天直接读日台账缓存）。
    /// 写进结果是为了让"增量确实生效"可验证，不是给人看的排版信息。
    public var daysRecomputed: [String] = []
    /// 这一份是从 `ledgers` 表里原样读回来的（7 天一天都没变）。
    public var servedFromCache: Bool = false

    /// T12（schema v6）的叙述标注：模型、生成时刻、输入 token 数、忠实度核对结果。
    /// 与 `DayLedger.narrativeMeta` 同一口径，同样是独立列、同样随重算置 NULL。
    public var narrativeMeta: NarrativeMeta? = nil

    /// 叙述是不是已经对不上现在这份周台账了（口径与 `DayLedger.narrativeIsStale` 一致：
    /// 正常路径上恒为 false，它是绕过 `upsertWeekLedger` 直接改表时的第二道保险）。
    public var narrativeIsStale: Bool {
        guard narrative != nil else { return false }
        guard let meta = narrativeMeta else { return true }
        return meta.ledgerComputedAt != computedAt
    }
}

// MARK: - get_patterns（3.6 / 4.3）

/// `getPatterns` 的可配置口径。**每个默认值都要能解释**，不是调出来的魔数。
public struct PatternOptions: Sendable, Codable, Equatable {
    /// 连续工作块的时长下限（分钟）。计划 4.3 的原话是「≥ 25 分钟无打断」。
    public var focusBlockMinMinutes: Double = 25
    /// 最多返回几对切换（A→B），按次数倒序。
    public var maxTransitions: Int = 20
    /// 每个应用列几个「常用时段」。
    public var topHoursPerApp: Int = 3
    /// 应用排行最多几行。
    public var maxApps: Int = 20
    /// 最长的几个工作块列出明细。
    public var maxFocusBlockSamples: Int = 10

    public init() {}
}

/// 热力图的一格：星期 × 小时。
public struct PatternCell: Sendable, Codable {
    /// 1 = 周一 … 7 = 周日。
    public var weekday: Int
    /// 0…23，按 `retrieval.timeZone` 的当地小时。
    public var hour: Int
    public var dwellS: Double
    public var activeS: Double
    public var unknownS: Double
    public var observations: Int
    /// 这个格子在查询区间里**出现过几次**（例如问 4 周就是 4 次，跨夏令时可能 3 或 5 次）。
    /// 用它把总时长折算成「平均每次多少秒」，才能跨长度不同的区间比较。
    public var slots: Int
    /// `dwellS / slots`。`slots = 0` 时为 0。
    public var meanDwellS: Double
}

/// 每小时（不分星期）与每星期（不分小时）的两张边际表。
public struct PatternMarginal: Sendable, Codable {
    /// `hour`（0…23）或 `weekday`（1…7）。
    public var index: Int
    public var dwellS: Double
    public var activeS: Double
    public var observations: Int
    public var slots: Int
    public var meanDwellS: Double
}

/// 一个应用的常用时段。
public struct AppHourShare: Sendable, Codable {
    public var hour: Int
    public var dwellS: Double
    /// 占这个应用总 dwell 的比例（0…1）。
    public var share: Double
}

public struct AppPattern: Sendable, Codable {
    public var key: String
    public var name: String?
    public var dwellS: Double
    public var activeS: Double
    public var unknownS: Double
    public var observations: Int
    /// 占全部应用 dwell 的比例（0…1）。
    public var share: Double
    /// 按 dwell 倒序的常用时段（最多 `PatternOptions.topHoursPerApp` 个）。
    public var topHours: [AppHourShare]
    public var firstTS: Int64?
    public var lastTS: Int64?
}

/// 会话长度与打断率（3.7 的三个会话常量决定了会话怎么切）。
public struct SessionPatternStats: Sendable, Codable {
    public var count: Int
    /// 会话时长 = `end - start`（含打断期间；打断不切会话，3.7）。
    public var meanDurationS: Double
    public var medianDurationS: Double
    public var p90DurationS: Double
    public var longestDurationS: Double
    /// 会话内的前台停留合计（不含 unknown）。
    public var meanDwellS: Double
    public var totalDwellS: Double
    public var interruptions: Int
    /// 打断次数 ÷ 会话数。
    public var interruptionsPerSession: Double
    /// 至少被打断一次的会话数。
    public var sessionsWithInterruption: Int
    /// `sessionsWithInterruption / count`（0…1）。
    public var interruptionRate: Double
}

/// 最常切换对（A→B）。
public struct AppTransition: Sendable, Codable {
    public var from: String
    public var fromName: String?
    public var to: String
    public var toName: String?
    public var count: Int
    /// 两条观察之间的平均间隔（毫秒）。它是"切换被观测到的粒度"，不是"切换耗时"。
    public var meanGapMS: Double
}

/// 一个连续工作块。
public struct FocusBlock: Sendable, Codable {
    public var start: Int64
    public var end: Int64
    public var durationS: Double
    public var displayID: Int64?
    /// 块内 dwell 最多的应用。
    public var topApp: String?
    public var topAppName: String?
    /// 块内出现过几个应用（1 = 全程一个应用）。
    public var appCount: Int
    public var observations: Int
    public var activeS: Double
    /// `activeS / durationS`（0…1）。
    public var activeRatio: Double
}

public struct FocusBlockApp: Sendable, Codable {
    public var key: String
    public var name: String?
    public var blocks: Int
    public var totalS: Double
}

public struct FocusBlockStats: Sendable, Codable {
    /// 口径：块内相邻两条观察的间隔 **< `gapSeconds`**，且块内没有 `unknown` 观察，
    /// 总时长 ≥ `minMinutes`。`gapSeconds` 取 3.7 的打断阈值（默认 20 s）。
    public var minMinutes: Double
    public var gapSeconds: Double
    public var count: Int
    public var totalS: Double
    public var meanS: Double
    public var medianS: Double
    public var longestS: Double
    /// 其中全程只用了一个应用的块数。
    public var singleAppBlocks: Int
    /// 其中 `activeRatio ≥ 0.5` 的块数（`user_idle` 占一半以上的块不算在内）。
    public var activeMajorityBlocks: Int
    /// 按块内主应用归类。
    public var byApp: [FocusBlockApp]
    /// 最长的若干个块的明细。
    public var longest: [FocusBlock]
}

/// `get_patterns(start, end)` 的产物。全部可解释、不用模型。
public struct ActivityPatterns: Sendable, Codable {
    public var start: Int64
    public var end: Int64
    public var timeZone: String
    /// 区间跨了几天（`(end - start) / 86400000`，小数）。
    public var spanDays: Double
    /// 区间里实际有观察的自然日数。
    public var activeDays: Int
    public var observations: Int
    public var totalDwellS: Double
    public var totalActiveS: Double
    public var totalUnknownS: Double

    /// 星期 × 小时的活跃热力。只列有时长或有观察的格子（168 格里的非空子集）。
    public var heatmap: [PatternCell]
    /// 热力峰值格（`dwellS` 最大的那一格）；全空时为 nil。
    public var peakCell: PatternCell?
    /// 按小时的边际表（24 行，恒定长度，便于画图与比较）。
    public var byHour: [PatternMarginal]
    /// 按星期的边际表（7 行）。
    public var byWeekday: [PatternMarginal]

    public var apps: [AppPattern]
    public var sessions: SessionPatternStats
    public var transitions: [AppTransition]
    /// 观测到的切换总次数（`transitions` 只列前 N 对）。
    public var transitionsObserved: Int
    /// 不同的切换对个数。
    public var transitionPairs: Int
    public var focus: FocusBlockStats

    public var options: PatternOptions
    public var sessionConfig: SessionConfig
    /// 只统计了这些应用（grant 的白名单）；nil = 全部。
    public var appFilter: [String]?
    public var computedAt: Int64
    public var elapsedMS: Double
}

// MARK: - recent_activity（3.6 / 4.3）

/// 最近活动里的一条观察摘要。**摘要 ≤ `RetrievalOptions.summaryTokenBudget` token**（3.6 的 100 token）。
public struct RecentItem: Sendable, Codable {
    public var evidenceID: Int64
    public var ts: Int64
    public var appBundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?
    public var host: String?
    public var filePath: String?
    public var sourceState: String
    /// 「应用 · 标题 · 时间 · 正文开头」，截到 token 预算内。
    public var summary: String
    public var summaryTokens: Int
}

/// `recent_activity(minutes, max_items)` 的产物。
public struct RecentActivity: Sendable, Codable {
    public var minutes: Int
    /// 半开区间 `[start, end)`。`end` 默认是"现在"，可由调用方指定（测试与验收要确定性）。
    public var start: Int64
    public var end: Int64
    public var maxItems: Int
    /// 窗口内的应用聚合（三类时间分列）。
    public var apps: [LedgerEntry]
    /// 窗口内的会话（不展开证据 id）。
    public var sessions: [SessionRow]
    public var items: [RecentItem]
    /// 窗口内活着的观察总数（应用过滤之后）。
    public var observations: Int
    /// 观察比 `maxItems` 多，后面的没返回。
    public var truncated: Bool
    public var summaryTokenBudget: Int
    /// 只统计了这些应用（grant 的白名单）；nil = 全部。
    public var appFilter: [String]?
    public var timeZone: String
    public var computedAt: Int64
}

/// `list_activity(period | start / end, max_items, before_id)` 的结果：一段窗口内的应用聚合、
/// 会话汇总与观察摘要（最近的在前），按 `beforeID` 游标分页。`recent_activity` 是它的特例
/// （窗口 = 最近 N 分钟）。摘要口径、"只看本机产生的观察"与 `RecentActivity` 完全一致。
public struct ActivityList: Sendable, Codable {
    /// 半开区间 `[start, end)`。
    public var start: Int64
    public var end: Int64
    public var maxItems: Int
    public var apps: [LedgerEntry]
    public var sessions: [SessionRow]
    public var items: [RecentItem]
    /// 窗口内活着的观察总数（应用过滤之后、与游标无关）。
    public var observations: Int
    /// 这一页之后还有更早的观察。
    public var truncated: Bool
    /// 下一页的游标：把它当 `before_id` 再调一次就拿到更早的一页；nil = 没有下一页。
    public var nextBeforeID: Int64?
    /// 本页是从哪个游标之后开始的（原样回显）。
    public var beforeID: Int64?
    public var summaryTokenBudget: Int
    public var appFilter: [String]?
    public var timeZone: String
    public var computedAt: Int64
}
