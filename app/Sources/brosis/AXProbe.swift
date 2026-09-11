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
///
/// 第二种用法 `--ax-probe <bundle id> --dump-webarea [<AXTitle> | all]`：不做取样，
/// 把目标应用每个窗口里的 AXWebArea 列出来，并把标题匹配的那些整棵子树逐节点打出来
/// （见 `dumpWebAreas`）。**输出含屏幕上的真实文本**，落盘只能进不入库的目录。
enum AXProbe {

    /// 取样时刻（毫秒）。0 = 设完属性立刻读，也就是采集端现在的行为。
    static let sampleDelaysMS = [0, 100, 250, 500, 1000, 2000, 4000]

    static func run(bundleIDs: [String], dumpWebArea: String? = nil) -> Int32 {
        print("brosis \(BuildInfo.version) AX 树"
              + (dumpWebArea == nil ? "就绪时间探针" : "AXWebArea 子树转储")
              + "（只读，不开库、不截图）")
        guard AXIsProcessTrusted() else {
            print("没有辅助功能授权，读不了任何应用的 AX 树。")
            print("在「系统设置 → 隐私与安全性 → 辅助功能」里给 brosis 打开后重跑。")
            return 2
        }

        let targets = bundleIDs.isEmpty ? defaultTargets() : bundleIDs
        guard !targets.isEmpty else {
            print("没有正在运行的目标应用。用法：brosis --ax-probe [bundle id ...]"
                  + " [--dump-webarea <AXTitle>|all]")
            return 1
        }

        if let filter = dumpWebArea {
            for bundleID in targets { dumpWebAreas(bundleID: bundleID, filter: filter) }
            return 0
        }
        for bundleID in targets {
            probe(bundleID: bundleID)
        }
        print("\n读法：t=0 那一列就是采集端现在拿到的东西。它是 0、而后面某一列不是 0，")
        print("就说明「不可用」里有一部分纯粹是读得太早，不是这个应用给不出文本。")
        print("0 字符**且** OCR 请求 0 个，才是「这个应用什么都记不下来」。")
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

    /// 正在运行的目标应用；没在运行就说一声并返回 nil。
    private static func runningApp(bundleID: String) -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else {
            print("\n## \(bundleID)：没在运行，跳过")
            return nil
        }
        return app
    }

    private static func probe(bundleID: String) {
        guard let app = runningApp(bundleID: bundleID) else { return }
        let pid = app.processIdentifier
        let detection = AX.chromiumDetection(bundleID: bundleID, bundleURL: app.bundleURL).detection
        let rule = AdapterRegistry.rule(for: bundleID, bundleURL: app.bundleURL)
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
            // 区域明细只打一次（t=0）：定位到没有、挑中了哪个 web area、每块读到多少字、开头长什么样。
            if delay == 0 { for line in taken.regionLines { print("    " + line) } }
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

    // MARK: - `--dump-webarea`：把 AXWebArea 的整棵子树打出来（飞书 Step 0 探针）

    /// `--ax-probe <bundle id> --dump-webarea [<AXTitle> | all]`：列出目标应用**每个窗口**里的
    /// AXWebArea（标题 / URL / frame / 深度 / 子节点数），再把标题匹配的那些（`all` = 全部）
    /// 整棵子树逐节点打出来：role/subrole、AXDOMIdentifier、AXDOMClassList、AXIdentifier、
    /// AXTitle、AXDescription、AXValue 前 60 字、frame、选中 / 焦点状态。
    ///
    /// 为什么要它（2026-09-11 飞书复查，`tools/bench/results/feishu_capture_review_2026-09-11.md`）：
    /// 飞书主窗口有两个 AXWebArea——`messenger`（会话列表侧栏）与 `messenger-chat`（当前会话）。
    /// 规则按「最富」取，永远拿到侧栏。要改成读当前会话，得先知道 `messenger-chat` 里消息列表
    /// 容器、会话头、输入框各自的 DOM id / class 与 frame，以及侧栏里"选中的会话"长什么样——
    /// `dumpStructure` 只打前三层、看不到这些。
    ///
    /// 只读：不设任何属性、不发任何动作、不改焦点。列的是 `kAXWindowsAttribute` 给的所有窗口，
    /// 所以转发弹窗 / 搜索窗开着时也会一起打出来。
    private static func dumpWebAreas(bundleID: String, filter: String) {
        guard let app = runningApp(bundleID: bundleID) else { return }
        let pid = app.processIdentifier
        let application = AX.applicationElement(pid: pid)
        let focused = AX.focusedWindow(pid: pid)
        let windows = (AX.copyAttribute(application, kAXWindowsAttribute as String)
                       as? [AXUIElement]) ?? []
        print("\n## \(app.localizedName ?? bundleID)（\(bundleID)）pid \(pid)"
              + "：\(windows.count) 个窗口，过滤=\(filter)")
        for (windowIndex, window) in windows.enumerated() {
            let root = LiveAXNode(window)
            let isFocused = focused.map { CFEqual($0, window) } ?? false
            print("\n### 窗口 #\(windowIndex)「\(root.title ?? "(无标题)")」"
                  + (root.subrole.map { " \($0)" } ?? "")
                  + " frame=\(rectLabel(root.frame))"
                  + (isFocused ? " ← 焦点窗口" : ""))
            // 与引擎同一个收集器：探针列出来的就是引擎会挑的那批候选。
            var budget = AdapterEngine.Budget(limits: AX.BFSLimits(maxNodes: 20_000, maxDepth: 60),
                                              maxFrameProbes: 0)
            let areas = AdapterEngine.webAreas(in: root, budget: &budget, maxCount: .max)
            if areas.isEmpty {
                print("- 没有 AXWebArea（遍历 \(budget.visited) 节点）")
                // 小窗口（水印覆盖层、控制条）整棵打出来：要知道水印文字在不在 AX 里，看这里。
                if budget.visited <= 50 { dumpSubtree(root) }
            }
            for (areaIndex, area) in areas.enumerated() {
                print("- AXWebArea #\(areaIndex) 标题「\(area.title ?? "")」深度 \(area.depth)"
                      + " 子节点 \(area.node.children.count) frame=\(rectLabel(area.node.frame))"
                      + " URL=…\(((area.node as? LiveAXNode).flatMap { AX.string($0.element, kAXURLAttribute as String) } ?? "无").suffix(60))")
            }
            for (areaIndex, area) in areas.enumerated()
            where filter == "all" || filter == (area.title ?? "") {
                print("\n#### 子树：窗口 #\(windowIndex) AXWebArea #\(areaIndex)「\(area.title ?? "")」")
                dumpSubtree(area.node)
            }
        }
    }

    private static let dumpNodeCap = 8_000
    private static let dumpLineCap = 3_000

    /// 先序深度优先，缩进表示层级，每个节点一行。
    private static func dumpSubtree(_ root: any AXNodeSource) {
        var stack: [(any AXNodeSource, Int)] = [(root, 0)]
        var visited = 0, printed = 0, maxDepth = 0
        var roleCounts: [String: Int] = [:]
        var selected: [String] = []
        while let (node, depth) = stack.popLast() {
            visited += 1
            maxDepth = max(maxDepth, depth)
            guard visited <= dumpNodeCap else { print("  …节点超过 \(dumpNodeCap)，停"); break }
            let role = node.role
            roleCounts[role, default: 0] += 1
            let isSelected = isSelected(node, role: role)
            let line = describeNode(node, role: role, selected: isSelected)
            if printed < dumpLineCap {
                print(String(repeating: "  ", count: depth) + line)
            } else if printed == dumpLineCap {
                print("  …行数超过 \(dumpLineCap)，后面的不打了（仍在统计）")
            }
            printed += 1
            if isSelected { selected.append("深 \(depth)：" + line) }
            guard depth < 80 else { continue }
            for child in node.children.reversed() { stack.append((child, depth + 1)) }
        }
        let top = roleCounts.sorted { $0.value > $1.value }.prefix(10)
        print("  ── 共 \(visited) 节点，最深 \(maxDepth) 层；角色："
              + top.map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        if !selected.isEmpty {
            print("  ── 选中的节点（AXSelected，或 AXValue=1 的 AXRadioButton）：")
            for line in selected.prefix(10) { print("     " + line) }
        }
    }

    /// 属性读法与引擎同一份（`LiveAXNode`）：探针打出来的就是引擎看到的。
    private static func describeNode(_ node: any AXNodeSource, role: String, selected: Bool) -> String {
        var parts: [String] = [role]
        if let sub = node.subrole { parts[0] += "/\(sub)" }
        if let live = node as? LiveAXNode, let id = AX.string(live.element, "AXDOMIdentifier") {
            parts.append("id=\(id)")
        }
        let classes = node.domClasses
        if !classes.isEmpty { parts.append("class=\(classes.joined(separator: "."))") }
        if let id = node.identifier { parts.append("axid=\(id)") }
        if let t = node.title { parts.append("t=「\(clip(t))」") }
        if let d = node.descriptionText { parts.append("d=「\(clip(d))」") }
        if let v = node.value { parts.append("v=「\(clip(v))」") }
        if let frame = node.frame { parts.append(rectLabel(frame)) }
        if selected { parts.append("[选中]") }
        if let live = node as? LiveAXNode,
           (AX.copyAttribute(live.element, kAXFocusedAttribute as String) as? Bool) == true {
            parts.append("[焦点]")
        }
        return parts.joined(separator: " ")
    }

    private static func isSelected(_ node: any AXNodeSource, role: String) -> Bool {
        guard let live = node as? LiveAXNode else { return false }
        if (AX.copyAttribute(live.element, kAXSelectedAttribute as String) as? Bool) == true { return true }
        if role == "AXRadioButton",
           let number = AX.copyAttribute(live.element, kAXValueAttribute as String) as? NSNumber,
           number.intValue == 1 { return true }
        return false
    }

    private static func clip(_ text: String, max: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    private static func rectLabel(_ rect: CGRect?) -> String {
        guard let rect else { return "?" }
        return "[\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))]"
    }

    private struct Sample {
        var chars = 0
        var nodes = 0
        var completeness: Completeness = .unavailable
        var elapsedMS = 0.0
        var noWindow = false
        /// 这一次扫描排了几个 OCR 区域。**0 字符 + 0 个 OCR 请求 = 这个应用什么都不会被记下来**，
        /// 光看字符数分不出"读不到但会 OCR 补"和"读不到而且不会补"。
        var ocrRequests = 0
        /// 每个区域一行：名字、定位、挑中的 web area、字符数、开头 60 字（只在终端上看，不落库）。
        var regionLines: [String] = []

        func describe() -> String {
            if noWindow { return "拿不到焦点窗口" }
            return "\(chars) 字符 / \(nodes) 节点 / \(completeness.rawValue)"
                 + "，OCR 请求 \(ocrRequests) 个"
                 + "（\(String(format: "%.0f", elapsedMS)) ms）"
        }
    }

    /// 走**生产同一条路**：有适配规则就用规则扫，没有就退回窗口整棵树的字符统计。
    private static func sample(pid: pid_t, bundleID: String, rule: AdapterRule) -> Sample {
        let started = Date()
        let read = AX.focusedWindowInfo(pid: pid, bundleID: bundleID)
        guard let window = read.element else { return Sample(noWindow: true) }
        // 与采集端逐字一致：兜底规则由 `AdapterRegistry.rule(for:bundleURL:)` 自己按
        // Chromium 判定选（generic / generic_chromium），量的就是生产会拿到的那个数。
        let scan = AdapterEngine.scan(rule: rule, window: LiveAXNode(window),
                                      windowFrame: read.info.frame)
        var out = Sample()
        out.chars = scan.totalChars
        out.nodes = scan.visitedNodes
        out.completeness = scan.completeness
        out.ocrRequests = scan.ocrRequests.count
        out.elapsedMS = Date().timeIntervalSince(started) * 1000
        out.regionLines = scan.regions.map { region in
            "区域 \(region.name)：定位=\(region.located ? "是" : "否")"
                + (region.pickedWebAreaTitle.map { " webarea=「\($0)」锚=\(region.anchored ? "是" : "否")" } ?? "")
                + " \(region.text.count) 字 可见\(region.visibleNodes)/视口外\(region.offscreenNodes)"
                + (region.text.isEmpty ? "" : "「\(clip(region.text))」")
        }
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
