import Foundation

// =============================================================================
// 检索延迟压测（2.4「延迟」行的口径：分冷 / 热，p50 / p95）
//
// 查询分四类，与 tools/proto/measure.py 的 QUERY_SET 对齐，并且**只用修正后的写法**
// （tools/proto/results/capacity_2026-09-06.md §10 的三处）：
//   1. 精确字段（两步式，含一条「命中 0 行」的对照）
//   2. FTS 检索（bigram phrase + rowid 倒序候选 + 子串复核）
//   3. 1–2 字扫描回退（限时 / 限应用）
//   4. 聚合类：get_context / get_timeline / get_day_ledger / sessions 区间（start 补下界）
//
// 冷 / 热的定义由调用方（`brosis-store bench`）实现：
//   冷 = 全新子进程 + 全新连接，跑一次就退出；热 = 同一连接预热一次后连测 N 次。
// =============================================================================

public struct BenchQuery: Sendable, Codable {
    public var category: String
    public var id: String
    public var label: String
}

public struct BenchSample: Sendable, Codable {
    public var id: String
    public var ms: Double
    public var rows: Int
    public var error: String?

    public init(id: String, ms: Double, rows: Int, error: String? = nil) {
        self.id = id
        self.ms = ms
        self.rows = rows
        self.error = error
    }
}

/// 一套按库内容实例化好的压测查询。参数（host / 路径片段 / 应用 / 最近 20 条 id …）
/// 都是从库里真实取出来的，不是硬编码，换一个库就跟着变。
public final class BenchPlan: @unchecked Sendable {
    public let queries: [BenchQuery]
    let runners: [String: () throws -> Int]
    public let parameters: [String: String]

    init(queries: [BenchQuery], runners: [String: () throws -> Int], parameters: [String: String]) {
        self.queries = queries
        self.runners = runners
        self.parameters = parameters
    }

    /// 跑一条查询，返回命中行数。
    @discardableResult
    public func run(_ id: String) throws -> Int {
        guard let fn = runners[id] else { throw StoreError.invalidUsage("未知的压测查询：\(id)") }
        return try fn()
    }

    /// 整套各跑一次，返回逐条耗时。
    public func runRound() -> [BenchSample] {
        queries.map { q in
            let t0 = Date()
            do {
                let rows = try run(q.id)
                return BenchSample(id: q.id, ms: Date().timeIntervalSince(t0) * 1000,
                                   rows: rows, error: nil)
            } catch {
                return BenchSample(id: q.id, ms: Date().timeIntervalSince(t0) * 1000,
                                   rows: 0, error: String(describing: error))
            }
        }
    }
}

extension Store {

    /// 从库里取真实参数并生成压测计划。
    ///
    /// - Parameters:
    ///   - ftsQueries: FTS 通道用的查询串（应当在语料里真实存在，否则测的是空结果）。
    ///   - shortQueries: 1–2 字查询串。
    public func makeBenchPlan(ftsQueries: [String] = ["采集覆盖率", "checkpoint", "蟠桃"],
                              shortQueries: [String] = ["预算", "会"]) throws -> BenchPlan {
        // 参数取一次，之后每轮复用（与 measure.py 的 load_params 同一个思路）。
        let params: (host: String?, canonical: String?, path: String?, title: String?,
                     bundle: String?, ids: [Int64], maxTS: Int64, minTS: Int64)
        params = try withLock { conn in
            // 取参数只在**最近 20000 条观察**里统计：全表 GROUP BY 在 1 个月库上要几百毫秒，
            // 而它每轮冷测都要跑一次（虽然不计入计时，但会把整轮压测拖成几分钟）。
            let host = try conn.scalarText("""
                SELECT u.host FROM urls u
                  JOIN (SELECT url_id FROM observations WHERE device_id = ?
                         ORDER BY ts DESC LIMIT 20000) s ON s.url_id = u.id
                 WHERE u.host IS NOT NULL GROUP BY u.host ORDER BY COUNT(*) DESC LIMIT 1;
                """, [.text(deviceID)])
            let canonical = try conn.scalarText("SELECT canonical_url FROM urls ORDER BY id LIMIT 1;")
            let path = try conn.scalarText("SELECT path FROM files ORDER BY id LIMIT 1;")
            let title = try conn.scalarText("SELECT title FROM windows ORDER BY id LIMIT 1;")
            let bundle = try conn.scalarText("""
                SELECT a.bundle_id FROM apps a
                  JOIN (SELECT app_id FROM observations WHERE device_id = ?
                         ORDER BY ts DESC LIMIT 20000) s ON s.app_id = a.id
                 GROUP BY a.id ORDER BY COUNT(*) DESC LIMIT 1;
                """, [.text(deviceID)])
            let ids = try conn.intColumn("""
                SELECT id FROM observations WHERE device_id = ? AND deleted_at IS NULL
                 ORDER BY ts DESC LIMIT 20;
                """, [.text(deviceID)])
            let maxTS = try conn.scalarInt("SELECT COALESCE(MAX(ts),0) FROM observations WHERE device_id = ?;",
                                           [.text(deviceID)]) ?? 0
            let minTS = try conn.scalarInt("SELECT COALESCE(MIN(ts),0) FROM observations WHERE device_id = ?;",
                                           [.text(deviceID)]) ?? 0
            return (host, canonical, path, title, bundle, ids, maxTS, minTS)
        }

        let dayMS: Int64 = 86_400_000
        let pathFragment = params.path.map { ($0 as NSString).lastPathComponent } ?? "brosis"
        let titlePrefix = params.title.map { String($0.prefix(6)) } ?? "窗口"
        let canonicalPrefix = params.canonical.map { String($0.prefix(40)) } ?? "https://"
        // files 表里一定没有的路径：用来复现 E7 §10.1 的「命中 0 行」形状。
        let missPath = "tools/bench/does-not-exist-\(UUID().uuidString.prefix(8)).py"
        let scanFrom = params.maxTS - 7 * dayMS
        let cal = DayCalendar(retrieval.timeZone)
        let ledgerDay = cal.dayString(params.maxTS)

        var queries: [BenchQuery] = []
        var runners: [String: () throws -> Int] = [:]
        func add(_ category: String, _ id: String, _ label: String, _ fn: @escaping () throws -> Int) {
            queries.append(BenchQuery(category: category, id: id, label: label))
            runners[id] = fn
        }

        // ---- 1. 精确字段（两步式） ----
        let exact = "精确字段"
        add(exact, "exact_host", "host 等值 → 观察（两步式）") {
            try self.search(q: "host:" + (params.host ?? "example.com"), limit: 20).hits.count
        }
        add(exact, "exact_url_prefix", "canonical_url 前缀 → 观察（两步式）") {
            try self.search(q: "url:" + canonicalPrefix, limit: 20).hits.count
        }
        add(exact, "exact_path", "files.path 子串 → 观察（两步式）") {
            try self.search(q: "path:" + pathFragment, limit: 20).hits.count
        }
        add(exact, "exact_title", "窗口标题子串 → 观察（两步式）") {
            try self.search(q: "title:" + titlePrefix, limit: 20).hits.count
        }
        add(exact, "exact_path_miss", "路径命中 0 行（两步式空集早返回）") {
            try self.search(q: "path:" + missPath, limit: 20).hits.count
        }
        add(exact, "exact_evidence", "get_evidence 主键点查 20 条") {
            try self.getEvidence(ids: params.ids, neighbors: 2).items.count
        }
        add(exact, "exact_item_app", "get_item(app)") {
            try self.getItem(.app(params.bundle ?? "com.apple.Safari")).observations
        }

        // ---- 2. FTS ----
        for q in ftsQueries {
            add("FTS 检索", "fts_" + slug(q), "bigram phrase + rowid 倒序：`\(q)`") {
                try self.search(q: q, limit: 20).hits.count
            }
        }

        // ---- 3. 1–2 字短查询（扫描通道开不开由 `scanChannelApplies` 决定）----
        for q in shortQueries {
            // 纯汉字两字本身就是一个 bigram token，只走 FTS；单字 / 含非汉字的才真扫。
            let scans = Store.scanChannelApplies(to: TextPipeline.foldForIndex(q), options: retrieval)
            let how = scans ? "限最近 7 天 LIKE 扫描" : "纯汉字两字 → 只走 FTS（bigram 已是精确子串）"
            add("1–2 字短查询", "scan_" + slug(q), "\(how)：`\(q)`") {
                try self.search(q: q, limit: 20).hits.count
            }
            add("1–2 字短查询", "scanapp_" + slug(q), "\(how) + 限应用：`\(q)`") {
                try self.search(q: q, app: params.bundle, limit: 20).hits.count
            }
        }

        // ---- 4. 聚合类 ----
        let agg = "聚合（context / timeline / ledger / sessions）"
        add(agg, "ctx_24h", "get_context(hours=24, max_tokens=2000)") {
            try self.getContext(hours: 24, maxTokens: 2000, endingAt: params.maxTS).snippets.count
        }
        add(agg, "timeline_day", "get_timeline(最近 7 天, day)") {
            try self.getTimeline(start: scanFrom, end: params.maxTS + 1, granularity: .day).buckets.count
        }
        add(agg, "ledger_day", "get_day_ledger(最后一天，读缓存)") {
            let l = try self.getDayLedger(date: ledgerDay)
            return l.apps.count
        }
        add(agg, "sessions_range", "sessions 区间查询（start 补下界）") {
            try self.sessions(from: params.maxTS - dayMS, to: params.maxTS + 1).count
        }

        let parameters: [String: String] = [
            "host": params.host ?? "-",
            "canonical_prefix": canonicalPrefix,
            "path_fragment": pathFragment,
            "title_prefix": titlePrefix,
            "bundle_id": params.bundle ?? "-",
            "miss_path": missPath,
            "evidence_ids": params.ids.map(String.init).joined(separator: ","),
            "min_ts": String(params.minTS),
            "max_ts": String(params.maxTS),
            "scan_from": String(scanFrom),
            "ledger_day": ledgerDay,
            "time_zone": retrieval.timeZone.identifier,
        ]
        return BenchPlan(queries: queries, runners: runners, parameters: parameters)
    }

    private func slug(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) && ch.isASCII { out.unicodeScalars.append(ch) }
            else if ch == "_" { out.append("_") }
        }
        if out.isEmpty {
            // 中文查询用 UTF-8 字节的十六进制做 id，保证 id 里没有非 ASCII。
            out = s.utf8.map { String(format: "%02x", $0) }.joined()
        }
        return String(out.prefix(24))
    }
}
