import XCTest
@testable import BrosisCore

/// 密钥、编译开关、明文泄漏、目录拒绝——T2 自己的验收项（不属于 E3 七场景）。
final class CryptoAndBuildTests: XCTestCase {

    // MARK: - 错密钥 / 正确密钥

    func testWrongKeyFailsAndRightKeySucceeds() throws {
        let f = try Fixture("key", keySeed: 0x11)
        let store = f.store!
        _ = try store.record(Synth.observation(ts: Synth.baseTS, texts: ["密钥测试正文"]))
        let deviceID = store.deviceID
        f.closeStore()

        // 换一把密钥：必须失败，且报的是"密钥错误或损坏"，不是一般 SQLite 错误
        var options = StoreOptions()
        options.createIfMissing = false
        let wrong = try InMemoryKeyProvider.deterministic(seed: 0x22)
        XCTAssertThrowsError(try Store.open(directory: f.dataDirectory,
                                            keyProvider: wrong, options: options)) { error in
            guard case StoreError.wrongKeyOrCorrupt(let code, let message) = error else {
                return XCTFail("期望 wrongKeyOrCorrupt，实际 \(error)")
            }
            XCTAssertEqual(code, 26, "SQLITE_NOTADB")
            XCTAssertTrue(message.contains("not a database"), message)
        }

        // 完全不给密钥（把 32 字节全 0 当密钥也不行）
        let zeros = try InMemoryKeyProvider(key: Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try Store.open(directory: f.dataDirectory,
                                            keyProvider: zeros, options: options))

        // 失败的解锁不应该破坏库：正确密钥仍能打开、内容还在
        let reopened = try Store.open(directory: f.dataDirectory,
                                      keyProvider: f.keyProvider, options: options)
        defer { reopened.close() }
        XCTAssertEqual(reopened.deviceID, deviceID)
        XCTAssertEqual(try reopened.count(table: "observations"), 1)
        XCTAssertEqual(try reopened.evidenceText(observationID: 1), "密钥测试正文")
    }

    func testKeyIsZeroizedOnClose() throws {
        let f = try Fixture("keyzero")
        let store = f.store!
        _ = try store.record(Synth.observation(ts: Synth.baseTS, texts: ["清零测试"]))
        XCTAssertFalse(store.keyIsZeroized)
        store.close()
        XCTAssertTrue(store.keyIsZeroized, "close() 之后密钥缓冲区必须全 0")
        // 关库之后任何操作都应报"库已关闭"，不能悄悄用一把已清零的密钥
        XCTAssertThrowsError(try store.count(table: "observations"))
    }

    func testLockCycleRepeatedly() throws {
        // 3.5 的锁定状态机：unlocking → unlocked → locking → unlocking …
        let f = try Fixture("lockcycle")
        for round in 0..<20 {
            _ = try f.store.record(Synth.observation(
                ts: Synth.baseTS + Int64(round) * 1_000, texts: ["第 \(round) 轮"]))
            try f.reopen()
        }
        XCTAssertEqual(try f.store.count(table: "observations"), 20)
        XCTAssertTrue(try f.store.integrityReport().allPassed)
    }

    // MARK: - 编译开关与连接配置

    func testCompileOptionsAndConnectionPreamble() throws {
        let f = try Fixture("build")
        let info = try f.store.buildInfo()

        for required in ["THREADSAFE=1", "ENABLE_FTS5", "SECURE_DELETE",
                         "ENABLE_DBSTAT_VTAB", "HAS_CODEC", "TEMP_STORE=3"] {
            XCTAssertTrue(info.compileOptions.contains(required),
                          "PRAGMA compile_options 必须含 \(required)；实际：\(info.compileOptions)")
        }
        XCTAssertEqual(info.tempStoreCompiled, 3, "D25：TEMP_STORE 必须编译成 3（PRAGMA 改不回文件）")
        XCTAssertEqual(info.cipherPageSize, 16384, "D23：cipher_page_size = 16384")
        XCTAssertEqual(info.pageSize, 16384)
        XCTAssertEqual(info.journalMode, "wal")
        XCTAssertEqual(info.autoVacuum, 2, "auto_vacuum = INCREMENTAL")
        XCTAssertEqual(info.foreignKeys, 1)
        XCTAssertEqual(info.secureDelete, 1)
        XCTAssertEqual(info.cipherProvider, "commoncrypto", "D25：crypto 后端必须是 CommonCrypto")
        XCTAssertTrue(info.cipherVersion.hasPrefix("4.18.0"), info.cipherVersion)
        XCTAssertEqual(info.sqliteVecVersion, "v0.1.9", "sqlite-vec 静态编入，D8 通过前不启用")

        // SQLite 版本必须 ≥ 3.43（contentless_delete=1 的下限）
        let parts = info.sqliteVersion.split(separator: ".").compactMap { Int($0) }
        XCTAssertGreaterThanOrEqual(parts.count, 2)
        XCTAssertTrue(parts[0] > 3 || (parts[0] == 3 && parts[1] >= 43), info.sqliteVersion)

        // temp_store 是编译期强制的：PRAGMA 改不回 FILE
        _ = try? f.store.withLock { conn in try conn.exec("PRAGMA temp_store = FILE;") }
        let after = try f.store.buildInfo()
        XCTAssertEqual(after.tempStoreCompiled, 3)
    }

    func testCipherMemorySecurityOption() throws {
        // 可选严格项（D25）。只验证它能开、库照常可用；1.38× 的写入代价由 E6 已实测。
        var options = StoreOptions()
        options.cipherMemorySecurity = true
        let f = try Fixture("memsec", options: options)
        _ = try f.store.record(Synth.observation(ts: Synth.baseTS, texts: ["memsec 正文"]))
        XCTAssertEqual(try f.store.count(table: "observations"), 1)
        // 进程里可能已经分配过加密上下文（别的用例先开过库），所以只断言"不报错"，
        // 读回值作为信息记录而不是断言——3.5 要求它在存储服务启动的最早一步设置。
        _ = try f.store.buildInfo().cipherMemorySecurity
    }

    // MARK: - 明文泄漏

    func testNoPlaintextLeak() throws {
        // 私有 TMPDIR：SQLite 的临时文件（如果有）会落在这里，扫描面才收得住
        let f = try Fixture("leak")
        let tmp = f.root.appendingPathComponent("sqlite-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("SQLITE_TMPDIR", tmp.path, 1)
        defer { unsetenv("SQLITE_TMPDIR") }

        let canaries = ["BROSISLEAKCANARY7F3A2D", "饕餮鑫垚焱淼", "会议纪要独占标记"]
        let store = f.store!
        for i in 0..<600 {
            _ = try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(i) * 1_000,
                texts: ["第 \(i) 条：\(canaries[0]) \(canaries[1]) \(canaries[2]) "
                      + String(repeating: "填充内容 padding ", count: 12)]))
        }
        // 强制一次必须排序的全表扫描：E6 §6.3 证明 temp_store=FILE 时这里会写出明文溢出文件。
        try store.withLock { conn in
            try conn.exec("PRAGMA cache_size = -64;")   // 压到 64 KiB，逼它溢出
            _ = try conn.scalarInt("SELECT count(*) FROM (SELECT text FROM text_versions ORDER BY text);")
            try conn.exec("PRAGMA cache_size = -131072;")
        }
        // WAL 未 checkpoint 时先扫一遍
        let dirtyHits = LeakScan.scanDirectory(f.dataDirectory, for: canaries)
        for hit in dirtyHits.hits {
            XCTAssertEqual(hit.count, 0, "未 checkpoint 时 \(hit.path) 里出现了明文金丝雀")
        }
        try store.checkpoint()
        store.close()

        // 关库后再扫：.db / -wal / -shm / 数据目录 / 私有 TMPDIR / 系统 TMPDIR
        var scanned: [LeakScan.Hit] = []
        for path in [f.dataDirectory, tmp, URL(fileURLWithPath: NSTemporaryDirectory())] {
            let result = LeakScan.scanDirectory(path, for: canaries)
            scanned += result.hits
        }
        for hit in scanned {
            XCTAssertEqual(hit.count, 0, "\(hit.path) 里出现了明文金丝雀 \(hit.count) 次")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.dataDirectory
            .appendingPathComponent("brosis.db").path))
        XCTAssertGreaterThan(scanned.count, 2, "至少扫到了 .db 与目录里的其他文件")

        // 阳性对照：同样的检查器对明文文件必须能命中，证明不是空转
        let control = f.root.appendingPathComponent("plaintext-control.txt")
        try (canaries.joined(separator: " ") + "\n").write(to: control, atomically: true, encoding: .utf8)
        XCTAssertEqual(LeakScan.countOccurrences(of: canaries[0], inFileAt: control.path), 1)
        XCTAssertEqual(LeakScan.countOccurrences(of: canaries[1], inFileAt: control.path), 1)
    }

    // MARK: - D16 目录拒绝

    func testRejectsSyncedDirectories() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rejected = [
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs/brosis",
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs/some/nested/project/data",
            "\(home)/Dropbox/brosis",
            "\(home)/Google Drive/My Drive/brosis",
            "\(home)/OneDrive - Some Company/brosis",
            "\(home)/Library/Mobile Documents/com~apple~CloudDocs/brosis-sync/db",
            "\(home)/Nextcloud/brosis",
            "\(home)/坚果云/brosis",
        ]
        for path in rejected {
            XCTAssertThrowsError(try DataDirectory.validate(URL(fileURLWithPath: path)),
                                 "必须拒绝 \(path)") { error in
                guard case StoreError.directoryRejected = error else {
                    return XCTFail("期望 directoryRejected，实际 \(error)")
                }
            }
        }

        // Store.open 层也必须拒绝（不能只有 validate 拦得住）
        let icloud = URL(fileURLWithPath: "\(home)/Library/Mobile Documents/com~apple~CloudDocs/brosis-t2-should-not-exist")
        XCTAssertThrowsError(try Store.open(directory: icloud,
                                            keyProvider: try InMemoryKeyProvider.random())) { error in
            guard case StoreError.directoryRejected = error else {
                return XCTFail("期望 directoryRejected，实际 \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: icloud.path),
                       "被拒绝时不能已经把目录建出来")

        // 允许的目录
        XCTAssertNoThrow(try DataDirectory.validate(Fixture.testRoot.appendingPathComponent("ok")))
        XCTAssertNoThrow(try DataDirectory.validate(
            URL(fileURLWithPath: "\(home)/Library/Application Support/com.brosis.app")))
    }

    func testDirectoryFlags() throws {
        let f = try Fixture("dirflags")
        let flags = DataDirectory.auditFlags(f.dataDirectory)
        XCTAssertEqual(flags.mode, 0o700, "硬约束 7：数据目录 0700")
        XCTAssertTrue(flags.neverIndex, "目录里要有 .metadata_never_index（排除 Spotlight）")
        XCTAssertTrue(flags.excludedFromBackup, "要排除 Time Machine")
    }

    // MARK: - KeyProvider

    func testFileKeyProviderCreatesAndEnforces0600() throws {
        let dir = Fixture.testRoot.appendingPathComponent("filekey-\(UUID().uuidString.prefix(8))",
                                                          isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyURL = dir.appendingPathComponent("db.key")

        let provider = FileKeyProvider(url: keyURL)
        let first = try provider.fetchKey()
        XCTAssertEqual(first.count, 32)
        let mode = ((try FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions])
                    as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(mode & 0o777, 0o600, "密钥文件必须是 0600")
        XCTAssertEqual(try provider.fetchKey(), first, "第二次取到同一把")

        // 权限放宽后必须拒绝
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))],
                                              ofItemAtPath: keyURL.path)
        XCTAssertThrowsError(try provider.fetchKey())

        // 不允许生成时必须报错
        let missing = FileKeyProvider(url: dir.appendingPathComponent("absent.key"),
                                      createIfMissing: false)
        XCTAssertThrowsError(try missing.fetchKey())
    }

    func testKeyBytesAreRandomAnd32Bytes() throws {
        let a = try KeyBytes.random()
        let b = try KeyBytes.random()
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(b.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertThrowsError(try SecureKey(Data(repeating: 1, count: 16)))
    }

    func testSecureKeyZeroize() throws {
        var raw = try KeyBytes.random()
        let key = try SecureKey(raw)
        brosisZeroize(&raw)
        XCTAssertTrue(raw.allSatisfy { $0 == 0 }, "brosisZeroize 必须真的清零")
        XCTAssertFalse(key.isAllZero)
        key.zeroize()
        XCTAssertTrue(key.isAllZero)
        XCTAssertTrue(key.wasZeroized)
    }

    /// KeychainKeyProvider 只做"能构造、能编译"的冒烟；**不实跑**读写，
    /// 因为 data-protection 钥匙串首次访问会弹授权对话框（本轮约束禁止）。实跑归 T4。
    func testKeychainKeyProviderConstructsWithoutTouchingKeychain() {
        let provider = KeychainKeyProvider(service: "com.brosis.store.test",
                                           account: "unit-test", createIfMissing: false)
        XCTAssertEqual(provider.service, "com.brosis.store.test")
        XCTAssertEqual(provider.account, "unit-test")
        XCTAssertFalse(provider.createIfMissing)
    }
}
