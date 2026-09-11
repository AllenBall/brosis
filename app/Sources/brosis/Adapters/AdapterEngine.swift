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
    /// - `minSize`：宽或高小于它就算没渲染出来。**文本节点**传 `minVisibleSize`（2026-09-11 飞书探针：
    ///   虚拟列表把滚出视口的消息行留在树里，frame 是 789×1、全叠在列表顶部，它们的文本节点也是 …×1，
    ///   1 pt 与视口相交，原来的判定把它们当成了视口内正文；任何真正渲染出来的文字都不止 2 pt 高）。
    ///   容器不传：Electron 里 1 pt 高的弹层容器（`#pp_popupContainer` 789×1）底下挂着绝对定位的可见子树。
    static func isVisible(_ frame: CGRect?, in viewport: CGRect?, minSize: CGFloat = 0) -> Bool? {
        guard let frame, let viewport, !viewport.isEmpty else { return nil }
        // 零面积的节点（AX 里常见的占位元素）按不可见处理，免得把空节点算进"视口内"。
        guard !frame.isEmpty else { return false }
        guard frame.width >= minSize, frame.height >= minSize else { return false }
        return !frame.intersection(viewport).isEmpty
    }

    /// 文本节点宽或高小于它就算没渲染出来（见 `isVisible`）。
    static let minVisibleSize: CGFloat = 2

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
    /// `.webArea` 定位器挑中的 web area 的 AXTitle（飞书：`messenger-chat` / 「主页 - 飞书云文档」…）。
    var pickedWebAreaTitle: String?
    /// 区域根锚到了 `anchorClass` 那个节点上（而不是 web area 本身）。
    var anchored: Bool = false

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

    /// 第一个读到东西的标题区域的文本（会话名）。规则"第一个非空的标题区域算数"只写在这一处。
    var conversationTitle: String? { regions.first { $0.kind == .title && !$0.isEmpty }?.text }
    /// 用 `.webArea` 定位的那个区域（挑中了哪个 web area、锚没锚上）。
    var pickedWebArea: RegionScan? { regions.first { $0.pickedWebAreaTitle != nil } }

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

    static func shouldProbeFrame(role: String, hasText: Bool, probeContainers: Bool = true) -> Bool {
        hasText || textRoles.contains(role) || (probeContainers && scrollContainerRoles.contains(role))
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
        let layout = rule.chatLayout ?? ChatLayout()

        // 预处理：规则里有 `.webArea` 区域就先把 web area 挑出来，顺手把锚点与各 `.webAreaDescendant`
        // 要的节点在同一趟 BFS 里找齐——挑一次、走一遍，标题与正文共用。
        var pick: WebAreaPickResult?
        if let region = rule.regions.first(where: { $0.locator.webAreaPick != nil }),
           let spec = region.locator.webAreaPick {
            let descendants = Set(rule.regions.compactMap { region -> String? in
                if case .webAreaDescendant(let domClass) = region.locator { return domClass }
                return nil
            })
            pick = pickWebArea(spec, from: window, descendantClasses: descendants,
                               markerClass: region.rowLabels?.onlyWhenAncestorClass, budget: &budget)
        }

        // 标题区域先读（按 kind 排，不靠规则里写的顺序）：正文读行前缀时要拿会话名当对方名，
        // 与 OCR 那条路"先定会话身份，再成文"同一口径。
        let ordered = rule.regions.enumerated()
            .sorted { ($0.element.kind == .title ? 0 : 1, $0.offset) < ($1.element.kind == .title ? 0 : 1, $1.offset) }
            .map(\.element)

        for region in ordered {
            var result = RegionScan(name: region.name, kind: region.kind)

            // —— 1. 定位 ——
            let located: (any AXNodeSource)?
            // 定位到 AX 节点的三种定位器：矩形在 switch 之后统一探，`fallbackInset` 对它们一视同仁。
            var probesRect = false
            var probedRect: CGRect?
            switch region.locator {
            case .webArea:
                located = pick?.root
                result.pickedWebAreaTitle = pick?.title
                result.anchored = pick?.anchored ?? false
                probesRect = true
            case .webAreaDescendant(let domClass):
                located = pick?.descendants[domClass]
                // 矩形只在裁视口 / OCR 用得上；纯 AX 的标题区域不必为它探两次 frame。
                if region.needsRect { result.rect = located.flatMap { probeFrame($0, budget: &budget) } }
                // 挑中的不是首选那个（云文档 / 邮箱）：web area 的 AXTitle 就是页标题，直接当文本；
                // 没有矩形 ⇒ 不会为它排 OCR。
                if located == nil, let pick, !pick.preferred,
                   let title = pick.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    append(title, to: &result, region: region)
                    result.visibleNodes += 1
                }
            case .relativeRect(let relative):
                located = nil
                result.rect = windowFrame.map { relative.resolve(in: $0) }
            case .insetRect(let inset):
                located = nil
                result.rect = windowFrame.map { inset.resolve(in: $0) }
            case .wholeWindow:
                located = window
                result.rect = windowFrame
            case .primaryWebArea:
                let picked = primaryWebArea(from: window, budget: &budget)
                located = picked?.node
                probedRect = picked?.frame           // 挑选时探过的就不再探第二次
                probesRect = true
            default:
                located = region.preferRichestMatch
                    ? findRichest(region.locator, from: window, budget: &budget)
                    : find(region.locator, from: window, budget: &budget)
                probesRect = true
            }
            if probesRect {
                result.rect = probedRect ?? located.flatMap { probeFrame($0, budget: &budget) }
                    ?? fallbackRect(region, windowFrame: windowFrame)
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
                    // 行前缀只在规则要求的祖先 class（单聊标记）真的见到时启用；行本身照认。
                    let prefixes = region.rowLabels.map { labels in
                        labels.onlyWhenAncestorClass == nil || pick?.sawMarker == true
                    } ?? false
                    let peer = scan.conversationTitle.flatMap(firstLine) ?? layout.peerLabel
                    readSubtree(node, viewport: viewport, into: &result, region: region, budget: &budget,
                                labels: prefixes ? (me: layout.selfLabel, peer: peer) : nil)
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
                                                  frameChanged: frameChanged && region.ocrOnFrameChange,
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
        // 兜底规则（bundleIDs 为空）走的就是"全窗口 BFS"，口径记 .ax 而不是 .adapter。
        if rule.bundleIDs.isEmpty { scan.captureMethod = .ax }
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
            if let title = region.pickedWebAreaTitle {
                item["web_area"] = title
                item["anchored"] = region.anchored
            }
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

    /// 定位器没命中时的区域矩形：规则给了 `fallbackInset` 就按它从窗口内缩，否则整窗。
    private static func fallbackRect(_ region: RegionRule, windowFrame: CGRect?) -> CGRect? {
        guard let windowFrame else { return nil }
        return region.fallbackInset?.resolve(in: windowFrame) ?? windowFrame
    }

    private static func intersect(_ a: CGRect?, _ b: CGRect?) -> CGRect? {
        guard let a else { return b }
        guard let b else { return a }
        let result = a.intersection(b)
        return result.isNull || result.isEmpty ? a : result
    }

    // MARK: - 定位

    /// `walk` 的每一步：继续往下、跳过这棵子树、或整个遍历到此为止。
    enum Step { case descend, skip, stop }

    /// 所有定位器共用的 BFS 骨架：同一份预算、同一套深度记账。
    /// 到了 `maxDepth` 还有子节点没进就标 `reachedDepthLimit`（与 M1 起的 `find` 口径一致）。
    static func walk(from root: any AXNodeSource, maxDepth: Int, budget: inout Budget,
                     visit: (any AXNodeSource, Int) -> Step) {
        var queue: [(any AXNodeSource, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (node, depth) = queue.removeFirst()
            guard budget.visit() else { return }
            switch visit(node, depth) {
            case .stop: return
            case .skip: continue
            case .descend: break
            }
            if depth < maxDepth {
                for child in node.children { queue.append((child, depth + 1)) }
            } else {
                budget.reachedDepthLimit = true
            }
        }
    }

    /// 按 locator 在窗口子树里找第一个命中的节点。
    static func find(_ locator: ElementLocator, from window: any AXNodeSource,
                     budget: inout Budget) -> (any AXNodeSource)? {
        if case .rolePath(let path) = locator { return descend(path, from: window, budget: &budget) }
        var found: (any AXNodeSource)?
        walk(from: window, maxDepth: budget.limits.maxDepth, budget: &budget) { node, _ in
            guard matches(locator, node) else { return .descend }
            found = node
            return .stop
        }
        return found
    }

    /// 找**内容最多**的那个命中节点（`preferRichestMatch` 的实现）。
    ///
    /// 一个 Electron 窗口常有多个 `AXWebArea`：外壳一个、真正的应用一个、内嵌预览再一个。
    /// 取第一个就会稳定落在空壳上（实测 Claude 桌面版：外壳子树 2 个节点、0 字符）。
    /// 命中的节点自己就是候选，不再往它里面找同类（嵌套 iframe 另算）。
    static func findRichest(_ locator: ElementLocator, from window: any AXNodeSource,
                            budget: inout Budget,
                            maxCandidates: Int = 4, weightBudget: Int = 250,
                            goodEnough: Int = 200) -> (any AXNodeSource)? {
        var candidates: [any AXNodeSource] = []
        walk(from: window, maxDepth: budget.limits.maxDepth, budget: &budget) { node, _ in
            guard matches(locator, node) else { return .descend }
            candidates.append(node)
            return candidates.count < maxCandidates ? .skip : .stop
        }
        return richest(candidates, budget: &budget, weightBudget: weightBudget, goodEnough: goodEnough)
    }

    /// 候选里挑字最多的那个。只有一个候选时完全不估。
    ///
    /// `goodEnough`：某个候选估出的字数达到它就不再往下比。Claude 桌面版 / Chrome 用 200——
    /// 绝大多数情况第一个有内容的就是要找的那个；`pickWebArea` 传 `Int.max`——首选缺席的场景
    /// 候选只有一两个，早退省不了什么，却可能挑错（2026-09-11 复查 F1 的教训）。
    private static func richest(_ candidates: [any AXNodeSource], budget: inout Budget,
                                weightBudget: Int, goodEnough: Int) -> (any AXNodeSource)? {
        guard candidates.count > 1 else { return candidates.first }
        var best: (node: any AXNodeSource, weight: Int)?
        for candidate in candidates {
            let weight = textWeight(of: candidate, budget: &budget, maxNodes: weightBudget)
            if best == nil || weight > best!.weight { best = (candidate, weight) }
            if weight >= goodEnough { break }
        }
        return best?.node
    }

    /// 粗估一棵子树里有多少字，只用来在同角色候选之间挑一个。**不是真正的读取**：
    /// 不裁视口、不去重、不管字符上限，走的节点也计入同一份预算。
    private static func textWeight(of root: any AXNodeSource, budget: inout Budget,
                                   maxNodes: Int) -> Int {
        var total = 0
        var seen = 0
        var queue: [any AXNodeSource] = [root]
        while !queue.isEmpty, seen < maxNodes {
            let node = queue.removeFirst()
            seen += 1
            guard budget.visit() else { break }
            if textRoles.contains(node.role), let text = node.visibleText {
                total += text.count
            }
            queue.append(contentsOf: node.children)
        }
        return total
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
        case .domClass(let domClass):
            return node.domClasses.contains(domClass)
        case .wholeWindow:
            return true
        case .rolePath, .relativeRect, .insetRect, .webArea, .webAreaDescendant, .primaryWebArea:
            return false
        }
    }

    // MARK: - 按标题挑 web area / 按 DOM class 下钻

    /// 窗口里的 AXWebArea（不进它们内部：要找的是它们的兄弟，不是里面的 iframe）。
    /// 探针 `--dump-webarea` 也用它——探针列出来的与引擎挑选的必须是同一批候选。
    /// `readTitles: false` 时不读 AXTitle（每个 web area 省一条 AX 消息）——`.primaryWebArea` 用不上标题。
    static func webAreas(in window: any AXNodeSource, budget: inout Budget,
                         maxCount: Int = 6, readTitles: Bool = true)
        -> [(node: any AXNodeSource, title: String?, depth: Int)] {
        var areas: [(node: any AXNodeSource, title: String?, depth: Int)] = []
        walk(from: window, maxDepth: budget.limits.maxDepth, budget: &budget) { node, depth in
            guard node.role == "AXWebArea" else { return .descend }
            areas.append((node, readTitles ? node.title : nil, depth))
            return areas.count < maxCount ? .skip : .stop
        }
        return areas
    }

    /// `pickWebArea` 的结果。
    struct WebAreaPickResult {
        var webArea: any AXNodeSource
        var title: String?
        /// 挑中的是 `prefer` 那个。
        var preferred: Bool
        /// 锚到的节点（`anchorClass`）；nil = 用 web area 本身当区域根。
        var anchor: (any AXNodeSource)?
        /// 各 `.webAreaDescendant` 区域要的节点（只在 `preferred` 时找）。
        var descendants: [String: any AXNodeSource] = [:]
        /// 去锚点的路上见到过 `markerClass`（飞书：`p2pChat` = 单聊）。
        var sawMarker = false

        var root: any AXNodeSource { anchor ?? webArea }
        var anchored: Bool { anchor != nil }
    }

    /// 在窗口的 AXWebArea 里按 `WebAreaPick` 挑一个；挑中首选那个时再用一趟 BFS 把锚点与
    /// `descendantClasses` 要的节点一起找齐。
    static func pickWebArea(_ pick: WebAreaPick, from window: any AXNodeSource,
                            descendantClasses: Set<String> = [], markerClass: String?,
                            budget: inout Budget) -> WebAreaPickResult? {
        let areas = webAreas(in: window, budget: &budget)
            .filter { area in area.title.map { !pick.exclude.contains($0) } ?? true }
        guard !areas.isEmpty else { return nil }
        if let prefer = pick.prefer, let area = areas.first(where: { $0.title == prefer.title }) {
            var result = WebAreaPickResult(webArea: area.node, title: area.title, preferred: true)
            var targets = descendantClasses
            if let anchorClass = prefer.anchorClass { targets.insert(anchorClass) }
            let found = findClasses(targets, from: area.node, markerClass: markerClass, budget: &budget)
            result.sawMarker = found.sawMarker
            result.anchor = prefer.anchorClass.flatMap { found.nodes[$0] }
            result.descendants = found.nodes
            return result
        }
        // 没有首选时才比"谁最富"，而且比完所有候选（`goodEnough: .max`）。
        guard let node = richest(areas.map(\.node), budget: &budget, weightBudget: 250,
                                 goodEnough: Int.max) else { return nil }
        let title = areas.first { $0.node.role == node.role && $0.title == node.title }?.title ?? node.title
        return WebAreaPickResult(webArea: node, title: title, preferred: false)
    }

    /// `.primaryWebArea`：在窗口的 AXWebArea 里挑主文档（判据见 `ElementLocator.primaryWebArea`）。
    /// 候选与 `webAreas(in:)` 同一批（不进 web area 内部：iframe、PDF 阅读器的内层不算）。
    /// 返回值带上挑选时探过的 frame（只有比过面积才有），调用方不必再探一次。
    static func primaryWebArea(from window: any AXNodeSource, budget: inout Budget)
        -> (node: any AXNodeSource, frame: CGRect?)? {
        let areas = webAreas(in: window, budget: &budget, readTitles: false).map(\.node)
        // 1. 有外部地址的候选时，内部页（侧边栏 / DevTools / 扩展外壳 / bundle 内 file://）出局。
        //    URL 读不到的按外部算。
        let external = areas.filter { !($0.url.map(AX.isInternalURL) ?? false) }
        let pool = external.isEmpty ? areas : external
        guard pool.count > 1 else { return pool.first.map { ($0, nil) } }
        // 2. 面积最大；读不到 frame 的按 0。
        var sized: [(node: any AXNodeSource, frame: CGRect?, area: Double)] = []
        for node in pool {
            let frame = probeFrame(node, budget: &budget)
            sized.append((node, frame, frame.map { Double($0.width * $0.height) } ?? 0))
        }
        sized.sort { $0.area > $1.area }
        let top = sized[0].area
        // 3. 面积相近（5% 内）的才比字数，而且比完所有候选（早退会挑错，同 `pickWebArea`）。
        let contenders = sized.filter { $0.area >= top * 0.95 }
        guard contenders.count > 1 else { return contenders.first.map { ($0.node, $0.frame) } }
        var best = contenders[0]
        var bestWeight = -1
        for candidate in contenders {
            let weight = textWeight(of: candidate.node, budget: &budget, maxNodes: 250)
            if weight > bestWeight { best = candidate; bestWeight = weight }
        }
        return (best.node, best.frame)
    }

    /// 从 `root` 起一趟 BFS，把 DOM class 含 `targets` 之一的节点各找出第一个；全找齐就停。
    /// 顺带记下沿途见没见过 `markerClass`。每个经过的节点读一次 `AXDOMClassList`，
    /// 所以只给声明了 class 锚点的规则用，而且路径要短（飞书从 web area 到 `chatMessages` 约 40 个节点）。
    static func findClasses(_ targets: Set<String>, from root: any AXNodeSource,
                            markerClass: String? = nil, budget: inout Budget,
                            maxDepth: Int = 24) -> (nodes: [String: any AXNodeSource], sawMarker: Bool) {
        var nodes: [String: any AXNodeSource] = [:]
        var sawMarker = false
        guard !targets.isEmpty else { return (nodes, false) }
        walk(from: root, maxDepth: maxDepth, budget: &budget) { node, _ in
            let classes = node.domClasses
            if let markerClass, classes.contains(markerClass) { sawMarker = true }
            for target in targets where nodes[target] == nil && classes.contains(target) {
                nodes[target] = node
            }
            return nodes.count == targets.count ? .stop : .descend
        }
        return (nodes, sawMarker)
    }

    /// 标题区域的文本 → 一行会话名：第一行、去首尾空白、按 `ChatTitle.maxTitleCharacters` 截；空返回 nil。
    static func firstLine(_ title: String) -> String? {
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? title
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(ChatTitle.maxTitleCharacters))
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
                                    budget: inout Budget,
                                    labels: (me: String, peer: String)?) {
        // 待访问项：节点、相对区域根的深度、所属行（0 = 不在任何行里）、行的深度、这一行的前缀。
        struct Item {
            var node: any AXNodeSource
            var depth: Int
            var row: Int
            var rowDepth: Int
            var prefix: String?
        }
        let documentOrder = region.documentOrder
        // 行只在先序遍历下界定得了：广度优先会把一行的文本散在各层。
        let rowLabels = documentOrder ? region.rowLabels : nil
        let prunes = !region.pruneClasses.isEmpty
        var pending = [Item(node: root, depth: 0, row: 0, rowDepth: 0, prefix: nil)]
        var nextRow = 1
        var lastPrefixedRow = 0
        while !pending.isEmpty {
            let item = documentOrder ? pending.removeLast() : pending.removeFirst()
            let node = item.node
            guard budget.visit() else { break }
            let role = node.role
            // AXSecureTextField 永不暴露值，直接跳过整棵子树（沿用 M0 的处理）；
            // 规则排除的角色（飞书的输入框）同样整棵跳过。
            if role == "AXSecureTextField" || region.excludeRoles.contains(role) { continue }

            var row = item.row, rowDepth = item.rowDepth, prefix = item.prefix
            var isRow = false
            // class 只对 AXGroup 读、只读一次，两个用途共用：认行、按 class 剪子树。
            // 剪子树的 class 在行里只看行下 `pruneDepthBelowRow` 层，不在行里看区域根下 `classProbeMaxDepth` 层。
            if role == "AXGroup" {
                let wantsRow = rowLabels != nil && row == 0 && item.depth <= region.classProbeMaxDepth
                let wantsPrune = prunes && (row != 0
                    ? item.depth - rowDepth <= region.pruneDepthBelowRow
                    : item.depth <= region.classProbeMaxDepth)
                if wantsRow || wantsPrune {
                    let classes = node.domClasses
                    if wantsPrune, !region.pruneClasses.isDisjoint(with: classes) { continue }
                    if wantsRow, let rowLabels {
                        if classes.contains(rowLabels.selfClass) {
                            isRow = true; prefix = labels?.me
                        } else if classes.contains(rowLabels.peerClass) {
                            isRow = true; prefix = labels?.peer
                        }
                        if isRow { row = nextRow; nextRow += 1; rowDepth = item.depth }
                    }
                }
            }

            // 非文本节点的 value / description / title 只在"容器也要探 frame"时才有用（判它带不带正文）；
            // 关掉容器探测的规则（飞书）省下这三次 AX 调用——一棵树里七成节点是 AXGroup。
            let isText = textRoles.contains(role)
            let carried = (isText || region.probeContainerFrames) ? node.viewportText() : nil
            var visible: Bool? = nil
            // 探到的矩形留着复用：回滚区统计再读一次 `node.frame` 就是**两条不计预算的
            // AX 消息**（每个视口外节点多两条），而它要的正是同一个矩形。
            var probed: CGRect? = nil
            // 行是虚拟列表的单位：滚出视口的行以 1 pt 占位留在树里，整行不可见就整棵子树剪掉，
            // 比在它的每个文本节点上各判一次省得多。
            if region.clipToViewport, let viewport,
               isRow || shouldProbeFrame(role: role, hasText: carried != nil,
                                         probeContainers: region.probeContainerFrames) {
                probed = probeFrame(node, budget: &budget)
                visible = Viewport.isVisible(probed, in: viewport,
                                             minSize: isText ? Viewport.minVisibleSize : 0)
            }

            if isText, let (text, clipped) = carried {
                if visible == false {
                    result.offscreenNodes += 1
                    if Viewport.isScrollback(probed, in: viewport) { result.scrollbackNodes += 1 }
                } else {
                    if clipped { result.clippedByCharRange = true }
                    var line = text
                    // 一行只在它的第一段文本前加发送者前缀。
                    if row != 0, row != lastPrefixedRow, let prefix {
                        line = prefix + "：" + text
                        lastPrefixedRow = row
                    }
                    append(line, to: &result, region: region)
                    result.visibleNodes += 1
                }
            } else if visible == false {
                // 容器（或整行）在视口外：整棵子树都不用看了。
                result.offscreenNodes += 1
                if Viewport.isScrollback(probed, in: viewport) { result.scrollbackNodes += 1 }
                continue
            }

            if item.depth < budget.limits.maxDepth {
                let children = node.children
                for child in (documentOrder ? Array(children.reversed()) : children) {
                    pending.append(Item(node: child, depth: item.depth + 1,
                                        row: row, rowDepth: rowDepth, prefix: prefix))
                }
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
