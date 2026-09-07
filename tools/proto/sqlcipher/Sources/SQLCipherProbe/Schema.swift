// brosis M0 / T8（E6）：计划 3.2 核心表的子集 + D22 的 contentless FTS + sqlite-vec 的 vec0 表。
// 与 tools/proto/schema.sql 的差异（都是 D22 / D23 定案，schema.sql 里还是旧写法）：
//   1. text_fts 从 external content + 触发器 改为 contentless（content=''、contentless_delete=1）
//      + unicode61，删除由存储服务显式执行（D22）；
//   2. sha256 从 hex TEXT 改为 32 字节 BLOB（D23）；
//   3. 新增 vec_text（vec0，int8[512]），对应 3.4「向量检索」与 3.2 的 vec_chunks。
enum Schema {
    /// 建库前的连接级 / 文件级 PRAGMA（顺序有讲究，见 tools/proto/README.md）。
    /// pageSizePragma 由调用方给：加密库用 cipher_page_size，明文库用 page_size。
    static func preamble(pageSizePragma: String) -> [String] {
        [
            pageSizePragma,                    // 必须在建第一张表之前
            "PRAGMA auto_vacuum = INCREMENTAL;",  // 文件级，必须在建第一张表之前
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",
            "PRAGMA foreign_keys = ON;",
            "PRAGMA secure_delete = ON;",
            "PRAGMA temp_store = MEMORY;",     // 3.5：排序/中间结果不落盘
        ]
    }

    static let tables = """
    CREATE TABLE apps (
      id INTEGER PRIMARY KEY, bundle_id TEXT NOT NULL UNIQUE, name TEXT NOT NULL);

    CREATE TABLE windows (
      id INTEGER PRIMARY KEY,
      app_id INTEGER NOT NULL REFERENCES apps(id) ON DELETE RESTRICT,
      title TEXT NOT NULL, UNIQUE (app_id, title));
    CREATE INDEX idx_windows_title ON windows(title COLLATE NOCASE);

    CREATE TABLE urls (
      id INTEGER PRIMARY KEY,
      raw_locator   TEXT NOT NULL UNIQUE,
      canonical_url TEXT NOT NULL,
      host          TEXT COLLATE NOCASE,
      kind          TEXT NOT NULL CHECK (kind IN ('web','file','deeplink','doc','other')));
    CREATE INDEX idx_urls_host ON urls(host);

    CREATE TABLE observations (
      device_id TEXT NOT NULL, id INTEGER NOT NULL, ts INTEGER NOT NULL,
      display_id INTEGER,
      app_id    INTEGER REFERENCES apps(id)    ON DELETE RESTRICT,
      window_id INTEGER REFERENCES windows(id) ON DELETE RESTRICT,
      url_id    INTEGER REFERENCES urls(id)    ON DELETE RESTRICT,
      "trigger"      TEXT NOT NULL,
      capture_method TEXT NOT NULL,
      completeness   TEXT NOT NULL,
      source_state   TEXT NOT NULL,
      deleted_at     INTEGER,
      PRIMARY KEY (device_id, id));
    CREATE INDEX idx_obs_ts     ON observations(ts);
    CREATE INDEX idx_obs_url_ts ON observations(url_id, ts);
    CREATE INDEX idx_obs_app_ts ON observations(app_id, ts);

    -- D23：sha256 存 32 字节 BLOB；vrow 是本机私有代理 rowid，不参与同步
    CREATE TABLE text_versions (
      vrow       INTEGER PRIMARY KEY,
      device_id  TEXT NOT NULL, id INTEGER NOT NULL,
      sha256     BLOB NOT NULL, text TEXT NOT NULL,
      byte_len   INTEGER NOT NULL, created_at INTEGER NOT NULL,
      UNIQUE (device_id, id), UNIQUE (device_id, sha256));

    CREATE TABLE occurrences (
      device_id TEXT NOT NULL, id INTEGER NOT NULL,
      observation_id INTEGER NOT NULL, text_version_id INTEGER NOT NULL,
      ord INTEGER NOT NULL,
      PRIMARY KEY (device_id, id),
      UNIQUE (device_id, observation_id, ord),
      FOREIGN KEY (device_id, observation_id)  REFERENCES observations(device_id, id) ON DELETE CASCADE,
      FOREIGN KEY (device_id, text_version_id) REFERENCES text_versions(device_id, id) ON DELETE RESTRICT);
    CREATE INDEX idx_occ_tv ON occurrences(device_id, text_version_id);

    CREATE TABLE sessions (
      device_id TEXT NOT NULL, id INTEGER NOT NULL,
      start INTEGER NOT NULL, "end" INTEGER NOT NULL,
      primary_app_id INTEGER REFERENCES apps(id) ON DELETE RESTRICT,
      dwell_s REAL NOT NULL, active_s REAL NOT NULL, unknown_s REAL NOT NULL,
      evidence TEXT NOT NULL, stale INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (device_id, id));
    CREATE INDEX idx_sessions_range ON sessions(device_id, start, "end");
    """

    /// D22：contentless（不重复存正文）+ contentless_delete=1（需要 SQLite ≥ 3.43）+ unicode61。
    /// 不建触发器：FTS 维护由存储服务显式执行，夜间与 text_versions 对账。
    static let fts = """
    CREATE VIRTUAL TABLE text_fts USING fts5(
      text,
      content = '',
      contentless_delete = 1,
      tokenize = 'unicode61'
    );
    """

    /// sqlite-vec v0.1.9 的 vec0 表。int8[512]：Qwen3-Embedding-0.6B 截断到 512 维后再量化到 int8。
    static let vec = """
    CREATE VIRTUAL TABLE vec_text USING vec0(
      text_rowid INTEGER PRIMARY KEY,
      embedding int8[512]
    );
    """
}
