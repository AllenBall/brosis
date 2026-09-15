# ChatGPT 采集兼容性复查：AX 不是死的，是「戳一下才建、建好又被 12 层截断」（2026-09-15）

## 0. 口径

2026-09-15 15:30–15:45，macOS 27.0（Darwin 27.0.0，当天刚升级），brosis **0.7.7**（已装 /Applications，`ax.enhancedUserInterface` 默认开），
ChatGPT **26.908.70816**（bundle id `com.openai.codex`，`/Applications/ChatGPT.app`，15:30 刚经 Sparkle 自更新、15:31:13 重启）。
它已经**不是**当年那个原生 Swift 的 ChatGPT：内核是 `Codex Framework.framework`（**Chromium 152**，非 Electron，
渲染 / GPU / 网络子进程叫 `Codex (Renderer)` / `Codex (Service)`），UI 是 Codex 桌面应用（侧栏「新对话 / Pull Request / 定时任务 / 插件 / 探索 / 项目」，
会话视图里是 ChatGPT 对话）。`CFBundleURLTypes` 把 `http/https` 与自有 `codex` 混在一条里，所以 `bundleHandlesWebLinks` 判它**不是浏览器**——这是对的，它也不该拿 Chrome 规则。

方法：读 `Adapters/*`、`EventSkeleton.swift`、`AXSupport.swift`、`OCR/OCRTrigger.swift`；跑生产探针 `brosis --ax-probe com.openai.codex`（含 `--dump-webarea all`）三次；
自编四个只读探针（`~/Library/Caches/brosis-build/chatgpt-probe/`：`axgpt` 逐节点转储、`axgpt2` 命中测试与属性表、`axgpt3` 容器骨架、`axpoke` 激活验证），
本会话子进程 `AXIsProcessTrusted()` 为真，全程没弹 TCC 框；用 brosis MCP（grant `claude-code`，fields = evidence）查库；
Chromium main 分支源码 `content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm`、`content/browser/accessibility/browser_accessibility_state_impl.cc`。
引用的 evidence 全是**被记录的屏幕内容**，只作证据；报告里不写会话标题、项目名、账号名。**没改任何源码，没构建，没装机。**

## 1. 结论

**ChatGPT 现在基本记不到东西，但原因不是 AX 死了，而是三件事叠在一起：**

1. **网页无障碍树是「戳一下才建」的。** Chromium（macOS 14+，`kSonomaAccessibilityActivationRefinements`）在无障碍模式未启用时，
   网页内容视图 `isAccessibilityElement = false`、不出现在 `AXChildren` 里；只有 AX 客户端**命中测试拿到这个视图、再问它的 `AXRole`**，
   才会 `CreateScopedModeForProcess(kAXModeBasic)` 把树建起来。brosis 的 BFS 走到 `ContentsContainerView` 就没有子节点了，永远碰不到这个开关。
   `AXManualAccessibility` 不支持（-25205，不是 Electron）；`AXEnhancedUserInterface` set 返回 notImplemented（-25208）但值会翻成 1（与 Telegram 复查同款现象）。
   本机实测：激活后 0–4000 ms 七个取样点全是 11 节点外壳；约 2–3 分钟后树自己出现（415 节点、1 个 AXWebArea、39 个 AXStaticText）。
2. **树建好之后，通用规则的 12 层深度上限把它整个截掉。** AXWebArea 在窗口下第 7 层，正文文本在第 17–21 层。生产规则 `generic_chromium`（1500 节点 / 12 层）
   在树建好后 t=0…4000 ms 只读到 **7 字 / 23 节点**（那 7 个字是 web area 的标题「ChatGPT」）；maxDepth 30 才读到 304 字（裁视口）/ 796 字（不裁）。
3. **7 字不等于 0 字。** `noteAXOutcome` 只在 `chars == 0` 时排重扫，`OCRTriggerGate` 只在 `axEmpty` 时因回退而 OCR。读到 7 字的那一刻起，
   这个进程被记成「已热」，既不再重扫，也不再因 AX 空而 OCR——只剩 `frame_dirty` 触发的整窗 OCR（置信度 0.59–0.67、`lowconf=1`，侧栏会话列表与正文的行互相串）。

库里 30 天 **41 条**观察：**0 条**带 AX 正文，4 条 OCR 整窗正文，其余全空（`unavailable` / `excluded`，其中 5 条 `sourceState = timeout`）。

**最佳方案是一条专属规则 `chatgpt`，形态介于 Claude 桌面版与 Chrome 之间**：读唯一的 AXWebArea 里的 `AXLandmarkMain`（主内容区，自动排除侧栏），
`excludeRoles` 掉输入框，限额 3000 / 30，OCR 回退矩形跟主区走、窗口定向截图；再加一件通用的事——
**Chromium 系应用读到「有 web 内容容器但它没有子节点」时，做一次命中测试 + 读 AXRole 把树戳起来**，随后靠已订阅的 `AXLoadComplete` 重扫。
这两步不需要新机制：规则字段全都有，戳树是 `EventSkeleton.noteAXOutcome` 里加两条 AX 消息。

## 2. 真机实测

### 2.1 生产同一条路（`--ax-probe`，规则 `generic_chromium`，窗口 1470×868）

| 时刻 | 结果 |
|---|---|
| 15:33，应用被隐藏（Cmd+H） | 「拿不到焦点窗口」——`AXWindows` 为空、`AXFocusedWindow` noValue；CG 窗口表里主窗口在，`onscreen=false` |
| 15:35，`open -a` 后立刻 | 树 **11 节点**：AXWindow → RootView → NonClientView → NativeFrameViewMac → ChromeNodeClientView → View → **ContentsContainerView（0 子节点）** + 三个窗口按钮；没有 AXWebArea；t=0…4000 ms 全部相同 |
| 15:39，树建好后 | t=0…4000 ms 全部 **7 字符 / 23 节点 / partial（仍被深度截断）**，OCR 请求 0 个；AXWebArea 有，`URL=app://-/index.html`，子树 404 节点、39 个 AXStaticText / 744 字符 |
| 深度扫描（节点上限 20000） | maxDepth 8 → 7 字；14 → 7 字；20 → 7 字；**30 → 304 字 / 245 节点**；40 / 60 / 100 → 同 30 |
| `clipToViewport` | true：304 字 / 245 节点；false：796 字 / 416 节点 / complete |
| 文本挂在哪 | AXValue 43 节点 / 752 字；AXDescription 131 节点 / 1292 字（按钮的 aria-label：「隐藏侧边栏」「通知」这类，**不该收**）；AXTitle 17 / 112 |

### 2.2 树何时出现（自编探针，与 Chromium 源码对照）

| 时刻 | 动作 | 结果 |
|---|---|---|
| 15:35:3x | `axgpt`：枚举 AXWindows，BFS | 12 节点、0 文本；`AXEnhancedUserInterface` 读回 **0**（brosis 没给它设——`generic_chromium` 没有 `enhancedRegions`，`wantsEnhanced = false`） |
| 15:36 | `axgpt --set-enhanced`：设 `AXEnhancedUserInterface = true` | set 返回 **-25208 notImplemented**；1.5 s 后仍 11 节点 |
| 15:35:46–56 | brosis 自己的扫描（库 43091–43098） | 0 字 → 重扫 1.5 s / 5 s → 仍 0 → 15:35:53 整窗 OCR（43096，置信度 0.60） |
| 15:38 | `axgpt2` | **415 节点**、1 个 AXWebArea；`AXEnhancedUserInterface` 读回 **1**；`AXIsAttributeSettable` = true；命中测试：侧栏 → AXStaticText（会话列表项）、主区 → `AXGroup/AXLandmarkMain`、输入框 → `AXGroup ._ComposerLayoutBody_…` |
| 15:39 | `axgpt` | 415 节点 / 40 文本节点 / 749 字，42 ms |
| 15:40 | `axgpt3` | 「no window」——用户又把它隐藏了 |

15:36–15:38 之间发生了两件事，分不开哪件是触发：① 私有属性的值翻成了 1（set 报 notImplemented 但生效，Telegram 复查见过同款）；② 用户点了这个窗口（窗口从 (2424,188) 挪到 (225,83)）。
Chromium 源码给出的**确定**触发是：`RenderWidgetHostViewCocoa.accessibilityHitTest:` 在根元素为空时返回视图自己，随后任何人问它 `accessibilityRole` 就 `CreateScopedModeForProcess(kAXModeBasic | kFromPlatform)`。
用户点进网页时 AppKit 会算焦点元素、问它的 role，走的正是这条；brosis 的 BFS 只问 `AXChildren`，碰不到它。
另外 `BrowserAccessibilityStateImpl` 会在 WebContents **隐藏 5 分钟（±20 s）** 后撤掉模式（`kDisableDelay`），所以「每次从隐藏切回来都可能要重新戳」是常态，不是偶发。

### 2.3 DOM 结构（Codex 应用首页视图，窗口 1470×868，坐标相对窗口）

| 区块 | 定位 | 备注 |
|---|---|---|
| AXWebArea | 窗口下第 7 层，整窗 [0,0 1470×868]，`AXTitle=ChatGPT`、`AXURL=app://-/index.html` | 一个窗口只有这一个 web area，不必挑 |
| 侧栏（会话列表 + 项目 + 导航） | x 0–276；文本在第 17–21 层，class 含 `sidebar-item`（40 个）、`group/cwd`、`_viewport_…` | 会话名是 AXStaticText，一条 16 pt 高；「展开显示」折叠的那些是 **0 pt 高**的 AXStaticText（第 17 层，frame [241,905 259×0]），现有「文本节点 < 2 pt 视为未渲染」口径正好把它们剪掉 |
| 主内容区 | **`AXGroup` subrole `AXLandmarkMain`**，[276,95 1194×822]；class 含 `[container-name:home-main-content]`、`@container/left-panel` | `<main>` 元素，标准 landmark；侧栏收起时它应从 x=0 起——用 landmark 定位不依赖点数 |
| 输入框 | `AXTextArea`（ProseMirror）[742,851 712×44] + 占位文本；外层 `_ComposerLayoutBody_…`；模型 / 权限下拉是 `_ComposerDropdownLabelValueContent_…` | `excludeRoles: ["AXTextArea"]`；下拉的标签会以 AXStaticText 进正文（「完全访问」这类），可用 `pruneClasses` 剪 `_ComposerLayoutBody_` 前缀——**现有 `pruneClasses` 是全等匹配，CSS Modules 的 hash 后缀会变，要么改成前缀匹配，要么接受这几个字** |
| 会话头（会话名 + 分享） | 主区顶部一条（OCR 证据 31656 首行）；**这次没打开会话视图，class / role 未测** | 窗口标题恒为「ChatGPT」，会话名只能从 DOM 取 |
| 消息行 | **未测**（需要打开一个会话；本次不点用户的界面） | OCR 证据里能看到「用时 20 秒」「展开显示」这类元信息与正文混排 |

Tailwind 工具类（`flex` 272 个、`items-center` 264 个）不能当锚点；CSS Modules 类（`_ComposerLayoutBody_1qpwu_2`）前缀稳、hash 不稳；**唯一稳的语义锚点是 landmark subrole**（`AXLandmarkMain`，侧栏大概率是 `AXLandmarkNavigation`，本次没转出来）。

### 2.4 库里的数字（grant 窗 30 天，到 15:43）

| | |
|---|---|
| 观察 | **41** 条（09-09：9，09-14：25，09-15：7）；`titles` 只有「ChatGPT」一个 |
| 带正文 | **4 条，全是 OCR**（`ocr:generic_chromium.window`，整窗 1470×868，置信度 0.59–0.67，`lowconf=1`）；**0 条 AX 正文** |
| 空观察 | 其余 37 条：`captureMethod = ax`、`completeness = unavailable / excluded`、text 空 |
| 超时 | 5 条 `sourceState = timeout`（全在 `app_switch` 那一刻：`kAXFocusedWindow` 0.5 s 超时——Chromium 激活瞬间忙） |
| OCR 正文质量 | 侧栏会话列表（十几条别的会话的标题）与主区正文**逐行互相串**（evidence 31656：一行里左半是别的会话标题、右半是当前回答），底部还带模型选择器与账号名 |
| URL | 没入库（`app://-/index.html` 没进 sites 表）。**但注意**：`isBundleInternalURL` 只认 `file://…/.app/Contents/`，`app://` 不在内部清单里；钉钉的 `app://desktop.dingtalk.com/…` 已经以 host `desktop.dingtalk.com` 进了 sites 表（evidence 41400–41404）。ChatGPT 这条大概是因为 host 为 `-` 才没进 |

## 3. 发现

### F1（P0）通用 Chromium 规则 12 层深度上限，把整棵 DOM 树截在 web area 外面

- 证据：§2.1 深度扫描——12 层以内只有 web area 自己的标题 7 字；文本在第 17–21 层。
- 后果：树建好也读不到；且 7 字 ≠ 0 字，`noteAXOutcome` 把进程记成已热、`OCRTriggerGate` 不再因 AX 空而 OCR（§1 第 3 条）。
- 修法：专属规则限额 3000 / 30（Claude 桌面版同款）。顺带一条通用修正：**`generic_chromium` 的限额也该是 3000 / 30**——它存在的意义就是「没有专属规则的 Chromium 应用」，而 Chromium 的 DOM 没有 12 层以内的；1500 / 12 是给原生应用估的。
  另外「web area 标题 = 窗口标题」这 7 个字不该算正文：`readSubtree` 收 `AXWebArea` 的 AXTitle 是 M0 遗留（`textRoles` 里有 AXWebArea），对 Electron / Chromium 应用它永远等于窗口标题。

### F2（P0）网页无障碍树要「戳」才建，brosis 的读法戳不到；建好前每次 app_switch 都白跑，建好后不重读

- 机制见 §2.2。`AXManualAccessibility` 不支持，`AXEnhancedUserInterface` 现在根本不给它设（`wantsEnhanced` 只对有 `enhancedRegions` 的规则为真）。
- brosis 现有的重扫（1.5 s / 5 s 两次）对它是空转：没人戳，等多久都不建。实测建起来是在用户点进窗口之后。
- 修法（两级）：
  - a. **专属规则声明 `enhancedRegions`**（或加一个更直白的字段 `wantsEnhancedUI`），让 `attach` 时就设 `AXEnhancedUserInterface`。它 set 返回 notImplemented 但值会翻成 1，是不是它触发了建树**未证实**（§2.2）。
  - b. **确定有效的一步**：`noteAXOutcome` 读到 0 字且规则 `readsAX`、应用是 Chromium 系时，在排重扫之前做一次 `AXUIElementCopyElementAtPosition(app, 焦点窗口中心)` 并读命中元素的 `AXRole`——就两条 AX 消息，源码保证它在根为空时返回网页视图自己、问 role 即启用。随后 Chromium 对已加载文档发 `AXLoadComplete`，brosis 已订阅（`EventSkeleton` 第 318 行）→ `.loadComplete` 触发重扫。重扫时间表保留 1.5 s / 5 s 作兜底。
  - 验收探针已写好：`~/Library/Caches/brosis-build/chatgpt-probe/axpoke <pid>`——在树不在时做命中测试 + 读 role，然后每 250 ms 轮询 10 s 看 AXWebArea 何时出现。**这次没跑成**：15:40 起应用一直被隐藏（`AXWindows` 空），而我不再用 `open -a` 打断用户。要在它被隐藏 ≥ 6 分钟、再被用户自己切回来的那一刻跑。

### F3（P1）没有专属规则 ⇒ 整窗 OCR、显示器截图、侧栏与正文串行

- `generic_chromium`：`capturesWindow = false`（截显示器再裁矩形，压在上面的别的窗口会进图）、区域 `wholeWindow`（侧栏 276 pt 的会话列表整个进正文）、没有 `fallbackInset`。
- 证据：31656 / 31642 / 43096——每一条都是「侧栏十几个别的会话的标题 + 主区正文 + 底部模型选择器 + 账号名」，且逐行左右串。
- 修法：专属规则 `capturesWindow: true`；正文区域锚到 `AXLandmarkMain`，OCR 回退矩形自然是主区；landmark 找不到时 `fallbackInset(left: 276)`（`adapter.chatgpt.sidebarWidth` 可校准，侧栏收起时会切掉主区左 276 pt——所以兜底只在 AX 完全没建时用）。

### F4（P1）`AXDescription` 里 1292 字的按钮 aria-label 会不会进正文，取决于读法

- 探针：AXValue 752 字、AXDescription **1292 字**（「隐藏侧边栏」「通知 alt+T」「已安排任务文件夹」……131 个节点）。
- `AdapterEngine.readSubtree` 只收 `textRoles`（AXStaticText / AXTextArea / AXTextField / AXHeading / AXWebArea），AXButton 的 description 不收——**现状是对的**，规则里别加 AXButton。但 `AXPopUpButton`（13 个，模型 / 权限选择器）的当前值是 AXStaticText 子节点，会进正文；用 `pruneClasses` 剪 composer 即可。

### F5（P2）`app://` 不算内部地址

- `isBundleInternalURL` 只认 `file://…/.app/Contents/`。ChatGPT 的 `app://-/index.html` 这次没进 sites 表（host 是 `-`），钉钉的 `app://desktop.dingtalk.com/…` 已经进了。
- 修法：`browserInternalSchemes` 或一条新清单加 `app://`（Electron / CEF 应用自定义 scheme 的惯用名），标题照记。

### F6（P2）`app_switch` 那一刻 `kAXFocusedWindow` 超时（5 / 41）

- Chromium 激活瞬间主线程忙，0.5 s 超时。Telegram 那条「超时用 CG 窗口 frame 兜底」只对纯 OCR 规则开。
- 对读 AX 的规则，超时观察记成 `excluded/timeout` 就行，下一次 `window_change` 会补上（实测 1.6 s 后就有）。不用改。

### F7（P2）会话名与消息行结构没测

- 窗口标题恒为「ChatGPT」；会话名在主区顶部（OCR 证据首行）。消息行的 class / 角色、用户与助手气泡怎么区分、代码块是不是 `AXGroup` + 等宽——**都要打开一个会话再转一次**（`axgpt3 <pid>` 打印容器骨架，`axgpt <pid>` 打印文档顺序文本与 class 路径）。
- 在拿到这一步之前，规则先不做 `rowLabels` / `conversation_title` 区域，正文按文档顺序整块读。

## 4. 方案

### 4.1 规则 `chatgpt`（`Adapters/AdapterRegistry.swift`）

```swift
static let chatgpt = AdapterRule(
    id: "chatgpt",
    name: "ChatGPT / Codex 桌面版",
    bundleIDs: ["com.openai.codex"],
    electron: false,          // 不是 Electron，AXManualAccessibility 不支持；私有属性另走 wantsEnhanced
    regions: [
        RegionRule(name: "main", kind: .body,
                   locator: .roleAndSubrole("AXGroup", "AXLandmarkMain"),
                   read: .axSubtree, ocrFallback: true, required: true, clipToViewport: true,
                   excludeRoles: ["AXTextArea", "AXTextField"],
                   documentOrder: true,            // 一行消息的作者 / 正文在不同层，广度优先会串
                   ocrOnFrameChange: false,        // DOM 逐字给出，帧变了文本没变只会是动画 / 光标
                   pruneClasses: [/* composer 容器，见 F4；pruneClasses 要支持前缀匹配 */],
                   fallbackInset: WindowInset(left: sidebarWidth, top: 0,
                                              minWidth: 240, minHeight: 120,
                                              fallback: RelativeRect(x: 0.19, y: 0, width: 0.81, height: 1))),
    ],
    chatLayout: nil,
    limits: AX.BFSLimits(maxNodes: 3_000, maxDepth: 30),   // 正文在第 17–21 层，12 层一个字都读不到
    notes: "…",
    capturesWindow: true,
    enhancedRegions: /* 同 regions，或新字段 wantsEnhancedUI: true —— 目的只是让 attach 时设 AXEnhancedUserInterface */)
```

要点：
- **锚 `AXLandmarkMain` 而不是 web area**：一个窗口只有一个 web area 且整窗大，锚它等于整窗 OCR、侧栏进正文；`<main>` 是标准 landmark，侧栏收起 / 拖宽都跟着走。
  `find` 只取第一个命中，`<main>` 只有一个，够用；万一 Codex 的 diff 面板也是 `<main>`（未测），改 `preferRichestMatch`。
- **`axTreePerDocument` 保持 false**：单文档应用，树建好就不退（隐藏 5 分钟除外——那由 F2-b 的戳树补）。
- OCR 回退只在 AX 真读不到（树没建、戳了也没起来）时发生，矩形 = landmark 的 frame（找不到时 = 左侧内缩兜底）；`capturesWindow` 让压在上面的窗口不进图。

### 4.2 戳树（`EventSkeleton.noteAXOutcome`，对所有 Chromium 系规则生效）

```
读到 0 字 && rule.readsAX && detection.isChromium && 焦点窗口 frame 已知:
    hit = AXUIElementCopyElementAtPosition(appElement, frame.midX, frame.midY)
    _ = AXRole(hit)                      // Chromium 在这一步 CreateScopedModeForProcess(kAXModeBasic)
    照旧排重扫（1.5 s / 5 s），AXLoadComplete 到了会先触发
```
- 只多两条 AX 消息，只在空读时发；对 Chrome / 飞书无副作用（它们的树本来就在，命中测试落到 DOM 节点上）。
- 探针 `--ax-probe` 也做同一件事并打印「戳之前 / 戳之后」两列，否则探针永远显示这类应用「不可用」。

### 4.3 通用修正

| 改动 | 落点 |
|---|---|
| `generic_chromium` 限额 1500/12 → 3000/30 | `AdapterRegistry.genericChromium` |
| `AXWebArea` 的 AXTitle 不算正文（等于窗口标题） | `AdapterEngine.readSubtree` 或 `AX.textRoles` |
| `pruneClasses` 支持前缀（CSS Modules hash） | `AdapterEngine.readSubtree`、`RegionRule` |
| `app://` 归内部地址 | `AX.browserInternalSchemes` |
| 自检：规则用例 + 合成树（`AdapterVectors`）：7 层外壳 + landmark + 侧栏 + 0 pt 折叠项 + AXTextArea，断言 12 层读 0 字、30 层读到正文、侧栏不进、输入框不进 | `AdapterVectors.swift`、`SelfCheck.swift` |
| README 第 211 段加 ChatGPT | 两份 README |

### 4.4 不做的

- **不走纯 OCR**（微信 / Telegram 形态）：AX 建好后 42 ms 读完 749 字、逐字准确，OCR 置信度 0.6 且串行；OCR 只当回退。
- **不改浏览器判定**让它拿 Chrome 规则：它不是浏览器，Chrome 规则的地址栏取 URL、无痕判定、按文档建树都不适用。
- **不靠重启应用加 `--force-renderer-accessibility`**：brosis 不能替用户重启应用。

## 5. 验收口径（改完装机后，用户正常用 ChatGPT 30 分钟）

1. `search app:ChatGPT period=…`：带正文的观察里 `adapter:chatgpt.main` 占比 ≥ 80%，`ocr:chatgpt.*` ≤ 20% 且只出现在 app_switch 后头几秒。
2. 正文里**不出现**侧栏会话列表的标题、输入框占位文本「随心输入」、模型选择器文案；`lowconf` 消失。
3. 从隐藏 ≥ 6 分钟切回来：日志 `扫描：com.openai.codex 规则 chatgpt … AX字符=0` 之后 ≤ 5 s 内出现 `触发=load_complete` 且 `AX字符>0`。
4. `--ax-probe com.openai.codex`：t=0 允许 0 字，「戳之后」那列 ≤ 2 s 内非 0；maxDepth 30 列 ≥ 300 字。
5. 打开一个会话后跑 `axgpt3 <pid>`，补 F7：会话名区域与消息行 class 进第二轮。

## 6. 本次动过什么（诚实清单）

- 15:35 `open -a ChatGPT` 一次，把被隐藏的窗口带到前台；这会打断用户正在做的事，之后没再做（15:40 用户又隐藏了它，探针改为「no window」退出）。
- `axgpt --set-enhanced` 给 ChatGPT 设过一次 `AXEnhancedUserInterface = true`（返回 notImplemented，值翻成 1，没复位——brosis 对 Chrome / 飞书本来也是设上不复位）。
- 跑了 3 次 `--ax-probe`、5 次自编探针，全部只读；命中测试 4 个点（不点、不敲、不改窗口尺寸 / 位置）。
- 探针源码与二进制在 `~/Library/Caches/brosis-build/chatgpt-probe/`，Chromium 源码副本在会话临时目录，可删。
- 没改源码、没构建、没装机、没发版、没动 `docs/`。

## 7. 实施（0.7.8，2026-09-15 16:0x–17:3x，已构建、**未装机、未提交**）

按 §4 实施，全部落在 `app/Sources/brosis/`：

| 改动 | 落点 |
|---|---|
| 规则 `chatgpt`：锚 `AXGroup/AXLandmarkMain`，`excludeRoles` 掉输入框，`documentOrder`，`ocrOnFrameChange: false`，`pruneClasses` 剪 `_ComposerLayoutBody_` / `_ActiveProjectSelectorTrigger_`，限额 3000 / 30，`capturesWindow`，`axTreePerDocument: true`（隐藏 5 分钟后树被撤、要再戳），回退 OCR 矩形按侧栏宽内缩（默认 276，`adapter.chatgpt.sidebarWidth` 可校准） | `Adapters/AdapterRegistry.swift` |
| 戳树：`AX.pokeWebContents`（命中测试 + 读 AXRole，两条 AX 消息）；`EventSkeleton.noteAXOutcome` 读到 0 字、规则读 AX、应用是 Chromium 系时在排重扫之前先戳，结果记进 `ax_empty_retry_scheduled` 事件（`戳树 hit=…`）；`--ax-probe` 第一次读到 0 字也戳，并打出戳的结果 | `AXSupport.swift`、`EventSkeleton.swift`、`AXProbe.swift` |
| `generic_chromium` 限额 1500 / 12 → **3000 / 40**（不是方案里的 30：ZCode 实测 30 层读 291 字仍截断、40 层 1890 字，与飞书同款）；`rule(for:)` 不再用默认 1500 / 12 把兜底规则自己的限额盖回去——只对 `bfsLimitsByBundleID` 表里有的应用（访达）覆盖 | `Adapters/AdapterRegistry.swift` |
| `AXWebArea` 从 `AX.textRoles` 去掉：真机核过 Safari（AXValue 空、AXDescription 是角色说明）、Chrome（AXTitle = 页标题）、飞书（模块名），它自己的字从来不是正文，留着就是"7 字 ≠ 0 字"那个坑 | `AXSupport.swift` |
| `pruneClasses` 改成**前缀**匹配（`RegionRule.prunes`），CSS Modules 的 hash 后缀换了照样剪；飞书写全名的行为不变 | `Adapters/AdapterRule.swift`、`Adapters/AdapterEngine.swift` |
| `app://` 归 `isBundleInternalURL`（ChatGPT `app://-/index.html`、钉钉 `app://desktop.dingtalk.com/…` 都不再进 sites 表） | `AXSupport.swift` |
| 合成树 `chatgptTree`（7 层 Chromium 外壳 → 整窗 web area → 侧栏含 0 pt 折叠项 + `<main>` 三行正文一行滚出 + CSS Modules 命名的输入区）与 `chatgptShellTree`（树没建）；规则用例 3 条；自检 4 条（规则形状、12 层 0 字 / 30 层有字、回退矩形按侧栏内缩、前缀剪枝）；`app://` 两条 URL 用例；原来拿 ChatGPT 当"没有专属规则的 Chromium 应用"的那条自检改用假 bundle id + ChatGPT 的 bundle 结构 | `Adapters/AdapterVectors.swift`、`SelfCheck.swift` |
| 两份 README 第 211 段加 ChatGPT，第 214 段新增 ChatGPT 说明；`BuildInfo.version = 0.7.8` | `README*.md`、`BuildInfo.swift` |

**顺手修的环境问题**（今天机器升到 macOS 27 / Xcode 27，Swift 6.4）：
- `swift build` 默认后端变成 swiftbuild，会自己编 mlx-swift 的 .metal，Metal Toolchain 必须在；已 `xcodebuild -downloadComponent MetalToolchain`（839 MB）。
- `/bin/bash` 3.2 把 `"$IDENTITY（"` 里全角括号的首字节吃进变量名（`set -u` 下报 `IDENTITY�: unbound variable`）——`app/build_app.sh`、`Support/build_metallib.sh`、`dist/build_dmg.sh`、`dist/make_appcast.sh` 里全角标点前的 `$VAR` 一律改成 `${VAR}`（43 处，纯文案行）。
- `SelfCheck.swift` 里 OCR 冒烟那一段十项字符串拼接，Swift 6.4 报"无法在合理时间内类型检查"，拆成 `line +=`。

**构建与闸门**：`app/build_app.sh` 零 error、签名 OK；闸门 `--self-check` **278 通过 / 2 失败**（0.7.7 是 273 项）。
与本次改动相关的 9 项（规则路由 8 条 + 兜底、ChatGPT 规则形状、12 / 30 层、回退矩形、前缀剪枝、三条规则用例、`app://`）全部 PASS。
失败的两项是 **macOS 27 的 Vision 变了，与本次无关**——已装的 0.7.7 在同一台机器上跑 `--self-check` 同样 271 通过 / 这两项失败：
- `视口 OCR 冒烟`：无标点标识符严格召回 0.67–0.86（门槛 0.9）。`--dump-ocr` 看差在哪：`handler` → `handLer`、`/usr/local/etc` → `/usr/localletc`、`NSCocoaErrorDomain` → `NSCocoaError Domain`（小写 l 认成 L、斜杠认成 l、多出空格）；中文行 CER 0.03–0.05 仍在门槛内，NFKC 折叠召回 1.0。
- `视口 OCR 端到端`：dark_ui@1x 样张里「适配器名单」被认成「适配名单」，用「适配器」去搜自然搜不到。
所以按 CLAUDE.md「构建 + 公证成功后装机」的口径**没有装机、没有公证**；构建目录里那个签过名的 0.7.8（`~/Library/Caches/brosis-build/dist-app/brosis.app`）可以直接用来跑探针。
这两项怎么处理是 D24 口径的事，要用户定：① 把 OCR 冒烟的严格召回门槛按 macOS 27 重标（或改成只断言折叠召回 + 中文 CER），端到端改搜一个稳的词（「视口」）；② 或者先查 macOS 27 的 Vision 是不是换了模型 / 需要 `usesLanguageCorrection` 之类的参数才回到原来的召回。

**真机验证**：
- `--ax-probe dev.zcode.app`（0.7.8 构建目录）：`generic_chromium` 现在 t=0 读 291 字（0.7.7 的 12 层是 0 字），深度扫描 12→0 / 20→29 / 30→291 / **40→1890** 字——F1 的根因与 40 层的取值都在真机上对上了。
- **戳树没验到**：ChatGPT 从 15:40 起一直被隐藏（`AXWindows` 为空），我没有再 `open -a` 打断用户；ZCode 是 Electron，树早被 0.7.7 用 `AXManualAccessibility` 建好了，用不着戳。验收口径见 §5 第 3、4 条：等用户自己把 ChatGPT 切回来后跑
  `~/Library/Caches/brosis-build/dist-app/brosis.app/Contents/MacOS/brosis --ax-probe com.openai.codex`，看「设 AXManualAccessibility 之前」是 0、`戳树 hit=AXScrollArea`（或别的角色）之后 t=1000–4000 ms 那几列是不是非 0。

**本次动过什么**（接 §6）：装了 Metal Toolchain 组件；跑了三次 `app/build_app.sh`（产物全在 `~/Library/Caches/brosis-build/dist-app/`）；跑了一次已装 0.7.7 的 `--self-check`、两次 0.7.8 的 `--dump-ocr`、一次 `--ax-probe dev.zcode.app`（会给 ZCode 设一次 `AXManualAccessibility`，0.7.7 本来就设过）。没装机、没公证、没提交、没动 `docs/`。

## 8. macOS 27 的 Vision 参数实验（2026-09-15 17:5x，回答「要不要换参数」）

方法：把 `OCRSelfTest` 的三张样张（画法、真值、指标逐字抄成独立脚本 `~/Library/Caches/brosis-build/chatgpt-probe/ocrparams.swift`），
同一批图换参数跑 `VNRecognizeTextRequest`，口径与自检一致（无标点标识符严格召回 / 带标点折叠召回 / 中文行 CER）。
`--dump-ocr` 已确认自检里的失败与脚本基线逐字相同。原始输出在同目录 `ocrparams_run1/2.txt`。

### 8.1 结论

**没有任何参数组合能把中英混排行里的 Latin 标识符拉回 macOS 26 的水平**——变的是 zh-Hans 模型本身，不是我们的参数：

| 参数 | 结果 |
|---|---|
| `revision` 1 / 2 / 3 | 三个结果**逐字节相同**；`supportedRevisions = [1,2,3]`，新的 Swift API `RecognizeTextRequest` 也只有 revision3，跑出来同样的字 |
| `usesLanguageCorrection = true` | 与关着完全相同（accurate 下本来就不起作用，D24 的结论仍成立） |
| 语言顺序 `["en-US", "zh-Hans"]` | **只有第一种语言算数**（与 `["en-US"]` 结果逐字相同）：Latin 全对、中文行 CER 0.45–1.19（中文整段丢） |
| `.fast` | 更差（中文 CER ≥ 0.97，标识符 0.33–0.83） |
| `zh-Hant` 打头 | 与 zh-Hans 相同 |
| 缩放（0.5x–2.0x） | 结果跟着字号**乱跳**：body_mixed@2x 在 0.6–0.9x 全对、1.25x / 2x 又丢路径；1x 输入缩到 0.8x 以下中文整段崩。字号 16–21 px 时 zh 模型认 Latin 最好，但这不是能用的旋钮 |
| **`automaticallyDetectsLanguage = true`** | **纯 Latin 区域（代码样张）从 0.67 / 0.83 变成 1.00 / 1.00**，逐字节全对、还更快（150 ms → 50–65 ms）；中英混排与中文样张与基线**逐字相同**（不会变差） |

zh-Hans 模型在 macOS 27 上对混排行里 Latin 的固定错法：`l` → `L`（`handLer`、`Let`）、路径里的 `/` → `l`（`/usr/localletc/`）、
CamelCase 中间插空格（`NSCocoaError Domain`）、1x 时丢点（`developerapple.com`）与丢字（「适配器名单」→「适配名单」）。

### 8.2 建议

1. **生产端**：`ViewportOCR.recognize` 加 `request.automaticallyDetectsLanguage = true`，其余参数不动。实测只赚不赔：代码 / 终端 / 英文页这类纯 Latin 区域回到逐字节正确，中文与混排一字不变。D24 的参数表多一行即可。
2. **自检口径**（D24，要用户定）：
   - 无标点标识符那组改成**折叠口径**（NFKC + 小写 + 去空白，与带标点组、与 FTS 一致）：`NSCocoaError Domain`、`KTCC`、`handLer` 都能对上；
     折叠后仍过不了的只剩 body_mixed 的路径 `/usr/local/etc/…`（`/` 认成 `l`，2x：6/7 = 0.86）和 1x 的 URL（丢点，5/7 = 0.71）。
   - 所以要么把门槛从 0.9 降到 **0.85**、并把 body_mixed@1x 与 code_small@1x 一样只报数不断言（D24 本来就说 1x 只是"可用"）；要么把这两条样张里的路径 / URL 单独列成"只报数"的第三组。
   - 端到端那条改搜「规则引擎」或「飞书和微信」（六次实验里全对），别搜「适配器」（1x 下丢字）。
3. **不建议**的：换语言顺序（丢中文）、双通道（zh 一遍 + en 一遍再按坐标拼，OCR 开销翻倍，D24 的耗时口径要重算）——除非以后真机数据说明路径 / URL 的检索失败率明显上去了。

**本次动过什么**：只跑了两个只读脚本（`ocrparams` / `ocrnewapi`，各自画图 + Vision 本地推理），没截屏、没碰 TCC、没改源码。

## 9. 用户决定后的收尾（2026-09-15 18:0x，0.7.8 已公证、已装机、**未提交**）

**按 §8 建议 1、2 改**：`ViewportOCR.recognize` 加 `automaticallyDetectsLanguage = true`；自检两组标识符合成一组、按检索侧折叠口径判定、门槛 0.9 → **0.85**（用户定）、`body_mixed@1x` 与 `code_small@1x` 一样只报数（`OCRSelfTest.reportOnly` 带理由）；端到端改搜「规则引擎」。

**/simplify（四个视角并行审 §7 的 diff，去重后修了这些）**：
- **层次**：删掉 `EventSkeleton.axWarmedKeys`（"读到过字就永久已热"）——Chromium 隐藏 5 分钟会撤树，永久已热等于切回来再也不重扫；重扫计数本来就封顶两次、读到字清零，够用。ChatGPT 规则随之不再借用 `axTreePerDocument`。戳树改成**每次空读都戳**、只让重扫受预算限制（否则两次重扫没等到树建好就再也不戳）。`app://` 并进 `browserInternalSchemes`，`isBundleInternalURL` 复原。`generic.notes` 不再列 AXWebArea。
- **效率**：`generic_chromium` 节点上限退回 1500（只加深度到 40；ZCode 40 层裁视口后才 451 节点，翻倍只会让 VS Code / Slack 这类没有专属规则的应用每次扫描慢一倍）；`AdapterEngine.readSubtree` 对滚动 / 列表类容器不再读 value / description / title（它们本来就要探 frame，读文本纯属浪费，一棵 Chromium 树七成是 AXGroup，每个省三条 AX 消息）；ChatGPT 的 `classProbeMaxDepth` 收到 8。
- **简化**：规则形状断言只留行为用例没覆盖的四项；删掉与规则用例重复的 deepScan；`pokeWebContents(pid:windowFrame:)`；`Outcome` 七个召回字段收成 `recall / missing / strictRecall / strictMissing`；戳树的机制只在 `AX.pokeWebContents` 写全，规则与骨架里只留指针；`pruneClasses` 改数组；合成树去掉没人读的 class；回退矩形自检与 Chrome F2c 共用 `fallbackOCRRect`；OCR 打印用 `fixed(_:_:)`。
- **复用**：自检里 1500 / 12 改引用 `AX.defaultBFSLimits`；探针复用 `sample()` 读到的窗口 frame，不再多发一次 `kAXFocusedWindow`。
- **shell**：漏掉的 `$VERSION。` 补上；新增 `app/Support/check_shell_braces.py` 作构建闸门第 0c 步，`$VAR` 紧跟非 ASCII 一律报错。
- **跳过**（记下理由）：限额归属（把访达做成一条规则、删 `bfsLimitsByBundleID`、把 `rule.limits` 传进 `focusedWindowInfo`）与 web area URL 改白名单——都超出这次 diff 的范围，改动面在别的应用上；CSS Modules 的 hash 在 `domClasses` 源头剥掉——模式不够确定，先用前缀。

**构建 / 公证 / 装机**：`app/build_app.sh` 零 error，闸门 `--self-check` **280 项全 PASS**（含新的 0c 步）；
公证 `notarize-180800`（id e9c564b5…，Accepted、已 staple，spctl `Notarized Developer ID`）；18:10 装机（0.7.7 备份在 `installed-backup/brosis-0.7.7-20260915-181010.app`），新实例开库正常、Chrome 扫描照常。

**仍待真机验收**（§5）：ChatGPT 的戳树——等用户切回 ChatGPT 后看日志里 `ax_empty_retry_scheduled bundle=com.openai.codex … 戳树 hit=…` 之后有没有 `触发=load_complete` 且 `AX字符>0`；会话视图的消息行结构（F7）。
