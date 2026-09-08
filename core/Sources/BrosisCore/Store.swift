import Foundation
import SQLCipher
import CBrosisSQLite

/// 存储服务的选项。
public struct StoreOptions: Sendable {
    /// 库文件名（目录内）。
    public var databaseFileName: String = "brosis.db"
    /// 目录不存在时是否创建；库文件不存在时是否建库。
    public var createIfMissing: Bool = true
    /// `PRAGMA cipher_memory_security`：给 SQLCipher 的分配器加 mlock + 释放前清零。
    /// E6 实测写入慢 1.38×，D25 定为"可选严格项"，默认关。
    /// **注意**：它必须在进程里第一次分配加密上下文之前生效，所以只有本进程第一次开库时设置才可靠。
    public var cipherMemorySecurity: Bool = false
    /// 页缓存（KiB，取负值传给 `PRAGMA cache_size`）。E6 §5.2：加密库上扫描型查询靠它，
    /// 128 MiB 让 KNN 从 11.4 ms 降到 3.9 ms，比换 crypto 后端还管用。
    public var cacheSizeKiB: Int = 131_072
    public var busyTimeoutMS: Int32 = 5_000
    /// 配额（原文净载荷字节）。默认 10 GiB = 10 × 2^30。
    public var quotaBytes: Int = 10 * 1024 * 1024 * 1024
    /// 到达配额的这个比例就回调提示（3.8：80% 提示）。
    public var quotaWarnRatio: Double = 0.8
    /// 首次建库时写入的 device_id；nil 表示生成一个 UUID（D17：每台机器一个）。
    public var deviceID: String?
    /// `capture_stats` 遥测保留天数，`maintenance()` 按它滚动清理。
    public var captureStatsRetentionDays: Int = 30
    /// `mcp_audit` 保留天数（3.6 的调用审计），`maintenance()` 按它滚动清理。
    /// 比遥测留得久：授权与访问记录是要能回溯的，而它每行只有几十字节。
    public var mcpAuditRetentionDays: Int = 90
    /// `capture_audit` 保留天数（3.3 的采样审计），`maintenance()` 按它滚动清理。
    /// 与 MCP 审计同档：它是"AX 覆盖率随时间怎么变"的曲线，跨月对比才有意义。
    public var captureAuditRetentionDays: Int = 90

    public init() {}
}

/// 单一存储服务：唯一持钥者，负责开库、写入、索引、删除级联、配额、维护、统计。
///
/// 并发口径：内部一条连接、一把锁，所有公开方法串行。
/// 评审 F1 / 3.1 要求"单一存储服务持钥"，所以这里不做多连接读写分离（留给 M2 按实测决定）。
public final class Store: @unchecked Sendable {

    // MARK: - 状态

    private let lock = NSLock()
    private var conn: SQLiteConnection
    private var key: SecureKey
    let options: StoreOptions

    /// 数据目录（0700，已排除 TM / Spotlight）。
    public let directory: URL
    /// 库文件路径。
    public let databaseURL: URL
    /// 本机设备标识（D17）。
    public private(set) var deviceID: String
    /// 缩略图目录：`<db>.thumbs/`。
    public var thumbnailDirectory: URL { URL(fileURLWithPath: databaseURL.path + ".thumbs") }

    /// 单调计数器（每次写入事务内一起持久化到 `meta`，崩溃时与数据一起回滚）。
    struct Counters {
        var observation: Int64 = 1
        var textVersion: Int64 = 1
        var occurrence: Int64 = 1
        var deletion: Int64 = 1
        var vrow: Int64 = 1       // D23：本机私有代理 rowid，不复用
    }
    var counters = Counters()

    /// 库里出现过「原文经 NFKC 折叠会变样」的正文吗（全角标点 / 全角字母 / 兼容汉字…）。
    /// 写入时顺手记进 `meta.has_compat_text`，**只置位不清位**。
    ///
    /// 用途只有一个：1–2 字扫描通道在**原文**上做 `LIKE`，为了让半角查询也能命中全角原文，
    /// 要把查询串展开成兼容区的各种写法一起匹配——那是按模式条数线性变慢的
    /// （1 个月合成库上同一条 ASCII 两字查询：1 个 `LIKE` 117.4 ms → 9 个 721.0 ms）。
    /// 从来没写进过这类正文的库根本不需要展开，这个标志就是用来跳过它的。
    /// 事务回滚时内存里的标志不会跟着回滚，方向是**保守的**（多展开一次，不会漏召回）。
    public private(set) var hasCompatibilityText = false

    /// 配额到达 `quotaWarnRatio` 时的回调（3.8：80% 提示）。在 `expire` 内同步调用。
    public var quotaWarningHandler: (@Sendable (_ used: Int, _ quota: Int) -> Void)?

    /// 检索层参数（3.4）。开库后、开始查询前设置；改它不是线程安全的。
    public var retrieval = RetrievalOptions()

    /// 3.7 的三个会话常量。**可配置参数，不是已验证结论**；改了要重建会话（`buildSessions(force: true)`）。
    public var sessionConfig = SessionConfig()

    // MARK: - sqlite-vec 注册（M2 c / T11）

    /// 把 sqlite-vec 注册成 auto extension，**进程内只做一次**。
    /// `true` = `sqlite3_auto_extension` 返回 `SQLITE_OK`，此后每条新连接都带 `vec0` 与 `vec_*` 函数。
    ///
    /// v3 之前它只是静态链接进来「保证能链接」（3.4）；v4 起真的注册，
    /// 因为 `vec_chunks` 是 `vec0` 虚拟表，不注册就连建表都建不出来。
    public static let sqliteVecRegistered: Bool = (brosis_register_vec() == SQLITE_OK)

    /// 静态编入的 sqlite-vec 版本（不需要开库就能问）。
    public static var sqliteVecVersion: String { String(cString: brosis_vec_version()) }

    // MARK: - 打开

    /// 打开（或创建）加密库。
    ///
    /// 连接序言的顺序是固定的，不能改（D25 / E6 §7.1）：
    /// ```
    /// [PRAGMA cipher_memory_security]   -- 可选，必须在第一次分配加密上下文之前
    /// PRAGMA key = "x'…'"               -- 256 位原始密钥，跳过 PBKDF2
    /// PRAGMA cipher_page_size = 16384   -- 不写进文件头！不重设会报 file is not a database
    /// PRAGMA journal_mode = WAL
    /// PRAGMA synchronous = NORMAL
    /// PRAGMA foreign_keys = ON          -- 连接级，每次都要
    /// PRAGMA auto_vacuum = INCREMENTAL  -- 仅建库时，且必须在建第一张表之前
    /// SELECT count(*) FROM sqlite_schema -- 首次真读，密钥错在这里暴露
    /// ```
    public static func open(directory: URL,
                            keyProvider: KeyProvider,
                            options: StoreOptions = StoreOptions()) throws -> Store {
        try Store(directory: directory, keyProvider: keyProvider, options: options)
    }

    private init(directory: URL, keyProvider: KeyProvider, options: StoreOptions) throws {
        self.options = options

        // —— D16：先拒绝同步盘，再碰文件系统 ——
        try DataDirectory.validate(directory)
        let resolved = directory.standardizedFileURL
        if options.createIfMissing {
            try DataDirectory.prepare(resolved)
        } else if !FileManager.default.fileExists(atPath: resolved.path) {
            throw StoreError.filesystem("数据目录不存在：\(resolved.lastPathComponent)")
        }
        self.directory = resolved
        self.databaseURL = resolved.appendingPathComponent(options.databaseFileName, isDirectory: false)

        let isNew = !FileManager.default.fileExists(atPath: databaseURL.path)
        if isNew && !options.createIfMissing {
            throw StoreError.filesystem("库文件不存在：\(options.databaseFileName)")
        }

        // —— 取钥并立刻拷进可清零缓冲区 ——
        var raw = try keyProvider.fetchKey()
        defer { brosisZeroize(&raw) }
        self.key = try SecureKey(raw)

        // M2 c / T11：sqlite-vec 必须在**建连接之前**注册（`sqlite3_auto_extension` 只对之后
        // 新建的连接生效）。`static let` 保证进程内只跑一次、且线程安全。
        // 它只往连接上挂函数与虚拟表模块，不碰库文件，所以排在 `PRAGMA key` 之前没有问题。
        _ = Store.sqliteVecRegistered

        self.conn = try SQLiteConnection(path: databaseURL.path, createIfMissing: options.createIfMissing)
        self.deviceID = ""       // 建库 / 读库后填
        do {
            sqlite3_busy_timeout(conn.handle, options.busyTimeoutMS)
            try applyPreamble(creating: isNew)
            if isNew {
                try createSchema(deviceID: options.deviceID ?? UUID().uuidString)
            } else {
                try migrateIfNeeded()
            }
            try loadIdentity()
            try loadCounters()
            try loadCompatibilityFlag()
        } catch {
            conn.close()
            key.zeroize()
            // 建库中途失败留下的半个文件要清掉，否则下次开库会当成"已存在的库"。
            if isNew { try? FileManager.default.removeItem(at: databaseURL) }
            throw error
        }
    }

    /// 连接序言。顺序见 `open` 的文档注释。
    private func applyPreamble(creating: Bool) throws {
        if options.cipherMemorySecurity {
            // 必须在 PRAGMA key 之前：key 那一步会分配第一个加密上下文。
            let r = conn.tryExec("PRAGMA cipher_memory_security = ON;")
            if r.rc != SQLITE_OK {
                throw StoreError.sqlite(op: "PRAGMA cipher_memory_security", code: r.rc, message: r.message)
            }
        }
        try key.applyKey(to: conn.handle!)
        try execExpectingKeyErrors("PRAGMA cipher_page_size = \(Schema.pageSize);")
        if creating {
            // 【实测修正】auto_vacuum 必须排在 journal_mode 之前。
            // 它是文件级设置，只在**页 1 还没写出去**时可改。`PRAGMA journal_mode = WAL`
            // 是一次模式切换，会把页 1（此时 auto_vacuum = 0）落盘，之后再设 INCREMENTAL 就静默无效。
            // 本机实测：按 key → cipher_page_size → WAL → synchronous → foreign_keys → auto_vacuum
            // 的顺序建库，`PRAGMA auto_vacuum` 读回 **0**；把这一行提到 WAL 之前读回 **2**。
            // tools/proto/schema.sql 与 M0 探针的 Schema.preamble 也都是这个顺序。
            try execExpectingKeyErrors("PRAGMA auto_vacuum = INCREMENTAL;")
        }
        try execExpectingKeyErrors("PRAGMA journal_mode = WAL;")
        try execExpectingKeyErrors("PRAGMA synchronous = NORMAL;")
        try execExpectingKeyErrors("PRAGMA foreign_keys = ON;")
        // 首次真读：密钥错误 / cipher_page_size 不匹配都在这里暴露。
        try execExpectingKeyErrors("SELECT count(*) FROM sqlite_schema;")

        // 以下不属于"固定序言"，是性能与安全的连接级设置。
        try conn.exec("PRAGMA secure_delete = ON;")               // 3.8：覆写页内残留
        try conn.exec("PRAGMA cache_size = -\(options.cacheSizeKiB);")
    }

    /// 把 `SQLITE_NOTADB` 翻译成"密钥错误或损坏"，别的错误照原样抛。
    private func execExpectingKeyErrors(_ sql: String) throws {
        let r = conn.tryExec(sql)
        guard r.rc != SQLITE_OK else { return }
        if r.rc == SQLITE_NOTADB {
            throw StoreError.wrongKeyOrCorrupt(code: r.rc, message: r.message)
        }
        throw StoreError.sqlite(op: "序言 \(sql)", code: r.rc, message: r.message)
    }

    // MARK: - 建库 / 读库

    private func createSchema(deviceID: String) throws {
        try conn.transaction {
            try conn.exec(Schema.createTables)
            try conn.exec(Schema.createFTS)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            try conn.run("INSERT INTO meta(key, value) VALUES ('schema_version', ?);",
                         [.text(String(Schema.version))])
            try conn.run("INSERT INTO meta(key, value) VALUES ('device_id', ?);", [.text(deviceID)])
            try conn.run("INSERT INTO meta(key, value) VALUES ('created_at', ?);",
                         [.text(String(now))])
            try conn.run("INSERT INTO meta(key, value) VALUES ('fts_scheme', ?);",
                         [.text("bigram+unicode61 remove_diacritics 2, contentless, contentless_delete=1 (D22)")])
            try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?);",
                         [.int(1), .int(now),
                          .text("初始 schema v1：计划 3.2 全部表 + 3.12 app_policies + meta/migrations/capture_stats")])
            // v2 与 v1 一起建（新库不需要"先建 v1 再迁移"），但审计行照样写两条，
            // 好让"这个库是哪一版建的 / 迁过哪几版"在 migrations 表里一目了然。
            try conn.exec(Schema.createMCPAudit)
            try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?);",
                         [.int(2), .int(now), .text("v2：mcp_audit（3.6 MCP 调用审计）")])
            // v3 同理：`occurrences` 的两列已经写在 createTables 里（新库直接带上），
            // 这里只建 capture_audit 并补审计行。
            try conn.exec(Schema.createCaptureAudit)
            try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?);",
                         [.int(3), .int(now),
                          .text("v3：capture_audit（3.3 采样审计）+ occurrences.confidence / note（D24）")])
            // v4（M2 c / T11）：分块与向量索引。表建出来但默认空、检索开关默认关。
            try conn.exec(SchemaV4.createChunks)
            try conn.exec(SchemaV4.createVecChunks)
            try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?);",
                         [.int(4), .int(now),
                          .text("v4：chunks + vec_chunks（3.4 向量检索 / 4.3 嵌入任务，"
                                + "\(SchemaV4.elementType)[\(SchemaV4.dimension)] cosine）")])
            // v5（M2 c / T13）：D17 跨设备同步。新库直接把两张表与三个索引建上；
            // `observations` / `deletions` 的三个新列已经写在 createTables 里。
            try conn.exec(SyncSchema.createAllForNewDatabase)
            try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?);",
                         [.int(5), .int(now),
                          .text("v5：sync_state + sync_peers + observations.origin_device / origin_id"
                                + " + deletions.targets（3.9 跨设备同步，D17）")])
            // v6（M2 c / T12）：`ledgers.narrative_meta` 已经写在 createTables 里，
            // 新库这里只补审计行。
            try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?);",
                         [.int(6), .int(now), .text(SchemaV6.note)])
        }
    }

    /// 已有库的 schema 迁移。走 `migrations` 表，一版一个事务，失败整版回滚。
    ///
    /// 只在库文件已存在时调用。迁移只做**纯新增**：加表，或给已有表加**可空**列——
    /// v1 的库补一张 `mcp_audit` 就是 v2，再补 `capture_audit` 与 `occurrences` 的两个可空列
    /// 就是 v3；不重写数据、不改已有列的语义，用户不用重建库、不丢数据。
    private func migrateIfNeeded() throws {
        guard let text = try conn.scalarText("SELECT value FROM meta WHERE key = 'schema_version';"),
              let found = Int(text) else {
            throw StoreError.invalidUsage("库里没有 meta.schema_version，可能不是 brosis 的库")
        }
        guard found != Schema.version else { return }
        // 只往前迁；库比本版本更新说明是别的版本的 app 建的，直接报错而不是硬开。
        guard found < Schema.version else {
            throw StoreError.schemaVersion(found: found, expected: Schema.version)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if found < 2 {
            try conn.transaction {
                try conn.exec(Schema.createMCPAudit)
                try conn.run("UPDATE meta SET value = '2' WHERE key = 'schema_version';")
                try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?);",
                             [.int(2), .int(now),
                              .text("v2：mcp_audit（3.6 MCP 调用审计），由 v\(found) 就地迁移")])
            }
        }
        if found < 3 {
            try conn.transaction {
                // 建表与加列都**先查再做**：迁移要能被中断后重跑，也要容得下
                // "库里已经有这张表 / 这一列"的情况（例如从更老的版本一路迁上来）。
                let tables = Set(try conn.textColumn(
                    "SELECT name FROM sqlite_schema WHERE type = 'table';"))
                if !tables.contains("capture_audit") { try conn.exec(Schema.createCaptureAudit) }
                let columns = Set(try conn.textColumn(
                    "SELECT name FROM pragma_table_info('occurrences');"))
                for item in Schema.alterOccurrencesV3 where !columns.contains(item.column) {
                    try conn.exec(item.sql)
                }
                try conn.run("UPDATE meta SET value = '3' WHERE key = 'schema_version';")
                try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?);",
                             [.int(3), .int(now),
                              .text("v3：capture_audit（3.3 采样审计）+ occurrences.confidence / note"
                                    + "（D24），由 v\(found) 就地迁移")])
            }
        }
        // v4（M2 c / T11）：chunks + vec_chunks。纯新增两张表，老库就地补建、不重建、不丢数据。
        if found < 4 {
            try conn.transaction {
                let tables = Set(try conn.textColumn(
                    "SELECT name FROM sqlite_schema WHERE type = 'table';"))
                if !tables.contains("chunks") { try conn.exec(SchemaV4.createChunks) }
                if !tables.contains("vec_chunks") { try conn.exec(SchemaV4.createVecChunks) }
                try conn.run("UPDATE meta SET value = '4' WHERE key = 'schema_version';")
                // 审计行也要能重跑：`migrations.version` 是主键，库里已经有 v4 那一行时
                // （例如只把 meta.schema_version 手工回滚过）直接 INSERT 会撞唯一约束。
                try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?) "
                           + "ON CONFLICT(version) DO UPDATE "
                           + "SET applied_at = excluded.applied_at, note = excluded.note;",
                             [.int(4), .int(now),
                              .text("v4：chunks + vec_chunks（3.4 向量检索 / 4.3 嵌入任务，"
                                    + "\(SchemaV4.elementType)[\(SchemaV4.dimension)] cosine），"
                                    + "由 v\(found) 就地迁移")])
            }
        }
        // v5（M2 c / T13）：D17 跨设备同步。两张新表 + 三个可空列 + 三个索引，全部纯新增。
        if found < 5 {
            try conn.transaction {
                let tables = Set(try conn.textColumn(
                    "SELECT name FROM sqlite_schema WHERE type = 'table';"))
                if !tables.contains("sync_state") { try conn.exec(SyncSchema.createSyncState) }
                if !tables.contains("sync_peers") { try conn.exec(SyncSchema.createSyncPeers) }
                let obsColumns = Set(try conn.textColumn(
                    "SELECT name FROM pragma_table_info('observations');"))
                for item in SyncSchema.alterObservationsV5 where !obsColumns.contains(item.column) {
                    try conn.exec(item.sql)
                }
                let delColumns = Set(try conn.textColumn(
                    "SELECT name FROM pragma_table_info('deletions');"))
                for item in SyncSchema.alterDeletionsV5 where !delColumns.contains(item.column) {
                    try conn.exec(item.sql)
                }
                let indexes = Set(try conn.textColumn(
                    "SELECT name FROM sqlite_schema WHERE type = 'index';"))
                for item in SyncSchema.createIndexes where !indexes.contains(item.name) {
                    try conn.exec(item.sql)
                }
                try conn.run("UPDATE meta SET value = '5' WHERE key = 'schema_version';")
                try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?);",
                             [.int(5), .int(now),
                              .text("v5：sync_state + sync_peers + observations.origin_device /"
                                    + " origin_id + deletions.targets（3.9 跨设备同步，D17），"
                                    + "由 v\(found) 就地迁移")])
            }
        }
        // v6（M2 c / T12）：ledgers 补一列可空的 narrative_meta。纯新增，先查再加，能重跑。
        if found < 6 {
            try conn.transaction {
                let columns = Set(try conn.textColumn(
                    "SELECT name FROM pragma_table_info('ledgers');"))
                for item in SchemaV6.alterLedgersV6 where !columns.contains(item.column) {
                    try conn.exec(item.sql)
                }
                try conn.run("UPDATE meta SET value = '6' WHERE key = 'schema_version';")
                try conn.run("INSERT INTO migrations(version, applied_at, note) VALUES (?,?,?) "
                           + "ON CONFLICT(version) DO UPDATE "
                           + "SET applied_at = excluded.applied_at, note = excluded.note;",
                             [.int(6), .int(now), .text(SchemaV6.note + "，由 v\(found) 就地迁移")])
            }
        }
    }

    private func loadIdentity() throws {
        guard let versionText = try conn.scalarText("SELECT value FROM meta WHERE key = 'schema_version';"),
              let version = Int(versionText) else {
            throw StoreError.invalidUsage("库里没有 meta.schema_version，可能不是 brosis 的库")
        }
        guard version == Schema.version else {
            throw StoreError.schemaVersion(found: version, expected: Schema.version)
        }
        guard let device = try conn.scalarText("SELECT value FROM meta WHERE key = 'device_id';") else {
            throw StoreError.invalidUsage("库里没有 meta.device_id")
        }
        deviceID = device

        // 表自检：3.2 的表少一张就说明库被人改过。
        let present = Set(try conn.textColumn(
            "SELECT name FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%';"))
        let missing = Schema.expectedTables.filter { !present.contains($0) }
        guard missing.isEmpty else {
            throw StoreError.invalidUsage("库里缺少表：\(missing.joined(separator: ", "))")
        }
    }

    private func loadCompatibilityFlag() throws {
        hasCompatibilityText =
            (try conn.scalarText("SELECT value FROM meta WHERE key = 'has_compat_text';")) == "1"
    }

    /// 第一次写进「折叠会变样」的正文时置位。在写入事务里做，和数据一起提交 / 回滚。
    func markCompatibilityText(conn: SQLiteConnection) throws {
        guard !hasCompatibilityText else { return }
        try conn.run("INSERT INTO meta(key, value) VALUES ('has_compat_text', '1') "
                     + "ON CONFLICT(key) DO UPDATE SET value = '1';")
        hasCompatibilityText = true
    }

    private func loadCounters() throws {
        func counter(_ key: String, table: String, column: String = "id") throws -> Int64 {
            let fromMeta = try conn.scalarText("SELECT value FROM meta WHERE key = ?;", [.text(key)])
                .flatMap(Int64.init) ?? 0
            let sql = column == "vrow"
                ? "SELECT COALESCE(MAX(vrow), 0) FROM \(table);"
                : "SELECT COALESCE(MAX(id), 0) FROM \(table) WHERE device_id = ?;"
            let binds: [SQLValue] = column == "vrow" ? [] : [.text(deviceID)]
            let fromTable = try conn.scalarInt(sql, binds) ?? 0
            return max(fromMeta, fromTable + 1)
        }
        counters.observation = try counter("next_observation_id", table: "observations")
        counters.textVersion = try counter("next_text_version_id", table: "text_versions")
        counters.occurrence = try counter("next_occurrence_id", table: "occurrences")
        counters.deletion = try counter("next_deletion_id", table: "deletions")
        counters.vrow = try counter("next_vrow", table: "text_versions", column: "vrow")
    }

    /// 在当前事务里把计数器写回 `meta`，和数据一起提交 / 回滚。
    func persistCounters() throws {
        let pairs: [(String, Int64)] = [
            ("next_observation_id", counters.observation),
            ("next_text_version_id", counters.textVersion),
            ("next_occurrence_id", counters.occurrence),
            ("next_deletion_id", counters.deletion),
            ("next_vrow", counters.vrow),
        ]
        for (k, v) in pairs {
            try conn.run("INSERT INTO meta(key, value) VALUES (?, ?) "
                       + "ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                         [.text(k), .text(String(v))])
        }
    }

    // MARK: - 关闭

    /// `locking`：checkpoint、关库、清零密钥（3.5）。可重复调用。
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closeUnlocked()
    }

    private var closed = false

    private func closeUnlocked() {
        guard !closed else { return }
        closed = true
        _ = conn.tryExec("PRAGMA wal_checkpoint(TRUNCATE);")
        conn.close()
        key.zeroize()
    }

    deinit { closeUnlocked() }

    /// 供测试与自检：密钥缓冲区是否已清零。
    public var keyIsZeroized: Bool { key.wasZeroized && key.isAllZero }

    // MARK: - 内部访问

    /// 所有公开方法都经它串行化；内部实现之间直接互相调用，不再取锁。
    func withLock<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, conn.handle != nil else {
            throw StoreError.invalidUsage("库已关闭")
        }
        return try body(conn)
    }

    // MARK: - 环境自检（compile_options 等）

    /// 编译开关与运行期配置的核对，`brosis-store init --verify` 与测试用。
    public struct BuildInfo: Sendable, Codable {
        public var sqliteVersion: String
        public var cipherVersion: String
        public var cipherProvider: String
        public var sqliteVecVersion: String
        public var compileOptions: [String]
        public var cipherPageSize: Int
        public var journalMode: String
        public var autoVacuum: Int
        public var foreignKeys: Int
        public var secureDelete: Int
        public var tempStoreCompiled: Int      // 编译期 TEMP_STORE（3 = 强制内存，D25）
        public var cipherMemorySecurity: Int
        public var pageSize: Int
    }

    public func buildInfo() throws -> BuildInfo {
        try withLock { conn in
            let options = try conn.textColumn("PRAGMA compile_options;")
            let tempStore = options.first(where: { $0.hasPrefix("TEMP_STORE=") })
                .flatMap { Int($0.dropFirst("TEMP_STORE=".count)) } ?? -1
            return BuildInfo(
                sqliteVersion: try conn.scalarText("SELECT sqlite_version();") ?? "?",
                cipherVersion: try conn.scalarText("PRAGMA cipher_version;") ?? "?",
                cipherProvider: try conn.scalarText("PRAGMA cipher_provider;") ?? "?",
                sqliteVecVersion: String(cString: brosis_vec_version()),
                compileOptions: options,
                cipherPageSize: Int(try conn.scalarInt("PRAGMA cipher_page_size;") ?? -1),
                journalMode: try conn.scalarText("PRAGMA journal_mode;") ?? "?",
                autoVacuum: Int(try conn.scalarInt("PRAGMA auto_vacuum;") ?? -1),
                foreignKeys: Int(try conn.scalarInt("PRAGMA foreign_keys;") ?? -1),
                secureDelete: Int(try conn.scalarInt("PRAGMA secure_delete;") ?? -1),
                tempStoreCompiled: tempStore,
                cipherMemorySecurity: Int(try conn.scalarInt("PRAGMA cipher_memory_security;") ?? -1),
                pageSize: Int(try conn.scalarInt("PRAGMA page_size;") ?? -1)
            )
        }
    }
}
