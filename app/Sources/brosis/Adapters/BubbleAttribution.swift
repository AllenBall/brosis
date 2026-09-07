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
