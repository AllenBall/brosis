import Foundation

// =============================================================================
// 叙述任务的存储侧（计划 4.3「可选叙述」、3.7「输出与台账分开标注」、3.10、D19）
//
// 这一层负责四件事：
//   1. 把**确定性台账**折成一份叙述输入（`narrativeDayInput` / `narrativeWeekInput`）；
//   2. 挑出"该写而还没写"的日 / 周（`narrativeBacklog`）；
//   3. 跑一次完整的叙述（`runNarrative`）：构造 → 裁剪 → 生成（可重试一次）→
//      **忠实度核对** → 过了才入库、没过就丢弃并记事件；
//   4. 读写 `ledgers` 的 `narrative` / `model` / `narrative_meta` 三列。
//
// 这里**不加载任何模型**：模型藏在 `GenerationProvider` 后面，
// core 的用例用 `ScriptedGenerationProvider` 把整条路走完。
// =============================================================================

/// 一次叙述任务的目标。
public struct NarrativeTarget: Sendable, Codable, Equatable, Hashable {
    /// `day` / `week`
    public var level: String
    /// `YYYY-MM-DD` 或 `YYYY-Www`
    public var period: String
    public init(level: String, period: String) { self.level = level; self.period = period }

    public static func day(_ date: String) -> NarrativeTarget { .init(level: "day", period: date) }
    public static func week(_ week: String) -> NarrativeTarget { .init(level: "week", period: week) }
}

/// 库里存着的一条叙述。
public struct NarrativeRecord: Sendable, Codable, Equatable {
    public var level: String
    public var period: String
    public var text: String
    public var model: String?
    public var meta: NarrativeMeta?
    /// 台账行本身被标脏（3.8 的删除级联）。
    public var ledgerStale: Bool
    /// 叙述过期：台账行被标脏，或者 `meta.ledgerComputedAt` 与台账的 `computed_at` 对不上。
    public var stale: Bool
    /// 台账行的 `computed_at`。
    public var ledgerComputedAt: Int64
}

/// 跑一次叙述的结果。**无论过没过都返回**，调用方按 `saved` 判断。
public struct NarrativeRunReport: Sendable, Codable, Equatable {
    public var target: NarrativeTarget
    /// 通过忠实度核对并写进库了。
    public var saved: Bool
    /// `saved` / `rejected` / `skipped_stale` / `skipped_empty` / `failed`
    public var outcome: String
    public var model: String
    public var compression: String
    public var inputTokens: Int
    public var inputTokenSource: String
    public var outputTokens: Int
    public var promptCharacters: Int
    public var hanCharacters: Int
    public var truncated: Bool
    public var attempts: Int
    public var timeToFirstTokenSeconds: Double
    public var tokensPerSecond: Double
    public var elapsedSeconds: Double
    public var stopReason: String
    public var thinkingDetected: Bool
    public var check: NarrativeCheckReport?
    /// 生成出来的正文。没通过核对时**只在报告里**出现，不入库。
    public var text: String
    public var error: String?
}

extension Store {

    // MARK: - 1. 叙述输入（确定性）

    /// 某一天的叙述输入。台账走 `getDayLedger`（缓存有效就读缓存），
    /// 会话与屏幕文本摘录另取。
    ///
    /// - Parameter maxSessions: 最多带多少段会话（按停留时长降序取）。默认 24——
    ///   L0 渲染下 24 段约 2,000–3,000 token，离 8,000 的闸门还有两倍余量。
    public func narrativeDayInput(date: String, config: NarrativeConfig = NarrativeConfig(),
                                  maxSessions: Int = 24) throws -> NarrativeInput {
        let ledger = try getDayLedger(date: date)
        let sessions = try narrativeSessions(from: ledger.start, to: ledger.end,
                                             limit: maxSessions, config: config)
        // 应用的「时段」要裁进台账窗口：跨午夜的会话（前一天 23:41 开始）不裁的话，
        // 渲染出来是「23:41–18:52」这种看着就不对的区间，时段核对也会被撑到几乎全天。
        let (firstByApp, lastByApp) = Self.appSpans(sessions, clipTo: (ledger.start, ledger.end))
        let apps = ledger.apps.map { entry in
            NarrativeAppLine(bundleID: entry.key, name: entry.name ?? entry.key,
                             dwellS: entry.dwellS, activeS: entry.activeS,
                             switches: entry.switches,
                             firstTS: firstByApp[entry.key], lastTS: lastByApp[entry.key])
        }
        return NarrativeInput(
            level: "day", period: date, timeZone: ledger.timeZone,
            start: ledger.start, end: ledger.end,
            totalDwellS: ledger.totalDwellS, totalActiveS: ledger.totalActiveS,
            totalUnknownS: ledger.totalUnknownS, onlineUnionS: ledger.onlineUnionS,
            switches: ledger.switches, interruptions: ledger.interruptions,
            sessionCount: ledger.sessions, observations: ledger.observations,
            apps: apps,
            sites: ledger.sites.map { NarrativeKeyLine(key: $0.key, dwellS: $0.dwellS) },
            files: ledger.files.map { NarrativeKeyLine(key: $0.key, dwellS: $0.dwellS) },
            sessions: sessions, days: [],
            ledgerComputedAt: ledger.computedAt, stale: ledger.stale)
    }

    /// 某一周的叙述输入。
    ///
    /// 周台账走 `getWeekLedger`（3.6 / T14）——**先调它一次**，既保证
    /// `ledgers` 里那一行是新的（叙述要挂在它上面），也拿到 7 天逐字段之和；
    /// 每天一行的分布则由 7 份日台账给出，与周台账同源（周 = 7 天之和）。
    ///
    /// 会话只取整周里**最长的若干段**：周叙述谈的是分布与趋势，不是逐段回放。
    public func narrativeWeekInput(week: String, config: NarrativeConfig = NarrativeConfig(),
                                   maxSessions: Int = 12) throws -> NarrativeInput {
        let weekLedger = try getWeekLedger(weekStart: week)
        var days: [NarrativeDayLine] = []
        for date in weekLedger.days {
            let day = try getDayLedger(date: date)
            days.append(NarrativeDayLine(
                date: date, dwellS: day.totalDwellS, activeS: day.totalActiveS,
                sessions: day.sessions, switches: day.switches,
                topApps: day.apps.prefix(3).map { $0.name ?? $0.key }))
        }
        let sessions = try narrativeSessions(from: weekLedger.start, to: weekLedger.end,
                                             limit: maxSessions, config: config)
        let (firstByApp, lastByApp) = Self.appSpans(sessions,
                                                    clipTo: (weekLedger.start, weekLedger.end))
        let apps = weekLedger.apps.map { entry in
            NarrativeAppLine(bundleID: entry.key, name: entry.name ?? entry.key,
                             dwellS: entry.dwellS, activeS: entry.activeS,
                             switches: entry.switches,
                             firstTS: firstByApp[entry.key], lastTS: lastByApp[entry.key])
        }
        return NarrativeInput(
            level: "week", period: weekLedger.week, timeZone: weekLedger.timeZone,
            start: weekLedger.start, end: weekLedger.end,
            totalDwellS: weekLedger.totalDwellS, totalActiveS: weekLedger.totalActiveS,
            totalUnknownS: weekLedger.totalUnknownS, onlineUnionS: weekLedger.onlineUnionS,
            switches: weekLedger.switches, interruptions: weekLedger.interruptions,
            sessionCount: weekLedger.sessions, observations: weekLedger.observations,
            apps: apps,
            sites: weekLedger.sites.map { NarrativeKeyLine(key: $0.key, dwellS: $0.dwellS) },
            files: weekLedger.files.map { NarrativeKeyLine(key: $0.key, dwellS: $0.dwellS) },
            sessions: sessions, days: days,
            ledgerComputedAt: weekLedger.computedAt, stale: weekLedger.stale)
    }

    /// 每个应用在窗口内的首末时刻（会话时刻先裁进 `[start, end)`）。
    static func appSpans(_ sessions: [NarrativeSessionLine], clipTo range: (Int64, Int64))
        -> (first: [String: Int64], last: [String: Int64]) {
        var first: [String: Int64] = [:]
        var last: [String: Int64] = [:]
        let upper = max(range.0, range.1 - 1)
        for session in sessions {
            let from = max(session.start, range.0)
            let to = min(session.end, upper)
            guard to >= from else { continue }
            first[session.bundleID] = min(first[session.bundleID] ?? from, from)
            last[session.bundleID] = max(last[session.bundleID] ?? to, to)
        }
        return (first, last)
    }

    /// 时间窗内最长的若干段会话，带窗口标题与屏幕文本摘录。
    ///
    /// 摘录口径：这一段会话里**最早的那条观察**的正文（一次捕获 = 一段完整可见正文，E7 口径），
    /// 裁到 `config.excerptCharacters`；正文里带待办标记时整段打 `hasTODO`。
    /// 选"最早的一条"而不是"最长的一条"，是为了让摘录与会话的开始时刻对得上——
    /// 时段核对那条规则要靠它。
    func narrativeSessions(from start: Int64, to end: Int64, limit: Int,
                           config: NarrativeConfig) throws -> [NarrativeSessionLine] {
        let rows = try sessions(from: start, to: end, includeStale: false)
        let picked = rows.sorted { $0.dwellS == $1.dwellS ? $0.start < $1.start : $0.dwellS > $1.dwellS }
            .prefix(limit)
            .sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        guard !picked.isEmpty else { return [] }
        let anchors = picked.compactMap { $0.observationIDs.min() }
        let (bodies, metas) = try withLock { conn -> ([Int64: String], [Int64: ObservationMeta]) in
            (try snippetSources(anchors, conn: conn), try observationMetas(anchors, conn: conn))
        }
        return picked.map { row in
            let anchor = row.observationIDs.min()
            let raw = anchor.flatMap { bodies[$0] } ?? ""
            let excerpt = NarrativePromptBuilder.clip(raw, to: config.excerptCharacters)
            let title = anchor.flatMap { metas[$0]?.windowTitle } ?? ""
            return NarrativeSessionLine(
                start: row.start, end: row.end,
                bundleID: row.appBundleID ?? "unknown",
                appName: row.appName ?? row.appBundleID ?? "未知应用",
                dwellS: row.dwellS, interruptions: row.interruptions,
                windowTitles: title.isEmpty ? [] : [title],
                excerpt: excerpt,
                // 待办标记按**原文**判（裁剪之后可能把 TODO 那一行裁掉了，
                // 但"这段里有未完成的事"这个事实不因为裁剪而消失）。
                hasTODO: NarrativeText.hasTODO(raw))
        }
    }

    // MARK: - 2. 读 / 写 / 清除叙述

    /// 读一条叙述。行不存在或 `narrative` 为空时返回 nil。
    public func narrativeRecord(level: String, period: String) throws -> NarrativeRecord? {
        try withLock { conn in
            let st = try conn.prepare("""
                SELECT narrative, model, narrative_meta, stale, computed_at FROM ledgers
                 WHERE device_id = ? AND level = ? AND period = ?;
                """)
            defer { st.finalize() }
            try st.bind([.text(deviceID), .text(level), .text(period)])
            guard try st.step(), let text = st.text(0), !text.isEmpty else { return nil }
            let meta = st.text(2).flatMap {
                try? JSONDecoder().decode(NarrativeMeta.self, from: Data($0.utf8))
            }
            let ledgerStale = (st.int(3) ?? 0) == 1
            let computedAt = st.int(4) ?? 0
            let mismatched = meta.map { $0.ledgerComputedAt != computedAt } ?? true
            return NarrativeRecord(level: level, period: period, text: text, model: st.text(1),
                                   meta: meta, ledgerStale: ledgerStale,
                                   stale: ledgerStale || mismatched,
                                   ledgerComputedAt: computedAt)
        }
    }

    /// 把一条叙述写进 `ledgers` 的三列。**台账行必须已经存在**——
    /// 叙述是台账的标注，不能凭空造出一行台账来挂它（3.7）。
    public func saveNarrative(level: String, period: String, text: String,
                              model: String, meta: NarrativeMeta) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let metaJSON = String(decoding: try encoder.encode(meta), as: UTF8.self)
        try withLock { conn in
            let rows = try conn.run("""
                UPDATE ledgers SET narrative = ?, model = ?, narrative_meta = ?
                 WHERE device_id = ? AND level = ? AND period = ? AND computed_at = ?;
                """, [.text(text), .text(model), .text(metaJSON),
                      .text(deviceID), .text(level), .text(period),
                      .int(meta.ledgerComputedAt)])
            guard rows == 1 else {
                // computed_at 对不上 = 台账在我们生成的这几秒里被重算了。
                // 这时候叙述已经作废，**不能**硬写进去。
                throw StoreError.invalidUsage(
                    "写叙述失败：\(level)/\(period) 的台账行不存在，或者已经在生成期间被重算"
                    + "（期望 computed_at = \(meta.ledgerComputedAt)）")
            }
        }
    }

    /// 清掉一条叙述（台账重算、用户关闭功能、或者核对没过时用）。
    @discardableResult
    public func clearNarrative(level: String, period: String) throws -> Bool {
        try withLock { conn in
            let rows = try conn.run("""
                UPDATE ledgers SET narrative = NULL, model = NULL, narrative_meta = NULL
                 WHERE device_id = ? AND level = ? AND period = ?;
                """, [.text(deviceID), .text(level), .text(period)])
            return rows > 0
        }
    }

    // MARK: - 3. 待办清单

    /// 该写而还没写的日 / 周。**只看已经过完的自然日 / 自然周**（今天的台账还在长）。
    ///
    /// 判定顺序：
    /// 1. 库里有观察的自然日里，取最近 `config.backlogDays` 天且**早于今天**的；
    /// 2. 逐个读 `ledgers`：没有叙述、或者叙述过期（台账重算过）的，进清单；
    /// 3. 周同理，取最近 4 周里已经过完的。
    ///
    /// 它**不加载模型、不写库**，所以界面上随时可以调它来显示"还欠几天"。
    public func narrativeBacklog(config: NarrativeConfig = NarrativeConfig(),
                                 now: Date = Date()) throws -> [NarrativeTarget] {
        let cal = DayCalendar(retrieval.timeZone)
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        let today = cal.dayString(nowMS)
        var out: [NarrativeTarget] = []

        if config.dailyEnabled {
            let days = try observationDays().filter { $0 < today }.suffix(config.backlogDays)
            for date in days {
                let record = try narrativeRecord(level: "day", period: date)
                if record == nil || record?.stale == true { out.append(.day(date)) }
            }
        }

        if config.weeklyEnabled {
            // 已经过完的周：周结束时刻 ≤ 现在。最多回看 4 周。
            let weekCal = PatternCalendar(retrieval.timeZone)
            let finished = try observationWeeks()
                .filter { week in
                    guard let bounds = try? weekCal.weekBounds(week) else { return false }
                    return bounds.end <= nowMS
                }
                .suffix(4)
            for week in finished {
                let record = try narrativeRecord(level: "week", period: week)
                if record == nil || record?.stale == true { out.append(.week(week)) }
            }
        }
        return out
    }

    // MARK: - 4. 跑一次叙述

    /// 构造 → 裁剪 → 生成（失败重试 `config.generation.retries` 次）→ 忠实度核对 →
    /// 过了入库、没过丢弃并记事件。
    ///
    /// **没过的叙述一个字都不入库**：`jobs` 里只留一行 `runtime_event:narrative_rejected`，
    /// `input_ref` 记违规规则与计量（不含正文）。
    @discardableResult
    public func runNarrative(_ target: NarrativeTarget, provider: some GenerationProvider,
                             config: NarrativeConfig = NarrativeConfig(),
                             now: Date = Date(),
                             thermalState: String? = nil,
                             peakFootprintMiB: Double? = nil) throws -> NarrativeRunReport {
        let requested = target
        let input = requested.level == "week"
            ? try narrativeWeekInput(week: requested.period, config: config)
            : try narrativeDayInput(date: requested.period, config: config)
        // `getWeekLedger` 允许用周内任意一天来指周（`2026-08-23` ⇒ `2026-W34`），
        // 而 `ledgers` 行的 period 存的是**规范化之后**的那个字符串。
        // 后面写库、记事件、报告一律用规范化的 target，不然 UPDATE 会一行都命中不到。
        let target = NarrativeTarget(level: input.level, period: input.period)

        func empty(_ outcome: String, error: String? = nil) -> NarrativeRunReport {
            NarrativeRunReport(
                target: target, saved: false, outcome: outcome, model: provider.modelID,
                compression: "-", inputTokens: 0, inputTokenSource: "-", outputTokens: 0,
                promptCharacters: 0, hanCharacters: 0, truncated: false, attempts: 0,
                timeToFirstTokenSeconds: 0, tokensPerSecond: 0, elapsedSeconds: 0,
                stopReason: "-", thinkingDetected: false, check: nil, text: "", error: error)
        }

        guard !input.stale else { return empty("skipped_stale") }
        guard input.observations > 0 else { return empty("skipped_empty") }

        // 提示：能拿到真实分词器就用真值，拿不到就用 core 的估算器。
        var tokenSource = "estimate"
        let counter: (String) -> Int = { text in
            if let real = provider.tokenCount(text) { tokenSource = "tokenizer"; return real }
            return NarrativeTokens.estimate(text)
        }
        let prompt = NarrativePromptBuilder.build(input, config: config, tokenCount: counter)

        var attempts = 0
        var lastError: Error?
        var result: GenerationResult?
        let maxAttempts = max(1, 1 + config.generation.retries)
        while attempts < maxAttempts {
            attempts += 1
            do {
                result = try provider.generate(system: prompt.system, prompt: prompt.user,
                                               options: config.generation)
                break
            } catch {
                lastError = error
            }
        }
        guard let generated = result else {
            var report = empty("failed", error: lastError.map { "\($0)" })
            report.attempts = attempts
            report.compression = prompt.compression.label
            report.inputTokens = prompt.estimatedTokens
            report.inputTokenSource = tokenSource
            report.promptCharacters = prompt.user.count
            _ = try? recordRuntimeEvent(
                kind: "narrative_failed",
                detail: "{\"level\":\"\(target.level)\",\"period\":\"\(target.period)\","
                      + "\"attempts\":\(attempts)}")
            return report
        }

        let check = NarrativeFaithfulness.check(generated.text, facts: prompt.facts,
                                                config: config,
                                                thinkingDetected: generated.thinkingDetected)
        var report = NarrativeRunReport(
            target: target, saved: false, outcome: check.passed ? "saved" : "rejected",
            model: provider.modelID, compression: prompt.compression.label,
            inputTokens: prompt.estimatedTokens, inputTokenSource: tokenSource,
            outputTokens: generated.generationTokens, promptCharacters: prompt.user.count,
            hanCharacters: check.hanCharacters, truncated: check.truncated, attempts: attempts,
            timeToFirstTokenSeconds: generated.timeToFirstTokenSeconds,
            tokensPerSecond: generated.tokensPerSecond, elapsedSeconds: generated.elapsedSeconds,
            stopReason: generated.stopReason, thinkingDetected: generated.thinkingDetected,
            check: check, text: check.text, error: nil)

        guard check.passed else {
            let rules = check.violations.map(\.rule).sorted().joined(separator: ",")
            _ = try? recordRuntimeEvent(
                kind: "narrative_rejected",
                detail: "{\"level\":\"\(target.level)\",\"period\":\"\(target.period)\","
                      + "\"rules\":\"\(rules)\",\"violations\":\(check.violations.count),"
                      + "\"input_tokens\":\(prompt.estimatedTokens),"
                      + "\"output_tokens\":\(generated.generationTokens),"
                      + "\"compression\":\"\(prompt.compression.label)\"}",
                at: Int64(now.timeIntervalSince1970 * 1000))
            return report
        }

        let meta = NarrativeMeta(
            model: provider.modelID, generatedAt: Int64(now.timeIntervalSince1970 * 1000),
            inputTokens: prompt.estimatedTokens, inputTokenSource: tokenSource,
            outputTokens: generated.generationTokens, compression: prompt.compression.label,
            faithfulnessChecked: true, checkedNumbers: check.checkedNumbers,
            checkedApps: check.checkedApps, truncated: check.truncated,
            ledgerComputedAt: input.ledgerComputedAt,
            timeToFirstTokenSeconds: generated.timeToFirstTokenSeconds,
            tokensPerSecond: generated.tokensPerSecond, elapsedSeconds: generated.elapsedSeconds,
            thermalState: thermalState, peakFootprintMiB: peakFootprintMiB)
        do {
            try saveNarrative(level: target.level, period: target.period, text: check.text,
                              model: provider.modelID, meta: meta)
        } catch {
            report.saved = false
            report.outcome = "failed"
            report.error = "\(error)"
            return report
        }
        report.saved = true
        _ = try? recordRuntimeEvent(
            kind: "narrative_run",
            detail: "{\"level\":\"\(target.level)\",\"period\":\"\(target.period)\","
                  + "\"model\":\"\(provider.modelID)\","
                  + "\"input_tokens\":\(prompt.estimatedTokens),"
                  + "\"output_tokens\":\(generated.generationTokens),"
                  + "\"compression\":\"\(prompt.compression.label)\","
                  + "\"han\":\(check.hanCharacters),"
                  + "\"ttft_s\":\(String(format: "%.3f", generated.timeToFirstTokenSeconds)),"
                  + "\"tok_per_s\":\(String(format: "%.2f", generated.tokensPerSecond)),"
                  + "\"thermal\":\"\(thermalState ?? "-")\"}",
            at: Int64(now.timeIntervalSince1970 * 1000))
        return report
    }
}
