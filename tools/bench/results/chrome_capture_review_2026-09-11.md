# Chrome 采集兼容性复查（2026-09-11）

## 0. 口径

- 环境：brosis 0.7.5（装机版，`ax.enhancedUserInterface` 未改、即默认开）、Google Chrome 153.0.8010.12（界面语言 zh-CN、多 Profile）、macOS 26.6（Darwin 25.6）、三块显示器。
- 方法：
  1. 读代码：`AdapterRegistry.chrome` 两副形态、`AdapterEngine`、`EventSkeleton`、`AXSupport`（`urlSources` / `enableManualAccessibilityIfNeeded`）、`CapturePolicy.PrivateBrowsing`、`CaptureController.pickTarget`。
  2. 真机探针：`/Applications/brosis.app/Contents/MacOS/brosis --ax-probe com.google.Chrome`（含 `--dump-webarea all`），分别对着 `chrome://accessibility`、一篇维基长文、一个本地 PDF、一个无痕窗口各跑一次。页面用 `open -a "Google Chrome" <url>` 打开，无痕窗口用 `open -na "Google Chrome" --args --incognito`，都不需要辅助功能或自动化授权。
  3. 库里证据：MCP `search(app:Chrome)` + `get_evidence`，看最近三天的 `captureMethod` / `region` / OCR 置信度。
  4. 日志：`/usr/bin/log show --info --predicate 'subsystem == "com.brosis.app"'`（**zsh 里 `log` 是内建命令，直接写 `log show` 会拿到空输出或 "too many arguments"，必须写全路径**）。
  5. Chromium 源码（main 分支）：`chrome/browser/chrome_browser_application_mac.mm`、`content/browser/accessibility/browser_accessibility_state_impl.cc`、`ui/accessibility/platform/browser_accessibility_manager_mac.mm`、`chrome/browser/ui/views/frame/browser_view.cc`、`chrome/app/generated_resources.grd` 与 `resources/generated_resources_zh-CN.xtb`。
- 匿名化：证据里的 Profile 名、内部后台域名、同事姓名一律不写，只给 evidence id。

## 1. 结论

**现状方向是对的，主路径已经能用**：私有属性开着时 Chrome 建起完整无障碍树，正文按 DOM 逐字读，长页面裁视口后 50–90 ms 一次，URL 从 `AXWebArea.AXURL` 取，OCR 请求 0。**但有一个隐私缺陷（P0）和一组"页面刚打开那一秒"的质量 / 耗电缺陷（P1）**，另有几处判定不一致。不需要换方案（扩展 / CDP / AppleScript 都不如现状），要做的是把现状补齐。

## 2. 真机实测（私有属性开着）

| 页面 | t=0 读到 | 树建好之后 | 节点 / 深度 | 备注 |
|---|---|---|---|---|
| `chrome://accessibility` | 2801 字 / 220 节点 | 同左，24–52 ms | web area 子树 177 节点 | 页面显示五项模式全部 "Forced on because of an interaction with an assistive technology" —— 就是 brosis 设的那一下 |
| 维基长文（英文） | **0 字 / 43 节点（只有外壳），OCR 请求 1** | t=1000 ms 起 3940 → 4033 字 / 556 节点，50–90 ms | 整棵子树 5178 节点、2361 个 AXStaticText、61690 字；`clipToViewport=false` 时撞 20000 字上限 | 视口裁剪有效；maxDepth=8 会截断（2102 字），14 以上一致，规则用的 30 够 |
| 本地 PDF（Chrome 内置阅读器） | 0 字 / 50 节点，OCR 请求 1 | t=250 ms 35 字（只有首次使用的"绘图"帮助气泡，它是 AXApplicationAlertDialog，模态期间树里只剩它） | 约 15 s 后 brosis 经 AX 读到 4689 字节正文（evidence 26299，`adapter:chrome.web_area`，`filePath` 也带上了 PDF 路径） | PDF 文本走 AX 可用，只是来得晚 |

窗口标题实测：`<页标题> - Google Chrome - <Profile 名>`。这正是 Chromium `BrowserView::GetAccessibleWindowTitleForChannelAndProfile` 的产物（`IDS_ACCESSIBLE_WINDOW_TITLE_WITH_PROFILE_FORMAT`），说明 **Chrome 的 `kAXTitle` 用的是无障碍标题，而不是可见标题**——这一点决定了 F1。

日志（`/usr/bin/log`，打开维基页那 2 秒）：

```
扫描：com.google.Chrome 规则 chrome，读正文=true 拿到窗口=true AX字符=0 OCR请求=1 触发=title_changed   ×3
扫描：com.google.Chrome 规则 chrome，读正文=true 拿到窗口=true AX字符=3940 OCR请求=0 触发=title_changed
扫描：com.google.Chrome 规则 chrome，读正文=true 拿到窗口=true AX字符=4033 OCR请求=0 触发=title_changed
```

## 3. 发现

### F1（P0，已真机复现）中文界面的无痕窗口识别不了，无痕页面标题、URL、正文全部入库

- `PrivateBrowsing.titleMarkers` 里中文项是「无痕浏览 / 私密浏览 / 隐私浏览 / 无痕式视窗」，英文项含 "Incognito"。
- Chromium 源码：无痕窗口的无障碍标题格式是 `IDS_ACCESSIBLE_INCOGNITO_WINDOW_TITLE_FORMAT` = `$1 (Incognito)`；zh-CN 翻译（xtb id 6751344591405861699）是 **`$1（无痕）`**——全角括号、只有"无痕"两个字。访客窗口对应 `$1 (Guest)` / `$1（访客）`。
- 英文 Chrome 能命中 "Incognito"，**中文 Chrome 一个标记都不命中**：无痕窗口被当普通窗口，开关开着时 DOM 正文、标题、URL 全部入库。代码注释里"Chromium 无痕标题不带标记"的判断在 Views 版 Chrome 上已经不成立（标题就是无障碍标题，带后缀）。
- **真机复现（18:43）**：`open -na "Google Chrome" --args --incognito`（参数会转交给正在运行的实例，不触发 TCC）开出无痕窗口，`--dump-webarea all` 打出的标题是 **`新的无痕式标签页 - Google Chrome（无痕）`**——后缀与源码一致，且无痕窗口不带 Profile 名，「（无痕）」就是串尾。
- brosis 当场把它当普通窗口处理：日志 `读正文=true 拿到窗口=true AX字符=0 OCR请求=1`；库里 evidence 26442（OCR，无痕提示页正文，含错字「了解详債」）、26448（AX DOM 正文）、26451（标题 + `chrome://newtab/`）。私密浏览本应只留 app + 时间 + `excluded`，现在三样都记了。
- 修法：标记表加「（无痕）」「(Incognito)」「（访客）」「(Guest)」，并且对 Chromium 系浏览器改成**判后缀**（`hasSuffix`），因为 Chrome 只在最末尾加；`contains` 那套留给 Safari / Firefox。Edge / Brave 的 zh-CN 字符串没查，先保留 "InPrivate" 等 contains 标记。

### F2（P1）每次导航、每次切回久未显示的标签页，头 0.3–1 s 树是空的，会白跑一次整窗 OCR，还把垃圾入库

- 证据：evidence 26135（OCR，置信度 0.30，103 字节，全是标签条 + 地址栏：`•• ~ & Accessibility Internals x ，无标题 × + …`）、25690（新标签页加载中，置信度 0.51）、26298（PDF 帮助气泡 + 半页正文，置信度 0.51）。
- 三个原因叠加：
  1. `EventSkeleton.noteAXOutcome` 的"读到空 ⇒ 排重扫、撤掉这一帧 OCR"只对**冷进程**生效（`axWarmedPIDs` 按 pid 记）。Chrome 进程热了之后，每个新页面头一秒的空读都直接落到 `ocrFallback && axEmpty` ⇒ 立刻 OCR。
  2. AXWebArea 还没建出来时 `located == nil`，`AdapterEngine` 把 OCR 矩形退成**整个窗口**（含标签条、地址栏），`adapter.chrome.toolbarHeight` 那道裁边只在开关关着那副形态里生效。
  3. Chromium 侧：树是导航后异步建的；另外 `BrowserAccessibilityStateImpl` 会把**隐藏超过约 5 分钟（±20 s）的标签页**的无障碍模式整个撤掉（`AccessibilityDisabler`，`Accessibility.DisabledAfterHide`），切回来时重建——所以"切标签页也会空读"不是偶发。
- 修法（按性价比排）：
  - a. 对 `readsAX` 且判为 Chromium 系的规则，空读时的处理从"按 pid 冷热"改成"按 (pid, 窗口标题) 或 (pid, AXURL)"：新标题 / 新 URL 的头 2 次空读只排 1 s 重扫、不发 OCR；第 3 次仍空才 OCR。
  - b. `AXObserver` 多订一个 `AXLoadComplete`（Chromium mac 对顶层文档 `kLoadComplete` 发 `kAXLoadCompleteNotification`，新标签页除外），拿它当"页面就绪、现在读"的精确触发，比 `title_changed` 连打三下准。
  - c. AXWebArea 缺席时的回退矩形套用 `chromeToolbarKey` 的顶部内缩，不要整窗。
- 验收：打开 5 个不同站点各一次，`ocr:chrome.*` 观察数 = 0（或 ≤ 1 且置信度 ≥ 0.8）；`--ax-probe` 的 t=0 列允许为 0，但库里不应出现 t=0 那一帧的 OCR 文本。

### F3（P1）OCR 的窗口定向截图挑的是"最大的那个窗口"，不是焦点窗口

- `CaptureController.pickTarget`：同 bundle id、在屏、layer 0 里取**面积最大**的。两个 Chrome 窗口（三块显示器上很常见）时，AX 读的是焦点窗口，OCR 回退截的可能是另一个窗口，两份正文挂在同一条观察上。微信 / 飞书同受影响。
- 修法：`Context.windowFrame` 已经有焦点窗口的 AX 矩形，按矩形匹配 `SCWindow.frame`（允许 ±2 pt），匹配不到再退回最大面积。

### F4（P2）"最富的 AXWebArea"在 DevTools 停靠 / 侧边栏 / 分屏时会挑错

- Chrome 一个窗口里可以同时有：页面、停靠的 DevTools（`devtools://`）、侧边栏（`chrome://…`，Gemini / 阅读清单）、分屏的第二个标签页。它们都是 AXWebArea，`preferRichestMatch` 只比字数——DevTools 的 Elements 面板几乎永远比页面"富"。
- 本轮未复现（需要交互打开 DevTools）。修法：候选先按 `AXURL` 的 scheme 分层（有 `http(s)://` / `file://` 候选时排除 `chrome://` `devtools://` `chrome-extension://`），再按矩形是否包含窗口中心 / 面积最大挑，字数只做平手时的裁决。这套判据也能顺手解决"新标签页只剩 `chrome://new-tab-page`"的情形（它是唯一候选，照旧选中）。

### F5（P2）`chrome://` 内部页进了 sites 表

- 今日台账 sites 里出现 `new-tab-page`、`accessibility`（`urlRef` 把 `chrome://x/` 当 deeplink、host = x）。
- 修法：`isBundleInternalURL` 扩到 `chrome://` `chrome-extension://` `devtools://` `about:`——这些不写 `observations.url`，标题照记。PDF 阅读器那种"外层 `file://` + 内层 `chrome-extension://`"实测取到的是外层 file 路径，不受影响。

### F6（P2）"是不是浏览器"在三处各判各的

- 规则解析：`AX.bundleIsBrowser`（读 Info.plist，本机 Zen 也被判成浏览器）。
- 无痕判定与地址栏取 URL（`includeAddressBar`）：`PrivateBrowsing.browserBundleIDs` 手写清单。
- 设私有属性：`chromiumFamilyBundleIDs` 手写清单 + 框架结构检测。
- 后果：结构判出来的新浏览器（Zen、Edge Beta、Dia、Comet…）拿到 `chrome` 规则，但**不做无痕判定、开关关着时也不从地址栏取 URL**。修法：`isBrowser = plist ∪ 清单` 只算一次，三处共用。

### F7（P2）Chrome 规则没有合成树用例

- `AdapterVectors` 里没有 Chrome 树；`SelfCheck` 只钉了规则形状（两副形态、`capturesWindow`、`ocrOnFrameChange`）。CLAUDE.md 要求改规则必须配合成树。
- 建议补三棵：① 43 节点外壳树（无 AXWebArea）⇒ 只出一条带顶部内缩的 OCR 请求；② 带视口外节点的 web area 树 ⇒ 裁剪 + partial；③ 页面 + `devtools://` 两个 web area ⇒ 按 F4 的判据选页面。

### F8（说明）私有属性的真实代价，按 Chromium 源码核过

- brosis 设 `AXEnhancedUserInterface=true` ⇒ `BrowserCrApplication` 计数 +1，**2 s 防抖**后对整个进程开 `kAXModeComplete | kScreenReader`（完整屏幕阅读器模式），所有标签页都付这份开销；这就是 `chrome://accessibility` 里 "Forced on…" 的来源，也解释了 2026-09-07 交接里"设完连读 4 s 仍是 16 节点"。
- 设 `false` **是被 Chrome 认的**（没有未处理的 enable 请求时立即关掉模式）——screenpipe #3884 里"设 false 返回不支持"的说法在 Chrome 上不成立（Electron 可能不同）。但"优雅退出前设 false 能不能避开按键重放"没有测，不要盲改；如要试，用例是：在 Chrome 输入框敲 `abcd`，退出 brosis，看是否变成 `abcdbcdbcd`。
- 隐藏标签页 5 分钟后模式被撤（见 F2）；VoiceOver 开着时 Chrome 忽略第三方 AT 的请求。
- 结论：默认开的决定有数据支撑（正文逐字、OCR 0），代价已在 README 写明；本轮不建议改默认。

### F9（P3）PDF 文本来得晚

- 阅读器的无障碍树在文档加载完之后才挂上，探针 4 s 内只看见帮助气泡；brosis 约 15 s 后经 AX 读全（evidence 26299）。中间那次 OCR 与 F2 同因，F2 修好即消。

### F10（P3）固定列表格会让正文重复一遍

- evidence 13281（10 KB）里整张表出现两次：前端固定列实现会渲染一份克隆表，它确实在视口里，裁剪不会去掉。可选做法：同一区域内按整行去重。低优先级。

### F11（P3）加载期标题抖动

- 一次导航会依次出现「无标题」「<URL> - Google Chrome - …」「<页标题> - …」三个标题，各写一条观察。无害，只是多。

## 4. 方案对比

| 方案 | 正文 | 视口口径 | 副作用 / 隐私 | 用户负担 | 判断 |
|---|---|---|---|---|---|
| 现状：私有属性 + DOM 读，空读回退 OCR | 逐字，50–90 ms | 可裁视口 | 整进程屏幕阅读器模式；退出时按键重放风险（已写明） | 无 | **保留为默认**，按 §5 补齐 |
| 关开关，纯 OCR | 中文错字多（既有实测） | 天然视口 | 无 | 无 | 只当兜底 |
| AppleScript `execute javascript` 拿 `innerText` | 逐字、整页 | 要自己按 `getBoundingClientRect` 算可见性 | 需用户手动开「允许 Apple 事件中的 JavaScript」（Chrome 默认关，企业策略常禁），且触发一次"自动化"TCC 弹框；JS 注入进每个页面 | 高 | 不做默认。它的 `mode of window` 能精确判无痕，可作可选辅助通道，但 F1 修完就不需要 |
| 扩展 / Native Messaging | 最好 | 可 | 装扩展 | 高 | 用户已排除 |
| CDP（远程调试端口） | 好 | 可 | 端口对本机所有进程开放 | 高 | 已排除（2026-09-07） |

## 5. 推荐方案（按顺序做）

1. **F1 无痕（P0，半天）**：加标记 + 后缀匹配 + 自检用例（中英文各一条）+ 真机复现一次。
2. **F2 + F9 + F3（P1，一两天）**：按 (pid, 标题/URL) 的空读重扫、`AXLoadComplete` 订阅、缺 web area 时的顶部内缩矩形、OCR 目标窗口按焦点矩形匹配。验收口径见 F2。
3. **F7（与 2 一起）**：三棵合成树进 `AdapterVectors`，自检从 262 往上加。
4. **F4 / F5 / F6（P2，一天）**：web area 候选按 scheme + 矩形挑；`chrome://` 系不写 URL；浏览器判定统一。
5. **F8**：README 加一句"隐藏标签页 5 分钟后 Chrome 会撤掉该页的无障碍模式，切回来的第一秒读不到属正常"；退出前设 false 只做实验，不进主线。
6. F10 / F11 视情况。

## 6. 未验与局限

- 无痕标题后缀已在本机复现（F1）；Edge / Brave / Vivaldi 的 zh-CN 后缀未查。
- DevTools / 侧边栏 / 分屏的挑选错误是按代码推断，未复现。
- 按键重放（F8）未复现，也未验证"退出前设 false"的效果。
- PDF 只测了一个本地文件且首次使用弹了帮助气泡；气泡关掉后的首读时延未测。
- 本轮在用户 Chrome 里打开了三个标签页（`chrome://accessibility`、维基 Web accessibility、`/Library/Documentation/License.lpdf` 里的 PDF）和一个无痕窗口（只停在无痕新标签页），都未关闭。

## 7. 修复与验证（0.7.6，2026-09-11 19:0x，已装机、未提交）

按 §5 顺序一次做完，构建闸门自检 262 → **268 项全 PASS**（裸二进制 179 PASS / 0 FAIL / 1 SKIP，SKIP 是 bundle 版本号那项）。

| 项 | 改动 | 真机验证（0.7.6 装机后） |
|---|---|---|
| F1 无痕 | `PrivateBrowsing.titleSuffixMarkers`（「（无痕）」「(Incognito)」「（访客）」「(Guest)」）+ 串尾匹配；`isPrivate` 带 `bundleURL` | 无痕窗口在前台时每次扫描 `读正文=false`；evidence 26777 = `excluded`，无标题、无 URL、无正文 |
| F2 空读 | `EventSkeleton.noteAXOutcome` 改按键记冷热，Chrome 键 = pid + URL/标题、不进"已热"集合、读到正文清零；**重扫排着时再读到空也不 OCR** | 导航到维基长文：`title_changed` 三次空读 `OCR请求=0`，随后 3329 → 3771 字，`ocr:chrome.*` 观察 0 条（此前每次导航一条，evidence 26135 那类） |
| F2b AXLoadComplete | `AXObserver` 多订 `AXLoadComplete`，新触发 `load_complete`（收敛为 `window_change`） | 维基与 chrome://version 都收到 `触发=load_complete`，读到的字数与页面就绪后的 `title_changed` 一致 |
| F2c 回退矩形 | `RegionRule.fallbackInset`；Chrome 增强形态缺 web area 时按 `chromeShellInset()` 内缩，不再整窗 | 自检钉住：合成外壳树的回退矩形 y 从窗口顶 +80 起、到窗口底；真机本轮没触发到 OCR，无法从库里看 |
| F3 OCR 目标窗口 | `CaptureController.pickTarget(… preferredFrame:)` 先按焦点窗口 AX 矩形认（容差 8 pt），`CaptureCoordinator.windowFrame(bundleID:)` 供矩形 | 自检 2 条（认小窗 / 对不上退回最大）；真机 OCR 未触发，未验 |
| F4 主文档 | `ElementLocator.primaryWebArea` + `AdapterEngine.primaryWebArea`（外部地址优先 → 面积最大 → 5% 内比字数）；`AXNodeSource.url` | 合成树：页面 + DevTools + 侧边栏只读页面；分屏等面积取字多的。真机 DevTools 停靠未复现 |
| F5 内部页 | `AX.isBrowserInternalURL` / `isInternalURL`（chrome / chrome-extension / devtools / edge / brave / about…），web area 与地址栏两条路都过滤 | chrome://version 的观察（26791）有标题、有正文、**没有 url / host**；维基观察 url 正常 |
| F6 浏览器判定 | `PrivateBrowsing.isBrowser` = 清单 ∪ plist 缓存（`AX.isBrowser`），`attach` 时算一次；无痕判定与地址栏取 URL 共用 | 自检通过；Zen 等结构判出的浏览器未真机测 |
| F7 用例 | `AdapterVectors` 加 Chrome 外壳树 / DevTools 树 / 分屏树，规则用例 +4，自检另加 3 项 | 268 项全 PASS |
| F8 文档 | README Chrome 段落补无痕 / 内部页 / 空读 / DevTools 一句；`AdapterRegistry.chrome.notes` 同步 | — |

未做：F10 表格重复行去重、F11 加载期标题抖动（低优先级）；退出前设 false 的实验没做。
验证时的副作用：本机 Chrome 里多了两个无痕窗口（都停在无痕新标签页）和四个标签页，未关。

### 7.1 /simplify 清理（同日 19:2x，重新构建 + 装机，闸门仍 268 项全 PASS）

四个角度（复用 / 简化 / 效率 / 层次）各一个只读评审代理，去重后采纳的改动：

- 浏览器判定只剩一处：`AX.isBrowser` 删掉，"没有 URL 只查缓存"并进 `AX.bundleIsBrowser`；`AdapterRegistry.rule(for:)` 也改走 `PrivateBrowsing.isBrowser`；`browserBundleIDs` 从 chrome / safari 两条规则的 bundle id 派生，不再手抄。
- `focusedWindowInfo` 直接收 `bundleURL`，`attach` 里那行只为预热缓存的调用删掉。
- "按页面记冷热"由规则声明（`AdapterRule.axTreePerDocument`，chrome 置 true），`EventSkeleton` 不再比规则 id；`noteAXOutcome` 只收一个 `page: String?`，键在函数里拼。
- 重扫闭包多一道 `lastAXTextReadAt[pid] < scheduledAt`：排了之后已经读到正文（AXLoadComplete 往往先到）就不再补扫——省每次导航一整棵树的遍历和一条观察。
- `AXLoadComplete` 改用 SDK 常量 `kAXLoadCompleteNotification`。
- `AdapterEngine.scan` 里三种"定位到 AX 节点"的定位器统一在 switch 后探矩形，`fallbackInset` 对 `.webArea` 同样生效；`primaryWebArea` 不再读候选的 AXTitle、把比面积时探过的 frame 带回去（每次扫描省 1–3 条 AX 消息）、内部页用合并谓词 `AX.isInternalURL`（bundle 内 file:// 外壳也出局）。
- `titleMarkers` 去掉 "Incognito"（只认串尾 "(Incognito)"），页面标题里讨论它的不再误伤；自检加了这条反例。
- `pickTarget` 焦点矩形改成一次 `first(where:)`；自检 `expectPick` 加 `preferredFrame:` 参数复用；无痕用例改成表驱动、失败时报出是哪条标题；回退矩形断言改成与 `chromeShellInset().resolve(in:)` 相等；`AdapterVectors` 的三棵 Chrome 树共用 `chromeWindow` / `rows` 两个构造器。

没采纳：`load_complete` 加 300 ms 防抖（Chromium 只对顶层文档发一次，成本不值一层机制）；把 Claude 桌面版的 `preferRichestMatch` 并进 `.primaryWebArea`（要另做合成树验证面积阶段不会选中预览 web area）；`PrivateBrowsing` 搬到 AX 层（依赖方向在改动前就是这样，另议）。
