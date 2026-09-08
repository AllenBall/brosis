import Foundation

/// Schema v1：计划 3.2 的全部表 + 3.12 的 `app_policies` + 本包自加的 `meta` / `migrations` /
/// `capture_stats`。写法以 D22 / D23 为准（tools/proto/sqlcipher/Sources/SQLCipherProbe/Schema.swift
/// 是它的子集原型），并把 tools/proto/schema.sql 里那些 D22 之前的旧写法（external content FTS +
/// 触发器、sha256 存 hex TEXT）全部换掉。
public enum Schema {

    /// 库里写的 schema 版本。改表结构必须同时加一条 `migrations` 行并把这个数 +1。
    ///
    /// - v1：3.2 全部表 + 3.12 `app_policies` + `meta` / `migrations` / `capture_stats`。
    /// - v2（M1 R2 / T5）：`mcp_audit`（3.6「审计：每次调用记录客户端、工具、参数摘要、返回条数」
    ///   + 2.2 硬约束 4）。老库开库时由 `Store.migrateIfNeeded` 就地补建，不用重建库。
    /// - v3（M1 R2 / T8）：`capture_audit`（3.3「采样审计：AX 非空的观察每 N 次取一次全窗口 OCR
    ///   对照，计算覆盖率写入审计表」）+ `occurrences` 两个可空列 `confidence` / `note`
    ///   （视口 OCR 的片段置信度与低置信 token 计数，D24）。两处都是纯新增，老库 ALTER 就地迁移。
    /// - v4（M2 c / T11）：`chunks` + `vec_chunks`（3.4「向量检索」、4.3「若 D8 通过：嵌入任务、
    ///   sqlite-vec、混合检索」）。SQL 与口径见 `SchemaV4`；两张表都是**本机派生数据**，
    ///   删了能重建、不参与 D17 同步。纯新增，老库就地补建。
    /// - v5（M2 c / T13）：D17 跨设备同步（3.9）。`sync_state` / `sync_peers` 两张新表、
    ///   `observations` 的 `origin_device` / `origin_id` 两个可空列、`deletions.targets`
    ///   一个可空列、三个索引。SQL 与口径（尤其是"入站记录用哪一个 (device_id, id)"）
    ///   见 `SyncSchema`。纯新增，老库 ALTER 就地迁移。
    /// - v6（M2 c / T12）：`ledgers.narrative_meta`（4.3「可选叙述」、3.7「输出与台账分开标注」）。
    ///   一列可空 TEXT，存 `NarrativeMeta` 的 JSON。SQL 与口径见 `SchemaV6`。纯新增，老库 ALTER。
    /// - v8（M2 d / T16）：`export_imports`（3.8「加密导出」、D7「删前通知并可先加密导出」）。
    ///   一张新表，记这个库导入过哪些归档——恢复模式写回的是源 id，逐条判据认不出重复，
    ///   所以再加一层归档粒度的幂等。SQL 与口径见 `SchemaV8`。纯新增，老库就地补建。
    ///   （v7 是 M2 d 批留给 T15 的号；T15 没有用到就空着，`migrations` 表里也不会有那一行。）
    public static let version = 9

    /// `migrations` 表里**实际会出现**的版本号，升序。
    ///
    /// 它不一定连续：M2 d 批把 v7 / v8 / v9 分给三个并行任务，"用不到就不占"，
    /// 于是没被认领的号会留成空洞（当前 v7 空着——它是留给 T15 的）。
    /// 建库与迁移各写各的审计行，这里是唯一一份清单，测试按它断言。
    public static let migrationVersions = [1, 2, 3, 4, 5, 6, 8, 9]

    /// 页大小（D23：16384，比 4096 省约 10%）。加密库用 `cipher_page_size`。
    public static let pageSize = 16384

    // MARK: - 建表

    /// 顺序有讲究：`auto_vacuum` 必须在建第一张表之前设好（`Store.open` 的连接序言负责）。
    static let createTables = """
    ------------------------------------------------------------------ 元数据
    -- 3.2 没列，本包自加：设备身份、schema 版本、配额参数。本机配置，不同步。
    CREATE TABLE meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    -- 迁移审计：每次 schema 变更一行，便于排查"库是哪一版建的"。
    CREATE TABLE migrations (
      version    INTEGER PRIMARY KEY,
      applied_at INTEGER NOT NULL,
      note       TEXT NOT NULL
    );

    ------------------------------------------------- 规范化对象（对象身份 ≠ 内容版本）
    CREATE TABLE apps (
      id        INTEGER PRIMARY KEY,
      bundle_id TEXT NOT NULL UNIQUE COLLATE NOCASE,
      name      TEXT NOT NULL
    );

    CREATE TABLE windows (
      id     INTEGER PRIMARY KEY,
      app_id INTEGER NOT NULL REFERENCES apps(id) ON DELETE RESTRICT,
      title  TEXT NOT NULL COLLATE NOCASE,
      UNIQUE (app_id, title)
    );
    -- 标题走前缀 / LIKE，不进 FTS（3.4 第一条）
    CREATE INDEX idx_windows_title ON windows(title);

    -- 规范化不删有业务语义的查询参数和 hash 路由；raw_locator 永远保留原样（3.2）。
    -- D22：COLLATE NOCASE 必须写在【列】上，只给索引加等值查询走不了索引。
    CREATE TABLE urls (
      id            INTEGER PRIMARY KEY,
      raw_locator   TEXT NOT NULL UNIQUE,
      canonical_url TEXT NOT NULL COLLATE NOCASE,
      host          TEXT COLLATE NOCASE,
      kind          TEXT NOT NULL CHECK (kind IN ('web','file','deeplink','doc','other'))
    );
    CREATE INDEX idx_urls_host      ON urls(host);
    CREATE INDEX idx_urls_canonical ON urls(canonical_url);

    CREATE TABLE files (
      id   INTEGER PRIMARY KEY,
      path TEXT NOT NULL UNIQUE COLLATE NOCASE
    );
    CREATE INDEX idx_files_path ON files(path);

    ------------------------------------------------------------------ 观察
    -- D17：主键从 M1 起就带 device_id，两台机器永不碰撞。
    CREATE TABLE observations (
      device_id      TEXT    NOT NULL,
      id             INTEGER NOT NULL,              -- 设备内单调递增
      ts             INTEGER NOT NULL,              -- Unix 毫秒（UTC）
      display_id     INTEGER,
      app_id         INTEGER REFERENCES apps(id)    ON DELETE RESTRICT,
      window_id      INTEGER REFERENCES windows(id) ON DELETE RESTRICT,
      url_id         INTEGER REFERENCES urls(id)    ON DELETE RESTRICT,
      file_id        INTEGER REFERENCES files(id)   ON DELETE RESTRICT,
      "trigger"      TEXT NOT NULL CHECK ("trigger" IN
                       ('app_switch','window_change','url_change','ax_notification',
                        'frame_dirty','timer','manual')),
      capture_method TEXT NOT NULL CHECK (capture_method IN ('ax','ocr','adapter','mixed')),
      completeness   TEXT NOT NULL CHECK (completeness IN
                       ('complete','partial','unavailable','excluded')),
      visible_range  TEXT,                          -- JSON：视口内实际显示的范围（3.3）
      source_state   TEXT NOT NULL CHECK (source_state IN
                       ('ok','permission_lost','timeout','user_idle','secure_input','locked')),
      frame_hash     TEXT,                          -- dHash，只用于是否触发内容检查
      thumb_ref      TEXT,                          -- 缩略图相对路径，删除时一并清理
      deleted_at     INTEGER,                       -- 用户删除墓碑（毫秒）；NULL = 有效
      -- v5 / D17：这条记录的**来源**。NULL = 本机产生（出站集合、会话构建集合都是它）；
      -- 非 NULL = 从别的设备导入的副本，(origin_device, origin_id) 是它的全局身份。
      -- 为什么入站记录不直接沿用源设备的 (device_id, id)：见 SyncSchema.swift 的文件头。
      origin_device  TEXT,
      origin_id      INTEGER,
      PRIMARY KEY (device_id, id)
    );
    CREATE INDEX idx_obs_ts      ON observations(ts);
    CREATE INDEX idx_obs_app_ts  ON observations(app_id, ts);
    CREATE INDEX idx_obs_url_ts  ON observations(url_id, ts);
    CREATE INDEX idx_obs_file_ts ON observations(file_id, ts);
    CREATE INDEX idx_obs_live    ON observations(device_id, ts) WHERE deleted_at IS NULL;
    CREATE INDEX idx_obs_deleted ON observations(deleted_at) WHERE deleted_at IS NOT NULL;

    ------------------------------------------------------------ 文本版本（不可变）
    -- D23：vrow 是本机私有代理 rowid（不参与 D17 同步），FTS 行按它对齐；
    --      sha256 存 32 字节 BLOB（不是 hex TEXT）。
    CREATE TABLE text_versions (
      vrow       INTEGER PRIMARY KEY,     -- = rowid，本机内不复用
      device_id  TEXT    NOT NULL,
      id         INTEGER NOT NULL,
      sha256     BLOB    NOT NULL,        -- **原文** UTF-8 字节的 SHA-256（不折叠：证据要原样）
      text       TEXT    NOT NULL,        -- v1 存完整原文，不分块、不做 NFKC 折叠（3.2）
      byte_len   INTEGER NOT NULL,        -- 原文 UTF-8 字节数，容量口径（2.4）
      created_at INTEGER NOT NULL,
      UNIQUE (device_id, id),             -- 业务主键
      UNIQUE (device_id, sha256)          -- 精确哈希复用：同一设备内**逐字节相同**的文本只有一行
                                          --（全角写法与半角写法是两个版本；NFKC 折叠只用于索引）
    );

    -- 不可变：只允许 INSERT / DELETE，任何 UPDATE 直接 ABORT。
    CREATE TRIGGER trg_text_versions_immutable
    BEFORE UPDATE ON text_versions
    BEGIN
      SELECT RAISE(ABORT, 'text_versions is immutable: insert a new version instead');
    END;

    ------------------------------------------------------------------ 出现记录
    CREATE TABLE occurrences (
      device_id       TEXT    NOT NULL,
      id              INTEGER NOT NULL,
      observation_id  INTEGER NOT NULL,
      text_version_id INTEGER NOT NULL,
      region          TEXT,                -- JSON：{"x":..,"y":..,"w":..,"h":..} 或 AX 路径
      ord             INTEGER NOT NULL,    -- 观察内的有序片段序号，重建原文用
      confidence      REAL,                -- v3：0–1，OCR 片段才有；AX / 适配器读值为 NULL
      note            TEXT,                -- v3：区域备注（形状，不含正文），如低置信 token 计数
      PRIMARY KEY (device_id, id),
      UNIQUE (device_id, observation_id, ord),
      FOREIGN KEY (device_id, observation_id)  REFERENCES observations(device_id, id)
        ON DELETE CASCADE,                 -- 配额过期物理删观察时自动带走
      FOREIGN KEY (device_id, text_version_id) REFERENCES text_versions(device_id, id)
        ON DELETE RESTRICT                 -- 还有 occurrence 的版本删不掉（3.8 共享版本规则）
    );
    CREATE INDEX idx_occ_obs ON occurrences(device_id, observation_id);
    CREATE INDEX idx_occ_tv  ON occurrences(device_id, text_version_id);

    ------------------------------------------------------------------ 派生结果
    CREATE TABLE sessions (
      device_id      TEXT    NOT NULL,
      id             INTEGER NOT NULL,
      start          INTEGER NOT NULL,        -- 毫秒
      "end"          INTEGER NOT NULL,
      display_id     INTEGER,
      primary_app_id INTEGER REFERENCES apps(id) ON DELETE RESTRICT,
      dwell_s        REAL NOT NULL,           -- 前台停留
      active_s       REAL NOT NULL,           -- 有输入的活跃
      unknown_s      REAL NOT NULL,           -- 权限丢失 / 超时 / 锁定（3.7 三类分列）
      interruptions  INTEGER NOT NULL DEFAULT 0,
      evidence       TEXT NOT NULL,           -- JSON：观察 id 数组
      stale          INTEGER NOT NULL DEFAULT 0 CHECK (stale IN (0,1)),
      computed_at    INTEGER NOT NULL,
      PRIMARY KEY (device_id, id)
    );
    CREATE INDEX idx_sessions_range ON sessions(device_id, start, "end");

    CREATE TABLE ledgers (
      device_id   TEXT    NOT NULL,
      id          INTEGER NOT NULL,
      level       TEXT NOT NULL CHECK (level IN ('day','week')),
      period      TEXT NOT NULL,              -- 'YYYY-MM-DD' 或 'YYYY-Www'
      ledger      TEXT NOT NULL,              -- JSON：确定性台账
      narrative   TEXT,                       -- 可选叙述，与台账分开标注（3.7）
      model       TEXT,
      -- v6 / T12：叙述的标注（JSON）——生成时刻、输入 token 数、忠实度核对、
      -- 以及"依据哪一版台账写的"。定义见 `NarrativeMeta`；台账重算时与 narrative 一起置 NULL。
      narrative_meta TEXT,
      evidence    TEXT NOT NULL,              -- JSON：D23 用区间表示
      stale       INTEGER NOT NULL DEFAULT 0 CHECK (stale IN (0,1)),
      computed_at INTEGER NOT NULL,
      PRIMARY KEY (device_id, id),
      UNIQUE (device_id, level, period)
    );

    ------------------------------------------------------------------ 删除审计
    -- 三种语义分开（3.8）：user 留墓碑并随 D17 同步；quota 物理删行、审计行本身是区间墓碑，
    -- 不同步（配额是本机策略）；policy 预留给按应用策略降档时的清理。
    CREATE TABLE deletions (
      device_id             TEXT    NOT NULL,
      id                    INTEGER NOT NULL,
      kind                  TEXT NOT NULL CHECK (kind IN ('app','range','object','observation')),
      reason                TEXT NOT NULL CHECK (reason IN ('user','quota','policy')),
      params                TEXT NOT NULL,   -- JSON：可重放的删除条件
      applied_at            INTEGER NOT NULL,
      observations_affected INTEGER NOT NULL DEFAULT 0,
      occurrences_deleted   INTEGER NOT NULL DEFAULT 0,
      text_versions_deleted INTEGER NOT NULL DEFAULT 0,
      fts_rows_deleted      INTEGER NOT NULL DEFAULT 0,
      sessions_stale        INTEGER NOT NULL DEFAULT 0,
      ledgers_stale         INTEGER NOT NULL DEFAULT 0,
      thumbs_deleted        INTEGER NOT NULL DEFAULT 0,
      bytes_freed           INTEGER NOT NULL DEFAULT 0,   -- 释放的原文 UTF-8 字节
      -- v5 / D17：这次删除具体作用在哪些记录上，按来源设备分组、区间压缩的 JSON
      -- （`[{"d":设备,"r":[[lo,hi],…]},…]`）。只有 reason = 'user' 写它：对端要靠它
      -- 精确删掉**同一批**记录，而不是拿 params 在自己库上重放谓词。
      targets               TEXT,
      PRIMARY KEY (device_id, id)
    );
    CREATE INDEX idx_deletions_at ON deletions(applied_at);

    ------------------------------------------------------------------ 策略与运行时
    CREATE TABLE grants (
      client_id   TEXT PRIMARY KEY,
      mode        TEXT NOT NULL CHECK (mode IN ('strict_local','remote_allowed')),
      apps        TEXT NOT NULL,                   -- JSON 白名单；'["*"]' = 全部
      time_window INTEGER NOT NULL DEFAULT 30,     -- 天
      fields      TEXT NOT NULL CHECK (fields IN ('summary','evidence')),
      created_at  INTEGER NOT NULL
    );

    CREATE TABLE jobs (
      id         INTEGER PRIMARY KEY,
      type       TEXT NOT NULL,
      state      TEXT NOT NULL CHECK (state IN ('pending','running','done','failed','cancelled')),
      input_ref  TEXT,
      output_ref TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      error      TEXT
    );
    CREATE INDEX idx_jobs_state ON jobs(state, type);

    -- 3.12：每个应用单独勾选的采集模式。本机配置，不随 iCloud 同步。
    CREATE TABLE app_policies (
      bundle_id  TEXT PRIMARY KEY COLLATE NOCASE,
      mode       TEXT NOT NULL CHECK (mode IN ('none','events_only','events_and_content')),
      source     TEXT NOT NULL CHECK (source IN ('default','user','builtin_denylist')),
      updated_at INTEGER NOT NULL
    );

    -- 本包自加，**不是 3.2 的表、不参与 D17 同步**：承接 M0 app 骨架的 frame_stats 遥测
    -- （帧门控率、dHash 汉明距离、脏区面积比、按需截图触发原因）。
    -- 它是本机运行质量的度量，不是证据；配额过期与用户删除都不动它，maintenance() 按天数滚动清理。
    CREATE TABLE capture_stats (
      id               INTEGER PRIMARY KEY,
      ts               INTEGER NOT NULL,           -- Unix 毫秒
      display_id       INTEGER,
      status           TEXT    NOT NULL,           -- complete / failed / skipped
      "trigger"        TEXT,                       -- 按需截图的触发原因
      width            INTEGER,
      height           INTEGER,
      content_scale    REAL,
      dhash            TEXT,                       -- 64 bit，16 位十六进制
      hamming          INTEGER,                    -- 与上一 complete 帧的汉明距离
      dirty_rects      INTEGER,
      dirty_area_ratio REAL,
      gated            INTEGER NOT NULL DEFAULT 0, -- 1 = 未触发内容检查（不是丢证据）
      ax_chars         INTEGER,                    -- 该帧 AX 读到的字符数，校准回退阈值用
      ocr_regions      INTEGER
    );
    CREATE INDEX idx_capture_stats_ts ON capture_stats(ts);
    """

    // MARK: - v2 迁移：MCP 审计（3.6 / 2.2 硬约束 4）

    /// 每次 MCP 调用一行。**不存正文、不存查询串本身**：
    /// `params` 只记参数的形状（长度、条数、时间窗、粒度、bundle id 之类），
    /// 查询串只记字符数与 SHA-256 前 8 位十六进制——同一条查询能对上，内容不落库。
    ///
    /// 它是运行质量与授权的审计，**不是证据**：不参与 D17 同步、不进删除级联，
    /// 由 `maintenance()` 按 `mcpAuditRetentionDays` 滚动清理（与 `capture_stats` 同一个口径）。
    static let createMCPAudit = """
    CREATE TABLE mcp_audit (
      id           INTEGER PRIMARY KEY,
      ts           INTEGER NOT NULL,            -- Unix 毫秒
      client_id    TEXT    NOT NULL,            -- grants.client_id
      op           TEXT    NOT NULL,            -- tool / admin / ping
      tool         TEXT    NOT NULL,            -- 工具名或管理命令名
      params       TEXT    NOT NULL,            -- 参数摘要（形状，不含正文与查询串）
      decision     TEXT    NOT NULL CHECK (decision IN
                     ('ok','no_grant','denied_by_grant','rate_limited','locked','paused',
                      'unauthorized_peer','bad_request','unknown_tool','error')),
      result_count INTEGER NOT NULL DEFAULT 0,  -- 返回条数（命中 / 证据 / 分桶 / 台账行）
      peer         TEXT,                        -- uid / pid / Team ID / 签名校验结果
      elapsed_ms   REAL    NOT NULL DEFAULT 0,
      note         TEXT                         -- 被裁掉多少条、限流用量之类的补充
    );
    CREATE INDEX idx_mcp_audit_ts     ON mcp_audit(ts);
    CREATE INDEX idx_mcp_audit_client ON mcp_audit(client_id, ts);
    """

    // MARK: - v3 迁移：采样审计（3.3）+ occurrences 的置信度列（D24）

    /// 采样审计（3.3「AX 非空的观察每 N 次取一次全窗口 OCR 对照，计算覆盖率写入审计表」）。
    ///
    /// 每行 = 一次对照：同一时刻同一个窗口，AX 读到的正文 vs 全窗口 OCR 读到的正文，
    /// 覆盖率 = **AX 文本的 token 有多少比例能在 OCR 文本里找到**（去空白与标点后比较，
    /// 口径见 `CaptureCoverage.coverage(axText:ocrText:)`）。
    ///
    /// **不存正文**：只有两边的字符数、token 数、命中数与比值。它和 `capture_stats` / `mcp_audit`
    /// 一样是本机运行质量的度量，**不是证据**：不参与 D17 同步、不进删除级联，
    /// 由 `maintenance()` 按 `captureAuditRetentionDays` 滚动清理。
    ///
    /// `observation_id` 只是**弱引用**（没有外键）：审计行比观察活得久是允许的——
    /// 观察被配额过期物理删掉之后，这条"当时覆盖率是多少"的度量仍然有意义。
    static let createCaptureAudit = """
    CREATE TABLE capture_audit (
      id             INTEGER PRIMARY KEY,
      ts             INTEGER NOT NULL,           -- Unix 毫秒
      observation_id INTEGER,                    -- 弱引用 observations.id（同 device），可为空
      app            TEXT    NOT NULL,           -- bundle id
      ax_chars       INTEGER NOT NULL,           -- AX / 适配器读到的字符数
      ocr_chars      INTEGER NOT NULL,           -- 全窗口 OCR 读到的字符数
      ax_tokens      INTEGER NOT NULL,           -- AX 文本切出的 token 数（去空白与标点）
      hit_tokens     INTEGER NOT NULL,           -- 其中能在 OCR 文本里找到的 token 数
      coverage       REAL    NOT NULL,           -- hit_tokens / ax_tokens，ax_tokens = 0 时为 0
      method         TEXT    NOT NULL,           -- 被对照的那条观察的 capture_method
      region         TEXT,                       -- 被 OCR 的区域名（规则里的 region 名）
      elapsed_ms     REAL    NOT NULL DEFAULT 0  -- 这次对照 OCR 的耗时
    );
    CREATE INDEX idx_capture_audit_ts  ON capture_audit(ts);
    CREATE INDEX idx_capture_audit_app ON capture_audit(app, ts);
    """

    /// v2 → v3 给 `occurrences` 补的两列。SQLite 的 `ALTER TABLE ADD COLUMN` 只改表头、
    /// 不重写数据页，老行读回来是 NULL。
    static let alterOccurrencesV3: [(column: String, sql: String)] = [
        ("confidence", "ALTER TABLE occurrences ADD COLUMN confidence REAL;"),
        ("note", "ALTER TABLE occurrences ADD COLUMN note TEXT;"),
    ]

    // MARK: - FTS（D22）

    /// contentless（`content=''`，不重复存正文）+ `contentless_delete=1`（需要 SQLite ≥ 3.43）
    /// + `unicode61 remove_diacritics 2`。**没有触发器**：写进 FTS 的是 Swift 侧
    /// **NFKC 折叠后再 bigram 化**的文本（`TextPipeline.bigramForIndex`），SQL 触发器算不出来；
    /// 增删由存储服务显式执行，`maintenance()` 夜间对账（D22）。
    /// 折叠只到这张表为止——`text_versions.text` 存的是原文。
    /// rowid 用 `text_versions.vrow`。
    static let createFTS = """
    CREATE VIRTUAL TABLE text_fts USING fts5(
      body,
      tokenize = 'unicode61 remove_diacritics 2',
      content = '',
      contentless_delete = 1
    );
    """

    // MARK: - v4 迁移：分块与向量索引
    //
    // SQL 与全部口径（512 维的依据、int8 + cosine 的依据、删除级联）见 `SchemaV4`。
    // v3 及更早这里放的是一张占位的 `vec_text`，从来没建过；v4 起真的建 `chunks` / `vec_chunks`，
    // 占位的那份已删掉，免得留两套不一致的定义。

    /// 3.2 里必须存在的表（含 3.12 的 app_policies 与本包自加的三张），`Store.open` 用它自检。
    /// v4 起再加 `chunks` / `vec_chunks`（`SchemaV4.expectedTables`）；
    /// v5 起再加 `sync_state` / `sync_peers`（`SyncSchema.tables`）。
    public static let expectedTables = [
        "apps", "app_policies", "capture_audit", "capture_stats", "chunks", "deletions",
        "export_imports", "files",
        "grants", "jobs", "ledgers", "mcp_audit", "meta", "migrations", "observations",
        "occurrences", "sessions", "sync_peers", "sync_state", "text_fts", "text_versions",
        "urls", "vec_chunks", "windows",
    ]
}
