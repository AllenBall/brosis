import CryptoKit
import Foundation
import XCTest
@testable import BrosisCore

/// M2 d / T16：3.8 的加密导出与导入。
///
/// 覆盖八件事：往返一致（含墓碑与台账）、合并幂等、口令强度、口令错、块与清单两种篡改、
/// 范围过滤、脱敏正文原样往返、D7 的配额通知联动。
///
/// 全程 `InMemoryKeyProvider`，不碰钥匙串、不弹授权；归档目录在 `Fixture` 的临时目录下。
final class ExportTests: XCTestCase {

    /// 口令**运行时拼接**：不让形如口令的字符串以字面量形式留在二进制里。
    private var passphrase: String { ["Brosis", "Export", "2026", "#T16"].joined(separator: "-") }
    private var otherPassphrase: String { ["Nope", "Wrong", "2026", "#T16"].joined(separator: "-") }

    // MARK: - 夹具

    /// 建一个带内容的源库：3 个应用 × 若干观察，其中一段正文被复用（验证 sha 复用），
    /// 外加一次用户删除（留墓碑）、一次会话构建与一张日台账。
    private func makeSource(_ name: String, deviceID: String = "export-source")
        throws -> (fixture: Fixture, canary: String, deletedIDs: [Int64]) {
        var options = StoreOptions()
        options.deviceID = deviceID
        let fixture = try Fixture(name, options: options)
        fixture.store.retrieval.timeZone = TimeZone(identifier: "UTC")!

        // 运行时拼出来的稀有串：既当检索的锚点，也当"归档里不该出现明文"的金丝雀。
        let canary = "导出金丝雀 " + ["QX", "ARCH", String(7_331)].joined(separator: "-")
        let base = Synth.baseTS
        var inputs: [ObservationInput] = []
        for index in 0..<24 {
            let bundle = ["com.apple.Safari", "com.electron.lark", "com.apple.dt.Xcode"][index % 3]
            let shared = "共享正文段 \(index % 4)：知识图谱与全文检索。"
            var texts = [shared]
            // 放在第 0 条（Safari）：下面那次用户删除挑的是 Xcode 的前两条，
            // 金丝雀不能正好被删掉，否则"导入后还搜得到"就验不出来了。
            if index == 0 { texts.append(canary) }
            inputs.append(Synth.observation(
                ts: base + Int64(index) * 60_000,
                bundle: bundle, appName: bundle, window: "窗口 \(index % 3)",
                host: "example.com", path: "/doc/\(index % 5)",
                texts: texts))
        }
        _ = try fixture.store.record(batch: inputs)

        // 一次用户删除：留墓碑 + 审计行（3.8）。
        let victims = try fixture.store.liveObservationIDs(app: "com.apple.dt.Xcode").prefix(2)
        _ = try fixture.store.deleteObservations(Array(victims))

        _ = try fixture.store.buildSessions()
        _ = try fixture.store.getDayLedger(date: dayString(base))
        return (fixture, canary, Array(victims))
    }

    private func dayString(_ ts: Int64) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day],
                                            from: Date(timeIntervalSince1970: Double(ts) / 1000))
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func archiveURL(_ fixture: Fixture, _ name: String) -> URL {
        fixture.root.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - 1. 往返：导出 → 空库导入 → 逐项相同

    func testRoundTripIntoEmptyDatabase() throws {
        let source = try makeSource("export-roundtrip")
        let store = source.fixture.store!
        let archive = archiveURL(source.fixture, "arch")

        let outcome = try store.exportArchive(to: archive, passphrase: passphrase)
        XCTAssertGreaterThan(outcome.counts.observations, 0)
        XCTAssertEqual(outcome.counts.observations, try store.count(table: "observations"))
        XCTAssertEqual(outcome.counts.tombstonedObservations, source.deletedIDs.count)
        XCTAssertEqual(outcome.counts.deletions, try store.count(table: "deletions"))

        // 目标库用同一个 device_id 建（`brosis-store import` 会自动这么做）。
        var options = StoreOptions()
        options.deviceID = "export-source"
        let target = try Fixture("export-roundtrip-target", options: options)
        target.store.retrieval.timeZone = TimeZone(identifier: "UTC")!
        let stats = try target.store.importArchive(from: archive, passphrase: passphrase)
        XCTAssertEqual(stats.mode, ExportImportMode.restore.rawValue)
        XCTAssertFalse(stats.alreadyImported)
        XCTAssertEqual(stats.observationsInserted, outcome.counts.observations)

        // 行数逐表相同
        for table in ["observations", "text_versions", "occurrences", "deletions",
                      "sessions", "ledgers"] {
            XCTAssertEqual(try target.store.count(table: table), try store.count(table: table),
                           "\(table) 行数不同")
        }
        XCTAssertEqual(try target.store.ftsRowCount(), try store.ftsRowCount())

        // search 逐项相同（含 id）。查询词用金丝雀里的中文片段：D22 的 bigram 从 2 字起才有 token，
        // 整条带空格与连字符的串会被切成一串短片段，不是这条用例要验的东西。
        let before = try store.search(q: "金丝雀", limit: 20)
        let after = try target.store.search(q: "金丝雀", limit: 20)
        XCTAssertEqual(before.hits.map(\.evidenceID), after.hits.map(\.evidenceID))
        XCTAssertEqual(before.hits.map(\.summary), after.hits.map(\.summary))
        XCTAssertFalse(after.hits.isEmpty)

        // get_evidence 逐字节相同
        // grant 传 nil = 本地可信调用方，不做时间窗与白名单裁剪（合成数据的时刻在 30 天之外，
        // 带 grant 会被时间窗全部挡掉，那验的就不是导入导出了）。
        let ids = try store.liveObservationIDs()
        let evidenceBefore = try store.getEvidence(ids: ids)
        let evidenceAfter = try target.store.getEvidence(ids: ids)
        XCTAssertEqual(evidenceBefore.items.map(\.text), evidenceAfter.items.map(\.text))
        XCTAssertEqual(evidenceBefore.items.map(\.evidenceID), evidenceAfter.items.map(\.evidenceID))

        // 墓碑：删掉的 id 在两边都查不到内容（3.8 的验收口径）
        let missingBefore = try store.getEvidence(ids: source.deletedIDs)
        let missingAfter = try target.store.getEvidence(ids: source.deletedIDs)
        XCTAssertEqual(missingBefore.missing.sorted(), source.deletedIDs.sorted())
        XCTAssertEqual(missingAfter.missing.sorted(), source.deletedIDs.sorted())

        // 日台账逐项相同（不重算，直接读导进来的那一行）
        let day = dayString(Synth.baseTS)
        let ledgerBefore = try store.getDayLedger(date: day)
        let ledgerAfter = try target.store.getDayLedger(date: day)
        XCTAssertEqual(encode(ledgerBefore), encode(ledgerAfter))

        // 删除审计逐行相同
        XCTAssertEqual(try store.deletionRows().map { "\($0.id)|\($0.kind)|\($0.reason)" },
                       try target.store.deletionRows().map { "\($0.id)|\($0.kind)|\($0.reason)" })

        // 会话的两个水位线也要跟着恢复。`sessionRows` 的区间查询要用
        // `meta.sessions_max_duration_ms` 给 `start` 补下界（E7 §10.3）；恢复出来的库只有
        // `sessions` 表、没有这个键的话下界退化成 0，"起点在窗口之前、终点落在窗口里"的那条会话
        // 就查不到——1 个月合成库上实测是日台账的 sessions 比源库少 1（30 天里 24 天都少）。
        for key in ["sessions_max_duration_ms", "sessions_watermark_ts"] {
            let before = try store.withLock { try $0.scalarText(
                "SELECT value FROM meta WHERE key = ?;", [.text(key)]) }
            let after = try target.store.withLock { try $0.scalarText(
                "SELECT value FROM meta WHERE key = ?;", [.text(key)]) }
            XCTAssertNotNil(after, "\(key) 没恢复")
            XCTAssertEqual(before, after, "\(key) 与源库不一致")
        }
        // 窗口起点故意落在某条会话中间：下界不对就会少一条。
        for offset in [3, 5, 9, 17] {
            let windowStart = Synth.baseTS + Int64(offset) * 60_000 + 1
            let windowEnd = Synth.baseTS + 24 * 60_000
            let idsBefore = try store.sessions(from: windowStart, to: windowEnd).map(\.id)
            let idsAfter = try target.store.sessions(from: windowStart, to: windowEnd).map(\.id)
            XCTAssertEqual(idsBefore, idsAfter, "窗口 +\(offset) min 的会话集合不同")
            XCTAssertFalse(idsAfter.isEmpty)
        }

        // 一致性
        XCTAssertTrue(try target.store.integrityReport().allPassed)
    }

    private func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
    }

    // MARK: - 2. 合并：幂等 + 增量 + 墓碑级联

    func testMergeIsIdempotentAndCascadesTombstones() throws {
        let source = try makeSource("export-merge")
        let store = source.fixture.store!
        let first = archiveURL(source.fixture, "arch-1")
        _ = try store.exportArchive(to: first, passphrase: passphrase)

        var options = StoreOptions()
        options.deviceID = "export-source"
        let target = try Fixture("export-merge-target", options: options)
        target.store.retrieval.timeZone = TimeZone(identifier: "UTC")!
        _ = try target.store.importArchive(from: first, passphrase: passphrase)
        let baseline = try target.store.count(table: "observations")

        // ① 同一份归档再导一次：归档粒度幂等，一行都不动。
        let again = try target.store.importArchive(from: first, passphrase: passphrase)
        XCTAssertTrue(again.alreadyImported)
        XCTAssertEqual(again.observationsInserted, 0)
        XCTAssertEqual(try target.store.count(table: "observations"), baseline)

        // ② 源库继续写 2 条、再删 2 条，导第二份归档 → 合并进去。
        let extra = (0..<2).map { index in
            Synth.observation(ts: Synth.baseTS + Int64(200 + index) * 60_000,
                              bundle: "com.apple.Safari", appName: "Safari",
                              texts: ["增量正文 \(index)：配额过期与删除级联。"])
        }
        _ = try store.record(batch: extra)
        let victims = Array(try store.liveObservationIDs(app: "com.electron.lark").prefix(2))
        XCTAssertEqual(victims.count, 2)
        _ = try store.deleteObservations(victims)

        let second = archiveURL(source.fixture, "arch-2")
        _ = try store.exportArchive(to: second, passphrase: passphrase)
        let merged = try target.store.importArchive(from: second, passphrase: passphrase)
        XCTAssertEqual(merged.mode, ExportImportMode.merge.rawValue)
        XCTAssertFalse(merged.alreadyImported)
        // 只多了那 2 条；老记录全部按 (device, id) 判定跳过。
        XCTAssertEqual(merged.observationsInserted, 2)
        XCTAssertEqual(merged.observationsSkipped, baseline)
        XCTAssertEqual(try target.store.count(table: "observations"), baseline + 2)

        // ③ 墓碑级联：第二份归档带来的用户删除在目标库里真的执行了。
        XCTAssertEqual(merged.tombstonesCascaded, 2)
        XCTAssertEqual(try target.store.getEvidence(ids: victims).missing.sorted(),
                       victims.sorted())
        XCTAssertTrue(try target.store.integrityReport().allPassed)

        // ④ 第二份归档再导一次：仍然幂等。
        let third = try target.store.importArchive(from: second, passphrase: passphrase)
        XCTAssertTrue(third.alreadyImported)
        XCTAssertEqual(try target.store.count(table: "observations"), baseline + 2)
    }

    // MARK: - 3. 口令：强度门槛与口令错

    func testWeakPassphraseRejectedBeforeAnyWrite() throws {
        let source = try makeSource("export-weak")
        let archive = archiveURL(source.fixture, "arch-weak")
        for weak in ["", "short", "aaaaaaaaaaaaaaaa", "1234567890123456"] {
            XCTAssertThrowsError(try source.fixture.store.exportArchive(to: archive,
                                                                       passphrase: weak)) { error in
                guard case ExportError.weakPassphrase = error else {
                    return XCTFail("期望 weakPassphrase，实得 \(error)")
                }
            }
        }
        // 一个字节都没写出去。
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        // 合格的口令能过。
        XCTAssertTrue(ExportKeyring.strength(of: passphrase).ok)
    }

    func testWrongPassphraseIsDistinguishedAndLeaksNothing() throws {
        let source = try makeSource("export-wrongpass")
        let archive = archiveURL(source.fixture, "arch")
        _ = try source.fixture.store.exportArchive(to: archive, passphrase: passphrase)

        // 不给口令也能读清单（3.8 的"能看清是哪一份"）。
        let manifest = try ExportArchive.readManifest(root: archive)
        XCTAssertEqual(manifest.format, ExportFormat.formatName)
        XCTAssertEqual(manifest.sourceDevice, "export-source")

        XCTAssertThrowsError(try ExportArchiveReader(root: archive,
                                                     passphrase: otherPassphrase)) { error in
            guard case ExportError.wrongPassphrase = error else {
                return XCTFail("期望 wrongPassphrase，实得 \(error)")
            }
        }
        var options = StoreOptions()
        options.deviceID = "export-source"
        let target = try Fixture("export-wrongpass-target", options: options)
        XCTAssertThrowsError(try target.store.importArchive(from: archive,
                                                            passphrase: otherPassphrase))
        // 口令错的那次没往库里写任何东西。
        XCTAssertEqual(try target.store.count(table: "observations"), 0)
        XCTAssertEqual(try target.store.count(table: "export_imports"), 0)
    }

    // MARK: - 4. 篡改检测：块一次、清单一次

    func testTamperedBlockIsRejected() throws {
        let source = try makeSource("export-tamper-block")
        let archive = archiveURL(source.fixture, "arch")
        let manifest = try source.fixture.store.exportArchive(to: archive, passphrase: passphrase)
        XCTAssertGreaterThan(manifest.blocks, 0)

        let blockURL = ExportArchive.blockURL(root: archive, seq: 0)
        var bytes = [UInt8](try Data(contentsOf: blockURL))
        bytes[bytes.count / 2] ^= 0x01                    // 翻一个比特
        try Data(bytes).write(to: blockURL)

        let reader = try ExportArchiveReader(root: archive, passphrase: passphrase)
        XCTAssertThrowsError(try reader.verify()) { error in
            guard case ExportError.blockChecksumMismatch(let seq) = error else {
                return XCTFail("期望 blockChecksumMismatch，实得 \(error)")
            }
            XCTAssertEqual(seq, 0)
        }

        // 把校验和一起改对（只剩 GCM tag 拦得住）→ 报的是解密失败，不是校验和。
        let fixed = try Data(contentsOf: blockURL)
        let cipher = fixed.dropFirst(ExportFormat.magic.count + 2)
        var patched = try ExportArchive.readManifest(root: archive)
        patched.blocks[0].checksum = ExportKeyring.hex(SHA256.hash(data: cipher))
        try writeManifest(patched, to: archive, resignWith: passphrase)
        let reader2 = try ExportArchiveReader(root: archive, passphrase: passphrase)
        XCTAssertThrowsError(try reader2.verify()) { error in
            guard case ExportError.blockDecryptFailed(let seq) = error else {
                return XCTFail("期望 blockDecryptFailed，实得 \(error)")
            }
            XCTAssertEqual(seq, 0)
        }
    }

    func testTamperedManifestIsRejected() throws {
        let source = try makeSource("export-tamper-manifest")
        let archive = archiveURL(source.fixture, "arch")
        _ = try source.fixture.store.exportArchive(to: archive, passphrase: passphrase)

        // ① 改计数：总校验和还对得上（它只盖块），但清单 HMAC 拦下来。
        var manifest = try ExportArchive.readManifest(root: archive)
        manifest.counts.observations -= 1
        try writeManifestRaw(manifest, to: archive)
        XCTAssertThrowsError(try ExportArchiveReader(root: archive,
                                                     passphrase: passphrase)) { error in
            guard case ExportError.manifestTampered = error else {
                return XCTFail("期望 manifestTampered，实得 \(error)")
            }
        }

        // ② 删掉一条块登记：**不需要口令**就能发现（总校验和）。
        var trimmed = try loadManifestBypassingChecks(archive)
        trimmed.counts.observations += 1                  // 还原上一步
        trimmed.blocks.removeLast()
        try writeManifestRaw(trimmed, to: archive)
        XCTAssertThrowsError(try ExportArchive.readManifest(root: archive)) { error in
            guard case ExportError.totalChecksumMismatch = error else {
                return XCTFail("期望 totalChecksumMismatch，实得 \(error)")
            }
        }

        // ③ 改归档格式版本：v1 只读 v1，更新的版本直接拒绝，不猜着读。
        var bumped = try loadManifestBypassingChecks(archive)
        bumped.blocks = manifest.blocks
        bumped.version = ExportFormat.version + 1
        try writeManifestRaw(bumped, to: archive)
        XCTAssertThrowsError(try ExportArchive.readManifest(root: archive)) { error in
            guard case ExportError.unsupportedVersion = error else {
                return XCTFail("期望 unsupportedVersion，实得 \(error)")
            }
        }
    }

    func testArchiveFromAnotherSchemaVersionIsRejected() throws {
        let source = try makeSource("export-schema")
        let archive = archiveURL(source.fixture, "arch")
        _ = try source.fixture.store.exportArchive(to: archive, passphrase: passphrase)
        var manifest = try ExportArchive.readManifest(root: archive)
        manifest.schemaVersion = Schema.version + 1
        try writeManifestRaw(manifest, to: archive)

        var options = StoreOptions()
        options.deviceID = "export-source"
        let target = try Fixture("export-schema-target", options: options)
        XCTAssertThrowsError(try target.store.importArchive(from: archive,
                                                            passphrase: passphrase)) { error in
            guard case ExportError.schemaMismatch = error else {
                return XCTFail("期望 schemaMismatch，实得 \(error)")
            }
        }
    }

    // MARK: - 5. 范围过滤

    func testTimeAndAppScopeFilters() throws {
        let source = try makeSource("export-scope")
        let store = source.fixture.store!
        let base = Synth.baseTS

        // ① 时间范围：只要前 10 分钟。
        let timeArchive = archiveURL(source.fixture, "arch-time")
        let timeOutcome = try store.exportArchive(
            to: timeArchive, passphrase: passphrase,
            request: ExportRequest(start: base, end: base + 10 * 60_000))
        let expectedInWindow = try store.withLock { conn in
            Int(try conn.scalarInt("""
                SELECT COUNT(*) FROM observations WHERE device_id = ? AND ts >= ? AND ts < ?;
                """, [.text(store.deviceID), .int(base), .int(base + 10 * 60_000)]) ?? 0)
        }
        XCTAssertEqual(timeOutcome.counts.observations, expectedInWindow)
        XCTAssertEqual(timeOutcome.counts.observations, 10)

        // ② 应用范围：只要 Safari；按 3.8 的取舍，限定应用时不带删除审计与派生结果。
        let appArchive = archiveURL(source.fixture, "arch-app")
        let appOutcome = try store.exportArchive(
            to: appArchive, passphrase: passphrase,
            request: ExportRequest(apps: ["com.apple.Safari"]))
        let expectedSafari = try store.withLock { conn in
            Int(try conn.scalarInt("""
                SELECT COUNT(*) FROM observations o JOIN apps a ON a.id = o.app_id
                 WHERE o.device_id = ? AND a.bundle_id = ?;
                """, [.text(store.deviceID), .text("com.apple.Safari")]) ?? 0)
        }
        XCTAssertEqual(appOutcome.counts.observations, expectedSafari)
        XCTAssertEqual(appOutcome.counts.deletions, 0)
        XCTAssertEqual(appOutcome.counts.sessions, 0)
        XCTAssertEqual(appOutcome.counts.ledgers, 0)
        let appManifest = try ExportArchive.readManifest(root: appArchive)
        XCTAssertEqual(appManifest.scope.apps, ["com.apple.Safari"])
        XCTAssertTrue(appManifest.notes.contains { $0.contains("限定了应用范围") })

        // 导进空库之后，里面只有 Safari 的观察。
        var options = StoreOptions()
        options.deviceID = "export-source"
        let target = try Fixture("export-scope-target", options: options)
        _ = try target.store.importArchive(from: appArchive, passphrase: passphrase)
        XCTAssertEqual(try target.store.count(table: "observations"), expectedSafari)
        let others = try target.store.liveObservationIDs(app: "com.electron.lark")
        XCTAssertTrue(others.isEmpty)
        XCTAssertTrue(try target.store.integrityReport().allPassed)
    }

    // MARK: - 6. 脱敏正文原样往返 + 归档里没有明文

    func testRedactedTextRoundTripsAndArchiveHasNoPlaintext() throws {
        var options = StoreOptions()
        options.deviceID = "export-redaction"
        let fixture = try Fixture("export-redaction", options: options)
        // 采集端在**入库前**就把密钥换成了占位符（app 的 Redactor 干的）。
        // 这里模拟它的产物：库里存的就是这一份，归档要原样搬——不二次脱敏、也不还原。
        let secret = ["sk", "live", String(4_242_424_242)].joined(separator: "_")
        let redacted = "配置里写了 api_key = \"[REDACTED:apikey]\"，其余照旧。"
        _ = try fixture.store.record(Synth.observation(ts: Synth.baseTS, texts: [redacted]))

        let archive = fixture.root.appendingPathComponent("arch", isDirectory: true)
        _ = try fixture.store.exportArchive(to: archive, passphrase: passphrase)

        // 归档里既没有脱敏前的密钥，也没有脱敏后的正文（正文是加密的）。
        for probe in [secret, redacted, "REDACTED:apikey"] {
            let hits = scanArchive(archive, for: probe)
            XCTAssertEqual(hits, 0, "归档里出现了「\(probe.prefix(12))…」\(hits) 次")
        }

        let target = try Fixture("export-redaction-target", options: options)
        _ = try target.store.importArchive(from: archive, passphrase: passphrase)
        let ids = try target.store.liveObservationIDs()
        let items = try target.store.getEvidence(ids: ids)
        XCTAssertEqual(items.items.first?.text, redacted)
        XCTAssertFalse(items.items.first?.text?.contains(secret) ?? true)
    }

    /// 在归档目录的所有文件里数一段 UTF-8 字节出现了几次（不解码，逐字节找）。
    private func scanArchive(_ root: URL, for probe: String) -> Int {
        let needle = [UInt8](Data(probe.utf8))
        guard !needle.isEmpty else { return 0 }
        var total = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            let bytes = [UInt8](data)
            guard bytes.count >= needle.count else { continue }
            for start in 0...(bytes.count - needle.count)
            where Array(bytes[start..<(start + needle.count)]) == needle {
                total += 1
            }
        }
        return total
    }

    // MARK: - 7. 多块：块边界切在正文与它的观察之间也要能导

    func testSmallBlocksSplitAcrossManyFiles() throws {
        var options = StoreOptions()
        options.deviceID = "export-blocks"
        let fixture = try Fixture("export-blocks", options: options)
        fixture.store.retrieval.timeZone = TimeZone(identifier: "UTC")!
        // 每条 4 KiB 左右的正文 × 40 条 ≈ 160 KiB 明文，配 64 KiB 一块 → 至少 3 块，
        // 块边界一定会切在"正文行"与"引用它的观察行"之间，正是要验的那一条。
        let inputs = (0..<40).map { index in
            Synth.observation(ts: Synth.baseTS + Int64(index) * 60_000,
                              texts: ["块切分用正文 \(index)：" + String(repeating: "字", count: 1_400)])
        }
        _ = try fixture.store.record(batch: inputs)

        let archive = fixture.root.appendingPathComponent("arch", isDirectory: true)
        let outcome = try fixture.store.exportArchive(
            to: archive, passphrase: passphrase,
            request: ExportRequest(blockPlainBytes: 64 * 1024, batchObservations: 3))
        let manifest = try ExportArchive.readManifest(root: archive)
        XCTAssertGreaterThanOrEqual(manifest.blocks.count, 3, "应该切成多块")
        XCTAssertEqual(manifest.blocks.count, outcome.blocks)
        for block in manifest.blocks {
            XCTAssertLessThanOrEqual(block.plainBytes, 64 * 1024 + 8 * 1024,
                                     "块 \(block.seq) 超出上限太多")
        }

        let reader = try ExportArchiveReader(root: archive, passphrase: passphrase)
        let report = try reader.verify()
        XCTAssertEqual(report.counts, outcome.counts)
        XCTAssertTrue(report.manifestMACOK)
        XCTAssertTrue(report.totalChecksumOK)

        let target = try Fixture("export-blocks-target", options: options)
        target.store.retrieval.timeZone = TimeZone(identifier: "UTC")!
        let stats = try target.store.importArchive(from: archive, passphrase: passphrase)
        XCTAssertEqual(stats.observationsInserted, 40)
        XCTAssertEqual(try target.store.count(table: "observations"),
                       try fixture.store.count(table: "observations"))
        XCTAssertEqual(try target.store.count(table: "text_versions"),
                       try fixture.store.count(table: "text_versions"))
        XCTAssertTrue(try target.store.integrityReport().allPassed)
    }

    // MARK: - 8. D7：配额通知 + "先加密导出" 入口

    func testQuotaActionNotifiesBeforeDeleting() throws {
        var options = StoreOptions()
        options.deviceID = "export-quota"
        options.quotaBytes = 4_000            // 故意设得很小，几条观察就满
        options.quotaWarnRatio = 0.8
        let fixture = try Fixture("export-quota", options: options)
        let store = fixture.store!

        // 先写到 80% 以下
        _ = try store.record(Synth.observation(ts: Synth.baseTS, texts: [String(repeating: "甲", count: 300)]))
        var action = try store.quotaAction()
        XCTAssertEqual(action.level, .ok)
        XCTAssertFalse(action.expireAllowed)

        // 写到满
        for index in 1...6 {
            _ = try store.record(Synth.observation(
                ts: Synth.baseTS + Int64(index) * 60_000,
                texts: [String(repeating: "乙", count: 300) + " \(index)"]))
        }
        action = try store.quotaAction()
        XCTAssertEqual(action.level, .full)
        XCTAssertGreaterThan(action.wouldDeleteObservations, 0)
        XCTAssertNotNil(action.suggestedExportStart)
        XCTAssertTrue(action.message.contains("加密导出"))
        XCTAssertTrue(action.message.contains("不会影响已经导出的副本"))
        XCTAssertFalse(action.expireAllowed)

        // ① 没确认就不删（3.8「删前通知」）
        switch try store.expireAfterNotice() {
        case .blocked(let blocked):
            XCTAssertEqual(blocked.level, .full)
        default:
            XCTFail("没确认通知时不应该删")
        }
        let liveBefore = try store.count(table: "observations")

        // ② 先加密导出，再拿归档 id 确认
        let archive = fixture.root.appendingPathComponent("arch", isDirectory: true)
        let outcome = try store.exportArchive(to: archive, passphrase: passphrase)
        try store.acknowledgeQuotaAction(archiveID: outcome.archiveID)
        let acknowledged = try store.quotaAction()
        XCTAssertEqual(acknowledged.acknowledgedArchiveID, outcome.archiveID)
        XCTAssertEqual(acknowledged.lastExportArchiveID, outcome.archiveID)
        XCTAssertTrue(acknowledged.expireAllowed)

        // ③ 确认之后才真的删；删完确认作废（下次满了要重新确认）
        switch try store.expireAfterNotice() {
        case .expired(_, let report):
            XCTAssertGreaterThan(report.summary?.observationsAffected ?? 0, 0)
        default:
            XCTFail("确认之后应该真的删")
        }
        XCTAssertLessThan(try store.count(table: "observations"), liveBefore)
        XCTAssertNil(try store.quotaAction().acknowledgedAt)

        // ④ 删除**不影响已经导出的副本**：归档还在，还能完整校验。
        let reader = try ExportArchiveReader(root: archive, passphrase: passphrase)
        let report = try reader.verify()
        XCTAssertEqual(report.counts.observations, outcome.counts.observations)

        // ⑤ 事件写了（内容只有数字，没有路径）
        let events = try store.runtimeEventDetails(kind: "quota_full")
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events[0].contains("would_delete="))
        let exported = try store.runtimeEventDetails(kind: "export_completed")
        XCTAssertFalse(exported.isEmpty)
        XCTAssertTrue(exported[0].contains("archive=\(outcome.archiveID)"))
        XCTAssertFalse(exported[0].contains(passphrase))
    }

    // MARK: - 9. 归档写一次不改：目标目录非空直接拒绝

    func testExportRefusesNonEmptyDirectory() throws {
        let source = try makeSource("export-nonempty")
        let archive = archiveURL(source.fixture, "arch")
        _ = try source.fixture.store.exportArchive(to: archive, passphrase: passphrase)
        XCTAssertThrowsError(try source.fixture.store.exportArchive(to: archive,
                                                                   passphrase: passphrase)) { error in
            guard case ExportError.invalidRequest = error else {
                return XCTFail("期望 invalidRequest，实得 \(error)")
            }
        }
    }

    // MARK: - 小工具

    private func writeManifestRaw(_ manifest: ExportManifest, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: ExportArchive.manifestURL(root: root))
    }

    /// 改完清单再用同一把口令重签（用来单独验证"改块 + 把校验和也改对"这条路径）。
    private func writeManifest(_ manifest: ExportManifest, to root: URL,
                               resignWith passphrase: String) throws {
        var copy = manifest
        copy.totalChecksum = ExportArchive.totalChecksum(archiveID: copy.archiveID,
                                                         blocks: copy.blocks)
        let keys = try ExportKeyring.derive(passphrase: passphrase, salt: copy.salt,
                                            iterations: copy.kdfIterations)
        copy.mac = ""
        copy.mac = try ExportKeyring.manifestMAC(copy, key: keys.manifestMAC)
        try writeManifestRaw(copy, to: root)
    }

    /// 绕过 `readManifest` 的校验直接读文件（测试里改坏之后还要接着改）。
    private func loadManifestBypassingChecks(_ root: URL) throws -> ExportManifest {
        let data = try Data(contentsOf: ExportArchive.manifestURL(root: root))
        return try JSONDecoder().decode(ExportManifest.self, from: data)
    }
}
