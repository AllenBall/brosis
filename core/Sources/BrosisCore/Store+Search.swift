import Foundation

// =============================================================================
// 三通道检索（计划 3.4；查询写法按 tools/proto/results/capacity_2026-09-06.md §10）
//
//   1. 精确字段通道：url / host / path / app / title，**两步式**——先在规范化对象小表上
//      取 id，空集直接返回；再按 `observations.<col> IN (…)` 取行。
//      §10.1：写成一条 JOIN + ORDER BY ts LIMIT 时，谓词命中 0 行会退化成 observations
//      全表倒序扫描（12 个月库 520 ms）；两步式 0.6 ms。
//   2. FTS 通道：bigram phrase → 候选 **ORDER BY rowid DESC**（§10.2：bm25 排序在 12 个月
//      库上 225 ms，rowid 倒序 1.3 ms 且与规模无关）→ 子串复核（只对 FTS 候选）→ 展开到观察。
//   3. 扫描通道：1–2 字查询限时（默认 7 天）/ 限应用 LIKE 扫描，不依赖 FTS。
//
// NFKC 口径（M1 R1 之后定案）：**折叠只用于索引，正文存原文**。查询串照旧折叠，
// 于是「原文是全角、查询是半角」这一路要在两条通道上分别补：
// FTS 通道对**候选**现折叠再复核（候选有上限，代价可控）；
// 扫描通道把**查询串**展开成兼容区的各种写法，且只在 `Store.hasCompatibilityText`
// 为真（库里确实写进过全角 / 兼容区正文）时才展开——展开是按模式条数线性变慢的。
// 两处的理由与实测代价分别写在 `ftsChannel`、`scanPredicate` 与 `scanChannel` 上。
//
// 三条通道是**并集**，按 精确 → 扫描 → FTS 的顺序合并去重，每条通道内部按 ts 倒序。
// =============================================================================

extension Store {

    /// 3.6 的 `search(q, start, end, app, limit)`。每条命中带 ≤ 100 token 的摘要与 evidence id。
    public func search(q: String, start: Int64? = nil, end: Int64? = nil,
                       app: String? = nil, limit: Int = 20) throws -> SearchResult {
        try search(SearchRequest(q: q, start: start, end: end, app: app, limit: limit))
    }

    public func search(_ request: SearchRequest) throws -> SearchResult {
        let t0 = Date()
        let options = retrieval
        let (field, rawTerm) = QueryRouter.parseField(request.q)
        let term = TextPipeline.foldForIndex(rawTerm)
        let limit = max(1, request.limit)

        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SearchResult(query: request.q, normalizedQuery: term, route: .text, channels: [],
                                hits: [], ftsCandidates: 0, ftsCandidatesTruncated: false,
                                ftsVerified: 0, scanFromTS: nil, scanToTS: nil,
                                elapsedMS: Date().timeIntervalSince(t0) * 1000)
        }
        let route = field == nil ? QueryRouter.route(term) : .text

        return try withLock { conn in
            let appID = try request.app.flatMap { try self.appID(bundleID: $0, conn: conn) }
            // 指定了应用但库里没有这个应用：直接空结果，别去扫观察表。
            if request.app != nil && appID == nil {
                return SearchResult(query: request.q, normalizedQuery: term, route: route,
                                    channels: [], hits: [], ftsCandidates: 0,
                                    ftsCandidatesTruncated: false, ftsVerified: 0,
                                    scanFromTS: nil, scanToTS: nil,
                                    elapsedMS: Date().timeIntervalSince(t0) * 1000)
            }

            var ordered: [(Int64, SearchChannel)] = []
            var seen = Set<Int64>()
            var channels: [SearchChannel] = []
            func add(_ ids: [Int64], _ channel: SearchChannel) {
                guard !ids.isEmpty else { return }
                if !channels.contains(channel) { channels.append(channel) }
                for id in ids where !seen.contains(id) {
                    seen.insert(id)
                    ordered.append((id, channel))
                }
            }

            // ---- 1. 精确字段通道（两步式） ----
            if let field {
                // 带字段前缀：只走这一条通道，不经 FTS（3.4 第一条）。
                let channel = try exactChannel(field: field, term: term, request: request,
                                               appID: appID, limit: limit, conn: conn)
                add(channel.ids, channel.channel)
                let hits = try makeHits(ordered, term: term, options: options, conn: conn)
                return SearchResult(query: request.q, normalizedQuery: term, route: route,
                                    channels: channels, hits: Array(hits.prefix(limit)),
                                    ftsCandidates: 0, ftsCandidatesTruncated: false, ftsVerified: 0,
                                    scanFromTS: nil, scanToTS: nil,
                                    elapsedMS: Date().timeIntervalSince(t0) * 1000)
            }
            switch route {
            case .url:
                let c = try exactChannel(field: "url", term: term, request: request,
                                         appID: appID, limit: limit, conn: conn)
                add(c.ids, c.channel)
            case .path:
                let c = try exactChannel(field: "path", term: term, request: request,
                                         appID: appID, limit: limit, conn: conn)
                add(c.ids, c.channel)
            case .text:
                break
            }
            // 窗口标题永远参与：标题是短字段，子串命中就是真命中，且标题本来就显示在屏幕上。
            let titleHits = try exactChannel(field: "title", term: term, request: request,
                                             appID: appID, limit: limit, conn: conn)
            add(titleHits.ids, titleHits.channel)

            // ---- 2. 扫描通道（1–2 字，3.4） ----
            var scanFrom: Int64?
            var scanTo: Int64?
            if term.count <= options.scanMaxQueryCharacters,
               Self.scanChannelApplies(to: term, options: options) {
                let window = try scanWindow(request: request, options: options, conn: conn)
                scanFrom = window.from
                scanTo = window.to
                let ids = try scanChannel(term: term, rawTerm: rawTerm,
                                          from: window.from, to: window.to,
                                          appID: appID, limit: limit, conn: conn)
                add(ids, .scan)
            }

            // ---- 3. FTS 通道（D22 + E7 §10.2） ----
            let filtered = request.start != nil || request.end != nil || appID != nil
            let candidateLimit = filtered ? options.filteredFTSCandidateLimit : options.ftsCandidateLimit
            let fts = try ftsChannel(term: term, request: request, appID: appID,
                                     limit: limit, candidateLimit: candidateLimit, conn: conn)
            add(fts.ids, .fts)

            let hits = try makeHits(ordered, term: term, options: options, conn: conn)
            return SearchResult(query: request.q, normalizedQuery: term, route: route,
                                channels: channels, hits: Array(hits.prefix(limit)),
                                ftsCandidates: fts.candidates,
                                ftsCandidatesTruncated: fts.truncated,
                                ftsVerified: fts.verified,
                                scanFromTS: scanFrom, scanToTS: scanTo,
                                elapsedMS: Date().timeIntervalSince(t0) * 1000)
        }
    }

    // MARK: - 通道 1：精确字段（两步式）

    struct ExactChannelResult {
        var ids: [Int64]
        var channel: SearchChannel
        /// 第一步在规范化对象表上命中的对象 id 数（0 就直接返回了，第二步根本没跑）。
        var objectCount: Int
    }

    /// 两步式精确字段查询。**第一步在小表上求 id 集合，空集直接返回**（E7 §10.1）。
    func exactChannel(field: String, term: String, request: SearchRequest,
                      appID: Int64?, limit: Int, conn: SQLiteConnection) throws -> ExactChannelResult {
        let objectIDs: [Int64]
        let column: String
        let channel: SearchChannel
        switch field {
        case "url", "host":
            objectIDs = try conn.intColumn(Self.urlObjectSQL(term), Self.urlObjectBinds(term))
            column = "url_id"
            channel = .exactURL
        case "path":
            objectIDs = try conn.intColumn("SELECT id FROM files WHERE path LIKE ? ESCAPE '\\';",
                                           [.text(LikePattern.contains(term))])
            column = "file_id"
            channel = .exactPath
        case "title":
            objectIDs = try conn.intColumn("SELECT id FROM windows WHERE title LIKE ? ESCAPE '\\';",
                                           [.text(LikePattern.contains(term))])
            column = "window_id"
            channel = .exactTitle
        case "app":
            objectIDs = try conn.intColumn("""
                SELECT id FROM apps
                 WHERE bundle_id = ? OR name = ?
                    OR bundle_id LIKE ? ESCAPE '\\' OR name LIKE ? ESCAPE '\\';
                """, [.text(term), .text(term),
                      .text(LikePattern.contains(term)), .text(LikePattern.contains(term))])
            column = "app_id"
            channel = .exactApp
        default:
            throw StoreError.invalidUsage("未知的字段前缀：\(field)")
        }
        // ★ 空集早返回：这一行就是 E7 §10.1 那 520 ms → 0.6 ms 的修法。
        guard !objectIDs.isEmpty else {
            return ExactChannelResult(ids: [], channel: channel, objectCount: 0)
        }
        var rows: [(Int64, Int64)] = []
        for chunk in objectIDs.chunked(into: 400) {
            var sql = "SELECT id, ts FROM observations WHERE device_id = ? AND \(column) IN (\(placeholders(chunk.count))) AND deleted_at IS NULL"
            var binds: [SQLValue] = [.text(deviceID)] + chunk.map { SQLValue.int($0) }
            if let start = request.start { sql += " AND ts >= ?"; binds.append(.int(start)) }
            if let end = request.end { sql += " AND ts < ?"; binds.append(.int(end)) }
            if let appID { sql += " AND app_id = ?"; binds.append(.int(appID)) }
            sql += " ORDER BY ts DESC LIMIT ?;"
            binds.append(.int(Int64(limit)))
            rows += try conn.intPairs(sql, binds)
        }
        // 分块查回来的几段各自有序，合起来要重新按 ts 倒序取前 limit 条。
        let ids = rows.sorted { $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 > $1.1 }.map(\.0)
        return ExactChannelResult(ids: Array(ids.prefix(limit)), channel: channel,
                                  objectCount: objectIDs.count)
    }

    /// URL 通道第一步的两种形状（写法沿用 `tools/bench/fts_compare.py` 的 `_exact`）：
    ///
    /// - **裸域名**（`docs.internal.example`）：`host` 等值 + 子域后缀 + `canonical_url` 子串。
    /// - **带路径**（`https://docs.internal.example/spec/`）：**只按 URL 列子串匹配**。
    ///   这里不能再退回 host 等值——那会把同域名下所有别的页面全带进来，
    ///   本轮评估里 `url-03` 就是这么掉到 Recall@10 0.4 的（同域名的 `/page/N` 挤满了前 10 条）。
    static func urlObjectSQL(_ term: String) -> String {
        hasPath(term)
            ? "SELECT id FROM urls WHERE canonical_url LIKE ? ESCAPE '\\' OR raw_locator LIKE ? ESCAPE '\\';"
            : """
              SELECT id FROM urls
               WHERE host = ? OR host LIKE ? ESCAPE '\\'
                  OR canonical_url LIKE ? ESCAPE '\\' OR raw_locator LIKE ? ESCAPE '\\';
              """
    }

    static func urlObjectBinds(_ term: String) -> [SQLValue] {
        if hasPath(term) {
            return [.text(LikePattern.contains(term)), .text(LikePattern.contains(term))]
        }
        let bare = bareHost(term)
        return [.text(bare), .text(LikePattern.suffix("." + bare)),
                .text(LikePattern.contains(term)), .text(LikePattern.contains(term))]
    }

    /// 去掉协议头之后还带 `/` 的就是「带路径的 URL」。
    static func hasPath(_ term: String) -> Bool {
        var s = term
        for prefix in ["https://", "http://", "file://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        return s.contains("/")
    }

    static func bareHost(_ term: String) -> String {
        var s = term
        for prefix in ["https://", "http://", "file://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let slash = s.firstIndex(of: "/") { s = String(s[s.startIndex..<slash]) }
        return s
    }

    // MARK: - 通道 2：FTS（bigram + rowid 倒序 + 子串复核）

    struct FTSChannelResult {
        var ids: [Int64]
        var candidates: Int
        var truncated: Bool
        var verified: Int
    }

    func ftsChannel(term: String, request: SearchRequest, appID: Int64?,
                    limit: Int, candidateLimit: Int,
                    conn: SQLiteConnection) throws -> FTSChannelResult {
        let bigram = TextPipeline.bigram(term)
        guard !bigram.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FTSChannelResult(ids: [], candidates: 0, truncated: false, verified: 0)
        }
        // ① 候选：**ORDER BY rowid DESC**，不是 bm25。vrow 单调递增 ⇒ rowid 倒序 ≈ 时间倒序，
        //    FTS5 能直接从倒排表尾部取前 N 条，延迟与库规模无关（E7 §10.2）。
        let vrows = try conn.intColumn("""
            SELECT rowid FROM text_fts WHERE text_fts MATCH ? ORDER BY rowid DESC LIMIT ?;
            """, [.text(TextPipeline.ftsPhrase(term)), .int(Int64(candidateLimit))])
        guard !vrows.isEmpty else {
            return FTSChannelResult(ids: [], candidates: 0, truncated: false, verified: 0)
        }
        // ② 子串复核：**只作用于 FTS 通道候选**（3.4）。分两遍：
        //
        //    第一遍还是 SQL 的 LIKE，在**原文**上做。它对 ASCII 大小写不敏感，与 unicode61
        //    分词器、与 fts_compare.py 的真值口径（q.lower() in text.lower()）一致，
        //    绝大多数候选在这一遍就定了，行为与折叠入库那版逐字节相同。
        //
        //    第二遍只捞第一遍没过的那些候选（正常就是分词假阳性，很少），把正文**现折叠**
        //    一遍再比一次。这一遍是这次口径变更必须补的：正文存原文、FTS 索引存折叠后的形式，
        //    一段全角正文（`"ＳＱＬ 100"`）能被半角查询 MATCH 到，只在原文上复核会把它误杀。
        //
        //    代价：多一次同 rowid 集合的索引回查，外加对「没过第一遍」的候选做 NFKC。
        //    候选本身有上限（无过滤 200、带过滤 2000），所以是有界的常数级开销；
        //    换掉它的另一条路是在 text_versions 旁边存一份折叠副本，那要多一倍正文存储，不取。
        var verified: [Int64] = []
        for chunk in vrows.chunked(into: 400) {
            let slots = placeholders(chunk.count)
            let binds = chunk.map { SQLValue.int($0) } + [.text(LikePattern.contains(term))]
            verified += try conn.intColumn("""
                SELECT id FROM text_versions
                 WHERE vrow IN (\(slots)) AND text LIKE ? ESCAPE '\\';
                """, binds)
            let st = try conn.prepare("""
                SELECT id, text FROM text_versions
                 WHERE vrow IN (\(slots)) AND text NOT LIKE ? ESCAPE '\\';
                """)
            defer { st.finalize() }
            try st.bind(binds)
            while try st.step() {
                guard let id = st.int(0), let text = st.text(1) else { continue }
                if TextPipeline.indexContains(text, foldedTerm: term) { verified.append(id) }
            }
        }
        guard !verified.isEmpty else {
            return FTSChannelResult(ids: [], candidates: vrows.count,
                                    truncated: vrows.count >= candidateLimit, verified: 0)
        }
        // ③ 展开到观察。
        var rows: [(Int64, Int64)] = []
        for chunk in verified.chunked(into: 400) {
            var sql = """
                SELECT DISTINCT o.id, o.ts FROM occurrences oc
                  JOIN observations o ON o.device_id = oc.device_id AND o.id = oc.observation_id
                 WHERE oc.device_id = ? AND oc.text_version_id IN (\(placeholders(chunk.count)))
                   AND o.deleted_at IS NULL
                """
            var binds: [SQLValue] = [.text(deviceID)] + chunk.map { SQLValue.int($0) }
            if let start = request.start { sql += " AND o.ts >= ?"; binds.append(.int(start)) }
            if let end = request.end { sql += " AND o.ts < ?"; binds.append(.int(end)) }
            if let appID { sql += " AND o.app_id = ?"; binds.append(.int(appID)) }
            sql += " ORDER BY o.ts DESC LIMIT ?;"
            binds.append(.int(Int64(limit)))
            rows += try conn.intPairs(sql, binds)
        }
        var seen = Set<Int64>()
        let ids = rows.sorted { $0.1 == $1.1 ? $0.0 > $1.0 : $0.1 > $1.1 }
            .map(\.0).filter { seen.insert($0).inserted }
        return FTSChannelResult(ids: Array(ids.prefix(limit)), candidates: vrows.count,
                                truncated: vrows.count >= candidateLimit, verified: verified.count)
    }

    // MARK: - 通道 3：1–2 字扫描（限时 / 限应用）

    /// 扫描窗口：显式给了区间就用它；否则以「库里最新一条观察」为锚点往回取
    /// `scanWindowDays` 天（3.4：7 天窗口内实测召回 100%，延迟与库规模无关）。
    func scanWindow(request: SearchRequest, options: RetrievalOptions,
                    conn: SQLiteConnection) throws -> (from: Int64, to: Int64) {
        let dayMS: Int64 = 86_400_000
        // 显式给了 end：上界就是 end，**半开区间**，与精确字段 / FTS 两条通道的 `ts < end` 一致。
        if let end = request.end {
            return (request.start ?? (end - Int64(options.scanWindowDays) * dayMS), end)
        }
        // 没给 end：锚点取库里最新一条观察的 ts，上界要 +1 才能把它自己也扫进来。
        let anchor = try conn.scalarInt(
            "SELECT COALESCE(MAX(ts), 0) FROM observations WHERE device_id = ?;",
            [.text(deviceID)]) ?? 0
        if let start = request.start { return (start, anchor + 1) }
        return (anchor - Int64(options.scanWindowDays) * dayMS, anchor + 1)
    }

    /// 扫描通道该不该开。
    ///
    /// 只有 bigram 索引**确实覆盖不到**的短查询才值得扫：
    /// - **纯汉字两字**（`熵值`）本身就是一个 bigram token，FTS 通道 MATCH 到它再用 `LIKE`
    ///   复核，语义已经是精确子串，扫描通道对这一类**零召回增益**——本轮 6 道「中文两字词」
    ///   单靠 FTS 就全部召回；而它要把窗口内的正文全扫一遍，实测多花 130 ms 以上。所以不开。
    /// - **单字**（`熵`）在 bigram 索引里没有对应 token（`TextPipeline.bigram` 对长度 1 的
    ///   汉字连续段保留该字本身，但正文里的单字几乎都被吸进了两字 token），必须扫。
    /// - **≤2 字里含非汉字**（`ab`、`a工`）：`unicode61` 按词切，`ab` 命中不了 `abc` 里的子串，
    ///   也必须扫。
    static func scanChannelApplies(to term: String,
                                   options: RetrievalOptions = RetrievalOptions()) -> Bool {
        guard options.scanSkipsPureCJKBigram else { return true }
        let scalars = Array(term.unicodeScalars)
        if scalars.count >= 2, scalars.allSatisfy(TextPipeline.isCJK) { return false }
        return true
    }

    /// 扫描通道在**原文**上要匹配的谓词：若干个 `LIKE` 的 `OR`。
    ///
    /// 三个方向缺一不可：
    /// - 折叠串 → 原文本来就是半角（绝大多数）；
    /// - 原样串 → 用户输入里带了折叠会丢掉的写法（例：查 `ﬁ` 而正文里就是 `ﬁ`）；
    /// - 前像展开 → **半角查询命中全角原文**。这一路只靠「折叠 / 不折叠各试一次」是做不到的：
    ///   查 `A`、正文是 `Ａ`，两种查询串都不含 `Ａ`，`LIKE` 一定落空。实测过，
    ///   `testScanChannelMatchesFullwidthBodyWithHalfwidthQuery` 就是钉这条的用例。
    ///
    /// **`expandCompatibility` 决定要不要做第三件事**，因为它按模式条数线性变慢
    /// （ASCII 两字：1 条 117.4 ms → 9 条 721.0 ms，见 `TextPipeline.scanVariants`）。
    /// 调用方传的是 `Store.hasCompatibilityText`：库里从来没写进过「折叠会变样」的正文
    /// 就不展开，代价与口径变更之前逐字节一样。
    static func scanPredicate(term: String, rawTerm: String,
                              expandCompatibility: Bool) -> (sql: String, binds: [SQLValue]) {
        let patterns: [String]
        if expandCompatibility {
            patterns = scanPatterns(term: term, rawTerm: rawTerm)
        } else if rawTerm.isEmpty || rawTerm == term {
            patterns = [term]
        } else {
            patterns = [term, rawTerm]
        }
        let sql = "(" + patterns.map { _ in "tv.text LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")"
        return (sql, patterns.map { SQLValue.text(LikePattern.contains($0)) })
    }

    /// 展开后的全部写法：折叠串 + 兼容区前像展开 + 原样串。
    static func scanPatterns(term: String, rawTerm: String) -> [String] {
        var out: [String] = []
        for candidate in TextPipeline.scanVariants(term) + [rawTerm]
        where !candidate.isEmpty && !out.contains(candidate) {
            out.append(candidate)
        }
        return out.isEmpty ? [term] : out
    }

    /// 扫描通道就是一条 SQL，**不要拆成两步**。
    ///
    /// 试过一版「先 `SELECT DISTINCT text_version_id` 去重、再只在这些版本上 LIKE」的两步式：
    /// 想法是本轮语料里一个文本版本平均被 2.6 条观察引用，去重之后正文只用扫一遍。
    /// 同一个库上实测反而**慢了将近一倍**：省下的那点正文扫描，抵不过 6 万行上的
    /// `DISTINCT` 临时 b-tree 加几十次 400 元素 `IN` 回查。
    /// 精确字段那条通道要两步是因为**空集能早返回**，这里没有空集可言，所以两步只是纯开销。
    func scanChannel(term: String, rawTerm: String, from: Int64, to: Int64, appID: Int64?,
                     limit: Int, conn: SQLiteConnection) throws -> [Int64] {
        // 为什么是「展开查询串」而不是「现折叠正文」：正文不再折叠之后，
        // 要在原文上认出全角写法只有两条路。把 `tv.text` 现折叠再匹配是完全正确的，
        // 但那是对 7 天窗口里约 34 MiB 正文逐条做 NFKC——这条通道本来就是 3.4 分层目标里
        // 最贵的一档（实测热 p95 122 ms / 目标 150 ms），再加一遍全窗口 NFKC 直接超标。
        // 查询串只有 1–2 个字符，展开它是常数代价；但 `OR` 出来的每个 `LIKE` 都要各扫一遍窗口，
        // 所以只在库里**真的有**兼容区正文时才展开（`hasCompatibilityText`）。
        // 代价与「试过但退回的 GLOB 写法」都写在 `TextPipeline.scanVariants` 上。
        let predicate = Self.scanPredicate(term: term, rawTerm: rawTerm,
                                           expandCompatibility: hasCompatibilityText)
        var sql = """
            SELECT DISTINCT o.id, o.ts FROM observations o
              JOIN occurrences oc ON oc.device_id = o.device_id AND oc.observation_id = o.id
              JOIN text_versions tv ON tv.device_id = oc.device_id AND tv.id = oc.text_version_id
             WHERE o.device_id = ? AND o.ts >= ? AND o.ts < ? AND o.deleted_at IS NULL
            """
        var binds: [SQLValue] = [.text(deviceID), .int(from), .int(to)]
        if let appID { sql += " AND o.app_id = ?"; binds.append(.int(appID)) }
        sql += " AND " + predicate.sql
        binds += predicate.binds
        sql += " ORDER BY o.ts DESC LIMIT ?;"
        binds.append(.int(Int64(limit)))
        return try conn.intColumn(sql, binds)
    }

    // MARK: - 摘要

    func makeHits(_ ordered: [(Int64, SearchChannel)], term: String,
                  options: RetrievalOptions, conn: SQLiteConnection) throws -> [SearchHit] {
        guard !ordered.isEmpty else { return [] }
        let metas = try observationMetas(ordered.map(\.0), conn: conn)
        let texts = try snippetSources(ordered.map(\.0), conn: conn)
        let cal = DayCalendar(options.timeZone)
        var out: [SearchHit] = []
        out.reserveCapacity(ordered.count)
        for (id, channel) in ordered {
            guard let meta = metas[id] else { continue }
            let body = texts[id] ?? ""
            let snippet = Self.snippet(of: body, matching: term, context: options.snippetContext)
            let head = [meta.appName ?? meta.appBundleID ?? "?",
                        meta.windowTitle ?? meta.host ?? meta.filePath ?? "",
                        cal.stamp(meta.ts)]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            let summary = TokenBudget.truncate(
                snippet.isEmpty ? head : head + " · " + snippet,
                toTokens: options.summaryTokenBudget)
            out.append(SearchHit(evidenceID: id, ts: meta.ts,
                                 appBundleID: meta.appBundleID, appName: meta.appName,
                                 windowTitle: meta.windowTitle,
                                 url: meta.canonicalURL ?? meta.rawLocator, host: meta.host,
                                 filePath: meta.filePath, snippet: snippet, channel: channel,
                                 summary: summary, summaryTokens: TokenBudget.tokens(of: summary)))
        }
        return out
    }

    /// 命中片段：正文里第一次出现查询串的位置，前后各留 `context` 个字符。
    /// 找不到就取正文开头——两种情况会走到这条：精确字段通道的命中（正文里可以不含该串），
    /// 以及「全角原文 + 半角查询」（命中是真的，只是定位不到，片段退化成正文开头）。
    /// 后者只影响摘要好不好看，不影响召回；要精确定位就得把折叠后的下标映回原文，
    /// 折叠会改长度，映射不可靠，M1 不做。
    static func snippet(of text: String, matching term: String, context: Int) -> String {
        guard !text.isEmpty else { return "" }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: term, options: [.caseInsensitive]) else {
            return String(flat.prefix(context * 2))
        }
        let lower = flat.index(range.lowerBound, offsetBy: -context,
                               limitedBy: flat.startIndex) ?? flat.startIndex
        let upper = flat.index(range.upperBound, offsetBy: context,
                               limitedBy: flat.endIndex) ?? flat.endIndex
        var s = String(flat[lower..<upper])
        if lower != flat.startIndex { s = "…" + s }
        if upper != flat.endIndex { s += "…" }
        return s
    }

    // MARK: - 共用取行

    func appID(bundleID: String, conn: SQLiteConnection) throws -> Int64? {
        try conn.scalarInt("SELECT id FROM apps WHERE bundle_id = ?;", [.text(bundleID)])
    }

    /// 按 id 批量取观察的展示字段。
    func observationMetas(_ ids: [Int64], conn: SQLiteConnection) throws -> [Int64: ObservationMeta] {
        var out: [Int64: ObservationMeta] = [:]
        for chunk in Array(Set(ids)).sorted().chunked(into: 400) {
            let st = try conn.prepare("""
                SELECT o.id, o.ts, o.display_id, o.app_id, a.bundle_id, a.name, w.title,
                       u.raw_locator, u.canonical_url, u.host, f.path,
                       o."trigger", o.capture_method, o.completeness, o.source_state
                  FROM observations o
                  LEFT JOIN apps    a ON a.id = o.app_id
                  LEFT JOIN windows w ON w.id = o.window_id
                  LEFT JOIN urls    u ON u.id = o.url_id
                  LEFT JOIN files   f ON f.id = o.file_id
                 WHERE o.device_id = ? AND o.id IN (\(placeholders(chunk.count)))
                   AND o.deleted_at IS NULL;
                """)
            defer { st.finalize() }
            try st.bind([.text(deviceID)] + chunk.map { SQLValue.int($0) })
            while try st.step() {
                guard let id = st.int(0) else { continue }
                out[id] = ObservationMeta(
                    id: id, ts: st.int(1) ?? 0, displayID: st.int(2), appID: st.int(3),
                    appBundleID: st.text(4), appName: st.text(5), windowTitle: st.text(6),
                    rawLocator: st.text(7), canonicalURL: st.text(8), host: st.text(9),
                    filePath: st.text(10), trigger: st.text(11) ?? "", captureMethod: st.text(12) ?? "",
                    completeness: st.text(13) ?? "", sourceState: st.text(14) ?? "")
            }
        }
        return out
    }

    /// 摘要用的正文：每条观察取 `ord = 0` 的那段（一次捕获 = 一段完整可见正文，见 E7 口径）。
    func snippetSources(_ ids: [Int64], conn: SQLiteConnection) throws -> [Int64: String] {
        var out: [Int64: String] = [:]
        for chunk in Array(Set(ids)).sorted().chunked(into: 400) {
            let st = try conn.prepare("""
                SELECT oc.observation_id, tv.text FROM occurrences oc
                  JOIN text_versions tv ON tv.device_id = oc.device_id AND tv.id = oc.text_version_id
                 WHERE oc.device_id = ? AND oc.observation_id IN (\(placeholders(chunk.count)))
                 ORDER BY oc.observation_id, oc.ord;
                """)
            defer { st.finalize() }
            try st.bind([.text(deviceID)] + chunk.map { SQLValue.int($0) })
            while try st.step() {
                guard let id = st.int(0), let text = st.text(1) else { continue }
                if out[id] == nil { out[id] = text }
            }
        }
        return out
    }
}
