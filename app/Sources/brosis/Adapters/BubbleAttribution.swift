import CoreGraphics
import Foundation

/// 一条归属好的聊天气泡。
struct ChatBubble: Sendable, Equatable {
    var sender: String
    var text: String
    var isSelf: Bool

    /// 入库时的一行：`发送者：正文`。
    var line: String { "\(sender)：\(text)" }
}

/// 气泡归属（计划 3.3 微信适配器）：
/// **单聊左 = 对方、右 = 自己；群聊取气泡上方昵称；语音只记 `[语音]`。**
///
/// 输入是 OCR 的行（`ReadingOrder.Item`，Vision 归一化坐标：原点左下、y 向上），
/// 所以这个判定**不碰图像也不碰 AX**，可以直接对合成布局 JSON 跑（`AdapterVectors`）。
enum BubbleAttribution {

    /// 语音条：微信把语音显示成一个带时长的气泡（`3"`、`12''`、`5 秒`）。
    /// 计划 3.3 规定这类只记 `[语音]`，不猜内容。
    static let voicePlaceholder = "[语音]"

    static func isVoiceBubble(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 8 else { return false }
        // 形如 3"、12''、8″、5 秒、10s
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        return ["\"", "''", "″", "’’", "秒", "s", "S", "''"].contains(rest)
    }

    /// 昵称行判定：群聊里昵称是气泡**上方**一行很短的灰字，左对齐在气泡同侧。
    /// 这里只用"够短 + 紧贴下一行 + 与下一行同侧"三条，不依赖颜色（OCR 拿不到颜色）。
    static let maxNicknameCharacters = 16

    /// - Parameters:
    ///   - items: 一次 OCR 的全部结果（未聚行也行，这里会自己聚）。
    ///   - layout: 规则里的气泡布局参数。
    ///   - group: 是不是群聊。单聊时不找昵称，直接按左右分。
    ///   - regionHeightPoints: 这块区域的点高度，用来把 `layout.nicknameGap`（点）换算成归一化距离。
    static func attribute(items: [ReadingOrder.Item],
                          layout: ChatLayout,
                          group: Bool,
                          regionHeightPoints: Double) -> [ChatBubble] {
        let bands = ReadingOrder.lines(items)
        guard !bands.isEmpty else { return [] }
        let gap = regionHeightPoints > 0
            ? layout.nicknameGap / regionHeightPoints
            : 0.05

        struct Band {
            var text: String
            var midY: Double
            var isSelf: Bool
        }
        let rows: [Band] = bands.compactMap { band in
            let raw = band.map(\.text).joined(separator: " ")
            // 气泡里带时间 / edited 的（Telegram）：先剥掉，剥空的行（单独一个时间）不算气泡。
            let text = layout.inlineMetaInBubble ? stripTrailingMeta(raw) : raw
            guard !text.isEmpty else { return nil }
            let minX = band.map { Double($0.box.minX) }.min() ?? 0
            let maxX = band.map { Double($0.box.maxX) }.max() ?? 0
            let midY = band.map { Double($0.box.midY) }.reduce(0, +) / Double(band.count)
            let midX = (minX + maxX) / 2
            // 气泡里带元信息时按左缘判：右下角的时间会把行带中点拉到右边。
            let isSelf = layout.inlineMetaInBubble
                ? minX > layout.leftEdgeSelfThreshold
                : midX > layout.selfSideThreshold
            return Band(text: text, midY: midY, isSelf: isSelf)
        }

        var out: [ChatBubble] = []
        var currentNickname: String?
        var index = 0
        while index < rows.count {
            let row = rows[index]
            // 群聊：够短 + 与下一行紧贴 + 同侧 → 这是下一条气泡的昵称，不入库成正文。
            // Telegram 的昵称行右边还挂着「admin」这类角色标签（同一行），先剥掉再量长度。
            if group, !row.isSelf, index + 1 < rows.count,
               case let nickname = (layout.inlineMetaInBubble ? stripRoleTag(row.text) : row.text),
               nickname.count <= maxNicknameCharacters {
                let next = rows[index + 1]
                if !next.isSelf, row.midY - next.midY <= gap, row.midY > next.midY {
                    currentNickname = nickname.trimmingCharacters(in: .whitespaces)
                    index += 1
                    continue
                }
            }
            let text = isVoiceBubble(row.text) ? voicePlaceholder : row.text
            let sender: String
            if row.isSelf {
                sender = layout.selfLabel
            } else if group {
                sender = currentNickname ?? layout.peerLabel
            } else {
                sender = layout.peerLabel
            }
            out.append(ChatBubble(sender: sender, text: text, isSelf: row.isSelf))
            index += 1
        }
        return out
    }

    /// 归属好的气泡拼成入库文本。
    static func text(_ bubbles: [ChatBubble]) -> String {
        bubbles.map(\.line).joined(separator: "\n")
    }

    // MARK: - 气泡内元信息（Telegram，`ChatLayout.inlineMetaInBubble`）

    /// 行尾的「edited」标记。
    static let trailingMetaTokens: Set<String> = ["edited", "已编辑"]
    /// 昵称行尾的角色标签（Telegram 群聊气泡内首行：「发送者名 …… admin」）。
    static let roleTags: Set<String> = ["admin", "owner", "creator", "管理员", "群主", "创建者"]

    /// 形如 `14:24` / `9:05` 的时间。Telegram 的语音条也显示成 `0:07`，与它同形，所以语音在这条规则下
    /// 认不成 `[语音]`（写在规则的 notes 里）。
    static func isClockToken(_ token: String) -> Bool {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// 从行尾往前弹掉满足 `drop` 的词（按空格分词）。两个剥离函数共用这一个循环。
    static func droppingTrailingTokens(_ text: String, while drop: (String) -> Bool) -> String {
        var tokens = text.split(separator: " ")
        while let last = tokens.last, drop(String(last)) { tokens.removeLast() }
        return tokens.joined(separator: " ")
    }

    /// 剥掉行尾的时间与「edited」（可能连着几个：`… edited 14:52`）。整行只剩这些时返回空串。
    /// 代价：正文本身以「14:30」这类词结尾时会被剥掉一个词，规则 notes 里写明。
    static func stripTrailingMeta(_ text: String) -> String {
        droppingTrailingTokens(text) { token in
            let lowered = token.lowercased()
            return isClockToken(lowered) || trailingMetaTokens.contains(lowered)
        }
    }

    /// 剥掉昵称行尾的角色标签。中文标签可能紧贴名字没有空格（`张三管理员`），按后缀再剥一次，
    /// 但至少给名字留一个字。
    static func stripRoleTag(_ text: String) -> String {
        var joined = droppingTrailingTokens(text) { roleTags.contains($0.lowercased()) }
        if let tag = roleTags.first(where: { joined.hasSuffix($0) && joined.count > $0.count }) {
            joined.removeLast(tag.count)
        }
        return joined.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 合成布局（测试与自检的输入）

/// 合成聊天布局的 JSON 形状。用 JSON 而不是 Swift 字面量，是为了让"布局"这件事
/// 能被复核的人直接看懂、也能在结果文件里原样贴出来。
///
/// 坐标是 **Vision 的归一化坐标**：原点左下、y 向上、值域 0–1（与真实 OCR 输出同一套）。
struct BubbleLayoutFixture: Codable, Sendable {
    struct Line: Codable, Sendable {
        var text: String
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }
    var name: String
    var group: Bool
    /// 气泡里带时间 / 标签（Telegram）：用 `ChatLayout(inlineMetaInBubble: true)` 跑。不写 = 微信那套。
    var inlineMeta: Bool?
    var regionHeightPoints: Double
    var lines: [Line]
    /// 期望的归属结果，每条 `发送者：正文`。
    var expected: [String]

    var layout: ChatLayout { ChatLayout(inlineMetaInBubble: inlineMeta ?? false) }

    var items: [ReadingOrder.Item] {
        lines.map {
            ReadingOrder.Item(text: $0.text,
                              box: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h))
        }
    }
}

// MARK: - 会话名与群聊判定

/// 从 OCR 出来的标题条里认出「干净的会话名」与「这是不是群聊」。
///
/// 为什么必须从这里认：微信的 AX 正文是空的（M0 实测 0 字符），主窗口标题恒为「微信」——
/// 标题条 OCR 是**唯一**能拿到会话身份的通道。M2 之前 `BubbleAttribution.attribute` 的
/// `group` 参数被写死成 `false`，于是群聊昵称那一支永远不执行：昵称行没被认成昵称，
/// 反而被当成一条独立消息入库（`对方：才剑锋`），发送者一律是「对方」。
///
/// 判定只碰字符串，不碰图像也不碰 AX，所以能脱离屏幕单独测（`AdapterVectors.chatTitleCases`）。
enum ChatTitle {

    /// 一条认出来的会话身份。
    struct Resolved: Sendable, Equatable {
        /// 去掉图标残渣与人数后缀之后的会话名，写进 `windows.title`。
        var display: String
        /// 是不是群聊。
        var isGroup: Bool
    }

    /// 会话名最长认到这么多字符。再长基本是把会话列表也框进来了，不当会话名用——
    /// `windows` 表按 (app, title) 唯一，放进去一条噪声就永久多一行。
    static let maxTitleCharacters = 40

    /// 人数后缀最多允许后面再跟几个字符（`（29）` 后面常有 OCR 认出来的图标残渣）。
    static let maxTrailingNoise = 3

    /// 群人数的合理区间。微信群至少 3 人，这里放宽到 2，上限按微信的 500 人群再留一倍余量。
    static let memberCountRange = 2...1000

    /// 认出这一行结尾的群人数后缀，形如「省省吧（29）」。
    ///
    /// 不用正则：OCR 对括号非常不稳（`（` `(` `〔` `【` 与全半角混排都见过），
    /// 与其枚举括号，不如只要求**结构**：结尾附近有一段数字，数字前面紧挨着一个非文字符号。
    /// 「2026年7月C端APP日活查询」这种数字在词中间的不会命中（数字前是汉字）。
    static func memberCount(in line: String) -> Int? {
        let scalars = Array(line.trimmingCharacters(in: .whitespaces).unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        // 这里**故意**比 `isWordScalar` 宽（用 alphanumerics，含带圈数字那类 N）：
        // 判错方向不对称——把单聊误判成群聊会让昵称提取乱抓一通，把群聊误判成单聊
        // 只是退回「对方」。所以数字前面只要有一点像文字，就不当人数后缀。
        func isWord(_ s: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(s) || s.properties.isIdeographic
        }
        // 从结尾往回找数字段，中间只允许隔着很少几个收尾符号。
        var end = scalars.count
        while end > 0, !CharacterSet.decimalDigits.contains(scalars[end - 1]) { end -= 1 }
        guard end > 0, scalars.count - end <= maxTrailingNoise else { return nil }
        var start = end
        while start > 0, CharacterSet.decimalDigits.contains(scalars[start - 1]) { start -= 1 }
        // 数字前面必须是一个**非文字**符号（括号），否则「第2组」「2026年」也会命中。
        guard start > 0, !isWord(scalars[start - 1]) else { return nil }
        guard let count = Int(String(String.UnicodeScalarView(scalars[start..<end]))),
              memberCountRange.contains(count) else { return nil }
        return count
    }

    /// 把标题条的整块 OCR 文本认成一条会话身份；认不出来返回 nil。
    ///
    /// 认不出来时**什么都不改**（观察照旧用窗口标题「微信」）：宁可少一条身份，
    /// 也不要让 OCR 噪声在 `windows` 表里堆出一堆一次性的假标题。
    static func resolve(_ raw: String) -> Resolved? {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        // 带人数后缀的那一行最像会话名（群聊）；没有就用第一行（单聊）。
        let line = lines.first { memberCount(in: $0) != nil } ?? lines[0]
        let count = memberCount(in: line)
        guard let display = cleaned(line, droppingMemberCount: count != nil) else { return nil }
        // Telegram 的群信号在**第二行**（「5,107 members, 338 online」），会话名本身没有人数后缀。
        let statusSaysGroup = lines.dropFirst().contains(where: isGroupStatusLine)
        return Resolved(display: display, isGroup: count != nil || statusSaysGroup)
    }

    /// Telegram 会话头第二行的群信号：数字（可带千分位）后面紧跟「members / 位成员」。
    ///
    /// 频道（`subscribers` / `订阅者`）、单聊（`online` / `last seen …`）、机器人（`bot`）**不算群**：
    /// 频道没有逐条发送者名，按群处理只会把短消息误认成昵称。`member` 单数也认（「1 member」）。
    static let groupStatusKeywords = ["member", "位成员", "名成员", "个成员"]

    static func isGroupStatusLine(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces).lowercased()
        let rest = text.drop { $0.isNumber || $0 == "," }
        guard text[..<rest.startIndex].contains(where: \.isNumber) else { return false }
        let keywordPart = rest.trimmingCharacters(in: .whitespaces)
        return groupStatusKeywords.contains { keywordPart.hasPrefix($0) }
    }

    /// 一个标量能不能当会话名的开头 / 结尾。
    ///
    /// 用 `letters ∪ decimalDigits ∪ 表意文字`，**不能**用 `alphanumerics`：后者含整个 N 类，
    /// 而 OCR 把头像和图标恰恰认成 `④`（U+2463，类别 No）这种带圈数字，用 alphanumerics
    /// 判就把它当成正文留下了。
    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.letters.contains(s) || CharacterSet.decimalDigits.contains(s)
            || s.properties.isIdeographic
    }

    /// 去掉行首图标残渣（OCR 把头像 / 图标认成 `◎` `④` 这类字）、行尾的人数后缀与标点。
    static func cleaned(_ line: String, droppingMemberCount: Bool) -> String? {
        var scalars = Array(line.unicodeScalars)
        if droppingMemberCount {
            // 从右往左：先跳过收尾符号（`）`），再跳过数字，落到**左**括号上，从那里截断。
            var index = scalars.count
            while index > 0, !CharacterSet.decimalDigits.contains(scalars[index - 1]) { index -= 1 }
            while index > 0, CharacterSet.decimalDigits.contains(scalars[index - 1]) { index -= 1 }
            if index > 0 { scalars = Array(scalars[0..<(index - 1)]) }
        }
        // 行首 / 行尾：丢掉连续的非文字符号（含空白与图标残渣）。
        var start = 0
        while start < scalars.count, !isWordScalar(scalars[start]) { start += 1 }
        var end = scalars.count
        while end > start, !isWordScalar(scalars[end - 1]) { end -= 1 }
        guard start < end else { return nil }
        let text = String(String.UnicodeScalarView(scalars[start..<end]))
        guard !text.isEmpty, text.count <= maxTitleCharacters else { return nil }
        return text
    }
}
