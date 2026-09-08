import Foundation

// =============================================================================
// schema v5（M2 c 批 / T13 跨设备同步，D17 / 计划 3.9）
//
// 全部是**纯新增**：两张新表 + 给 observations 加两个可空列 + 给 deletions 加一个可空列
// + 三个索引。老库（v3 / v4）开库时就地迁移，不重写数据、不重建库。
//
// -------------------------------------------------------------------------
// 入站记录怎么落库（本任务最重要的一条口径，先读这段再读代码）
// -------------------------------------------------------------------------
// 3.9 的表格写「不可变记录的主键带 device_id，两边永不碰撞」。schema 从 M1 起就是
// `PRIMARY KEY (device_id, id)`，这一点没有变。变的是**入站记录用哪一个 (device_id, id)**：
//
//   入站记录以 `device_id = 本机`、`id = 本机计数器新分配的值` 落库，
//   同时把它的来源 `(origin_device, origin_id)` 记在 observations 的两个新列上，
//   并用一个**部分唯一索引**保证同一条来源记录只会落一次（幂等重放的判据）。
//
// 为什么不直接把源设备的 (device_id, id) 原样写进去：
//   M1 的检索层（Store+Search / +Evidence / +Query 与 3.6 的 MCP 协议）把 observation
//   的句柄定死成**一个 Int64**（`SearchHit.observationID`、`getEvidence(ids:)`、
//   `Set<Int64>` 去重）。两台机器的 id 都从 1 开始，原样写入之后 (A,7) 与 (B,7)
//   在检索层是同一个 Int64——搜索去重会把两条不同的证据当成一条，get_evidence 会返回错的
//   那一条。要原样写就必须把整个检索层与 MCP 协议的 id 改成复合键，那是把
//   Store+Search / +Evidence / +Query / +Ledger 全部重写一遍，与本批并行的另外几个任务
//   （向量检索、叙述、周台账）改的正是这几个文件。
//
// 换成本机 id 空间之后：
//   - 检索层一行都不用改，入站记录**自动**被 search / get_evidence / get_item /
//     get_context 查得到（本任务的验收要求）；
//   - 全局身份仍然唯一，只是它叫 `(origin_device, origin_id)`，写在列上而不是主键里；
//   - 出站永远只发 `origin_device IS NULL` 的行（= 本机自己产生的），所以不会把别人的记录
//     再转发回去，两台机器之间不会来回打转；
//   - 墓碑用 `(origin_device, origin_id)` 指目标，对端能精确定位到自己的那一份副本。
//
// 代价与边界写在 core/README 的同步章节与结果文件里：
//   - 同一条记录在两台机器上的**本机 id 不同**（全局身份看 origin 两列）；
//   - sessions / ledgers 只用本机产生的观察构建（见 Store+Sync.swift 的注释）。
// =============================================================================

public enum SyncSchema {

    /// 3.9 的库侧状态（出站水位线、段序号、时间戳）。本机配置，不同步。
    static let createSyncState = """
    CREATE TABLE sync_state (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    """

    /// 3.9「入站」的每设备水位线与状态显示所需的字段。本机视角，不同步。
    static let createSyncPeers = """
    CREATE TABLE sync_peers (
      device_id    TEXT PRIMARY KEY,
      name         TEXT,
      first_seen   INTEGER NOT NULL,
      last_seen    INTEGER NOT NULL,
      imported_seq INTEGER NOT NULL DEFAULT 0,   -- 已导入到该设备的哪个 seq（0 = 还没导）
      imported_at  INTEGER,
      observations INTEGER NOT NULL DEFAULT 0,   -- 从该设备导入过多少条观察
      last_error   TEXT
    );
    """

    /// `observations` 的来源两列 + 部分唯一索引（幂等判据）+ 出站扫描用的部分索引。
    ///
    /// `origin_device IS NULL` = 本机产生（出站集合、会话构建集合都是它）。
    static let alterObservationsV5: [(column: String, sql: String)] = [
        ("origin_device", "ALTER TABLE observations ADD COLUMN origin_device TEXT;"),
        ("origin_id", "ALTER TABLE observations ADD COLUMN origin_id INTEGER;"),
    ]

    /// `deletions` 的目标列：这次用户删除**具体作用在哪些记录上**，按来源设备分组、区间压缩。
    /// 只有 `reason = 'user'` 的行会写它（配额过期不同步，3.8）。
    static let alterDeletionsV5: [(column: String, sql: String)] = [
        ("targets", "ALTER TABLE deletions ADD COLUMN targets TEXT;"),
    ]

    static let createIndexes: [(name: String, sql: String)] = [
        ("idx_obs_origin", """
         CREATE UNIQUE INDEX idx_obs_origin ON observations(origin_device, origin_id)
           WHERE origin_device IS NOT NULL;
         """),
        ("idx_obs_local", """
         CREATE INDEX idx_obs_local ON observations(id) WHERE origin_device IS NULL;
         """),
        ("idx_deletions_sync", """
         CREATE INDEX idx_deletions_sync ON deletions(device_id, id) WHERE reason = 'user';
         """),
    ]

    /// v5 的全部 DDL，建新库时一次跑完（老库走 `Store.migrateIfNeeded` 的逐项判断）。
    static var createAllForNewDatabase: String {
        ([createSyncState, createSyncPeers] + createIndexes.map(\.sql)).joined(separator: "\n")
    }

    /// v5 之后 `Schema.expectedTables` 要多的两张表。
    public static let tables = ["sync_peers", "sync_state"]

    // MARK: - sync_state 的键名

    public enum StateKey {
        /// 下一个要写的段序号（1 起）。
        public static let nextSeq = "next_seq"
        /// 已出站到哪条本机 observation id。
        public static let exportedObservationID = "exported_observation_id"
        /// 已出站到哪条本机 deletion id。
        public static let exportedDeletionID = "exported_deletion_id"
        public static let lastExportAt = "last_export_at"
        public static let lastImportAt = "last_import_at"
        /// 同步目录（显示用；真正的路径由 app 侧的 UserDefaults 决定）。
        public static let directory = "directory"
        /// 同步密钥的指纹（前 8 字节十六进制），用来发现"换了一套密钥"。
        public static let keyID = "key_id"
    }
}
