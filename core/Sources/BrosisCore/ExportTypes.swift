import Foundation

// =============================================================================
// 3.8「备份：加密导出另有独立口令；删除不能覆盖已导出的副本」+ D7「满后最旧先删且删前
// 通知并可先加密导出」的**格式层**：归档清单、行记录、范围、错误。
//
// 这里只有类型与常量，没有加密（ExportKeyring.swift）、没有文件（ExportArchive.swift）、
// 没有 SQL（Store+Export.swift）。
//
// -------------------------------------------------------------------------
// 与 D17 同步段文件（BrosisSync）的关系：**借代码思路，不共用格式**
// -------------------------------------------------------------------------
// 段文件是"用完即删的传输载体"，两台机器都 ack 之后就删；归档是"长期保存的副本"，
// 用户可能三年后才拿出来解。两者的取舍完全不同，所以格式与版本号各走各的：
//
// | | 同步段文件（BRSSEG） | 加密归档（BRSEXP） |
// |---|---|---|
// | 密钥 | 同步密钥（存在加密库里，机器之间共享） | **独立口令**现场派生，哪里都不存 |
// | 单位 | 一个段一个文件，按 seq 严格连续 | 一个归档一个目录，块只是分片 |
// | 范围 | 只发本机新增（水位线） | 用户选的时间 / 应用范围，可重复导 |
// | 内容 | observations / text_versions / occurrences / user 墓碑 | 再加 sessions / ledgers /
//         app_policies / 运行期事件 |
// | 缺一块 | 停下等它（还会再来） | 直接判归档损坏（不会再来） |
//
// 复用的是**做法**：明文头 + AES-256-GCM、头进 AAD、密文 SHA-256 与 GCM tag 分工报错、
// JSON Lines 载荷。复用的是**代码习惯**而不是同一个函数，因为共用一份实现意味着
// 以后改同步格式会顺手改坏归档格式——归档是要能读三年前那一份的。
// =============================================================================

public enum ExportFormat {

    /// 写进 manifest 的格式名。
    public static let formatName = "brosis-export"
    /// **归档格式版本**。manifest 结构或块布局有任何变化必须 +1。
    /// v1 的导入端只接受 `version == 1`：更新的版本直接拒绝（不猜、不降级读）。
    public static let version = 1
    /// **载荷版本**（JSON Lines 的行结构）。行里加字段可以不动它（解码端忽略未知字段），
    /// 改字段含义或删字段必须 +1。
    public static let payloadVersion = 1

    /// 块文件的 magic。
    public static let magic = Array("BRSEXP".utf8)
    /// 块文件的字节布局版本。
    public static let blockVersion: UInt8 = 1

    /// 一块的**明文**上限（3.8 的实现选择：8 MiB）。
    /// 选它的理由：解一块要把明文整个拿进内存，8 MiB × 1 块 = 导入端内存上界；
    /// 同时块数不至于爆（1 个月合成库约 630 MiB 明文 → 80 块左右）。
    public static let defaultBlockPlainBytes = 8 * 1024 * 1024
    /// 块文件名：`blocks/000000.blk`（补零到 6 位，目录列表按字典序 = 按序号）。
    public static let blockDigits = 6

    public static let manifestFileName = "manifest.json"
    public static let blocksDirectoryName = "blocks"
    /// 归档目录建议后缀（不强制）。
    public static let directorySuffix = "brosisexport"

    public static func blockFileName(_ seq: Int) -> String {
        String(format: "%0\(blockDigits)d.blk", seq)
    }
}

// MARK: - 范围（3.8「可选时间范围与应用范围」）

/// 调用方给的导出范围。`nil` / 空 = 不限制。
public struct ExportRequest: Sendable, Equatable {
    /// 半开区间 `[start, end)`，Unix 毫秒。
    public var start: Int64?
    public var end: Int64?
    /// bundle id 白名单；空 = 全部应用。
    public var apps: [String]
    /// 3.12 的采集策略（可选，默认不导——它是**本机配置**，见 3.9 的同一条口径）。
    public var includePolicies: Bool
    /// 运行期事件（`jobs` 里 `type LIKE 'runtime_event:%'` 的行，可选，默认不导）。
    public var includeEvents: Bool
    /// 一块的明文上限。
    public var blockPlainBytes: Int
    /// 每次取锁读多少条观察（分段读的粒度，见 Store+Export.swift 的"导出期间库照常可用"）。
    public var batchObservations: Int

    public init(start: Int64? = nil, end: Int64? = nil, apps: [String] = [],
                includePolicies: Bool = false, includeEvents: Bool = false,
                blockPlainBytes: Int = ExportFormat.defaultBlockPlainBytes,
                batchObservations: Int = 200) {
        self.start = start
        self.end = end
        self.apps = apps
        self.includePolicies = includePolicies
        self.includeEvents = includeEvents
        self.blockPlainBytes = blockPlainBytes
        self.batchObservations = batchObservations
    }

    public var isFullDatabase: Bool { start == nil && end == nil && apps.isEmpty }
}

/// 写进 manifest 的范围（= 请求 + 导出开始时定下的两条水位线）。
public struct ExportScope: Codable, Sendable, Equatable {
    public var start: Int64?
    public var end: Int64?
    public var apps: [String]
    public var includePolicies: Bool
    public var includeEvents: Bool
    /// **一致性边界**：只导 `observations.id ≤ 这个值` 的行。
    /// 导出不开长事务（否则整段时间库都写不进去），改用"开头定水位线 + 分段读"，
    /// 于是归档是库的一个**前缀**，导出期间新写进来的观察不在里面——这是有意的，
    /// 也是可核对的（manifest 里写着边界在哪）。
    public var maxObservationID: Int64
    /// 同上，作用于 `deletions.id`。
    public var maxDeletionID: Int64

    enum CodingKeys: String, CodingKey {
        case start, end, apps
        case includePolicies = "include_policies"
        case includeEvents = "include_events"
        case maxObservationID = "max_observation_id"
        case maxDeletionID = "max_deletion_id"
    }
}

// MARK: - 行记录（JSON Lines 的 `v`）

/// 一条正文。归档内**全局**按 sha 去重（与段文件的"每段自包含"相反）：
/// 归档是整体导入的，块按序号从小到大读，正文总是排在第一次引用它的观察之前，
/// 所以后面的块解析时那条正文要么已经在库里（前面的块已提交），要么就在本块里。
public struct ExportTextRecord: Codable, Sendable, Equatable {
    /// 原文 UTF-8 字节的 SHA-256，64 位小写十六进制（与 `text_versions.sha256` 同口径）。
    public var sha: String
    /// 原文，一个字节都不改。
    ///
    /// **脱敏在入库前就做完了**（app 的 `Redactor`）：库里存的已经是脱敏后的正文，
    /// 归档原样带走，既不做二次脱敏、也不还原。3.8 的口径是"导出的是库里那一份"。
    public var text: String
    public var len: Int
    public var at: Int64

    enum CodingKeys: String, CodingKey { case sha, text, len, at }
}

public struct ExportOccurrenceRecord: Codable, Sendable, Equatable {
    public var sha: String
    public var ord: Int
    public var region: String?
    public var conf: Double?
    public var note: String?

    enum CodingKeys: String, CodingKey { case sha, ord, region, conf, note }
}

public struct ExportURLRecord: Codable, Sendable, Equatable {
    public var raw: String
    public var canonical: String
    public var host: String?
    public var kind: String

    enum CodingKeys: String, CodingKey { case raw, canonical, host, kind }
}

/// 一次观察（含它的 occurrence）。`id` 是**源库里的** observation id；
/// 恢复模式原样写回，合并模式换成本机 id 空间（见 Store+Export.swift 的两张表）。
public struct ExportObservationRecord: Codable, Sendable, Equatable {
    public var id: Int64
    public var ts: Int64
    public var display: Int64?
    public var bundle: String?
    public var appName: String?
    public var title: String?
    public var url: ExportURLRecord?
    public var path: String?
    public var trigger: String
    public var method: String
    public var completeness: String
    public var visible: String?
    public var state: String
    public var frame: String?
    /// 用户删除墓碑（3.8）。非空 = 这条观察在源库里已经删了，正文早就没了，只剩这行墓碑。
    public var deletedAt: Int64?
    /// D17 的来源两列（源库里从别的设备导进来的记录才有）。
    public var originDevice: String?
    public var originID: Int64?
    public var texts: [ExportOccurrenceRecord]

    enum CodingKeys: String, CodingKey {
        case id, ts, display, bundle, appName = "app", title, url, path
        case trigger, method, completeness = "comp", visible = "vis", state, frame
        case deletedAt = "del", originDevice = "odev", originID = "oid", texts
    }
}

/// 一条删除审计（3.8）。`reason = 'user'` 的带 `targets`，导入端据它级联；
/// `reason = 'quota'` 是本机策略的区间审计，导入端只留审计行、不级联。
public struct ExportDeletionRecord: Codable, Sendable, Equatable {
    /// 源库里这行的 `device_id`（可能不是源设备本身——源库里也可能有从对端导入的墓碑）。
    public var device: String
    public var id: Int64
    public var kind: String
    public var reason: String
    public var params: String
    public var appliedAt: Int64
    public var targets: String?
    public var observationsAffected: Int
    public var occurrencesDeleted: Int
    public var textVersionsDeleted: Int
    public var ftsRowsDeleted: Int
    public var sessionsStale: Int
    public var ledgersStale: Int
    public var thumbsDeleted: Int
    public var bytesFreed: Int

    enum CodingKeys: String, CodingKey {
        case device = "dev", id, kind, reason, params, appliedAt = "at", targets
        case observationsAffected = "obs", occurrencesDeleted = "occ"
        case textVersionsDeleted = "tv", ftsRowsDeleted = "fts"
        case sessionsStale = "ss", ledgersStale = "ls"
        case thumbsDeleted = "th", bytesFreed = "bytes"
    }
}

/// 一条会话（3.7）。`primaryApp` 用 bundle id 而不是本机 `apps.id`。
public struct ExportSessionRecord: Codable, Sendable, Equatable {
    public var id: Int64
    public var start: Int64
    public var end: Int64
    public var display: Int64?
    public var primaryApp: String?
    public var dwell: Double
    public var active: Double
    public var unknown: Double
    public var interruptions: Int
    public var evidence: String
    public var stale: Bool
    public var computedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, start, end, display, primaryApp = "app"
        case dwell, active, unknown, interruptions, evidence, stale, computedAt = "at"
    }
}

/// 一条台账（3.7 / 4.3）。`ledger` / `evidence` / `narrativeMeta` 都是不透明 JSON，原样搬。
public struct ExportLedgerRecord: Codable, Sendable, Equatable {
    public var id: Int64
    public var level: String
    public var period: String
    public var ledger: String
    public var narrative: String?
    public var model: String?
    public var narrativeMeta: String?
    public var evidence: String
    public var stale: Bool
    public var computedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, level, period, ledger, narrative, model
        case narrativeMeta = "nmeta", evidence, stale, computedAt = "at"
    }
}

/// 3.12 的一条采集策略。
public struct ExportPolicyRecord: Codable, Sendable, Equatable {
    public var bundle: String
    public var mode: String
    public var source: String
    public var updatedAt: Int64

    enum CodingKeys: String, CodingKey { case bundle, mode, source, updatedAt = "at" }
}

/// 一条运行期事件（`jobs` 里 `type = 'runtime_event:<kind>'` 的行）。
public struct ExportEventRecord: Codable, Sendable, Equatable {
    public var type: String
    public var state: String
    public var input: String?
    public var output: String?
    public var createdAt: Int64
    public var updatedAt: Int64
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case type, state, input, output
        case createdAt = "ct", updatedAt = "ut", error
    }
}

/// 每块的第一行：块自描述（诊断用；权威计数在 manifest 里）。
public struct ExportBlockHead: Codable, Sendable, Equatable {
    public var format: Int
    public var archive: String
    public var device: String
    public var seq: Int
    public var at: Int64

    enum CodingKeys: String, CodingKey { case format, archive, device, seq, at }
}

// MARK: - manifest

/// 一块在 manifest 里的登记。
public struct ExportBlockInfo: Codable, Sendable, Equatable {
    public var seq: Int
    /// 数据行数（**不含**块头行）。
    public var rows: Int
    /// 明文（JSON Lines）字节数。
    public var plainBytes: Int
    /// 密文（GCM combined）字节数。
    public var cipherBytes: Int
    /// 密文的 SHA-256，十六进制。**文件坏没坏**看它（不需要口令）。
    public var checksum: String

    enum CodingKeys: String, CodingKey {
        case seq, rows
        case plainBytes = "plain_bytes", cipherBytes = "cipher_bytes", checksum
    }
}

public struct ExportCounts: Codable, Sendable, Equatable {
    public var observations: Int = 0
    public var tombstonedObservations: Int = 0
    public var textVersions: Int = 0
    public var occurrences: Int = 0
    public var sessions: Int = 0
    public var ledgers: Int = 0
    public var deletions: Int = 0
    public var appPolicies: Int = 0
    public var events: Int = 0
    /// 原文净载荷（UTF-8 字节），与 2.4 / 配额同一个口径。
    public var textPayloadBytes: Int = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case observations
        case tombstonedObservations = "tombstoned_observations"
        case textVersions = "text_versions"
        case occurrences, sessions, ledgers, deletions
        case appPolicies = "app_policies", events
        case textPayloadBytes = "text_payload_bytes"
    }
}

/// `manifest.json`——**明文**，不含口令、不含密钥、不含任何正文。
///
/// 明文的理由与 3.9 的 manifest 一样：不输入口令也要能看出"这是什么、多大、什么范围、
/// 什么时候导的"，否则用户面对一堆归档目录只能一个个试口令。
/// 代价是范围（时间窗与 bundle id 名单）是可见的——bundle id 是应用标识，不是内容；
/// 这一条写在 core/README 与结果文件里。
public struct ExportManifest: Codable, Sendable, Equatable {
    public var format: String
    public var version: Int
    public var payloadVersion: Int
    /// 这一份归档的随机标识（16 字节十六进制）。导入端按它做**归档粒度**的幂等。
    public var archiveID: String
    public var createdAt: Int64
    /// 源库的 `meta.device_id`（**不是主机名**，D17 已定每台机器一个 device_id）。
    public var sourceDevice: String
    /// 源库的 schema 版本。导入端按它判断能不能读（v1 只接受同版本）。
    public var schemaVersion: Int
    public var aead: String
    public var kdf: String
    public var kdfIterations: Int
    /// PBKDF2 的盐（16 字节，base64）。每一份归档一份自己的盐。
    public var salt: Data
    /// 口令校验值：HKDF 派生出的"校验密钥"的 SHA-256，十六进制。
    /// 口令错在**碰任何一块之前**就能判出来，于是"口令错"与"文件被改过"是两种错误。
    public var verifier: String
    public var blockPlainBytes: Int
    public var scope: ExportScope
    public var counts: ExportCounts
    public var blocks: [ExportBlockInfo]
    /// 全部块密文校验和按序拼起来再哈希：块被删掉一整块 / 换序，不用口令就能发现。
    public var totalChecksum: String
    /// 整份 manifest 的 HMAC-SHA256（用口令派生的第三把子密钥），`mac` 字段本身置空后计算。
    /// 它盖住 blocks 列表、counts 与 scope：没有口令改不动 manifest 而不被发现。
    public var mac: String
    /// 人读的说明（导出时的取舍，比如"限定了应用范围所以没带删除审计"）。
    public var notes: [String]

    enum CodingKeys: String, CodingKey {
        case format, version, aead, kdf, salt, verifier, scope, counts, blocks, mac, notes
        case payloadVersion = "payload_version"
        case archiveID = "archive_id"
        case createdAt = "created_at"
        case sourceDevice = "source_device"
        case schemaVersion = "schema_version"
        case kdfIterations = "kdf_iterations"
        case blockPlainBytes = "block_plain_bytes"
        case totalChecksum = "total_checksum"
    }
}

// MARK: - 结果

public struct ExportOutcome: Sendable, Codable {
    public var archiveID: String
    public var directory: String
    public var counts: ExportCounts
    public var blocks: Int
    /// 归档目录的总字节（manifest + 全部块）。
    public var archiveBytes: Int
    public var plainBytes: Int
    public var elapsedMS: Double
    /// 写进 `runtime_event:export_completed` 的那一行（**不含口令**）。
    public var eventDetail: String

    enum CodingKeys: String, CodingKey {
        case counts, blocks, directory
        case archiveID = "archive_id"
        case archiveBytes = "archive_bytes"
        case plainBytes = "plain_bytes"
        case elapsedMS = "elapsed_ms"
        case eventDetail = "event_detail"
    }
}

public struct ExportProgress: Sendable {
    public var observationsWritten: Int
    public var blocksWritten: Int
    public var bytesWritten: Int
}

/// `--dry-run` / 导入前校验的结果。
public struct ExportVerifyReport: Sendable, Codable {
    public var archiveID: String
    public var blocks: Int
    public var rows: Int
    public var plainBytes: Int
    public var cipherBytes: Int
    public var counts: ExportCounts
    public var manifestMACOK: Bool
    public var totalChecksumOK: Bool
    public var elapsedMS: Double

    enum CodingKeys: String, CodingKey {
        case blocks, rows, counts
        case archiveID = "archive_id"
        case plainBytes = "plain_bytes"
        case cipherBytes = "cipher_bytes"
        case manifestMACOK = "manifest_mac_ok"
        case totalChecksumOK = "total_checksum_ok"
        case elapsedMS = "elapsed_ms"
    }
}

public enum ExportImportMode: String, Sendable, Codable {
    /// 恢复：目标库是空的，源 id 原样写回，会话 / 台账 / 事件一并恢复。
    case restore
    /// 合并：目标库里已经有数据，走 T13 的 `origin_device` / `origin_id` 口径，
    /// 派生结果（会话 / 台账）与运行期事件不导（各机自算，3.9 同一条理由）。
    case merge
}

public struct ExportImportStats: Sendable, Codable, Equatable {
    public var mode: String = ExportImportMode.merge.rawValue
    public var blocks: Int = 0
    public var observationsInserted: Int = 0
    public var observationsSkipped: Int = 0
    /// 目标库里已经有这条记录的墓碑：**不复活**（3.8 的删除是合规动作）。
    public var observationsSkippedTombstoned: Int = 0
    public var occurrencesInserted: Int = 0
    public var textVersionsInserted: Int = 0
    public var textVersionsReused: Int = 0
    public var deletionsInserted: Int = 0
    public var deletionsSkipped: Int = 0
    public var tombstonesCascaded: Int = 0
    public var sessionsInserted: Int = 0
    public var sessionsSkipped: Int = 0
    public var ledgersInserted: Int = 0
    public var ledgersSkipped: Int = 0
    public var policiesInserted: Int = 0
    public var policiesSkipped: Int = 0
    public var eventsInserted: Int = 0
    public var eventsSkipped: Int = 0
    /// 归档整份已经导过（按 `archive_id`），一行都没动。
    public var alreadyImported: Bool = false
    public var elapsedMS: Double = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, blocks
        case observationsInserted = "observations_inserted"
        case observationsSkipped = "observations_skipped"
        case observationsSkippedTombstoned = "observations_skipped_tombstoned"
        case occurrencesInserted = "occurrences_inserted"
        case textVersionsInserted = "text_versions_inserted"
        case textVersionsReused = "text_versions_reused"
        case deletionsInserted = "deletions_inserted"
        case deletionsSkipped = "deletions_skipped"
        case tombstonesCascaded = "tombstones_cascaded"
        case sessionsInserted = "sessions_inserted"
        case sessionsSkipped = "sessions_skipped"
        case ledgersInserted = "ledgers_inserted"
        case ledgersSkipped = "ledgers_skipped"
        case policiesInserted = "policies_inserted"
        case policiesSkipped = "policies_skipped"
        case eventsInserted = "events_inserted"
        case eventsSkipped = "events_skipped"
        case alreadyImported = "already_imported"
        case elapsedMS = "elapsed_ms"
    }
}

// MARK: - 配额联动（3.8 / D7）

public enum QuotaLevel: String, Sendable, Codable {
    case ok         // < 80%
    case warning    // ≥ 80%，还没满
    case full       // ≥ 100%，再写就要"最旧先删"
}

/// D7「达 80% 提示，满后最旧先删，删前通知并允许先加密导出」的**数据层**。
///
/// 这里只算"该说什么、会删掉哪一段、导出该选什么范围"，一行 UI 都不画；
/// app 侧把它渲染成通知与窗口（接入方式见 app/README）。
public struct QuotaAction: Sendable, Codable {
    public var level: QuotaLevel
    public var usedBytes: Int
    public var quotaBytes: Int
    public var ratio: Double
    /// 现在跑 `expire()` 会**物理删掉**多少条观察（估算，按最旧先删逐条累加到降回配额为止）。
    public var wouldDeleteObservations: Int
    public var wouldFreeBytes: Int
    public var wouldDeleteOldestTS: Int64?
    public var wouldDeleteNewestTS: Int64?
    /// 建议的"先加密导出"范围：正是会被删掉的那一段（半开区间）。
    public var suggestedExportStart: Int64?
    public var suggestedExportEnd: Int64?
    /// 用户确认过这条通知的时刻（`acknowledgeQuotaAction` 写的）。
    public var acknowledgedAt: Int64?
    /// 确认时附带的归档 id（用户真的先导出了）。
    public var acknowledgedArchiveID: String?
    /// 最近一次成功导出的时刻与归档 id（`export_completed` 事件之外的快查）。
    public var lastExportAt: Int64?
    public var lastExportArchiveID: String?
    /// `expireAfterNotice()` 现在会不会真的删。
    public var expireAllowed: Bool

    /// 给通知 / 窗口用的一行文案（3.8 要求"删前通知并可先加密导出"，并如实说明
    /// "删除不影响已经导出的副本"）。
    public var message: String {
        let usedGiB = Double(usedBytes) / 1_073_741_824.0
        let quotaGiB = Double(quotaBytes) / 1_073_741_824.0
        let percent = Int((ratio * 100).rounded())
        switch level {
        case .ok:
            return String(format: "存储用量 %.2f / %.2f GiB（%d%%），没到提示线。", usedGiB, quotaGiB, percent)
        case .warning:
            return String(format: "存储用量已到 %.2f / %.2f GiB（%d%%）。到 100%% 之后会按"
                                + "「最旧先删」清出空间；要保留最早那段原文，可以先做一次加密导出。",
                          usedGiB, quotaGiB, percent)
        case .full:
            return String(format: "存储已满（%.2f / %.2f GiB）。继续采集会删掉最旧的 %d 条观察，"
                                + "释放约 %.2f GiB。删除**不可撤销**，但**不会影响已经导出的副本**——"
                                + "要保留就先做一次加密导出（口令与库密钥无关，丢了没人能恢复）。",
                          usedGiB, quotaGiB, wouldDeleteObservations,
                          Double(wouldFreeBytes) / 1_073_741_824.0)
        }
    }
}

/// `expireAfterNotice()` 的结果：要么被拦下（还没确认过通知），要么真的删了。
public enum QuotaExpireOutcome: Sendable {
    /// 没到配额，什么都不用做。
    case notNeeded(QuotaAction)
    /// 到配额了，但通知还没被确认——**不删**，把通知内容交出去（3.8「删前通知」）。
    case blocked(QuotaAction)
    case expired(QuotaAction, ExpireReport)
}

// MARK: - 错误

public enum ExportError: Error, CustomStringConvertible, Sendable {

    /// 口令太弱（长度 / 字符种类），**在派生密钥之前**就拒绝。
    case weakPassphrase(String)
    /// 口令错。`verifier` 对不上，一块都没解过——不泄漏任何内容。
    case wrongPassphrase
    /// 不是 brosis 归档（没有 manifest / magic 不对）。
    case notAnArchive(String)
    /// manifest 读不了（不是合法 JSON、字段缺失）。
    case manifestUnreadable(String)
    /// manifest 被改过：HMAC 对不上（口令是对的，但 blocks / counts / scope 被人动过）。
    case manifestTampered
    /// 归档格式版本不认识。v1 只读 v1，**更新的版本直接拒绝**。
    case unsupportedVersion(found: Int, supported: Int)
    /// 源库 schema 版本与本版本不同。v1 只导同版本（见 core/README）。
    case schemaMismatch(found: Int, supported: Int)
    /// 块文件不在。
    case missingBlock(seq: Int)
    /// 块文件坏了（密文 SHA-256 与 manifest 不符）。
    case blockChecksumMismatch(seq: Int)
    /// 块解密失败：密钥不对，或块头 / 归档身份被改过（它们是 AAD）。
    case blockDecryptFailed(seq: Int)
    /// 块内容自相矛盾（明文字节数、行数、行类型）。
    case corruptBlock(seq: Int, detail: String)
    /// 块清单被动过：总校验和对不上。
    case totalChecksumMismatch
    /// 导出 / 导入的参数不合法。
    case invalidRequest(String)
    /// 文件系统失败。
    case filesystem(String)

    public var description: String {
        switch self {
        case .weakPassphrase(let m):
            return "导出口令不合要求：\(m)"
        case .wrongPassphrase:
            return "口令错误，归档没有被解开（一块都没读）"
        case .notAnArchive(let m):
            return "不是 brosis 加密归档：\(m)"
        case .manifestUnreadable(let m):
            return "manifest.json 读不了：\(m)"
        case .manifestTampered:
            return "manifest 的校验码不符：口令是对的，但清单被改过（块列表 / 计数 / 范围），拒绝导入"
        case .unsupportedVersion(let found, let supported):
            return "归档格式版本 \(found)，本版本只支持 \(supported)；"
                 + "更新的版本不猜着读，请用能读它的 brosis 版本"
        case .schemaMismatch(let found, let supported):
            return "归档来自 schema v\(found) 的库，本版本是 v\(supported)；"
                 + "v1 的归档只在同一个 schema 版本之间导入导出"
        case .missingBlock(let seq):
            return "缺少块文件 \(ExportFormat.blockFileName(seq))：归档不完整，拒绝导入"
        case .blockChecksumMismatch(let seq):
            return "块 \(seq) 的校验和不符（文件坏了或被改过），拒绝导入"
        case .blockDecryptFailed(let seq):
            return "块 \(seq) 解密失败（密钥不对，或块头 / 归档身份被改过），拒绝导入"
        case .corruptBlock(let seq, let detail):
            return "块 \(seq) 内容不一致：\(detail)"
        case .totalChecksumMismatch:
            return "归档总校验和不符：块列表被增删或换序过，拒绝导入"
        case .invalidRequest(let m):
            return "参数不合法：\(m)"
        case .filesystem(let m):
            return "文件操作失败：\(m)"
        }
    }
}
