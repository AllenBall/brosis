import Foundation
import BrosisIPC

// =============================================================================
// 时间范围：所有带时间的 MCP 工具共用的一个解析器
//
// 它要解决的问题只有一个：**「今天」在工具层原来不存在**。`get_context` 按小时从库里
// 最新一条观察往回滚、`recent_activity` 按分钟从现在往回滚、`search` 不给范围就是整个 grant
// 时间窗、schema 里的时间示例还写着 UTC——Agent 问「今天做了什么」时能拿到正文的三条路
// 没有一条切在自然日上，昨晚的、上周的内容就混进了今天（2026-09-10 实测：`get_context(24h)`
// 的窗口是 09-09 19:04 — 09-10 19:04，微信多出 173 条、ChatGPT 整条都是昨天的）。
//
// 修法是三条规矩，全部在这里与 `StoreMCPService` 里落实：
//   ① **一套语法**：`period` 字符串，所有工具同一个函数解析——
//        today / yesterday / this_week / last_week
//        YYYY-MM-DD                       某一自然日
//        YYYY-MM-DD..YYYY-MM-DD           自然日区间，**两端都含**（人说「8 号到 10 号」就是这个意思）
//        YYYY-Www                         ISO 周
//        <N>h / <N>m / <N>d               从**现在**往回滚（不再以库里最新一条观察为锚）
//      `start` / `end` 保留给精确边界：Unix 毫秒、ISO 8601（带时区偏移；不带的按服务端时区）、
//      裸日期（放在 `end` 位置取当天 24:00，也就是两端都含）。
//   ② **服务端解析、服务端回显、服务端报时**：按 `retrieval.timeZone` 解析；结果里回
//      `window`（真正用到的 [start, end)、当地时间戳、时区、来源）与 `serverNow` / `serverToday`，
//      Agent 不必知道今天几号、什么时区，也一眼能看出自己有没有限定范围。
//   ③ **优先级**：`start` / `end` > `period` > 工具默认；`period` 与 `start` / `end` 同时给
//      直接报错，不猜。grant 的时间窗仍是硬下界，被抬高时 `clippedByGrant = true`。
// =============================================================================

public struct TimeScope: Sendable, Equatable {

    /// 这个窗口是怎么来的。`default` 是"调用方什么都没给"——Agent 看到它就知道自己没限定范围。
    public enum Source: String, Sendable {
        case explicit, period, `default`
    }

    /// 半开区间 `[start, end)`，Unix 毫秒。`end == nil` = 上不封顶（只有 search / get_item
    /// 的默认窗口会这样：它们是找东西的工具，默认覆盖整个 grant 时间窗）。
    public var start: Int64
    public var end: Int64?
    /// 给人（和 Agent）看的标签：`2026-09-10`、`2026-09-08..2026-09-10`、`2026-W37`、`24h`，
    /// 精确边界时是两端的当地时间戳。
    public var label: String
    public var source: Source
    /// 调用方原样给的 `period`（小写、去空白），没给时为 nil。
    public var period: String?
    /// grant 时间窗把 `start` 抬高过。
    public var clippedByGrant: Bool

    public init(start: Int64, end: Int64?, label: String, source: Source,
                period: String? = nil, clippedByGrant: Bool = false) {
        self.start = start
        self.end = end
        self.label = label
        self.source = source
        self.period = period
        self.clippedByGrant = clippedByGrant
    }

    /// grant 时间窗是硬下界：`start` 只能更晚。
    public func clipped(toGrantStart windowStart: Int64) -> TimeScope {
        guard start < windowStart else { return self }
        var out = self
        out.start = windowStart
        out.clippedByGrant = true
        return out
    }

    /// 恰好是一个自然日时返回 `YYYY-MM-DD`，否则 nil（日台账只认单日）。
    public func singleDay(in timeZone: TimeZone) -> String? {
        let cal = DayCalendar(timeZone)
        let day = cal.dayString(start)
        guard let bounds = try? cal.dayBounds(day), bounds.start == start, bounds.end == end else {
            return nil
        }
        return day
    }

    /// 恰好是一个 ISO 周时返回 `YYYY-Www`，否则 nil（周台账只认整周）。
    public func singleWeek(in timeZone: TimeZone) -> String? {
        let cal = DayCalendar(timeZone)
        let weekStart = cal.bucketStart(start, .week)
        guard weekStart == start, cal.bucketEnd(weekStart, .week) == end else { return nil }
        return cal.bucketLabel(weekStart, .week)
    }

    /// 结果里回显的 `window` 块。
    func json(timeZone: TimeZone) -> JSONValue {
        let cal = DayCalendar(timeZone)
        return .object([
            "start": .int(start),
            "end": end.map { .int($0) } ?? .null,
            "startLocal": .string(cal.stamp(start)),
            "endLocal": end.map { .string(cal.stamp($0)) } ?? .null,
            "timeZone": .string(timeZone.identifier),
            "label": .string(label),
            "period": period.map { .string($0) } ?? .null,
            "resolvedFrom": .string(source.rawValue),
            "clippedByGrant": .bool(clippedByGrant),
        ])
    }
}

extension TimeScope {

    public static let periodGrammar =
        "today / yesterday / this_week / last_week / YYYY-MM-DD / YYYY-MM-DD..YYYY-MM-DD / YYYY-Www / <N>h / <N>m / <N>d"

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// 按第 ③ 条规矩解析一次调用的时间参数。
    ///
    /// - `fallback`：工具默认（nil = 这个工具必须给范围）。
    /// - 只给 `end` 不给 `start` 时，`start` 取默认窗口的起点（没有默认就报错）；
    ///   只给 `start` 不给 `end` 时上不封顶。
    public static func resolve(args: [String: JSONValue], now: Int64, timeZone: TimeZone,
                               default fallback: TimeScope?) throws -> TimeScope {
        let period = args["period"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let startGiven = args["start"].map { !$0.isNull } ?? false
        let endGiven = args["end"].map { !$0.isNull } ?? false

        if !period.isEmpty, startGiven || endGiven {
            throw MCPBadArgument(message: "period 与 start / end 只能给一种：要么 period=\"today\" 这样的范围，"
                                        + "要么 start / end 精确边界")
        }
        if startGiven || endGiven {
            let cal = DayCalendar(timeZone)
            let start = try parseInstant(args["start"], field: "start", isEnd: false, timeZone: timeZone)
            let end = try parseInstant(args["end"], field: "end", isEnd: true, timeZone: timeZone)
            guard let start = start ?? fallback?.start else {
                throw MCPBadArgument(message: "只给了 end 没给 start；这个工具没有默认起点，请补 start 或改用 period")
            }
            if let end, end <= start {
                throw MCPBadArgument(message: "时间区间要求 start < end（收到 \(cal.stamp(start)) — \(cal.stamp(end))）")
            }
            let label = end.map { "\(cal.stamp(start)) — \(cal.stamp($0))" } ?? "\(cal.stamp(start)) — （不封顶）"
            return TimeScope(start: start, end: end, label: label, source: .explicit)
        }
        if !period.isEmpty {
            return try parsePeriod(period, now: now, timeZone: timeZone)
        }
        guard let fallback else {
            throw MCPBadArgument(message: "需要时间范围：period（\(periodGrammar)）或 start / end")
        }
        return fallback
    }

    /// `period` 语法（大小写不敏感，前后空白忽略）。所有相对写法都以 `now` 为锚。
    public static func parsePeriod(_ raw: String, now: Int64, timeZone: TimeZone) throws -> TimeScope {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else {
            throw MCPBadArgument(message: "period 不能为空（可写 \(periodGrammar)）")
        }
        let cal = DayCalendar(timeZone)
        func dayBounds(_ s: String) throws -> (start: Int64, end: Int64) {
            do { return try cal.dayBounds(s) } catch {
                throw MCPBadArgument(message: "无法解析 period 里的日期 \(s)（要 YYYY-MM-DD）")
            }
        }
        func scope(_ start: Int64, _ end: Int64, _ label: String) -> TimeScope {
            TimeScope(start: start, end: end, label: label, source: .period, period: text)
        }

        switch text {
        case "today":
            let day = cal.dayString(now)
            let b = try dayBounds(day)
            return scope(b.start, b.end, day)
        case "yesterday":
            // 今天 00:00 的前一毫秒一定落在昨天，跨夏令时也成立。
            let todayStart = try dayBounds(cal.dayString(now)).start
            let day = cal.dayString(todayStart - 1)
            let b = try dayBounds(day)
            return scope(b.start, b.end, day)
        case "this_week", "last_week":
            var start = cal.bucketStart(now, .week)
            if text == "last_week" { start = cal.bucketStart(start - 1, .week) }
            return scope(start, cal.bucketEnd(start, .week), cal.bucketLabel(start, .week))
        default:
            break
        }

        // <N>h / <N>m / <N>d：从现在往回
        if let unit = text.last, "hmd".contains(unit), let n = Int64(text.dropLast()) {
            guard n >= 1, n <= 100_000 else {
                throw MCPBadArgument(message: "period 的数量要在 1…100000 之间：\(raw)")
            }
            let unitMS: Int64 = unit == "h" ? 3_600_000 : (unit == "m" ? 60_000 : 86_400_000)
            return scope(now - n * unitMS, now, "\(n)\(unit)")
        }

        // YYYY-MM-DD..YYYY-MM-DD（两端都含）
        if let dots = text.range(of: "..") {
            let a = String(text[..<dots.lowerBound]).trimmingCharacters(in: .whitespaces)
            let b = String(text[dots.upperBound...]).trimmingCharacters(in: .whitespaces)
            let ba = try dayBounds(a)
            let bb = try dayBounds(b)
            guard ba.start <= bb.start else {
                throw MCPBadArgument(message: "日期区间要求起点不晚于终点：\(raw)")
            }
            return scope(ba.start, bb.end, "\(a)..\(b)")
        }

        // YYYY-Www
        if text.count >= 7, text.dropFirst(4).hasPrefix("-w") {
            let weekCal = PatternCalendar(timeZone)
            let bounds: (start: Int64, end: Int64)
            do { bounds = try weekCal.weekBounds(text.uppercased()) } catch {
                throw MCPBadArgument(message: "\(error)")
            }
            return scope(bounds.start, bounds.end, weekCal.weekString(bounds.start))
        }

        // YYYY-MM-DD
        if text.count == 10, text.contains("-") {
            let b = try dayBounds(text)
            return scope(b.start, b.end, text)
        }

        throw MCPBadArgument(message: "无法解析 period：\(raw)（可写 \(periodGrammar)）")
    }

    /// 精确边界：Unix 毫秒（整数或数字串）、ISO 8601（带时区偏移；不带的按服务端时区）、
    /// 裸 `YYYY-MM-DD`（`start` 位置取当天 00:00，`end` 位置取当天 24:00）。
    public static func parseInstant(_ value: JSONValue?, field: String, isEnd: Bool,
                                    timeZone: TimeZone) throws -> Int64? {
        guard let value, !value.isNull else { return nil }
        if case .int(let ms) = value { return ms }
        if case .double(let ms) = value { return Int64(ms) }
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            throw MCPBadArgument(message: "\(field) 只能是 Unix 毫秒、ISO 8601 或 YYYY-MM-DD")
        }
        if let ms = Int64(text) { return ms }
        if text.count == 10, text.contains("-"),
           let bounds = try? DayCalendar(timeZone).dayBounds(text) {
            return isEnd ? bounds.end : bounds.start
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { return ms(d) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return ms(d) }
        // 不带时区偏移的写法按服务端时区——Agent 照系统提示里的日期写 `2026-09-10T00:00:00`
        // 时，它想说的就是当地 0 点，不该被当成 UTC。
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = format
            if let d = f.date(from: text) { return ms(d) }
        }
        throw MCPBadArgument(message: "无法解析 \(field)：\(text)（要 Unix 毫秒、ISO 8601 或 YYYY-MM-DD）")
    }
}
