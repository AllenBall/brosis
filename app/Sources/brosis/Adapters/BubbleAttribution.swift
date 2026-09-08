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
            var midX: Double
            var midY: Double
            var isSelf: Bool
        }
        let rows: [Band] = bands.map { band in
            let text = band.map(\.text).joined(separator: " ")
            let minX = band.map { Double($0.box.minX) }.min() ?? 0
            let maxX = band.map { Double($0.box.maxX) }.max() ?? 0
            let midY = band.map { Double($0.box.midY) }.reduce(0, +) / Double(band.count)
            let midX = (minX + maxX) / 2
            return Band(text: text, midX: midX, midY: midY,
                        isSelf: midX > layout.selfSideThreshold)
        }

        var out: [ChatBubble] = []
        var currentNickname: String?
        var index = 0
        while index < rows.count {
            let row = rows[index]
            // 群聊：够短 + 与下一行紧贴 + 同侧 → 这是下一条气泡的昵称，不入库成正文。
            if group, !row.isSelf, row.text.count <= maxNicknameCharacters,
               index + 1 < rows.count {
                let next = rows[index + 1]
                if !next.isSelf, row.midY - next.midY <= gap, row.midY > next.midY {
                    currentNickname = row.text.trimmingCharacters(in: .whitespaces)
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
    var regionHeightPoints: Double
    var lines: [Line]
    /// 期望的归属结果，每条 `发送者：正文`。
    var expected: [String]

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
        return Resolved(display: display, isGroup: count != nil)
    }

    /// 去掉行首图标残渣（OCR 把头像 / 图标认成 `◎` `④` `白` 这类字）、行尾的人数后缀与标点。
    static func cleaned(_ line: String, droppingMemberCount: Bool) -> String? {
        var scalars = Array(line.unicodeScalars)
        if droppingMemberCount {
            // 砍掉最后一个非文字符号（左括号）及其之后的全部内容。
            var cut: Int? = nil
            var index = scalars.count - 1
            while index >= 0 {
                if CharacterSet.decimalDigits.contains(scalars[index]) { index -= 1; continue }
                if cut == nil, !CharacterSet.alphanumerics.contains(scalars[index]),
                   !scalars[index].properties.isIdeographic, !scalars[index].properties.isWhitespace {
                    cut = index
                    index -= 1
                    continue
                }
                break
            }
            if let cut { scalars = Array(scalars[0..<cut]) }
        }
        // 行首：丢掉开头连续的非文字符号（含空白）。
        var start = 0
        while start < scalars.count,
              !CharacterSet.alphanumerics.contains(scalars[start]),
              !scalars[start].properties.isIdeographic { start += 1 }
        // 行尾：同样丢掉结尾连续的非文字符号。
        var end = scalars.count
        while end > start,
              !CharacterSet.alphanumerics.contains(scalars[end - 1]),
              !scalars[end - 1].properties.isIdeographic { end -= 1 }
        guard start < end else { return nil }
        let text = String(String.UnicodeScalarView(scalars[start..<end]))
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= maxTitleCharacters else { return nil }
        return text
    }
}
