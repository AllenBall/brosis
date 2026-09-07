# brosis 查询集格式（`brosis/queryset@1`）

评估脚本（`eval_stage1.py` / `eval_stage2.py`）读的就是这个格式。合成集由
`make_synthetic_queryset.py` 生成，真实集由你按本文手写（计划 4.2「查询集扩到 60 题」、
D12）。**两者字段完全一样**，脚本不区分来源，只看 `source` 决定要不要打「合成语料」的警示。

对应文档：`docs/查询集草稿.md`（四类配额与评分规则）、`docs/实施计划.md` 2.4（检索验收口径）、
4.4（失败归因六类）。

---

## 1. 顶层对象

```json
{
  "schema": "brosis/queryset@1",
  "source": "synthetic",
  "generated_at": "2026-09-07T00:00:00Z",
  "seed": 20260907,
  "quota": {"活动定位": 20, "原文细节": 20, "跨来源": 10, "无答案或已删除": 10},
  "corpus": { "...见 §4..." },
  "deletions": [ "...见 §5..." ],
  "scoring": { "...见 §6..." },
  "truth_rule": "一句话说明 relevant 是怎么算出来的",
  "queries": [ { "...见 §2..." } ]
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `schema` | 是 | 固定 `brosis/queryset@1`。脚本会校验，不认的直接报错退出 |
| `source` | 是 | `synthetic`（合成，结论只能证明方法成立）或 `real`（你按真实事件出的题） |
| `generated_at` | 是 | UTC ISO8601 |
| `seed` | 合成集必填 | 生成用的随机种子；同 seed 同输入 → 逐字节相同的查询集 |
| `quota` | 是 | 四类各多少题。脚本会核对实际题数与它一致，不一致报错 |
| `corpus` | 合成集必填 | 见 §4 |
| `deletions` | 否 | 建库后要执行的删除操作，用来造「已删除」题；见 §5 |
| `scoring` | 是 | 评分规则，原样写进两阶段的判题提示；见 §6 |
| `truth_rule` | 是 | 人读的一句话，说明 `relevant` 的口径 |
| `queries` | 是 | 题目数组 |

## 2. 题目对象

```json
{
  "id": "det-03",
  "class": "原文细节",
  "holdout": false,
  "q": "我看到过的那条提到「采集覆盖率」的内容，原文是怎么写的？",
  "search": {"q": "采集覆盖率", "start": null, "end": null, "app": null, "limit": 10},
  "expect": "hit",
  "unanswerable_reason": null,
  "evidence": {
    "text_substrings": ["采集覆盖率"],
    "apps": ["md.obsidian", "com.electron.lark"],
    "time_window": null,
    "urls": [],
    "paths": []
  },
  "relevant": [1041, 9987, "..."],
  "relevant_count": 18,
  "answer": "……标准答案……",
  "answer_check": {"must_include": ["采集覆盖率"], "must_not_include": []},
  "answer_source": "合成语料全量重算",
  "authored": "2026-09-07",
  "notes": ""
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `id` | 是 | 全集唯一。合成集用 `loc-NN` / `det-NN` / `cross-NN` / `none-NN` / `del-NN` |
| `class` | 是 | 只能是 `活动定位` / `原文细节` / `跨来源` / `无答案或已删除`（草稿的四类；草稿里写作「活动 / 定位」，这里去掉空格便于当键用） |
| `holdout` | 是 | `true` = 留出题，不参与调参。合成集按类分层取每类第 3、6、9… 题，确定性 |
| `q` | 是 | **给 Agent 看的自然语言问题**。第二阶段原样进提示 |
| `search` | 是 | **第一阶段实际发给 `brosis-store search` 的参数**。`q` 是检索串（可带 `app:` / `host:` / `path:` / `title:` / `url:` 前缀），`start` / `end` 是 Unix 毫秒半开区间 `[start, end)`，`app` 是 bundle_id 等值过滤，`limit` 默认 10。为 `null` 的键不传 |
| `expect` | 是 | `hit`（可答，必须拿到证据）或 `none`（不可答，必须一条都不返回） |
| `unanswerable_reason` | `none` 题必填 | `excluded`（排除清单）/ `not_captured`（未采集）/ `user_deleted`（用户删除）/ `not_seen`（没看到过）/ `not_recorded`（不采集该模态，如音频）。对应草稿第 26–30 题的五种成因 |
| `evidence` | 是 | **期望证据**，四类条件任意组合，见 §3 |
| `relevant` | 合成集必填 | 真值观察 id 数组（升序）。真实集可以留 `[]`，此时第一阶段只报「返回了几条」，Recall 记 `null` 并在报告里点名 |
| `relevant_count` | 是 | `len(relevant)`；真实集留 `[]` 时写 `null` |
| `answer` | 是 | 标准答案。`none` 题写应当给出的拒答话术 |
| `answer_check` | 是 | 第二阶段自动判分用的子串规则：`must_include` 全部命中且 `must_not_include` 一个都不命中才算内容正确 |
| `answer_source` | 是 | 答案哪来的：`合成语料全量重算` / `原始任务` / `人工回忆` / `排除清单` |
| `authored` | 是 | 出题日期。草稿要求「出题时记录日期」 |
| `notes` | 否 | 备注 |

## 3. `evidence`：期望证据

四个键任意组合，**留空 = 不作要求**。第一阶段用它做「上下文裁剪」判定，
第二阶段用它检查引用是否有效。

| 键 | 类型 | 含义 |
|---|---|---|
| `text_substrings` | `string[]` | 证据正文里必须出现的子串（ASCII 大小写不敏感）。最常用 |
| `apps` | `string[]` | 证据应当来自这些 bundle_id（≥ 2 个就是跨来源题） |
| `time_window` | `{start_ms, end_ms}` 或 `null` | 证据应当落在这个半开区间里 |
| `urls` | `string[]` | 证据的 `url` / `host` 里应当出现的子串 |
| `paths` | `string[]` | 证据的文件路径里应当出现的子串 |

## 4. `corpus`（只合成集有）

```json
{
  "jsonl": "synth_1m.jsonl",
  "jsonl_sha256": "……",
  "jsonl_bytes": 658825878,
  "observations": 259200,
  "start_ms": 1754697600000,
  "end_ms": 1757289600000,
  "step_ms": 10000,
  "id_rule": "import-jsonl 按行序写入，第 k 行（1 起）对应 observations.id = k"
}
```

`id_rule` 是真值能用整数 id 表达的前提；它由 `core/README.md` 的 `import-jsonl` 行为保证。
`jsonl_sha256` 是生成时记下的案底，**评估时不重算**（那要再读一遍几百 MiB）；
要确认「现在这个库就是这份语料建出来的」，给第一阶段加 `--check-corpus`：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 eval_stage1.py --check-corpus …
```

它拿 `brosis-store stats` 的 `observations`（**含墓碑行**，所以删除执行前后都一样）
和这里的 `observations` 比，对不上就退出；活/墓碑数与 `deletions` 的预期条数并排列进报告，
只作参考不作判据（删除还没执行时墓碑本来就是 0）。真实题没有 `corpus` 段，加了也自动跳过。

## 5. `deletions`：造「已删除」题

数组，按顺序在**建库导入之后、评估之前**执行。每项：

```json
{
  "id": "del-01",
  "kind": "observations",
  "cli": ["--observations", "1234,5678"],
  "expect_observations_affected": 9,
  "note": "把「蟠桃」那几屏按用户删除处理"
}
```

| 键 | 说明 |
|---|---|
| `kind` | `observations` / `range` / `object` / `app`，对应 `brosis-store delete` 的四个入口 |
| `cli` | 原样拼到 `brosis-store delete --dir … --key-file …` 后面的参数 |
| `expect_observations_affected` | 生成侧模拟出来的条数。执行时用它和 CLI 回的 `observations_affected` **对账**，不等就报错——这是「模拟的删除语义 == 存储层真实语义」的自检 |

`make_synthetic_queryset.py apply-deletions` 负责执行与对账。生成时已经把被删的观察从
**每一道题**的 `relevant` 里剔除了，所以删除后的库和查询集是一致的。

## 6. `scoring`：评分规则

```json
{
  "stage1": {
    "metric": ["recall@10", "precision@10", "mrr@10"],
    "hit_pass": "recall@10 == 1.0",
    "none_pass": "返回 0 条",
    "target": "可答题 Recall@10 ≥ 0.90（计划 2.4）"
  },
  "stage2": {
    "hit_pass": "答案含 answer_check.must_include 的全部子串，且引用的 evidence id 至少一条落在 relevant 里",
    "none_pass": "明确表示无证据 / 未记录，且不给出任何具体事实",
    "target": "有效证据引用 ≥ 0.95（计划 2.4）；编造一次即记失败（草稿）"
  }
}
```

脚本把 `scoring` 原样写进第二阶段的判题提示，改规则只改查询集、不改脚本。

`hit_pass` 里「落在 `relevant` 里」这一句对**真实题**要换个尺子——真实题 `relevant` 是空的。
`eval_stage2.py` 自动按可信度退档（`citation_basis`）：

| 档 | 什么时候用 | 「有效引用」的判据 |
|---|---|---|
| `relevant_ids` | 查询集有全量真值（合成集） | 引用落在 `relevant` 里 |
| `evidence_match` | 真实题，且第一阶段有返回证据满足 `evidence` | 引用落在第一阶段的 `evidence_matched_ids` 里 |
| `packed_evidence` | 上面两档都没有 | 引用至少是**喂给它看过的**那几条（只拦编造的 id）；口径最松，报告里单独点名，不能拿它对 2.4 的 ≥ 0.95 |

## 7. 真实题怎么出（D12）

1. 复制 `queryset.example.json`，把 `source` 改成 `real`、`corpus` / `deletions` 删掉。
2. 按草稿的四类配额出 60 题（20 / 20 / 10 / 10），`answer` 与 `answer_source` 必须来自
   原始任务或人工回忆，**不能用本系统自己推出来**（草稿规则）。
3. `relevant` 留 `[]`：真实库上没有全量真值，第一阶段改看
   「返回的证据里有没有满足 `evidence` 的那条」——`eval_stage1.py` 在
   `relevant == []` 时自动切到这个口径（用 `evidence.text_substrings` 对
   `search` 返回的摘要与片段做判定，其余键对 app / 时间窗 / url / path 做判定；
   `time_window` 只写一端时另一端当无界），并在报告里把这些题单列
   （`judged_by = evidence_match`、`recall@10 = null`）。
   第二阶段跟着用同一批 id 判「引用有没有效」（见 §6 的退档表），
   所以 `evidence` 填得越准，两个阶段的判分越靠得住。
4. 每题填 `authored`；30 题定稿后固定不动，随实现调整的只能是新题。
5. 留出题：`holdout: true`。M1 是 60 题留 18 题，M2 扩到 100 题时留 30 题。
