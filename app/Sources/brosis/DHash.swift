import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// 64 bit 差分感知哈希（9×8 灰度，逐行左右比较）。
/// 只用于“是否触发内容检查”，不用于丢弃小幅文本修改（评审 F5）。
struct DHash: Sendable, Equatable {
    let bits: UInt64

    var hex: String { String(format: "%016llx", bits) }

    func hamming(to other: DHash) -> Int {
        (bits ^ other.bits).nonzeroBitCount
    }
}

/// dHash 计算器。持有一个 CIContext（Metal 后端），跨帧复用。
final class DHasher: @unchecked Sendable {
    private let context: CIContext
    private static let width = 9
    private static let height = 8

    init() {
        context = CIContext(options: [.workingColorSpace: NSNull(),
                                      .cacheIntermediates: false])
    }

    func hash(pixelBuffer: CVPixelBuffer) -> DHash? {
        hash(image: CIImage(cvPixelBuffer: pixelBuffer))
    }

    func hash(cgImage: CGImage) -> DHash? {
        hash(image: CIImage(cgImage: cgImage))
    }

    func hash(image: CIImage) -> DHash? {
        let extent = image.extent
        guard extent.width >= 2, extent.height >= 2,
              extent.width.isFinite, extent.height.isFinite else { return nil }

        let targetWidth = CGFloat(Self.width)
        let targetHeight = CGFloat(Self.height)
        let scale = targetHeight / extent.height
        let aspectRatio = (targetWidth / extent.width) / scale

        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(aspectRatio, forKey: kCIInputAspectRatioKey)
        guard let scaled = filter.outputImage else { return nil }

        let rowBytes = Self.width * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * Self.height)
        let bounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        pixels.withUnsafeMutableBytes { raw in
            context.render(scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x,
                                                                    y: -scaled.extent.origin.y)),
                           toBitmap: raw.baseAddress!,
                           rowBytes: rowBytes,
                           bounds: bounds,
                           format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        var bits: UInt64 = 0
        var bitIndex = 0
        for row in 0..<Self.height {
            for column in 0..<(Self.width - 1) {
                let left = luminance(pixels, rowBytes: rowBytes, row: row, column: column)
                let right = luminance(pixels, rowBytes: rowBytes, row: row, column: column + 1)
                if left > right { bits |= (1 << UInt64(bitIndex)) }
                bitIndex += 1
            }
        }
        return DHash(bits: bits)
    }

    // MARK: - 32×32 亮度网格（按需截图的变化面积估算，替代流才有的 dirtyRects）

    static let gridSize = 32

    /// 把整张图缩到 32×32 灰度，返回 1024 个亮度值（0–255）。
    func luminanceGrid(cgImage: CGImage) -> [UInt8]? {
        let image = CIImage(cgImage: cgImage)
        let extent = image.extent
        guard extent.width >= 2, extent.height >= 2 else { return nil }
        let n = Self.gridSize
        let scale = CGFloat(n) / extent.height
        let aspectRatio = (CGFloat(n) / extent.width) / scale
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(aspectRatio, forKey: kCIInputAspectRatioKey)
        guard let scaled = filter.outputImage else { return nil }
        let rowBytes = n * 4
        var pixels = [UInt8](repeating: 0, count: rowBytes * n)
        pixels.withUnsafeMutableBytes { raw in
            context.render(scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x,
                                                                    y: -scaled.extent.origin.y)),
                           toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: 0, width: n, height: n),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        var grid = [UInt8](repeating: 0, count: n * n)
        for row in 0..<n {
            for column in 0..<n {
                grid[row * n + column] = UInt8(clamping: luminance(pixels, rowBytes: rowBytes, row: row, column: column))
            }
        }
        return grid
    }

    /// 两个网格里亮度差超过阈值的格子数。
    static func changedCells(_ a: [UInt8], _ b: [UInt8], threshold: Int) -> Int {
        var changed = 0
        for i in 0..<min(a.count, b.count) where abs(Int(a[i]) - Int(b[i])) > threshold {
            changed += 1
        }
        return changed
    }

    private func luminance(_ pixels: [UInt8], rowBytes: Int, row: Int, column: Int) -> Int {
        let offset = row * rowBytes + column * 4
        let r = Int(pixels[offset])
        let g = Int(pixels[offset + 1])
        let b = Int(pixels[offset + 2])
        return (r * 299 + g * 587 + b * 114) / 1000
    }
}
