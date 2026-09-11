# brosis

**简体中文** · [English](README.md)

**本地 macOS 活动记录器。** 记录你在哪个应用、哪个窗口、看的是什么内容，整理成可查询的时间线与台账，加密存在本机，通过 MCP 供 AI 助手检索。

一句话说清它和别的工具的区别：**数据不出本机，理解层不靠大模型。** 时间线、时长统计、模式识别全部由确定性规则生成，不调用任何模型也能用；向量检索是可选的第二层，模型也在本地跑。

```
你在屏幕上看到的  →  加密的本地数据库  →  MCP  →  你的 AI 助手
                     （从不外发）
```

---

## 目录

- [它能做什么](#它能做什么)
- [四条硬约束](#四条硬约束)
- [安装](#安装)
- [使用](#使用)
- [接入 AI 助手（MCP）](#接入-ai-助手mcp)
- [隐私与数据](#隐私与数据)
- [开发](#开发)
- [架构](#架构)
- [参考文献](#参考文献)
- [许可](#许可)

---

## 它能做什么

**记录。** 应用切换、窗口标题、URL、文件路径，以及屏幕上实际可见的正文。正文优先走 macOS 无障碍接口（AX）直接读文字；读不到的应用（Electron、自绘界面）退回到视口 OCR。只记录**当前视口内实际显示**的内容，不追溯你没滚动到的历史。

**整理。** 把零散的观察合并成会话，生成日 / 周台账、时长统计、活动模式。这一层是纯规则，可复现、可解释、零模型调用。

**检索。** 三条通道融合：精确字段（应用、URL、路径）、全文检索（SQLite FTS5，中文按二元组切分）、可选的向量语义检索。融合用加权 RRF。

**交给 AI 助手。** 内置 MCP 服务器，10 个只读工具：`search`、`get_evidence`、`get_context`、`get_timeline`、`get_day_ledger`、`get_week_ledger`、`get_patterns`、`get_item`、`recent_activity`、`list_activity`。所有带时间的工具共用一个 `period` 参数（`today`、`yesterday`、`2026-09-08..2026-09-10`、`2026-W37`、`24h` …），按服务端时区解析；每个结果都回显实际使用的窗口与服务端的 `serverToday`。

## 四条硬约束

这四条是设计前提，不是可配置项：

1. **默认不外发。** 没有云端、没有账号、没有遥测。app 自己不会主动联网——`SUEnableAutomaticChecks` 是关的，连"要不要自动检查更新"那个许可框都不弹。只有两件事会走网络，都得你点：菜单里的「检查更新…」，和在模型面板里下载嵌入模型。
2. **入库前脱敏。** 密码、验证码、令牌、密钥在**写进数据库之前**就被替换掉——库里从一开始就没有这些明文。标题和 URL 同样过脱敏（邮件标题里的验证码、URL 查询串里的 access_token 都是常见泄漏点）。
3. **存储有上限。** 日常使用**每天大约新增 30 MB**（正文与它的全文索引占八成，重度使用或开着向量索引会更多）。默认上限 10 GiB，口径是**原文净载荷**——FTS 索引、向量、WAL 都不计入，所以磁盘上的实际文件会更大。到线后先提示导出、确认后才删最旧的原文。可在设置里调，「当前用量」随时能看。
4. **app 自包含。** 所有依赖静态链接进 app bundle，不依赖构建目录、不依赖 Homebrew、不装任何后台守护进程。

另外默认就**不采集**密码管理器、钥匙串、认证器、券商与银行类应用（内置 25 个 bundle id 的清单），以及浏览器的隐私窗口。

## 安装

macOS 26 或更新（Apple Silicon）。

从 [Releases](https://github.com/AllenBall/brosis/releases) 下载 DMG，拖进「应用程序」。app 经过 Developer ID 签名与 Apple 公证，首次打开不需要绕过 Gatekeeper。

首次运行会引导你授予两项权限：

| 权限 | 用途 | 不给会怎样 |
|---|---|---|
| 辅助功能 | 读窗口标题与正文 | 只能记录应用切换，没有内容 |
| 屏幕录制 | AX 读不到时的 OCR 回退 | Electron 与自绘应用没有正文 |
| 自动化（可选） | 无障碍接口读不到网址时，向浏览器要当前标签页的地址与标题 | 部分浏览器场景缺 URL，其余不受影响 |

brosis 是菜单栏应用（无 Dock 图标）。内置 Sparkle 自动更新，签名验证失败时**拒绝更新**而不是降级放行。

## 使用

菜单栏图标下有这些入口：

**应用采集清单** — 每个应用一行，三档可选：

| 档位 | 记什么 |
|---|---|
| 不采集 | 什么都不记 |
| 只记事件 | 应用切换与窗口标题，不读正文 |
| 事件 + 内容 | 完整记录（默认） |

同一行还显示最近 7 天的观察数与完整性分布（完整 / 部分 / 不可用 / 排除），方便判断哪些应用值得留。「不可用」会进一步拆成**读空**（应用给不出文本，要靠 OCR）、**超时**、**受阻**（权限、安全输入、锁屏），三类的处置方向完全不同。

**模型** — 管理向量检索用的嵌入模型。可从 Hugging Face 下载、从本地目录导入，或关联到外部目录（例如 LM Studio 的模型目录，只记路径不复制）。支持 Qwen3-Embedding 的 0.6B / 4B / 8B 三档，面板里随时切换。

**设置** — 界面语言、磁盘上限、自动清理、定时兜底截图间隔、严格锁屏、向量检索开关、自动建索引与间隔、日均 GPU 预算。

**加密导出** — 导出为加密归档，用于备份或迁移到另一台机器。

**跨设备同步** — 可选，默认走你自己的 iCloud Drive（`iCloud Drive/brosis-sync/`）。同步的是加密后的内容，密钥不进同步目录。

全局热键：`⌃⌥⌘P` 暂停 / 继续采集，`⌃⌥⌘L` 锁定数据库。

### 界面语言

设置 → 界面语言。中文与英文，默认**跟随系统**：中文系统用中文，其余用英文。切换后已打开的窗口会关掉，重开即是新语言，不需要重启。

自检输出与命令行工具**刻意保持中文**——它们是排障用的，翻译了只会让日志和解释它们的笔记对不上号。

### 什么时候不采集

- 屏幕锁定、屏保、睡眠
- 检测到安全输入（系统正在收密码）
- 浏览器隐私窗口（事件仍记，正文、标题、URL 一律不存）
- 你手动暂停时

采集本身**不看电源状态**，电池上照常记录。接电门控只管建索引这类 GPU 重活（拔电暂停、接回继续）。

## 接入 AI 助手（MCP）

**默认自动完成。** brosis 每 30 分钟看一遍你装了哪些 harness——Claude Code、Codex CLI、Cursor、Grok CLI、ZCode、Kimi Code——给装了的那几家写好用户级配置并发授权。没装的一律不碰：不会为你根本没装的软件建出目录。不想要就在菜单栏 →「MCP 集成」里去掉那个勾，改成自己一行一行接。

**手动关掉的会一直关着。** 在那个窗口里关掉某一家会被记下来，自动集成永远不会再把它打开。而去掉总开关的勾**不会**撤销已经接好的集成——要撤请在列表里一行一行点。

优先调用各家官方 CLI 写配置，CLI 不可用时才直接改配置文件（改前备份、原子替换，文件解析不了就拒绝写并给出手动片段）。

也可以手动接：

```bash
claude mcp add brosis /Applications/brosis.app/Contents/MacOS/brosis-mcp
```

**授权是真正的闸门。** 配置文件里有条目只表示"能连上"，能不能读数据由数据库里的 `grants` 表决定，没有授权的客户端**所有工具一律拒绝**。授权可以按客户端限定可见的应用、时间窗口和字段粒度（只给摘要 / 允许原文）：

```bash
brosis-mcp admin grant add --client claude-code --fields evidence
brosis-mcp admin grant list
brosis-mcp admin audit --limit 20     # 谁读过什么（不含正文）
```

grant 是按 client id 发的，而这个名字由客户端连过来时自己报——对不上就会被全拒。所以凡是 brosis 自己写的配置，都会把 `BROSIS_CLIENT_ID` 钉成该 harness 的 id：名字对得上是设计保证的，不是碰运气。

落在这之外的情况——你手写的配置，或者经 harness 自己的 CLI 加进去的条目——MCP 集成窗口里有「学习模式」：开启 60 秒，被拒绝的连接会把自报的名字捞出来给你确认。它是人按一次、只跑 60 秒的轮询，不是常驻的后台监视。

命令行也能管：

```bash
brosis --mcp list                          # 各 harness 的配置与授权状态
brosis --mcp enable --harness claude-code
brosis --mcp auto                          # 自动集成开着没有、哪几家被手动关过
brosis --mcp auto --set off
```

## 隐私与数据

数据库用 SQLCipher 加密，密钥存在**数据保护钥匙串**里——屏幕锁定期间钥匙串不可读，所以新装的 app 在锁屏状态下打不开库，解锁后会自动重试。已经在跑的进程把密钥留在内存里，锁屏不受影响。

数据都在 `~/Library/Application Support/brosis/`。删掉这个目录就等于彻底删除，没有任何副本在别处。

单条删除、按应用删除、按时间段删除都会级联清掉全文索引与向量索引，不留孤儿行。

**在别的机器上读你的数据，需要同时拿到数据库文件和钥匙串里的密钥。** 只拷走数据库文件是打不开的。

## 开发

需要 Xcode 26（含 Metal Toolchain，用来现编 mlx 的着色器库）。仓库是两个独立的 SwiftPM 包。

```bash
# 存储核心：加密库、检索、台账、MCP 服务
swift test --package-path core

# 完整 app：构建 + 签名 + 公证前检查 + 发布闸门
bash app/build_app.sh
```

`build_app.sh` 会在签名之后把构建目录**临时改名**再跑一遍自检与嵌入自测——这道闸门保证 app 真的自包含，不会出现"靠构建目录才没崩"的产物。构建产物一律落在 `~/Library/Caches/brosis-build/`，不写进项目目录。

若 `xcode-select` 指向的是 Command Line Tools（那里没有 `metal` 编译器），脚本会自动切到 Xcode，不改你的全局设置。

### 仓库结构

| 目录 | 内容 |
|---|---|
| `app/` | 菜单栏 app：事件骨架、AX 与适配规则、OCR、模型管理、各个窗口、MCP 集成 |
| `core/` | 加密存储核心：SQLCipher、schema 与迁移、写入 / 删除 / 配额、检索、台账、同步、MCP 服务、`brosis-store` CLI |
| `tools/eval/` | 检索评测流水线：合成语料、查询集、FTS-only 与混合检索对照、阈值扫描 |
| `tools/bench/` | OCR 基准、FTS 分词对照、运行时基准 |
| `tools/proto/` | schema 原型、合成数据生成、正确性与容量测量 |
| `dist/` | DMG 打包、公证、appcast 生成 |

### 诊断工具

```bash
brosis --self-check     # 202 项自检，覆盖每一条硬约束与关键判定
brosis --ax-probe       # 量 Electron 应用的 AX 树到底给不给文本
brosis --dump-ocr       # OCR 识别结果逐行核对
```

`--ax-probe` 在排查"某个应用读不到正文"时很有用：它会打印角色分布、逐层追踪 `AXWebArea`、扫描深度与视口裁剪两个可疑参数，走的是和生产完全相同的遍历路径。
加 `--dump-webarea [<AXTitle>|all]`（如 `brosis --ax-probe com.bytedance.macos.feishu --dump-webarea messenger-chat`）则改为把目标应用每个窗口里的 `AXWebArea` 列出来，并把指定的那棵子树逐节点打出来（角色、DOM id / class、标题、文本前 60 字、frame、选中状态）——给适配规则定位器找依据用。输出含屏幕上的真实文本，别落进会提交的目录。

### 测试与自检的分工

- `swift test --package-path core` — 存储核心的单元与端到端测试
- `brosis --self-check` — 跑在真实 app bundle 里的 202 项断言，构建闸门会强制它通过

自检刻意断言**关系而不是字面量**（例如"设置读的键 == 功能自己的常量"，而不是"默认值 == 12.0"）——写死字面量恰恰会漏掉归属方改动这种真正的漂移。

## 架构

```
采集           AX 适配规则 → 视口 OCR 回退 → 入库前脱敏
  ↓
存储           SQLCipher + FTS5（中文二元组）+ sqlite-vec（int8[1024] 余弦）
  ↓
理解           会话化 → 日 / 周台账 → 活动模式        ← 纯规则，零模型
  ↓
检索           精确字段 ∪ FTS ∪ 向量  →  加权 RRF 融合
  ↓
出口           MCP（9 个只读工具，grants 授权）
```

**采集适配规则。** 不同应用的界面结构差别很大，逐个写规则：Safari、Claude 桌面版、飞书、微信各有专门规则，其余走通用规则。规则描述"正文在哪个区域、怎么读、读不到时退回什么"。

Electron 应用需要先设 `AXManualAccessibility` 才暴露无障碍树；一个窗口里往往有多个 `AXWebArea`（外壳一个、真正的应用一个、内嵌预览再一个），必须挑内容最多的那个而不是第一个。Chromium 建树是异步的，读到空树时会隔一会儿重扫。

**Chrome 系浏览器**（Chrome / Edge / Brave / Vivaldi / Arc）只认私有属性 `AXEnhancedUserInterface`，不认公开的 `AXManualAccessibility`。实测 Chrome 153 的无障碍树只有 43 个节点、全是浏览器外壳、**没有 `AXWebArea`**。所以默认路径是：正文整页 OCR，URL 从地址栏的 `AXTextField` 直接读——两件事都不需要装扩展。截图走窗口定向，别的窗口盖在上面时不会把它的像素记成网页内容；有两个窗口时按焦点窗口的矩形认，不是按面积。无痕 / 访客窗口按标题串尾识别（Chrome 的窗口 AX 标题就是无障碍标题，末尾带「（无痕）」「(Incognito)」「（访客）」「(Guest)」），命中后只记应用与时间。`chrome://`、`devtools://`、`chrome-extension://` 这类内部页不写 URL。

**`AXEnhancedUserInterface` 默认开启，可以自行关闭。** 开着时 Chrome、飞书、飞书会议都会真的建起无障碍树，正文优先读 DOM 文本（逐字准确、含滚动区外的内容、且完全不跑 OCR），读空再回退 OCR。实测：Chrome 从「43 个节点全是外壳、0 字正文」变成可读；飞书读的是当前会话所在的 `messenger-chat`（会话名 + 消息，单聊行带「我 / 对方名」前缀），会话列表侧栏整块排除；切到云文档 / 邮箱就读那个模块自己的 web area，页标题即其 AXTitle；搜索 / 转发 / 名片这类 `ModalWebViewWidget` 弹窗只记标题；走到 OCR 的部分会先剥掉平铺的「用户名 组织名」水印（学不出来时可用 `defaults write com.brosis.app adapter.watermark.text "张三 某公司"` 指定）。关掉则退回整页 OCR。Chrome 的树是按页面建的：导航后头一秒、切回隐藏超过 5 分钟的标签页时读到空树属正常，这时不 OCR、等 1.5 s 重扫（并订阅 Chromium 的 `AXLoadComplete`）；页面与停靠的 DevTools / 侧边栏同在一个窗口时挑带外部地址、面积最大的那个 web area。

⚠️ **打开前请知道代价**：该属性会让 Chromium 进入无障碍模式并镜像输入，设置它的客户端**突然断开**时，把最近缓冲的按键**重放进当时的焦点输入框**——复现用例是输入 `abcd`、退出客户端后变成 `abcdbcdbcd`，即**把你刚敲的内容重复一遍**（见 [screenpipe #3884](https://github.com/mediar-ai/screenpipe/issues/3884)；1Password、Alfred、TextExpander 中过同一个）。

风险窗口是 **brosis 退出的那一刻**（包括更新时），落点是 Chromium 系应用里当时的焦点输入框。平时开着不触发。这就是它做成开关、并把症状与触发时机写在这里的原因。

```bash
defaults write com.brosis.app ax.enhancedUserInterface -bool false  # 关掉，需重启 app
defaults delete com.brosis.app ax.enhancedUserInterface             # 回到默认（开）
```

**向量检索是可选的。** 所有尺寸的模型统一截断到 1024 维，换模型只需重建向量、不用改表。模型在本地用 mlx-swift 跑。建索引受门控：接电、温度正常、未锁定、日均 GPU 预算。没装模型时向量通道显示为未启用，精确字段与全文检索不受影响。

**schema 有版本与迁移**（当前 v9），升级时按序执行迁移，失败即回滚。

## 参考文献

架构上直接参照或反复用到的工作：

**确定性台账层的直接参照**

- *Activity Frames* — [arXiv:2608.05784](https://arxiv.org/abs/2608.05784)，代码 [nossa-y/activity-frames](https://github.com/nossa-y/activity-frames)。用零 LLM 调用把屏幕快照确定性地编译为结构化"活动帧"，可复现、可解释。本项目的会话化与台账层照这个思路做。

  **引用它时请连同适用范围一起看**：作者标注为独立研究者；论文报告的 98.4% 问答准确率来自**单用户语料上 8 天、64 个问答**，问题集中在应用、时长、排名与域名访问，不涵盖文章内容与决策原因。论文本身也区分「停留」与「注意力」，并讨论双屏时长的重复计算。本项目把它当作**可解释活动台账**的证据，不当作通用记忆质量的证明——这个区分在设计里是认真对待的：前台停留、有输入的活跃区间、未知状态分开记录，不混成一个"使用时长"。

**为什么必须 AX 与 OCR 双路径**

- V. Muryn, M. Sumyk, M. Hirna, S. Garkot, M. Shamrai, *Screen2AX: Vision-Based Approach for Automatic macOS Accessibility Generation*, [arXiv:2507.16704](https://arxiv.org/abs/2507.16704)（MacPaw Research）。实测**只有约 33% 的 macOS 应用提供完整的无障碍支持**。这条数据是本项目不敢只走 AX 的直接依据——单靠无障碍接口，三分之二的应用读不全。

**检索**

- G. V. Cormack, C. L. A. Clarke, S. Buettcher, *Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning Methods*, SIGIR 2009。多通道检索结果的融合方法；本项目融合精确字段、全文与向量三条通道，RRF 常数 k=60 取自该文。

- A. Kusupati et al., *Matryoshka Representation Learning*, [arXiv:2205.13147](https://arxiv.org/abs/2205.13147)。让同一个嵌入的前 N 维单独可用。本项目据此把 0.6B / 4B / 8B 三档模型统一截到 1024 维——换模型只需重建向量，不用改表结构。

- Qwen Team, *Qwen3 Embedding: Advancing Text Embedding and Reranking Through Foundation Models*, [arXiv:2506.05176](https://arxiv.org/abs/2506.05176)。本项目使用的嵌入模型系列（Apache 2.0）。

**采集**

- *Perceptual hash distance distributions*, [arXiv:2212.08035](https://arxiv.org/abs/2212.08035)。按需截图的帧去重阈值取自该文的距离分布数据（无关图像 pHash 归一化距离均值约 0.49，同图重压约 0.005）。

工程实现上重度依赖的项目：[SQLCipher](https://github.com/sqlcipher/sqlcipher)、[sqlite-vec](https://github.com/asg017/sqlite-vec)、[mlx-swift](https://github.com/ml-explore/mlx-swift)、[Sparkle](https://sparkle-project.org/)、[Model Context Protocol](https://modelcontextprotocol.io/)。

## 许可

[MIT](LICENSE)。

依赖各自的许可另计：SQLCipher（BSD 类）、sqlite-vec（Apache 2.0 / MIT）、mlx-swift（MIT）、Sparkle（MIT）、Qwen3-Embedding 模型权重（Apache 2.0）。
