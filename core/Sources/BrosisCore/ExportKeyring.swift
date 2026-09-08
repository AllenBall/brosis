import CommonCrypto
import CryptoKit
import Foundation

// =============================================================================
// 3.8「加密导出另有独立口令」的密钥层。
//
// -------------------------------------------------------------------------
// 四把互不相干的东西（前三把是 3.9 已经定好的，这里加第四把）
// -------------------------------------------------------------------------
//   1. **库密钥**（256 位随机）——SQLCipher 开库用，存 data-protection 钥匙串，从不出本机。
//   2. **同步密钥**（256 位随机）——只封段文件，静态存在加密库里（`sync_state`）。
//   3. **配对口令**——新设备加入同步目录时用一次，解开 `keyring/*.wrapped`。
//   4. **导出口令**（本文件）——**只在导出 / 导入那一刻存在于内存里**，哪里都不存：
//      不进钥匙串、不进库、不进 manifest、不进日志、不进事件、不走命令行参数。
//      归档密钥完全由它派生，与前三把**没有任何共同的输入**——
//      拿到库密钥解不开归档，拿到归档口令也读不了库。
//      代价写在明处：**口令丢了，归档就永远打不开**，没有找回通道。
//
// -------------------------------------------------------------------------
// 派生链
// -------------------------------------------------------------------------
//   PBKDF2-HMAC-SHA256(口令 UTF-8, 盐 16 字节随机, 600,000 次) → 32 字节 PRK
//     ├─ HKDF-SHA256(PRK, info "brosis-export/1 data")     → 归档数据密钥（封每一块）
//     ├─ HKDF-SHA256(PRK, info "brosis-export/1 manifest") → manifest 的 HMAC 密钥
//     └─ HKDF-SHA256(PRK, info "brosis-export/1 verify")   → 校验值，manifest 里只存它的 SHA-256
//
// 迭代数 600,000 沿用 3.9 的取值（OWASP 2023 对 PBKDF2-HMAC-SHA256 的建议）；
// 不用 Argon2id 的理由也一样：本轮不引第三方依赖，系统里只有 CommonCrypto 的 PBKDF2。
// HKDF 那一步是**域分离**：三把子密钥各管一件事，泄露其一不削弱另外两把。
//
// manifest 里存 `verifier`（校验密钥的 SHA-256）是为了让"口令错"能在**碰任何一块之前**
// 被判出来，于是错误消息可以明确说"口令错误"，而不是含糊的"解密失败"，
// 也不会因为试解一块而泄漏任何密文以外的信息。
// 它确实让离线猜口令有了一个快速判据——但归档密文本身（GCM tag）本来就是同样的判据，
// 真正的防线是 600,000 次 PBKDF2 与口令强度，不是"藏起判据"。
// =============================================================================

public enum ExportKeyring {

    public static let kdfAlgorithm = "PBKDF2-HMAC-SHA256"
    public static let kdfIterations = 600_000
    public static let saltBytes = 16
    public static let aeadName = "AES-256-GCM"

    static let dataInfo = "brosis-export/1 data"
    static let manifestInfo = "brosis-export/1 manifest"
    static let verifyInfo = "brosis-export/1 verify"

    // MARK: - 口令强度（3.8「口令强度最低要求写明」）

    /// 最短长度（Unicode 字符数，不是字节数）。
    public static let minimumLength = 12
    /// 至少要覆盖几类字符（小写 / 大写 / 数字 / 其他）。
    public static let minimumClasses = 2
    /// 上限：挡住"整个文件被当成口令喂进来"这类误用。
    public static let maximumLength = 1_024

    /// 人读的要求，UI 直接显示这一行。
    public static let requirementText =
        "至少 \(minimumLength) 个字符，且至少包含两类字符（小写字母 / 大写字母 / 数字 / 符号）；"
        + "不能是同一个字符重复。这个口令与登录密码、库密钥、同步配对口令都无关，"
        + "**丢了就再也打不开这份归档**。"

    public struct Strength: Sendable, Equatable {
        public var length: Int
        public var classes: Int
        public var ok: Bool
        public var reason: String?
    }

    /// 只判定不抛错（UI 边输边提示用）。
    public static func strength(of passphrase: String) -> Strength {
        let length = passphrase.count
        var lower = false, upper = false, digit = false, other = false
        for character in passphrase {
            if character.isLowercase { lower = true }
            else if character.isUppercase { upper = true }
            else if character.isNumber { digit = true }
            else { other = true }
        }
        let classes = [lower, upper, digit, other].filter { $0 }.count
        var reason: String?
        if length == 0 {
            reason = "口令是空的"
        } else if length < minimumLength {
            reason = "只有 \(length) 个字符，至少要 \(minimumLength) 个"
        } else if length > maximumLength {
            reason = "超过 \(maximumLength) 个字符"
        } else if Set(passphrase).count == 1 {
            reason = "整条口令是同一个字符重复"
        } else if classes < minimumClasses {
            reason = "只用了 \(classes) 类字符，至少要 \(minimumClasses) 类"
                   + "（小写字母 / 大写字母 / 数字 / 符号）"
        }
        return Strength(length: length, classes: classes, ok: reason == nil, reason: reason)
    }

    /// 导出时用：不合格直接抛，**不派生任何密钥**（省掉 60 万次 PBKDF2）。
    public static func requireStrong(_ passphrase: String) throws {
        let s = strength(of: passphrase)
        guard s.ok else { throw ExportError.weakPassphrase(s.reason ?? "不合要求") }
    }

    // MARK: - 派生

    /// 一份归档的三把子密钥。
    public struct ArchiveKeys: Sendable {
        public var data: SymmetricKey
        public var manifestMAC: SymmetricKey
        /// 校验值（十六进制），与 manifest 里的 `verifier` 比对。
        public var verifier: String
    }

    /// 口令 + 盐 → 三把子密钥。
    ///
    /// **导入端不检查口令强度**：老归档可能是用更早的规则做的，强度是导出时的门槛，
    /// 不是解密的门槛。只有空口令直接拒绝（那必然是调用方漏传了）。
    public static func derive(passphrase: String, salt: Data,
                              iterations: Int = kdfIterations) throws -> ArchiveKeys {
        guard !passphrase.isEmpty else { throw ExportError.weakPassphrase("口令是空的") }
        guard salt.count >= 8 else { throw ExportError.manifestUnreadable("盐太短（\(salt.count) 字节）") }
        guard iterations >= 1_000 else {
            throw ExportError.manifestUnreadable("KDF 迭代数太小（\(iterations)）")
        }
        var derived = [UInt8](repeating: 0, count: 32)
        defer { for index in derived.indices { derived[index] = 0 } }
        let passwordBytes = Array(passphrase.utf8)
        // 与 SyncKeyring.derive 同一种写法：String 桥接成 NUL 结尾的 C 串，
        // 长度显式给 UTF-8 字节数（不含 NUL）。
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
            throw ExportError.filesystem("PBKDF2 失败：status=\(status)")
        }
        let prk = SymmetricKey(data: Data(derived))
        func expand(_ info: String) -> SymmetricKey {
            HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data(info.utf8), outputByteCount: 32)
        }
        let verifyKey = expand(verifyInfo)
        let verifier = verifyKey.withUnsafeBytes { hex(SHA256.hash(data: Data($0))) }
        return ArchiveKeys(data: expand(dataInfo), manifestMAC: expand(manifestInfo),
                           verifier: verifier)
    }

    /// 随机盐 / 归档 id。
    public static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw ExportError.filesystem("SecRandomCopyBytes 失败：status=\(status)")
        }
        return Data(bytes)
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// manifest 的 HMAC：把 `mac` 字段置空后按 `sortedKeys` 编码，对那串字节算 HMAC-SHA256。
    /// 于是校验时只要把读到的 manifest 的 `mac` 清掉、重编码、重算，就能逐字节复现。
    static func manifestMAC(_ manifest: ExportManifest, key: SymmetricKey) throws -> String {
        var skeleton = manifest
        skeleton.mac = ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(skeleton)
        return hex(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }
}
