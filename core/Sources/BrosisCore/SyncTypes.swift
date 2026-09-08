import Foundation

// =============================================================================
// D17 / 计划 3.9 跨设备同步：段文件的**载荷类型**（与文件格式、加密、目录无关）。
//
// 分层：
//   BrosisCore（本文件 + SyncSchema.swift + Store+Sync.swift）—— 只管"从库里取出要出站的
//     记录"和"把入站记录写进库"，不认识文件、不认识密钥、不认识 iCloud。
//   BrosisSync（另一个 target）—— 只管 JSON Lines 编解码、AES-GCM、目录布局、占位符下载、
//     ack 与清理、循环调度。它依赖 BrosisCore，反过来不依赖。
//
// 这么分的原因：加密与文件格式要能单独测（不开库），入库与级联要能单独测（不写文件）。
//
// 同步范围（3.9 的表格「出站」一行）：observations、text_versions、occurrences、
// deletions 的**用户删除**墓碑。**不同步**：capture_audit / capture_stats / mcp_audit
// （本机运行质量度量）、app_policies / grants（各机独立的可变配置）、sessions / ledgers
// （派生结果，各机按自己的屏幕时间算，见 Store+Sync.swift 的口径注释）、
// 配额过期的 deletions 行（reason = 'quota'，3.8 说明配额是本机策略）、
// thumb_ref（缩略图是本机文件，D10 默认关）。
// =============================================================================

/// 段文件载荷的格式版本。改动载荷字段必须 +1，并在 `SyncSegment.header` 里带上。
public enum SyncFormat {
    /// 载荷（JSON Lines 的行结构）版本。
    public static let payloadVersion = 1
}

// MARK: - 行记录

/// 一条正文。段内按 `sha` 去重（同一段里同一段文本只出现一次）。
///
/// **段是自包含的**：只要一个段里的某条 occurrence 引用了某个 sha，这个段就带上它的正文，
/// 哪怕更早的段已经发过一次。代价是跨段重复（实测数字见结果文件），换来的是
/// "任何一个段都能独立导入"以及"对端删过正文也不会卡住"——如果改成跨段只发一次，
/// 对端一旦把那条正文删掉（用户删除后 3.8 的孤儿清理），后面的段就永远解析不了。
public struct SyncTextRecord: Codable, Sendable, Equatable {
    /// 原文 UTF-8 字节的 SHA-256，64 位小写十六进制。与 `text_versions.sha256` 同一口径。
    public var sha: String
    /// 原文，一个字节都不改（证据要原样；NFKC 折叠只在索引侧）。
    public var text: String
    /// 原文 UTF-8 字节数。
    public var len: Int
    /// 源设备上的创建时刻（Unix 毫秒）。
    public var at: Int64

    public init(sha: String, text: String, len: Int, at: Int64) {
        self.sha = sha
        self.text = text
        self.len = len
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case sha, text, len, at }
}

/// 观察里的一段正文引用（= 一条 occurrence）。按 `sha` 指向同段里的 `SyncTextRecord`。
public struct SyncOccurrenceRecord: Codable, Sendable, Equatable {
    public var sha: String
    public var ord: Int
    public var region: String?
    public var conf: Double?
    public var note: String?

    public init(sha: String, ord: Int, region: String? = nil,
                conf: Double? = nil, note: String? = nil) {
        self.sha = sha
        self.ord = ord
        self.region = region
        self.conf = conf
        self.note = note
    }

    enum CodingKeys: String, CodingKey { case sha, ord, region, conf, note }
}

public struct SyncURLRecord: Codable, Sendable, Equatable {
    public var raw: String
    public var canonical: String
    public var host: String?
    public var kind: String

    public init(raw: String, canonical: String, host: String?, kind: String) {
        self.raw = raw
        self.canonical = canonical
        self.host = host
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case raw, canonical, host, kind }
}

/// 一次观察（含它的全部 occurrence）。`id` 是**源设备上的** observation id；
/// 加上段头里的 `device` 就是 3.9 说的"带 device_id 的主键"，两台机器永不碰撞。
public struct SyncObservationRecord: Codable, Sendable, Equatable {
    public var id: Int64
    public var ts: Int64
    public var display: Int64?
    public var bundle: String?
    public var appName: String?
    public var title: String?
    public var url: SyncURLRecord?
    public var path: String?
    public var trigger: String
    public var method: String
    public var completeness: String
    public var visible: String?
    public var state: String
    public var frame: String?
    /// 源设备上已经打了墓碑（导出时就已删除）。导入端照抄，不再等墓碑记录。
    public var deletedAt: Int64?
    public var texts: [SyncOccurrenceRecord]

    public init(id: Int64, ts: Int64, display: Int64? = nil, bundle: String? = nil,
                appName: String? = nil, title: String? = nil, url: SyncURLRecord? = nil,
                path: String? = nil, trigger: String, method: String, completeness: String,
                visible: String? = nil, state: String, frame: String? = nil,
                deletedAt: Int64? = nil, texts: [SyncOccurrenceRecord] = []) {
        self.id = id
        self.ts = ts
        self.display = display
        self.bundle = bundle
        self.appName = appName
        self.title = title
        self.url = url
        self.path = path
        self.trigger = trigger
        self.method = method
        self.completeness = completeness
        self.visible = visible
        self.state = state
        self.frame = frame
        self.deletedAt = deletedAt
        self.texts = texts
    }

    enum CodingKeys: String, CodingKey {
        case id, ts, display, bundle, appName = "app", title, url, path
        case trigger, method, completeness = "comp", visible = "vis", state
        case frame, deletedAt = "del", texts
    }
}

/// 墓碑的目标：某个源设备上的一批 observation id，用**区间**表示（D23 给 ledgers.evidence
/// 定的同一种写法）。按应用 / 时间段删除通常是连续 id，区间压缩后一条删除只有几十字节。
public struct SyncTombstoneTarget: Codable, Sendable, Equatable {
    /// 目标记录的**源设备**（不是执行删除的设备）。
    public var device: String
    /// `[[lo, hi], …]`，闭区间，已排序、已合并。
    public var ranges: [[Int64]]

    public init(device: String, ranges: [[Int64]]) {
        self.device = device
        self.ranges = ranges
    }

    enum CodingKeys: String, CodingKey { case device = "d", ranges = "r" }

    /// 展开成 id 列表。上限保护交给调用方（段文件本身就有大小上限）。
    public var ids: [Int64] {
        var out: [Int64] = []
        for range in ranges where range.count == 2 {
            let lo = range[0], hi = range[1]
            guard lo <= hi else { continue }
            out.append(contentsOf: lo...hi)
        }
        return out
    }

    /// 把一串 id 压成区间。
    public static func compress(device: String, ids: [Int64]) -> SyncTombstoneTarget {
        let sorted = Array(Set(ids)).sorted()
        var ranges: [[Int64]] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            ranges.append([sorted[i], sorted[j]])
            i = j + 1
        }
        return SyncTombstoneTarget(device: device, ranges: ranges)
    }
}

/// 一次用户删除（3.8「用户主动删除」）。`id` 是源设备上的 `deletions.id`。
///
/// 为什么要显式带目标 id 而不是让对端"重放 params"：params 是**本机**的谓词
/// （按 bundle / 时间段 / 对象），在对端重放会命中对端自己产生的、不在这次删除范围里的记录。
/// 3.8 要求的是"同一次删除在另一台机器上作用于同一批记录"，所以目标必须显式。
public struct SyncTombstoneRecord: Codable, Sendable, Equatable {
    public var id: Int64
    public var kind: String
    public var appliedAt: Int64
    /// 源设备的删除条件 JSON，原样带过去只作审计用途，不参与判定。
    public var params: String
    public var targets: [SyncTombstoneTarget]

    public init(id: Int64, kind: String, appliedAt: Int64, params: String,
                targets: [SyncTombstoneTarget]) {
        self.id = id
        self.kind = kind
        self.appliedAt = appliedAt
        self.params = params
        self.targets = targets
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, appliedAt = "at", params, targets
    }
}

// MARK: - 段

/// 段头。明文写在段文件里（不含任何密钥），同时作为 AES-GCM 的附加认证数据（AAD），
/// 于是"把 5.seg 改名成 3.seg"或"改段头里的 device"都会让解密失败，而不是静默错位。
public struct SyncSegmentHeader: Codable, Sendable, Equatable {
    public var format: Int
    public var device: String
    public var seq: Int64
    public var createdAt: Int64
    public var texts: Int
    public var observations: Int
    public var tombstones: Int
    /// 明文（JSON Lines）字节数，解密后核对。
    public var plainBytes: Int
    /// 密文（含 nonce 与 tag 的 combined 表示）的 SHA-256，十六进制。
    /// GCM 的 tag 本来就能发现篡改，这个校验和是为了把"文件坏了"与"密钥不对"区分开
    /// （3.9 的状态显示要能说出是哪一种）。
    public var checksum: String

    public init(format: Int, device: String, seq: Int64, createdAt: Int64,
                texts: Int, observations: Int, tombstones: Int,
                plainBytes: Int, checksum: String) {
        self.format = format
        self.device = device
        self.seq = seq
        self.createdAt = createdAt
        self.texts = texts
        self.observations = observations
        self.tombstones = tombstones
        self.plainBytes = plainBytes
        self.checksum = checksum
    }
}

/// 一个段的全部载荷。
public struct SyncSegment: Sendable, Equatable {
    public var device: String
    public var seq: Int64
    public var createdAt: Int64
    public var texts: [SyncTextRecord]
    public var observations: [SyncObservationRecord]
    public var tombstones: [SyncTombstoneRecord]
    /// 本段覆盖到的最大本机 observation id（出站水位线）。
    public var lastObservationID: Int64
    /// 本段覆盖到的最大本机 deletion id（出站水位线）。
    public var lastDeletionID: Int64

    public init(device: String, seq: Int64, createdAt: Int64,
                texts: [SyncTextRecord] = [],
                observations: [SyncObservationRecord] = [],
                tombstones: [SyncTombstoneRecord] = [],
                lastObservationID: Int64 = 0, lastDeletionID: Int64 = 0) {
        self.device = device
        self.seq = seq
        self.createdAt = createdAt
        self.texts = texts
        self.observations = observations
        self.tombstones = tombstones
        self.lastObservationID = lastObservationID
        self.lastDeletionID = lastDeletionID
    }

    public var isEmpty: Bool {
        observations.isEmpty && tombstones.isEmpty
    }

    /// 载荷里原文的净字节数（容量口径与 2.4 一致）。
    public var textPayloadBytes: Int { texts.reduce(0) { $0 + $1.len } }
}

// MARK: - 导入结果与状态

public struct SyncImportStats: Sendable, Codable, Equatable {
    public var observationsInserted: Int = 0
    public var observationsSkipped: Int = 0          // 已经导过（幂等重放）
    public var occurrencesInserted: Int = 0
    public var textVersionsInserted: Int = 0
    public var textVersionsReused: Int = 0
    public var tombstonesApplied: Int = 0
    public var tombstonesSkipped: Int = 0
    public var observationsTombstoned: Int = 0
    public var occurrencesDeleted: Int = 0
    public var textVersionsDeleted: Int = 0
    public var sessionsStale: Int = 0
    public var ledgersStale: Int = 0

    public init() {}
}

public struct SyncExportStats: Sendable, Codable, Equatable {
    public var observations: Int = 0
    public var texts: Int = 0
    public var occurrences: Int = 0
    public var tombstones: Int = 0
    public var textPayloadBytes: Int = 0

    public init() {}
}

/// 3.9「状态显示」要的数据（库里那一半；文件那一半由 BrosisSync 补）。
public struct SyncStateSnapshot: Sendable, Codable, Equatable {
    public var deviceID: String
    /// 下一个要写的段序号。
    public var nextSeq: Int64
    /// 已出站到哪条本机 observation id。
    public var exportedObservationID: Int64
    /// 已出站到哪条本机 deletion id。
    public var exportedDeletionID: Int64
    /// 还没出站的本机观察条数。
    public var pendingObservations: Int
    /// 还没出站的本机用户删除条数。
    public var pendingTombstones: Int
    public var lastExportAt: Int64?
    public var lastImportAt: Int64?
    public var peers: [SyncPeerState]

    public init(deviceID: String, nextSeq: Int64, exportedObservationID: Int64,
                exportedDeletionID: Int64, pendingObservations: Int, pendingTombstones: Int,
                lastExportAt: Int64?, lastImportAt: Int64?, peers: [SyncPeerState]) {
        self.deviceID = deviceID
        self.nextSeq = nextSeq
        self.exportedObservationID = exportedObservationID
        self.exportedDeletionID = exportedDeletionID
        self.pendingObservations = pendingObservations
        self.pendingTombstones = pendingTombstones
        self.lastExportAt = lastExportAt
        self.lastImportAt = lastImportAt
        self.peers = peers
    }
}

public struct SyncPeerState: Sendable, Codable, Equatable {
    public var deviceID: String
    public var name: String?
    public var firstSeen: Int64
    public var lastSeen: Int64
    /// 本机已经导入该设备到哪个 seq（0 = 一个都没导）。
    public var importedSeq: Int64
    public var importedAt: Int64?
    /// 从该设备导入过多少条观察。
    public var observations: Int
    public var lastError: String?

    public init(deviceID: String, name: String?, firstSeen: Int64, lastSeen: Int64,
                importedSeq: Int64, importedAt: Int64?, observations: Int, lastError: String?) {
        self.deviceID = deviceID
        self.name = name
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.importedSeq = importedSeq
        self.importedAt = importedAt
        self.observations = observations
        self.lastError = lastError
    }
}
