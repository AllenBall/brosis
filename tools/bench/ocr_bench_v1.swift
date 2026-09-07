import Foundation
import AppKit
import Vision

// Render a synthetic "screen" full of mixed zh/en UI-like text at Retina resolution
func makeImage(w: Int, h: Int) -> CGImage {
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
    let lines = [
        "func captureFrame(_ stream: SCStream) async throws -> CGImage { // ScreenCaptureKit 采集帧",
        "项目计划：本周完成 brosis 采集守护进程的 AX 文本抽取与 OCR 回退逻辑，评估存储占用。",
        "https://developer.apple.com/documentation/screencapturekit/scstream  — 打开的标签页 3/12",
        "SELECT id, ts, app, title, text FROM observations WHERE ts > datetime('now','-1 day') ORDER BY ts;",
        "会议纪要 2026-09-05：与 Allen 讨论知识图谱 schema（Project/Person/File/URL/Topic），决定用 SQLite+sqlite-vec。",
        "Error: TCC kTCCServiceScreenCapture not granted for /usr/local/bin/brosisd (pid 4821) — retrying in 30s",
        "The quick brown fox jumps over the lazy dog. 敏捷的棕色狐狸跳过了懒狗。0123456789 ¥1,234.56 $9.99",
    ]
    let font = NSFont.systemFont(ofSize: 26) // ~13pt @2x retina
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    var y = CGFloat(h) - 60
    var i = 0
    while y > 40 {
        let s = NSAttributedString(string: lines[i % lines.count], attributes: attrs)
        s.draw(at: NSPoint(x: 40, y: y))
        y -= 44; i += 1
    }
    img.unlockFocus()
    return img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

func ocr(_ cg: CGImage, level: VNRequestTextRecognitionLevel, langs: [String]) -> (Double, Int, Int) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.recognitionLanguages = langs
    req.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let t0 = Date()
    try! handler.perform([req])
    let dt = Date().timeIntervalSince(t0)
    let obs = req.results ?? []
    let chars = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").count
    return (dt, obs.count, chars)
}

let sizes = [(3456, 2234), (1728, 1117), (3840, 2160)]
for (w, h) in sizes {
    let cg = makeImage(w: w, h: h)
    // warm-up
    _ = ocr(cg, level: .fast, langs: ["zh-Hans", "en-US"])
    for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
        var total = 0.0; var lines = 0; var chars = 0
        for _ in 0..<3 { let r = ocr(cg, level: level, langs: ["zh-Hans", "en-US"]); total += r.0; lines = r.1; chars = r.2 }
        print(String(format: "%dx%d  %@  avg %.0f ms/frame  lines=%d chars=%d", w, h, level == .accurate ? "accurate" : "fast    ", total/3*1000, lines, chars))
    }
}
