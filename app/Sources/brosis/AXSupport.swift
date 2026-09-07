import AppKit
import ApplicationServices
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

    /// 遍历上限，防止 Electron 大树把主线程占满。
    static let maxNodes = 1500
    static let maxDepth = 12

    /// Chromium / Electron 系应用：读 AX 前必须先设 AXManualAccessibility（报告 3.2）。
    /// 这是公开属性，不用私有的 AXEnhancedUserInterface。
    static let chromiumFamilyBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "company.thebrowser.Browser",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.tinyspeck.slackmacgap", "md.obsidian", "com.hnc.Discord",
        "com.electron.lark", "com.larksuite.larkApp", "com.bytedance.macos.feishu"
    ]

    /// 应用元素。这里再设一次是冗余的防守：全局超时正常时它与全局值相同，
    /// 万一 `installGlobalMessagingTimeout()` 没装上，至少这一层还是 0.5 s。
    static func applicationElement(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// 对 Chromium 系应用打开手动无障碍。失败不影响其他通道。
    @discardableResult
    static func enableManualAccessibilityIfNeeded(bundleID: String?, pid: pid_t) -> Bool {
        guard let bundleID, chromiumFamilyBundleIDs.contains(bundleID) else { return false }
        let element = applicationElement(pid: pid)
        let error = AXUIElementSetAttributeValue(
            element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return error == .success
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
    static func windowInfo(pid: pid_t) -> WindowInfo {
        guard let window = focusedWindow(pid: pid) else {
            return WindowInfo(title: nil, url: nil, document: nil, frame: nil, timedOut: true)
        }
        let title = string(window, kAXTitleAttribute as String)
        let document = string(window, kAXDocumentAttribute as String)
        var url = string(window, kAXURLAttribute as String)
        if url == nil {
            // Safari / Chromium 的 URL 挂在 AXWebArea 上，不在窗口上。
            url = firstWebAreaURL(in: window)
        }
        return WindowInfo(title: title, url: url, document: document,
                          frame: frame(window), timedOut: false)
    }

    private static func firstWebAreaURL(in window: AXUIElement) -> String? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (element, depth) = queue.first {
            queue.removeFirst()
            visited += 1
            if visited > 400 || depth > maxDepth { break }
            if role(element) == "AXWebArea", let url = string(element, kAXURLAttribute as String) {
                return url
            }
            for child in children(element) { queue.append((child, depth + 1)) }
        }
        return nil
    }

    // MARK: - 正文文本统计

    /// M0 只统计字符数，不落正文。completeness 先按占位规则：非空 = partial，空 = unavailable
    /// （评审 F5：AX 非空不等于正文完整，真正的 complete 判定要等 E5 的适配规则与 OCR 对照）。
    static let textRoles = ["AXTextArea", "AXTextField", "AXStaticText", "AXWebArea"]

    static func textSummaries(pid: pid_t) -> [AXTextSummary] {
        guard let window = focusedWindow(pid: pid) else { return [] }
        var nodeCounts: [String: Int] = [:]
        var charCounts: [String: Int] = [:]
        for role in textRoles {
            nodeCounts[role] = 0
            charCounts[role] = 0
        }

        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty && visited < maxNodes {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let elementRole = role(element)
            if textRoles.contains(elementRole) {
                nodeCounts[elementRole, default: 0] += 1
                let value = string(element, kAXValueAttribute as String)
                    ?? string(element, kAXDescriptionAttribute as String)
                charCounts[elementRole, default: 0] += (value?.count ?? 0)
            }
            // AXSecureTextField 永不暴露值，直接跳过，不往下走。
            if elementRole == "AXSecureTextField" { continue }
            if depth < maxDepth {
                for child in children(element) { queue.append((child, depth + 1)) }
            }
        }

        return textRoles.map { role in
            let chars = charCounts[role] ?? 0
            return AXTextSummary(role: role,
                                 nodeCount: nodeCounts[role] ?? 0,
                                 charCount: chars,
                                 completeness: chars > 0 ? .partial : .unavailable)
        }
    }
}
