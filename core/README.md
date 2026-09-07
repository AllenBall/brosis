# core/ —— 加密存储与检索核心（M1 / T2 + T3）

brosis 的**单一存储服务**：唯一持钥者，负责开库、写入、索引、删除级联、配额过期、夜间维护、体积统计，
以及**三通道检索、会话化与日台账**。
`app/`（采集端，T4）与将来的 `brosis-mcp` 都通过这个包访问数据库，谁都不自己开库。

对应 `docs/实施计划.md` 的 **3.1**（存储服务）、**3.2**（数据模型）、**3.4**（检索设计）、
**3.5**（密钥）、**3.6**（6 个 MCP 工具的**数据层**）、**3.7**（台账口径）、
**3.8**（保留、过期与删除）、**3.12**（`app_policies`），
决策 **D16**（数据目录不进同步盘）、**D17**（主键带 `device_id`）、**D22**（bigram + contentless FTS）、
**D23**（schema 定稿项）、**D25**（SQLCipher 构建路线）。

> **不做什么**：`brosis-mcp` 进程本身（stdio 传输、审计、按客户端拉起）归 R2，本包只提供
> 6 个工具各自的数据层与 grant 判定；采集、AX、OCR、锁定状态机的驱动归 T4；
> 向量检索要等 D8 通过（sqlite-vec 已静态编入并验证能链接，但不注册、不建表）；
> 夜间叙述（`ledgers.narrative`）是 M2 的可选任务，本包恒写 NULL。

---

## 目录

```text
core/
├── Package.swift                 swift-tools 6.1，macOS 26，语言模式 v6
├── setup.sh                      准备 vendor 源码 + 建两个符号链接 + 写 .gitignore
├── Vendor/
│   ├── SQLCipher -> <构建缓存>/sqlcipher/vendor/route-b            （符号链接，不进仓库）
│   └── SqliteVec -> <构建缓存>/sqlcipher/vendor/sqlite-vec-target  （符号链接，不进仓库）
├── Sources/
│   ├── CBrosisSQLite/            薄 C 垫片：volatile 清零、sqlite-vec 注册入口、SQLITE_TRANSIENT
│   ├── BrosisCore/
│   │   ├── Store.swift           开 / 关库、连接序言、身份与计数器、buildInfo
│   │   ├── Store+Write.swift     record / 批量写 / 规范化对象 upsert / 文本版本 + FTS / 策略 / 遥测
│   │   ├── Store+Delete.swift    四个删除入口 + 用户删除引擎 + 配额过期
│   │   ├── Store+Maintenance.swift  FTS 对账、checkpoint、incremental_vacuum
│   │   ├── Store+Stats.swift     dbstat 分项字节
│   │   ├── Store+Query.swift     T2 留的最小 FTS 通道与三个证据探针（对照用）
│   │   ├── Store+Search.swift    T3：三通道 search（精确字段两步式 / FTS / 1–2 字扫描）
│   │   ├── Store+Evidence.swift  T3：getEvidence / getItem / getContext + grants
│   │   ├── Store+Sessions.swift  T3：会话切分（三常量、双屏、增量构建）
│   │   ├── Store+Ledger.swift    T3：getDayLedger / getTimeline
│   │   ├── Store+Bench.swift     T3：四类查询的压测计划（参数从库里真实取）
│   │   ├── RetrievalTypes.swift  T3：检索 / 证据 / 会话 / 台账的入参与结果 + token 口径
│   │   ├── Retrieval+Support.swift T3：查询路由、LIKE 转义、日历、区间并集、三类时间归属
│   │   ├── Store+Integrity.swift 13 项悬空引用检查 + integrity_check + FTS integrity-check
│   │   ├── Schema.swift          schema v1（3.2 全部表）
│   │   ├── KeyProvider.swift     三个 KeyProvider 实现
│   │   ├── SecureKey.swift       可清零的 256 位原始密钥
│   │   ├── TextPipeline.swift    SHA-256（按原文）、索引侧 NFKC 折叠、bigram（D22）
│   │   ├── DataDirectory.swift   D16 的同步盘拒绝 + 0700 + 排除 TM / Spotlight
│   │   ├── SQLiteConnection.swift 裸 C API 的薄封装（D25：M1 不上 GRDB）
│   │   ├── Types.swift           入参 / 结果 / 枚举
│   │   └── StoreError.swift
│   └── brosis-store/main.swift   命令行工具（测试与验收用）
└── Tests/BrosisCoreTests/        71 个用例（T2 的 39 个 + T3 的检索 / 会话 / 台账 32 个）
```

**项目目录里没有任何构建产物**：SQLCipher 的 9.30 MiB amalgamation 与 sqlite-vec 都在
`~/Library/Caches/brosis-build/sqlcipher/vendor/` 下，包里只有两个符号链接
（SwiftPM 的 target `path` 必须在包内，但实测接受指向包外的符号链接）。
scratch 目录一律显式指到 `~/Library/Caches/brosis-build/m1-core/`。

---

## setup 与构建

```sh
# 一次即可（首次要 clone sqlcipher 并生成 amalgamation，数分钟）
sh core/setup.sh

# 构建（本机 xcode-select 指向 CommandLineTools，所以必须显式给 DEVELOPER_DIR）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift build --package-path core -c release \
  --scratch-path ~/Library/Caches/brosis-build/m1-core

# 测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path core \
  --scratch-path ~/Library/Caches/brosis-build/m1-core
```

`core/setup.sh` 做三件事：调用 `tools/proto/sqlcipher/setup.sh` 取源并生成 amalgamation
（SQLCipher **v4.18.0**、sqlite-vec **v0.1.9**，SHA-256 由该脚本打印并与 M0 一致）；
在 `core/Vendor/` 下建两个符号链接；把这两条路径追加进项目根 `.gitignore`（幂等）。

**必须 `-c release`**：debug 配置下 C 目标是 `-O0` 编的，SQLite 会慢 2–3 倍。
测试本身在 debug 下跑（`swift test` 默认），因为它验的是正确性不是性能。

### 编译开关（相对 M0 / E6 路线 b 的三处改动）

清单直接沿用 `tools/proto/sqlcipher/Package.swift` 的 `routeBCipherSettings`，只改三处：

| # | 改动 | 理由 |
|---|---|---|
| 1 | `SQLITE_TEMP_STORE` 2 → **3** | D25。值 2 的语义是"默认内存但 PRAGMA 可改回文件"；E6 实测 `temp_store=FILE` 时一次全表排序写出 **22.64 MiB 明文**溢出文件（金丝雀命中 73,494 次）。3 是编译期强制，PRAGMA 改不回去 |
| 2 | 去掉 `SQLITE_ENABLE_COLUMN_METADATA` 与 `SQLITE_ENABLE_PREUPDATE_HOOK` | 这两项当初是为"将来接 GRDB"打开的（`Database.columnInfo` / `ValueObservation`）。D25 已定 M1 不上 GRDB、先用薄 C 封装，`BrosisCore` 一行都没用到，留着白白增大二进制与 API 面。M2 若真接 GRDB，加回两行即可 |
| 3 | 加 `-Wno-ambiguous-macro` | amalgamation 自己 `#define` 了 `MIN` / `MAX`，unix VFS 那段又 `#include <sys/param.h>`（SDK 里也有同名宏），clang 对 **68 处**调用报 `-Wambiguous-macro`。两个定义语义完全相同，纯噪声，而源码是脚本从上游生成的、不能改。关掉后本包构建**零 warning** |

保留的关键项：`NDEBUG`（不给会编译失败，见 E6 §10.2）、`SQLITE_ENABLE_FTS5`、
`SQLITE_ENABLE_DBSTAT_VTAB`、`SQLITE_HAS_CODEC`、`SQLCIPHER_CRYPTO_CC`（CommonCrypto，走 AES 硬件指令）、
`SQLITE_SECURE_DELETE`、`SQLITE_THREADSAFE=1`、`SQLITE_DQS=0`。

> 改动 3 用了 `.unsafeFlags`，这让本包不能作为**按版本解析的**依赖被引用。
> 本包只会被 `app/` 以 `.package(path: "../core")`（本地路径）引用，实测可用。

---

## API 概览

```swift
import BrosisCore

// 开库（3.5 unlocking）
var options = StoreOptions()
options.quotaBytes = 10 * 1024 * 1024 * 1024      // 默认 10 GiB（2^30）
options.cipherMemorySecurity = false              // 可选严格项，写入 ×1.38
let store = try Store.open(
    directory: DataDirectory.defaultURL(bundleID: "com.brosis.app"),
    keyProvider: KeychainKeyProvider(),
    options: options)

// 写入
let result = try store.record(ObservationInput(
    ts: Int64(Date().timeIntervalSince1970 * 1000),
    app: AppRef(bundleID: "com.apple.Safari", name: "Safari"),
    windowTitle: "标题",
    url: URLRef(rawLocator: "https://example.com/a?x=1", host: "example.com", kind: .web),
    trigger: .axNotification, captureMethod: .ax, completeness: .complete,
    texts: [TextFragment(text: "视口内正文", region: "{\"x\":0,\"y\":0,\"w\":800,\"h\":600}")]))
try store.record(batch: [...])                    // 一个事务包住整批

// 删除（3.8，四个入口，都是"用户主动删除"语义）
try store.deleteByApp(bundleID: "com.electron.lark")
try store.deleteByTimeRange(start: t0, end: t1)   // 半开区间 [start, end)
try store.deleteByObject(.host("docs.internal"))  // 也支持 urlPrefix / rawLocator / filePath / filePathPrefix / windowTitle
try store.deleteObservations([1, 2, 3])

// 配额过期（3.8「自动过期」）
store.quotaWarningHandler = { used, quota in /* 80% 提示 */ }
let report = try store.expire()                   // 或 expire(toBytes:batchSize:)

// 夜间维护
let maintenance = try store.maintenance()         // FTS 对账 + checkpoint(TRUNCATE) + incremental_vacuum

// 统计与自检
let stats = try store.stats()                     // 分项字节
let detail = try store.statsDetail()              // 逐 b-tree
let integrity = try store.integrityReport()       // 13 项悬空引用 + 三项内建检查
let build = try store.buildInfo()                 // compile_options / cipher_version / PRAGMA 读回值

// 检索与台账（3.4 / 3.6 / 3.7，详见下面两章）
store.retrieval.timeZone = TimeZone(identifier: "UTC")!   // 台账按自然日切，时区要显式给
let result = try store.search(q: "知识图谱", start: t0, end: t1, app: nil, limit: 20)
let evidence = try store.getEvidence(ids: result.hits.map(\.evidenceID), grant: grant)
let timeline = try store.getTimeline(start: t0, end: t1, granularity: .day)
let item = try store.getItem(.url("docs.internal"))
let context = try store.getContext(hours: 24, maxTokens: 2000)
try store.buildSessions()                          // 增量；改了 sessionConfig 要 force: true
let ledger = try store.getDayLedger(date: "2026-09-07")

// 关库（3.5 locking：checkpoint、关连接、清零密钥）
store.close()
```

### 三个 KeyProvider

| 实现 | 用途 | 本轮是否实跑 |
|---|---|---|
| `InMemoryKeyProvider` | 单元测试。密钥常驻内存，**没有任何保护** | 是（全部 71 个用例） |
| `FileKeyProvider` | `brosis-store` CLI 与跨进程测试。0600 文件，读取时校验权限，缺失时 `SecRandomCopyBytes` 生成 | 是 |
| `KeychainKeyProvider` | **产品路径**。data-protection 钥匙串、`kSecUseDataProtectionKeychain = true`、`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`、`SecAccessControl` 绑本应用签名、首次 `SecRandomCopyBytes` 生成 | **否，待 T4 在 GUI 里验证** |

`FileKeyProvider` **不用于产品**：任何拿到同用户权限的进程都能直接读走那个文件。
它存在的唯一理由是让 CLI 与 `swift test` 能反复开关同一个库而不弹钥匙串授权。

### 连接序言（顺序不能改）

```text
[PRAGMA cipher_memory_security = ON]   -- 可选；必须在第一次分配加密上下文之前
PRAGMA key = "x'<64 位十六进制>'"       -- 256 位原始密钥，跳过 PBKDF2（E6：0.53 ms vs 78 ms）
PRAGMA cipher_page_size = 16384        -- 不写进文件头！不重设会报 file is not a database
PRAGMA auto_vacuum = INCREMENTAL       -- 仅建库时，且必须在 journal_mode 之前（见下）
PRAGMA journal_mode = WAL
PRAGMA synchronous = NORMAL
PRAGMA foreign_keys = ON               -- 连接级，每次都要
SELECT count(*) FROM sqlite_schema     -- 首次真读，密钥错在这里暴露
-- 以下不属于固定序言，是性能与安全的连接级设置
PRAGMA secure_delete = ON
PRAGMA cache_size = -131072            -- 128 MiB；E6 §5.2：加密库上扫描型查询靠它
```

两处踩过的坑，都写进了代码注释：

1. **`cipher_page_size` 不写进文件头**（E6）。用 16384 建的库，新连接只 `PRAGMA key` 不重设页大小，
   SQLCipher 会按默认 4096 去解第一页，报 `SQLITE_NOTADB / file is not a database`——
   和密钥错误的报错**一模一样**。所以 `StoreError.wrongKeyOrCorrupt` 的文档里写明了这一点。
2. **`auto_vacuum` 必须排在 `journal_mode` 之前**（本轮实测）。它是文件级设置，只在页 1 还没写出去时可改；
   `PRAGMA journal_mode = WAL` 是一次模式切换，会把页 1（此时 `auto_vacuum = 0`）落盘，
   之后再设 `INCREMENTAL` 静默无效。按 `… → WAL → … → auto_vacuum` 的顺序建库，
   `PRAGMA auto_vacuum` 读回 **0**；提到 WAL 之前读回 **2**。

### 文本处理（D22 / D23 / 3.3）

`TextPipeline`：**SHA-256（按原文，32 字节 BLOB） + 索引侧 NFKC 折叠 → bigram 预处理**。

- **NFKC 折叠只用于索引，不改原文**（M1 R1 定案的口径）。
  `text_versions.text` 存进去什么就是什么，`sha256` 与 `byte_len` 都按**原文的 UTF-8 字节**算；
  折叠只出现在两个地方——写 `text_fts` 的 bigram 预处理列（`TextPipeline.bigramForIndex`）
  与查询串（`TextPipeline.ftsPhrase`）。**`get_evidence` 拿到的正文与屏幕上看到的逐字节相同**，
  `"第一段：标题"` 的全角冒号 U+FF1A 原样保留。
- **去重语义因此是「逐字节相同才复用版本」**。同一段内容的全角写法（OCR 常产出）与半角写法（AX 常产出）
  是**两个** `text_versions` 行——这是有意的，证据必须原样；代价是这类内容各占一行原文，
  `text_versions` 行数与 `SUM(byte_len)` 都会比折叠入库时略高。
  它们的 FTS 行是**同一串 bigram**，所以检索侧看不出区别：两种写法的查询互相都能命中
  （`BigramFTSTests.testFullwidthAndHalfwidthAreSeparateVersionsButShareIndexForm`）。
- **折叠一去掉，两条通道各要补一处**（细节见下面「检索」一章）：
  FTS 通道的子串复核要对**候选正文**现折叠再比，扫描通道要把**查询串**展开成兼容区的写法。
- **bigram** 是 `tools/bench/fts_compare.py` 里 `bigram_join()` 的 Swift 重写，按 Unicode 标量逐个判定，
  与 Python 版产出逐字节相同（`BigramFTSTests.testBigramMatchesPythonReference` 有 8 条黄金用例）。
  汉字连续段切重叠 bigram，非汉字片段原样保留，用单个空格连接。
- **单个汉字查不到长正文**（D22 已知限制）：bigram 从 2 字起才有 token。
  `TextPipeline.requiresScanFallback(_:)` 告诉检索层什么时候必须改走"限定时间 / 应用范围的 LIKE 扫描"（3.4）——
  那条扫描通道归 T3。

---

## 检索（3.4 / 3.6，T3）

### 三条通道，是并集不是互斥

一次 `search(q, start, end, app, limit)` 会按 **精确字段 → 1–2 字扫描 → FTS** 的顺序走若干条通道，
结果合并去重、每条通道内部按 `ts` 倒序，最后截到 `limit`。返回的每条命中带
**≤ 100 token 的摘要**与 `evidenceID`（就是 `observations.id`，拿它去 `getEvidence` 展开原文）。

| 通道 | 什么时候走 | 怎么查 |
|---|---|---|
| `exact_url` / `exact_path` / `exact_title` / `exact_app` | 查询串带 `url:` / `host:` / `path:` / `app:` / `title:` 前缀时**只走**这一条；不带前缀时，形态被判成 URL 或路径的走对应那条，另外窗口标题这条**永远**参与 | **两步式**：先在 `urls` / `files` / `windows` / `apps` 小表上取 id，**空集直接返回**；再 `observations.<col> IN (…)` 取行 |
| `scan` | 查询串 ≤ `scanMaxQueryCharacters`（默认 2）个字符，**且不是纯汉字两字**（那一类 bigram 索引已经覆盖，见下） | 限时（默认最近 7 天）/ 限应用的 `tv.text LIKE '%q%'` 扫描（`q` 按下面的兼容写法展开成若干个），**不依赖 FTS** |
| `fts` | 只要 bigram 之后还有 token 就走 | bigram phrase → 候选 **`ORDER BY rowid DESC LIMIT`** → **子串复核** → 展开到观察 |

三处写法都是 E7（`tools/proto/results/capacity_2026-09-06.md` §10）实测出来的修正，**不能改回去**：

1. **精确字段必须两步式**。写成一条 `JOIN … ORDER BY o.ts DESC LIMIT 20`，规划器为了满足 `ORDER BY`
   会选**倒序扫 `observations`**，谓词一条都不命中时它要把整张表扫完（12 个月库 520 ms，加索引也救不了，
   问题在查询形状）。两步式在同一规模上 0.6 ms。`RetrievalTests.testTwoStepQueryPlanAvoidsObservationScan`
   用 `EXPLAIN QUERY PLAN` 把这个差别钉死，不靠计时。
2. **FTS 候选按 `rowid` 倒序取，不用 `bm25`**。`text_versions.vrow` 单调递增，所以 rowid 倒序 ≈ 时间倒序，
   FTS5 能直接从倒排表尾部取前 N 条；bm25 要求把整条倒排表读完再排序，高频词在 12 个月库上 225 ms，
   rowid 倒序 1.3 ms 且**与库规模无关**。代价是排序质量从相关度序变成时间序——对「我上周看的那个东西」
   这类问题时间序反而更对；真要相关度，M2 再在候选窗口里算 bm25。
3. **`sessions` 区间查询要给 `start` 补下界**，见下一章。

### 子串复核只作用于 FTS 通道

`unicode61` 会把 `abc-def` 切成 `abc` / `def` 两个 token，于是 phrase 查询命中了正文里的 `abc def`，
但正文并不含 `abc-def` 这个子串——这类**分词假阳性**只出现在 FTS 通道，所以复核也只加在这条通道上
（精确字段与扫描通道本身就是精确匹配，正文里不含该串是正常的：`urls` 命中而正文没抄这条 URL）。
复核**分两遍**。第一遍还是 SQL 的 `LIKE`，在**原文**上做：它对 ASCII 大小写不敏感，
与 `unicode61`、与 `fts_compare.py` 的真值口径（`q.lower() in text.lower()`）一致，
绝大多数候选在这一遍就定了（用 Swift 的 `contains` 会变成大小写敏感，英文查询会漏）。

第二遍只捞第一遍没过的候选，把**正文现折叠一遍**再比一次（`TextPipeline.indexContains`）。
这一遍是「正文存原文、索引存折叠后形式」这个口径必须补的：一段全角正文（`"ＳＱＬ 100"`）
在 FTS 里是以半角形式建的索引，半角查询 `SQL` 能 MATCH 到它，只在原文上复核就会把它**误杀**。

- **为什么不在 `text_versions` 旁边存一份折叠副本**：那要多一倍正文存储，与 D21 的容量口径冲突。
- **代价**：多一次同 rowid 集合的索引回查，加上对「没过第一遍」的候选做 NFKC。
  候选本身有上限（无过滤 200、带过滤 2000），所以是**有界的常数级开销**，
  且第一遍就过的候选一次 NFKC 都不做。
- 钉这条的用例：`RetrievalTests.testFTSChannelMatchesFullwidthBodyWithEitherWidth`。

### 带路径的 URL 不退回 host

`host:docs.internal` 走 host 等值 + 子域后缀 + `canonical_url` 子串；
`url:https://docs.internal/spec/` **只按 URL 列子串匹配**。后者要是退回 host 等值，
同域名下别的页面会把前 10 条挤满——本轮评估里 `url-03` 这一题就是这么先掉到 Recall@10 0.4 的。

### 1–2 字查询

bigram 从 2 字起才有 token，单个汉字在 bigram 索引里基本命中不了（D22 已知限制）。
计划 3.4 规定这类查询走「限定时间 / 应用范围后 LIKE 扫描」，本包的口径是：

- 查询 ≤ 2 个字符就**额外**并上一条扫描通道（不是替代 FTS，是并集）；
- **例外：纯汉字两字（`熵值`）不开扫描通道**。它本身就是一个 bigram token，FTS 通道
  MATCH 到它再用 `LIKE` 复核，语义**已经是精确子串**，扫描通道对这一类零召回增益
  （55 题查询集里 6 道「中文两字词」单靠 FTS 全部召回，Recall@10 = 1.000），
  却要把窗口内的正文全扫一遍——同一个库、同一条查询 `熵值` 实测：默认口径热 p95 **4.64 ms**，
  用 `bench --scan-all-short` 退回「≤ 2 字一律扫」是 **140.59 ms**，两边命中行数都是 14 条。
  判定在 `Store.scanChannelApplies(to:options:)`，可以用 `retrieval.scanSkipsPureCJKBigram` 关掉。留给扫描通道的是**单字**、以及 **≤ 2 字里含非汉字**的查询
  （`unicode61` 按词切，`sq` 这个 token 在索引里不存在，命中不了 `SQLCipher` 的子串）。
- **查询串要展开成兼容区的几种写法再 LIKE**（`Store.scanPatterns` / `TextPipeline.scanVariants`）。
  这条通道在**原文**上做子串匹配，而原文不再折叠，于是有两个方向：
  「全角查询 → 半角原文」把查询串折叠就行；「半角查询 → 全角原文」**折叠没用**——
  查 `AB`、正文是 `ＡＢ`，折叠只会让查询串更半角，两种写法都不在原文里，`LIKE` 一定落空
  （把 `scanPatterns` 临时改回「折叠 / 不折叠各试一次」跑
  `testScanChannelMatchesFullwidthBodyWithHalfwidthQuery`，实测断言全部落空——
  原始输出 `~/Library/Caches/brosis-build/m1-nfkc/results/ab_naive_two_forms.log`）。
  所以反过来把查询串展开成兼容区的**单标量前像**（`A` → `Ａ`、`:` → `：` / `﹕` / `︓` …）一起 LIKE。
  - **为什么不像 FTS 通道那样现折叠正文**：那是对 7 天窗口里约 34 MiB 正文逐条做 NFKC。
    这条通道本来就是 3.4 分层目标里最贵的一档（实测热 p95 122 ms / 目标 150 ms），加不起。
  - **前像表按「折叠 + 小写」归并**：SQL 的 `LIKE` 只对 ASCII 大小写不敏感，
    `LIKE '%ＳＱ%'` 命中不了 `ｓｑ`，所以每个 ASCII 字母展开成 3 种写法（`S` / `Ｓ` / `ｓ`）。
    不归并时实测过：同一批语料改成全角后 `SQ` 从 5 条掉到 3 条。
  - **展开不是免费的，所以只在需要时才展开。** 这条通道按定义要扫完整个时间窗，
    代价与模式条数近似成正比：同一条 ASCII 两字查询（`bench --short-queries SQ`，命中 10 条、
    不触发 `LIMIT` 短路）**1 个 `LIKE` 热 p95 117.4 ms、展开成 9 个 721.0 ms**。
    所以 `Store.hasCompatibilityText` 记录「这个库里写进过折叠会变样的正文吗」
    （写入时顺手记进 `meta.has_compat_text`，只置位不清位，折叠本来就要算一次，不额外跑 NFKC），
    **没有就只发一个 `LIKE`**——纯 AX 来源的库、以及本轮 1 个月合成库都是这一档，零回归。
    有的时候（OCR 会产出全角标点）ASCII 短查询要付那 6 倍；纯汉字查询任何时候都只有 1 个
    `LIKE`（`熵` 在兼容区里没有前像），最贵的那一档一点没变。
  - **试过但退回：把 9 种写法压成一个 `GLOB` 字符类**（`*[SsＳｓ][QqＱｑ]*`）想一遍扫完。
    反而更慢——SQLite 的 `GLOB` 走带 UTF-8 逐字符解码的通用匹配器：同一条查询 **605.1 ms**，
    连纯汉字单字 `熵` 都从 122.3 ms 掉到 **398.5 ms**。已退回 `LIKE`。
  - **代价（明写）**：只覆盖康熙部首 / 表意空格 / CJK 兼容汉字 / 字母表现形式 / 竖排小写形式 /
    半角全角形式这几段的**单标量**前像。连字（`ﬁ` → `fi`）这类一个字符折成多个字符的写法、
    以及组合数超过 16 的查询串，扫描通道仍然会漏；这类正文由 FTS 通道兜底
    （那条通道对候选做的是真折叠，没有这个限制）。
- 没给区间时，窗口 = **以「库里最新一条观察」为锚点**往回 `scanWindowDays`（默认 7）天。
  用最新一条而不是「此刻」，是因为离线的合成库上只有它才是有意义的锚点；
  记录器在跑的时候两者约等。显式给了 `end` 时上界就是 `end`（**半开区间**，与另外两条通道一致）。
- 给了 `app` 就再限应用。

### token 口径

**token 数 = 字符数 ÷ 2，向上取整**（`TokenBudget`）。本项目的正文是中英混排（本轮语料实测汉字占字符数
32.1%），汉字大致 1 字 1 token、英文大致 4 字符 1 token，取 2 是居中的保守估计。
这是**估算不是分词**：3.6 的「每条 ≤ 100 token 摘要」按这个口径就是**每条摘要 ≤ 200 个字符**，
`get_context(max_tokens)` 也按它截断。要精确计数得引入分词器，M1 不做。

### 3.6 六个工具的数据层

| 工具（3.6） | 本包的方法 | 说明 |
|---|---|---|
| `search(q, start, end, app, limit)` | `Store.search` | 上面三通道；每条 ≤ 100 token 摘要 + evidence id |
| `get_evidence(ids)` | `Store.getEvidence(ids:grant:neighbors:)` | 原文（按 `ord` 拼）+ 出现上下文（同屏前后各 N 条的摘要）。**受 grant 字段级限制**：`fields = summary` 时不返回原文、`redactedByGrant = true`；应用白名单与时间窗挡掉的 id 进 `deniedByGrant`；不存在 / 已删除的 id 只回 id 本身进 `missing`（3.8 要求这几类不返回任何内容） |
| `get_timeline(start, end, granularity)` | `Store.getTimeline` | `hour` / `day` / `week` 分桶，每桶给应用分布、三类时间、区间并集、切换次数 |
| `get_item(url \| path \| app)` | `Store.getItem` | 两步式；给首末次、按天分布、应用分布、标题样本、最近证据 id 与时长 |
| `get_context(hours, max_tokens)` | `Store.getContext` | 应用聚合 + 会话汇总 + 最近正文片段，按 token 预算截断 |
| `get_day_ledger(date)` | `Store.getDayLedger` | 见下一章 |

`grants` 表的读写是 `setGrant` / `grant(clientID:)`。**MCP 进程本身不在本包里**（R2）：
stdio 传输、按客户端拉起、调用审计都归它，本包只负责「给定一份 grant，返回被裁剪过的数据」。

---

## 会话与日台账（3.7，T3）

### 一条观察代表多长时间

**到「同一块屏上的下一条观察」为止，上限 `maxDwellSeconds`（默认 90 s）**。
3.7 的「停留上限 90 s」就是这个上限：超过它说明中间那段没有证据，不记时长。
每块屏最后一条观察没有下一条，记 **0**——不给未来的时间记账。

### 三类时间分列

| 类别 | 包含的 `source_state` | 口径 |
|---|---|---|
| `unknown_s` | `permission_lost` / `timeout` / `locked` | 3.7 点名的三种。这段时间**不算前台停留** |
| `dwell_s` | 其余全部（`ok` / `user_idle` / `secure_input`） | 前台停留 |
| `active_s` | `ok` / `secure_input` | 有输入的活跃。`user_idle` 明确是「用户未活动」，不算 |

`active ⊆ dwell`；`dwell + unknown` = 会话总时长。**三个数分列报告，不相加当总数。**

### 会话怎么切

按 `(display_id, app_id)` 切，两条规则：

1. 同一 (屏, 应用) 的相邻观察间隔 **≥ `gapSeconds`（默认 300 s）** → 切成两个会话；
2. 中途切到别的应用又切回来、离开时长 **≤ `interruptionSeconds`（默认 20 s）** → **不切**，
   `interruptions += 1`。离开超过 20 s 就是两段会话，不算打断。

规则 1 是开区间（`< 300 s` 才接上）、规则 2 是闭区间（`≤ 20 s` 算打断），不是笔误：
3.7 的原话是「间隔 300 s、打断 20 s」，「间隔」读作"超过就断开"、「打断」读作"20 秒以内算打断"。
更实际的理由是采集节奏——E7 口径是 10 s 一次，一条观察的外出往返正好 20 s，
用严格小于的话**默认常量下一次打断都观测不到**（本轮实测过，1 个月台账的打断数全是 0），
这条口径就等于没有。3.7 已经写明这三个数是待校准参数不是结论，真实采样率定下来之后要重标。

三个常量在 `Store.sessionConfig` 里，**是可配置参数不是已验证结论**（3.7 原话），
CLI 用 `--max-dwell-s` / `--gap-s` / `--interruption-s` 覆盖。改了必须 `buildSessions(force: true)` 重建，
台账 JSON 里也带着这三个数，好知道某份台账是用哪套常量算出来的。

### 双屏

时长**按焦点窗口归属**：每块屏是一条独立的焦点流，会话不跨屏。
另算所有会话区间的**并集**当作「总在线」（`onlineUnionS`），两者都报告、不重复计：
两块屏同时在用的时候 `focusDwellS` 会是 `onlineUnionS` 的两倍，这是对的，不是 bug。

### 增量构建

`buildSessions()` 默认增量。重算起点分两步定：

1. **锚点** = `min(最早一条 stale 会话的 start, 每块屏最后一个会话的 start)` 再减去一个
   `maxDwellSeconds`——新观察只可能延长每块屏最后那个会话（那块屏原来的最后一条观察时长记 0），
   被删除标脏的会话必须重算，而一条观察的时长最多受它后面 90 s 内的观察影响。
2. **往前推到不切开任何会话**：把所有与 `[起点, ∞)` 有交叠的会话（`"end" > 起点 或 start >= 起点`）
   一起删掉重算，起点取它们的 `MIN(start)`，推早之后可能又圈进更早的会话，所以**迭代到不动点**。
3. **再查一次边界上的同毫秒观察**（`boundaryStartToInclude`）：留下的会话里 `"end" == 起点`
   的那几个（每块屏至多一个）如果含着 `ts == 起点` 的观察，把它们也卷进来（起点降到它的 `start`）
   再迭代。同一块屏上两条观察的 `ts` 完全相同是可能的（毫秒时间戳、记录器取 `Date()`、
   schema 也没有 `(device_id, display_id, ts)` 唯一约束），这时前一条的时间片长度是 0，
   第 2 步判不到它——R1 第二轮验收就是在这里发现同一条观察进了两个会话（7 条观察即可复现）。

第 2 步不能省。只按 `start >= 起点` 删会话的话，**起点更早、尾巴伸进重算区间的会话**会被留下
（打断规则把后面的观察吸回早先的会话、或者两块屏的会话边界不对齐时必然出现），
它里面 `ts >= 起点` 的观察又被重扫分进新会话，于是**同一条观察进了两个会话**：
会话数虚增、时长重复计。判据用严格大于而不是 `>=`，是因为相邻两个会话通常首尾相接
（前一个的 `"end"` 正好等于后一个的 `start`），写成 `>=` 会把整个月的会话串成一条链，
不动点退到库首、增量退化成全量。

收敛之后的不变量：**留下的会话与重扫区间的观察集合不相交**，所以增量结果与全量重建逐字段相等。
更早的会话原样保留。水位线存在 `meta.sessions_watermark_ts`。
`SessionLedgerTests` 里三个用例断言这件事：
`testIncrementalBuildOnlyScansNewObservations`（单屏，只扫新观察）、
`testIncrementalBuildMatchesFullRebuildWithTwoDisplaysAndInterruption`
（两块屏边界不对齐 + 一次打断：零新观察的 `build()` 幂等，且会话数 / 证据 id / 三类时长
与 `force` 重建逐字段相等）与
`testIncrementalBuildWithSameMillisecondObservationsOnOneDisplay`
（同一块屏上同毫秒且换了应用的两条观察：连跑两次 `build()` 都与 `force` 逐字段相等、证据 id 不重复）。

被用户删除或配额过期扫掉的观察会让 `sessions` / `ledgers` 打上 `stale`（3.8 的级联，T2 已实现）。
`stale` 的会话**不进区间查询结果**（等重算），下一次 `buildSessions()` 把它们卷进来重算并清掉标记。

### 区间查询要给 `start` 补下界

```sql
-- 有问题：idx_sessions_range 是 (device_id, start, "end")，这个谓词只能用上 start <= ?，
-- 等于扫掉库里几乎所有会话（E7 §10.3：12 个月库 6.42 ms）
WHERE device_id = ? AND "end" >= ? AND start <= ?
-- 本包的写法：补一个 start 下界，规模无关（0.07 ms）
WHERE device_id = ? AND start >= ? - <最长会话> AND start < ? AND "end" > ?
```

下界用的是**构建时实测的最长会话时长**，存在 `meta.sessions_max_duration_ms`。
不是硬编码 24 h（E7 报告里那句「不该硬编码」），也不是 3.7 的 90 s——
90 s 是单条观察的停留上限，不是会话长度上界，一段连续同应用的观察可以拼出几小时的会话。

### 日台账

`getDayLedger(date:)` 按 `retrieval.timeZone` 切自然日（半开区间 `[00:00, 次日 00:00)`），产出：

- 按**应用 / 站点（host） / 文件**三张表，每行给 dwell / active / unknown、**切换次数**、观察数；
- 三类时间合计、`focusDwellS` 与 `onlineUnionS`、每块屏的 dwell；
- 切换次数、打断数、会话数、观察数；
- `evidence` 按 **D23 的区间表示** `[[lo, hi], …]`；
- `sessionConfig`：算这份台账用的三个常量；
- **`narrative` 恒为 `null`、`model` 恒为 `null`**——3.7 要求台账与叙述分开标注，叙述是 M2 的可选夜间任务。

台账是**确定性**的（同样的观察算出同样的数，不经过任何模型），所以已有且不是 `stale` 的直接读回，
缺失 / `stale` / `recompute: true` 时才重算并覆盖（重算时 `narrative` 与 `model` 一并置回 NULL：
台账变了，旧叙述不再对得上）。

跨日边界的时间片按天裁开：23:59:20 那条观察的 90 s 里，40 s 记在当天、50 s 记到第二天。

---

## schema v1 与计划 3.2 的对应

| 计划 3.2 的表 | 本包 | 差异与说明 |
|---|---|---|
| `apps` | ✔ | `bundle_id` 列上 `COLLATE NOCASE`（D22：必须写在列上，只给索引加等值查询走不了索引） |
| `windows` | ✔ | `title COLLATE NOCASE` + `idx_windows_title` |
| `urls` | ✔ | `raw_locator` 原样保留且 UNIQUE；`canonical_url` / `host` 列上 NOCASE；`kind` 有 CHECK |
| `files` | ✔ | `path` UNIQUE + NOCASE |
| `observations` | ✔ | 主键 `(device_id, id)`（D17）；`trigger` / `capture_method` / `completeness` / `source_state` 都有 CHECK；`deleted_at` 是用户删除墓碑 |
| `text_versions` | ✔ | `vrow INTEGER PRIMARY KEY` 是本机私有代理 rowid（D23，不参与同步）；`sha256` 是**原文 UTF-8 字节**的 **32 字节 BLOB**（D23，不折叠）；`text` 存原文、`byte_len` 按原文；`UNIQUE(device_id, sha256)` 实现哈希复用（**逐字节相同才复用**，全角与半角是两个版本）；`trg_text_versions_immutable` 让任何 UPDATE 直接 ABORT |
| `occurrences` | ✔ | 主键带 `device_id`；`observation_id` 外键 `ON DELETE CASCADE`（配额过期用），`text_version_id` 外键 `ON DELETE RESTRICT`（共享版本的硬保证） |
| `text_fts` | ✔ | **contentless**（`content=''`、`contentless_delete=1`）+ `unicode61 remove_diacritics 2`（D22）。**没有触发器**——写进去的是 Swift 侧 **NFKC 折叠后再 bigram 化**的文本（`TextPipeline.bigramForIndex`，折叠只到这张表为止），SQL 触发器算不出来；增删显式做，`maintenance()` 夜间对账 |
| `sessions` | ✔ | 三类时间分列（3.7）+ `stale` |
| `ledgers` | ✔ | 台账与叙述分开标注；`evidence` 按 D23 用区间表示，`markDerivedStale` 同时认数组与区间两种形状 |
| `deletions` | ✔ | 主键带 `device_id`；`reason ∈ {user, quota, policy}` 把三种语义分开；`fts_rows_deleted` 是**实测差值**不是照抄 |
| `grants` | ✔ | 给 T3 / MCP 用，本包只建表 |
| `jobs` | ✔ | 兼作运行期事件表：`type = 'runtime_event:<kind>'`、`state = 'done'`（理由写在 `recordRuntimeEvent` 的注释里） |
| `chunks` / `vec_chunks` | ✘ | D8 通过后才建。sqlite-vec 已静态编入（`brosis_vec_version()` 读回 `v0.1.9`），但不注册 `sqlite3_auto_extension`、不建 `vec0` 表 |
| **3.12** `app_policies` | ✔ | `(bundle_id, mode, source, updated_at)`，三档模式有 CHECK。本机配置，不同步 |
| 本包自加 `meta` | — | `schema_version` / `device_id` / `created_at` / `fts_scheme` / 五个单调计数器 / `has_compat_text`（库里写进过「NFKC 折叠会变样」的正文吗，扫描通道靠它决定要不要展开查询串）/ `sessions_watermark_ts` / `sessions_max_duration_ms`。本机配置，不同步 |
| 本包自加 `migrations` | — | 每次 schema 变更一行 |
| 本包自加 `capture_stats` | — | **不是 3.2 的表、不参与 D17 同步、不进删除级联**。承接 M0 app 骨架 `frame_stats` 的遥测（帧门控率、dHash 汉明距离、脏区面积比、按需截图触发原因、AX 字符数）。它是本机运行质量的度量，不是证据；`maintenance()` 按 `captureStatsRetentionDays`（默认 30 天）滚动清理 |

**单调计数器**：`observations` / `text_versions` / `occurrences` / `deletions` 的 id 与 `text_versions.vrow`
都由内存计数器分配，并在**同一个事务里**写回 `meta`。这样崩溃时计数器与数据一起回滚
（`CrashRecoveryTests` 有一条断言专门核这个），而且配额过期把最旧的一批物理删掉之后 id 也不会回绕重用。

---

## 删除的两条路径（3.8）

| | 用户主动删除 | 配额过期 |
|---|---|---|
| 入口 | `deleteByApp` / `deleteByTimeRange` / `deleteByObject` / `deleteObservations` | `expire(toBytes:)` |
| `observations` 行 | **保留**，打 `deleted_at` 墓碑（审计 + D17 重放） | **物理删除**，审计行本身是区间墓碑 |
| `occurrences` | 显式 `DELETE` | 随外键 `ON DELETE CASCADE` |
| 无引用的 `text_version` | 删 | 删 |
| FTS 行 | 显式 `DELETE FROM text_fts WHERE rowid = ?` | 同左 |
| `sessions` / `ledgers` | 证据命中就标 `stale` | 同左 |
| 缩略图 | 删文件，`thumb_ref` 置空 | 删文件 |
| `deletions.reason` | `user` | `quota`，`params` 里带 `"synced": false` |

级联顺序按 3.8 写死：**observation → occurrences → 无剩余引用的 text_version → FTS 行 →
派生结果 stale → 缩略图 → 审计行**。

`deletions.fts_rows_deleted` 是**实测值**：事务开始与清完孤儿版本之后各数一次 `text_fts_docsize`，
取差值写入，而不是照抄 `text_versions_deleted`——照抄就失去了独立核验的意义
（`E3ScenarioTests.testS3_UserDeleteCascade` 有一条断言专门对这个账）。

配额默认 **10 GiB = 10 × 2^30 字节**，口径是**原文净载荷** `SUM(text_versions.byte_len)`
（与 2.4「存储」行的"原文"一栏一致，不含索引与页开销）。
到达 `quotaWarnRatio`（默认 0.8）触发 `quotaWarningHandler`。

---

## `brosis-store` 命令行工具

所有输出都是 JSON（除 `--help`），便于验收脚本直接解析。密钥用 `--key-file`，不碰钥匙串。

```sh
BIN=~/Library/Caches/brosis-build/m1-core/release/brosis-store
W=~/Library/Caches/brosis-build/m1-core/demo

$BIN init          --dir $W/db --key-file $W/db.key       # 建库，打印编译开关与连接配置
$BIN gen-jsonl     --out $W/synth.jsonl --count 500 --seed 20260907
$BIN import-jsonl  --dir $W/db --key-file $W/db.key --file $W/synth.jsonl
$BIN stats         --dir $W/db --key-file $W/db.key --detail
$BIN dump-fts-count --dir $W/db --key-file $W/db.key --match 会议纪要
$BIN delete        --dir $W/db --key-file $W/db.key --app com.apple.Safari
$BIN delete        --dir $W/db --key-file $W/db.key --object host=docs.internal
$BIN delete        --dir $W/db --key-file $W/db.key --range 1757000000000,1757000300000
$BIN expire        --dir $W/db --key-file $W/db.key --to-bytes 2000 --batch 20
$BIN maintenance   --dir $W/db --key-file $W/db.key
$BIN check         --dir $W/db --key-file $W/db.key       # 13 项悬空引用；未过时退出码 2
$BIN crash-after   --dir $W/db --key-file $W/db.key --count 300 --batch 50   # 写完自杀
```

`--object` 的 key 可以是 `host` / `url-prefix` / `raw-locator` / `file` / `file-prefix` / `window`。

检索、会话与台账（T3 新增）：

```sh
$BIN search   --dir $W/db --key-file $W/db.key --q 知识图谱 --limit 20
$BIN search   --dir $W/db --key-file $W/db.key --q host:docs.internal      # 精确字段前缀
$BIN search   --dir $W/db --key-file $W/db.key --q 熵 --start T0 --end T1 --app com.electron.lark
$BIN search-batch --dir $W/db --key-file $W/db.key --file queries.json      # 评估脚本用
$BIN evidence --dir $W/db --key-file $W/db.key --ids 1,2,3 --client claude-code
$BIN grant    --dir $W/db --key-file $W/db.key --client claude-code --fields summary --apps '*'
$BIN item     --dir $W/db --key-file $W/db.key --app com.apple.Safari
$BIN context  --dir $W/db --key-file $W/db.key --hours 24 --max-tokens 2000
$BIN timeline --dir $W/db --key-file $W/db.key --start T0 --end T1 --granularity day
$BIN sessions --dir $W/db --key-file $W/db.key --build          # 增量；--force 全量重建
$BIN ledger   --dir $W/db --key-file $W/db.key --days           # 有观察的自然日
$BIN ledger   --dir $W/db --key-file $W/db.key --date 2026-09-07 --recompute
$BIN bench    --dir $W/db --key-file $W/db.key --cold-rounds 20 --hot-reps 20 --out bench.json
$BIN fts-only --dir $W/db --key-file $W/db.key --q 存储服务      # T2 的最小 FTS 通道，对照用
```

其余通用选项：`--memsec`、`--quota-bytes`、`--cache-kib`、`--device-id`、`--no-create-key`、
`--capture-stats-days`；检索侧还有 `--tz`、`--scan-days`、`--scan-all-short`、`--fts-candidates`、
`--fts-candidates-filtered`、`--summary-tokens`、`--max-dwell-s`、`--gap-s`、`--interruption-s`。
`--scan-all-short` 把「纯汉字两字只走 FTS」关掉退回「≤ 2 字一律扫」，是量这条策略收益的对照口径。

> `search --app <bundle_id>` 与 `getEvidence` 的应用过滤都是 **`bundle_id` 等值**，不认应用名：
> `--app 终端` 静默返回 0 条、`channels` 为空。想按应用名找就用 `--q app:终端`——
> `app:` 前缀走精确字段通道，`bundle_id` 与 `name` 两列都匹配（`RetrievalTypes.swift` 有说明）。

> `search` 子命令从 T3 起是**三通道**检索，输出里 `hits` 是命中数组、`hit_count` 是条数
> （T2 的版本只跑 FTS 通道、`hits` 是个整数）。要 T2 那个口径请用 `fts-only`。

### JSONL 格式（`gen-jsonl` 产出、`import-jsonl` 消费）

一行一条观察。除 `ts` 外全部可选；缺省值写在括号里。

```json
{
  "ts": 1757000000000,
  "display_id": 1,
  "app":  {"bundle_id": "com.apple.Safari", "name": "Safari"},
  "window": "Safari — 窗口 0",
  "url":  {"raw": "https://example.com/doc/0?q=1",
           "canonical": "https://example.com/doc/0?q=1",
           "host": "example.com", "kind": "web"},
  "file": "/tmp/brosis-synth/doc-0.md",
  "trigger": "timer",              
  "capture_method": "ax",          
  "completeness": "complete",      
  "source_state": "ok",            
  "visible_range": "{...}",
  "frame_hash": "0f1e2d3c4b5a6978",
  "thumb_ref": "t0.png",
  "texts": [{"text": "正文", "region": "{\"ord\":0}"}]
}
```

枚举取值与 schema 的 CHECK 一致：
`trigger ∈ {app_switch, window_change, url_change, ax_notification, frame_dirty, timer, manual}`（缺省 `timer`）、
`capture_method ∈ {ax, ocr, adapter, mixed}`（缺省 `ax`）、
`completeness ∈ {complete, partial, unavailable, excluded}`（缺省 `complete`）、
`source_state ∈ {ok, permission_lost, timeout, user_idle, secure_input, locked}`（缺省 `ok`）、
`url.kind ∈ {web, file, deeplink, doc, other}`（缺省 `web`）。
`texts` 的数组下标就是 `occurrences.ord`。

`gen-jsonl` 是确定性的（SplitMix64）：同 `--seed` 两次产出逐字节相同。
`--reuse-every`（默认 5）控制复用率：每 5 条一组，组内第一条产出新正文、其余 4 条复现它，
所以 500 条会得到 100 个 `text_version`、400 次复用。

---

## 测试

`swift test` 下 **71 个用例**，七个套件（T2 的 39 个 + T3 的 32 个：`RetrievalTests` 20 + `SessionLedgerTests` 12）：

| 套件 | 覆盖 |
|---|---|
| `E3ScenarioTests` | E3 七场景在加密库上复跑：S1 文本版本复用、S2 正文修改（含不可变触发器）、S3 用户删除级联（含 FTS 行数独立复核 + `get_evidence` / `get_context` / `get_day_ledger` 三入口）、S4 共享文本版本（含外键 RESTRICT）、S5 配额过期（含 80% 回调、最旧先删、与用户删除可区分、两条独立审计）、S6 应用切换；外加混合操作后的 13 项悬空引用总检 |
| `CrashRecoveryTests` | S7 崩溃恢复：`brosis-store crash-after` + `kill -9` 打在未提交事务里，重开库后核对已提交条数、整批回滚、13 项悬空检查、计数器一并回滚；外加 CLI 全流程端到端 |
| `CryptoAndBuildTests` | 错密钥失败 / 正确密钥成功 / 失败的解锁不破坏库、密钥清零、20 轮锁定状态机、`compile_options` 与连接配置核对、`cipher_memory_security`、明文泄漏扫描（含阳性对照）、D16 目录拒绝、目录 0700 与两个排除标记、三个 KeyProvider |
| `BigramFTSTests` | bigram 与 Python 参考实现的黄金用例、**原文逐字节入库**（sha256 / byte_len 都按原文）、**全角与半角是两个版本但共用同一串 FTS bigram、两种写法互相都能命中**、中英混排往返（写入 → 短语命中 → 删除 → 不再命中）、单字限制、FTS 对账、空间回收 |
| `StoreAPITests` | schema 全表自检与 D17 / D23 的列级核对、`device_id` 稳定性、`app_policies` 三档、运行期事件与遥测、dbstat 分项口径、多片段按 ord 重建、`deleteByObject` 各变体、半开区间、空删除也留审计 |
| `RetrievalTests`（T3，20 个） | bigram 命中 / 未命中 / 跨句边界；子串复核滤掉分词假阳性（含反向对照）；**全角原文用半角 / 全角查询都能过 FTS 通道的子串复核**、**全角原文用半角查询也能被 1–2 字扫描通道命中**；1–2 字扫描的默认 7 天窗口、显式区间、限应用、窗口可配置、**上界半开**、**纯汉字两字不开扫描通道而召回不变**、**≤2 字含非汉字仍然要扫**；五个字段前缀的两步式与「命中 0 行第一步就空集返回」；**`EXPLAIN QUERY PLAN` 对照**一条 JOIN 与两步式的计划差别；带路径 URL 不退回 host；摘要 ≤ 100 token；时间与应用过滤（半开区间）；删除后 search / getEvidence / getContext / 台账四个入口都不再返回内容；**FTS 候选被截断 + 早期时间窗会漏召回、且 `ftsCandidatesTruncated` 必须报 true**；grant 的字段级 / 应用白名单 / 时间窗；getItem / getContext 预算 / getTimeline 分桶；查询路由 |
| `SessionLedgerTests`（T3，12 个） | 三个会话常量的**边界**（299 s vs 300 s、90 s 封顶、15 s vs 25 s 打断）与可配置性；三类时间分列；双屏焦点归属 vs 区间并集；增量构建（只扫新观察、结果与全量一致、延长最后一个会话、**两块屏边界不对齐 + 一次打断时幂等且与全量重建逐字段相等**、**同一块屏上同毫秒的两条观察也不能被分进两个会话**）；删除标 stale → 重算清掉且证据里不再有被删的观察；日台账形状与确定性；跨日边界裁剪 |

测试数据落在 `~/Library/Caches/brosis-build/m1-core-tests/`，每个用例一个临时目录，用完删掉；
不启动任何 GUI、不碰钥匙串、不触发 TCC。

---

## 已知限制

1. **`KeychainKeyProvider` 没有实跑**。读写 data-protection 钥匙串需要签名 + entitlement，
   首次访问会弹钥匙串授权对话框，本轮约束禁止触发任何 GUI / 授权弹窗。
   编译通过、接口正确，**实跑留给 T4 在 GUI 里验证**（同时验证 3.5 的锁定状态机与 ACL 是否真的限住了本应用）。
2. **sqlite-vec 静态编入但未启用**。D8 通过前不调用 `brosis_register_vec()`、不建 `vec0` 表。
   本轮只验证了它能链接、`brosis_vec_version()` 读回 `v0.1.9`。
3. **单连接、单写者**。内部一把 `NSLock` 串行化全部公开方法。多读连接与 WAL 下的读写并发没测，
   留给 M2 按实测决定（E6 §11 也把这条列为遗留项）。
4. **`cipher_memory_security` 默认关**。它必须在进程里第一次分配加密上下文之前设置，
   所以只有本进程**第一次**开库时给 `options.cipherMemorySecurity = true` 才可靠；
   T4 要把它放在存储服务启动的最早一步。E6 实测开启后写入 ×1.38。
5. **`evidenceText` / `contextTexts` / `dayLedgerTexts` 是 T2 留下的最小实现**，只用于自测与对照；
   产品路径请用 `getEvidence` / `getContext` / `getDayLedger`。
6. **删除的批量粒度**。`expire` 按 `batchSize`（默认 200）成批删，所以最终字节可能低于目标不少；
   要贴着配额停就把 batch 调小。用户删除按 400 个 id 一组分块，避免 SQL 变量数上限。
7. **单字扫描通道不与点查共用「热 p95 < 10 ms」**：计划 3.4 的延迟目标已经分层
   （2026-09-07 定，7 天窗口 ≤ 150 ms、限应用 ≤ 60 ms），本包按分层目标达标。
   原因是这条通道按定义就要把窗口内的全部正文扫一遍（默认 7 天窗口，本轮 1 个月合成库上
   约 34 MiB 正文），延迟**与库规模无关**（只跟窗口大小与命中密度有关），但绝对值就是
   几十到一百多毫秒：本轮 1 个月库上单字 `熵` 冷 p95 170.79 ms / 热 p95 **122.40 ms**（目标 150），
   加 `app` 过滤降到冷 94.41 / 热 **50.33 ms**（目标 60）。
   E7 报的 0.19 ms 是「高频词 + `LIMIT 20` 提前短路」的下界，稀有词命中不了 20 条就没法短路。
   两个可调项：加 `app` 过滤约降六成，缩短 `scanWindowDays` 线性下降。
   真正的解法（单字倒排 / 辅助索引）要权衡索引体积，留给 M2。
   **纯汉字两字已经不走这条通道**（见「1–2 字查询」一节），热 p95 4.64 ms。
8. **`getItem` 与 `getTimeline` 是报表类查询**（计划 3.4 的分层目标：**≤ 50 ms**），
   延迟随「对象有多大 / 问多长的区间」增长，不随库规模增长：
   一个应用一个月有 62,217 条观察时 `get_item(app)` 冷 p95 57.21 ms / **热 p95 40.51 ms**
   （全部聚合已经在 SQL 里做，不把行拉进 Swift）；7 天的 `get_timeline` 要把窗口内每条观察
   折算成时间片，冷 p95 31.93 ms / **热 p95 28.17 ms**。两条都在 50 ms 以内。
   给 `start` / `end` 收窄范围就线性下降。
9. **`getItem` 的按天直方图在 SQL 里用固定时区偏移分桶**。取样点是**命中行的
   `(MIN(ts) + MAX(ts)) / 2`**（R1 第二轮验收指出：原来用「区间中点」，不给 `start` / `end`
   时会落到 1998 年，取样点离数据很远，有夏令时的时区里可能整段偏 1 h）。
   现在只有**跨夏令时切换的区间**才可能有一天的桶边界偏 1 h。
   UTC 与中国时区都没有夏令时，验收不受影响。
10. **`getContext` / 扫描通道的时间锚点是「库里最新一条观察」**，不是此刻。
    记录器在跑的时候两者约等；库停了很久再查，窗口会跟着往回挪。
11. **会话的时长口径依赖 `source_state`，不依赖真实输入计数**。3.7 的「有输入的活跃」
    在本包里等于 `source_state ∈ {ok, secure_input}`；真正的 CGEventSource 输入计数在采集端（T4），
    接上之后 `active_s` 才是字面意义上的「有输入」。
12. **FTS 候选被截断时，早期时间窗会漏召回**。候选是
    `ORDER BY rowid DESC LIMIT`（默认无过滤 200、带时间 / 应用过滤 2000）取的，
    ≈ 时间倒序，**时间过滤在候选之后做**。所以当一个词的文本版本数超过候选上限、
    而查询窗口又落在更早的时间时，早期的命中根本进不了子串复核。
    结果里的 `ftsCandidatesTruncated` 会报 `true`（调用方能区分「确实没有」与「没看完」）。
    本轮 55 题查询集里最多的一题 120 个版本（`eval.json` 的 `max_fts_candidates`），
    没有任何一题触发（`fts_candidates_truncated_queries` 是空的）；
    把上限压到 3 就能复现：同一条查询同一个库，默认 10 条命中 → 上限 3 时 0 条、`truncated = true`
    （`results/truncation_default.json` vs `truncation_limit3.json`，
    单测 `testFTSCandidateTruncationOnEarlyWindowIsReported`）。
    真正的修法是把时间约束推进候选选取（需要 `vrow ↔ 时间` 的映射，`created_at` 是写入墙钟不能用），
    归 M2 与向量 / 排序一起做。
