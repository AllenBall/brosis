# M2 c 批 / T12：夜间叙述（本地模型 + 确定性忠实度自检）

日期：2026-09-08 · 机器：M4 Air（Mac16,12）/ 16 GiB / 无风扇 / macOS 26.6 · Swift 6.3.3、语言模式 v6
对应计划：4.3「可选叙述：mlx-swift-lm 加载 app 管理的可选模型，夜间日 / 周叙述（接电、空闲、
热状态门控；输出与台账分开标注）」、3.7 台账口径、3.10 提供方抽象（**只做本地实现**）、
3.11 模型管理器、**D19**（Qwen3.5-4B 实测与两处忠实度偏差）、**D27**（缓冲池 256 MiB + 热门控）；
报告 L6。

**一句话**：叙述做成了**贴在台账上的一层标注**——台账仍然是确定性的，叙述由本地
Qwen3.5-4B 写，写完先过一遍**确定性的四条核对**，过了才入库、没过一个字都不留；
整套默认关闭，模型没装时显示「未启用」。

---

## 1. 做了什么

| # | 东西 | 落在哪 |
|---|---|---|
| 1 | 提示构造 + 五级压缩 + 忠实度核对 + 生成侧提供方抽象（**core 里零 mlx 依赖**） | `core/Sources/BrosisCore/Narrative.swift`（新） |
| 2 | **schema v6**：`ledgers.narrative_meta` 一列 + `NarrativeMeta` 类型 | `core/Sources/BrosisCore/SchemaV6.swift`（新） |
| 3 | 叙述输入、待办清单、跑一次叙述、读写三列 | `core/Sources/BrosisCore/Store+Narrative.swift`（新） |
| 4 | `DayLedger` 加 `narrativeMeta` 与 `narrativeIsStale`（MCP 的返回形状） | `RetrievalTypes.swift`（追加两处） |
| 5 | 台账缓存透传 `narrative_meta`、重算时三列一起置 NULL | `Store+Ledger.swift`（改三处） |
| 6 | v6 迁移注册（新库一行、老库一块） | `Schema.swift`、`Store.swift`（各追加一处） |
| 7 | 本地生成运行时（`LLMModelFactory` + `ChatSession`，关思考 / 温度 0 / 两道保险） | `app/Sources/BrosisModels/MLXGenerationProvider.swift`（新） |
| 8 | 夜间叙述调度器（**复用 T11 的环境采集与同一本 GPU 预算账**） | `app/Sources/brosis/Models/NarrativeScheduler.swift`（新） |
| 9 | 自检第 9 组（门控 15 条、提示裁剪、忠实度 6 条、端到端） | `app/Sources/brosis/Models/NarrativeSelfCheck.swift`（新，`SelfCheck.swift` 只加一行） |
| 10 | `--narrative-smoke`：**用真实模型**跑一次（不进默认自检） | `app/Sources/brosis/Models/NarrativeSmoke.swift`（新，`main.swift` 只加三行） |
| 11 | `Package.swift` 加一个产品 `MLXLLM`（同一个固定的 mlx-swift-lm 3.31.4） | `app/Package.swift`（追加一行） |
| 12 | **24 个新用例** | `core/Tests/BrosisCoreTests/NarrativeTests.swift`（新） |

**`AppDelegate.swift` 一行没改**；`StoreMCPService.swift` 一行没改（T14 在动它）。
接入方式见第 7 节。

---

## 2. 设计上的三个决定

### 2.1 叙述放 core、模型放 app

`GenerationProvider`（3.10 的 `generate` 侧）只有协议在 core，本地 mlx 实现在 app 注入，
与 T11 的 `EmbeddingProvider` 完全同构。好处是 `swift test --package-path core`
**不编译 mlx-swift** 就能把整条叙述路径（构造 → 裁剪 → 生成 → 核对 → 入库 / 丢弃）跑完，
24 个用例 0.31 s；真实模型那一次单独放 `--narrative-smoke`。

**线上适配器本轮不写**（用户指示：不接线上模型）。协议留着，将来接线上时本地与线上共用
温度 0 / 关思考 / 失败重试一次这几条规则。

### 2.2 schema v6 只加一列

`ledgers` 从 v1 起就有 `narrative` 与 `model`。4.3 还要求记住**生成时刻**、**输入 token 数**、
**忠实度核对过没有**，另外还需要「这条叙述是依据哪一版台账写的」。
塞进 `model` 会把它变成 JSON 大杂烩，所以 v6 单加一列可空 TEXT：

```sql
ALTER TABLE ledgers ADD COLUMN narrative_meta TEXT;   -- NarrativeMeta 的 JSON
```

三列都**不进 `ledgers.ledger` 那份 JSON**（3.7「输出与台账分开标注」），
台账一重算就一起置回 NULL。老库 `ALTER` 就地迁移，先查再加、能被中断后重跑。

### 2.3 GPU 预算与嵌入任务**共用一本账**

4.3 的验收原文是「日均 GPU < 10 分钟（**若启用嵌入与叙述**）」——那是两个任务
**合起来**的一个预算，不是各给 10 分钟。所以叙述调度器直接用 T11 的 `GPUBudgetLedger`
与同一组 UserDefaults 键（`embedding.dailyGPUSeconds` / `embedding.gpuSecondsUsed`），
定时器比嵌入任务晚 60 s 起跑，免得同一分钟里抢 GPU。

---

## 3. 门控与裁剪

### 3.1 门控（纯函数，判定顺序与 T11 逐条对齐）

`用户没开 → 生成模型没装 → 没有待写的 → 库锁着 → 已暂停 → 用电池 →
空闲不足 5 分钟 → 热状态非 nominal → 今日 GPU 预算用完 → 跑`

顺序有意义：界面上用户看到的第一条永远是他自己能改的那一条。
自检里 **15 条用例**（含 299 s vs 300 s 的空闲边界、`fair` / `serious` 两档热状态、
599.5 s vs 600 s 的预算边界、两条"顺序"用例）。
一次 tick 最多写 4 篇，**每篇之前重新过一遍门控**。

### 3.2 输入上限 8,000 token 与五级压缩

D19 实测预填约 340 tok/s，8,000 token 的 TTFT 约 23.5 s，262K 的名义上下文在这台机器上不可用。
提示按五级逐级往下走，第一个落在闸门内的等级就是最终等级：

| 等级 | 内容 | 本轮实测那一天 |
|---|---|---|
| `full` | 概览 + 全部应用 + 站点 / 文件各前 10 + 全部会话（窗口标题 + 摘录 160 字符） | **选中**（3,025 token） |
| `trimmed` | 应用前 12、站点 / 文件各前 5、会话前 12，摘录裁到 3/4 | 自检里 120 应用 + 120 会话的合成台账落在这一级（2,837 token 估算） |
| `session_summary` | 应用前 10，去掉站点与文件，会话**按应用合并**（只留最长一段摘录） | — |
| `app_summary` | 应用前 8，只留概览 + 应用表 + **待办清单**（≤ 5 条） | — |
| `minimal` | 概览 + 应用前 5，没有会话 | 用例 `testHardTruncationWhenEvenMinimalOverflows` 把闸门压到 200 token 时命中 |

core 里没有分词器，闸门按 `NarrativeTokens.estimate` 判（汉字 1、ASCII 字母数字 0.5、
空白 1/3、其余 1，再加 48 的模板开销），口径是**只高不低**。校准与实测：

| 提示 | 真值 token | 估算 | 比值 |
|---|---:|---:|---:|
| D19 `prompt_b_narrative.txt` | 837 | 1,046 | 1.25 |
| D19 `prompt_e_long_4k.txt` | 3,664 | 4,046 | 1.10 |
| D19 `prompt_e_long.txt` | 5,354 | 5,568 | 1.04 |
| **本轮日叙述（真实分词器）** | **3,025** | **3,792** | **1.2536** |
| **本轮周叙述（真实分词器）** | **2,454** | **2,833** | **1.1544** |

五个点全部高估 ⇒ **闸门不会被低估突破**。app 侧能拿到真实分词器时优先用真值
（`NarrativeMeta.inputTokenSource = "tokenizer"`，本轮两次都是 `tokenizer`）。

---

## 4. 忠实度自检：四条确定性规则

| 规则 | 抓什么 | 依据 |
|---|---|---|
| `fabricated_number` | 叙述里出现**提示正文里没有**的阿拉伯数字（归一：去前导 0、去小数末尾 0） | 4.3 |
| `fabricated_app` | 叙述里出现台账里没有的应用（别名词表判组） | 4.3 |
| `todo_claimed_done` | 一句话里同时出现「解决 / 完成 / 修复 / 搞定…」与**待办关键词** | **D19 偏差 1** |
| `wrong_time_band` | 一句话把某应用放进它当天没有活动的时段 | **D19 偏差 2** |
| `thinking_detected` / `empty` | 输出里出现 `<think>` 段；叙述为空 | D19 硬性约束 |

**没通过就丢弃**：一个字都不入库，只往 `jobs` 写一行 `runtime_event:narrative_rejected`，
`input_ref` 只记违规规则名与计量（**不含正文**，用例里有反向断言）。

三处口径值得单说：

1. **数字白名单从「渲染好的提示正文」里抓**，不是从台账对象里抓。这样"数字必须在台账里"
   的口径就是"必须在模型**真正看见的那份文本**里"，不会出现「台账里有、但被压缩掉了、
   模型其实没看见」的假通过。只查阿拉伯数字，中文数字（「三次」）不查——
   台账一律用阿拉伯数字渲染，模型改写成中文数字属于措辞不是编造，硬查会大量假阳。
2. **待办词的命中条件是「一个 ≥ 3 字的词，或两个不同的 2 字词」。** D19 那句
   「解决了锁屏切换漏事件的问题」同时命中「锁屏」「切换」「事件」三个 2 字词，走后者；
   而「完成 34 项测试」只蹭到一个「测试」，不算违规——单个 2 字词的重合在中文里太常见，
   按它判会把正确的叙述也丢掉。用例里正反两条都钉住了。
3. **时段按会话逐段算，且先裁进台账窗口。** 跨午夜的会话（前一天 23:41 开始、今天 00:01 结束）
   也会出现在今天的会话表里；不裁的话「飞书今天活跃的小时」会从 23 点铺满一整天，
   这条规则就形同虚设（本轮第一版实测提示里真的渲染出过「时段 23:41–18:52」）。
   另外**有会话时不用「首末时刻之间」那个粗口径**——09:00 与 18:00 各一段的话，
   粗口径会把 10–17 点也算成活跃。

**已知边界**（写在这里免得被当成没做）：
应用名靠别名词表（60 组）+ 台账自己的展示名识别，词表外**且**台账里也没有的生造名字抓不到；
中文别名只收「基本不会当普通名词用」的那些——「预览」「照片」「音乐」「地图」**故意不收**，
收了之后一句「预览了文档」会被判成"台账里没有 Preview 这个应用"，把正确的叙述丢掉；
ASCII 别名一律按**词边界**匹配（不然 `search` 里能找出 `Arc`、`keyword` 里能找出 `Word`）；
一句话里提到多个时段时，只要应用与**其中一个**时段有交集就算过（宁松勿误杀）。

长度按**汉字数**在代码里截断（默认 150，优先切在句末符号上），不只写在提示词里——
D19 结论 5 说得很清楚，只靠提示词管不住。

---

## 5. 实测数字（本机 M4 Air / 16 GiB / 无风扇）

### 5.1 语料与库（T3 的 1 个月合成库）

| 指标 | 值 | 出处 |
|---|---|---|
| 合成流 | 30 天 × 2,880 条/天 = **86,400 条观察**，28,542 个文本版本，平均正文 537.4 字符，汉字占 31.4% | `results/gen_synth.json` |
| 建库导入 | **17.68 s**，4,887.5 条/s | `results/import.json` |
| 会话构建 | 86,400 条 → **3,352 段**，195.7 ms | `results/sessions.json` |
| 库里的自然日 | 31 天（2026-08-08 … 2026-09-07） | `results/days.json` |
| 生成模型本地导入（T11 的导入器，重新校验 12 个文件的 sha256） | **2,919.32 MiB**，12 个文件，**1.285 s**，进程 peak footprint **9.95 MiB** | `results/model_import.json` / `.time` |

> 导入 2.9 GiB 的模型峰值只有 9.95 MiB——3.11 那条「逐块读文件的循环必须包 `autoreleasepool`」
> 在产品路径上确实生效了（E9 验收前是 2,935.8 MiB）。

### 5.2 日叙述（`--date 2026-08-23 --tz UTC --repeat 2`）

| 指标 | 值 |
|---|---|
| 台账规模 | 2,880 条观察、132 段会话、6 个应用 |
| 提示 | 5,201 字符，压缩等级 **full**，**3,025 token（真实分词器）** / 3,792（估算器，比值 1.2536） |
| 模型热加载 | **0.739 s** |
| **TTFT** | **8.844 / 8.842 s** |
| **生成吞吐** | **36.39 / 36.52 tok/s** |
| 输出 | 48 token / **42 个汉字**，`stopReason = stop`，`thinkingDetected = false` |
| 单次端到端（`NarrativeMeta.elapsedSeconds`） | **10.174 / 10.168 s** |
| **忠实度** | **两次都通过，零违规**；核对了 5 个应用、0 个数字 |
| **确定性** | 两次输出**逐字相同**（`answersIdentical = true`） |
| **峰值 footprint** | **3,768.1 MiB = 3.680 GiB**（含打开着的加密库，`cache_size` 128 MiB） |
| GPU 峰值 / 缓冲池 | 3,380.8 MiB / 256.6 MiB（`cacheLimit` 256 MiB 生效） |
| `clearCache()` 之后 | footprint 2,713.1 → **2,418.0 MiB**，GPU 缓冲池 256.6 → **0 MiB** |
| swap | 全程 **0**（`/usr/bin/time -l` 的 `swaps`；系统 swap 用量前后完全没变） |
| 热状态 | `nominal → nominal` |
| 整个进程（含建库连接、两次生成、模型卸载） | `21.51 real` |

### 5.3 周叙述（`--week 2026-08-23 --tz UTC --repeat 2` ⇒ 规范化成 `2026-W34`）

| 指标 | 值 |
|---|---|
| 台账规模 | 7 天、20,160 条观察、772 段会话、6 个应用 |
| 提示 | 3,783 字符，压缩等级 **full**，**2,454 token（分词器）** / 2,833（估算，比值 1.1544） |
| 热加载 / TTFT / 吞吐 / 单次端到端 | 0.718 s / **7.234 · 7.264 s** / **37.07 · 37.19 tok/s** / 8.567 · 8.593 s |
| 输出 | 49 token / 55 个汉字，两次逐字相同，忠实度**通过** |
| 峰值 footprint | **3,666.6 MiB = 3.581 GiB**，GPU 峰值 3,248.7 MiB，swap 0 |
| 整个进程 | `18.32 real` |

### 5.4 一天的叙述原文与逐条核对表

**输入台账的头部**（`results/prompt_day.txt` 原文粘贴，时区 UTC）：

```text
【日台账】2026-08-23（时区 GMT）
总计：前台停留 21 小时 28 分，有输入的活跃 20 小时 27 分，未知 2 小时 38 分，总在线 21 小时 24 分；
应用切换 132 次，会话 132 段，打断 0 次，观察 2880 条。

【应用】
- 飞书：停留 6 小时 24 分、活跃 6 小时 8 分、切换 33 次，时段 00:00–18:52
- Code：停留 5 小时 25 分、活跃 5 小时 9 分、切换 27 次，时段 02:01–23:29
- Safari：停留 3 小时 3 分、活跃 2 小时 54 分、切换 23 次，时段 01:01–21:09
- 微信：停留 2 小时 15 分、活跃 2 小时 8 分、切换 17 次，时段 20:06–20:48
- Obsidian：停留 2 小时 13 分、活跃 2 小时 6 分、切换 16 次，时段 09:04–21:53
- 终端：停留 2 小时 7 分、活跃 2 小时 1 分、切换 16 次，时段 16:18–16:45
```

**模型写出来的叙述**（`ledgers.narrative` 原文，两次逐字相同）：

> 凌晨至上午，飞书、Code、Safari 等应用持续活跃。下午时段，终端、飞书、Code 用于代码审查与测试。晚上，微信、Safari、Obsidian 处理会议与文档。

**逐条核对**（叙述输入里那 24 段会话按 UTC 小时展开的活跃小时集合）：

| 叙述里的说法 | 台账依据（活跃小时） | 判定 |
|---|---|---|
| 凌晨至上午 · **飞书** | `{0,1,2,7,8,10,11,15,18}` ⇒ 凌晨 ✔ 上午 ✔ | ✅ |
| 凌晨至上午 · **Code** | `{2,4,5,7,8,13,14,15,19,21,22,23}` ⇒ 凌晨 ✔ 上午 ✔ | ✅ |
| 凌晨至上午 · **Safari** | `{1,4,20,21}` ⇒ 凌晨 ✔（上午无） | ✅（规则：与所提时段之一有交集即可） |
| 下午 · **终端** | `{16}` ⇒ 下午 ✔ | ✅ |
| 下午 · **飞书** | `{15}` ⇒ 下午 ✔ | ✅ |
| 下午 · **Code** | `{13,14,15}` ⇒ 下午 ✔ | ✅ |
| 晚上 · **微信** | `{20}` ⇒ 晚上 ✔ | ✅ |
| 晚上 · **Safari** | `{20,21}` ⇒ 晚上 ✔ | ✅ |
| 晚上 · **Obsidian** | `{21}` ⇒ 晚上 ✔ | ✅ |
| 出现的应用名 | 飞书 / Safari / 微信 / Obsidian / 终端 5 组在词表内且都在台账里；「Code」词表外，但它是台账的展示名（bundle id `com.microsoft.VSCode` ⇒ VS Code 组） | ✅ 无编造 |
| 出现的数字 | **0 个** | ✅ 无编造 |
| 「代码审查与测试」「处理会议与文档」这类**措辞** | 来自会话摘录里的窗口标题与屏幕文本 | ⚠️ 属于概括，核对器不判（见第 8 节） |

**入库之后读回**（`brosis-store ledger --tz UTC --date 2026-08-23`）：

```json
"model": "Qwen3.5-4B-MLX-4bit",
"narrativeMeta": {
  "generatedBy": "model", "faithfulnessChecked": true, "compression": "full",
  "inputTokens": 3072, "inputTokenSource": "tokenizer", "outputTokens": 48,
  "checkedApps": 5, "checkedNumbers": 0, "truncated": false,
  "generatedAt": …, "ledgerComputedAt": …（与 ledgers.computed_at 相等）,
  "timeToFirstTokenSeconds": 8.842, "tokensPerSecond": 36.52, "elapsedSeconds": 10.17,
  "thermalState": "nominal", "peakFootprintMiB": 3768.1
}
```

**台账变 stale 就重算**：对同一天执行 `ledger --recompute` 之后，
`narrative` / `model` / `narrativeMeta` **三个都变回 `null`**（`results/stale_demo.txt`），
`narrativeBacklog()` 重新把这一天列进待办。

### 5.5 自检与构建

| 指标 | 值 |
|---|---|
| `swift test`（core） | **209 个用例全过、零 warning**（其中本任务 24 个） |
| `build_app.sh` | 零 warning，`Developer ID` 签名 + hardened runtime + 内嵌描述文件全过 |
| `brosis --self-check` | **137 项全 PASS、0 FAIL**，`2.30 real`，peak footprint **230.08 MiB**（**不加载任何模型**） |
| app 体积 | **99.79 MiB** = 主程序 47.14 + `brosis-embed` 45.52 + metallib 2.99 + 其余（M2 c / T11 之后是 89.14 MiB，本任务 +10.65） |

### 5.6 变异检验（三次，都被用例抓住）

复制 `core/` 到 `~/Library/Caches/brosis-build/m2-narrative-mutate/core` 再改，原树不动：

| # | 改什么 | 结果 |
|---|---|---|
| 1 | `NarrativeFaithfulness.check` 里把时段那条规则短路（`guard !bands.isEmpty, false`） | **4 个用例失败**，含 `testWrongTimeBandIsRejected` |
| 2 | `NarrativePromptBuilder.build` 里去掉「超限就降一级」（永远用 `full`） | **2 个用例失败**，含 `testHardTruncationWhenEvenMinimalOverflows` |
| 3 | `upsertLedger` 的 UPDATE 里不再把 `narrative` / `model` / `narrative_meta` 置 NULL | **3 个用例失败**，含 `testLedgerRecomputeInvalidatesNarrative` |

---

## 6. 测试清单（`NarrativeTests`，24 个）

| 组 | 用例 |
|---|---|
| token 与提示 | 估算器确定性 / 单调 / 权重；提示两次构造逐字相同、三条禁令都在、待办被显式标出；大台账（120 应用 + 120 会话）逐级压缩后仍在 8,000 内且比 `full` 低、五级渲染长度严格递减；闸门压到 200 token 时兜底硬截断 |
| 忠实度正例 | 忠实的叙述通过；单个 2 字词重合**不算**违规 |
| 忠实度反例 | 编造数字、编造应用、**把待办说成已完成（D19 偏差 1 原句）**、**把上午说成下午（D19 偏差 2）**、输出里出现思考段、叙述为空 |
| 时段口径 | 词表外的台账应用（展示名「Code」）照样被时段核对；**跨午夜的会话被裁进台账窗口**（否则活跃小时铺满全天） |
| 长度 | 按汉字数截断、优先切句号、没有句号时补省略号、没超限时原样返回 |
| 词表 | ASCII 别名要词边界（`search` 里找不出 `Arc`、`keywords` 里找不出 `Excel`）、bundle id 归组、词表外返回 nil |
| 端到端 | 过核对 ⇒ 写三列 + 事件不含正文 + 不再进待办；没过 ⇒ 不入库、只记事件、事件不含被丢弃的正文；**失败重试一次**（`retries = 0` 时不重试）；空的一天连模型都不叫；台账重算 ⇒ 叙述作废并重新进待办；`ledgerComputedAt` 对不上 ⇒ `stale` |
| 周 | 周输入按 7 天聚合、提示里有【每天】、**用周内某一天当参数时目标被规范化成 ISO 周**（不规范化会 UPDATE 到零行、悄悄存不进去） |
| schema v6 | 新库有 `narrative_meta` 列与 v6 审计行；**把库降级成 v5 再重开**必须就地补列、老数据一字不差、一致性检查全过 |

---

## 7. 怎么跑（可复制粘贴）

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
P="<项目目录>"
W="$HOME/Library/Caches/brosis-build/m2-narrative"     # 自己的 scratch
mkdir -p "$W/results" "$W/synth" "$W/data" "$W/models"

# 1) core 测试（零 warning、全绿）
swift test --package-path "$P/core" --scratch-path "$HOME/Library/Caches/brosis-build/m2-narrative-core"

# 2) app 构建 + 自检（自检不加载任何模型，约 2.3 s）
SCRATCH="$HOME/Library/Caches/brosis-build/m2-narrative-app" bash "$P/app/build_app.sh"
APP="$HOME/Library/Caches/brosis-build/m2-narrative-app/brosis.app/Contents/MacOS"
"$APP/brosis" --self-check | grep -c PASS      # 137，且 FAIL 为 0

# 3) 1 个月合成库（T3 的生成器）
STORE="$(swift build --package-path "$P/core" \
          --scratch-path "$HOME/Library/Caches/brosis-build/m2-narrative-core" --show-bin-path)/brosis-store"
PYTHONDONTWRITEBYTECODE=1 python3 "$P/tools/proto/gen_synth_m1.py" gen \
  --out "$W/synth/synth.jsonl" --queries "$W/synth/queries.json" \
  --days 30 --per-day 2880 --avg-chars 500 --seed 20260908 > "$W/results/gen_synth.json"
"$STORE" init --dir "$W/data" --key-file "$W/data.key" > "$W/results/init.json"
"$STORE" import-jsonl --dir "$W/data" --key-file "$W/data.key" \
  --file "$W/synth/synth.jsonl" --batch 500 > "$W/results/import.json"
"$STORE" maintenance --dir "$W/data" --key-file "$W/data.key" > "$W/results/maintenance.json"
"$STORE" sessions --dir "$W/data" --key-file "$W/data.key" --build --force > "$W/results/sessions.json"

# 4) 导入生成模型（用 T11 的导入器，会重新校验 12 个文件的 sha256）
"$APP/brosis-embed" models --models-dir "$W/models" --import \
  --id Qwen3.5-4B-MLX-4bit \
  --from "$HOME/Library/Application Support/brosis-m0/models/Qwen3.5-4B-MLX-4bit"

# 5) 真实生成（日 + 周）。--commit 才入库；不加就只生成与核对。
"$APP/brosis" --narrative-smoke --dir "$W/data" --key-file "$W/data.key" \
  --models-dir "$W/models" --date 2026-08-23 --tz UTC --repeat 2 --commit \
  --prompt-out "$W/results/prompt_day.txt" --out "$W/results/narrative_smoke_day.json"
"$APP/brosis" --narrative-smoke --dir "$W/data" --key-file "$W/data.key" \
  --models-dir "$W/models" --week 2026-08-23 --tz UTC --repeat 2 --commit \
  --out "$W/results/narrative_smoke_week.json"

# 6) 读回：叙述与标注在 ledgers 的三列上（**时区要和生成时一致**，见第 8 节）
"$STORE" ledger      --dir "$W/data" --key-file "$W/data.key" --tz UTC --date 2026-08-23
"$STORE" week-ledger --dir "$W/data" --key-file "$W/data.key" --tz UTC --week 2026-W34

# 7) 台账重算 ⇒ 叙述作废
"$STORE" ledger --dir "$W/data" --key-file "$W/data.key" --tz UTC --date 2026-08-23 --recompute
```

**变异检验**（复制到 scratch 再改，原树不动）：

```sh
M="$HOME/Library/Caches/brosis-build/m2-narrative-mutate"
rm -rf "$M"; mkdir -p "$M"; cp -R "$P/core" "$M/core"; rm -rf "$M/core/.build"
# ① 关掉时段规则：Narrative.swift 里 `guard !bands.isEmpty else { continue }`
#    改成 `guard !bands.isEmpty, false else { continue }`
# ② 关掉逐级压缩：Narrative.swift 里 `if candidateTokens <= config.maxInputTokens { break }`
#    改成 `break`
# ③ 台账重算时不清叙述：Store+Ledger.swift 的 UPDATE 里把
#    `narrative = NULL, model = NULL, narrative_meta = NULL`
#    改成 `narrative = narrative, model = model, narrative_meta = narrative_meta`
swift test --package-path "$M/core" --scratch-path "$M/build" --filter NarrativeTests
# 期望：① 4 个失败 ② 2 个失败 ③ 3 个失败
```

**接入 app（主会话来接，两行，`AppDelegate.swift` 里起 `EmbeddingScheduler` 的地方旁边）**：

```swift
NarrativeScheduler.shared.configure(recorder: recorder, lockSnapshot: { lockController.snapshot })
NarrativeScheduler.shared.start()      // 开关关着时定时器不做事
```

界面上要显示状态就调 `NarrativeScheduler.shared.statusLine()`。

原始数据全部在 `~/Library/Caches/brosis-build/m2-narrative/results/`
（`core_tests.txt`、`build_app.log`、`self_check.txt` + `.time`、`gen_synth.json`、`import.json` + `.time`、
`sessions.json`、`model_import.json` + `.time`、`prompt_day.txt`、`prompt_week.txt`、
`narrative_smoke_day.json` + `.time`、`narrative_smoke_week.json` + `.time`、
`ledger_with_narrative.json`、`week_ledger.json`、`stale_demo.txt`、
`mutation_time_band.txt`、`mutation_compression.txt`、`mutation_stale.txt`、
`swap_before.txt` / `swap_after.txt`）。

---

## 8. 未做的项与原因（含一条踩到的坑）

| 项 | 原因 |
|---|---|
| **MCP 层的字段透传** | 按分工：叙述的返回形状写在 core 的 `DayLedger`（`narrative` / `model` / `narrativeMeta` / `narrativeIsStale`），`StoreMCPService.swift` **一行没改**（T14 在动它）。主会话在 T14 之后把 `get_day_ledger` 的返回加上 `generatedBy = "model"` 与 `faithfulnessChecked`（两个值直接取 `narrativeMeta`）。T14 已经在 `brosis-store` 的 `ledger` / `week-ledger` 两个子命令里做了同样的透传，可以照抄 |
| **线上生成适配器（D20）** | 用户本轮明确指示不接线上模型。协议留着，规则（温度 0 / 关思考 / 失败重试一次）是本地与线上共用的 |
| **叙述面板 / 菜单项** | 3.12 的「模型」面板是 T11 的文件（`ModelsWindow.swift`），并行任务不改它。开关、状态、"立刻写一篇"三个入口的数据都已就绪（`NarrativeScheduler.isEnabled` / `.statusLine()` / `.runOnce(modelsRoot:)`），主会话接一下即可 |
| **另一台机器的加载时间与内存峰值**（4.3「在两台机器上各测一次」） | 家里机不在手边，且 D26 记着它还没装 Metal Toolchain。Air 这一侧的数字见第 5 节 |
| **热降频下的持续叙述** | 一次叙述 10 s，四篇也才 40 s，够不到 D27 那条「持续 2 分 10 秒转 fair」的线；本轮两次跑全程 `nominal → nominal`。真要连着补一周的课时门控每篇都会重新看一次热状态 |
| **中文数字的核对** | 见第 4 节：台账一律用阿拉伯数字渲染，硬查中文数字会大量假阳 |
| **叙述的"措辞"层核对** | 核对器只判**事实**（应用、数字、待办、时段），不判「代码审查与测试」这种概括是否贴切——那需要另一个模型去判，属于 M2b 的评估范围 |

**踩到的坑（会影响验收，写清楚）**：
`ledgers` 的一行是按**时区**算出来的，`period` 相同但时区不同就是两份不同的台账。
用 `--tz UTC` 生成叙述、再用默认（本机）时区去读同一个 `--date`，
台账指纹对不上 ⇒ 当场重算 ⇒ **叙述被清掉**。所以第 7 节的读回命令里 `--tz` 必须与生成时一致。
这不是本任务引入的行为（M1 就是这样），但叙述让它第一次变得可见。

---

## 9. 对计划的影响（各一句话）

- **4.3**：「可选叙述」这一条可以从待办改成**已实现并实测**——日 / 周叙述在 Air 上各 10 s / 9 s、
  峰值 3.68 GiB、温度 0 逐字确定、忠实度核对通过，四项门控（接电 / 空闲 / 热状态 / 锁定）
  与日均 GPU 预算与嵌入任务共用一本账；「日均 GPU < 10 分钟」对叙述这一侧毫无压力
  （一天一篇 10 s，补一周的课也才 70 s）。
- **3.7**：「输出与台账分开标注」现在有了具体形状——`ledgers` 的三个独立列
  （`narrative` / `model` / `narrative_meta`），台账重算时一起置 NULL；建议把
  「叙述必须带 `generatedBy = model` 与 `faithfulnessChecked` 两个标注」写进正文。
- **3.10**：`generate` 侧的本地实现落地，温度 0 / 关思考 / **失败重试一次**三条都在产品路径上；
  「JSON 校验」那一条仍然只在抽取任务上有意义（叙述是自由文本），M2 抽取时再补。
- **D19**：两处偏差各配了一条**确定性规则**并有用例钉住；另外补一条给计划的实测——
  **叙述提示的 token 估算器在真实分词器上高估 15–25%**，8,000 的闸门按估算判是安全的。
- **D27**：生成任务上策略照旧成立——`cacheLimit = 256 MiB` 时 GPU 缓冲池峰值 256.6 MiB、
  `clearCache()` 之后回到 0，进程 footprint 从 2,713 MiB 落到 2,418 MiB，全程零 swap。
- **3.11**：app 体积从 89.14 MiB 涨到 **99.79 MiB**（`MLXLLM` 进来了），刚好卡在「约 100 MB」那条线上；
  其中 `brosis-embed` 的 45.52 MiB 是可选的评估工具，去掉它 app 回到 54.27 MiB，
  建议把「发版是否带 `brosis-embed`」作为一个显式选项写进 3.11。
