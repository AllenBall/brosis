// brosis M0 / T8（E6）：SQLCipher 构建与密钥 / 数据边界验证。
// 对应 docs/实施计划.md 的 4.1 E6、3.2、3.4、3.5、D22、D23，以及 docs/调研方案评审.md 的 F1。
import Foundation
import CryptoKit
import SQLCipher
import CBrosisShim

struct Doc {
    let text: String
    let bigram: String
    let sha: [UInt8]
    let vec: [Int8]
    let byteLen: Int
}

struct Opts {
    var rows = 20_000
    var route = "a"
    var workDir = NSHomeDirectory() + "/Library/Caches/brosis-build/sqlcipher/run"
    var outPath = ""
    var seed: UInt64 = 20_260_907
    var queryReps = 100
    var openReps = 20
    var memorySecurity = false
}

enum Probe {

    /// D23 定的页大小。SQLCipher 的坑：非默认的 cipher_page_size 不写进文件头，
    /// **每一条新连接**都必须在 PRAGMA key 之后、第一次读之前再设一遍，否则报 "file is not a database"。
    static let cipherPageSize = 16_384

    /// 3.5 的 unlocking 状态：取钥 -> 开库 -> 设页大小 -> 读一次真数据完成校验。
    /// 返回 (连接, 解锁耗时 ms, 密钥缓冲区是否已清零)。
    static func openUnlocked(path: String, key: [UInt8]?, create: Bool) throws -> (DB, Double, Bool) {
        let db = try DB(path: path, create: create)
        guard let key else { return (db, 0, true) }
        let sk = SecureKey(bytes: key)
        let t0 = nowNs()
        do {
            try sk.applyKey(to: db.h!)
            try db.exec("PRAGMA cipher_page_size = \(cipherPageSize);")
            _ = try db.scalarInt("SELECT count(*) FROM sqlite_schema;")
        } catch {
            sk.zeroize(); db.close(); throw error
        }
        let ms = msSince(t0)
        sk.zeroize()
        return (db, ms, sk.isAllZero)
    }

    // ------------------------------------------------------------ 入口

    static func main() throws {
        var o = Opts()
        o.route = (ProcessInfo.processInfo.environment["BROSIS_SQLCIPHER_ROUTE"] ?? "a").lowercased()
        var args = Array(CommandLine.arguments.dropFirst())
        while let a = args.first {
            args.removeFirst()
            switch a {
            case "--rows":    o.rows = Int(args.removeFirst())!
            case "--work":    o.workDir = args.removeFirst()
            case "--out":     o.outPath = args.removeFirst()
            case "--seed":    o.seed = UInt64(args.removeFirst())!
            case "--reps":    o.queryReps = Int(args.removeFirst())!
            case "--opens":   o.openReps = Int(args.removeFirst())!
            case "--route":   o.route = args.removeFirst()
            case "--memsec":  o.memorySecurity = true
            default: FileHandle.standardError.write("未知参数 \(a)\n".data(using: .utf8)!); exit(2)
            }
        }
        if o.outPath.isEmpty { o.outPath = o.workDir + "/probe_route_\(o.route).json" }

        let fm = FileManager.default
        let tmpDir = o.workDir + "/sqlite-tmp"
        try? fm.removeItem(atPath: tmpDir)
        try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: o.workDir, withIntermediateDirectories: true)
        // SQLite 找临时文件目录的顺序：SQLITE_TMPDIR -> TMPDIR -> /var/tmp -> /usr/tmp -> /tmp
        setenv("SQLITE_TMPDIR", tmpDir, 1)
        setenv("TMPDIR", tmpDir + "/", 1)

        // 统计型 VFS + 明文金丝雀 + sqlite-vec 自动扩展，都必须在第一次 open 之前装好
        let rcVfs = brosis_shim_register()
        for (_, bytes) in Corpus.needles {
            _ = bytes.withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) {
                    brosis_shim_add_marker($0, Int32(p.count))
                }
            }
        }
        let rcVec = brosis_register_vec()

        var out: [String: Any] = [
            "task": "T8 / E6 SQLCipher 构建与密钥、数据边界验证",
            "date": ISO8601DateFormatter().string(from: Date()),
            "route": o.route,
            "rows": o.rows,
            "seed": String(o.seed),
            "vfs_shim_rc": Int(rcVfs),
            "vec_auto_extension_rc": Int(rcVec),
            "work_dir": o.workDir,
            "sqlite_tmpdir": tmpDir,
            "memory_security_requested": o.memorySecurity,
        ]

        out["build"] = try buildInfo(memorySecurity: o.memorySecurity)

        // ---- 语料只生成一次，加密库和明文库用同一批数据，耗时差才只反映加解密 ----
        let (docs, corpusMs) = timedMs { makeCorpus(rows: o.rows, seed: o.seed) }
        let plainBytes = docs.reduce(0) { $0 + $1.byteLen }
        out["corpus"] = [
            "docs": docs.count,
            "gen_ms": r(corpusMs),
            "plaintext_bytes": plainBytes,
            "plaintext_MiB": r(Double(plainBytes) / 1_048_576.0, 2),
            "avg_doc_bytes": plainBytes / max(1, docs.count),
            "avg_bigram_bytes": docs.reduce(0) { $0 + $1.bigram.utf8.count } / max(1, docs.count),
        ]

        // ---- 主实验：加密库 ----
        let key = keyMaterial()
        out["encrypted"] = try buildDatabase(path: o.workDir + "/enc.db", key: key, docs: docs, opts: o)
        // ---- 对照：同 schema 明文库 ----
        out["plaintext"] = try buildDatabase(path: o.workDir + "/plain.db", key: nil, docs: docs, opts: o)
        // ---- 锁定状态机 ----
        out["lock_cycle"] = try lockCycle(path: o.workDir + "/enc.db", opts: o)
        // ---- 错误密钥（放在锁定状态机之后：顺带验证失败的解锁尝试不会破坏库）----
        out["wrong_key"] = wrongKeyChecks(path: o.workDir + "/enc.db", correct: key)
        // ---- 口令密钥的开库延迟（对照，证明原始密钥确实跳过了 PBKDF2）----
        out["passphrase_open"] = try passphraseOpen(path: o.workDir + "/pass.db", opts: o)
        // ---- 临时目录残留 ----
        out["tmpdir_after_all"] = scanDirectory(tmpDir)

        // ---- 加密开销汇总 ----
        if let e = out["encrypted"] as? [String: Any], let p = out["plaintext"] as? [String: Any] {
            out["overhead"] = overhead(enc: e, plain: p)
        }

        let text = jsonString(out)
        try text.write(toFile: o.outPath, atomically: true, encoding: .utf8)
        print("写出 \(o.outPath)")
    }

    // ------------------------------------------------------------ 构建信息

    static func buildInfo(memorySecurity: Bool) throws -> [String: Any] {
        var info: [String: Any] = [
            "sqlite_libversion": String(cString: sqlite3_libversion()),
            "sqlite_version_number": Int(sqlite3_libversion_number()),
            "sqlite_sourceid": String(cString: sqlite3_sourceid()),
        ]
        let db = try DB(path: ":memory:")
        defer { db.close() }
        if memorySecurity {
            // 必须在分配任何加密上下文之前设置
            info["cipher_memory_security_set_rc"] = Int(db.tryExec("PRAGMA cipher_memory_security = ON;").0)
        }
        // 不设密钥时 cipher_provider / kdf_iter 等大多返回空，所以先给内存库上一把钥匙
        let sk = SecureKey(bytes: keyMaterial())
        try? sk.applyKey(to: db.h!)
        try? db.exec("CREATE TABLE probe(x);")
        sk.zeroize()
        for p in ["cipher_version", "cipher_provider", "cipher_provider_version",
                  "cipher_page_size", "cipher_default_page_size", "kdf_iter", "cipher_default_kdf_iter",
                  "cipher_hmac_algorithm", "cipher_kdf_algorithm", "cipher_memory_security",
                  "cipher_default_use_hmac", "cipher_compatibility"] {
            info[p] = (try? db.scalarString("PRAGMA \(p);")) ?? nil ?? "(空)"
        }
        info["cipher_settings"] = (try? db.stringRows("PRAGMA cipher_settings;", columns: 1))?.map { $0[0] } ?? []
        info["vec_version"] = (try? db.scalarString("SELECT vec_version();")) ?? "(不可用)"

        // 只留和 T8 有关的编译开关，全量太长
        let interesting = ["ENABLE_FTS5", "ENABLE_DBSTAT_VTAB", "TEMP_STORE", "THREADSAFE", "SECURE_DELETE",
                           "HAS_CODEC", "ENABLE_COLUMN_METADATA", "ENABLE_PREUPDATE_HOOK", "ENABLE_SESSION",
                           "ENABLE_SNAPSHOT", "ENABLE_RTREE", "ENABLE_STAT4", "ENABLE_MATH_FUNCTIONS",
                           "DQS", "OMIT_LOAD_EXTENSION", "MAX_VARIABLE_NUMBER", "ENABLE_MEMORY_MANAGEMENT",
                           "ENABLE_API_ARMOR", "ENABLE_UNLOCK_NOTIFY", "USE_URI", "ENABLE_CARRAY"]
        let all = (try? db.stringRows("PRAGMA compile_options;", columns: 1))?.map { $0[0] } ?? []
        info["compile_options_all_count"] = all.count
        info["compile_options_selected"] = all.filter { opt in interesting.contains { opt.contains($0) } }.sorted()
        // T8 要求逐项确认的四个开关
        info["required_flags"] = [
            "SQLITE_ENABLE_FTS5": all.contains("ENABLE_FTS5"),
            "SQLITE_ENABLE_DBSTAT_VTAB": all.contains("ENABLE_DBSTAT_VTAB"),
            "SQLITE_HAS_CODEC": all.contains("HAS_CODEC"),
            "SQLITE_TEMP_STORE": all.first(where: { $0.hasPrefix("TEMP_STORE=") }) ?? "(未列出)",
            "sqlite_ge_3_43": sqlite3_libversion_number() >= 3_043_000,
        ]
        return info
    }

    // ------------------------------------------------------------ 语料

    static func makeCorpus(rows: Int, seed: UInt64) -> [Doc] {
        var rng = SplitMix64(seed: seed)
        var docs: [Doc] = []
        docs.reserveCapacity(rows)
        for i in 0..<rows {
            let t = Corpus.document(index: i, rng: &rng)
            let b = Corpus.bigramJoin(t)
            let sha = Array(SHA256.hash(data: Data(t.utf8)))
            docs.append(Doc(text: t, bigram: b, sha: sha, vec: Corpus.vector(index: i), byteLen: t.utf8.count))
        }
        return docs
    }

    /// 模拟"从 data-protection 钥匙串取出的 256 位主密钥"（3.5）。
    /// 这里用固定字节，报告可复现；产品里由 SecRandomCopyBytes 生成后存钥匙串。
    static func keyMaterial() -> [UInt8] {
        var k = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { k[i] = UInt8((i &* 37 &+ 11) & 0xFF) }
        return k
    }

    // ------------------------------------------------------------ 建库 + 灌数据 + 查询

    static func buildDatabase(path: String, key: [UInt8]?, docs: [Doc], opts: Opts) throws -> [String: Any] {
        let encrypted = key != nil
        removeDBFiles(path)
        var res: [String: Any] = ["path": path, "encrypted": encrypted]

        let (db, openMs, zeroed) = try openUnlocked(path: path, key: key, create: true)
        if encrypted {
            res["key_applied_and_verified_ms"] = r(openMs)
            res["key_buffer_zeroed"] = zeroed
        }
        // 加密库的页大小已经在 openUnlocked 里设过，这里只补明文库的
        let pagePragma = encrypted ? "PRAGMA cipher_page_size = \(cipherPageSize);" : "PRAGMA page_size = \(cipherPageSize);"
        for p in Schema.preamble(pageSizePragma: pagePragma) { try db.exec(p) }
        try db.exec(Schema.tables)
        try db.exec(Schema.fts)
        try db.exec(Schema.vec)

        res["page_size"] = try db.scalarInt("PRAGMA page_size;") ?? -1
        res["journal_mode"] = try db.scalarString("PRAGMA journal_mode;") ?? "?"
        res["temp_store"] = try db.scalarInt("PRAGMA temp_store;") ?? -1
        res["auto_vacuum"] = try db.scalarInt("PRAGMA auto_vacuum;") ?? -1
        res["secure_delete"] = try db.scalarInt("PRAGMA secure_delete;") ?? -1
        if encrypted {
            for p in ["cipher_version", "cipher_provider", "cipher_provider_version",
                      "cipher_page_size", "kdf_iter", "cipher_hmac_algorithm",
                      "cipher_kdf_algorithm", "cipher_memory_security"] {
                res[p] = (try? db.scalarString("PRAGMA \(p);")) ?? nil ?? "(空)"
            }
        }

        // ---- 参照对象 ----
        try db.exec("BEGIN;")
        for (i, b) in Corpus.appNames.enumerated() {
            try db.exec("INSERT INTO apps(id,bundle_id,name) VALUES(\(i+1),'\(b)','\(b)');")
        }
        for w in 0..<40 {
            try db.exec("INSERT INTO windows(id,app_id,title) VALUES(\(w+1),\(w % 8 + 1),'窗口标题 \(w) window');")
        }
        for u in 0..<200 {
            let host = "host\(u % 25).example.com"
            try db.exec("INSERT INTO urls(id,raw_locator,canonical_url,host,kind) VALUES(\(u+1),'https://\(host)/p/\(u)?q=1','https://\(host)/p/\(u)','\(host)','web');")
        }
        try db.exec("COMMIT;")

        // ---- 主体写入 ----
        let insObs = try db.prepare("""
            INSERT INTO observations(device_id,id,ts,display_id,app_id,window_id,url_id,
              "trigger",capture_method,completeness,source_state)
            VALUES('dev-m4max',?,?,1,?,?,?,'timer','ax','complete','ok');
            """)
        let insTV = try db.prepare("""
            INSERT INTO text_versions(vrow,device_id,id,sha256,text,byte_len,created_at)
            VALUES(?,'dev-m4max',?,?,?,?,?);
            """)
        let insOcc = try db.prepare("""
            INSERT INTO occurrences(device_id,id,observation_id,text_version_id,ord)
            VALUES('dev-m4max',?,?,?,0);
            """)
        let insFTS = try db.prepare("INSERT INTO text_fts(rowid, text) VALUES(?,?);")
        // sqlite-vec 默认把裸 BLOB 当 float32，必须用 vec_int8() 明确类型
        let insVec = try db.prepare("INSERT INTO vec_text(text_rowid, embedding) VALUES(?, vec_int8(?));")
        defer { for s in [insObs, insTV, insOcc, insFTS, insVec] { sqlite3_finalize(s) } }

        let baseTs: Int64 = 1_756_000_000_000
        let t0 = nowNs()
        var batchStart = 0
        while batchStart < docs.count {
            let end = min(batchStart + 1000, docs.count)
            try db.exec("BEGIN;")
            for i in batchStart..<end {
                let d = docs[i]
                let rowid = Int64(i + 1)
                let ts = baseTs + Int64(i) * 5_000

                sqlite3_reset(insObs); sqlite3_clear_bindings(insObs)
                sqlite3_bind_int64(insObs, 1, rowid)
                sqlite3_bind_int64(insObs, 2, ts)
                sqlite3_bind_int64(insObs, 3, Int64(i % 8 + 1))
                sqlite3_bind_int64(insObs, 4, Int64(i % 40 + 1))
                sqlite3_bind_int64(insObs, 5, Int64(i % 200 + 1))
                if sqlite3_step(insObs) != SQLITE_DONE { throw SQLError(op: "insert observations", code: sqlite3_errcode(db.h), message: db.errmsg) }

                sqlite3_reset(insTV); sqlite3_clear_bindings(insTV)
                sqlite3_bind_int64(insTV, 1, rowid)
                sqlite3_bind_int64(insTV, 2, rowid)
                _ = d.sha.withUnsafeBufferPointer { sqlite3_bind_blob(insTV, 3, $0.baseAddress, 32, SQLITE_TRANSIENT_DESTRUCTOR) }
                _ = d.text.withCString { sqlite3_bind_text(insTV, 4, $0, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
                sqlite3_bind_int64(insTV, 5, Int64(d.byteLen))
                sqlite3_bind_int64(insTV, 6, ts)
                if sqlite3_step(insTV) != SQLITE_DONE { throw SQLError(op: "insert text_versions", code: sqlite3_errcode(db.h), message: db.errmsg) }

                sqlite3_reset(insOcc); sqlite3_clear_bindings(insOcc)
                sqlite3_bind_int64(insOcc, 1, rowid)
                sqlite3_bind_int64(insOcc, 2, rowid)
                sqlite3_bind_int64(insOcc, 3, rowid)
                if sqlite3_step(insOcc) != SQLITE_DONE { throw SQLError(op: "insert occurrences", code: sqlite3_errcode(db.h), message: db.errmsg) }

                sqlite3_reset(insFTS); sqlite3_clear_bindings(insFTS)
                sqlite3_bind_int64(insFTS, 1, rowid)
                _ = d.bigram.withCString { sqlite3_bind_text(insFTS, 2, $0, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
                if sqlite3_step(insFTS) != SQLITE_DONE { throw SQLError(op: "insert text_fts", code: sqlite3_errcode(db.h), message: db.errmsg) }

                sqlite3_reset(insVec); sqlite3_clear_bindings(insVec)
                sqlite3_bind_int64(insVec, 1, rowid)
                _ = d.vec.withUnsafeBufferPointer {
                    sqlite3_bind_blob(insVec, 2, UnsafeRawPointer($0.baseAddress!), Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR)
                }
                if sqlite3_step(insVec) != SQLITE_DONE { throw SQLError(op: "insert vec_text", code: sqlite3_errcode(db.h), message: db.errmsg) }
            }
            try db.exec("COMMIT;")
            batchStart = end
        }
        // 派生表：每 20 条观察一个会话
        try db.exec("""
            INSERT INTO sessions(device_id,id,start,"end",primary_app_id,dwell_s,active_s,unknown_s,evidence,stale)
            SELECT 'dev-m4max', (o.id-1)/20 + 1, MIN(o.ts), MAX(o.ts), MIN(o.app_id), 90.0, 40.0, 5.0, '[]', 0
            FROM observations o GROUP BY (o.id-1)/20;
            """)
        let insertMs = msSince(t0)
        res["insert_ms"] = r(insertMs)
        res["insert_rows_per_s"] = r(Double(docs.count) / (insertMs / 1000.0), 1)

        // ---- WAL 未 checkpoint 时的泄漏检查 ----
        try db.exec("PRAGMA wal_autocheckpoint = 0;")
        try db.exec("BEGIN;")
        for i in 0..<500 {
            let d = docs[i]
            let rowid = Int64(docs.count + i + 1)
            sqlite3_reset(insObs); sqlite3_clear_bindings(insObs)
            sqlite3_bind_int64(insObs, 1, rowid); sqlite3_bind_int64(insObs, 2, baseTs + Int64(rowid) * 5_000)
            sqlite3_bind_int64(insObs, 3, 1); sqlite3_bind_int64(insObs, 4, 1); sqlite3_bind_int64(insObs, 5, 1)
            _ = sqlite3_step(insObs)
            sqlite3_reset(insTV); sqlite3_clear_bindings(insTV)
            sqlite3_bind_int64(insTV, 1, rowid); sqlite3_bind_int64(insTV, 2, rowid)
            var sha2 = d.sha; sha2[0] ^= 0xFF
            _ = sha2.withUnsafeBufferPointer { sqlite3_bind_blob(insTV, 3, $0.baseAddress, 32, SQLITE_TRANSIENT_DESTRUCTOR) }
            _ = d.text.withCString { sqlite3_bind_text(insTV, 4, $0, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
            sqlite3_bind_int64(insTV, 5, Int64(d.byteLen)); sqlite3_bind_int64(insTV, 6, baseTs)
            _ = sqlite3_step(insTV)
            sqlite3_reset(insFTS); sqlite3_clear_bindings(insFTS)
            sqlite3_bind_int64(insFTS, 1, rowid)
            _ = d.bigram.withCString { sqlite3_bind_text(insFTS, 2, $0, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
            _ = sqlite3_step(insFTS)
        }
        try db.exec("COMMIT;")
        res["leak_wal_dirty"] = scanDBFiles(path)
        res["wal_size_bytes"] = fileSize(path + "-wal")

        // ---- 查询 ----
        res["queries"] = try runQueries(db: db, opts: opts, docCount: docs.count)

        // ---- temp_store 落盘检查（3.5：排序不落盘）----
        res["temp_store_check"] = try tempStoreCheck(db: db, tmpDir: opts.workDir + "/sqlite-tmp")

        // ---- contentless_delete + 显式 FTS 维护（D22）----
        res["fts_delete_check"] = try ftsDeleteCheck(db: db, docCount: docs.count)

        // ---- dbstat 分项 ----
        let (dbstatRows, dbstatMs) = try timedMs { try db.stringRows(
            "SELECT name, SUM(pgsize), COUNT(*) FROM dbstat GROUP BY name ORDER BY 2 DESC;", columns: 3) }
        res["dbstat_ms"] = r(dbstatMs)
        res["dbstat"] = dbstatRows.map { ["name": $0[0], "bytes": Int($0[1]) ?? 0, "pages": Int($0[2]) ?? 0] }
        res["page_count"] = try db.scalarInt("PRAGMA page_count;") ?? -1
        res["freelist_count"] = try db.scalarInt("PRAGMA freelist_count;") ?? -1

        // ---- checkpoint + 关库后再查一次 ----
        try db.exec("PRAGMA wal_checkpoint(TRUNCATE);")
        db.close()
        res["leak_after_close"] = scanDBFiles(path)
        res["file_sizes"] = [
            "db": fileSize(path), "wal": fileSize(path + "-wal"), "shm": fileSize(path + "-shm"),
            "db_MiB": r(Double(fileSize(path)) / 1_048_576.0, 2),
        ]
        return res
    }

    // ------------------------------------------------------------ 查询

    static func runQueries(db: DB, opts: Opts, docCount: Int) throws -> [String: Any] {
        var out: [String: Any] = [:]
        var rng = SplitMix64(seed: 424_242)

        // 1) FTS：D22 的写法——bigram 化后包成 phrase，按 rowid 倒序取候选（不用 bm25）
        let ftsStmt = try db.prepare("SELECT rowid FROM text_fts WHERE text_fts MATCH ? ORDER BY rowid DESC LIMIT 10;")
        defer { sqlite3_finalize(ftsStmt) }
        var ftsMs: [Double] = []; var ftsRows = 0
        for k in 0..<(opts.queryReps + 10) {
            let w = Corpus.zhWords[rng.int(Corpus.zhWords.count)]
            let q = "\"" + Corpus.bigramJoin(w) + "\""
            sqlite3_reset(ftsStmt); sqlite3_clear_bindings(ftsStmt)
            _ = q.withCString { sqlite3_bind_text(ftsStmt, 1, $0, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
            let t = nowNs()
            let n = try db.drain(ftsStmt)
            let ms = msSince(t)
            if k >= 10 { ftsMs.append(ms); ftsRows += n }   // 前 10 次当预热
        }
        out["fts_match"] = LatencyStats(ftsMs).json.merging(["avg_rows": Double(ftsRows) / Double(max(1, ftsMs.count))]) { a, _ in a }

        // 2) 精确字段两步式（E7）：先取 id，再取行
        let hostStmt = try db.prepare("SELECT id FROM urls WHERE host = ?;")
        let obsStmt = try db.prepare("SELECT id, ts FROM observations WHERE url_id = ? ORDER BY ts DESC LIMIT 20;")
        defer { sqlite3_finalize(hostStmt); sqlite3_finalize(obsStmt) }
        var exactMs: [Double] = []
        for k in 0..<(opts.queryReps + 10) {
            let host = "host\(rng.int(25)).example.com"
            let t = nowNs()
            sqlite3_reset(hostStmt); sqlite3_clear_bindings(hostStmt)
            _ = host.withCString { sqlite3_bind_text(hostStmt, 1, $0, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
            var ids: [Int64] = []
            while sqlite3_step(hostStmt) == SQLITE_ROW { ids.append(sqlite3_column_int64(hostStmt, 0)) }
            for id in ids.prefix(4) {
                sqlite3_reset(obsStmt); sqlite3_clear_bindings(obsStmt)
                sqlite3_bind_int64(obsStmt, 1, id)
                _ = try db.drain(obsStmt)
            }
            let ms = msSince(t)
            if k >= 10 { exactMs.append(ms) }
        }
        out["exact_two_step"] = LatencyStats(exactMs).json

        // 3) vec0 KNN
        let knnStmt = try db.prepare("SELECT text_rowid, distance FROM vec_text WHERE embedding MATCH vec_int8(?) ORDER BY distance LIMIT 10;")
        defer { sqlite3_finalize(knnStmt) }
        var knnMs: [Double] = []; var knnRows = 0; var knnErr = ""
        for k in 0..<(opts.queryReps + 10) {
            let q = Corpus.vector(index: rng.int(docCount))
            sqlite3_reset(knnStmt); sqlite3_clear_bindings(knnStmt)
            _ = q.withUnsafeBufferPointer {
                sqlite3_bind_blob(knnStmt, 1, UnsafeRawPointer($0.baseAddress!), Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR)
            }
            let t = nowNs()
            do {
                let n = try db.drain(knnStmt)
                let ms = msSince(t)
                if k >= 10 { knnMs.append(ms); knnRows += n }
            } catch { knnErr = "\(error)"; break }
        }
        out["vec_knn"] = knnMs.isEmpty ? ["error": knnErr]
            : LatencyStats(knnMs).json.merging(["avg_rows": Double(knnRows) / Double(max(1, knnMs.count))]) { a, _ in a }

        // 4) KNN 召回自检：查询向量就是第 i 条，最近邻应当命中自己
        var selfHit = 0
        for i in stride(from: 0, to: docCount, by: max(1, docCount / 50)) {
            let q = Corpus.vector(index: i)
            sqlite3_reset(knnStmt); sqlite3_clear_bindings(knnStmt)
            _ = q.withUnsafeBufferPointer {
                sqlite3_bind_blob(knnStmt, 1, UnsafeRawPointer($0.baseAddress!), Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR)
            }
            if sqlite3_step(knnStmt) == SQLITE_ROW, sqlite3_column_int64(knnStmt, 0) == Int64(i + 1) { selfHit += 1 }
        }
        out["vec_knn_self_hit"] = selfHit

        // 5) 会话区间（加 start 下界，E7）
        let sessStmt = try db.prepare("""
            SELECT id, dwell_s FROM sessions
            WHERE device_id='dev-m4max' AND start >= ? AND start <= ? ORDER BY start LIMIT 50;
            """)
        defer { sqlite3_finalize(sessStmt) }
        var sessMs: [Double] = []
        for k in 0..<(opts.queryReps + 10) {
            let s = 1_756_000_000_000 + Int64(rng.int(max(1, docCount)) * 5_000)
            sqlite3_reset(sessStmt); sqlite3_clear_bindings(sessStmt)
            sqlite3_bind_int64(sessStmt, 1, s); sqlite3_bind_int64(sessStmt, 2, s + 3_600_000)
            let t = nowNs(); _ = try db.drain(sessStmt); let ms = msSince(t)
            if k >= 10 { sessMs.append(ms) }
        }
        out["sessions_range"] = LatencyStats(sessMs).json

        // 6) 大页缓存对照：默认 cache_size 只有 2 MiB，10 MiB 的向量分块每次 KNN 都要重新读盘 + 解密。
        //    把缓存放大到 128 MiB 再测一遍，用来判断"加密开销"里有多少其实是缓存不够导致的重复解密。
        try db.exec("PRAGMA cache_size = -131072;")
        for _ in 0..<3 {                                   // 预热：把向量分块和 FTS 索引读进缓存
            let q = Corpus.vector(index: 0)
            sqlite3_reset(knnStmt); sqlite3_clear_bindings(knnStmt)
            _ = q.withUnsafeBufferPointer {
                sqlite3_bind_blob(knnStmt, 1, UnsafeRawPointer($0.baseAddress!), Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR)
            }
            _ = try db.drain(knnStmt)
        }
        var knnBig: [Double] = []
        for _ in 0..<opts.queryReps {
            let q = Corpus.vector(index: rng.int(docCount))
            sqlite3_reset(knnStmt); sqlite3_clear_bindings(knnStmt)
            _ = q.withUnsafeBufferPointer {
                sqlite3_bind_blob(knnStmt, 1, UnsafeRawPointer($0.baseAddress!), Int32($0.count), SQLITE_TRANSIENT_DESTRUCTOR)
            }
            let t = nowNs(); _ = try db.drain(knnStmt); knnBig.append(msSince(t))
        }
        out["vec_knn_cache128MiB"] = LatencyStats(knnBig).json
        var ftsBig: [Double] = []
        for _ in 0..<(opts.queryReps + 10) {
            let w = Corpus.zhWords[rng.int(Corpus.zhWords.count)]
            let q = "\"" + Corpus.bigramJoin(w) + "\""
            sqlite3_reset(ftsStmt); sqlite3_clear_bindings(ftsStmt)
            _ = q.withCString { sqlite3_bind_text(ftsStmt, 1, $0, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
            let t = nowNs(); _ = try db.drain(ftsStmt); let ms = msSince(t)
            if ftsBig.count < opts.queryReps { ftsBig.append(ms) }
        }
        out["fts_match_cache128MiB"] = LatencyStats(ftsBig).json
        try db.exec("PRAGMA cache_size = -2000;")
        return out
    }

    // ------------------------------------------------------------ temp_store

    /// 临时目录所在卷的可用字节（statvfs 口径）。
    nonisolated static func freeBytes(dir: String) -> Int64 {
        var st = statvfs()
        guard statvfs(dir, &st) == 0 else { return -1 }
        return Int64(st.f_bavail) * Int64(st.f_frsize)
    }

    static func tempStoreCheck(db: DB, tmpDir: String) throws -> [String: Any] {
        // 强制一次必须排序的全表扫描：ORDER BY 一个没有索引的大 TEXT 列
        let sortSQL = "SELECT count(*) FROM (SELECT text FROM text_versions ORDER BY text);"
        try db.exec("PRAGMA cache_size = -1000;")   // 1 MiB，逼 sorter 真的想落盘

        var out: [String: Any] = [:]
        for (label, pragma) in [("memory", "PRAGMA temp_store = MEMORY;"), ("file", "PRAGMA temp_store = FILE;")] {
            try db.exec(pragma)
            brosis_shim_reset()
            let freeBefore = freeBytes(dir: tmpDir)
            var freeMin = freeBefore
            // statvfs 口径：另开一个线程在排序期间高频采样临时目录所在卷的可用字节
            let stop = UnsafeMutablePointer<Bool>.allocate(capacity: 1); stop.pointee = false
            let sampler = Thread {
                while !stop.pointee {
                    let f = Probe.freeBytes(dir: tmpDir)
                    if f < freeMin { freeMin = f }
                    usleep(500)
                }
            }
            sampler.start()
            let (_, ms) = try timedMs { try db.scalarInt(sortSQL) }
            stop.pointee = true
            usleep(20_000)
            stop.deallocate()
            out[label] = [
                "statvfs_free_bytes_before": freeBefore,
                "statvfs_free_bytes_min_during": freeMin,
                "statvfs_max_dip_bytes": max(0, freeBefore - freeMin),
                "statvfs_max_dip_MiB": r(Double(max(0, freeBefore - freeMin)) / 1_048_576.0, 2),
                "temp_store_readback": (try? db.scalarInt("PRAGMA temp_store;")) ?? -1,
                "sort_ms": r(ms),
                "temp_file_opens": brosis_shim_temp_opens(),
                "temp_file_bytes": brosis_shim_temp_bytes(),
                "temp_file_MiB": r(Double(brosis_shim_temp_bytes()) / 1_048_576.0, 2),
                "plaintext_marker_hits_in_temp":
                    brosis_shim_marker_hits(BROSIS_KIND_TEMP_JOURNAL) + brosis_shim_marker_hits(BROSIS_KIND_TEMP_DB)
                    + brosis_shim_marker_hits(BROSIS_KIND_TRANSIENT_DB) + brosis_shim_marker_hits(BROSIS_KIND_SUBJOURNAL),
                "plaintext_marker_hits_all_files": brosis_shim_total_marker_hits(),
                "main_db_writes": brosis_shim_writes(BROSIS_KIND_MAIN_DB),
                "wal_writes": brosis_shim_writes(BROSIS_KIND_WAL),
            ]
        }
        try db.exec("PRAGMA temp_store = MEMORY;")   // 恢复
        brosis_shim_reset()
        return out
    }

    // ------------------------------------------------------------ contentless_delete

    static func ftsDeleteCheck(db: DB, docCount: Int) throws -> [String: Any] {
        let victim = Int64(docCount / 2)
        func matches(_ token: String) throws -> Int {
            let st = try db.prepare("SELECT rowid FROM text_fts WHERE text_fts MATCH ? LIMIT 10;")
            defer { sqlite3_finalize(st) }
            _ = token.withCString { sqlite3_bind_text(st, 1, $0, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
            return try db.drain(st)
        }
        let token = "docid\(victim - 1)"    // 第 victim 行对应 index victim-1
        let before = try matches(token)
        // D22：存储服务显式删除，没有触发器
        try db.exec("BEGIN;")
        try db.exec("DELETE FROM occurrences WHERE device_id='dev-m4max' AND text_version_id=\(victim);")
        try db.exec("DELETE FROM text_versions WHERE vrow=\(victim);")
        let (delRC, delMsg) = db.tryExec("DELETE FROM text_fts WHERE rowid=\(victim);")
        try db.exec("DELETE FROM vec_text WHERE text_rowid=\(victim);")
        try db.exec("COMMIT;")
        let after = try matches(token)
        return [
            "token": token,
            "matches_before": before,
            "matches_after": after,
            "fts_delete_rc": Int(delRC),
            "fts_delete_msg": delMsg,
            "contentless_delete_works": delRC == SQLITE_OK && before >= 1 && after == before - 1,
            "fts_integrity_check_rc": Int(db.tryExec("INSERT INTO text_fts(text_fts) VALUES('integrity-check');").0),
        ]
    }

    // ------------------------------------------------------------ 错误密钥

    static func wrongKeyChecks(path: String, correct: [UInt8]) -> [String: Any] {
        var out: [String: Any] = [:]
        // a) 换一个密钥
        do {
            var wrong = correct; wrong[0] ^= 0xFF
            let db = try DB(path: path, create: false)
            defer { db.close() }
            let sk = SecureKey(bytes: wrong)
            try? sk.applyKey(to: db.h!)
            _ = db.tryExec("PRAGMA cipher_page_size = \(cipherPageSize);")
            let (rc, msg) = db.tryExec("SELECT count(*) FROM sqlite_schema;")
            sk.zeroize()
            out["wrong_key"] = ["rc": Int(rc), "rc_name": rcName(rc), "message": msg, "failed_as_expected": rc != SQLITE_OK]
        } catch { out["wrong_key"] = ["error": "\(error)"] }
        // b) 完全不给密钥
        do {
            let db = try DB(path: path, create: false)
            defer { db.close() }
            _ = db.tryExec("PRAGMA page_size = \(cipherPageSize);")
            let (rc, msg) = db.tryExec("SELECT count(*) FROM sqlite_schema;")
            out["no_key"] = ["rc": Int(rc), "rc_name": rcName(rc), "message": msg, "failed_as_expected": rc != SQLITE_OK]
        } catch { out["no_key"] = ["error": "\(error)"] }
        // c) 正确密钥必须还能开
        do {
            let (db, _, _) = try openUnlocked(path: path, key: correct, create: false)
            defer { db.close() }
            let n = try db.scalarInt("SELECT count(*) FROM observations;") ?? -1
            out["correct_key"] = ["observations": n, "ok": n > 0,
                                  "note": "错误密钥尝试之后仍能用正确密钥打开，说明失败的解锁不会破坏库"]
        } catch { out["correct_key"] = ["error": "\(error)"] }
        return out
    }

    // ------------------------------------------------------------ 锁定状态机

    static func lockCycle(path: String, opts: Opts) throws -> [String: Any] {
        var openMs: [Double] = []
        var writeMs: [Double] = []
        var queryMs: [Double] = []
        var closeMs: [Double] = []
        var zeroOK = true
        var lastRows: Int64 = 0

        for cycle in 0..<opts.openReps {
            // unlocking：从"钥匙串"取密钥（这里是固定字节），开库，校验
            let tOpen = nowNs()
            let (db, unlockMs, zeroed) = try openUnlocked(path: path, key: keyMaterial(), create: false)
            lastRows = try db.scalarInt("SELECT count(*) FROM observations;") ?? -1
            openMs.append(msSince(tOpen))
            if !zeroed { zeroOK = false }
            _ = unlockMs
            try db.exec("PRAGMA foreign_keys = ON; PRAGMA temp_store = MEMORY;")

            // unlocked：写
            let tW = nowNs()
            try db.exec("""
                INSERT INTO observations(device_id,id,ts,display_id,app_id,window_id,url_id,
                  "trigger",capture_method,completeness,source_state)
                VALUES('dev-m4max',\(900_000 + cycle),\(1_756_900_000_000 + cycle),1,1,1,1,
                       'manual','ax','complete','ok');
                """)
            writeMs.append(msSince(tW))

            // unlocked：查
            let tQ = nowNs()
            let st = try db.prepare("SELECT rowid FROM text_fts WHERE text_fts MATCH ? ORDER BY rowid DESC LIMIT 10;")
            let q = "\"" + Corpus.bigramJoin("会议纪要") + "\""
            _ = q.withCString { sqlite3_bind_text(st, 1, $0, -1, SQLITE_TRANSIENT_DESTRUCTOR) }
            _ = try db.drain(st)
            sqlite3_finalize(st)
            queryMs.append(msSince(tQ))

            // locking：flush、checkpoint、关库、清密钥
            let tC = nowNs()
            try db.exec("PRAGMA wal_checkpoint(PASSIVE);")
            db.close()
            closeMs.append(msSince(tC))
        }
        return [
            "cycles": opts.openReps,
            "open_ms": LatencyStats(openMs).json,
            "write_ms": LatencyStats(writeMs).json,
            "query_ms": LatencyStats(queryMs).json,
            "close_ms": LatencyStats(closeMs).json,
            "key_zeroized_every_cycle": zeroOK,
            "reopen_after_zeroize_ok": lastRows > 0,
            "observations_last_seen": lastRows,
        ]
    }

    // ------------------------------------------------------------ 口令密钥对照

    static func passphraseOpen(path: String, opts: Opts) throws -> [String: Any] {
        removeDBFiles(path)
        let pass = "correct horse battery staple"
        do {
            let db = try DB(path: path)
            defer { db.close() }
            try db.exec("PRAGMA key = '\(pass)';")
            try db.exec("PRAGMA cipher_page_size = 16384;")
            try db.exec("CREATE TABLE t(a TEXT); INSERT INTO t VALUES('\(Corpus.canaryEN)');")
        }
        var ms: [Double] = []
        var kdf: Int64 = -1
        for _ in 0..<5 {
            let t = nowNs()
            let db = try DB(path: path, create: false)
            try db.exec("PRAGMA key = '\(pass)';")
            try db.exec("PRAGMA cipher_page_size = \(cipherPageSize);")
            _ = try db.scalarInt("SELECT count(*) FROM t;")
            ms.append(msSince(t))
            kdf = try db.scalarInt("PRAGMA kdf_iter;") ?? -1
            db.close()
        }
        return ["passphrase_open_ms": LatencyStats(ms).json, "kdf_iter": kdf,
                "note": "口令密钥每次开库都要跑 PBKDF2-HMAC-SHA512 kdf_iter 轮；原始密钥跳过这一步"]
    }

    // ------------------------------------------------------------ 泄漏扫描

    static func scanDBFiles(_ path: String) -> [String: Any] {
        var out: [String: Any] = [:]
        var total = 0
        for suffix in ["", "-wal", "-shm"] {
            let r = scanFile(path + suffix, needles: Corpus.needles)
            out[suffix.isEmpty ? "db" : String(suffix.dropFirst())] = r
            total += (r["total_hits"] as? Int) ?? 0
        }
        out["total_hits"] = total
        return out
    }

    static func scanDirectory(_ dir: String) -> [String: Any] {
        let fm = FileManager.default
        guard let items = try? fm.subpathsOfDirectory(atPath: dir) else { return ["exists": false] }
        var files: [[String: Any]] = []
        var total = 0
        for it in items {
            let full = dir + "/" + it
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
            let r = scanFile(full, needles: Corpus.needles)
            total += (r["total_hits"] as? Int) ?? 0
            files.append(["name": it, "scan": r])
        }
        return ["exists": true, "file_count": files.count, "files": files, "total_hits": total]
    }

    static func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
    }

    static func removeDBFiles(_ path: String) {
        for s in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + s) }
    }

    static func rcName(_ rc: Int32) -> String {
        switch rc {
        case SQLITE_OK: return "SQLITE_OK"
        case SQLITE_NOTADB: return "SQLITE_NOTADB"
        case SQLITE_ERROR: return "SQLITE_ERROR"
        case SQLITE_CORRUPT: return "SQLITE_CORRUPT"
        case SQLITE_PERM: return "SQLITE_PERM"
        default: return "rc=\(rc)"
        }
    }

    // ------------------------------------------------------------ 加密开销

    static func overhead(enc: [String: Any], plain: [String: Any]) -> [String: Any] {
        func d(_ m: [String: Any], _ k: String) -> Double { (m[k] as? Double) ?? Double((m[k] as? Int) ?? 0) }
        func q(_ m: [String: Any], _ name: String, _ field: String) -> Double {
            guard let qs = m["queries"] as? [String: Any], let one = qs[name] as? [String: Any] else { return .nan }
            return (one[field] as? Double) ?? .nan
        }
        var out: [String: Any] = [
            "insert_ms_encrypted": d(enc, "insert_ms"),
            "insert_ms_plaintext": d(plain, "insert_ms"),
            "insert_slowdown_x": r(d(enc, "insert_ms") / max(0.001, d(plain, "insert_ms")), 3),
            "db_bytes_encrypted": ((enc["file_sizes"] as? [String: Any])?["db"] as? Int) ?? 0,
            "db_bytes_plaintext": ((plain["file_sizes"] as? [String: Any])?["db"] as? Int) ?? 0,
        ]
        var perQuery: [String: Any] = [:]
        for name in ["fts_match", "exact_two_step", "vec_knn", "sessions_range", "vec_knn_cache128MiB", "fts_match_cache128MiB"] {
            let e50 = q(enc, name, "p50_ms"), p50 = q(plain, name, "p50_ms")
            let e95 = q(enc, name, "p95_ms"), p95 = q(plain, name, "p95_ms")
            perQuery[name] = ["enc_p50_ms": r(e50), "plain_p50_ms": r(p50), "p50_slowdown_x": r(e50 / max(1e-6, p50), 3),
                              "enc_p95_ms": r(e95), "plain_p95_ms": r(p95), "p95_slowdown_x": r(e95 / max(1e-6, p95), 3)]
        }
        out["queries"] = perQuery
        let eb = (out["db_bytes_encrypted"] as? Int) ?? 0
        let pb = (out["db_bytes_plaintext"] as? Int) ?? 1
        out["db_size_ratio"] = r(Double(eb) / Double(max(1, pb)), 4)
        return out
    }
}
