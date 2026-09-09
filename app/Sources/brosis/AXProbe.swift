import AppKit
import BrosisCore
import Foundation

/// `--ax-probe [bundle id ...]`：量 Chromium / Electron 应用的 AX 树**什么时候才有内容**。
///
/// 为什么需要它：`AXManualAccessibility` 设上之后 Chromium 才开始把渲染进程的
/// 无障碍树建起来，这是**异步**的。采集端现在的做法是设完立刻遍历
/// （`EventSkeleton.attach` 里 `enableManualAccessibilityIfNeeded` 之后紧接着 `record`），
/// 于是第一次读到的很可能是空树 → 记成 `unavailable` → 落到 OCR 回退。
/// 这个探针在**同一条生产遍历路径**（`AdapterEngine.scan` + 应用自己的适配规则）上
/// 按时间点重复取样，直接给出"要等多久"这个数，而不是照抄别人 issue 里的 200 ms。
///
/// 只读：不开库、不截图、不申请任何权限。没有辅助功能授权时直接说明并退出，
/// **绝不弹 TCC 框**（用 `AXIsProcessTrusted()`，不是带 prompt 的那个变体）。
enum AXProbe {

    /// 取样时刻（毫秒）。0 = 设完属性立刻读，也就是采集端现在的行为。
    static let sampleDelaysMS = [0, 100, 250, 500, 1000, 2000, 4000]

    static func run(bundleIDs: [String]) -> Int32 {
        print("brosis \(BuildInfo.version) AX 树就绪时间探针（只读，不开库、不截图）")
        guard AXIsProcessTrusted() else {
            print("没有辅助功能授权，读不了任何应用的 AX 树。")
            print("在「系统设置 → 隐私与安全性 → 辅助功能」里给 brosis 打开后重跑。")
            return 2
        }

        let targets = bundleIDs.isEmpty ? defaultTargets() : bundleIDs
        guard !targets.isEmpty else {
            print("没有正在运行的目标应用。用法：brosis --ax-probe [bundle id ...]")
            return 1
        }

        for bundleID in targets {
            probe(bundleID: bundleID)
        }
        print("\n读法：t=0 那一列就是采集端现在拿到的东西。它是 0、而后面某一列不是 0，")
        print("就说明「不可用」里有一部分纯粹是读得太早，不是这个应用给不出文本。")
        return 0
    }

    /// 没给参数时，探所有**正在运行的** Chromium 系应用（普通应用，不含后台进程）。
    private static func defaultTargets() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> String? in
                guard let id = app.bundleIdentifier else { return nil }
                let detection = AX.chromiumDetection(bundleID: id, bundleURL: app.bundleURL).detection
                return detection == .notChromium ? nil : id
            }
    }

    private static func probe(bundleID: String) {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else {
            print("\n## \(bundleID)：没在运行，跳过")
            return
        }
        let pid = app.processIdentifier
        let detection = AX.chromiumDetection(bundleID: bundleID, bundleURL: app.bundleURL).detection
        let rule = AdapterRegistry.rule(for: bundleID)
        print("\n## \(app.localizedName ?? bundleID)（\(bundleID)）pid \(pid)")
        print("- Chromium 系判定：\(detection.rawValue)"
              + "；适配规则：\(rule.id)")

        // 设属性**之前**先读一次：区分"本来就读得到"与"靠这个属性才读得到"。
        let before = sample(pid: pid, bundleID: bundleID, rule: rule)
        print("- 设 AXManualAccessibility 之前：\(before.describe())")

        let element = AX.applicationElement(pid: pid)
        let error = AXUIElementSetAttributeValue(
            element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // kAXErrorAttributeUnsupported 说明这个应用根本不认这个属性——Electron 才实现了它，
        // 纯 Chromium（Chrome / Edge / CEF）不认，那边只吃 AXEnhancedUserInterface，
        // 而后者会把缓冲的按键在断开时重放进焦点输入框，我们**不用**它。
        print("- 设 AXManualAccessibility：\(describe(error))")

        for delay in sampleDelaysMS {
            if delay > 0 { Thread.sleep(forTimeInterval: Double(delay) / 1000) }
            let taken = sample(pid: pid, bundleID: bundleID, rule: rule)
            let marker = delay == 0 ? "  ← 采集端现在读到的" : ""
            print("- t=\(delay) ms：\(taken.describe())\(marker)")
        }

        // 读到 0 字符时，光知道"是 0"没用——要区分两种完全不同的处境：
        //   a. 窗口里根本没有 AXWebArea  ⇒ Chromium 的无障碍压根没打开，属性没起作用；
        //   b. AXWebArea 在，但底下没有文本节点 ⇒ 打开了，只是内容没暴露。
        // 这两种要做的事不一样，所以把实际的角色分布打出来。
        dumpStructure(pid: pid)
        depthSweep(pid: pid, bundleID: bundleID, rule: rule)
    }

    /// 深度 / 节点上限扫描。
    ///
    /// React 这类前端的 DOM 是**深而窄**的：AXWebArea 往下常常是一长串只有一个孩子的
    /// AXGroup，真正的 AXStaticText 埋在二三十层以下。如果 BFS 的 maxDepth 比这个浅，
    /// 遍历就会在还没碰到任何文本的地方停住——现象和"这个应用不给文本"一模一样，
    /// 但病因完全不同（前者调一个常量就好，后者只能上 OCR）。
    private static func depthSweep(pid: pid_t, bundleID: String, rule: AdapterRule) {
        // 规则里 `clipToViewport: true` 会把落在视口外的节点整支剪掉。视口一旦算错
        // （窗口 frame 拿不到、坐标系不对），剪掉的就是**整棵**内容树——现象同样是 0 字符。
        for clip in [true, false] {
            var probeRule = rule
            probeRule.limits = AX.BFSLimits(maxNodes: 20_000, maxDepth: 40)
            probeRule.regions = rule.regions.map { region in
                var copy = region
                copy.clipToViewport = clip
                return copy
            }
            guard let window = AX.focusedWindow(pid: pid) else { return }
            let read = AX.focusedWindowInfo(pid: pid, bundleID: bundleID)
            let scan = AdapterEngine.scan(rule: probeRule, window: LiveAXNode(window),
                                          windowFrame: read.info.frame)
            print("- clipToViewport=\(clip)：\(scan.totalChars) 字符 / "
                  + "\(scan.visitedNodes) 节点 / \(scan.completeness.rawValue)"
                  + "；窗口 frame=\(read.info.frame.map { "\(Int($0.width))×\(Int($0.height))" } ?? "拿不到")")
        }
        print("- 深度扫描（节点上限固定放到 20000，只动深度）：")
        for depth in [8, 14, 20, 30, 40, 60, 100] {
            var probeRule = rule
            probeRule.limits = AX.BFSLimits(maxNodes: 20_000, maxDepth: depth)
            let started = Date()
            guard let window = AX.focusedWindow(pid: pid) else { return }
            let read = AX.focusedWindowInfo(pid: pid, bundleID: bundleID)
            let scan = AdapterEngine.scan(rule: probeRule, window: LiveAXNode(window),
                                          windowFrame: read.info.frame)
            let ms = Date().timeIntervalSince(started) * 1000
            print("  maxDepth=\(depth)：\(scan.totalChars) 字符 / \(scan.visitedNodes) 节点"
                  + " / \(scan.completeness.rawValue)"
                  + "（\(String(format: "%.0f", ms)) ms"
                  + "\(scan.reachedDepthLimit ? "，仍被深度截断" : "")）")
        }
    }

    /// 把焦点窗口的角色分布与前几层结构打出来（只读角色名，不读任何文本值）。
    private static func dumpStructure(pid: pid_t) {
        guard let window = AX.focusedWindow(pid: pid) else { return }
        var roleCounts: [String: Int] = [:]
        var webAreas: [AXUIElement] = []
        var lines: [String] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        // 文本挂在哪个属性上，各家不一样：AXStaticText 通常在 AXValue，
        // 而 Chromium 的很多节点把可读文本放在 AXDescription / AXTitle 上。
        // 我们的 textRoles 只看 AXValue，所以这里三个都统计一遍。
        var withValue = 0, withTitle = 0, withDescription = 0
        var valueChars = 0, titleChars = 0, descChars = 0
        var samples: [String] = []
        while !queue.isEmpty, visited < 12_000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = AX.string(element, kAXRoleAttribute as String) ?? "(无角色)"
            roleCounts[role, default: 0] += 1
            if role == "AXWebArea" { webAreas.append(element) }
            if let v = AX.string(element, kAXValueAttribute as String), !v.isEmpty {
                withValue += 1; valueChars += v.count
                if samples.count < 6 { samples.append("AXValue/\(role)「\(v.prefix(40))」") }
            }
            if let t = AX.string(element, kAXTitleAttribute as String), !t.isEmpty {
                withTitle += 1; titleChars += t.count
                if samples.count < 6 { samples.append("AXTitle/\(role)「\(t.prefix(40))」") }
            }
            if let d = AX.string(element, kAXDescriptionAttribute as String), !d.isEmpty {
                withDescription += 1; descChars += d.count
                if samples.count < 6 { samples.append("AXDescription/\(role)「\(d.prefix(40))」") }
            }
            if depth <= 2 {
                let sub = AX.string(element, kAXSubroleAttribute as String)
                lines.append(String(repeating: "  ", count: depth) + "· " + role
                             + (sub.map { "/\($0)" } ?? ""))
            }
            guard depth < 40 else { continue }
            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString,
                                             &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                for child in children { queue.append((child, depth + 1)) }
            }
        }
        // AXWebArea 自己说了什么：有 URL / 标题就说明桥接是通的，
        // 那么 AXChildren 为 0 就只能是"渲染进程没把内容树推上来"。
        for area in webAreas.prefix(2) {
            var namesRef: CFArray?
            _ = AXUIElementCopyAttributeNames(area, &namesRef)
            let names = (namesRef as? [String]) ?? []
            var childCount: CFIndex = -1
            _ = AXUIElementGetAttributeValueCount(area, kAXChildrenAttribute as CFString, &childCount)
            print("- AXWebArea：子节点 \(childCount) 个"
                  + "；URL=\(AX.string(area, kAXURLAttribute as String) ?? "无")"
                  + "；标题=\(AX.string(area, kAXTitleAttribute as String) ?? "无")")
            print("  可读属性 \(names.count) 个：" + names.prefix(18).joined(separator: " "))
        }
        // 顺着 AXWebArea 往下逐层走，看树到底在哪一层断掉。
        for (index, area) in webAreas.enumerated() {
            // 每个 AXWebArea 各自的文本量。规则用 `.role("AXWebArea")` 取**第一个**匹配，
            // 如果第一个是 Electron 的空壳（file:// 那个），后面真正有内容的就永远读不到。
            var textNodes = 0, textChars = 0, seen = 0
            var walk: [AXUIElement] = [area]
            while !walk.isEmpty, seen < 6000 {
                let node = walk.removeFirst()
                seen += 1
                if AX.string(node, kAXRoleAttribute as String) == "AXStaticText",
                   let v = AX.string(node, kAXValueAttribute as String), !v.isEmpty {
                    textNodes += 1; textChars += v.count
                }
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString,
                                                 &ref) == .success,
                   let kids = ref as? [AXUIElement] { walk.append(contentsOf: kids) }
            }
            print("- AXWebArea #\(index)：子树 \(seen) 节点，"
                  + "AXStaticText \(textNodes) 个 / \(textChars) 字符"
                  + "；URL=\((AX.string(area, kAXURLAttribute as String) ?? "无").prefix(60))")
            print("  往下逐层：")
            var current = area
            for level in 1...12 {
                var childrenRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString,
                                                    &childrenRef) == .success,
                      let children = childrenRef as? [AXUIElement], !children.isEmpty else {
                    print("    第 \(level) 层：没有子节点了 ← 树到这里就断了")
                    break
                }
                let roles = children.compactMap { AX.string($0, kAXRoleAttribute as String) }
                let value = AX.string(children[0], kAXValueAttribute as String)
                let desc = AX.string(children[0], kAXDescriptionAttribute as String)
                print("    第 \(level) 层：\(children.count) 个 "
                      + "[\(Set(roles).sorted().joined(separator: ","))]"
                      + (value.map { "，首个 AXValue \($0.count) 字符" } ?? "")
                      + (desc.map { "，AXDescription「\($0.prefix(30))」" } ?? ""))
                current = children[0]
            }
        }
        let sorted = roleCounts.sorted { $0.value > $1.value }.prefix(10)
        print("- 角色分布（前 \(visited) 个节点）："
              + sorted.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        print("- 有没有 AXWebArea：" + (roleCounts["AXWebArea"] != nil ? "有" : "**没有**"))
        print("- 文本挂在哪：AXValue \(withValue) 个节点 / \(valueChars) 字符"
              + "；AXTitle \(withTitle) 个 / \(titleChars) 字符"
              + "；AXDescription \(withDescription) 个 / \(descChars) 字符")
        print("- 我们只认的角色：\(AX.textRoles.joined(separator: " "))"
              + "，其中在这棵树里出现："
              + AX.textRoles.filter { roleCounts[$0] != nil }
                  .map { "\($0)×\(roleCounts[$0] ?? 0)" }.joined(separator: " "))
        for sample in samples { print("  样本 " + sample) }
        for line in lines.prefix(14) { print("  " + line) }
    }

    private struct Sample {
        var chars = 0
        var nodes = 0
        var completeness: Completeness = .unavailable
        var elapsedMS = 0.0
        var noWindow = false

        func describe() -> String {
            if noWindow { return "拿不到焦点窗口" }
            return "\(chars) 字符 / \(nodes) 节点 / \(completeness.rawValue)"
                 + "（\(String(format: "%.0f", elapsedMS)) ms）"
        }
    }

    /// 走**生产同一条路**：有适配规则就用规则扫，没有就退回窗口整棵树的字符统计。
    private static func sample(pid: pid_t, bundleID: String, rule: AdapterRule) -> Sample {
        let started = Date()
        let read = AX.focusedWindowInfo(pid: pid, bundleID: bundleID)
        guard let window = read.element else { return Sample(noWindow: true) }
        // 与采集端逐字一致：`AdapterRegistry.rule(for:)` 对没有专门规则的应用给的是
        // 通用规则，所以这里不分叉——量的就是生产会拿到的那个数。
        let scan = AdapterEngine.scan(rule: rule, window: LiveAXNode(window),
                                      windowFrame: read.info.frame)
        var out = Sample()
        out.chars = scan.totalChars
        out.nodes = scan.visitedNodes
        out.completeness = scan.completeness
        out.elapsedMS = Date().timeIntervalSince(started) * 1000
        return out
    }

    private static func describe(_ error: AXError) -> String {
        switch error {
        case .success:              return "成功"
        case .attributeUnsupported: return "不支持这个属性（不是 Electron，或版本不认）"
        case .cannotComplete:       return "调用没完成（应用没响应 / 超时）"
        case .notImplemented:       return "应用没实现 AX API"
        case .apiDisabled:          return "辅助功能 API 被禁用"
        case .invalidUIElement:     return "元素无效"
        default:                    return "AXError \(error.rawValue)"
        }
    }
}
