import XCTest
@testable import BrosisCore

/// 3.2 / 3.12 的其余数据层面：策略表、运行期事件、遥测、统计口径、schema 自检。
final class StoreAPITests: XCTestCase {

    func testSchemaHasAllPlannedTables() throws {
        let f = try Fixture("schema")
        let store = f.store!
        let present = Set(try store.withLock { conn in
            try conn.textColumn("""
                SELECT name FROM sqlite_schema
                 WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'
                   AND name NOT LIKE 'text_fts_%';
                """)
        })
        // 计划 3.2 列的 13 张 + 3.12 的 app_policies + 本包自加的 meta / migrations /
        // capture_stats / mcp_audit（T5 的 schema v2）
        for table in ["apps", "windows", "urls", "files", "observations", "text_versions",
                      "occurrences", "text_fts", "sessions", "ledgers", "deletions",
                      "grants", "jobs", "app_policies", "meta", "migrations", "capture_stats",
                      "mcp_audit"] {
            XCTAssertTrue(present.contains(table), "schema 里缺少 \(table)")
        }
        // D8 通过前不建 vec 表
        XCTAssertFalse(present.contains("vec_text"), "sqlite-vec 只是静态编入，D8 通过前不建表")

        // meta / migrations
        let version = try store.withLock { conn in
            try conn.scalarText("SELECT value FROM meta WHERE key = 'schema_version';")
        }
        XCTAssertEqual(version, String(Schema.version))
        // 新库直接建到最新版，但 migrations 表里每一版各留一行审计。
        // 版本号**不一定连续**：并行任务预分配了号段，没被认领的号会留空（见 Schema.migrationVersions）。
        XCTAssertEqual(try store.count(table: "migrations"), Schema.migrationVersions.count)
        let applied = try store.withLock { conn in
            try conn.intColumn("SELECT version FROM migrations ORDER BY version;")
        }
        XCTAssertEqual(applied, Schema.migrationVersions.map(Int64.init))
        XCTAssertEqual(applied.last, Int64(Schema.version), "最后一版必须等于 Schema.version")
        XCTAssertFalse(store.deviceID.isEmpty, "D17：每台机器一个 device_id")

        // D17：不可变记录的主键都带 device_id
        for table in ["observations", "text_versions", "occurrences", "deletions"] {
            let pk = try store.withLock { conn in
                try conn.textColumn("SELECT name FROM pragma_table_info(?) WHERE pk > 0;",
                                    [.text(table)])
            }
            XCTAssertTrue(pk.contains("device_id") || table == "text_versions",
                          "\(table) 的主键要带 device_id")
        }
        // text_versions 的物理主键是 vrow（D23 的本机私有代理 rowid），业务主键靠 UNIQUE
        let tvColumns = try store.withLock { conn in
            try conn.textColumn("SELECT name FROM pragma_table_info('text_versions');")
        }
        XCTAssertTrue(tvColumns.contains("vrow"))
        XCTAssertTrue(tvColumns.contains("device_id"))

        // D23：sha256 存 BLOB
        let shaType = try store.withLock { conn in
            try conn.scalarText("SELECT type FROM pragma_table_info('text_versions') WHERE name = 'sha256';")
        }
        XCTAssertEqual(shaType, "BLOB")
    }

    func testDeviceIDIsStableAcrossReopen() throws {
        var options = StoreOptions()
        options.deviceID = "fixed-device-for-test"
        let f = try Fixture("deviceid", options: options)
        XCTAssertEqual(f.store.deviceID, "fixed-device-for-test")
        try f.reopen()   // 第二次不带 deviceID 选项，必须从 meta 读回来
        XCTAssertEqual(f.store.deviceID, "fixed-device-for-test")
    }

    func testAppPolicies() throws {
        let f = try Fixture("policies")
        let store = f.store!
        XCTAssertNil(try store.appPolicy(bundleID: "com.apple.Safari"))
        try store.setAppPolicy(bundleID: "com.apple.keychainaccess", mode: .none,
                               source: .builtinDenylist)
        try store.setAppPolicy(bundleID: "com.apple.Safari", mode: .eventsAndContent)
        try store.setAppPolicy(bundleID: "com.apple.Safari", mode: .eventsOnly)   // 改档
        let policy = try store.appPolicy(bundleID: "com.apple.Safari")
        XCTAssertEqual(policy?.mode, .eventsOnly)
        XCTAssertEqual(policy?.source, .user)
        XCTAssertEqual(try store.appPolicy(bundleID: "com.apple.keychainaccess")?.source,
                       .builtinDenylist)
        XCTAssertEqual(try store.count(table: "app_policies"), 2, "改档是 upsert，不是新增行")
    }

    func testRuntimeEventsAndCaptureStats() throws {
        let f = try Fixture("runtime")
        let store = f.store!
        _ = try store.recordRuntimeEvent(kind: "lock_state", detail: "{\"to\":\"locked\"}")
        _ = try store.recordRuntimeEvent(kind: "permission_lost", detail: "{\"api\":\"ax\"}")
        XCTAssertEqual(try store.count(table: "jobs"), 2)

        _ = try store.recordCaptureStat(ts: Synth.baseTS, displayID: 1, status: "complete",
                                        trigger: "app_switch", width: 3024, height: 1964,
                                        contentScale: 2.0, dhash: "0f1e2d3c4b5a6978",
                                        hamming: 12, dirtyRects: 3, dirtyAreaRatio: 0.18,
                                        gated: false, axChars: 1420, ocrRegions: 1)
        _ = try store.recordCaptureStat(ts: Synth.baseTS + 1_000, status: "complete", gated: true)
        XCTAssertEqual(try store.count(table: "capture_stats"), 2)

        // 遥测不参与删除级联：删光观察之后 capture_stats 一行不少
        _ = try store.record(Synth.observation(ts: Synth.baseTS, texts: ["正文"]))
        _ = try store.expire(toBytes: 0)
        XCTAssertEqual(try store.count(table: "capture_stats"), 2,
                       "capture_stats 不是 3.2 的证据表，删除与配额都不动它")
    }

    func testStatsBuckets() throws {
        let f = try Fixture("stats")
        let store = f.store!
        for i in 0..<300 {
            _ = try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(i) * 1_000,
                texts: ["统计正文 #\(i) " + String(repeating: "分项字节 dbstat ", count: 30)]))
        }
        try store.checkpoint()
        let s = try store.stats()

        XCTAssertEqual(s.pageSize, 16384)
        XCTAssertGreaterThan(s.contentBytes, 0, "正文（text_versions b-tree）")
        XCTAssertGreaterThan(s.ftsBytes, 0, "FTS 影子表")
        XCTAssertGreaterThan(s.indexBytes, s.ftsBytes, "索引应当含 FTS 影子表之外的索引")
        XCTAssertGreaterThan(s.metadataBytes, 0, "元数据（观察 / 出现 / 规范化对象）")
        XCTAssertEqual(s.walBytes, 0, "checkpoint(TRUNCATE) 之后 WAL 为 0")
        XCTAssertEqual(s.observations, 300)
        XCTAssertEqual(s.textVersions, 300)
        XCTAssertEqual(s.occurrences, 300)
        XCTAssertEqual(s.ftsRows, 300)
        XCTAssertEqual(s.quotaBytes, s.textPayloadBytes, "配额口径 = 原文净载荷")

        // dbstat 的分项之和不应该超过主库文件（还有 freelist 与页头）
        let bucketSum = s.contentBytes + s.indexBytes + s.metadataBytes   // index 已含 fts
        XCTAssertLessThanOrEqual(bucketSum, s.dbFileBytes)
        XCTAssertGreaterThan(bucketSum, s.dbFileBytes / 2, "分项应当覆盖文件的大部分")

        // 净载荷必须等于逐条 byte_len 之和
        let sumBytes = try store.withLock { conn in
            Int(try conn.scalarInt("SELECT SUM(byte_len) FROM text_versions;") ?? 0)
        }
        XCTAssertEqual(s.textPayloadBytes, sumBytes)

        let detail = try store.statsDetail()
        XCTAssertFalse(detail.isEmpty)
        XCTAssertEqual(detail.first(where: { $0.name == "text_versions" })?.bucket, "content")
        XCTAssertEqual(detail.first(where: { $0.name == "idx_obs_ts" })?.bucket, "index")
        XCTAssertNotNil(detail.first(where: { $0.bucket == "fts" }))
    }

    func testMultiFragmentObservationReconstructsInOrder() throws {
        let f = try Fixture("frag")
        let store = f.store!
        let fragments = ["第一段：标题", "第二段：正文主体", "第三段：脚注"]
        let r = try store.record(Synth.observation(ts: Synth.baseTS, texts: fragments))
        XCTAssertEqual(r.textVersionIDs.count, 3)
        // 入库不做 NFKC 折叠（折叠只用于索引），全角冒号 U+FF1A 原样保留
        XCTAssertEqual(try store.evidenceText(observationID: r.observationID),
                       fragments.joined(separator: "\n"))
        let ords = try store.withLock { conn in
            try conn.intColumn("SELECT ord FROM occurrences WHERE observation_id = ? ORDER BY ord;",
                               [.int(r.observationID)])
        }
        XCTAssertEqual(ords, [0, 1, 2])
    }

    func testDeleteByObjectVariants() throws {
        let f = try Fixture("object")
        let store = f.store!
        _ = try store.record(Synth.observation(ts: Synth.baseTS, host: "docs.internal",
                                               path: "/wiki/a", texts: ["内网 wiki A"]))
        _ = try store.record(Synth.observation(ts: Synth.baseTS + 1, host: "docs.internal",
                                               path: "/wiki/b", texts: ["内网 wiki B"]))
        _ = try store.record(Synth.observation(ts: Synth.baseTS + 2, host: "example.com",
                                               path: "/x", texts: ["外网 X"]))
        _ = try store.record(Synth.observation(ts: Synth.baseTS + 3, host: nil,
                                               file: "/private/tmp/brosis-test/Documents/秘密.md",
                                               texts: ["文件正文"]))

        XCTAssertEqual(try store.deleteByObject(.host("docs.internal")).observationsAffected, 2)
        XCTAssertEqual(try store.deleteByObject(.filePath("/private/tmp/brosis-test/Documents/秘密.md"))
                        .observationsAffected, 1)
        XCTAssertEqual(try store.liveObservationIDs().count, 1)
        XCTAssertEqual(try store.deleteByObject(.urlPrefix("https://example.com/"))
                        .observationsAffected, 1)
        XCTAssertEqual(try store.liveObservationIDs().count, 0)
        XCTAssertTrue(try store.integrityReport().allPassed)
    }

    func testDeleteByTimeRangeIsHalfOpen() throws {
        let f = try Fixture("range")
        let store = f.store!
        for i in 0..<5 {
            _ = try store.record(Synth.observation(ts: Synth.baseTS + Int64(i) * 1_000,
                                                   texts: ["区间 #\(i)"]))
        }
        let summary = try store.deleteByTimeRange(start: Synth.baseTS + 1_000,
                                                  end: Synth.baseTS + 3_000)
        XCTAssertEqual(summary.observationsAffected, 2, "半开区间 [start, end)")
        XCTAssertEqual(try store.liveObservationIDs().count, 3)
        XCTAssertThrowsError(try store.deleteByTimeRange(start: 100, end: 100))
    }

    func testEmptyDeleteStillWritesAudit() throws {
        let f = try Fixture("emptydel")
        let store = f.store!
        let summary = try store.deleteByApp(bundleID: "com.nonexistent.app")
        XCTAssertEqual(summary.observationsAffected, 0)
        XCTAssertEqual(try store.count(table: "deletions"), 1, "删了 0 条也要留审计行（可重放）")
    }
}
