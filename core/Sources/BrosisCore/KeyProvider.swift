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
/// **本任务（M1 / T2）没有实跑它**：读写 data-protection 钥匙串需要签名 + entitlement，
/// 首次访问会弹钥匙串授权对话框，而本轮的硬约束是不触发任何 GUI / 授权弹窗。
/// 这里只保证编译通过与接口正确，**实跑留给 T4 在 GUI 里验证**（见 core/README.md「已知限制」）。
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

    public func fetchKey() throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data, data.count == 32 else {
                throw StoreError.keyUnavailable("钥匙串条目不是 32 字节原始密钥")
            }
            return data
        }
        guard status == errSecItemNotFound else {
            throw StoreError.keyUnavailable("SecItemCopyMatching 失败：OSStatus \(status)")
        }
        guard createIfMissing else {
            throw StoreError.keyUnavailable("钥匙串里没有 \(service)/\(account)，且未允许生成")
        }

        var key = try KeyBytes.random()
        defer { brosisZeroize(&key) }

        // ACL：限本应用（同一签名身份），解锁后可读，不跨设备。
        var aclError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            SecAccessControlCreateFlags(),   // 不要求用户在场（D4：v1 不要求 Touch ID）
            &aclError
        ) else {
            let message = aclError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw StoreError.keyUnavailable("SecAccessControlCreateWithFlags 失败：\(message)")
        }

        query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessControl as String: access,
            kSecValueData as String: key,
        ]
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StoreError.keyUnavailable("SecItemAdd 失败：OSStatus \(addStatus)")
        }
        return key
    }

    /// 删除条目（换库、重置用）。本任务同样未实跑。
    public func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keyUnavailable("SecItemDelete 失败：OSStatus \(status)")
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
