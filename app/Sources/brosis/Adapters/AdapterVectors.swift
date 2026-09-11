import BrosisCore
import CoreGraphics
import Foundation

/// 适配器与视口 OCR 的判定用例（`--self-check` 与 `--dump-vectors` 共用）。
///
/// 全部走合成树 / 合成布局：**不启动任何应用、不发 AX 消息、不需要辅助功能权限**。
/// 四棵合成树刻意都带上三种节点：视口内、视口外、回滚区（整块在视口上方）。
enum AdapterVectors {

    /// 所有合成树共用的窗口矩形（AX 坐标：原点左上、y 向下）。
    static let window = CGRect(x: 100, y: 60, width: 1_200, height: 800)

    /// 视口内的一条 y（窗口中部）。
    private static func visibleRect(y: Double, height: Double = 40) -> CGRect {
        CGRect(x: window.minX + 20, y: y, width: window.width - 40, height: height)
    }

    // MARK: - 四棵合成树

    /// Safari：AXWebArea 里三段正文，其中一段在视口下方之外、一段整块在视口上方（回滚区）。
    /// 另有一个 `AXVisibleCharacterRange` 只暴露前 12 个字符的长文本节点。
    static func safariTree() -> SyntheticAXNode {
        SyntheticAXNode(
            role: "AXWindow", title: "brosis 项目周报 — Safari", frame: window,
            kids: [
                SyntheticAXNode(role: "AXToolbar", frame: visibleRect(y: 70, height: 40), kids: [
                    SyntheticAXNode(role: "AXTextField", value: "https://example.invalid/report",
                                    frame: visibleRect(y: 70, height: 24)),
                ]),
                SyntheticAXNode(
                    role: "AXWebArea", value: "https://example.invalid/report",
                    frame: CGRect(x: 100, y: 120, width: 1_200, height: 700),
                    kids: [
                        // 回滚区：整块在视口上方（y + h <= viewport.minY）
                        SyntheticAXNode(role: "AXGroup",
                                        frame: CGRect(x: 100, y: 0, width: 1_200, height: 100),
                                        kids: [
                                            SyntheticAXNode(role: "AXStaticText",
                                                            value: "滚上去看不见的历史正文",
                                                            frame: CGRect(x: 120, y: 10,
                                                                          width: 400, height: 30)),
                                        ]),
                        SyntheticAXNode(role: "AXStaticText", value: "第一段可见正文",
                                        frame: visibleRect(y: 200)),
                        SyntheticAXNode(role: "AXStaticText", value: "第二段可见正文",
                                        frame: visibleRect(y: 260)),
                        // 长文本，只暴露视口内的前 12 个字符
                        SyntheticAXNode(role: "AXTextArea",
                                        value: "这一段很长一共有二十四个字后面的看不见了",
                                        frame: visibleRect(y: 320, height: 60),
                                        visibleCharacterRange: NSRange(location: 0, length: 12)),
                        // 视口外：在窗口下方之外
                        SyntheticAXNode(role: "AXStaticText", value: "视口下方之外的正文",
                                        frame: CGRect(x: 120, y: 1_400, width: 400, height: 30)),
                    ]),
            ])
    }

    /// Claude 桌面版（Electron）：设过 AXManualAccessibility 之后能读到 AXWebArea。
    /// 这里造的是"能读到"的分支；"读不到"的分支用 `claudeEmptyTree()`。
    static func claudeTree() -> SyntheticAXNode {
        SyntheticAXNode(
            role: "AXWindow", title: "Claude", frame: window,
            kids: [
                SyntheticAXNode(
                    role: "AXWebArea", frame: CGRect(x: 100, y: 120, width: 1_200, height: 700),
                    kids: [
                        SyntheticAXNode(role: "AXStaticText", value: "用户：帮我看下这段代码",
                                        frame: visibleRect(y: 200)),
                        SyntheticAXNode(role: "AXStaticText", value: "Claude：这里的坐标翻转反了",
                                        frame: visibleRect(y: 260)),
                        SyntheticAXNode(role: "AXStaticText", value: "更早的对话（已滚出视口）",
                                        frame: CGRect(x: 120, y: 0, width: 400, height: 30)),
                    ]),
            ])
    }

    /// Claude 桌面版的**实测形态**（M0：74 条观察、AX 正文合计 0 字符）：树在但没有文本节点。
    /// 规则的 `ocrFallback` 必须在这棵树上触发。
    static func claudeEmptyTree() -> SyntheticAXNode {
        SyntheticAXNode(
            role: "AXWindow", title: "Claude", frame: window,
            kids: [
                SyntheticAXNode(role: "AXWebArea",
                                frame: CGRect(x: 100, y: 120, width: 1_200, height: 700),
                                kids: [SyntheticAXNode(role: "AXGroup",
                                                       frame: visibleRect(y: 200))]),
            ])
    }

    // MARK: - 飞书（开关开着那副样子：2026-09-11 Step 0 探针量到的结构）

    /// 飞书主窗口：两个 AXWebArea——侧栏 `messenger`（更富、全是别的会话的预览）与当前会话
    /// `messenger-chat`。会话在 `.chatMessages` 下，深度按真机造（web area 下第 22 层才到正文）；
    /// 三行消息里第一行是 1 pt 高的虚拟列表占位（滚出视口的历史）；会话头里有对方的个性签名；
    /// 输入区里有 AXTextArea 草稿。`p2p` 决定容器有没有 `p2pChat`、行里有没有发送者名。
    static func feishuEnhancedTree(p2p: Bool) -> SyntheticAXNode {
        let pane = CGRect(x: 484, y: 60, width: 816, height: 800)
        func group(_ classes: [String] = [], frame: CGRect = pane,
                   kids: [SyntheticAXNode]) -> SyntheticAXNode {
            SyntheticAXNode(role: "AXGroup", frame: frame, domClasses: classes, kids: kids)
        }
        func text(_ value: String, y: Double, height: Double = 20) -> SyntheticAXNode {
            SyntheticAXNode(role: "AXStaticText", value: value,
                            frame: CGRect(x: 560, y: y, width: 500, height: height))
        }
        func content(_ value: String, y: Double, height: Double) -> SyntheticAXNode {
            let frame = CGRect(x: 546, y: y, width: 700, height: height)
            return group(["message-section"], frame: frame, kids: [
                group(["message-content-container"], frame: frame, kids: [
                    group(["richTextContainer"], frame: frame,
                          kids: [text(value, y: y + 4, height: max(height - 8, 1))]),
                ]),
            ])
        }
        func row(_ classes: [String], y: Double, height: Double,
                 kids: [SyntheticAXNode]) -> SyntheticAXNode {
            let frame = CGRect(x: 484, y: y, width: 816, height: height)
            return group(["messageList-row-wrapper"], frame: frame, kids: [
                group(["messageItem-wrapper"], frame: frame, kids: [
                    group(["js-message-item", "message-item"] + classes, frame: frame, kids: [
                        group(["message-right"], frame: frame, kids: kids),
                    ]),
                ]),
            ])
        }
        let title = p2p ? "崔某" : "需求同步群"
        let peerKids: [SyntheticAXNode] = p2p
            ? [content("对方说的话", y: 220, height: 60)]
            : [group(["message-info"], frame: CGRect(x: 546, y: 220, width: 700, height: 24),
                     kids: [group(["message-info-name"],
                                  frame: CGRect(x: 546, y: 220, width: 100, height: 24),
                                  kids: [text("王某", y: 222)])]),
               content("群里的一句话", y: 250, height: 30)]
        let header = group(["chatContainer__headerWrapper"],
                           frame: CGRect(x: 484, y: 60, width: 816, height: 68), kids: [
            group(["chatNewWindow_headerMain"],
                  frame: CGRect(x: 500, y: 60, width: 780, height: 68), kids: [
                group(["chatWindow_chatName"], frame: CGRect(x: 540, y: 82, width: 200, height: 24),
                      kids: [text(title, y: 84)]),
                group(["chatNewWindow_chatterDescription"],
                      frame: CGRect(x: 760, y: 82, width: 300, height: 24),
                      kids: [text("对方的个性签名", y: 84)]),
            ]),
        ])
        let messages = group(["chatSidebar"], kids: [
            group(["larkw-drag-panel"], kids: [
                group(["chatMessageContainer"], kids: [
                    group(["chatMessages"], kids: [
                        group(["messageContainer"], kids: [
                            group(["scroller"], kids: [
                                group(["list_items"], kids: [
                                    row(["message-not-self"], y: 140, height: 1,
                                        kids: [content("滚上去的历史消息", y: 140, height: 1)]),
                                    row(["message-not-self"], y: 220, height: 60, kids: peerKids),
                                    row(["message-self"], y: 300, height: 60,
                                        kids: [content("我说的话", y: 300, height: 40),
                                               // 点表情的人名（真机 evidence 19481 里以独立行混进对话）
                                               group(["message-reactions"],
                                                     frame: CGRect(x: 546, y: 342, width: 200, height: 16),
                                                     kids: [group(["reaction-user"],
                                                                  frame: CGRect(x: 580, y: 342, width: 60, height: 16),
                                                                  kids: [text("点表情的人", y: 342, height: 16)])])]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
            group(["lark__editor--chat"], frame: CGRect(x: 500, y: 783, width: 780, height: 48),
                  kids: [SyntheticAXNode(role: "AXTextArea", value: "发送给 \(title)",
                                         frame: CGRect(x: 510, y: 795, width: 460, height: 23))]),
        ])
        let chat = SyntheticAXNode(
            role: "AXWebArea", title: "messenger-chat", frame: pane, kids: [
                group(["larkc-zh-CN"], kids: [
                    SyntheticAXNode(role: "AXGroup", identifier: "root", frame: pane, kids: [
                        group(["lark-chat", "main-box"], kids: [
                            group(["lark-chat-right"], kids: [
                                group(["chatContainer", "post-container"] + (p2p ? ["p2pChat"] : []),
                                      kids: [
                                    group(["chatSidebar"], kids: [
                                        group(["chatContainer_contentWrapper"],
                                              kids: [header, messages]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        let sidebarFrame = CGRect(x: 100, y: 60, width: 384, height: 800)
        let sidebar = SyntheticAXNode(
            role: "AXWebArea", title: "messenger", frame: sidebarFrame, kids: [
                SyntheticAXNode(role: "AXGroup", identifier: "root", frame: sidebarFrame, kids:
                    (1...6).map { index in
                        SyntheticAXNode(role: "AXStaticText",
                                        value: "会话甲\(index) : 预览甲\(index) 这是别的会话的最后一条",
                                        frame: CGRect(x: 120, y: 200 + Double(index) * 60,
                                                      width: 340, height: 40))
                    }),
            ])
        return SyntheticAXNode(role: "AXWindow", title: "飞书", frame: window, kids: [
            SyntheticAXNode(role: "AXGroup", frame: window, kids: [sidebar, chat]),
        ])
    }

    /// 飞书切到「云文档」：树里只剩那个模块自己的 web area，AXTitle 就是页标题（Step 0 §5.2）。
    static func feishuDocsTree() -> SyntheticAXNode {
        SyntheticAXNode(role: "AXWindow", title: "飞书", frame: window, kids: [
            SyntheticAXNode(role: "AXGroup", frame: window, kids: [
                SyntheticAXNode(role: "AXWebArea", title: "主页 - 飞书云文档", frame: window, kids: [
                    SyntheticAXNode(role: "AXGroup", frame: window, kids: [
                        SyntheticAXNode(role: "AXStaticText", value: "最近访问",
                                        frame: CGRect(x: 600, y: 200, width: 200, height: 24)),
                        SyntheticAXNode(role: "AXStaticText", value: "文档一",
                                        frame: CGRect(x: 600, y: 260, width: 200, height: 24)),
                    ]),
                ]),
            ]),
        ])
    }

    /// 飞书树还没建起来（刚设完私有属性）或图片查看器窗口：一个 web area 都没有 → 正文空、排整窗 OCR。
    static func feishuColdTree() -> SyntheticAXNode {
        SyntheticAXNode(role: "AXWindow", title: "飞书", frame: window,
                        kids: [SyntheticAXNode(role: "AXGroup", frame: window)])
    }

    /// 微信：AX 树里只有窗口本身（M0 实测正文 0 字符）。规则声明整块聊天面板走 OCR。
    static func wechatTree() -> SyntheticAXNode {
        SyntheticAXNode(role: "AXWindow", title: "微信", frame: window,
                        kids: [SyntheticAXNode(role: "AXSplitGroup", frame: window)])
    }

    // MARK: - 规则引擎用例

    struct RuleCase: Sendable {
        var name: String
        var rule: AdapterRule
        var tree: @Sendable () -> SyntheticAXNode
        /// 期望入库的片段数。
        var expectedFragments: Int
        var expectedCompleteness: Completeness
        /// 期望文本里**必须**出现的串。
        var mustContain: [String]
        /// 期望文本里**不能**出现的串（视口外 / 回滚区的内容）。
        var mustNotContain: [String]
        /// 期望产生的 OCR 请求区域名。
        var expectedOCRRegions: [String]
    }

    static let ruleCases: [RuleCase] = [
        RuleCase(name: "Safari：AXWebArea 正文，视口外与回滚区不入库",
                 rule: AdapterRegistry.safari,
                 tree: safariTree,
                 expectedFragments: 1,                    // 只有 web_area（URL 由事件骨架读）
                 expectedCompleteness: .partial,          // 视口外有内容 → partial
                 mustContain: ["第一段可见正文", "第二段可见正文", "这一段很长一共有二十四"],
                 mustNotContain: ["滚上去看不见的历史正文", "视口下方之外的正文",
                                  "个字后面的看不见了"],
                 expectedOCRRegions: []),
        RuleCase(name: "Claude 桌面版：AX 能读到时不 OCR",
                 rule: AdapterRegistry.claudeDesktop,
                 tree: claudeTree,
                 expectedFragments: 1,
                 expectedCompleteness: .partial,
                 mustContain: ["这里的坐标翻转反了"],
                 mustNotContain: ["更早的对话"],
                 expectedOCRRegions: []),
        RuleCase(name: "Claude 桌面版：AX 读到空 → 回退视口 OCR",
                 rule: AdapterRegistry.claudeDesktop,
                 tree: claudeEmptyTree,
                 expectedFragments: 0,
                 expectedCompleteness: .unavailable,
                 mustContain: [],
                 mustNotContain: [],
                 expectedOCRRegions: ["conversation"]),
        RuleCase(name: "飞书（开关关）：只记窗口标题——不读正文、不 OCR、unavailable",
                 // **显式取"开关关着"那副样子**（Step 4）：树里有东西也不读——这条路上读到的
                 // 从来都是侧栏预览与水印，诚实标 unavailable。
                 rule: AdapterRegistry.feishu.resolvingEnhanced(false),
                 tree: { feishuEnhancedTree(p2p: true) },
                 expectedFragments: 0,
                 expectedCompleteness: .unavailable,
                 mustContain: [],
                 mustNotContain: [],
                 expectedOCRRegions: []),
        RuleCase(name: "飞书（开关开）单聊：只读 messenger-chat 的 .chatMessages，侧栏 / 会话头 / 草稿 / 占位行不进库，行带前缀",
                 rule: AdapterRegistry.feishu.resolvingEnhanced(true),
                 tree: { feishuEnhancedTree(p2p: true) },
                 expectedFragments: 2,                    // conversation_title + body
                 expectedCompleteness: .partial,          // 1 pt 占位行算视口外
                 mustContain: ["崔某", "崔某：对方说的话", "我：我说的话"],
                 mustNotContain: ["会话甲", "预览甲", "滚上去的历史消息", "发送给", "个性签名", "点表情的人"],
                 expectedOCRRegions: []),
        RuleCase(name: "飞书（开关开）群聊：行里自带发送者名、文档顺序不串行、不加前缀",
                 rule: AdapterRegistry.feishu.resolvingEnhanced(true),
                 tree: { feishuEnhancedTree(p2p: false) },
                 expectedFragments: 2,
                 expectedCompleteness: .partial,
                 mustContain: ["需求同步群", "王某\n群里的一句话", "我说的话"],
                 mustNotContain: ["我：", "需求同步群：", "对方：", "会话甲", "发送给", "点表情的人"],
                 expectedOCRRegions: []),
        RuleCase(name: "飞书（开关开）云文档：只剩模块自己的 web area，页标题即其 AXTitle",
                 rule: AdapterRegistry.feishu.resolvingEnhanced(true),
                 tree: feishuDocsTree,
                 expectedFragments: 2,
                 expectedCompleteness: .complete,
                 mustContain: ["主页 - 飞书云文档", "文档一"],
                 mustNotContain: ["会话甲"],
                 expectedOCRRegions: []),
        RuleCase(name: "飞书（开关开）树没建起来：一个 web area 都没有 → 正文空、排整窗 OCR",
                 rule: AdapterRegistry.feishu.resolvingEnhanced(true),
                 tree: feishuColdTree,
                 expectedFragments: 0,
                 expectedCompleteness: .unavailable,
                 mustContain: [],
                 mustNotContain: [],
                 expectedOCRRegions: ["body"]),
        RuleCase(name: "微信：AX 全空 → 聊天面板与会话名都走 OCR",
                 rule: AdapterRegistry.wechat,
                 tree: wechatTree,
                 expectedFragments: 0,
                 expectedCompleteness: .unavailable,
                 mustContain: [],
                 mustNotContain: [],
                 expectedOCRRegions: ["chat_panel", "conversation_title"]),
    ]

    // MARK: - 完整性四态

    struct CompletenessCase: Sendable {
        var name: String
        var rule: AdapterRule
        var tree: @Sendable () -> SyntheticAXNode
        var windowFrame: CGRect?
        var expected: Completeness
        var why: String
    }

    /// 全部可见、没有任何限额与裁剪 → `complete`（M0 一条都没有的那个状态）。
    static func completeTree() -> SyntheticAXNode {
        SyntheticAXNode(role: "AXWindow", title: "记事本", frame: window,
                        kids: [
                            SyntheticAXNode(role: "AXTextArea", value: "一整页都在视口里的正文",
                                            frame: CGRect(x: 120, y: 100,
                                                          width: 1_000, height: 200)),
                        ])
    }

    static let completenessCases: [CompletenessCase] = [
        CompletenessCase(name: "complete：必需区域全读到、视口内没有漏、没有待办 OCR",
                         rule: AdapterRegistry.generic, tree: completeTree, windowFrame: window,
                         expected: .complete, why: "全部文本节点都在视口内且没命中任何限额"),
        CompletenessCase(name: "partial：视口外还有内容",
                         rule: AdapterRegistry.safari, tree: safariTree, windowFrame: window,
                         expected: .partial, why: "回滚区与视口下方各有一个文本节点被丢掉"),
        CompletenessCase(name: "unavailable：一个字都没读到",
                         rule: AdapterRegistry.claudeDesktop, tree: claudeEmptyTree,
                         windowFrame: window,
                         expected: .unavailable, why: "AX 树在但没有文本节点（M0 实测形态）"),
    ]

    /// `excluded` 不由适配器判：它在 `EventSkeleton` 里由 3.12 的档位与私密浏览先行决定。
    /// 这里把那条判定原样复述成一个用例，保证四态都有出处。
    static func excludedByPolicy(mode: CapturePolicyMode, privateBrowsing: Bool) -> Completeness? {
        if privateBrowsing { return .excluded }
        if !CapturePolicyStore.gate(for: mode).readsContent { return .excluded }
        return nil
    }

    // MARK: - OCR 触发条件（三类 + 反例 + 限流）

    struct TriggerCase: Sendable {
        var name: String
        var ruleDeclaresOCR: Bool
        var ocrFallback: Bool
        var axEmpty: Bool
        var axChanged: Bool
        var frameChanged: Bool
        var coverageFailed: Bool
        var expected: OCRTriggerReason?
    }

    static let triggerCases: [TriggerCase] = [
        TriggerCase(name: "① 规则声明 AX 不可用（微信聊天面板）",
                    ruleDeclaresOCR: true, ocrFallback: false, axEmpty: true, axChanged: false,
                    frameChanged: false, coverageFailed: false, expected: .ruleDeclared),
        TriggerCase(name: "① 规则允许回退且 AX 读到空（Claude 桌面版）",
                    ruleDeclaresOCR: false, ocrFallback: true, axEmpty: true, axChanged: false,
                    frameChanged: false, coverageFailed: false, expected: .ruleDeclared),
        TriggerCase(name: "② 帧变化超阈值 + AX 值未变 → OCR",
                    ruleDeclaresOCR: false, ocrFallback: false, axEmpty: false, axChanged: false,
                    frameChanged: true, coverageFailed: false, expected: .frameChangedAXStable),
        TriggerCase(name: "② 反例：帧变化 + AX 值也变了 → 不 OCR",
                    ruleDeclaresOCR: false, ocrFallback: false, axEmpty: false, axChanged: true,
                    frameChanged: true, coverageFailed: false, expected: nil),
        TriggerCase(name: "② 反例：AX 值未变但帧也没变 → 不 OCR",
                    ruleDeclaresOCR: false, ocrFallback: false, axEmpty: false, axChanged: false,
                    frameChanged: false, coverageFailed: false, expected: nil),
        TriggerCase(name: "③ 覆盖检查失败 → OCR",
                    ruleDeclaresOCR: false, ocrFallback: false, axEmpty: false, axChanged: true,
                    frameChanged: false, coverageFailed: true, expected: .coverageFailed),
        TriggerCase(name: "反例：什么条件都不满足 → 不 OCR",
                    ruleDeclaresOCR: false, ocrFallback: false, axEmpty: true, axChanged: true,
                    frameChanged: false, coverageFailed: false, expected: nil),
    ]

    // MARK: - 阅读顺序

    struct ReadingOrderCase: Sendable {
        var name: String
        var items: [ReadingOrder.Item]
        var expected: String
    }

    static let readingOrderCases: [ReadingOrderCase] = [
        ReadingOrderCase(
            name: "两栏：同一行的两块按 x 从左到右，行间从上到下",
            items: [
                ReadingOrder.Item(text: "右上", box: CGRect(x: 0.55, y: 0.80, width: 0.3, height: 0.05)),
                ReadingOrder.Item(text: "左上", box: CGRect(x: 0.05, y: 0.80, width: 0.3, height: 0.05)),
                ReadingOrder.Item(text: "左下", box: CGRect(x: 0.05, y: 0.40, width: 0.3, height: 0.05)),
                ReadingOrder.Item(text: "右下", box: CGRect(x: 0.55, y: 0.41, width: 0.3, height: 0.05)),
            ],
            expected: "左上 右上\n左下 右下"),
        ReadingOrderCase(
            name: "行距紧但高度一致：不该被粘成一行",
            items: [
                ReadingOrder.Item(text: "第一行", box: CGRect(x: 0.1, y: 0.60, width: 0.3, height: 0.04)),
                ReadingOrder.Item(text: "第二行", box: CGRect(x: 0.1, y: 0.54, width: 0.3, height: 0.04)),
                ReadingOrder.Item(text: "第三行", box: CGRect(x: 0.1, y: 0.48, width: 0.3, height: 0.04)),
            ],
            expected: "第一行\n第二行\n第三行"),
        ReadingOrderCase(
            name: "同一行里高度不齐（中英混排）：仍算同一行",
            items: [
                ReadingOrder.Item(text: "brosis", box: CGRect(x: 0.40, y: 0.700, width: 0.2, height: 0.030)),
                ReadingOrder.Item(text: "适配器", box: CGRect(x: 0.10, y: 0.702, width: 0.2, height: 0.040)),
            ],
            expected: "适配器 brosis"),
    ]

    // MARK: - 低置信 token（D24）

    static let lowConfidencePositives = [
        "0x7ffee4b21c30", "a3f9c1e2b", "deadbeef12", "Zm9vYmFy1234Abcd",
    ]
    static let lowConfidenceNegatives = [
        "适配器", "ObservationInput", "https://example.invalid/x", "2026-09-08", "brosis",
    ]

    // MARK: - 气泡归属（合成布局 JSON）

    /// 单聊 + 群聊两份合成布局。坐标是 Vision 的归一化坐标（原点左下、y 向上）。
    static let bubbleLayoutJSON = """
    [
      {
        "name": "单聊：左 = 对方、右 = 自己，语音只记 [语音]",
        "group": false,
        "regionHeightPoints": 600,
        "lines": [
          { "text": "你那边适配器跑通了吗", "x": 0.06, "y": 0.82, "w": 0.34, "h": 0.05 },
          { "text": "跑通了，正在接视口 OCR", "x": 0.58, "y": 0.70, "w": 0.36, "h": 0.05 },
          { "text": "3\\"", "x": 0.06, "y": 0.58, "w": 0.06, "h": 0.05 },
          { "text": "好的我看下", "x": 0.62, "y": 0.46, "w": 0.30, "h": 0.05 }
        ],
        "expected": [
          "对方：你那边适配器跑通了吗",
          "我：跑通了，正在接视口 OCR",
          "对方：[语音]",
          "我：好的我看下"
        ]
      },
      {
        "name": "群聊：取气泡上方的昵称，昵称行本身不入库成正文",
        "group": true,
        "regionHeightPoints": 600,
        "lines": [
          { "text": "张三", "x": 0.06, "y": 0.860, "w": 0.08, "h": 0.025 },
          { "text": "今天的适配器名单确认了吗", "x": 0.06, "y": 0.800, "w": 0.38, "h": 0.045 },
          { "text": "李四", "x": 0.06, "y": 0.700, "w": 0.08, "h": 0.025 },
          { "text": "确认了，飞书和微信都在里面", "x": 0.06, "y": 0.640, "w": 0.40, "h": 0.045 },
          { "text": "我这边同步一下", "x": 0.60, "y": 0.520, "w": 0.32, "h": 0.045 }
        ],
        "expected": [
          "张三：今天的适配器名单确认了吗",
          "李四：确认了，飞书和微信都在里面",
          "我：我这边同步一下"
        ]
      }
    ]
    """

    static func bubbleLayouts() -> [BubbleLayoutFixture] {
        (try? JSONDecoder().decode([BubbleLayoutFixture].self,
                                   from: Data(bubbleLayoutJSON.utf8))) ?? []
    }

    // MARK: - 视口相交

    struct ViewportCase: Sendable {
        var name: String
        var frame: CGRect?
        var viewport: CGRect?
        var expected: Bool?
        var scrollback: Bool
        /// 文本节点传 `Viewport.minVisibleSize`，容器传 0（默认）。
        var minSize: CGFloat = 0
    }

    static let viewportCases: [ViewportCase] = [
        ViewportCase(name: "完全在视口内", frame: CGRect(x: 150, y: 200, width: 100, height: 40),
                     viewport: window, expected: true, scrollback: false),
        ViewportCase(name: "部分相交也算可见", frame: CGRect(x: 50, y: 200, width: 100, height: 40),
                     viewport: window, expected: true, scrollback: false),
        ViewportCase(name: "整块在视口上方 = 回滚区",
                     frame: CGRect(x: 150, y: 0, width: 100, height: 40),
                     viewport: window, expected: false, scrollback: true),
        ViewportCase(name: "整块在视口下方",
                     frame: CGRect(x: 150, y: 1_400, width: 100, height: 40),
                     viewport: window, expected: false, scrollback: false),
        ViewportCase(name: "读不到 frame → 判定不了，按可见处理",
                     frame: nil, viewport: window, expected: nil, scrollback: false),
        ViewportCase(name: "没有视口矩形 → 判定不了",
                     frame: CGRect(x: 150, y: 200, width: 100, height: 40),
                     viewport: nil, expected: nil, scrollback: false),
        ViewportCase(name: "零面积节点按不可见处理",
                     frame: CGRect(x: 150, y: 200, width: 0, height: 0),
                     viewport: window, expected: false, scrollback: false),
        ViewportCase(name: "1 pt 高的文本节点（虚拟列表滚出视口的消息）按不可见",
                     frame: CGRect(x: 150, y: 200, width: 800, height: 1),
                     viewport: window, expected: false, scrollback: false,
                     minSize: Viewport.minVisibleSize),
        ViewportCase(name: "1 pt 高的容器（弹层挂载点）不按阈值判，仍算相交",
                     frame: CGRect(x: 150, y: 200, width: 800, height: 1),
                     viewport: window, expected: true, scrollback: false),
    ]

    // MARK: - AXVisibleCharacterRange

    struct VisibleRangeCase: Sendable {
        var name: String
        var value: String
        var range: NSRange?
        var expectedText: String
        var expectedClipped: Bool
    }

    static let visibleRangeCases: [VisibleRangeCase] = [
        VisibleRangeCase(name: "有可见范围：只取视口内那一段",
                         value: "一二三四五六七八九十", range: NSRange(location: 0, length: 4),
                         expectedText: "一二三四", expectedClipped: true),
        VisibleRangeCase(name: "可见范围覆盖全文：不算裁剪",
                         value: "一二三四", range: NSRange(location: 0, length: 4),
                         expectedText: "一二三四", expectedClipped: false),
        VisibleRangeCase(name: "没有可见范围：原样返回",
                         value: "一二三四", range: nil,
                         expectedText: "一二三四", expectedClipped: false),
        VisibleRangeCase(name: "范围越界：按原样返回，不崩",
                         value: "一二三四", range: NSRange(location: 10, length: 4),
                         expectedText: "一二三四", expectedClipped: false),
        VisibleRangeCase(name: "范围长度为 0：按原样返回",
                         value: "一二三四", range: NSRange(location: 0, length: 0),
                         expectedText: "一二三四", expectedClipped: false),
    ]

    // MARK: - 会话名与群聊判定（M2）

    struct ChatTitleCase: Sendable {
        var name: String
        /// 标题条那一块 OCR 出来的整段文本（可能多行、带图标残渣）。
        var raw: String
        /// nil = 认不出会话名（这时观察退回窗口标题，不写 windows 表）。
        var expected: ChatTitle.Resolved?
    }

    /// 前两条是**真机样本**：M2 从库里 evidence 2849 / 4260 的 `conversation_title` 区域原样取的。
    static let chatTitleCases: [ChatTitleCase] = [
        ChatTitleCase(name: "真机：群聊，带人数后缀与图标残渣",
                      raw: "④ 省省吧 （29）\n眼",
                      expected: ChatTitle.Resolved(display: "省省吧", isGroup: true)),
        ChatTitleCase(name: "真机：框偏时抓到会话列表 → 当单聊处理，取第一行",
                      raw: "◎ Routines\n白 Dispatch Beta",
                      expected: ChatTitle.Resolved(display: "Routines", isGroup: false)),
        ChatTitleCase(name: "单聊：只有联系人名",
                      raw: "张三",
                      expected: ChatTitle.Resolved(display: "张三", isGroup: false)),
        ChatTitleCase(name: "群聊：半角括号（OCR 常把全角认成半角）",
                      raw: "M1 复核组 (7)",
                      expected: ChatTitle.Resolved(display: "M1 复核组", isGroup: true)),
        ChatTitleCase(name: "反例：数字在词中间不是人数后缀",
                      raw: "2026年7月C端APP日活查询",
                      expected: ChatTitle.Resolved(display: "2026年7月C端APP日活查询", isGroup: false)),
        ChatTitleCase(name: "反例：第2组——数字前是汉字，不算人数",
                      raw: "第2组",
                      expected: ChatTitle.Resolved(display: "第2组", isGroup: false)),
        ChatTitleCase(name: "反例：整段都是符号 → 认不出，不写 windows 表",
                      raw: "◎ ••• ——",
                      expected: nil),
        ChatTitleCase(name: "反例：超长（框偏抓到整块面板）→ 认不出",
                      raw: String(repeating: "长", count: ChatTitle.maxTitleCharacters + 1),
                      expected: nil),
        ChatTitleCase(name: "反例：空文本",
                      raw: "   \n  ",
                      expected: nil),
    ]

    // MARK: - 水印过滤（Step 3）

    struct WatermarkLearnCase: Sendable {
        var name: String
        var items: [ReadingOrder.Item]
        var expected: String?
    }

    private static func box(_ x: Double, _ y: Double) -> CGRect {
        CGRect(x: x, y: y, width: 0.12, height: 0.03)
    }

    static let watermarkLearnCases: [WatermarkLearnCase] = [
        WatermarkLearnCase(name: "平铺四处的「用户名 组织名」→ 学到（归一化去空格）",
                           items: [
                               ReadingOrder.Item(text: "邱某 某学园", box: box(0.1, 0.9)),
                               ReadingOrder.Item(text: "邱某某学园", box: box(0.6, 0.9)),
                               ReadingOrder.Item(text: "邱某 某学园.", box: box(0.1, 0.4)),
                               ReadingOrder.Item(text: "邱某某学园", box: box(0.6, 0.4)),
                               ReadingOrder.Item(text: "这是一句真正的正文", box: box(0.2, 0.7)),
                           ],
                           expected: "邱某某学园"),
        WatermarkLearnCase(name: "群聊里左对齐重复的发送者名 → 不是水印（同一列，且太短）",
                           items: (0..<5).map { ReadingOrder.Item(text: "刘某", box: box(0.1, 0.1 + Double($0) * 0.15)) },
                           expected: nil),
        WatermarkLearnCase(name: "同一列重复五次的长串 → 不是水印（没有平铺）",
                           items: (0..<5).map { ReadingOrder.Item(text: "这段正文重复出现", box: box(0.1, 0.1 + Double($0) * 0.15)) },
                           expected: nil),
        WatermarkLearnCase(name: "只出现两次 → 不够",
                           items: [ReadingOrder.Item(text: "邱某某学园", box: box(0.1, 0.9)),
                                   ReadingOrder.Item(text: "邱某某学园", box: box(0.6, 0.4))],
                           expected: nil),
    ]

    struct WatermarkStripCase: Sendable {
        var name: String
        var line: String
        var watermark: String
        /// nil = 整行都是水印，丢掉。
        var expected: String?
    }

    /// 前四条按真机 evidence 16514 / 4226 的形状造（名字已替换）。
    static let watermarkStripCases: [WatermarkStripCase] = [
        WatermarkStripCase(name: "行尾整串", line: "<>〇 100%④ 邱某 某学园", watermark: "邱某某学园",
                           expected: "<>〇 100%④"),
        WatermarkStripCase(name: "整行都是水印 → 丢掉", line: "邱某 某学园.", watermark: "邱某某学园",
                           expected: nil),
        // 残片：「某学」「某学园」全落在水印字符集里，「邱單某学」四个字里三个落在集合里（0.75 ≥ 0.7）。
        WatermarkStripCase(name: "残片（OCR 错字）也丢", line: "竟23点后免费 某学 某学园 邱單某学",
                           watermark: "邱某某学园", expected: "竟23点后免费"),
        // 反例：只有一半字符落在集合里（「某雅」= 1/2）的短 token 不算残片，保留。
        WatermarkStripCase(name: "重叠只有一半的短 token 不算残片", line: "免费 某雅",
                           watermark: "邱某某学园", expected: "免费 某雅"),
        WatermarkStripCase(name: "水印粘在正文前面 → 剥掉整串留正文",
                           line: "邱某某学园智能会议纪要", watermark: "邱某某学园",
                           expected: "智能会议纪要"),
        WatermarkStripCase(name: "正文里提到组织名但不是水印（字符重叠不到七成）→ 保留",
                           line: "某学园的课程更新了", watermark: "邱某某学园",
                           expected: "某学园的课程更新了"),
        WatermarkStripCase(name: "与水印无关的行原样保留", line: "我：明天 10:15 开会", watermark: "邱某某学园",
                           expected: "我：明天 10:15 开会"),
    ]

    // MARK: - 定点内缩矩形（M2）

    struct WindowInsetCase: Sendable {
        var name: String
        var window: CGRect
        var inset: WindowInset
        var expected: CGRect
    }

    /// 微信实测窗口：1085×846（库里 evidence 4260 反推出来的那一个）。
    static let wechatProbeWindow = CGRect(x: 1601, y: 97, width: 1085, height: 846)

    static let windowInsetCases: [WindowInsetCase] = [
        WindowInsetCase(
            name: "聊天面板：让开侧栏 340 / 标题条 60 / 输入框 180",
            window: wechatProbeWindow,
            inset: WindowInset(left: 340, top: 60, bottom: 180,
                               fallback: RelativeRect(x: 0.22, y: 0.08, width: 0.78, height: 0.70)),
            expected: CGRect(x: 1941, y: 157, width: 745, height: 606)),
        WindowInsetCase(
            name: "会话名：顶部一条，同样让开侧栏",
            window: wechatProbeWindow,
            inset: WindowInset(left: 340, maxHeight: 60, minHeight: 24,
                               fallback: RelativeRect(x: 0.22, y: 0.0, width: 0.78, height: 0.08)),
            expected: CGRect(x: 1941, y: 97, width: 745, height: 60)),
        WindowInsetCase(
            name: "窄窗口：内缩后不够宽 → 退回比例兜底",
            window: CGRect(x: 0, y: 0, width: 500, height: 400),
            inset: WindowInset(left: 340, top: 60, bottom: 180,
                               fallback: RelativeRect(x: 0.22, y: 0.08, width: 0.78, height: 0.70)),
            expected: CGRect(x: 110, y: 32, width: 390, height: 280)),
    ]
}
