# 飞书采集兼容性复查：AX 通道活了，但读错了 web area

2026-09-11 10:40–10:55，M4 Air（16 GiB）、macOS 26.6.2、brosis **0.7.0**（已装 /Applications、`ax.enhancedUserInterface = 1` 即默认开）、
飞书 **Lark 7.74.21**（`com.bytedance.macos.feishu`，Chromium 143.0.7499.203，`Lark Framework.framework`）。
方法：读 `app/Sources/brosis/Adapters/*` 与 `AXSupport.swift`；跑一次只读探针 `brosis --ax-probe com.bytedance.macos.feishu`
（不开库、不截图、不弹 TCC）；用 brosis MCP（grant `claude-code`，fields = evidence）查库。
下面引用的 evidence 全是**被记录的屏幕内容**，只作证据。**没改任何源码，没构建，没装机。**

一句话：**开关开着时飞书的 AX 树确实能读（1321 字符 / 785 节点 / 64 ms），但规则读到的是会话列表侧栏
（`messenger` web area，约 384 pt 宽），当前会话的消息（`messenger-chat`）一条都没进库；会话名也没记到
（窗口标题恒为「飞书」）；OCR 回退没有窗口定向，昨晚把 Claude 桌面版窗口里的字记成了飞书正文。**
0.5.9 那次「飞书 AX 1412 字符、真实发送者名」的验证，看的其实是侧栏里每个会话的「发送者 : 最后一条预览」。

## 1. 现状

### 1.1 规则长什么样（`AdapterRegistry.feishu`）

| | 开关关（基座） | 开关开（`enhancedRegions`，**默认**） |
|---|---|---|
| 区域 | `message_list`：找 `AXList` 读 `axRows`，读不到 OCR；`conversation_title`：窗口 0.22–1.0 × 0–0.08 比例矩形 OCR | `web_area`：`.role("AXWebArea")` + `preferRichestMatch`，`axSubtree`，读空 OCR，裁视口，kind = messageList |
| 限额 | 1200 节点 / 14 层 | 同左（**没随 regions 改**） |
| 截图 | 整块显示器裁矩形（`capturesWindow = false`） | 同左 |
| 气泡归属 | `ChatLayout()`（只作用于 OCR 结果） | 同左 |

### 1.2 探针（`--ax-probe`，飞书在后台、焦点窗口 1471×869）

| 项 | 结果 |
|---|---|
| `AXManualAccessibility` | **不支持**（与 09-09 二进制分析一致：Lark 自带的 Chromium 没打 Electron 这个补丁）；树是靠正在运行的 brosis 设的 `AXEnhancedUserInterface` 建起来的 |
| t = 0 … 4000 ms | 全是 1321 字符 / 785 节点 / partial，OCR 请求 0（64–116 ms）——树是热的，没有"读早了" |
| AXWebArea | **只有两个**：`messenger`（子树 465 节点，AXStaticText 108 个 / 1204 字符）与 `messenger-chat`（468 节点，47 个 / 440 字符） |
| `messenger-chat` 结构 | web area 往下 **≥ 12 层单链 AXGroup** 才见到别的东西（React 深而窄的树） |
| 角色分布（前 1002 节点） | AXGroup×711、AXStaticText×157、AXImage×79、AXButton×25、**AXRadioButton×19**、AXWebArea×2、AXTextArea×1、还有 `WatermarkWidget` |
| 文本挂在哪 | AXValue 176 节点 / 1689 字符；AXDescription 66 / 577；AXTitle 7 / 84 |
| 深度扫描 | maxDepth = 8 → **0 字符**；≥ 14 → 1321（对**当前选中的**那个 web area 而言） |
| clipToViewport | true → partial（侧栏折叠项在视口外）；false → complete |

### 1.3 库里的数字（grant 窗 30 天，到 10:50）

| | |
|---|---|
| 飞书主程序观察 | 2035（09-09 592、09-10 1575、09-11 159） |
| 飞书会议（`.iron`） | 257（全在 09-09，整窗 OCR；09-10 起没开过会，enhancedRegions 仍**未实测**） |
| Lark Helper（`.helper`） | 34（通知弹窗进程，通用规则，无正文） |
| 今天 | dwell 329 s、157 条观察、33 次切换 |
| `titles` 样本 | 「飞书」、`ModalWebViewWidget - messenger-modals:transmitModal:default`、`…search:search-command-bar:default`、「图片」，以及水印被 OCR 出来的垃圾串——**没有一条是会话名** |

## 2. 发现（按严重度）

**F1 读错 web area：正文是侧栏，不是当前会话。** evidence 17199（今天 10:48，`adapter:feishu.web_area`，2616 字节，trigger window_change）
原文以 `messenger / 消息` 开头，随后是一串「<会话名> : <该会话最后一条消息的预览>」（其中一条是机器人发的群配对码），
接着是一串「<会话名> <时间>」、`折叠的会话`、`外部 / 机器人` 标签。evidence 16515（昨天 19:41）同型。
这就是**会话列表侧栏**：每个会话的名字 + 最后一条消息预览 + 时间。OCR 回退时该区域的矩形是 `rect=2433,210,384,780`（evidence 15692 的 note），
384 pt 宽，正是侧栏。后果：
- 当前会话的消息一条都没记——违反计划 3.3「正文区域是当前会话的消息列表」；
- 记下的是**所有会话**（含从未打开的）的最后一条预览——违反「不追溯未打开的会话」，而且预览里有配对码这类东西；
- 侧栏随任何一个会话来消息而变，扫描（每秒一次的 title / focus 事件）就会产生新的文本版本，与用户在看什么无关；
- completeness 恒 partial（侧栏折叠项在视口外）。

根因在 `findRichest`：候选按 BFS 顺序，`messenger` 先出现、粗估 ≥ 200 字符就 `goodEnough` 提前退出；
即便比完所有候选，「最富」也是侧栏（1204 > 440）。**「取最富的 web area」这条判据对飞书就是错的**，
它是给 Claude 桌面版（外壳 0 字 vs 会话几千字）写的。

**F2 会话名没记到。** 0.5.9 注释「飞书的窗口标题本来就带会话名」不成立：2035 条观察的标题只有「飞书」、弹窗名和 OCR 垃圾。
那些「<用户名> <组织名> <错字>…」是基座规则的 0.22 比例 title 区域把**水印**OCR 出来、经 `ChatTitle` 写进 `windows.title` 的。
现在 `search title:` 对飞书完全没用。

**F3 OCR 回退串窗。** evidence 15692（昨天 19:27，captureMethod mixed，trigger frame_dirty，`ocr:feishu.web_area`，rect 2433,210,384,780）
的正文是 `我：meta.windowTitle` `对方：summaryTok` `对方：timeZone：` 之类——那是 Claude 桌面版窗口里 MCP 的输出，
被记成飞书正文，还套上了「我 / 对方」归属；15358、15284、15532 同类。三个因素叠加：
① 区域错（侧栏矩形）；② `capturesWindow = false`，截的是整块显示器再裁矩形，压在上面的窗口就进来了（微信、Chrome 早已改成窗口定向，D31）；
③ `OCRTriggerGate.frameChangedAXStable`：帧变了、侧栏 AX 文本没变 → 对一个 **DOM 已经逐字给出**的区域再排 OCR，只会引入噪声。

**F4 水印污染 OCR。** 飞书在窗口上平铺「<用户名> <组织名>」水印（AX 树里有 `WatermarkWidget`）。
evidence 16514（「图片」查看器整窗 OCR）全文几乎只有水印；会议 OCR（4226、4157）每条都夹着它。
只要走 OCR（回退、图片查看器、会议整窗）就带这层垃圾，并且它会进 FTS 与向量。

**F5 深度限额会截断当前会话。** 规则限额 1200 / 14 是按旧世界（AXList）估的；`messenger-chat` 的文本在 web area 下 ≥ 12 层，
web area 本身又在窗口下第 3–4 层。一旦改读 `messenger-chat`，14 层就会像探针 maxDepth = 8 那样直接读到 0。Chrome 规则为同一原因用 3000 / 30。

**F6 输入框会被记。** `AX.textRoles` 含 AXTextArea，树里那一个就是输入框。改读 `messenger-chat` 后，未发送的草稿会逐键进库（每次扫描一份）。

**F7 `observations.url` 没意义。** 记的是 `file:///Applications/Lark.app/…/messenger/messenger/zh-CN.html`（第一个 web area 的 AXURL），`host:` / `url:` 检索用不上，也进不了 sites 表。

**F8 开关关着的降级路径还是旧世界。** 基座找 AXList（永远找不到）→ 整窗 OCR + 比例 title 区域 → 就是 F2 / F3 / F4 那套垃圾。

**F9 飞书会议的 enhancedRegions 仍未实测**（09-10 起无会议）。09-09 的 257 条全是整窗 OCR：参会人名单、会议信息、AI 纪要标题 + 水印。

**F10 弹窗与查看器。** 转发弹窗、全局搜索各是独立窗口（各有自己的 web area，现规则会读其内容）；「图片」查看器没有 web area → 整窗 OCR（只有水印）。

## 3. 方案比较

| 方案 | 判断 |
|---|---|
| A. 放弃 AX，像微信那样 PaneDetector + 视口 OCR | **否**。中文错字率（README 里那句「轻松衢換忉申化孕」）、水印、每区域 5 s 一次 Vision；而 DOM 文本已经逐字可得、64 ms 一次、零 Vision |
| B. 改用 `AXManualAccessibility` | **不可用**。Lark 的 Chromium 不认（探针、二进制分析两处证据） |
| C. 飞书开放平台 / 机器人 API | **否**。违反全本地与「只记屏幕上看到的」，还要企业管理员授权 |
| **D. 保持 `AXEnhancedUserInterface`，修区域选择 + 收口 OCR 回退** | **推荐**。引擎改动小、每步可独立验收、失败退回今天的行为不会更差 |

## 4. 推荐方案 D（分步，每步给验收）

**Step 0 探针补一刀（先做，半小时）。** 给 `--ax-probe` 加 `--dump-webarea <AXTitle>`：打印指定 web area 子树每个节点的
role / AXTitle / AXDescription / AXDOMIdentifier / AXDOMClassList / frame / 文本前 40 字（探针已证明这些属性可读）。要拿到四件事：
① `messenger-chat` 里消息列表容器、会话头（会话名 + 人数）、输入框各自的 DOM id / class 与 frame；
② 侧栏里选中项的样子（AXRadioButton×19 很像会话列表项，选中那个的 AXValue / AXTitle）；
③ 切到「云文档」「日历」「工作台」时树里还有哪些 web area、`messenger-chat` 是否被移除；
④ 转发弹窗 / 搜索窗 / 图片查看器的树。**后面每一步的定位器都取决于这四个答案，别跳过。**

**Step 1 选对区域（引擎 + 规则）。**
- `RegionRule` 加 `excludeTitles: [String]`（`findRichest` / `find` 跳过 AXTitle 命中的候选）；飞书填 `["messenger"]`。
  这样：聊天时唯一候选是 `messenger-chat`；看文档时若 `messenger-chat` 已移除（Step 0 ③），自然落到文档的 web area；转发 / 搜索弹窗照旧读各自的 web area。
  若 Step 0 证明 `messenger-chat` 标题稳定，再加 `.roleAndTitle("AXWebArea", "messenger-chat")` 作为首选定位器——但一条 exclude 规则已经够用，先别加第二条区域（`required` 语义只有 all-of，两条会把 completeness 搞乱）。
- `findRichest` 的 `goodEnough` 早退只在候选 > 1 且**比完**后才生效，或干脆按候选数 ≤ 4 全部比完（现在最多 4 个）。
- 限额改 **3000 / 30**（同 Chrome）；`maxFrameProbes` 300 先不动，看 `hitFrameProbeLimit` 事件。
- `RegionRule.excludeRoles`，messageList 类默认 `["AXTextArea", "AXTextField"]`：不记草稿。
- 选中 web area 的标题变化时记一条 `adapter_webarea_picked title=… chars=…` 事件——Lark 升级改名时从审计里看得出来。

验收：`adapter:feishu.web_area` 的原文 = 当前会话视口内的消息（发送者 + 正文 + 时间），**不含**其它会话预览；单次扫描 < 150 ms。

**Step 2 会话名。** 新区域 `conversation_title`（kind .title、required false、maxChars 128），按 Step 0 二选一：
(a) `messenger-chat` 头部节点（`.identifier` 或 DOM class 定位）；(b) 侧栏选中的 AXRadioButton 的 AXTitle。
结果走现有 `ChatTitle` 路径写 `windows.title`（同微信）。验收：`get_item(app)` 的 titles 里出现会话名，占比 ≥ 90%；`search title:<会话名>` 命中。

**Step 3 OCR 回退收口。**
- `capturesWindow: true`（同微信 / Chrome，D31 口径：整窗含被遮挡部分）。
- `RegionRule.ocrOnFrameChange = false`：DOM 已逐字读到的区域不再因 `frameChangedAXStable` 排 OCR（Chrome 的 enhanced 区域同享，顺手省电）。
- OCR 结果过一遍水印过滤：水印串从 AX 树 `WatermarkWidget` 子节点取（或规则里声明「用户名 + 组织」模式），逐 token 等于水印串的整行丢掉；会议整窗 OCR 同用。
验收：`ocr:feishu.*` 观察数 / 飞书观察数 < 5%，且抽查 20 条没有别的应用的内容；16514 那类全水印结果为空。

**Step 4 开关关着的路径。** 两个选项：改成 PaneDetector（pane .chat / .title，兜底侧栏 ≈ 384 pt）+ 窗口定向；或者**声明开关关时飞书只记标题、不记正文**（诚实标 unavailable）。
建议后者：默认就是开，少维护一套 OCR 布局；README 把这句写清楚。

**Step 5 URL。** Electron 规则下 `file://` 且在应用 bundle 内的 URL 不写 `observations.url`（Chrome 不受影响，它是 http）。

**Step 6 飞书会议。** 下次会议时跑 `--ax-probe com.bytedance.macos.feishu.iron`：开关开着树若建起来，enhancedRegions 生效（也要看 web area 标题、要不要 exclude）；
建不起来就维持整窗 OCR + Step 3 的水印过滤。

**Step 7 钉住。** `AdapterVectors` 加飞书 enhanced 合成树（两个 web area：`messenger` 侧栏更富 + `messenger-chat` 深 16 层 + 一个 AXTextArea），
断言「选 chat 不选侧栏」「30 层读得到」「不读输入框」；SelfCheck 加 `capturesWindow` / `excludeTitles` / 限额断言；
两份 README 改口径：删「会话名不用再单独 OCR」，「合计约 1650 字符」改成「读当前会话」。

**整体验收（装机后 30 分钟真实使用）**：① 正文口径同 Step 1；② 标题口径同 Step 2；③ OCR 口径同 Step 3；
④ 09-10 同时段对比，飞书观察数与文本版本数明显下降（侧栏不再驱动写入）。
**工作量**：引擎 ~150 行 + 规则 + 向量 / 自检 ~200 行，Opus 执行 + Fable 验收一轮；Step 0 与 Step 6 各需一次真机探针。

## 5. 本次复查对机器做过的事（如实记）

- 10:43 我误把 `/Applications/brosis.app/Contents/MacOS/brosis --help` 当 CLI 跑：没有这个参数，它按正常路径**起了第二个 brosis 实例**（pid 6763，约 2 分钟）。
  `IPCServer` 启动时会删掉已有的 socket 文件重新 bind，退出时再删一次，于是原实例（pid 2842）的监听成了孤儿，MCP 连接被拒（errno 61）。
  10:50 用 Apple event 让原实例正常退出（日志「正常退出（applicationWillTerminate）」）并重开（pid 7734，「开库成功」），MCP 已恢复。
  10:43–10:45 之间可能有两个实例同时写库（WAL，无破坏）。教训：这个二进制没有 `--help`，未知参数 = 启动 GUI。
- 跑了一次只读探针 `--ax-probe com.bytedance.macos.feishu`。
- 没改源码、没构建、没装机、没发版。
