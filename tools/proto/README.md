# tools/proto — 存储 schema 原型、E3 正确性/删除测试、E7 容量与延迟测量、E6 SQLCipher 验证

> **子目录 `sqlcipher/` 是 T8 / E6 的 SQLCipher 构建与密钥、数据边界验证**（Swift + SwiftPM，
> 不属于本目录的 Python 工具链）。结论：推荐自带 SQLCipher 4.18.0 源码作 C 目标、
> crypto 后端用 CommonCrypto；`SQLITE_TEMP_STORE` 建议编成 3。
> 见 `sqlcipher/README.md` 与 `results/sqlcipher_2026-09-07.md`。
> 注意那里定的 schema 写法（contentless FTS + 显式维护、sha256 存 BLOB）
> 已经按 D22 / D23 更新，本目录的 `schema.sql` 还是 T4 时的旧写法（external content + trigram 占位），
> 两者的差异在 `sqlcipher/Sources/SQLCipherProbe/Schema.swift` 的注释里逐条列了。


对应 `docs/实施计划.md` 的 **3.2 数据模型**、**3.8 保留、过期与删除**、**附录 A 的 E3**；
必须遵守的修正来自 `docs/调研方案评审.md` 的 **F4**（内容去重与出现记录分离；自动过期、
用户删除、逻辑删除后的物理清理三种语义分开验收）。

只用 Python 标准库，不依赖第三方包。数据库文件一律写到 `~/Library/Caches/brosis-build/proto/`，
不落在项目目录（项目目录在 iCloud Drive 里）。

## 文件

| 文件 | 作用 |
|---|---|
| `schema.sql` | v1 存储 schema 原型：14 张普通表（计划 3.2 的 13 张 + 原型自加的 `meta`）+ 1 张 FTS5 虚拟表 + 3 个触发器 + 12 个显式索引 |
| `gen_synth.py` | 确定性合成观察流生成器。两种模式：**E3 模式**（默认，应用切换、文本版本复用、正文修改、两个 device_id）与 **容量模式**（`--capacity`，8640 次/天 × 30% 新文本 × 1500 字符，供 E7 用） |
| `test_correctness.py` | 7 个场景的正确性与删除级联测试，跑完直接生成 Markdown 报告 |
| `measure.py` | **M0 T5 / E7**：容量与延迟测量。建 1 / 3 / 12 个月规模库，用 `dbstat` 分项报告字节，测四类查询的冷热 p50/p95 |
| `capacity_conclusions.md` | T5 报告 §7 起的结论段落（人写的），由 `measure.py` 拼到生成的 §1–§6 后面 |
| `results/correctness_2026-09-06.md` | E3 最近一次实跑结果（本机 2026-09-06） |
| `results/capacity_2026-09-06.md` / `.json` | E7 最近一次实跑结果与逐查询原始数据 |
| `sqlcipher/` | **T8 / E6**：SQLCipher 两条构建路线的对比、编译开关核对、明文泄漏检查、锁定状态机原型、加密开销测量（Swift 包，见该目录的 README） |
| `results/sqlcipher_2026-09-07.md` / `.json` | E6 实跑结果与三次探针的原始数据 |

## 怎么跑

前提：macOS 自带或 Homebrew 的 Python 3（本机 3.14.7，内置 SQLite 3.53.4，需要 FTS5 与 trigram 分词）。

```sh
cd "<项目目录>/tools/proto"

# 1. 只建库、只灌合成数据（不跑测试）
python3 gen_synth.py --days 7 --per-day 120 --seed 20260906 --devices 2 \
    --out ~/Library/Caches/brosis-build/proto/synth.db --digest

# 2. 跑全部 7 个场景并写报告（会自己重新生成一份干净的库）
python3 test_correctness.py

# 3. 换参数跑（报告写到别处，不覆盖 results/ 里的存档）
python3 test_correctness.py --seed 777 --days 14 --per-day 60 --devices 3 \
    --db ~/Library/Caches/brosis-build/proto/alt.db \
    --report ~/Library/Caches/brosis-build/proto/alt.md

# 4. 只看 schema 能不能干净地建起来
sqlite3 ~/Library/Caches/brosis-build/proto/empty.db < schema.sql
```

退出码：`0` 全部场景通过，`1` 有场景失败，`2` 参数太小（`--days × --per-day < 100` 时构造不出
共享版本、独占探针这些测试夹具，会直接拒绝运行而不是给一个假的通过）。

`gen_synth.py --digest` 打印内容摘要，用来验证同一 seed 的生成结果完全一致。

**回归基线（2026-09-07 实测，当前代码）**：

| 参数 | 内容摘要（sha256） |
|---|---|
| `--days 7 --per-day 120 --seed 20260906 --devices 2` | `03e4e382635b134c7de5581c5e2e0df55a3e93048d6dceabfd2f3602ab64b54f` |
| 同上但 `--seed 7` | `23544b0fa180236d16db6368c73c1c294563830e051424a68706c367c8ff0f19` |

同 seed 两次运行摘要相同，换 seed 摘要不同。**改动 `gen_synth.py` 的语料池、字段或生成顺序后
这两个值会变，必须在这里同步更新**（摘要只覆盖 `observations` / `text_versions` 的内容，
不含文件大小等易变量）。

产物位置：

- 数据库：`~/Library/Caches/brosis-build/proto/e3.db`（测试用）、`synth.db`（手工生成）、
  `crash.db`（崩溃场景专用）；
- 缩略图占位文件：`<db 路径>.thumbs/`，用来验证删除时缩略图一并清理；
- 报告：`tools/proto/results/correctness_<日期>.md`。

## schema 的几个关键决定

1. **`auto_vacuum = INCREMENTAL` 必须在建第一张表之前设置**，所以它是 `schema.sql` 的第一行。
   建表之后再改需要整库 `VACUUM`。`journal_mode = WAL` 是文件级、只设一次；
   `foreign_keys` 和 `secure_delete` 是**连接级**，每次打开库都要重设（见 `gen_synth.connect()`）。
2. **主键带 `device_id`（D17）**：`observations` / `text_versions` / `occurrences` / `deletions`
   的业务主键都是 `(device_id, id)`，`occurrences` 用复合外键引用它们。
3. **`text_versions` 多一个 `vrow INTEGER PRIMARY KEY`**：FTS5 外部内容表只能按单列整型 rowid
   关联内容表，复合主键做不到，所以加一个代理 rowid。`vrow` 是本机私有的，不参与跨设备同步。
4. **按 sha256 复用**：`UNIQUE (device_id, sha256)` 保证同一设备内同一段文本只有一行。
   跨设备的去重放到 M2 的同步合并里做，不在本地强行统一。
5. **`text_versions` 不可变**：`trg_text_versions_immutable` 触发器让任何 `UPDATE` 直接 `ABORT`，
   改内容只能插新版本。允许 `DELETE`（删除级联和配额过期要用）。
6. **共享版本靠外键 `RESTRICT` 保护**：`occurrences.text_version_id` 是 `ON DELETE RESTRICT`，
   只要还有一条 occurrence，这个版本就删不掉——这是 3.8「共享文本版本」规则的硬保证，
   不依赖应用层记得检查。而 `occurrences.observation_id` 是 `ON DELETE CASCADE`，
   配额过期物理删观察时自动带走出现记录。
7. **`trigger` 和 `end` 是 SQLite 关键字**，在 `observations` 和 `sessions` 里必须写成 `"trigger"`、`"end"`。

### FTS 维护：选了触发器，没选显式维护

`schema.sql` 里 `trg_text_fts_ai` / `trg_text_fts_ad` 两个触发器负责同步 `text_fts`。理由：

- `text_versions` 不可变，只有 INSERT 和 DELETE 两条路径，触发器一共 6 行，覆盖完整；
- 删除级联会从**多个入口**发生（用户删除、配额过期、以后的夜间清理任务）。如果改成显式维护，
  每个入口都要记得删 FTS 行，漏掉一个就是「内容已删但全文检索还能命中」——这是隐私 bug，
  不是性能问题；
- 触发器和主表写在同一个事务里，崩溃恢复后索引与内容表天然一致（S6 用 FTS5 内建
  `integrity-check` 验证过）。

代价：批量回填时无法把建索引推迟到最后。真遇到瓶颈的逃生口是——先 `DROP` 两个触发器，
批量插完 `text_versions`，再 `INSERT INTO text_fts(text_fts) VALUES('rebuild');` 重建，
最后把触发器建回来。

### 换分词方案（T3 / E2 定稿后）

现在是 `tokenize='trigram'` + `detail=full` **占位**（3.4 的第三个候选）。

T3 的离线对照已经出了：`tools/bench/results/fts_compare_2026-09-06.md`。它的 §9.2 推荐
**B+E+V**（汉字 bigram 预处理 + `unicode61 remove_diacritics 2` + 精确字段列 + 短查询补扫描
+ 只对 FTS 候选做子串复核）：Recall@10 97.0%、索引净增 0.99 MiB（正文的 0.55 倍），
而这里占位的 trigram 是 Recall@10 81.0%、索引 3.42 MiB（正文的 1.88 倍）。
**但 T3 报告本身没有「选定分词」的定稿段落，E2 的在线部分也还没跑**，所以 `schema.sql`
暂时保持 trigram 占位不动；`measure.py` 的默认值已经是 bigram（`--fts bigram`），
两边不一致是有意的：一个是待定稿的 schema，一个是按 T3 推荐做的容量测量。

定稿（T3/E2 正式选定）后按这个顺序改，其余表和删除逻辑都不受影响：

```sql
DROP TRIGGER trg_text_fts_ai;
DROP TRIGGER trg_text_fts_ad;
DROP TABLE text_fts;                      -- 改 tokenize 必须重建虚拟表，不能 ALTER
CREATE VIRTUAL TABLE text_fts USING fts5(
  text, content='text_versions', content_rowid='vrow',
  tokenize='<新分词>', detail=full);
-- 重新创建 schema.sql 里那两个触发器
INSERT INTO text_fts(text_fts) VALUES('rebuild');   -- 从 text_versions 重灌索引
```

本机验证过这套流程：1484 行索引换成 `unicode61 remove_diacritics 2` 后重建，行数不变，
`integrity-check` 通过。

## 两条删除路径的语义差别（3.8）

| | 用户主动删除 | 配额过期 |
|---|---|---|
| 触发 | 合规工具，用户点了就立即执行 | 库超过配额（默认 5 GB），最旧先删 |
| `observations` 行 | **保留**，打 `deleted_at` 墓碑（供审计与跨设备同步重放） | **物理删除**，`deletions` 审计行充当区间墓碑 |
| `occurrences` | 显式 `DELETE` | 随外键 `ON DELETE CASCADE` 自动删 |
| 无引用的 `text_version` | 删 | 删 |
| FTS 行 | 随触发器删 | 随触发器删 |
| `sessions` / `ledgers` | 证据命中就标 `stale` 待重算 | 同左 |
| 缩略图文件 | 删，`thumb_ref` 置空 | 删 |
| `deletions` 审计 | `reason='user'` | `reason='quota'` |

级联顺序在 `test_correctness.py` 的 `user_delete()` 和 `quota_expire()` 里，按 3.8 写死：
observation → occurrences → 无引用 text_version → FTS 行 → 派生结果 stale → 缩略图 → 审计行。

`deletions.fts_rows_deleted` 是**实测值**：两条路径都在事务开始与清完孤儿版本之后各查一次
`SELECT COUNT(*) FROM text_fts_docsize`，取差值写入，而不是照抄 `text_versions_deleted`。
触发器保证两者 1:1，但审计字段照抄就失去了独立核验的意义——S3 / S5 各有一条断言专门对这个账。

## 7 个测试场景

| # | 场景 | 验的是什么 |
|---|---|---|
| S1 | 同一文本重复出现 | 一个 `text_version`、多条 `occurrence`；同设备内 sha256 不重复 |
| S2 | 正文修改（预算 100 → 200） | 两版都在、都可检索；按 observation 能唯一确定当时看到的是哪一版；`UPDATE` 被拒 |
| S3 | 用户按应用 + 时段删除 | 全链级联；FTS 探针删前命中删后不命中；`get_evidence` / `get_context` / `get_day_ledger` 三个入口都不再返回内容 |
| S4 | 共享版本只删部分 occurrence | 版本保留、FTS 仍命中；直接删仍被引用的版本被外键挡住 |
| S5 | 配额过期 | 最旧先删、降到配额以下；与用户删除语义可区分；两条路径都有独立审计行 |
| S6 | 崩溃重启 | 子进程 `kill -9` 打在未提交事务中间；重开后 `integrity_check` = ok、`foreign_key_check` 空、未提交批整批回滚 |
| S7 | 悬空引用总检 | 13 项自定义悬空查询全为 0；`integrity_check`、FTS5 `integrity-check`、`incremental_vacuum` 空间回收 |

S6 会自己判断 `kill -9` 是不是真落在事务中间（子进程在每个 `BEGIN` 之后把批号 `fsync` 到
`<db>.progress`，父进程比对已开始批号与已提交批数），没打中就重试，最多 5 次。

## 范围之外

- **加密**：本原型跑明文库。SQLCipher 与 FTS5 / sqlite-vec 的链接兼容属于 E6。
- **向量表**：`chunks` / `vec_chunks` 只在 D8 通过后才建，这里没有。
- **容量口径**：合成数据的复用率和字节量只用于验证机制，真实容量以 E7 实测为准。
- **长度 < 3 的文本版本进不了 trigram 索引**（评审 F3 的已知限制）：本轮语料里的「备注」「已阅」
  共 4 个 `text_version` 有 FTS 行，但 trigram 从 3 个字符起才有 token，phrase 查询永远不命中。
  计划 3.4 规定一到两字的查询走**限定时间/应用范围的扫描**（`tools/bench/results/fts_compare_2026-09-06.md`
  §6 实测：限定「7 天 + 指定应用」后这类查询召回 100%）。因此 S3 的「删除后 FTS 不再命中」这条验收
  对这类短文本不适用——S7 会把它们的个数单列出来作为口径说明，不作断言。

---

## E7 / T5：容量与延迟测量怎么跑（`measure.py`）

对应《实施计划》附录 A 的 **E7**、**2.4 验收口径**的「存储」与「延迟」两行，
落实《调研方案评审》**F8**（统一按 UTF-8 字节分项；延迟分冷热 p50/p95，
并在 1 / 3 / 12 个月三个规模上分别测）。

### 一条命令跑完整轮

```sh
cd "<项目目录>/tools/proto"
python3 measure.py --scales 1,3,12 --sensitivity --cold-rounds 10 --hot-reps 20 \
    --max-build-min 22 --date 2026-09-06
```

本机（M4 Max 128 GB）整轮约 **25 分钟**，其中建 12 个月的库约 12 分钟。
产物：`results/capacity_<date>.md`（人读）+ `results/capacity_<date>.json`（原始数据），
数据库落在 `~/Library/Caches/brosis-build/proto/capacity_*.db`：

| 库 | 体积 | 现在还在不在 |
|---|---:|---|
| `capacity_1m.db` | 579 MB | 在（`--latency-only` / `--content-probe` 要用） |
| `capacity_3m.db` | 1.7 GB | 在 |
| `capacity_12m.db` | 6.8 GB | 在（`--latency-only` / `--index-probe` 要用） |
| `capacity_1m_ps8192.db` / `_ps16384.db` / `_trigram.db` | 各 0.5–0.8 GB | **已删**，数字都在 JSON 里，要复核就 `--sensitivity` 重跑（每个约 51 秒） |

留着的三个合计约 **9.1 GB**。不需要了：

```sh
rm -f ~/Library/Caches/brosis-build/proto/capacity_*.db
```

### 只跑一部分

```sh
# 只跑 1 个月，快速验证脚本能走通（约 2 分钟）
python3 measure.py --scales 1 --date probe

# 换 FTS 方案（默认 bigram = T3 推荐；trigram 是 schema.sql 里的占位）
python3 measure.py --scales 1 --fts trigram --date probe-trigram

# 改完 capacity_conclusions.md 或 write_report() 后，不重跑测量、只重新生成报告
python3 measure.py --report-only --date 2026-09-06

# 试跑（不覆盖 results/ 里的存档；下面这条同时验证 --max-build-min 的线性外推路径）
python3 measure.py --scales 1,3 --days-per-month 2 --max-build-min 0.02 \
    --cold-rounds 2 --hot-reps 3 --date probe-extrap \
    --build-dir ~/Library/Caches/brosis-build/proto-t9 \
    --results-dir ~/Library/Caches/brosis-build/proto-t9

# 不重建库，只在已有库上重跑延迟（改了查询集之后用这个，约 70 秒）
python3 measure.py --latency-only --date 2026-09-06

# 两个专项对照（都会把结果并进同一份 JSON，并在报告里多出 §6.x / §6.y）
python3 measure.py --index-probe   --date 2026-09-06   # observations(file_id, ts) 索引值不值
python3 measure.py --content-probe --date 2026-09-06   # 正文按应用的分布 + 压缩比
```

`--index-probe` 会在最大的那个库上临时建一个索引再删掉，跑完 `incremental_vacuum`
把库还原（实测前后都是 7,292,542,976 字节），所以 §3 的分项字节不受影响。

### 参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `--scales` | `1,3,12` | 要测的规模（月），逗号分隔 |
| `--days-per-month` | `30` | 一个月按几天算（调小可做快速冒烟） |
| `--fts` | `bigram` | `bigram` = T3 推荐的 B+E+V；`trigram` = schema.sql 的占位方案 |
| `--cold-rounds` / `--hot-reps` | `10` / `20` | 冷测轮数（每轮一个新进程）/ 热测重复次数 |
| `--sensitivity` | 关 | 额外在 1 个月规模上跑 `page_size` 8192 / 16384 与 trigram 三个变体 |
| `--max-build-min` | `20` | 单个规模的建库时间上限（分钟）。按上一个规模实测外推超了就**不实建**，改为按天数线性外推行数与字节，报告 §2 里标「线性外推」；延迟、WAL、`dbstat` 分项不外推，这类规模也不进 §3–§5 各表 |
| `--build-dir` | `~/Library/Caches/brosis-build/proto` | 数据库目录 |
| `--report` / `--date` | `results/capacity_<date>.md` | 输出路径与文件名里的日期 |
| `--results-dir` | `tools/proto/results` | JSON 与报告的输出目录。**试跑时指到缓存目录**，别覆盖 `results/` 里的存档 |

### 测量口径（读数字之前先看这个）

| 项 | 口径 |
|---|---|
| 规模 | 每天 **8640 次捕获** = 24 h ÷ 10 s；1 / 3 / 12 个月 = 30 / 90 / 360 天；**单设备单库** |
| 新文本 | **30%，分母是全部捕获**（评审 F8 的算式）。13.5% 的捕获 `completeness ∈ {unavailable, excluded}` 根本没有正文，所以在「读到正文的捕获」里概率被放大到 34.7%，使每天新 `text_version` 落在 8640 × 30% = 2592 段 |
| 一次捕获 | 产出**一段**完整可见正文（schema 里 `text` 是「存完整原文，不分块」），所以 `occurrences` 与有正文的 `observations` 一比一 |
| 字节 | 全部 UTF-8。库内分项用 `dbstat` 逐 b-tree 统计**实占页字节**，不是估算系数；「原文净载荷」= `SUM(text_versions.byte_len)` |
| FTS | 默认 T3 推荐的 **B+E+V**：`fts5(body, tokenize='unicode61 remove_diacritics 2', content='', contentless_delete=1)`，写入前汉字切重叠 bigram，查询时同样 bigram 化包 phrase，候选再用 `LIKE` 复核 |
| 冷 | **全新子进程 + 全新连接**：每轮 spawn 一个新的 `python3`，进程内每条查询各开一条连接跑一次就关。**只清了 SQLite 的页缓存，没清 macOS 文件缓存**（清缓存要提权），所以冷数字是下界 |
| 热 | 同一条连接，先预热 1 次再连测 N 次。单次超过 200 ms 的查询会自动把 N 降到 `max(3, N×200/预热毫秒)`，免得 12 个月规模上跑太久。**所以「热 20 个样本」不是每条查询都成立**：本轮 12 个月规模上有 3 条降到了 7 / 18 / 18，报告 §1 与 §5 表下都写明了，逐查询的 `hot_n` 在 JSON 里 |
| 8640 次/天怎么铺 | 均匀铺满 **24 h**（每 10 s 一次）。可行性调研报告 §6.2 的同一个 8640 是「12 h 活跃 ÷ 5 s」。捕获数与字节数一致，**容量结论不受影响**；受影响的是 `get_context(hours=24)` 这类按时间窗口取行的查询——两种铺法在同一个 24 h 窗口里行数相同但分布不同，本报告的延迟数字偏保守 |
| 单位 | §1–§6 与 §7 起的结论一律 **KiB / MiB / GiB = 2^10 / 2^20 / 2^30**，字节原值在 JSON 里。《实施计划》2.4 的「0.3 GB/月、5 GB 配额」**没注明进制**，所以 §7 同时给出 GiB 与十进制 GB 两套倍数与配额月数 |
| WAL 峰值 | 建库全程后台每 50 ms 采 `-wal` 文件字节取最大值 |
| 临时空间 | **不能靠扫 `SQLITE_TMPDIR` 目录**——SQLite 在 unix 上建完临时文件立刻 `unlink`，目录里永远是 0 字节。这里用「文件系统可用空间下降峰值 − 同期库文件增长」估，含其他进程的磁盘噪声，是**上界** |

### bigram 方案对 schema.sql 的影响（要反馈给 T4）

T3 推荐的是 **contentless** FTS（`content=''`），而 `schema.sql` 现在是 **external content**
（`content='text_versions'`）+ 两个触发器。换成 contentless 之后：

- FTS 表里存的是 **bigram 预处理后的文本**，SQL 触发器算不出来（要么在连接上注册自定义函数，
  要么由应用层维护）。`measure.py` 走的是**应用层显式维护**：
  `INSERT INTO text_fts(rowid, body) VALUES (?, ?)`，`rowid` 用 `text_versions.vrow`。
- 于是 T4 README 里「为什么选触发器」的那条理由（删除入口多，怕漏删 FTS 行）**重新变成风险**：
  删除路径必须显式 `DELETE FROM text_fts WHERE rowid = ?`。建议 schema v0.2 定稿时，
  要么在存储服务里把 FTS 维护和 `text_versions` 的增删封进同一个函数，
  要么注册一个 `bigram()` SQL 函数把触发器保留下来。

`measure.py` 用 `gen_synth.apply_fts_scheme()` 在建表之后、灌数据之前换掉这张虚拟表，
换法就是 T4 README 里写的那套 `DROP TRIGGER / DROP TABLE / CREATE VIRTUAL TABLE`。

### 单独用容量模式建库（不测延迟）

```sh
python3 gen_synth.py --capacity --days 30 --seed 20260906 \
    --out ~/Library/Caches/brosis-build/proto/cap30.db
# 换 FTS 方案 / 页大小
python3 gen_synth.py --capacity --days 30 --fts trigram --page-size 16384 \
    --out ~/Library/Caches/brosis-build/proto/cap30_tri16k.db
```

容量模式与 E3 模式是**两条独立的代码路径**：容量模式不写缩略图占位文件
（12 个月会是 78 万个小文件），会话边生成边攒不做全表回查，正文按 `--avg-chars` 拼装。
E3 模式一行没改——同 seed 的内容摘要仍然是
`03e4e382635b134c7de5581c5e2e0df55a3e93048d6dceabfd2f3602ab64b54f`，
改完之后已复核过。
