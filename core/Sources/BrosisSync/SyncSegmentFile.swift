import BrosisCore
import CryptoKit
import Foundation

// =============================================================================
// D17 / 3.9 的段文件：JSON Lines → AES-256-GCM → `<seq>.seg`，写一次不改。
//
// 字节布局（全部大端）：
//
//   0..5    magic "BRSSEG"
//   6       格式版本（当前 1）
//   7       保留，恒 0
//   8..11   UInt32 段头 JSON 的字节数
//   12..    段头 JSON（**明文**，不含任何密钥；见 SyncSegmentHeader）
//   ...     AES-GCM 的 combined 表示（12 字节 nonce + 密文 + 16 字节 tag）
//
// 三层校验，各管一件事，报错要能分辨：
//   1. `checksum`（段头里的密文 SHA-256）—— 文件在传输 / 同步盘上坏了；
//   2. GCM tag —— 密钥不对，**或者段头被改过**（段头是 AAD，见下）；
//   3. `plainBytes` 与三个计数 —— 解出来的明文与段头声明的不一致。
//
// 段头进 AAD 的作用：把 `<seq>.seg` 改名成别的序号、或者改段头里的 device / seq，
// 解密都会失败，而不是"解开了但内容错位"。3.9 要求"缺段或损坏时停止导入并提示，不跳过"，
// 前提就是这些情况都能被明确检出。
//
// 为什么没有压缩：本轮不引入任何第三方依赖（zstd 不在系统库里），
// Apple 自带的 `Compression` 框架能用，但它会在段文件格式上多加一层要长期兼容的东西；
// 段文件是**用完即删**的传输载体（两边都 ack 就清理），先把正确性做对。
// 体积的实测数字见结果文件。
// =============================================================================

public enum SyncSegmentFile {

    public static let magic = Array("BRSSEG".utf8)
    public static let formatVersion: UInt8 = 1
    /// 文件名里 seq 的位数（补零，好让目录列表按字典序 = 按序号）。
    public static let sequenceDigits = 12

    public static func fileName(seq: Int64) -> String {
        String(format: "%0\(sequenceDigits)d.seg", seq)
    }

    /// 从文件名解析序号；不是段文件就返回 nil。
    public static func sequence(fromFileName name: String) -> Int64? {
        guard name.hasSuffix(".seg") else { return nil }
        let stem = String(name.dropLast(4))
        guard !stem.isEmpty, stem.allSatisfy(\.isNumber) else { return nil }
        return Int64(stem)
    }

    // MARK: - 明文编码（JSON Lines）

    /// 段载荷 → JSON Lines。每行一条记录，行首的 `k` 是类型：
    /// `h` 段头摘要、`t` 正文、`o` 观察（含它的 occurrence）、`d` 墓碑。
    public static func encodeLines(_ segment: SyncSegment) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]      // 逐字节可复现，便于比对与测试
        var out = Data()

        func append(_ kind: String, _ body: Data) {
            out.append(contentsOf: Array("{\"k\":\"\(kind)\",\"v\":".utf8))
            out.append(body)
            out.append(contentsOf: Array("}\n".utf8))
        }
        let head = SegmentLineHead(format: SyncFormat.payloadVersion, device: segment.device,
                                   seq: segment.seq, at: segment.createdAt,
                                   lastObservationID: segment.lastObservationID,
                                   lastDeletionID: segment.lastDeletionID)
        append("h", try encoder.encode(head))
        for text in segment.texts { append("t", try encoder.encode(text)) }
        for observation in segment.observations { append("o", try encoder.encode(observation)) }
        for tombstone in segment.tombstones { append("d", try encoder.encode(tombstone)) }
        return out
    }

    public static func decodeLines(_ data: Data) throws -> SyncSegment {
        let decoder = JSONDecoder()
        var head: SegmentLineHead?
        var texts: [SyncTextRecord] = []
        var observations: [SyncObservationRecord] = []
        var tombstones: [SyncTombstoneRecord] = []

        for slice in data.split(separator: UInt8(ascii: "\n")) where !slice.isEmpty {
            let line = Data(slice)
            let envelope = try decoder.decode(SegmentLineKind.self, from: line)
            switch envelope.k {
            case "h": head = try decoder.decode(SegmentLine<SegmentLineHead>.self, from: line).v
            case "t": texts.append(try decoder.decode(SegmentLine<SyncTextRecord>.self, from: line).v)
            case "o":
                observations.append(
                    try decoder.decode(SegmentLine<SyncObservationRecord>.self, from: line).v)
            case "d":
                tombstones.append(
                    try decoder.decode(SegmentLine<SyncTombstoneRecord>.self, from: line).v)
            default:
                // 未知行类型：**不静默跳过**。段是我们自己写的，出现未知类型只可能是格式版本不对
                // 或者文件被改过，两种都该停。
                throw SyncError.corruptSegment("未知的行类型「\(envelope.k)」")
            }
        }
        guard let head else { throw SyncError.corruptSegment("段里没有头行") }
        guard head.format == SyncFormat.payloadVersion else {
            throw SyncError.unsupportedFormat(found: head.format, supported: SyncFormat.payloadVersion)
        }
        return SyncSegment(device: head.device, seq: head.seq, createdAt: head.at,
                           texts: texts, observations: observations, tombstones: tombstones,
                           lastObservationID: head.lastObservationID,
                           lastDeletionID: head.lastDeletionID)
    }

    // MARK: - 加密封装

    /// 载荷 → 段文件字节。
    public static func seal(_ segment: SyncSegment, key: SymmetricKey) throws -> Data {
        let plain = try encodeLines(segment)
        let nonce = AES.GCM.Nonce()
        // 顺序：checksum 是对**最终密文**算的，而密文又取决于 AAD——如果 AAD 里含 checksum
        // 就成了循环依赖。所以 AAD 用「段头去掉 checksum 的骨架」，checksum 只做文件层校验。
        // 于是：骨架 → AAD → 密文 → checksum → 完整段头（骨架 + checksum）写进文件。
        // 读的时候反过来：段头 → 去掉 checksum 得到同一个骨架 → 同一个 AAD。
        let skeleton = SyncSegmentHeader(
            format: Int(formatVersion), device: segment.device, seq: segment.seq,
            createdAt: segment.createdAt, texts: segment.texts.count,
            observations: segment.observations.count, tombstones: segment.tombstones.count,
            plainBytes: plain.count, checksum: "")
        let aad = try aadBytes(skeleton)
        let sealed = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: aad)
        guard let combined = sealed.combined else {
            throw SyncError.corruptSegment("AES-GCM combined 表示不可用")
        }
        var header = skeleton
        header.checksum = hex(SHA256.hash(data: combined))

        var out = Data()
        out.append(contentsOf: magic)
        out.append(formatVersion)
        out.append(0)
        let headerData = try encodeHeader(header)
        out.append(contentsOf: withUnsafeBytes(of: UInt32(headerData.count).bigEndian, Array.init))
        out.append(headerData)
        out.append(combined)
        return out
    }

    /// 段文件字节 → 段头 + 载荷。`key` 为 nil 时只解析并校验段头（状态显示用，不解密）。
    public static func open(_ data: Data, key: SymmetricKey?) throws
        -> (header: SyncSegmentHeader, segment: SyncSegment?) {
        guard data.count > magic.count + 6 else { throw SyncError.corruptSegment("文件太短") }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<magic.count]) == magic else {
            throw SyncError.corruptSegment("magic 不对，不是 brosis 段文件")
        }
        let version = bytes[magic.count]
        guard version == formatVersion else {
            throw SyncError.unsupportedFormat(found: Int(version), supported: Int(formatVersion))
        }
        let lengthStart = magic.count + 2
        let headerLength = Int(UInt32(bytes[lengthStart]) << 24 | UInt32(bytes[lengthStart + 1]) << 16
                             | UInt32(bytes[lengthStart + 2]) << 8 | UInt32(bytes[lengthStart + 3]))
        let headerStart = lengthStart + 4
        guard headerLength > 0, headerStart + headerLength <= bytes.count else {
            throw SyncError.corruptSegment("段头长度越界（\(headerLength)）")
        }
        let headerData = Data(bytes[headerStart..<(headerStart + headerLength)])
        guard let header = try? JSONDecoder().decode(SyncSegmentHeader.self, from: headerData) else {
            throw SyncError.corruptSegment("段头不是合法 JSON")
        }
        let combined = Data(bytes[(headerStart + headerLength)...])

        // 1) 文件层校验和：坏文件与错密钥要能分开报。
        guard hex(SHA256.hash(data: combined)) == header.checksum else {
            throw SyncError.checksumMismatch(device: header.device, seq: header.seq)
        }
        guard let key else { return (header, nil) }

        // 2) GCM：AAD 是"去掉 checksum 的段头骨架"，改 device / seq / 计数都会解密失败。
        var skeleton = header
        skeleton.checksum = ""
        let aad = try aadBytes(skeleton)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw SyncError.corruptSegment("密文结构不合法：\(error)")
        }
        guard let plain = try? AES.GCM.open(box, using: key, authenticating: aad) else {
            throw SyncError.decryptFailed(device: header.device, seq: header.seq)
        }
        // 3) 明文与段头声明的一致性。
        guard plain.count == header.plainBytes else {
            throw SyncError.corruptSegment("明文字节数与段头不符（\(plain.count) vs \(header.plainBytes)）")
        }
        let segment = try decodeLines(plain)
        guard segment.device == header.device, segment.seq == header.seq,
              segment.texts.count == header.texts,
              segment.observations.count == header.observations,
              segment.tombstones.count == header.tombstones else {
            throw SyncError.corruptSegment("段头与载荷不一致（device / seq / 计数）")
        }
        return (header, segment)
    }

    static func encodeHeader(_ header: SyncSegmentHeader) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(header)
    }

    private static func aadBytes(_ skeleton: SyncSegmentHeader) throws -> Data {
        var aad = Data(magic)
        aad.append(formatVersion)
        aad.append(try encodeHeader(skeleton))
        return aad
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 行结构

    struct SegmentLineKind: Codable { var k: String }

    /// `{"k":"o","v":{…}}`。用泛型直接解到目标类型，不经 `JSONSerialization` 二次序列化——
    /// 那会改写数值与转义写法。
    struct SegmentLine<T: Codable>: Codable {
        var k: String
        var v: T
    }

    struct SegmentLineHead: Codable {
        var format: Int
        var device: String
        var seq: Int64
        var at: Int64
        var lastObservationID: Int64
        var lastDeletionID: Int64

        enum CodingKeys: String, CodingKey {
            case format, device, seq, at
            case lastObservationID = "lastObs", lastDeletionID = "lastDel"
        }
    }
}
