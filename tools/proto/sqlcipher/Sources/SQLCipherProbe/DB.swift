// brosis M0 / T8（E6）：SQLite/SQLCipher 的最小封装 + 可清零的原始密钥。
import Foundation
import SQLCipher
import CBrosisShim

let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLError: Error, CustomStringConvertible {
    let op: String
    let code: Int32
    let message: String
    var description: String { "\(op) 失败：rc=\(code) \(message)" }
}

/// 256 位原始密钥。密钥字节和拼出来的 PRAGMA 语句都放在可显式清零的堆缓冲区里。
final class SecureKey {
    private var buf: UnsafeMutablePointer<UInt8>
    let count: Int
    private(set) var zeroed = false

    init(bytes: [UInt8]) {
        count = bytes.count
        buf = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        buf.update(from: bytes, count: count)
    }
    deinit { brosis_secure_zero(buf, UInt(count)); buf.deallocate() }

    /// 拼 `PRAGMA key = "x'<64 hex>'";`，执行，然后把 SQL 缓冲区就地清零。
    func applyKey(to db: OpaquePointer) throws {
        guard !zeroed else { throw SQLError(op: "PRAGMA key（密钥已清零）", code: -1, message: "key already zeroized") }
        let prefix = Array("PRAGMA key = \"x'".utf8)
        let suffix = Array("'\";".utf8)
        let total = prefix.count + count * 2 + suffix.count + 1
        let sql = UnsafeMutablePointer<CChar>.allocate(capacity: total)
        defer { brosis_secure_zero(sql, UInt(total)); sql.deallocate() }
        var i = 0
        for b in prefix { sql[i] = CChar(bitPattern: b); i += 1 }
        let hex: [UInt8] = Array("0123456789abcdef".utf8)
        for k in 0..<count {
            sql[i] = CChar(bitPattern: hex[Int(buf[k] >> 4)]); i += 1
            sql[i] = CChar(bitPattern: hex[Int(buf[k] & 0x0F)]); i += 1
        }
        for b in suffix { sql[i] = CChar(bitPattern: b); i += 1 }
        sql[i] = 0
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        let msg = err.map { String(cString: $0) } ?? ""
        if err != nil { sqlite3_free(err) }
        if rc != SQLITE_OK { throw SQLError(op: "PRAGMA key", code: rc, message: msg) }
    }

    func zeroize() { brosis_secure_zero(buf, UInt(count)); zeroed = true }

    /// 供报告使用：确认缓冲区确实全 0（不打印密钥本身）。
    var isAllZero: Bool {
        for k in 0..<count where buf[k] != 0 { return false }
        return true
    }
}

final class DB {
    var h: OpaquePointer?

    init(path: String, create: Bool = true) throws {
        var handle: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE
        if create { flags |= SQLITE_OPEN_CREATE }
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        if rc != SQLITE_OK {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "(no handle)"
            if handle != nil { sqlite3_close_v2(handle) }
            throw SQLError(op: "sqlite3_open_v2(\(path))", code: rc, message: msg)
        }
        h = handle
    }

    func close() {
        if let h { sqlite3_close_v2(h) }
        h = nil
    }

    var errmsg: String { h.map { String(cString: sqlite3_errmsg($0)) } ?? "" }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &err)
        let msg = err.map { String(cString: $0) } ?? errmsg
        if err != nil { sqlite3_free(err) }
        if rc != SQLITE_OK { throw SQLError(op: "exec(\(sql.prefix(80)))", code: rc, message: msg) }
    }

    /// 执行但不抛错，返回 (rc, message)。用于"错误密钥必须失败"这类期望失败的场景。
    func tryExec(_ sql: String) -> (Int32, String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(h, sql, nil, nil, &err)
        let msg = err.map { String(cString: $0) } ?? errmsg
        if err != nil { sqlite3_free(err) }
        return (rc, msg)
    }

    func scalarString(_ sql: String) throws -> String? {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(h, sql, -1, &st, nil)
        guard rc == SQLITE_OK else { throw SQLError(op: "prepare(\(sql))", code: rc, message: errmsg) }
        defer { sqlite3_finalize(st) }
        if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
            return String(cString: c)
        }
        return nil
    }

    func scalarInt(_ sql: String) throws -> Int64? {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(h, sql, -1, &st, nil)
        guard rc == SQLITE_OK else { throw SQLError(op: "prepare(\(sql))", code: rc, message: errmsg) }
        defer { sqlite3_finalize(st) }
        if sqlite3_step(st) == SQLITE_ROW { return sqlite3_column_int64(st, 0) }
        return nil
    }

    /// 跑一条查询，把所有行读干净，返回行数（用来测查询延迟，不关心内容）。
    func drain(_ st: OpaquePointer?) throws -> Int {
        var n = 0
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { n += 1; continue }
            if rc == SQLITE_DONE { break }
            throw SQLError(op: "step", code: rc, message: errmsg)
        }
        return n
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(h, sql, -1, &st, nil)
        guard rc == SQLITE_OK, let st else {
            throw SQLError(op: "prepare(\(sql.prefix(120)))", code: rc, message: errmsg)
        }
        return st
    }

    func stringRows(_ sql: String, columns: Int) throws -> [[String]] {
        let st = try prepare(sql)
        defer { sqlite3_finalize(st) }
        var out: [[String]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            var row: [String] = []
            for c in 0..<columns {
                if let t = sqlite3_column_text(st, Int32(c)) { row.append(String(cString: t)) }
                else { row.append("") }
            }
            out.append(row)
        }
        return out
    }
}
