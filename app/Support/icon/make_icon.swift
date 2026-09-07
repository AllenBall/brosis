// brosis 应用图标生成器（只用 CoreGraphics / ImageIO，无第三方依赖）
//
// 设计：深靛蓝 → 青绿的纵向渐变方形圆角底；白色时间线横穿，线上两个事件点；
// 中央一个白色圆环（观察 / 镜头），环心一颗琥珀色的"记录点"。
// 含义：brosis 观察屏幕上发生的事，把它们落在一条本机的时间线上。
//
// 用法：
//   swiftc -O make_icon.swift -o <构建目录>/make_icon
//   <构建目录>/make_icon <输出目录>          # 写出 AppIcon.iconset/ 与 preview_1024.png
//   iconutil -c icns <输出目录>/AppIcon.iconset -o app/Resources/AppIcon.icns
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = outDir.appending(path: "AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let canvas: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r/255, g/255, b/255, a])!
}

func drawIcon(_ ctx: CGContext, size s: CGFloat) {
    let k = s / canvas
    ctx.saveGState()
    ctx.scaleBy(x: k, y: k)   // 一律按 1024 画布坐标作图

    // ---- 底：macOS 图标网格，圆角方形占 824×824，居中留 100 边距 ----
    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: canvas - 2*inset, height: canvas - 2*inset)
    let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.addPath(path); ctx.clip()
    let gradient = CGGradient(colorsSpace: cs,
                              colors: [rgb(36, 50, 135), rgb(31, 110, 156), rgb(34, 166, 156)] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: rect.maxY), end: CGPoint(x: 512, y: rect.minY), options: [])
    // 左上角的一点高光，让底色不那么平
    let glow = CGGradient(colorsSpace: cs, colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 760), startRadius: 0,
                           endCenter: CGPoint(x: 330, y: 760), endRadius: 620, options: [])

    // ---- 时间线：横穿，圆头 ----
    ctx.setLineCap(.round)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.88))
    ctx.setLineWidth(34)
    ctx.move(to: CGPoint(x: 178, y: 512)); ctx.addLine(to: CGPoint(x: 846, y: 512)); ctx.strokePath()
    // 线上两个事件点
    ctx.setFillColor(rgb(255, 255, 255, 0.95))
    for x in [262.0, 762.0] {
        ctx.fillEllipse(in: CGRect(x: x - 34, y: 512 - 34, width: 68, height: 68))
    }

    // ---- 圆环：先用底色把环内的时间线盖掉，再描白环 ----
    let ringR: CGFloat = 196
    ctx.setFillColor(rgb(31, 112, 156))
    ctx.fillEllipse(in: CGRect(x: 512 - ringR, y: 512 - ringR, width: 2*ringR, height: 2*ringR))
    ctx.setStrokeColor(rgb(255, 255, 255))
    ctx.setLineWidth(52)
    ctx.strokeEllipse(in: CGRect(x: 512 - ringR + 26, y: 512 - ringR + 26, width: 2*ringR - 52, height: 2*ringR - 52))

    // ---- 记录点：琥珀色，带一圈柔光 ----
    let dotR: CGFloat = 74
    let halo = CGGradient(colorsSpace: cs, colors: [rgb(255, 184, 77, 0.55), rgb(255, 184, 77, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(halo, startCenter: CGPoint(x: 512, y: 512), startRadius: dotR * 0.6,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: dotR * 1.9, options: [])
    ctx.setFillColor(rgb(255, 184, 77))
    ctx.fillEllipse(in: CGRect(x: 512 - dotR, y: 512 - dotR, width: 2*dotR, height: 2*dotR))
    ctx.restoreGState()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawIcon(ctx, size: CGFloat(px))
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 \(url.path)"])
    }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 2) }
}

// iconset 需要的 10 个文件（点尺寸 × 倍率）
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
var cache: [Int: CGImage] = [:]
for (name, px) in entries {
    let img = cache[px] ?? render(px); cache[px] = img
    try writePNG(img, to: iconset.appending(path: "\(name).png"))
}
try writePNG(cache[1024]!, to: outDir.appending(path: "preview_1024.png"))
print("写出 \(entries.count) 个 PNG 到 \(iconset.path) 与 preview_1024.png")
