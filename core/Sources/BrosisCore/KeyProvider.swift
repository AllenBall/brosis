import Foundation
import Security

/// 提供 256 位（32 字节）原始密钥。
///
/// 3.5 / D25：v1 用原始密钥而不是口令派生——E6 实测原始密钥开库 0.53 ms，
/// 口令派生（kdf_iter = 256000）要 78 ms，差两个数量级，锁定状态机才跑得动。
///
/// **约定：`fetchKey()` 返回的 `Data` 归调用方所有，用完必须清零**
/// （`BrosisCore` 内部由 `Store.open` 负责：拷进 `SecureKey` 后立刻 `brosisZeroize`）。
public protocol KeyProvider: Sendable {
    /// 取密钥；不存在时按实现的语义决定是生成还是报错。
    func fetchKey() throws -> Data
}

// MARK: - InMemoryKeyProvider（测试用）

/// 密钥常驻内存，**只用于测试**：进程内谁都能读到，没有任何保护。
public struct InMemoryKeyProvider: KeyProvider {
    private let key: Data

    public init(key: Data) throws {
        guard key.count == 32 else {
            throw StoreError.keyUnavailable("InMemoryKeyProvider 需要 32 字节密钥，实际 \(key.count)")
        }
        self.key = key
    }

    /// 随机生成一把（`SecRandomCopyBytes`）。
    public static func random() throws -> InMemoryKeyProvider {
        try InMemoryKeyProvider(key: KeyBytes.random())
    }

    /// 确定性密钥，只给需要复现的测试用（例如"错密钥必须失败"要两把可控的密钥）。
    public static func deterministic(seed: UInt8) throws -> InMemoryKeyProvider {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { bytes[i] = seed &+ UInt8(truncatingIfNeeded: i) }
        return try InMemoryKeyProvider(key: Data(bytes))
    }

    public func fetchKey() throws -> Data { key }
}

// MARK: - FileKeyProvider（CLI 测试用）

/// 把 32 字节原始密钥放在一个 0600 的文件里。
///
/// **不用于产品。** 产品路径是 `KeychainKeyProvider`。
/// 这个实现只是为了让 `brosis-store` 命令行工具与 `swift test` 能在不弹钥匙串授权的前提下
/// 反复开关同一个库（本任务的硬约束之一是不触发 TCC / 钥匙串弹窗）。
/// 风险如实写在这里：任何拿到同用户权限的进程都能直接读走这个文件。
public struct FileKeyProvider: KeyProvider {
    public let url: URL
    /// 文件不存在时是否用 `SecRandomCopyBytes` 生成一把并写入（0600）。
    public let createIfMissing: Bool

    public init(url: URL, createIfMissing: Bool = true) {
        self.url = url
        self.createIfMissing = createIfMissing
    }

    public func fetchKey() throws -> Data {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count == 32 else {
                throw StoreError.keyUnavailable("密钥文件 \(url.lastPathComponent) 是 \(data.count) 字节，应为 32")
            }
            // 权限自查：不是 0600 就拒绝，免得测试环境里悄悄放宽。
            if let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber,
               mode.uint16Value & 0o077 != 0 {
                throw StoreError.keyUnavailable(
                    "密钥文件权限是 \(String(mode.uint16Value, radix: 8))，必须是 600")
            }
            return data
        }
        guard createIfMissing else {
            throw StoreError.keyUnavailable("密钥文件不存在：\(url.lastPathComponent)")
        }
        var key = try KeyBytes.random()
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 先建 0600 空文件再写，避免 umask 让它短暂可读。
        guard fm.createFile(atPath: url.path, contents: nil,
                            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
            throw StoreError.filesystem("无法创建密钥文件 \(url.lastPathComponent)")
        }
        try key.write(to: url, options: [.atomic])
        // .atomic 会换 inode，权限要再设一次。
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        let out = key
        brosisZeroize(&key)
        return out
    }
}

// MARK: - KeychainKeyProvider（产品路径）

/// data-protection 钥匙串里的 256 位密钥（3.5 / D25 的产品实现）。
///
/// - `kSecUseDataProtectionKeychain = true`：走 data-protection 钥匙串而不是老的 file-based 钥匙串。
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`：解锁后可读、不进任何备份、不跨设备同步。
/// - ACL（`SecAccessControlCreateWithFlags`）：条目绑到本应用的签名身份，别的进程读不到。
/// - 首次生成用 `SecRandomCopyBytes`。
///
/// 2026-09-07 公司机实跑结论：Developer ID + hardened runtime 但没有 application-identifier /
/// keychain-access-groups 权利（需要内嵌 Developer ID 描述文件）的 app，data-protection 钥匙串
/// 直接返回 errSecMissingEntitlement (-34018)。因此本实现按「data-protection 优先，被拒回退登录钥匙串」
/// 工作；要真正用上 data-protection 钥匙串，需要在 developer.apple.com 建 Developer ID 描述文件并把
/// 两个权利签进 app（归 M1 第二轮的分发管线）。
public struct KeychainKeyProvider: KeyProvider {
    public let service: String
    public let account: String
    /// 条目不存在时是否生成并写入。
    public let createIfMissing: Bool

    public init(service: String = "com.brosis.store",
                account: String = "primary-db-key",
                createIfMissing: Bool = true) {
        self.service = service
        self.account = account
        self.createIfMissing = createIfMissing
    }

    /// `errSecMissingEntitlement`：data-protection 钥匙串在 macOS 上要求 app 带
    /// application-identifier / keychain-access-groups 权利并内嵌 Developer ID 描述文件。
    /// 2026-09-07 公司机实跑：只有 Developer ID 签名 + hardened runtime 的 brosis.app 调 SecItemAdd
    /// 直接返回 -34018。所以这里先试 data-protection，被拒就回退到传统登录钥匙串（见下）。
    static let missingEntitlement: OSStatus = -34018

    public enum Backend: String, Sendable { case dataProtection = "data-protection", legacy = "login-keychain" }

    /// 取密钥；`backend` 回传实际用的是哪条钥匙串。
    public func fetchKey(backend: UnsafeMutablePointer<Backend>? = nil) throws -> Data {
        // 1. data-protection 钥匙串：读
        switch try read(dataProtection: true) {
        case .found(let data):
            backend?.pointee = .dataProtection
            return data
        case .missingEntitlement:
            break                                   // 这条路走不通，整体回退
        case .notFound:
            // 1b. 迁移：之前的构建没有 data-protection 权利时，密钥落在了登录钥匙串。
            //     现在权利有了，就把那把密钥搬进 data-protection（不能换新密钥，否则已有库打不开）。
            if case .found(let legacy) = try read(dataProtection: false) {
                switch try create(dataProtection: true, existing: legacy) {
                case .created(let data):
                    try? deleteLegacyOnly()
                    backend?.pointee = .dataProtection
                    return data
                case .missingEntitlement:
                    backend?.pointee = .legacy
                    return legacy
                }
            }
            // 2. data-protection：生成并写入；被 -34018 拒绝也回退
            guard createIfMissing else {
                throw StoreError.keyUnavailable("钥匙串里没有 \(service)/\(account)，且未允许生成")
            }
            switch try create(dataProtection: true) {
            case .created(let data):
                backend?.pointee = .dataProtection
                return data
            case .missingEntitlement:
                break
            }
        }

        // 3. 传统登录钥匙串（file-based）：本机、不进 iCloud 钥匙串同步（kSecAttrSynchronizable 默认 false），
        //    默认 ACL 只信任创建它的这个签名身份；换签名身份后系统会弹一次授权框，这是预期。
        //    代价：没有 kSecAttrAccessible 语义（登录钥匙串随登录解锁），与 3.5「随登录会话可用」一致。
        switch try read(dataProtection: false) {
        case .found(let data):
            backend?.pointee = .legacy
            return data
        case .missingEntitlement:
            throw StoreError.keyUnavailable("登录钥匙串也返回 errSecMissingEntitlement，无法取钥")
        case .notFound:
            guard createIfMissing else {
                throw StoreError.keyUnavailable("钥匙串里没有 \(service)/\(account)，且未允许生成")
            }
            switch try create(dataProtection: false) {
            case .created(let data):
                backend?.pointee = .legacy
                return data
            case .missingEntitlement:
                throw StoreError.keyUnavailable("登录钥匙串 SecItemAdd 返回 errSecMissingEntitlement，无法取钥")
            }
        }
    }

    private enum ReadResult { case found(Data), notFound, missingEntitlement }
    private enum CreateResult { case created(Data), missingEntitlement }

    private func baseQuery(dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    private func read(dataProtection: Bool) throws -> ReadResult {
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else {
                throw StoreError.keyUnavailable("钥匙串条目不是 32 字节原始密钥")
            }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        case Self.missingEntitlement:
            return .missingEntitlement
        default:
            throw StoreError.keyUnavailable("SecItemCopyMatching 失败：OSStatus \(status)（\(dataProtection ? "data-protection" : "login-keychain")）")
        }
    }

    private func deleteLegacyOnly() throws {
        let status = SecItemDelete(baseQuery(dataProtection: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keyUnavailable("删除登录钥匙串旧条目失败：OSStatus \(status)")
        }
    }

    /// `existing` 非空时写入这把已有密钥（迁移），否则生成新的。
    private func create(dataProtection: Bool, existing: Data? = nil) throws -> CreateResult {
        var key = try existing ?? KeyBytes.random()
        defer { brosisZeroize(&key) }
        var query = baseQuery(dataProtection: dataProtection)
        query[kSecValueData as String] = key
        if dataProtection {
            // ACL：限本应用（同一签名身份），解锁后可读，不跨设备。只有 data-protection 钥匙串认这个属性。
            var aclError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                SecAccessControlCreateFlags(),   // 不要求用户在场（D4：v1 不要求 Touch ID）
                &aclError
            ) else {
                let message = aclError?.takeRetainedValue().localizedDescription ?? "unknown"
                throw StoreError.keyUnavailable("SecAccessControlCreateWithFlags 失败：\(message)")
            }
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrLabel as String] = "brosis 数据库主密钥"
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return .created(key)
        case Self.missingEntitlement:
            return .missingEntitlement
        default:
            throw StoreError.keyUnavailable("SecItemAdd 失败：OSStatus \(status)（\(dataProtection ? "data-protection" : "login-keychain")）")
        }
    }

    /// KeyProvider 协议要求的无参版本。
    public func fetchKey() throws -> Data { try fetchKey(backend: nil) }

    /// 删除条目（换库、重置用）：两条钥匙串都删。
    public func deleteKey() throws {
        for dp in [true, false] {
            let status = SecItemDelete(baseQuery(dataProtection: dp) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound || status == Self.missingEntitlement else {
                throw StoreError.keyUnavailable("SecItemDelete 失败：OSStatus \(status)")
            }
        }
    }
}

// MARK: - 随机字节

public enum KeyBytes {
    /// 32 字节 CSPRNG（`SecRandomCopyBytes`）。
    public static func random() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let rc = bytes.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, 32, raw.baseAddress!)
        }
        guard rc == errSecSuccess else {
            throw StoreError.keyUnavailable("SecRandomCopyBytes 失败：OSStatus \(rc)")
        }
        return Data(bytes)
    }
}
