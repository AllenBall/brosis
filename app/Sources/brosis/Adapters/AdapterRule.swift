import BrosisCore
import CoreGraphics
import Foundation

/// 一条适配规则（计划 3.3「每个常用应用一条规则，声明正文区域、读取方式、可见范围处理、
/// 新鲜度判定」）。规则是**纯数据**，所以能单元测试；执行它的是 `AdapterEngine`。

// MARK: - 区域定位

/// 窗口内的相对矩形（0–1，原点左上）。给"AX 读不到、只能按坐标 OCR"的应用用（微信）。
struct RelativeRect: Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// 落到 AX 坐标系的绝对矩形。
    func resolve(in window: CGRect) -> CGRect {
        CGRect(x: window.minX + window.width * x,
               y: window.minY + window.height * y,
               width: window.width * width,
               height: window.height * height)
    }

    var label: String {
        String(format: "%.2f,%.2f,%.2f,%.2f", x, y, width, height)
    }
}

/// 怎么在 AX 树里找到这个区域。
enum ElementLocator: Sendable, Equatable {
    /// 角色等于（第一个命中的节点）。
    case role(String)
    /// 角色 + 子角色都等于。
    case roleAndSubrole(String, String)
    /// `AXIdentifier` 等于。
    case identifier(String)
    /// 从窗口起逐层按角色下钻（每层取第一个命中的子节点）。
    case rolePath([String])
    /// 不找 AX 节点，直接用窗口内的相对矩形（只能 OCR）。
    case relativeRect(RelativeRect)
    /// 整个焦点窗口。
    case wholeWindow

    var label: String {
        switch self {
        case .role(let r): return "role=\(r)"
        case .roleAndSubrole(let r, let s): return "role=\(r) subrole=\(s)"
        case .identifier(let id): return "identifier=\(id)"
        case .rolePath(let path): return "path=" + path.joined(separator: "/")
        case .relativeRect(let rect): return "rect=\(rect.label)"
        case .wholeWindow: return "window"
        }
    }
}

/// 读取方式。
enum ReadMethod: String, Sendable {
    /// 直接读这个节点的 `AXValue` / `AXDescription`（配合 `AXVisibleCharacterRange` 裁视口）。
    case axValue = "ax_value"
    /// 在这个节点的子树里做限额 BFS，收集文本角色（配合 frame 相交裁视口）。
    case axSubtree = "ax_subtree"
    /// 消息列表：`AXList` / `AXRow` 的每一行拼成「发送者 时间 文本」，只取视口内已渲染的行。
    case axRows = "ax_rows"
    /// 不读 AX，直接对这块区域做视口 OCR（规则声明 AX 不可用）。
    case ocr = "ocr"

    var declaresOCR: Bool { self == .ocr }
}

/// 区域类型。只影响 OCR 的分辨率策略（D24：正文类 1x，代码与等宽小字不降采样）与区域名前缀。
enum RegionKind: String, Sendable {
    case body           // 正文
    case messageList    // 聊天消息列表
    case code           // 代码 / 等宽小字：不降采样
    case title          // 会话名 / 标题条
    case url

    /// D24：代码与等宽小字区域不降采样。
    var monospace: Bool { self == .code }
}

/// 一个正文区域的规则。
struct RegionRule: Sendable {
    /// 区域名，进 `occurrences.region` 的前缀之后那一截（`adapter:feishu.message_list`）。
    var name: String
    var kind: RegionKind
    var locator: ElementLocator
    var read: ReadMethod
    /// AX 读到空时是否回退视口 OCR（3.3 的第一类触发条件）。
    var ocrFallback: Bool = false
    /// 是不是"正文必需区域"。`completeness = complete` 只看必需区域全都读到了。
    var required: Bool = true
    /// 只入库视口内实际显示的内容：用元素 frame 与窗口可见区域相交判定，
    /// `AXVisibleCharacterRange` 可用时优先用它。关掉它就是"整棵子树都收"。
    var clipToViewport: Bool = true
    /// 这个区域一次最多留多少字符（防止长会话把库刷爆）。
    var maxChars: Int = AX.maxCharsPerRole

    var label: String {
        "\(name) kind=\(kind.rawValue) \(locator.label) read=\(read.rawValue)"
            + " clip=\(clipToViewport ? "yes" : "no") required=\(required ? "yes" : "no")"
            + (ocrFallback ? " ocr_fallback=yes" : "")
    }
}

// MARK: - 聊天气泡归属（微信 / 飞书）

/// 气泡归属规则（计划 3.3 微信适配器）：单聊左 = 对方、右 = 自己；群聊取气泡上方昵称。
struct ChatLayout: Sendable {
    /// 气泡中心在窗口宽度的这个比例右侧就算"自己发的"。
    var selfSideThreshold: Double = 0.55
    /// 群聊时昵称行落在气泡上方这么多点以内才算这条气泡的昵称。
    var nicknameGap: Double = 40
    /// 单聊时"自己"的显示名。
    var selfLabel: String = "我"
    /// 读不到昵称时对方的显示名。
    var peerLabel: String = "对方"
}

// MARK: - 规则

struct AdapterRule: Sendable {
    /// 规则 id，进运行期事件与结果文件。
    var id: String
    var name: String
    /// 命中的 bundle id。空数组 = 兜底规则（`AdapterRegistry.generic`）。
    var bundleIDs: [String]
    /// 是不是 Chromium / Electron 系：读树前要先设 `AXManualAccessibility`（报告 3.2）。
    var electron: Bool
    var regions: [RegionRule]
    /// 有值就按聊天气泡归属处理 OCR 结果。
    var chatLayout: ChatLayout?
    var limits: AX.BFSLimits
    /// 一次扫描最多探多少次元素 frame。**这是主线程预算的闸**：
    /// 每探一次 frame 要发两条 AX 消息（position + size），Safari 的 web area 里
    /// 光 `AXStaticText` 就可能几百个。超了就不再裁视口、把完整性降成 partial，
    /// 而不是让菜单栏 app 卡住。
    ///
    /// 300 次 = 最多 600 条 AX 消息。配合 `AdapterEngine.shouldProbeFrame`
    /// （只问带正文的节点与滚动 / 列表类容器）与"容器整块在视口外就剪掉整棵子树"，
    /// 真实窗口上远到不了这个数。
    var maxFrameProbes: Int = 300
    /// 已知局限，原样进 README 与结果文件。
    var notes: String

    /// 这条规则声明了哪些区域必须走 OCR。
    var ocrRegions: [RegionRule] { regions.filter { $0.read.declaresOCR } }

    var declaresOCR: Bool { !ocrRegions.isEmpty || regions.contains { $0.ocrFallback } }
}
