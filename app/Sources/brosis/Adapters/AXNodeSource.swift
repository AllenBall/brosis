import ApplicationServices
import CoreGraphics
import Foundation

/// 采集端读 AX 树的最小抽象（计划 3.3「内容采集，按应用适配规则」）。
///
/// **为什么要有它**：适配规则的判定（正文区域定位、视口相交、可见范围、新鲜度、完整性）
/// 是纯逻辑，但它读的是 `AXUIElement`——那玩意儿只能对着一个真的、正在运行的应用发消息，
/// 没法在单元测试里造。所以把"读一个节点的属性"抽成协议，给两个实现：
///
/// - `LiveAXNode`：包一个 `AXUIElement`，真机上用；
/// - `SyntheticAXNode`：内存里的合成树，测试与自检用（`AdapterVectors` 里有四个应用各一棵）。
///
/// 判定逻辑（`AdapterEngine`）只认这个协议，所以**全部用例都走合成树**，
/// 不启动任何应用、不发 AX 消息、不需要辅助功能权限。
protocol AXNodeSource {
    /// `kAXRole`，读不到时是 `"AXUnknown"`。
    var role: String { get }
    /// `kAXSubrole`。
    var subrole: String? { get }
    /// `kAXIdentifier`（Electron 应用常把 DOM 的 id 挂在这里）。
    var identifier: String? { get }
    var title: String? { get }
    /// `kAXValue`，只在是字符串时有值。
    var value: String? { get }
    /// `kAXDescription`。AX 树里很多可见文字挂在这里而不是 value 上。
    var descriptionText: String? { get }
    /// AX 坐标系里的矩形：**原点在主屏左上、y 向下、跨屏全局**（与 `CGDisplayBounds` 同一套）。
    /// 读不到时是 nil——**nil 一律按"可见"处理**，绝不因为读不到坐标就丢内容。
    var frame: CGRect? { get }
    /// `AXVisibleCharacterRange`：文本控件当前**真正显示在视口里**的字符区间。
    /// 有它的时候优先用它裁（比按 frame 相交精确得多）。
    var visibleCharacterRange: NSRange? { get }
    /// 子节点。真实实现每次调用都发一次 AX 消息，调用方要自己控制次数。
    var children: [any AXNodeSource] { get }
}

extension AXNodeSource {

    /// 这个节点自带的可见文字：`kAXValue` 优先，其次 `kAXDescription`，最后 `kAXTitle`。
    /// 与 `AX.textScan` 的取值顺序一致，换掉实现不改口径。
    ///
    /// 补上 `kAXTitle`（2026-09-09）：Claude 桌面版实测一棵树里 AXValue 3274 字符、
    /// AXDescription 2295 字符、**AXTitle 1644 字符**，最后这份此前直接丢掉。
    /// Chromium 把按钮标签、标题这类可读文字放在 AXTitle 上，它们是正文的一部分。
    var visibleText: String? {
        if let value, !value.isEmpty { return value }
        if let descriptionText, !descriptionText.isEmpty { return descriptionText }
        if let title, !title.isEmpty { return title }
        return nil
    }

    /// 按 `AXVisibleCharacterRange` 裁出视口内那一段。
    ///
    /// 返回 `(text, clipped)`：`clipped = true` 表示**确实裁掉了东西**（视口外有内容），
    /// 调用方据此把 completeness 降成 partial。范围非法（越界、长度 0）时原样返回、不裁。
    func viewportText() -> (text: String, clipped: Bool)? {
        guard let full = visibleText else { return nil }
        guard let range = visibleCharacterRange, range.length > 0 else { return (full, false) }
        let characters = Array(full)
        guard range.location >= 0, range.location < characters.count else { return (full, false) }
        let end = min(characters.count, range.location + range.length)
        guard end > range.location else { return (full, false) }
        let slice = String(characters[range.location..<end])
        return (slice, slice.count < characters.count)
    }
}

// MARK: - 真实 AX

/// `AXUIElement` 的包装。每个属性读一次发一次 AX 消息，全局超时 0.5 s（见 `AX`）。
struct LiveAXNode: AXNodeSource {

    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    var role: String { AX.role(element) }
    var subrole: String? { AX.string(element, kAXSubroleAttribute as String) }
    var identifier: String? { AX.string(element, "AXIdentifier") }
    var title: String? { AX.string(element, kAXTitleAttribute as String) }
    var value: String? { AX.string(element, kAXValueAttribute as String) }
    var descriptionText: String? { AX.string(element, kAXDescriptionAttribute as String) }
    var frame: CGRect? { AX.frame(element) }

    var visibleCharacterRange: NSRange? {
        // **先验类型再转**：属性值是第三方应用给的，AX 里没有任何东西保证它真是 AXValue。
        // 直接 `as!` 的话，一个 AX 实现不规范的应用就能让常驻菜单栏的采集进程崩掉。
        guard let raw = AX.copyAttribute(element, kAXVisibleCharacterRangeAttribute as String),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        // 上一行已经确认过 CFTypeID，这里的强转不会失败。
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range) else { return nil }
        guard range.length > 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    var children: [any AXNodeSource] { AX.children(element).map { LiveAXNode($0) } }
}

// MARK: - 合成树（测试与自检）

/// 内存里的 AX 节点。测试用它造出"视口内 / 视口外 / 回滚区"三种位置的节点，
/// 判定逻辑一行都不用改。
struct SyntheticAXNode: AXNodeSource {

    var role: String
    var subrole: String?
    var identifier: String?
    var title: String?
    var value: String?
    var descriptionText: String?
    var frame: CGRect?
    var visibleCharacterRange: NSRange?
    var kids: [SyntheticAXNode]

    init(role: String,
         subrole: String? = nil,
         identifier: String? = nil,
         title: String? = nil,
         value: String? = nil,
         descriptionText: String? = nil,
         frame: CGRect? = nil,
         visibleCharacterRange: NSRange? = nil,
         kids: [SyntheticAXNode] = []) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.value = value
        self.descriptionText = descriptionText
        self.frame = frame
        self.visibleCharacterRange = visibleCharacterRange
        self.kids = kids
    }

    var children: [any AXNodeSource] { kids.map { $0 as any AXNodeSource } }
}
