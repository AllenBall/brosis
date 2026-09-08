import Foundation
import BrosisIPC

// =============================================================================
// 计划 3.6 的服务端：把一条 IPC 请求变成一次 Store 查询，按 grant 裁剪，写审计。
//
// 这一层在**持钥进程**里（brosis.app，或测试里的 `brosis-store serve`）。
// `brosis-mcp` 只负责 stdio 上的 MCP 与转发，所有判定都在这里，客户端改不动也绕不过。
//
// 只读：本文件只调用 `Store` 的查询方法（search / getEvidence / getTimeline /
// getDayLedger / getItem / getContext）与 grant 读写、审计写入，没有任何观察写入路径
// （2.2 硬约束 4「MCP 只读」）。
//
// M2 d / T15：`search` 多了一个**可注入**的查询嵌入器（`QueryEmbedder`，定义在
// `QueryEmbedder.swift`）。core 仍然不加载任何模型——注入的实现在 app 侧
// （`BrosisModels.MLXQueryEmbedder`）。**没注入时行为与 c 批逐位相同**：
// 结果里 `vectorsUnavailable = true`、`vectorUnavailableReason = no_query_vector`。
// =============================================================================

/// 被 grant 挡下（应用白名单 / 时间窗 / 字段级别）。
struct MCPDeniedByGrant: Error { let message: String }
/// 参数不合法。
struct MCPBadArgument: Error { let message: String }

public final class StoreMCPService: @unchecked Sendable {

    public struct Options: Sendable {
        /// `get_evidence` 一次最多展开几条（3.6「证据展开量受限」）。
        public var maxEvidenceIDs = 50
        /// `search` 的 limit 上限。
        public var maxSearchLimit = 100
        /// `get_context` 的 token 预算上限。
        public var maxContextTokens = 20_000
        /// `get_timeline` 的分桶数上限，防止有人问一百年的 hour 粒度。
        public var maxTimelineBuckets = 2000
        /// `get_patterns` 的区间上限（天）。它要扫区间内**全部**观察，
        /// 代价随区间线性（1 个月合成库实测见 T14 结果文件），所以给个明确的上界。
        public var maxPatternDays = 180
        /// `recent_activity` 一次最多返回几条观察摘要。
        public var maxRecentItems = 200
        /// 应用白名单生效时，`search` 内部多取几倍候选再过滤（过滤后再截到 limit）。
        public var whitelistOverfetch = 5
        public init() {}
    }

    private let store: Store
    private let options: Options
    /// 服务端自己的名字，写进 ping / status 结果。
    private let serverInfo: String

    // ---- M2 d / T15：查询嵌入器（可注入，nil 时行为与 c 批逐位相同）----
    private let embedderLock = NSLock()
    private var _queryEmbedder: QueryEmbedder?

    public init(store: Store, options: Options = Options(), serverInfo: String = "brosis",
                queryEmbedder: QueryEmbedder? = nil) {
        self.store = store
        self.options = options
        self.serverInfo = serverInfo
        self._queryEmbedder = queryEmbedder
    }

    /// 当前注入的查询嵌入器（`nil` = 没有，`search` 走 `no_query_vector` 那条老路）。
    public var queryEmbedder: QueryEmbedder? {
        embedderLock.lock(); defer { embedderLock.unlock() }
        return _queryEmbedder
    }

    /// app 侧在「库解锁 + 模型已装 + `retrieval.vectorsEnabled` 开」时注入，
    /// 关库 / 锁定时摘掉（M2 d / T15；产品接线在 `app/Sources/brosis/IPCService.swift`）。
    public func setQueryEmbedder(_ embedder: QueryEmbedder?) {
        embedderLock.lock()
        _queryEmbedder = embedder
        embedderLock.unlock()
    }

    /// 给 `MCPGate` 补写审计用（库不可用期间攒下的行）。
    @discardableResult
    public func appendAudit(_ row: MCPAuditRow) -> Bool { store.appendMCPAudit(row) }

    // MARK: - 入口

    public func handle(_ call: IPCCall) -> IPCResponse {
        let t0 = Date()
        let request = call.request

        // `ping` 不查库、不需要 grant、不写审计、不计限流：它只回"服务在、库开着"。
        if request.op == .ping, call.refusal == nil {
            return IPCResponse(id: request.id, result: .object([
                "server": .string(serverInfo),
                "state": .string("unlocked"),
                "protocolVersion": .int(Int64(IPCProtocol.version)),
                "schemaVersion": .int(Int64(Schema.version)),
                "tools": .array(MCPTool.allCases.map { .string($0.rawValue) }),
            ]))
        }

        // 传输层已经判定的拒绝（对端签名 / 限流）：这里只补一条审计行。
        if let refusal = call.refusal {
            writeAudit(call, tool: request.name ?? "-", params: "-",
                       decision: MCPDecision(refusal.code), count: 0,
                       note: "rate=\(call.rateUsed)/\(call.rateLimit)", since: t0)
            return IPCResponse(id: request.id, code: refusal.code, message: refusal.message)
        }

        switch request.op {
        case .ping:
            return IPCResponse(id: request.id, result: .object(["server": .string(serverInfo)]))
        case .admin:
            return handleAdmin(call, since: t0)
        case .tool:
            return handleTool(call, since: t0)
        }
    }

    // MARK: - 工具

    private func handleTool(_ call: IPCCall, since t0: Date) -> IPCResponse {
        let request = call.request
        let name = request.name ?? ""
        guard let tool = MCPTool(rawValue: name) else {
            writeAudit(call, tool: name, params: "-", decision: .unknownTool, count: 0,
                       note: nil, since: t0)
            return IPCResponse(id: request.id, code: .unknownTool,
                               message: "不认识的工具 \(name)；本服务只有 "
                                      + MCPTool.allCases.map(\.rawValue).joined(separator: " / "))
        }
        let params = Self.parameterSummary(tool: tool, args: request.args)

        // 3.6：没有 grant 的客户端**所有工具都拒绝**。
        let grant: Grant?
        do {
            grant = try store.grant(clientID: request.client)
        } catch {
            writeAudit(call, tool: name, params: params, decision: .error, count: 0,
                       note: "grant 读取失败", since: t0)
            return IPCResponse(id: request.id, code: .internalError, message: "读取 grant 失败：\(error)")
        }
        guard let grant else {
            writeAudit(call, tool: name, params: params, decision: .noGrant, count: 0,
                       note: nil, since: t0)
            return IPCResponse(id: request.id, code: .noGrant,
                               message: "客户端 \(request.client) 没有 grant，所有工具都被拒绝。"
                                      + "请用 `brosis-mcp admin grant add --client \(request.client)` 授权。")
        }

        do {
            let outcome = try run(tool: tool, args: request.args, grant: grant)
            writeAudit(call, tool: name, params: params, decision: .ok,
                       count: outcome.count, note: outcome.note, since: t0)
            return IPCResponse(id: request.id, result: outcome.value)
        } catch let e as MCPDeniedByGrant {
            writeAudit(call, tool: name, params: params, decision: .deniedByGrant, count: 0,
                       note: e.message, since: t0)
            return IPCResponse(id: request.id, code: .deniedByGrant, message: e.message)
        } catch let e as MCPBadArgument {
            writeAudit(call, tool: name, params: params, decision: .badRequest, count: 0,
                       note: e.message, since: t0)
            return IPCResponse(id: request.id, code: .badRequest, message: e.message)
        } catch {
            writeAudit(call, tool: name, params: params, decision: .error, count: 0,
                       note: "\(error)", since: t0)
            return IPCResponse(id: request.id, code: .internalError, message: "查询失败：\(error)")
        }
    }

    struct ToolOutcome {
        var value: JSONValue
        var count: Int
        var note: String?
    }

    private func run(tool: MCPTool, args: [String: JSONValue], grant: Grant) throws -> ToolOutcome {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let windowStart = now - Int64(grant.timeWindowDays) * 86_400_000
        let calendar = DayCalendar(store.retrieval.timeZone)
        let scoped = !grant.apps.contains("*")

        switch tool {
        case .search:
            return try runSearch(args, grant: grant, windowStart: windowStart, scoped: scoped)
        case .getEvidence:
            return try runEvidence(args, grant: grant)
        case .getContext:
            return try runContext(args, grant: grant, windowStart: windowStart,
                                  scoped: scoped, calendar: calendar)
        case .getTimeline:
            return try runTimeline(args, grant: grant, windowStart: windowStart, scoped: scoped)
        case .getDayLedger:
            return try runDayLedger(args, grant: grant, windowStart: windowStart, scoped: scoped)
        case .getItem:
            return try runItem(args, grant: grant, windowStart: windowStart, scoped: scoped)
        case .getWeekLedger:
            return try runWeekLedger(args, grant: grant, windowStart: windowStart, scoped: scoped)
        case .getPatterns:
            return try runPatterns(args, grant: grant, windowStart: windowStart, scoped: scoped)
        case .recentActivity:
            return try runRecentActivity(args, grant: grant, scoped: scoped)
        }
    }

    // MARK: - search

    private func runSearch(_ args: [String: JSONValue], grant: Grant,
                           windowStart: Int64, scoped: Bool) throws -> ToolOutcome {
        guard let q = args["q"]?.stringValue, !q.isEmpty else {
            throw MCPBadArgument(message: "search 需要非空的 q")
        }
        let limit = min(max(1, Int(args["limit"]?.intValue ?? 20)), options.maxSearchLimit)
        let asked = try Self.time(args["start"], field: "start", calendar: DayCalendar(store.retrieval.timeZone))
        let end = try Self.time(args["end"], field: "end", calendar: DayCalendar(store.retrieval.timeZone))
        // 3.6 的时间窗：grant 的窗口是硬下界，客户端给的 start 只能更晚。
        let start = max(asked ?? windowStart, windowStart)

        var app = args["app"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        if app?.isEmpty == true { app = nil }
        if let app, !grant.allows(app: app) {
            throw MCPDeniedByGrant(message: "grant 的应用白名单不含 \(app)")
        }

        // ---- M2 d / T15：查询向量（**在 `store.search` 之前算，不持库锁**）----
        let timing = queryEmbedding(for: q)
        let fetch = scoped ? min(limit * options.whitelistOverfetch, 500) : limit
        let result = try store.search(SearchRequest(q: q, start: start, end: end, app: app,
                                                    limit: fetch, queryVector: timing.vector))
        var hits = result.hits
        var dropped = 0
        if scoped {
            let kept = hits.filter { grant.allows(app: $0.appBundleID) }
            dropped = hits.count - kept.count
            hits = Array(kept.prefix(limit))
        }

        var object = try JSONValue(encoding: result).objectValue ?? [:]
        object["hits"] = try JSONValue(encoding: hits)
        object["hitCount"] = .int(Int64(hits.count))
        object["appliedStart"] = .int(start)
        if let end { object["appliedEnd"] = .int(end) }
        object["grant"] = grantBlock(grant, windowStart: windowStart,
                                     filtered: scoped, droppedByGrant: dropped)
        // 3.4 的分层目标要按它报：查询嵌入热延迟 ≤ 150 ms（M2 d / T15）。
        object["queryEmbed"] = try JSONValue(encoding: timing.timing)
        var note = "qvec=\(timing.timing.source)"
        if let ms = timing.timing.elapsedMS { note += String(format: " embed_ms=%.1f", ms) }
        if scoped { note += " grant_filtered=\(dropped)" }
        return ToolOutcome(value: .object(object), count: hits.count, note: note)
    }

    /// 算一条查询向量。**四道门，顺序有意义**，前三道任意一道命中就
    /// **一次模型调用都不发**（4.3.2 T15：模型未装 / 开关关 / 锁定时零模型调用）：
    ///
    ///  1. `retrieval.vectorsEnabled` 关着（默认关，D8 的条件 1）→ `disabled`；
    ///  2. 没有注入嵌入器（模型没装 / app 没接线 / `brosis-store serve`）→ `no_embedder`；
    ///  3. 查询带字段前缀（`app:` / `host:` / …）→ `field_prefix`：
    ///     `Store.search` 对这类查询本来就直接返回、不走向量通道，算了也是白算；
    ///  4. 嵌入器自己说这次算不出（正在卸载 / 模型目录没了）→ `unavailable`。
    ///
    /// **锁定**那一道不在这里：`MCPGate` 在 `locked` / `paused` 时根本不会把调用交到这一层
    /// （3.5），所以锁着的时候连 `runSearch` 都进不来，更谈不上调模型。
    /// 这条由 `QueryEmbedderTests.testLockedGateNeverTouchesTheModel` 钉住。
    ///
    /// 出错不算失败：记 `error:<原因>`，检索照常走前三条通道（3.11 降级表）。
    private func queryEmbedding(for q: String) -> (vector: [Float]?, timing: QueryEmbedTiming) {
        guard store.retrieval.vectorsEnabled else { return (nil, QueryEmbedTiming(source: "disabled")) }
        guard let embedder = queryEmbedder else { return (nil, QueryEmbedTiming(source: "no_embedder")) }
        guard QueryRouter.parseField(q).field == nil else {
            return (nil, QueryEmbedTiming(source: "field_prefix"))
        }
        let t0 = Date()
        do {
            guard let vector = try embedder.queryVector(for: q) else {
                return (nil, QueryEmbedTiming(source: "unavailable",
                                              elapsedMS: Date().timeIntervalSince(t0) * 1000))
            }
            return (vector, QueryEmbedTiming(source: "embedder",
                                             elapsedMS: Date().timeIntervalSince(t0) * 1000,
                                             dimension: vector.count))
        } catch {
            return (nil, QueryEmbedTiming(source: "error:\(error)",
                                          elapsedMS: Date().timeIntervalSince(t0) * 1000))
        }
    }

    // MARK: - get_evidence

    private func runEvidence(_ args: [String: JSONValue], grant: Grant) throws -> ToolOutcome {
        guard let raw = args["ids"]?.arrayValue, !raw.isEmpty else {
            throw MCPBadArgument(message: "get_evidence 需要非空的 ids 数组")
        }
        let ids = raw.compactMap(\.intValue)
        guard ids.count == raw.count else {
            throw MCPBadArgument(message: "ids 里有不是整数的元素")
        }
        guard ids.count <= options.maxEvidenceIDs else {
            throw MCPBadArgument(message: "一次最多展开 \(options.maxEvidenceIDs) 条证据，收到 \(ids.count) 条")
        }
        let neighbors = min(max(0, Int(args["neighbors"]?.intValue ?? 2)), 10)
        // grant 的应用白名单、时间窗、字段级别都在 core 的 getEvidence 里执行（T3 已实测）——
        // **包括 items[].before / after 这两串出现上下文**：它们带 bundle id 与窗口标题，
        // 不按白名单过滤就等于把白名单外的应用漏出去（M1 第一轮验收抓到的口子）。
        let result = try store.getEvidence(ids: ids, grant: grant, neighbors: neighbors)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var object = try JSONValue(encoding: result).objectValue ?? [:]
        object["grant"] = grantBlock(grant, windowStart: now - Int64(grant.timeWindowDays) * 86_400_000,
                                     filtered: !grant.apps.contains("*"),
                                     droppedByGrant: result.deniedByGrant.count
                                                   + result.droppedNeighbors)
        object["redacted"] = .bool(grant.fields == .summary)
        return ToolOutcome(value: .object(object), count: result.items.count,
                           note: "missing=\(result.missing.count) denied=\(result.deniedByGrant.count)"
                               + " neighbors_dropped=\(result.droppedNeighbors)"
                               + " fields=\(grant.fields.rawValue)")
    }

    // MARK: - get_context

    private func runContext(_ args: [String: JSONValue], grant: Grant, windowStart: Int64,
                            scoped: Bool, calendar: DayCalendar) throws -> ToolOutcome {
        var hours = max(1, Int(args["hours"]?.intValue ?? 24))
        // 时间窗是硬上界：grant 给 30 天，就问不出 90 天的上下文。
        let cappedHours = grant.timeWindowDays * 24
        let clamped = hours > cappedHours
        hours = min(hours, cappedHours)
        let maxTokens = min(max(50, Int(args["max_tokens"]?.intValue ?? 2000)), options.maxContextTokens)

        let bundle = try store.getContext(hours: hours, maxTokens: maxTokens)
        let redact = grant.fields == .summary

        var apps = bundle.apps
        var sessions = bundle.sessions
        var snippets = bundle.snippets
        var dropped = 0
        if scoped {
            let keptApps = apps.filter { grant.allows(app: $0.key) }
            dropped += apps.count - keptApps.count
            apps = keptApps
            sessions = sessions.filter { grant.allows(app: $0.appBundleID) }
            let keptSnippets = snippets.filter { grant.allows(app: $0.appBundleID) }
            dropped += snippets.count - keptSnippets.count
            snippets = keptSnippets
        }
        if redact {
            // fields = summary：正文片段按摘要口径截到 ≤ 100 token（3.6「默认 summary」）。
            let budget = store.retrieval.summaryTokenBudget
            snippets = snippets.map {
                var s = $0
                s.text = TokenBudget.truncate($0.text, toTokens: budget)
                s.tokens = TokenBudget.tokens(of: s.text)
                return s
            }
        }

        var object = try JSONValue(encoding: bundle).objectValue ?? [:]
        if scoped || redact {
            // `text` 是 core 拼好的整段上下文，裁剪之后必须重拼，不能把没过滤的那份发出去。
            let text = Self.contextText(hours: hours, start: bundle.start, end: bundle.end,
                                        apps: apps, sessions: sessions, snippets: snippets,
                                        calendar: calendar)
            object["apps"] = try JSONValue(encoding: apps)
            object["sessions"] = try JSONValue(encoding: sessions)
            object["snippets"] = try JSONValue(encoding: snippets)
            object["text"] = .string(text)
            object["usedTokens"] = .int(Int64(TokenBudget.tokens(of: text)))
        }
        object["hoursClampedByGrant"] = .bool(clamped)
        object["redactedByGrant"] = .bool(redact)
        object["grant"] = grantBlock(grant, windowStart: windowStart,
                                     filtered: scoped, droppedByGrant: dropped)
        return ToolOutcome(value: .object(object), count: snippets.count,
                           note: "hours=\(hours) tokens=\(maxTokens)"
                               + (scoped ? " grant_filtered=\(dropped)" : "")
                               + (redact ? " redacted" : ""))
    }

    /// 与 `Store.getContext` 里那段拼串**同一个格式**（应用行取前 8 条）。
    /// 裁剪之后要重拼，格式必须一致，否则同一个库、两份 grant 会给出两种排版。
    static func contextText(hours: Int, start: Int64, end: Int64, apps: [LedgerEntry],
                            sessions: [SessionRow], snippets: [ContextSnippet],
                            calendar: DayCalendar) -> String {
        var lines: [String] = []
        lines.append("[窗口] \(calendar.stamp(start)) — \(calendar.stamp(end))（\(hours) h）")
        for a in apps.prefix(8) {
            lines.append(String(format: "[应用] %@ dwell %.0fs active %.0fs unknown %.0fs 切换 %d 次 观察 %d 条",
                                a.name ?? a.key, a.dwellS, a.activeS, a.unknownS,
                                a.switches, a.observations))
        }
        lines.append("[会话] \(sessions.count) 段，打断 \(sessions.reduce(0) { $0 + $1.interruptions }) 次")
        for s in snippets {
            lines.append("[\(calendar.stamp(s.ts)) \(s.appBundleID ?? "?")] " + s.text)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - get_timeline

    private func runTimeline(_ args: [String: JSONValue], grant: Grant,
                             windowStart: Int64, scoped: Bool) throws -> ToolOutcome {
        let calendar = DayCalendar(store.retrieval.timeZone)
        guard let askedStart = try Self.time(args["start"], field: "start", calendar: calendar),
              let end = try Self.time(args["end"], field: "end", calendar: calendar) else {
            throw MCPBadArgument(message: "get_timeline 需要 start 与 end")
        }
        let start = max(askedStart, windowStart)
        guard end > start else {
            throw MCPDeniedByGrant(message: "区间整体落在 grant 的时间窗（\(grant.timeWindowDays) 天）之外")
        }
        let granularity = TimelineGranularity(rawValue: args["granularity"]?.stringValue ?? "day")
        guard let granularity else {
            throw MCPBadArgument(message: "granularity 只能是 hour / day / week")
        }
        let span = Double(end - start)
        let bucketMS: Double = granularity == .hour ? 3_600_000
            : (granularity == .day ? 86_400_000 : 604_800_000)
        guard span / bucketMS <= Double(options.maxTimelineBuckets) else {
            throw MCPBadArgument(message: "区间太长：\(granularity.rawValue) 粒度下超过 "
                                        + "\(options.maxTimelineBuckets) 个桶，请缩小区间或换粒度")
        }

        let timeline = try store.getTimeline(start: start, end: end, granularity: granularity)
        var object = try JSONValue(encoding: timeline).objectValue ?? [:]
        var dropped = 0
        if scoped {
            var buckets: [TimelineBucket] = []
            for var bucket in timeline.buckets {
                let kept = bucket.apps.filter { grant.allows(app: $0.key) }
                dropped += bucket.apps.count - kept.count
                bucket.apps = kept
                // 汇总量按**留下的应用**重算，不能把全库的数字发出去。
                bucket.dwellS = kept.reduce(0) { $0 + $1.dwellS }
                bucket.activeS = kept.reduce(0) { $0 + $1.activeS }
                bucket.unknownS = kept.reduce(0) { $0 + $1.unknownS }
                bucket.observations = kept.reduce(0) { $0 + $1.observations }
                bucket.switches = kept.reduce(0) { $0 + $1.switches }
                bucket.topApp = kept.max(by: { $0.dwellS < $1.dwellS })?.key
                // 区间并集算不回来（它要原始会话区间），直接置 0 并在下面写明被丢掉了。
                bucket.onlineUnionS = 0
                buckets.append(bucket)
            }
            object["buckets"] = try JSONValue(encoding: buckets)
            object["droppedFields"] = .array([.string("buckets[].onlineUnionS")])
        }
        object["appliedStart"] = .int(start)
        object["grant"] = grantBlock(grant, windowStart: windowStart,
                                     filtered: scoped, droppedByGrant: dropped)
        return ToolOutcome(value: .object(object), count: timeline.buckets.count,
                           note: "granularity=\(granularity.rawValue)"
                               + (scoped ? " grant_filtered=\(dropped)" : ""))
    }

    // MARK: - get_day_ledger

    private func runDayLedger(_ args: [String: JSONValue], grant: Grant,
                              windowStart: Int64, scoped: Bool) throws -> ToolOutcome {
        guard let date = args["date"]?.stringValue, !date.isEmpty else {
            throw MCPBadArgument(message: "get_day_ledger 需要 date（YYYY-MM-DD）")
        }
        let ledger = try store.getDayLedger(date: date)
        guard ledger.end > windowStart else {
            throw MCPDeniedByGrant(message: "\(date) 早于 grant 的时间窗（\(grant.timeWindowDays) 天）")
        }
        var object = try JSONValue(encoding: ledger).objectValue ?? [:]
        // 时间窗边界那一天的口径：台账是**整个自然日**的预聚合（`ledgers` 表按天存），
        // 切不成半天，所以 windowStart 落在这一天里面时，窗口之前那几小时的观察数与时长
        // 也在返回的数字里。search / get_timeline / get_item 是逐条查询，能把 start 抬到
        // windowStart，这里做不到——如实标出来，不假装裁过（README 第 10 节也写了）。
        object["coversBeforeWindowStart"] = .bool(ledger.start < windowStart)
        var dropped = 0
        var dropList: [String] = []
        if scoped {
            let kept = ledger.apps.filter { grant.allows(app: $0.key) }
            dropped = ledger.apps.count - kept.count
            object["apps"] = try JSONValue(encoding: kept)
            object["totalDwellS"] = .double(kept.reduce(0) { $0 + $1.dwellS })
            object["totalActiveS"] = .double(kept.reduce(0) { $0 + $1.activeS })
            object["totalUnknownS"] = .double(kept.reduce(0) { $0 + $1.unknownS })
            object["focusDwellS"] = .double(kept.reduce(0) { $0 + $1.dwellS })
            object["switches"] = .int(Int64(kept.reduce(0) { $0 + $1.switches }))
            object["observations"] = .int(Int64(kept.reduce(0) { $0 + $1.observations }))
            // 站点 / 文件两张表按 URL 与路径聚合，回不到"是哪个应用打开的"，
            // 白名单生效时整段丢掉；会话数、打断数、区间并集、每屏 dwell 同理算不回来。
            let droppedFields = ["sites", "files", "onlineUnionS", "perDisplayDwellS",
                                 "sessions", "interruptions", "evidence"]
            for key in droppedFields { object.removeValue(forKey: key) }
            dropList = droppedFields
        }
        // T12 的叙述标注：键永远在，过期不给正文，白名单生效时整段丢掉。
        dropList += Self.attachNarrative(&object, narrative: ledger.narrative,
                                         model: ledger.model, meta: ledger.narrativeMeta,
                                         isStale: ledger.narrativeIsStale, scoped: scoped)
        if !dropList.isEmpty { object["droppedFields"] = .array(dropList.map { .string($0) }) }
        object["grant"] = grantBlock(grant, windowStart: windowStart,
                                     filtered: scoped, droppedByGrant: dropped)
        let count = (object["apps"]?.arrayValue?.count) ?? ledger.apps.count
        return ToolOutcome(value: .object(object), count: count,
                           note: "date=\(date)"
                               + (ledger.narrative == nil ? "" : " narrative")
                               + (scoped ? " grant_filtered=\(dropped)" : ""))
    }

    // MARK: - get_week_ledger（M2 / T14）

    private func runWeekLedger(_ args: [String: JSONValue], grant: Grant,
                               windowStart: Int64, scoped: Bool) throws -> ToolOutcome {
        guard let week = args["week"]?.stringValue, !week.isEmpty else {
            throw MCPBadArgument(message: "get_week_ledger 需要 week（YYYY-Www 或周内任意一天的 YYYY-MM-DD）")
        }
        let ledger: WeekLedger
        do {
            ledger = try store.getWeekLedger(weekStart: week)
        } catch let e as StoreError {
            throw MCPBadArgument(message: "\(e)")
        }
        guard ledger.end > windowStart else {
            throw MCPDeniedByGrant(message: "\(ledger.week) 早于 grant 的时间窗（\(grant.timeWindowDays) 天）")
        }
        var object = try JSONValue(encoding: ledger).objectValue ?? [:]
        // 与 get_day_ledger 同一条口径：台账是**整周**的预聚合，切不成半周。
        // 窗口起点落在这一周里面时，窗口之前那几天的数字也在返回值里，如实标出来。
        object["coversBeforeWindowStart"] = .bool(ledger.start < windowStart)
        var dropped = 0
        var dropList: [String] = []
        if scoped {
            let kept = ledger.apps.filter { grant.allows(app: $0.key) }
            dropped = ledger.apps.count - kept.count
            object["apps"] = try JSONValue(encoding: kept)
            object["totalDwellS"] = .double(kept.reduce(0) { $0 + $1.dwellS })
            object["totalActiveS"] = .double(kept.reduce(0) { $0 + $1.activeS })
            object["totalUnknownS"] = .double(kept.reduce(0) { $0 + $1.unknownS })
            object["focusDwellS"] = .double(kept.reduce(0) { $0 + $1.dwellS })
            object["switches"] = .int(Int64(kept.reduce(0) { $0 + $1.switches }))
            object["observations"] = .int(Int64(kept.reduce(0) { $0 + $1.observations }))
            // 站点 / 文件按 URL 与路径聚合、按天分布与会话数按整条观察流算，
            // 都回不到"是哪个应用"，白名单生效时整段丢掉（与 get_day_ledger 同一处理）。
            let droppedFields = ["sites", "files", "onlineUnionS", "perDisplayDwellS",
                                 "sessions", "interruptions", "evidence", "dayTotals",
                                 "activeDays"]
            for key in droppedFields { object.removeValue(forKey: key) }
            dropList = droppedFields
        }
        dropList += Self.attachNarrative(&object, narrative: ledger.narrative,
                                         model: ledger.model, meta: ledger.narrativeMeta,
                                         isStale: ledger.narrativeIsStale, scoped: scoped)
        if !dropList.isEmpty { object["droppedFields"] = .array(dropList.map { .string($0) }) }
        object["grant"] = grantBlock(grant, windowStart: windowStart,
                                     filtered: scoped, droppedByGrant: dropped)
        let count = (object["apps"]?.arrayValue?.count) ?? ledger.apps.count
        return ToolOutcome(value: .object(object), count: count,
                           note: "week=\(ledger.week) recomputed=\(ledger.daysRecomputed.count)"
                               + " cache=\(ledger.servedFromCache)"
                               + (ledger.narrative == nil ? "" : " narrative")
                               + (scoped ? " grant_filtered=\(dropped)" : ""))
    }

    // MARK: - get_patterns（M2 / T14）

    private func runPatterns(_ args: [String: JSONValue], grant: Grant,
                             windowStart: Int64, scoped: Bool) throws -> ToolOutcome {
        let calendar = DayCalendar(store.retrieval.timeZone)
        guard let askedStart = try Self.time(args["start"], field: "start", calendar: calendar),
              let end = try Self.time(args["end"], field: "end", calendar: calendar) else {
            throw MCPBadArgument(message: "get_patterns 需要 start 与 end")
        }
        // 时间窗是硬下界（与 search / get_timeline 同一条规矩）。
        let start = max(askedStart, windowStart)
        guard end > start else {
            throw MCPDeniedByGrant(message: "区间整体落在 grant 的时间窗（\(grant.timeWindowDays) 天）之外")
        }
        let days = Double(end - start) / 86_400_000.0
        guard days <= Double(options.maxPatternDays) else {
            throw MCPBadArgument(message: "区间太长：get_patterns 一次最多 \(options.maxPatternDays) 天，"
                                        + "收到 \(String(format: "%.1f", days)) 天")
        }

        var patternOptions = PatternOptions()
        if let v = args["focus_block_minutes"]?.doubleValue {
            guard v >= 1, v <= 600 else {
                throw MCPBadArgument(message: "focus_block_minutes 要在 1…600 之间")
            }
            patternOptions.focusBlockMinMinutes = v
        }
        if let v = args["max_transitions"]?.intValue {
            patternOptions.maxTransitions = min(max(1, Int(v)), 200)
        }
        if let v = args["max_apps"]?.intValue {
            patternOptions.maxApps = min(max(1, Int(v)), 200)
        }

        // 白名单**下推到 core**：热力图 / 切换对 / 工作块都要在"只剩白名单内应用"的
        // 观察流上重算，事后裁字段是算不回来的（`ActivityPatterns.appFilter` 会标出来）。
        let patterns = try store.getPatterns(start: start, end: end,
                                             apps: scoped ? grant.apps : nil,
                                             options: patternOptions)
        var object = try JSONValue(encoding: patterns).objectValue ?? [:]
        object["appliedStart"] = .int(start)
        object["grant"] = grantBlock(grant, windowStart: windowStart,
                                     filtered: scoped, droppedByGrant: 0)
        if scoped {
            object["scopeNote"] = .string(
                "白名单生效：热力图、切换对、连续工作块都在只含白名单应用的观察流上重算，"
                + "因此块更碎、切换对更少——这是换了输入，不是把结果裁短。")
        }
        return ToolOutcome(value: .object(object), count: patterns.heatmap.count,
                           note: "days=\(String(format: "%.2f", patterns.spanDays))"
                               + " obs=\(patterns.observations)"
                               + " blocks=\(patterns.focus.count)"
                               + (scoped ? " app_filter=\(grant.apps.count)" : ""))
    }

    // MARK: - recent_activity（M2 / T14）

    private func runRecentActivity(_ args: [String: JSONValue], grant: Grant,
                                   scoped: Bool) throws -> ToolOutcome {
        var minutes = max(1, Int(args["minutes"]?.intValue ?? 30))
        // 时间窗是硬上界：grant 给 30 天，就问不出 90 天前的"最近活动"。
        let cappedMinutes = grant.timeWindowDays * 1440
        let clamped = minutes > cappedMinutes
        minutes = min(minutes, cappedMinutes)
        let maxItems = min(max(0, Int(args["max_items"]?.intValue ?? 20)), options.maxRecentItems)

        let recent = try store.recentActivity(minutes: minutes, maxItems: maxItems,
                                              apps: scoped ? grant.apps : nil)
        var object = try JSONValue(encoding: recent).objectValue ?? [:]
        object["minutesClampedByGrant"] = .bool(clamped)
        object["grant"] = grantBlock(grant, windowStart: recent.start,
                                     filtered: scoped, droppedByGrant: 0)
        // 3.6 的 fields 分级只管**原文**：这里每条都是 ≤ 100 token 的摘要（与 search 同口径），
        // 原文一律走 get_evidence，那里才按 fields 裁。说清楚，免得被读成"summary 也漏原文"。
        object["fieldsNote"] = .string(
            "items[].summary 是 ≤ \(recent.summaryTokenBudget) token 的摘要，与 search 的命中摘要同一口径；"
            + "原文只能经 get_evidence 展开，受 grant.fields 限制。")
        return ToolOutcome(value: .object(object), count: recent.items.count,
                           note: "minutes=\(minutes) items=\(recent.items.count)"
                               + "/\(recent.observations)"
                               + (clamped ? " clamped" : "")
                               + (scoped ? " app_filter=\(grant.apps.count)" : ""))
    }

    // MARK: - get_item

    private func runItem(_ args: [String: JSONValue], grant: Grant,
                         windowStart: Int64, scoped: Bool) throws -> ToolOutcome {
        let calendar = DayCalendar(store.retrieval.timeZone)
        let given = ["url", "path", "app"].filter { args[$0]?.stringValue?.isEmpty == false }
        guard given.count == 1 else {
            throw MCPBadArgument(message: "get_item 需要 url / path / app 三者给且只给一个，收到 \(given.count) 个")
        }
        let key = args[given[0]]!.stringValue!
        let selector: ItemSelector
        switch given[0] {
        case "url":  selector = .url(key)
        case "path": selector = .path(key)
        default:     selector = .app(key)
        }
        if case .app(let bundle) = selector, !grant.allows(app: bundle) {
            throw MCPDeniedByGrant(message: "grant 的应用白名单不含 \(bundle)")
        }
        let asked = try Self.time(args["start"], field: "start", calendar: calendar)
        let start = max(asked ?? windowStart, windowStart)
        let end = try Self.time(args["end"], field: "end", calendar: calendar)

        let summary = try store.getItem(selector, start: start, end: end)
        var object = try JSONValue(encoding: summary).objectValue ?? [:]
        var dropped = 0
        if scoped, case .app = selector {
            // 单个应用的汇总本来就只有这个应用，白名单已经放行，不用裁。
        } else if scoped {
            let kept = summary.apps.filter { grant.allows(app: $0.key) }
            dropped = summary.apps.count - kept.count
            object["apps"] = try JSONValue(encoding: kept)
            object["observations"] = .int(Int64(kept.reduce(0) { $0 + $1.observations }))
            object["dwellS"] = .double(kept.reduce(0) { $0 + $1.dwellS })
            // 首末次、按天分布、标题样本、最近证据 id 都是跨应用聚合出来的，回不到单应用，
            // 白名单生效时丢掉（要这些就用 get_item(app) 或 search + get_evidence）。
            let droppedFields = ["firstSeen", "lastSeen", "days", "titles", "recentEvidenceIDs"]
            for k in droppedFields { object.removeValue(forKey: k) }
            object["droppedFields"] = .array(droppedFields.map { .string($0) })
        }
        object["appliedStart"] = .int(start)
        object["grant"] = grantBlock(grant, windowStart: windowStart,
                                     filtered: scoped, droppedByGrant: dropped)
        return ToolOutcome(value: .object(object), count: summary.observations,
                           note: "kind=\(selector.kind)" + (scoped ? " grant_filtered=\(dropped)" : ""))
    }

    // MARK: - admin（grant 管理）

    private func handleAdmin(_ call: IPCCall, since t0: Date) -> IPCResponse {
        let request = call.request
        let name = request.name ?? ""
        guard let command = AdminCommand(rawValue: name) else {
            writeAudit(call, tool: name, params: "-", decision: .unknownTool, count: 0,
                       note: "admin", since: t0)
            return IPCResponse(id: request.id, code: .unknownTool,
                               message: "不认识的管理命令 \(name)")
        }
        // 服务端在连接建立时已经查过 uid 与代码签名（`IPCServer.serve`），
        // 这里再核一次：admin 能改授权范围，不能靠单点判定。
        guard call.peer.uid == getuid(), call.peer.codeSigningVerified else {
            writeAudit(call, tool: name, params: "-", decision: .unauthorizedPeer, count: 0,
                       note: call.peer.codeSigningNote, since: t0)
            return IPCResponse(id: request.id, code: .unauthorizedPeer,
                               message: "管理命令只接受同 uid 且通过代码签名校验的对端")
        }

        do {
            let outcome = try runAdmin(command, args: request.args)
            writeAudit(call, tool: name, params: outcome.note ?? "-", decision: .ok,
                       count: outcome.count, note: "admin", since: t0)
            return IPCResponse(id: request.id, result: outcome.value)
        } catch let e as MCPBadArgument {
            writeAudit(call, tool: name, params: "-", decision: .badRequest, count: 0,
                       note: e.message, since: t0)
            return IPCResponse(id: request.id, code: .badRequest, message: e.message)
        } catch {
            writeAudit(call, tool: name, params: "-", decision: .error, count: 0,
                       note: "\(error)", since: t0)
            return IPCResponse(id: request.id, code: .internalError, message: "管理命令失败：\(error)")
        }
    }

    private func runAdmin(_ command: AdminCommand, args: [String: JSONValue]) throws -> ToolOutcome {
        switch command {
        case .grantList:
            let grants = try store.allGrants()
            return ToolOutcome(value: .object([
                "grants": try JSONValue(encoding: grants),
                "count": .int(Int64(grants.count)),
                "note": .string("mode = strict_local 只是标记 + 审计，系统无法技术上验证客户端是否外发（3.6）"),
            ]), count: grants.count, note: nil)

        case .grantAdd:
            guard let clientID = args["client_id"]?.stringValue?
                .trimmingCharacters(in: .whitespaces), !clientID.isEmpty else {
                throw MCPBadArgument(message: "grant add 需要 client_id")
            }
            let mode = try Self.enumValue(args["mode"], GrantMode.self, default: .strictLocal,
                                          field: "mode")
            let fields = try Self.enumValue(args["fields"], GrantFields.self, default: .summary,
                                            field: "fields")
            var apps = args["apps"]?.arrayValue?.compactMap(\.stringValue) ?? ["*"]
            if apps.isEmpty { apps = ["*"] }
            let window = Int(args["time_window_days"]?.intValue ?? 30)
            guard window > 0, window <= 3650 else {
                throw MCPBadArgument(message: "time_window_days 要在 1…3650 之间")
            }
            let grant = Grant(clientID: clientID, mode: mode, apps: apps,
                              timeWindowDays: window, fields: fields)
            try store.setGrant(grant)
            return ToolOutcome(value: .object([
                "grant": try JSONValue(encoding: grant),
                "written": .bool(true),
            ]), count: 1, note: "client=\(clientID) fields=\(fields.rawValue) apps=\(apps.count)")

        case .grantRemove:
            guard let clientID = args["client_id"]?.stringValue, !clientID.isEmpty else {
                throw MCPBadArgument(message: "grant remove 需要 client_id")
            }
            let removed = try store.removeGrant(clientID: clientID)
            return ToolOutcome(value: .object([
                "client_id": .string(clientID), "removed": .bool(removed),
            ]), count: removed ? 1 : 0, note: "client=\(clientID)")

        case .auditTail:
            let limit = min(max(1, Int(args["limit"]?.intValue ?? 20)), 500)
            let rows = try store.mcpAuditTail(limit: limit,
                                              clientID: args["client_id"]?.stringValue)
            return ToolOutcome(value: .object([
                "rows": try JSONValue(encoding: rows),
                "count": .int(Int64(rows.count)),
                "total": .int(Int64(try store.mcpAuditCount())),
            ]), count: rows.count, note: nil)

        case .status:
            let build = try store.buildInfo()
            return ToolOutcome(value: .object([
                "server": .string(serverInfo),
                "state": .string("unlocked"),
                "schemaVersion": .int(Int64(Schema.version)),
                "deviceID": .string(store.deviceID),
                "cipherVersion": .string(build.cipherVersion),
                "grants": .int(Int64(try store.allGrants().count)),
                "auditRows": .int(Int64(try store.mcpAuditCount())),
                "timeZone": .string(store.retrieval.timeZone.identifier),
                "tools": .array(MCPTool.allCases.map { .string($0.rawValue) }),
            ]), count: 1, note: nil)
        }
    }

    // MARK: - 审计

    private func writeAudit(_ call: IPCCall, tool: String, params: String,
                            decision: MCPDecision, count: Int, note: String?, since t0: Date) {
        let row = MCPAuditRow(clientID: call.request.client, op: call.request.op.rawValue,
                              tool: tool, params: params, decision: decision,
                              resultCount: count, peer: call.peer.auditDescription,
                              elapsedMS: Date().timeIntervalSince(t0) * 1000, note: note)
        _ = store.appendMCPAudit(row)
    }

    /// 台账的**叙述标注**透传（3.7「输出与台账分开标注」，T12 的 schema v6 三列）。
    ///
    /// 三件事：
    /// ① 键**永远在**，没有叙述时显式给 `null`——`JSONEncoder` 会把 nil 的可选字段整键省掉，
    ///    客户端就没法区分"没跑叙述"和"这个版本还没有这个字段"。
    /// ② `narrativeIsStale` 为真（叙述对不上现在这份台账）时**不把正文交出去**，
    ///    只留标记：一段描述另一版台账的话比没有更糟。
    /// ③ **应用白名单生效时整段丢掉**：叙述是照整份台账写的，里面可能点名白名单之外的应用，
    ///    按 key 裁字段裁不掉它（这是 M1 第一轮验收在 `get_evidence` 的邻居上抓到过的同一类口子）。
    static func attachNarrative(_ object: inout [String: JSONValue],
                                narrative: String?, model: String?,
                                meta: NarrativeMeta?, isStale: Bool,
                                scoped: Bool) -> [String] {
        object.removeValue(forKey: "narrativeMeta")
        guard !scoped else {
            object["narrative"] = .null
            object["model"] = .null
            object["narrativeMeta"] = .null
            object["narrativeIsStale"] = .bool(false)
            return ["narrative", "model", "narrativeMeta"]
        }
        let usable = !isStale
        object["narrative"] = (usable ? narrative.map { JSONValue.string($0) } : nil) ?? .null
        object["model"] = (usable ? model.map { JSONValue.string($0) } : nil) ?? .null
        object["narrativeMeta"] = (usable ? meta.flatMap { try? JSONValue(encoding: $0) } : nil) ?? .null
        object["narrativeIsStale"] = .bool(isStale)
        // 3.7：叙述是模型写的，台账是算出来的。这一条让客户端不必去猜哪个是哪个。
        object["narrativeGeneratedBy"] = (usable && narrative != nil) ? .string("model") : .null
        return []
    }

    /// 每个结果里都带一份 grant 说明：客户端拿到的是"被谁按什么范围裁过的数据"，
    /// 这一点不该靠人去猜。
    private func grantBlock(_ grant: Grant, windowStart: Int64,
                            filtered: Bool, droppedByGrant: Int) -> JSONValue {
        .object([
            "client": .string(grant.clientID),
            "mode": .string(grant.mode.rawValue),
            "fields": .string(grant.fields.rawValue),
            "apps": .array(grant.apps.map { .string($0) }),
            "timeWindowDays": .int(Int64(grant.timeWindowDays)),
            "windowStart": .int(windowStart),
            "filteredByGrant": .bool(filtered),
            "droppedByGrant": .int(Int64(droppedByGrant)),
        ])
    }

    // MARK: - 参数解析

    /// 时间参数：Unix 毫秒（整数或数字串）、ISO 8601、或 `YYYY-MM-DD`（按服务端时区取当天 00:00）。
    static func time(_ value: JSONValue?, field: String, calendar: DayCalendar) throws -> Int64? {
        guard let value, !value.isNull else { return nil }
        if case .int(let ms) = value { return ms }
        if case .double(let ms) = value { return Int64(ms) }
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw MCPBadArgument(message: "\(field) 只能是 Unix 毫秒或 ISO 8601 字符串")
        }
        if let ms = Int64(text) { return ms }
        if text.count == 10, text.contains("-"), let bounds = try? calendar.dayBounds(text) {
            return bounds.start
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        throw MCPBadArgument(message: "无法解析 \(field)：\(text)（要 Unix 毫秒、ISO 8601 或 YYYY-MM-DD）")
    }

    static func enumValue<T: RawRepresentable & CaseIterable>(
        _ value: JSONValue?, _ type: T.Type, default fallback: T, field: String
    ) throws -> T where T.RawValue == String {
        guard let text = value?.stringValue, !text.isEmpty else { return fallback }
        guard let parsed = T(rawValue: text) else {
            let all = T.allCases.map(\.rawValue).joined(separator: " / ")
            throw MCPBadArgument(message: "\(field) 只能是 \(all)，收到 \(text)")
        }
        return parsed
    }

    /// 参数摘要：**只记形状，不记正文，也不记查询串本身**。
    /// 查询串给「字符数 + SHA-256 前 8 位十六进制」——同一条查询在审计里能对上，内容不落库。
    static func parameterSummary(tool: MCPTool, args: [String: JSONValue]) -> String {
        func digest(_ text: String) -> String {
            TextPipeline.sha256(text).prefix(4).map { String(format: "%02x", $0) }.joined()
        }
        var parts: [String] = []
        switch tool {
        case .search:
            let q = args["q"]?.stringValue ?? ""
            parts.append("q_chars=\(q.count)")
            parts.append("q_sha=\(digest(q))")
            parts.append("limit=\(args["limit"]?.intValue.map(String.init) ?? "-")")
            if let app = args["app"]?.stringValue { parts.append("app=\(app)") }
        case .getEvidence:
            parts.append("ids=\(args["ids"]?.arrayValue?.count ?? 0)")
            parts.append("neighbors=\(args["neighbors"]?.intValue.map(String.init) ?? "-")")
        case .getContext:
            parts.append("hours=\(args["hours"]?.intValue.map(String.init) ?? "-")")
            parts.append("max_tokens=\(args["max_tokens"]?.intValue.map(String.init) ?? "-")")
        case .getTimeline:
            parts.append("granularity=\(args["granularity"]?.stringValue ?? "-")")
        case .getDayLedger:
            parts.append("date=\(args["date"]?.stringValue ?? "-")")
        case .getWeekLedger:
            parts.append("week=\(args["week"]?.stringValue ?? "-")")
        case .getPatterns:
            parts.append("focus_min=\(args["focus_block_minutes"]?.doubleValue.map { String(format: "%.0f", $0) } ?? "-")")
            parts.append("max_transitions=\(args["max_transitions"]?.intValue.map(String.init) ?? "-")")
        case .recentActivity:
            parts.append("minutes=\(args["minutes"]?.intValue.map(String.init) ?? "-")")
            parts.append("max_items=\(args["max_items"]?.intValue.map(String.init) ?? "-")")
        case .getItem:
            if let app = args["app"]?.stringValue {
                parts.append("kind=app key=\(app)")            // bundle id 不是隐私内容
            } else if let url = args["url"]?.stringValue {
                parts.append("kind=url key_chars=\(url.count) key_sha=\(digest(url))")
            } else if let path = args["path"]?.stringValue {
                parts.append("kind=path key_chars=\(path.count) key_sha=\(digest(path))")
            } else {
                parts.append("kind=-")
            }
        }
        for key in ["start", "end"] where args[key] != nil && args[key]?.isNull == false {
            parts.append("\(key)=given")
        }
        return parts.joined(separator: " ")
    }
}
