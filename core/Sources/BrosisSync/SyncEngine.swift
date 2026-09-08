import BrosisCore
import CryptoKit
import Foundation

// =============================================================================
// D17 / 3.9 的引擎：把「库侧取数 / 落库」（BrosisCore 的 Store+Sync）与
// 「文件格式 / 加密 / 目录」（本 target 的另外三个文件）接起来，并实现 3.9 的两个循环。
//
// 三条硬规则，代码里到处都在守：
//   1. **每台机器只写自己的文件**：segments/<自己>/、devices/<自己>.json、acks/<自己>.json、
//      keyring/<自己>.wrapped。不写别人的，于是不需要跨机器加锁。
//   2. **段按 seq 连续导入，缺一段就停**，绝不跳过（3.9「校验」一行）。
//   3. **段文件写一次不改**，序号只增不减。
// =============================================================================

public struct SyncOptions: Sendable {
    public var maxObservationsPerSegment = 2_000
    public var maxTextBytesPerSegment = 8 * 1024 * 1024
    public var maxTombstonesPerSegment = 500
    /// 一次 `exportOnce` 最多写几个段（防止第一次同步时一口气写几百个文件占住线程）。
    public var maxSegmentsPerRun = 8
    /// 等 iCloud 把占位符下成实体的上限。
    public var downloadTimeout: TimeInterval = 60
    /// 写进 `devices/<id>.json` 的设备名。由调用方给（app 用电脑名），库里不产生。
    public var deviceName: String?

    public init() {}
}

public struct SyncExportReport: Sendable, Equatable {
    public var segments: Int = 0
    public var observations: Int = 0
    public var texts: Int = 0
    public var occurrences: Int = 0
    public var tombstones: Int = 0
    public var textPayloadBytes: Int = 0
    public var fileBytes: Int = 0
    public var firstSeq: Int64?
    public var lastSeq: Int64?
    public var elapsedMS: Double = 0
}

public struct SyncImportReport: Sendable, Equatable {
    public var segments: Int = 0
    public var stats = SyncImportStats()
    /// 每个对端的结果：正常导到哪、或者卡在什么错误上。
    public var peers: [String: String] = [:]
    public var errors: [String] = []
    public var elapsedMS: Double = 0

    public var ok: Bool { errors.isEmpty }
}

public struct SyncStatus: Sendable {
    public var directory: String
    public var deviceID: String
    public var keyID: String
    public var state: SyncStateSnapshot
    /// 目录里看到的其他设备。
    public var peers: [String]
    /// 每个对端还有几段没导入。
    public var pendingImports: [String: Int]
    /// 本机段文件在目录里还剩几个（ack 后会被清理）。
    public var ownSegments: Int
    public var segmentBytes: Int
}

/// 一次同步会话。
///
/// **并发口径**：标了 `@unchecked Sendable` 是为了能被丢进一条串行队列去跑，
/// **不代表它线程安全**——它内部没有锁，同一个实例在两条线程上同时用会同时动库与文件。
/// 调用方必须保证**同一个实例的全部方法都在同一条串行队列上调用**
/// （app 侧见 `SyncController` 的 `queue`；命令行工具是单线程）。
public final class SyncEngine: @unchecked Sendable {

    public let store: Store
    public let folder: SyncFolder
    public let manifest: SyncManifest
    public var options: SyncOptions
    private let key: SymmetricKey
    /// 运行期事件的记录出口（写 `jobs` 的 `runtime_event:sync_*`）。
    private let logEvent: @Sendable (String, String) -> Void

    private init(store: Store, folder: SyncFolder, manifest: SyncManifest,
                 key: SymmetricKey, options: SyncOptions,
                 logEvent: @escaping @Sendable (String, String) -> Void) {
        self.store = store
        self.folder = folder
        self.manifest = manifest
        self.key = key
        self.options = options
        self.logEvent = logEvent
    }

    /// 不标 `Sendable`：`SyncEngine` 本身就不是线程安全的（见类的注释），
    /// 让它跨隔离域传递会掩盖这一点。
    public struct OpenResult {
        public var engine: SyncEngine
        /// 只有"这台机器新建了目录"时才有值：**显示一次**的配对口令（3.9）。
        public var generatedPassphrase: String?
        public var created: Bool
    }

    /// 3.9「打开时的流程」：目录不存在就建 + 生成密钥 + 显示一次口令；
    /// 目录已存在就读 manifest + 用口令解开同步密钥；口令错则不加入。
    ///
    /// - Parameter passphrase: 本机还没有同步密钥时必须给（新设备加入）。已经有了就不用。
    public static func openOrCreate(store: Store, root: URL,
                                    passphrase: String? = nil,
                                    options: SyncOptions = SyncOptions(),
                                    logEvent: @escaping @Sendable (String, String) -> Void = { _, _ in })
        throws -> OpenResult {
        let folder = SyncFolder(root: root)
        try folder.validate(against: store.directory)

        let fm = FileManager.default
        let device = store.deviceID
        let manifestExists = fm.fileExists(atPath: folder.manifestURL.path)
            || fm.fileExists(atPath: folder.root
                .appendingPathComponent(".manifest.json.icloud", isDirectory: false).path)

        // 冲突副本先检查：有两个 manifest 就什么都别做（3.9「边界情况」）。
        let conflicts = folder.manifestConflicts()
        guard conflicts.isEmpty else {
            logEvent("sync_manifest_conflict", "names=\(conflicts.joined(separator: ","))")
            throw SyncError.manifestConflict(names: conflicts)
        }

        if !manifestExists {
            // —— 首台：建目录、生成同步密钥、显示一次配对口令 ——
            let syncKey = SyncKeyring.generateSyncKey()
            let pass = try passphrase.map { try SyncKeyring.normalize(passphrase: $0) }
                ?? SyncKeyring.generatePassphrase()
            let manifest = SyncManifest(createdBy: device, keyID: SyncKeyring.keyID(syncKey))
            try folder.createSkeleton(device: device)
            try folder.writeAtomically(try encode(manifest), to: folder.manifestURL)
            let wrapped = try SyncKeyring.wrap(syncKey: syncKey, passphrase: pass, device: device)
            try folder.writeAtomically(try encode(wrapped), to: folder.keyringURL(device: device))
            try store.syncSetKeyMaterial(syncKey.withUnsafeBytes { Data($0) },
                                         keyID: manifest.keyID)
            try store.syncSetDirectoryPath(folder.root.path)
            let engine = SyncEngine(store: store, folder: folder, manifest: manifest,
                                    key: syncKey, options: options, logEvent: logEvent)
            try engine.registerSelf()
            logEvent("sync_folder_created", "key_id=\(manifest.keyID) device=\(device)")
            return OpenResult(engine: engine,
                              generatedPassphrase: SyncKeyring.formatted(pass),
                              created: true)
        }

        // —— 目录已存在 ——
        let manifestData = try folder.read(folder.manifestURL, timeout: options.downloadTimeout)
        let manifest = try JSONDecoder().decode(SyncManifest.self, from: manifestData)
        guard manifest.format == SyncManifest.formatName else {
            throw SyncError.unsupportedManifest("format = \(manifest.format)")
        }
        guard manifest.version <= SyncManifest.currentVersion else {
            throw SyncError.unsupportedManifest(
                "version = \(manifest.version)，本版本支持到 \(SyncManifest.currentVersion)")
        }

        let syncKey: SymmetricKey
        if let stored = try store.syncKeyMaterial(), stored.count == 32,
           SyncKeyring.keyID(SymmetricKey(data: stored)) == manifest.keyID {
            syncKey = SymmetricKey(data: stored)
        } else {
            guard let passphrase else {
                if let stored = try store.syncKeyMaterial(), stored.count == 32 {
                    throw SyncError.keyMismatch(expected: manifest.keyID,
                                                found: SyncKeyring.keyID(SymmetricKey(data: stored)))
                }
                throw SyncError.keyRequired
            }
            syncKey = try unwrapFromKeyring(folder: folder, manifest: manifest,
                                            passphrase: passphrase, timeout: options.downloadTimeout)
            // 加入成功：把密钥留在本机加密库里，并写自己那一份 keyring（自己的盐）。
            try store.syncSetKeyMaterial(syncKey.withUnsafeBytes { Data($0) }, keyID: manifest.keyID)
            let wrapped = try SyncKeyring.wrap(syncKey: syncKey, passphrase: passphrase,
                                               device: device)
            try folder.createSkeleton(device: device)
            try folder.writeAtomically(try encode(wrapped), to: folder.keyringURL(device: device))
            logEvent("sync_joined", "key_id=\(manifest.keyID) device=\(device)")
        }
        try store.syncSetDirectoryPath(folder.root.path)
        let engine = SyncEngine(store: store, folder: folder, manifest: manifest,
                                key: syncKey, options: options, logEvent: logEvent)
        try engine.registerSelf()
        return OpenResult(engine: engine, generatedPassphrase: nil, created: false)
    }

    /// 用口令去试 keyring 里每一份包裹。全试不开 = 口令错，不加入。
    private static func unwrapFromKeyring(folder: SyncFolder, manifest: SyncManifest,
                                          passphrase: String, timeout: TimeInterval) throws -> SymmetricKey {
        let names = folder.entries(at: folder.keyringDirectory).filter { $0.hasSuffix(".wrapped") }
        guard !names.isEmpty else {
            throw SyncError.keyring("keyring/ 里一份包裹都没有，目录不完整")
        }
        var lastError: Error = SyncError.wrongPassphrase
        for name in names {
            let url = folder.keyringDirectory.appendingPathComponent(name, isDirectory: false)
            guard let data = try? folder.read(url, timeout: timeout),
                  let item = try? JSONDecoder().decode(SyncKeyring.Wrapped.self, from: data) else {
                continue
            }
            guard item.keyID == manifest.keyID else { continue }
            do {
                return try SyncKeyring.unwrap(item, passphrase: passphrase)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 3.9「注册本机」：写 `devices/<device_id>.json`。
    public func registerSelf() throws {
        try folder.createSkeleton(device: store.deviceID)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let url = folder.deviceURL(store.deviceID)
        var joined = now
        if let data = try? folder.read(url, timeout: options.downloadTimeout),
           let existing = try? JSONDecoder().decode(SyncDeviceRecord.self, from: data) {
            joined = existing.joinedAt
        }
        let lastSeq = max(0, (try store.syncState().nextSeq) - 1)
        let record = SyncDeviceRecord(device: store.deviceID, name: options.deviceName,
                                      joinedAt: joined, updatedAt: now, lastSeq: lastSeq)
        try folder.writeAtomically(try Self.encode(record), to: url)
    }

    // MARK: - 出站循环

    /// 把待出站记录打成段文件写进 `segments/<本机>/`。
    ///
    /// 顺序很重要：**先写文件、再推水位线**。反过来的话，写文件失败会把那批记录永久漏掉。
    /// 现在的失败模式是"可能重复出一个段"，而重复段在对端是幂等的。
    @discardableResult
    public func exportOnce() throws -> SyncExportReport {
        let t0 = Date()
        var report = SyncExportReport()
        for _ in 0..<options.maxSegmentsPerRun {
            guard let segment = try store.syncExportNext(
                maxObservations: options.maxObservationsPerSegment,
                maxTextBytes: options.maxTextBytesPerSegment,
                maxTombstones: options.maxTombstonesPerSegment) else { break }
            let data = try SyncSegmentFile.seal(segment, key: key)
            let url = folder.segmentURL(device: store.deviceID, seq: segment.seq)
            try folder.writeAtomically(data, to: url)
            try store.syncCommitExport(segment)

            let stats = Store.exportStats(of: segment)
            report.segments += 1
            report.observations += stats.observations
            report.texts += stats.texts
            report.occurrences += stats.occurrences
            report.tombstones += stats.tombstones
            report.textPayloadBytes += stats.textPayloadBytes
            report.fileBytes += data.count
            if report.firstSeq == nil { report.firstSeq = segment.seq }
            report.lastSeq = segment.seq
        }
        if report.segments > 0 {
            try registerSelf()
            logEvent("sync_export",
                     "segments=\(report.segments) observations=\(report.observations) "
                   + "tombstones=\(report.tombstones) bytes=\(report.fileBytes) "
                   + "seq=\(report.firstSeq ?? 0)..\(report.lastSeq ?? 0)")
        }
        report.elapsedMS = Date().timeIntervalSince(t0) * 1000
        return report
    }

    // MARK: - 入站循环

    /// 扫描其他设备的段目录，按 seq 顺序导入。
    ///
    /// 每个对端独立处理：一个对端缺段 / 坏段并不影响另一个对端继续导。
    /// 但**同一个对端内部绝不跳过**——缺第 n 段就停在 n，把 n 之后的都留着，等它到齐。
    @discardableResult
    public func importOnce() throws -> SyncImportReport {
        let t0 = Date()
        var report = SyncImportReport()
        let conflicts = folder.manifestConflicts()
        guard conflicts.isEmpty else {
            logEvent("sync_manifest_conflict", "names=\(conflicts.joined(separator: ","))")
            throw SyncError.manifestConflict(names: conflicts)
        }

        let me = store.deviceID
        for peer in folder.knownDevices() where peer != me {
            try store.syncTouchPeer(deviceID: peer, name: peerName(peer))
            let available = folder.segmentSequences(device: peer)
            let imported = (try store.syncPeers().first { $0.deviceID == peer })?.importedSeq ?? 0
            var next = imported + 1
            var count = 0
            do {
                while available.contains(next) {
                    let url = folder.segmentURL(device: peer, seq: next)
                    let data = try folder.read(url, timeout: options.downloadTimeout)
                    let opened = try SyncSegmentFile.open(data, key: key)
                    guard let segment = opened.segment else {
                        throw SyncError.corruptSegment("没有载荷")
                    }
                    guard segment.device == peer else {
                        throw SyncError.corruptSegment(
                            "段头里的设备是 \(segment.device)，却放在 \(peer) 的目录下")
                    }
                    let stats = try store.syncImport(segment)
                    report.stats.merge(stats)
                    report.segments += 1
                    count += 1
                    next += 1
                }
                try store.syncSetPeerError(deviceID: peer, error: nil)
                if let ahead = available.first(where: { $0 > next }) {
                    // 后面的段已经到了，中间这一段还没到：明确报缺段，不跳过。
                    let error = SyncError.missingSegment(device: peer, expected: next,
                                                         available: available)
                    report.errors.append("\(error)")
                    report.peers[peer] = "缺第 \(next) 段（已有到 \(ahead) 的后续段），停在这里"
                    try store.syncSetPeerError(deviceID: peer, error: "缺第 \(next) 段")
                    logEvent("sync_missing_segment", "device=\(peer) expected=\(next)")
                } else {
                    report.peers[peer] = count > 0 ? "导入 \(count) 段，到 seq \(next - 1)"
                                                   : "没有新段（到 seq \(imported)）"
                }
            } catch {
                let text = "\(error)"
                report.errors.append(text)
                report.peers[peer] = text
                try? store.syncSetPeerError(deviceID: peer, error: text)
                logEvent("sync_import_failed", "device=\(peer) seq=\(next) error=\(text)")
            }
        }
        try writeAck()
        if report.segments > 0 {
            logEvent("sync_import",
                     "segments=\(report.segments) observations=\(report.stats.observationsInserted) "
                   + "skipped=\(report.stats.observationsSkipped) "
                   + "tombstones=\(report.stats.tombstonesApplied) "
                   + "tombstoned_observations=\(report.stats.observationsTombstoned)")
        }
        report.elapsedMS = Date().timeIntervalSince(t0) * 1000
        return report
    }

    private func peerName(_ device: String) -> String? {
        guard let data = try? folder.read(folder.deviceURL(device), timeout: options.downloadTimeout),
              let record = try? JSONDecoder().decode(SyncDeviceRecord.self, from: data) else {
            return nil
        }
        return record.name
    }

    /// 写 `acks/<本机>.json`：本机已导入各设备到哪个 seq。
    public func writeAck() throws {
        var imported: [String: Int64] = [:]
        for peer in try store.syncPeers() where peer.importedSeq > 0 {
            imported[peer.deviceID] = peer.importedSeq
        }
        try folder.writeAck(SyncAckRecord(device: store.deviceID,
                                          updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
                                          imported: imported))
    }

    /// 3.9「清理」：两边都 ack 的本机段文件删掉。
    @discardableResult
    public func cleanup() throws -> (deleted: Int, watermark: Int64) {
        let result = try folder.cleanupAckedSegments(device: store.deviceID,
                                                     timeout: options.downloadTimeout)
        if result.deleted > 0 {
            logEvent("sync_cleanup", "deleted=\(result.deleted) watermark=\(result.watermark)")
        }
        return result
    }

    /// 一轮完整的同步：入站 → 出站 → 清理。app 的定时器调它。
    @discardableResult
    public func runOnce() throws -> (imported: SyncImportReport, exported: SyncExportReport,
                                     cleaned: Int) {
        let imported = try importOnce()
        let exported = try exportOnce()
        let cleaned = (try? cleanup().deleted) ?? 0
        return (imported, exported, cleaned)
    }

    // MARK: - 状态

    public func status() throws -> SyncStatus {
        let state = try store.syncState()
        let me = store.deviceID
        var pending: [String: Int] = [:]
        for peer in folder.knownDevices() where peer != me {
            let imported = state.peers.first { $0.deviceID == peer }?.importedSeq ?? 0
            pending[peer] = folder.segmentSequences(device: peer).filter { $0 > imported }.count
        }
        return SyncStatus(directory: folder.root.path, deviceID: me, keyID: manifest.keyID,
                          state: state, peers: folder.knownDevices().filter { $0 != me },
                          pendingImports: pending,
                          ownSegments: folder.segmentSequences(device: me).count,
                          segmentBytes: folder.segmentBytes())
    }

    // MARK: - 小工具

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(value)
    }
}

extension SyncImportStats {
    mutating func merge(_ other: SyncImportStats) {
        observationsInserted += other.observationsInserted
        observationsSkipped += other.observationsSkipped
        occurrencesInserted += other.occurrencesInserted
        textVersionsInserted += other.textVersionsInserted
        textVersionsReused += other.textVersionsReused
        tombstonesApplied += other.tombstonesApplied
        tombstonesSkipped += other.tombstonesSkipped
        observationsTombstoned += other.observationsTombstoned
        occurrencesDeleted += other.occurrencesDeleted
        textVersionsDeleted += other.textVersionsDeleted
        sessionsStale += other.sessionsStale
        ledgersStale += other.ledgersStale
    }
}

extension SyncKeyring {
    /// 显示用：把规范形式切成 `ABCD-EFGH-…`。
    public static func formatted(_ normalized: String) -> String {
        var out = ""
        for (index, character) in normalized.enumerated() {
            if index > 0 && index % passphraseGroupLength == 0 { out.append("-") }
            out.append(character)
        }
        return out
    }
}
