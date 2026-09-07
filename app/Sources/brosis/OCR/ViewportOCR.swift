import CoreGraphics
import Foundation
import Vision

/// 视口 OCR（计划 3.3 + D24）。
///
/// 入口是 `CaptureController.analyze` 拿到的那张 `CGImage`——**那一刻是全屏一张图**，
/// 这里把它裁到目标窗口 / 区域再交给 Vision。参数按 D24 定死：
///
/// | 项 | 值 | 依据 |
/// |---|---|---|
/// | 识别级别 | `.accurate` | D24：fast 不支持 zh-Hans，中文 CER 24–50% |
/// | 语言 | `zh-Hans`, `en-US` | E8 |
/// | 语言纠错 | **关** | D24：accurate 下输出逐字节相同，fast 下更慢且无改善 |
/// | 分辨率 | 正文类 1x；代码 / 等宽小字**不降采样** | D24 |
/// | 阅读顺序 | 按 `boundingBox` 行聚类重建 | D24 / `ReadingOrder` |
/// | NFKC | **不折叠** | M1 T2/T3 定案：折叠只在索引侧，采集端存原文 |
enum ViewportOCR {

    /// 一次识别的结果。
    struct Result: Sendable {
        /// 按阅读顺序重建的文本（**原文，未折叠、未脱敏**）。
        var text: String
        var lines: [ReadingOrder.Item]
        /// 按字符数加权的平均置信度（0–1）。没有结果时为 0。
        var meanConfidence: Double
        /// D24 的低置信 token（短哈希 / 十六进制 / 内存地址）。
        var lowConfidenceTokens: [String]
        var elapsedMS: Double
        /// 实际送进 Vision 的像素尺寸。
        var pixelWidth: Int
        var pixelHeight: Int
        /// 送进去之前有没有降采样（正文类区域按 D24 允许 1x）。
        var downscaled: Bool

        var isEmpty: Bool { text.isEmpty }

        /// 写进 `occurrences.note` 的**形状**（不含正文）。
        func note(rect: CGRect) -> String {
            "lowconf=\(lowConfidenceTokens.count) conf=\(String(format: "%.2f", meanConfidence)) "
                + "px=\(pixelWidth)x\(pixelHeight)\(downscaled ? "(1x)" : "") "
                + "rect=\(Int(rect.origin.x.rounded())),\(Int(rect.origin.y.rounded())),"
                + "\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
        }
    }

    /// 置信度低于这个值就把整段标成"参考"（写进 note，并把 completeness 压到 partial）。
    static let lowConfidenceThreshold: Double = 0.5

    /// 识别语言，顺序有意义（Vision 按顺序优先）。
    static let languages = ["zh-Hans", "en-US"]

    // MARK: - 裁剪

    /// 把全屏截图裁到 AX 坐标系里的某个矩形。
    ///
    /// 三套坐标要对齐：
    /// - **AX**：原点在主屏左上、y 向下、跨屏全局（`AXPosition` 就是这一套）；
    /// - **CGDisplayBounds**：同样是原点主屏左上、y 向下、跨屏全局——所以这两套**不用翻转**，
    ///   只要减掉这台显示器的原点就落到"这台屏内部的点坐标"；
    /// - **CGImage**：原点左上、单位是像素。`CGImage.cropping(to:)` 用的就是这一套，
    ///   所以只差一个 `scale = 图像像素宽 / 显示器点宽`（Retina 上是 2，抓 1x 时是 1）。
    ///
    /// 多屏：`displayBounds` 传的是**这一帧所属那台显示器**的 bounds，
    /// 窗口在别的屏上时相减会得到负坐标，`clamp` 之后与图像不相交 → 返回 nil（不瞎裁）。
    static func crop(_ image: CGImage, axRect: CGRect, displayBounds: CGRect) -> (image: CGImage, pixelRect: CGRect)? {
        guard displayBounds.width > 0, displayBounds.height > 0 else { return nil }
        let scaleX = Double(image.width) / Double(displayBounds.width)
        let scaleY = Double(image.height) / Double(displayBounds.height)
        let local = CGRect(x: (axRect.origin.x - displayBounds.origin.x) * scaleX,
                           y: (axRect.origin.y - displayBounds.origin.y) * scaleY,
                           width: axRect.width * scaleX,
                           height: axRect.height * scaleY)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clamped = local.intersection(bounds).integral
        guard !clamped.isNull, clamped.width >= 8, clamped.height >= 8 else { return nil }
        guard let cropped = image.cropping(to: clamped) else { return nil }
        return (cropped, clamped)
    }

    /// 按 D24 决定要不要降采样：正文类区域可以按 1x 送（省不了时间但省内存），
    /// 代码 / 等宽小字区域**原样送**。
    ///
    /// 注意 D24 的实测结论：「降采样不省时间，耗时由字符数决定（约 0.25–0.47 ms/字符）」——
    /// 所以这里默认**不主动降**，只在图像明显超过目标点尺寸 2 倍时才降到 1x，
    /// 避免把 4K 外接屏的一整块面板原样丢进 Vision。
    static func prepare(_ image: CGImage, kind: RegionKind, pointWidth: Double)
        -> (image: CGImage, downscaled: Bool) {
        guard !kind.monospace, pointWidth > 0 else { return (image, false) }
        let scale = Double(image.width) / pointWidth
        guard scale > 2.0 else { return (image, false) }
        let targetWidth = Int(pointWidth.rounded())
        let targetHeight = Int((Double(image.height) / scale).rounded())
        guard targetWidth >= 8, targetHeight >= 8 else { return (image, false) }
        guard let context = CGContext(data: nil, width: targetWidth, height: targetHeight,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return (image, false) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { return (image, false) }
        return (scaled, true)
    }

    // MARK: - 识别

    /// 对一张已经裁好的图跑 Vision。**不需要任何 TCC 授权**（Vision 是本地推理），
    /// 所以自检可以对自绘图像直接跑。
    static func recognize(_ image: CGImage, kind: RegionKind = .body,
                          pointWidth: Double = 0) throws -> Result {
        let prepared = prepare(image, kind: kind, pointWidth: pointWidth)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate                 // D24
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = false               // D24
        let handler = VNImageRequestHandler(cgImage: prepared.image, options: [:])
        let started = DispatchTime.now().uptimeNanoseconds
        try handler.perform([request])
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000

        var items: [ReadingOrder.Item] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            items.append(ReadingOrder.Item(text: candidate.string,
                                           box: observation.boundingBox,
                                           confidence: Double(candidate.confidence)))
        }
        let text = ReadingOrder.text(items)
        let weight = items.reduce(0.0) { $0 + Double($1.text.count) }
        let weighted = items.reduce(0.0) { $0 + $1.confidence * Double($1.text.count) }
        return Result(text: text,
                      lines: items,
                      meanConfidence: weight > 0 ? weighted / weight : 0,
                      lowConfidenceTokens: ReadingOrder.lowConfidenceTokens(in: text),
                      elapsedMS: elapsed,
                      pixelWidth: prepared.image.width,
                      pixelHeight: prepared.image.height,
                      downscaled: prepared.downscaled)
    }

    /// 裁 + 认，一步到位。裁不出来（区域在别的屏上、太小）返回 nil。
    static func recognize(fullFrame image: CGImage, axRect: CGRect, displayBounds: CGRect,
                          kind: RegionKind) throws -> Result? {
        guard let cropped = crop(image, axRect: axRect, displayBounds: displayBounds) else {
            return nil
        }
        return try recognize(cropped.image, kind: kind, pointWidth: Double(axRect.width))
    }
}
