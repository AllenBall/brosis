# M1 R1 / T3：检索、会话与日台账（2026-09-07，含 R1 两轮验收后的修复）

- 对应：`docs/实施计划.md` 的 **3.4**（检索设计）、**3.6**（6 个 MCP 工具的**数据层**）、**3.7**（台账口径）、**3.8**（删除后各入口都不返回内容），决策 **D22**（bigram + contentless FTS）、**D23**（证据用区间表示）
- 依赖：T2 的 `core/`（已验收）。本轮在它上面加检索、会话化、日台账，没有改 schema
- 代码：`core/Sources/BrosisCore/`（新增 7 个文件）、`core/Sources/brosis-store/main.swift`（新增 10 个子命令）、`core/Tests/BrosisCoreTests/`（新增 2 个套件 **30** 个用例）、`tools/proto/gen_synth_m1.py`（新增）。文档：`core/README.md` 新增「检索」与「会话与日台账」两章
- 本机：Apple M4 Air / 16 GiB / 无风扇 / macOS 26.6 / Darwin 25.6.0 / Xcode 26.6 / Swift 6.3.3（语言模式 v6）/ Python 3.14.7
- 单位口径：**KiB / MiB / GiB = 2¹⁰ / 2²⁰ / 2³⁰**；**内存一律取 `/usr/bin/time -l` 的 `peak memory footprint`**，不是 `maximum resident set size`（两者都记在 `results/memory_peak_footprint.txt` 里）
- 原始输出：`~/Library/Caches/brosis-build/m1-r1-fix2/results/`（**61 个文件**，含 `collect.sh` 与运行日志；重采一遍就是 `sh ~/Library/Caches/brosis-build/m1-r1-fix2/results/collect.sh`）。本文每个数字都出自**同一次** `collect.sh`（全程约 253 s：构建 22.96 + 测试 4.93 + 生成 38.38 + 导入 45.73 + 压测 99.38，其余是会话 / 台账 / 评估 / 各入口复核；`results/collect_run.log`）
- **这一次采集是用最终源码跑的**：源码改完 → 跑 `collect.sh` → 写本文，中间没有再动过 `core/`（R1 第二轮验收指出上一轮 `Store+Sessions.swift` 的 mtime 晚于原始输出，见 §0 第 5 条）
- 本轮**没有启动任何 GUI、没有触发 TCC 或钥匙串授权弹窗、没有用 sudo、没有改 xcode-select**；没有 git commit；**没有改 `docs/` 下任何文件**（`docs/实施计划.md` 的 mtime 一直是 15:10:53，本轮工作从 16:20 开始）；项目目录里 `find` 不到任何构建产物

---

## 0. R1 第二轮验收提的问题，逐条怎么处理的

| # | 验收的问题 | 处理 | 证据 |
|---|---|---|---|
| 1 | **【阻断·正确性】同一块屏上两条观察 ts 相同且换了应用时，增量 `buildSessions` 仍把同一条观察分进两个会话**（7 条观察复现：`--force` 3 段 → 零新观察 `--build` 4 段，id 3 重复且不自愈） | **已修**：不动点收敛之后**再查一次边界**——留下的会话里 `"end" == 起点` 的那几个如果含着 `ts == 起点` 的观察，把它们也卷进来重算（`Store.boundaryStartToInclude`）。验收给的 7 条观察加成了用例 | `results/same_ms_*.json`（`--force` 3 段、两次 `--build` 都 3 段、**逐字段相等**、重复 id 0）、新增用例 `testIncrementalBuildWithSameMillisecondObservationsOnOneDisplay`（把这一步注释掉，这条用例报 **18 处失败**） |
| 2 | **【文档】README 写 63 个用例 / T3 新增 25，实际 66 / 28，且同表格里已写 17 / 11** | **已改**：本轮又加了 2 个用例，现在统一成 **68 个（T2 38 + T3 30：`RetrievalTests` 18 + `SessionLedgerTests` 12）**，`swift_test.log` 与 README 三处一致 | `results/swift_test.log`、`core/README.md` 的目录树 / KeyProvider 表 / 测试一节 |
| 3 | **【口径】`docs/实施计划.md` 在上一轮编辑时段内被改过，其 §3.4 已写入分层延迟目标、§3.7 已写入打断闭区间；结果文件却还在报「未达标 / 等你拍板」** | **已改结果文件**（没有改 docs）：§7 与 §8.2 现在按计划 **v0.18 §3.4 的分层目标**（单字扫描 7 天 ≤ 150 ms / 限应用 ≤ 60 ms、报表类 ≤ 50 ms、FTS 与精确字段 < 10 ms）和 **§3.7 的闭区间**写，**四档全部达标**；§11 / §12 里的「等拍板」删掉。**这次改动不是我做的**：该文件 mtime 一直是 **15:10:53**，早于上一轮 scratch 目录建起来的时间（`~/Library/Caches/brosis-build/m1-r1-fix/workspace-state.json` mtime **15:11:12**），也早于本轮（16:20 起，本轮的 `collect.sh` mtime 16:46:30）；本轮结束时它仍是 15:10:53 | `docs/实施计划.md` §3.4 / §3.7 原文、`results/bench.json`、两个文件的 mtime |
| 4 | **【汇报一致性】上一轮交的汇报 JSON 还是第一轮的文本（63 个用例、`grep "Executed 63"`、collect.sh 取自 `m1-retrieval`、503.4 MiB）** | **已重出**：本轮汇报 JSON 全部按这一次的实测重写，`how_to_verify` 里的每条命令都在本机跑过一遍 | 本轮汇报 JSON |
| 5 | **【低】`Store+Sessions.swift` 的 mtime 晚于原始输出，交付的数字不是最终源码采的** | **本轮从流程上消除**：改完源码才跑 `collect.sh`，跑完只写结果文件、不再动 `core/`（末尾用 `find -newer` 复核过）。上一轮那次改动我无法从记录里复原内容；验收者在最终源码上复跑数字全部一致，说明它没有行为差异 | `results/collect_run.log` 与源码 mtime |
| 6 | **【低】`getItem` 的按天分桶取样点 `((start ?? 0) + (end ?? now)) / 2`，不给区间时落到 1998 年** | **已修**：取样点改成**命中行的 `(MIN(ts) + MAX(ts)) / 2`**（第一趟先算 `COUNT / MIN / MAX`，再定时区偏移，第二趟做直方图 / 应用 / 标题 / 最近证据）。现在只有跨夏令时切换的区间才可能有一天偏 1 h | `Store+Evidence.swift` 的 `getItem`、`results/bench.json` 的 `exact_item_app`（热 p95 40.51 ms，与修改前同量级） |
| 7 | **【低·评估覆盖】查询集没覆盖「高频词 + 早期时间窗」下 FTS 候选被截断导致漏召回的情形** | **已补三处**：① 查询集加 **win-05「跨周高频标记」**（种在全月 120 条、只查第 0 周窗口），Recall@10 = 1.000；② `eval.json` 现在每题都记 `fts_candidates` / `fts_candidates_truncated`，汇总里给 `max_fts_candidates` 与 `fts_candidates_truncated_queries`；③ 把悬崖量出来：同一条查询同一个库，候选上限 2000 → 10 条命中、上限 3 → **0 条且 `truncated = true`** | `results/eval.json`（55 题、`max_fts_candidates` 120、`fts_candidates_truncated_queries` 为空）、`results/truncation_default.json` vs `truncation_limit3.json`、新增用例 `testFTSCandidateTruncationOnEarlyWindowIsReported` |
| 8 | **【备注】`search(app:)` / CLI `--app` 只按 `bundle_id` 等值，`--app 终端` 静默 0 条** | **已在 README 的命令行一节写明**，并指到 `app:` 前缀（bundle_id 与应用名两列都匹配） | `core/README.md`「检索、会话与台账」命令一节 |

本轮**只动了上面这几条**，没有别的功能改动。代码改动落在 3 个文件：`Store+Sessions.swift`（边界同毫秒观察）、`Store+Evidence.swift`（`getItem` 取样点）、`tools/proto/gen_synth_m1.py`（win-05 与截断字段），外加两个测试文件各加一条用例。

## 1. 做了什么

| 文件 | 行数 | 内容 |
|---|---:|---|
| `RetrievalTypes.swift` | 428 | 检索 / 证据 / 会话 / 台账的入参与结果类型；**`TokenBudget`（token 口径）** |
| `Retrieval+Support.swift` | 239 | 查询形态路由、`LIKE` 转义、固定时区日历、区间并集、`source_state` → 三类时间 |
| `Store+Search.swift` | 456（口径变更后 515） | **三通道 `search`**：精确字段（两步式）/ FTS（bigram + rowid 倒序 + 两遍子串复核）/ 短查询扫描（查询串展开） |
| `Store+Evidence.swift` | 427 | `getEvidence`（含 grant 字段级限制与出现上下文）、`getItem`、`getContext`、`grants` 读写 |
| `Store+Sessions.swift` | 472 | 会话切分（3.7 三常量、双屏、**增量构建的不动点起点 + 同毫秒边界**、stale 重算） |
| `Store+Ledger.swift` | 309 | `getDayLedger`、`getTimeline` |
| `Store+Bench.swift` | 220 | 四类查询的压测计划，参数从库里真实取 |
| `Tests/RetrievalTests.swift` | 529（口径变更后 581） | **18 个**用例（口径变更后 **20 个**）|
| `Tests/SessionLedgerTests.swift` | 428 | **12 个**用例 |
| `tools/proto/gen_synth_m1.py` | 753 | 1 个月合成流生成器 + **55 题**带标准答案的查询集 + 评估 |
| `brosis-store/main.swift` | 914（T2 是 534 行） | 重写 `search`（T2 只跑 FTS 通道，改成三通道；T2 那个口径挪到 `fts-only`），新增 `search-batch` / `evidence` / `grant` / `item` / `context` / `timeline` / `sessions` / `ledger` / `bench` / `fts-only` 十个子命令；`import-jsonl` 改成流式逐行读 |

3.6 的六个工具**数据层**全部到位；`brosis-mcp` 进程本身（stdio、审计、按客户端拉起）按计划归 R2。

## 2. 怎么跑

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path core -c release \
  --scratch-path ~/Library/Caches/brosis-build/m1-r1-fix2

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path core \
  --scratch-path ~/Library/Caches/brosis-build/m1-r1-fix2

# 采一遍本文引用的全部原始输出（本次约 253 s）
# 想用自己的 scratch 目录：SCRATCH=~/Library/Caches/brosis-build/verify-t3 sh …/collect.sh
sh ~/Library/Caches/brosis-build/m1-r1-fix2/results/collect.sh
```

`collect.sh` 十七步：全新构建与测试 → 生成 1 个月合成流与查询集 → 建库导入 → **会话（全量 / 增量 / 幂等 / 无重复证据 / 与全量逐字段比）** → 日台账与时间线 → 检索评估 → 延迟压测 → **扫描策略 A/B 对照** → **峰值内存汇总** → 一致性与维护 → 删除后四个入口复核 → grant 字段级限制 → `get_context` 预算 → 台账 stale 重算 → 会话常量可配置 → **同毫秒观察的增量边界** → **FTS 候选截断对照**。

## 3. 构建、测试

| 项 | 数字 | 出处 |
|---|---|---|
| release **全新**构建（先删掉 `release` 产物目录再构建） | **0 error、0 warning**，22.96 s | `results/build_release_clean.log` |
| `swift test` | **68 个用例、0 失败**，4.930 s，0 warning | `results/swift_test.log` |
| — `BigramFTSTests` / `CrashRecoveryTests` / `CryptoAndBuildTests` / `E3ScenarioTests` / `StoreAPITests`（T2） | 8 / 2 / 12 / 7 / 9 | 同上 |
| — **`RetrievalTests`（T3）** | **18 个**，0.497 s | 同上 |
| — **`SessionLedgerTests`（T3）** | **12 个**，0.239 s | 同上 |
| `brosis-store`（release） | **3,289,632 字节 = 3.1372 MiB** | `results/binary_size.txt` |

> 二进制大小逐次构建会有几百字节的浮动（不同 scratch 路径下的调试映射不同），所以这里引用的是**这一次**构建的 `ls`，验收者复跑时以自己的 `binary_size.txt` 为准。

## 4. 1 个月合成库的规模

口径与 E7 完全一致：每天 8640 次捕获 = 24 h ÷ 10 s、平均 1500 字符中英混排、30% 新文本。
（本轮查询集多了 win-05 的 120 条种植，所以语料统计与 JSONL 的 SHA-256 与上一轮不同。）

| 项 | 数字 | 出处 |
|---|---:|---|
| 观察数 | **259,200**（30 天 × 8,640） | `results/gen_synth.json` |
| JSONL | 658,825,878 字节 = **628.3 MiB**，SHA-256 `642ba490…fa121d02` | 同上 / `results/jsonl_size.txt` |
| 生成耗时 / **峰值 footprint** | 38.38 s / **39.3 MiB**（41,189,856 B；RSS 是 52,723,712 B = 50.3 MiB） | `results/gen_synth.json` / `gen_synth.time` |
| 有正文的观察 | 221,951（85.6%）；新文本 84,840、复用 137,111 | `results/gen_synth.json` |
| 语料实测 | 平均 **1538.6 字符/段**、**1.673 字节/字符**、汉字占 **32.1%**（`cjk_ratio = 0.32124`） | 同上 |
| 导入 | 45.70 s，**5,672 条观察/s**，**峰值 footprint 818.4 MiB**（858,146,400 B；RSS 732,823,552 B = 698.9 MiB） | `results/import.json` / `import.time` |
| 库文件 | 533,118,976 字节 = **508.4 MiB**（WAL 0、SHM 32 KiB） | `results/stats.json` |
| — 正文 `text_versions` | 250,363,904 = **238.8 MiB**（净载荷 218,381,394 = **208.3 MiB**，放大 1.15×） | 同上 |
| — 全文索引 `text_fts` | 130,859,008 = **124.8 MiB** = 净载荷的 **0.60×** | 同上 |
| — 索引合计 / 元数据 | 231.0 MiB / 38.5 MiB | 同上 |
| 行数 | observations 259,200、text_versions 84,840、occurrences 221,951、fts_rows 84,840 | 同上 |

> **导入峰值 818.4 MiB 是当前实测值**（其中 128 MiB 是 `PRAGMA cache_size`）。导入已经是**流式逐行读 + 每批一个 `autoreleasepool`**；继续往下压要动批大小与 SQLite 页缓存，属于调参不属于修 bug，本轮没做。
>
> 与 E7 的 1 个月库（`tools/proto/results/capacity_2026-09-06.md` §3.1，580.9 MiB、索引 0.79×）不完全可比：本轮语料的字节/字符是 1.673（E7 是 1.89），汉字占比 32.1%（E7 是 40.5%），bigram 索引跟着汉字比例走，所以索引倍数低一些。**结论方向一致**：正文约占一半、FTS 约占三成。

### 4b.（2026-09-07 晚）NFKC 口径改成「索引侧折叠、原文不动」之后的复采

原始输出在 `~/Library/Caches/brosis-build/m1-nfkc/results/`（`collect_nfkc.sh` 是本节与 §6 的采集脚本，
只跑 collect.sh 的第 0 / 1 / 2 / 5 / 6 步；`fullwidth_probe.sh` 是下面那张全角对照表）。口径见
`m1_r1_core_store_2026-09-07.md` §9。

同一 seed、同一份 JSONL（SHA-256 仍是 `642ba490…fa121d02`），**库的每一项都逐字节没变**：
`db_file_bytes` 533,118,976、`text_versions` **84,840 行**、净载荷 218,381,394、FTS 130,859,008、
新文本 84,840 / 复用 137,111。原因很实在——`tools/proto/gen_synth_m1.py` 在写 JSONL **之前**
就对正文做了一次 NFKC（第 473 行），所以这份合成语料里**一个会被折叠的字符都没有**，
「存原文」与「存折叠后」在它上面是同一件事。

这说明两件事：① 口径变更在 1 个月库上**没有任何回归**（评估见 §6，延迟见 §7 下的复采行）；
② 它**证明不了**新补的那两条路，那由单测和下面这张全角对照表负责。

**全角对照**（`results/fullwidth_probe.json`）：把同一批语料的**前 20,000 条**观察里的
ASCII 可见字符全部改写成全角（17,071 个片段落到全角），与原样切片各建一个库：

| 项 | 原样切片 | 全角改写 | 说明 |
|---|---:|---:|---|
| `text_versions` 行数 | 6,604 | 6,604 | 去重变严了，但两份语料**各自内部**没有全角 / 半角变体，所以行数没变 |
| 净载荷 `SUM(byte_len)` | 16,639,076 | **28,118,994** | +69%：全角字符 UTF-8 是 3 字节，半角是 1 字节。这就是「证据原样」的存储代价 |
| 库文件 | 41,730,048 | **56,442,880** | +35% |
| FTS 索引 | 9,977,856 | 9,977,856 | **逐字节相同**——折叠确实还在索引侧照常起作用 |
| 13 项悬空检查 | 全过 | 全过 | |
| `search checkpoint`（半角查询） | 3 条 / `ftsVerified` 3 | 3 条 / `ftsVerified` 3 | 子串复核第二遍生效，全角正文没被误杀 |
| `search SQLCipher` | 3 / 3 | 3 / 3 | 同上 |
| `search 知识图谱` | 2 / 2 | 2 / 2 | 汉字不受折叠影响 |
| `search SQ`（两字，走扫描通道） | 5 条 | **5 条** | 前像展开生效；前像表不按大小写归并时这里是 3 条 |
| `get_evidence` 取回的正文 | — | `Ｃｏｄｅ — 测试工作区…` | **原样是全角**，入库没改过一个字节 |
| `scan_SQ` 热 p95 | 34.3 ms | **332.8 ms** | 全角库 `has_compat_text = 1` → 展开成 9 个 `LIKE`，且正文本身大 1.7 倍 |
| `scan 熵` 热 p95 | 39.4 ms | 54.7 ms | 纯汉字任何时候都只有 1 个 `LIKE`，差的只是正文体积 |

最后两行就是这次口径变更**唯一实测到的性能代价**，而且只落在「库里真有全角正文 + ASCII 短查询」
这一格上：`has_compat_text` 为 0 的库（纯 AX 来源、本轮 1 个月合成库）走的还是一个 `LIKE`。

## 5. 三通道检索（3.4）

一次 `search(q, start, end, app, limit)` 按 **精确字段 → 短查询扫描 → FTS** 的顺序走若干条通道，结果**并集**去重，每条通道内部按 `ts` 倒序。三处写法都照抄 E7（`capacity_2026-09-06.md` §10）实测出来的修正：

| # | 写法 | E7 的理由 | 本轮怎么验的 |
|---|---|---|---|
| 1 | 精确字段**两步式**，第一步空集直接返回 | 一条 `JOIN … ORDER BY ts DESC LIMIT` 在谓词命中 0 行时退化成倒序扫全表（12 个月库 520 ms） | `RetrievalTests.testTwoStepQueryPlanAvoidsObservationScan` 用 **`EXPLAIN QUERY PLAN`** 断言：一条 JOIN 的计划里有 `SCAN o`，两步式的计划里没有 `SCAN observations`。不依赖计时 |
| 2 | FTS 候选 **`ORDER BY rowid DESC`**，不用 `bm25` | `vrow` 单调递增 ⇒ rowid 倒序 ≈ 时间倒序，可从倒排表尾部短路；bm25 高频词要读完整条倒排表（12 个月库 225 ms） | 压测里 FTS 四条查询热 p95 **3.15–6.86 ms**（`results/bench.json`） |
| 3 | `sessions` 区间查询给 `start` 补下界 | 只写 `"end" >= ? AND start <= ?` 用不上 `idx_sessions_range`（12 个月库 6.42 ms） | 下界用**构建时实测的最长会话时长**（`meta.sessions_max_duration_ms`），不是硬编码 24 h。压测里 `sessions_range` 热 p95 **0.79 ms** |

另外几条是本轮自己踩出来的 / 按验收意见改的：

- **子串复核只作用于 FTS 通道，第一遍必须用 SQL 的 `LIKE`**。`unicode61` 把 `abc-def` 切成两个 token，phrase 查询于是命中了正文里的 `abc def`，但正文并不含这个子串——`RetrievalTests.testSubstringRecheckDropsTokenizerFalsePositive` 正反两面都断言了。用 Swift 的 `contains` 会变成大小写敏感，英文查询会漏；`LIKE` 对 ASCII 大小写不敏感，与 `unicode61`、与 `fts_compare.py` 的真值口径一致。
  - **（2026-09-07 口径变更后新增）复核有第二遍**：NFKC 折叠改成「只用于索引、原文不动」之后，正文存原文、`text_fts` 存折叠后的形式，一段全角正文能被半角查询 MATCH 到，只在原文上复核会把它误杀。所以第一遍没过的候选要把**候选正文现折叠**一遍再比（`TextPipeline.indexContains`）。候选有上限（200 / 2000），是有界的常数级开销；`RetrievalTests.testFTSChannelMatchesFullwidthBodyWithEitherWidth` 钉这条。详见 `m1_r1_core_store_2026-09-07.md` §9。
- **带路径的 URL 不能退回 host 等值**。`url:https://docs.internal.example/spec/` 要是也去匹配 `host = docs.internal.example`，同域名下别的页面会把前 10 条挤满。本轮评估里 `url-03` 这一题最初就是这么掉到 **Recall@10 0.4** 的，改成「带路径只按 URL 列子串匹配」之后回到 1.0（`RetrievalTests.testURLChannelDistinguishesBareHostFromPathURL`）。
- **纯汉字两字不开扫描通道**。`熵值` 本身就是**一个 bigram token**，FTS 通道 MATCH 到它再用 `LIKE` 复核，语义已经是精确子串；扫描通道对这一类**零召回增益**，却要把窗口内的正文全扫一遍。留给扫描通道的是**单字**（bigram 里没有对应 token）与 **≤ 2 字里含非汉字**的查询。判定在 `Store.scanChannelApplies(to:options:)`，可以用 `retrieval.scanSkipsPureCJKBigram` / CLI 的 `--scan-all-short` 关掉做对照。
  - **同一个库、同一条查询的 A/B**（`results/bench.json` vs `results/bench_scan_all_short.json`）：`熵值` 热 p95 **4.64 ms**（默认）vs **140.59 ms**（一律扫），**命中行数都是 14**；加 `app` 过滤 2.40 ms vs 47.78 ms，**命中都是 7**。
  - 召回侧：55 题里 6 道「中文两字词」`channels` 只有 `fts`，Recall@10 / Precision@10 仍是 **1.000**（`results/eval.json` 的 `per_query`）。
  - **（2026-09-07 口径变更后新增）扫描通道的 `LIKE` 要展开查询串，但只在需要时展开**。它在**原文**上做子串匹配，而原文不再折叠，「半角查询 → 全角原文」这一路靠折叠查询串是做不到的（查 `AB`、正文是 `ＡＢ`，折叠 / 不折叠两种写法都不在原文里，实测断言全部落空）。改成把查询串展开成兼容区的**单标量前像**一起 LIKE（`Store.scanPatterns`）。**没选「现折叠正文」**：那是对 7 天窗口约 34 MiB 正文逐条 NFKC，这一档本来就最贵（热 p95 122 ms / 目标 150 ms），加不起。
    - **展开按模式条数线性变慢**：1 个月库上同一条 ASCII 两字查询（`--short-queries SQ`，命中 10 条、不触发 `LIMIT` 短路）**1 个 `LIKE` 117.4 ms → 9 个 721.0 ms**。所以 `Store.hasCompatibilityText`（写入时记进 `meta.has_compat_text`）记录库里到底有没有「折叠会变样」的正文，**没有就只发一个 `LIKE`**——本轮 1 个月合成库正是这一档，§7 的延迟表**逐条没有回归**。纯汉字查询任何时候都只有 1 个 `LIKE`（`熵` 在兼容区里没有前像）。
    - **试过但退回**：把 9 种写法压成一个 `GLOB` 字符类想一遍扫完，反而更慢（同一条查询 **605.1 ms**，连 `熵` 都从 122.3 掉到 **398.5 ms**）——SQLite 的 `GLOB` 走带 UTF-8 逐字符解码的通用匹配器。
    - 代价：只覆盖单标量前像，连字这类由 FTS 通道兜底。
- **（本轮新增）FTS 候选截断是一个会漏召回的已知边界，现在能看出来也能量出来。** 候选按 `ORDER BY rowid DESC LIMIT`（无过滤 200、带时间 / 应用过滤 2000）取，**时间过滤在候选之后做**：一个词的文本版本数超过候选上限、而窗口又落在更早的时间时，早期命中根本进不了复核。
  - 结果里的 `ftsCandidatesTruncated` 报 `true`，调用方能区分「确实没有」与「没看完」。
  - **本轮 55 题一题都没触发**：`max_fts_candidates = 120`（win-05），`fts_candidates_truncated_queries` 为空（`results/eval.json`）。
  - **悬崖量在这里**：同一条查询、同一个库，候选上限 2000 → **10 条命中、truncated = false**；上限压到 3 → **0 条命中、truncated = true**（`results/truncation_default.json` vs `truncation_limit3.json`，CLI `--fts-candidates-filtered`）。单测 `testFTSCandidateTruncationOnEarlyWindowIsReported` 在 20 个版本的小库上把这三种情形（默认全召回 / 截断后漏召回且报 true / 截断但查最新窗口不受影响）一次断言完。
  - 真正的修法是把时间约束推进候选选取，需要 `vrow ↔ 时间` 的映射——`text_versions.created_at` 是**写入墙钟**（整月导入都落在那 46 s 里），用不了；加列或加索引是 schema 改动，归 M2。

**token 口径**：token 数 = **字符数 ÷ 2，向上取整**（`TokenBudget`）。3.6 的「每条 ≤ 100 token 摘要」就是每条 ≤ 200 字符。本轮 55 题里**最大摘要 80 token**（`results/eval.json`）；`get_context` 三档预算实测用量 458 / 1991 / 7921 token，都没越界（`results/context_*.json`）。逐条计费时把拼接用的换行也算进去了，测试用 120 段短正文 × 5 档预算（含 199 / 501 / 777 这种奇数档）断言 `usedTokens ≤ maxTokens` 且与全文重算一致。

## 6. 检索评估：Recall@10 / Precision@10

查询集 **55 题**（49 题有答案 + 6 题负例），十一类，全部**带标准答案**。真值口径沿用 `tools/bench/fts_compare.py`：查询词只种在指定数量的文档里，基础语料里一个查询词都不出现，**真值在生成时对每条观察全量重算**，不靠种植记录推断。

| 类别 | 题数 | Recall@10 | Precision@10 | 主要通道 |
|---|---:|---:|---:|---|
| 中文两字词 | 6 | **1.000** | 1.000 | **fts**（不并扫描通道） |
| 单个汉字 | 4 | **1.000** | 1.000 | scan（bigram 命中不了） |
| 中文三字以上 | 7 | **1.000** | 1.000 | fts |
| 英文单词 | 5 | **1.000** | 1.000 | fts |
| 代码标识符 | 5 | **1.000** | 1.000 | fts |
| URL / 域名 | 4 | **1.000** | 1.000 | exact_url + fts |
| 文件路径 | 4 | **1.000** | 1.000 | exact_path + fts |
| 数字 / 错误码 | 4 | **1.000** | 1.000 | fts |
| 中英混排短语 | 3 | **1.000** | 1.000 | fts |
| 时间窗过滤 | **5** | **1.000** | 1.000 | fts（带 start/end），含**新增的 win-05** |
| 应用过滤 | 2 | **1.000** | 1.000 | fts（带 app）/ exact_app |
| **合计** | **49** | **1.000** | **1.000** | — |

- **目标是 Recall@10 ≥ 90%，实测 100%**，`results/eval.json` 的 `failures` 为空数组。
- **6 道负例一条都没返回**（`none_queries_with_false_positives: 0`）：`麒麟` / `鳄` / `星际航行日志` / `quokkaflux` / `nowhere.invalid.example` / `/tmp/brosis-m1/never-written.bin`。
- **新增的 win-05「跨周高频标记」**：种在全月 120 条（`fts_candidates = 120`，是全套里最多的一题），只查**第 0 周**窗口，窗口内真值 28 条，取前 10 条 **Recall@10 = Precision@10 = 1.000**，`fts_candidates_truncated = false`。它覆盖的正是「全月都出现的词 + 早期窗口」这一形态（见 §5 最后一条）。
- 整套 55 题在一个进程里跑完 **0.78 s**（`search-batch`）。
- 两题（`AXReader.swift`、`LedgerBuilder.swift`）被路由判成「域名」而不是「路径」——`.swift` 的形状和顶级域一样。**代价只是多跑一次空的两步式查询**（`results/bench.json` 里 `exact_path_miss` 热 p50 **0.006 ms**），FTS 通道照样把它们召回，Recall 仍是 1.0。这正是「三条通道是并集不是互斥」的价值。

**（2026-09-07 晚，NFKC 口径变更后的复采）** 同一份查询集、同一个库、同一条命令，
**55 题 Recall@10 / Precision@10 仍是 1.000**：`failures` 为空、6 道负例零误报
（`none_queries_with_false_positives: 0`）、`max_fts_candidates` 仍是 120、
`fts_candidates_truncated_queries` 仍为空、最大摘要仍是 80 token、整套 0.81 s
（`~/Library/Caches/brosis-build/m1-nfkc/results/eval_summary.json`）。
延迟同样没动（同一台机器、冷 10 轮 / 热 20 次）：单字扫描 `熵` 热 p95 **124.46 ms**（本表 122.40）、
四条 FTS 查询 **3.39–7.09 ms**（3.15–6.86）、`get_item(app)` **43.52 ms**（40.51）、
7 天 `get_timeline` **28.79 ms**（28.17），全套最大热 p95 **124.46 ms**，四档目标依旧全部达标
（`results/bench.json`）。

> 口径说明：这是**合成语料 + 自己出的题**，只能证明检索方法本身成立，不能当作真实使用的召回率。计划 4.2 要求的「真实查询集扩到 60 题」需要你按 `docs/查询集草稿.md` 填真实事件，归 R2。

## 7. 延迟：四类查询，冷 / 热 p50 / p95（1 个月库）

口径与 `tools/proto/measure.py` 一致：**冷** = 全新子进程 + **每条查询各开一条新连接**跑一次就关（只清了 SQLite 自己的页缓存，没清 macOS 文件缓存，所以冷数字是下界）；**热** = 同一连接预热 1 次后连测 20 次。冷 **20 轮**、热 **20 次**，p50 / p95 用与 measure.py 相同的线性插值。原始数据 `results/bench.json`。

**验收阈值按计划 v0.18 §3.4 的分层目标**（2026-09-07 定）：FTS 通道与精确字段通道 **热 p95 < 10 ms**；1–2 字扫描通道 **7 天窗口 ≤ 150 ms、限应用 ≤ 60 ms**；报表类查询（`get_item(app)` 的月度聚合、7 天 `get_timeline`）**≤ 50 ms**。

| 类别 | 查询 | 命中行 | 冷 p50 / p95 | 热 p50 / p95 | 目标 | 达标 |
|---|---|---:|---:|---:|---:|:--|
| **精确字段** | `host:` 等值 → 观察 | 20 | 5.06 / 5.12 | 4.42 / **5.23** | < 10 | ✅ |
| | `url:` 前缀 → 观察 | 20 | 5.28 / 5.36 | 3.82 / **3.85** | < 10 | ✅ |
| | `path:` 子串 → 观察 | 20 | 4.21 / 4.27 | 3.84 / **3.87** | < 10 | ✅ |
| | `title:` 子串 → 观察 | 20 | 2.99 / 3.04 | 2.63 / **2.67** | < 10 | ✅ |
| | **路径命中 0 行（两步式空集早返回）** | 0 | 0.024 / 0.029 | 0.006 / **0.008** | < 10 | ✅ |
| | `get_evidence` 主键点查 20 条 | 20 | 2.34 / 2.43 | 1.90 / **1.93** | < 10 | ✅ |
| | `get_item(app)`（该应用 62,217 条观察） | 62,217 | 56.29 / 57.21 | 39.41 / **40.51** | ≤ 50（报表类） | ✅ |
| **FTS 检索** | `知识图谱` | 20 | 9.28 / 9.43 | 6.80 / **6.86** | < 10 | ✅ |
| | `采集覆盖率` | 18 | 8.71 / 8.84 | 6.37 / **6.45** | < 10 | ✅ |
| | `checkpoint` | 20 | 6.36 / 6.47 | 3.69 / **3.79** | < 10 | ✅ |
| | `SQLCipher` | 17 | 5.11 / 5.22 | 3.14 / **3.15** | < 10 | ✅ |
| **1–2 字短查询** | `熵值`（纯汉字两字 → 只走 FTS） | 14 | 6.11 / 6.22 | 4.60 / **4.64** | < 10（走 FTS） | ✅ |
| | `熵值` + 限应用 | 7 | 3.74 / 3.86 | 2.36 / **2.40** | < 10（走 FTS） | ✅ |
| | `熵`（单字 → 7 天窗口扫描） | 20 | 168.84 / 170.79 | 121.40 / **122.40** | ≤ 150（扫描档） | ✅ |
| | `熵` + 限应用 | 15 | 93.57 / 94.41 | 49.66 / **50.33** | ≤ 60（扫描 + 限应用） | ✅ |
| **聚合** | `get_context(24 h, 2000 token)` | 8 | 5.84 / 5.88 | 4.71 / **4.82** | < 10 | ✅ |
| | `get_timeline(最近 7 天, day)` | 8 | 31.57 / 31.93 | 27.57 / **28.17** | ≤ 50（报表类） | ✅ |
| | `get_day_ledger`（读缓存） | 6 | 0.25 / 0.73 | 0.048 / **0.055** | < 10 | ✅ |
| | `sessions` 区间查询（start 补下界） | 299 | 0.99 / 1.00 | 0.72 / **0.79** | < 10 | ✅ |

按类别汇总（p95 取该类所有样本的 p95）：

| 类别 | 冷 p50 / p95 | 热 p50 / p95 | 该类最大单条热 p95 |
|---|---:|---:|---:|
| 精确字段 | 4.21 / 56.46 | 3.82 / 39.52 | 40.51（`get_item(app)`，报表档） |
| FTS 检索 | 7.51 / 9.32 | 4.96 / 6.83 | **6.86** |
| 1–2 字短查询 | 49.25 / 170.42 | 26.76 / 122.10 | 122.40（单字扫描档） |
| 聚合 | 5.79 / 31.81 | 2.77 / 27.73 | 28.17（7 天 timeline，报表档） |

全套最大热 p95 **122.40 ms**（`bench.json` 的 `hot_p95_max_ms`），出现在单字扫描这一档，目标 150 ms。

**三档阈值分别在量什么（分层的理由）：**

1. **单字扫描（50–123 ms）是它的定义决定的，不是实现问题。** 这条通道按定义要把窗口内的正文扫一遍：7 天窗口里有 60,480 条观察、约 34 MiB 正文。**延迟与库规模无关**（只跟窗口大小与命中密度有关），E7 报的 0.19 ms 是「高频词 + `LIMIT 20` 提前短路」的下界；本轮查询集里的单字是**稀有词**，扫描没法短路，测到的是这条通道的**上界**。两个可调项已实测：加 `app` 过滤降到 50.33 ms（−59%），缩短 `scanWindowDays` 线性下降。真正的解法（单字倒排 / 辅助索引）会抬高索引体积，与 D21 的 0.6 GiB/月冲突，留 M2 先量再决定。
2. **`get_item(app)` 40.5 ms**：一个应用一个月有 62,217 条观察，按天直方图必须把它们数一遍。聚合**已经全部在 SQL 里做**（`COUNT` / `MIN` / `MAX` / `GROUP BY`），不把行拉进 Swift；给 `start` / `end` 收窄范围就线性下降。
3. **7 天 `get_timeline` 28.2 ms**：要把窗口内每条观察折算成时间片。同理，随「问多长的区间」增长，不随库规模增长。

试过但退回的两个做法（都在代码注释里写明了）：

- **扫描通道拆成「先 `DISTINCT` 文本版本、再只扫这些版本」的两步式**：本轮语料一个文本版本平均被 2.6 条观察引用，理论上正文只用扫一遍。同一个库上实测**慢了将近一倍**——省下的正文扫描抵不过 6 万行上的 `DISTINCT` 临时 b-tree 加几十次 400 元素 `IN` 回查。精确字段那条要两步是因为**空集能早返回**，扫描通道没有空集可言，两步只是纯开销。已退回单条 SQL。
- **`get_context` 的正文片段用一条 `JOIN … ORDER BY o.ts DESC, oc.ord LIMIT N`**：这个 `ORDER BY` 让规划器上临时排序器，要求把整个窗口的行（连正文一起）读出来再排，`LIMIT` 救不了，一条就吃掉几乎全部时间。改成两步式（先在 `observations` 上纯索引扫出前 N 条 id，再按 id 取正文）之后是现在的 4.82 ms。

## 8. 会话与日台账（3.7）

### 8.1 三类时间分列

| 类别 | 包含的 `source_state` |
|---|---|
| `unknown_s` | `permission_lost` / `timeout` / `locked`（3.7 点名的三种），**不算前台停留** |
| `dwell_s` | 其余全部（`ok` / `user_idle` / `secure_input`） |
| `active_s` | `ok` / `secure_input`（`user_idle` 明确是「用户未活动」，不算） |

`active ⊆ dwell`，`dwell + unknown` = 会话总时长，三个数**分列报告不相加**。
一条观察代表的时长 = 到「同一块屏上的下一条观察」为止，**上限 90 s**；每块屏最后一条记 0。

### 8.2 三个常量的边界（`SessionLedgerTests`，全部实测）

| 常量 | 默认 | 边界断言 |
|---|---:|---|
| 停留上限 `maxDwellSeconds` | 90 s | 0 s / 200 s / 260 s 三条观察 → dwell = 90 + 60 + 0 = **150 s**；把上限改成 30 s → **60 s** |
| 间隔 `gapSeconds` | 300 s | 间隔 **299 s → 1 个会话**，**300 s → 2 个会话**（开区间）；改成 600 s → 又变回 1 个 |
| 打断 `interruptionSeconds` | 20 s | 离开 15 s → 1 个会话 + 1 次打断；离开**正好 20 s → 算打断**（**闭区间**）；离开 25 s → 2 个会话、0 次打断；把上限改成 30 s → 25 s 也算打断 |

**打断用闭区间、间隔用开区间，计划 3.7 已经定了**（v0.18：「打断阈值按闭区间判定（离开正好 20 s 也算打断）」）。理由记录在案：E7 口径是 10 s 一次捕获，**一条观察的外出往返正好是 20 s**，用严格小于的话默认常量下一次打断都观测不到（实测过，那一版 1 个月台账的打断数全是 0）。三个常量都是待校准参数，真实采样率定下来之后要重标。

同一个库换一套常量重建（`--gap-s 600 --interruption-s 60`）：会话数 8,189 → **8,087**（`results/sessions_alt_config.json` / `sessions_default_config.json`）。

### 8.3 双屏：焦点归属 + 区间并集

时长按**焦点窗口归属**（每块屏一条独立焦点流，会话不跨屏），另算所有会话区间的**并集**当「总在线」，两者都报告、不重复计。

- 单元测试：两块屏各两条完全重叠的观察 → 焦点归属求和 **60 s**，区间并集 **30 s**。
- 1 个月库实测（2026-08-08，`results/ledger_2026-08-08.json`）：焦点和 **79,270 s**，并集 **77,910 s**，每屏 34,080 / 45,190 s。

### 8.4 增量构建与 stale 重算（**两轮验收的阻断项都在这里**）

R1 第一轮验收发现：零新观察的 `--build` 会让会话数从 8,189 变成 8,190。根因是重算起点只按 `start >= rebuildFrom` 删会话——**起点更早、尾巴伸进重算区间的会话被原样留下**，它里面 `ts >= rebuildFrom` 的观察又被重扫分进新会话。第一轮修法：起点取「与 `[起点, ∞)` 有交叠的会话」的 `MIN(start)` 不动点。

R1 第二轮验收发现那个不变量还漏了一种情形：**同一块屏上两条观察的 `ts` 完全相同**（毫秒时间戳，记录器取 `Date()`，schema 上也没有 `(device_id, display_id, ts)` 唯一约束）。这时前一条的时间片长度是 0（`end == ts`），它所在的会话满足 `"end" == 起点` 且 `start < 起点`，被留下；可它含着 `ts == 起点` 的观察，重扫又把这条观察分进新会话，而且**再 `--build` 一次也不自愈**。

现在的起点分三步定（`Store+Sessions.swift` 的 `incrementalRebuildStart`）：

1. **锚点** = `min(最早一条 stale 会话的 start, 每块屏最后一个会话的 start)` **再减一个 `maxDwellSeconds`**——新观察只可能延长每块屏最后那个会话，被删除标脏的会话必须重算，而一条观察的时长最多受它后面 90 s 内的观察影响。
2. **往前推到不切开任何会话**：把所有与 `[起点, ∞)` 有交叠的会话（`"end" > 起点 或 start >= 起点`）一起删掉重算，起点取它们的 `MIN(start)`；**迭代到不动点**（上限 64 轮，不收敛就退回全量重建，正确但慢）。判据用**严格大于**而不是 `>=`：相邻两个会话通常首尾相接，写成 `>=` 会把整个月的会话串成一条链，增量退化成全量（实测过，`observationsScanned` 会变成 259,200）。
3. **（本轮新增）再查一次边界上的同毫秒观察**（`boundaryStartToInclude`）：留下的会话里 `"end" == 起点` 的那几个（**通常一个、可能多个**：会话按 `(display, app)` 切，同一块屏上多条同毫秒观察分属不同应用时每个应用各留一个长度为 0 的会话）如果含着 `ts == 起点` 的观察，把它们也卷进来（起点降到它的 `start`）再迭代。查法是先在 `observations(device_id, ts)` 上点查 `ts == 起点` 的活观察——**绝大多数库里这一步直接空集返回**，再对那几个会话展开证据判包含。起点每轮严格变小，所以仍然收敛。

| 项 | 数字 | 出处 |
|---|---:|---|
| 全量构建 25.92 万条观察 → 8,189 个会话 | **177.0 ms**，峰值 footprint **185.7 MiB**（194,675,408 B；RSS 210,403,328 B = 200.7 MiB） | `results/sessions_full.json` / `sessions_full.time` |
| **零新观察的增量构建（连跑两次）** | 两次都是**扫 637 条、删 22 插 22、总数 8,189**，4.36 / 4.19 ms | `results/sessions_incremental.json` / `sessions_incremental2.json` |
| **一条观察只进一个会话** | 8,189 个会话的证据 id 展开后 **259,200 个，去重后还是 259,200，重复 0** | `results/sessions_no_duplicate_ids.json` |
| **增量后的结果 = 全量重建的结果** | 8,189 vs 8,189，`start` / `end` / 三类时长 / 打断数 / 证据 id **逐字段相等** | `results/sessions_incremental_equals_full.json` |
| **同毫秒边界（验收给的 7 条观察）** | `--force` **3 段** `A[1,2,3] B[4,5] C[6,7]`；零新观察 `--build` 两次都是 **3 段**、与 `--force` **逐字段相等**、重复 id **0**（修复前：`--build` 4 段、多出 `A[3]`、id 3 重复、不自愈） | `results/same_ms_force.json` / `same_ms_build.json` / `same_ms_build2.json` / `same_ms_compare.json` |
| 删除 5 条观察后 | `sessions_stale = 5`，stale 会话**不进区间查询结果** | `results/delete_apply.json` / `delete_after_sessions.json` |
| stale 重算 | `staleRecomputed = 5`，重扫 67,888 条、删 2,087 插 2,087，52.8 ms，总数仍是 8,189 | `results/delete_after_rebuild.json` |

单元测试三条：`testIncrementalBuildOnlyScansNewObservations`（单屏，只扫新观察 + 与全量一致）、`testIncrementalBuildMatchesFullRebuildWithTwoDisplaysAndInterruption`（两块屏边界不对齐 + 一次打断）与**本轮新增的** `testIncrementalBuildWithSameMillisecondObservationsOnOneDisplay`（同屏同毫秒换应用；另带一个两块屏各有一对同毫秒观察的场景）。**把第 3 步的调用注释掉，最后这条用例立刻报 18 处失败**（会话数 4 ≠ 3、证据 `[[1,2,3],[3],[4,5],[6,7]]`、id 去重后 7 ≠ 8），已实测确认它不是空断言。

### 8.5 日台账

`getDayLedger(date)` 按 `retrieval.timeZone` 切自然日，产出按**应用 / 站点 / 文件**三张表 + 三类时间 + 焦点和 / 并集 / 每屏时长 + 切换数 / 打断数 / 会话数 / 观察数 + D23 区间证据 + 算它用的三个常量，**`narrative` 与 `model` 恒为 `null`**（3.7：台账与叙述分开标注，叙述是 M2 的可选夜间任务）。

前三天实测（`results/ledger_2026-08-0*.json`）：

| 日期 | 观察 | 会话 | 切换 | 打断 | dwell | active | unknown | 焦点和 | 并集 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2026-08-08 | 8,640 | 276 | 324 | 53 | 79,270 | 75,080 | 8,960 | 79,270 | 77,910 |
| 2026-08-09 | 8,640 | 281 | 337 | 58 | 79,090 | 74,850 | 8,580 | 79,090 | 78,150 |
| 2026-08-10 | 8,640 | 272 | 323 | 53 | 79,030 | 74,700 | 8,550 | 79,030 | 78,010 |

台账是**确定性**的（不经过任何模型），已有且不是 `stale` 的直接读回（压测里 `ledger_day` 热 p50 0.048 ms）。
跨日边界的时间片按天裁开：`testDayLedgerClipsAcrossMidnight` 断言 23:59:20 那条观察的 90 s 里 40 s 记当天、50 s 记第二天。
`get_timeline` 在整个 30 天区间上按 `day` 分桶得 **30 个桶**（`results/timeline_day.json`）。

## 9. 删除后各入口都不再返回内容（3.8 验收）

在 1 个月库上跑的完整链路（`results/delete_*.json`）：

| 步骤 | 结果 |
|---|---|
| 删除前 `search 知识图谱` | `[254379, 219529, 218910, 205773, 191368]` |
| 删除前 `getEvidence` 这 5 个 id | 5 条，都有原文 |
| `delete --observations` 这 5 个 | 观察 5、出现 5、文本版本 5、**FTS 行 5**（实测 84,840 → 84,835）、会话 stale 5、台账 stale 1、释放 13,365 字节 |
| 删除后 `search 知识图谱` | 换成 `[187703, 156216, 151845, 143024, 137897]`，**被删的一条都不在** |
| 删除后 `getEvidence` 同样的 id | `items: []`，`missing: [254379, 219529, 218910, 205773, 191368]`——**只回 id，不回任何内容** |
| 删除后 `sessions` | stale 5，重算后 stale 归 0、总数仍是 8,189 |
| 删除某一天的观察后 `getDayLedger` | 该天台账 `ledgers_stale = 1` → 重算后观察数 8640 → **8637**，证据区间从 `[[1,8640]]` 裂成 `[[1,999],[1003,8640]]` |
| 两次 `check`（删除前后） | 13 项悬空引用**全部为 0**，`integrity_check` / `foreign_key_check` / FTS `integrity-check` 全 ok |

单元测试 `RetrievalTests.testDeletedObservationDisappearsFromEveryEntry` 把 `search` / `getEvidence` / `getContext` / `getDayLedger` 四个入口一次断言完。

## 10. grant 字段级限制（3.6 的钩子，已实跑）

| 情形 | 结果 | 出处 |
|---|---|---|
| 不给 grant（本地可信调用方） | 2 条证据，原文 1292 / 1294 字符，各带前后 2 条出现上下文 | `results/grant_none.json` |
| `fields = summary` | 2 条，**结果里不再有 `text` 字段**（原文与每条 occurrence 的正文都不返回，只剩 `byteLen` / `ord` / `region`），`redactedByGrant = true`，摘要仍在（各 200 字符 = 100 token） | `results/grant_evidence.json` |
| 应用白名单 `["com.apple.Terminal"]` | 0 条，`deniedByGrant = [256975, 256454]` | `results/grant_narrow.json` |
| 时间窗（默认 30 天） | 超窗的 id 同样进 `deniedByGrant`（单元测试 `testGrantLimitsFieldsAppsAndWindow` 用 90 天前的观察断言） | `results/swift_test.log` |

## 11. 未做与原因

| 项 | 原因 |
|---|---|
| **把 FTS 候选截断真正修掉**（把时间约束推进候选选取） | 需要 `vrow ↔ 时间` 的映射：`text_versions.created_at` 是写入墙钟（整月导入都落在那 46 s 里），用不了；加列或加索引是 schema 改动，本轮明确不改 schema。现在的做法是**能报出来（`ftsCandidatesTruncated`）+ 能量出来（§5）**，修法归 M2，与向量 / 相关度排序一起做 |
| **把导入峰值 818 MiB 压下来** | 要降得动批大小与 `cache_size`，属于调参且会牵动导入吞吐，留给 T4 接真实记录器时一起量 |
| `brosis-mcp` 进程（stdio 传输、按客户端拉起、调用审计） | 计划 4.2.1 把它排在 R2，依赖本轮的数据层。本包只提供 6 个工具的数据层与 grant 判定 |
| 3 / 12 个月规模的延迟 | 本轮约束明确写了「不要在这台 16 GiB 机器上建 12 个月库」。E7 已经在 1 / 3 / 12 三个规模上证明了「修完三处写法之后延迟与规模无关」，本轮验证的是**修法确实落到了实现里**（`EXPLAIN QUERY PLAN` + 1 个月实测） |
| 真实查询集（60 题） | 需要你按 `docs/查询集草稿.md` 填真实事件与期望答案，归 R2 的「评估与月报」 |
| 向量检索、混合排序 | D8 未通过。本轮 FTS 候选是**时间序**（rowid 倒序）不是相关度序，要相关度得在候选窗口里补算 bm25，M2 再说 |
| 单字查询的索引方案 | 见 §7 第 1 条。加单字倒排会显著抬高索引体积，与 D21 的 0.6 GiB/月冲突，要先量再决定 |
| 周台账 | 3.6 明确写了周台账放 M2；`ledgers.level` 已经有 `week` 的 CHECK，接口留着 |
| 真实输入计数驱动的 `active_s` | 本包的 `active` 是按 `source_state` 判的；CGEventSource 输入计数在采集端（T4），接上之后才是字面意义上的「有输入」 |
| `getItem` 按天分桶在跨夏令时切换的区间上仍可能偏 1 h | 取样点已经从「区间中点」改成「命中行的 `(MIN(ts) + MAX(ts)) / 2`」，剩下的是「一个区间内偏移变过」这一种；根治要按天各取各的偏移（分桶就得在 Swift 侧做，或者按本地日再建一列）。UTC 与中国时区没有夏令时，不影响本项目 |

## 12. 对计划的影响

**3.4 与 3.7 可以按现在的口径收口。**

- 检索：三通道在 1 个月合成库上 **Recall@10 / Precision@10 都是 100%**（目标 90%，55 题、十一类、6 道负例零误报），摘要 ≤ 100 token，`get_context` 有 token 预算截断。
- 延迟：按 §3.4 **已经分层的目标**逐条对照，**四档全部达标**——FTS 与精确字段热 p95 ≤ 6.86 ms（目标 10）、单字扫描 122.40 ms（目标 150）、扫描 + 限应用 50.33 ms（目标 60）、报表类 40.51 / 28.17 ms（目标 50）。分层是对的：这三类查询的成本分别由「库规模」「窗口大小 × 命中密度」「问的对象有多大」决定，共用一个阈值没有意义。
- 会话：增量构建这两轮从「会重复计入」修成了「与全量重建逐字段相等且幂等」，台账因此才是可增量维护的。**建议 3.7 的验收里明确写上两条硬性检查**：①「增量与全量必须逐字段一致」；②「同一条观察只能出现在一个会话的证据里」。两轮的阻断项都是这两条抓出来的，只看「只扫了新观察」看不出来。
- 新增一条要记进已知限制的边界：**FTS 候选按 rowid 倒序截断时，早期时间窗会漏召回**（本轮语料离悬崖还很远：最多 120 个版本 vs 上限 2000，但真实库里一个高频词很容易过 2000）。结果里已经有 `ftsCandidatesTruncated` 可以判，M2 做相关度排序时一起解决。
- 3.7 的三个常量都是可配置参数并有边界测试，其中「打断 20 s」按计划已定的**闭区间**实现；真实采样率定下来后需要重标这三个数。
