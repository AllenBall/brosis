import CommonCrypto
import CryptoKit
import Foundation

// =============================================================================
// D17 / 3.9「密钥」：同步密钥与本机库密钥**分开**，配对口令包裹同步密钥放进 keyring/。
//
// 三把不同的东西，不要混：
//   1. **库密钥**（256 位随机）——SQLCipher 开库用，存 data-protection 钥匙串，从不出本机。
//   2. **同步密钥**（256 位随机）——只用来封段文件。它静态存放在**加密库里**
//      （`sync_state` 的一行），也就是由库密钥保护；进程内存里以 `SymmetricKey` 形式存在。
//      它和库密钥是两把不同的密钥、两种不同的用途，泄露其一不影响另一个：
//      拿到同步密钥只能解段文件（= 已经同步出去的那部分记录），解不开本机库。
//   3. **配对口令**——只在"新设备加入"时用一次，派生出包裹密钥去解 keyring/*.wrapped。
//      口令不存任何地方（首台显示一次，用户自己记）。
//
// KDF 参数（本轮定案，写进 manifest.json 好让将来能升级）：
//   PBKDF2-HMAC-SHA256，迭代 600,000，盐 16 字节随机（每个 wrapped 文件一份自己的盐），
//   输出 32 字节；再经 HKDF-SHA256 扩展（info = "brosis-sync/1 keywrap"）得到包裹密钥。
//   迭代数按 OWASP 2023 对 PBKDF2-HMAC-SHA256 的建议取 600k；本机实测耗时见结果文件。
//   为什么不是 Argon2id：本轮不引入第三方依赖，系统里没有 Argon2；PBKDF2 是
//   CommonCrypto 自带的、经过审计的实现。HKDF 那一步是域分离，防止同一份 PBKDF2 输出
//   将来被别的用途复用。
//
// 包裹本身用 AES-256-GCM，AAD 绑定 "格式 + 设备 id"，所以把 A 的 wrapped 文件改名成 B 的
// 会解不开——而不是解开一把错的密钥。
// =============================================================================

public enum SyncKeyring {

    public static let kdfAlgorithm = "PBKDF2-HMAC-SHA256"
    /// PBKDF2 迭代数。改它要同时改 manifest 里的记录，老的 wrapped 文件按自己文件里记的迭代数解。
    public static let kdfIterations = 600_000
    public static let saltBytes = 16
    public static let hkdfInfo = "brosis-sync/1 keywrap"

    // MARK: - 配对口令

    /// 口令字母表：32 个字符，去掉了 0/O、1/I/L 这些容易念错抄错的。
    /// 32 个字符 = 每字符 5 bit，且 256 % 32 == 0，所以直接对随机字节取模没有偏置。
    public static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
    /// 6 组 × 4 字符 = 24 字符 = **120 bit** 熵。
    public static let passphraseGroups = 6
    public static let passphraseGroupLength = 4

    /// 生成配对口令（首台显示一次），返回**规范形式**（24 个字符、没有分隔符）。
    /// 显示给用户时用 `formatted(_:)` 切成 `ABCD-EFGH-…`。
    public static func generatePassphrase() throws -> String {
        let count = passphraseGroups * passphraseGroupLength
        let bytes = try randomBytes(count)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// 用户输入的口令 → 规范形式：大写、去掉分隔符与空白。字母表之外的字符直接判非法。
    public static func normalize(passphrase: String) throws -> String {
        let upper = passphrase.uppercased()
        var out = ""
        for character in upper {
            if character == "-" || character.isWhitespace { continue }
            guard alphabet.contains(character) else {
                throw SyncError.invalidPassphrase("口令里有不属于字母表的字符")
            }
            out.append(character)
        }
        guard out.count == passphraseGroups * passphraseGroupLength else {
            throw SyncError.invalidPassphrase(
                "口令应为 \(passphraseGroups * passphraseGroupLength) 个字符（当前 \(out.count) 个）")
        }
        return out
    }

    // MARK: - 同步密钥

    public static func generateSyncKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// 密钥指纹：SHA-256 前 8 字节的十六进制。写进 manifest 与库里，用来发现"换了一套密钥"。
    /// 只有 64 bit 且是单向哈希，泄露它不会削弱密钥。
    public static func keyID(_ key: SymmetricKey) -> String {
        let digest = key.withUnsafeBytes { SHA256.hash(data: Data($0)) }
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 包裹 / 解包

    public struct Wrapped: Codable, Sendable, Equatable {
        public var format: Int
        public var device: String
        public var kdf: String
        public var iterations: Int
        public var salt: Data
        /// AES-GCM combined（nonce + 密文 + tag）。
        public var wrapped: Data
        public var keyID: String
        public var createdAt: Int64

        enum CodingKeys: String, CodingKey {
            case format, device, kdf, iterations, salt, wrapped
            case keyID = "key_id", createdAt = "created_at"
        }
    }

    public static func wrap(syncKey: SymmetricKey, passphrase: String, device: String) throws -> Wrapped {
        let normalized = try normalize(passphrase: passphrase)
        let salt = Data(try randomBytes(saltBytes))
        let wrappingKey = try derive(passphrase: normalized, salt: salt, iterations: kdfIterations)
        let raw = syncKey.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(raw, using: wrappingKey,
                                      authenticating: aad(device: device))
        guard let combined = sealed.combined else {
            throw SyncError.keyring("AES-GCM combined 表示不可用")
        }
        return Wrapped(format: 1, device: device, kdf: kdfAlgorithm, iterations: kdfIterations,
                       salt: salt, wrapped: combined, keyID: keyID(syncKey),
                       createdAt: Int64(Date().timeIntervalSince1970 * 1000))
    }

    /// 解包。口令错 → `.wrongPassphrase`（3.9「口令错误则不加入」）。
    public static func unwrap(_ item: Wrapped, passphrase: String) throws -> SymmetricKey {
        let normalized = try normalize(passphrase: passphrase)
        guard item.kdf == kdfAlgorithm else {
            throw SyncError.keyring("不认识的 KDF：\(item.kdf)")
        }
        let wrappingKey = try derive(passphrase: normalized, salt: item.salt,
                                     iterations: item.iterations)
        guard let box = try? AES.GCM.SealedBox(combined: item.wrapped),
              let raw = try? AES.GCM.open(box, using: wrappingKey,
                                          authenticating: aad(device: item.device)) else {
            throw SyncError.wrongPassphrase
        }
        let key = SymmetricKey(data: raw)
        guard keyID(key) == item.keyID else {
            throw SyncError.keyring("解出来的密钥指纹与文件里记的不符")
        }
        return key
    }

    private static func aad(device: String) -> Data {
        Data("brosis-sync/1|wrap|\(device)".utf8)
    }

    /// PBKDF2-HMAC-SHA256 → HKDF-SHA256。
    static func derive(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(passphrase.utf8)
        let status = salt.withUnsafeBytes { saltBuffer -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passphrase, passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived, derived.count)
        }
        guard status == kCCSuccess else {
            throw SyncError.keyring("PBKDF2 失败：status=\(status)")
        }
        defer { for index in derived.indices { derived[index] = 0 } }
        let prk = SymmetricKey(data: Data(derived))
        return HKDF<SHA256>.expand(pseudoRandomKey: prk,
                                   info: Data(hkdfInfo.utf8),
                                   outputByteCount: 32)
    }

    static func randomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw SyncError.keyring("SecRandomCopyBytes 失败：status=\(status)")
        }
        return bytes
    }
}

// MARK: - manifest.json

/// 3.9 的 `manifest.json`：格式版本、创建时间、加密参数，**不含密钥**。
public struct SyncManifest: Codable, Sendable, Equatable {
    public var format: String
    public var version: Int
    public var createdAt: Int64
    /// 建这个目录的设备 id（不是主机名）。
    public var createdBy: String
    public var aead: String
    public var kdf: String
    public var kdfIterations: Int
    public var saltBytes: Int
    public var segmentFormat: Int
    /// 同步密钥的指纹（单向哈希前 8 字节），用来核对"解出来的是不是这套目录的密钥"。
    public var keyID: String

    public static let formatName = "brosis-sync"
    public static let currentVersion = 1

    public init(createdBy: String, keyID: String, createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.format = Self.formatName
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.aead = "AES-256-GCM"
        self.kdf = SyncKeyring.kdfAlgorithm
        self.kdfIterations = SyncKeyring.kdfIterations
        self.saltBytes = SyncKeyring.saltBytes
        self.segmentFormat = Int(SyncSegmentFile.formatVersion)
        self.keyID = keyID
    }

    enum CodingKeys: String, CodingKey {
        case format, version, aead, kdf
        case createdAt = "created_at", createdBy = "created_by"
        case kdfIterations = "kdf_iterations", saltBytes = "salt_bytes"
        case segmentFormat = "segment_format", keyID = "key_id"
    }
}

/// `devices/<device_id>.json`：设备名与加入时间（3.9「注册本机」）。
public struct SyncDeviceRecord: Codable, Sendable, Equatable {
    public var device: String
    public var name: String?
    public var joinedAt: Int64
    public var updatedAt: Int64
    /// 最后出站的段序号（3.9 的表格里「设备名、加入时间、最后出站 seq」）。
    public var lastSeq: Int64

    public init(device: String, name: String?, joinedAt: Int64, updatedAt: Int64, lastSeq: Int64) {
        self.device = device
        self.name = name
        self.joinedAt = joinedAt
        self.updatedAt = updatedAt
        self.lastSeq = lastSeq
    }

    enum CodingKeys: String, CodingKey {
        case device, name
        case joinedAt = "joined_at", updatedAt = "updated_at", lastSeq = "last_seq"
    }
}

/// `acks/<device_id>.json`：本机已导入各设备到哪个 seq（3.9「清理」）。
public struct SyncAckRecord: Codable, Sendable, Equatable {
    public var device: String
    public var updatedAt: Int64
    /// 对端 device_id → 已导入到的 seq。
    public var imported: [String: Int64]

    public init(device: String, updatedAt: Int64, imported: [String: Int64]) {
        self.device = device
        self.updatedAt = updatedAt
        self.imported = imported
    }

    enum CodingKeys: String, CodingKey {
        case device, imported
        case updatedAt = "updated_at"
    }
}
