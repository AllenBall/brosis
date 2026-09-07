import CoreGraphics
import Foundation

/// 按 `boundingBox` 重建阅读顺序（D24 最后一条）与低置信 token 标记。
///
/// 两件事都**不依赖 Vision**：输入是「一段文字 + 它的归一化矩形 + 置信度」，
/// 所以可以脱离图像单独测（`AdapterVectors.readingOrderCases`）。
enum ReadingOrder {

    /// 一条识别结果。`box` 用 Vision 的归一化坐标：**原点左下、y 向上、值域 0–1**。
    struct Item: Sendable, Equatable {
        var text: String
        var box: CGRect
        var confidence: Double

        init(text: String, box: CGRect, confidence: Double = 1) {
            self.text = text
            self.box = box
            self.confidence = confidence
        }
    }

    /// 行聚类的容差系数：两条结果的中心 y 相差不超过 `median(高度) × 这个系数` 就算同一行。
    ///
    /// 0.6 是折中值：太小会把同一行里高度不齐的字（中英混排、表情）拆成两行；
    /// 太大会把行距紧的正文粘成一行。`ocr_bench.swift` 用的是固定的绝对容差，
    /// 这里改成按实际行高自适应——采集端的区域高度差得太远（顶部标题条 40 pt，聊天面板 600 pt）。
    static let bandFactor: Double = 0.6

    /// 行聚类 + 行内按 x 排序 → 阅读顺序文本。
    ///
    /// 返回的每个元素是一行（已按 x 拼好），调用方再决定用 `\n` 还是别的方式连接。
    static func lines(_ items: [Item]) -> [[Item]] {
        guard !items.isEmpty else { return [] }
        let heights = items.map { Double($0.box.height) }.sorted()
        let median = heights[heights.count / 2]
        let tolerance = max(median * bandFactor, 1e-6)

        // y 从大到小 = 从上往下（Vision 的原点在左下）。
        let sorted = items.sorted { Double($0.box.midY) > Double($1.box.midY) }
        var bands: [[Item]] = []
        var currentTop: Double = 0
        for item in sorted {
            let y = Double(item.box.midY)
            if bands.isEmpty || abs(currentTop - y) > tolerance {
                bands.append([item])
                currentTop = y
            } else {
                bands[bands.count - 1].append(item)
            }
        }
        return bands.map { band in band.sorted { $0.box.minX < $1.box.minX } }
    }

    /// 阅读顺序文本：行内用空格连接，行间用换行。
    static func text(_ items: [Item]) -> String {
        lines(items)
            .map { $0.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    // MARK: - 低置信 token（D24）

    /// D24：「短哈希、十六进制、内存地址标记低置信不作证据」。
    ///
    /// 这类串没有语言先验，Vision 认错一位也读不出来，而且认错了看不出来——
    /// 所以**照样入库**（它确实在屏幕上），但要在 `occurrences.note` 里记下条数，
    /// 检索侧与叙述侧据此不把它们当作可引用的证据。
    ///
    /// 三条规则（都要求"整个 token 匹配"，避免把普通英文单词误判）：
    /// 1. `0x` 开头 + 至少 4 位十六进制 → 内存地址 / 句柄；
    /// 2. 纯十六进制、长度 7–40、且至少含一个数字和一个字母 → 短哈希（git sha、摘要前缀）；
    /// 3. 长度 ≥ 16 的纯 base16/base64 字符集串且大小写混排 → 不可读的标识串。
    static func lowConfidenceTokens(in text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: ",;:()[]{}\"'，。；：（）"))
            guard token.count >= 4 else { continue }
            if isMemoryAddress(token) || isShortHash(token) || isOpaqueIdentifier(token) {
                out.append(token)
            }
        }
        return out
    }

    static func isMemoryAddress(_ token: String) -> Bool {
        let lowered = token.lowercased()
        guard lowered.hasPrefix("0x") else { return false }
        let body = lowered.dropFirst(2)
        guard body.count >= 4 else { return false }
        return body.allSatisfy { $0.isHexDigit }
    }

    static func isShortHash(_ token: String) -> Bool {
        guard (7...40).contains(token.count) else { return false }
        guard token.allSatisfy({ $0.isHexDigit }) else { return false }
        let hasDigit = token.contains { $0.isNumber }
        let hasLetter = token.contains { $0.isLetter }
        return hasDigit && hasLetter
    }

    static func isOpaqueIdentifier(_ token: String) -> Bool {
        guard token.count >= 16 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=_-"))
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let upper = token.contains { $0.isUppercase }
        let lower = token.contains { $0.isLowercase }
        let digit = token.contains { $0.isNumber }
        // 大小写混排 + 有数字 = 人读不出来的串；普通英文长单词（全小写）不会命中。
        return upper && lower && digit
    }
}
