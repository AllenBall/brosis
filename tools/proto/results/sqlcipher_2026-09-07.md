# T8 / E6：SQLCipher 构建与密钥、数据边界验证（2026-09-07）

对应 `docs/实施计划.md` 的 **4.1 E6**、**3.2 数据模型**、**3.4 检索设计**、**3.5 密钥与锁定状态机**、**D22**（contentless FTS + bigram）、**D23**（page_size 16384、sha256 存 BLOB），以及 `docs/调研方案评审.md` 的 **F1**（单一存储服务持钥）。

本机：M4 Max 128 GB / macOS 26.6 / Xcode 26.6 / Swift 6.3.3。**单位口径：MB / GB 一律按 2^20 / 2^30，写作 MiB / GiB；延迟是 wall clock（`CLOCK_UPTIME_RAW`），查询延迟都是热态（前 10 次预热不计）。**

代码与复现：`tools/proto/sqlcipher/`（`sh setup.sh` 一次，然后 `sh run.sh`）。原始数据：`tools/proto/results/sqlcipher_2026-09-07.json`。

## 0. 结论（一页）

1. **推荐路线 b：自带 SQLCipher 4.18.0 community 源码作 SwiftPM 的 C 目标，crypto 后端用 Apple CommonCrypto。** 同样的 schema、同样的 2 万条语料，写入比路线 a 快 **2.83 倍**，加密相对明文的开销从 **4.447×** 降到 **1.542×**。根因是 crypto 后端：路线 a 用的社区包把 LibTomCrypt 编了进去（纯 C 软件实现），路线 b 用 CommonCrypto，走 Apple Silicon 的 AES 硬件指令。

2. **T8 要求的四个编译开关全部到位**，两条路线都是：`SQLITE_ENABLE_FTS5`、`SQLITE_ENABLE_DBSTAT_VTAB`、`SQLITE_HAS_CODEC`、`SQLITE_TEMP_STORE=2`；底层 SQLite 路线 a 是 3.53.0、路线 b 是 3.53.4，都 ≥ 3.43，`contentless_delete=1` 实测可用。

3. **sqlite-vec v0.1.9 能作为同一包内的 C 目标静态编入**，用 `sqlite3_auto_extension` 注册后每条新连接自带 `vec0`；`int8[512]` 表建得起来、KNN 查得动，2 万条向量上自查召回 50/50。

4. **加密库没有明文泄漏**：数据库文件、`-wal`（未 checkpoint 时 23.83 MiB 的脏 WAL）、`-shm` 三个文件里，四个明文金丝雀一次都没出现；同 schema 的明文库在同一把尺子下命中 78,435 次，说明检查器不是空转。

5. **但 `temp_store` 一旦是 FILE，明文就会整段落到磁盘。** 用统计型 VFS 垫片在系统调用层实测：`PRAGMA temp_store = FILE` 时一次全表排序写出 22.64 MiB 临时文件，里面命中金丝雀 **73,494 次**；`temp_store = MEMORY` 时临时文件 `xOpen` 次数为 **0**、写出字节为 **0**、命中 **0**。**v1 应该直接用 `SQLITE_TEMP_STORE=3` 编译**（编译期强制内存，`PRAGMA` 改不了），而不是靠每条连接记得设 `PRAGMA temp_store = MEMORY`。

6. **原始密钥确实跳过 PBKDF2**：256 位原始密钥开库并完成校验，路线 b p50 **0.526 ms**（路线 a 2.046 ms）；同一台机器上用口令密钥开库要 **78.357 ms**（路线 a 201.09 ms），差两个数量级。锁定状态机（开库 → 写 → 查 → 关库并清零密钥 → 再开库）20 轮全通过。

7. **错误密钥必须失败**：换一个字节的密钥、以及完全不给密钥，两种情况都是 `SQLITE_NOTADB (26) file is not a database`；失败的解锁尝试之后，正确密钥仍能正常打开，库没被写坏。

8. **DuckDuckGo 的 GRDB fork 不能用**：`duckduckgo/GRDB.swift` 最新 tag `v6.6.0` 的最后一次提交是 2022-12-29，`Package.swift` 里根本没有 SQLCipher 目标（`CSQLite` 是 `systemLibrary`，链系统 SQLite）。SQLCipher 在它的 `SQLCipher` / `SQLCipher-source` 分支上，没有打 tag，SPM 也没法按版本解析。详见 §2。

## 1. 两条路线的构建方式

| | 路线 a（社区 SwiftPM 包） | 路线 b（自带源码作 C 目标）**推荐** |
|---|---|---|
| 来源 | `skiptools/swift-sqlcipher`，pin `exact: "1.9.0"` | `github.com/sqlcipher/sqlcipher` tag `v4.18.0`，`./configure --disable-tcl && make sqlite3.c` 生成 amalgamation |
| SQLCipher 版本 | 4.15.0 community | 4.18.0 community |
| 底层 SQLite | 3.53.0 | 3.53.4 |
| crypto 后端 | libtomcrypt 1.18.2-develop（包内自带 491 个 .c） | commoncrypto 61901.160.44（系统库，走 AES 硬件指令） |
| 维护状态 | 活跃：最后一次提交 2026-04-28，有 GitHub Action 每次自动追 SQLCipher 上游新 tag | 上游本体，v4.18.0 提交于 2026-08-14 |
| 编译开关可控性 | 用 SwiftPM traits 暴露约 25 个开关；但 `SQLITE_TEMP_STORE`、`SECURE_DELETE`、crypto 后端等写死在包里，**改不了**（要改只能 fork） | 全部开关都在我们自己的 `Package.swift` 的 `cSettings` 里，想加 `SQLITE_TEMP_STORE=3` 就加 |
| 项目目录占用 | 0（SPM 依赖，落在 `.build/checkouts`） | 0（`RouteB/SQLCipher` 是指向构建缓存的符号链接） |
| 与 GRDB 的配合 | 需要让 GRDB 用这个包的 `SQLCipher` 模块，官方 GRDB 不支持这种组合 | 同上，需要自定义 GRDB 构建（见 §8） |
| 供应链 | 多一个第三方中间人；LibTomCrypt 1.18.2-develop 也一起进了二进制 | 只信任 SQLCipher 上游 + Apple 系统库，源码 SHA-256 可固定 |

两条路线都实际构建并跑通了。下面所有数字都是同一批语料、同一套 schema、release 构建（`-O2`）。

## 2. 查过但没采用的方案

| 候选 | 结论 |
|---|---|
| `duckduckgo/GRDB.swift` | **不可用**。最新 tag `v6.6.0`，最后提交 2022-12-29（三年多没动），且该 tag 的 `Package.swift` 里 `CSQLite` 是 `.systemLibrary`，没有任何 SQLCipher 目标。SQLCipher 相关内容在未打 tag 的 `SQLCipher` / `SQLCipher-source` 分支上，SPM 无法按版本固定。 |
| `groue/GRDB.swift`（官方，v7.11.1） | 本身不带 SQLCipher。官方只在 CocoaPods 的 `GRDB.swift/SQLCipher` subspec 里支持，SPM 路径要自己拼一个「自定义 SQLite 构建」。可以做，但 SQLCipher 从哪来仍然要在 a / b 里选，所以这不是第三条路线。 |
| 系统自带 SQLite | 不带 codec，且版本随 macOS 走。真源必须是我们自己编的那份。 |

## 3. 编译开关与版本核对

| 检查项 | 路线 a | 路线 b | 要求 |
|---|---|---|---|
| `SQLITE_ENABLE_FTS5` | 是 | 是 | 必须 |
| `SQLITE_ENABLE_DBSTAT_VTAB` | 是 | 是 | 必须 |
| `SQLITE_HAS_CODEC` | 是 | 是 | 必须 |
| `SQLITE_TEMP_STORE` | TEMP_STORE=2 | TEMP_STORE=2 | 2 或 3（见 §6 的建议：v1 用 3） |
| SQLite 版本 | 3.53.0 | 3.53.4 | ≥ 3.43（`contentless_delete`） |
| sqlite-vec | v0.1.9 | v0.1.9 | 固定版本，静态编入 |

路线 b 的完整开关列表见 `tools/proto/sqlcipher/Package.swift` 的 `routeBCipherSettings`。其余开关（`SQLITE_DQS=0`、`SECURE_DELETE`、`ENABLE_COLUMN_METADATA`、`ENABLE_PREUPDATE_HOOK`、`ENABLE_SNAPSHOT`、`ENABLE_STAT4` 等）是对齐路线 a 的默认 trait 集设的，目的是让两条路线的对比只反映 crypto 后端与版本差异。

`PRAGMA cipher_settings`（两条路线一致）：

```text
PRAGMA kdf_iter = 256000;
PRAGMA cipher_page_size = 4096;
PRAGMA cipher_use_hmac = 1;
PRAGMA cipher_plaintext_header_size = 0;
PRAGMA cipher_hmac_algorithm = HMAC_SHA512;
PRAGMA cipher_kdf_algorithm = PBKDF2_HMAC_SHA512;
```

`PRAGMA cipher_memory_security` 默认 **0**（关）。打开的效果见 §9。

## 4. 负载与 schema

- 2 万条中英混排正文，确定性生成（SplitMix64，seed `20260907`），平均每条 1153 字节 UTF-8，合计 21.99 MiB；bigram 预处理后平均 2122 字节。
- 表：`apps` / `windows` / `urls` / `observations` / `text_versions` / `occurrences` / `sessions`（计划 3.2 的核心子集，主键带 `device_id`）。
- FTS：`CREATE VIRTUAL TABLE text_fts USING fts5(text, content='', contentless_delete=1, tokenize='unicode61')`，**没有触发器**，写入 / 删除由代码显式做（D22）。写进 FTS 的是 Swift 侧 bigram 化后的文本。
- 向量：`CREATE VIRTUAL TABLE vec_text USING vec0(text_rowid INTEGER PRIMARY KEY, embedding int8[512])`，2 万条 int8[512]。
- 页大小 16384（D23），`journal_mode=WAL`、`auto_vacuum=INCREMENTAL`、`secure_delete=ON`、`foreign_keys=ON`。

成品库分项（`dbstat`，路线 b 加密库，2 万条 + WAL 阶段追加的 500 条）：

| 段 | 字节 | MiB | 页数 |
|---|---:|---:|---:|
| `text_versions` | 26,181,632 | 24.97 | 1598 |
| `text_fts_data` | 19,546,112 | 18.64 | 1193 |
| `vec_text_vector_chunks00` | 10,567,680 | 10.08 | 645 |
| `observations` | 1,163,264 | 1.11 | 71 |
| `sqlite_autoindex_text_versions_2` | 1,146,880 | 1.09 | 70 |
| `occurrences` | 557,056 | 0.53 | 34 |
| `sqlite_autoindex_text_versions_1` | 491,520 | 0.47 | 30 |
| `sqlite_autoindex_occurrences_2` | 491,520 | 0.47 | 30 |
| `sqlite_autoindex_observations_1` | 491,520 | 0.47 | 30 |
| `sqlite_autoindex_occurrences_1` | 475,136 | 0.45 | 29 |
| **文件总计** | 64,126,976 | 61.16 | 3914 |

加密库 61.16 MiB vs 明文库 60.97 MiB，比值 **1.0031×**——SQLCipher 的额外开销只是每页 16 字节 IV + 64 字节 HMAC，在 16 KiB 页上可以忽略。

## 5. 加密开销：明文 vs 加密

### 5.1 写入 2 万条

| | 明文 | 加密 | 倍数 |
|---|---:|---:|---:|
| 路线 a（LibTomCrypt） | 1303.206 ms（15346.8 行/s） | 5795.901 ms（3450.7 行/s） | **4.447×** |
| 路线 b（CommonCrypto） | 1330.129 ms（15036.1 行/s） | 2050.799 ms（9752.3 行/s） | **1.542×** |

口径：语料（正文、bigram、SHA-256、向量）在两次写入之前一次性生成好放在内存里，所以这里的差值只包含 SQLite 写入 + 加解密，不含文本处理。每 1000 条一个事务。

### 5.2 查询（各 100 次，热态 p50 / p95，毫秒）

| 查询 | 路线 a 明文 | 路线 a 加密 | 路线 b 明文 | 路线 b 加密 |
|---|---:|---:|---:|---:|
| FTS `MATCH`（bigram phrase，rowid 倒序取 10） | 0.069 / 0.088 | 1.603 / 1.954 | 0.069 / 0.082 | 0.299 / 0.38 |
| 精确字段两步式（host → observations） | 0.016 / 0.018 | 0.016 / 0.018 | 0.016 / 0.017 | 0.016 / 0.018 |
| `sessions` 区间（带 start 下界） | 0.002 / 0.002 | 0.002 / 0.002 | 0.002 / 0.002 | 0.002 / 0.002 |
| `vec0` KNN top-10（默认 2 MiB 缓存） | 4.116 / 4.352 | 55.536 / 56.39 | 4.131 / 4.306 | 11.416 / 12.203 |
| `vec0` KNN top-10（128 MiB 缓存） | 4.093 / 4.358 | 3.867 / 4.065 | 4.128 / 4.336 | 3.895 / 4.08 |
| FTS `MATCH`（128 MiB 缓存） | 0.067 / 0.111 | 0.627 / 1.692 | 0.066 / 0.095 | 0.139 / 0.318 |
| `dbstat` 全表分项（1 次） | 6.788 | 315.059 | 6.612 | 48.104 |

三点解读：

1. **索引命中的小查询几乎不受加密影响**：精确字段两步式和 `sessions` 区间在加密与明文之间没有可测差异——它们只碰几页，解密成本被淹没在其他开销里。
2. **扫描型查询的加密开销 = 重复解密**。`vec0` KNN 是暴力扫 10.08 MiB 的向量分块，默认 2 MiB 页缓存装不下，于是每次查询都要把这 10 MiB 重新读盘 + 解密。把 `cache_size` 放大到 128 MiB 后，路线 b 加密态 KNN 从 11.416 ms 降到 3.895 ms，和明文的 4.128 ms 基本持平。**M1 的存储服务应该把页缓存配大（建议 ≥ 128 MiB），这比换 crypto 后端还管用。**
3. **crypto 后端的差距很实在**：同样是加密态、同样默认缓存，路线 b 的 KNN 是 11.416 ms，路线 a 是 55.536 ms；FTS 是 0.299 ms vs 1.603 ms。`dbstat` 全表分项 48.104 ms vs 315.059 ms。

## 6. 无明文泄漏

### 6.1 方法

每一条正文里都埋了四个「金丝雀」：`BROSISLEAKCANARY7F3A2D`、`饕餮鑫垚焱淼`、`饕餮`、`会议纪要`。检查分两层：

1. **逐字节扫文件**：把 `.db`、`-wal`、`-shm` 和临时目录里的每个文件整个读进内存，找这四个字节串。
2. **统计型 VFS 垫片**（`tools/proto/sqlcipher/Sources/CBrosisShim/shim.c`）：在 SQLite 和真实 VFS 之间插一层，记录每一次 `xOpen` 的文件类别，并在每一次 `xWrite` 里扫描缓冲区。这比事后 grep 强，因为 SQLite 的排序临时文件是 `DELETEONCLOSE` 的——建完立刻 unlink，事后去目录里根本看不到，只有在系统调用这一层才抓得住。

为什么不用 `fs_usage`：它要 root，会触发授权弹窗，M0 阶段不引入。`statvfs` 口径也一并采了（排序期间每 0.5 ms 采一次临时目录所在卷的可用字节，取最大回落），结果和 VFS 垫片一致，见下表。

### 6.2 结果（路线 b；路线 a 完全一致）

| 检查点 | 文件大小 | 金丝雀命中 |
|---|---:|---:|
| 加密库 `.db`（WAL 未 checkpoint） | 58.52 MiB | **0** |
| 加密库 `-wal`（未 checkpoint） | 23.83 MiB | **0** |
| 加密库 `-shm`（未 checkpoint） | 0.03 MiB | **0** |
| 加密库 `.db`（checkpoint + 关库后） | 61.16 MiB | **0** |
| 加密库 `-wal`（checkpoint + 关库后） | 0.00 MiB | **0** |
| 临时目录（跑完全部实验后） | 0 个文件 | **0** |

阳性对照——同 schema、同语料的**明文**库：

| 检查点 | 文件大小 | 金丝雀命中 |
|---|---:|---:|
| 明文库 `.db`（WAL 未 checkpoint） | 58.38 MiB | 68,180 |
| 明文库 `-wal`（未 checkpoint） | 23.86 MiB | 10,255 |
| 明文库 `.db`（关库后） | 60.97 MiB | 73,547 |

命令行交叉复核（`run.sh` 里跑）：`strings -a enc.db | grep -c BROSISLEAKCANARY7F3A2D` = 0，同一命令对 `plain.db` 有上万行命中。

### 6.3 排序落盘：这是真实的泄漏面

在加密库上跑一次必须排序的全表扫描（`SELECT count(*) FROM (SELECT text FROM text_versions ORDER BY text)`，约 22 MiB 待排数据，`cache_size` 压到 1 MiB）：

| `PRAGMA temp_store` | 临时文件 `xOpen` 次数 | 临时文件写出字节 | 其中金丝雀命中 | statvfs 最大回落 | 排序耗时 |
|---|---:|---:|---:|---:|---:|
| `MEMORY`（= 编译期默认） | 0 | 0（0 MiB） | **0** | 0 MiB | 29.645 ms |
| `FILE`（人为改回文件） | 1 | 23,739,278（22.64 MiB） | **73,494** | 22.64 MiB | 74.821 ms |

**这是 T8 最重要的一条结论**：SQLCipher 的 codec 挂在 pager / btree 上，只管数据库页；`vdbesort` 溢出用的临时文件走的是另一条路径（`sqlite3OsOpenMalloc` + `SQLITE_OPEN_TEMP_JOURNAL | DELETEONCLOSE`），**不经过 codec，写的是明文**。22.64 MiB 的排序溢出文件里能直接找到 73,494 次金丝雀。

因为 `SQLITE_TEMP_STORE=2` 的语义是「默认内存，但 `PRAGMA` 可以改回文件」（源码：`sqlite3TempInMemory()` 返回 `db->temp_store != 1`），**任何一处误写 `PRAGMA temp_store = FILE`（或某个库替我们写）都会把这条泄漏面打开**。

→ **建议 v1 直接用 `SQLITE_TEMP_STORE=3` 编译**（编译期强制内存，`PRAGMA` 无法覆盖）。代价是超大排序会吃内存而不是磁盘，但 brosis 的查询都带时间 / 应用限定，真正的全表排序只出现在夜间任务，可以在那里显式分批。路线 b 改这个开关只要动 `Package.swift` 一行；**路线 a 改不了**（写死在依赖包里），这也是推荐 b 的一条硬理由。

## 7. 密钥、错误密钥与锁定状态机

### 7.1 原始密钥 vs 口令

解锁流程（`Probe.openUnlocked`，对应 3.5 的 `unlocking`）：

```text
sqlite3_open_v2(path, READWRITE)
PRAGMA key = "x'<64 位十六进制>'";      -- 256 位原始密钥，跳过 PBKDF2
PRAGMA cipher_page_size = 16384;         -- 必须！见下面的坑
SELECT count(*) FROM sqlite_schema;      -- 真读一次，密钥错在这里才会暴露
```

| | 路线 a | 路线 b |
|---|---:|---:|
| 原始密钥开库 + 校验 p50 / p95 | 2.046 / 2.17 ms | **0.526 / 0.646 ms** |
| 口令密钥开库 p50（kdf_iter = 256000） | 201.09 ms | 78.357 ms |
| 倍数 | 98× | 149× |

结论：**原始密钥的毫秒级开库让 3.5 的锁定状态机是可行的**——睡眠关库、唤醒开库不会让人等。如果退回口令派生，每次唤醒要多花 80–200 ms，屏幕解锁后的第一次 MCP 调用会有肉眼可见的迟滞。

**踩到的坑（M1 必须写进存储服务）**：`cipher_page_size` 不写进文件头。用 16384 建的库，如果新连接只 `PRAGMA key` 不重设 `cipher_page_size`，SQLCipher 会按默认的 4096 去解第一页，直接报 `file is not a database`——和密钥错误的报错一模一样，很容易误判成「库坏了」。**每一条连接都必须按 key → cipher_page_size → 首次读 的顺序来。**

### 7.2 错误密钥

| 场景 | 返回码 | 消息 | 是否如预期失败 |
|---|---|---|---|
| 密钥错一个字节 | `SQLITE_NOTADB`（26） | `file is not a database` | 是 |
| 完全不给密钥 | `SQLITE_NOTADB`（26） | `file is not a database` | 是 |
| 之后再用正确密钥 | — | 读到 20,520 条 observations | 失败的解锁没有破坏库 |

### 7.3 锁定状态机原型

20 轮 `open → 写 → 查 → close + 密钥清零 → 再 open`（路线 b，毫秒，p50 / p95）：

| 阶段 | p50 | p95 |
|---|---:|---:|
| `unlocking`：开库 + 校验 | 0.526 | 0.646 |
| `unlocked`：一次写入 + 提交 | 0.439 | 0.616 |
| `unlocked`：一次 FTS 查询 | 0.457 | 0.544 |
| `locking`：checkpoint + 关库 | 0.417 | 0.559 |

- 密钥缓冲区每轮都用 volatile 写清零并复查全 0：**是**。清零的不只是密钥字节，还包括拼出来的 `PRAGMA key = "x'...'"` SQL 缓冲区（否则十六进制密钥会留在堆上）。
- 清零之后重新取钥开库：**是**。
- 一整轮 `locking → unlocking` 加起来 < 1 ms，说明 D4 的「睡眠即关库、唤醒即开库」不需要额外的取舍。

## 8. FTS5、sqlite-vec、dbstat 的功能验证

- **contentless + `contentless_delete=1` 建表成功**，`unicode61` 分词。显式 `DELETE FROM text_fts WHERE rowid = ?` 返回 `not an error`，删除前 `MATCH 'docid9999'` 命中 1 条、删除后 0 条 → **是**。这验证了 D22 的「FTS 用 contentless + 存储服务显式删除」可行。
- FTS5 `'integrity-check'` 通过。
- **sqlite-vec v0.1.9** 用 `sqlite3_auto_extension(sqlite3_vec_init)` 注册，`SELECT vec_version()` 可用；`vec0(text_rowid INTEGER PRIMARY KEY, embedding int8[512])` 建表成功。写入时必须写 `vec_int8(?)`——直接绑一个 512 字节 BLOB 会被当成 float32 向量而报错，查询侧 `MATCH vec_int8(?)` 同理。
- KNN 自查：取第 i 条自己的向量做查询，top-1 应当是自己，50 个抽样 **50/50** 命中。
- `dbstat` 虚表可用，一次全库分项 48.104 ms（加密）/ 6.612 ms（明文）。E7 的容量口径可以直接搬到加密库上。

## 9. `cipher_memory_security`

默认值 `0`（关）。用 `PRAGMA cipher_memory_security = ON` 打开后（返回码 0，读回 `1`）：

对照那一轮的行数、语料、seed 与主实验完全一致，只有锁定状态机轮数从 20 减到 5。

| | 关（默认） | 开 |
|---|---:|---:|
| 写入 2 万条 | 2050.799 ms | 2835.688 ms |
| FTS `MATCH` p50 | 0.299 ms | 0.748 ms |
| `vec0` KNN p50 | 11.416 ms | 13.161 ms |
| 开库 p50 | 0.526 ms | 0.815 ms |

写入慢了 **1.38×**。

它做的事是：给 SQLCipher 自己的分配器加上 `mlock`（阻止换页到 swap）和释放前清零。**建议 v1 打开**：brosis 的库里装的是你全部的屏幕内容，「解密后的页不会被写进 swap」是这条数据链上少数几个能真正兑现的承诺之一，而代价在上表里是可接受的。注意它必须在进程里第一次分配加密上下文之前设置，所以要放在存储服务启动的最早一步，不能等到开库时才设。

## 10. 给 M1 的接入建议

1. **构建**：把 `tools/proto/sqlcipher/setup.sh` 的取源 + `make sqlite3.c` 固化成一个构建步骤，amalgamation 的 SHA-256 写进仓库（本次：`sqlite3.c` = `964c72bd…`，`sqlite-vec.c` = `ba081a47…`），生成物本身不进 iCloud 目录。C 目标的 `cSettings` 直接抄 `Package.swift` 的 `routeBCipherSettings`，**但把 `SQLITE_TEMP_STORE` 改成 3**。
2. **必须显式给 `-DNDEBUG`**。amalgamation 里有一段「没定义 `SQLITE_DEBUG` 就自动 `#define NDEBUG`」，但 SwiftPM 的 C 目标是带 `-fmodules` 编的，`crypto_cc.c` 里 `#include <CommonCrypto/…>` 会触发 framework 模块导入，`assert` 宏按模块构建时的状态重新生效，那段自动 `NDEBUG` 就失效了，于是 `SQLITE_DEBUG`-only 的 assert 辅助函数变成「未声明函数」直接编译失败。（路线 a 用 LibTomCrypt、不引 framework，所以躲过了这个问题。）
3. **GRDB 的接法**：官方 GRDB 只在 CocoaPods 里支持 SQLCipher。SPM 下的做法是让 GRDB 依赖我们的 `SQLCipher` C 目标而不是系统 SQLite——把 GRDB 源码作为一个本地 target 纳入我们自己的包，`GRDB` target 依赖 `SQLCipher`，并给它 `-DSQLITE_HAS_CODEC` 和 `GRDBCIPHER` 之类的条件编译。要用到的 GRDB 特性（`ValueObservation`）需要 `SQLITE_ENABLE_PREUPDATE_HOOK`，`Database.columnInfo` 之类需要 `SQLITE_ENABLE_COLUMN_METADATA`——两个开关本次都已经打开验证过。**如果 M1 不想背这个集成成本，也可以先不上 GRDB**：本次的探针只用裸 C API 就跑通了全部功能，存储服务本来就是单点持钥、接口收敛的，直接写一层薄封装（`DB.swift` 那 150 行）是可行的备选。
4. **每条连接的固定序言**（顺序不能变）：

```text
PRAGMA key = "x'…'";
PRAGMA cipher_page_size = 16384;   -- 不设会报 file is not a database
SELECT count(*) FROM sqlite_schema;
PRAGMA foreign_keys = ON;          -- 连接级，每次都要
PRAGMA secure_delete = ON;         -- 连接级，每次都要
PRAGMA busy_timeout = 5000;
PRAGMA cache_size = -131072;       -- 128 MiB，见 §5.2 第 2 点
```

   建库那一次还要在建第一张表之前加 `PRAGMA auto_vacuum = INCREMENTAL;` 和 `PRAGMA journal_mode = WAL;`。
5. **进程启动最早一步**：`PRAGMA cipher_memory_security = ON`（§9），以及 `sqlite3_auto_extension(sqlite3_vec_init)`。
6. **密钥生命周期**：密钥字节和拼出来的 `PRAGMA key` SQL 都要在用完后 volatile 清零；本次原型的做法在 `DB.swift` 的 `SecureKey` 里，M1 直接搬。

## 11. 没做的和遗留项

- **iCloud 钥匙串可同步项在 Developer ID 签名下是否可用**（E6 的另一半，3.9 的密钥交换）本次没有验证：那要真的签名并运行一个带 keychain-access-groups entitlement 的 app，会触发钥匙串授权弹窗，M0 的这一轮约束里不做。留给 T? / M1。
- **本次密钥是固定字节的桩**，不是 `SecRandomCopyBytes` + data-protection 钥匙串。真正的取钥路径（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + ACL 限定签名）在 M1 存储服务里做。
- **没测多连接并发**。存储服务是单点持钥、单写者，但读连接可能有多个，`busy_timeout` 与 WAL 下的读写并发要在 M1 补一轮。
- **没测崩溃恢复**（E3 已经在明文库上做过 `kill -9`），加密库的 WAL 恢复路径值得在 M1 复跑一次 E3 的脚本。
- **`cipher_plaintext_header_size`** 保持 0。如果以后要让备份工具识别文件类型可以调，v1 不需要。

