import CoreGraphics
import CoreText
import Foundation

/// 视口 OCR 的自绘图像基准（自检用；口径与 `tools/bench/ocr_bench.swift` 对齐）。
///
/// 三件事让它能在 `--self-check` 里跑而**不需要任何授权**：
/// 1. 图像是本进程用 CoreText 画出来的，不截屏、不碰 ScreenCaptureKit；
/// 2. Vision 是本地推理，不需要 TCC；
/// 3. 真值就是画上去的那串字，逐行存在内存里，不读磁盘。
///
/// 指标与 `ocr_bench` 同口径：
/// - **CER**：真值与识别文本各自按行归一化空白（行内连续空白折叠成一个半角空格、去首尾、
///   丢空行、行间 `\n`）后做字符级 Levenshtein，除以归一化真值字符数；
/// - **标识符召回**：真值里的标识符 token 是否**以完整子串**出现在归一化识别文本里；
/// - 两个尺寸：`2x`（3456×2234，视网膜原生像素）与 `1x`（同一张位图高质量下采样到一半），
///   对应 D24「正文类 1x 可用、代码与等宽小字不降采样」。
enum OCRSelfTest {

    /// 基准位图尺寸（与 `ocr_bench` 一致，便于两边数字直接比）。
    static let baseWidth = 1_728
    static let baseHeight = 1_120

    struct Sample: Sendable {
        var id: String
        var name: String
        var monospace: Bool
        var fontPixels: Double
        var leadingPixels: Double
        var background: (Double, Double, Double)
        var foreground: (Double, Double, Double)
        var lines: [String]
        /// **严格召回**的标识符：不含 accurate 模型会转全角的 ASCII 标点
        /// （`(` `)` `[` `]` `:` `,`）。这一组按逐字节子串判定，是自检的硬门槛。
        var identifiers: [String]
        /// **带标点的标识符**：`foo(bar:)` 这一类。D24 / E8 已实测 accurate 模型会把它们里的
        /// 括号与冒号认成全角，逐字节比一定不过——所以这一组只按**检索侧口径**
        /// （NFKC 折叠 + 大小写折叠 + 去空白，与 `text_fts` 的 unicode61 一致）判定，
        /// 严格值照常报出来，不藏。
        var punctuatedIdentifiers: [String]

        var truth: String { lines.joined(separator: "\n") }
    }

    struct Outcome: Sendable {
        var sampleID: String
        var sampleName: String
        var scaleLabel: String
        var pixelWidth: Int
        var pixelHeight: Int
        /// 归一化后整体 CER。
        var cer: Double
        /// 只统计含汉字的行的 CER（中文行口径）。
        var chineseCER: Double
        /// 无标点标识符的**严格**子串召回（逐字节，不折叠）。自检的硬门槛。
        var identifierRecall: Double
        var missingIdentifiers: [String]
        /// 带标点标识符按**检索侧口径**（NFKC 折叠 + 大小写折叠 + 去空白）的召回。
        /// accurate 模型会把代码里的 `(` `)` `:` `,` 认成全角（D24 / E8 实测），
        /// 而本项目的 FTS 预处理列与查询串都折叠（3.4 / M1 T2、T3 定案），
        /// 所以"检索侧能不能对上"才是这组该问的问题。
        var foldedIdentifierRecall: Double
        var foldedMissingIdentifiers: [String]
        /// 同一组带标点标识符按**逐字节**判定的召回，只报数不作门槛（用来说明差在哪）。
        var punctuatedStrictRecall: Double
        /// 逐字节判定下没召回的**带标点**标识符（`--dump-ocr` 打出来，好让人对着识别原文看
        /// "差的到底是全角还是真认错了"）。
        var punctuatedStrictMissing: [String]
        /// 识别原文（`--dump-ocr` 用；自检本身不打印）。
        var recognizedText: String
        var elapsedMS: Double
        var meanConfidence: Double
        var truthChars: Int
        var ocrChars: Int
        var lowConfidenceTokens: Int
    }

    // MARK: - 样式

    static let samples: [Sample] = [
        Sample(id: "body_mixed", name: "中英混排正文", monospace: false,
               fontPixels: 26, leadingPixels: 46,
               background: (0.98, 0.98, 0.98), foreground: (0.08, 0.08, 0.08),
               lines: [
                "brosis 适配器与视口 OCR 自检样张 第 36 周",
                "本周把采集守护进程的文本通路跑通：AX 优先，OCR 兜底。",
                "新增 recognizeViewport(in:kind:) 与 attributeBubbles(_:) 两个入口。",
                "飞书消息列表只记录视口内已渲染的消息，不追溯未打开的会话。",
                "微信按气泡坐标归属：单聊左侧为对方、右侧为自己，语音只记标签。",
                "权限缺失时抛出 kTCCServiceScreenCapture 未授权，OSStatus 为 -25300。",
                "配置文件路径 /usr/local/etc/brosis/config.json 支持热重载。",
                "参考文档 https://developer.apple.com/documentation/vision 里的识别级别一节。",
                "采样审计每 50 次观察取一次全窗口对照，覆盖率写进 capture_audit 表。",
                "完整性四态分别是 complete、partial、unavailable 与 excluded。",
               ],
               identifiers: ["attributeBubbles", "/usr/local/etc/brosis/config.json",
                             "https://developer.apple.com/documentation/vision",
                             "OSStatus", "capture_audit", "unavailable", "excluded"],
               punctuatedIdentifiers: ["recognizeViewport(in:kind:)",
                                       "kTCCServiceScreenCapture"]),
        Sample(id: "code_small", name: "代码小字（等宽 11.5 pt @2x）", monospace: true,
               fontPixels: 23, leadingPixels: 33,
               background: (1.0, 1.0, 1.0), foreground: (0.05, 0.05, 0.05),
               lines: [
                "func recognize(_ image: CGImage, kind: RegionKind) throws -> Result {",
                "    let request = VNRecognizeTextRequest()",
                "    request.recognitionLevel = .accurate",
                "    request.recognitionLanguages = [\"zh-Hans\", \"en-US\"]",
                "    request.usesLanguageCorrection = false",
                "    let handler = VNImageRequestHandler(cgImage: image, options: [:])",
                "    try handler.perform([request])",
                "    return ReadingOrder.text(items)",
                "}",
                "// completeness: complete / partial / unavailable / excluded",
               ],
               identifiers: ["VNRecognizeTextRequest", "usesLanguageCorrection",
                             "VNImageRequestHandler", "ReadingOrder.text",
                             "recognitionLevel", "zh-Hans"],
               punctuatedIdentifiers: ["VNRecognizeTextRequest()",
                                       "VNImageRequestHandler(cgImage:",
                                       "ReadingOrder.text(items)"]),
        Sample(id: "dark_ui", name: "深色背景浅色字", monospace: false,
               fontPixels: 26, leadingPixels: 44,
               background: (0.09, 0.10, 0.12), foreground: (0.92, 0.93, 0.95),
               lines: [
                "深色主题下的聊天面板样张，用来验证反色不影响召回。",
                "张三：今天的适配器名单确认了吗",
                "李四：确认了，飞书和微信都在里面",
                "我：规则引擎写完了，正在接视口 OCR",
                "系统提示：OCR 最小间隔 5 秒，同一区域不重复识别。",
                "错误码 NSCocoaErrorDomain Code=257 表示读取被拒。",
               ],
               identifiers: ["NSCocoaErrorDomain", "Code=257", "OCR"],
               punctuatedIdentifiers: []),
    ]

    // MARK: - 绘制

    static func makeContext(width: Int, height: Int,
                            background: (Double, Double, Double)) -> CGContext? {
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else { return nil }
        context.setFillColor(CGColor(colorSpace: space,
                                     components: [background.0, background.1,
                                                  background.2, 1.0])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setShouldAntialias(true)
        context.setShouldSubpixelPositionFonts(true)
        return context
    }

    static func font(monospace: Bool, size: Double) -> CTFont {
        if monospace {
            for name in ["SFMono-Regular", "Menlo-Regular", "Courier"] {
                let candidate = CTFontCreateWithName(name as CFString, size, nil)
                let family = CTFontCopyFamilyName(candidate) as String
                if family.contains("Mono") || family.contains("Menlo") || family.contains("Courier") {
                    return candidate
                }
            }
            return CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
        }
        if let system = CTFontCreateUIFontForLanguage(.system, size, nil) { return system }
        return CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// 画一张 2x 基准位图。真值就是 `sample.lines`（不裁剪、不加省略号）。
    static func render(_ sample: Sample) -> CGImage? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = makeContext(width: baseWidth, height: baseHeight,
                                        background: sample.background) else { return nil }
        let color = CGColor(colorSpace: space,
                            components: [sample.foreground.0, sample.foreground.1,
                                         sample.foreground.2, 1.0])!
        let ctFont = font(monospace: sample.monospace, size: sample.fontPixels)
        let marginX = 60.0
        let marginTop = 60.0
        for (index, line) in sample.lines.enumerated() where !line.isEmpty {
            let attributed = NSAttributedString(
                string: line,
                attributes: [kCTFontAttributeName as NSAttributedString.Key: ctFont,
                             kCTForegroundColorAttributeName as NSAttributedString.Key: color])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let yTop = marginTop + Double(index) * sample.leadingPixels
            context.textPosition = CGPoint(x: marginX,
                                           y: Double(baseHeight) - yTop - sample.fontPixels)
            CTLineDraw(ctLine, context)
        }
        return context.makeImage()
    }

    /// 高质量下采样（与 `ocr_bench` 的同源缩放同一个做法：同一张位图，不重新排版）。
    static func downscale(_ image: CGImage, factor: Double,
                          background: (Double, Double, Double)) -> CGImage? {
        let width = Int((Double(image.width) * factor).rounded())
        let height = Int((Double(image.height) * factor).rounded())
        guard let context = makeContext(width: width, height: height,
                                        background: background) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - 指标（与 ocr_bench 同口径）

    static func normalizeByLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func cer(truth: String, recognized: String) -> Double {
        let a = Array(normalizeByLine(truth))
        let b = Array(normalizeByLine(recognized))
        guard !a.isEmpty else { return b.isEmpty ? 0 : 1 }
        return Double(levenshtein(a, b)) / Double(a.count)
    }

    /// 只统计**含汉字的行**：中文行 CER。真值行与识别行按顺序一一对齐，
    /// 数量不等时缺的那几行整行计为错（不做对齐搜索，口径要简单可复核）。
    static func chineseCER(truth: String, recognized: String) -> Double {
        let truthLines = normalizeByLine(truth).split(separator: "\n").map(String.init)
        let ocrLines = normalizeByLine(recognized).split(separator: "\n").map(String.init)
        var distance = 0
        var total = 0
        for (index, line) in truthLines.enumerated()
        where line.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            let expected = Array(line)
            total += expected.count
            let got = index < ocrLines.count ? Array(ocrLines[index]) : []
            distance += levenshtein(expected, got)
        }
        guard total > 0 else { return 0 }
        return Double(distance) / Double(total)
    }

    static func identifierRecall(_ identifiers: [String], in recognized: String, fold: Bool = false)
        -> (recall: Double, missing: [String]) {
        guard !identifiers.isEmpty else { return (1, []) }
        let normalized = fold
            ? foldForMatching(normalizeByLine(recognized))
            : normalizeByLine(recognized)
        let missing = identifiers.filter {
            !normalized.contains(fold ? foldForMatching($0) : $0)
        }
        return (Double(identifiers.count - missing.count) / Double(identifiers.count), missing)
    }

    /// **检索侧口径**的折叠，三步，与库里那条通路一一对应：
    /// 1. NFKC（全角 → 半角）——`TextPipeline.foldForIndex` 就是这一步；
    /// 2. 小写化——`text_fts` 的 `unicode61` 分词器本来就大小写不敏感；
    /// 3. 去掉全部空白——Vision 会在标识符内部插空格（`ReadingOrder.text （items）`），
    ///    而空格在标识符里不是语义差别。
    static func foldForMatching(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        return String(folded.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    // MARK: - 跑

    /// 对每个样张跑 2x 与 1x 两个尺寸。返回顺序固定，便于结果文件逐行对照。
    static func run(samples: [Sample] = OCRSelfTest.samples) -> [Outcome] {
        var out: [Outcome] = []
        for sample in samples {
            guard let base = render(sample) else { continue }
            let variants: [(String, CGImage?)] = [
                ("2x", base),
                ("1x", downscale(base, factor: 0.5, background: sample.background)),
            ]
            for (label, image) in variants {
                guard let image else { continue }
                // 自检里**不再降采样**：两个尺寸都原样送进 Vision，
                // 这样"1x 够不够用"这个问题的答案不被 prepare() 的策略掩盖。
                guard let result = try? ViewportOCR.recognize(image, kind: .code) else { continue }
                let recall = identifierRecall(sample.identifiers, in: result.text)
                let folded = identifierRecall(sample.punctuatedIdentifiers, in: result.text,
                                              fold: true)
                let punctuatedStrict = identifierRecall(sample.punctuatedIdentifiers,
                                                        in: result.text)
                out.append(Outcome(
                    sampleID: sample.id,
                    sampleName: sample.name,
                    scaleLabel: label,
                    pixelWidth: image.width,
                    pixelHeight: image.height,
                    cer: cer(truth: sample.truth, recognized: result.text),
                    chineseCER: chineseCER(truth: sample.truth, recognized: result.text),
                    identifierRecall: recall.recall,
                    missingIdentifiers: recall.missing,
                    foldedIdentifierRecall: folded.recall,
                    foldedMissingIdentifiers: folded.missing,
                    punctuatedStrictRecall: punctuatedStrict.recall,
                    punctuatedStrictMissing: punctuatedStrict.missing,
                    recognizedText: result.text,
                    elapsedMS: result.elapsedMS,
                    meanConfidence: result.meanConfidence,
                    truthChars: sample.truth.count,
                    ocrChars: result.text.count,
                    lowConfidenceTokens: result.lowConfidenceTokens.count))
            }
        }
        return out
    }

    /// 自检的判定线。
    ///
    /// 自检的判定线。
    ///
    /// - **无标点标识符的严格子串召回 ≥ 0.9**：逐字节比，硬门槛。
    /// - **带标点标识符按检索侧口径的召回 ≥ 0.9**：D24 / E8 已实测 accurate 模型把
    ///   `(` `)` `:` `,` 认成全角，逐字节比这组必然不过；本项目的 FTS 与查询串都折叠，
    ///   所以这组按折叠口径判定，同时把逐字节值一起报出来（`punctuatedStrictRecall`）。
    /// - **中文行 CER ≤ 0.20**：给自检留足余量（`ocr_bench` 在 1x 正文上实测 ≤ 2.4%）；
    ///   这里要的是"管线接对了"，不是复刻 E8 的精度基准。
    /// - 1x 的代码小字按 D24 本来就不该用（等宽 11.5 px），只报数不断言。
    static let recallFloor = 0.9
    static let chineseCERCeiling = 0.20

    static func isAsserted(_ outcome: Outcome) -> Bool {
        !(outcome.sampleID == "code_small" && outcome.scaleLabel == "1x")
    }

    static func passes(_ outcome: Outcome) -> Bool {
        guard isAsserted(outcome) else { return true }
        return outcome.identifierRecall >= recallFloor
            && outcome.foldedIdentifierRecall >= recallFloor
            && outcome.chineseCER <= chineseCERCeiling
    }
}
