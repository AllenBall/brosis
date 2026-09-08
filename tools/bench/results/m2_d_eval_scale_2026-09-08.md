# M2 d / T17：评估扩展（100 题 + 六类归因）与 1 / 3 / 12 个月规模压测（2026-09-08）

- 对应：`docs/实施计划.md` **4.3**「查询集扩到 100 题，留出 30 题作独立测试；持续记录答不出的问题并按 4.4 的六类归因」「规模压测：1 / 3 / 12 个月合成库，按 2.4 报告延迟」、**2.4**（检索 / 存储 / 延迟口径）、**3.4**（延迟分层目标，含 4.3.1 采纳的补充）、**4.4**（六类归因）、**4.3.2 T17**
- 依赖：M1 的 `core/`（T2 存储、T3 检索与日台账、T6 评估脚本）、M2 c 批的 T14（周台账 / `get_patterns` / `recent_activity`）
- 并行：同一批的 T15（向量进 MCP）/ T16（加密导出）/ T18（Focus + 热键）在同一棵源码树上落地。**本任务一行 Swift 都没改**——只动 `tools/eval/` 与 `tools/proto/gen_synth_m1.py`，所以分配给我的 schema 版本号一个都没占，`AppDelegate.swift` 也没碰
- 本机：Apple M4 Air / 16 GiB / 无风扇 / macOS 26.6 / Darwin 25.6.0 / Xcode 26.6 / Swift 6.3.3（语言模式 v6）/ Python 3.14（只用标准库）
- 单位：**KiB / MiB / GiB = 2¹⁰ / 2²⁰ / 2³⁰**；内存取 `/usr/bin/time -l` 的 **peak memory footprint**
- 原始输出：`~/Library/Caches/brosis-build/m2-eval-scale/results/`，本文每个数字都出自那里
- 本轮**没有启动 GUI、没有触发 TCC / 钥匙串弹窗、没有 sudo、没有改 `docs/`、没有 git commit**；项目目录里 `find` 不到任何构建产物

---

## 1. 做了什么

| 文件 | 内容 |
|---|---|
| `tools/eval/make_synthetic_queryset.py`（改） | 查询集 60 → **100 题**：新增 18 道检索题 + **22 道工具题**；六类配额；`difficulty` 由规则算出；留出题 30 道；新增 `url` 真值规则；新增 `verify-tools` 子命令（真的调 `brosis-store` 核对工具题的断言）；`mutate` 加第五道变异题（别名）；`verify-mutations` 支持核对六类归因 |
| `tools/eval/triage_failures.py`（新增） | **4.4 的六类失败归因**：规则给候选、JSONL 留人工标注列、按类计数 + 逐题表 + 「该修什么」 |
| `tools/eval/scale_test.py`（新增） | **1 / 3 / 12 个月规模压测**：按月生成 → 导入 → 删 JSONL；空闲门控；体积分项；冷 / 热 p50 / p95 |
| `tools/eval/scale_report.py`（新增） | 把压测 JSON 排成表 + **3.4 分层目标逐桶判定** |
| `tools/eval/run_t17_eval.sh`（新增） | 评估半边一键复现，末尾 **21 项自检**（含"原 60 题一个字没改"） |
| `tools/eval/eval_stage1.py`（改） | 六类；**留出题三档**（默认排除 / `--include-holdout` / `--holdout-only`）；报告加按难度、按工具两张表 |
| `tools/eval/eval_stage2.py`（改） | 六类；只判第一阶段真的跑过的题（两个阶段的题目集合不会错位） |
| `tools/eval/monthly_report.py`（改） | 加 `--stage1` / `--triage`：**留出题的检索回归只在月报里跑** |
| `tools/eval/run_all.sh`（改） | 跟着改成 100 题（`--include-holdout`）；工具题的"好答案"改引 `evidence_match` 那一档的 id |
| `tools/proto/gen_synth_m1.py`（改，追加一个可选参数） | `--anchor YYYY-MM-DD`：让规模压测能按月生成 12 段互不重叠的时间区间；不给它时行为与之前**逐字节相同** |
| `tools/eval/queryset.schema.md`（改） | 六类；新增 `difficulty` / `tool` / `truth_mode` / `tool_call` / `tool_check` 五个字段与 §2b「`tool_check` 的形状」；写明**向后兼容**（`schema` 仍是 `brosis/queryset@1`，全是追加字段） |
| `tools/eval/README.md`（改） | 新增 §2.1b（100 题）、§2.5（六类归因）、§2.6（规模压测），§2.2 / §2.4 / §3 跟着改 |

**没改任何 Swift 代码**，也没改 `docs/`。`brosis-store` 只是被当成被测对象调用。

被测的 `brosis-store` 是从本轮工作树编出来的 release（M2 c 批 8b732dc + 同批
T15 / T16 / T18 当时已落地的部分）。收尾时**从零重建了一次**核对：
`swift build --package-path core -c release --scratch-path …`，退出码 0、
**warning 0 条**、45.42 s（`results/build_release.log`）。
同一批的三个任务还在往 `core/` 里加东西，验收者从最终合并树重建出来的二进制会比它新一点；
本文的数字对应的是本轮这一份，重建之后把两个脚本重跑一遍即可。

## 2. 怎么跑

```sh
REPO="<项目目录>"
S=$HOME/Library/Caches/brosis-build/m2-eval-scale        # 自己的 scratch，换个名字就是验收者的

# 0) 只要 core 的 brosis-store（不用 app、不加载任何模型），零 warning
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path "$REPO/core" -c release --scratch-path "$S-core"

# 1) 评估半边：建库 → 100 题 → 删除对账 → 工具题核对 → 三档留出口径 → 变异检验
#    → 第二阶段 → 六类归因 → 月报。末尾自己核对 19 项，任何一项不过就 exit 1
SCRATCH=$S sh "$REPO/tools/eval/run_t17_eval.sh"

# 2) 规模压测：1 / 3 / 12 个月。机器空闲时跑，中途别编译
PYTHONDONTWRITEBYTECODE=1 python3 "$REPO/tools/eval/scale_test.py" \
  --bin "$S-core/release/brosis-store" --work $S/scale --results $S/results --months 1,3,12

# 3) 排表 + 3.4 分层目标逐桶判定
PYTHONDONTWRITEBYTECODE=1 python3 "$REPO/tools/eval/scale_report.py" \
  --scale $S/results/scale_all.json --out-md $S/results/scale_report.md
```

第 1 步约 5 分钟（含构建），第 2 步在空闲机器上约 45–60 分钟（12 个月档的建库就要 12 分钟）。
第 2 步跑完每一档都会**删库**释放磁盘；要重测延迟就加 `--keep-db`，第二次跑加 `--reuse` 只重测不重建。

## 3. 查询集：60 → 100 题

### 3.1 原 60 题一个字都没改，这件事是**可执行的**

`id` / `q` / `search` / `relevant` / `answer` / `answer_check` / `holdout` 全部原样，
每道题只是多了 `difficulty` / `tool` / `truth_mode` 三个新字段。
`run_t17_eval.sh` 第 2b 步拿 M2 c 批那个提交的脚本
（`git show 8b732dc:tools/eval/make_synthetic_queryset.py`）在**同一份 JSONL** 上重建一份 60 题，
逐题逐字段比对：

| 核对项 | 结果 |
|---|---|
| M1 的 60 个 id 全在 | 是 |
| 60 题的字段差异 | **0 处** |
| 60 题的 `holdout` 标记变化 | **0 道** |
| 同一份 JSONL 两次生成（去掉 `generated_at`） | 逐字节相同 |

原始输出：`results/queryset_diff.json`。

### 3.2 六类配额与难度分布

| 类 | 题数 | 新增 | 新增的是什么 |
|---|---:|---:|---|
| 活动定位 | 25 | +5 | 站点 + 周窗口、`/spec/` 前缀 URL（新增的 `url` 真值规则）、基础站点 + 3 h 窗口、`report-q3.md` 路径、窗口标题 + 整天 |
| 原文细节 | 26 | +6 | 单字「榄」（扫描通道）、模板词「复核」、两个 `.swift` 路径、`kanban.internal.example`、**全大写 `SQLCIPHER`**（考 ASCII 大小写折叠） |
| 跨来源 | 13 | +3 | 「橄榄」「brosis-m1/notes」「珀」，生成时断言证据跨 ≥ 2 个 bundle_id |
| 无答案或已删除 | 14 | +4 | 4 道新负例（「麒麟」「鳄」「星际航行日志」`nowhere.invalid.example`），生成时断言全库 0 命中 |
| **活动模式**（新类） | 14 | +14 | `get_day_ledger` 2 / 周台账 3 / `get_patterns` 5 / `get_timeline` 2 / `get_item` 2 |
| **最近活动**（新类） | 8 | +8 | `recent_activity` 7 / `get_context` 1 |
| **合计** | **100** | **+40** | |

难度**由规则算出来**（`difficulty_of()`），不是手工标的：工具题 / 不可答题 / 单个汉字 /
全大写变形 = 难；跨来源、带时间窗或应用过滤 = 中；其余 = 易。本语料上是 **易 24 / 中 35 / 难 41**。

按 `tool` 分：`search` 78、`recent_activity` 7、`get_patterns` 5、周台账 3、
`get_day_ledger` 2、`get_item` 2、`get_timeline` 2、`get_context` 1。

### 3.3 留出 30 题（计划 4.3）

两段选，都没有随机数：M1 的 60 题按老规则（每类 id 排序后第 3、6、9… 题）→ **18 道，一道没换**；
新增的 40 题按 id 排序后每 10 题取第 3 / 6 / 9 道 → **12 道**。合计 30 道，按类是
活动定位 7 / 原文细节 8 / 跨来源 4 / 无答案 4 / 活动模式 4 / 最近活动 3。

**留出题只在月报里跑**。`eval_stage1.py` 默认口径是 `exclude`（只跑 70 题），
`--include-holdout` 全跑，`--holdout-only` 只跑 30 道；`eval_stage2.py` 跟着第一阶段走，
两个阶段的题目集合不会错位。`monthly_report.py` 新增 `--stage1` / `--triage` 两个参数，
把留出题的 Recall / Precision / MRR、2.4 达标判定与 4.4 的六类计数写进同一张报表。

### 3.4 工具题：`relevant` 为什么是空的，判据换成了什么

22 道工具题问的是**聚合量**（"哪个应用最多"、"这一周多少条"、"最近半小时在干嘛"），
不是"某几条观察"。给它们编一份全量 `relevant` 既臃肿（一周窗口动辄一万多条观察 id）
又没意义——前 10 条里随便哪 10 条都算"相关"，Recall@10 恒等于 1。所以：

* `relevant` 留空、`truth_mode = "evidence_match"`：第一阶段判"返回的证据满不满足期望证据"
  （与真实题同一条口径，`queryset.schema.md` §7），**Recall 记 null，不进均值**，报告里按 `tool` 单列；
* 真正的判据是 `tool_check` —— 一组从 JSONL **精确算出来**的断言，
  `verify-tools` 子命令**真的调 `brosis-store` 跑一遍**逐条核对。

三条口径上的讲究：

1. **只断言条数与结构，不断言时长**。合成流里 `source_state` 约 10% 是
   `permission_lost` / `timeout`，按 3.7 不计入 dwell，所以秒数不是"能从 JSONL 精确算出来"的量；
   而观察是 10 s 一格的均匀网格，条数是。
2. **期望值按删除之后的库算**。`deletions` 是查询集的一部分，在建库之后、评估之前执行，
   台账 / 模式 / 最近活动看到的是删完的样子——和每道题的 `relevant` 已经扣掉被删观察是同一条口径。
   第一版这里写错了（拿 `8640` 当每天的条数），`verify-tools` 当场报出 8 道题不符，
   改成"扫描时跳过将被删除的观察"之后全过。**这就是这个子命令存在的意义**。
3. **切换对也按删除之后算**：被删的观察不参与"相邻"，删掉一整段之后前后两条的间隔超过
   90 s 的停留上限，那就不算一次切换——与 `get_patterns` 的定义一致。

`tool_check` 的形状：`{"path": "byHour.*.observations", "op": "sum_eq", "value": 60476}`。
`path` 点号分段、数字段是数组下标、`*` 是"每个元素"；`op ∈ eq / all_eq / sum_eq / all_le / len / le / ge`；
`value` 写成 `"@另一条路径"` 就是两条路径互比（周台账的"周 = 7 天之和"就是这么断言的）。

**合成语料没有作息**（24 h 均匀网格），所以"我一般几点最活跃"这类题在这套语料上的正确答案
就是"没有高峰"（`pat-07`）、"没有哪一天特别多"（`pat-04`）、"一个 25 分钟工作块都没有"（`pat-10`）。
这三道是故意留的**诚实答案**，用来验证工具不会为了给答案而编一个高峰 / 一个工作块出来。
真要量作息类模式，用 `tools/proto/gen_workweek.py` 的库（T14 已在那上面与生成器逐项对照过）。

## 4. 失败六类归因（4.4）

### 4.1 规则

`tools/eval/triage_failures.py`。按优先级从上往下，第一个命中的算：

| 类 | 判据 | 该修什么（4.4 的分工） |
|---|---|---|
| `未采集` | 真值为空、期望证据也一条没匹配上 | 修采集 |
| `已过期或已删除` | 漏掉的证据 id 拿去 `get_evidence` 全部回 `missing` | 修保留策略 / 配额 |
| `别名不统一` | 证据**还活着**却没召回，**并且**检索串与期望答案没有任何公共字面（中文字符 bigram ∪ ASCII 词元）；或原题过了、它的改写题挂了 | 先试轻量方案（标签 / 别名表 / 字段过滤 / 多步检索 / 向量通道） |
| `索引漏召回` | 证据还活着、没召回，但检索串与答案**有**公共字面 | 修检索（索引 / 候选上限 / 排序） |
| `上下文裁剪` | 证据召回了，但 ≤ 100 token 的摘要与片段里都没有答案子串 | 修上下文预算 / 让 Agent 展开 `get_evidence` |
| `推理错误` | **兜底**：证据拿到了、也没被裁，第二阶段仍然答错 | 修提示 / 换模型 |

外加单列的 `负例误报`（不可答题却返回了证据）。它不属六类（六类说的是"答不出"），
但草稿规定"编造一次即失败"，必须看得见。

**为什么把 `别名不统一` 排在 `索引漏召回` 前面**：两者都是"活着但没召回"，区别只在为什么。
本项目的 FTS 通道是「bigram phrase 命中 → 在原文上做子串复核」（D22 + 3.4），
语义上等于**精确子串**——换个说法之后字面通道必然一条都召不回。
所以"检索串与期望答案没有公共字面"就是"换了说法"的可判定形式，
这也正是 D8 改写题实验成立的前提（`tools/eval/README.md` §4）。

**判不出 `推理错误` 的情况会写在报告开头**：没给 `--stage2` 时这一类恒为 0，报告里明写
「未提供——`推理错误` 这一类判不出来」，不会假装它是 0。

### 4.2 人工标注

规则只给候选。`--write-annotations <file.jsonl>` 写一份一题一行的 JSONL：

```json
{"id":"det-01","class":"原文细节","q":"…","auto_bucket":"推理错误","auto_why":"…",
 "manual_bucket":null,"annotator":"","annotated_at":"","note":""}
```

人工把 `manual_bucket` 填成六类之一（或 `负例误报` / `通过`）、`note` 写理由；
下次跑加 `--annotations <同一个文件>` 读回来，`final_bucket` 优先用人工的，
并统计规则与人工**分歧**了几题（`disagreements`）——分歧率就是这套规则的可信度。
已填的行永远不会被覆盖。

### 4.3 分类器自己怎么验：五道变异题 + 一道故意答错的

全过的评估报告里"失败归因"那张表是空的，空表证明不了分类器是对的。所以：

`make_synthetic_queryset.py mutate` 造 5 道注定失败的题，
`verify-mutations --triage <triage.json>` 同时核对**第一阶段的桶**与**六类归因**；
`推理错误` 那一桶靠 `run_t17_eval.sh` 第 7 步——给一道本来两阶段全过的题
（`det-01`）喂一个驴唇不对马嘴的答案，第二阶段判挂，归因必须落到 `推理错误`。

## 5. 实测：100 题在 1 个月库上跑出来的数

语料：`gen_synth_m1.py --days 30 --per-day 8640 --avg-chars 1500 --seed 20260908`，
259,200 条观察、JSONL 626.4 MiB（sha256 `3b0d298e…`）、带正文 221,716 条。
建库 `import-jsonl` **68.74 s**（3,771 条/s）、峰值 footprint **816.6 MiB**
（这一遍是和另一个任务的编译抢机器时跑的；空闲时的同一份语料是 **50.45 s / 5,137 条/s**，
见 §6 的 1 个月档）。
执行查询集的 4 项删除后墓碑 **383** 条、活 258,817 条，`--check-corpus` 对上。

### 5.1 第一阶段（`eval_stage1.py`）

| 留出题口径 | 题数 | 可答题 | 其中算得出 Recall 的 | 不可答题 | Recall@10 | Precision@10 | MRR@10 | 负例误报 | 通过 | 整套 `search-batch` |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 默认 `exclude` | 70 | 60 | 45 | 10 | **1.000** | 1.000 | 1.000 | 0 | 70/70 | 0.863 s |
| `--include-holdout` | 100 | 86 | 64 | 14 | **1.000** | 1.000 | 1.000 | 0 | 100/100 | 1.488 s |
| `--holdout-only` | 30 | 26 | 19 | 4 | **1.000** | 1.000 | 1.000 | 0 | 30/30 | 0.867 s |

「其中算得出 Recall 的」= 有全量真值的题；工具题 `relevant` 为空、Recall 记 null，不进均值。
逐题 `search` 与 `search-batch` 的证据 id **逐题相同**（`batch_vs_single_mismatch` 为空）。
最大 FTS 候选 143 条、**没有一道触到候选上限**；最大摘要 81 token（预算 100）。

按六类（`--include-holdout`）：活动定位 25、原文细节 26、跨来源 13 各 Recall@10 = 1.000；
无答案或已删除 14 道全部零误报；活动模式 14、最近活动 8 按 `evidence_match` 判，Precision@10 = 1.000。
按难度：易 24 / 中 35 / 难 41 全过。

**这个 1.000 不能读成"检索做好了"**：题是脚本按合成流出的、词是种进去的、真值是算出来的
（`source = synthetic`，报告里也印着这句话）。它证明的是**这条评估链路是通的、归因是可验的**。
真实召回率要等 D12 的真实题。

### 5.2 工具题：22 道、59 条断言，全过

`verify-tools` 真的调 `brosis-store` 跑了 22 次，逐条核对 59 条断言，**全过**
（`results/tool_checks.json`）。举几条实际比中的数：

| 题 | 工具 | 断言 | 实测 |
|---|---|---|---|
| `pat-03` | 周台账 | `2026-W34` 整周观察数 | 60,476（满格 60,480，差 4 条是查询集执行的删除） |
| `pat-05` | 周台账 `--check` | `week_observations == sum_observations` 且 `week_online_union_s == sum_online_union_s` | 两侧相等 |
| `pat-07` | `get_patterns` | `byHour` 24 行之和 == 区间总数、`heatmap` 168 格 | 相等 / 168 |
| `pat-09` | `get_patterns` | 最常切换对的 from / to / count 与 `transitionPairs` | 与 JSONL 独立算出来的完全一致 |
| `pat-10` | `get_patterns` | `focus.count == 0`（25 分钟连续工作块） | 0 |
| `pat-12` | `get_timeline` | 7 个日桶之和 == 区间总数、没有哪天超过 8640 | 相等 |
| `rec-01` | `recent_activity` | 最后 30 分钟的观察数 | 180 |
| `rec-05` | `recent_activity` | `items` 5 条、`truncated == true`、每条 `summaryTokens ≤ 100` | 5 / true / ≤ 100 |

**第一版这里是错的**：期望值直接写了"每天 8640 条"，`verify-tools` 当场报出 8 道题不符
（`8638` / `8639` / `60476`…）。原因是 `deletions` 在评估之前就执行了，台账看到的是删完的库。
改成"扫描时跳过将被删除的观察"之后 59 条全过。**这就是这个子命令存在的意义**——
不真跑一遍，这些数只是生成侧的一厢情愿。

### 5.3 第二阶段与六类归因

第二阶段 `provider = none` 时只落盘提示与作答模板（不联网、不评分），
100 道题的提示写进 `results/stage2/prompts/`。
另跑一遍 `provider = file`，喂一套"照抄标准答案 + 引有效 id"的答案、**只把 `det-01` 换成
一句驴唇不对马嘴的话**：

| 项 | 值 |
|---|---|
| 判了几题 / 通过 | 100 / **99** |
| 有效证据引用率 | **1.000**（2.4 的目标 ≥ 0.95） |
| 引用判据分档 | `relevant_ids` 64 道、`evidence_match` 22 道（工具题）、`packed_evidence` **0 道** |

六类归因（`triage_failures.py`，100 题 + 第二阶段）：

| 类 | 题数 |
|---|---:|
| 未采集 | 0 |
| 已过期或已删除 | 0 |
| 索引漏召回 | 0 |
| 上下文裁剪 | 0 |
| 别名不统一 | 0 |
| **推理错误** | **1**（`det-01`，就是故意答错的那道） |
| 负例误报 | 0 |
| 通过 | 99 |

留出题那一档（`--holdout-only`，30 题）六类全 0、零误报——按 4.4 的启动条件，
**M2b 语义图谱现在没有任何启动依据**（留出题上一道都没挂，更谈不上"失败集中在关系 / 别名 / 时态"）。
这一条也写进了月报（`results/monthly.md` 的「检索回归（留出题）」一节）。

### 5.4 归因分类器本身怎么验的

`mutate` 造 5 道注定失败的题，`verify-mutations --triage` 同时核对第一阶段的桶与六类归因：

| 变异题 | 第一阶段归因 | 六类归因 | 对不对 |
|---|---|---|---|
| `mut-01-not-captured` | 未采集 | 未采集 | ✓ |
| `mut-02-expired` | 已过期或已删除 | 已过期或已删除 | ✓ |
| `mut-03-index-miss` | 索引漏召回 | 索引漏召回 | ✓ |
| `mut-04-context-trim` | 上下文裁剪 | 上下文裁剪 | ✓ |
| `mut-05-alias`（新增） | 索引漏召回 | **别名不统一** | ✓ |

第 6 个桶「推理错误」由 §5.3 那道故意答错的题覆盖。**六个桶全部被真实触发过一次。**

### 5.5 M1 那条老流水线（`run_all.sh`）也重跑了一遍

脚本升级之后 `run_all.sh` 跑出来的是 100 题。用它自己的 seed（20260907）另建一个库跑通：
查询集两次生成 sha256 相同、删除对账通过、变异检验通过、
判分器自检**好答案 100/100 过、坏答案 0/100 过**、真实题路径的引用判据自检 `ok = true`、
月报 **0.501 GiB/月**（目标 0.6，达标）、去重率 0.6176。
改它的时候踩到一个真问题并修掉了：`queryset.example.json` 那 4 道真实题样本里有一道
`holdout: true`，第一阶段默认口径会把它排掉，第 7b 步就给不出它的答案而崩——
所以那两处 `eval_stage1.py` 调用都补了 `--include-holdout`。

## 6. 规模压测：1 / 3 / 12 个月

### 6.1 库是怎么造出来的（三条必须这么做的理由）

`tools/proto/gen_synth_m1.py` 的 **E7 最坏口径**：每天 8640 次捕获（24 h ÷ 10 s）、
平均 1500 字符中英混排、30% 是新文本。**按月分文件生成 → 导入 → 立刻删掉 JSONL**。

1. **磁盘**：这么做峰值只有「库 + 一个月的 JSONL」，12 个月档实测目录峰值见下表；
   一次性生成 12 个月的 JSONL 要 7.3 GiB，加上库就顶到 12 GiB 以上。
2. **每个月一个 `--anchor`**（本轮给 `gen_synth_m1.py` 加的可选参数，不给时行为与之前逐字节相同），
   否则 12 段落在同一个月上、时间区间全重叠，测出来的不是 12 个月。
3. **每个月一个种子**（`seed + 月序号`）。同种子产出**逐字节相同的正文**，
   而存储层按内容去重（`text_versions`），12 个月会塌成 1 个月的正文量——
   库体积会小得离谱。**证据就在下面那张表**：3 个月档的库文件正好是 1 个月档的 3.00 倍、
   12 个月档正好是 12 倍上下，`text_versions` 也按月份数线性长——没有塌。

导入**从最老的月份开始**：`observations.id` 随时间单调，才符合检索层
「FTS 候选按 rowid 倒序 ≈ 时间倒序」的前提（3.4 / D22）。

**配额（D7）**：全程用默认的 10 GiB，12 个月库没有触到，没有触发 `expire`，
所以不需要 `--quota-bytes` 抬高。

### 6.2 冷 / 热的定义（与 `brosis-store bench` 一致）

| | 定义 |
|---|---|
| 冷 | **全新子进程 + 全新连接**，跑一次就退出。只清掉了 SQLite 自己的页缓存，没有清 macOS 文件缓存（要提权），所以**冷数字是下界** |
| 热 | 同一条连接上预热一次之后连测 N 次 |

`bench` 自己 spawn 20 个子进程做冷测、同一连接热测 20 次；
`week-ledger` / `patterns` / `recent` 三条走 `--reps`（同一进程里第一次是冷、其余是热），
冷的分布靠**重复启动进程 20 次各取第一次**得到。

`bench` 的四类查询已经覆盖了 `get_day_ledger`（`ledger_day`）、`get_timeline`（`timeline_day`）、
`get_evidence`（`exact_evidence`）、`get_item(app)`（`exact_item_app`）、`get_context`（`ctx_24h`）
与 sessions 区间；周台账 / `get_patterns` 7 天与 30 天 / `recent_activity` 是 M2 c 批新加的、
`bench` 里没有，所以另测。

### 6.3 三档一览

| 项 | 1 个月 | 3 个月 | 12 个月 |
|---|---:|---:|---:|
| 观察数 | 259,200 | 777,600 | 3,110,400 |
| 生成的 JSONL 合计（MiB） | 626.4 | 1882.1 | 7530.8 |
| 生成耗时（s） | 67.5 | 119.3 | 476.3 |
| 导入耗时合计（s） | 60.4 | 171.3 | 739.0 |
| 导入速率（条/s） | 4,291 | 4,539 | 4,209 |
| 导入峰值 footprint（MiB） | 816 | 819 | 822 |
| `maintenance` 耗时（s） | 0.7 | 2.2 | 40.9 |
| `sessions --build` 耗时（s） | 0.2 | 0.7 | 6.0 |
| 会话数 | 8,285 | 24,628 | 97,862 |
| 目录磁盘峰值（GiB） | 0.61 | 1.61 | 6.11 |
| 文本版本 `text_versions` | 84,459 | 253,979 | 1,016,611 |
| 出现记录 `occurrences` | 221,716 | 665,033 | 2,660,794 |
| 去重率 = 1 − 版本/出现 | 0.6191 | 0.6181 | 0.6179 |
| 全文索引行 `fts_rows` | 84,459 | 253,979 | 1,016,611 |
| 库文件（GiB） | 0.500 | 1.505 | 6.020 |
| 库文件 / 1 个月档 | 1.00× | 3.01× | 12.03× |
| 每月折算（GiB/月） | 0.500 | 0.502 | 0.502 |

### 6.4 体积分项（`brosis-store stats --detail`，MiB = 2²⁰ / GiB = 2³⁰）

| 项 | 1 个月 MiB | 3 个月 MiB | 12 个月 MiB | 1 个月 占库 | 3 个月 占库 | 12 个月 占库 |
|---|---:|---:|---:|---:|---:|---:|
| 原文（净载荷） | 206.8 | 623.4 | 2495.9 | 40.4% | 40.5% | 40.5% |
| 原文（含 b-tree 开销） | 237.3 | 715.3 | 2863.6 | 46.3% | 46.4% | 46.5% |
| 索引（全部，含 FTS） | 234.6 | 704.9 | 2817.7 | 45.8% | 45.8% | 45.7% |
| 其中全文索引 | 123.8 | 372.9 | 1489.2 | 24.2% | 24.2% | 24.2% |
| 元数据 | 40.4 | 120.2 | 481.3 | 7.9% | 7.8% | 7.8% |
| 空闲页 | 0.0 | 0.0 | 0.0 | 0.0% | 0.0% | 0.0% |
| 库文件 | 512.4 | 1540.9 | 6164.4 | 100.0% | 100.0% | 100.0% |
| WAL | 0.0 | 0.0 | 0.0 | 0.0% | 0.0% | 0.0% |
| SHM | 0.0 | 0.0 | 0.0 | 0.0% | 0.0% | 0.0% |
| 向量索引 | 未建 | 未建 | 未建 | — | — | — |
| 缩略图 / 模型资产 / 临时空间 | 0 | 0 | 0 | — | — | — |

> 向量：本轮没建（要加载 mlx 模型，1 个月库就要 1 小时 32 分，见 T11）。缩略图 D10 默认关；模型资产不在库里；临时空间按 D25 记 0（`SQLITE_TEMP_STORE=3` 编进去了，PRAGMA 改不回文件）。

### 6.5 延迟：逐条查询的冷 / 热 p50 / p95（ms）

| 查询 | 桶 | 1 个月 冷 p50/p95 | 3 个月 冷 p50/p95 | 12 个月 冷 p50/p95 | 1 个月 热 p50/p95 | 3 个月 热 p50/p95 | 12 个月 热 p50/p95 |
|---|---|---:|---:|---:|---:|---:|---:|
| `exact_host` | 精确字段 | 4.08 / 6.49 | 5.06 / 6.17 | 7.08 / 7.78 | 3.277 / 3.649 | 4.895 / 5.032 | 4.593 / 5.047 |
| `exact_url_prefix` | 精确字段 | 5.00 / 6.40 | 5.12 / 5.83 | 14.27 / 15.58 | 3.457 / 3.568 | 4.279 / 4.530 | 4.367 / 4.463 |
| `exact_path` | 精确字段 | 3.88 / 5.97 | 3.75 / 4.24 | 5.44 / 6.23 | 3.353 / 3.489 | 4.069 / 4.339 | 3.978 / 4.123 |
| `exact_title` | 精确字段 | 5.24 / 6.05 | 3.55 / 4.14 | 5.01 / 6.04 | 4.641 / 4.770 | 3.960 / 6.935 | 3.714 / 3.894 |
| `exact_path_miss` | 精确字段 | 0.04 / 0.08 | 0.05 / 0.06 | 0.07 / 0.07 | 0.007 / 0.007 | 0.008 / 0.011 | 0.006 / 0.007 |
| `exact_evidence` | 精确字段 | 2.45 / 4.23 | 2.76 / 4.06 | 2.55 / 3.31 | 1.835 / 1.938 | 3.001 / 6.206 | 1.910 / 1.965 |
| `exact_item_app` | 报表类 | 60.46 / 84.27 | 176.18 / 246.09 | 2113.96 / 4010.63 | 42.551 / 49.614 | 158.849 / 180.798 | 1994.678 / 2084.114 |
| `fts_e98787e99b86e8a686e79b96` | FTS 通道 | 8.69 / 14.11 | 11.77 / 16.93 | 90.58 / 105.52 | 6.101 / 6.315 | 7.784 / 8.146 | 8.550 / 9.750 |
| `fts_checkpoint` | FTS 通道 | 6.69 / 8.91 | 10.10 / 12.57 | 76.56 / 81.16 | 3.814 / 3.961 | 4.175 / 4.308 | 4.243 / 4.746 |
| `fts_e89fa0e6a183` | FTS 通道 | 4.59 / 5.69 | 9.81 / 12.70 | 56.24 / 61.06 | 3.200 / 3.332 | 7.810 / 8.065 | 8.402 / 8.590 |
| `scan_e9a284e7ae97` | 1–2 字扫描 7 天窗口 | 5.91 / 9.93 | 10.10 / 15.14 | 22.60 / 73.26 | 4.618 / 5.099 | 7.099 / 7.376 | 8.101 / 8.602 |
| `scanapp_e9a284e7ae97` | 1–2 字扫描 + 限应用 | 3.77 / 4.17 | 10.27 / 13.84 | 23.37 / 24.65 | 2.553 / 2.876 | 7.241 / 7.376 | 8.488 / 10.043 |
| `scan_e4bc9a` | 1–2 字扫描 7 天窗口 | 14.94 / 18.32 | 34.26 / 44.91 | 499.59 / 662.15 | 14.064 / 14.420 | 35.035 / 36.840 | 494.315 / 513.566 |
| `scanapp_e4bc9a` | 1–2 字扫描 + 限应用 | 14.58 / 17.03 | 34.52 / 45.63 | 500.39 / 546.39 | 13.604 / 14.954 | 36.935 / 38.161 | 496.298 / 528.939 |
| `ctx_24h` | 报表类 | 5.88 / 7.34 | 6.11 / 10.28 | 6.56 / 8.37 | 4.791 / 5.672 | 5.529 / 5.636 | 4.880 / 4.994 |
| `timeline_day` | 报表类 | 32.84 / 36.94 | 32.67 / 41.54 | 32.59 / 36.07 | 30.824 / 32.687 | 37.280 / 41.244 | 29.031 / 29.455 |
| `ledger_day` | 台账缓存 / recent | 1.17 / 2.05 | 1.18 / 1.95 | 1.22 / 3.95 | 0.475 / 0.495 | 0.660 / 0.881 | 0.476 / 0.586 |
| `sessions_range` | 报表类 | 0.98 / 1.36 | 1.01 / 1.20 | 1.12 / 1.22 | 0.683 / 0.759 | 0.923 / 1.017 | 0.738 / 0.800 |
| `week_ledger_cached` | 台账缓存 / recent | 13.32 / 17.16 | 17.08 / 32.03 | 12.19 / 14.85 | 3.390 / 3.618 | 4.827 / 4.993 | 3.352 / 3.454 |
| `patterns_7d` | get_patterns 7 天 | 41.79 / 47.26 | 53.66 / 71.10 | 40.75 / 41.55 | 31.172 / 37.845 | 42.074 / 48.239 | 29.595 / 48.714 |
| `patterns_30d` | get_patterns 30 天 | 176.32 / 194.54 | 230.02 / 351.96 | 173.94 / 177.87 | 130.095 / 140.872 | 163.223 / 197.896 | 127.150 / 131.591 |
| `recent_30min` | 台账缓存 / recent | 1.38 / 1.59 | 2.44 / 2.53 | 1.48 / 1.52 | 0.787 / 0.845 | 1.188 / 1.325 | 0.859 / 0.906 |

### 6.6 对照计划 3.4 的分层目标逐项判定（用**热 p95**，取桶内最大的一条）

| 桶（3.4 的目标） | 1 个月 | 3 个月 | 12 个月 | 判定 |
|---|---:|---:|---:|---|
| 精确字段（热 p95 < 10 ms） | 4.77 | 6.93 | 5.05 | **达标** |
| FTS 通道（热 p95 < 10 ms） | 6.32 | 8.15 | 9.75 | **达标** |
| 1–2 字扫描 7 天窗口（≤ 150 ms） | 14.42 | 36.84 | 513.57 ✗ | **未达标** |
| 1–2 字扫描 + 限应用（≤ 60 ms） | 14.95 | 38.16 | 528.94 ✗ | **未达标** |
| 报表类（≤ 50 ms） | 49.61 | 180.80 ✗ | 2084.11 ✗ | **未达标** |
| 台账缓存 / recent（≤ 50 ms，4.3.1 补充） | 3.62 | 4.99 | 3.45 | **达标** |
| get_patterns 7 天（≤ 7 ms/天 = 49 ms） | 37.85 | 48.24 | 48.71 | **达标** |
| get_patterns 30 天（≤ 7 ms/天 = 210 ms） | 140.87 | 197.90 | 131.59 | **达标** |

> 单元格是该桶里**最慢的一条**的热 p95（ms），`✗` = 超目标，`†` = 测的时候机器上还有别的编译任务（`contended = true`），这一格不作判据。

### 6.7 测量条件

| 档 | 开测前等了多久 | 开测时 1 min 负载 | 忙进程 | 测完的负载 | 有干扰 |
|---|---:|---:|---|---|---|
| 1 个月 | 481 s | 3.13 | 无 | 3.87/6.52/7.29 | 否 |
| 3 个月 | 0 s | 3.42 | 无 | 5.73/4.95/5.76 | 否 |
| 12 个月 | 0 s | 2.32 | 无 | 3.27/3.78/3.99 | 否 |

### 6.8 读这些数之前要知道的三件事

1. **冷数字是下界**。冷 = 全新子进程 + 全新连接，但只清掉了 SQLite 自己的页缓存，
   没有清 macOS 的文件缓存（要提权，本轮禁止 sudo）。真正的"开机第一次查"会比这慢。
2. **这台机器无风扇，数字随温度浮动**。M2 c / T14 已经记过同一现象：同一条查询在 Air 上
   随机器温度浮动 25–45%。跨档比较看的是**趋势**（随规模线性还是无关），不是第三位小数。
3. **旁边有别的任务在编译时不能测**。本批四个任务并行，实测一个 `swift build` 就能把报表类
   查询翻倍（1 个月档第一遍在有编译时测出 `exact_item_app` 热 p95 65.2 ms、`patterns_7d`
   51.5 ms；空闲重测是 49.6 / 37.9 ms）。脚本因此带了空闲门控，三档的等待时长与当时负载
   都在上面「测量条件」表里，本轮**三档全都是在没有编译任务、负载 2.3–3.4 时测的**。

### 6.9 结论一：存储完全线性，每月 0.502 GiB，达标

库文件 0.500 / 1.505 / 6.020 GiB = 1.00× / 3.01× / 12.03×，分项占比三档几乎一模一样
（原文净载荷 40.5%、索引 45.8%（其中 FTS 24.2%）、元数据 7.8%）。
**每月 0.502 GiB**，在 D21 的 0.6 GiB/月目标之内、远低于 2.4 的 1 GiB/月上限
（E7 在明文原型库上的数是 0.567 GiB/月，产品路径略低）。
去重率三档都是 0.618，说明"每月换一个种子"确实避免了正文塌缩（否则 12 个月的
`text_versions` 会停在 8.4 万而不是 101.7 万）。

**配额（D7）没触发**：默认 10 GiB，12 个月库 6.02 GiB，`expire` 一次都没跑。
12 个月档的**目录磁盘峰值 6.11 GiB**（按月生成 + 导完就删 JSONL；一次性生成要 7.35 GiB 的
JSONL，加上库超过 13 GiB）。

### 6.10 结论二：**所有带窗口的查询都与规模无关**

`get_day_ledger`、周台账（缓存命中）、`recent_activity`、`get_context(24h)`、
`get_timeline(7 天)`、sessions 区间、`get_evidence`、精确字段五条、FTS 三条、
`get_patterns`（7 天 / 30 天）——**12 个月档的热 p95 与 1 个月档在同一量级**，
好几条 12 个月比 1 个月还快一点（温度与页缓存的噪声）。
这条正面结论是 3.4 / E7 那三处查询写法（两步式、rowid 倒序候选、sessions 补下界）
在**产品路径**（SQLCipher + core 的实现）上的复核，不是外推。

### 6.11 结论三：两条**没有窗口**的通道随规模退化，其中一条是真问题

| 查询 | 1 个月 | 3 个月 | 12 个月 | 3.4 目标 | 判定 |
|---|---:|---:|---:|---|---|
| `exact_item_app`（`get_item(app)`，**不带时间范围**） | 49.6 | 180.8 | **2084.1** | 报表类 ≤ 50 ms | 未达标 |
| `scan_会` / `scanapp_会`（1–2 字扫描） | 14.4 / 15.0 | 36.8 / 38.2 | **513.6 / 528.9** | 7 天窗口 ≤ 150 ms / 限应用 ≤ 60 ms | 未达标 |

**`get_item(app)` 是"按定义就该这么慢"**：它问的是"这个应用的全部历史"，12 个月库里
那个应用有 775,641 条观察，返回的 `observations` 就是这个数。3.4 原话是「按问的范围
线性增长属预期」，所以这不是 bug；但它意味着 **`≤ 50 ms` 这条目标只对"问了范围"的调用成立**。
建议（下一轮）：MCP 的 `get_item` 给一个默认时间窗（比如 30 天），或者把 3.4 的目标改写成
"按查询范围计价"，两者选一，别让一个工具调用在 12 个月库上占住 2 秒。

**1–2 字扫描通道是真问题**，因为**缩窗口救不了**。3.4 写的补救措施是「超出就缩默认窗口」，
本轮实测这条**无效**——同一个库上把 `--scan-days` 从 365 缩到 1，耗时一点没变：

| `--scan-days` | 1 | 7 | 30 | 365 |
|---|---:|---:|---:|---:|
| 1 个月库（整进程耗时 ms，含开库约 60 ms） | 60.9 | 86.4 | 65.3 | 102.4 |
| 3 个月库 | 149.2 | 154.2 | 161.5 | 154.8 |
| 12 个月库 | 512.4 | 537.3 | 514.0 | 522.4 |

（`results/scan_window_probe.json`，每档跑 4 次取第 4 次，前三次预热。）

窗口大小不影响、库大小线性影响 ⇒ **时间窗根本没进查询计划的外层循环**。
`Store+Search.swift` 的 `scanChannel` 是一条 SQL：
`observations`（`ts` 窗口）→ `occurrences` → `text_versions`，再在 `tv.text` 上 `LIKE`。
`LIKE` 没有索引可用，SQLite 选了把 `text_versions` 当外层循环、时间窗留到最后过滤，
于是代价跟着**全库正文版本数**走（8.4 万 → 25.4 万 → 101.7 万 = 1 : 3.0 : 12.0）。
实测热 p95 是 1 : 2.6 : **35.7**——比线性更陡，多出来的那一截是 6 GiB 的库在 16 GiB
（还开着别的 app）的机器上放不进页缓存之后的随机读放大。两个因素叠在一起，
所以 12 个月档不是"慢 12 倍"而是"慢 36 倍"。

这条代码上方的注释里记着："试过一版先 `SELECT DISTINCT text_version_id` 去重、再只在这些
版本上 `LIKE` 的两步式，同一个库上实测反而慢了将近一倍"。**那个结论是在 1 个月库上得出的**；
12 个月库上一步式的代价 ∝ 全库正文版本数，两步式的代价 ∝ 窗口内的版本数（一周约 2 万），
取舍会反过来。下一轮的动作：把窗口内的 `text_version_id` 先固化成一个临时表 / CTE
（或者给这条 SQL 加 `CROSS JOIN` 之类的连接顺序提示），再用本节这张表复测——
**判据就是"缩窗口要能省时间"**。这一条已经记进 4.3 的剩余项。

## 7. 未做与原因

1. **向量通道没进规模压测**。建整套向量索引要加载 mlx 模型，1 个月库 46,545 块就要
   **1 小时 32 分**（T11 实测），12 个月档一次会话跑不完，而且本批的 mlx 任务是错开的（T15）。
   所以本轮报的"索引"**不含 `vec_chunks`**，延迟也只有精确字段 / FTS / 扫描 / 聚合四类，
   没有混合检索。向量的体积与延迟口径见 `tools/bench/results/m2_c_vectors_2026-09-08.md`。
2. **2.4「延迟」行里的"嵌入"与"端到端"没测**。`brosis-store` 不加载模型，测不了嵌入；
   端到端要经 app 的 IPC 服务端（T15 这一批才刚把查询向量接进去）。本轮只覆盖**检索服务**那一层。
3. **工具题的断言只到条数与结构，没断言时长**。合成流里 `source_state` 约 10% 是
   `permission_lost` / `timeout`，按 3.7 不计入 dwell，秒数不是能从 JSONL 精确算出来的量。
   要把时长也纳入断言，得先在生成侧把 `source_state` 的分布固定下来。
4. **作息类模式题没出**。这套语料是 24 h 均匀网格，"几点最活跃"在它上面没有信息量；
   `pat-04` / `pat-07` / `pat-10` 是按这一点出的"诚实答案"题。作息类要用
   `tools/proto/gen_workweek.py` 的库另出一套，本轮没做。
5. **`已过期` 与 `用户删除` 仍然分不开**（M1 就记着的老问题）：`get_evidence` 对两者都只回
   `missing`，CLI 也没有查 `deletions` 审计表的子命令。所以六类里这两类合成一桶
   `已过期或已删除`。要分开得给 `brosis-store` 加一个查删除审计的子命令。
6. **真实题（D12）还是没有**。这 100 题仍然是脚本按合成流出的：词是种进去的、真值是算出来的，
   只能证明方法与流程成立，**不是真实召回率**。所以 §6 里 Recall@10 = 1.000 这个数
   不能当成"检索做好了"，它证明的是"这条评估链路是通的、归因是可验的"。
7. **缩略图与模型资产**在库外，本轮都是 0（D10 缩略图默认关）；临时空间按 D25 记 0
   （`SQLITE_TEMP_STORE=3` 编进去了，PRAGMA 改不回文件）。

## 8. 对计划的影响

一句话：**4.3 的四项（100 题、留出 30 题、六类归因、1 / 3 / 12 个月规模压测）全部闭合；
存储每月 0.502 GiB 达标，所有**带窗口**的查询在 12 个月规模上与 1 个月同量级；
唯一的新问题是 **1–2 字扫描通道的时间窗没进查询计划**（缩窗口救不了，12 个月库热 p95 513 ms
对 150 ms 目标），要在下一轮改 `scanChannel` 的连接顺序并用本文那张 `--scan-days` 表复测。**

具体三条：

1. **4.3 的评估条闭合**：查询集 100 题、留出 30 题、六类归因脚本 + 人工标注格式都在，
   六个桶各被真实触发过一次。按 4.4 的启动条件，**M2b 语义图谱现在没有启动依据**
   （留出题上一道都没挂）——这条要等 D12 的真实题到位再看。
2. **2.4 的"存储"与"延迟"两行在 12 个月规模上有实测数**：存储 0.502 GiB/月（目标 0.6、
   上限 1）；延迟按 3.4 的分层目标逐桶判定，8 个桶里 5 个达标、3 个未达（1–2 字扫描两条 +
   报表类一条）。「嵌入」与「端到端」两栏本轮没测，原因在 §7。
3. **给 3.4 提两条修改建议**（不在本任务里改，只把数字摆出来）：
   ① 「1–2 字扫描超出就缩默认窗口」这条补救措施**在 12 个月规模上无效**，实测缩窗口不省时间，
   得先修查询计划；② `get_item(app)` 这类**不带时间范围**的报表调用在 12 个月库上是 2.1 s，
   `≤ 50 ms` 只对"问了范围"的调用成立，建议给 MCP 的 `get_item` 一个默认时间窗，
   或者把目标改写成"按查询范围计价"。

## 9. 验收清单（每一条都能复制粘贴）

```sh
REPO="<项目目录>"
V=$HOME/Library/Caches/brosis-build/verify-t17        # 验收者自己的 scratch

# 1) 零 warning 的 release 构建（只要 core）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path "$REPO/core" -c release --scratch-path "$V-core" 2>&1 | grep -c warning:
#    期望：0

# 2) 评估半边（约 5 分钟，末尾自己核对 21 项，任何一项不过就 exit 1）
SCRATCH=$V sh "$REPO/tools/eval/run_t17_eval.sh"
#    期望最后一行 all_ok = True

# 3) 100 题的分布与留出题
python3 -c "import json;d=json.load(open('$V/results/queryset_gen.json'));print(d['queries'],d['by_class'],d['by_difficulty'],d['holdout_count'],d['by_tool'])"
#    期望：100 / 25,26,13,14,14,8 / 易 24 中 35 难 41 / 30

# 4) 原 60 题一个字没改
python3 -c "import json;d=json.load(open('$V/results/queryset_diff.json'));print(d['m1_60_unchanged'],d['holdout_flag_changed_on_m1_60'],d['deterministic_two_runs'])"
#    期望：True [] True

# 5) 22 道工具题的 59 条断言
python3 -c "import json;d=json.load(open('$V/results/tool_checks.json'));print(d['queries'],d['checks'],d['all_ok'],d['failed'])"
#    期望：22 59 True []

# 6) 六类归因分布（100 题；那一道是 run_t17_eval.sh 故意答错的）
python3 -c "import json;d=json.load(open('$V/results/triage_100.json'));print(d['six_class_counts'],d['failures'])"
#    期望：推理错误 1、其余五类 0，failures = 1

# 7) 归因分类器的变异检验（五个桶）
python3 -c "import json;d=json.load(open('$V/results/mutation_check.json'));print(d['all_match'],[(r['id'],r['bucket'],r.get('triage_bucket')) for r in d['rows']])"
#    期望：True，五道题的两列归因都对得上

# 8) 规模压测（机器空闲时跑；约 55 分钟，磁盘峰值约 6 GiB）
PYTHONDONTWRITEBYTECODE=1 python3 "$REPO/tools/eval/scale_test.py" \
  --bin "$V-core/release/brosis-store" --work $V/scale --results $V/results --months 1,3,12
PYTHONDONTWRITEBYTECODE=1 python3 "$REPO/tools/eval/scale_report.py" \
  --scale $V/results/scale_all.json --out-md $V/results/scale_report.md
#    看 scale_report.md 最后两张表：3.4 逐桶判定 + 测量条件。
#    `idle_gate.timed_out = true` 或 `contended = true` 的档不作判据，重测：
#    …/scale_test.py … --months 12 --keep-db --reuse

# 9) M1 那条老流水线也没被改坏（它现在跑的是 100 题）
mkdir -p $V/runall/release && ln -sf "$V-core/release/brosis-store" $V/runall/release/brosis-store
SKIP_BUILD=1 SCRATCH=$V/runall sh "$REPO/tools/eval/run_all.sh" | tail -20
#    期望：好答案 100/100 过、坏答案 0/100 过、citation_basis_check true、
#          mutation_check true、月报 gib_per_month ≈ 0.501 且 meets_target true

# 10) 项目目录里没有构建产物、没有敏感串
find "$REPO" \( -name .build -o -name DerivedData -o -name __pycache__ -o -name '*.pyc' \
                -o -name .swiftpm -o -name '*.metallib' \) | wc -l          # 期望 0
grep -rn "$(whoami)\|/Users/" "$REPO/tools/eval" | wc -l                     # 期望 0
```

### 变异检验：怎么证明这些自检不是摆设

**复制到 scratch 再改**，别动仓库里的文件。

**a) 把"原 60 题没改"这条弄挂**（证明第 2b 步真的在比）：

```sh
cp "$REPO/tools/eval/make_synthetic_queryset.py" $V/mutant.py
python3 - $V/mutant.py <<'EOF'
import io, sys
p = sys.argv[1]; s = io.open(p, encoding="utf-8").read()
s = s.replace('"det-01", CLASS_DETAIL, "我看到过的关于「知识图谱」的那段原文是怎么写的？"',
              '"det-01", CLASS_DETAIL, "「知识图谱」那段原文是什么？"', 1)
io.open(p, "w", encoding="utf-8").write(s)
EOF
PYTHONDONTWRITEBYTECODE=1 python3 $V/mutant.py gen --jsonl $V/eval/synth_1m.jsonl \
  --corpus $V/eval/queries_1m.json --out $V/eval/queryset_tampered.json --seed 20260908 >/dev/null
# 再拿 run_t17_eval.sh 第 2b 步那段对比脚本比一次 → field_diffs_on_m1_60 里出现 det-01 的 q
```

**b) 把工具题的断言弄挂**（证明 `verify-tools` 真的在调 `brosis-store`）：

```sh
python3 - $V/eval/queryset_100.json $V/eval/queryset_badtool.json <<'EOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for q in d["queries"]:
    if q["id"] == "pat-03":
        q["tool_check"][0]["value"] += 1          # 只改期望值，不改工具调用
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
EOF
PYTHONDONTWRITEBYTECODE=1 python3 "$REPO/tools/eval/make_synthetic_queryset.py" verify-tools \
  --queryset $V/eval/queryset_badtool.json --bin "$V-core/release/brosis-store" \
  --dir $V/eval/db --key-file $V/eval/db.key
# 期望 exit 1，stderr：工具题断言没过：pat-03
```

**b 这一条本轮真跑过**：把 `pat-03` 的第一条断言期望值 60476 改成 60477，
`verify-tools` 报 `checks 59 / failed ["pat-03"] / all_ok false` 并以 exit 1 退出
（`results/tool_checks_tampered.json`）——59 条断言里只有被改的那一条挂，其余 58 条照样过。

**c) 把六类归因弄挂**（证明 `别名不统一` 不是硬编码的）：

```sh
python3 - $V/eval/queryset_mut.json $V/eval/queryset_mut2.json <<'EOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for q in d["queries"]:
    if q["id"] == "mut-05-alias":
        # 把检索串换成与答案有公共字面的说法：规则应当把它判回「索引漏召回」
        q["search"]["q"] = "知识图谱网络"
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
EOF
# 重跑第一阶段 + triage，mut-05 的 final_bucket 会从「别名不统一」变成「索引漏召回」
```
