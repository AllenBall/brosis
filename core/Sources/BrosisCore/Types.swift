import Foundation

// MARK: - 观察相关枚举（与 schema 的 CHECK 约束一一对应）

public enum CaptureTrigger: String, Sendable, CaseIterable, Codable {
    case appSwitch = "app_switch"
    case windowChange = "window_change"
    case urlChange = "url_change"
    case axNotification = "ax_notification"
    case frameDirty = "frame_dirty"
    case timer
    case manual
}

public enum CaptureMethod: String, Sendable, CaseIterable, Codable {
    case ax, ocr, adapter, mixed
}

public enum Completeness: String, Sendable, CaseIterable, Codable {
    case complete, partial, unavailable, excluded
}

public enum SourceState: String, Sendable, CaseIterable, Codable {
    case ok
    case permissionLost = "permission_lost"
    case timeout
    case userIdle = "user_idle"
    case secureInput = "secure_input"
    case locked
}

public enum URLKind: String, Sendable, CaseIterable, Codable {
    case web, file, deeplink, doc, other
}

/// 3.12 的三档采集模式。
public enum CapturePolicyMode: String, Sendable, CaseIterable, Codable {
    case none                                  // 什么都不记
    case eventsOnly = "events_only"            // 只记事件
    case eventsAndContent = "events_and_content"
}

public enum CapturePolicySource: String, Sendable, CaseIterable, Codable {
    case `default`, user
    case builtinDenylist = "builtin_denylist"
}

/// 3.8 的三种删除语义。
public enum DeletionReason: String, Sendable, CaseIterable, Codable {
    case user      // 合规工具，立即执行、留墓碑、随 D17 同步
    case quota     // 配额过期，物理删行，只记区间审计，不同步
    case policy    // 按应用策略降档时的清理
}

public enum DeletionKind: String, Sendable, CaseIterable, Codable {
    case app, range, object, observation
}

// MARK: - 写入入参

public struct AppRef: Sendable, Hashable {
    public var bundleID: String
    public var name: String
    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public struct URLRef: Sendable, Hashable {
    /// 原始定位信息，永远原样保留（3.2）。
    public var rawLocator: String
    /// 规范化后的 URL；规范化不删有业务语义的查询参数和 hash 路由。
    public var canonicalURL: String
    public var host: String?
    public var kind: URLKind

    public init(rawLocator: String, canonicalURL: String? = nil, host: String? = nil, kind: URLKind = .web) {
        self.rawLocator = rawLocator
        self.canonicalURL = canonicalURL ?? rawLocator
        self.host = host
        self.kind = kind
    }
}

/// 一次观察里的一段正文。`ord` 由数组下标决定（观察内的有序片段序号，重建原文用）。
public struct TextFragment: Sendable {
    public var text: String
    /// JSON：`{"x":..,"y":..,"w":..,"h":..}` 或 AX 路径。
    public var region: String?
    public init(text: String, region: String? = nil) {
        self.text = text
        self.region = region
    }
}

/// `Store.record(_:)` 的入参：一次观察 = 一个证据单元。
public struct ObservationInput: Sendable {
    public var ts: Int64                     // Unix 毫秒（UTC）
    public var displayID: Int64?
    public var app: AppRef?
    public var windowTitle: String?
    public var url: URLRef?
    public var filePath: String?
    public var trigger: CaptureTrigger
    public var captureMethod: CaptureMethod
    public var completeness: Completeness
    public var visibleRange: String?         // JSON
    public var sourceState: SourceState
    public var frameHash: String?
    public var thumbRef: String?
    public var texts: [TextFragment]

    public init(ts: Int64,
                displayID: Int64? = nil,
                app: AppRef? = nil,
                windowTitle: String? = nil,
                url: URLRef? = nil,
                filePath: String? = nil,
                trigger: CaptureTrigger,
                captureMethod: CaptureMethod,
                completeness: Completeness,
                visibleRange: String? = nil,
                sourceState: SourceState = .ok,
                frameHash: String? = nil,
                thumbRef: String? = nil,
                texts: [TextFragment] = []) {
        self.ts = ts
        self.displayID = displayID
        self.app = app
        self.windowTitle = windowTitle
        self.url = url
        self.filePath = filePath
        self.trigger = trigger
        self.captureMethod = captureMethod
        self.completeness = completeness
        self.visibleRange = visibleRange
        self.sourceState = sourceState
        self.frameHash = frameHash
        self.thumbRef = thumbRef
        self.texts = texts
    }
}

public struct RecordResult: Sendable {
    public var observationID: Int64
    /// 本次观察各片段落到的 `text_versions.id`（业务 id，不是 vrow），按 ord 顺序。
    public var textVersionIDs: [Int64]
    /// 其中新建的版本数。
    public var newTextVersions: Int
    /// 其中命中 sha256 复用的版本数。
    public var reusedTextVersions: Int
}

// MARK: - 删除结果

public struct DeletionSummary: Sendable, Codable {
    public var deletionID: Int64
    public var kind: DeletionKind
    public var reason: DeletionReason
    public var observationsAffected: Int
    public var occurrencesDeleted: Int
    public var textVersionsDeleted: Int
    public var ftsRowsDeleted: Int
    public var sessionsStale: Int
    public var ledgersStale: Int
    public var thumbsDeleted: Int
    public var bytesFreed: Int
}

// MARK: - 统计

/// `Store.stats()` 的分项字节（2.4 存储行：按 UTF-8 字节分别报告）。
public struct StoreStats: Sendable, Codable {
    public var pageSize: Int
    public var pageCount: Int
    public var freelistPages: Int
    /// 主库文件字节。
    public var dbFileBytes: Int
    /// `-wal` 文件字节。
    public var walBytes: Int
    /// `-shm` 文件字节。
    public var shmBytes: Int
    /// dbstat：`text_versions` 表 b-tree 实占字节 = "正文"。
    public var contentBytes: Int
    /// dbstat：全部索引（显式 + autoindex）+ FTS 影子表 = "索引"。
    public var indexBytes: Int
    /// 其中 FTS 影子表单独列出。
    public var ftsBytes: Int
    /// dbstat：其余表（观察、出现、规范化对象、审计、策略…）= "元数据"。
    public var metadataBytes: Int
    /// 空闲页字节（`freelist_count × page_size`）。
    public var freeBytes: Int
    /// 原文净载荷 = `SUM(text_versions.byte_len)`，不含任何索引与页开销。
    public var textPayloadBytes: Int

    // 行数
    public var observations: Int
    public var liveObservations: Int
    public var tombstonedObservations: Int
    public var textVersions: Int
    public var occurrences: Int
    public var ftsRows: Int
    public var apps: Int
    public var deletions: Int

    /// 配额判定用的口径：原文净载荷（`expire(toBytes:)` 与它比较）。
    public var quotaBytes: Int { textPayloadBytes }
}

/// dbstat 的逐 b-tree 明细，`brosis-store stats --detail` 与结果文件用。
public struct StatsRow: Sendable, Codable {
    public var name: String
    public var bucket: String     // content / index / fts / metadata
    public var bytes: Int
    public var pages: Int
}

// MARK: - 一致性报告

/// 13 项悬空引用检查 + 三项内建检查（对应 E3 的 S7）。
public struct IntegrityReport: Sendable, Codable {
    public struct Item: Sendable, Codable {
        public var name: String
        public var value: Int
        public var expected: Int
        public var ok: Bool { value == expected }
    }
    public var danglingChecks: [Item]
    public var integrityCheck: String        // PRAGMA integrity_check
    public var foreignKeyViolations: Int     // PRAGMA foreign_key_check 行数
    public var ftsIntegrityCheck: String     // FTS5 'integrity-check'
    /// 长度 < 2 的 text_version 个数：bigram 从 2 字起才有 token，
    /// 这类文本进得了索引但 phrase 查询永远不命中（D22 已知限制，计划 3.4 规定走扫描）。口径说明，不作断言。
    public var shortTextVersions: Int

    public var allPassed: Bool {
        danglingChecks.allSatisfy(\.ok)
            && integrityCheck == "ok"
            && foreignKeyViolations == 0
            && ftsIntegrityCheck == "ok"
    }
}

// MARK: - 维护结果

public struct MaintenanceReport: Sendable, Codable {
    /// FTS 里有行、text_versions 里没有 → 已删除的孤儿 FTS 行数。
    public var orphanFTSRowsDeleted: Int
    /// text_versions 里有、FTS 里没有 → 已补写的行数。
    public var missingFTSRowsInserted: Int
    public var walBytesBefore: Int
    public var walBytesAfter: Int
    public var dbBytesBefore: Int
    public var dbBytesAfter: Int
    public var freelistBefore: Int
    public var freelistAfter: Int
    public var captureStatsPruned: Int
    public var elapsedMS: Double
}

/// `expire(toBytes:)` 的结果。
public struct ExpireReport: Sendable, Codable {
    public var quotaBytes: Int
    public var beforeBytes: Int
    public var afterBytes: Int
    public var warningThresholdCrossed: Bool
    public var summary: DeletionSummary?
    public var oldestDeletedTS: Int64?
    public var newestDeletedTS: Int64?
    public var batches: Int
}
