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

    /// 飞书：消息列表 AXList，三行——两行在视口内、一行整块在视口上方（未滚动到的历史）。
    /// 每行的子元素是「发送者 / 时间 / 正文」。
    static func feishuTree() -> SyntheticAXNode {
        func row(sender: String, time: String, body: String, y: Double) -> SyntheticAXNode {
            SyntheticAXNode(role: "AXRow", frame: CGRect(x: 120, y: y, width: 1_000, height: 50),
                            kids: [
                                SyntheticAXNode(role: "AXStaticText", value: sender,
                                                frame: CGRect(x: 120, y: y, width: 100, height: 20)),
                                SyntheticAXNode(role: "AXStaticText", value: time,
                                                frame: CGRect(x: 230, y: y, width: 80, height: 20)),
                                SyntheticAXNode(role: "AXStaticText", value: body,
                                                frame: CGRect(x: 120, y: y + 22,
                                                              width: 800, height: 26)),
                            ])
        }
        return SyntheticAXNode(
            role: "AXWindow", title: "飞书", frame: window,
            kids: [
                SyntheticAXNode(
                    role: "AXList", frame: CGRect(x: 120, y: 140, width: 1_000, height: 600),
                    kids: [
                        row(sender: "更早的人", time: "昨天", body: "滚上去的历史消息", y: 20),
                        row(sender: "张三", time: "10:02", body: "M1 第二轮的适配器进度如何", y: 300),
                        row(sender: "我", time: "10:05", body: "规则引擎写完了，正在接 OCR", y: 380),
                    ]),
            ])
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
        RuleCase(name: "飞书：消息列表只取视口内已渲染的行",
                 rule: AdapterRegistry.feishu,
                 tree: feishuTree,
                 expectedFragments: 1,
                 expectedCompleteness: .partial,
                 mustContain: ["张三", "10:02", "M1 第二轮的适配器进度如何",
                               "规则引擎写完了，正在接 OCR"],
                 mustNotContain: ["滚上去的历史消息", "更早的人"],
                 expectedOCRRegions: ["conversation_title"]),
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
}
