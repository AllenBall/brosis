import Foundation

/// Schema v1：计划 3.2 的全部表 + 3.12 的 `app_policies` + 本包自加的 `meta` / `migrations` /
/// `capture_stats`。写法以 D22 / D23 为准（tools/proto/sqlcipher/Sources/SQLCipherProbe/Schema.swift
/// 是它的子集原型），并把 tools/proto/schema.sql 里那些 D22 之前的旧写法（external content FTS +
/// 触发器、sha256 存 hex TEXT）全部换掉。
public enum Schema {

    /// 库里写的 schema 版本。改表结构必须同时加一条 `migrations` 行并把这个数 +1。
    public static let version = 1

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

    /// D8 通过后才建。本版本不建、不注册 sqlite-vec，只保证它静态链接进来（3.4）。
    static let createVec = """
    CREATE VIRTUAL TABLE vec_text USING vec0(
      text_rowid INTEGER PRIMARY KEY,
      embedding int8[512]
    );
    """

    /// 3.2 里必须存在的表（含 3.12 的 app_policies 与本包自加的三张），`Store.open` 用它自检。
    public static let expectedTables = [
        "apps", "app_policies", "capture_stats", "deletions", "files", "grants", "jobs",
        "ledgers", "meta", "migrations", "observations", "occurrences", "sessions",
        "text_fts", "text_versions", "urls", "windows",
    ]
}
