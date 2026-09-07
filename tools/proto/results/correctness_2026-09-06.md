# E3 存储 schema 正确性与删除测试结果（2026-09-06）

对应实施计划 3.2 数据模型、3.8 保留与删除、附录 A 的 E3；修正项来自评审 F4。
本报告由 `tools/proto/test_correctness.py` 直接生成，所有数字来自本机实跑，不是估算。

## 0. 结论

- **7 个场景全部通过**（7/7），共 56 项断言全部为真（56/56）。
- schema 可以按 3.2 定稿：观察、文本版本、出现记录三层分离能同时表达「同一文本重复出现」「正文修改后两版都在」「共享版本被部分删除」三种情况。
- 删除级联按 3.8 的顺序跑通：observation → occurrences → 无引用 text_version → FTS 行 → 派生结果 stale → 缩略图文件 → 审计行；用户删除与配额过期两条路径语义分开，都留审计。
- 崩溃后 WAL 恢复干净，未提交事务整批回滚，`integrity_check` / `foreign_key_check` / FTS5 `integrity-check` 三项都过。

## 1. 运行环境与参数

| 项 | 值 |
|---|---|
| 日期 | 2026-09-06 |
| 机器 | Darwin 26.6.2，arm64 |
| Python | 3.14.7 |
| SQLite（Python 内置） | 3.53.4 |
| FTS5 分词 | `trigram` + `detail=full`（占位；T3/E2 定稿后只改 schema.sql 里那两行） |
| 数据库 | `~/Library/Caches/brosis-build/proto/e3.db` |
| 生成参数 | `--days 7 --per-day 120 --seed 20260906 --devices 2` |
| 测试总耗时 | 1.3 秒 |

### 合成库初始规模

| 指标 | 值 |
|---|---|
| 设备 | dev-mbp16、dev-mba13 |
| observations | 1680 条（应用切换 368 次） |
| occurrences | 3186 条 |
| text_versions | 1922 个（新建 1922，哈希复用命中 1264 次，复用率 39.7%） |
| 原文体量 | 183829 字节（179.5 KiB，UTF-8 实际字节；本文 KiB/MiB 一律 2^10 / 2^20） |
| FTS 行 | 1922 行 |
| sessions / ledgers | 370 条 / 14 条 |
| 缩略图占位文件 | 418 个 |
| 库文件（含 WAL） | 2367488 字节（2.26 MiB） |

## 2. 场景结果

| 场景 | 名称 | 结果 | 断言 |
|---|---|---|---|
| S1 | 同一文本重复出现 → 一个 text_version、多条 occurrence | 通过 | 4/4 |
| S2 | 正文修改后两版都可取回，按 observation 能查到对应版本 | 通过 | 5/5 |
| S3 | 用户按「应用 + 时段」删除 → 逻辑删除 + 全链级联 + FTS 不再命中 | 通过 | 12/12 |
| S4 | 共享文本版本只删部分 occurrence → 版本保留 | 通过 | 4/4 |
| S5 | 配额过期（最旧先删）与用户删除语义分开，两条路径都级联并留审计 | 通过 | 8/8 |
| S6 | 崩溃重启：写到一半 kill -9，重开后 integrity_check / foreign_key_check 干净 | 通过 | 7/7 |
| S7 | 全场景跑完后的悬空引用与一致性总检 | 通过 | 16/16 |

### S1 同一文本重复出现 → 一个 text_version、多条 occurrence — 通过

| 指标 | 值 |
|---|---|
| text_versions 总数 | 1922 个 |
| occurrences 总数 | 3186 条 |
| occurrence / version 比 | 1.66 |
| 同一设备内 sha256 重复的版本 | 0 个 |
| 被 ≥2 条 occurrence 引用的版本 | 44 个（占 2.3%） |
| 引用最多的一个版本 | 44 条 occurrence，跨 8 个应用，原文前 28 字「The trigram tokenizer indexe…」 |
| byte_len 与实际 UTF-8 字节不一致的版本 | 0 个 |

| 断言 | 结果 |
|---|---|
| 同一设备内不存在两个 sha256 相同的 text_version（精确哈希复用生效） | 通过 |
| 存在被多条 occurrence 共享的版本（复用确实发生） | 通过 |
| 最热版本跨 ≥2 个应用出现，且每次出现各留一条 occurrence | 通过 |
| byte_len 口径正确（等于原文 UTF-8 字节数） | 通过 |

### S2 正文修改后两版都可取回，按 observation 能查到对应版本 — 通过

| 指标 | 值 |
|---|---|
| 「项目 A 季度规划」在 dev-mbp16 上的版本数 | 2 个 |
| 预算 100 万元 那一版 | text_version id=7，sha256=e77abba0fbd3…，被 7 条 occurrence 引用；最早 observation id=4（2026-08-31 09:13:30Z），最晚 id=724（2026-09-06 09:13:30Z） |
| 预算 200 万元 那一版 | text_version id=148，sha256=84f34fa23579…，被 7 条 occurrence 引用；最早 observation id=117（2026-08-31 17:42:00Z），最晚 id=837（2026-09-06 17:42:00Z） |
| 按 observation 反查命中数 | 共 14 次观察（预算 100 版 7 次、预算 200 版 7 次） |
| 按天成对出现（先 100 后 200） | 7 天 / 共 7 天有该文档 |
| FTS 命中「预算 100 万元」/「预算 200 万元」 | 2 行 / 2 行 |

| 断言 | 结果 |
|---|---|
| 同一文档的两版各自是独立、不可变的 text_version（不是覆盖） | 通过 |
| 每条 observation 都能唯一确定它当时看到的版本（无一条同时命中两版） | 通过 |
| 修改前的版本没有被新版本覆盖，每天都是先 100 后 200 成对出现 | 通过 |
| 两版原文都能被全文检索单独命中（F4 的「项目 A 预算」用例） | 通过 |
| text_versions 不可变（UPDATE 被拒绝） | 通过 |

> 尝试 UPDATE text_versions 被触发器拒绝：text_versions is immutable: insert a new version instead

### S3 用户按「应用 + 时段」删除 → 逻辑删除 + 全链级联 + FTS 不再命中 — 通过

| 指标 | 值 |
|---|---|
| 删除条件 | device=dev-mbp16，应用=com.apple.Safari，日期=2026-09-03（UTC 全天） |
| 命中 observation | 39 条 |
| observations 打 deleted_at | 39 条（行仍在库里，作为墓碑） |
| occurrences 删除 | 81 条（删除后残留 0 条） |
| text_versions 删除 | 41 个（dev-mbp16 设备内 957 → 916） |
| FTS 行（全库） | 1922 → 1881 行（差 41，与删除版本数一致） |
| deletions.fts_rows_deleted（审计字段） | 41 行（删除前后各查一次 text_fts_docsize 实测，不是照抄 text_versions_deleted） |
| 释放原文字节 | 3901 字节 |
| FTS 探针「[2026-09-03] Safari …」 | 删除前命中 1 行，删除后命中 0 行 |
| 派生结果标 stale | sessions 5 条、ledgers 1 条 |
| 缩略图文件删除 | 11 个 |
| deletions 审计行 | id=1 kind=app reason=user applied_at=2026-09-06 16:53:14Z |
| get_evidence 入口（按 observation 取回原文片段） | 删除后返回 0 条片段 |
| get_context 入口（该应用该日未删观察 + 正文） | 删除后返回 0 行 |
| get_day_ledger 入口（2026-09-03 的当日台账） | 非 stale 的台账 0 条（stale 的需重算后才可用） |

| 断言 | 结果 |
|---|---|
| 全部命中的 observation 都打上了 deleted_at | 通过 |
| observation 行本身保留（墓碑，供审计与跨设备同步） | 通过 |
| 这些 observation 的 occurrence 全部删除 | 通过 |
| 无引用的 text_version 被删除，FTS 行同步减少同样数量 | 通过 |
| 审计字段 fts_rows_deleted = 场景外独立测到的 FTS 行减少量 | 通过 |
| 独占探针文本删除前能命中、删除后不再命中 | 通过 |
| 派生 sessions / ledgers 被标 stale 待重算 | 通过 |
| 缩略图文件被清理且 thumb_ref 置空 | 通过 |
| deletions 表有一条 reason=user 的审计记录 | 通过 |
| get_evidence 入口取不到任何原文片段（3.8 验收） | 通过 |
| get_context 入口不再返回该应用该时段的内容（3.8 验收） | 通过 |
| get_day_ledger 入口的当日台账被标 stale，不会返回过期口径（3.8 验收） | 通过 |

### S4 共享文本版本只删部分 occurrence → 版本保留 — 通过

| 指标 | 值 |
|---|---|
| 被测共享版本 | text_version id=60，删除前 39 条 occurrence，跨 8 个应用 |
| 删除的那一条 observation | id=41（自身共 3 条 occurrence） |
| 该版本的 occurrence 数 | 39 → 38 条 |
| 该版本是否仍在库中 | 是（1 行） |
| FTS 仍能命中该版本原文 | 2 行 |
| 本次删除的 text_versions 数 | 1 个 |

| 断言 | 结果 |
|---|---|
| 只删了部分 occurrence，共享版本本身保留 | 通过 |
| occurrence 精确减少 1 条 | 通过 |
| 其他仍被保留的合法引用不受影响，FTS 仍能命中 | 通过 |
| 外键 RESTRICT 挡住了直接删除仍被引用的 text_version | 通过 |

> 直接 DELETE 仍被引用的 text_version 被外键拒绝：FOREIGN KEY constraint failed

### S5 配额过期（最旧先删）与用户删除语义分开，两条路径都级联并留审计 — 通过

| 指标 | 值 |
|---|---|
| 配额目标 | 把 dev-mba13 的原文压到 55811 字节（原 93019 字节的 60%） |
| observations | 840 → 490 条（物理删除 350 条） |
| occurrences 随外键 CASCADE 删除 | 673 条 |
| text_versions | 965 → 569 个（删除 396 个） |
| FTS 行 | 1880 → 1484 行（差 396） |
| deletions.fts_rows_deleted（审计字段） | 396 行（事务内实测） |
| 原文字节 | 93019 → 55070 字节（释放 37949 字节，40.8%） |
| 删除区间 | 最旧 2026-08-31 09:00:00Z → 2026-09-02 17:10:30Z；剩余最早观察 2026-09-02 17:15:00Z |
| 派生结果标 stale | sessions 61 条、ledgers 3 条 |
| deletions 审计 | reason=quota 1 条（kind=range，observations_affected=350）；reason=user 共 2 条 |
| 两种语义的行为差别 | 用户删除保留 40 条 deleted_at 墓碑行；配额过期物理删除行，由 deletions 审计行充当区间墓碑 |

| 断言 | 结果 |
|---|---|
| 原文字节降到配额目标以下 | 通过 |
| 最旧先删：被删观察全部早于剩余最早观察 | 通过 |
| occurrences 随观察物理删除被 CASCADE 清干净（无悬空） | 通过 |
| 无引用的 text_version 与 FTS 行同步减少 | 通过 |
| 审计字段 fts_rows_deleted = 场景外独立测到的 FTS 行减少量 | 通过 |
| 派生 sessions / ledgers 标 stale | 通过 |
| deletions 表同时有 reason=quota 与 reason=user 的独立审计记录 | 通过 |
| 两种语义可区分：用户删除留墓碑行，配额过期不留行 | 通过 |

### S6 崩溃重启：写到一半 kill -9，重开后 integrity_check / foreign_key_check 干净 — 通过

| 指标 | 值 |
|---|---|
| 子进程 | 独立 python3 写入进程（首行 'READY batch=400'），被 SIGKILL 终止，退出码 -9（尝试 1 次以命中事务中间） |
| kill 时刻 | 已开始第 47 批、已提交 46 批 → 第 47 批正在写、未提交 |
| 被杀时未 checkpoint 的 WAL | 7889832 字节（7.52 MiB） |
| 重开后 PRAGMA integrity_check | ok（耗时 113 ms，含 foreign_key_check） |
| 重开后 PRAGMA foreign_key_check | 0 行违规 |
| 恢复出的行数 | observations 18400 条、occurrences 18400 条、text_versions 18400 个、FTS 18400 行 |
| 已提交事务批数 | 46 批 × 400 行/批 = 18400 条（未提交的那批整批回滚） |
| FTS5 内建 integrity-check | ok |
| 崩溃库路径 | ~/Library/Caches/brosis-build/proto/crash.db |

| 断言 | 结果 |
|---|---|
| PRAGMA integrity_check 返回 ok | 通过 |
| PRAGMA foreign_key_check 无输出 | 通过 |
| 确实写入了数据后才被杀（非空库） | 通过 |
| kill -9 确实落在一个未提交的事务中间（已开始批号 > 已提交批数） | 通过 |
| 未提交的事务整批回滚，observations 行数是批大小的整数倍 | 通过 |
| occurrences 无悬空观察引用 | 通过 |
| FTS5 索引与外部内容表一致 | 通过 |

### S7 全场景跑完后的悬空引用与一致性总检 — 通过

| 指标 | 值 |
|---|---|
| occurrence 指向不存在的 observation | 0 行（期望 0） |
| occurrence 指向不存在的 text_version | 0 行（期望 0） |
| FTS 行没有对应的 text_version | 0 行（期望 0） |
| text_version 没有对应的 FTS 行 | 0 行（期望 0） |
| 没有任何 occurrence 引用的 text_version（孤儿版本） | 0 行（期望 0） |
| 已逻辑删除的 observation 仍留有 occurrence | 0 行（期望 0） |
| 已逻辑删除的 observation 仍留有 thumb_ref | 0 行（期望 0） |
| 同一设备内 sha256 重复的 text_version | 0 行（期望 0） |
| 同一 observation 内 ord 重复的 occurrence | 0 行（期望 0） |
| 引用了已删观察却未标 stale 的 sessions / ledgers | 0 行（期望 0） |
| 磁盘上无人引用的缩略图文件 | 0 行（期望 0） |
| 被引用但磁盘上已丢失的缩略图文件 | 0 行（期望 0） |
| PRAGMA foreign_key_check 违规行 | 0 行（期望 0） |
| 长度 < 3 的 text_version（trigram 索引不到，走扫描路径） | 4 个，其中 4 个有 FTS 行但 phrase 查询永远不命中；样例：「备注」、「已阅」 |
| PRAGMA integrity_check | ok |
| FTS5 integrity-check（rank=0，含与外部内容表比对） | ok |
| 空闲页（incremental_vacuum 前 → 后） | 93 → 0 页（页大小 4096 字节） |
| 总页数 | 613 → 520 页 |
| 主库文件 | 2510848 → 2129920 字节（回收 380928 字节，15.2%） |
| WAL 文件 | 清理前 1545032 字节 → checkpoint(TRUNCATE) 后 0 字节 |
| incremental_vacuum + wal_checkpoint 耗时 | 1 ms |

| 断言 | 结果 |
|---|---|
| occurrence 指向不存在的 observation = 0 | 通过 |
| occurrence 指向不存在的 text_version = 0 | 通过 |
| FTS 行没有对应的 text_version = 0 | 通过 |
| text_version 没有对应的 FTS 行 = 0 | 通过 |
| 没有任何 occurrence 引用的 text_version（孤儿版本） = 0 | 通过 |
| 已逻辑删除的 observation 仍留有 occurrence = 0 | 通过 |
| 已逻辑删除的 observation 仍留有 thumb_ref = 0 | 通过 |
| 同一设备内 sha256 重复的 text_version = 0 | 通过 |
| 同一 observation 内 ord 重复的 occurrence = 0 | 通过 |
| 引用了已删观察却未标 stale 的 sessions / ledgers = 0 | 通过 |
| 磁盘上无人引用的缩略图文件 = 0 | 通过 |
| 被引用但磁盘上已丢失的缩略图文件 = 0 | 通过 |
| PRAGMA foreign_key_check 违规行 = 0 | 通过 |
| PRAGMA integrity_check = ok | 通过 |
| FTS5 索引与 text_versions 内容表完全一致 | 通过 |
| incremental_vacuum 把空闲页清零，主库文件确实变小 | 通过 |

## 3. 遗留与说明

- **分词是占位的**：`text_fts` 现在用 `trigram` + `detail=full`。T3/E2 出结论前不算定稿；换分词只需改 `schema.sql` 里虚拟表的 `tokenize` / `detail` 两行再重建索引，其余表和删除逻辑都不受影响。
- **代理 rowid**：`text_versions` 的业务主键是 `(device_id, id)`（D17 要求带 device_id），但 FTS5 外部内容表只能按单列整型 rowid 关联，所以额外加了 `vrow INTEGER PRIMARY KEY`。跨设备同步时 `vrow` 是本机私有的，不参与同步。
- **本测试用明文库**：SQLCipher 与 FTS5 / sqlite-vec 的链接兼容在 E6 单独验证，不在 E3 范围。
- **合成数据不代表真实文本分布**：复用率、字节量只用于验证机制，容量口径以 E7 实测为准。
- **物理空间回收已实测一轮**（见 S7）：`auto_vacuum=INCREMENTAL` + `incremental_vacuum` + `wal_checkpoint(TRUNCATE)` 能把删除留下的空闲页归零并缩小文件。真实负载下这属于夜间接电任务，耗时随空闲页数增长，M1 要按批限量跑而不是一次清空。
- **`secure_delete=ON` 只覆盖页内残留**，不保证覆盖已被文件系统释放的块，更不覆盖已导出的备份副本；这一点要在 UI 里如实提示（3.8）。

