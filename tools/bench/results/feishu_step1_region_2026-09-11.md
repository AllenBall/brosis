# 飞书 Step 1：选对区域——读当前会话、会话名从 AX 来、侧栏整块排除（0.7.2）

2026-09-11 12:xx，M4 Air、macOS 26.6.2、飞书 Lark 7.74.21。依据 `feishu_capture_review_2026-09-11.md` §4 Step 1–2
与 `feishu_step0_probe_2026-09-11.md` 的锚点。构建 `~/Library/Caches/brosis-build/dist-app/brosis.app`（0.7.2，
自检 **256 项全过**，签名 + 公证 Accepted + staple），**尚未装到 /Applications**（装机那步要删旧 app、结束进程，
自动模式分类器拦下，留给用户）。真机验证全部用构建目录里的二进制跑 `--ax-probe`（生产同一条 `AdapterEngine.scan`）。

一句话：**飞书正文现在读的是 `messenger-chat` 里 `.chatMessages` 下的当前会话，会话名从 `.chatWindow_chatName` 进 `windows.title`，
侧栏 `messenger` 整块排除，1 pt 占位行不算视口内，输入框草稿不记，单聊行带「我 / 对方名」前缀；切到云文档 / 邮箱时退到那个模块
自己的 web area、页标题即其 AXTitle。真机三种界面下 OCR 请求都是 0。**

## 1. 改了什么

| 文件 | 改动 |
|---|---|
| `Adapters/AXNodeSource.swift` | 协议加 `domClasses`（`AXDOMClassList`）；`LiveAXNode` 读它，`SyntheticAXNode` 可造 |
| `Adapters/AdapterRule.swift` | 新定位器 `.webArea(WebAreaPick)`（prefer / exclude / anchorClass）与 `.webAreaDescendant(domClass:)`；`RegionRule` 加 `excludeRoles`、`probeContainerFrames`、`readOrder`（`.documentOrder`）、`rowLabels`、`ocrOnFrameChange` |
| `Adapters/AdapterEngine.swift` | `Viewport.isVisible`：宽或高 < 2 pt 视为未渲染；`pickWebArea` / `findByClass`；`readSubtree` 支持文档顺序、角色排除、只探文本节点 frame、行级前缀；标题区域先读、其文本作单聊对方名；`visible_range` 记 `web_area` / `anchored` |
| `Adapters/AdapterRegistry.swift` | 飞书 `enhancedRegions` 改成 `conversation_title`（`.webAreaDescendant("chatWindow_chatName")`，非必需）+ `body`（`.webArea(prefer: messenger-chat, exclude: [messenger], anchor: chatMessages)`，排除 AXTextArea / AXTextField，文档顺序，单聊行前缀，帧变化不 OCR）；限额 1200/14 → **3000/40**；`capturesWindow: true` |
| `EventSkeleton.swift` | 扫描到 `.title` 区域文本就盖过窗口标题写 `windows.title`（与 OCR 路径同一口径）；挑中的 web area 标题变化时记 `adapter_webarea_picked` 事件 |
| `Adapters/AdapterVectors.swift` | 四棵新合成树（单聊 / 群聊 / 云文档 / 树没建起来）+ 四条规则用例 + 一条视口用例 |
| `SelfCheck.swift` | 增强形态断言改成认 `.webArea`、只要求必需区域留 OCR 回退；新增一条钉飞书增强形态的 11 项性质 |
| `AXProbe.swift` | `--ax-probe` 的 t=0 行下面打每个区域的明细（定位、挑中的 web area、字数、开头 60 字） |
| README ×2、`app/README.md` | 飞书那段口径改成「读当前会话」 |

没动：开关关着的基座路径（Step 4）、水印过滤与 Chrome 的帧变化 OCR（Step 3 其余）、`file://` URL（Step 5）、会议（Step 6）。

## 2. 真机验证（构建目录二进制，`--ax-probe com.bytedance.macos.feishu`）

| 界面 | conversation_title | body | 字符 / 节点 / 耗时 | OCR 请求 |
|---|---|---|---|---|
| 群聊「某测试群」 | 定位=是「某测试群」 | webarea=messenger-chat，锚=是，可见 35 / 视口外 **149**（占位行全被判为视口外） | 726 / 751 / 65 ms | 0 |
| 单聊「同事甲」 | 定位=是「同事甲」 | 锚=是，开头 `我：… ⏎ 我：… ⏎ 我：… ⏎ …` | 272 / 567 / 47 ms | 0 |
| 云文档主页 | 定位=否，文本 =「主页 - 飞书云文档」（web area 的 AXTitle） | webarea=「主页 - 飞书云文档」，锚=否，正文是文件列表 | 786 / 1400 / 119 ms | 0 |

对照 0.7.0：同一台机器上原来读的是侧栏（evidence 17199 那种「会话名 : 预览」清单，1321 字、恒 partial、会话名恒「飞书」）。

**看到但没处理的噪声**：单聊里 `.message-reactions` 的点表情人名以独立行出现（`同事甲 ⏎ 同事甲`）；群聊正文开头有「1 条新消息」横幅。
都在 `.chatMessages` 之内、按 class 才能剪，要给每个 AXGroup 读一次 class（约 +250 次 AX 调用），归到 Step 3 一并定。

## 3. 合成树用例（自检 12.2，`--self-check` 已跑）

| 用例 | 钉住的行为 |
|---|---|
| 飞书（开关开）单聊 | 只读 messenger-chat 的 .chatMessages；侧栏 / 会话头个性签名 / 草稿 / 1 pt 占位行都不进库；`崔某：对方说的话`、`我：我说的话`；OCR 0 |
| 飞书（开关开）群聊 | `王某\n群里的一句话` 相邻（文档顺序）；不加任何前缀 |
| 飞书（开关开）云文档 | 只剩模块自己的 web area；标题 = AXTitle；complete |
| 飞书（开关开）树没建起来 | 正文空、`body` 排整窗 OCR、unavailable |
| 视口 | 800×1 的占位行判不可见 |
| 规则形状 | 挑 messenger-chat 锚 .chatMessages、排除侧栏、≥40 层、窗口定向、不读输入框、文档顺序、帧变不 OCR、单聊前缀、标题在正文前 |

老用例「飞书：消息列表只取视口内已渲染的行」（开关关的基座）原样保留。

## 4. 设计上值得记的三点

1. **不是「最富」而是「按名」**：web area 的 AXTitle 是模块名，`prefer` + `exclude` 两个名字就把侧栏与当前会话分开了；
   首选缺席（云文档 / 邮箱 / 弹窗）时才比谁最富，而且比完所有候选、不早退。
2. **锚到 `.chatMessages` 顺带解决了三件事**：会话头（含对方个性签名）与输入区不在区域内，深度需求从 40 降到 16，
   而且区域矩形就是聊天面板——OCR 回退（树没建起来时）的矩形也跟着对了。
3. **文档顺序是聊天的硬要求**：广度优先会先吐出所有发送者名再吐出所有正文。`readOrder` 做成区域属性、默认不变，
   Safari / Claude / Chrome 的行为一个字都没动。

## 5. 装机与下一步

- 装 0.7.2：`bash <scratchpad>/notarize_install.sh ~/Library/Caches/brosis-build/dist-app/brosis.app --skip-notarize`（已公证、已 staple，脚本里 `--skip-notarize` 只是跳过重复提交）。
- 装机后 30 分钟真实使用的验收口径（复查 §4）：`adapter:feishu.body` 原文 = 当前会话可见消息、不含其它会话预览；`windows.title` 为会话名占比 ≥ 90%；`ocr:feishu.*` / 飞书观察 < 5% 且无跨窗口内容；单次扫描 < 150 ms（三种界面实测 47–119 ms）。
- Step 3 其余（水印过滤、Chrome 帧变化 OCR、reactions 噪声）→ Step 4（开关关的路径）→ Step 5（URL）→ Step 6（会议）。
