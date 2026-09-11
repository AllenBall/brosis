# 飞书 Step 0：`--dump-webarea` 探针结果（聊天视图）

2026-09-11 11:1x，M4 Air、macOS 26.6.2、飞书 Lark 7.74.21（Chromium 143.0.7499.203）。
探针来自 **brosis 0.7.1**（本次唯一改动：`--ax-probe … --dump-webarea [<AXTitle>|all]`，
`app/Sources/brosis/AXProbe.swift` + `main.swift`；自检 251 项全过；已签名、公证 Accepted、已 staple，
产物 `~/Library/Caches/brosis-build/dist-app/brosis.app`，**尚未装到 /Applications**——装机脚本被自动模式拦下，
而探针直接从构建目录跑就有辅助功能授权：TCC 按 bundle id + 签名身份匹配，不看路径）。
只读，不开库、不截图、不弹 TCC。原始转储（含屏幕上的真实文本）在 `tools/probe/results/feishu_ax_dump_2026-09-11_chat.txt`
（该目录在 .gitignore 里）；本文只抄结构：角色、DOM id / class、frame。

方案与验收口径见 `feishu_capture_review_2026-09-11.md` §4。本文回答那里 Step 0 列的四个问题：①② 来自聊天视图（§2–3），③④ 与群聊来自 11:5x 用 computer use 切界面后的四次补充转储（§5）。

一句话：**`messenger-chat` 里所有需要的锚点都有语义化 class 名（`chatWindow_chatName`、`chatMessages`、
`js-message-item` + `message-self / message-not-self`、`lark__editor--chat`），侧栏的选中项只有哈希 class，
会话名必须从聊天头取；另外发现视口外的消息行以 1 pt 高的占位 frame 留在树里，现有视口裁剪会把它们当成可见。**

## 1. 窗口与 web area

| | |
|---|---|
| 窗口 #0 | 「WatermarkWidget」AXUnknown，frame 与主窗口完全相同，6 个节点、无 web area——**水印是一个独立的透明覆盖窗口**，AX 正文永远不含水印，只有 OCR 会看到它 |
| 窗口 #1 | 「飞书」AXStandardWindow 1471×869，焦点窗口，**两个** AXWebArea，都在窗口下第 9 层 |
| `messenger` | frame 384×780（侧栏），子树 463 节点、最深 13 层、AXStaticText 103 |
| `messenger-chat` | frame 789×780（聊天面板），子树 465 节点、**最深 30 层**、AXStaticText 46、AXTextArea 1、AXLink 1、AXButton 15 |

两个 web area 的 AXURL 都是 bundle 内 `file://…/webcontent/messenger/<name>/zh-CN.html`，AXTitle 就是 `<name>`。

## 2. `messenger-chat`：当前会话（本次是单聊）

从 web area 往下的骨架（缩进 = 层级，方括号 = 相对 web area 的深度）：

```
AXWebArea t=messenger-chat                                     [0]
  .larkc-zh-CN > #root > #messenger.mac > .lark-chat.main-box   [1–4]
    .lark-chat-right-box > .lark-chat-right                     [5–6]
      .chatContainer.post-container.p2pChat                     [7]   ← 群聊时预期不是 p2pChat
        .chatSidebar > .chatSidebar_content > .chatContainer_contentWrapper   [8–10]
          .chatContainer__headerWrapper   789×68               [11]  ← 会话头
            .chatNewWindow_headerMain
              .chatWindow_avatar_wrapper
              .chatWindow_chatName > AXStaticText              [13–14] ← **会话名**（49×24）
              .chatWindow_header_metas > .chatNewWindow_chatterDescription   ← 对方个人签名 + AXLink，**不要**
              .collapse-buttons.chatWindow_rightOperator        ← 右上角一排图标按钮
          .chatSidebar > .chatSidebar_content                   [11–12]
            .larkw-drag-panel   789×643                         [13]
              .chatBanners.optimize（789×0）
              .chatMessageContainer > .chatHeaderNav（789×0）   [14]
                .chatMessages > .messageContainer > .scroller   [15–17] ← **消息列表根**（建议锚 `chatMessages`）
                  .scroll_holder（789×2）
                  .list_items                                   [18]
                    .messageList-row-wrapper > .messageItem-wrapper   [19–20]
                      #<消息 id> .js-message-item.message-item.{message-self|message-not-self}.message-is-p2p.text-message…   [21]
                        .message-left（头像 62 pt）
                        .message-right > .message-section > #<同一 id> .MessageContextMenuTrigger…   [22–24]
                          .quote_reply_title > .referencePreviewTitle__name（「回复 X」「:」）+ .referencePreviewTitle__message   ← 引用
                          .message-content-container > .message-content > .limit-height-container   [25–27]
                            .richTextContainer > AXStaticText（正文）         [28–29]
                              .larkw-emoji__wrapper > AXImage d=「呲牙」 + AXStaticText「[呲牙]」   [29–31]
                          .message-reactions > .reaction-item > .reaction-user > AXStaticText（点表情的人名）
                          .message-section-right > .read-status-bar（已读图标）
                        .tips.reply-meta-tips > .tips-description > AXStaticText「3 条回复」
                    <无 class> > .divider.date-divider > AXStaticText（「9月8日」「昨天」「10:22」）
                  .messageList-footer（789×18）
            .lark__editor--chat   749×48，y=783                   [13]  ← **输入区**
              .outerdocbody > AXTextArea.zone-container.editor-kit-container.innerdocbody  v=「发送给 <对方名>⏎…」（占位文案）
              .toolbar-item ×N、.send-button-container、.schedule-button-container
              .editor__tip--enter.editor__tip--hidden > AXStaticText「Shift + Enter 换行」   ← class 说 hidden，树里仍有 frame 84×13
      #lark-chat-menu（1×780）、#__overlay-container__ / toast / modal 容器（0×0）、#pp_popupContainer（789×1）
```

要点：

- **会话名**：`.chatWindow_chatName > AXStaticText`，稳定、语义化。同一头部里的 `.chatNewWindow_chatterDescription`
  是对方的个人签名（带 AXLink），不能混进标题。
- **消息行**：单聊时行内**没有发送者名**，归属只能靠行的 class：`message-self`（自己）/ `message-not-self`（对方）。
  群聊预期多一个名字节点（待验）。
- **正文**：`.richTextContainer > AXStaticText`；emoji 是 AXImage（AXDescription 是中文名）+ 一个「[呲牙]」文本。
- **引用回复**：`.quote_reply_title` 给「回复 X : 被引用的话」，是有用上下文，保留。
- **噪声**：`.message-reactions`（点表情的人名）、`.read-status-bar`、`.tips`（「3 条回复」）、`.editor__tip--hidden`、
  `.chatNewWindow_chatterDescription`、输入框占位文案「发送给 X」。
- **深度**：正文 AXStaticText 在 web area 下第 **29–31** 层。规则现在 `maxDepth = 14`（相对区域根）——
  改读 `messenger-chat` 后 14 层在 `.chatMessages` 上面就停了，会读到 **0 字符**；Chrome 的 30 也只是刚好够，
  飞书要 **≥ 40**。若把区域根锚到 `.chatMessages`，正文只在其下第 14–16 层。
- **frame 探测预算**：子树 356 个 AXGroup，`shouldProbeFrame` 对 AXGroup 一律探 frame，会超过 `maxFrameProbes = 300`
  → 停止裁视口并降成 partial。要么只探文本节点与 `.messageList-row-wrapper`，要么把预算提到 1000。

### 2.1 新发现：虚拟列表的 1 pt 占位行

`.list_items` 里视口上方（已滚过去）的消息行**仍在树里**，但 frame 是 `789×1`，全部叠在列表顶部 y=140，
它们的 AXStaticText 也是 `…×1`。本次 9 行消息里 **5 行**是这种占位。`Viewport.isVisible` 只把零面积当不可见，
`789×1` 与视口相交 → 判成可见 → 这些**用户看不见**的历史消息会被记成视口内正文，违反 3.3。
Step 1 必须加一条：文本节点 frame 高度 ≤ 2 pt 视为未渲染（或整行 `.messageList-row-wrapper` 高度 ≤ 2 就整行剪掉）。

## 3. `messenger`：侧栏

```
AXWebArea t=messenger
  #root > … > .a11y_feed_header_menu_button（按钮）+ AXStaticText「消息」
    .feed-quickswitch（置顶快捷 7 个 .feed-shortcut-item：头像 + 名字）
    .scroller.feed-main-list.a11y_feed_main_list.lark_feedMainList   384×662
      <无 class> > ._13e3ffd > .a11y_feed_card_item._1e0a457[.<哈希>…]   369×60
        .c90c31ea > .c7ac3851
          .avatarWithBadge（未读数 AXStaticText）
          ._9f5c521 > AXStaticText（会话名）      ._97ba617 > AXStaticText（时间）
          AXStaticText（发送者）AXStaticText「:」AXStaticText（预览）   或 emoji + 预览
          ._717cd67 > … > .a11y_feed_item_done（「标记已读」按钮）
```

- 19 张 `.a11y_feed_card_item` 卡；**当前打开的那张**只多一个哈希 class（本次 `_2a5a61c`），
  没有 `aria-selected` / AXSelected / 语义 class → **不能用它定位「当前会话」**。会话名从聊天头取（§2）。
- 上一轮 `--ax-probe` 看到的 AXRadioButton×19 不在这两个 web area 里（应是窗口左侧原生导航栏）。
- 侧栏内容就是 evidence 17199 那种「会话名 : 预览 时间」清单，Step 1 用 `excludeTitles: ["messenger"]` 整块排除。

## 4. 对 Step 1 设计的直接输入

| 项 | 依据 | 建议 |
|---|---|---|
| 定位当前会话 | AXWebArea AXTitle = `messenger-chat` 稳定 | 新增定位器 `.webArea(title:)`；找不到时（云文档 / 弹窗）退回「最富且 AXTitle ∉ {messenger, messenger-chat}」 |
| 正文根 | `.chatMessages`（语义 class） | 定位器再支持「web area 内按 AXDOMClassList 下钻」，根锚到 `chatMessages`：自动排除会话头与输入区，深度需求降到 16 |
| 会话名 | `.chatWindow_chatName > AXStaticText` | 独立 `.title` 区域，走 `ChatTitle` 写 `windows.title` |
| 发送者归属 | 行 class `message-self / message-not-self`（单聊）| 引擎读到 `.message-item` 行时按 class 加前缀「我：/ <对方名>：」；群聊待验后补名字节点 |
| 视口 | 占位行 `×1` | `Viewport.isVisible` 加高度 ≤ 2 pt ⇒ 不可见；或按行剪 |
| 预算 | 356 AXGroup | 只探文本节点 + 行容器的 frame；`maxDepth` 相对区域根 ≥ 20（锚 chatMessages）或 ≥ 40（锚 web area） |
| 排除 | AXTextArea、`.message-reactions`、`.editor__tip--hidden` | `excludeRoles` + `pruneClasses` |
| 水印 | 独立覆盖窗口，不在 AX 正文里 | 只需在 OCR 侧过滤（Step 3） |

读 `AXDOMClassList` 每个节点多一次 AX 调用；只在声明了 class 锚点的规则里、且只对 AXGroup 读，465 节点约 +25 ms。

## 5. 补充转储：群聊 / 云文档 / 邮箱 / 搜索弹窗（11:5x，computer use 切界面）

用户让我用 computer use 代替操作。飞书当时已经开着一个群聊；随后我点了「云文档」「邮箱」（误点）、搜索框，
最后切回「消息」。原始转储：`tools/probe/results/feishu_ax_dump_2026-09-11_{group,docs,mail,modal}.txt`（不入库）。
操作副作用：在云文档侧栏误把「置顶文档」折叠过一次，已展开还原；在邮箱视图误点开了一封（已读）邮件的阅读面板；
没有发送、没有输入任何内容。

### 5.1 群聊（`messenger-chat`，386 节点、最深 32 层）

与单聊的差别，全在语义 class 上：

| 项 | 结构 |
|---|---|
| 容器 | `.chatContainer.post-container`（单聊多一个 `p2pChat`） |
| 会话头 | `.chatWindow_chatName > AXStaticText`（群名）；`.chatNewWindow_count`（人数）、`.chatWindow_botCount`（机器人数）；头部下面还有一排会话内标签页 `.chat-tab-item[.chat-tab-active] > .chat-tab-name`（「消息」+ 关联文档） |
| **发送者** | 每条消息 `.message-right > .message-info > .message-info-name > AXStaticText`；旁边可能有 `.ud__tag__content`（「机器人」标签）与 `.description`（机器人描述） |
| 系统消息 | `.js-message-item.system-text-background`（无 `.message-item`），正文由若干 `.user-name > AXStaticText` 与纯 AXStaticText 拼成「X 发起群聊，并邀请 Y，Z 加入」 |
| 卡片消息 | `.text-card-message.card-message > … > .universal-card-root`：标题 AXStaticText + `.universal-card-markdown__children_wrapper`（AXStaticText / `.universal-card-markdown-link > AXLink`） |
| 富文本 | `.post-message`；图片 `.rich-text-image > … > AXImage`，其 AXDescription 是**图片资源 URL**（`/image?resource_type=image&key=…`），不要当正文记 |
| @ 提及 | `.mention > AXStaticText「@X」` 内联在正文里，正文本身是同级 AXStaticText |
| 话题回复 | `.tips.reply-meta-tips > .tips-description > AXStaticText「N 条回复」` |
| 占位行 | 8 行里 **5 行**是 `×1` 占位（同 §2.1） |

结论：群聊发送者名有稳定锚点 `.message-info-name`；单聊没有这个节点，只能靠行 class `message-self / message-not-self`。
两种情况引擎都能在**行级**决定前缀：有 `.message-info-name` 用它，没有就按 class 给「我」/ 会话名。

### 5.2 云文档（主页）

树里**只剩一个** web area：AXTitle「主页 - 飞书云文档」、URL `https://<租户>.feishu.cn/drive/home/?larkTabName=space`，
1145 节点、最深 19 层；`messenger` 与 `messenger-chat` **都不在树里**（BrowserView 被换掉了）。
所以 Step 1 的「排除 `messenger`、其余取最富」在云文档下自然落到文档页；web area 的 AXTitle 本身就是页标题，
可以直接当 `windows.title`。主页是文件列表（`.table-view-row` ×20，每行标题 / 位置 / 所有者 / 时间），
文档编辑器本身**没量到**（两次点击文档行都没打开，只触发了 hover），按同一模式推断是一个以文档名为 AXTitle 的 web area，待 Step 1 装机后用真实使用验证。

### 5.3 邮箱

同样只有一个 web area：AXTitle「mail」、URL `file://…/webcontent/mail/mail/zh-CN.html#/lms/lms-normal`，555 节点、最深 22 层。
左侧文件夹栏、中间 `.mail-app-message-list-container` 列表、右侧阅读面板都在这一棵树里。
按现有规则会整棵读（列表 + 正文），与邮件客户端的口径一致，先不特殊处理。

### 5.4 搜索弹窗（⌘K）

- 弹窗是**独立窗口**：AXDialog，标题 `ModalWebViewWidget - search:search-command-bar:default`，frame 与主窗口完全相同；
  里面一个 web area「search-command-bar」（`file://…/search/search-command-bar/zh-CN.html?paramsKey=…`），195 节点。
- 弹窗开着时，主窗口「飞书」的树里也**只剩这同一个** `search-command-bar`，两个 messenger 都不见了。
- 内容是搜索历史、推荐问题、联系人列表——全是噪声。库里 `titles` 出现过的 `…messenger-modals:transmitModal…`（转发）
  应是同一模式；转发弹窗要 hover 才能打开，这次没量。
- 建议：飞书规则对窗口标题以 `ModalWebViewWidget - ` 开头的窗口**只记标题、不读正文也不 OCR**。

### 5.5 补充对 Step 1 设计的影响

| 项 | 依据 | 建议 |
|---|---|---|
| web area 选择 | 每个模块一个以模块名为 AXTitle 的 web area；云文档页以页标题为 AXTitle | 优先 `messenger-chat`；否则「最富且 AXTitle ≠ messenger」；把选中 web area 的 AXTitle 记进事件 |
| 发送者 | 群聊 `.message-info-name`，单聊只有行 class | 行级前缀：名字节点 > `message-self`→「我」/ `message-not-self`→会话名 |
| 图片 | AXImage 的 AXDescription 是资源 URL | `readSubtree` 本来只收文本角色，不会收 AXImage；`collectRowText` 会收 AXImage 的 visibleText，**改读 messenger-chat 时不要用 `.axRows`** |
| 弹窗 | 独立 AXDialog 窗口 | 标题前缀 `ModalWebViewWidget - ` ⇒ 只记标题 |
| 会话内标签页 | `.chat-tab-item.chat-tab-active` | 当前标签不是「消息」时（看关联文档），正文来自另一个 web area，走上面的兜底 |
