// ocr_bench.swift — brosis OCR 基准 v2（计划 E8，评审 F6）
//
// 与 v1（ocr_bench_v1.swift）的区别：
//   1. 同源：只在 3456×2234 像素的 CGContext 位图上绘制一次，再用 CoreGraphics
//      高质量插值下采样到 2560×1664 与 1728×1117；三种分辨率是同一张图，
//      不是按尺寸重新排版。每张图都打印 CGImage.width/height 核实真实像素。
//   2. 不用 NSImage / lockFocus，避免逻辑尺寸与像素尺寸不一致。
//   3. 5 种样式（中英混排正文 / 代码小字 / 深色背景 / 稀疏页 / 密集页），
//      文本由本脚本生成并存盘为真值。
//   4. 指标：CER（按行归一化空白后的编辑距离 / 真值长度）、关键标识符召回、
//      耗时 p50 / p95（每组 12 次，去掉前 2 次预热）。
//   5. 输出 results/ocr_bench_<日期>.json（原始数据）。Markdown 报告由
//      ocr_report.py 从 JSON 生成。
//
// 编译： swiftc -O -o ~/Library/Caches/brosis-build/ocr/ocr_bench ocr_bench.swift
// 运行： ~/Library/Caches/brosis-build/ocr/ocr_bench --out <results 目录> --samples <PNG 目录>
// 可选： --runs N --warmup N --styles id1,id2

import Foundation
import Dispatch
import CoreGraphics
import CoreText
import ImageIO
import Vision

// MARK: - 参数

let BASE_W = 3456
let BASE_H = 2234
let LANGS = ["zh-Hans", "en-US"]

struct Resolution { let label: String; let w: Int; let h: Int }
let RESOLUTIONS = [
    Resolution(label: "3456x2234", w: 3456, h: 2234),   // M4 Max 内置屏原生像素（2x）
    Resolution(label: "2560x1664", w: 2560, h: 1664),   // MacBook Air 13" 原生像素
    Resolution(label: "1728x1117", w: 1728, h: 1117),   // 3456×2234 的 1x（逻辑点）
]

func argValue(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

let OUT_DIR   = argValue("--out") ?? FileManager.default.currentDirectoryPath + "/results"
let SAMPLE_DIR = argValue("--samples")
let RUNS      = Int(argValue("--runs") ?? "") ?? 12
let WARMUP    = Int(argValue("--warmup") ?? "") ?? 2
let STYLE_FILTER: Set<String>? = argValue("--styles").map { Set($0.split(separator: ",").map(String.init)) }
let DATE_TAG  = argValue("--date") ?? {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current
    return f.string(from: Date())
}()

// MARK: - 位图与文字

func makeContext(w: Int, h: Int, bg: [CGFloat]) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs, bitmapInfo: info) else {
        fatalError("CGContext 创建失败 \(w)x\(h)")
    }
    ctx.setFillColor(CGColor(colorSpace: cs, components: [bg[0], bg[1], bg[2], 1.0])!)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.setAllowsFontSubpixelPositioning(true)
    ctx.setShouldSubpixelPositionFonts(true)
    ctx.setAllowsFontSubpixelQuantization(true)
    return ctx
}

func makeFont(mono: Bool, size: CGFloat) -> CTFont {
    if mono {
        for name in ["SFMono-Regular", "Menlo-Regular", "Courier"] {
            let f = CTFontCreateWithName(name as CFString, size, nil)
            let fam = CTFontCopyFamilyName(f) as String
            if fam.contains("Mono") || fam.contains("Menlo") || fam.contains("Courier") { return f }
        }
        return CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
    }
    if let f = CTFontCreateUIFontForLanguage(.system, size, nil) { return f }
    return CTFontCreateWithName("Helvetica" as CFString, size, nil)
}

let kFontKey  = kCTFontAttributeName as NSAttributedString.Key
let kColorKey = kCTForegroundColorAttributeName as NSAttributedString.Key

func ctLine(_ s: String, font: CTFont, color: CGColor) -> CTLine {
    let attr = NSAttributedString(string: s, attributes: [kFontKey: font, kColorKey: color])
    return CTLineCreateWithAttributedString(attr)
}

func lineWidthPx(_ s: String, font: CTFont, color: CGColor) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(ctLine(s, font: font, color: color), nil, nil, nil))
}

/// 把一行裁到不超过 maxW，保证“画出来的”与“真值”完全一致（不加省略号）。
func fitLine(_ s: String, font: CTFont, color: CGColor, maxW: CGFloat) -> String {
    if s.isEmpty || lineWidthPx(s, font: font, color: color) <= maxW { return s }
    var chars = Array(s)
    while !chars.isEmpty && lineWidthPx(String(chars), font: font, color: color) > maxW {
        chars.removeLast()
    }
    return String(chars)
}

// MARK: - 样式定义

struct Style {
    let id: String
    let name: String
    let mono: Bool
    let fontPx: CGFloat
    let leadingPx: CGFloat
    let marginX: CGFloat
    let marginTop: CGFloat
    let lineCount: Int
    let bg: [CGFloat]
    let fg: [CGFloat]
    let rawLines: [String]        // 已展开到 lineCount 行
    let identifierPool: [String]  // 候选标识符，最终以真值中实际出现的为准
}

struct RenderedStyle {
    let style: Style
    let truthLines: [String]
    let truth: String
    let identifiers: [String]
    let image: CGImage
    let fontFamily: String
    let textBBoxPx: [Int]   // x, y(top), w, h
}

func render(_ st: Style) -> RenderedStyle {
    let cs = CGColorSpaceCreateDeviceRGB()
    let fg = CGColor(colorSpace: cs, components: [st.fg[0], st.fg[1], st.fg[2], 1.0])!
    let font = makeFont(mono: st.mono, size: st.fontPx)
    let ctx = makeContext(w: BASE_W, h: BASE_H, bg: st.bg)
    let maxW = CGFloat(BASE_W) - 2 * st.marginX

    var truth: [String] = []
    var maxUsedW: CGFloat = 0
    for i in 0..<st.lineCount {
        let raw = st.rawLines[i]
        let fitted = fitLine(raw, font: font, color: fg, maxW: maxW)
        truth.append(fitted)
        if fitted.isEmpty { continue }
        maxUsedW = max(maxUsedW, lineWidthPx(fitted, font: font, color: fg))
        // CGContext 原点在左下；从上往下排版
        let yTop = st.marginTop + CGFloat(i) * st.leadingPx
        let baseline = CGFloat(BASE_H) - yTop - st.fontPx
        ctx.textPosition = CGPoint(x: st.marginX, y: baseline)
        CTLineDraw(ctLine(fitted, font: font, color: fg), ctx)
    }
    guard let img = ctx.makeImage() else { fatalError("makeImage 失败") }

    let truthText = truth.joined(separator: "\n")
    var ids: [String] = []
    for t in st.identifierPool where truthText.contains(t) && !ids.contains(t) { ids.append(t) }
    var missing: [String] = []
    for t in st.identifierPool where !truthText.contains(t) && !missing.contains(t) { missing.append(t) }
    if !missing.isEmpty {
        FileHandle.standardError.write("警告：样式 \(st.id) 的标识符未出现在真值中，已剔除：\(missing)\n".data(using: .utf8)!)
    }
    let bboxH = Int(st.marginTop + CGFloat(st.lineCount - 1) * st.leadingPx + st.fontPx * 1.3)
    return RenderedStyle(style: st, truthLines: truth, truth: truthText, identifiers: ids,
                         image: img, fontFamily: CTFontCopyFamilyName(font) as String,
                         textBBoxPx: [Int(st.marginX), Int(st.marginTop), Int(maxUsedW), bboxH])
}

func scaled(_ src: CGImage, w: Int, h: Int, bg: [CGFloat]) -> CGImage {
    if src.width == w && src.height == h { return src }
    let ctx = makeContext(w: w, h: h, bg: bg)
    ctx.interpolationQuality = .high
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let img = ctx.makeImage() else { fatalError("缩放失败") }
    return img
}

func writePNG(_ img: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - 语料（真值由这里生成，含函数名 / URL / 路径 / 错误码 / 金额等标识符）

let BODY_LINES: [String] = [
    "brosis 项目周报 · 2026 年第 36 周 · 负责人 Allen Qiu",
    "本周主线是把采集守护进程 brosisd 的文本通路跑通：AX 优先，OCR 兜底。",
    "新增 captureFrame(_:) 与 recognizeText(in:level:) 两个入口，均走 async/await。",
    "ScreenCaptureKit 文档见 https://developer.apple.com/documentation/screencapturekit",
    "Vision 的 VNRecognizeTextRequest 在 accurate 模式下对 11pt 代码字仍有可用召回。",
    "二进制安装路径 /usr/local/bin/brosisd，日志写入 /var/log/brosis/daemon.log。",
    "配置文件 ~/Library/Application Support/brosis/config.json 支持热重载。",
    "权限缺失时抛出 kTCCServiceScreenCapture 未授权，OSStatus 为 -25300。",
    "另一个常见错误是 NSError Domain=NSCocoaErrorDomain Code=257，读取被拒。",
    "数据库 observations.sqlite 现为 1.87 GB，FTS5 索引 412 MB，向量表 96 MB。",
    "本月云服务账单 $128.40，本地 SSD 扩容预算 ¥2,480.00，合计约 ¥3,392.16。",
    "提交 a3f9c1e 修复 OCRPipeline.swift 里 boundingBox 坐标系翻转的问题。",
    "提交 7be20d4 把 schema 从 v0.13 升到 v0.14，新增 observations.source 列。",
    "The quick brown fox jumps over the lazy dog; 敏捷的棕色狐狸跳过了懒狗。",
    "Pack my box with five dozen liquor jugs. 0123456789 ABCDEFGHIJKLMNOP",
    "下一步：先做 SQLCipher 落库，再接 sqlite-vec 做向量召回，最后补 MCP 授权。",
    "验收口径：端到端 p95 延迟 < 300 ms，单帧 OCR p50 < 1200 ms（3456×2234）。",
    "存储口径统一按 UTF-8 字节计：每日 388.8 万字符约 3.89–11.66 MB。",
    "评审意见 F6 要求同源缩放，本次基准已按同一张位图做高质量插值下采样。",
    "风险：Air 的 16 GB 内存在跑 4B 模型时余量不足，需要在 E9 阶段实测。",
    "会议纪要 2026-09-06 10:30：确认 M0 出口为记录、找回、展开、删除四步闭环。",
    "参会：Allen、Claude；缺席：无。下次评审定在 2026-09-13 14:00。",
    "TODO(allen): 把 idx_obs_ts 换成 (app, ts) 复合索引，看 EXPLAIN QUERY PLAN。",
    "TODO(claude): 补 tools/bench/ocr_bench.swift 的真值校验与 CER 计算。",
    "术语表：CER = character error rate，字符错误率；p95 = 95 分位延迟。",
    "缩略语：AX = Accessibility API；SCK = ScreenCaptureKit；FM = Foundation Models。",
    "地区设置 zh_CN 导致 Apple Foundation Models 不可用，已在 D5 记为阻塞项。",
    "临时方案：用 LM Studio 的 Gemma 4 26B-A4B 做离线抽取，端口 127.0.0.1:1234。",
    "接口约定 POST /v1/chat/completions，超时 30 s，重试 2 次，退避 1.5 倍。",
    "指标看板 https://brosis.local:8443/dashboard?range=7d 仅内网可达。",
    "本周新增测试 12 个，覆盖率从 61.2% 提升到 74.8%，仍低于 80% 的门槛。",
    "崩溃日志出现 EXC_BAD_ACCESS (SIGSEGV) at 0x0000000104f2a1c0，待复现。",
    "磁盘占用分项：主表 1.31 GB、WAL 96 MB、临时表 12 MB、缩略图 0 MB。",
    "保留期先设 90 天，超期降级为摘要并删除原文，见 docs/实施计划.md 第 6 节。",
    "隐私开关：暂停、排除应用、可见状态三项必须在真实试用前具备。",
    "版本号 brosisd/0.2.7 (build 411)，最低系统要求 macOS 26.0。",
    "签名 Developer ID Application: Allen Qiu (9K7X2QJ8AB)，已开 hardened runtime。",
    "公证提交耗时约 4 分 12 秒，结果 Accepted，ticket 已 staple 到 app bundle。",
    "结论：M0 的主要不确定性在 OCR 保真与容量口径，本文件给出前者的实测数据。",
]

let BODY_IDS: [String] = [
    "captureFrame(_:)", "recognizeText(in:level:)",
    "https://developer.apple.com/documentation/screencapturekit",
    "/usr/local/bin/brosisd", "/var/log/brosis/daemon.log",
    "kTCCServiceScreenCapture", "-25300", "NSCocoaErrorDomain",
    "observations.sqlite", "$128.40", "¥2,480.00", "¥3,392.16",
    "a3f9c1e", "OCRPipeline.swift", "7be20d4", "observations.source",
    "idx_obs_ts", "EXC_BAD_ACCESS", "0x0000000104f2a1c0", "127.0.0.1:1234",
    "https://brosis.local:8443/dashboard?range=7d", "brosisd/0.2.7",
    "9K7X2QJ8AB", "74.8%", "docs/实施计划.md",
]

let CODE_LINES: [String] = [
    "import Vision",
    "import CoreGraphics",
    "",
    "enum StoreError: Error { case prepareFailed(code: Int32, msg: String) }",
    "",
    "@inline(__always)",
    "func recognizeText(in image: CGImage, level: VNRequestTextRecognitionLevel) throws -> [String] {",
    "    let request = VNRecognizeTextRequest()",
    "    request.recognitionLevel = level",
    "    request.recognitionLanguages = [\"zh-Hans\", \"en-US\"]",
    "    request.usesLanguageCorrection = false",
    "    request.minimumTextHeight = 0.008          // 约 18 px @ 2234 px 高",
    "    let handler = VNImageRequestHandler(cgImage: image, options: [:])",
    "    try handler.perform([request])",
    "    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }",
    "}",
    "",
    "let mask: UInt32 = 0x8000_0000 | CGImageAlphaInfo.premultipliedFirst.rawValue",
    "",
    "// MARK: - 持久化",
    "let sql = \"\"\"",
    "SELECT o.id, o.ts, o.app, o.title, substr(o.text, 1, 240) AS snippet",
    "  FROM observations AS o",
    "  JOIN observations_fts AS f ON f.rowid = o.id",
    " WHERE f.observations_fts MATCH ?1",
    "   AND o.ts >= unixepoch('now', '-7 day')",
    " ORDER BY bm25(observations_fts) ASC LIMIT 50;",
    "\"\"\"",
    "guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {",
    "    throw StoreError.prepareFailed(code: sqlite3_errcode(db), msg: String(cString: sqlite3_errmsg(db)))",
    "}",
    "defer { sqlite3_finalize(stmt) }",
    "",
    "# --- shell ---",
    "$ swiftc -O -o ~/Library/Caches/brosis-build/ocr/ocr_bench ocr_bench.swift",
    "$ ./ocr_bench --runs 12 --warmup 2 --out ./results 2>&1 | tee bench.log",
    "$ sqlite3 observations.sqlite \"PRAGMA journal_mode=WAL;\"   # -> wal",
    "$ curl -sS --max-time 30 https://api.brosis.local/v1/ingest -d @payload.json",
    "$ codesign -dv --verbose=4 /usr/local/bin/brosisd 2>&1 | grep TeamIdentifier",
    "TeamIdentifier=9K7X2QJ8AB",
    "# error: ERR_TCC_DENIED (errno 13) while opening /var/db/brosis/wal",
    "# warning: 'usesLanguageCorrection' 对 zh-Hans 的收益未验证，见 F6",
]

let CODE_IDS: [String] = [
    "VNRecognizeTextRequest()", "usesLanguageCorrection", "minimumTextHeight",
    "VNImageRequestHandler(cgImage:", "topCandidates(1)",
    "0x8000_0000", "CGImageAlphaInfo.premultipliedFirst",
    "observations_fts", "bm25(observations_fts)", "sqlite3_prepare_v2",
    "SQLITE_OK", "StoreError.prepareFailed", "sqlite3_errmsg(db)", "sqlite3_finalize(stmt)",
    "~/Library/Caches/brosis-build/ocr/ocr_bench", "journal_mode=WAL",
    "https://api.brosis.local/v1/ingest", "payload.json", "--max-time",
    "TeamIdentifier=9K7X2QJ8AB", "ERR_TCC_DENIED", "/var/db/brosis/wal",
]

let DARK_LINES: [String] = [
    "brosisd[4821] INFO  启动完成，pid=4821，配置版本 v0.14",
    "brosisd[4821] DEBUG SCStream 已附着到 display 1 (3456x2234 @ 2x)",
    "brosisd[4821] WARN  AX 文本为空，回退 OCR：com.apple.Terminal",
    "brosisd[4821] INFO  OCR accurate 用时 1187 ms，观测 42 行，字符 1893",
    "brosisd[4821] ERROR kTCCServiceScreenCapture 未授权，OSStatus=-25300，30 s 后重试",
    "brosisd[4821] INFO  写入 observations.sqlite，rowid=88214，source=ocr",
    "brosisd[4821] DEBUG FTS5 索引更新耗时 12.4 ms，WAL 大小 96 MB",
    "brosisd[4821] WARN  磁盘剩余 18.3 GB，低于 20 GB 阈值，进入降级档 2",
    "brosisd[4821] INFO  嵌入队列长度 137，批大小 32，预计 4.2 s 清空",
    "brosisd[4821] ERROR HTTP 503 from https://api.brosis.local/v1/ingest (retry 2/3)",
    "brosisd[4821] INFO  用户触发暂停，采集器进入 paused 状态",
    "brosisd[4821] INFO  排除清单命中 com.agilebits.onepassword7，跳过本帧",
    "user@m4max ~ % ps -o pid,rss,%cpu -p 4821",
    "  PID    RSS  %CPU",
    " 4821 412336   3.7",
    "user@m4max ~ % du -sh ~/Library/Application\\ Support/brosis",
    "1.9G    /Users/allen/Library/Application Support/brosis",
    "user@m4max ~ % git log --oneline -3",
    "a3f9c1e fix(ocr): 修正 boundingBox 坐标翻转",
    "7be20d4 feat(store): schema v0.14 增加 source 列",
    "c15d90f chore(bench): 同源缩放与 CER 指标",
    "user@m4max ~ % swift build -c release 2>&1 | tail -2",
    "[42/42] Compiling brosisd OCRPipeline.swift",
    "Build complete! (18.42s)",
    "user@m4max ~ % echo $SHELL; sw_vers -productVersion",
    "/bin/zsh",
    "26.6.2",
]

let DARK_IDS: [String] = [
    "brosisd[4821]", "kTCCServiceScreenCapture", "OSStatus=-25300",
    "observations.sqlite", "rowid=88214", "https://api.brosis.local/v1/ingest",
    "com.agilebits.onepassword7", "com.apple.Terminal", "412336",
    "a3f9c1e", "7be20d4", "c15d90f", "OCRPipeline.swift", "(18.42s)",
    "/bin/zsh", "26.6.2", "1187 ms", "12.4 ms",
]

let SPARSE_LINES: [String] = [
    "brosis · M0 阶段出口检查表 · 2026-09-06",
    "",
    "1. 记录一段许可内容（AX 优先，OCR 兜底）",
    "2. 在 300 ms 内准确找回并展开原文",
    "3. 删除后确认 FTS5 与向量表都不可检索",
    "4. 关闭后台索引，CPU 占用回落到 1% 以下",
    "5. 导出 /var/log/brosis/audit.log 并校验 SHA-256",
    "6. 断网重启，确认无外发请求到 api.brosis.local",
    "",
    "负责人 Allen Qiu · 截止 2026-09-20 · schema v0.14",
    "详见 docs/实施计划.md 第 4 节 · brosisd/0.2.7 (build 411)",
]

let SPARSE_IDS: [String] = [
    "/var/log/brosis/audit.log", "SHA-256", "api.brosis.local",
    "2026-09-20", "v0.14", "docs/实施计划.md", "brosisd/0.2.7", "(build 411)",
    "2026-09-06", "300 ms",
]

/// 按 lineCount 展开语料；不足时循环，并加唯一前缀避免重复行。
func expand(_ pool: [String], to n: Int, prefix: (Int) -> String = { _ in "" }) -> [String] {
    (0..<n).map { i in
        let body = pool[i % pool.count]
        let p = prefix(i)
        return body.isEmpty && p.isEmpty ? "" : p + body
    }
}

func hhmmss(_ i: Int) -> String {
    let t = 9 * 3600 + 41 * 60 + 7 + i * 3
    return String(format: "[%02d:%02d:%02d] ", (t / 3600) % 24, (t / 60) % 60, t % 60)
}

let STYLE_BODY = Style(
    id: "body_mixed", name: "中英混排正文", mono: false,
    fontPx: 30, leadingPx: 52, marginX: 90, marginTop: 80, lineCount: 39,
    bg: [1.0, 1.0, 1.0], fg: [0.05, 0.05, 0.06],
    rawLines: expand(BODY_LINES, to: 39), identifierPool: BODY_IDS)

let STYLE_CODE = Style(
    id: "code_small", name: "代码小字（等宽 23 px = 11.5 pt @2x）", mono: true,
    fontPx: 23, leadingPx: 33, marginX: 60, marginTop: 56, lineCount: 62,
    bg: [1.0, 1.0, 1.0], fg: [0.10, 0.10, 0.12],
    rawLines: expand(CODE_LINES, to: 62, prefix: { String(format: "%3d  ", $0 + 1) }),
    identifierPool: CODE_IDS)

let STYLE_DARK = Style(
    id: "dark_ui", name: "深色背景浅色字", mono: true,
    fontPx: 26, leadingPx: 42, marginX: 70, marginTop: 66, lineCount: 49,
    bg: [0.11, 0.11, 0.12], fg: [0.90, 0.90, 0.93],
    rawLines: expand(DARK_LINES, to: 49, prefix: { hhmmss($0) }),
    identifierPool: DARK_IDS)

let STYLE_SPARSE = Style(
    id: "sparse_page", name: "稀疏页（约 300 字符）", mono: false,
    fontPx: 44, leadingPx: 170, marginX: 140, marginTop: 170, lineCount: 11,
    bg: [1.0, 1.0, 1.0], fg: [0.05, 0.05, 0.06],
    rawLines: SPARSE_LINES, identifierPool: SPARSE_IDS)

/// 密集页：轮转 正文 / 代码 / 日志 三个语料，22 px 字、30 px 行距、70 行。
/// 真值实测 3522 字符（含换行）——样式名按实测写「约 3500 字符」，不要写成设计初稿的 4000。
let DENSE_POOL: [String] = {
    var out: [String] = []
    let n = max(BODY_LINES.count, max(CODE_LINES.count, DARK_LINES.count))
    for i in 0..<n {
        if i < BODY_LINES.count { out.append(BODY_LINES[i]) }
        if i < CODE_LINES.count, !CODE_LINES[i].isEmpty { out.append(CODE_LINES[i]) }
        if i < DARK_LINES.count { out.append(DARK_LINES[i]) }
    }
    return out
}()

let STYLE_DENSE = Style(
    id: "dense_page", name: "密集页（约 3500 字符）", mono: false,
    fontPx: 22, leadingPx: 30, marginX: 60, marginTop: 60, lineCount: 70,
    bg: [1.0, 1.0, 1.0], fg: [0.05, 0.05, 0.06],
    rawLines: expand(DENSE_POOL, to: 70),
    identifierPool: BODY_IDS + CODE_IDS + DARK_IDS)

let ALL_STYLES = [STYLE_BODY, STYLE_CODE, STYLE_DARK, STYLE_SPARSE, STYLE_DENSE]

// MARK: - 指标

/// 按行归一化空白：每行内连续空白折叠为一个半角空格，去首尾空白，丢弃空行，行间用 \n 连接。
func normalizeByLine(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

func stripAllWhitespace(_ s: String) -> String {
    String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
}

/// 去空白 + NFKC 兼容分解重组：把全角括号、冒号、逗号、数字、字母折叠成半角，
/// 用于把「排版宽度差异」与「真正认错字」分开。
func foldCompat(_ s: String) -> String {
    stripAllWhitespace(s).precomposedStringWithCompatibilityMapping
}

func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var prev = [Int](repeating: 0, count: b.count + 1)
    var cur  = [Int](repeating: 0, count: b.count + 1)
    for j in 0...b.count { prev[j] = j }
    for i in 1...a.count {
        cur[0] = i
        let ac = a[i - 1]
        for j in 1...b.count {
            let cost = (ac == b[j - 1]) ? 0 : 1
            cur[j] = min(prev[j] + 1, min(cur[j - 1] + 1, prev[j - 1] + cost))
        }
        swap(&prev, &cur)
    }
    return prev[b.count]
}

/// 线性插值分位数（sorted 必须已升序）
func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    if sorted.count == 1 { return sorted[0] }
    let idx = p * Double(sorted.count - 1)
    let lo = Int(idx.rounded(.down))
    let hi = Int(idx.rounded(.up))
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - Double(lo))
}

// MARK: - OCR

struct OCROutput { let text: String; let observations: Int; let ms: Double }

/// 按 y 分带 → 带内按 x 排序，重建阅读顺序（Vision 用左下原点的归一化坐标）。
func orderedText(_ obs: [VNRecognizedTextObservation], bandTolerance: Double) -> String {
    struct Item { let y: Double; let x: Double; let s: String }
    var items: [Item] = []
    for o in obs {
        guard let s = o.topCandidates(1).first?.string else { continue }
        let bb = o.boundingBox
        items.append(Item(y: Double(bb.midY), x: Double(bb.minX), s: s))
    }
    items.sort { $0.y > $1.y }
    var bands: [[Item]] = []
    for it in items {
        if var last = bands.last, let ref = last.first, abs(ref.y - it.y) <= bandTolerance {
            last.append(it); bands[bands.count - 1] = last
        } else {
            bands.append([it])
        }
    }
    return bands.map { $0.sorted { $0.x < $1.x }.map(\.s).joined(separator: " ") }.joined(separator: "\n")
}

func runOCR(_ img: CGImage, level: VNRequestTextRecognitionLevel, langCorrection: Bool,
            bandTolerance: Double) throws -> OCROutput {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.recognitionLanguages = LANGS
    req.usesLanguageCorrection = langCorrection
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    let t0 = DispatchTime.now().uptimeNanoseconds
    try handler.perform([req])
    let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
    let obs = req.results ?? []
    return OCROutput(text: orderedText(obs, bandTolerance: bandTolerance), observations: obs.count, ms: dt)
}

// MARK: - JSON 结构

struct MetaResolution: Codable {
    let label: String, requested_w: Int, requested_h: Int
    let cgimage_w: Int, cgimage_h: Int
    let scale_x: Double, scale_y: Double
}
struct MetaStyle: Codable {
    let id: String, name: String, font_family: String
    let font_px: Double, leading_px: Double, line_count: Int
    let truth_chars: Int, truth_chars_no_ws: Int, truth_lines_nonempty: Int
    let identifier_count: Int, identifiers: [String]
    let bg_rgb: [Double], fg_rgb: [Double]
    let text_bbox_px: [Int], truth_file: String, truth_sha256_prefix: String
}
struct Meta: Codable {
    let tool: String, version: String, date: String, generated_at: String
    let os_version: String, hardware: String
    let vision_revision: Int
    let vision_supported_languages_accurate: [String]
    let vision_supported_languages_fast: [String]
    let languages: [String], base_pixels: [Int]
    let runs_per_config: Int, warmup_dropped: Int, measured_runs: Int
    let cer_definition: String, cer_relaxed_definition: String
    let recall_definition: String, recall_relaxed_definition: String, percentile_method: String
    let resolutions: [MetaResolution]
    let styles: [MetaStyle]
}
struct ResultRow: Codable {
    let style: String, style_name: String, resolution: String
    let cgimage_w: Int, cgimage_h: Int
    let level: String, language_correction: Bool
    let cer: Double, cer_no_whitespace: Double, cer_relaxed: Double
    let identifier_recall: Double, identifier_recall_relaxed: Double
    let identifiers_total: Int, identifiers_hit: Int
    let identifiers_missed: [String], identifiers_missed_relaxed: [String]
    let edit_distance: Int, truth_chars_norm: Int, hyp_chars_norm: Int
    let observation_count: Int
    let p50_ms: Double, p95_ms: Double, mean_ms: Double, min_ms: Double, max_ms: Double
    let samples_ms: [Double]
    let hyp_head: String
}
struct Report: Codable { let meta: Meta; let results: [ResultRow] }

func sha256Prefix(_ s: String) -> String {
    // 简易 FNV-1a 64，仅用于识别真值文件是否被改动（非安全用途）
    var h: UInt64 = 0xcbf29ce484222325
    for b in Array(s.utf8) { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(format: "fnv1a64:%016llx", h)
}

func shell(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    return (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - 主流程

func main() throws {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: OUT_DIR, withIntermediateDirectories: true)
    let truthDir = OUT_DIR + "/ocr_bench_\(DATE_TAG)_truth"
    try? fm.createDirectory(atPath: truthDir, withIntermediateDirectories: true)
    if let sd = SAMPLE_DIR { try? fm.createDirectory(atPath: sd, withIntermediateDirectories: true) }

    let styles = ALL_STYLES.filter { STYLE_FILTER == nil || STYLE_FILTER!.contains($0.id) }
    print("=== brosis OCR 基准 v2 ===")
    print("输出目录: \(OUT_DIR)")
    print("每组次数: \(RUNS)（丢弃前 \(WARMUP) 次预热），语言: \(LANGS.joined(separator: ", "))")

    var metaStyles: [MetaStyle] = []
    var metaRes: [MetaResolution] = []
    var rows: [ResultRow] = []

    let probeA = VNRecognizeTextRequest(); probeA.recognitionLevel = .accurate
    let probeF = VNRecognizeTextRequest(); probeF.recognitionLevel = .fast
    let supportedAccurate = (try? probeA.supportedRecognitionLanguages()) ?? []
    let supportedFast = (try? probeF.supportedRecognitionLanguages()) ?? []
    let revision = probeA.revision

    print("Vision revision = \(revision)")
    print("  accurate 支持语言 \(supportedAccurate.count) 种，含 zh-Hans：\(supportedAccurate.contains("zh-Hans"))")
    print("  fast     支持语言 \(supportedFast.count) 种，含 zh-Hans：\(supportedFast.contains("zh-Hans"))")
    print("  fast 语言列表：\(supportedFast.joined(separator: ", "))")

    var resRecorded = false
    for st in styles {
        let r = render(st)
        // 核实基准图真实像素
        print("")
        print("样式 \(st.id) [\(st.name)]  字体族=\(r.fontFamily)  字号=\(Int(st.fontPx))px  行距=\(Int(st.leadingPx))px")
        print("  基准位图 CGImage.width x height = \(r.image.width) x \(r.image.height)（请求 \(BASE_W) x \(BASE_H)）")
        precondition(r.image.width == BASE_W && r.image.height == BASE_H, "基准图像素与请求不符")
        let truthNorm = normalizeByLine(r.truth)
        let truthNormArr = Array(truthNorm)
        let truthNoWS = stripAllWhitespace(r.truth)
        let truthNoWSArr = Array(truthNoWS)
        let truthFold = foldCompat(r.truth)
        let truthFoldArr = Array(truthFold)
        let idsFold = r.identifiers.map { foldCompat($0) }
        print("  真值：\(r.truth.count) 字符（去空白 \(truthNoWS.count)），非空行 \(truthNorm.split(separator: "\n").count)，标识符 \(r.identifiers.count) 个")

        let truthPath = truthDir + "/\(st.id).txt"
        try r.truth.write(toFile: truthPath, atomically: true, encoding: .utf8)

        metaStyles.append(MetaStyle(
            id: st.id, name: st.name, font_family: r.fontFamily,
            font_px: Double(st.fontPx), leading_px: Double(st.leadingPx), line_count: st.lineCount,
            truth_chars: r.truth.count, truth_chars_no_ws: truthNoWS.count,
            truth_lines_nonempty: truthNorm.split(separator: "\n").count,
            identifier_count: r.identifiers.count, identifiers: r.identifiers,
            bg_rgb: st.bg.map(Double.init), fg_rgb: st.fg.map(Double.init),
            text_bbox_px: r.textBBoxPx,
            truth_file: "ocr_bench_\(DATE_TAG)_truth/\(st.id).txt",
            truth_sha256_prefix: sha256Prefix(r.truth)))

        for res in RESOLUTIONS {
            let img = scaled(r.image, w: res.w, h: res.h, bg: st.bg)
            precondition(img.width == res.w && img.height == res.h, "缩放后像素与请求不符")
            print("  → \(res.label)：CGImage.width x height = \(img.width) x \(img.height)"
                  + String(format: "  缩放 %.4f × %.4f", Double(img.width)/Double(BASE_W), Double(img.height)/Double(BASE_H))
                  + String(format: "  等效字号 %.1f px", Double(st.fontPx) * Double(img.height)/Double(BASE_H)))
            if !resRecorded {
                metaRes.append(MetaResolution(label: res.label, requested_w: res.w, requested_h: res.h,
                                              cgimage_w: img.width, cgimage_h: img.height,
                                              scale_x: Double(img.width)/Double(BASE_W),
                                              scale_y: Double(img.height)/Double(BASE_H)))
            }
            if let sd = SAMPLE_DIR { writePNG(img, to: sd + "/\(st.id)_\(res.label).png") }

            let bandTol = Double(st.leadingPx) * 0.5 / Double(BASE_H)

            for (levelName, level) in [("accurate", VNRequestTextRecognitionLevel.accurate),
                                       ("fast", VNRequestTextRecognitionLevel.fast)] {
                for lc in [true, false] {
                    var samples: [Double] = []
                    var last = OCROutput(text: "", observations: 0, ms: 0)
                    for _ in 0..<RUNS {
                        last = try runOCR(img, level: level, langCorrection: lc, bandTolerance: bandTol)
                        samples.append(last.ms)
                    }
                    let measured = Array(samples.dropFirst(WARMUP))
                    let sorted = measured.sorted()

                    let hypNorm = normalizeByLine(last.text)
                    let dist = levenshtein(truthNormArr, Array(hypNorm))
                    let cer = Double(dist) / Double(max(truthNormArr.count, 1))
                    let hypNoWS = stripAllWhitespace(last.text)
                    let distNo = levenshtein(truthNoWSArr, Array(hypNoWS))
                    let cerNo = Double(distNo) / Double(max(truthNoWSArr.count, 1))

                    let hypFold = foldCompat(last.text)
                    let distFold = levenshtein(truthFoldArr, Array(hypFold))
                    let cerFold = Double(distFold) / Double(max(truthFoldArr.count, 1))

                    let missed = r.identifiers.filter { !hypNorm.contains($0) }
                    let hit = r.identifiers.count - missed.count
                    let recall = r.identifiers.isEmpty ? 0 : Double(hit) / Double(r.identifiers.count)
                    var missedFold: [String] = []
                    for (i, t) in idsFold.enumerated() where !hypFold.contains(t) {
                        missedFold.append(r.identifiers[i])
                    }
                    let recallFold = r.identifiers.isEmpty ? 0
                        : Double(r.identifiers.count - missedFold.count) / Double(r.identifiers.count)

                    if let sd = SAMPLE_DIR {
                        let hd = sd + "/hyp"
                        try? fm.createDirectory(atPath: hd, withIntermediateDirectories: true)
                        try? last.text.write(toFile: hd + "/\(st.id)_\(res.label)_\(levelName)_lc\(lc ? 1 : 0).txt",
                                             atomically: true, encoding: .utf8)
                    }

                    rows.append(ResultRow(
                        style: st.id, style_name: st.name, resolution: res.label,
                        cgimage_w: img.width, cgimage_h: img.height,
                        level: levelName, language_correction: lc,
                        cer: cer, cer_no_whitespace: cerNo, cer_relaxed: cerFold,
                        identifier_recall: recall, identifier_recall_relaxed: recallFold,
                        identifiers_total: r.identifiers.count,
                        identifiers_hit: hit, identifiers_missed: missed,
                        identifiers_missed_relaxed: missedFold,
                        edit_distance: dist, truth_chars_norm: truthNormArr.count,
                        hyp_chars_norm: hypNorm.count, observation_count: last.observations,
                        p50_ms: percentile(sorted, 0.50), p95_ms: percentile(sorted, 0.95),
                        mean_ms: measured.reduce(0, +) / Double(max(measured.count, 1)),
                        min_ms: sorted.first ?? 0, max_ms: sorted.last ?? 0,
                        samples_ms: samples.map { (($0 * 100).rounded()) / 100 },
                        hyp_head: String(hypNorm.prefix(200))))

                    print(String(format: "     %-8@ lc=%@  CER %6.2f%% / 去空白 %6.2f%% / 宽度折叠 %6.2f%%  标识符 %2d/%2d(严) %2d/%2d(宽)  p50 %7.1f ms  p95 %7.1f ms  obs=%d",
                                 levelName as NSString, lc ? "on " : "off",
                                 cer * 100, cerNo * 100, cerFold * 100,
                                 hit, r.identifiers.count,
                                 r.identifiers.count - missedFold.count, r.identifiers.count,
                                 percentile(sorted, 0.50), percentile(sorted, 0.95), last.observations))
                }
            }
        }
        resRecorded = true
    }

    let iso = ISO8601DateFormatter()
    let meta = Meta(
        tool: "tools/bench/ocr_bench.swift", version: "2.0", date: DATE_TAG,
        generated_at: iso.string(from: Date()),
        os_version: shell("sw_vers -productVersion") + " (" + shell("sw_vers -buildVersion") + ")",
        hardware: shell("sysctl -n machdep.cpu.brand_string") + " / "
            + shell("sysctl -n hw.memsize | awk '{printf \"%d GB\", $1/1073741824}'"),
        vision_revision: revision,
        vision_supported_languages_accurate: supportedAccurate,
        vision_supported_languages_fast: supportedFast,
        languages: LANGS, base_pixels: [BASE_W, BASE_H],
        runs_per_config: RUNS, warmup_dropped: WARMUP, measured_runs: RUNS - WARMUP,
        cer_definition: "真值与识别文本各自按行归一化空白（行内连续空白折叠为单个空格、去首尾、丢空行、行间 \\n）后做字符级 Levenshtein 距离，除以归一化真值字符数；换行符计入距离。cer_no_whitespace 为去掉全部空白后的同法计算。",
        cer_relaxed_definition: "去掉全部空白并做 NFKC 兼容折叠（全角括号/冒号/逗号/数字/字母 → 半角）后的字符错误率，用于剔除中文排版宽度差异，只留真正认错的字。",
        recall_definition: "真值中的标识符 token 是否以完整子串出现在按行归一化空白后的识别文本中；命中数 / 标识符总数。",
        recall_relaxed_definition: "标识符与识别文本都做去空白 + NFKC 兼容折叠后再判子串命中；用于回答“字认对了但标点被转成全角”是否算召回。",
        percentile_method: "对去掉预热后的样本升序排序，按 (n-1)*p 线性插值。",
        resolutions: metaRes, styles: metaStyles)

    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try enc.encode(Report(meta: meta, results: rows))
    let jsonPath = OUT_DIR + "/ocr_bench_\(DATE_TAG).json"
    try data.write(to: URL(fileURLWithPath: jsonPath))
    print("")
    print("已写出 \(jsonPath)（\(rows.count) 组结果，\(data.count) 字节）")
    print("真值目录 \(truthDir)")
}

try main()
