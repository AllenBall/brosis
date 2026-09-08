import Foundation

// =============================================================================
// schema v8（M2 d 批 / T16 加密导出与导入，计划 3.8 / D7）
//
// 纯新增一张表 `export_imports`：**这个库导入过哪些归档**。
// 老库开库时就地补建，不重写数据、不改任何已有列。
//
// -------------------------------------------------------------------------
// 为什么需要它（这张表解决的是"导两次会不会翻倍"）
// -------------------------------------------------------------------------
// 合并模式的幂等靠 T13 的 `(origin_device, origin_id)` 部分唯一索引，逐条判定，够用。
// 恢复模式不行：恢复写回的是**源库的 id**、`origin_device` 照抄归档（通常是 NULL），
// 也就是说恢复出来的记录看起来就是"本机自己产生的"——再导一次同一份归档时，
// 逐条判定找不到它们，就会翻倍。
//
// 所以再加一层**归档粒度**的幂等：manifest 里的 `archive_id`（16 字节随机）进这张表，
// 同一个 archive_id 第二次导入直接整份跳过（`ExportImportStats.alreadyImported = true`）。
// 顺带它也是一份审计：这个库里的数据是从哪一份归档、什么时候、以哪种模式恢复来的。
//
// 它是**本机运行记录**，不是证据：不参与 D17 同步、不进删除级联、不进配额口径
// （与 `sync_peers` / `mcp_audit` 同一条口径）。
// =============================================================================

public enum SchemaV8 {

    public static let version = 8

    public static let note =
        "v8：export_imports（3.8 加密导出 / 导入的归档粒度幂等与审计，D7 配额联动）"

    static let createExportImports = """
    CREATE TABLE export_imports (
      archive_id     TEXT PRIMARY KEY,            -- manifest.archive_id（16 字节十六进制）
      source_device  TEXT NOT NULL,               -- 归档来自哪台设备的 device_id（不是主机名）
      created_at     INTEGER NOT NULL,            -- 归档的创建时刻（Unix 毫秒）
      mode           TEXT NOT NULL CHECK (mode IN ('restore','merge')),
      blocks         INTEGER NOT NULL DEFAULT 0,
      started_at     INTEGER NOT NULL,
      finished_at    INTEGER,                     -- NULL = 导到一半失败了（下次重来）
      observations   INTEGER NOT NULL DEFAULT 0,  -- 这次真正插进来多少条观察
      stats          TEXT                         -- ExportImportStats 的 JSON，排查用
    );
    CREATE INDEX idx_export_imports_at ON export_imports(started_at);
    """

    /// 建新库时一次跑完。
    static var createAllForNewDatabase: String { createExportImports }

    /// v8 之后 `Schema.expectedTables` 要多的表。
    public static let tables = ["export_imports"]

    // MARK: - meta 里的配额联动状态（3.8 / D7）
    //
    // 配额通知不另立表：它只有几个标量，`meta` 就是放这类本机配置的地方
    // （与 `next_observation_id` / `has_compat_text` 同一处）。

    public enum MetaKey {
        /// 上一次已经**通知过**的等级（ok / warning / full），用来只在跨档时写事件。
        public static let quotaNotifiedLevel = "quota_notified_level"
        /// 用户确认过通知的时刻（毫秒）。确认之后 `expireAfterNotice` 才会真的删。
        public static let quotaAcknowledgedAt = "quota_acknowledged_at"
        /// 确认时用户是不是先导出了，导出的是哪一份归档。
        public static let quotaAcknowledgedArchive = "quota_acknowledged_archive"
        /// 确认时库里的原文净载荷字节：用量涨上去之后这条确认就作废，要重新通知。
        public static let quotaAcknowledgedBytes = "quota_acknowledged_bytes"
        /// 最近一次成功导出的时刻与归档 id（窗口上"上次导出"那一行）。
        public static let lastExportAt = "last_export_at"
        public static let lastExportArchive = "last_export_archive"
    }
}
