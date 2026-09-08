import CryptoKit
import Foundation
import XCTest
@testable import BrosisCore
@testable import BrosisSync

/// D17 / 3.9 跨设备同步。
///
/// 全部用**两个临时数据目录 + 两个 Store（不同 device_id）+ 一个临时"同步目录"**模拟两台机器，
/// 不碰 iCloud、不碰钥匙串、不启动 GUI。
final class SyncTests: XCTestCase {

    // MARK: - 夹具

    /// 两台"机器" + 一个共享同步目录。
    final class Pair {
        let a: Fixture
        let b: Fixture
        let root: URL

        init(_ name: String) throws {
            a = try Fixture("\(name)-A", options: Pair.options(device: "device-A"), keySeed: 0x21)
            b = try Fixture("\(name)-B", options: Pair.options(device: "device-B"), keySeed: 0x22)
            root = Fixture.testRoot
                .appendingPathComponent("\(name)-sync-\(UUID().uuidString.prefix(8))",
                                        isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        static func options(device: String) -> StoreOptions {
            var options = StoreOptions()
            options.deviceID = device
            return options
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    /// A 上的三条观察，正文里有独一无二的稀有标记，方便断言"确实是从 A 来的那一条"。
    static let canaryOne = "季度复盘蟠桃标记 QT-77123 的结论是把采集覆盖率提到九成"
    static let canaryTwo = "第二条：与李四确认了段文件 QT-77124 的清理口径"
    static let canaryThree = "第三条：QT-77125 的墓碑要跟着同步过去"

    private func writeCanaries(_ store: Store) throws -> [Int64] {
        let base = Synth.baseTS
        var ids: [Int64] = []
        for (index, text) in [Self.canaryOne, Self.canaryTwo, Self.canaryThree].enumerated() {
            let result = try store.record(Synth.observation(
                ts: base + Int64(index) * 10_000,
                bundle: "com.apple.Safari", appName: "Safari",
                window: "复盘窗口 \(index)", host: "example.com",
                path: "/report/\(index)", texts: [text]))
            ids.append(result.observationID)
        }
        return ids
    }

    /// 建目录 + 出站；返回引擎与配对口令。
    private func startFirstDevice(_ pair: Pair) throws -> (engine: SyncEngine, passphrase: String) {
        let opened = try SyncEngine.openOrCreate(store: pair.a.store, root: pair.root)
        XCTAssertTrue(opened.created)
        let passphrase = try XCTUnwrap(opened.generatedPassphrase)
        return (opened.engine, passphrase)
    }

    // MARK: - 1. A 写 → 出站 → B 入站 → B 查得到

    func testRoundTripAToB() throws {
        let pair = try Pair("sync-roundtrip")
        _ = try writeCanaries(pair.a.store)

        let (engineA, passphrase) = try startFirstDevice(pair)
        let exported = try engineA.exportOnce()
        XCTAssertEqual(exported.segments, 1)
        XCTAssertEqual(exported.observations, 3)
        XCTAssertEqual(exported.texts, 3)
        XCTAssertEqual(exported.occurrences, 3)
        XCTAssertGreaterThan(exported.fileBytes, 0)

        // 段文件里不能出现明文（3.9 的段文件是加密的）。
        let segmentURL = SyncFolder(root: pair.root).segmentURL(device: "device-A", seq: 1)
        let bytes = try Data(contentsOf: segmentURL)
        for canary in [Self.canaryOne, Self.canaryTwo, Self.canaryThree] {
            XCTAssertNil(bytes.range(of: Data(canary.utf8)), "段文件里出现了明文：\(canary)")
        }

        let openedB = try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                  passphrase: passphrase)
        XCTAssertFalse(openedB.created)
        XCTAssertNil(openedB.generatedPassphrase)
        let report = try openedB.engine.importOnce()
        XCTAssertTrue(report.ok, "\(report.errors)")
        XCTAssertEqual(report.segments, 1)
        XCTAssertEqual(report.stats.observationsInserted, 3)
        XCTAssertEqual(report.stats.textVersionsInserted, 3)

        // B 查得到 A 的观察与正文。
        let hits = try pair.b.store.search(q: "QT-77123")
        XCTAssertEqual(hits.hits.count, 1, "B 应该能搜到 A 的那条观察")
        let evidenceID = try XCTUnwrap(hits.hits.first?.evidenceID)
        let evidence = try pair.b.store.getEvidence(ids: [evidenceID])
        XCTAssertEqual(evidence.items.count, 1)
        XCTAssertEqual(evidence.items.first?.text, Self.canaryOne, "正文必须逐字节一致")
        XCTAssertEqual(evidence.items.first?.appBundleID, "com.apple.Safari")
        XCTAssertEqual(evidence.items.first?.host, "example.com")

        // 来源可追溯：本机 id ≠ 源 id，但 (origin_device, origin_id) 指得回去。
        let origin = try XCTUnwrap(pair.b.store.syncOrigin(observationID: evidenceID))
        XCTAssertEqual(origin.device, "device-A")
        let counts = try pair.b.store.syncObservationCounts()
        XCTAssertEqual(counts.local, 0)
        XCTAssertEqual(counts.imported, 3)

        // 一致性检查照样干净（13 项悬空引用 + 三项内建）。
        let integrity = try pair.b.store.integrityReport()
        XCTAssertTrue(integrity.allPassed, "\(integrity)")
    }

    // MARK: - 2. 墓碑传播：B 删除 → A 导入后 search / get_evidence 不再返回

    func testTombstonePropagation() throws {
        let pair = try Pair("sync-tombstone")
        _ = try writeCanaries(pair.a.store)
        let (engineA, passphrase) = try startFirstDevice(pair)
        _ = try engineA.exportOnce()
        let engineB = try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                  passphrase: passphrase).engine
        _ = try engineB.importOnce()

        // B 上删掉那条 QT-77123（它在 B 上是导入来的副本，来源是 device-A）。
        let hitB = try XCTUnwrap(pair.b.store.search(q: "QT-77123").hits.first)
        let summary = try pair.b.store.deleteObservations([hitB.evidenceID])
        XCTAssertEqual(summary.observationsAffected, 1)
        XCTAssertEqual(try pair.b.store.search(q: "QT-77123").hits.count, 0)

        // B 出站 → A 入站。
        _ = try engineB.exportOnce()
        let reportA = try engineA.importOnce()
        XCTAssertTrue(reportA.ok, "\(reportA.errors)")
        XCTAssertEqual(reportA.stats.tombstonesApplied, 1)
        XCTAssertEqual(reportA.stats.observationsTombstoned, 1)

        // A 上四个入口都不再返回它（3.8 的验收口径）。
        XCTAssertEqual(try pair.a.store.search(q: "QT-77123").hits.count, 0, "search 仍然返回")
        let evidence = try pair.a.store.getEvidence(ids: [1])
        XCTAssertTrue(evidence.items.isEmpty, "get_evidence 仍然返回")
        XCTAssertEqual(evidence.missing, [1])
        XCTAssertNil(try pair.a.store.evidenceText(observationID: 1))
        // 另外两条不受影响。
        XCTAssertEqual(try pair.a.store.search(q: "QT-77124").hits.count, 1)

        // 不来回转发：A 应用完这条墓碑之后，不会把它当成"本机的删除"再发回 B。
        let stateA = try pair.a.store.syncState()
        XCTAssertEqual(stateA.pendingTombstones, 0, "导入的墓碑不该进本机的出站集合")
        let integrity = try pair.a.store.integrityReport()
        XCTAssertTrue(integrity.allPassed, "\(integrity)")
    }

    // MARK: - 3. 乱序到达 / 缺段停止

    func testMissingSegmentStopsImport() throws {
        let pair = try Pair("sync-missing")
        let (engineA, passphrase) = try startFirstDevice(pair)
        // 三批 → 三个段。
        for batch in 0..<3 {
            _ = try pair.a.store.record(Synth.observation(
                ts: Synth.baseTS + Int64(batch) * 60_000,
                window: "批次 \(batch)", texts: ["第 \(batch) 批：QT-8\(batch)0000 的内容"]))
            _ = try engineA.exportOnce()
        }
        let folder = SyncFolder(root: pair.root)
        XCTAssertEqual(folder.segmentSequences(device: "device-A"), [1, 2, 3])

        // 把第 2 段挪走：模拟"第 3 段先到、第 2 段还在路上"。
        let second = folder.segmentURL(device: "device-A", seq: 2)
        let parked = pair.root.appendingPathComponent("parked-2.bin", isDirectory: false)
        try FileManager.default.moveItem(at: second, to: parked)

        let engineB = try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                  passphrase: passphrase).engine
        let first = try engineB.importOnce()
        XCTAssertFalse(first.ok, "缺段必须报错")
        XCTAssertEqual(first.segments, 1, "只应该导入第 1 段")
        XCTAssertTrue(first.errors.joined().contains("缺第 2 段"), "\(first.errors)")
        XCTAssertEqual(try pair.b.store.syncPeers().first?.importedSeq, 1)
        XCTAssertEqual(try pair.b.store.syncObservationCounts().imported, 1,
                       "第 3 段绝不能被跳过导入")

        // 第 2 段到了：接着往下导，顺序不乱。
        try FileManager.default.moveItem(at: parked, to: second)
        let second2 = try engineB.importOnce()
        XCTAssertTrue(second2.ok, "\(second2.errors)")
        XCTAssertEqual(second2.segments, 2)
        XCTAssertEqual(try pair.b.store.syncPeers().first?.importedSeq, 3)
        XCTAssertEqual(try pair.b.store.syncObservationCounts().imported, 3)
        // 顺序正确：三条都在，且各自的来源 id 对得上。
        for batch in 0..<3 {
            XCTAssertEqual(try pair.b.store.search(q: "QT-8\(batch)0000").hits.count, 1)
        }
    }

    // MARK: - 4. 篡改一字节：校验失败 / 解密失败，都停止

    func testTamperedSegmentStops() throws {
        let pair = try Pair("sync-tamper")
        _ = try writeCanaries(pair.a.store)
        let (engineA, passphrase) = try startFirstDevice(pair)
        _ = try engineA.exportOnce()

        let folder = SyncFolder(root: pair.root)
        let url = folder.segmentURL(device: "device-A", seq: 1)
        var bytes = try Data(contentsOf: url)

        // ① 改密文里的一个字节 → 校验和不符（文件坏了）。
        let last = bytes.count - 1
        bytes[last] ^= 0x01
        try bytes.write(to: url)
        let engineB = try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                  passphrase: passphrase).engine
        let report = try engineB.importOnce()
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.errors.joined().contains("校验和不符"), "\(report.errors)")
        XCTAssertEqual(try pair.b.store.syncObservationCounts().imported, 0)

        // ② 改段头里的一个字节（长度不变）→ 校验和照样过（它只覆盖密文），但 AAD 变了 → 解密失败。
        bytes[last] ^= 0x01                                  // 先把密文改回去
        let headerRange = try XCTUnwrap(bytes.range(of: Data("\"createdAt\":".utf8)))
        let digitIndex = headerRange.upperBound + 3
        bytes[digitIndex] = bytes[digitIndex] == UInt8(ascii: "7")
            ? UInt8(ascii: "8") : UInt8(ascii: "7")
        try bytes.write(to: url)
        let report2 = try engineB.importOnce()
        XCTAssertFalse(report2.ok)
        XCTAssertTrue(report2.errors.joined().contains("解密失败"), "\(report2.errors)")
        XCTAssertEqual(try pair.b.store.syncObservationCounts().imported, 0)
    }

    // MARK: - 5. 重放幂等

    func testReplayIsIdempotent() throws {
        let pair = try Pair("sync-replay")
        _ = try writeCanaries(pair.a.store)
        let (engineA, passphrase) = try startFirstDevice(pair)
        _ = try engineA.exportOnce()
        let engineB = try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                  passphrase: passphrase).engine
        _ = try engineB.importOnce()
        let before = try pair.b.store.stats()

        // 直接把同一个段再喂一遍（跳过序号检查，模拟"出站时崩溃导致同一批记录换个序号又发一次"）。
        let folder = SyncFolder(root: pair.root)
        let data = try Data(contentsOf: folder.segmentURL(device: "device-A", seq: 1))
        let key = SymmetricKey(data: try XCTUnwrap(pair.b.store.syncKeyMaterial()))
        let segment = try XCTUnwrap(SyncSegmentFile.open(data, key: key).segment)
        let stats = try pair.b.store.syncImport(segment, enforceOrder: false)
        XCTAssertEqual(stats.observationsInserted, 0)
        XCTAssertEqual(stats.observationsSkipped, 3)

        let after = try pair.b.store.stats()
        XCTAssertEqual(before.observations, after.observations)
        XCTAssertEqual(before.textVersions, after.textVersions)
        XCTAssertEqual(before.occurrences, after.occurrences)
        XCTAssertEqual(before.ftsRows, after.ftsRows)
        XCTAssertEqual(try pair.b.store.search(q: "QT-77123").hits.count, 1, "不该出现重复命中")

        // 墓碑同样幂等。
        _ = try pair.b.store.deleteObservations([try XCTUnwrap(
            pair.b.store.search(q: "QT-77123").hits.first).evidenceID])
        _ = try engineB.exportOnce()
        _ = try engineA.importOnce()
        let again = try pair.a.store.syncImport(
            try XCTUnwrap(SyncSegmentFile.open(
                try Data(contentsOf: folder.segmentURL(device: "device-B", seq: 1)),
                key: SymmetricKey(data: try XCTUnwrap(pair.a.store.syncKeyMaterial()))).segment),
            enforceOrder: false)
        XCTAssertEqual(again.tombstonesApplied, 0)
        XCTAssertEqual(again.tombstonesSkipped, 1)
    }

    // MARK: - 6. 口令错误不加入

    func testWrongPassphraseIsRejected() throws {
        let pair = try Pair("sync-passphrase")
        let (_, passphrase) = try startFirstDevice(pair)
        let wrong = SyncKeyring.formatted(String(
            try SyncKeyring.normalize(passphrase: passphrase).reversed()))
        XCTAssertNotEqual(wrong, passphrase)
        XCTAssertThrowsError(try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                         passphrase: wrong)) { error in
            guard case SyncError.wrongPassphrase = error else {
                return XCTFail("应当是 wrongPassphrase，实际是 \(error)")
            }
        }
        XCTAssertNil(try pair.b.store.syncKeyMaterial(), "口令错就不该在本机留下同步密钥")
        // 没给口令也不行。
        XCTAssertThrowsError(try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root)) { error in
            guard case SyncError.keyRequired = error else {
                return XCTFail("应当是 keyRequired，实际是 \(error)")
            }
        }
        // 字符集 / 长度不合法直接判非法，不去做 60 万次 PBKDF2。
        XCTAssertThrowsError(try SyncKeyring.normalize(passphrase: "ABC")) { error in
            guard case SyncError.invalidPassphrase = error else {
                return XCTFail("应当是 invalidPassphrase，实际是 \(error)")
            }
        }
        XCTAssertThrowsError(try SyncKeyring.normalize(passphrase: "AAAA-BBBB-CCCC-DDDD-EEEE-0000")) { _ in }
        // 正确口令：大小写与分隔符都无所谓。
        let messy = " " + passphrase.lowercased().replacingOccurrences(of: "-", with: " ") + " "
        XCTAssertEqual(try SyncKeyring.normalize(passphrase: messy),
                       try SyncKeyring.normalize(passphrase: passphrase))
    }

    // MARK: - 7. ack 与清理

    func testAckAndCleanup() throws {
        let pair = try Pair("sync-ack")
        _ = try writeCanaries(pair.a.store)
        let (engineA, passphrase) = try startFirstDevice(pair)
        _ = try engineA.exportOnce()
        let folder = SyncFolder(root: pair.root)
        XCTAssertEqual(folder.segmentSequences(device: "device-A"), [1])

        // B 还没加入：一个段都不能删（没人 ack）。
        XCTAssertEqual(try engineA.cleanup().deleted, 0)
        XCTAssertEqual(folder.segmentSequences(device: "device-A"), [1])

        let engineB = try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                  passphrase: passphrase).engine
        // B 加入了但还没导：仍然不能删。
        XCTAssertEqual(try engineA.cleanup().deleted, 0)

        _ = try engineB.importOnce()
        let ack = try XCTUnwrap(folder.readAck(device: "device-B"))
        XCTAssertEqual(ack.imported["device-A"], 1)

        let cleaned = try engineA.cleanup()
        XCTAssertEqual(cleaned.deleted, 1)
        XCTAssertEqual(cleaned.watermark, 1)
        XCTAssertEqual(folder.segmentSequences(device: "device-A"), [])
        // 清理之后再同步一次不应该出错（水位线在库里，不在文件名里）。
        XCTAssertTrue(try engineB.importOnce().ok)
    }

    // MARK: - 8. 两个 manifest：冲突检测

    func testManifestConflictStops() throws {
        let pair = try Pair("sync-conflict")
        let (engineA, _) = try startFirstDevice(pair)
        // 模拟 iCloud 的冲突副本命名。
        let conflict = pair.root.appendingPathComponent("manifest 2.json", isDirectory: false)
        try Data("{}".utf8).write(to: conflict)
        XCTAssertEqual(SyncFolder(root: pair.root).manifestConflicts(), ["manifest 2.json"])
        XCTAssertThrowsError(try engineA.importOnce()) { error in
            guard case SyncError.manifestConflict(let names) = error else {
                return XCTFail("应当是 manifestConflict，实际是 \(error)")
            }
            XCTAssertEqual(names, ["manifest 2.json"])
        }
        XCTAssertThrowsError(try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                         passphrase: "AAAA-AAAA-AAAA-AAAA-AAAA-AAAA")) { error in
            guard case SyncError.manifestConflict = error else {
                return XCTFail("应当是 manifestConflict，实际是 \(error)")
            }
        }
    }

    // MARK: - 9. D16：库文件仍然不许进同步目录

    func testDatabaseStillRejectedInSyncFolder() throws {
        let pair = try Pair("sync-d16")
        // ① 数据目录本身在同步盘里 → Store.open 直接拒（M1 已有的 D16 检查）。
        let inside = pair.root.appendingPathComponent("brosis-sync/data", isDirectory: true)
        XCTAssertThrowsError(try Store.open(directory: inside,
                                            keyProvider: try InMemoryKeyProvider.random())) { error in
            guard case StoreError.directoryRejected = error else {
                return XCTFail("应当是 directoryRejected，实际是 \(error)")
            }
        }
        // ② 反方向：把同步目录设成数据目录（或它的祖先 / 子目录）→ 同步这边也拒。
        XCTAssertThrowsError(try SyncEngine.openOrCreate(store: pair.a.store,
                                                         root: pair.a.dataDirectory)) { error in
            guard case SyncError.directoryRejected = error else {
                return XCTFail("应当是 directoryRejected，实际是 \(error)")
            }
        }
        // ③ 同步目录里出现库文件 → 拒。
        try Data("not a db".utf8).write(
            to: pair.root.appendingPathComponent("brosis.db", isDirectory: false))
        XCTAssertThrowsError(try SyncEngine.openOrCreate(store: pair.a.store, root: pair.root)) { error in
            guard case SyncError.directoryRejected = error else {
                return XCTFail("应当是 directoryRejected，实际是 \(error)")
            }
        }
    }

    // MARK: - 10. 会话与台账只用本机观察

    func testSessionsIgnoreImportedObservations() throws {
        let pair = try Pair("sync-sessions")
        _ = try writeCanaries(pair.a.store)
        let (engineA, passphrase) = try startFirstDevice(pair)
        _ = try engineA.exportOnce()
        let engineB = try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                  passphrase: passphrase).engine
        _ = try engineB.importOnce()

        // B 自己什么都没记：导入 A 的三条之后，B 的会话仍然是 0 段（3.7 的时间是本机屏幕时间）。
        let built = try pair.b.store.buildSessions(force: true)
        XCTAssertEqual(built.sessionsInserted, 0, "导入的观察不该进本机会话")
        XCTAssertEqual(built.observationsScanned, 0, "导入的观察不该被会话构建扫到")
        // B 自己记一条之后才有会话。
        _ = try pair.b.store.record(Synth.observation(ts: Synth.baseTS + 500_000,
                                                      window: "B 自己的窗口",
                                                      texts: ["B 本机的正文 QT-9001"]))
        _ = try pair.b.store.record(Synth.observation(ts: Synth.baseTS + 510_000,
                                                      window: "B 自己的窗口",
                                                      texts: ["B 本机的正文 QT-9002"]))
        XCTAssertGreaterThan(try pair.b.store.buildSessions(force: true).sessionsInserted, 0)
    }

    // MARK: - 11. 段文件格式（不开库的纯单元测试）

    func testSegmentFileFormat() throws {
        let key = SyncKeyring.generateSyncKey()
        let segment = SyncSegment(
            device: "device-X", seq: 42, createdAt: 1_757_000_000_000,
            texts: [SyncTextRecord(sha: String(repeating: "ab", count: 32),
                                   text: "全角标点、ＡＢＣ 与换行\n都要原样过去", len: 51,
                                   at: 1_757_000_000_000)],
            observations: [SyncObservationRecord(
                id: 7, ts: 1_757_000_000_001, display: 1, bundle: "com.apple.Safari",
                appName: "Safari", title: "标题", path: nil, trigger: "timer", method: "ax",
                completeness: "complete", state: "ok",
                texts: [SyncOccurrenceRecord(sha: String(repeating: "ab", count: 32), ord: 0,
                                             region: "ax:AXWebArea", conf: 0.875, note: "n=2")])],
            tombstones: [SyncTombstoneRecord(
                id: 3, kind: "range", appliedAt: 1_757_000_000_002, params: "{\"start\":1}",
                targets: [SyncTombstoneTarget.compress(device: "device-Y", ids: [1, 2, 3, 7, 8])])],
            lastObservationID: 7, lastDeletionID: 3)

        let sealed = try SyncSegmentFile.seal(segment, key: key)
        let opened = try SyncSegmentFile.open(sealed, key: key)
        XCTAssertEqual(opened.header.device, "device-X")
        XCTAssertEqual(opened.header.seq, 42)
        XCTAssertEqual(opened.header.plainBytes, try SyncSegmentFile.encodeLines(segment).count)
        XCTAssertEqual(opened.segment, segment, "载荷必须原样往返")

        // 区间压缩：[1,2,3,7,8] → [[1,3],[7,8]]
        XCTAssertEqual(segment.tombstones[0].targets[0].ranges, [[1, 3], [7, 8]])
        XCTAssertEqual(segment.tombstones[0].targets[0].ids, [1, 2, 3, 7, 8])

        // 换一把密钥解不开。
        XCTAssertThrowsError(try SyncSegmentFile.open(sealed, key: SyncKeyring.generateSyncKey())) { error in
            guard case SyncError.decryptFailed = error else {
                return XCTFail("应当是 decryptFailed，实际是 \(error)")
            }
        }
        // 不给密钥只读段头（状态显示用），不解密。
        XCTAssertNil(try SyncSegmentFile.open(sealed, key: nil).segment)
        // 文件名与序号。
        XCTAssertEqual(SyncSegmentFile.fileName(seq: 42), "000000000042.seg")
        XCTAssertEqual(SyncSegmentFile.sequence(fromFileName: "000000000042.seg"), 42)
        XCTAssertNil(SyncSegmentFile.sequence(fromFileName: "manifest.json"))
    }

    // MARK: - 12. keyring：包裹 / 解包 / 口令熵

    func testKeyringWrapUnwrap() throws {
        let key = SyncKeyring.generateSyncKey()
        let passphrase = try SyncKeyring.generatePassphrase()
        XCTAssertEqual(passphrase.count, 24)
        XCTAssertTrue(passphrase.allSatisfy { SyncKeyring.alphabet.contains($0) })
        XCTAssertEqual(SyncKeyring.formatted(passphrase).count, 24 + 5)

        let wrapped = try SyncKeyring.wrap(syncKey: key, passphrase: passphrase, device: "device-A")
        XCTAssertEqual(wrapped.iterations, SyncKeyring.kdfIterations)
        XCTAssertEqual(wrapped.salt.count, SyncKeyring.saltBytes)
        // 包裹里不能出现密钥本身。
        let raw = key.withUnsafeBytes { Data($0) }
        XCTAssertNil(wrapped.wrapped.range(of: raw))

        let unwrapped = try SyncKeyring.unwrap(wrapped, passphrase: passphrase)
        XCTAssertEqual(SyncKeyring.keyID(unwrapped), SyncKeyring.keyID(key))
        XCTAssertEqual(unwrapped.withUnsafeBytes { Data($0) }, raw)

        // 改设备名（= 改 AAD）就解不开：把 A 的包裹改名成 B 的没有用。
        var moved = wrapped
        moved.device = "device-B"
        XCTAssertThrowsError(try SyncKeyring.unwrap(moved, passphrase: passphrase)) { error in
            guard case SyncError.wrongPassphrase = error else {
                return XCTFail("应当是 wrongPassphrase，实际是 \(error)")
            }
        }
        // 两次包裹用不同的盐 → 密文不同（不能从密文相同推出口令相同）。
        let again = try SyncKeyring.wrap(syncKey: key, passphrase: passphrase, device: "device-A")
        XCTAssertNotEqual(again.salt, wrapped.salt)
        XCTAssertNotEqual(again.wrapped, wrapped.wrapped)
    }

    // MARK: - 13. 占位符文件名还原

    func testPlaceholderNames() {
        XCTAssertEqual(SyncFolder.realName(of: ".000000000003.seg.icloud"), "000000000003.seg")
        XCTAssertEqual(SyncFolder.realName(of: "000000000003.seg"), "000000000003.seg")
        XCTAssertTrue(SyncFolder.isPlaceholder(".000000000003.seg.icloud"))
        XCTAssertFalse(SyncFolder.isPlaceholder("000000000003.seg"))
    }

    // MARK: - 14. 按应用整批删除：目标压成区间，对端按区间落到自己的副本上

    func testBulkTombstoneByAppUsesRanges() throws {
        let pair = try Pair("sync-bulk")
        // A 上两组：五条飞书、两条 Safari。
        for index in 0..<5 {
            _ = try pair.a.store.record(Synth.observation(
                ts: Synth.baseTS + Int64(index) * 1_000,
                bundle: "com.electron.lark", appName: "飞书", window: "会话 \(index)",
                host: nil, texts: ["飞书第 \(index) 条 QT-L\(index)0000"]))
        }
        for index in 0..<2 {
            _ = try pair.a.store.record(Synth.observation(
                ts: Synth.baseTS + 10_000 + Int64(index) * 1_000,
                window: "Safari \(index)", texts: ["Safari 第 \(index) 条 QT-S\(index)0000"]))
        }
        let (engineA, passphrase) = try startFirstDevice(pair)
        _ = try engineA.exportOnce()
        let engineB = try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                  passphrase: passphrase).engine
        _ = try engineB.importOnce()
        XCTAssertEqual(try pair.b.store.syncObservationCounts().imported, 7)

        // B 上按应用整批删：五条飞书。目标应当被压成一个区间（源设备 A 的 id 1…5 是连续的）。
        let summary = try pair.b.store.deleteByApp(bundleID: "com.electron.lark")
        XCTAssertEqual(summary.observationsAffected, 5)
        let targets = try pair.b.store.withLock { conn in
            try conn.scalarText("SELECT targets FROM deletions WHERE device_id = ? AND id = ?;",
                                [.text("device-B"), .int(summary.deletionID)])
        }
        let decoded = Store.decodeTargets(targets)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.device, "device-A")
        XCTAssertEqual(decoded.first?.ranges, [[1, 5]], "连续 id 应当压成一个区间")

        // A 导入这条墓碑：五条飞书都消失，两条 Safari 不受影响。
        _ = try engineB.exportOnce()
        let report = try engineA.importOnce()
        XCTAssertTrue(report.ok, "\(report.errors)")
        XCTAssertEqual(report.stats.observationsTombstoned, 5)
        for index in 0..<5 {
            XCTAssertEqual(try pair.a.store.search(q: "QT-L\(index)0000").hits.count, 0)
        }
        for index in 0..<2 {
            XCTAssertEqual(try pair.a.store.search(q: "QT-S\(index)0000").hits.count, 1)
        }
        XCTAssertTrue(try pair.a.store.integrityReport().allPassed)
    }

    // MARK: - 14. 双向：两台机器各写各的，互相都看得到

    func testBidirectional() throws {
        let pair = try Pair("sync-bidirectional")
        _ = try pair.a.store.record(Synth.observation(
            ts: Synth.baseTS, window: "A 的窗口", texts: ["A 机器的内容 QT-A001"]))
        _ = try pair.b.store.record(Synth.observation(
            ts: Synth.baseTS + 1_000, window: "B 的窗口", texts: ["B 机器的内容 QT-B001"]))

        let (engineA, passphrase) = try startFirstDevice(pair)
        let engineB = try SyncEngine.openOrCreate(store: pair.b.store, root: pair.root,
                                                  passphrase: passphrase).engine
        _ = try engineA.runOnce()
        _ = try engineB.runOnce()
        _ = try engineA.runOnce()

        XCTAssertEqual(try pair.a.store.search(q: "QT-B001").hits.count, 1, "A 应该看得到 B 的内容")
        XCTAssertEqual(try pair.b.store.search(q: "QT-A001").hits.count, 1, "B 应该看得到 A 的内容")
        // 两边的本机 id 不同，但 (origin_device, origin_id) 都指得回去。
        let onA = try XCTUnwrap(pair.a.store.search(q: "QT-B001").hits.first).evidenceID
        XCTAssertEqual(try pair.a.store.syncOrigin(observationID: onA)?.device, "device-B")
        let onB = try XCTUnwrap(pair.b.store.search(q: "QT-A001").hits.first).evidenceID
        XCTAssertEqual(try pair.b.store.syncOrigin(observationID: onB)?.device, "device-A")

        // 状态显示：各自看到对方，且没有待导入。
        let status = try engineA.status()
        XCTAssertEqual(status.peers, ["device-B"])
        XCTAssertEqual(status.pendingImports["device-B"], 0)
        XCTAssertEqual(status.state.pendingObservations, 0)
        XCTAssertFalse(status.keyID.isEmpty)
    }
}
