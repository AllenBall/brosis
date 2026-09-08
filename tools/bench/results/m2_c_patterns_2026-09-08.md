# M2 c / T14：周台账、`get_patterns`、`recent_activity`（2026-09-08）

- 对应：`docs/实施计划.md` 的 **4.3** 第一条、**3.6**「`recent_activity`、`get_patterns`、周台账放 M2」、**3.7**（台账口径）、**3.4**（延迟分层目标）
- 依赖：M1 的 `core/`（T2 存储、T3 检索与日台账、T5 MCP）。本轮**没有加 schema 迁移**——`ledgers` 表的 `level` 从 M1 起就允许 `'week'`、`period` 就允许 `'YYYY-Www'`，分配给 T14 的 **v7 没有用掉**
- 并行：同一批的 T11（向量）/ T12（叙述）/ T13（同步）在同一棵源码树上并行落地。T12 的叙述**读我的 `getWeekLedger` / `observationWeeks` / `PatternCalendar`**，我这边把它写的 `narrative` / `model` / `narrative_meta` 三列在两个台账工具上透传出去，见 §5
- 本机：Apple M4 Air / 16 GiB / 无风扇 / macOS 26.6 / Darwin 25.6.0 / Xcode 26.6 / Swift 6.3.3（语言模式 v6）/ Python 3.14
- 单位：**KiB / MiB / GiB = 2¹⁰ / 2²⁰ / 2³⁰**；内存取 `/usr/bin/time -l` 的 **peak memory footprint**
- 原始输出：`~/Library/Caches/brosis-build/m2-patterns/results/`（采集脚本 `collect.sh`，本文每个数字都出自**同一次**运行；重采一遍就是 `SCRATCH=<你的目录> bash …/collect.sh`）
- 本轮**没有启动 GUI、没有触发 TCC / 钥匙串弹窗、没有 sudo、没有改 `docs/`**（`docs/实施计划.md` mtime 全程 09-08 03:10）；项目目录里 `find` 不到任何构建产物；没有 git commit

---

## 1. 做了什么

| 文件 | 内容 |
|---|---|
| `core/Sources/BrosisCore/PatternTypes.swift`（新增） | `WeekLedger` / `WeekDayTotal`、`ActivityPatterns` 及其六个子类型、`PatternOptions`、`RecentActivity` / `RecentItem` |
| `core/Sources/BrosisCore/PatternCalendar.swift`（新增） | ISO 周（`YYYY-Www` ↔ 周一 00:00）、当地整点边界（走日历加法，跨夏令时是 23 / 25 格）、ISO 星期编号 |
| `core/Sources/BrosisCore/Store+WeekLedger.swift`（新增） | `getWeekLedger(weekStart:)`、`observationWeeks()`、纯函数 `aggregateWeek`、区间合并、`ledgers(level='week')` 读写 |
| `core/Sources/BrosisCore/Store+Patterns.swift`（新增） | `getPatterns(start:end:apps:options:)` 与 `recentActivity(minutes:maxItems:apps:endingAt:)` |
| `core/Sources/BrosisCore/Store+Ledger.swift`（改） | 拆出可复用的 `dayLedgerUnlocked`；**缓存内容指纹**（见 §3）；`narrative` / `model` / `narrative_meta` 透传 |
| `core/Sources/BrosisCore/RetrievalTypes.swift`（改，追加） | `DayLedger.contentFingerprint`（可空） |
| `core/Sources/BrosisIPC/Protocol.swift`（改，追加） | `MCPTool` 加三个 case，追加在末尾 |
| `core/Sources/BrosisIPC/ToolCatalog.swift`（改，追加） | 三个工具的 JSON Schema + `readOnlyHint`，追加在数组末尾 |
| `core/Sources/BrosisCore/StoreMCPService.swift`（改，追加） | 三个工具的路由与 grant 裁剪、`maxPatternDays` / `maxRecentItems` 两个上限、`attachNarrative`（叙述标注透传，两个台账工具共用） |
| `core/Sources/brosis-store/main.swift`（改，追加） | `week-ledger` / `patterns` / `recent` 三个子命令 + `--reps` 计时 + 帮助 |
| `core/Tests/BrosisCoreTests/WeekLedgerPatternsTests.swift`（新增） | **18 个用例** |
| `core/Tests/BrosisCoreTests/MCPEndToEndTests.swift`（改，追加） | 新增 `testM2ToolsThroughMCP`；`allSixCalls` → `allToolCalls`（九个工具各一次） |
| `IPCProtocolTests` / `MCPServiceTests`（改） | 把写死的「6」改成「9」/ `MCPTool.allCases.count`，并加了「`tools/list` 顺序 == 枚举顺序」这条断言 |
| `tools/proto/gen_workweek.py`（新增） | **带作息的合成观察流**：先写下作息表，再按表生成观察，并把表自己算出的「每小时应有多少秒」写进 `--summary`（模式的真值由生成器定义，不由被测代码定义） |
| `core/README.md` / `app/README.md` | 新增「周台账、活动模式与最近活动」一章；九个工具与 grant 的对照表；CLI 用法；Claude Code 一节的工具清单 |

**app 侧没有加任何代码**：T14 是数据层 + MCP 层，4.3 没有要求 UI；接入方式就是 MCP 的三个新工具与 `brosis-store` 的三个新子命令。app 只有 `README.md` 的工具清单改了。

## 2. 怎么跑

```sh
REPO="<项目目录>"
S=$HOME/Library/Caches/brosis-build/m2-patterns

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path core -c release --scratch-path $S
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test  --package-path core --scratch-path $S

# 采一遍本文引用的全部原始输出（本次约 3 分 20 秒）
SCRATCH=$S REPO="$REPO" bash $S/results/collect.sh
```

`collect.sh` 八步：全新 release 构建（数 warning）→ `swift test` → 生成并导入 **1 个月 E7 口径合成库** →
周台账（全量 / 缓存）→ `get_patterns`（1 / 7 / 30 天）与 `recent_activity` →
删除 → stale → 重算 → 生成并导入 **4 周作息库**、与生成器的计划逐项对照 → MCP 端到端（全量 grant 与白名单 grant 各一遍）。

app 侧（构建 + 自检，另跑）：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
SCRATCH=$HOME/Library/Caches/brosis-build/m2-patterns-app bash app/build_app.sh
$HOME/Library/Caches/brosis-build/m2-patterns-app/brosis.app/Contents/MacOS/brosis --self-check
```

## 3. 三样东西的口径

### 3.1 周台账 = 7 个日台账之和

`getWeekLedger(weekStart:)` 收 `YYYY-Www`（ISO 周、周一起算）或**周内任意一天**的 `YYYY-MM-DD`，
落进 `ledgers` 的 `level = 'week'` 行。它**不在一条连续的周观察流上重算**，而是把该周 7 个日台账加起来。
换来两件事：

1. **「周 = 7 天逐字段之和」是可断言的不变量**（`week-ledger --check` 直接打对照表）；
2. **增量成立**：只有变过的那几天要重算，其余天读日台账缓存；返回值里 `daysRecomputed` 是这次真重算了哪几天、
   `servedFromCache` 说明整份周台账是不是原样读回的。

三处**定义差异**（不是误差）：`switches` 与 `sessions` 是 7 天各自数字之和，跨午夜的段在相邻两天各记一次；
`onlineUnionS` 是 7 天并集之和，天与天不重叠所以它**等于**整周的并集，这一项没有差异。

### 3.2 顺带堵的一个洞：日台账缓存永远不失效

M1 的 `getDayLedger` 只在**删除**时因为 `stale` 标记重算（3.8 的级联）。新观察写进来**不会**碰 `ledgers` 行——
于是「今天」的台账一旦算过一次就被永久缓存，当天后来的活动全看不见。周台账要按天聚合、还要谈增量，
这个洞必须先堵：`DayLedger.contentFingerprint` 记下「算的时候这一天有哪些观察」，写成 `n=<条数>,max=<最大 id>`，
口径与算进台账的那批观察完全一致（本机产生 `origin_device IS NULL`、没被删、`ts` 落在当天）；
读缓存时拿它跟库里现算的一份比，不一致就重算。老库写下的台账行没有这个字段，读回来是 nil，按「验不了 → 重算」处理。

代价：每次缓存命中多一条 `COUNT(*) / MAX(id)` 的索引区间点查（走 `idx_obs_live`）。1 个月库上周台账缓存命中
（7 天 = 7 次指纹校验 + 7 次 JSON 解码）热 p95 **3.37 ms**，见 §4。

### 3.3 `get_patterns` 的五个口径

| 项 | 口径 |
|---|---|
| 星期 × 小时热力 | 时间片按**当地整点**分桶再按 (星期, 小时) 归并；每格带 `slots`（这个格子在区间里出现过几次）与 `meanDwellS`，好让长度不同的区间能比较；另给 `byHour`（24 行）/ `byWeekday`（7 行）两张**定长**边际表 |
| 每应用常用时段 | 同一批格子按应用拆开，取 dwell 前 3 的小时与各自占比 |
| 会话长度与打断率 | 直接读 `sessions` 表（3.7 三常量切出来的）。时长 = `end - start`；给均值 / 中位 / p90 / 最长、`interruptionsPerSession`、`sessionsWithInterruption`、`interruptionRate` |
| 最常切换对 A→B | **同一块屏**上相邻两条观察应用不同、且间隔 ≤ 停留上限 90 s。超过它就没有证据说明中间发生了什么，那不是切换而是空白之后重新开始 |
| 连续工作块 | **同一块屏**上的极大观察序列：相邻间隔 **< 打断阈值**（3.7 的 20 s，「离开正好 20 s 也算打断」所以严格小于）、**不含 `unknown` 观察**（权限丢失 / 超时 / 锁定期间没有证据说明人在工作）、块长 ≥ 25 分钟（4.3 原话）。**块内允许换应用**（3.7 的打断是离开、不是换应用），要「全程一个应用」看 `singleAppBlocks` |

块长 = 最后一条观察的时间片终点 − 第一条观察的 `ts`。最后一条按 3.7 的停留上限最多代表 90 s，
所以块尾可能比最后一条观察晚 90 s——与 dwell 的记账口径完全一致，不是把块拉长了。
`ActivityPatterns` 把算它用到的**全部常量**（`options` + `sessionConfig`）一起交回去。

### 3.4 `recent_activity`

最近 N 分钟的应用聚合 + 会话汇总 + 最多 `max_items` 条观察摘要（每条 ≤ 100 token，口径见 `TokenBudget`）。
**只看本机产生的观察**（`origin_device IS NULL`）：这是「这台机器最近在干什么」，D17 从别的设备导入的副本
不该混进同一条时间线（与 3.9 里 sessions / ledgers 的口径一致；找别的设备的内容走 `search` / `get_evidence`）。
摘要排版与 `search` 的命中摘要一致：应用 · 标题 · 时间 · 正文开头。

## 4. 实测数字

### 4.1 构建与测试

| 项 | 数字 | 出处 |
|---|---|---|
| release **全新**构建（先删 `release` 产物目录） | **0 error、0 warning** | `results/build_release_clean.log`、`results/build_warnings.txt`（内容 `0`） |
| `swift test` | **209 个用例、0 失败**，24.68 s | `results/swift_test.log` |
| — 本任务新增 `WeekLedgerPatternsTests` | **18 个** | 同上 |
| — 本任务给 `MCPEndToEndTests` 补的 | **1 个**（11 → 12） | 同上 |
| `brosis-store`（release） | 6,311,360 字节 = 6.019 MiB | `results/binary_size.txt` |
| `brosis-mcp`（release） | 453,240 字节 = 442.6 KiB | 同上 |
| `app/build_app.sh`（`SCRATCH=…/m2-patterns-app`） | **0 warning**，签名 / `codesign --verify --deep --strict` / Sparkle 逐 Mach-O Team ID 核对 / 从 bundle 里跑 `--version` 与 `brosis-embed env` 全过 | `results/build_app.log` |
| `brosis.app --self-check` | **自检通过**（退出码 0，无 `[FAIL]`）；参数快照里打的是 **`MCP：9 个工具 get_context search get_evidence get_timeline get_day_ledger get_item get_week_ledger get_patterns recent_activity`** | `results/self_check.log` |

> 209 是本轮收尾时的数字。M2 c 批四个任务并行落地，总数还会随另外几个任务再动，以 `swift test` 的实际输出为准。

### 4.2 两个合成库

| 库 | 口径 | 观察数 | JSONL | 导入 | 库文件 | 会话 |
|---|---|---:|---:|---:|---:|---:|
| **1 个月 E7 库** | `gen_synth_m1.py`，8640 条/天 × 30 天、**24 h 均匀**（容量最坏情形） | 259,200 | 658,825,878 B = 628.3 MiB，sha256 `642ba490…` | 51.05 s（5,077 条/s，峰值 footprint 858,244,728 B = 818.5 MiB） | 539,836,416 B = 514.8 MiB | 8,189 段 |
| **4 周作息库** | `gen_workweek.py`，先写作息表再生成（真实作息） | 63,621 | 169,735,814 B = 161.9 MiB，sha256 `e48b65c0…`（完整值在 `results/workweek_plan.json`） | 19.25 s（3,305 条/s） | — | 710 段 |

1 个月 E7 库的 JSONL sha256 与 M1 T3 那次逐字节一致（`642ba490fdb1162179bf80b992f3b71a2945977f60acc5fede717f55fa121d02`），
说明生成器仍然是确定性的。

### 4.3 耗时（**1 个月 E7 库**，最坏情形）

「冷」= 进程内第一次（连接刚开、页缓存空），「热」= 同一连接重复 N 次，与 `bench` 的定义一致。
命令是 `brosis-store <子命令> --reps N`。

| 查询 | 冷 ms | 热 p50 ms | **热 p95 ms** | n | 3.4 分层目标对照 |
|---|---:|---:|---:|---:|---|
| 周台账 缓存命中（2026-W34） | 11.38 | 3.31 | **3.43** | 20 | 报表类 ≤ 50 ms ✅ |
| 周台账 缓存命中（2026-W33，冷列是本进程第一次真算） | 66.87 | 3.26 | **3.28** | 20 | ✅ |
| 周台账 **7 天全量重算**（`--recompute`） | **67.14** | — | — | 1 | 超过 50 ms，见 §4.5 的目标建议 |
| `get_patterns` 1 天 | 6.10 | 4.36 | **4.41** | 20 | ✅ |
| `get_patterns` 7 天 | 40.47 | 30.08 | **30.55** | 20 | ✅ |
| `get_patterns` 30 天 | 170.93 | 129.22 | **130.12** | 10 | 超过 50 ms，随区间**线性**（4.3 ms/天） |
| `recent_activity` 30 min / 20 条 | 1.43 | 0.87 | **0.89** | 20 | ✅ |
| `recent_activity` 60 min / 50 条 | 2.68 | 2.04 | **2.06** | 20 | ✅ |

**同一台机器上这组数会浮动 25–45%**，要先说清楚：Air 是无风扇的，`collect.sh` 把这些测量
排在 55 s 的导入紧后面，机器热的时候同一条命令会明显慢。本文采集期间实测到的 30 天 `get_patterns`
热 p95 落在 **125–181 ms** 之间（最慢的一次紧跟一轮更重的负载，`results/patterns_30d_recheck.json`
是那一次之后机器空闲下来的复测：125.0 ms）。**本文按最后一次 `collect.sh` 的数写**——那是脚本能复现的；
§4.5 的目标建议按上界取，把降频态也包进去。

`get_patterns` 30 天跑一次的峰值 footprint **129,401,480 B = 123.4 MiB**（`results/patterns_30d.time`），
其中 128 MiB 是 `PRAGMA cache_size` 的上限，实际增量很小。

### 4.4 耗时（**4 周作息库**，真实作息）

| 查询 | 冷 ms | 热 p50 ms | 热 p95 ms | n |
|---|---:|---:|---:|---:|
| 周台账 7 天全量重算 | 16.80 | — | — | 1 |
| 周台账 缓存命中 | 3.38 | 1.05 | **1.07** | 20 |
| `get_patterns` 7 天 | 10.51 | 7.77 | **7.87** | 20 |
| `get_patterns` 28 天 | 40.84 | 30.66 | **30.78** | 10 |
| `recent_activity` 60 min | 1.39 | 0.87 | **0.90** | 20 |

同样是「一个月」，真实作息库比 E7 最坏情形快约 4 倍——因为观察数少 4 倍（63.6 k vs 259.2 k）。
**这两组数字都要看**：E7 那组是上界，作息那组是产品路径上更可能遇到的数。

### 4.5 三条目标建议（等你拍板，本文不改 `docs/`）

3.4 现在只给了「报表类 ≤ 50 ms」。周台账与 `get_patterns` 的代价形态不同，建议按下面分开写：

| 查询 | 建议目标 | 依据 |
|---|---|---|
| 周台账（缓存命中）、`recent_activity` | **≤ 50 ms**（沿用报表类） | 实测 3.43 ms / 2.06 ms，余量 15 倍以上 |
| 周台账（7 天全量重算） | **≤ 100 ms**（E7 最坏口径） | 实测 67.1 ms；它一周最多真算一次，之后全走缓存 |
| `get_patterns` | **≤ 7 ms/天**（E7 最坏口径），于是默认 7 天窗口 ≤ 50 ms；MCP 侧硬上限 180 天 | 实测 4.3 ms/天、7 天 30.6 ms、30 天 130.1 ms，**线性**（按定义要扫区间内全部观察，与 3.4 里 1–2 字扫描通道同一种形态）。7 ms/天不是 4.3 的整数倍凑出来的，是把上面说的降频波动（最慢那次 6.0 ms/天）也包进去 |

### 4.6 周 = 7 天之和

`brosis-store week-ledger --week … --check` 打出对照表，两个库都**逐字段相等**：

| 库 / 周 | dwell s | active s | unknown s | 并集 s | switches | interruptions | sessions | observations | 逐字段相等 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|:--:|
| 1 个月 E7 库 2026-W33 | 556,390 | 525,540 | 59,920 | 546,330 | 2,271 | 371 | 1,932 | 60,480 | **是** |
| 4 周作息库 2026-W34 | 159,870 | 151,970 | 1,420 | — | 211 | 54 | 161 | 15,881 | **是** |

W33 的按天分布（7 行，`dayTotals`）：08-10 至 08-16 各 8,640 条观察、dwell 79,030 / 79,260 / 79,580 /
79,670 / 79,600 / 79,290 / 79,960 s；双屏 `perDisplayDwellS` = {屏 1: 269,830 s，屏 2: 286,560 s}，
焦点合计 556,390 s、区间并集 546,330 s（3.7 的「两者都报告、不重复计」）；证据区间合并后 **1 段**。

4 周作息库 W34 的按天分布把「周日不开机」如实留成一行：`2026-08-23`、weekday 7、dwell 0、observations 0、
**`hasData = false`**——这一行**必须在**，否则「这一周有一天没开机」这件事就从结果里消失了。

### 4.7 stale 联动（3.8）

删掉 3 条观察（id 1–3，落在 2026-08-08 = ISO 周 2026-W32）：

| 步骤 | 数字 | 出处 |
|---|---|---|
| 删除前 `get_week_ledger(2026-W32)` | observations **17,280**、activeDays 2（库从 08-08 开始，W32 只有 2 天有数据） | `results/stale_before.json` |
| `delete --observations 1,2,3` | observations_affected 3、**ledgers_stale 2**（日台账 + 周台账各一行）、sessions_stale 1 | `results/stale_delete.json` |
| 删除后再问一次 | observations **17,277**、`stale = false`、`daysRecomputed = ["2026-08-08"]`（只重算了被影响的那天） | `results/stale_after.json` |
| 一致性自检 | `all_passed = true`（13 项悬空引用 + `integrity_check` + `foreign_key_check` + FTS integrity-check） | `results/check.json` |

### 4.8 模式的可解释性：与生成器的计划逐项对照

`gen_workweek.py` 先写下作息表（周一至周五 09:00–12:30 与 13:30–18:00，周二 / 周四加 20:00–22:00，
周六 10:00–11:30，周日不开机；10 s 一条；每小节 35% 概率插一条别的应用的观察 = 3.7 口径下的**一次打断**；
每小节之间 25% 概率离开 20–40 s = 断开连续工作块），并把表自己算出的每小时 / 每星期 / 每应用秒数写进
`results/workweek_plan.json`。然后拿 `get_patterns` 的输出去对（`results/workweek_compare.txt`）：

| 项 | 生成器的计划 | `get_patterns` 实测 | 结论 |
|---|---|---|---|
| 观察数 | 63,621 | **63,621** | 一致 |
| 有观察的自然日 | 24（28 天减 4 个周日） | **24** | 一致 |
| 总 dwell | 636,210 s | **642,160 s（+0.94%）** | 差额来自 3.7 停留上限在每段末尾多记的最多 90 s，与 unknown 观察不计 dwell 这两项相抵；18 点与 22 点各多出 1,280 / 640 s 就是这个溢出 |
| **按小时峰值** | 10 点（作息表里唯一「五个工作日都在」的整点） | **10 点** | **一致——这就是「热力峰值落在生成器设定的工作时段」** |
| 夜间 0–8 点与 23 点 | 0 | **0 s** | 一致 |
| 每应用 dwell | VSCode 240,690 / Safari 168,230 / 飞书 143,170 / 终端 48,170 / 微信 35,950 s | 242,710 / 169,720 / 144,560 / 48,800 / 36,370 s | 全部 +0.8%～+1.3%，同一个溢出 |
| 每应用常用时段 | 上午 VSCode + 终端 + 飞书、下午 Safari、晚上微信 | VSCode `[10, 11, 9]`、终端 `[11, 9, 10]`、飞书 `[10, 9, 16]`、Safari `[15, 17, 16]`、微信 `[20, 21, 10]` | 与作息表一致 |
| 打断 | 种下 **241** 次 | **243** 次、有打断的会话 206 段、**打断率 0.290** | 多出的 2 次是巧合命中（别的小节边界上正好也构成一次「离开又回来 ≤ 20 s」） |
| 连续工作块 | 154 次「离开 20–40 s」把长段切开 | **118 个 ≥ 25 分钟的块**，合计 239,360 s、均值 2,028 s、中位 1,870 s、最长 5,840 s；全程单应用 15 个、活跃过半 118 个 | 有断点才有块数，符合预期 |
| 最常切换对 | 上午 VSCode ↔ 飞书为主 | `VSCode→飞书 141`、`飞书→VSCode 132`、`Safari→VSCode 79`、`VSCode→Safari 77`、`飞书→Safari 66`；总 848 次、12 个不同对 | 与权重表一致 |

**1 个月 E7 库上连续工作块是 0 个**，这不是 bug：那条流按 E7 容量口径每 20 条观察里就有 2 条
`permission_lost` / `timeout`（10%），按 §3.3 的口径每 100 秒就断一次，永远凑不满 25 分钟。
它正好说明这条口径**确实在按「有没有证据」判定**，而不是按时长硬切。

### 4.9 MCP 端到端（四个真进程）

`brosis-store serve` → `brosis-mcp` → `core/Tests/mcp_client.py`，两份 grant 各跑一遍。

- `tools/list` 回 **9 个**工具：`get_context`、`search`、`get_evidence`、`get_timeline`、`get_day_ledger`、
  `get_item`、**`get_week_ledger`**、**`get_patterns`**、**`recent_activity`**，全部 `readOnlyHint = true`
  （3.6：这只是提示不是隔离，真正的只读在服务端）。
- 全量 grant（`apps = ["*"]`、`fields = evidence`）：三个新工具各一次调用全部 `is_error = false`；
  `recent_activity` 返回 5 条（窗口内 8,715 条），**每条摘要的 `summaryTokens` 上限 100、实测最大 100**。
- 白名单 grant（`apps = ["com.apple.Safari"]`、`fields = summary`）：
  - `get_week_ledger` 只剩 Safari 一行，汇总按留下的应用重算，
    `droppedFields = [sites, files, onlineUnionS, perDisplayDwellS, sessions, interruptions, evidence, dayTotals, activeDays, narrative, model, narrativeMeta]`，
    `grant.droppedByGrant = 5`（另外 5 个应用被挡掉）；
  - `get_patterns` 的 `appFilter = ["com.apple.Safari"]`，热力图与工作块**在只含 Safari 的观察流上重算**，
    切换对因此是 **0 次**（只剩一个应用就没有 A→B）；
  - `recent_activity` 同样只剩 Safari。
- 审计（`mcp_audit`）每次调用一行，参数**只记形状**：
  `week=2026-W34`、`focus_min=- max_transitions=- start=given end=given`、`minutes=2880 max_items=5`；
  `note` 里记结果规模与裁剪量（`week=2026-W34 recomputed=0 cache=true grant_filtered=5`、
  `days=7.00 obs=12819 blocks=0 app_filter=1`）。

## 5. 与 T12（叙述）的接口：`narrative` 三列的透传

T12 在同一批把 schema 推到 v6，给 `ledgers` 加了 `narrative_meta` 列，并且**读我的 `getWeekLedger`**
生成周叙述。MCP 这一层（`StoreMCPService.attachNarrative`，`get_day_ledger` 与 `get_week_ledger` 共用）做三件事：

1. **键永远在**：没有叙述就显式给 `null`。`JSONEncoder` 默认把 nil 的可选字段整键省掉，
   客户端就分不清「没跑叙述」和「这个版本没有这个字段」；
2. `narrativeIsStale = true`（叙述对不上现在这份台账）时**不把正文交出去**，只留标记——
   一段描述另一版台账的话比没有更糟；
3. **应用白名单生效时整段丢掉**（进 `droppedFields`）：叙述是照整份台账写的，里面可能点名白名单之外的应用，
   按 key 裁字段裁不掉它。这与 M1 第一轮验收在 `get_evidence` 邻居上抓到的是同一类口子。

另外 `upsertWeekLedger` 在重算时把 `narrative` / `model` / `narrative_meta` 一起置回 NULL，
与日台账 `upsertLedger` 同一条规矩。用例 `testMCPPassesThroughNarrativeMetadataAndDropsItUnderWhitelist`
把这四条都钉住了（挂叙述 → 全量 grant 能读到 → 白名单 grant 读不到 → 周台账重算后叙述消失）。

## 6. 测试

`WeekLedgerPatternsTests` 18 个用例，合成数据都是**手写的确定性观察流**——这些用例断言的是
「生成器设定的工作时段」与「人为埋进去的切换 / 工作块」能不能被算出来，真值必须由测试自己定义。

| 组 | 用例 |
|---|---|
| 日历 | `PatternCalendar` 与 `DayCalendar` 在 UTC / Asia/Shanghai / America/Los_Angeles 三个时区、140 个时刻上逐项相等（它是那三行配置的复制品，这条用例专门兜配错的风险）；`YYYY-Www` 与 `YYYY-MM-DD` 两种写法、周内任意一天都落到同一周、`2026-W99` 与乱写都报错 |
| 周台账 | **周 = 7 个日台账逐字段之和**（含应用排行逐 key 对账、`activeDays = 6`、周日 `hasData = false` 那一行必须在、证据区间已合并且覆盖全部观察）；**增量**（第一次七天全算 → 什么都没变时 `servedFromCache = true` 且 `computedAt` 不变 → 只往周四写新观察时 `daysRecomputed == ["2026-09-10"]`、其余六天 `dayComputedAt` 一个字节不动 → 与 `--recompute` 全量重算逐字段相等）；**新观察让日台账缓存失效**（指纹从 `n=10,max=10` 变成 `n=15,max=15`）；**删除让日 / 周台账都标 stale**（`ledgersStale ≥ 2`），重算后脏行清零 |
| `get_patterns` | 热力峰值落在生成器设定的工作时段（按小时边际表唯一峰值 = 10 点 = 那个「五个工作日都在」的小时；9 点与 11 点各 4 天、14–16 点各 3 天且都严格小于 10 点；夜间与周日恒为 0；周六只有 20–21 点；一周里每格 `slots = 1`）；每应用常用时段（VSCode `{9,10,11}`、Safari `{14,15,16}`、微信 `[20]`，share 之和 = 1）；切换对（A→B 6 次、B→A 5 次、第二块屏各算各的、**隔两小时的应用变化不算切换**）；连续工作块（40 分钟连续算 1 个、中间挖 60 s 空白与插一条 `unknown` 都断开、把下限放宽到 10 分钟后断成 5 段、块长 2,480 s = 239 × 10 s + 最后一条的 90 s、`activeRatio = 1.0`）；会话统计与 `sessions` 表逐项对账；**应用白名单是换输入不是裁输出**（只留 Safari 后热力图只剩 14–17 点）；空区间报错 |
| `recent_activity` | 摘要 ≤ 100 token 且 ≤ 200 字符、是一行、长正文以 `…` 结尾；最近的在前；`truncated`；会话不展开证据 id；应用过滤；空窗口 |
| MCP | 三个新工具的白名单裁剪（`droppedFields` / `appFilter` / `scopeNote`）与审计形状（三条 ok、参数只记形状）；时间窗（整周落窗口外、`minutes` 被封顶到 1,440）与六种坏参数（缺 `week`、`2026-W99`、缺 `end`、区间超 `maxPatternDays`、`focus_block_minutes = 0`）；**叙述标注透传与白名单下整段丢掉** |

端到端另有 `MCPEndToEndTests.testM2ToolsThroughMCP`：四个真进程上三个新工具各一次真实调用，
核对周台账 7 行按天分布、热力图与两张边际表的长度、`focus.minMinutes = 25`、每条摘要 `summaryTokens ≤ 100`、
审计里三条 ok。

### 6.1 变异检验（**复制到自己的 scratch 再改，别改项目目录**）

```sh
cp -R "$REPO" $HOME/Library/Caches/brosis-build/verify-t14-mutate
cd $HOME/Library/Caches/brosis-build/verify-t14-mutate
# 改完跑：DEVELOPER_DIR=… swift test --package-path core \
#          --scratch-path $HOME/Library/Caches/brosis-build/verify-t14-mutate-scratch
```

| # | 改哪里 | 应当失败的用例 |
|---|---|---|
| 1 | `Store+WeekLedger.swift` 的 `aggregateWeek` 里 `switches += day.switches` → `switches += 0` | `testWeekLedgerEqualsSumOfSevenDayLedgers` |
| 2 | `Store+WeekLedger.swift` 里 `dayLedgerUnlocked(date:recompute: recompute, …)` → `recompute: true` | `testWeekLedgerIsIncrementalAndServesFromCache`（`daysRecomputed` 永远是 7 天） |
| 3 | `Store+Ledger.swift` 的 `cachedLedger` 里删掉 `guard let cached = ledger.contentFingerprint, cached == (try dayFingerprint(...))` 这两行 | `testDayLedgerCacheIsInvalidatedByNewObservations` |
| 4 | `Store+Patterns.swift` 的 `focusBlocks` 里删掉 `if s.kind == .unknown { flush(); continue }` | `testPatternsFocusBlocksNeedContinuityAndLength`（放宽到 10 分钟后应当是 5 段，会变成 4 段） |
| 5 | `PatternCalendar.hourOfDay` 改成 `component(.hour, …) + 1` | `testPatternsHeatmapPeaksInsideGeneratedWorkHours`（峰值变 11 点） |
| 6 | `Store+Patterns.swift` 的切换对里 `s.ts - last.ts <= maxDwellMS` → 恒 `true` | `testPatternsCountsMostFrequentTransitions`（「隔两小时不算切换」那条断言） |
| 7 | `StoreMCPService.runPatterns` 里 `apps: scoped ? grant.apps : nil` → `apps: nil` | `testMCPWeekLedgerAndPatternsRespectAppWhitelist`（热力图会出现上午的格子） |
| 8 | `StoreMCPService.attachNarrative` 里删掉 `guard !scoped else { … }` 那一段 | `testMCPPassesThroughNarrativeMetadataAndDropsItUnderWhitelist` |
| 9 | `PatternCalendar` 的 `cal.firstWeekday = 2` → `= 1` | `testPatternCalendarAgreesWithDayCalendar`、`testWeekBoundsAcceptsBothSpellingsAndRejectsGarbage` |

## 7. 未做与原因

| 项 | 为什么 |
|---|---|
| **没有加 schema 迁移**（分配给 T14 的 v7 没用掉） | `ledgers` 表从 M1 起 `level` 就允许 `'week'`、`period` 就允许 `'YYYY-Www'`，周台账直接落进去。`DayLedger.contentFingerprint` 是写在 `ledgers.ledger` 那份 JSON 里的可空字段，不是新列，老库读回来是 nil 并按「验不了 → 重算」处理 |
| **app 侧没有加菜单 / 窗口** | 4.3 对这三样只要求数据层与 MCP；接入方式是三个 MCP 工具 + 三个 CLI 子命令，`app/README.md` 的 Claude Code 一节已经列全。若主会话想要一个「本周概览」窗口，那是独立的一块 UI 工作，不该塞进这次的口径任务里 |
| **`get_patterns` 没有进 `bench` 的默认计划** | `bench` 的 `--cold-rounds 20` 会把整套计划各跑 20 遍，把 30 天的 `get_patterns` 塞进去会让每一轮压测多花几秒，而它的形态（随区间线性）跟 `bench` 里那四类查询不是一回事。改用三个子命令自带的 `--reps`，冷 / 热定义与 `bench` 完全一致 |
| **周台账没有「跨周连续」口径** | 周 = 7 天之和是本任务选的口径（换来可断言的不变量与增量）。想要「在连续周流上重算」的那套数（跨午夜不重复记切换），得另设一个入口，属于新口径不是修 bug，§3.1 已如实写明差异 |
| **热力图的 `slots` 没有扣掉「机器关机」** | `slots` 是「这个格子在区间里出现过几次」，不是「这个格子里人有可能在」。要区分「没开机」与「开机但没活动」，得先有开关机事件（3.3 的 `source_state` 目前只覆盖到锁定 / 权限 / 超时），M2 不做 |
| **打断率没有在 E7 库上做交叉验证** | E7 那条流 10% 的观察是 `unknown`，`sessions` 的打断数是有的（W33 371 次），但它的分布不像真实使用。真实作息库上打断 243 次 vs 生成器种的 241 次已经把口径验住了 |

## 8. 任务清单逐条对照

| 任务要求 | 落在哪里 | 证据 |
|---|---|---|
| 周台账：三类时间、应用 / 站点 / 文件排行、切换与打断、日分布 | `WeekLedger`（`PatternTypes.swift`）+ `Store.aggregateWeek` | §4.6 的表与 `dayTotals`；`results/week_w33_check.json` |
| 周台账：stale 联动 | `markDerivedStale` 认 `ledgers.evidence` 的区间表示，周行与日行一起标脏 | §4.7；`testDeleteMarksWeekLedgerStaleAndRecomputeDropsIt` |
| 周台账：`getWeekLedger(weekStart:)` | `Store+WeekLedger.swift` | §3.1 |
| 周台账：增量 | 7 天各自读缓存 / 重算，周行按 7 个 `dayComputedAt` 判定 | `testWeekLedgerIsIncrementalAndServesFromCache`；`results/week_w34_cached.json` 的 `cache=true` |
| `get_patterns`：热力、每应用常用时段、会话长度与打断率、最常切换对、连续工作块 | `Store+Patterns.swift` | §3.3、§4.8 |
| `get_patterns`：全部可解释、不用模型 | 只读 `observations` / `sessions`，返回值带全部常量 | §3.3 最后一段；`ActivityPatterns.options` / `sessionConfig` |
| `recent_activity(minutes, max_items)`：摘要 ≤ 100 token、受 grant 裁剪 | `Store.recentActivity` + `StoreMCPService.runRecentActivity` | §3.4、§4.9；`testRecentActivityReturnsSummariesWithinTokenBudget` |
| MCP：三个新工具进 `tools/list`（JSON Schema） | `MCPToolCatalog.all` 追加三条；`brosis-mcp` 直接输出它 | §4.9 第一条；`testToolCatalogCoversEveryToolAndIsReadOnly` |
| MCP：`StoreMCPService` 路由 | `run(tool:)` 三个新 case | §4.9 |
| MCP：grant 裁剪（白名单 / 时间窗 / fields） | `runWeekLedger` / `runPatterns` / `runRecentActivity` | §4.9 第三条；`testMCPWeekLedgerAndPatternsRespectAppWhitelist`、`testMCPTimeWindowAndBadArgumentsOnNewTools` |
| MCP：`mcp_audit` | 复用 `writeAudit`，`parameterSummary` 加三个分支 | §4.9 最后一条 |
| MCP：`get_day_ledger` 透传 T12 的 narrative 元数据 | `attachNarrative`（两个台账工具共用） | §5；`testMCPPassesThroughNarrativeMetadataAndDropsItUnderWhitelist` |
| CLI：`week-ledger` / `patterns` / `recent` | `brosis-store/main.swift` | §2、`core/README.md` 的命令一节 |
| CLI：1 个月合成库上的耗时（热 p95）与 3.4 对照 | `--reps N` | §4.3、§4.4、§4.5 |
| 测试：周聚合与日台账之和一致 | `testWeekLedgerEqualsSumOfSevenDayLedgers` + CLI `--check` | §4.6 |
| 测试：stale 联动 | `testDeleteMarksWeekLedgerStaleAndRecomputeDropsIt` | §4.7 |
| 测试：模式统计的可解释断言（热力峰值落在工作时段） | `testPatternsHeatmapPeaksInsideGeneratedWorkHours` + `gen_workweek.py` 的计划对照 | §4.8 |
| 测试：`recent_activity` 的 grant 裁剪 | `testMCPWeekLedgerAndPatternsRespectAppWhitelist` 第 ③ 段 | §4.9 |
| 测试：MCP 端到端三工具各一次调用 | `MCPEndToEndTests.testM2ToolsThroughMCP` + `collect.sh` 第 7 步 | §4.9 |
| 文档：`core/README` / `app/README` | 见 §1 最后一行 | — |

## 9. 对计划的影响（一句话）

4.3 的第一条（`get_patterns`、`recent_activity`、周台账）三样全部落地并进了 MCP（3.6 的工具从六个变成九个），
3.4 的延迟分层建议加三行：周台账缓存命中与 `recent_activity` 沿用「报表类 ≤ 50 ms」、
周台账全量重算 ≤ 100 ms、`get_patterns` 按「≤ 7 ms/天、默认 7 天窗口 ≤ 50 ms」写
（E7 最坏口径实测 4.3 ms/天，最慢的一次降频态 6.0 ms/天）。
