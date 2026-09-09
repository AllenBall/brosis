import Foundation

// =============================================================================
// MARK: - token 预算
// =============================================================================

/// token 估算口径（全包统一，报告与 API 文档都按这个写）：
/// **token 数 = 字符数 ÷ 2，向上取整**。
///
/// 为什么是字符数 ÷ 2：本项目的正文是中英混排（E7 实测汉字占字符数 40.5%），
/// 汉字大致 1 字 1 token、英文大致 4 字符 1 token，取 2 是居中的保守估计。
/// 这是**估算**不是分词——真要精确计数得引入分词器，M1 不做。
/// 3.6 的「每条 ≤ 100 token 摘要」按这个口径就是**每条摘要 ≤ 200 个字符**。
public enum TokenBudget {

    /// 估算一段文本的 token 数。
    public static func tokens(of text: String) -> Int {
        let n = text.count
        return n == 0 ? 0 : (n + 1) / 2
    }

    /// token 预算折算成字符预算。
    public static func characters(forTokens tokens: Int) -> Int { max(0, tokens) * 2 }

    /// 截到 token 预算内。截断时末尾补 `…`，省略号本身也算在预算里。
    public static func truncate(_ text: String, toTokens limit: Int) -> String {
        let maxChars = characters(forTokens: limit)
        guard text.count > maxChars else { return text }
        guard maxChars >= 1 else { return "" }
        return String(text.prefix(maxChars - 1)) + "…"
    }
}

// =============================================================================
// MARK: - 检索
// =============================================================================

/// 查询形态路由（3.4「精确字段独立」）。写法与 `tools/bench/fts_compare.py` 的
/// `route_kind()` 对齐：判定只看查询串长什么样，判错了也只是多跑一次很便宜的两步式查询，
/// 因为三条通道是**并集**不是互斥的。
public enum QueryRoute: String, Sendable, Codable, CaseIterable {
    case url, path, text
}

/// 检索通道。一次 `search` 会走其中若干条，结果按通道顺序合并去重。
public enum SearchChannel: String, Sendable, Codable, CaseIterable {
    /// `urls` 表两步式：host 等值 / canonical 前缀 / raw_locator 子串
    case exactURL = "exact_url"
    /// `files.path` 两步式
    case exactPath = "exact_path"
    /// `apps.bundle_id` / `apps.name` 两步式（只在 `app:` 前缀查询时单独成通道）
    case exactApp = "exact_app"
    /// `windows.title` 两步式
    case exactTitle = "exact_title"
    /// bigram phrase → 候选按 rowid 倒序 → 子串复核 → 展开到观察（D22 + E7）
    case fts
    /// 1–2 字查询：限时 / 限应用的 `LIKE` 扫描（3.4）
    case scan
    /// v4（M2 c / T11）：查询向量 → `vec_chunks` kNN → 块 → 文本版本 → 展开到观察（3.4「向量检索」）。
    /// **默认关**（`RetrievalOptions.vectorsEnabled`），没装嵌入模型时强制关。
    case vector
}

/// `search(q, start, end, app, limit)`（3.6 工具签名）。
public struct SearchRequest: Sendable {
    /// 查询串。支持 `url:` / `host:` / `path:` / `app:` / `title:` 五个字段前缀，
    /// 带前缀时**只走**对应的精确字段通道，不经 FTS。
    public var q: String
    /// 半开区间 `[start, end)`，Unix 毫秒。
    public var start: Int64?
    public var end: Int64?
    /// 应用过滤：`apps.bundle_id` 等值（列上有 COLLATE NOCASE）。
    public var app: String?
    public var limit: Int
    /// v4（M2 c / T11）：查询串的嵌入向量。**由调用方算好传进来**——
    /// core 不加载任何模型（3.10 的提供方抽象在 `EmbeddingProvider`，本地实现在 app 侧）。
    /// 为 nil、或 `RetrievalOptions.vectorsEnabled` 为 false、或库里一条向量都没有时，
    /// 向量通道不参与，`SearchResult.vectorsUnavailable` 会说明是哪一种。
    public var queryVector: [Float]?

    public init(q: String, start: Int64? = nil, end: Int64? = nil,
                app: String? = nil, limit: Int = 20, queryVector: [Float]? = nil) {
        self.q = q
        self.start = start
        self.end = end
        self.app = app
        self.limit = limit
        self.queryVector = queryVector
    }
}

/// 一条命中。`evidenceID` 就是 `observations.id`，拿它去 `getEvidence` 展开原文。
public struct SearchHit: Sendable, Codable {
    public var evidenceID: Int64
    public var ts: Int64
    public var appBundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?
    public var host: String?
    public var filePath: String?
    /// 命中片段（正文里命中处前后各留 `RetrievalOptions.snippetContext` 个字符）。
    public var snippet: String
    public var channel: SearchChannel
    /// ≤ `RetrievalOptions.summaryTokenBudget` token 的一行摘要：应用 · 标题 · 时间 · 命中片段。
    public var summary: String
    public var summaryTokens: Int
    /// v4（M2 c / T11）：这条**观察**在向量通道里的余弦距离（0 = 完全一致、1 = 正交）。
    ///
    /// 语义是「向量通道也找到了它，距离是这么多」，与 `channel` 最终标了哪条通道无关：
    /// 一条 FTS 精确命中同时被向量通道找到时照样有值（那正是调用方想知道的）。
    /// 向量通道压根没返回这条观察时是 nil；向量通道没参与时全都是 nil。
    ///
    /// 它是给调用方（MCP 客户端、Agent）的**可信度信号**：`channel == .vector` 且距离偏大的命中
    /// 是「相似」不是「命中」。D8 的实验数据表明，单一距离阈值分不开
    /// 「库里没有这个内容」与「换了个说法的真命中」（见结果文件的阈值扫描），
    /// 所以这一层如实把距离交出去，由上层决定要不要展开成证据。
    public var vectorDistance: Double?
}

public struct SearchResult: Sendable, Codable {
    public var query: String
    /// NFKC 折叠后的查询串。**折叠只用于索引**：`text_fts` 与查询串按折叠后的形式对，
    /// `text_versions.text` 存的是原文，`get_evidence` 拿到的也是原文。
    public var normalizedQuery: String
    public var route: QueryRoute
    public var channels: [SearchChannel]
    public var hits: [SearchHit]
    /// FTS 通道取回的候选数（子串复核之前）。
    public var ftsCandidates: Int
    /// 候选是否被 `LIMIT` 截断（截断说明可能漏召回，是调参信号）。
    public var ftsCandidatesTruncated: Bool
    /// 子串复核之后剩下的候选数。
    public var ftsVerified: Int
    /// 扫描通道实际用的时间窗（毫秒；没走扫描通道时为 nil）。
    public var scanFromTS: Int64?
    public var scanToTS: Int64?
    public var elapsedMS: Double

    // ---- v4（M2 c / T11）向量通道 ----

    /// 向量通道这次**没有**参与。`true` 时 `vectorUnavailableReason` 说明原因，
    /// 三条精确 / 扫描 / FTS 通道照常工作（3.11「未安装模型时向量检索显示未启用」）。
    public var vectorsUnavailable: Bool = true
    /// `disabled`（开关关）/ `no_query_vector`（调用方没给向量）/ `no_index`（库里没有向量）/
    /// `error:<原因>`；参与时为 nil。
    public var vectorUnavailableReason: String?
    /// kNN 取回的块数（合并之前）。
    public var vectorCandidates: Int = 0
    /// 向量通道展开到观察后的条数。
    public var vectorObservations: Int = 0
    /// 最好的一条余弦距离（0 = 完全一致；没走向量通道时为 nil）。
    public var vectorBestDistance: Double?
    /// 这次的合并方式：`union`（三通道并集，向量关时的老口径）或 `rrf`（加权 RRF，向量开时）。
    public var fusion: String = "union"
}

/// 检索层的可配置参数。开库后、开始查询前设置；不是线程安全的。
public struct RetrievalOptions: Sendable {
    /// 1–2 字查询扫描通道的默认时间窗（3.4：7 天窗口内实测召回 100%）。
    public var scanWindowDays: Int = 7
    /// 触发扫描通道的查询字符数上界（3.4「一到两字查询」）。
    public var scanMaxQueryCharacters: Int = 2
    /// 纯汉字两字查询跳过扫描通道（默认开）。这类查询本身就是一个 bigram token，
    /// FTS 通道已经是精确子串语义，扫描零召回增益却要扫窗口内全部正文。
    /// 关掉它就退回「≤ 2 字一律扫」的老口径，用来量这条策略到底省了多少（`bench --scan-all-short`）。
    public var scanSkipsPureCJKBigram: Bool = true
    /// FTS 候选窗口（无过滤）。E7：`ORDER BY rowid DESC LIMIT` 让延迟与库规模无关。
    public var ftsCandidateLimit: Int = 200
    /// FTS 候选窗口（带时间 / 应用过滤）。过滤会把候选筛掉，所以要取更大的窗口。
    ///
    /// **经 MCP 的 search 必然走这一档**：grant 带时间窗，所以每次都是"带过滤"。
    /// T15 实测这让它比直接调用慢 3 倍，换来召回 0.254 → 0.277。
    ///
    /// **裁决（2026-09-09，e 批 ⑧）：不给 MCP 单独调小。** 一次 MCP search 客户端墙钟
    /// p50 84 ms，慢 3 倍也就 250 ms 量级——对一个 agent 工具调用，这个延迟看不出来，
    /// 而少 0.023 的召回意味着答不出的问题变多，那才是用户会察觉的。
    /// 再加一个只有作者会调的旋钮，不如把取舍写在这里。
    public var filteredFTSCandidateLimit: Int = 2000
    /// 每条摘要的 token 预算（3.6：每条 ≤ 100 token）。
    public var summaryTokenBudget: Int = 100
    /// 摘要里命中片段前后各留多少个字符。
    public var snippetContext: Int = 40
    /// 台账 / 时间线 / `getItem` 的日历时区。默认本机时区；测试与验收用 UTC 保证确定性。
    public var timeZone: TimeZone = .current

    // ---- v4（M2 c / T11）向量通道。全部**默认关**，模型没装时强制关 ----

    /// 向量检索开关（计划 3.4「未安装时向量检索显示为未启用」、4.3「默认关闭、模型安装后可开启」）。
    /// **默认 false**：关着的时候 `search` 一次向量调用都不发，行为与 v3 逐位相同。
    public var vectorsEnabled: Bool = false
    /// kNN 取多少个块（无过滤）。sqlite-vec v0.1.9 的 kNN 是全量扫描，
    /// 代价与 k 基本无关（排序那一点点除外），所以取大一些不吃亏。
    public var vectorK: Int = 200
    /// kNN 取多少个块（带时间 / 应用过滤）。过滤会把候选筛掉，所以要更大的窗口，
    /// 理由与 `filteredFTSCandidateLimit` 完全一样。
    public var filteredVectorK: Int = 1_000
    /// 余弦距离上界（`vec0` 的 `distance`，0 = 完全一致、1 = 正交）。超过它的块直接丢掉。
    ///
    /// 它挡的是**负例误报**：向量通道给的是最近邻，"库里根本没有这个内容"的查询照样能拿到
    /// 一堆相似度不高的块，而 `docs/查询集草稿.md` 规定不可答题「编造一次即失败」。
    ///
    /// **0.50 是实测选出来的**（2026-09-09 的 D8 重跑，1024 维；扫描表见
    /// `~/Library/Caches/brosis-build/d8-1024/d8s/results/d8_threshold_sweep_brief.txt`）：
    /// 46,545 块、47 道改写题上，0.45 → 0.50 还能多救 3 题（36 → 39）且误报不变（2 条），
    /// 0.50 → 0.55 召回几乎不涨（0.387 → 0.418）误报却翻到 8 条。原 60 题在整段扫描里
    /// Recall@10 恒为 1.000、MRR 恒为 0.7442、回退 0 题。
    ///
    /// **旧值 0.40 是在 512 维上调的**（M2 c / T11）。维度改成 1024（schema v9）之后
    /// 距离分布整体右移，0.40 变得过紧：同一套题只救回 28 题（0.234 / MRR 0.548），
    /// 反而不如当年 512 维的 0.277 / 0.662；换到 0.50 之后是 0.387 / 0.771，好过旧配置。
    ///
    /// **已知限制：这个阈值不随索引规模自适应**。同一套题、同一个阈值，索引从 37% 建到 66%
    /// 时负例误报就从 0 涨到 2——块越多，"库里没有的内容"的最近邻也越近。
    /// 所以它是**一个需要随语料规模与维度复核的常量**，不是一劳永逸的分界线；
    /// 真正的解法（按查询自适应的阈值、或让调用方按 `SearchHit.vectorDistance` 自己判）
    /// 仍未做。
    public var vectorMaxDistance: Double = 0.50
    /// RRF 融合常数 k（Cormack 2009 的经典取值 60）。
    public var rrfK: Double = 60
    /// RRF 里向量通道的权重。精确字段 / 扫描 / FTS 三条都是 1.0，向量是 0.5：
    /// 前三条是**精确子串**语义（命中就是真命中），向量是相似度，权重减半让
    /// "两边都命中"的证据排在"只有向量命中"的前面，从而保证原 60 题不被向量挤下去。
    public var vectorWeight: Double = 0.5

    public init() {}
}

// =============================================================================
// MARK: - 证据（3.6 `get_evidence(ids)`）
// =============================================================================

/// 3.6 的 grant 模式。
public enum GrantMode: String, Sendable, Codable, CaseIterable {
    case strictLocal = "strict_local"
    case remoteAllowed = "remote_allowed"
}

/// 3.6 的字段级别：`summary` 只给摘要，`evidence` 才给原文。默认 summary。
public enum GrantFields: String, Sendable, Codable, CaseIterable {
    case summary, evidence
}

/// `grants` 表的一行。MCP 进程（R2）按它校验，本包只提供读写与判定。
public struct Grant: Sendable, Codable {
    public var clientID: String
    public var mode: GrantMode
    /// 应用白名单；`["*"]` = 全部。
    public var apps: [String]
    /// 时间窗（天），默认 30。
    public var timeWindowDays: Int
    public var fields: GrantFields
    public var createdAt: Int64

    public init(clientID: String, mode: GrantMode = .strictLocal, apps: [String] = ["*"],
                timeWindowDays: Int = 30, fields: GrantFields = .summary,
                createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.clientID = clientID
        self.mode = mode
        self.apps = apps
        self.timeWindowDays = timeWindowDays
        self.fields = fields
        self.createdAt = createdAt
    }

    public func allows(app bundleID: String?) -> Bool {
        if apps.contains("*") { return true }
        guard let bundleID else { return false }
        return apps.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

public struct EvidenceOccurrence: Sendable, Codable {
    public var textVersionID: Int64
    public var ord: Int
    public var region: String?
    /// grant 字段级别是 `summary` 时为 nil。
    public var text: String?
    public var byteLen: Int
    /// schema v3：这段文本的来源置信度（0–1）。AX / 适配器读值为 nil，OCR 片段才有。
    public var confidence: Double?
    /// schema v3：区域备注（形状，不含正文），如低置信 token 计数与 OCR 区域像素矩形。
    public var note: String?
}

/// 出现上下文：同一条证据前后各 N 条观察的摘要（不含原文）。
public struct EvidenceNeighbor: Sendable, Codable {
    public var evidenceID: Int64
    public var ts: Int64
    public var appBundleID: String?
    public var windowTitle: String?
    public var summary: String
}

public struct EvidenceItem: Sendable, Codable {
    public var evidenceID: Int64
    public var ts: Int64
    public var displayID: Int64?
    public var appBundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: String?
    public var host: String?
    public var filePath: String?
    public var trigger: String
    public var captureMethod: String
    public var completeness: String
    public var sourceState: String
    public var occurrences: [EvidenceOccurrence]
    /// 按 `ord` 拼起来的完整原文；grant 是 `summary` 时为 nil。
    public var text: String?
    public var summary: String
    public var before: [EvidenceNeighbor]
    public var after: [EvidenceNeighbor]
    /// 因为 grant 字段级别被裁掉了原文。
    public var redactedByGrant: Bool
}

public struct EvidenceResult: Sendable, Codable {
    public var items: [EvidenceItem]
    /// 不存在、已被用户删除（墓碑）或已被配额过期物理删除的 id。
    /// 3.8 的验收要求这几类**不返回任何内容**，所以只回 id 本身。
    public var missing: [Int64]
    /// 被 grant 挡掉的 id（应用白名单 / 时间窗）。
    public var deniedByGrant: [Int64]
    /// 被 grant 挡掉的**出现上下文**条数（`before` / `after` 里白名单外、时间窗外的相邻观察）。
    /// 只回条数不回 id：回 id 本身就等于告诉调用方"这个时刻还有别的应用"。
    public var droppedNeighbors: Int = 0
}

// =============================================================================
// MARK: - 会话与台账（3.7）
// =============================================================================

/// 3.7 的三个会话常量。**是可配置参数，不是已验证结论**。
public struct SessionConfig: Sendable, Codable, Equatable {
    /// 单条观察能代表的前台停留上限（秒）。两条观察间隔超过它，超出部分不计时长。
    public var maxDwellSeconds: Double = 90
    /// 会话间隔上限（秒）。同一应用两段观察间隔 ≥ 它就切成两个会话。
    public var gapSeconds: Double = 300
    /// 打断上限（秒）。离开又回来的时长 < 它算一次「打断」，不切会话。
    public var interruptionSeconds: Double = 20

    public init(maxDwellSeconds: Double = 90, gapSeconds: Double = 300,
                interruptionSeconds: Double = 20) {
        self.maxDwellSeconds = maxDwellSeconds
        self.gapSeconds = gapSeconds
        self.interruptionSeconds = interruptionSeconds
    }
}

public struct SessionRow: Sendable, Codable {
    public var id: Int64
    public var start: Int64
    public var end: Int64
    public var displayID: Int64?
    public var appID: Int64?
    public var appBundleID: String?
    public var appName: String?
    /// 前台停留（秒）。不含 unknown。
    public var dwellS: Double
    /// 有输入的活跃（秒）。是 dwell 的子集。
    public var activeS: Double
    /// 未知（秒）：权限丢失 / 读取超时 / 锁定。
    public var unknownS: Double
    public var interruptions: Int
    public var observationIDs: [Int64]
    public var stale: Bool
}

public struct SessionBuildReport: Sendable, Codable {
    /// 本次重算的起点（毫秒）；nil 表示库里没有观察。
    public var fromTS: Int64?
    public var incremental: Bool
    public var observationsScanned: Int
    public var sessionsDeleted: Int
    public var sessionsInserted: Int
    /// 因为被标 stale 而被卷进这次重算的会话数。
    public var staleRecomputed: Int
    public var watermarkTS: Int64?
    public var elapsedMS: Double
}

/// 台账里的一行（按应用 / 站点 / 文件）。
public struct LedgerEntry: Sendable, Codable {
    public var key: String
    public var name: String?
    public var dwellS: Double
    public var activeS: Double
    public var unknownS: Double
    /// 切换次数：这一行在当天的观察流里被「切入」了多少次。
    public var switches: Int
    public var observations: Int
}

/// `get_day_ledger(date)` 的产物。
///
/// **台账本身是确定性的**：`apps` 以下到 `computedAt` 为止的每一个数都由观察算出来，
/// 不经过任何模型（3.7）。`narrative` / `model` / `narrativeMeta` 三个字段是
/// **M2 的可选夜间任务**贴上去的标注，与台账分开（3.7「输出与台账分开标注」）：
/// 它们不在 `ledgers.ledger` 那份 JSON 里，而是 `ledgers` 表的三个独立列，
/// 台账一重算就一起置回 NULL。没跑过叙述、或者模型没装时，三个都是 nil。
public struct DayLedger: Sendable, Codable {
    public var date: String
    public var timeZone: String
    public var start: Int64
    public var end: Int64
    public var apps: [LedgerEntry]
    public var sites: [LedgerEntry]
    public var files: [LedgerEntry]
    public var totalDwellS: Double
    public var totalActiveS: Double
    public var totalUnknownS: Double
    /// 双屏：按焦点归属的时长之和（可能重复计）。
    public var focusDwellS: Double
    /// 双屏：会话区间**并集**的「总在线」，不重复计（3.7）。
    public var onlineUnionS: Double
    /// 每块屏各自的 dwell。
    public var perDisplayDwellS: [String: Double]
    public var switches: Int
    public var interruptions: Int
    public var sessions: Int
    public var observations: Int
    /// D23：证据用区间表示 `[[lo, hi], …]`。
    public var evidence: [[Int64]]
    public var narrative: String?
    public var model: String?
    public var sessionConfig: SessionConfig
    public var stale: Bool
    public var computedAt: Int64
    /// M2 c / T14：这份台账**算的时候**这一天有哪些观察，写成 `n=<条数>,max=<最大 id>`。
    ///
    /// 为什么要它：`ledgers` 行只在**删除**时被标 `stale`（3.8 的级联），
    /// 新观察写进来不会碰它——于是"今天"的台账一旦算过一次就被永久缓存，
    /// 当天后来的活动全部看不见（M1 的既有行为）。周台账要按天聚合、还要谈"增量"，
    /// 这个洞必须先堵上：读缓存时拿它跟库里现算的一份比，不一致就重算。
    ///
    /// 可空：v1–v3 写下的老台账行没有这个字段，读回来是 nil，按"验不了 → 重算"处理。
    public var contentFingerprint: String?

    /// M2 c / T12（schema v6）：叙述的标注——模型、生成时刻、输入 token 数、忠实度核对结果。
    ///
    /// 它和 `narrative` / `model` 一样**不在 `ledgers.ledger` 那份 JSON 里**，
    /// 而是 `ledgers` 表的独立列（3.7「输出与台账分开标注」），台账一重算就一起置回 NULL。
    /// 可空：没跑过叙述、模型没装、或者叙述没通过忠实度核对被丢弃时都是 nil。
    /// 默认 nil，这样 `computeDayLedger` 的构造点不必显式传它（台账算出来时本来就没有叙述）。
    public var narrativeMeta: NarrativeMeta? = nil

    /// 叙述是不是已经对不上现在这份台账了。
    ///
    /// 正常路径上永远是 false：台账重算时 `narrative` / `model` / `narrative_meta`
    /// 一起被置成 NULL。留这个判定是**第二道保险**——万一有人绕过 `upsertLedger`
    /// 直接改了台账行，靠 `NarrativeMeta.ledgerComputedAt` 对不上也能把旧叙述判成过期。
    public var narrativeIsStale: Bool {
        guard narrative != nil else { return false }
        guard let meta = narrativeMeta else { return true }
        return meta.ledgerComputedAt != computedAt
    }
}

// =============================================================================
// MARK: - 时间线与对象（3.6 `get_timeline` / `get_item`）
// =============================================================================

public enum TimelineGranularity: String, Sendable, Codable, CaseIterable {
    case hour, day, week
}

public struct TimelineBucket: Sendable, Codable {
    public var label: String
    public var start: Int64
    public var end: Int64
    public var observations: Int
    public var apps: [LedgerEntry]
    public var topApp: String?
    public var dwellS: Double
    public var activeS: Double
    public var unknownS: Double
    public var onlineUnionS: Double
    public var switches: Int
}

public struct Timeline: Sendable, Codable {
    public var start: Int64
    public var end: Int64
    public var granularity: TimelineGranularity
    public var timeZone: String
    public var buckets: [TimelineBucket]
}

/// `get_item(url | path | app)` 的选择子。
public enum ItemSelector: Sendable {
    case url(String)
    case path(String)
    case app(String)

    public var kind: String {
        switch self {
        case .url: return "url"
        case .path: return "path"
        case .app: return "app"
        }
    }
    public var key: String {
        switch self {
        case .url(let v), .path(let v), .app(let v): return v
        }
    }
}

public struct ItemSummary: Sendable, Codable {
    public var kind: String
    public var key: String
    /// 两步式第一步命中的规范化对象（URL / 路径 / bundle_id），最多列 20 条。
    public var matchedObjects: [String]
    public var observations: Int
    public var firstSeen: Int64?
    public var lastSeen: Int64?
    /// 'YYYY-MM-DD' → 观察数。
    public var days: [String: Int]
    public var apps: [LedgerEntry]
    public var titles: [String]
    public var recentEvidenceIDs: [Int64]
    public var dwellS: Double
}

// =============================================================================
// MARK: - 上下文（3.6 `get_context(hours, max_tokens)`）
// =============================================================================

public struct ContextSnippet: Sendable, Codable {
    public var evidenceID: Int64
    public var ts: Int64
    public var appBundleID: String?
    public var windowTitle: String?
    public var text: String
    public var tokens: Int
}

public struct ContextBundle: Sendable, Codable {
    public var hours: Int
    public var start: Int64
    public var end: Int64
    public var maxTokens: Int
    public var usedTokens: Int
    public var apps: [LedgerEntry]
    public var sessions: [SessionRow]
    public var snippets: [ContextSnippet]
    /// 预算不够、后面的正文被丢掉了。
    public var truncated: Bool
    /// 拼好的、已按预算截断的上下文文本（token 口径见 `TokenBudget`）。
    public var text: String
}
