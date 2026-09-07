import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// M0 明文测试库，目录固定为 ~/Library/Application Support/brosis-m0/。
/// 两个文件互不干扰：GUI 运行写 `m0.sqlite`，`--self-check` 写 `m0-selfcheck.sqlite`。
/// 只允许写入合成内容或你明确许可的内容；v1 的加密库（SQLCipher）在 E6 另行验证。
final class Store: @unchecked Sendable {

    enum StoreError: Error, CustomStringConvertible {
        case open(String)
        case exec(String)
        case prepare(String)

        var description: String {
            switch self {
            case .open(let m): return "打开数据库失败：\(m)"
            case .exec(let m): return "执行 SQL 失败：\(m)"
            case .prepare(let m): return "准备语句失败：\(m)"
            }
        }
    }

    /// GUI 运行时写的库。E4 的真实观测数据只应该出现在这里。
    static var defaultURL: URL {
        directoryURL.appendingPathComponent("m0.sqlite", isDirectory: false)
    }

    /// `--self-check` 专用库。**故意与 defaultURL 分开**：自检写的是合成行
    /// （app=com.brosis.selfcheck、两条 AX 统计、三条帧统计），
    /// 混进 m0.sqlite 会污染 E4 的真实观测数据与统计口径。
    static var selfCheckURL: URL {
        directoryURL.appendingPathComponent("m0-selfcheck.sqlite", isDirectory: false)
    }

    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("brosis-m0", isDirectory: true)
    }

    let url: URL
    private let queue = DispatchQueue(label: "com.brosis.app.store")
    private var db: OpaquePointer?

    init(url: URL = Store.defaultURL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw StoreError.open(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 3000)
        try execute(Store.schema)
        // 2026-09-07 加的列：老库（CREATE TABLE IF NOT EXISTS 不会补列）在这里补。
        if scalarInt("SELECT COUNT(*) FROM pragma_table_info('frame_stats') WHERE name = 'trigger'") == 0 {
            try execute("ALTER TABLE frame_stats ADD COLUMN trigger TEXT")
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - schema

    static let schema = """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    PRAGMA foreign_keys = ON;

    CREATE TABLE IF NOT EXISTS meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    -- 一次观察。字段名对齐计划 3.2，M0 只填事件骨架能拿到的列。
    CREATE TABLE IF NOT EXISTS observations (
      id           INTEGER PRIMARY KEY,
      ts           REAL    NOT NULL,          -- Unix 秒，UTC
      app          TEXT,                       -- bundle id
      app_name     TEXT,
      pid          INTEGER,
      title        TEXT,                       -- AXTitle
      url          TEXT,                       -- kAXURL
      document     TEXT,                       -- kAXDocument
      trigger      TEXT    NOT NULL,
      source_state TEXT    NOT NULL,
      idle_s       REAL,                       -- CGEventSource 空闲秒数
      display_id   INTEGER
    );
    CREATE INDEX IF NOT EXISTS idx_observations_ts  ON observations(ts);
    CREATE INDEX IF NOT EXISTS idx_observations_app ON observations(app, ts);

    -- 焦点窗口下按角色汇总的 AX 文本统计。M0 只记字符数与是否为空，不存正文。
    CREATE TABLE IF NOT EXISTS ax_texts (
      id             INTEGER PRIMARY KEY,
      observation_id INTEGER NOT NULL REFERENCES observations(id) ON DELETE CASCADE,
      role           TEXT    NOT NULL,
      node_count     INTEGER NOT NULL,
      char_count     INTEGER NOT NULL,
      is_empty       INTEGER NOT NULL,
      completeness   TEXT    NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_ax_texts_obs ON ax_texts(observation_id);

    -- 帧统计。不存图像，只存 dHash、汉明距离与 dirtyRects 面积。
    CREATE TABLE IF NOT EXISTS frame_stats (
      id               INTEGER PRIMARY KEY,
      ts               REAL    NOT NULL,
      display_id       INTEGER NOT NULL,
      status           TEXT    NOT NULL,   -- complete / failed（按需截图）；idle_batch 等为流时代遗留
      width            INTEGER,
      height           INTEGER,
      content_scale    REAL,
      dhash            TEXT,               -- 64 bit，16 位十六进制
      hamming          INTEGER,            -- 与上一 complete 帧的汉明距离
      dirty_rects      INTEGER,
      dirty_area_ratio REAL,               -- 变化面积 / 内容面积
      gated            INTEGER NOT NULL DEFAULT 0,  -- 1 = 未触发内容检查（不是丢证据）
      idle_count       INTEGER NOT NULL DEFAULT 0,  -- status=idle_batch 时的合并帧数（流时代遗留）
      trigger          TEXT                         -- 按需截图的触发原因（2026-09-07 起）
    );
    CREATE INDEX IF NOT EXISTS idx_frame_stats_ts ON frame_stats(ts);

    -- 运行期事件（权限变化、流启停、暂停/继续、登录项注册）。
    CREATE TABLE IF NOT EXISTS runtime_events (
      id     INTEGER PRIMARY KEY,
      ts     REAL NOT NULL,
      kind   TEXT NOT NULL,
      detail TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_runtime_events_ts ON runtime_events(ts);

    INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', '1');
    INSERT OR REPLACE INTO meta(key, value) VALUES ('purpose', 'M0 明文测试库：仅合成或许可内容');
    """

    // MARK: - 低层

    private func execute(_ sql: String) throws {
        try queue.sync {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                throw StoreError.exec(message)
            }
        }
    }

    /// 绑定值。只用值类型，方便跨队列传递。
    enum Value: Sendable {
        case null
        case int(Int64)
        case real(Double)
        case text(String)
    }

    @discardableResult
    private func insert(_ sql: String, _ values: [Value]) -> Int64 {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(statement) }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case .null:          sqlite3_bind_null(statement, index)
                case .int(let v):    sqlite3_bind_int64(statement, index, v)
                case .real(let v):   sqlite3_bind_double(statement, index, v)
                case .text(let v):   sqlite3_bind_text(statement, index, v, -1, sqliteTransient)
                }
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { return -1 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// 当前连接的 SQLite 版本。
    var sqliteVersion: String { String(cString: sqlite3_libversion()) }

    func scalarText(_ sql: String) -> String? {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let raw = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: raw)
        }
    }

    func scalarInt(_ sql: String) -> Int64 {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
            return sqlite3_column_int64(statement, 0)
        }
    }

    // MARK: - 写入

    private static func text(_ value: String?) -> Value {
        guard let value, !value.isEmpty else { return .null }
        return .text(value)
    }

    @discardableResult
    func insertObservation(_ observation: ObservationRow) -> Int64 {
        insert("""
            INSERT INTO observations
              (ts, app, app_name, pid, title, url, document, trigger, source_state, idle_s, display_id)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .real(observation.ts),
                Store.text(observation.app),
                Store.text(observation.appName),
                observation.pid.map { Value.int(Int64($0)) } ?? .null,
                Store.text(observation.title),
                Store.text(observation.url),
                Store.text(observation.document),
                .text(observation.trigger.rawValue),
                .text(observation.sourceState.rawValue),
                observation.idleSeconds.map { Value.real($0) } ?? .null,
                observation.displayID.map { Value.int(Int64($0)) } ?? .null
            ])
    }

    func insertAXText(observationID: Int64, summary: AXTextSummary) {
        insert("""
            INSERT INTO ax_texts (observation_id, role, node_count, char_count, is_empty, completeness)
            VALUES (?,?,?,?,?,?)
            """,
            [
                .int(observationID),
                .text(summary.role),
                .int(Int64(summary.nodeCount)),
                .int(Int64(summary.charCount)),
                .int(summary.isEmpty ? 1 : 0),
                .text(summary.completeness.rawValue)
            ])
    }

    func insertFrameStat(_ stat: FrameStat) {
        insert("""
            INSERT INTO frame_stats
              (ts, display_id, status, width, height, content_scale,
               dhash, hamming, dirty_rects, dirty_area_ratio, gated, idle_count, trigger)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .real(stat.ts),
                .int(Int64(stat.displayID)),
                .text(stat.status),
                stat.width.map { Value.int(Int64($0)) } ?? .null,
                stat.height.map { Value.int(Int64($0)) } ?? .null,
                stat.contentScale.map { Value.real($0) } ?? .null,
                Store.text(stat.dHashHex),
                stat.hamming.map { Value.int(Int64($0)) } ?? .null,
                stat.dirtyRectCount.map { Value.int(Int64($0)) } ?? .null,
                stat.dirtyAreaRatio.map { Value.real($0) } ?? .null,
                .int(stat.gated ? 1 : 0),
                .int(Int64(stat.idleCount)),
                Store.text(stat.trigger)
            ])
    }

    func logEvent(kind: String, detail: String? = nil) {
        insert("INSERT INTO runtime_events (ts, kind, detail) VALUES (?,?,?)",
               [.real(Date().timeIntervalSince1970), .text(kind), Store.text(detail)])
    }
}

/// 一条观察记录（计划 3.3 的事件骨架输出）。
struct ObservationRow: Sendable {
    var ts: Double = Date().timeIntervalSince1970
    var app: String?
    var appName: String?
    var pid: Int32?
    var title: String?
    var url: String?
    var document: String?
    var trigger: ObservationTrigger
    var sourceState: SourceState
    var idleSeconds: Double?
    var displayID: UInt32?
}

/// 帧统计（不含图像）。
struct FrameStat: Sendable {
    var ts: Double = Date().timeIntervalSince1970
    var displayID: UInt32
    var status: String
    var width: Int?
    var height: Int?
    var contentScale: Double?
    var dHashHex: String?
    var hamming: Int?
    var dirtyRectCount: Int?
    var dirtyAreaRatio: Double?
    var gated: Bool = false
    var idleCount: Int = 0
    var trigger: String? = nil
}

/// 焦点窗口下某个 AX 角色的文本统计。
struct AXTextSummary: Sendable {
    var role: String
    var nodeCount: Int
    var charCount: Int
    var completeness: Completeness

    var isEmpty: Bool { charCount == 0 }
}
