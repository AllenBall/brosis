import Foundation

// =============================================================================
// 可选叙述：类型、提示构造、裁剪、忠实度自检（计划 4.3「可选叙述」、3.7、3.10、D19、D27）
//
// 这个文件里**一行模型代码都没有**：它只做三件确定性的事——
//   1. 把台账压成一份可喂给模型的提示（超过 token 上限就按 4.3.2 的算法逐级压缩）；
//   2. 定义提供方抽象的生成侧接口 `GenerationProvider`（3.10 的 `generate`，本轮只做本地实现）；
//   3. 对模型写出来的叙述做**确定性核对**，不通过就丢弃。
//
// 之所以整段放在 core 而不是 app：core 保持零 mlx 依赖（T11 的结论），
// 这样 `swift test --package-path core` 不必编译 mlx-swift 就能把整条叙述路径
// （构造 → 裁剪 → 生成 → 核对 → 入库 / 丢弃）用一个脚本化的假提供方跑完。
//
// D19 实测给这里定下的三条硬约束（`tools/bench/results/d19_qwen35_4b_air_2026-09-07.md`）：
//   * **必须 `enable_thinking = false`**：思考模式在 Air 上 4,000 token / 124 s 仍不收敛，
//     一个答案都拿不到。另加「若真的进了思考段、N 个 token 之内没见 `</think>` 就中止」的保险。
//   * **输入上限 8,000 token**：预填稳定在约 340 tok/s，8,000 token 的 TTFT 约 23.5 s；
//     262K 的名义上下文在这台机器上不可用。
//   * **叙述忠实度只有 8 条中 6 条**：两处偏差是「把 TODO 说成已完成」与「把上午说成下午」。
//     所以提示词里显式禁止这两件事，**并且**在核对里各写一条规则去抓。
// =============================================================================

// MARK: - token 估算（确定性，不需要分词器）

/// 叙述提示的 token 估算。
///
/// core 里没有分词器（那要拉 swift-transformers 与模型目录），所以用一个**按字符类别加权**的
/// 估算器，口径是「**只高不低**」——高估只会让我们比必要时早一级压缩，低估会让 8,000 的闸门失守。
///
/// 权重与校准（D19 的三份真实提示，真值取 `promptTokens`）：
///
/// | 提示 | 字符 | 真值 token | 本估算器 | 比值 |
/// |---|---:|---:|---:|---:|
/// | `prompt_b_narrative.txt` | 1,543 | 837 | 1,046 | 1.25 |
/// | `prompt_e_long_4k.txt` | 6,170 | 3,664 | 4,046 | 1.10 |
/// | `prompt_e_long.txt` | 8,875 | 5,354 | 5,568 | 1.04 |
///
/// 三点都高估，长文本上收敛到 +4%。
public enum NarrativeTokens {

    /// 汉字 / 假名 / 谚文：1 token。
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,          // 平假名 / 片假名
             0x3400...0x4DBF,          // CJK 扩展 A
             0x4E00...0x9FFF,          // CJK 基本区
             0xF900...0xFAFF,          // CJK 兼容
             0xAC00...0xD7AF:          // 谚文
            return true
        default:
            return false
        }
    }

    static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }

    /// 一段文本的估算 token 数。
    public static func estimate(_ text: String) -> Int {
        var total = 0.0
        for scalar in text.unicodeScalars {
            if isWide(scalar) {
                total += 1.0
            } else if isASCIIAlphanumeric(scalar) {
                total += 0.5
            } else if scalar.properties.isWhitespace {
                total += 1.0 / 3.0
            } else {
                total += 1.0
            }
        }
        return Int(total.rounded(.up))
    }

    /// 聊天模板 + 生成前缀的固定开销（Qwen3.5 的 `chat_template.jinja` 在
    /// `enable_thinking = false` 时还会多吐一段 `<think>\n\n</think>\n\n`）。
    public static let templateOverhead = 48

    /// 系统指令 + 正文 + 模板开销的合计估算。闸门按它判。
    public static func estimateRequest(system: String?, prompt: String) -> Int {
        estimate(system ?? "") + estimate(prompt) + templateOverhead
    }
}

// MARK: - 提供方抽象（3.10 的 generate 侧；本轮只做本地实现）

/// 生成参数。3.10 要求「温度 0、关闭思考模式、失败重试一次」对本地与线上一致。
public struct GenerationOptions: Sendable, Codable, Equatable {
    /// 生成 token 上限。D19：一次叙述 147 token，400 足够且给足余量。
    public var maxTokens: Int = 400
    /// **必须是 0**（3.10）。留成参数只是为了让测试能证明"产品路径传的是 0"。
    public var temperature: Float = 0
    public var topP: Float = 1
    /// **必须是 false**（D19 硬性约束）。
    public var enableThinking: Bool = false
    /// 墙钟超时（秒）。超时就中止，已生成的部分**不入库**。
    /// D19：8,000 token 输入的 TTFT 约 23.5 s，加 400 token 生成约 11 s，60 s 有 2 倍余量。
    public var timeoutSeconds: Double = 60
    /// 「进了思考段就中止」的保险（D19）：输出里出现 `<think>` 之后，
    /// 再生成这么多 token 仍没见到 `</think>` 就当场中止。
    public var thinkingAbortTokens: Int = 48
    /// 失败重试次数（3.10「失败重试一次」）。
    public var retries: Int = 1

    public init() {}
}

/// 一次生成的结果与计量。字段口径与 `tools/e9` 的 `generate` 子命令一致，
/// 这样结果文件里的数字能和 D19 的表直接对上。
public struct GenerationResult: Sendable, Codable, Equatable {
    /// 已经剥掉思考段（若有）并去掉首尾空白的答案。
    public var text: String
    public var promptTokens: Int
    public var generationTokens: Int
    public var promptTokensPerSecond: Double
    public var tokensPerSecond: Double
    /// 首 token 时延（秒）。
    public var timeToFirstTokenSeconds: Double
    public var elapsedSeconds: Double
    /// `maxTokens` / `stop` / `timeout` / `thinking_not_closed` / …
    public var stopReason: String
    /// 输出里出现过 `<think>`。**产品路径上应当恒为 false**。
    public var thinkingDetected: Bool

    public init(text: String, promptTokens: Int = 0, generationTokens: Int = 0,
                promptTokensPerSecond: Double = 0, tokensPerSecond: Double = 0,
                timeToFirstTokenSeconds: Double = 0, elapsedSeconds: Double = 0,
                stopReason: String = "stop", thinkingDetected: Bool = false) {
        self.text = text
        self.promptTokens = promptTokens
        self.generationTokens = generationTokens
        self.promptTokensPerSecond = promptTokensPerSecond
        self.tokensPerSecond = tokensPerSecond
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.elapsedSeconds = elapsedSeconds
        self.stopReason = stopReason
        self.thinkingDetected = thinkingDetected
    }
}

/// 3.10 的 `generate(prompt, schema?)`。**本轮只写本地实现**（用户指示：不接线上模型）。
///
/// core 只有协议；本地 mlx 实现在 `app/Sources/BrosisModels/MLXGenerationProvider.swift`，
/// 由 app 注入。协议是同步的，理由与 `EmbeddingProvider` 相同：`Store` 是一把锁的同步类。
public protocol GenerationProvider: Sendable {
    /// 模型标识，原样写进 `ledgers.model`。
    var modelID: String { get }
    /// 真实分词器的 token 数；拿不到就返回 nil，调用方退回 `NarrativeTokens.estimate`。
    func tokenCount(_ text: String) -> Int?
    func generate(system: String?, prompt: String, options: GenerationOptions) throws -> GenerationResult
}

public extension GenerationProvider {
    func tokenCount(_ text: String) -> Int? { nil }
}

/// 测试与自检用的**脚本化**提供方：给什么就回什么，不加载任何模型。
///
/// 它让 core 的用例能把「构造 → 裁剪 → 生成 → 核对 → 入库 / 丢弃」整条路走完，
/// 而不必依赖本机装没装 2.85 GiB 的权重。
public struct ScriptedGenerationProvider: GenerationProvider {
    public let modelID: String
    private let answers: [String]
    private let stopReason: String
    private let thinkingDetected: Bool
    private let failFirst: Bool
    // 只在同一个进程里给测试计数用；`Store` 侧不依赖它。
    private final class Counter: @unchecked Sendable { var value = 0 }
    private let counter = Counter()

    public init(modelID: String = "scripted-test-model", answers: [String],
                stopReason: String = "stop", thinkingDetected: Bool = false,
                failFirst: Bool = false) {
        self.modelID = modelID
        self.answers = answers
        self.stopReason = stopReason
        self.thinkingDetected = thinkingDetected
        self.failFirst = failFirst
    }

    public var callCount: Int { counter.value }

    public func generate(system: String?, prompt: String,
                         options: GenerationOptions) throws -> GenerationResult {
        counter.value += 1
        if failFirst && counter.value == 1 {
            throw StoreError.invalidUsage("脚本化提供方：第一次故意失败（测重试一次）")
        }
        let index = min(counter.value - 1, answers.count - 1)
        let text = answers.isEmpty ? "" : answers[index]
        return GenerationResult(
            text: text,
            promptTokens: NarrativeTokens.estimateRequest(system: system, prompt: prompt),
            generationTokens: NarrativeTokens.estimate(text),
            promptTokensPerSecond: 0, tokensPerSecond: 0,
            timeToFirstTokenSeconds: 0, elapsedSeconds: 0,
            stopReason: stopReason, thinkingDetected: thinkingDetected)
    }
}

// MARK: - 叙述的确定性输入（台账的裁剪版）

/// 台账里的一个应用（叙述输入用）。
public struct NarrativeAppLine: Sendable, Codable, Equatable {
    public var bundleID: String
    public var name: String
    public var dwellS: Double
    public var activeS: Double
    public var switches: Int
    /// 当天该应用最早 / 最晚的会话时刻（毫秒）。**时段核对用**，没有会话时是 nil。
    public var firstTS: Int64?
    public var lastTS: Int64?

    public init(bundleID: String, name: String, dwellS: Double, activeS: Double,
                switches: Int, firstTS: Int64? = nil, lastTS: Int64? = nil) {
        self.bundleID = bundleID; self.name = name
        self.dwellS = dwellS; self.activeS = activeS; self.switches = switches
        self.firstTS = firstTS; self.lastTS = lastTS
    }
}

/// 台账里的一个站点 / 文件（只有 key 与时长）。
public struct NarrativeKeyLine: Sendable, Codable, Equatable {
    public var key: String
    public var dwellS: Double
    public init(key: String, dwellS: Double) { self.key = key; self.dwellS = dwellS }
}

/// 一段会话（叙述输入用）。
public struct NarrativeSessionLine: Sendable, Codable, Equatable {
    public var start: Int64
    public var end: Int64
    public var bundleID: String
    public var appName: String
    public var dwellS: Double
    public var interruptions: Int
    public var windowTitles: [String]
    /// 屏幕文本摘录（已按预算裁剪）。
    public var excerpt: String
    /// 摘录里带待办标记（`TODO` / `待办` / `FIXME` / `需要` / `尚未` / `暂未`）。
    public var hasTODO: Bool

    public init(start: Int64, end: Int64, bundleID: String, appName: String,
                dwellS: Double, interruptions: Int, windowTitles: [String],
                excerpt: String, hasTODO: Bool) {
        self.start = start; self.end = end
        self.bundleID = bundleID; self.appName = appName
        self.dwellS = dwellS; self.interruptions = interruptions
        self.windowTitles = windowTitles; self.excerpt = excerpt; self.hasTODO = hasTODO
    }
}

/// 周叙述里的一天。
public struct NarrativeDayLine: Sendable, Codable, Equatable {
    public var date: String
    public var dwellS: Double
    public var activeS: Double
    public var sessions: Int
    public var switches: Int
    public var topApps: [String]
    public init(date: String, dwellS: Double, activeS: Double, sessions: Int,
                switches: Int, topApps: [String]) {
        self.date = date; self.dwellS = dwellS; self.activeS = activeS
        self.sessions = sessions; self.switches = switches; self.topApps = topApps
    }
}

/// 一次叙述的**全部确定性输入**。它由台账算出来，本身不含任何模型产物。
public struct NarrativeInput: Sendable, Codable, Equatable {
    /// `day` / `week`
    public var level: String
    /// `YYYY-MM-DD` 或 `YYYY-Www`
    public var period: String
    public var timeZone: String
    public var start: Int64
    public var end: Int64
    public var totalDwellS: Double
    public var totalActiveS: Double
    public var totalUnknownS: Double
    public var onlineUnionS: Double
    public var switches: Int
    public var interruptions: Int
    public var sessionCount: Int
    public var observations: Int
    public var apps: [NarrativeAppLine]
    public var sites: [NarrativeKeyLine]
    public var files: [NarrativeKeyLine]
    public var sessions: [NarrativeSessionLine]
    public var days: [NarrativeDayLine]
    /// 台账算出来的时刻。**叙述与它绑定**：台账重算 ⇒ 这个数变 ⇒ 旧叙述作废。
    public var ledgerComputedAt: Int64
    /// 台账本身是不是 `stale`。stale 的台账不生成叙述。
    public var stale: Bool

    public init(level: String, period: String, timeZone: String, start: Int64, end: Int64,
                totalDwellS: Double, totalActiveS: Double, totalUnknownS: Double,
                onlineUnionS: Double, switches: Int, interruptions: Int, sessionCount: Int,
                observations: Int, apps: [NarrativeAppLine], sites: [NarrativeKeyLine],
                files: [NarrativeKeyLine], sessions: [NarrativeSessionLine],
                days: [NarrativeDayLine], ledgerComputedAt: Int64, stale: Bool) {
        self.level = level; self.period = period; self.timeZone = timeZone
        self.start = start; self.end = end
        self.totalDwellS = totalDwellS; self.totalActiveS = totalActiveS
        self.totalUnknownS = totalUnknownS; self.onlineUnionS = onlineUnionS
        self.switches = switches; self.interruptions = interruptions
        self.sessionCount = sessionCount; self.observations = observations
        self.apps = apps; self.sites = sites; self.files = files
        self.sessions = sessions; self.days = days
        self.ledgerComputedAt = ledgerComputedAt; self.stale = stale
    }
}

// MARK: - 配置

/// 叙述任务的可配置项（4.3「每天一次日叙述、每周一次周叙述（可配置）」）。
public struct NarrativeConfig: Sendable, Codable, Equatable {
    public var dailyEnabled: Bool = true
    public var weeklyEnabled: Bool = true
    /// 周叙述在**周几之后**才生成（1 = 周一 … 7 = 周日，ISO）。默认周日结束后。
    public var weeklyGeneratedAfterWeekday: Int = 7
    /// 输入 token 上限（D19：8,000，TTFT 约 23.5 s）。
    public var maxInputTokens: Int = 8_000
    /// 输出上限（token）。
    public var maxOutputTokens: Int = 400
    /// 输出上限（**汉字数**）。D19 结论 5：长度约束不能只写在提示词里，代码要截断。
    public var maxHanCharacters: Int = 150
    /// 每段会话摘录的字符预算（L0 级）。
    public var excerptCharacters: Int = 160
    /// 往回补多少个自然日的叙述（补课上限）。
    public var backlogDays: Int = 7
    public var generation = GenerationOptions()

    public init() {}
}

// MARK: - 提示构造与逐级压缩

/// 压缩等级。**顺序即算法**：从 L0 开始，第一个估算 token ≤ 上限的等级就是最终等级。
public enum NarrativeCompression: Int, Sendable, Codable, CaseIterable, Comparable {
    /// 全量：概览 + 全部应用 + 站点 / 文件各前 10 + 全部会话（含窗口标题与摘录）。
    case full = 0
    /// 应用前 12、站点 / 文件各前 5、会话前 12，摘录裁到 3/4。
    case trimmed = 1
    /// 应用前 10，去掉站点与文件，会话**按应用合并**成一行（只留最长一段的摘录）。
    case bySession = 2
    /// 应用前 8，只留概览 + 应用表 + 待办清单（≤ 5 条）。
    case byApp = 3
    /// 兜底：概览 + 应用前 5，没有会话。
    case minimal = 4

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .full: "full"
        case .trimmed: "trimmed"
        case .bySession: "session_summary"
        case .byApp: "app_summary"
        case .minimal: "minimal"
        }
    }
}

/// 构造好的提示 + 核对时要用的事实集合。
public struct NarrativePrompt: Sendable, Equatable {
    public var system: String
    public var user: String
    public var compression: NarrativeCompression
    /// 估算 token（`NarrativeTokens.estimateRequest`）。
    public var estimatedTokens: Int
    /// 是否在最低等级之后仍然超限、只能硬截断。
    public var hardTruncated: Bool
    public var facts: NarrativeFacts
}

public enum NarrativePromptBuilder {

    /// 系统指令。三条禁令分别对应 D19 实测到的三种问题：编造、把 TODO 说成已完成、把上午说成下午。
    public static let systemInstruction = """
        你是一个只依据台账写作的助手。严格遵守以下规则：
        1. 只依据下面给出的台账写作，禁止编造台账中没有的应用、人名、数字，也不要推测原因。
        2. 台账里标着「待办（未完成）」的事项，禁止写成已解决、已完成、已修复、已搞定。
        3. 时段必须按台账给出的时刻写：00:00–06:00 是凌晨，06:00–12:00 是上午，
           12:00–18:00 是下午，18:00–24:00 是晚上。不得把上午的事写成下午。
        4. 直接输出叙述正文。不要输出思考过程、不要解释、不要 Markdown 围栏、不要列表。
        5. 不超过 150 个汉字。
        """

    /// 按配置构造提示，超限就逐级压缩。**没有随机数**：同一份输入两次构造逐字相同。
    public static func build(_ input: NarrativeInput, config: NarrativeConfig = NarrativeConfig(),
                             tokenCount: ((String) -> Int)? = nil) -> NarrativePrompt {
        let count: (String) -> Int = { text in
            tokenCount?(text) ?? NarrativeTokens.estimate(text)
        }
        let systemTokens = count(systemInstruction) + NarrativeTokens.templateOverhead
        var chosen = NarrativeCompression.minimal
        var body = ""
        var tokens = 0
        for level in NarrativeCompression.allCases {
            let candidate = render(input, level: level, config: config)
            let candidateTokens = systemTokens + count(candidate)
            chosen = level
            body = candidate
            tokens = candidateTokens
            if candidateTokens <= config.maxInputTokens { break }
        }
        var hardTruncated = false
        if tokens > config.maxInputTokens {
            // 兜底等级仍然超限（几百个应用的极端库）：按字符硬截断。
            // 用估算器的最保守权重（1 token/字符）折算，保证截完一定在闸门内。
            let budget = max(0, config.maxInputTokens - systemTokens)
            body = String(body.prefix(budget)) + "\n（台账过长，已截断）"
            tokens = systemTokens + count(body)
            hardTruncated = true
        }
        return NarrativePrompt(system: systemInstruction, user: body, compression: chosen,
                               estimatedTokens: tokens, hardTruncated: hardTruncated,
                               facts: NarrativeFacts(input: input, promptBody: body))
    }

    // MARK: 渲染

    static func render(_ input: NarrativeInput, level: NarrativeCompression,
                       config: NarrativeConfig) -> String {
        let cal = NarrativeClock(timeZone: TimeZone(identifier: input.timeZone) ?? .current)
        var lines: [String] = []
        lines.append(input.level == "week"
            ? "【周台账】\(input.period)（时区 \(input.timeZone)）"
            : "【日台账】\(input.period)（时区 \(input.timeZone)）")
        lines.append("总计：前台停留 \(duration(input.totalDwellS))，"
                   + "有输入的活跃 \(duration(input.totalActiveS))，"
                   + "未知 \(duration(input.totalUnknownS))，"
                   + "总在线 \(duration(input.onlineUnionS))；"
                   + "应用切换 \(input.switches) 次，会话 \(input.sessionCount) 段，"
                   + "打断 \(input.interruptions) 次，观察 \(input.observations) 条。")

        if !input.days.isEmpty {
            lines.append("")
            lines.append("【每天】")
            for day in input.days {
                lines.append("- \(day.date)：停留 \(duration(day.dwellS))、"
                           + "活跃 \(duration(day.activeS))、会话 \(day.sessions) 段、"
                           + "切换 \(day.switches) 次，主要应用 "
                           + (day.topApps.isEmpty ? "无" : day.topApps.joined(separator: "、")))
            }
        }

        let appLimit: Int
        switch level {
        case .full: appLimit = input.apps.count
        case .trimmed: appLimit = 12
        case .bySession: appLimit = 10
        case .byApp: appLimit = 8
        case .minimal: appLimit = 5
        }
        lines.append("")
        lines.append("【应用】")
        for app in input.apps.prefix(appLimit) {
            var line = "- \(app.name)：停留 \(duration(app.dwellS))、活跃 \(duration(app.activeS))、"
                     + "切换 \(app.switches) 次"
            if let first = app.firstTS, let last = app.lastTS {
                line += "，时段 \(cal.clock(first))–\(cal.clock(last))"
            }
            lines.append(line)
        }

        if level <= .trimmed {
            let keyLimit = level == .full ? 10 : 5
            if !input.sites.isEmpty {
                lines.append("")
                lines.append("【站点】" + input.sites.prefix(keyLimit)
                    .map { "\($0.key)（\(duration($0.dwellS))）" }.joined(separator: "、"))
            }
            if !input.files.isEmpty {
                lines.append("【文件】" + input.files.prefix(keyLimit)
                    .map { "\($0.key)（\(duration($0.dwellS))）" }.joined(separator: "、"))
            }
        }

        switch level {
        case .full, .trimmed:
            let sessionLimit = level == .full ? input.sessions.count : 12
            let excerptBudget = level == .full
                ? config.excerptCharacters : config.excerptCharacters * 3 / 4
            if !input.sessions.isEmpty {
                lines.append("")
                lines.append("【会话】")
                for session in input.sessions.prefix(sessionLimit) {
                    lines.append(sessionLine(session, cal: cal, excerptBudget: excerptBudget))
                }
            }
        case .bySession:
            let merged = mergeByApp(input.sessions)
            if !merged.isEmpty {
                lines.append("")
                lines.append("【会话摘要（按应用合并）】")
                for group in merged.prefix(10) {
                    var line = "- \(group.appName)：\(group.count) 段，共 \(duration(group.dwellS))，"
                             + "\(cal.clock(group.start))–\(cal.clock(group.end))"
                    if !group.excerpt.isEmpty {
                        line += "；摘录：" + clip(group.excerpt, to: 100)
                    }
                    if group.hasTODO { line += "；含待办（未完成）" }
                    lines.append(line)
                }
            }
        case .byApp, .minimal:
            break
        }

        // `.byApp` 把会话整段丢掉了，但**待办必须留着**：规则 2 全靠它。
        // `.minimal` 是兜底，连待办也不留（那一级只在几百个应用的极端库上才会被选中）。
        if level == .byApp {
            let todos = input.sessions.filter(\.hasTODO)
            if !todos.isEmpty {
                lines.append("")
                lines.append("【待办（未完成，禁止写成已完成）】")
                for session in todos.prefix(5) {
                    lines.append("- \(cal.clock(session.start)) \(session.appName)："
                               + clip(session.excerpt, to: 60))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func sessionLine(_ session: NarrativeSessionLine, cal: NarrativeClock,
                            excerptBudget: Int) -> String {
        var line = "- \(cal.clock(session.start))–\(cal.clock(session.end)) \(session.appName)"
        if let title = session.windowTitles.first, !title.isEmpty {
            line += "《\(clip(title, to: 60))》"
        }
        line += "，停留 \(duration(session.dwellS))"
        if session.interruptions > 0 { line += "，打断 \(session.interruptions) 次" }
        if !session.excerpt.isEmpty {
            line += "\n  屏幕文本：" + clip(session.excerpt, to: excerptBudget)
        }
        if session.hasTODO {
            line += "\n  待办（未完成）：这段里的事项尚未完成，不得写成已完成。"
        }
        return line
    }

    struct MergedSessions {
        var appName: String
        var count: Int
        var dwellS: Double
        var start: Int64
        var end: Int64
        var excerpt: String
        var hasTODO: Bool
    }

    /// 按应用合并会话。顺序按总停留降序、同长按应用名升序（确定性）。
    static func mergeByApp(_ sessions: [NarrativeSessionLine]) -> [MergedSessions] {
        var order: [String] = []
        var map: [String: MergedSessions] = [:]
        var longest: [String: Double] = [:]
        for session in sessions {
            if var existing = map[session.appName] {
                existing.count += 1
                existing.dwellS += session.dwellS
                existing.start = min(existing.start, session.start)
                existing.end = max(existing.end, session.end)
                existing.hasTODO = existing.hasTODO || session.hasTODO
                if session.dwellS > (longest[session.appName] ?? -1), !session.excerpt.isEmpty {
                    existing.excerpt = session.excerpt
                    longest[session.appName] = session.dwellS
                }
                map[session.appName] = existing
            } else {
                order.append(session.appName)
                longest[session.appName] = session.excerpt.isEmpty ? -1 : session.dwellS
                map[session.appName] = MergedSessions(
                    appName: session.appName, count: 1, dwellS: session.dwellS,
                    start: session.start, end: session.end,
                    excerpt: session.excerpt, hasTODO: session.hasTODO)
            }
        }
        return order.compactMap { map[$0] }
            .sorted { $0.dwellS == $1.dwellS ? $0.appName < $1.appName : $0.dwellS > $1.dwellS }
    }

    /// 时长的固定写法。**核对时的数字白名单就是从这些渲染结果里抓的**，所以写法必须唯一。
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return "\(total / 3600) 小时 \((total % 3600) / 60) 分"
        } else if total >= 60 {
            return "\(total / 60) 分 \(total % 60) 秒"
        }
        return "\(total) 秒"
    }

    static func clip(_ text: String, to limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit, limit > 1 else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }
}

/// 固定时区的时刻渲染（`HH:mm`）。台账里已经有 `DayCalendar`，但那是包内私有的；
/// 这里只需要一个 `HH:mm`，不值得把它整个 public 化。
struct NarrativeClock {
    let timeZone: TimeZone
    private let calendar: Calendar

    init(timeZone: TimeZone) {
        self.timeZone = timeZone
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        calendar = cal
    }

    func clock(_ ms: Int64) -> String {
        let c = calendar.dateComponents([.hour, .minute],
                                        from: Date(timeIntervalSince1970: Double(ms) / 1000))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 一个时刻落在哪几个「时段词」里。
    func hour(_ ms: Int64) -> Int {
        calendar.component(.hour, from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

// MARK: - 忠实度自检的事实集合

/// 核对时用到的全部事实。**从渲染好的提示正文里抓**——
/// 这样"叙述里的数字必须在台账里"这句话的口径就是"必须在模型真正看见的那份文本里"，
/// 不会出现"台账里有但被压缩掉了、模型其实没看见"的假通过。
public struct NarrativeFacts: Sendable, Equatable {
    /// 台账里出现过的数字（已归一：去前导 0、去小数末尾 0）。
    public var numbers: Set<String>
    /// 台账里的应用（按别名组归一后的组名）。
    public var appGroups: Set<String>
    /// 台账里的应用展示名（原样，报告用）。
    public var appNames: [String]
    /// 台账里的应用展示名 → 组名。
    ///
    /// 为什么要它：别名词表只认得住它收录的那些名字，台账里那个叫「Code」的应用
    /// （VS Code 的展示名）就落在词表外——那样它既不会被判成编造（对），
    /// **也不会被做时段核对**（不对）。所以时段那条规则额外按台账自己的展示名匹配一遍：
    /// 这些名字本来就在台账里，只会**开启**时段核对，永远不会被判成编造。
    public var appNameToGroup: [String: String]
    /// 每个应用组覆盖到的小时（0…23）。时段核对用。
    public var appHours: [String: Set<Int>]
    /// 待办条目里抽出来的关键词（≥ 2 个汉字或 ≥ 3 个 ASCII 字母的连续串）。
    public var todoTerms: Set<String>
    /// 已经明确"做完了"的条目里抽出来的关键词。它们会从 `todoTerms` 里减掉。
    public var doneTerms: Set<String>
    public var timeZone: String

    public init(input: NarrativeInput, promptBody: String) {
        timeZone = input.timeZone
        numbers = NarrativeText.numbers(in: promptBody)
        let clock = NarrativeClock(timeZone: TimeZone(identifier: input.timeZone) ?? .current)

        var groups: Set<String> = []
        var names: [String] = []
        var hours: [String: Set<Int>] = [:]
        var nameToGroup: [String: String] = [:]

        // 时段核对**优先按会话逐段算**，只有一个会话都没进输入的应用才退回
        // 「首末时刻之间」这个粗口径。
        //
        // 两条都要先把时刻裁进台账窗口：跨午夜的会话（前一天 23:41 开始、今天 00:01 结束）
        // 也会出现在今天的会话表里，不裁的话这个应用「今天活跃的小时」会从 23 点起铺满一整天。
        // 而「首末时刻之间」还会把中间的空档一并算进去（09:00 与 18:00 各一段，
        // 粗口径会把 10–17 点也算上），所以有会话时一律不用它。
        let upper = max(input.start, input.end - 1)
        for session in input.sessions {
            let group = NarrativeLexicon.group(for: session.appName)
                ?? NarrativeLexicon.group(for: session.bundleID)
                ?? NarrativeLexicon.key(session.appName)
            groups.insert(group)
            if session.appName.count >= 2 { nameToGroup[session.appName] = group }
            let from = max(session.start, input.start)
            let to = min(session.end, upper)
            guard to >= from else { continue }
            hours[group, default: []].formUnion(NarrativeText.hours(from: from, to: to,
                                                                   clock: clock))
        }
        for app in input.apps {
            let group = NarrativeLexicon.group(for: app.name)
                ?? NarrativeLexicon.group(for: app.bundleID)
                ?? NarrativeLexicon.key(app.name)
            groups.insert(group)
            names.append(app.name)
            if app.name.count >= 2 { nameToGroup[app.name] = group }
            guard hours[group]?.isEmpty ?? true else { continue }
            if let first = app.firstTS, let last = app.lastTS {
                let from = max(first, input.start)
                let to = min(last, upper)
                if to >= from {
                    hours[group, default: []].formUnion(NarrativeText.hours(from: from, to: to,
                                                                           clock: clock))
                }
            }
        }
        appGroups = groups
        appNames = names
        appNameToGroup = nameToGroup
        appHours = hours

        var todo: Set<String> = []
        var done: Set<String> = []
        for session in input.sessions {
            let terms = NarrativeText.terms(in: session.excerpt)
            if session.hasTODO {
                todo.formUnion(terms)
            } else if NarrativeText.containsAny(session.excerpt, NarrativeText.doneMarkers) {
                done.formUnion(terms)
            }
        }
        // 同一个词既出现在待办里又出现在"已完成"的证据里时，不当作待办词——
        // 否则"编译通过"这种两边都有的词会把正确的叙述判成违规。
        todoTerms = todo.subtracting(done)
        doneTerms = done
    }
}

// MARK: - 忠实度自检

public struct NarrativeViolation: Sendable, Codable, Equatable {
    /// `fabricated_number` / `fabricated_app` / `todo_claimed_done` / `wrong_time_band` /
    /// `thinking_detected` / `empty`
    public var rule: String
    public var detail: String
    public init(rule: String, detail: String) { self.rule = rule; self.detail = detail }
}

public struct NarrativeCheckReport: Sendable, Codable, Equatable {
    public var passed: Bool
    public var violations: [NarrativeViolation]
    /// 核对时用到的叙述文本（已按汉字数截断）。
    public var text: String
    public var hanCharacters: Int
    public var truncated: Bool
    /// 核对里比对过的数字个数与应用名个数（报告用）。
    public var checkedNumbers: Int
    public var checkedApps: Int
}

/// 确定性的忠实度核对。**四条规则**，全是纯字符串判定，没有模型参与。
///
/// | 规则 | 抓什么 | 依据 |
/// |---|---|---|
/// | `fabricated_number` | 叙述里出现台账里没有的数字 | 4.3「出现的数字必须在台账里」 |
/// | `fabricated_app` | 叙述里出现台账里没有的应用 | 4.3「出现的应用名必须在台账里」 |
/// | `todo_claimed_done` | 一句话里同时出现待办关键词与「解决 / 完成」类词 | D19 偏差 1 |
/// | `wrong_time_band` | 一句话里把某应用放进它没有活动的时段 | D19 偏差 2 |
///
/// **已知边界（写在这里免得被当成没做）**：
/// * 只查 ASCII 数字串，中文数字（「三次」）不查——台账里的数字一律用阿拉伯数字渲染，
///   模型改写成中文数字属于措辞而不是编造，硬查会造成大量假阳。
/// * 应用名靠**别名词表**（`NarrativeLexicon`）识别：词表外的生造名字抓不到。
///   词表覆盖本项目适配与常见的 60 余个应用，D19 那次实测的 8 个应用全在内。
/// * 时段核对只在**同一句话里同时出现时段词与应用名**时生效。
public enum NarrativeFaithfulness {

    public static func check(_ raw: String, facts: NarrativeFacts,
                             config: NarrativeConfig = NarrativeConfig(),
                             thinkingDetected: Bool = false) -> NarrativeCheckReport {
        var violations: [NarrativeViolation] = []
        let clamped = NarrativeText.clampHan(raw, limit: config.maxHanCharacters)
        let text = clamped.text

        if thinkingDetected {
            violations.append(NarrativeViolation(rule: "thinking_detected",
                                                 detail: "输出里出现了 <think> 段（D19：必须关思考模式）"))
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            violations.append(NarrativeViolation(rule: "empty", detail: "叙述为空"))
            return NarrativeCheckReport(passed: false, violations: violations, text: text,
                                        hanCharacters: clamped.hanCharacters,
                                        truncated: clamped.truncated,
                                        checkedNumbers: 0, checkedApps: 0)
        }

        // ---- 1. 数字 ----
        let used = NarrativeText.numbers(in: text)
        for number in used.sorted() where !facts.numbers.contains(number) {
            violations.append(NarrativeViolation(
                rule: "fabricated_number", detail: "台账里没有这个数字：\(number)"))
        }

        // ---- 2. 应用名 ----
        let mentioned = NarrativeLexicon.mentionedGroups(in: text)
        for group in mentioned.sorted() where !facts.appGroups.contains(group) {
            violations.append(NarrativeViolation(
                rule: "fabricated_app", detail: "台账里没有这个应用：\(group)"))
        }

        // ---- 3 与 4：逐句判 ----
        for sentence in NarrativeText.sentences(text) {
            // 3. 待办不得写成已完成。
            //    命中条件（两条之一，见 `NarrativeText.todoHits` 的注释）：
            //    一个 ≥ 3 字的待办词，或两个不同的 2 字待办词。
            if NarrativeText.containsAny(sentence, NarrativeText.completionMarkers) {
                let hits = NarrativeText.todoHits(sentence: sentence, terms: facts.todoTerms)
                if !hits.isEmpty {
                    violations.append(NarrativeViolation(
                        rule: "todo_claimed_done",
                        detail: "「\(hits.joined(separator: "、"))」在台账里是待办（未完成），"
                              + "这句却写成已完成：\(sentence)"))
                }
            }
            // 4. 时段
            let bands = NarrativeText.bands(in: sentence)
            guard !bands.isEmpty else { continue }
            // 词表认得的 + 台账自己的展示名（后者只开启时段核对，见 `appNameToGroup` 的注释）
            let apps = NarrativeLexicon.mentionedGroups(in: sentence)
                .union(NarrativeLexicon.mentionedLedgerApps(in: sentence,
                                                            names: facts.appNameToGroup))
            for app in apps.sorted() {
                guard let hours = facts.appHours[app], !hours.isEmpty else { continue }
                let ok = bands.contains { band in !band.hours.isDisjoint(with: hours) }
                if !ok {
                    let names = bands.map(\.name).joined(separator: "/")
                    violations.append(NarrativeViolation(
                        rule: "wrong_time_band",
                        detail: "\(app) 在台账里没有落在「\(names)」这个时段：\(sentence)"))
                }
            }
        }

        return NarrativeCheckReport(
            passed: violations.isEmpty, violations: violations, text: text,
            hanCharacters: clamped.hanCharacters, truncated: clamped.truncated,
            checkedNumbers: used.count, checkedApps: mentioned.count)
    }
}

// MARK: - 文本工具（全部确定性）

public enum NarrativeText {

    /// 待办标记。摘录里出现任一条就算这段带待办。
    public static let todoMarkers = ["TODO", "todo", "To-do", "FIXME", "fixme", "XXX:",
                                     "待办", "未完成", "尚未", "暂未", "还没", "需要补", "遗留"]
    /// "做完了"的证据词。用来把两边都出现的词从待办词表里减掉。
    public static let doneMarkers = ["完成", "通过", "成功", "已修", "解决", "succeeded",
                                     "passed", "Build succeeded", "0 failures"]
    /// 叙述里的"完成"类断言词。
    public static let completionMarkers = ["解决", "完成", "修复", "搞定", "已修", "修好",
                                           "处理完", "结束了", "fixed", "resolved", "done"]

    public static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    /// 一段文本里有没有待办标记。
    public static func hasTODO(_ text: String) -> Bool { containsAny(text, todoMarkers) }

    /// 抽出全部 ASCII 数字串并归一：去前导 0（保留至少一位）、去小数末尾的 0 与小数点。
    public static func numbers(in text: String) -> Set<String> {
        var out: Set<String> = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            out.insert(normalizeNumber(current))
            current = ""
        }
        let scalars = Array(text.unicodeScalars)
        for (i, s) in scalars.enumerated() {
            if s.value >= 0x30 && s.value <= 0x39 {
                current.unicodeScalars.append(s)
            } else if s == "." && !current.isEmpty
                        && i + 1 < scalars.count
                        && scalars[i + 1].value >= 0x30 && scalars[i + 1].value <= 0x39
                        && !current.contains(".") {
                current.unicodeScalars.append(s)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    static func normalizeNumber(_ raw: String) -> String {
        var text = raw
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        while text.count > 1 && text.hasPrefix("0") { text.removeFirst() }
        return text.isEmpty ? "0" : text
    }

    /// 关键词：连续 ≥ 2 个汉字，或连续 ≥ 3 个 ASCII 字母 / 数字。
    public static func terms(in text: String) -> Set<String> {
        var out: Set<String> = []
        var cjk = ""
        var ascii = ""
        func flushCJK() {
            if cjk.count >= 2 {
                // 连续汉字串再切出所有 2–4 字的子串，好让"锁屏切换漏事件"这种长串
                // 与叙述里的"锁屏"能对上。
                let chars = Array(cjk)
                for length in 2...min(4, chars.count) {
                    for start in 0...(chars.count - length) {
                        out.insert(String(chars[start..<(start + length)]))
                    }
                }
            }
            cjk = ""
        }
        func flushASCII() {
            if ascii.count >= 3 { out.insert(ascii) }
            ascii = ""
        }
        for scalar in text.unicodeScalars {
            if NarrativeTokens.isWide(scalar) {
                flushASCII()
                cjk.unicodeScalars.append(scalar)
            } else if NarrativeTokens.isASCIIAlphanumeric(scalar) {
                flushCJK()
                ascii.unicodeScalars.append(scalar)
            } else {
                flushCJK(); flushASCII()
            }
        }
        flushCJK(); flushASCII()
        // 功能词与"完成"类词不当关键词，否则待办里一句"尚未完成"就会让叙述里任何
        // 带"完成"的句子全部违规。
        return out.subtracting(stopTerms)
    }

    /// 关键词里要剔掉的词（功能词 + 完成类词 + 时段词）。
    static let stopTerms: Set<String> = {
        var out: Set<String> = ["需要", "已经", "可以", "这个", "那个", "一条", "一个",
                                "问题", "事项", "现在", "还有", "没有", "以及", "而且",
                                "监听", "之后", "之前", "然后", "同时"]
        out.formUnion(completionMarkers)
        out.formUnion(doneMarkers)
        out.formUnion(todoMarkers)
        out.formUnion(allBands.map(\.name))
        return out
    }()

    /// 一句话里命中的待办关键词。
    ///
    /// **两条命中条件**（这是把"抓得住 D19 那次偏差"与"不误伤正常叙述"之间那条线画在哪里）：
    /// 1. 命中一个 ≥ 3 个汉字（或 ≥ 3 个 ASCII 字符）的待办词；或
    /// 2. 命中 **2 个以上不同的** 2 字待办词。
    ///
    /// D19 的原句「随后在 Xcode 中完善 FrontmostObserver 逻辑，解决锁屏切换漏事件问题」
    /// 同时命中「锁屏」「切换」「事件」三个 2 字词，走条件 2。
    /// 而「完成 34 项测试」这种只蹭到一个「测试」的句子不算违规——
    /// 单个 2 字词的重合在中文里太常见，按它判会把正确的叙述也丢掉。
    public static func todoHits(sentence: String, terms: Set<String>) -> [String] {
        var short: [String] = []
        for term in terms.sorted() where sentence.contains(term) {
            if term.count >= 3 { return [term] }
            short.append(term)
        }
        return short.count >= 2 ? short : []
    }

    /// 按中英文句末符号切句（分隔符不进结果）。
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            if "。！？；\n；!?;".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            } else {
                current.append(character)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { out.append(trimmed) }
        return out
    }

    /// 时段词与它覆盖的小时。与系统指令里写给模型的那份口径**必须一致**。
    public struct Band: Sendable, Equatable {
        public var name: String
        public var hours: Set<Int>
    }

    public static let allBands: [Band] = [
        Band(name: "凌晨", hours: Set(0..<6)),
        Band(name: "早上", hours: Set(5..<9)),
        Band(name: "早晨", hours: Set(5..<9)),
        Band(name: "上午", hours: Set(6..<12)),
        Band(name: "中午", hours: Set(11..<14)),
        Band(name: "下午", hours: Set(12..<18)),
        Band(name: "傍晚", hours: Set(17..<19)),
        Band(name: "晚上", hours: Set(18..<24)),
        Band(name: "夜里", hours: Set(22..<24).union(Set(0..<4))),
        Band(name: "深夜", hours: Set(22..<24).union(Set(0..<4))),
    ]

    public static func bands(in sentence: String) -> [Band] {
        allBands.filter { sentence.contains($0.name) }
    }

    static func hours(from start: Int64, to end: Int64, clock: NarrativeClock) -> Set<Int> {
        guard end >= start else { return [clock.hour(start)] }
        var out: Set<Int> = []
        var cursor = start
        // 一小时一步，最多走 25 步（跨日的会话按天切过了，不会更长）。
        var steps = 0
        while cursor <= end && steps <= 25 {
            out.insert(clock.hour(cursor))
            cursor += 3_600_000
            steps += 1
        }
        out.insert(clock.hour(end))
        return out
    }

    /// 按**汉字数**截断（D19 结论 5：长度约束不能只靠提示词）。
    /// 优先切在句末符号上；整段一个句号都没有时硬截并补省略号。
    public static func clampHan(_ text: String, limit: Int)
        -> (text: String, hanCharacters: Int, truncated: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let total = hanCount(trimmed)
        guard total > limit, limit > 0 else { return (trimmed, total, false) }
        var kept = ""
        var lastSentenceEnd: String.Index?
        var count = 0
        for character in trimmed {
            if character.unicodeScalars.allSatisfy({ NarrativeTokens.isWide($0) }) { count += 1 }
            if count > limit { break }
            kept.append(character)
            if "。！？".contains(character) { lastSentenceEnd = kept.endIndex }
        }
        if let end = lastSentenceEnd {
            let result = String(kept[kept.startIndex..<end])
            return (result, hanCount(result), true)
        }
        return (kept + "…", hanCount(kept), true)
    }

    public static func hanCount(_ text: String) -> Int {
        text.reduce(0) { partial, character in
            character.unicodeScalars.allSatisfy { NarrativeTokens.isWide($0) } ? partial + 1 : partial
        }
    }
}

// MARK: - 应用别名词表

/// 应用名的别名词表。**只用来做"叙述里提到的应用是不是台账里的"这一条判定**，
/// 不参与采集、不参与检索、不写进库。
///
/// 一组别名共用一个组名（组里的第一个）。台账里出现组内任一别名，整组就算"台账里有"；
/// 叙述里出现组内任一别名而台账里没有这一组，就是编造。
public enum NarrativeLexicon {

    /// 每组第一个是组名。
    ///
    /// **中文别名只收"基本不会当普通名词用"的那些**（飞书 / 微信 / 终端 / 备忘录 …）。
    /// 「预览」「照片」「地图」「音乐」「日历」「邮件」这类既是应用名又是常用名词的词
    /// **故意不收**：收了之后，一句「预览了文档」会被判成"台账里没有 Preview 这个应用"，
    /// 把本来正确的叙述丢掉。漏抓一个真编造，代价远小于误杀一条正确叙述。
    public static let groups: [[String]] = [
        ["飞书", "Lark", "Feishu", "com.electron.lark"],
        ["微信", "WeChat", "com.tencent.xinWeChat"],
        ["QQ", "com.tencent.qq"],
        ["钉钉", "DingTalk"],
        ["Safari", "com.apple.Safari"],
        ["Chrome", "谷歌浏览器", "com.google.Chrome"],
        ["Firefox", "火狐", "org.mozilla.firefox"],
        ["Edge", "com.microsoft.edgemac"],
        ["Arc", "company.thebrowser.Browser"],
        ["Xcode", "com.apple.dt.Xcode"],
        ["Terminal", "终端", "com.apple.Terminal"],
        ["iTerm", "com.googlecode.iterm2"],
        ["VS Code", "Visual Studio Code", "VSCode", "com.microsoft.VSCode"],
        ["IntelliJ", "PyCharm", "GoLand", "WebStorm"],
        ["Android Studio"],
        ["Notes", "备忘录", "com.apple.Notes"],
        ["Notion"],
        ["Obsidian", "md.obsidian"],
        ["Figma", "com.figma.Desktop"],
        ["Sketch"],
        ["Photoshop"],
        ["Illustrator"],
        ["Music", "com.apple.Music"],
        ["Spotify"],
        ["Outlook", "com.microsoft.Outlook"],
        ["Reminders"],
        ["Finder", "访达", "com.apple.finder"],
        ["Slack", "com.tinyspeck.slackmacgap"],
        ["Discord"],
        ["Telegram"],
        ["Zoom", "us.zoom.xos"],
        ["Excel", "com.microsoft.Excel"],
        ["PowerPoint", "com.microsoft.Powerpoint"],
        ["Keynote", "com.apple.iWork.Keynote"],
        ["Postman"],
        ["Docker"],
        ["TablePlus"],
        ["Sublime Text"],
        ["MacVim"],
        ["Emacs"],
        ["Simulator", "模拟器", "com.apple.iphonesimulator"],
        ["System Settings", "系统设置", "com.apple.systempreferences"],
        ["App Store", "com.apple.AppStore"],
        ["1Password", "com.1password.1password"],
        ["Bitwarden"],
        ["知乎"],
        ["微博"],
        ["抖音"],
        ["哔哩哔哩", "Bilibili"],
        ["GitHub Desktop"],
        ["Warp"],
        ["Alacritty"],
    ]

    /// 词表里所有别名 → 组名（按 `key` 归一）。
    static let aliasToGroup: [String: String] = {
        var out: [String: String] = [:]
        for group in groups {
            guard let name = group.first else { continue }
            for alias in group { out[key(alias)] = name }
        }
        return out
    }()

    /// 整名查表用的归一：去空白、转小写。
    public static func key(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "").lowercased()
    }

    /// 一个名字（展示名或 bundle id）属于哪个组；词表里没有就返回 nil。
    public static func group(for name: String) -> String? {
        if let hit = aliasToGroup[key(name)] { return hit }
        // bundle id 形如 com.foo.Bar：拿最后一段再试一次。
        if name.contains("."), let last = name.split(separator: ".").last {
            return aliasToGroup[key(String(last))]
        }
        return nil
    }

    /// 纯 ASCII 的别名（含 `.` `-` `_`）——匹配时要求**词边界**。
    static func isASCIIAlias(_ alias: String) -> Bool {
        alias.unicodeScalars.allSatisfy {
            NarrativeTokens.isASCIIAlphanumeric($0) || $0 == "." || $0 == "-"
                || $0 == "_" || $0 == " "
        }
    }

    /// 带词边界的子串查找（左右两侧都不能是 ASCII 字母数字）。
    ///
    /// 没有它的话「search」里会找出「arc」、「keyword」里会找出「word」，
    /// 一句正常的中文叙述能凭空"提到"两三个应用。
    static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let h = Array(haystack.unicodeScalars)
        let n = Array(needle.unicodeScalars)
        guard h.count >= n.count else { return false }
        for start in 0...(h.count - n.count) {
            guard Array(h[start..<(start + n.count)]) == n else { continue }
            let beforeOK = start == 0 || !NarrativeTokens.isASCIIAlphanumeric(h[start - 1])
            let afterIndex = start + n.count
            let afterOK = afterIndex == h.count
                || !NarrativeTokens.isASCIIAlphanumeric(h[afterIndex])
            if beforeOK && afterOK { return true }
        }
        return false
    }

    /// 一段文本里提到了**台账自己那些应用**中的哪几个（按展示名匹配，返回组名）。
    ///
    /// 只服务于时段核对：这些名字都来自台账，不参与"是不是编造"的判定。
    public static func mentionedLedgerApps(in text: String,
                                           names: [String: String]) -> Set<String> {
        let haystack = text.lowercased()
        var out: Set<String> = []
        for (name, group) in names {
            let needle = name.lowercased()
            let hit = isASCIIAlias(name) ? containsWord(haystack, needle)
                                         : haystack.contains(needle)
            if hit { out.insert(group) }
        }
        return out
    }

    /// 一段文本里提到了哪些组。ASCII 别名按词边界匹配，中文别名按子串匹配。
    public static func mentionedGroups(in text: String) -> Set<String> {
        let haystack = text.lowercased()
        var out: Set<String> = []
        for group in groups {
            guard let name = group.first else { continue }
            let hit = group.contains { alias in
                let needle = alias.lowercased()
                return isASCIIAlias(alias) ? containsWord(haystack, needle)
                                           : haystack.contains(needle)
            }
            if hit { out.insert(name) }
        }
        return out
    }
}
