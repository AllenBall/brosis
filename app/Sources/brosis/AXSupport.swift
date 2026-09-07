import AppKit
import ApplicationServices
import BrosisCore
import Foundation

/// AX 读取工具。
///
/// **超时口径（务必按 SDK 头文件理解）**：`AXUIElementSetMessagingTimeout` 只对传进去的那个元素生效，
/// 只有传 `AXUIElementCreateSystemWide()` 才是**本进程全局**。`AXUIElement.h` 原文：
/// “Pass the system-wide accessibility object … if you want to set the timeout globally for this
/// process. Setting the timeout on another accessibility object sets it only for that object …”。
/// 所以只给应用元素和焦点窗口设超时是不够的——BFS 里通过 `kAXChildren` 拿到的每个子元素
/// 都会退回系统默认超时（约 6 s），目标应用一旦卡住，菜单栏 app 的主线程会跟着冻结。
/// 正确做法是进程启动时调用一次 `installGlobalMessagingTimeout()`（见 `AppDelegate`），
/// 之后所有 AX 元素（含遍历中新拿到的子元素）统一用 0.5 s（报告 3.1：0.5–1 s）。
enum AX {

    /// 单次 AX 调用的超时，单位秒。
    static let messagingTimeout: Float = 0.5

    /// 把 0.5 s 设成**本进程全局** AX 超时。必须在任何 AX 读取之前调用一次。
    ///
    /// 这个调用不向任何应用发消息、不需要辅助功能权限、不会触发 TCC 弹窗：
    /// 它只是把超时值写进本进程的 AX 客户端状态。返回 `AXError`，`.success` 才算装上了。
    @discardableResult
    static func installGlobalMessagingTimeout(_ timeout: Float = messagingTimeout) -> AXError {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
    }

    /// 默认遍历上限，防止 Electron 大树把主线程占满。按 bundle id 的收紧值见 `bfsLimitsByBundleID`。
    static let maxNodes = 1500
    static let maxDepth = 12
    /// 窗口 URL 搜索（找第一个 AXWebArea）的默认节点上限。
    static let webAreaSearchNodes = 400

    // MARK: - Chromium / Electron 系判定

    /// **第一路：显式 bundle id 清单。**Chromium / Electron 系应用读 AX 前必须先设
    /// `AXManualAccessibility`（报告 3.2）。这是公开属性，不用私有的 AXEnhancedUserInterface。
    ///
    /// 清单只是第一路。M0 实测（`tools/bench/results/m0_closeout_2026-09-07.md` 2.2）：
    /// Claude 桌面版 `com.anthropic.claudefordesktop`（探针里停留时间第一）74 条观察、
    /// AX 正文字符合计 **0**，原因就是它不在这份清单里，没设过 `AXManualAccessibility`。
    /// 人工维护的清单追不上新装的应用，所以另加第二路通用判定（`bundleContainsElectronFramework`）。
    static let chromiumFamilyBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "company.thebrowser.Browser",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.tinyspeck.slackmacgap", "md.obsidian", "com.hnc.Discord",
        "com.electron.lark", "com.larksuite.larkApp", "com.bytedance.macos.feishu",
        "com.anthropic.claudefordesktop"
    ]

    /// **第二路：通用框架检测。**这两个目录名出现在 `<app>.app/Contents/Frameworks/` 下时，
    /// 应用一定是 Chromium 内核（Electron 或 CEF），按 Chromium 系处理。
    /// 注意：改过框架名的应用（例如飞书把它重命名成 `Lark Framework.framework`）匹配不到，
    /// 仍然要靠第一路的显式清单兜底。
    static let electronFrameworkNames = [
        "Electron Framework.framework",             // Electron
        "Chromium Embedded Framework.framework"     // CEF
    ]

    /// 判定依据，原样写进 `runtime_events.detail` 的 `detection=` 字段。
    enum ChromiumDetection: String, Sendable {
        /// 命中显式 bundle id 清单。
        case list = "list"
        /// 命中 Electron / CEF 框架。
        case framework = "framework"
        /// 两路都没命中，按原生应用处理（不设 AXManualAccessibility）。
        case notChromium = "none"
    }

    /// 判定结果按 bundle id 缓存：通用检测要摸文件系统，每次切应用都摸一遍没必要；
    /// 缓存同时用来决定要不要写 `runtime_events`——同一个 bundle id 只在第一次判定时写一条，
    /// 否则一天几百次应用切换会把 runtime_events 刷满。
    private final class DetectionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: ChromiumDetection] = [:]

        /// 命中缓存就直接返回；没有就在**锁外**算一次再存进去。
        /// `firstSeen` = 这次是不是本进程第一次判定这个 bundle id。
        func resolve(_ key: String, compute: () -> ChromiumDetection)
            -> (detection: ChromiumDetection, firstSeen: Bool) {
            lock.lock()
            if let cached = values[key] {
                lock.unlock()
                return (cached, false)
            }
            lock.unlock()
            let computed = compute()          // 文件系统探测不在锁里做
            lock.lock()
            defer { lock.unlock() }
            if let raced = values[key] { return (raced, false) }
            values[key] = computed
            return (computed, true)
        }
    }

    private static let detectionCache = DetectionCache()

    /// 通用检测：`<bundle>/Contents/Frameworks/` 下有没有 Electron / CEF 框架目录。
    ///
    /// **只读文件系统**：不发任何 AX 消息、不需要辅助功能权限、不启动被检测的应用，
    /// 所以 `--self-check` 可以直接调用它做验证。
    static func bundleContainsElectronFramework(at bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        for name in electronFrameworkNames {
            var isDirectory: ObjCBool = false
            let path = frameworks.appendingPathComponent(name, isDirectory: true).path
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return true
            }
        }
        return false
    }

    /// 两路合一的判定：显式清单优先，其次通用框架检测；结果按 bundle id 缓存。
    /// 同样不发 AX 消息，自检可以调用。
    static func chromiumDetection(bundleID: String?, bundleURL: URL?)
        -> (detection: ChromiumDetection, firstSeen: Bool) {
        guard let bundleID, !bundleID.isEmpty else {
            // 没有 bundle id 就没法缓存（不同应用会撞同一个 key），也不写 runtime_events。
            return (bundleContainsElectronFramework(at: bundleURL) ? .framework : .notChromium, false)
        }
        return detectionCache.resolve(bundleID) {
            if chromiumFamilyBundleIDs.contains(bundleID) { return .list }
            return bundleContainsElectronFramework(at: bundleURL) ? .framework : .notChromium
        }
    }

    /// 应用元素。这里再设一次是冗余的防守：全局超时正常时它与全局值相同，
    /// 万一 `installGlobalMessagingTimeout()` 没装上，至少这一层还是 0.5 s。
    static func applicationElement(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// 一次「是不是 Chromium 系 + 有没有设上 AXManualAccessibility」的结果。
    struct ManualAccessibilityResult: Sendable {
        var bundleID: String
        var detection: ChromiumDetection
        /// 是否真的设了 `AXManualAccessibility`（`detection == .notChromium` 时为 false）。
        var applied: Bool
        /// `AXUIElementSetAttributeValue` 的返回值；没设过时为 nil。
        var axError: AXError?
        /// 这个 bundle id 是不是本进程第一次判定。调用方用它决定要不要写 runtime_events。
        var firstSeen: Bool

        var succeeded: Bool { applied && axError == .success }

        /// 写进 `runtime_events.detail`：bundle id + 检测依据 + 设置结果。
        var detail: String {
            var text = "bundle=\(bundleID) detection=\(detection.rawValue)"
            if let axError {
                text += " set=\(axError == .success ? "ok" : "failed") AXError=\(axError.rawValue)"
            } else {
                text += " set=skipped"
            }
            return text
        }
    }

    /// 对 Chromium / Electron 系应用打开手动无障碍。失败不影响其他通道。
    @discardableResult
    static func enableManualAccessibilityIfNeeded(bundleID: String?, bundleURL: URL?, pid: pid_t)
        -> ManualAccessibilityResult {
        let (detection, firstSeen) = chromiumDetection(bundleID: bundleID, bundleURL: bundleURL)
        let key = bundleID ?? "(unknown)"
        guard detection != .notChromium else {
            return ManualAccessibilityResult(bundleID: key, detection: detection,
                                             applied: false, axError: nil, firstSeen: firstSeen)
        }
        let element = applicationElement(pid: pid)
        let error = AXUIElementSetAttributeValue(
            element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return ManualAccessibilityResult(bundleID: key, detection: detection,
                                         applied: true, axError: error, firstSeen: firstSeen)
    }

    // MARK: - BFS 限额

    /// 一次遍历的限额。
    struct BFSLimits: Sendable {
        var maxNodes: Int
        var maxDepth: Int

        var label: String { "nodes=\(maxNodes) depth=\(maxDepth)" }
    }

    static let defaultBFSLimits = BFSLimits(maxNodes: maxNodes, maxDepth: maxDepth)

    /// 按 bundle id 的限额表。**默认不变**（1500 节点 / 12 层），只对已知会把 AX 拖慢的应用收紧。
    ///
    /// 访达：M0 实测 41 条观察里 9 条（**22%**）0.5 s 超时（m0_closeout 2.2），
    /// 大目录的列表节点极多，收到 400 节点 / 6 层。注意超时本身发生在
    /// `kAXFocusedWindow` 那一次调用上，限额只减少同一路径上的遍历开销，效果要授权后重跑才算数。
    static let bfsLimitsByBundleID: [String: BFSLimits] = [
        "com.apple.finder": BFSLimits(maxNodes: 400, maxDepth: 6)
    ]

    static func bfsLimits(bundleID: String?) -> BFSLimits {
        guard let bundleID, let limits = bfsLimitsByBundleID[bundleID] else { return defaultBFSLimits }
        return limits
    }

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let url = value as? URL { return url.absoluteString }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute as String) ?? "AXUnknown"
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, kAXChildrenAttribute as String) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let application = applicationElement(pid: pid)
        guard let value = copyAttribute(application, kAXFocusedWindowAttribute as String) else {
            return nil
        }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, messagingTimeout)   // 同样是冗余防守
        return window
    }

    /// 窗口矩形（AX 坐标：原点左上，y 向下，跨屏全局）。
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = copyAttribute(element, kAXPositionAttribute as String),
              let sizeValue = copyAttribute(element, kAXSizeAttribute as String) else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - 焦点窗口的定位信息

    struct WindowInfo: Sendable {
        var title: String?
        var url: String?
        var document: String?
        var frame: CGRect?
        var timedOut: Bool
    }

    /// 读窗口标题、kAXDocument、kAXURL。任一调用失败都记为超时候选，由调用方决定 source_state。
    /// `bundleID` 只用来查 BFS 限额表（AXWebArea 搜索也吃这份限额）。
    static func windowInfo(pid: pid_t, bundleID: String? = nil) -> WindowInfo {
        let limits = bfsLimits(bundleID: bundleID)
        guard let window = focusedWindow(pid: pid) else {
            return WindowInfo(title: nil, url: nil, document: nil, frame: nil, timedOut: true)
        }
        let title = string(window, kAXTitleAttribute as String)
        let document = string(window, kAXDocumentAttribute as String)
        var url = string(window, kAXURLAttribute as String)
        if url == nil {
            // Safari / Chromium 的 URL 挂在 AXWebArea 上，不在窗口上。
            url = firstWebAreaURL(in: window, limits: limits)
        }
        return WindowInfo(title: title, url: url, document: document,
                          frame: frame(window), timedOut: false)
    }

    private static func firstWebAreaURL(in window: AXUIElement, limits: BFSLimits) -> String? {
        let nodeCap = min(webAreaSearchNodes, limits.maxNodes)
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (element, depth) = queue.first {
            queue.removeFirst()
            visited += 1
            if visited > nodeCap || depth > limits.maxDepth { break }
            if role(element) == "AXWebArea", let url = string(element, kAXURLAttribute as String) {
                return url
            }
            for child in children(element) { queue.append((child, depth + 1)) }
        }
        return nil
    }

    // MARK: - 正文文本统计

    /// **M1 起正文本身也要入库**（`text_versions` / `occurrences`），不再只留统计。
    /// completeness 仍是占位规则：非空 = partial，空 = unavailable
    /// （评审 F5：AX 非空不等于正文完整，真正的 complete 判定要等 E5 的适配规则与 OCR 对照）。
    static let textRoles = ["AXTextArea", "AXTextField", "AXStaticText", "AXWebArea"]

    /// 单个角色一次遍历最多留多少字符。
    ///
    /// 为什么要有这个上限：`AXStaticText` 在长文档 / 长聊天记录里能轻松拼出几百 KB，
    /// 而这些内容**绝大部分不在视口内**（计划 3.3：只入库视口内实际显示的内容）。
    /// 视口裁剪要等 E5 的适配规则，本轮先用一个粗上限兜住内存与库体积，
    /// 命中上限时 `charLimitHit = true`，写进运行期事件，不静默截断。
    static let maxCharsPerRole = 20_000

    /// 一次正文遍历的结果：按角色的统计 + 这次遍历有没有被限额截断。
    ///
    /// 截断信息**不写进 `ax_texts.completeness`**，由调用方写 `runtime_events`，理由见
    /// `EventSkeleton.noteBFSLimitHit`。
    struct TextScan: Sendable {
        var summaries: [AXTextSummary]
        var limits: BFSLimits
        var visitedNodes: Int
        /// 节点数吃满上限，队列里还有没走的元素。
        var hitNodeLimit: Bool
        /// 有元素到达了深度上限——它下面的子树（如果有）没有展开。
        /// 这里故意不去取那个元素的 children 来确认，免得为了记一个标志位多发一轮 AX 消息。
        var reachedDepthLimit: Bool
        /// 至少一个角色的正文吃满了 `maxCharsPerRole`。
        var charLimitHit: Bool = false

        var truncated: Bool { hitNodeLimit || reachedDepthLimit || charLimitHit }

        /// 本次遍历读到的总字符数（脱敏前）。
        var totalChars: Int { summaries.reduce(0) { $0 + $1.charCount } }

        /// 写进 `runtime_events.detail`。
        var detail: String {
            var hits: [String] = []
            if hitNodeLimit { hits.append("node") }
            if reachedDepthLimit { hits.append("depth") }
            if charLimitHit { hits.append("chars") }
            return "limits=\(limits.label) visited=\(visitedNodes) chars=\(totalChars) "
                 + "hit=\(hits.isEmpty ? "none" : hits.joined(separator: "+"))"
        }
    }

    static func textScan(pid: pid_t, bundleID: String? = nil) -> TextScan {
        let limits = bfsLimits(bundleID: bundleID)
        guard let window = focusedWindow(pid: pid) else {
            return TextScan(summaries: [], limits: limits, visitedNodes: 0,
                            hitNodeLimit: false, reachedDepthLimit: false)
        }
        var nodeCounts: [String: Int] = [:]
        var charCounts: [String: Int] = [:]
        var pieces: [String: [String]] = [:]
        for role in textRoles {
            nodeCounts[role] = 0
            charCounts[role] = 0
            pieces[role] = []
        }

        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var reachedDepthLimit = false
        var charLimitHit = false
        while !queue.isEmpty && visited < limits.maxNodes {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let elementRole = role(element)
            if textRoles.contains(elementRole) {
                nodeCounts[elementRole, default: 0] += 1
                let value = string(element, kAXValueAttribute as String)
                    ?? string(element, kAXDescriptionAttribute as String)
                if let value, !value.isEmpty {
                    charCounts[elementRole, default: 0] += value.count
                    if (charCounts[elementRole] ?? 0) <= maxCharsPerRole {
                        pieces[elementRole, default: []].append(value)
                    } else {
                        charLimitHit = true
                    }
                }
            }
            // AXSecureTextField 永不暴露值，直接跳过，不往下走。
            if elementRole == "AXSecureTextField" { continue }
            if depth < limits.maxDepth {
                for child in children(element) { queue.append((child, depth + 1)) }
            } else {
                reachedDepthLimit = true
            }
        }

        let summaries = textRoles.map { role -> AXTextSummary in
            let chars = charCounts[role] ?? 0
            // 同一角色的多个节点按遍历顺序用换行拼起来：AX 树里一段正文常被拆成几十个
            // AXStaticText 节点，逐节点入库会把 text_versions 打成碎片、也让 bigram 检索失去上下文。
            let text = (pieces[role] ?? []).joined(separator: "\n")
            return AXTextSummary(role: role,
                                 nodeCount: nodeCounts[role] ?? 0,
                                 charCount: chars,
                                 completeness: chars > 0 ? .partial : .unavailable,
                                 text: text)
        }
        return TextScan(summaries: summaries,
                        limits: limits,
                        visitedNodes: visited,
                        hitNodeLimit: visited >= limits.maxNodes && !queue.isEmpty,
                        reachedDepthLimit: reachedDepthLimit,
                        charLimitHit: charLimitHit)
    }
}
