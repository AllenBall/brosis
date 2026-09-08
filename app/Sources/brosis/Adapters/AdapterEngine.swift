import BrosisCore
import CoreGraphics
import Foundation

/// 视口相交判定（计划 3.3「只入库视口内实际显示的内容；回滚区与视口外的 AX 节点不入库，
/// 完整性字段标记为 partial」）。
enum Viewport {

    /// 一个节点算不算"在视口内"。
    ///
    /// - `nil` = **判定不了**（节点没有 frame，或者根本没有视口矩形）。调用方一律按**可见**处理：
    ///   宁可多存一点，也绝不因为读不到坐标就丢证据。
    /// - `true` / `false` = 相交面积大于 0 / 不相交。
    static func isVisible(_ frame: CGRect?, in viewport: CGRect?) -> Bool? {
        guard let frame, let viewport, !viewport.isEmpty else { return nil }
        // 零面积的节点（AX 里常见的占位元素）按不可见处理，免得把空节点算进"视口内"。
        guard !frame.isEmpty else { return false }
        return !frame.intersection(viewport).isEmpty
    }

    /// 节点整体在视口**上方**（聊天窗口里的回滚区就是这一类）。只用于统计与说明。
    static func isScrollback(_ frame: CGRect?, in viewport: CGRect?) -> Bool {
        guard let frame, let viewport else { return false }
        return frame.maxY <= viewport.minY
    }
}

/// 一次 OCR 请求：规则判定"这块区域要 OCR"，但**图像不在这里**——
/// 图像来自 `CaptureController.analyze` 拿到的那张 CGImage，
/// 由 `CaptureCoordinator` 在下一帧把两边接起来。
struct OCRRequest: Sendable {
    var regionName: String
    var kind: RegionKind
    /// AX 坐标系（原点主屏左上、y 向下、跨屏全局）。
    ///
    /// 这是**扫描时**算出来的粗矩形。`pane != nil` 时它会在 `CaptureCoordinator.handleFrame`
    /// 里被现场量出来的边界覆盖掉——AX 扫描那一刻还没有图像，量不了。
    var rect: CGRect
    var reason: OCRTriggerReason
    /// 见 `RegionRule.pane`。
    var pane: PaneRole?
}

/// 单个区域的扫描结果。
struct RegionScan: Sendable {
    var name: String
    var kind: RegionKind
    var text: String = ""
    /// 视口内被采纳的文本节点数。
    var visibleNodes: Int = 0
    /// 因为在视口外（含回滚区）被丢掉的文本节点数。
    var offscreenNodes: Int = 0
    /// 其中整块在视口上方的（回滚区）。
    var scrollbackNodes: Int = 0
    /// `AXVisibleCharacterRange` 真的裁掉了东西。
    var clippedByCharRange: Bool = false
    /// 命中区域字符上限。
    var truncated: Bool = false
    /// 定位到了 AX 节点（`.ocr` 区域恒为 false）。
    var located: Bool = false
    /// 区域矩形（AX 坐标），OCR 请求与 `visible_range` 都用它。
    var rect: CGRect?

    var isEmpty: Bool { text.isEmpty }
    /// 这个区域有没有"没读全"的迹象。
    var incomplete: Bool { offscreenNodes > 0 || clippedByCharRange || truncated }
}

/// 一次适配扫描的完整结果。
struct AdapterScan: Sendable {
    var ruleID: String
    var fragments: [TextFragment] = []
    var completeness: Completeness = .unavailable
    var captureMethod: CaptureMethod = .ax
    /// `observations.visible_range` 的 JSON。
    var visibleRange: String?
    var ocrRequests: [OCRRequest] = []
    /// 区域名 → 本次读到的文本。新鲜度判定与 OCR 触发条件（AX 值有没有变）都用它。
    var regionTexts: [String: String] = [:]
    var regions: [RegionScan] = []
    var visitedNodes = 0
    var frameProbes = 0
    var hitNodeLimit = false
    var reachedDepthLimit = false
    /// frame 探测预算用光了：之后的节点不再裁视口，完整性降 partial。
    var hitFrameProbeLimit = false

    var totalChars: Int { regions.reduce(0) { $0 + $1.text.count } }

    var truncated: Bool { hitNodeLimit || reachedDepthLimit || hitFrameProbeLimit }

    /// 写进 `runtime_events.detail`。
    var detail: String {
        var hits: [String] = []
        if hitNodeLimit { hits.append("node") }
        if reachedDepthLimit { hits.append("depth") }
        if hitFrameProbeLimit { hits.append("frame_probe") }
        if regions.contains(where: { $0.truncated }) { hits.append("chars") }
        let offscreen = regions.reduce(0) { $0 + $1.offscreenNodes }
        let scrollback = regions.reduce(0) { $0 + $1.scrollbackNodes }
        return "rule=\(ruleID) visited=\(visitedNodes) probes=\(frameProbes) chars=\(totalChars) "
             + "offscreen=\(offscreen) scrollback=\(scrollback) "
             + "completeness=\(completeness.rawValue) method=\(captureMethod.rawValue) "
             + "hit=\(hits.isEmpty ? "none" : hits.joined(separator: "+"))"
    }
}

/// 规则执行器。**只认 `AXNodeSource` 协议**，所以全部用例都能走合成树跑（见 `AdapterVectors`）。
enum AdapterEngine {

    /// 只用来算完整性的文本角色，与 `AX.textRoles` 一致（换实现不改口径）。
    static let textRoles: Set<String> = Set(AX.textRoles)
    /// 消息列表里当作"一行"的角色。
    static let rowRoles: Set<String> = ["AXRow", "AXCell", "AXGroup", "AXListItem"]

    /// **值得花两条 AX 消息去问坐标的角色**（position + size 各一条）。
    ///
    /// 为什么要挑：视口裁剪要坐标，可 AX 树里绝大多数节点（工具栏、按钮、分隔线、
    /// 各种匿名包装元素）既不带正文也不是滚动容器，问它们的坐标纯属浪费主线程。
    /// 只问两类：**带正文的节点**（要判它在不在视口里）与**滚动 / 列表类容器**
    /// （整块在视口外时可以把子树一次剪掉，这是省时间的大头）。
    static let scrollContainerRoles: Set<String> = [
        "AXScrollArea", "AXList", "AXTable", "AXOutline", "AXWebArea", "AXGroup", "AXRow",
    ]

    static func shouldProbeFrame(role: String, hasText: Bool) -> Bool {
        hasText || textRoles.contains(role) || scrollContainerRoles.contains(role)
    }

    /// 一次扫描。
    ///
    /// - Parameters:
    ///   - rule: 适配规则。
    ///   - window: 焦点窗口节点。
    ///   - windowFrame: 窗口矩形（AX 坐标）。nil 时不做视口裁剪（判定不了就不丢内容）。
    ///   - previousRegionTexts: 上一次同一个应用同一个区域读到的文本，用于新鲜度判定；
    ///     它决定第二类 OCR 触发条件里的"AX 值未变"。
    ///   - frameChanged: 帧门控给出的"这一帧变化超过阈值"。
    ///   - coverageFailed: 上一次采样审计的覆盖检查没过（第三类触发条件）。
    static func scan(rule: AdapterRule,
                     window: any AXNodeSource,
                     windowFrame: CGRect?,
                     previousRegionTexts: [String: String] = [:],
                     frameChanged: Bool = false,
                     coverageFailed: Bool = false) -> AdapterScan {
        var scan = AdapterScan(ruleID: rule.id)
        var budget = Budget(limits: rule.limits, maxFrameProbes: rule.maxFrameProbes)

        for region in rule.regions {
            var result = RegionScan(name: region.name, kind: region.kind)

            // —— 1. 定位 ——
            let located: (any AXNodeSource)?
            switch region.locator {
            case .relativeRect(let relative):
                located = nil
                result.rect = windowFrame.map { relative.resolve(in: $0) }
            case .insetRect(let inset):
                located = nil
                result.rect = windowFrame.map { inset.resolve(in: $0) }
            case .wholeWindow:
                located = window
                result.rect = windowFrame
            default:
                located = find(region.locator, from: window, budget: &budget)
                result.rect = located.flatMap { probeFrame($0, budget: &budget) } ?? windowFrame
            }
            result.located = located != nil

            // —— 2. 读取 ——
            if !region.read.declaresOCR, let node = located {
                let viewport = region.clipToViewport
                    ? intersect(result.rect, windowFrame)
                    : nil
                switch region.read {
                case .axValue:
                    readValue(node, into: &result, region: region)
                case .axSubtree:
                    readSubtree(node, viewport: viewport, into: &result,
                                region: region, budget: &budget)
                case .axRows:
                    readRows(node, viewport: viewport, into: &result,
                             region: region, budget: &budget)
                case .ocr:
                    break                       // 上面的 guard 已经排除
                }
            }

            // —— 3. 要不要 OCR（3.3 的三类触发条件，只判"条件"，限流在 OCRTriggerGate）——
            let axChanged = previousRegionTexts[region.name] != result.text
            if let reason = OCRTriggerGate.reason(ruleDeclaresOCR: region.read.declaresOCR,
                                                  ocrFallback: region.ocrFallback,
                                                  axEmpty: result.isEmpty,
                                                  axChanged: axChanged,
                                                  frameChanged: frameChanged,
                                                  coverageFailed: coverageFailed),
               let rect = result.rect, !rect.isEmpty {
                scan.ocrRequests.append(OCRRequest(regionName: region.name, kind: region.kind,
                                                   rect: rect, reason: reason, pane: region.pane))
            }

            scan.regions.append(result)
            scan.regionTexts[region.name] = result.text
            if !result.text.isEmpty {
                scan.fragments.append(TextFragment(
                    text: result.text,
                    region: "adapter:\(rule.id).\(region.name)"))
            }
        }

        scan.visitedNodes = budget.visited
        scan.frameProbes = budget.frameProbes
        scan.hitNodeLimit = budget.hitNodeLimit
        scan.reachedDepthLimit = budget.reachedDepthLimit
        scan.hitFrameProbeLimit = budget.hitFrameProbeLimit
        scan.completeness = completeness(rule: rule, scan: scan)
        scan.captureMethod = scan.fragments.isEmpty ? .ax : .adapter
        if rule.id == AdapterRegistry.generic.id { scan.captureMethod = .ax }
        scan.visibleRange = visibleRangeJSON(windowFrame: windowFrame, scan: scan)
        return scan
    }

    // MARK: - 完整性（计划 3.2 的四态，M1 R2 起真判定）

    /// - `complete`：规则声明的**必需**区域全部读到了，且没有任何"没读全"的迹象
    ///   （视口外还有内容 / 命中限额 / 字符范围被裁 / frame 预算用光）。
    /// - `partial`：读到了一些，但上面任意一条成立。
    /// - `unavailable`：一个字都没读到。
    /// - `excluded`：策略排除。**不在这里判**——它由 3.12 的档位与私密浏览决定，
    ///   在 `EventSkeleton` 里先于适配器判定（读都不读，谈不上完整性）。
    static func completeness(rule: AdapterRule, scan: AdapterScan) -> Completeness {
        let required = scan.regions.filter { result in
            rule.regions.first { $0.name == result.name }?.required ?? false
        }
        let gotAnything = scan.regions.contains { !$0.isEmpty }
        guard gotAnything else { return .unavailable }
        let allRequiredRead = !required.isEmpty && required.allSatisfy { !$0.isEmpty }
        let anyIncomplete = scan.regions.contains { $0.incomplete } || scan.truncated
        // 规则还有没兑现的 OCR 请求时也只能算 partial：这一帧的正文还没配齐。
        let pendingOCR = !scan.ocrRequests.isEmpty
        if allRequiredRead && !anyIncomplete && !pendingOCR { return .complete }
        return .partial
    }

    // MARK: - visible_range JSON

    /// `observations.visible_range`（计划 3.2 的列）：只有**形状**，没有正文。
    static func visibleRangeJSON(windowFrame: CGRect?, scan: AdapterScan) -> String? {
        var payload: [String: Any] = ["rule": scan.ruleID]
        if let windowFrame {
            payload["window"] = [
                "x": Int(windowFrame.origin.x.rounded()), "y": Int(windowFrame.origin.y.rounded()),
                "w": Int(windowFrame.width.rounded()), "h": Int(windowFrame.height.rounded()),
            ]
        }
        payload["regions"] = scan.regions.map { region -> [String: Any] in
            var item: [String: Any] = [
                "name": region.name,
                "chars": region.text.count,
                "visible": region.visibleNodes,
                "offscreen": region.offscreenNodes,
                "scrollback": region.scrollbackNodes,
            ]
            if region.clippedByCharRange { item["char_range_clipped"] = true }
            if region.truncated { item["truncated"] = true }
            if let rect = region.rect {
                item["rect"] = [Int(rect.origin.x.rounded()), Int(rect.origin.y.rounded()),
                                Int(rect.width.rounded()), Int(rect.height.rounded())]
            }
            return item
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 遍历预算

    /// 一次扫描共用的限额账本。**所有区域共用同一份预算**——
    /// 规则里写三个区域不该让主线程多花三倍时间。
    struct Budget {
        var limits: AX.BFSLimits
        var maxFrameProbes: Int
        var visited = 0
        var frameProbes = 0
        var hitNodeLimit = false
        var reachedDepthLimit = false
        var hitFrameProbeLimit = false

        mutating func visit() -> Bool {
            guard visited < limits.maxNodes else { hitNodeLimit = true; return false }
            visited += 1
            return true
        }

        mutating func allowFrameProbe() -> Bool {
            guard frameProbes < maxFrameProbes else { hitFrameProbeLimit = true; return false }
            frameProbes += 1
            return true
        }
    }

    private static func probeFrame(_ node: any AXNodeSource, budget: inout Budget) -> CGRect? {
        guard budget.allowFrameProbe() else { return nil }
        return node.frame
    }

    private static func intersect(_ a: CGRect?, _ b: CGRect?) -> CGRect? {
        guard let a else { return b }
        guard let b else { return a }
        let result = a.intersection(b)
        return result.isNull || result.isEmpty ? a : result
    }

    // MARK: - 定位

    /// 按 locator 在窗口子树里找第一个命中的节点（BFS，吃同一份预算）。
    static func find(_ locator: ElementLocator, from window: any AXNodeSource,
                     budget: inout Budget) -> (any AXNodeSource)? {
        if case .rolePath(let path) = locator { return descend(path, from: window, budget: &budget) }
        var queue: [(any AXNodeSource, Int)] = [(window, 0)]
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            guard budget.visit() else { return nil }
            if matches(locator, node) { return node }
            if depth < budget.limits.maxDepth {
                for child in node.children { queue.append((child, depth + 1)) }
            } else {
                budget.reachedDepthLimit = true
            }
        }
        return nil
    }

    private static func descend(_ path: [String], from window: any AXNodeSource,
                                budget: inout Budget) -> (any AXNodeSource)? {
        var current: any AXNodeSource = window
        for role in path {
            guard budget.visit() else { return nil }
            guard let next = current.children.first(where: { $0.role == role }) else { return nil }
            current = next
        }
        return current
    }

    static func matches(_ locator: ElementLocator, _ node: any AXNodeSource) -> Bool {
        switch locator {
        case .role(let role):
            return node.role == role
        case .roleAndSubrole(let role, let subrole):
            return node.role == role && node.subrole == subrole
        case .identifier(let id):
            return node.identifier == id
        case .wholeWindow:
            return true
        case .rolePath, .relativeRect, .insetRect:
            return false
        }
    }

    // MARK: - 读取

    private static func readValue(_ node: any AXNodeSource, into result: inout RegionScan,
                                  region: RegionRule) {
        guard let (text, clipped) = node.viewportText(), !text.isEmpty else { return }
        result.clippedByCharRange = clipped
        append(text, to: &result, region: region)
        result.visibleNodes = 1
    }

    /// 子树 BFS，收集文本角色。视口裁剪分两层：
    /// 1. **容器**整个不在视口内就整棵子树跳过（回滚区最大的一块开销就是这么省掉的）；
    /// 2. 文本节点自己再判一次，读不到 frame 就按可见处理。
    private static func readSubtree(_ root: any AXNodeSource, viewport: CGRect?,
                                    into result: inout RegionScan, region: RegionRule,
                                    budget: inout Budget) {
        var queue: [(any AXNodeSource, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            guard budget.visit() else { break }
            let role = node.role
            // AXSecureTextField 永不暴露值，直接跳过整棵子树（沿用 M0 的处理）。
            if role == "AXSecureTextField" { continue }

            let carried = node.viewportText()
            var visible: Bool? = nil
            // 探到的矩形留着复用：回滚区统计再读一次 `node.frame` 就是**两条不计预算的
            // AX 消息**（每个视口外节点多两条），而它要的正是同一个矩形。
            var probed: CGRect? = nil
            if region.clipToViewport, let viewport,
               shouldProbeFrame(role: role, hasText: carried != nil) {
                probed = probeFrame(node, budget: &budget)
                visible = Viewport.isVisible(probed, in: viewport)
            }

            if textRoles.contains(role), let (text, clipped) = carried {
                if visible == false {
                    result.offscreenNodes += 1
                    if Viewport.isScrollback(probed, in: viewport) { result.scrollbackNodes += 1 }
                } else {
                    if clipped { result.clippedByCharRange = true }
                    append(text, to: &result, region: region)
                    result.visibleNodes += 1
                }
            } else if visible == false {
                // 容器整个在视口外：整棵子树都不用看了。
                result.offscreenNodes += 1
                if Viewport.isScrollback(probed, in: viewport) { result.scrollbackNodes += 1 }
                continue
            }

            if depth < budget.limits.maxDepth {
                for child in node.children { queue.append((child, depth + 1)) }
            } else if !node.children.isEmpty {
                budget.reachedDepthLimit = true
            }
        }
    }

    /// 消息列表：只取**视口内已渲染**的行，每行按子元素顺序拼「发送者 时间 文本」。
    ///
    /// 行结构不认识时（子元素里没有可辨认的发送者 / 时间）退化成"整行文本按顺序拼起来"——
    /// 这仍然是有用的证据，只是发送者与时间要靠 OCR 或人来看。
    private static func readRows(_ list: any AXNodeSource, viewport: CGRect?,
                                 into result: inout RegionScan, region: RegionRule,
                                 budget: inout Budget) {
        for row in list.children {
            guard budget.visit() else { break }
            guard rowRoles.contains(row.role) else { continue }
            var visible: Bool? = nil
            var probed: CGRect? = nil           // 同上：探到的矩形复用，不再多问一次坐标
            if region.clipToViewport, let viewport {
                probed = probeFrame(row, budget: &budget)
                visible = Viewport.isVisible(probed, in: viewport)
            }
            if visible == false {
                result.offscreenNodes += 1
                if Viewport.isScrollback(probed, in: viewport) { result.scrollbackNodes += 1 }
                continue
            }
            var pieces: [String] = []
            collectRowText(row, depth: 0, maxDepth: 4, into: &pieces, budget: &budget)
            guard !pieces.isEmpty else { continue }
            append(pieces.joined(separator: " "), to: &result, region: region)
            result.visibleNodes += 1
        }
    }

    private static func collectRowText(_ node: any AXNodeSource, depth: Int, maxDepth: Int,
                                       into pieces: inout [String], budget: inout Budget) {
        guard depth <= maxDepth, budget.visit() else { return }
        if node.role == "AXSecureTextField" { return }
        if let text = node.visibleText, !text.isEmpty,
           textRoles.contains(node.role) || node.role == "AXButton" || node.role == "AXImage" {
            pieces.append(text)
        }
        for child in node.children {
            collectRowText(child, depth: depth + 1, maxDepth: maxDepth,
                           into: &pieces, budget: &budget)
        }
    }

    /// 追加一段文本，命中区域字符上限时置 `truncated` 并停止追加（不静默截断）。
    private static func append(_ text: String, to result: inout RegionScan, region: RegionRule) {
        guard !result.truncated else { return }
        let separator = result.text.isEmpty ? "" : "\n"
        let remaining = region.maxChars - result.text.count
        guard remaining > 0 else { result.truncated = true; return }
        if text.count > remaining {
            result.text += separator + String(text.prefix(remaining))
            result.truncated = true
        } else {
            result.text += separator + text
        }
    }
}
