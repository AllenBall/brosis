import XCTest
@testable import BrosisCore

/// E3 的 S6 崩溃恢复，在**加密库**上复跑：
/// `brosis-store crash-after` 写 N 条并提交，再开一个未提交事务写一批，然后 `kill -9` 自己；
/// 本用例重开库，验证已提交的都在、未提交的整批回滚，13 项悬空引用检查全为 0。
final class CrashRecoveryTests: XCTestCase {

    func testKillDashNineDuringUncommittedTransaction() throws {
        guard let cli = Products.brosisStore else {
            throw XCTSkip("找不到 brosis-store 可执行文件；用 BROSIS_STORE_BIN 指定路径")
        }
        let root = Fixture.testRoot.appendingPathComponent("crash-\(UUID().uuidString.prefix(8))",
                                                           isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let keyFile = root.appendingPathComponent("db.key")

        let committed = 300
        let pending = 50

        let initResult = try Products.run(cli, ["init", "--dir", dataDir.path,
                                                "--key-file", keyFile.path])
        XCTAssertEqual(initResult.status, 0, initResult.err)
        let initJSON = parseJSONOutput(initResult.out)
        XCTAssertEqual(initJSON["temp_store_compiled"] as? Int, 3)
        XCTAssertEqual(initJSON["cipher_page_size"] as? Int, 16384)

        let crash = try Products.run(cli, ["crash-after", "--dir", dataDir.path,
                                           "--key-file", keyFile.path,
                                           "--count", String(committed),
                                           "--batch", String(pending)])
        // kill -9 → 终止状态码 9（Process.terminationStatus 在信号终止时给信号号）
        XCTAssertNotEqual(crash.status, 0, "子进程必须是被 SIGKILL 杀掉的，而不是正常退出")

        // 进度文件证明 kill 确实打在未提交事务里
        let progress = dataDir.appendingPathComponent("brosis.db.progress")
        XCTAssertTrue(FileManager.default.fileExists(atPath: progress.path))
        let progressJSON = parseJSONOutput(try String(contentsOf: progress, encoding: .utf8))
        XCTAssertEqual(progressJSON["committed"] as? Int, committed)
        XCTAssertEqual(progressJSON["pending"] as? Int, pending)

        // WAL 应该还在（没 checkpoint 就被杀了）
        let walSize = ((try? FileManager.default.attributesOfItem(
            atPath: dataDir.appendingPathComponent("brosis.db-wal").path)[.size]) as? NSNumber)?
            .intValue ?? 0
        XCTAssertGreaterThan(walSize, 0, "被杀时 WAL 里应当还有未 checkpoint 的内容")

        // 重开库：库自愈，未提交批整批回滚
        var options = StoreOptions()
        options.createIfMissing = false
        let store = try Store.open(directory: dataDir,
                                   keyProvider: FileKeyProvider(url: keyFile, createIfMissing: false),
                                   options: options)
        defer { store.close() }

        XCTAssertEqual(try store.count(table: "observations"), committed,
                       "已提交的 \(committed) 条都在，未提交的 \(pending) 条整批回滚")
        XCTAssertEqual(try store.count(table: "occurrences"), committed)

        let report = try store.integrityReport()
        // 13（E3 S7）+ 3（v4 的 chunks / vec_chunks）
        XCTAssertEqual(report.danglingChecks.count, 16)
        for item in report.danglingChecks {
            XCTAssertEqual(item.value, item.expected, "崩溃恢复后悬空检查失败：\(item.name)")
        }
        XCTAssertEqual(report.integrityCheck, "ok")
        XCTAssertEqual(report.ftsIntegrityCheck, "ok")
        XCTAssertEqual(report.foreignKeyViolations, 0)
        XCTAssertTrue(report.allPassed)

        // 计数器也要跟着回滚：下一条观察的 id 应当接在 committed 之后
        let next = try store.record(Synth.observation(ts: Synth.baseTS + 9_000_000,
                                                      texts: ["崩溃后的第一条"]))
        XCTAssertEqual(next.observationID, Int64(committed) + 1,
                       "计数器与数据在同一个事务里，必须一起回滚")
        XCTAssertTrue(try store.integrityReport().allPassed)
    }

    /// CLI 的其余子命令冒烟：验收者照 README 敲的命令必须都能跑通。
    func testCLIEndToEnd() throws {
        guard let cli = Products.brosisStore else {
            throw XCTSkip("找不到 brosis-store 可执行文件")
        }
        let root = Fixture.testRoot.appendingPathComponent("cli-\(UUID().uuidString.prefix(8))",
                                                           isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("data", isDirectory: true).path
        let key = root.appendingPathComponent("db.key").path
        let jsonl = root.appendingPathComponent("synth.jsonl").path

        func run(_ args: [String], file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
            let r = try Products.run(cli, args)
            XCTAssertEqual(r.status, 0, "\(args.first ?? "") 失败：\(r.err)", file: file, line: line)
            return parseJSONOutput(r.out)
        }

        _ = try run(["init", "--dir", dir, "--key-file", key])
        let gen = try run(["gen-jsonl", "--out", jsonl, "--count", "500", "--seed", "20260907"])
        XCTAssertEqual(gen["count"] as? Int, 500)

        // 同 seed 两次生成必须逐字节相同
        let jsonl2 = root.appendingPathComponent("synth2.jsonl").path
        _ = try run(["gen-jsonl", "--out", jsonl2, "--count", "500", "--seed", "20260907"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: jsonl)),
                       try Data(contentsOf: URL(fileURLWithPath: jsonl2)),
                       "同 seed 的合成流必须确定性一致")

        let imported = try run(["import-jsonl", "--dir", dir, "--key-file", key, "--file", jsonl])
        XCTAssertEqual(imported["imported"] as? Int, 500)
        XCTAssertEqual(imported["new_text_versions"] as? Int, 100, "reuse-every 默认 5 → 20% 新文本")
        XCTAssertEqual(imported["reused_text_versions"] as? Int, 400)

        let fts = try run(["dump-fts-count", "--dir", dir, "--key-file", key, "--match", "会议纪要"])
        XCTAssertEqual(fts["fts_rows"] as? Int, 100)
        XCTAssertEqual(fts["text_versions"] as? Int, 100)

        // T3 起 `search` 是三通道检索，输出里 hits 是命中数组、hit_count 是条数。
        let search = try run(["search", "--dir", dir, "--key-file", key, "--q", "存储服务", "--limit", "5"])
        XCTAssertGreaterThan(search["hit_count"] as? Int ?? 0, 0)
        XCTAssertEqual((search["evidence_ids"] as? [Any])?.count, search["hit_count"] as? Int)
        let ftsOnly = try run(["fts-only", "--dir", dir, "--key-file", key, "--q", "存储服务", "--limit", "5"])
        XCTAssertGreaterThan(ftsOnly["hits"] as? Int ?? 0, 0)

        let stats = try run(["stats", "--dir", dir, "--key-file", key, "--detail"])
        XCTAssertEqual(stats["page_size"] as? Int, 16384)
        XCTAssertGreaterThan(stats["content_bytes"] as? Int ?? 0, 0)
        XCTAssertNotNil(stats["detail"])

        let deleted = try run(["delete", "--dir", dir, "--key-file", key, "--app", "com.apple.Safari"])
        XCTAssertEqual(deleted["observations_affected"] as? Int, 100)
        XCTAssertEqual(deleted["reason"] as? String, "user")

        _ = try run(["delete", "--dir", dir, "--key-file", key,
                     "--object", "host=docs.internal"])
        _ = try run(["delete", "--dir", dir, "--key-file", key,
                     "--range", "1757000000000,1757000100000"])

        let expired = try run(["expire", "--dir", dir, "--key-file", key,
                               "--to-bytes", "2000", "--batch", "20"])
        XCTAssertLessThanOrEqual(expired["after_bytes"] as? Int ?? .max, 2000)

        let maint = try run(["maintenance", "--dir", dir, "--key-file", key])
        XCTAssertEqual(maint["wal_bytes_after"] as? Int, 0)
        XCTAssertEqual(maint["freelist_after"] as? Int, 0)

        let check = try run(["check", "--dir", dir, "--key-file", key])
        XCTAssertEqual(check["all_passed"] as? Bool, true)
        // 13（E3 S7）+ 3（v4 的 chunks / vec_chunks）
        XCTAssertEqual((check["dangling"] as? [[String: Any]])?.count, 16)

        // 错密钥必须失败（退出码非 0）
        let wrongKey = root.appendingPathComponent("wrong.key")
        try Data((0..<32).map { UInt8($0) }).write(to: wrongKey)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))],
                                              ofItemAtPath: wrongKey.path)
        let wrong = try Products.run(cli, ["stats", "--dir", dir, "--key-file", wrongKey.path])
        XCTAssertNotEqual(wrong.status, 0)
        XCTAssertTrue(wrong.err.contains("密钥错误或数据库损坏"), wrong.err)
    }
}
