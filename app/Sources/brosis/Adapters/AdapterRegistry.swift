import Foundation

/// 首批适配规则（计划 3.3；名单来自 `tools/bench/results/m0_closeout_2026-09-07.md` §2.2 的实测）。
///
/// M0 实测结论决定了每条规则长什么样：
///
/// | 应用 | AX 正文 | 结论 |
/// |---|---|---|
/// | Safari | 81.9% 观察有正文、109,035 字符、URL 也拿得到 | 走 AX，规则只负责把区域收窄到 AXWebArea + 裁视口 |
/// | Claude 桌面版（Electron） | **0 字符 / 74 条观察** | 先设 `AXManualAccessibility` 再读 AXWebArea；读不到就视口 OCR |
/// | 飞书（Electron） | 12/17 条"有正文"，但合计只有 **156 字符** | 消息列表按 AXList/AXRow 读；读不到就对消息面板 OCR |
/// | 微信 | 0 字符、6 条里 2 条超时 | AX 直接放弃，聊天面板 + 顶部会话名都走视口 OCR |
///
/// 兜底规则 `generic` 就是 M0 那套全窗口 BFS（四个文本角色、1500 节点 / 12 层），
/// 差别只有一处：**加了视口裁剪**（计划 3.3「只入库视口内实际显示的内容」）。
enum AdapterRegistry {

    // MARK: - Safari

    /// Safari：AX 可用，规则的作用是把范围从"整个窗口"收窄到"网页正文"，并裁掉视口外的节点。
    ///
    /// **URL 不在规则里**：它由事件骨架单独读（`AX.windowInfo` 找第一个 AXWebArea 的 `kAXURL`），
    /// 直接进 `observations.url`。R2 复核时删掉了这里原有的 `url` 区域——它写的是
    /// `read = .axValue`，读的是 `kAXValue` 而不是 `kAXURL`（真机上读不到东西），
    /// 却要为了同一个 AXWebArea 从窗口根再做一次 BFS，白吃共享的节点预算。
    static let safari = AdapterRule(
        id: "safari",
        name: "Safari",
        bundleIDs: ["com.apple.Safari", "com.apple.SafariTechnologyPreview"],
        electron: false,
        regions: [
            RegionRule(name: "web_area", kind: .body, locator: .role("AXWebArea"),
                       read: .axSubtree, ocrFallback: false, required: true, clipToViewport: true),
        ],
        chatLayout: nil,
        limits: AX.defaultBFSLimits,
        notes: "AX 可用（M0：81.9% 的观察有正文）。AXWebArea 找不到时（PDF 预览、"
             + "部分 Web 扩展页面）退回整窗口 BFS；跨 iframe 的正文顺序按 AX 树顺序，不是视觉顺序。")

    // MARK: - Claude 桌面版（Electron）

    /// Claude 桌面版：M0 实测 AX 正文 **0 字符**，原因是它当时不在 `chromiumFamilyBundleIDs` 里、
    /// 没设过 `AXManualAccessibility`（现在已经加进去了）。设上之后大概率能读到 AXWebArea，
    /// 所以规则是"先 AX，读不到再 OCR"：`ocrFallback = true`。
    static let claudeDesktop = AdapterRule(
        id: "claude_desktop",
        name: "Claude 桌面版",
        bundleIDs: ["com.anthropic.claudefordesktop"],
        electron: true,
        regions: [
            RegionRule(name: "conversation", kind: .body, locator: .role("AXWebArea"),
                       read: .axSubtree, ocrFallback: true, required: true, clipToViewport: true),
        ],
        chatLayout: nil,
        limits: AX.BFSLimits(maxNodes: 1_200, maxDepth: 14),
        notes: "Electron，必须先设 AXManualAccessibility。M0 实测未设时 AX 正文为 0；"
             + "设上之后若仍读不到 AXWebArea 就整窗口视口 OCR。代码块用的是等宽小字，"
             + "OCR 回退时按 D24 不降采样；折叠起来的长回复只记展开部分。")

    // MARK: - 飞书（Electron）

    /// 飞书：AX 树几乎为空（M0 合计 156 字符）。规则先试消息列表的 AXList/AXRow，
    /// 读不到就对消息面板区域做视口 OCR。**不追溯未打开的会话与未滚动到的历史**（计划 3.3）。
    static let feishu = AdapterRule(
        id: "feishu",
        name: "飞书 / Lark",
        bundleIDs: ["com.electron.lark", "com.larksuite.larkApp", "com.bytedance.macos.feishu"],
        electron: true,
        regions: [
            RegionRule(name: "message_list", kind: .messageList, locator: .role("AXList"),
                       read: .axRows, ocrFallback: true, required: true, clipToViewport: true),
            RegionRule(name: "conversation_title", kind: .title,
                       locator: .relativeRect(RelativeRect(x: 0.22, y: 0.0,
                                                           width: 0.78, height: 0.08)),
                       read: .ocr, ocrFallback: false, required: false, clipToViewport: true,
                       maxChars: 256),
        ],
        chatLayout: ChatLayout(),
        notes: "Electron（框架被改名成 Lark Framework，通用检测抓不到，靠显式清单）。"
             + "M0 实测 AX 正文合计 156 字符 → 主路径基本是 OCR 回退。"
             + "只记视口内已渲染的消息；不追溯未打开会话与未滚动到的历史；"
             + "图片、文件、语音、通话只有屏幕上显示的文字才可能被 OCR；"
             + "发送者与时间取自行内子元素，行结构变了就退化成整行文本。",
        limits: AX.BFSLimits(maxNodes: 1_200, maxDepth: 14))

    // MARK: - 微信（原生但 AX 空）

    /// 微信左侧「竖排功能栏 + 会话列表」的总宽（点）。默认 340 ≈ 功能栏 60 + 会话列表 280。
    ///
    /// **这是定点值不是比例**：会话列表宽度不随窗口放大而变，用比例切一定会偏（见 `WindowInset`
    /// 的头注释与 M2 实测）。用户拖过会话列表分隔线就得校准，不用重新编译：
    /// `defaults write com.brosis.app adapter.wechat.sidebarWidth -float 380`
    static let wechatSidebarKey = "adapter.wechat.sidebarWidth"
    static let wechatSidebarDefault: Double = 340
    /// 会话标题条高（点）。
    static let wechatTitleBarKey = "adapter.wechat.titleBarHeight"
    static let wechatTitleBarDefault: Double = 60
    /// 底部输入框（含工具条）高（点）。
    static let wechatComposerKey = "adapter.wechat.composerHeight"
    static let wechatComposerDefault: Double = 180

    /// 读一个"点数"参数。非法值（≤ 0 / NaN / 大得不像话）一律退回默认值——
    /// 这些数会直接变成截图裁剪的边界，宁可用默认的也不能让它变成负宽度。
    static func resolvePoints(_ key: String, default fallback: Double, maximum: Double,
                              _ defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let raw = defaults.double(forKey: key)
        guard raw.isFinite, raw > 0, raw <= maximum else { return fallback }
        return raw
    }

    /// 微信：原生应用，AX 为空且超时多（M0：6 条观察 0 字符、2 条超时）。
    /// 规则直接走视口 OCR：聊天面板一块、顶部会话名一块（主窗口标题恒为"微信"，
    /// 会话名与群聊判定都只能从这里拿，计划 3.3）。
    ///
    /// 区域按**点数**从窗口边缘内缩（M2 修正，原来用的是比例，见 `WindowInset`）：
    /// 左边让开侧栏、上边让开标题条、下边让开输入框，剩下的就是聊天面板；
    /// 会话名是顶部那一条，同样让开侧栏。
    static let wechat = AdapterRule(
        id: "wechat",
        name: "微信",
        bundleIDs: ["com.tencent.xinWeChat", "com.tencent.WeChat"],
        electron: false,
        regions: [
            RegionRule(name: "chat_panel", kind: .messageList,
                       locator: .insetRect(WindowInset(
                           left: resolvePoints(wechatSidebarKey,
                                               default: wechatSidebarDefault, maximum: 900),
                           top: resolvePoints(wechatTitleBarKey,
                                              default: wechatTitleBarDefault, maximum: 200),
                           bottom: resolvePoints(wechatComposerKey,
                                                 default: wechatComposerDefault, maximum: 500),
                           minWidth: 240, minHeight: 120,
                           fallback: RelativeRect(x: 0.22, y: 0.08,
                                                  width: 0.78, height: 0.70))),
                       read: .ocr, ocrFallback: false, required: true, clipToViewport: true,
                       pane: .chatPanel),
            RegionRule(name: "conversation_title", kind: .title,
                       locator: .insetRect(WindowInset(
                           left: resolvePoints(wechatSidebarKey,
                                               default: wechatSidebarDefault, maximum: 900),
                           maxHeight: resolvePoints(wechatTitleBarKey,
                                                    default: wechatTitleBarDefault, maximum: 200),
                           minWidth: 240, minHeight: 24,
                           fallback: RelativeRect(x: 0.22, y: 0.0,
                                                  width: 0.78, height: 0.08))),
                       read: .ocr, ocrFallback: false, required: false, clipToViewport: true,
                       maxChars: 256, pane: .conversationTitle),
        ],
        chatLayout: ChatLayout(),
        limits: AX.BFSLimits(maxNodes: 300, maxDepth: 6),
        notes: "原生应用但 AX 正文为空（M0：0 字符、6 条里 2 条超时），所以 AX 一路都不走。"
             + "截图走窗口定向（capturesWindow）：只截微信自己的焦点窗口，别的应用不进图；"
             + "代价是 desktopIndependentWindow 会连**被别的窗口盖住的部分**一起采，"
             + "放宽了 3.3「只入库视口内实际显示的内容」——2026-09-08 用户明确选的。"
             + "分栏边界每帧从窗口图像现场量（PaneDetector）；量不到才退回点数兜底"
             + "（侧栏 340 / 标题条 60 / 输入框 180，均可用 defaults 校准）。"
             + "M2 之前是写死的比例，在 1085 pt 宽的窗口上把半个会话列表当成了聊天面板。"
             + "气泡归属按坐标：单聊左 = 对方、右 = 自己；群聊取气泡上方昵称，"
             + "是不是群聊由会话名的人数后缀「（29）」判定（AX 与窗口标题都给不出这个信号）。"
             + "语音只记 [语音]；图片、表情、视频、小程序只记画面上显示的文字。"
             + "用户拖过会话列表分隔线、或开了免打扰浮层，仍需重新校准侧栏宽度；"
             + "支付 / 转账 / 红包界面与聊天一起记录，不特殊处理（D14 已定）。",
        paneFallback: PaneFallback(
            sidebar: resolvePoints(wechatSidebarKey, default: wechatSidebarDefault, maximum: 900),
            titleBar: resolvePoints(wechatTitleBarKey, default: wechatTitleBarDefault, maximum: 200),
            composer: resolvePoints(wechatComposerKey,
                                    default: wechatComposerDefault, maximum: 500)),
        capturesWindow: true)

    // MARK: - 兜底

    /// 没有专门规则的应用：M0 那套全窗口 BFS，加上视口裁剪。
    static let generic = AdapterRule(
        id: "generic",
        name: "通用（全窗口 BFS）",
        bundleIDs: [],
        electron: false,
        regions: [
            RegionRule(name: "window", kind: .body, locator: .wholeWindow,
                       read: .axSubtree, ocrFallback: false, required: true, clipToViewport: true),
        ],
        chatLayout: nil,
        limits: AX.defaultBFSLimits,
        notes: "M0 的四个文本角色（AXTextArea / AXTextField / AXStaticText / AXWebArea）全窗口 BFS，"
             + "限额 1500 节点 / 12 层；不触发 OCR。与 M0 的唯一差别是加了视口裁剪。")

    /// 首批规则（有序，进 README 与结果文件的规则表）。
    static let all: [AdapterRule] = [safari, claudeDesktop, feishu, wechat]

    /// bundle id → 规则；查不到就是兜底规则。
    static func rule(for bundleID: String?) -> AdapterRule {
        guard let bundleID, !bundleID.isEmpty else { return generic }
        let lowered = bundleID.lowercased()
        for rule in all where rule.bundleIDs.contains(where: { $0.lowercased() == lowered }) {
            return rule
        }
        // 访达等已经有 BFS 收紧值的应用：兜底规则 + 它自己的限额（`AX.bfsLimits`）。
        var fallback = generic
        fallback.limits = AX.bfsLimits(bundleID: bundleID)
        return fallback
    }
}

extension AdapterRule {
    /// 便利初始化：让上面的规则定义可以按"先写 notes 再写 limits"的顺序写。
    init(id: String, name: String, bundleIDs: [String], electron: Bool,
         regions: [RegionRule], chatLayout: ChatLayout?, notes: String, limits: AX.BFSLimits) {
        self.init(id: id, name: name, bundleIDs: bundleIDs, electron: electron,
                  regions: regions, chatLayout: chatLayout, limits: limits, notes: notes)
    }
}
