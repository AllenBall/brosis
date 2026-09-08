import CoreGraphics
import Foundation

/// 三栏布局的三条边界，**窗口内的点坐标**（相对窗口左上角）。
///
/// 为什么要有它：微信的区域原来是用写死的点数从窗口边缘内缩的（侧栏 340 / 标题条 60 /
/// 输入框 180）。那组数只是对"常见布局"的描述——用户拖过会话列表分隔线、换了字号、
/// 开了紧凑模式，它就偏；偏了之后半个会话列表会被当成聊天面板 OCR（M2 实测过一次）。
/// `PaneDetector` 每次 OCR 时从**这一帧的窗口图像**里把三条边界量出来，量不到才退回那组数。
struct PaneLayout: Sendable, Equatable {
    /// 侧栏右边界 = 聊天区左边界。
    var sidebarRight: Double
    /// 标题条下边界。
    var titleBottom: Double
    /// 输入框上边界。
    var composerTop: Double
    var source: Source

    /// 这三条边界是量出来的还是兜的底。进运行期事件，真机上一眼看出检测有没有在工作。
    enum Source: String, Sendable {
        /// 三条都量出来了。
        case detected
        /// 量出来一部分，其余用兜底值。
        case partial
        /// 一条都没量出来（或量出来的组合不合理），整组用兜底值。
        case defaults
    }

    /// 某个角色在窗口里的矩形（AX 坐标）。
    func rect(for role: PaneRole, in window: CGRect) -> CGRect {
        let x = window.minX + sidebarRight
        let width = window.width - sidebarRight
        switch role {
        case .chatPanel:
            return CGRect(x: x, y: window.minY + titleBottom,
                          width: width, height: composerTop - titleBottom)
        case .conversationTitle:
            return CGRect(x: x, y: window.minY, width: width, height: titleBottom)
        }
    }

    var label: String {
        String(format: "sidebar=%.0f title=%.0f composer=%.0f", sidebarRight, titleBottom, composerTop)
            + " source=\(source.rawValue)"
    }
}

/// 规则里的区域在三栏布局里扮演什么角色。声明了角色的区域，矩形由 `PaneDetector` 现场量，
/// 不再用规则里写死的那个。
enum PaneRole: String, Sendable {
    case chatPanel
    case conversationTitle
}

/// 从窗口图像里量三栏边界。
///
/// **判据是"贯穿性"，不是"对比强度"。** 一开始按强度找最强的竖边，结果被聊天气泡骗了：
/// 气泡是左右交替、规律堆叠的，所有左对齐气泡的左边距在整列上凑成一条**真实**的竖边，
/// 而且它与聊天背景的反差（0.145）远大于会话列表与聊天区的反差（0.035）——按强度选一定选它
/// （自检实测量出 sidebar=364 = 侧栏 340 + 气泡左边距 24）。
///
/// 真正把两者分开的是**它在多少条扫描线上成立**：分栏边界从窗口顶边贯穿到底边，几乎每一行
/// 都能看到同方向的阶跃；气泡边距只在有气泡的那些行上成立（实测约六成）。所以这里对每个候选
/// 位置统计"同号且够大的扫描线占比"，先按占比过滤，再在过关的里面挑反差最大的。
enum PaneDetector {

    /// 采样上限。边界只要精确到点级，再细没意义，还白烧内存。
    static let maxSamples = 1024

    /// 求均值的半窗（采样点）。取 6：比 1 px 分隔线宽，又远小于任何一栏的宽度。
    static let band = 6

    /// 单条扫描线上算"这里有阶跃"的最小两侧均值差（亮度 0–1，≈ 1.5/255）。
    static let perScanStep = 0.006

    /// 一个候选位置至少要在这么大比例的扫描线上成立，才算**贯穿性**边界。
    ///
    /// 0.85 而不是 1.0：真实窗口里侧栏顶部是它自己的搜索框、聊天区顶部是标题条，
    /// 那几十行两侧可能恰好同色，贡献不了信号；留出余量，别因为几十行就否掉整条边。
    static let minConsistency = 0.85

    /// 过关之后还要满足的整体平均反差，挡掉"到处都差一点点"的噪声。
    static let minStep = 0.010

    /// 侧栏右边界的搜索范围（点）。下限 120 是为了**跳过最左边那条竖排功能栏**
    /// （约 60 pt，它同样是贯穿性边界，不跳过就会选中它）。
    static let sidebarRange: ClosedRange<Double> = 120...600
    /// 标题条下边界的搜索范围（点，从窗口顶边往下量）。
    static let titleRange: ClosedRange<Double> = 24...140
    /// 输入框上边界的搜索范围（点，从窗口**底**边往上量）。
    static let composerRange: ClosedRange<Double> = 90...420

    /// 量完之后的合理性校验：聊天区至少要有这么大，否则这组边界不可信，整组退回兜底。
    static let minChatWidth: Double = 240
    static let minChatHeight: Double = 120

    /// 把图重画成灰度采样，**行 0 = 图像顶边**。
    ///
    /// CGBitmapContext 的内存第 0 行对应上下文坐标 y = height - 1，也就是画面的顶边，
    /// 所以按内存顺序读出来就已经是"从上到下"，不用再翻一次（`ViewportOCR.prepare` 同理）。
    static func luminance(_ image: CGImage, width: Int, height: Int) -> [Double]? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let address = raw.baseAddress,
                  let context = CGContext(data: address, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return bytes.map { Double($0) / 255 }
    }

    /// 一条量出来的边界。
    struct Boundary: Sendable, Equatable {
        var index: Int
        /// 全部扫描线上两侧均值差的平均（带符号取绝对值）。
        var magnitude: Double
        /// 同号且够大的扫描线占比——这就是"贯穿性"。
        var consistency: Double
    }

    /// 沿一个方向找贯穿性边界。
    ///
    /// `value(scan, position)`：`scan` 是扫描线序号（找竖边时是行，找横边时是列），
    /// `position` 是要定位的那个坐标。两个方向共用这一份实现，避免写两遍容易写反的下标。
    static func boundary(positions: Range<Int>, positionCount: Int, scanCount: Int,
                         value: (_ scan: Int, _ position: Int) -> Double) -> Boundary? {
        let low = max(band, positions.lowerBound)
        let high = min(positionCount - band, positions.upperBound)
        guard low < high, scanCount > 0 else { return nil }
        var positive = [Int](repeating: 0, count: positionCount)
        var negative = [Int](repeating: 0, count: positionCount)
        var sum = [Double](repeating: 0, count: positionCount)
        // 每条扫描线先做一次前缀和，band 均值就是 O(1)（否则是 O(band)，候选一多就慢）。
        var prefix = [Double](repeating: 0, count: positionCount + 1)
        for scan in 0..<scanCount {
            for position in 0..<positionCount {
                prefix[position + 1] = prefix[position] + value(scan, position)
            }
            for position in low..<high {
                let left = (prefix[position] - prefix[position - band]) / Double(band)
                let right = (prefix[position + band] - prefix[position]) / Double(band)
                let delta = left - right
                if delta >= perScanStep {
                    positive[position] += 1
                } else if delta <= -perScanStep {
                    negative[position] += 1
                }
                sum[position] += delta
            }
        }
        var best: Boundary?
        for position in low..<high {
            let consistency = Double(max(positive[position], negative[position])) / Double(scanCount)
            guard consistency >= minConsistency else { continue }
            let magnitude = abs(sum[position]) / Double(scanCount)
            guard magnitude >= minStep, magnitude > (best?.magnitude ?? 0) else { continue }
            best = Boundary(index: position, magnitude: magnitude, consistency: consistency)
        }
        return best
    }

    /// 从窗口图像量三条边界。`windowSize` 是窗口的**点**尺寸（图像可能是 2x）。
    /// 量不到的那条用 `fallback` 里对应的值。
    static func detect(window image: CGImage, windowSize: CGSize,
                       fallback: PaneLayout) -> PaneLayout {
        guard windowSize.width > 0, windowSize.height > 0 else { return fallback }
        let width = min(Int(windowSize.width.rounded()), maxSamples)
        let height = min(Int(windowSize.height.rounded()), maxSamples)
        guard width > 2 * band, height > 2 * band,
              let pixels = luminance(image, width: width, height: height) else { return fallback }

        // 采样点 ↔ 点 的换算（窗口比 maxSamples 大时一个采样点不止一个点）。
        let pointsPerColumn = Double(windowSize.width) / Double(width)
        let pointsPerRow = Double(windowSize.height) / Double(height)
        func columns(_ points: Double) -> Int { Int((points / pointsPerColumn).rounded()) }
        func rows(_ points: Double) -> Int { Int((points / pointsPerRow).rounded()) }

        var found = 0

        // —— ① 侧栏右边界 ——
        //
        // 扫描线**不能取全高**：深色模式下输入框常比会话列表更暗，而聊天区比它更亮，
        // 于是同一条侧栏边界在输入框那几行上阶跃方向是反的，一致性被拉到 0.79 掉出阈值
        // （自检里"深色三栏"那份就是这个）。所以只扫"无论标题条与输入框多高，都保证落在
        // 聊天区里"的中间带——它由两个搜索范围的上界推出来，不是又一个拍脑袋的常数。
        // 带子太窄（窗口很矮）就退回全高，宁可少一次检测也不要没有扫描线。
        let middleTop = rows(titleRange.upperBound)
        let middleBottom = rows(Double(windowSize.height) - composerRange.upperBound)
        let middleIsUsable = middleBottom - middleTop >= 80
        let sidebarScanFirst = middleIsUsable ? middleTop : 0
        let sidebarScanCount = middleIsUsable ? middleBottom - middleTop : height

        var sidebarRight = fallback.sidebarRight
        if let step = boundary(positions: columns(sidebarRange.lowerBound)..<columns(sidebarRange.upperBound),
                               positionCount: width, scanCount: sidebarScanCount,
                               value: { row, column in
                                   pixels[(sidebarScanFirst + row) * width + column]
                               }) {
            sidebarRight = Double(step.index) * pointsPerColumn
            found += 1
        }

        // —— ② / ③ 标题条与输入框：扫描线是**聊天区那些列**（避开会话列表自己的行结构）——
        let chatFirstColumn = min(max(0, columns(sidebarRight)), width - 1)
        let chatColumnCount = width - chatFirstColumn
        func chatValue(_ scan: Int, _ position: Int) -> Double {
            pixels[position * width + chatFirstColumn + scan]
        }

        var titleBottom = fallback.titleBottom
        if let step = boundary(positions: rows(titleRange.lowerBound)..<rows(titleRange.upperBound),
                               positionCount: height, scanCount: chatColumnCount,
                               value: chatValue) {
            titleBottom = Double(step.index) * pointsPerRow
            found += 1
        }

        var composerTop = fallback.composerTop
        // 输入框是从**底边**往上量的，换算成行下标要用窗口高度减一下。
        let composerLower = rows(Double(windowSize.height) - composerRange.upperBound)
        let composerUpper = rows(Double(windowSize.height) - composerRange.lowerBound)
        if let step = boundary(positions: composerLower..<composerUpper,
                               positionCount: height, scanCount: chatColumnCount,
                               value: chatValue) {
            composerTop = Double(step.index) * pointsPerRow
            found += 1
        }

        // —— 合理性校验：任何一条不合理就整组退回兜底 ——
        // 三条边界是一起用的，混着用（量准的 + 兜错的）比整组兜底更难排查。
        let chatWidth = Double(windowSize.width) - sidebarRight
        let chatHeight = composerTop - titleBottom
        guard chatWidth >= minChatWidth, chatHeight >= minChatHeight,
              sidebarRight > 0, titleBottom >= 0,
              composerTop <= Double(windowSize.height) else { return fallback }

        let source: PaneLayout.Source = found == 3 ? .detected : (found == 0 ? .defaults : .partial)
        return PaneLayout(sidebarRight: sidebarRight, titleBottom: titleBottom,
                          composerTop: composerTop, source: source)
    }
}

// MARK: - 合成窗口（自检用）

/// 一份合成的三栏窗口。
///
/// 存在的理由是**这条通路没法用真机数据回归**：真实微信窗口既进不了自检，也不能提交进仓库
/// （里面是聊天内容）。合成图能把"检测器该敏感什么、不该敏感什么"钉死：
/// 贯穿全高的分栏边界要量得准，聊天区里的气泡（局部高对比矩形）必须**量不到**。
struct PaneFixture: Sendable {
    var name: String
    /// 窗口点尺寸。默认取真机实测的那一个（库里 evidence 4260 反推出来的 1085×846）。
    var width: Int = 1085
    var height: Int = 846
    /// 竖排功能栏宽。检测器必须跳过它选中会话列表那条边（它俩的反差更大）。
    var iconBar: Int = 60
    /// 会话列表右边界（= 期望的 sidebarRight）。
    var sidebar: Int = 340
    /// 标题条高（= 期望的 titleBottom）。
    var titleBar: Int = 60
    /// 输入框高（期望的 composerTop = height - composer）。
    var composer: Int = 180
    var iconBarLuma: Double = 0.28
    var sidebarLuma: Double = 0.93
    var chatLuma: Double = 0.965
    var titleLuma: Double = 0.98
    var composerLuma: Double = 0.99
    /// 在聊天区画几个高对比"气泡"。检测器不该被它们带偏。
    var bubbles: Bool = true
    /// 允许误差（点）。
    var tolerance: Double = 4
    /// 期望检测结果的来源；纯色窗口那条是 `.defaults`。
    var expectedSource: PaneLayout.Source = .detected

    var expected: PaneLayout {
        // 一条都量不到时 `detect` 原样返回兜底那一组，所以期望值就是 fallback 本身。
        guard expectedSource != .defaults else { return fallback }
        return PaneLayout(sidebarRight: Double(sidebar), titleBottom: Double(titleBar),
                          composerTop: Double(height - composer), source: expectedSource)
    }

    /// 兜底值故意**都取错**（差 60–120 点），这样"检测生效了"与"退回兜底了"能分辨开。
    var fallback: PaneLayout {
        PaneLayout(sidebarRight: 220, titleBottom: 110, composerTop: Double(height - 300),
                   source: .defaults)
    }

    func render() -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let w = Double(width), h = Double(height)
        func fill(_ rect: CGRect, _ luma: Double) {
            context.setFillColor(gray: CGFloat(luma), alpha: 1)
            context.fill(rect)
        }
        // 上下文原点在**左下**，所以"从顶边往下 d 点"写成 y = h - d。
        fill(CGRect(x: 0, y: 0, width: w, height: h), chatLuma)
        fill(CGRect(x: 0, y: 0, width: Double(sidebar), height: h), sidebarLuma)
        fill(CGRect(x: 0, y: 0, width: Double(iconBar), height: h), iconBarLuma)
        fill(CGRect(x: Double(sidebar), y: h - Double(titleBar),
                    width: w - Double(sidebar), height: Double(titleBar)), titleLuma)
        fill(CGRect(x: Double(sidebar), y: 0,
                    width: w - Double(sidebar), height: Double(composer)), composerLuma)
        if bubbles {
            // 一左一右交替的气泡，高对比、边缘竖直——正是最容易骗走"找竖边"这类算法的东西。
            let chatLeft = Double(sidebar) + 24
            let chatRight = w - 24
            var top = h - Double(titleBar) - 40
            var index = 0
            while top > Double(composer) + 80 {
                let bubbleWidth = 260.0
                let x = index % 2 == 0 ? chatLeft : chatRight - bubbleWidth
                fill(CGRect(x: x, y: top - 56, width: bubbleWidth, height: 56),
                     index % 2 == 0 ? 0.82 : 0.62)
                top -= 96
                index += 1
            }
        }
        return context.makeImage()
    }
}

extension PaneFixture {
    /// 自检用的四份合成窗口。
    static let all: [PaneFixture] = [
        PaneFixture(name: "浅色三栏 + 气泡：会话列表与聊天区只差一点灰度，仍要量准"),
        PaneFixture(name: "深色三栏 + 气泡",
                    iconBarLuma: 0.10, sidebarLuma: 0.16, chatLuma: 0.22,
                    titleLuma: 0.19, composerLuma: 0.13),
        PaneFixture(name: "用户把会话列表拖宽到 460：写死的 340 会切错，检测要跟上",
                    sidebar: 460),
        PaneFixture(name: "纯色窗口：一条边界都量不到 → 整组退回兜底",
                    sidebarLuma: 0.965, chatLuma: 0.965, titleLuma: 0.965,
                    composerLuma: 0.965, bubbles: false, expectedSource: .defaults),
    ]
}
