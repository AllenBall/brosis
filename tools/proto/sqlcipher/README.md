# tools/proto/sqlcipher — T8 / E6：SQLCipher 构建与密钥、数据边界验证

对应 `docs/实施计划.md` 的 **4.1 E6**、**3.2**、**3.4**、**3.5**、**D22**、**D23**，
以及 `docs/调研方案评审.md` 的 **F1**（解锁期间由单一存储服务持钥）。

实测结果：`tools/proto/results/sqlcipher_2026-09-07.md`（结论 + 数字）与同名 `.json`（原始数据）。

---

## 结论先说

**推荐路线 b：自带 SQLCipher 源码（`v4.18.0`）作 SwiftPM 的 C 目标，crypto 后端用 Apple CommonCrypto。**

| | 路线 a `skiptools/swift-sqlcipher` 1.9.0 | 路线 b 自带 amalgamation |
|---|---|---|
| SQLCipher / SQLite | 4.15.0 / 3.53.0 | **4.18.0 / 3.53.4** |
| crypto 后端 | LibTomCrypt 1.18.2（纯软件） | **CommonCrypto（AES 硬件指令）** |
| 2 万条写入（加密） | 5796 ms（明文的 4.45×） | **2051 ms（明文的 1.54×）** |
| 原始密钥开库 p50 | 2.05 ms | **0.53 ms** |
| `vec0` KNN p50（默认缓存） | 55.5 ms | **11.4 ms** |
| 能不能改 `SQLITE_TEMP_STORE=3` | **不能**（写死在依赖包里） | 能，改 `Package.swift` 一行 |
| 维护状态 | 活跃（2026-04-28，有自动追上游的 CI） | 上游本体（2026-08-14） |

路线 a 不是不能用——它构建最省事、开关有 SwiftPM traits 可调、包本身维护得不错，
作为**备选**保留。但两条硬伤决定了它当不了 v1 主路径：
crypto 后端锁死在 LibTomCrypt（性能差 2–5 倍），
以及 `SQLITE_TEMP_STORE` 改不了（而 T8 实测证明这个开关直接关系到明文会不会落盘，见结果文档 §6.3）。

`duckduckgo/GRDB.swift` 查过了，**不可用**：最新 tag `v6.6.0` 停在 2022-12-29，
该 tag 的 `Package.swift` 里 `CSQLite` 是 `.systemLibrary`，根本没有 SQLCipher 目标；
SQLCipher 的内容在未打 tag 的 `SQLCipher` / `SQLCipher-source` 分支上，SPM 无法按版本固定。

---

## 怎么跑

```sh
cd "<项目目录>/tools/proto/sqlcipher"

sh setup.sh          # 只需一次：取源码、生成 amalgamation、建符号链接
sh run.sh            # 两条路线各跑一遍 2 万条，再跑一次 memory_security 对照，最后生成报告
sh run.sh 50000      # 换规模

# 单独跑一条路线
BROSIS_SQLCIPHER_ROUTE=b swift build -c release \
    --scratch-path ~/Library/Caches/brosis-build/sqlcipher/scratch-b
BROSIS_SQLCIPHER_ROUTE=b ~/Library/Caches/brosis-build/sqlcipher/scratch-b/release/SQLCipherProbe \
    --rows 20000 --reps 100 --opens 20 \
    --work ~/Library/Caches/brosis-build/sqlcipher/run/route-b \
    --out  ~/Library/Caches/brosis-build/sqlcipher/run/route-b.json
```

**必须用 `-c release`。** debug 配置下 C 目标是 `-O0` 编的，SQLite 会慢 2–3 倍，
明文 / 加密的对比全部失真。

探针参数：`--rows`（正文条数）、`--reps`（每类查询次数）、`--opens`（锁定状态机轮数）、
`--seed`、`--work`（工作目录）、`--out`（JSON 路径）、`--memsec`（开 `cipher_memory_security`）。

### 产物落在哪

项目目录里只有源码（144 KiB）和两个符号链接。其余全部在
`~/Library/Caches/brosis-build/sqlcipher/`：

```text
vendor/route-b/src/sqlite3.c            SQLCipher 4.18.0 amalgamation（9.30 MiB）
vendor/route-b/src/sqlite3ext.h         私有头，不能进 publicHeadersPath（见下）
vendor/route-b/include/sqlite3.h        公共头
vendor/sqlite-vec-target/sqlite-vec.c   sqlite-vec v0.1.9
vendor/sqlite-vec-target/include/sqlite-vec.h
work/sqlcipher-src/                     configure 过的 sqlcipher 源码树
scratch-a/ scratch-b/                   SwiftPM 构建目录
run/route-{a,b,b-memsec}/               数据库、WAL、临时目录
run/route-{a,b,b-memsec}.json           探针原始输出
```

固定版本与校验（`setup.sh` 每次都打印）：

| 文件 | SHA-256 |
|---|---|
| `sqlite3.c`（SQLCipher v4.18.0 amalgamation） | `964c72bd1d3e031862588202e2bf6342d36ec68a2cae4f4276d9cd79e6571acb` |
| `sqlite-vec.c`（v0.1.9） | `ba081a47fa02eadc3cf6b16c314b695b84081269349aac722b4efa338fe8fd85` |

---

## 包结构

```text
Package.swift            按 BROSIS_SQLCIPHER_ROUTE 选路线；两条路线都把模块名暴露为 SQLCipher
Package.resolved         路线 a 的依赖 pin（swift-sqlcipher 1.9.0 / cf5c89ad）
setup.sh                 取源码、生成 amalgamation、建符号链接
run.sh                   构建 + 跑两条路线 + memsec 对照 + strings 交叉复核 + 生成报告
render_report.py         把三份 JSON 拼成 results/sqlcipher_<日期>.md / .json（只用标准库）
Sources/
  SQLCipherProbe/        探针（Swift）
    main.swift           入口
    Probe.swift          全部实验：建库、灌数据、查询、泄漏扫描、锁定状态机、错误密钥
    DB.swift             SQLite 薄封装 + SecureKey（可清零的原始密钥）
    Schema.swift         3.2 核心表子集 + contentless FTS + vec0
    Corpus.swift         确定性中英混排语料 + D22 的 bigram 预处理 + int8 向量
    Support.swift        计时、百分位、SplitMix64、字节串搜索
  CBrosisShim/           统计型 VFS 垫片（C）+ sqlite-vec 注册 + volatile 清零
  CSqliteVec  -> 符号链接到 vendor/sqlite-vec-target
RouteB/
  SQLCipher   -> 符号链接到 vendor/route-b
```

### 为什么用符号链接

项目目录在 iCloud Drive 里，不放 9.3 MiB 的 amalgamation 和上千个小文件。
SwiftPM 的 target `path` 必须在包目录内，但**实测它接受指向包外的符号链接**
（`swift build` 正常编译符号链接目录下的 C 源文件），所以真正的源码留在构建缓存里，
包里只有两个符号链接。`setup.sh` 负责建链接，换机器重跑一次即可。

### 为什么 Swift 侧不 import CSqliteVec

`sqlite-vec.h` 在未定义 `SQLITE_CORE` 时会走 `#include "sqlite3ext.h"` 分支，
而 `sqlite3ext.h` 会把所有 `sqlite3_*` 宏重定义成 `sqlite3_api->*`。
C 目标的 `cSettings` 不会传播给依赖它的 Swift 目标，所以一旦 Swift 直接 `import CSqliteVec`
就会踩到这个分支。做法是：注册动作 `brosis_register_vec()` 放在 `CBrosisShim`（定义了 `SQLITE_CORE` 的 C 目标）里，
Swift 只 `import CBrosisShim`。同理，`sqlite3ext.h` 不放进 `publicHeadersPath`，只放在私有的 `src/`。

### VFS 垫片在做什么

`Sources/CBrosisShim/shim.c` 在 SQLite 和真实 unix VFS 之间插一层，转发全部 `sqlite3_io_methods`
（iVersion 3，含 shm 和 mmap），同时：

- 按文件类别（main db / journal / WAL / temp db / temp journal / transient db / subjournal）统计 `xOpen` 次数、`xWrite` 次数与字节数；
- 在每一次 `xWrite` 里扫描缓冲区，找登记过的明文标记。

这比事后 `grep` 文件强一档：SQLite 的排序溢出文件带 `SQLITE_OPEN_DELETEONCLOSE`，
建完立刻 unlink，事后去目录里根本看不到；只有在系统调用这一层才抓得住。
本次就是靠它证明了 `PRAGMA temp_store = FILE` 会把 22.64 MiB 明文写到磁盘。

---

## 三个踩过的坑（M1 一定会再遇到）

1. **`cipher_page_size` 不写进文件头。**
   用 16384 页建的库，新连接如果只 `PRAGMA key` 不重设 `PRAGMA cipher_page_size = 16384`，
   SQLCipher 会按默认 4096 去解第一页，报 **`file is not a database`**——和密钥错误的报错一模一样。
   每条连接的顺序必须是：`PRAGMA key` → `PRAGMA cipher_page_size` → 第一次真读。

2. **路线 b 必须显式给 `-DNDEBUG`。**
   amalgamation 里有一段「没定义 `SQLITE_DEBUG` 就自动 `#define NDEBUG`」，
   但 SwiftPM 的 C 目标是带 `-fmodules` 编的，`crypto_cc.c` 里 `#include <CommonCrypto/…>`
   会触发 framework 模块导入，`assert` 宏按模块构建时的状态重新生效，那段自动 `NDEBUG` 失效，
   于是 `SQLITE_DEBUG`-only 的 assert 辅助函数（`sqlite3BtreeHoldsAllMutexes` 等）
   变成「未声明函数」，直接编译失败。路线 a 用 LibTomCrypt、不引 framework，所以没这个问题。
   顺带：SQLCipher 自己还会检查 `SQLITE_TEMP_STORE` 必须是 2 或 3，否则 `#error` 拒绝编译。

3. **sqlite-vec 的 int8 向量要显式转换。**
   `INSERT INTO vec_text(text_rowid, embedding) VALUES(?, vec_int8(?))`、
   `WHERE embedding MATCH vec_int8(?)`。直接绑一个 512 字节 BLOB 会被当成 float32 向量，
   报 `Inserted vector ... expected to be of type int8, but a float32 vector was provided`。

---

## M1 接入 GRDB 的建议

官方 GRDB（`groue/GRDB.swift`）只在 CocoaPods 的 `GRDB.swift/SQLCipher` subspec 里支持 SQLCipher，
SPM 下要自己拼。可行做法：把 GRDB 源码作为本地 target 纳入我们自己的包，
让它依赖本包的 `SQLCipher` C 目标而不是系统 SQLite，并给它 `-DSQLITE_HAS_CODEC` 与 `GRDBCIPHER`。
GRDB 要用到的两个开关本次已经打开并验证：`SQLITE_ENABLE_PREUPDATE_HOOK`（`ValueObservation`）、
`SQLITE_ENABLE_COLUMN_METADATA`。

**也可以先不上 GRDB**：本次探针只用裸 C API 就跑通了 contentless FTS、vec0 KNN、dbstat、
锁定状态机与删除级联，封装量就是 `DB.swift` 那 150 行。存储服务本来就是单点持钥、
接口收敛的组件，把 GRDB 的集成成本推到 M2 是个合理的选项。

其余接入要点（每条连接的固定序言、`cipher_memory_security`、页缓存大小）见
`tools/proto/results/sqlcipher_2026-09-07.md` §10。
