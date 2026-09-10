import Foundation

// =============================================================================
// 证据展开、对象汇总、上下文（计划 3.6 的 get_evidence / get_item / get_context）
//
// 删除后的口径（3.8 验收）：被用户删除（墓碑）或被配额过期物理删除的观察，
// 这三个入口一律**不返回任何内容**，只在 `missing` 里回一个 id。
// =============================================================================

extension Store {

    // MARK: - grants（3.6 授权，MCP 进程 R2 才有；本包提供读写与判定）

    public func setGrant(_ grant: Grant) throws {
        try withLock { conn in
            let apps = String(decoding: try JSONSerialization.data(withJSONObject: grant.apps,
                                                                   options: []), as: UTF8.self)
            try conn.run("""
                INSERT INTO grants(client_id, mode, apps, time_window, fields, created_at)
                VALUES (?,?,?,?,?,?)
                ON CONFLICT(client_id) DO UPDATE SET mode = excluded.mode, apps = excluded.apps,
                    time_window = excluded.time_window, fields = excluded.fields;
                """, [.text(grant.clientID), .text(grant.mode.rawValue), .text(apps),
                      .int(Int64(grant.timeWindowDays)), .text(grant.fields.rawValue),
                      .int(grant.createdAt)])
        }
    }

    public func grant(clientID: String) throws -> Grant? {
        try withLock { conn in try grantRow(clientID: clientID, conn: conn) }
    }

    func grantRow(clientID: String, conn: SQLiteConnection) throws -> Grant? {
        let st = try conn.prepare("""
            SELECT client_id, mode, apps, time_window, fields, created_at
              FROM grants WHERE client_id = ?;
            """)
        defer { st.finalize() }
        try st.bind([.text(clientID)])
        guard try st.step(),
              let id = st.text(0),
              let mode = st.text(1).flatMap(GrantMode.init(rawValue:)),
              let fields = st.text(4).flatMap(GrantFields.init(rawValue:)) else { return nil }
        let apps = (st.text(2)?.data(using: .utf8))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? ["*"]
        return Grant(clientID: id, mode: mode, apps: apps,
                     timeWindowDays: Int(st.int(3) ?? 30), fields: fields,
                     createdAt: st.int(5) ?? 0)
    }

    // MARK: - get_evidence(ids)

    /// 3.6 的 `get_evidence(ids)`：返回原文（`text_versions`）与出现上下文。
    ///
    /// - Parameter grant: 字段级限制的钩子（3.6）。`nil` = 本地可信调用方，不限制；
    ///   给了就按应用白名单 + 时间窗过滤，且 `fields = .summary` 时**不返回原文**。
    ///   MCP 进程本身归 R2，这里只把口子留好并实测。
    /// - Parameter neighbors: 出现上下文取前后各几条（同一块屏的相邻观察）。
    public func getEvidence(ids: [Int64], grant: Grant? = nil,
                            neighbors: Int = 2) throws -> EvidenceResult {
        let options = retrieval
        return try withLock { conn in
            guard !ids.isEmpty else { return EvidenceResult(items: [], missing: [], deniedByGrant: []) }
            let metas = try observationMetas(ids, conn: conn)
            let cal = DayCalendar(options.timeZone)
            let now = Int64(Date().timeIntervalSince1970 * 1000)

            var items: [EvidenceItem] = []
            var missing: [Int64] = []
            var denied: [Int64] = []
            var droppedNeighbors = 0
            // grant 的时间窗下界：证据本身与**出现上下文**都按它收，前面的相邻观察不能漏出去。
            let windowStart: Int64? = grant.map { now - Int64($0.timeWindowDays) * 86_400_000 }
            for id in ids {
                // observationMetas 已经把墓碑与物理删除的行滤掉了（deleted_at IS NULL）。
                guard let meta = metas[id] else { missing.append(id); continue }
                if let grant, let windowStart {
                    guard grant.allows(app: meta.appBundleID), meta.ts >= windowStart else {
                        denied.append(id); continue
                    }
                }
                let redacted = grant?.fields == .summary
                let occs = try occurrenceRows(observationID: id, includeText: !redacted, conn: conn)
                let full = redacted ? nil : occs.compactMap(\.text).joined(separator: "\n")
                let head = [meta.appName ?? meta.appBundleID ?? "?",
                            meta.windowTitle ?? meta.host ?? meta.filePath ?? "",
                            cal.stamp(meta.ts)].filter { !$0.isEmpty }.joined(separator: " · ")
                let body = try snippetSources([id], conn: conn)[id] ?? ""
                let summary = TokenBudget.truncate(
                    body.isEmpty ? head : head + " · " + body.replacingOccurrences(of: "\n", with: " "),
                    toTokens: options.summaryTokenBudget)
                items.append(EvidenceItem(
                    evidenceID: id, ts: meta.ts, displayID: meta.displayID,
                    appBundleID: meta.appBundleID, appName: meta.appName,
                    windowTitle: meta.windowTitle,
                    url: meta.canonicalURL ?? meta.rawLocator, host: meta.host,
                    filePath: meta.filePath, trigger: meta.trigger,
                    captureMethod: meta.captureMethod, completeness: meta.completeness,
                    sourceState: meta.sourceState, occurrences: occs, text: full, summary: summary,
                    before: try neighborRows(of: meta, before: true, limit: neighbors,
                                             grant: grant, windowStart: windowStart,
                                             cal: cal, conn: conn, dropped: &droppedNeighbors),
                    after: try neighborRows(of: meta, before: false, limit: neighbors,
                                            grant: grant, windowStart: windowStart,
                                            cal: cal, conn: conn, dropped: &droppedNeighbors),
                    redactedByGrant: redacted))
            }
            return EvidenceResult(items: items, missing: missing, deniedByGrant: denied,
                                  droppedNeighbors: droppedNeighbors)
        }
    }

    func occurrenceRows(observationID: Int64, includeText: Bool,
                        conn: SQLiteConnection) throws -> [EvidenceOccurrence] {
        let st = try conn.prepare("""
            SELECT oc.text_version_id, oc.ord, oc.region, tv.text, tv.byte_len,
                   oc.confidence, oc.note
              FROM occurrences oc
              JOIN text_versions tv ON tv.device_id = oc.device_id AND tv.id = oc.text_version_id
             WHERE oc.device_id = ? AND oc.observation_id = ? ORDER BY oc.ord;
            """)
        defer { st.finalize() }
        try st.bind([.text(deviceID), .int(observationID)])
        var out: [EvidenceOccurrence] = []
        while try st.step() {
            out.append(EvidenceOccurrence(textVersionID: st.int(0) ?? 0,
                                          ord: Int(st.int(1) ?? 0), region: st.text(2),
                                          text: includeText ? st.text(3) : nil,
                                          byteLen: Int(st.int(4) ?? 0),
                                          confidence: st.double(5), note: st.text(6)))
        }
        return out
    }

    /// 出现上下文：同一块屏上时间相邻的观察，只给摘要不给原文。
    ///
    /// **grant 在这里同样生效**：相邻观察带 bundle id 与窗口标题，
    /// 白名单外 / 时间窗外的行漏一条就等于绕过白名单（M1 第一轮验收抓到的就是这个口子）。
    /// 被丢掉的行不占 `limit` 的名额：多取几倍候选、过滤后再截到 `limit`，
    /// 只把丢掉的条数累加进 `dropped`（进 `EvidenceResult.droppedNeighbors`）。
    func neighborRows(of meta: ObservationMeta, before: Bool, limit: Int,
                      grant: Grant?, windowStart: Int64?, cal: DayCalendar,
                      conn: SQLiteConnection, dropped: inout Int) throws -> [EvidenceNeighbor] {
        guard limit > 0 else { return [] }
        let cmp = before ? "<" : ">"
        let order = before ? "DESC" : "ASC"
        // 白名单生效时才多取：`apps = ["*"]` 的常规路径行为与取回条数都不变。
        let scoped = grant.map { !$0.apps.contains("*") } ?? false
        let fetch = scoped ? min(limit * 8, 200) : limit
        var sql = """
            SELECT o.id, o.ts, a.bundle_id, a.name, w.title FROM observations o
              LEFT JOIN apps a ON a.id = o.app_id
              LEFT JOIN windows w ON w.id = o.window_id
             WHERE o.device_id = ? AND o.deleted_at IS NULL AND o.ts \(cmp) ?
               AND COALESCE(o.display_id, -1) = ?
            """
        var binds: [SQLValue] = [.text(deviceID), .int(meta.ts), .int(meta.displayID ?? -1)]
        // 时间窗直接压进 SQL（`before` 方向才可能越界，`after` 方向恒真，留着不碍事）。
        if let windowStart { sql += " AND o.ts >= ?"; binds.append(.int(windowStart)) }
        sql += " ORDER BY o.ts \(order), o.id \(order) LIMIT ?;"
        binds.append(.int(Int64(fetch)))
        let st = try conn.prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        var out: [EvidenceNeighbor] = []
        while out.count < limit, try st.step() {
            let bundle = st.text(2)
            if let grant, !grant.allows(app: bundle) { dropped += 1; continue }
            let ts = st.int(1) ?? 0
            let head = [st.text(3) ?? bundle ?? "?", st.text(4) ?? "", cal.stamp(ts)]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            out.append(EvidenceNeighbor(evidenceID: st.int(0) ?? 0, ts: ts,
                                        appBundleID: bundle, windowTitle: st.text(4),
                                        summary: TokenBudget.truncate(head, toTokens: 100)))
        }
        return before ? out.reversed() : out
    }

    // MARK: - get_item(url | path | app)

    /// 3.6 的 `get_item(url | path | app)`。全程两步式（E7 §10.1）。
    public func getItem(_ selector: ItemSelector, start: Int64? = nil, end: Int64? = nil,
                        recentLimit: Int = 20) throws -> ItemSummary {
        let options = retrieval
        return try withLock { conn in
            let cal = DayCalendar(options.timeZone)
            let field: String
            switch selector {
            case .url: field = "url"
            case .path: field = "path"
            case .app: field = "app"
            }
            // 第一步：小表取 id 与对象名。空集直接返回，别去碰 observations。
            let (objectIDs, objectNames, column) = try itemObjects(field: field,
                                                                   term: TextPipeline.foldForIndex(selector.key),
                                                                   conn: conn)
            guard !objectIDs.isEmpty else {
                return ItemSummary(kind: selector.kind, key: selector.key, matchedObjects: [],
                                   observations: 0, firstSeen: nil, lastSeen: nil, days: [:],
                                   apps: [], titles: [], recentEvidenceIDs: [], dwellS: 0)
            }
            // 第二步：**聚合全部在 SQL 里做**，不把行拉进 Swift。
            // 一个应用在 1 个月库里能有 6 万多条观察，逐行取回来（还要带标题、应用名）
            // 本轮实测比 SQL 聚合慢好几倍，而且大头是 Swift 侧逐行取字符串。
            var count = 0
            var firstSeen: Int64?
            var lastSeen: Int64?
            var days: [String: Int] = [:]
            var appAcc: [String: LedgerAccumulator] = [:]
            var titles: [String] = []
            var recent: [(Int64, Int64)] = []
            let appNames = try appMap(conn: conn)

            // 每个 chunk 的谓词与绑定值：下面两趟都用它。
            let chunks = objectIDs.chunked(into: 400)
            func predicate(_ chunk: [Int64]) -> (String, [SQLValue]) {
                var whereSQL = "o.device_id = ? AND o.\(column) IN (\(placeholders(chunk.count)))"
                    + " AND o.deleted_at IS NULL"
                var binds: [SQLValue] = [.text(deviceID)] + chunk.map { SQLValue.int($0) }
                if let start { whereSQL += " AND o.ts >= ?"; binds.append(.int(start)) }
                if let end { whereSQL += " AND o.ts < ?"; binds.append(.int(end)) }
                return (whereSQL, binds)
            }

            // 第一趟：条数与首末时间。**自然日分桶要的时区偏移取自这里的中点**——
            // 取样点必须落在数据本身上：不给 start / end 时用「0 与此刻的中点」会落到 1998 年，
            // 有夏令时的时区里整段按错误的偏移分桶（不止切换当天）。
            // 现在的取样点是 `(MIN(ts) + MAX(ts)) / 2`，只有跨夏令时切换的区间才可能有
            // 一天的桶边界偏 1 h（UTC 与中国时区都没有夏令时，本轮验收不受影响）。
            for chunk in chunks {
                let (whereSQL, binds) = predicate(chunk)
                let head = try conn.prepare(
                    "SELECT COUNT(*), MIN(o.ts), MAX(o.ts) FROM observations o WHERE \(whereSQL);")
                try head.bind(binds)
                if try head.step() {
                    count += Int(head.int(0) ?? 0)
                    if let lo = head.int(1) { firstSeen = min(firstSeen ?? lo, lo) }
                    if let hi = head.int(2) { lastSeen = max(lastSeen ?? hi, hi) }
                }
                head.finalize()
            }
            let probeTS = (firstSeen ?? start ?? Int64(Date().timeIntervalSince1970 * 1000))
                / 2 &+ (lastSeen ?? end ?? Int64(Date().timeIntervalSince1970 * 1000)) / 2
            let offsetMS = Int64(cal.timeZone.secondsFromGMT(
                for: Date(timeIntervalSince1970: Double(probeTS) / 1000)) * 1000)

            // 第二趟：按天直方图、按应用、标题、最近证据。
            for chunk in chunks {
                let (whereSQL, binds) = predicate(chunk)
                for (bucket, n) in try conn.intPairs("""
                    SELECT (o.ts + \(offsetMS)) / 86400000, COUNT(*) FROM observations o
                     WHERE \(whereSQL) GROUP BY 1;
                    """, binds) {
                    days[cal.dayString(bucket * 86_400_000 - offsetMS + 43_200_000),
                         default: 0] += Int(n)
                }
                for (appID, n) in try conn.intPairs("""
                    SELECT o.app_id, COUNT(*) FROM observations o
                     WHERE \(whereSQL) AND o.app_id IS NOT NULL GROUP BY 1;
                    """, binds) {
                    guard let a = appNames[appID] else { continue }
                    var acc = appAcc[a.bundleID] ?? LedgerAccumulator(name: a.name)
                    acc.observations += Int(n)
                    appAcc[a.bundleID] = acc
                }
                for t in try conn.textColumn("""
                    SELECT DISTINCT w.title FROM observations o
                      JOIN windows w ON w.id = o.window_id
                     WHERE \(whereSQL) LIMIT 10;
                    """, binds) where !titles.contains(t) && titles.count < 10 {
                    titles.append(t)
                }
                recent += try conn.intPairs("""
                    SELECT o.id, o.ts FROM observations o WHERE \(whereSQL)
                     ORDER BY o.ts DESC LIMIT ?;
                    """, binds + [.int(Int64(recentLimit))])
            }

            // 时长：
            // - app 选择子直接用 sessions 里的 dwell，**精确**；
            // - url / path 选择子按「该对象自己的观察流」算，上限仍是 maxDwellSeconds，
            //   所以它是**上界**：每一次访问的最后一条观察最多多算 maxDwellSeconds。
            let dwellS: Double
            if case .app = selector, let bundle = objectNames.first {
                dwellS = try conn.scalarInt("""
                    SELECT CAST(COALESCE(SUM(s.dwell_s), 0) * 1000 AS INTEGER) FROM sessions s
                      JOIN apps a ON a.id = s.primary_app_id
                     WHERE s.device_id = ? AND a.bundle_id = ? AND s.stale = 0;
                    """, [.text(deviceID), .text(bundle)]).map { Double($0) / 1000.0 } ?? 0
            } else {
                let cap = Int64(sessionConfig.maxDwellSeconds * 1000)
                var total: Int64 = 0
                var lastByDisplay: [Int64: Int64] = [:]
                for chunk in objectIDs.chunked(into: 400) {
                    var sql = """
                        SELECT o.ts, COALESCE(o.display_id, -1) FROM observations o
                         WHERE o.device_id = ? AND o.\(column) IN (\(placeholders(chunk.count)))
                           AND o.deleted_at IS NULL
                        """
                    var binds: [SQLValue] = [.text(deviceID)] + chunk.map { SQLValue.int($0) }
                    if let start { sql += " AND o.ts >= ?"; binds.append(.int(start)) }
                    if let end { sql += " AND o.ts < ?"; binds.append(.int(end)) }
                    sql += " ORDER BY o.ts;"
                    for (ts, display) in try conn.intPairs(sql, binds) {
                        if let prev = lastByDisplay[display] { total += min(ts - prev, cap) }
                        lastByDisplay[display] = ts
                    }
                }
                dwellS = Double(total) / 1000.0
            }

            return ItemSummary(
                kind: selector.kind, key: selector.key,
                matchedObjects: Array(objectNames.prefix(20)),
                observations: count, firstSeen: firstSeen, lastSeen: lastSeen,
                days: days, apps: Self.sortedEntries(appAcc), titles: titles,
                recentEvidenceIDs: Array(recent.sorted {
                    $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 > $1.1
                }.map(\.0).prefix(recentLimit)),
                dwellS: dwellS)
        }
    }

    private func itemObjects(field: String, term: String, conn: SQLiteConnection)
        throws -> (ids: [Int64], names: [String], column: String) {
        var ids: [Int64] = []
        var names: [String] = []
        let column: String
        let st: Statement
        switch field {
        case "url":
            // 与 search 的 URL 通道同一套形状判定（裸域名 vs 带路径），见 Store+Search.swift。
            st = try conn.prepare(
                Store.urlObjectSQL(term).replacingOccurrences(of: "SELECT id FROM urls",
                                                              with: "SELECT id, canonical_url FROM urls"))
            try st.bind(Store.urlObjectBinds(term))
            column = "url_id"
        case "path":
            st = try conn.prepare("SELECT id, path FROM files WHERE path LIKE ? ESCAPE '\\';")
            try st.bind([.text(LikePattern.contains(term))])
            column = "file_id"
        default:
            st = try conn.prepare("""
                SELECT id, bundle_id FROM apps
                 WHERE bundle_id = ? OR name = ? OR bundle_id LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\';
                """)
            try st.bind([.text(term), .text(term),
                         .text(LikePattern.contains(term)), .text(LikePattern.contains(term))])
            column = "app_id"
        }
        defer { st.finalize() }
        while try st.step() {
            ids.append(st.int(0) ?? 0)
            if let n = st.text(1) { names.append(n) }
        }
        return (ids, names, column)
    }

    // MARK: - get_context(hours, max_tokens) / get_context(start, end)

    /// 3.6 的 `get_context(hours, max_tokens)`——**老入口**，CLI / bench / 测试还在用。
    ///
    /// - Parameter endingAt: 窗口右端（含）；nil 表示「库里最新一条观察」——离线的合成库上
    ///   它是唯一有意义的锚点。**MCP 那一层不走这个入口**：它按 `TimeScope` 解析出 `[start, end)`
    ///   后调下面那个重载，锚点是"现在"——原来锚在最新一条观察上，录制一停窗口就往回漂，
    ///   结果里却仍写着「24 h」。
    public func getContext(hours: Int, maxTokens: Int = 2000,
                           endingAt: Int64? = nil) throws -> ContextBundle {
        let options = retrieval
        return try withLock { conn in
            let end = try endingAt
                ?? conn.scalarInt("SELECT COALESCE(MAX(ts), 0) FROM observations WHERE device_id = ?;",
                                  [.text(deviceID)]) ?? 0
            let start = end - Int64(max(0, hours)) * 3_600_000
            // 老口径的右端是"含"，半开区间要 +1 才把那条观察自己也算进来。
            return try contextUnlocked(start: start, end: end + 1, maxTokens: maxTokens,
                                       hours: hours, options: options, conn: conn)
        }
    }

    /// 半开区间 `[start, end)` 上的上下文：MCP 的 `get_context(period | start / end)` 走这里。
    /// `hours` 按区间长度四舍五入（只是标签；精确边界看 `start` / `end`）。
    public func getContext(start: Int64, end: Int64, maxTokens: Int = 2000) throws -> ContextBundle {
        guard start < end else { throw StoreError.invalidUsage("时间区间要求 start < end") }
        let options = retrieval
        let hours = Int((Double(end - start) / 3_600_000).rounded())
        return try withLock { conn in
            try contextUnlocked(start: start, end: end, maxTokens: maxTokens,
                                hours: hours, options: options, conn: conn)
        }
    }

    /// **按 token 预算截断**，token 口径见 `TokenBudget`（字符数 ÷ 2，向上取整）。
    private func contextUnlocked(start: Int64, end: Int64, maxTokens: Int, hours: Int,
                                 options: RetrievalOptions, conn: SQLiteConnection) throws -> ContextBundle {
        let cal = DayCalendar(options.timeZone)
        let margin = Int64(sessionConfig.maxDwellSeconds * 1000) + 1000
        // 只按应用聚合，不做 urls / files 的 LEFT JOIN（24 h 窗口 8640 条观察上省一半时间）。
        let appNames = try appMap(conn: conn)
        var slices = try observationSlices(from: start - margin, to: end + margin,
                                           withLabels: false, conn: conn)
        for i in slices.indices {
            if let id = slices[i].appID, let a = appNames[id] {
                slices[i].appBundleID = a.bundleID
                slices[i].appName = a.name
            }
        }
        let apps = Self.sortedEntries(Self.aggregate(slices, clipTo: (start, end)) { s in
            guard let b = s.appBundleID else { return nil }
            return (b, s.appName)
        })
        // 会话只要时长与打断数，证据区间不展开。
        let sessions = try sessionRows(from: start, to: end, includeStale: false,
                                       includeEvidence: false, conn: conn)

        // 头部：应用聚合 + 会话汇总，先占预算。
        var lines: [String] = []
        lines.append("[窗口] \(cal.stamp(start)) — \(cal.stamp(end))（\(hours) h）")
        for a in apps.prefix(8) {
            lines.append(String(format: "[应用] %@ dwell %.0fs active %.0fs unknown %.0fs 切换 %d 次 观察 %d 条",
                                a.name ?? a.key, a.dwellS, a.activeS, a.unknownS,
                                a.switches, a.observations))
        }
        lines.append("[会话] \(sessions.count) 段，打断 \(sessions.reduce(0) { $0 + $1.interruptions }) 次")
        var text = lines.joined(separator: "\n")
        var used = TokenBudget.tokens(of: text)

        // 正文片段：最近的在前，按剩余预算逐条加。**两步式**：
        // 先在 observations 上纯索引扫出前 N 条 id（不碰正文），再按 id 取正文与标签。
        // 一条 SQL 带 `ORDER BY o.ts DESC, oc.ord` 会让规划器上临时排序器，
        // 那要求把整个窗口的行（连正文一起）都读出来再排，`LIMIT` 救不了——
        // 同一个库上实测，这一条就占掉了 get_context 几乎全部的时间（一个数量级）。
        var snippets: [ContextSnippet] = []
        var truncated = false
        // 取回条数按预算封顶：每条片段至少要花掉「[时间 应用] 」这个头部（约 18 token），
        // 所以 maxTokens/16 条之外的行永远用不上。
        let wanted = max(8, maxTokens / 16)
        let recent = try conn.intPairs("""
            SELECT id, ts FROM observations
             WHERE device_id = ? AND deleted_at IS NULL AND ts >= ? AND ts < ?
             ORDER BY ts DESC LIMIT ?;
            """, [.text(deviceID), .int(start), .int(end), .int(Int64(wanted))])
        let bodies = try snippetSources(recent.map(\.0), conn: conn)
        let metas = try observationMetas(recent.map(\.0), conn: conn)
        for (id, ts) in recent {
            let remaining = maxTokens - used
            if remaining <= 8 { truncated = true; break }
            guard let raw = bodies[id] else { continue }
            let body = TokenBudget.truncate(raw.replacingOccurrences(of: "\n", with: " "),
                                            toTokens: min(remaining - 8, 200))
            let meta = metas[id]
            let line = "[\(cal.stamp(ts)) \(meta?.appBundleID ?? "?")] " + body
            // **分隔符要算进预算**：拼进 `text` 的是 "\n" + line，只按 line 计费的话
            // 每条片段少算半个 token，片段一多，`usedTokens`（按拼好的全文重算）就可能
            // 超出 `maxTokens` 几个 token。
            let cost = TokenBudget.tokens(of: "\n" + line)
            if used + cost > maxTokens { truncated = true; break }
            used += cost
            text += "\n" + line
            snippets.append(ContextSnippet(evidenceID: id, ts: ts,
                                           appBundleID: meta?.appBundleID,
                                           windowTitle: meta?.windowTitle,
                                           text: body, tokens: cost))
        }
        if snippets.count == recent.count && recent.count == wanted { truncated = true }
        return ContextBundle(hours: hours, start: start, end: end, maxTokens: maxTokens,
                             usedTokens: TokenBudget.tokens(of: text), apps: apps,
                             sessions: sessions, snippets: snippets, truncated: truncated,
                             text: text)
    }
}
