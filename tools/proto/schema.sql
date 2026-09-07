-- brosis 存储 schema 原型 v0.1（M0 / E3，对应实施计划 3.2、3.8，评审 F4）
-- 目标：验证证据模型（观察 ≠ 内容版本）、删除级联、配额过期、崩溃恢复。
-- 只用 SQLite 标准特性 + FTS5；SQLCipher 在 E6 单独验证，本原型用明文库跑合成数据。
--
-- 【必须按顺序执行】auto_vacuum 只能在建第一张表之前设置，否则需要整库 VACUUM 才能改。
-- 应用方式：sqlite3 <db> < schema.sql，或 gen_synth.py 里的 apply_schema()（连接必须是 autocommit）。

------------------------------------------------------------------------------
-- 0. 文件级 / 连接级 PRAGMA
------------------------------------------------------------------------------
PRAGMA auto_vacuum   = INCREMENTAL;  -- 文件级，必须在建表前；夜间用 incremental_vacuum 回收（3.8）
PRAGMA journal_mode  = WAL;          -- 文件级，持久化
PRAGMA foreign_keys  = ON;           -- 连接级，每次打开都要重设
PRAGMA secure_delete = ON;           -- 连接级，逻辑删除后覆写页内残留（3.8）

------------------------------------------------------------------------------
-- 1. 规范化对象（对象身份 ≠ 内容版本，评审 F4）
------------------------------------------------------------------------------

CREATE TABLE apps (
  id         INTEGER PRIMARY KEY,
  bundle_id  TEXT NOT NULL UNIQUE,
  name       TEXT NOT NULL
);

CREATE TABLE windows (
  id      INTEGER PRIMARY KEY,
  app_id  INTEGER NOT NULL REFERENCES apps(id) ON DELETE RESTRICT,
  title   TEXT NOT NULL,
  UNIQUE (app_id, title)
);
CREATE INDEX idx_windows_title ON windows(title);   -- 标题走 LIKE / 前缀，不进 FTS（3.4）

-- 规范化不删有业务语义的查询参数和 hash 路由；raw_locator 永远保留原样（3.2）
CREATE TABLE urls (
  id            INTEGER PRIMARY KEY,
  raw_locator   TEXT NOT NULL UNIQUE,
  canonical_url TEXT NOT NULL,
  host          TEXT,
  kind          TEXT NOT NULL CHECK (kind IN ('web','file','deeplink','doc','other'))
);
CREATE INDEX idx_urls_host      ON urls(host);
CREATE INDEX idx_urls_canonical ON urls(canonical_url);

CREATE TABLE files (
  id   INTEGER PRIMARY KEY,
  path TEXT NOT NULL UNIQUE
);
CREATE INDEX idx_files_path ON files(path COLLATE NOCASE);

------------------------------------------------------------------------------
-- 2. 观察（一次观察 = 一个证据单元）
--    D17：主键从 M1 起就带 device_id；其余规范化表按本机派生。
------------------------------------------------------------------------------
CREATE TABLE observations (
  device_id       TEXT    NOT NULL,
  id              INTEGER NOT NULL,             -- 设备内单调递增
  ts              INTEGER NOT NULL,             -- Unix 毫秒（UTC）
  display_id      INTEGER,
  app_id          INTEGER REFERENCES apps(id)    ON DELETE RESTRICT,
  window_id       INTEGER REFERENCES windows(id) ON DELETE RESTRICT,
  url_id          INTEGER REFERENCES urls(id)    ON DELETE RESTRICT,
  file_id         INTEGER REFERENCES files(id)   ON DELETE RESTRICT,
  "trigger"       TEXT NOT NULL CHECK ("trigger" IN
                    ('app_switch','window_change','url_change','ax_notification',
                     'frame_dirty','timer','manual')),
  capture_method  TEXT NOT NULL CHECK (capture_method IN ('ax','ocr','adapter','mixed')),
  completeness    TEXT NOT NULL CHECK (completeness IN
                    ('complete','partial','unavailable','excluded')),
  visible_range   TEXT,                          -- JSON：视口内实际显示的范围（F5）
  source_state    TEXT NOT NULL CHECK (source_state IN
                    ('ok','permission_lost','timeout','user_idle','secure_input','locked')),
  frame_hash      TEXT,                          -- dHash，只用于是否触发内容检查，不用于丢弃
  thumb_ref       TEXT,                          -- 缩略图文件相对路径，删除时一并清理
  deleted_at      INTEGER,                       -- 逻辑删除时间戳（毫秒）；NULL = 有效
  PRIMARY KEY (device_id, id)
);
CREATE INDEX idx_obs_ts       ON observations(ts);
CREATE INDEX idx_obs_app_ts   ON observations(app_id, ts);
CREATE INDEX idx_obs_live     ON observations(device_id, ts) WHERE deleted_at IS NULL;
CREATE INDEX idx_obs_deleted  ON observations(deleted_at) WHERE deleted_at IS NOT NULL;

------------------------------------------------------------------------------
-- 3. 文本版本（不可变，按 sha256 复用）
--    vrow 是给 FTS5 external content 用的物理 rowid；业务主键是 (device_id, id)。
--    SQLite 的 FTS5 外部内容表只能用单列整型 rowid 关联，所以复合主键必须配一个代理 rowid。
------------------------------------------------------------------------------
CREATE TABLE text_versions (
  vrow       INTEGER PRIMARY KEY,     -- = rowid，content_rowid，本机内不复用
  device_id  TEXT    NOT NULL,
  id         INTEGER NOT NULL,
  sha256     TEXT    NOT NULL,        -- 原文 UTF-8 字节的 SHA-256（小写 hex）
  text       TEXT    NOT NULL,        -- v1 存完整原文，不分块（F4）
  byte_len   INTEGER NOT NULL,        -- UTF-8 字节数，容量口径（E7）
  created_at INTEGER NOT NULL,
  UNIQUE (device_id, id),             -- 业务主键
  UNIQUE (device_id, sha256)          -- 精确哈希复用：同一设备内同文本只有一行
);

-- 不可变：只允许 INSERT / DELETE，任何 UPDATE 直接 ABORT。
CREATE TRIGGER trg_text_versions_immutable
BEFORE UPDATE ON text_versions
BEGIN
  SELECT RAISE(ABORT, 'text_versions is immutable: insert a new version instead');
END;

------------------------------------------------------------------------------
-- 4. 出现记录（同一文本在不同时间 / 应用出现各自保留一条，F4）
------------------------------------------------------------------------------
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
    ON DELETE CASCADE,                 -- 物理清除观察时自动带走出现记录（配额过期路径）
  FOREIGN KEY (device_id, text_version_id) REFERENCES text_versions(device_id, id)
    ON DELETE RESTRICT                 -- 关键：还有 occurrence 的版本删不掉（3.8 共享版本规则）
);
CREATE INDEX idx_occ_obs ON occurrences(device_id, observation_id);
CREATE INDEX idx_occ_tv  ON occurrences(device_id, text_version_id);

------------------------------------------------------------------------------
-- 5. 全文索引
--    分词方案：T3 / E2 未出结论前用 trigram detail=full 占位（3.4 第三候选）。
--    >>> 定稿时只改下面这一张虚拟表的 tokenize / detail 两行，然后重建索引。<<<
------------------------------------------------------------------------------
CREATE VIRTUAL TABLE text_fts USING fts5(
  text,
  content       = 'text_versions',
  content_rowid = 'vrow',
  tokenize      = 'trigram',
  detail        = full
);

-- FTS 维护方式：【触发器】（二选一，见 README「为什么选触发器」）。
-- text_versions 不可变，所以只需要 INSERT / DELETE 两个触发器，没有 UPDATE 路径。
CREATE TRIGGER trg_text_fts_ai AFTER INSERT ON text_versions BEGIN
  INSERT INTO text_fts(rowid, text) VALUES (new.vrow, new.text);
END;
CREATE TRIGGER trg_text_fts_ad AFTER DELETE ON text_versions BEGIN
  INSERT INTO text_fts(text_fts, rowid, text) VALUES ('delete', old.vrow, old.text);
END;

------------------------------------------------------------------------------
-- 6. 派生结果（可重算，删除后标 stale）
------------------------------------------------------------------------------
CREATE TABLE sessions (
  device_id      TEXT    NOT NULL,
  id             INTEGER NOT NULL,
  start          INTEGER NOT NULL,        -- 毫秒
  "end"          INTEGER NOT NULL,
  display_id     INTEGER,
  primary_app_id INTEGER REFERENCES apps(id) ON DELETE RESTRICT,
  dwell_s        REAL NOT NULL,           -- 前台停留（秒）
  active_s       REAL NOT NULL,           -- 有输入的活跃（秒）
  unknown_s      REAL NOT NULL,           -- 权限丢失 / 超时 / 锁定（秒），三类分列（3.7）
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
  narrative   TEXT,                       -- 可选叙述，模型生成，与台账分开标注（3.7）
  model       TEXT,
  evidence    TEXT NOT NULL,              -- JSON：观察 id 数组
  stale       INTEGER NOT NULL DEFAULT 0 CHECK (stale IN (0,1)),
  computed_at INTEGER NOT NULL,
  PRIMARY KEY (device_id, id),
  UNIQUE (device_id, level, period)
);

------------------------------------------------------------------------------
-- 7. 删除审计（三种语义分开：user / quota / policy，3.8）
------------------------------------------------------------------------------
CREATE TABLE deletions (
  device_id             TEXT    NOT NULL,
  id                    INTEGER NOT NULL,
  kind                  TEXT NOT NULL CHECK (kind IN ('app','range','object','observation')),
  reason                TEXT NOT NULL CHECK (reason IN ('user','quota','policy')),
  params                TEXT NOT NULL,   -- JSON：可重放的删除条件
  applied_at            INTEGER NOT NULL,
  observations_affected INTEGER NOT NULL DEFAULT 0,  -- user=标 deleted_at；quota=物理删除
  occurrences_deleted   INTEGER NOT NULL DEFAULT 0,
  text_versions_deleted INTEGER NOT NULL DEFAULT 0,
  fts_rows_deleted      INTEGER NOT NULL DEFAULT 0,
  sessions_stale        INTEGER NOT NULL DEFAULT 0,
  ledgers_stale         INTEGER NOT NULL DEFAULT 0,
  thumbs_deleted        INTEGER NOT NULL DEFAULT 0,
  bytes_freed           INTEGER NOT NULL DEFAULT 0,  -- 释放的原文 UTF-8 字节
  PRIMARY KEY (device_id, id)
);

------------------------------------------------------------------------------
-- 8. 策略与运行时
------------------------------------------------------------------------------
CREATE TABLE grants (
  client_id   TEXT PRIMARY KEY,
  mode        TEXT NOT NULL CHECK (mode IN ('strict_local','remote_allowed')),
  apps        TEXT NOT NULL,          -- JSON 白名单；'["*"]' 表示全部
  time_window INTEGER NOT NULL DEFAULT 30,   -- 天
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

-- 本机配置，不随 iCloud 同步（3.12）
CREATE TABLE app_policies (
  bundle_id  TEXT PRIMARY KEY,
  mode       TEXT NOT NULL CHECK (mode IN ('none','events_only','events_and_content')),
  source     TEXT NOT NULL CHECK (source IN ('default','user','builtin_denylist')),
  updated_at INTEGER NOT NULL
);

-- 原型附加：设备身份与配额参数。计划 3.2 没列，属于本原型自加，M1 可并入设置文件。
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
