import Foundation
import CBrosisSQLite
import SQLCipher

/// 一段可以显式清零的原始密钥（256 位 = 32 字节）。
///
/// 3.5 / E6 的两条要求：
///   1. 密钥字节用完必须 volatile 清零；
///   2. 拼出来的 `PRAGMA key = "x'…'"` SQL 缓冲区也要清零——否则十六进制形式的密钥
///      会留在堆上，清了密钥本身等于没清。
///
/// 不是 `Sendable`：一把密钥只在持有它的 `Store`（单连接、内部串行）里用。
public final class SecureKey {

    private var buffer: UnsafeMutablePointer<UInt8>
    public let count: Int
    private var isZeroed = false

    /// 用完立刻把入参 `Data` 清零（调用方仍应对自己的副本负责）。
    public init(_ bytes: Data) throws {
        guard bytes.count == 32 else {
            throw StoreError.keyUnavailable("密钥必须是 32 字节（256 位），实际 \(bytes.count) 字节")
        }
        count = bytes.count
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        bytes.withUnsafeBytes { raw in
            buffer.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: count)
        }
    }

    deinit {
        brosis_secure_zero(buffer, UInt(count))
        buffer.deallocate()
    }

    /// 拼 `PRAGMA key = "x'<64 hex>'";`，执行，然后把 SQL 缓冲区就地清零。
    func applyKey(to db: OpaquePointer) throws {
        guard !isZeroed else {
            throw StoreError.keyUnavailable("密钥已清零，不能再用于开库")
        }
        let prefix = Array("PRAGMA key = \"x'".utf8)
        let suffix = Array("'\";".utf8)
        let total = prefix.count + count * 2 + suffix.count + 1
        let sql = UnsafeMutablePointer<CChar>.allocate(capacity: total)
        defer {
            brosis_secure_zero(sql, UInt(total))
            sql.deallocate()
        }
        var i = 0
        for b in prefix { sql[i] = CChar(bitPattern: b); i += 1 }
        let hex: [UInt8] = Array("0123456789abcdef".utf8)
        for k in 0..<count {
            sql[i] = CChar(bitPattern: hex[Int(buffer[k] >> 4)]); i += 1
            sql[i] = CChar(bitPattern: hex[Int(buffer[k] & 0x0F)]); i += 1
        }
        for b in suffix { sql[i] = CChar(bitPattern: b); i += 1 }
        sql[i] = 0

        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        let message = err.map { String(cString: $0) } ?? ""
        if err != nil { sqlite3_free(err) }
        guard rc == SQLITE_OK else {
            throw StoreError.sqlite(op: "PRAGMA key", code: rc, message: message)
        }
    }

    /// 显式清零。`Store.close()` 会调用；`deinit` 也会兜底。
    public func zeroize() {
        brosis_secure_zero(buffer, UInt(count))
        isZeroed = true
    }

    /// 供测试与自检使用：确认缓冲区确实全 0（不暴露密钥本身）。
    public var isAllZero: Bool {
        for k in 0..<count where buffer[k] != 0 { return false }
        return true
    }

    /// 供测试使用：本对象是否已被显式清零。
    public var wasZeroized: Bool { isZeroed }
}

/// 把一段 `Data` 就地清零（`Data` 是值类型，调用方要传 `inout`）。
@inlinable
public func brosisZeroize(_ data: inout Data) {
    data.withUnsafeMutableBytes { raw in
        if let base = raw.baseAddress { brosis_secure_zero(base, UInt(raw.count)) }
    }
}
