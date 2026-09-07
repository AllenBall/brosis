# M1 R1 / T2：加密存储核心包 `core/`（2026-09-07）

- 对应：`docs/实施计划.md` 的 **3.1**（存储服务）、**3.2**（数据模型）、**3.4**（只做 FTS 写入口径）、**3.5**（密钥）、**3.8**（保留、过期与删除）、**3.12**（`app_policies`），决策 **D16**、**D17**、**D22**、**D23**、**D25**
- 关闭的 M0 遗留项：收口清单 B 组第 10 条「E3 七个场景在 SQLCipher 加密库上复跑」；E6 结果文档 §11 的「没测崩溃恢复（加密库的 WAL 恢复路径）」
- 代码：`core/`（新增）。文档：`core/README.md`
- 本机：Apple M4 Air / 16 GiB / 无风扇 / macOS 26.6 / Darwin 25.6.0 / Xcode 26.6 / Swift 6.3.3（语言模式 v6）
- 单位口径：**KiB / MiB / GiB = 2¹⁰ / 2²⁰ / 2³⁰**。字节原值都写在表里，换算只是方便读
- 原始输出：`~/Library/Caches/brosis-build/m1-core/results/`（20 个文件；重采一遍就是 `sh results/collect.sh`）
- 本轮**没有启动任何 GUI、没有触发 TCC 或钥匙串授权弹窗、没有用 sudo、没有改 xcode-select**；没有 git commit

---

## 1. 做了什么

新增 SwiftPM 包 `core/`（swift-tools 6.1，macOS 26，语言模式 v6），四个目标：

| 目标 | 形态 | 内容 |
|---|---|---|
| `SQLCipher` | C | SQLCipher v4.18.0 amalgamation，CommonCrypto 后端。**源码不进仓库**：`core/Vendor/SQLCipher` 是指向构建缓存的符号链接，由 `core/setup.sh` 建 |
| `CSqliteVec` | C | sqlite-vec v0.1.9，静态编入。**D8 通过前不注册、不建表**，只保证能链接 |
| `CBrosisSQLite` | C | 53 行薄垫片：volatile 清零、sqlite-vec 注册入口、`SQLITE_TRANSIENT` |
| `BrosisCore` | Swift 库 | 2,954 行。KeyProvider ×3、`Store.open/close`、schema v1、`record`、四个删除入口、配额过期、夜间维护、dbstat 统计、13 项一致性检查 |
| `brosis-store` | 可执行 | 534 行。11 个子命令，输出全是 JSON，供测试与验收 |
| `BrosisCoreTests` | XCTest | 1,310 行，**38 个用例**，五个套件 |

**D25 的「先写薄封装、超过 500 行再评估 GRDB」**：`SQLiteConnection.swift` 实际 **210 行**，远低于 500 行的评估线，M1 不上 GRDB 的决定继续成立。

## 2. 怎么跑

```sh
# 一次即可（首次要 clone sqlcipher 并生成 amalgamation，数分钟）
sh core/setup.sh

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path core -c release \
  --scratch-path ~/Library/Caches/brosis-build/m1-core

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path core \
  --scratch-path ~/Library/Caches/brosis-build/m1-core

# 采一遍结果文件引用的全部原始输出（CLI 路径的独立复核）
sh ~/Library/Caches/brosis-build/m1-core/results/collect.sh
```

`core/setup.sh` 复用 M0 已验证的 `tools/proto/sqlcipher/setup.sh` 取源，两个源文件的 SHA-256 与 M0 逐位一致：

| 文件 | SHA-256 |
|---|---|
| `sqlite3.c`（SQLCipher v4.18.0 amalgamation，9,751,239 字节 = 9.30 MiB） | `964c72bd1d3e031862588202e2bf6342d36ec68a2cae4f4276d9cd79e6571acb` |
| `sqlite-vec.c`（v0.1.9，320,026 字节） | `ba081a47fa02eadc3cf6b16c314b695b84081269349aac722b4efa338fe8fd85` |

---

## 3. 构建与测试（实测）

| 项 | 数字 | 出处 |
|---|---|---|
| release 全新构建 | **0 error、0 warning**，16.88 s（wall 17.12 s） | `results/build_release.log` |
| `swift test` | **38 个用例、0 失败**，4.363 s | `results/swift_test.log` |
| — `E3ScenarioTests` | 7 个，0.222 s | 同上 |
| — `CrashRecoveryTests` | 2 个，2.153 s | 同上 |
| — `CryptoAndBuildTests` | 12 个，1.167 s | 同上 |
| — `BigramFTSTests` | 8 个，0.426 s | 同上 |
| — `StoreAPITests` | 9 个，0.395 s | 同上 |
| `brosis-store`（release） | 2,373,312 字节 = **2.2633 MiB** | `ls -la <scratch>/release/brosis-store` |

**warning 归零的代价**：上游 amalgamation 自己 `#define` 了 `MIN` / `MAX`，unix VFS 那段又 `#include <sys/param.h>`（SDK 里也有同名宏），clang 对 **68 处**调用报 `-Wambiguous-macro`。两个定义语义完全相同，是纯噪声，而源码由脚本从上游生成、不能改，所以在 `Package.swift` 里加了 `-Wno-ambiguous-macro`（`.unsafeFlags`）。副作用：本包不能作为**按版本解析的**依赖被引用；它只会被 `app/` 以本地路径 `.package(path: "../core")` 引用，已实测该组合可用。**除此之外没有任何被抑制或无法消除的 warning。**

---

## 4. E3 七个场景在加密库上复跑

场景编号与 `tools/proto/test_correctness.py` 对齐；S6 换成计划点名的「应用切换」，崩溃恢复放 S7（要跨进程 `kill -9`）。

| # | 场景 | 断言与实测 | 结果 |
|---|---|---|---|
| S1 | 文本版本复用 | 同一段正文出现 5 次（跨 2 个应用）→ `text_versions` = 1、`occurrences` = 5、`observations` = 5、FTS 行 = 1；`newTextVersions` = 1、复用 4 次；5 次观察指向同一个 `text_version` | 过 |
| S2 | 正文修改 | 「预算 100 万」→「预算 200 万」产生 2 个版本；按 observation 各自唯一确定当时看到的是哪一版；两版都能被 FTS 命中；`UPDATE text_versions` 被 `trg_text_versions_immutable` **ABORT**，原文未变 | 过 |
| S3 | 用户删除级联 | 删飞书：`observations_affected` = 1、`occurrences_deleted` = 1、`text_versions_deleted` = 1、`thumbs_deleted` = 1、`sessions_stale` = 1、`ledgers_stale` = 1；**FTS 行数独立复核**：`ftsBefore − ftsAfter` = 1 = 审计字段 `fts_rows_deleted`；`get_evidence` / `get_context` / `get_day_ledger` 三个入口删后都不再返回内容；墓碑保留、`thumb_ref` 置空、缩略图文件已删；未删的那条完好 | 过 |
| S4 | 共享文本版本 | 同一段正文在 3 个应用出现 → 1 个版本、3 条 occurrence；**直接 `DELETE` 被外键 RESTRICT 挡住**；删掉 1 条、2 条 occurrence 后版本仍在且 FTS 仍命中；删掉第 3 条时版本与 FTS 行一起消失（`text_versions_deleted` = 1、`fts_rows_deleted` = 1） | 过 |
| S5 | 配额过期 | 配额 4,000 字节、40 条独占正文；越过 80% 阈值触发 `quotaWarningHandler`；`batch = 3` 时删到低于配额即停，**最旧先删**（剩余最小 id = 被删条数 + 1，`oldest_deleted_ts` = 起始时间戳）；**与用户删除可区分**：墓碑数 = 1（只有用户删的那条），配额删的是物理行；两条路径各一条独立审计行，配额行的 `params` 含 `oldest_first` / `ts_from` / `"synced":false` | 过 |
| S6 | 应用切换 | 5 次切换（含回到同一窗口、同应用换窗口）→ `observations` = 5、`apps` = 3、`windows` = 4；按应用取观察 Safari 3 条 / 飞书 1 条；按应用删除只影响该应用，规范化对象本身不删（`ON DELETE RESTRICT`） | 过 |
| S7 | 崩溃恢复 | 见下表 | 过 |

**S7 崩溃恢复（`brosis-store crash-after` + `kill -9`，加密库）**

| 项 | 实测 | 出处 |
|---|---|---|
| 已提交 / 未提交 | 300 条已提交，50 条在未提交事务里 | `results/crash_after.txt` 的 `.progress` |
| 子进程终止 | `Killed: 9`，exit 137 | 同上 |
| 被杀时 WAL | 2,264,336 字节 = **2.1595 MiB**（未 checkpoint） | 同上 |
| 脏 WAL 明文扫描 | `会议纪要` / `SQLCipher` / `段落` 在 `-wal` 与 `.db` 里命中均为 **0** | 同上 |
| 重开后行数 | `observations` = **300**、`occurrences` = 300、`text_versions` = 60、FTS 行 = 60 | `results/crash_recovered_stats.json` |
| 一致性 | 13 项悬空检查全 0、`integrity_check` = ok、FTS `integrity-check` = ok、`foreign_key_check` 违规 0 | `results/crash_recovered_check.json` |
| 计数器 | 崩溃后写入的第一条观察 id = 301，说明计数器与数据在同一个事务里一起回滚了 | `CrashRecoveryTests` 的断言 |

**13 项悬空引用检查**（混合操作 + `maintenance()` 之后，全部为 0，期望 0）：

```
 1 occurrence 指向不存在的 observation          8 同一设备内 sha256 重复的 text_version
 2 occurrence 指向不存在的 text_version         9 同一 observation 内 ord 重复的 occurrence
 3 FTS 行没有对应的 text_version               10 引用了已删观察却未标 stale 的 sessions / ledgers
 4 text_version 没有对应的 FTS 行               11 磁盘上无人引用的缩略图文件
 5 没有任何 occurrence 引用的 text_version      12 被引用但磁盘上已丢失的缩略图文件
 6 已逻辑删除的 observation 仍留有 occurrence   13 PRAGMA foreign_key_check 违规行
 7 已逻辑删除的 observation 仍留有 thumb_ref
```

出处：`results/check.json`、`results/crash_recovered_check.json`。

---

## 5. 明文泄漏扫描（命中必须为 0）

600 条正文，每条埋三个金丝雀：`BROSISLEAKCANARY7F3A2D`、`饕餮鑫垚焱淼`、`会议纪要独占标记`。
命令行用 `grep -a -c`，测试里另有一套逐字节扫描器（`CryptoAndBuildTests.testNoPlaintextLeak`，含强制排序溢出与私有 `SQLITE_TMPDIR`）。

| 检查点 | 大小 | 三个金丝雀命中 |
|---|---:|---:|
| 加密库 `.db`（未 checkpoint） | 1,622,016 字节 = 1.5469 MiB | **0 / 0 / 0** |
| 加密库 `.db`（checkpoint + 关库后） | 1,622,016 字节 = 1.5469 MiB | **0 / 0 / 0** |
| `-wal` / `-shm`（关库后） | 已被 `TRUNCATE` 清掉，文件不存在 | — |
| 数据目录递归 `grep -a -r -c` | 2 个文件（`.db`、`.metadata_never_index`） | **0** |
| 私有 `SQLITE_TMPDIR` | **文件数 = 0**（`SQLITE_TEMP_STORE=3` 编译期强制内存） | **0** |
| 系统 `$TMPDIR` 递归 | 命中文件数 **0** | **0** |
| 崩溃留下的脏 `-wal`（2.16 MiB，另一个库） | 语料词 `会议纪要` / `SQLCipher` / `段落` | **0 / 0 / 0** |
| **阳性对照**：同一把尺子对明文文件 | — | **1**（证明检查器不是空转） |
| `strings -a brosis.db \| grep -c <金丝雀>` | — | **0** |

出处：`results/leak_scan.txt`、`results/crash_after.txt`。

> E6 §6.3 的结论在这里落地：`temp_store` 编译成 3 之后，一次强制排序溢出（`cache_size` 压到 64 KiB 跑全表 `ORDER BY text`）也没有产生任何临时文件——私有 `SQLITE_TMPDIR` 里文件数为 0。M0 时 `temp_store=FILE` 那次是 22.64 MiB 明文、73,494 次命中。

---

## 6. 编译开关与连接顺序

`PRAGMA compile_options` 共 63 条，逐条在 `results/init_compile_options.json`。要求项核对：

| 检查项 | 实测 | 要求 |
|---|---|---|
| `THREADSAFE=1` | 有 | 必须 |
| `ENABLE_FTS5` | 有 | 必须 |
| `SECURE_DELETE` | 有 | 必须 |
| `ENABLE_DBSTAT_VTAB` | 有 | 必须 |
| `HAS_CODEC` | 有 | 必须 |
| `TEMP_STORE=3` | 有，且 `PRAGMA temp_store = FILE` 之后读回仍是 **3** | D25（编译期强制，PRAGMA 改不回） |
| SQLite 版本 | **3.53.4** | ≥ 3.43（`contentless_delete=1` 的下限） |
| SQLCipher | **4.18.0 community** | D25 |
| crypto 后端 | **commoncrypto** | D25（不是 LibTomCrypt） |
| sqlite-vec | **v0.1.9**，静态链接可读到版本号 | 固定版本、D8 前不启用 |

连接级读回值（`brosis-store init`，`results/init_compile_options.json`）：

```
cipher_page_size = 16384   page_size = 16384   journal_mode = wal
auto_vacuum = 2 (INCREMENTAL)   foreign_keys = 1   secure_delete = 1
cipher_memory_security = 0（默认关，D25 的可选严格项）
数据目录：mode = 700，.metadata_never_index = true，excluded_from_backup = true
```

**连接序言（顺序固定，两处坑各有实测）**

```text
[PRAGMA cipher_memory_security = ON]   -- 可选，必须在第一次分配加密上下文之前
PRAGMA key = "x'<64 位十六进制>'"
PRAGMA cipher_page_size = 16384
PRAGMA auto_vacuum = INCREMENTAL       -- 仅建库时
PRAGMA journal_mode = WAL
PRAGMA synchronous = NORMAL
PRAGMA foreign_keys = ON
SELECT count(*) FROM sqlite_schema     -- 首次真读
-- 之后（不属于固定序言）：secure_delete = ON、cache_size = -131072（128 MiB）
```

1. **`cipher_page_size` 不写进文件头**（E6 已发现）：不重设就报 `SQLITE_NOTADB / file is not a database`，与密钥错误的报错完全一样。所以 `StoreError.wrongKeyOrCorrupt` 一个 case 同时覆盖这两种情况，并在文档注释里写明「因为序言固定写了 `cipher_page_size`，走到这一步只剩密钥不对或文件真坏」。
2. **`auto_vacuum` 必须排在 `journal_mode` 之前**（本轮新发现，与任务书给的顺序不同）：`auto_vacuum` 是文件级设置，只在页 1 还没写出去时可改；`PRAGMA journal_mode = WAL` 是一次模式切换，会把页 1（此时 `auto_vacuum = 0`）落盘，之后再设 `INCREMENTAL` **静默无效**。
   **实测**：按 `key → cipher_page_size → WAL → synchronous → foreign_keys → auto_vacuum` 建库，`PRAGMA auto_vacuum` 读回 **0**；把这一行提到 WAL 之前读回 **2**。`tools/proto/schema.sql` 与 M0 探针的 `Schema.preamble` 用的也是「auto_vacuum 在前」的顺序。已按实测顺序实现并在代码里写明理由。

**错密钥**：换一把随机密钥打开 → `rc = 26 SQLITE_NOTADB / file is not a database`，CLI 退出码 1；全 0 密钥同样失败；**失败的解锁之后正确密钥仍能打开，库没被写坏**（`results/wrong_key.txt`、`CryptoAndBuildTests.testWrongKeyFailsAndRightKeySucceeds`）。
**密钥清零**：`close()` 之后密钥缓冲区全 0；拼出来的 `PRAGMA key` SQL 缓冲区也 volatile 清零；20 轮 `开库 → 写 → 关库并清零 → 再开库` 全过。

---

## 7. 体积口径（dbstat 分项）

500 条合成观察（`gen-jsonl --count 500 --seed 20260907`，20% 新文本），`maintenance()` 之后：

| 分项 | 字节 | 换算 | 口径 |
|---|---:|---:|---|
| **正文** | 49,152 | 48 KiB | `text_versions` 表 b-tree 实占页字节 |
| **索引** | 786,432 | 768 KiB | 全部索引 b-tree（显式 + `sqlite_autoindex_*`）**+ FTS 影子表** |
| — 其中 FTS | 65,536 | 64 KiB | `text_fts_*` 影子表，单列一次（与「索引」是包含关系） |
| **元数据** | 344,064 | 336 KiB | 其余表：观察、出现、规范化对象、审计、策略、遥测、`sqlite_schema` |
| **WAL** | 0 | 0 | `checkpoint(TRUNCATE)` 之后 |
| 空闲页 | 0 | 0 | `freelist_count × page_size` |
| 主库文件 | 1,196,032 | 1.1406 MiB | 73 页 × 16,384 |
| **原文净载荷** | 14,063 | 13.73 KiB | `SUM(text_versions.byte_len)`，UTF-8 字节。**配额按它算** |

行数：`observations` 500、`text_versions` 100、`occurrences` 500、FTS 行 100、`apps` 5。
逐 b-tree 明细在 `results/stats_after_import.json` 的 `detail`（每行含 `name` / `bucket` / `bytes` / `pages`）。

> 这一组数字**不能外推成真实容量**：500 条合成数据的正文只有 13.73 KiB，远小于一页（16 KiB），所以「索引是正文的 16 倍」纯粹是页粒度效应，不是 D22 的索引比。真实容量口径以 E7 的 `tools/proto/results/capacity_2026-09-06.md` 为准；本表只用来证明**分项统计的实现与口径正确**（正文 = `text_versions`、FTS 单列、WAL 单量、净载荷 = `SUM(byte_len)`）。

**删除与配额的实测**（同一个库，依次执行，出处 `results/delete_*.json`、`results/expire.json`）：

| 操作 | observations | occurrences | text_versions | FTS 行 | 释放字节 |
|---|---:|---:|---:|---:|---:|
| `delete --app com.apple.Safari` | 100（打墓碑） | 100 | 0 | 0 | 0 |
| `delete --object host=docs.internal` | 100（打墓碑） | 100 | 0 | 0 | 0 |
| `delete --range 1757000000000,1757000300000` | 18（打墓碑） | 18 | 6 | 6 | 825 |
| `expire --to-bytes 2000 --batch 20` | 440（**物理删**） | 246 | 82 | 82 | 11,274 |

前两条「删了 100 条观察却一个文本版本都没删掉」正是 3.8 共享版本规则的直接证据：合成流里每 5 条连续观察共享同一段正文，而这 5 条分属 5 个不同应用，所以按应用删或按 host 删都留不下孤儿版本。
`expire` 从 13,238 字节降到 **1,964 字节**（目标 2,000），22 个批次，`warning_threshold_crossed = true`，审计行区间 `ts_from = 1757000000000` / `ts_to = 1757004390000`。
`maintenance()` 随后把主库从 1,196,032 降到 **884,736 字节**（`freelist` 19 → 0，耗时 0.61 ms）。

**FTS 对账**（D22 的显式维护需要它兜底）：人为删掉一条 FTS 行、插入一条孤儿 FTS 行后，13 项检查立刻报错；`maintenance()` 之后 `orphanFTSRowsDeleted = 1`、`missingFTSRowsInserted = 1`，检查全过，补写的行能被查到。

**合成流确定性**：同 seed 两次 `gen-jsonl --count 500 --seed 20260907` 逐字节相同，SHA-256 = `37f91ff7da294a3d077b683e0a1958fa0ff4663420c1615a214fa8d4b575d384`（`results/synth_digest.txt`）。

---

## 8. D16 目录拒绝

三层检查：路径组件名命中已知同步盘（不要求目录已存在）→ 最近的已存在祖先是 iCloud 项（`isUbiquitousItem`）→ 该位置在非本地卷上。

| 传入目录 | 结果 |
|---|---|
| `~/Library/Mobile Documents/com~apple~CloudDocs/…` | 拒绝（「路径里含同步目录『Mobile Documents』」），**目录未被创建** |
| `~/Dropbox/…` | 拒绝（「Dropbox」），目录未被创建 |
| `~/Library/Mobile Documents/com~apple~CloudDocs/brosis-sync/db` | 拒绝——D17 的同步段文件目录可以放**段文件**，但不能放数据库本体 |
| 单元测试另覆盖 | `Google Drive/My Drive`、`OneDrive - <公司>`（前缀匹配）、`Nextcloud`、`坚果云` |
| 允许 | `~/Library/Application Support/com.brosis.app`、构建缓存下的测试目录 |

错误消息里同时给出替代方案（「跨设备共享请用 D17 的加密同步段文件，不要共享数据库本体」）。
出处：`results/directory_reject.txt`、`CryptoAndBuildTests.testRejectsSyncedDirectories`。

数据目录本身：**mode = 700**、`.metadata_never_index` 已写、`isExcludedFromBackup = true`（Time Machine）。
`CSBackupSetItemExcluded` 的 C 函数在 Swift 6 下已不可用，改用它的等价物 `URLResourceValues.isExcludedFromBackup`（写的是同一个 `com.apple.metadata:com_apple_backup_excludeItem` 扩展属性）。

---

## 9. NFKC 折叠的口径：**已定 —— 索引侧折叠，原文不动**（2026-09-07 改）

本节原来是「一个需要你拍板的口径」，本轮已定案并改了实现。结论：**证据必须原样，NFKC 折叠只用于索引。**

**现在的口径**

| 位置 | 存 / 用什么 |
|---|---|
| `text_versions.text` | **原文**，逐字节。`"第一段：标题"` 的全角冒号 U+FF1A 原样保留 |
| `text_versions.sha256` | **原文** UTF-8 字节的 SHA-256（不再是折叠后的） |
| `text_versions.byte_len` | **原文** UTF-8 字节数（配额口径同步跟着走） |
| `text_fts.body` | **NFKC 折叠后再 bigram 化**（`TextPipeline.bigramForIndex`），折叠只到这一列为止 |
| 查询串 | 照旧折叠（`TextPipeline.ftsPhrase` / `foldForIndex`），与索引对齐 |

**去重语义随之改变**：从「折叠后相同就复用」变成「**逐字节相同才复用**」。
同一段内容的全角写法（OCR 常产出）与半角写法（AX 常产出）是**两个** `text_versions` 行。
这是有意的——证据必须原样；代价是这类内容各占一行原文，`text_versions` 行数与
`SUM(byte_len)` 会比折叠入库时略高（1 个月合成库上的实测对比见
`m1_r1_retrieval_ledger_2026-09-07.md` §4）。两行的 FTS 行是**同一串 bigram**，
所以检索侧看不出区别：两种写法的查询互相都能命中。

**折叠一从入库路径拿掉，检索两条通道各要补一处**（否则「全角原文 + 半角查询」会被误杀）：

1. **FTS 通道的子串复核**：第一遍照旧用 SQL `LIKE` 在原文上做（绝大多数候选在这一遍就定了，
   行为与折叠入库那版逐字节相同）；第二遍只捞第一遍没过的候选，把**候选正文现折叠**一遍再比
   （`TextPipeline.indexContains`）。**选它而不是在 `text_versions` 旁存一份折叠副本**——
   副本要多一倍正文存储，与 D21 的容量口径冲突。代价是多一次同 rowid 集合的索引回查
   加上对「没过第一遍」的候选做 NFKC；候选有上限（无过滤 200 / 带过滤 2000），是有界的常数级开销。
2. **1–2 字扫描通道**：它在**原文**上做 `LIKE`。「查询串折叠 / 不折叠各试一次」这个写法试过了，
   **不够**：查 `AB`、正文是 `ＡＢ`，两种写法都不在原文里，`LIKE` 一定落空
   （把 `Store.scanPatterns` 改回这个写法跑 `testScanChannelMatchesFullwidthBodyWithHalfwidthQuery`，
   断言全部落空，日志 `results/ab_naive_two_forms.log`）。
   改成把**查询串展开成兼容区的单标量前像**（`A` → `Ａ` / `ａ`、`:` → `：`/`﹕`/`︓` …）一起 LIKE。
   前像表按「折叠 + 小写」归并——`LIKE` 只对 ASCII 大小写不敏感，`'%ＳＱ%'` 命中不了 `ｓｑ`，
   所以每个字母要展开成 `S` / `Ｓ` / `ｓ` 三种；不归并时实测 `SQ` 从 5 条掉到 3 条。
   **没有选「现折叠正文」**：那是对 7 天窗口里约 34 MiB 正文逐条做 NFKC，
   而这条通道本来就是 3.4 分层目标里最贵的一档（热 p95 122 ms / 目标 150 ms），加不起。

   展开**不是免费的**（这一条是本轮量出来才发现的）：这条通道按定义要扫完整个时间窗，
   代价与模式条数近似成正比。1 个月库上同一条 ASCII 两字查询（`bench --short-queries SQ`，
   命中 10 条、不触发 `LIMIT` 短路）：**1 个 `LIKE` 热 p95 117.4 ms，展开成 9 个 721.0 ms**
   （`results/bench_scan_single.json` vs `bench_scan_expanded.json`）。两条应对：

   - **只在需要时展开**：`Store.hasCompatibilityText` 记录「这个库里写进过折叠会变样的正文吗」，
     写入时顺手记进 `meta.has_compat_text`（折叠本来就要算一次，不额外跑 NFKC），只置位不清位。
     **没有就只发一个 `LIKE`**——纯 AX 来源的库、以及本轮 1 个月合成库都是这一档，**零回归**；
     真有全角正文时 ASCII 短查询付那 6 倍，纯汉字查询任何时候都只有 1 个 `LIKE`
     （`熵` 在兼容区里没有前像），最贵的那一档一点没变。
   - **试过但退回**：把 9 种写法压成一个 `GLOB` 字符类（`*[SsＳｓ][QqＱｑ]*`）想一遍扫完，
     反而更慢——SQLite 的 `GLOB` 走带 UTF-8 逐字符解码的通用匹配器：同一条查询 **605.1 ms**，
     连纯汉字单字 `熵` 都从 122.3 ms 掉到 **398.5 ms**（`results/bench_scan_glob.json`）。

   代价（明写）：只覆盖那几段兼容区的**单标量**前像，连字（`ﬁ` → `fi`）这类一字折多字的写法、
   以及组合数超过 16 的查询串扫描通道仍会漏，由 FTS 通道兜底（那条做的是真折叠，没有这个限制）。

**验收用例**（`core/Tests/BrosisCoreTests/`）：

- `BigramFTSTests.testRawTextIsStoredVerbatimAndHashedByRawBytes`：全角标点 + 全角字母的正文读回逐字节相同，`sha256` == 原文哈希、`byte_len` == 原文字节数；
- `BigramFTSTests.testFullwidthAndHalfwidthAreSeparateVersionsButShareIndexForm`：`"ＳＱＬ 100"` 与 `"SQL 100"` 是两个版本，但 FTS body 相同、两种写法的查询互相都能命中；
- `RetrievalTests.testFTSChannelMatchesFullwidthBodyWithEitherWidth`：半角 / 全角查询都过 FTS 通道的子串复核（`ftsVerified = 1`）；
- `RetrievalTests.testScanChannelMatchesFullwidthBodyWithHalfwidthQuery`：全角原文被半角查询经扫描通道召回。

改动落在 `TextPipeline.swift`、`Store.swift`（`hasCompatibilityText` + `meta.has_compat_text`）、
`Store+Write.swift`、`Store+Maintenance.swift`、`Store+Search.swift`、`Store+Query.swift`、
`Schema.swift`（注释）与 `app/Sources/brosis/SelfCheck.swift`（自检期望值）。
**没有改 schema**：`meta` 是键值表，多一个键不算表结构变更，`Schema.version` 仍是 1。

---

## 10. 未做与原因

| 项 | 原因 |
|---|---|
| `KeychainKeyProvider` **没有实跑** | 读写 data-protection 钥匙串要签名 + entitlement，首次访问会弹钥匙串授权对话框，本轮硬约束禁止触发任何 GUI / 授权弹窗。编译通过、接口按 3.5 写全（`kSecUseDataProtectionKeychain`、`WhenUnlockedThisDeviceOnly`、`SecAccessControl` 绑本应用、`SecRandomCopyBytes` 首次生成）。**实跑归 T4** |
| sqlite-vec **未启用** | D8 未通过。已静态编入并验证能链接（`brosis_vec_version()` 读回 `v0.1.9`），但不注册 `sqlite3_auto_extension`、不建 `vec0` 表 |
| 三通道 `search`、会话化、日台账、MCP | 归 T3。本包只提供 FTS 写入口径与 `searchFTS` / `evidenceText` / `contextTexts` / `dayLedgerTexts` 四个最小读接口，供自测与 T3 复用 |
| 多连接并发 | 没测。本包是单连接、单写者、一把 `NSLock` 串行（评审 F1 / 3.1 要求单一存储服务持钥）。读写并发与 `busy_timeout` 的行为留给 M2 按实测决定，E6 §11 也把它列为遗留项 |
| 加密写入开销、开库延迟等性能数字 | 没重测。E6 已在同一构建路线上实测（写入 1.542×、原始密钥开库 p50 0.526 ms），本轮只验正确性。真实规模的延迟归 T3 的 1 / 3 / 12 个月合成库 |
| `cipher_memory_security` 只验证「能开、库照常可用」 | 它必须在进程第一次分配加密上下文之前设置，单个测试进程里没法干净地对照。开销数字用 E6 的 1.38×。T4 要把它放在存储服务启动的最早一步 |
| 缩略图加密 | D10：缩略图默认关，本包只负责删除时清理文件与对账，不生成、不加密 |

---

## 11. 对计划的影响

**一句话：3.2 / 3.5 / 3.8 / 3.12 的存储层按 D16 / D17 / D22 / D23 / D25 全部落地并在加密库上通过 E3 七场景，计划文本只需两处校正——连接序言里 `auto_vacuum` 必须排在 `journal_mode` 之前（3.5 现在的写法未指明相对顺序），以及 3.8「默认 5 GB 配额」与 D7 / E9 复测里用的 10 GiB 不一致（本包按 10 GiB 实现，请统一口径）。**

其余需要你知道但不改计划的一点：`core/` 因为要关上游 68 条噪声 warning 用了 `.unsafeFlags`，所以只能被本地路径依赖引用（`app/` 正是这么用）。
