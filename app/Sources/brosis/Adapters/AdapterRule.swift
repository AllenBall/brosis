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

/// 窗口内按**点数**从边缘内缩得到的矩形。
///
/// 为什么不都用 `RelativeRect`：三栏布局的应用（微信、飞书）左侧功能栏与会话列表是
/// **固定点宽**，不随窗口放大按比例伸缩；顶部标题条与底部输入框同理。用比例切分在一种
/// 窗口尺寸上调准了，换一台屏就整体偏。
///
/// M2 实测（库里 evidence 4260）：微信窗口宽约 1085 pt 时，`x = 0.22` 落在 239 pt 处，
/// 而实际侧栏约 340 pt——于是半个会话列表被当成聊天面板 OCR 了，记录里全是**别的会话**
/// 的摘要行（"用户交流群 |官方 外部 17:55"），而且左右分栏的基准跟着偏，把对方的消息
/// 判成了自己发的。
///
/// 内缩后尺寸不够（窄窗口、分屏）就退回 `fallback` 的比例切分：定点值只是对"常见布局"
/// 的描述，描述不适用时宁可用旧的粗略切法，也不要交出一个空的或倒过来的矩形。
struct WindowInset: Sendable, Equatable {
    var left: Double = 0
    var top: Double = 0
    var right: Double = 0
    var bottom: Double = 0
    /// 内缩之后再把高度截到这么多点（从内缩后的顶边往下量）。nil = 不截。
    /// 用来表达"顶部那一条"：`top = 0, bottom = 0, maxHeight = 60`。
    var maxHeight: Double?
    /// 内缩后至少要剩下的宽 / 高，不够就用 `fallback`。
    var minWidth: Double = 240
    var minHeight: Double = 48
    /// 定点值不适用时的兜底比例矩形。
    var fallback: RelativeRect

    /// 落到 AX 坐标系的绝对矩形。
    func resolve(in window: CGRect) -> CGRect {
        let width = window.width - left - right
        var height = window.height - top - bottom
        if let maxHeight { height = min(height, maxHeight) }
        guard width >= minWidth, height >= minHeight else { return fallback.resolve(in: window) }
        return CGRect(x: window.minX + left, y: window.minY + top, width: width, height: height)
    }

    var label: String {
        String(format: "inset l=%.0f t=%.0f r=%.0f b=%.0f", left, top, right, bottom)
            + (maxHeight.map { String(format: " h<=%.0f", $0) } ?? "")
            + " fallback=\(fallback.label)"
    }
}

/// 在窗口的所有 `AXWebArea` 里挑一个（一个窗口多个 web area 的 Electron 应用，飞书就是）。
///
/// 为什么不能用「最富的那个」（2026-09-11 复查，`tools/bench/results/feishu_capture_review_2026-09-11.md` F1）：
/// 飞书主窗口有两个 web area——`messenger`（会话列表侧栏，384 pt 宽、每个会话的名字 + 最后一条预览）
/// 与 `messenger-chat`（当前会话）。侧栏永远更"富"，于是当前会话一条都没进库，
/// 记下的全是别的会话的预览。web area 的 AXTitle 就是模块名，按名字挑才对。
struct WebAreaPick: Sendable, Equatable {
    /// 首选的那个 web area，以及选中它之后区域根往下锚到哪儿。只有首选那个才谈得上锚点：
    /// 别的模块（云文档 / 邮箱）的 web area 结构未知，整棵读。
    struct Preferred: Sendable, Equatable {
        /// AXTitle 等于它（飞书：`messenger-chat`）。
        var title: String
        /// 在它里面找 DOM class 含这个名字的节点当**区域根**（飞书：`chatMessages`，自动把会话头与
        /// 输入区排在外面）。找不到就退回 web area 本身。
        var anchorClass: String?
    }
    var prefer: Preferred?
    /// AXTitle 在这里面的不作候选（飞书：`messenger` = 侧栏）。剩下多个时取最富的那个——
    /// 切到云文档 / 邮箱时树里只剩那个模块自己的 web area（Step 0 实测），自然落到它。
    var exclude: [String] = []
}

/// 行级发送者前缀，由行节点的 DOM class 决定（飞书单聊）。
///
/// 飞书单聊的消息行里**没有发送者名**，只有行的 class `message-self` / `message-not-self`
/// （Step 0 探针 §2）；群聊每行自带 `.message-info-name`，不需要前缀——所以只在祖先里
/// 出现 `onlyWhenAncestorClass`（`p2pChat`）时启用。
struct RowLabels: Sendable, Equatable {
    var selfClass: String
    var peerClass: String
    /// 去锚点的路上见到这个 class 才**加前缀**（飞书：`p2pChat` = 单聊）；nil = 总是加。
    /// 行本身（谁是一行）不受它影响：群聊里也要认出行，行的 frame 决定它渲没渲染。
    var onlyWhenAncestorClass: String?
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
    /// 不找 AX 节点，直接用从窗口边缘按点数内缩的矩形（只能 OCR）。固定宽度的侧栏 /
    /// 标题条 / 输入框用这个，别用比例（见 `WindowInset`）。
    case insetRect(WindowInset)
    /// 整个焦点窗口。
    case wholeWindow
    /// `AXDOMClassList` 含这个名字（Chromium 应用里唯一稳定的语义锚点）。
    case domClass(String)
    /// 在窗口的所有 AXWebArea 里按标题挑一个（见 `WebAreaPick`）。一条规则里最多一个区域用它。
    case webArea(WebAreaPick)
    /// 在同一条规则里 `.webArea` 挑中的那个 web area 内，找 DOM class 含这个名字的节点。
    /// 挑中的**不是** `prefer` 那个时（云文档 / 邮箱），退而把 web area 自己的 AXTitle 当文本
    /// ——那正是页标题（「主页 - 飞书云文档」「mail」）。
    case webAreaDescendant(domClass: String)

    /// `.webArea` 的参数；不是它就是 nil。
    var webAreaPick: WebAreaPick? {
        if case .webArea(let pick) = self { return pick }
        return nil
    }

    var label: String {
        switch self {
        case .domClass(let c): return "class=.\(c)"
        case .webArea(let pick):
            return "webarea prefer=\(pick.prefer?.title ?? "-") exclude=\(pick.exclude.joined(separator: ","))"
                + (pick.prefer?.anchorClass.map { " anchor=.\($0)" } ?? "")
        case .webAreaDescendant(let domClass): return "webarea-descendant=.\(domClass)"
        case .role(let r): return "role=\(r)"
        case .roleAndSubrole(let r, let s): return "role=\(r) subrole=\(s)"
        case .identifier(let id): return "identifier=\(id)"
        case .rolePath(let path): return "path=" + path.joined(separator: "/")
        case .relativeRect(let rect): return "rect=\(rect.label)"
        case .insetRect(let inset): return "rect=\(inset.label)"
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
    /// 这块区域在三栏布局里的角色。**声明了角色的区域，OCR 时矩形由 `PaneDetector`
    /// 从窗口图像现场量**，`locator` 给的那个只当量不到时的兜底（见 `PaneLayout`）。
    var pane: PaneRole?
    /// 这些角色的节点连同子树一律不读（飞书：输入框 AXTextArea——未发送的草稿会逐键进库）。
    var excludeRoles: Set<String> = []
    /// 要不要给容器节点（AXGroup 等）探 frame。默认探：容器整块在视口外时能把子树一次剪掉。
    /// 关掉的理由（飞书）：一棵 465 节点的聊天树里 356 个是 AXGroup，全探会撞上 `maxFrameProbes`
    /// 然后停止裁视口；而它的视口外行是 1 pt 占位、并不在视口外，容器探测剪不掉任何东西。
    var probeContainerFrames: Bool = true
    /// 按文档顺序（先序深度优先）读，而不是默认的广度优先。聊天列表必须用它——一行消息的发送者名
    /// 在第 8 层、正文在第 12 层，广度优先会先吐出所有人的名字再吐出所有正文，对话就串了。
    /// 默认仍是广度优先：命中节点上限时得到的是"每层都有一点"的均匀样本。
    var documentOrder: Bool = false
    /// 见 `RowLabels`。只在 `documentOrder` 下生效（行的范围要靠先序遍历界定）。
    var rowLabels: RowLabels?
    /// 「帧变了、AX 文本没变」要不要排 OCR（3.3 第二类触发条件）。DOM 逐字给出的区域应关掉：
    /// 文本没变而画面变了，变的只能是图片 / 动画 / 光标，OCR 只会引入噪声——2026-09-11 复查里
    /// 飞书侧栏的 OCR 回退把压在上面的 Claude 窗口的字记成了飞书正文，走的正是这条触发。
    var ocrOnFrameChange: Bool = true
    /// DOM class 含这些名字的节点连同子树不读（飞书：`message-reactions`——点表情的人名会以独立行混进对话）。
    var pruneClasses: Set<String> = []
    /// 读 class（认行、剪子树）只到区域根下这么多层——每读一次 class 是一次 AX 调用。
    var classProbeMaxDepth: Int = 12
    /// 进了一行之后，剪子树的 class 只在行下这么多层内看（飞书：`.message-reactions` 在行下第 4 层）。
    var pruneDepthBelowRow: Int = 6

    /// 这个区域要不要一个矩形：裁视口、OCR 回退、声明 OCR 三者任一。都不要就不必探它的 frame。
    var needsRect: Bool { clipToViewport || ocrFallback || read.declaresOCR }

    var label: String {
        "\(name) kind=\(kind.rawValue) \(locator.label) read=\(read.rawValue)"
            + " clip=\(clipToViewport ? "yes" : "no") required=\(required ? "yes" : "no")"
            + (ocrFallback ? " ocr_fallback=yes" : "")
            + (pane.map { " pane=\($0.rawValue)" } ?? "")
            + (excludeRoles.isEmpty ? "" : " exclude=\(excludeRoles.sorted().joined(separator: ","))")
            + (documentOrder ? " order=document" : "")
            + (rowLabels == nil ? "" : " row_labels=yes")
            + (ocrOnFrameChange ? "" : " ocr_on_frame_change=no")
            + (pruneClasses.isEmpty ? "" : " prune=.\(pruneClasses.sorted().joined(separator: ",."))")
    }

    /// 定位器命中多个节点时，挑**内容最多**的那个，而不是第一个。
    ///
    /// 为什么需要（2026-09-09 实测 Claude 桌面版）：一个 Electron 窗口里有好几个
    /// `AXWebArea`——第一个是外壳 `file://…/index.html`（子树 2 个节点、0 字符），
    /// 真正的会话在第二个 `https://claude.ai/…`（687 个节点、115 个 AXStaticText、
    /// 2832 字符）。规则取第一个匹配，于是永远落在空壳上、读出 0 字符 →
    /// 记成 unavailable → 掉进 OCR 回退。这就是「不可用」占 85% 的主因。
    var preferRichestMatch = false
}

/// 三栏布局量不到边界时的兜底值（点，从窗口边缘算）。
///
/// 这一组就是 M2 之前写死在规则里的那三个数。现在它们**只在检测失败时**生效，
/// 所以偏一点也不再意味着整块区域切错。
struct PaneFallback: Sendable, Equatable {
    var sidebar: Double
    var titleBar: Double
    var composer: Double

    func layout(windowHeight: Double) -> PaneLayout {
        PaneLayout(sidebarRight: sidebar, titleBottom: titleBar,
                   composerTop: windowHeight - composer, source: .defaults)
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
    /// 声明了 `pane` 角色的区域，边界量不到时用这一组兜底。
    var paneFallback: PaneFallback?
    /// **窗口定向截图**：截这个应用时不截整块显示器，只截它的焦点窗口
    /// （`SCContentFilter(desktopIndependentWindow:)`）。见 `CaptureController.capture`。
    var capturesWindow: Bool = false

    /// 窗口标题以这些前缀开头时**只记标题、不读正文也不 OCR**（completeness = excluded）。
    ///
    /// 飞书的弹窗（搜索 ⌘K、转发、用户名片）是独立的 AXDialog 窗口，标题
    /// `ModalWebViewWidget - <模块>:<弹窗>:default`，frame 与主窗口一样大（2026-09-11 Step 0 §5.4）。
    /// 它们的 AX 树里只有弹窗自己那个 web area（搜索历史、联系人列表），读到空就整窗 OCR，
    /// 于是把压在下面的主窗口、侧栏、水印全记成了正文（evidence 19456）。这类窗口是过渡界面，
    /// 用户真正在看的内容已经在主窗口那条观察里了。
    var titleOnlyWindowPrefixes: [String] = []
    /// OCR 结果先过水印过滤（`WatermarkFilter`）：飞书在窗口上平铺「用户名 组织名」水印，
    /// AX 正文不含它（水印是独立覆盖窗口），但每一次 OCR 都会认出一片。
    var watermarkFilter: Bool = false

    /// 这个窗口按规则只记标题（见 `titleOnlyWindowPrefixes`）。
    func skipsBody(windowTitle: String?) -> Bool {
        guard let windowTitle else { return false }
        return titleOnlyWindowPrefixes.contains { windowTitle.hasPrefix($0) }
    }

    /// `AXEnhancedUserInterface` 开着时改用这组区域。nil = 开关不影响这条规则。
    ///
    /// 存在的理由：好几条规则的形状都是"这个应用的 AX 是空的，所以走 OCR"，而那个前提
    /// **由开关决定**——私有属性一设，Chromium 系应用（Chrome、飞书、飞书会议）就真的
    /// 把树建起来了。与其给每条规则各写一个 `xxxRule(enhanced:)` 闭包，不如让规则自己
    /// 声明"开着时我长这样"，由 `AdapterRegistry` 统一套用。
    var enhancedRegions: [RegionRule]?

    /// 按开关状态定形。开关关着、或这条规则没声明 `enhancedRegions` 时原样返回。
    func resolvingEnhanced(_ enhanced: Bool) -> AdapterRule {
        guard enhanced, let enhancedRegions else { return self }
        var copy = self
        copy.regions = enhancedRegions
        return copy
    }

    /// 这条规则**读不读 AX**。全部区域都声明 `.ocr` 时为 false。
    ///
    /// 用途只有一个：Chromium 系「读到空树 ⇒ 排一次重扫」那条路（`EventSkeleton.noteAXOutcome`）
    /// 只该对**真的试过读 AX**的规则生效。Chrome 的规则一个 AX 区域都没有，AX 字符数恒为 0，
    /// 而它又确实被判为 Chromium 系——不加这道门的话，每个 Chrome 进程头两次扫描都会被当成
    /// 「读早了」，连带把这一帧的 OCR 请求一起丢掉（那正是重扫的设计意图：撤掉回退）。
    var readsAX: Bool { regions.contains { !$0.read.declaresOCR } }

    /// 这条规则声明了哪些区域必须走 OCR。
    var ocrRegions: [RegionRule] { regions.filter { $0.read.declaresOCR } }

    var declaresOCR: Bool { !ocrRegions.isEmpty || regions.contains { $0.ocrFallback } }
}
