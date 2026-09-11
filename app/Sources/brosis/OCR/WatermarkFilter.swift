import CoreGraphics
import Foundation

/// 把飞书这类应用平铺在窗口上的水印（「<用户名> <组织名>」）从 OCR 结果里去掉（Step 3）。
///
/// 为什么只能在 OCR 侧做：水印是一个独立的透明覆盖窗口（`WatermarkWidget`，2026-09-11 探针），
/// AX 正文从来不含它；但只要走 OCR（树没建起来、图片查看器、会议整窗），每一帧都会认出一片
/// 「邱军雅 洋葱学园」「邱军雅洋葱学园」「雅洋葱学园」「邱單雅洋葱」这样的整串与残片
/// （evidence 16514、4226、4157、19456），进 FTS 与向量之后再也捞不干净。
///
/// 判定只碰字符串与归一化坐标，不碰图像，所以能脱离屏幕单独测（`AdapterVectors.watermark*Cases`）。
enum WatermarkFilter {

    /// 同一串至少出现这么多次才认成水印。
    static let minRepeats = 3
    /// 归一化后的长度区间。下限 5 是为了排除「刘森」「已读」这种短而常见的真实行——
    /// 群聊里发送者名也会重复出现，但它们只有两三个字。
    static let minLength = 5
    static let maxLength = 24
    /// 一个 token 里落在水印字符集里的比例达到它就当水印残片。
    static let overlapThreshold = 0.7
    /// 用户可以直接指定（学不出来时兜底）：`defaults write com.brosis.app adapter.watermark.text "张三 某公司"`。
    static let defaultsKey = "adapter.watermark.text"

    /// 只留字母、数字、表意文字，用来比对（OCR 对空格、标点极不稳定）。
    /// 判据与 `ChatTitle.isWordScalar` 同一份：带圈数字「④」这种 OCR 把图标认出来的残渣不算字。
    static func normalize(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter(ChatTitle.isWordScalar)))
    }

    /// 一个已归一化的水印，连同比对要反复用的字符集与长度——每块区域算一次，不在每个 token 上重算。
    struct Prepared {
        let text: String
        let chars: Set<Character>
        let count: Int

        init(_ normalized: String) {
            text = normalized
            chars = Set(normalized)
            count = normalized.count
        }
    }

    static func prepare(_ normalized: String) -> Prepared { Prepared(normalized) }

    /// 从一帧的识别结果里学水印：同一串（归一化后 5–24 字）出现 ≥ 3 次，**且至少分布在两列两行**。
    /// 平铺是水印的本质特征；群聊里的发送者名虽然也重复，但都左对齐在同一列。
    static func learn(_ items: [ReadingOrder.Item]) -> String? {
        var boxes: [String: [CGRect]] = [:]
        for item in items {
            let key = normalize(item.text)
            let count = key.count
            guard count >= minLength, count <= maxLength else { continue }
            boxes[key, default: []].append(item.box)
        }
        // 归一化坐标切成 6×6 的格，看落在几列几行。
        func tiled(_ list: [CGRect]) -> Bool {
            list.count >= minRepeats
                && Set(list.map { Int((Double($0.midX) * 6).rounded(.down)) }).count >= 2
                && Set(list.map { Int((Double($0.midY) * 6).rounded(.down)) }).count >= 2
        }
        return boxes.filter { tiled($0.value) }.max { $0.value.count < $1.value.count }?.key
    }

    static func configured(_ defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.string(forKey: defaultsKey) else { return nil }
        let key = normalize(raw)
        return key.count >= 2 ? key : nil
    }

    /// 一个 token 是不是水印（或水印的残片）：不长于水印 + 2，且七成以上的字落在水印字符集里。
    static func isWatermarkToken(_ token: String, watermark: Prepared) -> Bool {
        let normalized = normalize(token)
        let count = normalized.count
        guard count >= 2, count <= watermark.count + 2 else { return false }
        let hits = normalized.filter { watermark.chars.contains($0) }.count
        return Double(hits) / Double(count) >= overlapThreshold
    }

    /// 去掉一行里的水印 token；整行都是水印就返回 nil。
    /// 水印常与正文粘成一个 token（「邱军雅洋葱学园智能会议纪要」）：先剥头尾的整串，再看剩下的。
    static func strip(line: String, watermark: Prepared) -> String? {
        var kept: [String] = []
        for raw in line.split(separator: " ", omittingEmptySubsequences: true) {
            var token = String(raw)
            if token.count > watermark.count {
                if token.hasPrefix(watermark.text) { token = String(token.dropFirst(watermark.count)) }
                if token.hasSuffix(watermark.text) { token = String(token.dropLast(watermark.count)) }
            }
            guard !token.isEmpty, !isWatermarkToken(token, watermark: watermark) else { continue }
            kept.append(token)
        }
        let joined = kept.joined(separator: " ")
        return normalize(joined).isEmpty ? nil : joined
    }

    /// 对整段识别结果生效：条目逐个剥，剥空的丢掉，再按识别器同一套公式重建文本与置信度。
    static func apply(_ result: ViewportOCR.Result, watermark: Prepared) -> ViewportOCR.Result {
        result.replacingLines(result.lines.compactMap { item in
            guard let text = strip(line: item.text, watermark: watermark) else { return nil }
            var copy = item
            copy.text = text
            return copy
        })
    }
}
