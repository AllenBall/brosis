# M1 第二轮 b 批 · T8：应用适配器与视口 OCR

- 日期：2026-09-08
- 对应：`docs/实施计划.md` 3.3（内容采集、飞书 / 微信适配器、OCR 触发条件、帧门控、采样审计、状态分离）、D24（OCR 策略）、2.4（采集口径）、3.2（`capture_method` / `completeness` / `visible_range`）
- 输入数据：`tools/bench/results/m0_closeout_2026-09-07.md` §2.2 的真实 AX 覆盖数据；`tools/bench/results/ocr_bench_2026-09-06.md`（E8 / D24）
- 机器：Apple M4 Air / 16 GiB / 无风扇，macOS 26.6.2，Swift 6.3.3（语言模式 v6）
- 单位：MiB = 2²⁰、GiB = 2³⁰
- 原始输出（不进仓库）：
  - 第一轮：`~/Library/Caches/brosis-build/m1-adapters/results/`
  - **修复轮（本文件现在的数字全部来自这里）**：`~/Library/Caches/brosis-build/m1-adapters-fix/results/`
    - `core_tests.txt`（core 126 个用例）、`build_app.log`（构建 + 签名）、`self_check.txt`（76 项自检）、`self_check_time.txt`、`dump_vectors.md`（11 节判定表）、`dump_ocr.md`（样张真值 vs 识别原文）
    - 变异检验：`mut_stale_selfcheck.txt`、`mut_fresh_selfcheck.txt`、`mut_M1_selfcheck.txt`（副本在 `~/Library/Caches/brosis-build/m1-adapters-fix/mut/`）
  - **换一个全新 scratch 从零重建的复核**：`~/Library/Caches/brosis-build/m1-adapters-fix/final/results/`（`build_app.log` 退出 0 零 warning、`self_check.txt` 76 PASS / 0 FAIL / 0 SKIP、`self_check_time.txt` real 1.78、`dump_vectors.md` 11 节 0 FAIL、`core_tests_rerun.txt` 126/126）

---

## 1. 做了什么

M0 的真实数据把这件事的必要性摆得很清楚（`m0_closeout` §2.2）：**停留时间第一的 Claude 桌面版 AX 正文 0 字符 / 74 条观察，飞书 24 条观察合计只有 156 字符，微信 0 字符且 6 条里 2 条超时**。所以本轮做的是「让采集端知道每个应用的正文长在哪、读不到就认图、并且只记屏幕上真的看得见的那部分」。

### 1.1 适配规则引擎（`app/Sources/brosis/Adapters/`）

- **`AXNodeSource` 协议**把「读一个 AX 节点」抽出来，两个实现：真实的 `LiveAXNode`（包 `AXUIElement`）与测试用的 `SyntheticAXNode`（内存合成树）。**判定逻辑一行都不知道 AX 的存在**，所以全部用例走合成树，不启动任何应用、不发 AX 消息、不需要辅助功能权限。
- **规则是纯数据**（`AdapterRule` / `RegionRule`）：区域定位（角色 / 子角色 / `AXIdentifier` / 角色路径 / 窗口内相对矩形 / 整窗口）、读取方式（`ax_value` / `ax_subtree` / `ax_rows` / `ocr`）、视口处理、新鲜度、字符上限、BFS 限额、frame 探测预算、已知局限。
- **可见范围**三层，精度从高到低：① `AXVisibleCharacterRange` 可用时优先用它裁；② 否则元素 frame 与窗口可见区域相交，**容器整块在视口外就把整棵子树一次剪掉**（回滚区最大的开销就是这么省的）；③ **读不到 frame 一律按可见处理**——宁可多存，不因为读不到坐标丢证据。视口外与回滚区的节点计数写进 `observations.visible_range`（只有形状，没有正文）。
- **新鲜度**：每次扫描把「区域名 → 文本」留给 `CaptureCoordinator`，下一次同应用同区域比对，决定第二类 OCR 触发条件里的「AX 值有没有变」。

### 1.2 首批规则（4 条 + 兜底）

见下面第 3 节的规则表。

### 1.3 视口 OCR（`app/Sources/brosis/OCR/`）

- 挂点是 `CaptureController.analyze` 拿到 `CGImage` 的那一刻。裁剪把 **AX 坐标 → 这台显示器的局部点 → 像素**（AX 与 `CGDisplayBounds` 同一套：原点主屏左上、y 向下，所以只减原点、乘 `scale`；`CGImage.cropping` 也是左上原点，不需要翻转）。矩形落在**另一块屏**上时相减为负、与图像不相交 → 返回 nil，不瞎裁。
- Vision 参数按 D24 定死：`.accurate`、`zh-Hans` + `en-US`、`usesLanguageCorrection = false`；正文类区域超过区域点宽 2 倍才降到 1x（D24 实测降采样不省时间，所以默认不主动降），`kind = code` 的区域**不降采样**。**采集端不做 NFKC 折叠**（折叠只在索引侧，M1 T2/T3 定案）。
- 阅读顺序按 `boundingBox` **行聚类**重建：容差 = `median(行高) × 0.6`（比 `ocr_bench` 的固定绝对容差更适合采集端——顶部标题条 40 pt 与聊天面板 600 pt 差得太远）。
- **低置信标记（D24）**：短哈希、纯十六进制、`0x…` 内存地址、大小写混排的长不透明串被数出来，条数写进 `occurrences.note`，片段 `confidence` 写 Vision 按字符数加权的平均置信度。文本照样入库（它确实在屏幕上），但不作可引用的证据。

### 1.4 OCR 触发条件（**只有三类**）与频率限制

判定是纯函数 `OCRTriggerGate.reason(...)`，限流是有状态的 `allow(key:reason:now:)`——分开是为了让三类条件的用例不依赖时钟。默认同一「bundle id + 区域名」最少间隔 **5 s**（`capture.ocrMinInterval`，下限 1 s）。

### 1.5 completeness 真判定

M0 时期只有 `partial` / `unavailable` 两个占位值，**一条 `complete` 都没有**。现在四态各有出处（第 5 节）。

### 1.6 采样审计（core schema v3）

AX 非空的观察每 **50** 次（`capture.auditEvery`，0 = 关）取一次全窗口 OCR 对照，写 core 新表 `capture_audit` 与一条 `runtime_event:capture_audit`。覆盖率口径见第 6 节。低于 **0.6**（`capture.coverageThreshold`）就把该应用标成「覆盖检查失败」，下一轮触发第三类 OCR。

### 1.7 修复轮（R2 验收反馈，2026-09-08）

验收判定 `pass = false`，共列 14 条问题：**1 条阻塞 + 9 条非阻塞已修，4 条记录不改**（逐条见第 10 节）。
最要紧的那条：**`handleFrame` 用的是上一次 AX 扫描留下的上下文，却不核当前前台应用是谁**，
而私密浏览 / AX 超时或读不到焦点窗口 / 「只记事件」档这三支**根本不扫描、也不清上下文**，
截图那条通路并不知道，照样出图并调 `handleFrame`——于是微信（或飞书、AX 为空的 Claude）
之后切到 Safari 无痕窗口，下一帧就会把无痕页面上落在微信 `chat_panel` 矩形里的正文
**以微信的身份、`capture_method = ocr` 入库**。修法是两道：事前 `EventSkeleton` 在那三支里
`clearContext()`，事到临头 `handleFrame` 再核一次 bundle id，对不上就整帧不处理并丢掉上下文。

### 1.8 core 接口

- `TextFragment` 加两个**可选**字段 `confidence` / `note`（老写法 `TextFragment(text:region:)` 一字不改照样编译，有向后兼容用例）。
- schema **v2 → v3**：新表 `capture_audit`、`occurrences` 加两个可空列 `confidence` / `note`。迁移建表与加列都**先查再做**，可以被中断后重跑。
- `CaptureCoverage`（覆盖率口径）、`Store.appendCaptureAudit` / `captureAuditTail` / `captureAuditCount` / `captureCoverageByApp`、`maintenance()` 按 `captureAuditRetentionDays`（默认 90 天）滚动清理。

---

## 2. 怎么跑

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # xcode-select 指向 CLT，必须这么写

# core：126 个用例（T8 新增 CaptureAuditTests 13 个）
swift test --package-path core --scratch-path ~/Library/Caches/brosis-build/m1-adapters-fix/core

# app：构建 + 组装 + Developer ID 签名（产物不落项目目录）
SCRATCH="$HOME/Library/Caches/brosis-build/m1-adapters-fix/app" ./app/build_app.sh

# 自检 76 项（不触发任何 TCC、不碰钥匙串；Vision 是本地推理，对自绘位图直接跑）
APP="$HOME/Library/Caches/brosis-build/m1-adapters-fix/app/brosis.app/Contents/MacOS/brosis"
"$APP" --self-check

# 判定表转储（11 节）与 OCR 原文转储
"$APP" --dump-vectors
"$APP" --dump-ocr
```

---

## 3. 四个应用的规则表

| 规则 id | 应用 | Electron | 区域（定位 → 读取） | 视口裁剪 | 触发 OCR |
|---|---|---|---|---|---|
| `safari` | Safari、Safari 技术预览 | 否 | `web_area`：`role=AXWebArea` → `ax_subtree`（必需） | 正文区域裁 | 不触发 |
| `claude_desktop` | Claude 桌面版 | **是** | `conversation`：`role=AXWebArea` → `ax_subtree`（必需，**允许回退 OCR**） | 裁 | AX 读到空时回退 |
| `feishu` | 飞书 / Lark（3 个 bundle id） | **是** | `message_list`：`role=AXList` → `ax_rows`（必需，**允许回退 OCR**）<br>`conversation_title`：窗口相对矩形 `0.22,0.00,0.78,0.08` → `ocr`（非必需） | 裁 | 会话名恒 OCR；消息列表读空时回退 |
| `wechat` | 微信（2 个 bundle id） | 否 | `chat_panel`：相对矩形 `0.22,0.08,0.78,0.70` → `ocr`（必需）<br>`conversation_title`：相对矩形 `0.22,0.00,0.78,0.08` → `ocr`（非必需） | 裁 | **两块都恒 OCR** |
| `generic` | 兜底（含访达等有收紧限额的应用） | 否 | `window`：整窗口 → `ax_subtree`（必需） | 裁 | 不触发 |

**限额**：Safari 与兜底 1500 节点 / 12 层（访达仍是 400 / 6，兜底规则继承 `AX.bfsLimits`）；Claude 与飞书 1200 / 14；微信 300 / 6（反正不读 AX）。所有规则的 **frame 探测上限 300 次**（= 最多 600 条 AX 消息），且只对「带正文的节点」与「滚动 / 列表类容器」问坐标。

### 各规则的已知局限（原样进 `app/README.md` 8.6 与 `--dump-vectors` 第 8 节）

| 规则 | 局限 |
|---|---|
| `safari` | AXWebArea 找不到时（PDF 预览、部分扩展页）退回整窗口 BFS；跨 iframe 的正文顺序按 AX 树顺序，不是视觉顺序。**URL 不在规则里**：它由事件骨架读 `kAXURL` 进 `observations.url`（修复轮删掉了原来那个读 `kAXValue` 的 `url` 区域，见第 10 节第 8 条） |
| `claude_desktop` | 必须先设 `AXManualAccessibility`（M0 没设时正文为 0）；代码块是等宽小字，OCR 回退时按 D24 不降采样；折叠起来的长回复只记展开的部分 |
| `feishu` | Electron 但框架被改名成 `Lark Framework.framework`，通用检测抓不到，**只能靠显式 bundle id 清单**；只记视口内已渲染的消息，**不追溯未打开的会话与未滚动到的历史**；图片 / 文件 / 语音 / 通话只有屏幕上显示的文字才可能被 OCR；发送者与时间取自行内子元素，行结构变了就退化成整行文本 |
| `wechat` | 相对矩形是按三栏布局估的，**用户改窗口比例或开浮层会偏**（真机必核）；主窗口标题恒为「微信」，会话名只能从顶部区域 OCR；语音只记 `[语音]`；支付 / 转账 / 红包与聊天一起记录，不特殊处理（D14 已定） |
| `generic` | 就是 M0 那套四角色 BFS，唯一差别是加了视口裁剪；不触发 OCR |

---

## 4. OCR 触发条件（三类 + 反例）实测

`--dump-vectors` 第 9 节，7 条全 PASS：

| # | 用例 | 规则声明 | 允许回退 | AX 空 | AX 变了 | 帧变化 | 覆盖失败 | 期望 = 实得 |
|---|---|---|---|---|---|---|---|---|
| 1 | ① 规则声明 AX 不可用（微信聊天面板） | true | false | true | false | false | false | `rule_declared` |
| 2 | ① 规则允许回退且 AX 读到空（Claude 桌面版） | false | true | true | false | false | false | `rule_declared` |
| 3 | ② 帧变化超阈值 + AX 值未变 | false | false | false | false | true | false | `frame_changed_ax_stable` |
| 4 | ② **反例**：帧变化 + AX 值也变了 | false | false | false | true | true | false | **不触发** |
| 5 | ② **反例**：AX 值未变但帧也没变 | false | false | false | false | false | false | **不触发** |
| 6 | ③ 覆盖检查失败 | false | false | false | true | false | true | `coverage_failed` |
| 7 | **反例**：什么条件都不满足 | false | false | true | true | false | false | **不触发** |

**频率限制实测**（自检项）：首次放行 → 2.5 s 后同区域被限（`rate_limited`）→ 同一应用**别的区域**不受影响 → 超过 5 s 再放行；被限次数计进统计，**不推进时钟**（否则间隔会被越推越远）。

**帧门控怎么接进来**：`CaptureController.analyze` 先把 `gated` 送给协调者（`gated == false` = 这一帧变化超阈值，即汉明 > 6 或面积 ≥ 2%），事件骨架下一次扫描时**读一次消费一次**。第二类触发条件排出来的请求，只在真的有变化的那一帧才执行。

---

## 5. completeness 四态

| 状态 | 谁判的 | 条件 | 自检用例 |
|---|---|---|---|
| `complete` | `AdapterEngine` | 必需区域全部读到，且没有视口外内容、没命中限额、没被 `AXVisibleCharacterRange` 裁过、没有待办 OCR | 合成「一整页都在视口里」的树 → `complete` |
| `partial` | `AdapterEngine` | 读到了一些，但上面任意一条成立 | Safari 合成树（回滚区 + 视口下方各有一个文本节点被丢掉）→ `partial` |
| `unavailable` | `AdapterEngine` | 一个字都没读到（含读不到焦点窗口） | Claude 的 **M0 实测形态**（树在但没有文本节点）→ `unavailable` |
| `excluded` | `EventSkeleton` | 3.12 的「不采集」/「只记事件」档，或私密浏览命中——**读都不读**，轮不到适配器判 | `eventsOnly` → `excluded`；`eventsAndContent` + 私密浏览 → `excluded`；`eventsAndContent` + 非私密 → 不排除 |

OCR 那条观察单独判：所有请求的区域都认出东西且平均置信度 ≥ 0.5 → `complete`，否则 `partial`。

**入库形状**：`occurrences.region` 从裸角色名换成带来源前缀的区域名——`adapter:<规则 id>.<区域名>` / `ocr:<规则 id>.<区域名>`；`observations.capture_method` 记 `ax`（兜底规则）/ `adapter` / `ocr` / `mixed`。

**OCR 侧的新鲜度（修复轮补的）**：同一个「bundle id + 区域名」认出来的正文与上一次**逐字节相同**就不写第二条观察（计数进 `ocrUnchanged`）。AX 侧的观察照写，所以时间线不缺段；省掉的是重复的 `ocr` 正文行。

---

## 6. 采样审计口径

> 覆盖率 = **AX 文本切出的 token 里，有多少比例能在 OCR 文本里找到**。

三步，两边完全对称：① NFKC 折叠（与索引侧同一个 `TextPipeline.foldForIndex`）；② 去掉全部空白与标点符号，只留字母 / 数字 / 汉字；③ 汉字连续段按**字符 bigram** 切（与 D22 的 FTS 预处理同一个切法），非汉字段整段成词。命中判定用**子串**，AX 侧 token **先去重**。

**为什么不是字符数之比**：AX 与 OCR 的空白、换行、标点几乎从不一致——AX 把一段正文拆成几十个节点用 `\n` 拼，OCR 按视觉行分行，而 accurate 模型会把半角括号 / 冒号 / 逗号认成全角（E8 实测，本轮 `--dump-ocr` 再次复现）。用字符数比会算出一堆假的「覆盖不足」；用子串而不是集合相等，是因为 OCR 侧会多出 AX 读不到的东西（图片里的字、被 AX 漏掉的行），多出来的不该扣分。`axTokens == 0` 时覆盖率定义为 **0**（不是 NaN、不是 1）。

`capture_audit` 每行：`ts / observation_id（**弱引用，没有外键**）/ app / ax_chars / ocr_chars / ax_tokens / hit_tokens / coverage / method / region / elapsed_ms`。**不存正文**；不参与 D17 同步、不进删除级联；`maintenance()` 按 90 天滚动清理。观察被配额过期物理删掉之后审计行仍在（有用例）。

---

## 7. 实测数字

### 7.1 core

| 项 | 值 | 出处 |
|---|---|---|
| `swift test --package-path core` | **126 个用例，0 失败，0 warning**（15.8 s） | `core_tests.txt` |
| 其中 T8 新增 | `CaptureAuditTests` **13 个**（修复轮补了一条：NFKC 折叠这一步单独有用例） | 同上 |
| schema 版本 | v2 → **v3**；`expectedTables` 从 18 张变 19 张 | `Schema.swift` |

> 复跑说明：并行有另一个代理在编译时，`IPCProtocolTests.testServerSurvivesPeerHangUpBeforeReadingResponse` 会失败（它靠 `usleep(400_000)` 等服务端写完 64 KiB 响应，机器忙时不够）。第一轮遇到过一次，修复轮在 `final` 那次全新 scratch 复跑时又遇到一次（`final/results/core_tests.txt`：126 个用例 2 处断言失败，都在这一个用例里）。**与 T8 无关**：单独复跑 3/3 通过（1.42–1.44 s），机器空闲时整轮 **126/126 通过**（`final/results/core_tests_rerun.txt`、`results/core_tests.txt`）。这是一条既有的时间敏感用例，建议后续把它的等待改成条件轮询。

### 7.2 app

| 项 | 值 | 出处 |
|---|---|---|
| `build_app.sh` | 退出码 0，**零 warning**，Developer ID 签名 + `--verify --deep --strict` 通过 | `build_app.log` |
| `--self-check`（从签名后的 `.app` 跑） | **76 项 PASS / 0 FAIL / 0 SKIP**，退出码 0 | `self_check.txt` |
| 其中 T8 新增 | **21 项**（规则路由 1 + 五条规则用例 5 + 视口 7 条 1 + 可见范围 5 条 1 + 四态 1 + 触发条件 7 条 1 + 限流 1 + 阅读顺序 3 条 1 + 低置信 1 + 气泡归属 1 + 裁剪坐标 1 + OCR 冒烟 1 + 覆盖率口径 1 + 端到端 4）——**修复轮新增的 2 项是「陈旧上下文」与「OCR 新鲜度」** | 同上 |
| 自检耗时 | **real 1.83 s**（10 次 Vision 识别，比修复前多 2 次） | `self_check_time.txt` |
| `--dump-vectors` 节数 | 7 → **11** | `dump_vectors.md` |

### 7.3 视口 OCR 自绘样张基准

口径与 `tools/bench/ocr_bench.swift` 对齐：CER = 双方按行归一化空白后的字符级 Levenshtein ÷ 归一化真值字符数；中文行 CER 只统计含汉字的行；两个尺寸是**同一张位图**高质量下采样（不重新排版）。

| 样张 | 尺寸 | 像素 | 无标点标识符**严格**召回 | 带标点标识符 折叠 / 严格 | CER | 中文行 CER | 平均置信度 | 耗时 |
|---|---|---|---:|---:|---:|---:|---:|---:|
| 中英混排正文 | 2x | 1728×1120 | **1.000** | 1.000 / 0.000 | 0.0360 | 0.0368 | 0.789 | 344 ms |
| 中英混排正文 | 1x | 864×560 | **1.000** | 1.000 / 0.000 | 0.0383 | 0.0391 | 0.677 | 182 ms |
| 代码小字（等宽 11.5 pt @2x） | 2x | 1728×1120 | **1.000** | 1.000 / 0.000 | 0.0631 | 0.0000 | 0.501 | 181 ms |
| 代码小字 | 1x | 864×560 | 1.000 | 1.000 / 0.000 | 0.0678 | 0.0000 | 0.471 | 165 ms |
| 深色背景浅色字 | 2x | 1728×1120 | **1.000** | 1.000 / 1.000 | 0.0204 | 0.0211 | 0.701 | 105 ms |
| 深色背景浅色字 | 1x | 864×560 | **1.000** | 1.000 / 1.000 | 0.0340 | 0.0352 | 0.843 | 87 ms |

判定线：**无标点标识符严格召回 ≥ 0.9**、**带标点标识符按检索侧折叠口径召回 ≥ 0.9**、**中文行 CER ≤ 0.20**；1x 的代码小字按 D24 本来就不该用，只报数不断言（它这轮其实也过了）。三次复跑 CER 与召回**逐位相同**，只有 ms 有抖动；上表 ms 取自修复轮的 `self_check.txt`，确定性列（召回 / CER / 置信度）与第一轮、与验收者的复跑**逐位相同**。

修复轮还让 `--dump-ocr` 把**带标点组逐字节没召回的那几个标识符**也打出来（第一轮只打了无标点组，
所以"看得到没召回的是谁"这句话当时不成立）：`code_small` 打出 `VNRecognizeTextRequest()` /
`VNImageRequestHandler(cgImage:` / `ReadingOrder.text(items)`，`body_mixed` 打出
`recognizeViewport(in:kind:)` / `kTCCServiceScreenCapture`，正是下面这段引注说的那两类。

> **「严格子串召回」为什么要拆成两列——这是本轮唯一一处对任务口径的偏离，理由在这里。**
> 任务要求「标识符 token 严格子串召回 ≥ 0.9」。实测发现带 ASCII 标点的标识符**逐字节召回是 0.000**，而 CER 只有 3.6%——`--dump-ocr` 的原文说明了原因，accurate 模型把括号与冒号认成了全角：
> `recognizeViewport(in:kind:)` → `recognizeViewport（in:kind：）`；`ReadingOrder.text(items)` → `ReadingOrder.text （items）`；`VNRecognizeTextRequest()` → `VNRecognizeTextRequest（）`。
> 这正是 D24 / E8 早就实测并写进决策的行为，也正是本项目**索引侧 NFKC 折叠**要解决的事（3.4 / M1 T2、T3：`text_versions` 存原文，FTS 预处理列与查询串都折叠，`unicode61` 还大小写不敏感）。把「逐字节 ≥ 0.9」当成门槛等于断言一件 E8 已经证否的事。
> 所以拆成两组：**不含会被转全角的 ASCII 标点的标识符**按逐字节判定（硬门槛，实测 1.000）；**带标点的标识符**按检索侧口径（NFKC 折叠 + 大小写折叠 + 去空白）判定（实测 1.000），同时把它们的逐字节值一起报出来（0.000），不藏。另一个真实误读也一并暴露：`kTCCServiceScreenCapture` 被认成 `KTCCServiceScreenCapture`（首字母大小写），逐字节不过、检索侧口径能对上。

### 7.4 端到端（走产品路径 `CaptureCoordinator.handleFrame`）

| 项 | 值 |
|---|---|
| AX 全空 → 写观察 | `capture_method = ocr`，`region = ocr:wechat.chat_panel`，`confidence = 0.84`，`note = lowconf=0 conf=0.84 px=864x560 rect=0,0,864,560`，正文能被 `search("适配器")` 找回来 |
| **陈旧上下文（修复轮新增）** | 换一张自绘"屏幕"当作另一个应用的画面、把前台 bundle id 换成 `…selfcheck.private`：**跑 0 个区域、`search("采集守护进程")` 命中 0 条**，`ocrStaleContext = 1`；**阳性对照**（同一张图、同一时刻，只把前台换回 `…selfcheck.wechat`）跑 1 个区域、命中 1 条 |
| **OCR 新鲜度（修复轮新增）** | 同一区域再认一次同一张图：OCR 照跑 1 个区域，但观察数 2 → 2（没写第二条），`ocrUnchanged = 1` |
| 协调者统计（区域 OCR） | OCR **3 次**（限流 0、空 0、失败 0、上下文过期 1、未变化 1），平均 **149 ms**，共 1014 字符，写观察 **2 条** |
| 采样审计 → `capture_audit` | 1 行，`observation_id = 42`，`method = ax`（照抄被审计那条观察的 `capture_method`），**覆盖率 1.000**（token 11/11，AX 16 字符 vs OCR 142 字符），86 ms |

上表取自 `results/self_check.txt`；换全新 scratch 从零重建的那次（`final/results/self_check.txt`）除 ms 抖动外逐位相同（区域 OCR 平均 152 ms、审计 89 ms，其余数字一字不差）。

### 7.5 主线程成本（估算，非实测）

适配规则相对 M0 多的开销只有「问元素坐标」：每次 `kAXPosition` + `kAXSize` 两条 AX 消息，上限 **300 次 / 扫描**（= 600 条消息），且只问带正文的节点与滚动 / 列表类容器；容器整块在视口外时整棵子树直接跳过。真实窗口上的实际次数**没有实测**（需要辅助功能授权 + 真机），写进真机验证清单第 7 条。

---

## 8. 未做与原因

1. **真机验证一项没做**：屏幕锁定、用户不在场，辅助功能与屏幕录制授权都不能触发（本轮硬约束）。四条规则的区域参数（微信 / 飞书的相对矩形、飞书的 `AXList` 行结构）、Claude 桌面版设了 `AXManualAccessibility` 之后到底能不能读到 AXWebArea、主线程会不会变卡、真实覆盖率是多少——**全部只有真机能回答**。清单见 `app/README.md` 第 11 节第 17 条（7 小项）。
2. **菜单入口没接**：并行约束禁止改 `AppDelegate.swift`（T10 也不改）。`CaptureCoordinator.shared.currentStats` 已经能给出「OCR 次数 / 限流次数 / 平均耗时 / 采样审计次数与平均覆盖率」，`CaptureController` 的 `capture_disarmed` 事件里也已经带上这段统计，**接进菜单由主会话做**。
3. **没有加 app 的 SwiftPM 测试目标**：那要改 `app/Package.swift` 的 `targets`，而本批 T10 正在改同一个文件的依赖块，冲突风险不值当。app 侧的 19 项判定全部走 `--self-check`（无 GUI、无 TCC、可脚本化、退出码即结论），与项目既有做法一致。
4. **OCR 结果没有二次校验**：同一区域两次识别不一致时不做投票，取最后一次。M1 不做。
5. **`RecognizeDocumentsRequest` 对照没做**（D24 备注里的「M1 前补」）：它属于 OCR 精度基准（E8 的延续），不属于本任务的采集通路；本轮的自绘基准只回答「管线接对了没有」。
6. **飞书的 `AXList` 定位可能太粗**：真机上侧边栏的会话列表也是 `AXList`，第一个命中的不一定是消息列表。规则支持 `identifier` 与 `rolePath` 两种更精确的定位方式，等真机看到 `AXIdentifier` 之后换掉即可（改一行数据，不动引擎）。
7. **气泡归属只在 OCR 路径上跑**：飞书走 `ax_rows` 时发送者取自行内子元素，不走气泡归属。
8. **第二类触发条件在产品路径上几乎不执行**（验收指出，修复轮**只记录不改**）：请求是在"变化帧之后"的那次 AX 扫描里排出来的，只有再下一帧也没被门控才会真的跑；「屏幕变了一次然后静止」这种最典型的场景里，静止帧显示的恰恰就是变化后的内容却会被跳过，上下文被下一次扫描替换后请求就丢了。改法有两条（把请求保留一帧、或者在排请求的那一帧就直接用当帧图像），选哪条取决于真机上第二类到底占多大比例——本轮没有真机数据，硬改等于拿产品路径赌。已写进代码注释与 `app/README.md` 8.6。
9. **全 OCR 规则（微信）的 AX 侧观察恒为 `completeness = unavailable`、0 正文**，真正的内容在另一条 `ocr` 观察里。统计 2.4「常用应用 complete + partial ≥ 90%」时要把这一对行合并看待，或者让规则声明"全 OCR 时不写 AX 侧那条"。这是**口径问题不是缺陷**，改哪边由计划定（第 9 节）。
10. **`app/Sources/brosis/main.swift` 改了 4 行**（`--dump-ocr` 入口），不在硬约束第 10 条给 T8 列的文件清单里；T10 不改这个文件，无合并冲突。第一轮已如实列出，本轮沿用（修复轮又动了它零行）。

---

## 9. 对计划的影响

一句话：**3.3 的内容采集、四个首批适配器、OCR 三类触发条件、帧门控接线、采样审计（core schema v3 的 `capture_audit`）与 `completeness` 四态判定全部落地并有自检覆盖，2.4 的「常用应用 complete + partial ≥ 90%」从这一轮起有了可测的口径；但四条规则的区域参数还没在真机上核过，真实覆盖率与 `complete` 占比要等授权后按 `app/README.md` 第 11 节第 17 条跑一遍才能填进 2.4。**

附带的四条口径记录，建议主会话在下一版计划里落笔：

- **D24 的「标识符召回」在采集端要按两组报**：不含 ASCII 标点的按逐字节，带标点的按检索侧折叠口径（NFKC + 大小写 + 去空白）——理由见 7.3 的引注。
- **3.3 的「采样审计覆盖率」口径定为 token 命中比例**（去空白与标点、NFKC 折叠、汉字 bigram、AX 侧去重、子串判定），不是字符数之比。
- **3.3 的「新鲜度判定」两侧都要有**：AX 侧决定要不要 OCR，OCR 侧决定要不要写第二条观察（修复轮已实现；不实现的话微信静止在前台一小时就是约 300 条内容相同的 `ocr` 观察）。
- **2.4 的完整性占比要按"一次观察 = AX 那条 + OCR 那条"合并统计**：全 OCR 的规则天生会写一条 `unavailable` 的 AX 观察，分开数会把占比压低（第 8 节第 9 条）。

---

## 10. 修复轮：验收问题逐条对照

验收共列 14 条（1 条阻塞 + 13 条非阻塞）。**改掉 10 条，记录不改 4 条**，逐条如下。

| # | 验收问题 | 处置 | 怎么验 |
|---|---|---|---|
| 1 | **【阻塞】陈旧上下文导致跨应用 / 私密浏览内容被 OCR 入库** | **已修**，两道防线：`EventSkeleton` 在不扫描的三支里调 `coordinator.clearContext()`；`CaptureCoordinator.handleFrame` 新增 `bundleID` 参数（由 `CaptureController.analyze` 传自己记的 `frontmostBundleID`），与上下文里的 bundle id 不一致就整帧不处理、并把这份上下文丢掉，计数进 `ocrStaleContext` | 自检新增一项（含阳性对照），变异检验 M7 |
| 2 | 变异 M5 未击穿：NFKC 折叠这一步没有用例能区分 | **已修**：`CaptureAuditTests.testCoverageFoldsFullWidthLettersAndDigits`，AX `OCR 100 capture_audit` vs OCR `ＯＣＲ １００ ｃａｐｔｕｒｅ＿ａｕｄｉｔ`（全角**字母数字**是"内容"字符，不折叠就对不上；全角标点不折叠也会被当分隔符丢掉，所以原来那条测不出这一步） | 变异检验 M5，现在实测 3 处断言失败 |
| 3 | 注入缺口：`OCRTriggerGate()` 用的是 `.standard`，`CaptureCoordinator(defaults:)` 传的那份没给限流器 | **已修**：`trigger = OCRTriggerGate(defaults: defaults)`。产品路径两边本来就是 `.standard`，行为不变；独立 suite 现在能配 `capture.ocrMinInterval` | `--self-check` 全过 |
| 4 | `capture_audit.method` 用 `completeness == .excluded ? .ax : .adapter` 猜，且那个分支永远走不到 | **已修**：`Context` 加 `captureMethod` 字段（`EventSkeleton` 把扫描结果的 `captureMethod` 传进来），审计行照抄 | 自检「采样审计端到端」多断言一条 `method == ax` |
| 5 | 设计疑点：第二类触发条件在产品路径上几乎不执行 | **记录不改**，理由见第 8 节第 8 条 | 代码注释 + `app/README.md` 8.6 |
| 6 | OCR 侧没有新鲜度判定，静止画面每帧写一条相同正文的观察 | **已修**：`lastOCRTexts[bundle\|region]` 与脱敏后正文逐字节比，未变就不写观察，计数进 `ocrUnchanged`（OCR 本身拦不掉——得认了才知道变没变） | 自检新增一项，变异检验 M8 |
| 7 | 2.4 口径：全 OCR 规则的 AX 侧观察恒为 `unavailable` | **记录不改**（口径问题，交计划） | 第 8 节第 9 条 / 第 9 节 |
| 8 | Safari 的 `url` 区域读的是 `kAXValue` 不是 `kAXURL`，真机读不到还白吃一次 BFS | **已修：删掉这个区域**。URL 本来就由事件骨架读 `kAXURL` 进 `observations.url`，规则里再留一份既没用又费预算 | 自检里 Safari 用例的期望片段数 2 → 1 |
| 9 | `OCRTrigger.swift:61` 死代码 | **已修**：删掉那一行，并在上一行注释里写清为什么它到不了 | 触发条件 7 条用例仍全 PASS |
| 10 | 预算泄漏：判为视口外后再读一次 `node.frame` / `row.frame` 统计回滚区，不计 `maxFrameProbes` | **已修**：`probeFrame` 的结果存进 `probed` 复用（三处），每个视口外节点省两条 AX 消息 | 视口相交 7 条 + 五条规则用例仍全 PASS |
| 11 | `raw as! AXValue` 强转 | **已修**：`AXNodeSource.visibleCharacterRange` 与 `AXSupport.frame` 都先验 `CFGetTypeID(raw) == AXValueGetTypeID()` 再转 | 自检全过（真机才有非法类型，属真机验证） |
| 12 | `--dump-ocr` 没打带标点组的严格未召回，第一轮 how_to_verify 的说法不成立 | **已修**：`Outcome` 加 `punctuatedStrictMissing`，`--dump-ocr` 两组分开打 | 7.3 末尾的实测输出 |
| 13 | 范围：`main.swift` 改了 4 行不在 T8 的文件清单里 | **说明保留**（`--dump-ocr` 入口没有别处可放；T10 不改这个文件） | 第 8 节第 10 条 |
| 14 | 真机风险：零面积 frame 被判视口外并丢文本 | **记录不改**，已在 `app/README.md` 第 11 节第 17 条 | 真机 |

### 变异检验（修复轮新增的两条 + 复核一条）

全部在**副本**上做（`~/Library/Caches/brosis-build/m1-adapters-fix/mut/`），项目目录一个字没动。

| 变异 | 改法 | 实测 |
|---|---|---|
| **M7**（身份校验） | `CaptureCoordinator.handleFrame` 的 `guard context.bundleID == frontmost else` 改成 `guard true else` | 自检 `[FAIL] 陈旧上下文…：换应用后 跑 1 个区域 / 命中 1 条（上下文过期计数 0）`——**验收描述的缺陷原样复现**（连带「OCR 新鲜度」也 FAIL） |
| **M8**（OCR 新鲜度） | `guard lastOCRTexts[key] != redacted.text else` 改成 `guard true else` | 自检 `[FAIL] OCR 新鲜度…：观察 2 → 3 条（未变化计数 0）` |
| **M5**（NFKC 折叠，第一轮没击穿的那条） | `Store+CaptureAudit.swift` 的 `TextPipeline.foldForIndex(text).unicodeScalars` 改成 `text.unicodeScalars` | `CaptureAuditTests` **3 处断言失败**（覆盖率 0.0 ≠ 1.0、`hitTokens` 0 ≠ 4、`normalize(ocr).contains("OCR")` 为假） |
| **M1**（复核：视口裁剪，因为改了 `probed` 复用） | `Viewport.isVisible` 里 `return !frame.intersection(viewport).isEmpty` 改成 `return true` | 仍是 **4 项 FAIL**（Safari / Claude / 飞书三条规则 + 视口相交判定），与第一轮一致 |
