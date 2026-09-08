import CryptoKit
import Foundation

// =============================================================================
// 3.8 加密归档的**文件层**：目录布局、块的封装 / 打开、manifest 的读写。
//
// 目录（不是单文件容器，理由见下）：
//
//   <归档目录>/
//   ├── manifest.json                明文清单（格式版本、时刻、来源 device_id、范围、
//   │                                加密参数、每块校验、总校验、清单 HMAC；**没有正文**）
//   └── blocks/000000.blk            每块 ≤ 8 MiB 明文，AES-256-GCM 加密
//       blocks/000001.blk
//
// 块文件的字节布局（全部大端）：
//
//   0..5   magic "BRSEXP"
//   6      块格式版本（当前 1）
//   7      保留，恒 0
//   8..    AES-GCM 的 combined 表示（12 字节 nonce + 密文 + 16 字节 tag）
//
// -------------------------------------------------------------------------
// 为什么选"归档目录"而不是单文件容器（3.8 要求二选一并写明）
// -------------------------------------------------------------------------
//  1. **内存上界**：导出端一次只攒一块明文（8 MiB）就落盘，导入端一次只解一块。
//     单文件容器要么在文件头留一张偏移表（写完才知道，得回头改文件头），
//     要么把长度写在每块前面（那就是自己做一遍 tar，还得自己处理截断）。
//  2. **坏一块能说清是哪一块**：manifest 里每块一条 SHA-256，`missingBlock` /
//     `blockChecksumMismatch` / `blockDecryptFailed` 三种错误都带块号。
//  3. **不输口令就能看清单**：`manifest.json` 是普通文本，用户面对一堆归档时
//     不用一个个试口令才知道哪份是哪份。
//  4. 用户要一个文件的时候，Finder 右键压缩就是一个文件；反过来把单文件容器
//     拆成可校验的块就得写一个解包器。
//
// 代价：归档是一个目录，拷贝时不能只拖一个文件；manifest 明文暴露了时间范围与
// bundle id 名单（应用标识，不是内容）。两条都写在 core/README 与结果文件里。
// =============================================================================

/// AAD：把每一块绑死在"这一份归档的这一个位置"上。
///
/// 改块文件名（把 5 号改成 3 号）、改 manifest 里的 `archive_id` / `source_device` /
/// `created_at` / 盐 / 迭代数、改这一块登记的 `plain_bytes` 或 `rows`，
/// 解密都会失败，而不是"解开了但错位"。
struct ExportBlockAAD: Codable {
    var format: String
    var version: Int
    var payload: Int
    var archive: String
    var device: String
    var createdAt: Int64
    var salt: Data
    var iterations: Int
    var seq: Int
    var plainBytes: Int
    var rows: Int

    enum CodingKeys: String, CodingKey {
        case format, version, payload, archive, device, salt, iterations, seq, rows
        case createdAt = "created_at"
        case plainBytes = "plain_bytes"
    }
}

/// 一块解出来的载荷。
public struct ExportBlockPayload: Sendable {
    public var head: ExportBlockHead
    public var texts: [ExportTextRecord] = []
    public var observations: [ExportObservationRecord] = []
    public var deletions: [ExportDeletionRecord] = []
    public var sessions: [ExportSessionRecord] = []
    public var ledgers: [ExportLedgerRecord] = []
    public var policies: [ExportPolicyRecord] = []
    public var events: [ExportEventRecord] = []

    public var rows: Int {
        texts.count + observations.count + deletions.count + sessions.count
            + ledgers.count + policies.count + events.count
    }
}

public enum ExportArchive {

    // MARK: - 行类型

    /// JSON Lines 行首的 `k`。
    enum LineKind: String {
        case head = "h"
        case text = "t"
        case observation = "o"
        case deletion = "d"
        case session = "s"
        case ledger = "l"
        case policy = "p"
        case event = "e"
    }

    struct LineEnvelopeKind: Codable { var k: String }
    struct LineEnvelope<T: Codable>: Codable {
        var k: String
        var v: T
    }

    // MARK: - 块的封装 / 打开

    static func seal(plain: Data, aad: ExportBlockAAD, key: SymmetricKey) throws
        -> (bytes: Data, cipherBytes: Int, checksum: String) {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce,
                                      authenticating: try aadBytes(aad))
        guard let combined = sealed.combined else {
            throw ExportError.filesystem("AES-GCM combined 表示不可用")
        }
        var out = Data()
        out.append(contentsOf: ExportFormat.magic)
        out.append(ExportFormat.blockVersion)
        out.append(0)
        out.append(combined)
        return (out, combined.count, ExportKeyring.hex(SHA256.hash(data: combined)))
    }

    /// 打开一块。三层校验各管一件事，报错要能分辨（与 3.9 段文件同一套分工）：
    /// 1. 密文 SHA-256 ↔ manifest → **文件坏了 / 被改过**（不需要口令就能查）；
    /// 2. GCM tag（AAD = 归档身份 + 块位置）→ 密钥不对，或块头 / 登记信息被改过；
    /// 3. 明文字节数 ↔ 登记 → 明文与清单不一致。
    static func open(fileBytes: Data, info: ExportBlockInfo, aad: ExportBlockAAD,
                     key: SymmetricKey) throws -> Data {
        let headerLength = ExportFormat.magic.count + 2
        guard fileBytes.count > headerLength else {
            throw ExportError.corruptBlock(seq: info.seq, detail: "文件太短（\(fileBytes.count) 字节）")
        }
        let bytes = [UInt8](fileBytes)
        guard Array(bytes[0..<ExportFormat.magic.count]) == ExportFormat.magic else {
            throw ExportError.corruptBlock(seq: info.seq, detail: "magic 不对，不是 brosis 归档块")
        }
        let version = bytes[ExportFormat.magic.count]
        guard version == ExportFormat.blockVersion else {
            throw ExportError.unsupportedVersion(found: Int(version),
                                                 supported: Int(ExportFormat.blockVersion))
        }
        let combined = Data(bytes[headerLength...])
        guard combined.count == info.cipherBytes else {
            throw ExportError.blockChecksumMismatch(seq: info.seq)
        }
        guard ExportKeyring.hex(SHA256.hash(data: combined)) == info.checksum else {
            throw ExportError.blockChecksumMismatch(seq: info.seq)
        }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw ExportError.corruptBlock(seq: info.seq, detail: "密文结构不合法")
        }
        let aadData = try aadBytes(aad)
        guard let plain = try? AES.GCM.open(box, using: key, authenticating: aadData) else {
            throw ExportError.blockDecryptFailed(seq: info.seq)
        }
        guard plain.count == info.plainBytes else {
            throw ExportError.corruptBlock(
                seq: info.seq, detail: "明文字节数与清单不符（\(plain.count) vs \(info.plainBytes)）")
        }
        return plain
    }

    static func aadBytes(_ aad: ExportBlockAAD) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data(ExportFormat.magic)
        out.append(ExportFormat.blockVersion)
        out.append(try encoder.encode(aad))
        return out
    }

    static func aad(for info: ExportBlockInfo, manifest: ExportManifest) -> ExportBlockAAD {
        ExportBlockAAD(format: manifest.format, version: manifest.version,
                       payload: manifest.payloadVersion, archive: manifest.archiveID,
                       device: manifest.sourceDevice, createdAt: manifest.createdAt,
                       salt: manifest.salt, iterations: manifest.kdfIterations,
                       seq: info.seq, plainBytes: info.plainBytes, rows: info.rows)
    }

    // MARK: - 明文解码

    static func decodeBlock(_ plain: Data, seq: Int) throws -> ExportBlockPayload {
        let decoder = JSONDecoder()
        var head: ExportBlockHead?
        var texts: [ExportTextRecord] = []
        var observations: [ExportObservationRecord] = []
        var deletions: [ExportDeletionRecord] = []
        var sessions: [ExportSessionRecord] = []
        var ledgers: [ExportLedgerRecord] = []
        var policies: [ExportPolicyRecord] = []
        var events: [ExportEventRecord] = []

        for slice in plain.split(separator: UInt8(ascii: "\n")) where !slice.isEmpty {
            let line = Data(slice)
            guard let envelope = try? decoder.decode(LineEnvelopeKind.self, from: line),
                  let kind = LineKind(rawValue: envelope.k) else {
                // **不静默跳过**：归档是我们自己写的，出现未知行类型只可能是版本不对
                // 或者被改过，两种都该停。
                throw ExportError.corruptBlock(seq: seq, detail: "未知的行类型")
            }
            do {
                switch kind {
                case .head:
                    head = try decoder.decode(LineEnvelope<ExportBlockHead>.self, from: line).v
                case .text:
                    texts.append(try decoder.decode(LineEnvelope<ExportTextRecord>.self, from: line).v)
                case .observation:
                    observations.append(
                        try decoder.decode(LineEnvelope<ExportObservationRecord>.self, from: line).v)
                case .deletion:
                    deletions.append(
                        try decoder.decode(LineEnvelope<ExportDeletionRecord>.self, from: line).v)
                case .session:
                    sessions.append(
                        try decoder.decode(LineEnvelope<ExportSessionRecord>.self, from: line).v)
                case .ledger:
                    ledgers.append(
                        try decoder.decode(LineEnvelope<ExportLedgerRecord>.self, from: line).v)
                case .policy:
                    policies.append(
                        try decoder.decode(LineEnvelope<ExportPolicyRecord>.self, from: line).v)
                case .event:
                    events.append(
                        try decoder.decode(LineEnvelope<ExportEventRecord>.self, from: line).v)
                }
            } catch {
                throw ExportError.corruptBlock(seq: seq, detail: "「\(kind.rawValue)」行解不开")
            }
        }
        guard let head else { throw ExportError.corruptBlock(seq: seq, detail: "块里没有头行") }
        guard head.seq == seq else {
            throw ExportError.corruptBlock(seq: seq, detail: "块头里的序号是 \(head.seq)")
        }
        guard head.format == ExportFormat.payloadVersion else {
            throw ExportError.unsupportedVersion(found: head.format,
                                                 supported: ExportFormat.payloadVersion)
        }
        return ExportBlockPayload(head: head, texts: texts, observations: observations,
                                  deletions: deletions, sessions: sessions, ledgers: ledgers,
                                  policies: policies, events: events)
    }

    // MARK: - 总校验

    /// 全部块的密文校验和按序拼起来再哈希。**不需要口令**就能发现"少了一整块 / 块被换了序"。
    static func totalChecksum(archiveID: String, blocks: [ExportBlockInfo]) -> String {
        var material = "brosis-export/1|" + archiveID
        for block in blocks { material += "|\(block.seq):\(block.checksum)" }
        return ExportKeyring.hex(SHA256.hash(data: Data(material.utf8)))
    }

    // MARK: - manifest 读写

    public static func manifestURL(root: URL) -> URL {
        root.appendingPathComponent(ExportFormat.manifestFileName, isDirectory: false)
    }

    public static func blockURL(root: URL, seq: Int) -> URL {
        root.appendingPathComponent(ExportFormat.blocksDirectoryName, isDirectory: true)
            .appendingPathComponent(ExportFormat.blockFileName(seq), isDirectory: false)
    }

    /// 读清单。**不需要口令**，也不碰任何块。
    /// 做三件事：格式名与版本、块文件都在不在、总校验和对不对。
    public static func readManifest(root: URL) throws -> ExportManifest {
        let url = manifestURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExportError.notAnArchive("目录里没有 \(ExportFormat.manifestFileName)")
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw ExportError.manifestUnreadable("\(error)")
        }
        let manifest: ExportManifest
        do { manifest = try JSONDecoder().decode(ExportManifest.self, from: data) } catch {
            throw ExportError.manifestUnreadable("\(error)")
        }
        guard manifest.format == ExportFormat.formatName else {
            throw ExportError.notAnArchive("format = \(manifest.format)")
        }
        guard manifest.version == ExportFormat.version else {
            throw ExportError.unsupportedVersion(found: manifest.version,
                                                 supported: ExportFormat.version)
        }
        guard manifest.payloadVersion == ExportFormat.payloadVersion else {
            throw ExportError.unsupportedVersion(found: manifest.payloadVersion,
                                                 supported: ExportFormat.payloadVersion)
        }
        guard totalChecksum(archiveID: manifest.archiveID, blocks: manifest.blocks)
                == manifest.totalChecksum else {
            throw ExportError.totalChecksumMismatch
        }
        for block in manifest.blocks {
            let path = blockURL(root: root, seq: block.seq).path
            guard FileManager.default.fileExists(atPath: path) else {
                throw ExportError.missingBlock(seq: block.seq)
            }
        }
        return manifest
    }

    /// 归档目录占多少字节（manifest + 全部块）。
    public static func archiveBytes(root: URL, manifest: ExportManifest) -> Int {
        func size(_ url: URL) -> Int {
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
                .intValue ?? 0
        }
        return size(manifestURL(root: root))
            + manifest.blocks.reduce(0) { $0 + size(blockURL(root: root, seq: $1.seq)) }
    }
}

// MARK: - 写

/// 顺序写一份归档。**单线程使用**：导出循环在一条串行队列上跑。
final class ExportArchiveWriter {

    let root: URL
    let archiveID: String
    let salt: Data
    let createdAt: Int64
    let sourceDevice: String
    let schemaVersion: Int
    let scope: ExportScope
    private let keys: ExportKeyring.ArchiveKeys
    private let blockPlainBytes: Int
    private let encoder: JSONEncoder

    private var pending = Data()
    private var pendingRows = 0
    private var blocks: [ExportBlockInfo] = []
    private(set) var bytesWritten = 0

    init(root: URL, passphrase: String, sourceDevice: String, schemaVersion: Int,
         scope: ExportScope, blockPlainBytes: Int, now: Int64) throws {
        try ExportKeyring.requireStrong(passphrase)
        guard blockPlainBytes >= 64 * 1024 else {
            throw ExportError.invalidRequest("块明文上限太小（\(blockPlainBytes) 字节），至少 64 KiB")
        }
        self.root = root
        self.archiveID = ExportKeyring.hex(try ExportKeyring.randomBytes(16))
        self.salt = try ExportKeyring.randomBytes(ExportKeyring.saltBytes)
        self.createdAt = now
        self.sourceDevice = sourceDevice
        self.schemaVersion = schemaVersion
        self.scope = scope
        self.keys = try ExportKeyring.derive(passphrase: passphrase, salt: salt)
        self.blockPlainBytes = blockPlainBytes
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        // 一次要到位、之后靠 `removeAll(keepingCapacity:)` 复用：
        // 不预留的话每块都要把缓冲区从 0 翻倍长到 8 MiB（约 20 次重分配 × 块数），
        // 释放掉的大块留在分配器里算进 footprint。1 个月合成库上实测峰值
        // 538.8 MiB → 143.4 MiB（见结果文件）。
        pending.reserveCapacity(blockPlainBytes + 1 << 20)

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw ExportError.invalidRequest("目标已存在且不是目录：\(root.lastPathComponent)")
            }
            let existing = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            guard existing.filter({ !$0.hasPrefix(".") }).isEmpty else {
                throw ExportError.invalidRequest(
                    "目标目录不是空的（\(root.lastPathComponent)）；归档写一次不改，请换一个新目录")
            }
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(
                at: root.appendingPathComponent(ExportFormat.blocksDirectoryName, isDirectory: true),
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw ExportError.filesystem("建归档目录失败：\(error)")
        }
    }

    // MARK: - 追加行

    func append<T: Codable>(_ kind: ExportArchive.LineKind, _ value: T) throws {
        try beginBlockIfNeeded()
        pending.append(contentsOf: Array("{\"k\":\"\(kind.rawValue)\",\"v\":".utf8))
        pending.append(try encoder.encode(value))
        pending.append(contentsOf: Array("}\n".utf8))
        pendingRows += 1
        if pending.count >= blockPlainBytes { try flush() }
    }

    private func beginBlockIfNeeded() throws {
        guard pending.isEmpty else { return }
        let head = ExportBlockHead(format: ExportFormat.payloadVersion, archive: archiveID,
                                   device: sourceDevice, seq: blocks.count, at: createdAt)
        pending.append(contentsOf: Array("{\"k\":\"h\",\"v\":".utf8))
        pending.append(try encoder.encode(head))
        pending.append(contentsOf: Array("}\n".utf8))
        pendingRows = 0
    }

    /// 把攒着的明文封成一块写出去。
    func flush() throws {
        guard !pending.isEmpty else { return }
        let seq = blocks.count
        let aad = ExportBlockAAD(
            format: ExportFormat.formatName, version: ExportFormat.version,
            payload: ExportFormat.payloadVersion, archive: archiveID, device: sourceDevice,
            createdAt: createdAt, salt: salt, iterations: ExportKeyring.kdfIterations,
            seq: seq, plainBytes: pending.count, rows: pendingRows)
        let sealed = try ExportArchive.seal(plain: pending, aad: aad, key: keys.data)
        let url = ExportArchive.blockURL(root: root, seq: seq)
        do {
            try sealed.bytes.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        } catch {
            throw ExportError.filesystem("写块 \(seq) 失败：\(error)")
        }
        blocks.append(ExportBlockInfo(seq: seq, rows: pendingRows, plainBytes: pending.count,
                                      cipherBytes: sealed.cipherBytes, checksum: sealed.checksum))
        bytesWritten += sealed.bytes.count
        pending.removeAll(keepingCapacity: true)
        pendingRows = 0
    }

    var blockCount: Int { blocks.count }
    var plainBytesWritten: Int { blocks.reduce(0) { $0 + $1.plainBytes } }

    // MARK: - 收尾

    func finish(counts: ExportCounts, notes: [String]) throws -> ExportManifest {
        try flush()
        var manifest = ExportManifest(
            format: ExportFormat.formatName, version: ExportFormat.version,
            payloadVersion: ExportFormat.payloadVersion, archiveID: archiveID,
            createdAt: createdAt, sourceDevice: sourceDevice, schemaVersion: schemaVersion,
            aead: ExportKeyring.aeadName, kdf: ExportKeyring.kdfAlgorithm,
            kdfIterations: ExportKeyring.kdfIterations, salt: salt, verifier: keys.verifier,
            blockPlainBytes: blockPlainBytes, scope: scope, counts: counts, blocks: blocks,
            totalChecksum: ExportArchive.totalChecksum(archiveID: archiveID, blocks: blocks),
            mac: "", notes: notes)
        manifest.mac = try ExportKeyring.manifestMAC(manifest, key: keys.manifestMAC)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        let url = ExportArchive.manifestURL(root: root)
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        } catch {
            throw ExportError.filesystem("写 manifest 失败：\(error)")
        }
        bytesWritten += data.count
        return manifest
    }
}

// MARK: - 读

/// 打开一份归档并逐块解出来。
public struct ExportArchiveReader {

    public let root: URL
    public let manifest: ExportManifest
    private let keys: ExportKeyring.ArchiveKeys

    /// 打开归档：先核**口令**（`verifier`，不碰任何块），再核**清单**（HMAC）。
    /// 于是"口令错"与"清单被改过"是两种不同的错误，用户能据此判断该重输口令还是该换一份归档。
    public init(root: URL, passphrase: String) throws {
        let manifest = try ExportArchive.readManifest(root: root)
        try self.init(root: root, manifest: manifest, passphrase: passphrase)
    }

    public init(root: URL, manifest: ExportManifest, passphrase: String) throws {
        let keys = try ExportKeyring.derive(passphrase: passphrase, salt: manifest.salt,
                                            iterations: manifest.kdfIterations)
        guard keys.verifier == manifest.verifier else { throw ExportError.wrongPassphrase }
        guard try ExportKeyring.manifestMAC(manifest, key: keys.manifestMAC) == manifest.mac else {
            throw ExportError.manifestTampered
        }
        self.root = root
        self.manifest = manifest
        self.keys = keys
    }

    /// 解一块。
    public func block(_ index: Int) throws -> ExportBlockPayload {
        let info = manifest.blocks[index]
        let url = ExportArchive.blockURL(root: root, seq: info.seq)
        guard let bytes = try? Data(contentsOf: url) else {
            throw ExportError.missingBlock(seq: info.seq)
        }
        let aad = ExportArchive.aad(for: info, manifest: manifest)
        let plain = try ExportArchive.open(fileBytes: bytes, info: info, aad: aad, key: keys.data)
        let payload = try ExportArchive.decodeBlock(plain, seq: info.seq)
        guard payload.rows == info.rows else {
            throw ExportError.corruptBlock(seq: info.seq,
                                           detail: "行数与清单不符（\(payload.rows) vs \(info.rows)）")
        }
        return payload
    }

    public func forEachBlock(_ body: (Int, ExportBlockPayload) throws -> Void) throws {
        for index in manifest.blocks.indices {
            try body(index, try self.block(index))
        }
    }

    /// 全量校验：每块都解一遍、核字节数与行数，再把类型计数与 manifest 对一遍。
    /// `brosis-store import --dry-run` 与导入前的预检都走它。
    public func verify() throws -> ExportVerifyReport {
        let t0 = Date()
        var counts = ExportCounts()
        var rows = 0
        try forEachBlock { _, payload in
            rows += payload.rows
            counts.textVersions += payload.texts.count
            counts.textPayloadBytes += payload.texts.reduce(0) { $0 + $1.len }
            counts.observations += payload.observations.count
            counts.tombstonedObservations += payload.observations.filter { $0.deletedAt != nil }.count
            counts.occurrences += payload.observations.reduce(0) { $0 + $1.texts.count }
            counts.deletions += payload.deletions.count
            counts.sessions += payload.sessions.count
            counts.ledgers += payload.ledgers.count
            counts.appPolicies += payload.policies.count
            counts.events += payload.events.count
        }
        guard counts == manifest.counts else {
            throw ExportError.corruptBlock(seq: -1, detail: "逐块统计与 manifest 的计数不符")
        }
        return ExportVerifyReport(
            archiveID: manifest.archiveID, blocks: manifest.blocks.count, rows: rows,
            plainBytes: manifest.blocks.reduce(0) { $0 + $1.plainBytes },
            cipherBytes: manifest.blocks.reduce(0) { $0 + $1.cipherBytes },
            counts: counts, manifestMACOK: true, totalChecksumOK: true,
            elapsedMS: Date().timeIntervalSince(t0) * 1000)
    }
}
