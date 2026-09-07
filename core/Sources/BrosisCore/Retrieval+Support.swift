import Foundation

// =============================================================================
// MARK: - 查询形态路由（3.4「精确字段独立」）
// =============================================================================

/// 查询串路由与字段前缀解析。
///
/// 判定规则与 `tools/bench/fts_compare.py` 的 `route_kind()` 保持同样的意图：
/// 只看查询串长什么样。**判错的代价很小**——三条通道是并集，多跑的那次精确字段查询是
/// 两步式的（先在 `urls` / `files` 小表上取 id，空集直接返回，E7 实测热 p50 0.00 ms）。
public enum QueryRouter {

    /// 支持的字段前缀。带前缀时只走对应的精确字段通道，不经 FTS。
    public static let fieldPrefixes = ["url", "host", "path", "app", "title"]

    /// 把 `host:example.com` 拆成 `("host", "example.com")`；没有前缀时字段为 nil。
    public static func parseField(_ q: String) -> (field: String?, term: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return (nil, trimmed) }
        let head = String(trimmed[trimmed.startIndex..<colon]).lowercased()
        guard fieldPrefixes.contains(head) else { return (nil, trimmed) }
        let rest = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return (nil, trimmed) }
        return (head, rest)
    }

    public static func route(_ q: String) -> QueryRoute {
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .text }
        // 带空白的一律当正文：URL 与路径里不会有空格（真有空格的路径按正文查也能命中）。
        if s.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" }) { return .text }
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("file://") { return .url }
        if s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./") { return .path }
        let head = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? s
        if looksLikeHost(head) { return .url }
        if s.contains("/") { return .path }
        return .text
    }

    /// `a.b`、`www.a.b`、`a.b.cn`：只含 `[A-Za-z0-9.-]`，且最后一段是 2 个以上的 ASCII 字母。
    /// 与 fts_compare.py 的 `URL_RE` 同一个字符类——所以 `fts_compare.py`（带下划线）不会被当成域名，
    /// 而 `AXReader.swift` 会（这跟 M0 的工具行为一致，代价只是多跑一次空的两步式查询）。
    static func looksLikeHost(_ s: String) -> Bool {
        guard let first = s.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        guard s.contains(".") else { return false }
        for ch in s.unicodeScalars {
            let ok = (ch.value >= 0x41 && ch.value <= 0x5A) || (ch.value >= 0x61 && ch.value <= 0x7A)
                || (ch.value >= 0x30 && ch.value <= 0x39) || ch == "." || ch == "-"
            if !ok { return false }
        }
        guard let last = s.split(separator: ".").last, last.count >= 2 else { return false }
        return last.allSatisfy { $0.isASCII && $0.isLetter }
    }
}

// =============================================================================
// MARK: - LIKE 转义
// =============================================================================

enum LikePattern {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
    static func contains(_ s: String) -> String { "%" + escape(s) + "%" }
    static func prefix(_ s: String) -> String { escape(s) + "%" }
    static func suffix(_ s: String) -> String { "%" + escape(s) }
}

// =============================================================================
// MARK: - 日历（台账 / 时间线 / getItem 用）
// =============================================================================

/// 固定时区的日历工具。台账按自然日切分，时区一定要显式给，
/// 否则同一个库在两台机器上算出的日边界不一样（测试与验收统一用 UTC）。
struct DayCalendar {
    let timeZone: TimeZone
    private let calendar: Calendar

    init(_ timeZone: TimeZone) {
        self.timeZone = timeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        cal.firstWeekday = 2                     // ISO：周一
        cal.minimumDaysInFirstWeek = 4
        self.calendar = cal
    }

    private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000.0) }
    private func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    func dayString(_ ts: Int64) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date(ts))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `YYYY-MM-DD HH:mm`，摘要里用。
    func stamp(_ ts: Int64) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date(ts))
        return String(format: "%04d-%02d-%02d %02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// `'YYYY-MM-DD'` → 半开区间 `[当天 00:00, 次日 00:00)`。
    func dayBounds(_ dateString: String) throws -> (start: Int64, end: Int64) {
        let parts = dateString.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else {
            throw StoreError.invalidUsage("日期要写成 YYYY-MM-DD：\(dateString)")
        }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = 0; comps.minute = 0; comps.second = 0
        guard let start = calendar.date(from: comps),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw StoreError.invalidUsage("无法解析日期：\(dateString)")
        }
        return (ms(start), ms(end))
    }

    /// 把时刻对齐到桶的起点。
    func bucketStart(_ ts: Int64, _ g: TimelineGranularity) -> Int64 {
        let d = date(ts)
        switch g {
        case .hour:
            let c = calendar.dateComponents([.year, .month, .day, .hour], from: d)
            return ms(calendar.date(from: c) ?? d)
        case .day:
            return ms(calendar.startOfDay(for: d))
        case .week:
            var c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
            c.weekday = calendar.firstWeekday
            return ms(calendar.date(from: c) ?? calendar.startOfDay(for: d))
        }
    }

    func bucketEnd(_ start: Int64, _ g: TimelineGranularity) -> Int64 {
        let d = date(start)
        let next: Date?
        switch g {
        case .hour: next = calendar.date(byAdding: .hour, value: 1, to: d)
        case .day: next = calendar.date(byAdding: .day, value: 1, to: d)
        case .week: next = calendar.date(byAdding: .weekOfYear, value: 1, to: d)
        }
        return ms(next ?? d)
    }

    func bucketLabel(_ start: Int64, _ g: TimelineGranularity) -> String {
        switch g {
        case .hour:
            let c = calendar.dateComponents([.year, .month, .day, .hour], from: date(start))
            return String(format: "%04d-%02d-%02d %02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
        case .day:
            return dayString(start)
        case .week:
            let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date(start))
            return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        }
    }
}

// =============================================================================
// MARK: - 观察的展示字段
// =============================================================================

/// 一条观察的展示字段（摘要、证据、台账都用它）。
struct ObservationMeta: Sendable {
    var id: Int64
    var ts: Int64
    var displayID: Int64?
    var appID: Int64?
    var appBundleID: String?
    var appName: String?
    var windowTitle: String?
    var rawLocator: String?
    var canonicalURL: String?
    var host: String?
    var filePath: String?
    var trigger: String
    var captureMethod: String
    var completeness: String
    var sourceState: String
}

// =============================================================================
// MARK: - 区间并集（3.7 双屏「总在线」）
// =============================================================================

enum IntervalMath {
    /// 合并重叠 / 相接的半开区间，返回并集总毫秒数。双屏「总在线」按这个算，不重复计。
    static func unionMilliseconds(_ intervals: [(Int64, Int64)]) -> Int64 {
        guard !intervals.isEmpty else { return 0 }
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        guard !sorted.isEmpty else { return 0 }
        var total: Int64 = 0
        var curStart = sorted[0].0
        var curEnd = sorted[0].1
        for (s, e) in sorted.dropFirst() {
            if s > curEnd {
                total += curEnd - curStart
                curStart = s
                curEnd = e
            } else if e > curEnd {
                curEnd = e
            }
        }
        total += curEnd - curStart
        return total
    }
}

// =============================================================================
// MARK: - 时间片的三类归属（3.7）
// =============================================================================

/// 观察的 `source_state` → 三类时间。
///
/// - `unknown`：权限丢失 / 读取超时 / 锁定（3.7 点名的三种）。这段时间**不算前台停留**。
/// - `dwell`：前台停留 = 其余全部（ok / user_idle / secure_input）。
/// - `active`：有输入的活跃 = `ok` 与 `secure_input`（`user_idle` 明确是"用户未活动"，不算）。
///
/// `active ⊆ dwell`；`dwell + unknown` = 会话总时长。三个数分列报告，不相加当总数。
enum TimeBucketKind: Sendable {
    case dwellActive        // 计入 dwell 且计入 active
    case dwellIdle          // 只计入 dwell
    case unknown            // 只计入 unknown

    static func of(sourceState: String) -> TimeBucketKind {
        switch sourceState {
        case "permission_lost", "timeout", "locked": return .unknown
        case "user_idle": return .dwellIdle
        default: return .dwellActive          // ok / secure_input
        }
    }
}
