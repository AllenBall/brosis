import Foundation

// =============================================================================
// 周与小时的日历工具（周台账 / get_patterns 用）
//
// 为什么不直接扩 `DayCalendar`：它的 `Calendar` 实例是 `private`，扩展写在别的文件里
// 拿不到；而周台账与热力图要按 ISO 周、按当地小时切，需要同一份配置。
// 这里**原样复制它的三行配置**（公历、firstWeekday = 2 也就是周一、minimumDaysInFirstWeek = 4），
// 并由 `PatternCalendarTests` 断言两者对同一批时刻给出同样的 `dayString` 与同样的周标签——
// 复制的代价是可能配错，那条用例就是用来兜这个的。
// =============================================================================

struct PatternCalendar {
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

    /// ISO 周标签 `YYYY-Www`。
    func weekString(_ ts: Int64) -> String {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date(ts))
        return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
    }

    /// 1 = 周一 … 7 = 周日。`Calendar.component(.weekday)` 是 1 = 周日，这里换成 ISO 编号。
    func weekdayIndex(_ ts: Int64) -> Int {
        let w = calendar.component(.weekday, from: date(ts))     // 1 = 周日 … 7 = 周六
        return ((w + 5) % 7) + 1
    }

    func hourOfDay(_ ts: Int64) -> Int {
        calendar.component(.hour, from: date(ts))
    }

    /// 这一时刻所在 ISO 周的周一 00:00。
    func weekStart(_ ts: Int64) -> Int64 {
        var c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date(ts))
        c.weekday = calendar.firstWeekday
        guard let d = calendar.date(from: c) else { return ms(calendar.startOfDay(for: date(ts))) }
        return ms(calendar.startOfDay(for: d))
    }

    /// 周一 00:00 → 下周一 00:00（跨夏令时时不是 604800000 ms，所以走日历加法）。
    func weekEnd(_ weekStart: Int64) -> Int64 {
        ms(calendar.date(byAdding: .weekOfYear, value: 1, to: date(weekStart)) ?? date(weekStart))
    }

    /// 周一 00:00 起的 7 个自然日起点。
    func daysOfWeek(_ weekStart: Int64) -> [Int64] {
        var out: [Int64] = []
        var cursor = weekStart
        for _ in 0..<7 {
            out.append(cursor)
            let next = calendar.date(byAdding: .day, value: 1, to: date(cursor)) ?? date(cursor)
            cursor = ms(calendar.startOfDay(for: next))
        }
        return out
    }

    /// 把 `YYYY-MM-DD`（周内任意一天）或 `YYYY-Www` 解析成这一周的 `[周一 00:00, 下周一 00:00)`。
    func weekBounds(_ spec: String) throws -> (start: Int64, end: Int64) {
        let text = spec.trimmingCharacters(in: .whitespaces)
        if let wIndex = text.firstIndex(where: { $0 == "W" || $0 == "w" }),
           text.distance(from: text.startIndex, to: wIndex) == 5, text.count >= 7 {
            // YYYY-Www
            let yearPart = String(text[text.startIndex..<text.index(text.startIndex, offsetBy: 4)])
            let weekPart = String(text[text.index(after: wIndex)...])
            guard let year = Int(yearPart), let week = Int(weekPart) else {
                throw StoreError.invalidUsage("周要写成 YYYY-Www 或 YYYY-MM-DD：\(spec)")
            }
            guard (1...53).contains(week) else {
                throw StoreError.invalidUsage("ISO 周编号只能是 1…53，收到 \(week)（\(spec)）")
            }
            var c = DateComponents()
            c.yearForWeekOfYear = year
            c.weekOfYear = week
            c.weekday = calendar.firstWeekday
            guard let d = calendar.date(from: c) else {
                throw StoreError.invalidUsage("无法解析周：\(spec)")
            }
            let start = ms(calendar.startOfDay(for: d))
            // 跨年的第 53 周在有些年份不存在，日历会折回上一周；折回了就明说，不假装算对了。
            guard weekString(start) == String(format: "%04d-W%02d", year, week) else {
                throw StoreError.invalidUsage("\(spec) 这一周不存在（ISO 周编号最多到 52 或 53）")
            }
            return (start, weekEnd(start))
        }
        // YYYY-MM-DD：取这一天所在的那一周
        let parts = text.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else {
            throw StoreError.invalidUsage("周要写成 YYYY-Www 或 YYYY-MM-DD：\(spec)")
        }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d
        comps.hour = 0; comps.minute = 0; comps.second = 0
        guard let day = calendar.date(from: comps) else {
            throw StoreError.invalidUsage("无法解析日期：\(spec)")
        }
        let start = weekStart(ms(day))
        return (start, weekEnd(start))
    }

    /// `[start, end)` 覆盖到的整点边界：`[小时起点0, 小时起点1, …]`，首个 ≤ start、末个 ≥ end。
    ///
    /// 走日历加法而不是 `+3600000`：夏令时切换的那一天有 23 或 25 个小时，
    /// 直接加毫秒会让那天之后的所有格子错一小时。
    /// 上限是防手滑（问一百年的小时热力），不是业务约束。
    func hourBoundaries(from start: Int64, to end: Int64, limit: Int = 200_000) throws -> [Int64] {
        guard end > start else { return [] }
        let first = calendar.dateComponents([.year, .month, .day, .hour], from: date(start))
        var cursor = calendar.date(from: first) ?? date(start)
        var out: [Int64] = [ms(cursor)]
        while ms(cursor) < end {
            guard out.count <= limit else {
                throw StoreError.invalidUsage("区间太长：小时格子超过 \(limit) 个，请缩小区间")
            }
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
            out.append(ms(cursor))
        }
        return out
    }

    /// `YYYY-MM-DD HH:mm`（与 `DayCalendar.stamp` 同一个格式）。
    func stamp(_ ts: Int64) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date(ts))
        return String(format: "%04d-%02d-%02d %02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}
