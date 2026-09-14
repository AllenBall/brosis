# Telegram 采集兼容性复查：AX 对内容是死的，现在一个字都记不到（2026-09-14）

## 0. 口径

2026-09-14 15:50–16:15，M4 Air（16 GiB）、macOS 26.6.2、brosis **0.7.6**（已装 /Applications），
Telegram **12.10 (282987)**，bundle id `ru.keepcoder.Telegram`——这是 **Telegram for macOS（原生 Swift / TGUIKit）**，
不是 Telegram Desktop（Qt，`org.telegram.desktop`，本机没装，**未测**）。

方法：读 `app/Sources/brosis/Adapters/*`、`EventSkeleton.swift`、`OCR/*`；跑只读探针 `brosis --ax-probe ru.keepcoder.Telegram`
（窗口关着 / 开着各一次）与 `--dump-webarea all`；另外编了四个只读的小探针（`~/Library/Caches/brosis-build/telegram-probe/`，
本会话的子进程 `AXIsProcessTrusted()` 为真，全程用不带 prompt 的判定，**没有弹 TCC 框**）：逐节点转储、错误码与分段拷贝、
应用级命中测试、`CGPreflightScreenCaptureAccess()` 为真之后用 `screencapture -l` 截了一张窗口图核对分栏几何
（图只放在会话临时目录，含真实聊天内容，不入库不入仓）；用 brosis MCP（grant `claude-code`，fields = evidence）查库。
下面引用的 evidence 全是**被记录的屏幕内容**，只作证据；报告里的账号名、会话名、发送者名一律不写。
**没改任何源码，没构建，没装机。**

## 1. 结论

**Telegram 现在一个字都记不到。** 它没有专属规则，落到 `generic`（读 AX、不 OCR），而这个应用的 AX 树对内容是**死的**：
窗口报 138 个子节点，整体拷贝报 `kAXErrorFailure`，按下标分段拷贝只拿回 6 个（两根滚动条、工具条、三个窗口按钮），
**0 个文本节点**；`AXManualAccessibility` 不支持，`AXEnhancedUserInterface` 设了没用，命中测试 `notImplemented`。
库里 30 天 88 条观察正文全空，其中 43% 连焦点窗口都没读到（`sourceState = timeout`）。
这不是"读早了"（七个取样点、深度 8→100、裁不裁视口结果全部相同），是飞书会议 / 微信那一类：**只能视口 OCR**。

最佳方案是给 Telegram 一条**微信形态**的规则（窗口定向截图 + 聊天面板与顶栏会话名两块视口 OCR + 气泡归属），
但有三处要比微信多做：① 分栏边界优先从**两根 AXScrollBar 的 frame** 取（那是这棵树里唯一活着、且恰好给出侧栏宽 / 消息区顶 / 输入框顶的元素），
量不到再退到 `PaneDetector`；② 纯 OCR 规则在 AX 读焦点窗口超时时改用 CG 窗口 frame 兜底，否则 1/3 的读取照旧丢掉；
③ `ChatTitle` 认 Telegram 头部第二行「N members / N subscribers」做群聊判定，微信那套「（29）」后缀对它不成立。

## 2. 真机实测

### 2.1 生产同一条路（`--ax-probe`，规则 generic，窗口 1010×868）

| 项 | 结果 |
|---|---|
| Chromium 系判定 | none；规则 `generic`（读 AX，`ocrFallback = false`） |
| 窗口关着时 | 「拿不到焦点窗口」——Telegram 关掉窗口后进程还在，`kAXFocusedWindow` 为空 |
| t = 0 … 4000 ms | 全部 **0 字符 / 1 节点 / unavailable，OCR 请求 0**（3–7 ms） |
| `AXManualAccessibility` | 不支持（不是 Electron） |
| 角色分布 | AXWindow×1，就这一个节点；没有 AXWebArea |
| 深度扫描 maxDepth 8→100 | 全 0 |
| clipToViewport true / false | 全 0 |

### 2.2 树到底在不在（自编探针，分段拷贝 + 错误码）

| 项 | 结果 |
|---|---|
| 窗口 `AXChildren` 整体拷贝 | **`failure`**（kAXErrorFailure，不是超时） |
| `AXUIElementGetAttributeValueCount(AXChildren)` | **138** |
| 分段拷贝（16 一段，段失败再逐个） | 成功 **6** 个（下标 0–5），失败 132 个 |
| 拿回的 6 个 | AXScrollBar×2（value 1 / 0）、AXToolbar `[0,0 1010×66]`、关闭 / 缩放 / 最小化按钮 |
| 整棵树 | 18 节点、最深 2 层、45 ms；AXValue 4 节点 / 4 字（滚动条的 0 / 1）；**AXStaticText 0** |
| `AXChildrenInNavigationOrder` | 同样 failure / 138 |
| `AXSections` / `AXContents` / `AXVisibleChildren` | failure / 不支持 / 不支持 |
| 应用 `AXFocusedUIElement` | 永远是窗口本身（输入框从不出现） |
| 应用级命中测试（8 个点：会话列表、搜索框、顶栏、消息区上中下、输入框） | 全部 **`notImplemented`** |
| 设 `AXEnhancedUserInterface = true` | 返回 notImplemented 但值读回 true；1.5 s / 3.5 s 后 children 仍 failure / 138；已复位 false |

解释：138 个子节点是 TGUIKit 自绘视图被"提升"到窗口层的叶子，它们没有实现 NSAccessibility 协议，序列化时整个数组失败；
系统级命中测试摸到的是压在上面的别的窗口（探针陷阱：要用 `AXUIElementCopyElementAtPosition(app, …)`，不能用 system-wide）。
库里的 88 条是 Telegram **在前台**时记的，结果与后台探针一致（0 字），所以"是不是活动应用"不影响结论。

### 2.3 库里的数字（grant 窗 30 天，到 16:12）

| | |
|---|---|
| 观察 | **88** 条（09-10：49，09-11：19，09-14：20）；14 天 dwell 557 s、54 次切换（D2 探针里 0.09 h/天，第 6 名） |
| 正文 | 88 条**全空**；captureMethod 恒 `ax`；completeness = unavailable（读过）/ excluded（失活那条） |
| `titles` | 只有一条：`Telegram @ <账号显示名>`——**没有会话名**，而且带的是用户自己的账号名 |
| 焦点窗口读不到 | **38 / 88 = 43%** 的观察没有标题 = `AX.focusedWindowInfo` 返回 timedOut（消息超时 0.5 s，或窗口刚关掉） |
| 抽 20 条细看 | 12 条读取（app_switch / window_change / ax_notification）里 **4 条超时**；8 条失活里 5 条超时 |
| M0 收尾时 | 6 条，全在权限缺失阶段 |

### 2.4 窗口几何（AX 滚动条 + 截图核对，窗口 1010×868 pt，坐标相对窗口左上）

| 区块 | 位置 | 来源 |
|---|---|---|
| 会话列表（侧栏） | x 0–300，含顶部搜索框、每行「头像 + 会话名 + 最后一条预览 + 时间 + 未读数」，底部 57 pt 标签条 | 侧栏滚动条 `[282,97 19×714]` → 右边界 301；截图分隔线 300 |
| 顶部标题条 | y 0–66 整宽（AXToolbar）；侧栏之上是「Chats」，聊天区之上是**会话头**：第一行会话名，第二行状态（群「N members, M online」/ 单聊「online / last seen …」/ 频道「N subscribers」），右侧搜索与更多按钮各约 60 pt | AXToolbar frame；截图 |
| 置顶消息条 | y 66–101（有置顶时才有，35 pt） | 消息区滚动条顶 101 vs 工具条底 66 |
| 消息区 | x 300–1010，y 101–823；图案壁纸背景；收到的气泡靠左（左侧头像列约 30 pt），群聊气泡**内**首行是彩色发送者名、右上有「admin」标签、右下时间；自己发的靠右（气泡模式） | 消息区滚动条 `[992,101 19×722]`；截图 |
| 输入框 | y 823–868（45 pt，随多行输入变高） | 滚动条底 823 |

**这一组数只是一次快照**：本机默认文字大小、英文界面、没开文件夹侧栏、窗口 1010 宽、有置顶条。
Telegram 的文字大小可以在设置里调，会话列表分隔线可以拖，文件夹侧栏一开左边多一条，窗口窄了会折成单栏——
这些都会让点数变。所以方案里点数只当**第三级兜底**（可用 defaults 校准），第一来源是滚动条 frame（§2.5 实测跟着变）。

### 2.5 改窗口尺寸之后边界跟不跟（AX 写窗口 AXSize / AXPosition，改完已恢复）

| 状态 | 窗口 | 侧栏滚动条 | 消息区滚动条 | 推出的 sidebarRight / titleBottom / composerTop |
|---|---|---|---|---|
| 原状 | 1010×868 | `[282,97 19×714]` | `[992,101 19×722]` | 301 / 101 / 823 |
| 改矮 | 984×700 | `[282,97 19×546]` | `[966,101 19×554]` | 301 / 101 / **655**（输入框高仍 44） |
| 改窄 | 600×834（Telegram 折成**单栏**） | **没有** | `[582,101 19×698]` | — / 101 / 799 |
| 布局瞬态（窗口被系统推到屏幕顶后） | 984×868 | `[282,163 19×648]` | `[966,167 19×656]` | 301 / **167** / 823——整块内容下移了 66 pt，滚动条照样跟着 |
| 恢复 | 1010×868 | `[282,97 19×714]` | `[992,101 19×722]` | 301 / 101 / 823 |

另外两件事：① **子节点下标不稳定**——同一个窗口三次计数 138 / 207 / 156，可拷的 6 个元素从 #0–5 挪到了 #151、#202–206；
按下标分段拷贝要**从尾部倒着扫**，找齐两根滚动条就停：双栏时 56 次调用 53–81 ms，单栏时扫完 156 个 66 ms，上限 300 次。
② 文字大小滑块**没试**（Telegram 的 AX 是死的，没法用 AX 动作改设置；驱动它的界面要用别的工具）。但滚动条 frame 就是滚动视图的边，
字号变了行高、输入框高、置顶条高都跟着变，边界仍从 frame 来，结构上不依赖字号；这一点留到 Step 5 的缩放矩阵里验。

## 3. 发现（按严重度）

### F1（P0，已真机复现）一个字都不记

链条：没有专属规则 → `generic` → `ocrFallback = false` → AX 0 字 → `unavailable` → 不排 OCR。
与 2026-09-09 飞书会议 / Codex / ZCode / LM Studio 那一批「完整 0 · 部分 0」是同一条路。
根因在应用侧：TGUIKit 自绘视图不实现无障碍，窗口 138 个子节点整体拷贝失败（§2.2），分段也只救回滚动条和按钮。
两个私有 / 公开属性都无效。**AX 通道对内容是死的，与飞书会议同级**，不是 Claude 桌面版那种"读早了"。

### F2（P1）1/3 的读取连焦点窗口都拿不到，改成 OCR 之后这部分照旧丢

88 条里 38 条没有标题，即 `AX.focusedWindowInfo` 超时或窗口不存在；抽样的 12 条读取里 4 条如此。
`EventSkeleton.record` 只有 `windowElement != nil` 才跑 `AdapterEngine.scan`，OCR 请求就是在 scan 里生成的，
所以即便规则声明了 `.ocr`，这些帧也不会 OCR，而且 `coordinator.clearContext` 会把上下文清掉。
微信同样暴露在这条路上（M0：6 条里 2 条超时），只是没人量过。0.5 s 的消息超时对刚激活、正在重绘的 Telegram 太紧。
注意两种情况混在一个字段里：真超时，与"用户 ⌘W 关掉窗口、进程仍在前台"——后者 Telegram 尤其常见（关窗不退出）。

### F3（P1）会话名没记到，标题里记的是用户自己的账号名

窗口标题恒为 `Telegram @ <账号显示名>`，`windows` 表只有这一行，`search title:` 对 Telegram 完全没用。
会话身份只在顶栏会话头（§2.4）。而且 Telegram 群的人数不是「（29）」后缀，是第二行「5,107 members, 338 online」这种：
`ChatTitle.memberCount` 认不出 → `isGroup = false` → `BubbleAttribution` 的昵称那一支不执行 →
群聊里气泡内首行的发送者名会被当成独立消息入库（M2 之前微信的那个老毛病原样回来）。

### F4（P2）走 OCR 之后必须窗口定向，否则压在上面的窗口会混进来

`generic` 的 `capturesWindow` 是 false（截整块显示器再裁矩形）。飞书复查 F3 那种"别的窗口的字记成本应用正文"会原样重现。
微信 / Chrome / 飞书早已改成 `desktopIndependentWindow`（D31 口径：整窗含被遮挡部分）。

### F5（P2）侧栏预览、置顶条、壁纸

- 侧栏每行带**别的会话**的最后一条预览，OCR 区域必须把 x < 300 整块排在外面（飞书 F1 的教训：记了所有会话的预览，违反「不追溯未打开的会话」）。
- 置顶消息条每帧都在，包进聊天面板就每次都多一行同样的字；用消息区滚动条的顶边（101）当面板顶就自然排除。
- 消息区背景是图案壁纸，Vision 可能认出低置信度的碎字；现有 `lowconf` 过滤在，但要在首轮真机跑里看比例。

### F6（P2）分栏边界有比图像检测更准更便宜的来源

两根 AXScrollBar 是这棵树里唯一活着的内容元素，frame 直接给出：侧栏右边界（侧栏滚动条 maxX）、消息区顶（消息区滚动条 minY）、
输入框顶（消息区滚动条 maxY）；用户拖动分栏、出现 / 消失置顶条、输入框长高都会跟着变。代价是一次分段拷贝（实测 45 ms 拿完整棵树）。
`PaneDetector` 在图案壁纸上能不能量准还没试；把它降成第二来源，点数常量降成第三来源。
§2.5 实测：改高、改窄、布局瞬态三种情况边界都跟着 frame 走；窗口窄到折成单栏时侧栏滚动条消失，只剩消息区那根——规则要把
「只有一根、且贴着窗口右缘」认成单栏（sidebarRight = 0）。下标不稳定，要从尾部倒扫。
**未验**：列表短到不用滚动时滚动条元素还在不在；文字大小滑块。

### F7（P3）其它窗口与形态

- 媒体查看器、通话窗、机器人小程序（WKWebView，会出现 AXWebArea，`generic` 的 BFS 反而能读到点东西）、设置页（在主窗口内）——都没探。
  窗口定向截图取面积最大的那个，媒体查看器全屏时会用聊天面板的内缩矩形去 OCR 一张图片，出来是垃圾；Step 0 要把这些窗口的标题列出来。
- Telegram 有「气泡 / 经典」两种聊天外观，经典模式所有消息靠左，左右归属失效。
- 本机 Telegram 界面是英文；中文界面的头部第二行文案（「位成员」「订阅者」）要一起认。
- Telegram Desktop（Qt）没装、没测；Qt 自绘的消息列表大概率同样是空树，但**别照搬这条规则的内缩值**，它的布局不一样。

## 4. 方案对比

| 方案 | 判断 |
|---|---|
| A. 把 `generic` 的 OCR 回退对所有原生应用打开 | **否**。0.5.x 明确只对 Chromium 系放开：原生应用 AX 空通常就是真没内容，全面开会给每个原生应用烧 Vision |
| B. 修 AX：分段拷贝 / 等树建好 / `AXEnhancedUserInterface` / `AXManualAccessibility` | **否**。分段拷贝实测只救回 6 个非文本元素；两个属性一个不支持一个无效；七个取样点全 0，不是等的问题 |
| C. Telegram Bot API / TDLib / 本地会话导出 | **否**。不是屏幕上看到的、要登录凭据、会追溯未打开的会话，违反 3.3 与全本地口径 |
| **D. 微信形态视口 OCR 规则 + AX 滚动条定边界 + 超时兜底** | **推荐**。规则是纯数据、可单测；引擎三处改动都对微信同样有益；失败退回今天的行为（0 字）不会更差 |

## 5. 推荐方案 D（分步，每步给验收）

**Step 0 探针补一刀（先做，半小时）。** `--ax-probe` 对非 Chromium 应用打印窗口 `AXChildren` 的**错误码与计数**（现在只打"1 节点"，
分不出"真空"和"拷贝失败"），整体失败时按下标分段拷并打出拿回的元素；`--dump-webarea` 顺带列出该应用**所有**窗口的标题 / frame
（媒体查看器、通话、小程序开着时各跑一次，F7 用）。

**Step 1 规则 `AdapterRegistry.telegram`。** `bundleIDs = ["ru.keepcoder.Telegram"]`（Telegram Desktop 等探过再加），`electron: false`，
`capturesWindow: true`，`chatLayout: ChatLayout()`，限额 300 / 6（反正读不到）。两个区域，全部 `read: .ocr`：
- `chat_panel`（`.messageList`，`pane: .chatPanel`）：`insetRect(left 300, top 101, bottom 45, minWidth 240, minHeight 120, fallback RelativeRect(0.30, 0.08, 0.70, 0.84))`；
- `conversation_title`（`.title`，`pane: .conversationTitle`，`required: false`，`maxChars: 256`）：`insetRect(left 300, right 120, maxHeight 66, fallback RelativeRect(0.30, 0, 0.58, 0.08))`。
三个点数走 `defaults`（`adapter.telegram.sidebarWidth / titleBarHeight / composerHeight`，默认 300 / 66 / 45），`paneFallback` 同一组。
**这组点数只是第三级兜底**（§2.4 的快照说明）：字号、拖栏、文件夹侧栏、单栏都会让它偏，正常路径是 Step 2 的滚动条边界。
`PaneLayout` 只有一个 `titleBottom`，取消息区顶（有置顶条 101、没有 66）：标题矩形会连置顶条一起框进来，但 `ChatTitle.resolve` 取第一行，会话名不受影响。

**Step 2 分栏边界先问 AX 滚动条（引擎，约 80 行）。** `PaneLayout.Source` 加 `ax`；协调者在 `PaneDetector` 之前，对声明了 pane 角色的规则做一次
窗口子节点**从尾部倒着**逐个拷贝（整体拷贝对它必失败；下标不稳定，可用元素这次在 #151 与 #202–206，上次在 #0–5），
找齐两根 AXScrollBar 就停，上限 300 次调用（实测双栏 56 次 / 53–81 ms，单栏 156 次 / 66 ms），取 AXScrollBar：
右边贴着窗口右缘（≤ 24 pt）的是消息区 → `titleBottom = minY − 窗口 minY`、`composerTop = maxY − 窗口 minY`；
右边在窗口中线左侧的是侧栏 → `sidebarRight = maxX − 窗口 minX`。
只找到一根、且贴着窗口右缘 ⇒ 单栏（sidebarRight = 0，聊天面板从窗口左缘起）；只找到侧栏那根 ⇒ 整组作废。
合理性：侧栏 200–600、titleBottom 40–260、composerTop > titleBottom + 100，不合理就整组作废退给 `PaneDetector`。
结果按窗口 frame 缓存：窗口 frame 没变就沿用，变了才重扫（改尺寸、拖栏、置顶条出现都会改滚动条 frame，但拖栏不改窗口 frame——所以每次 OCR 前仍要重扫，只是 5 s 限流已经把频率压住了）。
`AX.children` 顺手加同一套分段拷贝（`kAXErrorFailure` 时），Telegram 之外不会触发。
验收：拖动分栏 / 出现置顶条 / 输入框长高 / 改字号之后 `pane_layout` 事件里 source = ax 且三个数跟着变；窄窗单栏时 sidebarRight = 0；
列表短到没滚动条时退到 detected / defaults 而不是空矩形。

**Step 3 纯 OCR 规则的超时兜底（引擎，约 60 行）。** `EventSkeleton.record` 里 `windowElement == nil` 且 `!rule.readsAX` 且权限正常时，
不再直接跳过：从 CG 窗口表取该 pid 面积最大的 layer 0 在屏窗口 frame（`CaptureController.pickTarget` 已经在枚举同一批候选），
用 `SyntheticAXNode(role: "AXWindow", frame:)` 跑 `AdapterEngine.scan`，OCR 请求照常生成；`sourceState` 照记 `timeout`（诚实），
标题用上一次的会话名（协调者已有 `lastConversationTitles`）。微信同享。
验收：Telegram 读取观察里"有正文"的比例 ≥ 80%（今天是 0%，F2 那 1/3 是上限损失）。

**Step 4 会话名与群聊判定。** `ChatTitle` 加第二种群信号：任一行匹配 `^\d[\d,]* ?(members|subscribers|位成员|订阅者)`（Telegram），
保留微信的「（29）」；display 取第一行。`AdapterVectors.chatTitleCases` 加英文 / 中文群、频道、单聊（online / last seen）、机器人（bot）各一条。
群聊气泡内首行发送者名与右侧「admin」标签同一行，OCR 可能拼成「某某 admin」：昵称清洗时去掉行尾的 `admin` / `管理员` / `owner` / `群主`，加向量用例。
验收：`get_item(app)` 的 titles 里会话名占比 ≥ 90%，群聊观察的发送者不再是清一色「对方」。

**Step 5 首轮真机看三个比例 + 一个缩放矩阵。** 装机后正常用 30 分钟：① `lowconf` 丢弃比例（壁纸碎字）；② `ocr:telegram.chat_panel` 抽 20 条，
没有侧栏预览、没有别的应用的内容；③ 每小时 Vision 次数（帧频 12 s + 每区域 5 s 限流两道都在，口径同飞书会议）。超标就调 `capture.ocrMinInterval`。
缩放矩阵（每格看 `pane_layout` 事件的 source 与三个数，再抽一条 OCR 看区域对不对）：文字大小最小 / 默认 / 最大 × 分隔线拖到最窄 / 最宽 ×
文件夹侧栏开 / 关 × 置顶条有 / 无 × 窗口双栏 / 单栏。字号是唯一这次没在真机上动过的变量，矩阵里优先跑它。

**Step 6 钉住。** `AdapterVectors.telegramTree()`：窗口 + 两根 AXScrollBar + AXToolbar、无文本，断言「规则命中 telegram、AX 0 字、恰好两个 OCR 请求、矩形 = [300,101 710×722] 与 [300,0 590×66]」；
滚动条定边界的三个用例（正常 / 缺一根 / 数值不合理 → 退回）；`WindowInsetCase` 加 1010×868 窗口；`SelfCheck` 规则表断言 `capturesWindow`、pane 角色、`paneFallback`；
README 两份的规则表加 Telegram 一行，口径写清：只记屏幕上显示的文字、不追溯未打开会话与未滚动到的历史、语音只记 [语音]、
气泡模式左 = 对方右 = 自己、经典模式归属不可靠、Telegram Desktop 未适配。

**整体验收（装机后 30 分钟真实使用）**：① 正文口径同 Step 1 / 5；② 标题口径同 Step 4；③ 超时口径同 Step 3；
④ 与 09-10 同时段对比，Telegram 观察数不变（不新增写入源），有正文的观察从 0 变成 ≥ 80%。
**工作量**：规则 + 向量 / 自检约 250 行，引擎三处约 200 行，Opus 执行 + Fable 验收一轮；Step 0 与 Step 5 各一次真机。

## 6. 未验与局限

- 探针都是在 Telegram **后台**（`open -g` 重开窗口）跑的；前台的结论靠库里 88 条前台观察间接支撑，没有前台再跑一遍分段拷贝。
- 滚动条元素在列表不需要滚动时是否仍存在（F6）；**文字大小滑块**没动过（改设置要驱动 Telegram 的界面，这次没做）。
- `PaneDetector` 在图案壁纸上的表现；OCR 在壁纸上的碎字比例（Step 5 才知道）。
- 43% 的"超时"里真超时与"窗口刚关掉"各占多少（F2）。
- 媒体查看器 / 通话 / 小程序 / 设置 的窗口形态（F7）；经典聊天模式；中文界面文案；Telegram Desktop（Qt）。

## 7. 本次复查对机器做过的事（如实记）

- 15:58 `open -g -a Telegram`：Telegram 当时在跑但没有窗口，用它在**后台**重开主窗口，没有激活它；窗口留着没关。
- 跑了两次 `--ax-probe ru.keepcoder.Telegram` 与两次 `--dump-webarea all`（只读，dist-app 构建目录里的二进制）。
- 在 `~/Library/Caches/brosis-build/telegram-probe/` 编了 5 个小探针（axcheck / axdump / axprobe2 / axprobe3 / sccheck）并各跑一次。
  只有 axprobe2 写过一个属性：给 Telegram 设 `AXEnhancedUserInterface = true` 约 4 s，随后复位为 false（两次调用都返回 notImplemented，但值确实翻转了）。
- `CGPreflightScreenCaptureAccess()` 为真后用 `screencapture -l <窗口 id>` 截了一张 Telegram 窗口图，只在会话临时目录（`/private/tmp/claude-501/…/scratchpad/telegram_window.png`），含真实聊天内容，没复制到别处，可删。
- 16:07–16:09 库里多了 5 条 Telegram 观察（33832–33841，有标题、正文仍空）：可能是用户自己在用，也可能是探针发的 AX 调用触发了通知。
- 16:2x（用户问"界面能调大调小，几何是不是不通用"之后）用 AX 写过 Telegram 窗口的 AXSize / AXPosition：先后设成 1400×700、800×900、984×700、600×868
  （Telegram 各自夹成 1400×700、800×900、984×700、600×834），期间窗口一度被系统推到屏幕右上角 (3046,30)、宽度被屏幕右缘夹成 984；
  最后按 15:58 的值恢复成 (2666,293) 1010×868，三条边界回到 301 / 101 / 823。又截了两张窗口图（984 宽、600 宽，同样只在会话临时目录）。
  截图里看到窗口处于「7 messages selected」的多选状态——探针只读属性、写过尺寸与位置，**没有发过任何点击或按键**，那不是探针造成的；
  如果用户当时正在用 Telegram，这几次改尺寸、挪位置会打断操作，这是本次复查最该道歉的一件事。
- 没改源码、没构建、没装机、没发版、没动 `docs/`。

## 8. 实施（0.7.7，2026-09-14 17:1x，已装机、未提交）

按 `~/.claude/plans/parsed-popping-hickey.md`（用户已审核）实施，评审子代理的六条修正都吸收了：

| 改动 | 落点 |
|---|---|
| 规则 `telegram`：两块 `.ocr` 区域（`chat_panel` / `conversation_title`）、窗口定向、点数兜底 300 / 66 / 45（`adapter.telegram.*` 可校准）、`paneSource: .axScrollBars`、`windowTitleIsConstant`、`ChatLayout(inlineMetaInBubble: true)` | `Adapters/AdapterRegistry.swift`；微信同时标 `windowTitleIsConstant` |
| 分栏边界从 AX 滚动条算：`AX.ScrollBarProbe`（先头 8 个再从尾往前逐个拷、墙钟封顶 100 ms、遇 cannotComplete 即停、按 pid 缓存元素只重读 frame）+ 纯函数 `PaneLayout.fromScrollBars`（右半边候选按贴边 / 高度排序，过"下面必有输入框"那关；单栏按窗口宽 < 720 判；宽窗只剩一根 → 侧栏用兜底、`.partial`） | `AXSupport.swift`、`OCR/PaneLayout.swift`；`EventSkeleton.record` 扫描后算、经 `Context.paneLayout` 交给协调者；协调者对 `.axScrollBars` 规则**不跑** `PaneDetector` |
| AX 超时兜底：`AX.onScreenWindowFrame`（CG 窗口表 + `pickTarget` 最小边 400）；`EventSkeleton.shouldReadText` 抽成纯函数，纯 OCR 规则拿到 frame 时允许 `timedOut`；扫描用只有 frame 的 `SyntheticAXNode`；`sourceState` 照记 timeout | `EventSkeleton.swift`、`CaptureController.pickTarget(minSide:)` |
| 恒定标题：AX 观察用协调者上一次认出的会话名当 `windows.title` | `EventSkeleton.swift`、`CaptureCoordinator.lastConversationTitle` |
| `ChatTitle.isGroupStatusLine`（「N members / 位成员」判群，subscribers 不判）；`BubbleAttribution.stripTrailingMeta / stripRoleTag`；`inlineMetaInBubble` 时按行带左缘判侧 | `Adapters/BubbleAttribution.swift` |
| 探针：非 Chromium 应用打印 `AXChildren` 错误码 / 计数 / 按下标拿回的滚动条 / 推出的边界 | `AXProbe.swift` |
| 向量与自检：`telegramTree`、规则用例、9 条滚动条边界、7 + 6 + 9 条元信息 / 标签 / 群状态行、7 条读取判定 + 五道门 + 最小边、6 条 Telegram 会话名、2 份气泡布局、2 条内缩矩形；`layouts.count == 2` 改成动态 | `Adapters/AdapterVectors.swift`、`SelfCheck.swift`；闸门 268 → **273 项全 PASS** |
| 文档与版本 | 两份 README 第 211 段；`BuildInfo.version = 0.7.7` |

构建：`app/build_app.sh` 零 error、闸门 273 项 PASS；公证 `notarize-171558`（Accepted、已 staple、spctl `Notarized Developer ID`）；
17:18 装机（旧 0.7.6 在 `installed-backup/brosis-0.7.6M1-20260914-171808.app`），新实例开库正常。

**装机前用新包跑探针**（`--ax-probe ru.keepcoder.Telegram`，Telegram 在后台、窗口 1010×868）：规则 `telegram`、七个取样点 **OCR 请求 2 个**、
窗口 `AXChildren` 整体拷贝 `-25200`、计数 116、按下标 65 次 34 ms 找到两根滚动条 `[282,97 19×714]` `[992,61 19×762]`，
边界 `sidebar=301 title=61 composer=824 source=ax`（这次会话头下没有置顶条，所以 title 是 61 不是 101——正是"边界跟着 frame 走"）。

**待真机验收**（§5 Step 4 / 5 的口径，需要用户正常用 Telegram 30 分钟后再查）：`ocr:telegram.chat_panel` 正文、`titles` 里的会话名占比、
超时观察是否带 OCR 正文、`pane=… source=ax` 占比、lowconf 比例、缩放矩阵（字号优先）。已知一处未进这次包的改动：探针直接调 `scan()` 时标签误显示 `cached`，
源码已改一行（`rescanned = true`），下次构建带上。

### 8.1 /simplify 清理（同日 17:4x，重新构建 + 公证 `notarize-174652` + 装机，闸门仍 273 项全 PASS）

四个视角（复用 / 简化 / 效率 / 层次）并行审这 12 个文件的 diff，去重后修了这些：
- **层次**：`paneSource` 并进 `PaneFallback.source`（有来源必有兜底，两个消费者不再各查一遍）；删掉 `windowTitleIsConstant`——AX 路无条件 `axConversationTitle ?? 协调者上次会话名 ?? 窗口标题`，缓存只由 `.title` 区域的 OCR 写入，没有那种区域的规则拿到的永远是 nil，行为不变；超时兜底挑窗先按上一次扫描的焦点窗口矩形认（`preferredFrame`），400 pt 最小边只作后手。
- **复用**：探针与采集端共用 `PaneLayout.fromScrollBarProbe`（结果 → 边界 → 日志一行）；`onScreenWindowFrame` 挪到 `CaptureController` 与 `targetWindow` 并列；`[x,y w×h]` 统一成 `CGRect.axLabel`；两个"从尾弹词"合成 `droppingTrailingTokens`；`telegramPaneFallback` 用 `PaneFallback.layout(windowHeight:)` 算；`resolvePoints` 三元组只算一次（`telegramPanes`）。
- **简化**：`fromScrollBars` 先转窗口局部坐标、单一返回；`ScrollBarProbe.Result` 平行数组改成元组、`rescanned` 只在 `scan` 里设；`Band` 删掉没人读的 `minX / midX`；`isGroupStatusLine` 用 `drop(while:)`；超时兜底的门直接复用 `shouldReadText` 纯函数（不再手抄一遍状态清单，顺带把 `collectText / readsContent` 挡在 CG 枚举之前）；自检三段 `filter+map` 改 `compactMap`，读取判定用例带全六道门（12 条）并删掉手写的 `gateOpen`，挑窗最小边并进 12.10d 的 `expectPick` 表（发现原先拿 600×500 的图片查看窗当"不够大"是错的，改成 300×300 的小面板），Telegram 的逐字段 x==x 断言换成跨规则不变量（声明滚动条来源的规则必须有 pane 区域）。
- **效率**：边界按 pid 缓存 5 s（与 OCR 每区域限流同一口径，不再每条观察都发 AX）；每个下标一次 `AXUIElementCopyMultipleAttributeValues` 拿 role + frame（原来三次）；缓存元素与拷回的子元素也设 0.1 s 超时；扫到更少时保留旧缓存；`stripRoleTag` 只对群聊非自己的行算。
- **跳过**（记下理由）：`AX.children` 整体失败时自动按下标回退——对未知应用是每个失败容器上百次跨进程调用，主线程风险，保持规则显式声明；`inlineMetaInBubble` 拆成"判侧方式 + 词表字段"——现在只有一个使用者，拆开是提前抽象；`focusedWindowInfo` 自己补 CG frame——会改所有应用超时时的行为，超出本轮；协调者里 `rule(for:)` 二次解析与热路径日志字符串——量小，既有模式。

装机后再探针（用户已把 Telegram 窗口关掉，探针先报「拿不到焦点窗口」；`open -g` 在后台重开一次后）：规则 `telegram`、OCR 请求 2 个、子节点计数 160、按下标 65 次 49 ms 找到两根滚动条（`CopyMultipleAttributeValues` 那条路）、边界 `sidebar=301 title=61 composer=824 source=ax`，标签正确显示 `rescan`。
