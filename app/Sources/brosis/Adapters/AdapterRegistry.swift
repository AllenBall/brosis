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
                       read: .axSubtree, ocrFallback: true, required: true, clipToViewport: true,
                       // 窗口里有三个 AXWebArea：外壳 file://（2 节点 0 字）、会话
                       // https://claude.ai/…（687 节点 2832 字）、内嵌预览 localhost（106 节点）。
                       // 取第一个就永远是空壳，必须挑内容最多的那个。
                       preferRichestMatch: true),
        ],
        chatLayout: nil,
        // 实测会话那棵子树 687 个节点，加上定位与挑选的开销，1200 太紧（会在读到一半时
        // 耗光预算、把 completeness 压成 partial）。2026-09-09 放到 3000。
        limits: AX.BFSLimits(maxNodes: 3_000, maxDepth: 30),
        notes: "Electron，必须先设 AXManualAccessibility。M0 实测未设时 AX 正文为 0；"
             + "设上之后若仍读不到 AXWebArea 就整窗口视口 OCR。代码块用的是等宽小字，"
             + "OCR 回退时按 D24 不降采样；折叠起来的长回复只记展开部分。")

    // MARK: - Chrome 系浏览器（AX 只给外壳）

    /// Chrome 顶部外壳（标签条 + 地址栏）的高度（点）。默认 80 ≈ 标签条 40 + 工具栏 40。
    ///
    /// **宁可切小不切大**：切大了会把页面顶部真内容裁掉，切小了只是多认一条地址栏——
    /// 而地址栏的 URL 本来就另外单独取了，重复一次无害。开了书签栏的加约 32：
    /// `defaults write com.brosis.app adapter.chrome.toolbarHeight -float 112`
    static let chromeToolbarKey = "adapter.chrome.toolbarHeight"
    static let chromeToolbarDefault: Double = 80

    /// Chrome / Edge / Brave / Vivaldi / Arc：**AX 只给浏览器外壳，一个字正文都没有**。
    ///
    /// 实测（--ax-probe，Chrome 153，窗口 1728×1070）：整棵树 43 个节点，
    /// 角色全是 AXGroup / AXButton / AXToolbar / AXTabGroup，**没有 AXWebArea**；
    /// 全部 68 个"正文"字符其实是地址栏那一串 URL。七个取样时刻、maxDepth 8→100 结果一致。
    /// 原因是 Chrome 的网页无障碍树要私有属性 `AXEnhancedUserInterface` 才会建，
    /// 而那个开关**默认开**（`AX.enhancedUserInterfaceKey`，代价见那里）。所以默认走的是
    /// `enhancedRegions`（`webAreaRegions()`）：优先读 AXWebArea 的 DOM 文本。
    /// 下面这副纯 OCR 的样子是**关掉开关之后**的形态，也是这条规则最初的形态。
    /// 所以正文只能 OCR，URL 单独从地址栏取（`AX.addressBarURL`）——两件事都不需要装扩展。
    ///
    /// 在这条规则之前 Chrome 落在 `genericChromium` 上，后果有两个：
    ///  1. 那 68 个字符让 AX 看起来"非空"，正文里于是只有一串 URL；
    ///  2. 截的是**整块显示器再裁窗口矩形**，压在 Chrome 上面的别的窗口的像素会一起进来，
    ///     并以 Chrome 的身份入库——2026-09-10 库里就有一条，页面正文里混着另一个窗口的
    ///     "AppleCare+ 按年经"、"Phone 16 Pra"。这不只是脏，是**归错了应用**。
    ///
    /// 所以走 `capturesWindow`：只渲染 Chrome 自己那个窗口，别人的画面根本不进这张图。
    /// 代价与微信那条一致，也是 2026-09-08 用户明确选过的那个取舍：**会连被盖住的部分一起采**，
    /// 库里可能出现用户当时其实看不见的页面内容。
    ///
    /// 无痕窗口不受影响：`PrivateBrowsing` 认标题里的 Incognito / 无痕浏览，那一支不读正文。
    /// 开关开着时正文走 AX（DOM 文本，逐字准确、含视口外内容），读空回退 OCR；
    /// 回退矩形跟着 AXWebArea 走，比按点数裁顶部外壳更准。这时 `readsAX` 变 true，
    /// Chromium「读到空树 ⇒ 排一次重扫」那条路重新生效——那正是它当初的设计场景
    /// （Chromium 的树是**异步**建起来的，第一次多半读到空）。
    /// 开关开着时那副样子的区域：读最富的那个 `AXWebArea` 的 DOM 文本，读空回退 OCR。
    /// Chrome 开关开着那副样子（飞书改成了按标题挑 web area，飞书会议的 AX 实测是死的、不再给增强形态）。
    static func webAreaRegions() -> [RegionRule] {
        // `ocrOnFrameChange: false`（Step 3）：DOM 逐字给出的区域，帧变了而文本没变只可能是
        // 图片 / 动画 / 光标，再排 OCR 只会把噪声（乃至压在上面的别的窗口）记进来。
        // `.primaryWebArea`（2026-09-11 复查 F4）：页面 + 停靠 DevTools / 侧边栏同在一个窗口时
        // 按"外部地址优先、面积最大"挑，不再只比字数。`fallbackInset`（F2c）：web area 还没建出来
        // 那一秒的回退 OCR 矩形裁掉顶部外壳，不是整窗。
        [RegionRule(name: "web_area", kind: .body, locator: .primaryWebArea,
                    read: .axSubtree, ocrFallback: true, required: true, clipToViewport: true,
                    ocrOnFrameChange: false, fallbackInset: chromeShellInset())]
    }

    /// Chrome 顶部外壳（标签条 + 地址栏）的内缩矩形：开关关着时整页 OCR 的区域，
    /// 也是开关开着、AXWebArea 还没建出来那一秒的回退矩形。
    static func chromeShellInset() -> WindowInset {
        WindowInset(top: resolvePoints(chromeToolbarKey, default: chromeToolbarDefault, maximum: 400),
                    minWidth: 240, minHeight: 120,
                    fallback: RelativeRect(x: 0, y: 0.08, width: 1.0, height: 0.92))
    }

    /// **未按开关定形**。定形只发生在 `all` 那一处（`resolvingEnhanced`），
    /// 所以这条以及自检拿到的都是基座；`rule(for:)` 返回的才是定过形的。
    static let chrome = AdapterRule(
        id: "chrome",
        name: "Chrome 系浏览器",
        bundleIDs: ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
                    "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
                    "com.operasoftware.Opera", "company.thebrowser.Browser"],
        electron: false,
        regions: [
            RegionRule(name: "page", kind: .body,
                       locator: .insetRect(chromeShellInset()),
                       read: .ocr, ocrFallback: false, required: true, clipToViewport: true),
        ],
        chatLayout: nil,
        // **限额按"开关开着"那副样子定**：300/8 是按关着时那棵 43 节点的外壳树估的，
        // 开着时要走的是整棵网页 DOM 子树（飞书实测两个 web area 各 474 / 510 节点，
        // Claude 桌面版当年要 3000/30）。限额跟着规则走、不跟着 regions 走，
        // 所以必须按更大的那副定，否则开关一开就静默截断。
        limits: AX.BFSLimits(maxNodes: 3_000, maxDepth: 30),
        notes: "两副样子：私有属性开关关着时 AX 只给浏览器外壳（实测 43 节点、无 AXWebArea），"
             + "走整页视口 OCR、顶部外壳按 adapter.chrome.toolbarHeight 裁；"
             + "开着时改读最富的 AXWebArea（DOM 文本，逐字准确、含视口外内容），读空回退 OCR。"
             + "URL 从地址栏的 AXTextField 取，不装扩展、不用私有属性。"
             + "截图走窗口定向：别的窗口盖在上面时不会把它的像素记成 Chrome 的页面。"
             + "顶部外壳按点数裁（默认 80，开书签栏约 112，adapter.chrome.toolbarHeight 可校准）；"
             + "只记屏幕上显示出来的字：视频、图片、canvas 里的内容只有渲染成文字才认得到。"
             + "树是按页面建的：导航后头一秒、切回隐藏超过 5 分钟的标签页时读到空树属正常，"
             + "这时不 OCR、等重扫（并订阅 AXLoadComplete）；同窗口的停靠 DevTools / 侧边栏不当正文；"
             + "无痕 / 访客窗口按标题串尾「（无痕）」「(Incognito)」识别；chrome:// 内部页不写 URL。",
        capturesWindow: true,
        axTreePerDocument: true,
        enhancedRegions: webAreaRegions())

    // MARK: - 飞书（Electron）

    /// 飞书：正文只在 `AXEnhancedUserInterface` 开着时才读得到（Lark 的 Chromium 不认
    /// `AXManualAccessibility`，M0 实测树几乎为空）。**开关关着时只记窗口标题，不读正文也不 OCR**
    ///（Step 4，2026-09-11）：旧的"找 AXList、找不到就整窗 OCR + 顶部比例矩形认会话名"那条路
    /// 从没在真机上认对过——AXList 根本不存在，OCR 出来的是侧栏预览、水印（「邱某 某学园」
    /// 被写进 `windows.title`）与压在上面的别的窗口（复查 F2 / F3 / F4 / F8）。诚实地标 unavailable，
    /// 比往库里灌一堆错的东西好；而且默认就是开，这条路只有用户显式关掉开关时才会走。
    /// **不追溯未打开的会话与未滚动到的历史**（计划 3.3）。
    static let feishu = AdapterRule(
        id: "feishu",
        name: "飞书 / Lark",
        bundleIDs: ["com.electron.lark", "com.larksuite.larkApp", "com.bytedance.macos.feishu"],
        electron: true,
        // 开关关着那副样子：没有区域 ⇒ 一个字都不读、不排 OCR、completeness = unavailable。
        regions: [],
        chatLayout: ChatLayout(),
        // **限额按开关开着那副样子定**（2026-09-11 探针）：`messenger-chat` 里正文在 web area 下
        // 第 29–31 层；锚到 `.chatMessages` 之后是它下面第 14–16 层，加上找锚点那段 BFS，
        // 40 层才稳。旧的 14 层会在 `.chatMessages` 上面就停住，读到 0 字。
        limits: AX.BFSLimits(maxNodes: 3_000, maxDepth: 40),
        notes: "Electron（框架被改名成 Lark Framework，通用检测抓不到，靠显式清单）。"
             + "开关开着（默认）时读 messenger-chat 这个 web area 里 .chatMessages 下的当前会话，"
             + "会话名取 .chatWindow_chatName；侧栏 messenger 整块排除；云文档 / 邮箱等其它模块"
             + "退到那个模块自己的 web area，页标题即 web area 的 AXTitle。"
             + "只记视口内已渲染的消息（1 pt 占位行不算）；不追溯未打开会话与未滚动到的历史；"
             + "输入框草稿不记；单聊按行 class 加「我 / 对方名」前缀，群聊行里自带发送者名；"
             + "图片、文件、语音、通话只有屏幕上显示的文字才可能被记；"
             + "开关关着时只记窗口标题（恒为「飞书」），不读正文也不 OCR。",
        // OCR 回退截整个窗口（含被遮挡部分，D31 口径），不再截显示器再裁矩形：
        // 2026-09-11 复查 F3——压在上面的 Claude 窗口的字被记成了飞书正文。
        capturesWindow: true,
        titleOnlyWindowPrefixes: ["ModalWebViewWidget - "],
        watermarkFilter: true,
        // 2026-09-11 Step 0 探针（`tools/bench/results/feishu_step0_probe_2026-09-11.md`）定下的形态。
        // 标题区域由引擎先读（按 kind 排，不靠写的顺序），正文读行前缀时拿它当对方名。
        enhancedRegions: [
            RegionRule(name: "conversation_title", kind: .title,
                       locator: .webAreaDescendant(domClass: "chatWindow_chatName"),
                       read: .axSubtree, ocrFallback: false, required: false,
                       clipToViewport: false, maxChars: 128, ocrOnFrameChange: false),
            RegionRule(name: "body", kind: .messageList,
                       locator: .webArea(WebAreaPick(
                           prefer: .init(title: "messenger-chat", anchorClass: "chatMessages"),
                           exclude: ["messenger"])),
                       read: .axSubtree, ocrFallback: true, required: true, clipToViewport: true,
                       excludeRoles: ["AXTextArea", "AXTextField"],
                       probeContainerFrames: false,
                       documentOrder: true,
                       rowLabels: RowLabels(selfClass: "message-self",
                                            peerClass: "message-not-self",
                                            onlyWhenAncestorClass: "p2pChat"),
                       ocrOnFrameChange: false,
                       // 点表情的人名（`.reaction-user`）会以独立行混进对话（0.7.2 真机 evidence 19481）。
                       pruneClasses: ["message-reactions"]),
        ])

    // MARK: - 飞书会议（**另一个 app**，AX 是死的）

    /// 飞书会议不是飞书的一个窗口，是**另一个 app**：bundle id
    /// `com.bytedance.macos.feishu.iron`，进程是 Lark Framework 里的 `Lark Helper (Iron).app`。
    /// 所以上面 `feishu` 那条规则的 bundleIDs 根本匹配不到它。
    ///
    /// 它落到哪儿了：`Lark Helper (Iron).app` 里没有 `Contents/Frameworks`，通用 Chromium
    /// 检测的结构信号抓不到，人工清单里也没有它 ⇒ 拿到的是 `generic`，而 `generic` 的
    /// `ocrFallback` 是 **false** ⇒ **一次 OCR 都不会排**。2026-09-09 库里 17:33–17:37 的
    /// 18 条飞书会议观察全部 0 字符，就是这条路走出来的。
    ///
    /// 为什么直接 `.ocr`，而不是"BFS 读不到再回退"：`--ax-probe` 在**会议进行中**实测
    /// （0.5.0，窗口 1470×868，pid 97873）——整棵树**只有 2 个节点**（AXWindow + AXGroup），
    /// 0 字符，**没有 AXWebArea**；`AXManualAccessibility` 被拒；t=0/100/250/500/1000/2000/4000 ms
    /// 七个取样点全是 0；maxDepth 8→60、clipToViewport 开关，结果都不变。
    /// AX 通道在这个应用上是**死的**，不是"读得太早"（那是 Claude 桌面版那次的结论，别照搬）。
    /// 所以走微信那条路：直接视口 OCR，不浪费一次 BFS。
    ///
    /// 为什么整窗一块、不切区域：会议窗口的布局随状态大改（共享屏幕 / 宫格 / 演讲者 /
    /// 聊天面板开合 / 字幕条升降），定点或比例切都会在换布局时切到空处；而每多一个区域
    /// 就多一次 Vision 请求（限流是**按区域**算的），整窗一块反而最省。
    ///
    /// 代价（2026-09-09 复查时修正过一次，原来那个估算两头都错）：
    ///   * **次数**没有 5 s 限流说的那么多。OCR 只在有帧时才跑，而定时兜底是 **12 s** 一帧
    ///     （`CaptureController.periodicIntervalDefault`），且 `periodicTick` 只在
    ///     `source_state == .ok` 时截 —— 看会议时人往往不动键鼠，落到 `.userIdle` 就整个跳过。
    ///     所以上限是每小时几百次量级，不是按 5 s 限流算出来的 720 次。
    ///   * **单次**比 169 ms 贵。accurate 的耗时由**字符数**决定而不是像素
    ///     （D24 / E8 实测 0.24–0.36 ms/字符；稀疏页 306 字符 144 ms，密集页 2881 字符 **1008 ms**）。
    ///     而会议窗口共享文档时正是密集页 —— 本机实测一次整窗 OCR 出 2326 字节。
    /// 合起来仍然是有界的（帧频 12 s + 每区域 5 s 限流两道都在），但别拿"169 ms"去估。
    /// 嫌多就调间隔，不用重编译：
    /// `defaults write com.brosis.app capture.ocrMinInterval -float 15`
    static let feishuMeeting = AdapterRule(
        id: "feishu_meeting",
        name: "飞书会议",
        bundleIDs: [
            // 实测的那个（国内版飞书 7.x）。
            "com.bytedance.macos.feishu.iron",
            // 另外两个是按同一命名规律补的：`feishu` 规则里列了三个包名变体，
            // 会议子 app 就是在各自后面加 `.iron`。没有这两台机器可验，先放着；
            // 命中不了的后果只是退回今天的行为（0 字符），不会更差。
            "com.electron.lark.iron", "com.larksuite.larkApp.iron",
        ],
        electron: false,   // 实测不认 AXManualAccessibility，标 true 只会每次白设一遍
        regions: [
            RegionRule(name: "window", kind: .body, locator: .wholeWindow,
                       read: .ocr, ocrFallback: false, required: true, clipToViewport: true),
        ],
        chatLayout: nil,
        limits: AX.BFSLimits(maxNodes: 200, maxDepth: 6),
        notes: "独立 app（Lark Helper (Iron)），AX 树实测只有 2 个节点、0 字符、无 AXWebArea，"
             + "所以直接整窗视口 OCR。能记到的是屏幕上**显示出来的字**："
             + "共享屏幕里的内容、字幕、会中聊天、参会人名、会议标题；"
             + "语音本身不记，没显示在屏幕上的也不记。",
        // 会议窗口同样平铺水印（09-09 的 257 条整窗 OCR 每条都夹着「用户名 组织名」）。
        watermarkFilter: true)
        // **不给增强形态**（Step 6，2026-09-11 在真实会议里用 0.7.3 复测）：brosis 已经给
        // `.iron` 设了 `AXEnhancedUserInterface`，树仍然只有 2 个节点（AXWindow + AXGroup）、
        // 没有 AXWebArea，七个取样点全 0——与 09-09 只设公开属性时一模一样。这个 app 的 AX 是死的，
        // 不是没等到。之前那副 `webAreaRegions()` 只会让规则"读 AX"，触发 Chromium 空树重扫并把
        // 头两次扫描的 OCR 请求扔掉，白白晚几秒才开始记。

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

    /// Chromium 系但没有专属规则时用它：与通用规则唯一的差别是**开了 OCR 回退**。
    ///
    /// 为什么只对 Chromium 系放开（2026-09-09，探测 Codex 时定的）：通用规则写死
    /// `ocrFallback: false`，所以「没有专属规则 + AX 读不到」的应用**一个字都不会被记**——
    /// 不是记得少，是完全没有。清单里 `完整 0 · 部分 0` 的那些行全是这个原因
    /// （Codex 0/0/6、ZCode 0/2/66、LM Studio 0/0/19）。
    ///
    /// 但也不该对所有应用一律开 OCR：原生应用的 AX 空**通常就是真的没内容**，
    /// 为它们烧 OCR 是白费电。Chromium 系是唯一"AX 空 ≠ 没内容"的一类——
    /// 它们的正文在渲染进程里，要么应用主动打开无障碍才暴露，要么根本不暴露
    /// （Codex 连 AXWebArea 都没有，飞书那个定制 Electron 不认 AXManualAccessibility）。
    /// 对它们回退 OCR 是有依据的，对别人不是。
    static let genericChromium: AdapterRule = {
        var rule = generic
        rule.id = "generic_chromium"
        rule.name = "通用（Chromium 系，OCR 回退）"
        rule.regions = generic.regions.map { region in
            var copy = region
            copy.ocrFallback = true
            return copy
        }
        rule.notes = "与通用规则同一条 BFS，区别只在 AX 读不到时会排一次视口 OCR。"
                   + "真正拦在 Vision 前面的只有三道：有没有截到帧、OCRTriggerGate 的"
                   + "每区域 5 秒限流、以及'画面没变且该区域已 OCR 过就跳过'。"
                   + "**没有** per-OCR 的接电 / 温度 / 预算判定——别再照抄这句话。"
        return rule
    }()

    /// 首批规则（有序，进 README 与结果文件的规则表）。
    /// 定过形的 Chrome 规则。`all.first(where:)` 是对一个已知成员做线性搜索——
    /// 直接指名更清楚，也省掉每次扫描的那次字符串比较。
    static let resolvedChrome = all.first { $0.id == chrome.id } ?? chrome

    /// **规则表在这里按开关定形**：`enhancedRegions` 只是声明，套用只有这一处。
    static let all: [AdapterRule] = {
        let enhanced = AX.enhancedUserInterfaceEnabled()
        return [safari, chrome, claudeDesktop, feishu, feishuMeeting, wechat]
            .map { $0.resolvingEnhanced(enhanced) }
    }()

    /// bundle id → 规则；查不到就是兜底规则。
    /// 没有专属规则时兜底走哪一条，由**这里**决定，不再让每个调用点自己 derive——
    /// 加了 `chromium:` 参数的第一版有 6 个调用点没传，于是同一个 bundle id 在采集端解析成
    /// `generic_chromium`、在 OCR 协调器和策略列表里解析成 `generic`：
    /// "这个应用用哪条规则"变成了取决于谁在问。
    ///
    /// - Parameter bundleURL: 有就做完整判定（会摸一次文件系统并缓存），
    ///   没有就只查缓存——采集端在应用激活时已经算过了。
    static func rule(for bundleID: String?, bundleURL: URL? = nil) -> AdapterRule {
        let chromium: Bool
        if bundleURL != nil {
            chromium = AX.chromiumDetection(bundleID: bundleID, bundleURL: bundleURL)
                .detection.isChromium
        } else {
            chromium = AX.cachedChromiumDetection(bundleID: bundleID)?.isChromium ?? false
        }
        let base = chromium ? genericChromium : generic
        guard let bundleID, !bundleID.isEmpty else { return base }
        let lowered = bundleID.lowercased()
        for rule in all where rule.bundleIDs.contains(where: { $0.lowercased() == lowered }) {
            return rule
        }
        // **没在清单里、但结构上就是个 Chromium 浏览器** ⇒ 照样按浏览器那条规则来。
        //
        // 窗口定向截图、地址栏取 URL、无痕排除，这三件事是"浏览器"的性质而不是"Chrome"的
        // 性质。只认手写清单的话，新装一个 Chromium 浏览器（Edge Beta、Arc、Opera GX……）
        // 会落到 `genericChromium` 上——那条 `capturesWindow` 是 false，于是"压在上面的
        // 别的窗口的像素被记成这个应用的网页内容"那个**归错应用**的缺陷会原样回来，
        // 而且没有任何信号。判据只读 Info.plist，见 `AX.isChromiumBrowser`。
        //
        // 判定只有一处（`PrivateBrowsing.isBrowser`）；没有 bundleURL 时它只查缓存、不缓存错的 false。
        if chromium, PrivateBrowsing.isBrowser(bundleID: bundleID, bundleURL: bundleURL) {
            return resolvedChrome
        }
        // 访达等已经有 BFS 收紧值的应用：兜底规则 + 它自己的限额（`AX.bfsLimits`）。
        var fallback = base
        fallback.limits = AX.bfsLimits(bundleID: bundleID)
        return fallback
    }
}

extension AdapterRule {
    /// 便利初始化：让上面的规则定义可以按"先写 notes 再写 limits"的顺序写。
    init(id: String, name: String, bundleIDs: [String], electron: Bool,
         regions: [RegionRule], chatLayout: ChatLayout?, notes: String, limits: AX.BFSLimits,
         enhancedRegions: [RegionRule]? = nil) {
        self.init(id: id, name: name, bundleIDs: bundleIDs, electron: electron,
                  regions: regions, chatLayout: chatLayout, limits: limits, notes: notes,
                  enhancedRegions: enhancedRegions)
    }
}
