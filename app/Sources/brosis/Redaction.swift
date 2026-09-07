import Foundation

/// 入库前的规则脱敏（2.2 硬约束 2、计划 4.2「规则脱敏（gitleaks 核心规则子集、Luhn 卡号、
/// 验证码启发式），入库前一道、查询时一道」）。
///
/// **本轮实现的是「入库前」那一道**：`EventSkeleton` 把 AX 读到的正文**以及窗口标题、
/// URL、`kAXDocument` 文件路径**都交给 `Redactor.redact(_:)`，命中的片段替换成
/// `[REDACTED:<类型>]` 之后才构造 `ObservationInput`，所以库里（`text_versions` 与
/// `windows` / `urls` / `files`）从一开始就没有这些明文。查询时那一道属于 T3 的检索层，
/// 本轮不做（`Redactor` 是纯函数，T3 直接复用即可）。
///
/// 口径三条：
/// - **只删不改语义**：替换成固定长度的占位符，不做打码保留前后几位——保留几位就等于泄漏几位。
/// - **宁可多删**：`generic_secret` 这类通用规则一定会误伤（例如 `token=abcdefgh` 其实是个变量名），
///   在"少存一点正文"和"存进去一把真钥匙"之间选前者。误伤率靠反例向量控制在可接受范围。
/// - **命中要留痕**：每次脱敏的类型与条数写进运行期事件 `redaction`，不写被删掉的内容本身。
enum RedactionType: String, Sendable, CaseIterable {
    /// PEM 私钥块（gitleaks `private-key`）。
    case privateKey = "private_key"
    /// AWS access key id（gitleaks `aws-access-token`）。
    case awsAccessKey = "aws_access_key"
    /// GitHub 的五种 token 前缀（gitleaks `github-pat` / `-oauth` / `-app` / `-refresh`）。
    case githubToken = "github_token"
    /// Slack token（gitleaks `slack-bot-token` 等）。
    case slackToken = "slack_token"
    /// 通用 `api_key = ...` / `secret: ...` 形式（gitleaks `generic-api-key` 的收敛版）。
    case genericSecret = "generic_secret"
    /// 过 Luhn 校验的 13–19 位卡号。
    case cardNumber = "card_number"
    /// 验证码启发式：「验证码 / verification code / OTP」附近的 4–8 位数字。
    case verificationCode = "verification_code"

    var placeholder: String { "[REDACTED:\(rawValue)]" }
}

struct RedactionResult: Sendable {
    var text: String
    /// 按类型的命中条数；没命中时是空字典。
    var counts: [RedactionType: Int]

    var total: Int { counts.values.reduce(0, +) }
    var hit: Bool { total > 0 }

    /// 写进运行期事件的 detail：只有类型与条数，没有任何被删掉的内容。
    var detail: String {
        RedactionType.allCases
            .compactMap { type in counts[type].map { "\(type.rawValue)=\($0)" } }
            .joined(separator: " ")
    }
}

enum Redactor {

    /// 一条规则。`group` 是要替换的捕获组（0 = 整个匹配）。
    /// `validate` 用于正则表达不了的判定，目前只有 Luhn。
    private struct Rule: @unchecked Sendable {
        var type: RedactionType
        var regex: NSRegularExpression
        var group: Int
        var validate: (@Sendable (String) -> Bool)?
    }

    // MARK: - 规则表（顺序即优先级，靠前的先占坑）

    private static let rules: [Rule] = {
        func make(_ type: RedactionType, _ pattern: String,
                  options: NSRegularExpression.Options = [],
                  group: Int = 0,
                  validate: (@Sendable (String) -> Bool)? = nil) -> Rule? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                return nil
            }
            return Rule(type: type, regex: regex, group: group, validate: validate)
        }

        return [
            // 1. PEM 私钥块。优先级最高：块内部往往还能命中别的规则，先整块占坑最省事。
            make(.privateKey,
                 "-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
                 options: [.dotMatchesLineSeparators]),

            // 2. AWS access key id：八种前缀 + 16 位大写字母数字，前后不能再接同类字符。
            make(.awsAccessKey,
                 "(?<![A-Z0-9])(?:A3T[A-Z0-9]|AKIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])"),

            // 3. GitHub：ghp_ / gho_ / ghu_ / ghs_ / ghr_ + ≥36 位。
            make(.githubToken,
                 "(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36,255}(?![A-Za-z0-9])"),

            // 4. Slack：xoxb / xoxa / xoxp / xoxr / xoxs。
            make(.slackToken,
                 "(?<![A-Za-z0-9])xox[baprs]-[A-Za-z0-9-]{10,}(?![A-Za-z0-9-])"),

            // 5. 通用 key = value。只认显式的赋值形式（`=` 或 `:`），
            //    值至少 8 位且限定在 URL-safe / base64 字符集内，避免把整句中文吃掉。
            make(.genericSecret,
                 "(?:api[_-]?key|apikey|secret[_-]?key|client[_-]?secret|secret|access[_-]?token|"
                 + "auth[_-]?token|refresh[_-]?token|token|passwd|password|pwd)"
                 + "\\s*[:=]\\s*[\"']?([A-Za-z0-9_\\-\\.\\+/=]{8,})[\"']?",
                 options: [.caseInsensitive],
                 group: 1),

            // 6. 卡号：13–19 位、允许单个空格或短横做分隔，必须过 Luhn。
            //    只有过 Luhn 才替换——不然日志时间戳（13 位）、订单号（16 位）会被大面积误伤。
            make(.cardNumber,
                 "(?<![0-9])[0-9](?:[ -]?[0-9]){12,18}(?![0-9])",
                 validate: { luhnPassed($0) }),

            // 7. 验证码启发式（两个方向）。窗口刻意开得小：关键词与数字之间不允许再出现数字。
            make(.verificationCode,
                 "(?:验证码|校验码|动态密码|短信码|\\bverification\\s+code\\b|\\bverify\\s+code\\b|"
                 + "\\bsecurity\\s+code\\b|\\bone[- ]?time\\s+(?:code|password)\\b|\\bOTP\\b)"
                 + "[^0-9\\n]{0,24}(?<![0-9])([0-9]{4,8})(?![0-9])",
                 options: [.caseInsensitive],
                 group: 1),
            make(.verificationCode,
                 "(?<![0-9])([0-9]{4,8})(?![0-9])[^0-9\\n]{0,16}"
                 + "(?:验证码|校验码|动态密码|\\bverification\\s+code\\b|\\bOTP\\b)",
                 options: [.caseInsensitive],
                 group: 1),
        ].compactMap { $0 }
    }()

    /// 规则条数，自检里打印。
    static var ruleCount: Int { rules.count }

    // MARK: - 主入口

    /// 对一段正文做脱敏。没有命中时原样返回（不复制、不改动，`counts` 为空）。
    static func redact(_ text: String) -> RedactionResult {
        guard !text.isEmpty else { return RedactionResult(text: text, counts: [:]) }
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        // 先收集全部候选，再按"规则优先级 → 位置"排序，重叠时靠前的赢。
        var candidates: [(range: NSRange, type: RedactionType, priority: Int)] = []
        for (priority, rule) in rules.enumerated() {
            for match in rule.regex.matches(in: text, options: [], range: whole) {
                let range = rule.group == 0 ? match.range : match.range(at: rule.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                if let validate = rule.validate, !validate(ns.substring(with: range)) { continue }
                candidates.append((range, rule.type, priority))
            }
        }
        guard !candidates.isEmpty else { return RedactionResult(text: text, counts: [:]) }

        candidates.sort { a, b in
            a.priority != b.priority ? a.priority < b.priority : a.range.location < b.range.location
        }
        var accepted: [(range: NSRange, type: RedactionType)] = []
        for candidate in candidates {
            let overlaps = accepted.contains { NSIntersectionRange($0.range, candidate.range).length > 0 }
            if !overlaps { accepted.append((candidate.range, candidate.type)) }
        }

        // 从后往前替换，前面的 range 才不会失效。
        accepted.sort { $0.range.location > $1.range.location }
        let output = NSMutableString(string: text)
        var counts: [RedactionType: Int] = [:]
        for item in accepted {
            output.replaceCharacters(in: item.range, with: item.type.placeholder)
            counts[item.type, default: 0] += 1
        }
        return RedactionResult(text: output as String, counts: counts)
    }

    // MARK: - Luhn

    /// 标准 Luhn 校验。输入里的空格与短横先去掉；只接受 13–19 位纯数字。
    static func luhnPassed(_ raw: String) -> Bool {
        let digits = raw.unicodeScalars.compactMap { scalar -> Int? in
            guard scalar.value >= 48, scalar.value <= 57 else { return nil }
            return Int(scalar.value) - 48
        }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}

// MARK: - 测试向量

/// 脱敏的测试向量。`SelfCheck` 全量跑一遍，任何一条不符就退出码非 0。
///
/// 正例 21 条（要求 ≥ 12）、反例 12 条（要求 ≥ 8）。
/// 最后三条正例是**元数据**（窗口标题 / URL）：它们和正文走同一套规则。
/// 反例里刻意放了三种最容易被误伤的东西：**13 位毫秒时间戳**、**16 位订单号**、**11 位手机号**——
/// 它们都长得像卡号，只有 Luhn 能把它们区分开。
enum RedactionVectors {

    struct Positive: Sendable {
        var name: String
        var input: String
        var expected: String
        var types: [RedactionType]
    }

    /// 测试向量里的"密钥"一律在运行时拼接：源码里不出现完整的 token 形状，
    /// 否则 GitHub 的 push protection（secret scanning）会把仓库推送拦下（2026-09-07 实际被拦过一次）。
    private static func joined(_ parts: String...) -> String { parts.joined() }

    static let positives: [Positive] = [
        Positive(name: "AWS AKIA",
                 input: "凭据 " + joined("AKIA", "IOSFODNN7EXAMPLE") + " 到期",
                 expected: "凭据 [REDACTED:aws_access_key] 到期",
                 types: [.awsAccessKey]),
        Positive(name: "AWS 临时会话 ASIA",
                 input: joined("ASIA", "Y34FZKBOKMUTVV7A"),
                 expected: "[REDACTED:aws_access_key]",
                 types: [.awsAccessKey]),
        Positive(name: "GitHub ghp_",
                 input: "git remote 里写着 " + joined("ghp", "_1234567890abcdefghijklmnopqrstuvwxyz"),
                 expected: "git remote 里写着 [REDACTED:github_token]",
                 types: [.githubToken]),
        Positive(name: "GitHub gho_",
                 input: joined("gho", "_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
                 expected: "[REDACTED:github_token]",
                 types: [.githubToken]),
        Positive(name: "Slack xoxb",
                 input: joined("xoxb", "-123456789012-1234567890123-abcdefghijklmnopqrstuvwx"),
                 expected: "[REDACTED:slack_token]",
                 types: [.slackToken]),
        Positive(name: "Slack xoxp",
                 input: "webhook 用 " + joined("xoxp", "-9876543210-0123456789-abcdefgh") + " 试试",
                 expected: "webhook 用 [REDACTED:slack_token] 试试",
                 types: [.slackToken]),
        Positive(name: "PEM RSA 私钥块",
                 input: joined("-----BEGIN ", "RSA PRIVATE KEY-----") + "\nMIIBOgIBAAJBAKj34GkxFhD\n" + joined("-----END ", "RSA PRIVATE KEY-----"),
                 expected: "[REDACTED:private_key]",
                 types: [.privateKey]),
        Positive(name: "PEM EC 私钥块",
                 input: "前 " + joined("-----BEGIN ", "EC PRIVATE KEY-----") + "\nMHcCAQEEIB\n" + joined("-----END ", "EC PRIVATE KEY-----") + " 后",
                 expected: "前 [REDACTED:private_key] 后",
                 types: [.privateKey]),
        Positive(name: "通用 api_key（带引号）",
                 input: "api_key = \"s3cr3t_value_1234\"",
                 expected: "api_key = \"[REDACTED:generic_secret]\"",
                 types: [.genericSecret]),
        Positive(name: "通用 SECRET=",
                 input: "SECRET=abcdefgh12345678",
                 expected: "SECRET=[REDACTED:generic_secret]",
                 types: [.genericSecret]),
        Positive(name: "通用 password:",
                 input: "password: Tr0ub4dor-3xy",
                 expected: "password: [REDACTED:generic_secret]",
                 types: [.genericSecret]),
        Positive(name: "卡号 Visa（带空格）",
                 input: "4111 1111 1111 1111",
                 expected: "[REDACTED:card_number]",
                 types: [.cardNumber]),
        Positive(name: "卡号 MasterCard（尾号不误伤）",
                 input: "卡号 5555555555554444 尾号 4444",
                 expected: "卡号 [REDACTED:card_number] 尾号 4444",
                 types: [.cardNumber]),
        Positive(name: "卡号 Amex 15 位",
                 input: "378282246310005",
                 expected: "[REDACTED:card_number]",
                 types: [.cardNumber]),
        Positive(name: "验证码（中文，码在后）",
                 input: "您的验证码是 638201，5 分钟内有效",
                 expected: "您的验证码是 [REDACTED:verification_code]，5 分钟内有效",
                 types: [.verificationCode]),
        Positive(name: "验证码（中文，码在前）",
                 input: "638201 是您的验证码",
                 expected: "[REDACTED:verification_code] 是您的验证码",
                 types: [.verificationCode]),
        Positive(name: "验证码（英文 verification code）",
                 input: "Your verification code is 4821.",
                 expected: "Your verification code is [REDACTED:verification_code].",
                 types: [.verificationCode]),
        Positive(name: "验证码（OTP）+ 卡号 同段命中两类",
                 input: "OTP: 90210，卡号 4111111111111111",
                 expected: "OTP: [REDACTED:verification_code]，卡号 [REDACTED:card_number]",
                 types: [.verificationCode, .cardNumber]),
        // ↓ 三条**元数据**向量：标题与 URL 走的是同一套规则（`EventSkeleton` 对
        //   `info.title` / `info.url` / `kAXDocument` 也调 `redact`），不是只有正文。
        Positive(name: "窗口标题里的验证码（邮件列表）",
                 input: "Your verification code is 482913 — 收件箱",
                 expected: "Your verification code is [REDACTED:verification_code] — 收件箱",
                 types: [.verificationCode]),
        Positive(name: "URL 查询串里的 access_token",
                 input: "https://mail.example.invalid/oauth/callback?access_token=ya29.a0AfB_byB1234567890",
                 expected: "https://mail.example.invalid/oauth/callback?access_token=[REDACTED:generic_secret]",
                 types: [.genericSecret]),
        Positive(name: "窗口标题里的卡号（收银台）",
                 input: "结算 4111 1111 1111 1111 — 收银台",
                 expected: "结算 [REDACTED:card_number] — 收银台",
                 types: [.cardNumber]),
    ]

    struct Negative: Sendable {
        var name: String
        var input: String
    }

    static let negatives: [Negative] = [
        Negative(name: "会议室号 + 时间", input: "会议室 1203 房间，14:30 开始"),
        Negative(name: "AKIA 但长度不够", input: "AKIASHORT 不是密钥"),
        Negative(name: "16 位订单号（Luhn 不过）", input: "订单号 1234567812345678"),
        Negative(name: "13 位毫秒时间戳（Luhn 不过）", input: "时间戳 1757000000000"),
        Negative(name: "11 位手机号", input: "联系电话 13800138000"),
        Negative(name: "GitHub 仓库地址", input: "见 https://github.com/foo/bar 的说明"),
        Negative(name: "password 只是个词", input: "password 输入框需要焦点"),
        Negative(name: "验证但不是验证码", input: "验证这段文本是否完整"),
        Negative(name: "版本号与日期", input: "版本 v1.2.3-20260907 已发布"),
        Negative(name: "xox 前缀不完整", input: "xox-notatoken"),
        Negative(name: "普通中文正文", input: "第一段：标题。第二段是正文，讲的是存储服务的连接序言。"),
        Negative(name: "空串", input: ""),
    ]
}
