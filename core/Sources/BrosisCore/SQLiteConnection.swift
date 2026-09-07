import Foundation
import SQLCipher
import CBrosisSQLite

/// 裸 C API 的薄封装（D25：M1 不上 GRDB，先写约 150 行封装，超过 500 行再评估）。
///
/// 只做四件事：开 / 关、exec、prepare + 绑定 + 取列、事务。不做映射、不做观察、不做查询构造。
final class SQLiteConnection {

    private(set) var handle: OpaquePointer?

    var errorMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "(no handle)" }

    init(path: String, createIfMissing: Bool) throws {
        var h: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if createIfMissing { flags |= SQLITE_OPEN_CREATE }
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let message = h.map { String(cString: sqlite3_errmsg($0)) } ?? "(no handle)"
            if h != nil { sqlite3_close_v2(h) }
            throw StoreError.sqlite(op: "sqlite3_open_v2", code: rc, message: message)
        }
        handle = h
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    // MARK: - exec

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        let message = err.map { String(cString: $0) } ?? errorMessage
        if err != nil { sqlite3_free(err) }
        guard rc == SQLITE_OK else {
            throw StoreError.sqlite(op: "exec(\(sql.prefix(100)))", code: rc, message: message)
        }
    }

    /// 执行但不抛错，用于"期望失败"的场景（错密钥）与探测性 PRAGMA。
    @discardableResult
    func tryExec(_ sql: String) -> (rc: Int32, message: String) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        let message = err.map { String(cString: $0) } ?? errorMessage
        if err != nil { sqlite3_free(err) }
        return (rc, message)
    }

    // MARK: - 语句

    func prepare(_ sql: String) throws -> Statement {
        var st: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &st, nil)
        guard rc == SQLITE_OK, let st else {
            throw StoreError.sqlite(op: "prepare(\(sql.prefix(160)))", code: rc, message: errorMessage)
        }
        return Statement(st, connection: self)
    }

    // MARK: - 便捷查询

    func scalarInt(_ sql: String, _ binds: [SQLValue] = []) throws -> Int64? {
        let st = try prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        return try st.step() ? st.int(0) : nil
    }

    func scalarText(_ sql: String, _ binds: [SQLValue] = []) throws -> String? {
        let st = try prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        return try st.step() ? st.text(0) : nil
    }

    func intColumn(_ sql: String, _ binds: [SQLValue] = []) throws -> [Int64] {
        let st = try prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        var out: [Int64] = []
        while try st.step() { out.append(st.int(0) ?? 0) }
        return out
    }

    /// 取前两列整数（检索层要 `(observation_id, ts)` 这种成对结果）。
    func intPairs(_ sql: String, _ binds: [SQLValue] = []) throws -> [(Int64, Int64)] {
        let st = try prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        var out: [(Int64, Int64)] = []
        while try st.step() { out.append((st.int(0) ?? 0, st.int(1) ?? 0)) }
        return out
    }

    func textColumn(_ sql: String, _ binds: [SQLValue] = []) throws -> [String] {
        let st = try prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        var out: [String] = []
        while try st.step() { out.append(st.text(0) ?? "") }
        return out
    }

    @discardableResult
    func run(_ sql: String, _ binds: [SQLValue] = []) throws -> Int {
        let st = try prepare(sql)
        defer { st.finalize() }
        try st.bind(binds)
        while try st.step() {}
        return Int(sqlite3_changes(handle))
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    // MARK: - 事务

    func begin() throws { try exec("BEGIN IMMEDIATE;") }
    func commit() throws { try exec("COMMIT;") }
    func rollback() { _ = tryExec("ROLLBACK;") }

    /// 出错自动回滚。
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try begin()
        do {
            let value = try body()
            try commit()
            return value
        } catch {
            rollback()
            throw error
        }
    }
}

// MARK: - 绑定值

enum SQLValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func int(_ v: Int) -> SQLValue { .int(Int64(v)) }
    static func optionalInt(_ v: Int64?) -> SQLValue { v.map { .int($0) } ?? .null }
    static func optionalText(_ v: String?) -> SQLValue { v.map { .text($0) } ?? .null }
}

// MARK: - Statement

final class Statement {
    private let st: OpaquePointer
    private unowned let connection: SQLiteConnection
    private var finalized = false

    init(_ st: OpaquePointer, connection: SQLiteConnection) {
        self.st = st
        self.connection = connection
    }

    deinit { if !finalized { sqlite3_finalize(st) } }

    func finalize() {
        if !finalized { sqlite3_finalize(st); finalized = true }
    }

    func bind(_ values: [SQLValue]) throws {
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(st, idx)
            case .int(let v):
                rc = sqlite3_bind_int64(st, idx, v)
            case .double(let v):
                rc = sqlite3_bind_double(st, idx, v)
            case .text(let v):
                rc = sqlite3_bind_text(st, idx, v, -1, brosis_transient())
            case .blob(let v):
                rc = v.withUnsafeBytes { raw in
                    sqlite3_bind_blob(st, idx, raw.baseAddress, Int32(raw.count), brosis_transient())
                }
            }
            guard rc == SQLITE_OK else {
                throw StoreError.sqlite(op: "bind(\(idx))", code: rc, message: connection.errorMessage)
            }
        }
    }

    /// 返回 true 表示有一行；false 表示 DONE。
    func step() throws -> Bool {
        let rc = sqlite3_step(st)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw StoreError.sqlite(op: "step", code: rc, message: connection.errorMessage)
    }

    func reset() { sqlite3_reset(st); sqlite3_clear_bindings(st) }

    func isNull(_ c: Int32) -> Bool { sqlite3_column_type(st, c) == SQLITE_NULL }

    func int(_ c: Int32) -> Int64? { isNull(c) ? nil : sqlite3_column_int64(st, c) }
    func double(_ c: Int32) -> Double? { isNull(c) ? nil : sqlite3_column_double(st, c) }
    func text(_ c: Int32) -> String? {
        guard let p = sqlite3_column_text(st, c) else { return nil }
        return String(cString: p)
    }
    func blob(_ c: Int32) -> Data? {
        guard let p = sqlite3_column_blob(st, c) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(st, c)))
    }
}
