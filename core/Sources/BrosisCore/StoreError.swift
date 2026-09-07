import Foundation

/// BrosisCore 对外抛出的全部错误。
///
/// 特别注意 `wrongKeyOrCorrupt`：SQLCipher 在密钥错误、以及 `cipher_page_size` 没重设
/// 这两种完全不同的情况下都报 `SQLITE_NOTADB / file is not a database`
/// （E6 实测，见 tools/proto/results/sqlcipher_2026-09-07.md §7.1）。
/// 因为 `Store.open` 把 `PRAGMA cipher_page_size` 固定写在连接序言里，
/// 所以走到这一步时只剩"密钥不对"或"文件真的坏了"两种可能。
public enum StoreError: Error, CustomStringConvertible, Sendable {

    /// 目录被 D16 拒绝：数据库不允许放在 iCloud Drive 或其他文件同步目录 / 网络卷。
    case directoryRejected(path: String, reason: String)
    /// 目录 / 文件系统层面的失败（建目录、chmod、排除标记）。
    case filesystem(String)
    /// 密钥不是 32 字节，或提供方取不到密钥。
    case keyUnavailable(String)
    /// `PRAGMA key` + `cipher_page_size` 之后第一次真读失败。
    case wrongKeyOrCorrupt(code: Int32, message: String)
    /// 一般的 SQLite 失败。
    case sqlite(op: String, code: Int32, message: String)
    /// schema 版本不认识（比库新）。
    case schemaVersion(found: Int, expected: Int)
    /// 调用方用法错误（参数不合法、库已关闭等）。
    case invalidUsage(String)

    public var description: String {
        switch self {
        case .directoryRejected(let path, let reason):
            return "数据目录被拒绝（D16）：\(path)——\(reason)"
        case .filesystem(let m):
            return "文件系统操作失败：\(m)"
        case .keyUnavailable(let m):
            return "取不到可用的 256 位密钥：\(m)"
        case .wrongKeyOrCorrupt(let code, let message):
            return "密钥错误或数据库损坏：rc=\(code) \(message)"
        case .sqlite(let op, let code, let message):
            return "SQLite \(op) 失败：rc=\(code) \(message)"
        case .schemaVersion(let found, let expected):
            return "schema 版本不匹配：库里是 \(found)，本版本支持 \(expected)"
        case .invalidUsage(let m):
            return "用法错误：\(m)"
        }
    }
}
