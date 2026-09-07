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

    public init(q: String, start: Int64? = nil, end: Int64? = nil,
                app: String? = nil, limit: Int = 20) {
        self.q = q
        self.start = start
        self.end = end
        self.app = app
        self.limit = limit
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
    public var filteredFTSCandidateLimit: Int = 2000
    /// 每条摘要的 token 预算（3.6：每条 ≤ 100 token）。
    public var summaryTokenBudget: Int = 100
    /// 摘要里命中片段前后各留多少个字符。
    public var snippetContext: Int = 40
    /// 台账 / 时间线 / `getItem` 的日历时区。默认本机时区；测试与验收用 UTC 保证确定性。
    public var timeZone: TimeZone = .current

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

/// `get_day_ledger(date)` 的产物。**`narrative` 永远是 nil**——3.7 要求台账与叙述分开标注，
/// 叙述是 M2 的可选夜间任务。
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
