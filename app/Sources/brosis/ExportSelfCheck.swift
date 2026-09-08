import BrosisCore
import Foundation

/// M2 d / T16：3.8 加密导出 / 导入的自检——**临时库往返冒烟**，全程无 GUI、无 TCC、不碰钥匙串。
///
/// 两个临时数据目录 + 两个 `Store`（同一个 device_id，模拟"恢复到一台新机器"）走完主路径：
/// 写一条**已脱敏**的观察 → 导出 → 归档里搜不到明文 → 导入 → 证据逐字节相同 →
/// 源库把它删掉 → 归档**不受影响**（3.8 的如实提示就是这一条）。
/// 另外三项是反例：口令弱、口令错、篡改一字节。
///
/// 由 `SelfCheck.run()` 调一次（那边只加一行），失败项数原样返回。
enum ExportSelfCheck {

    static func run() -> Int {
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("brosis-exportcheck-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // 三串运行时拼出来的东西：口令、脱敏前的密钥、检索锚点。
        // 一个字面量都不留在二进制里。
        let passphrase = ["Brosis", "SelfCheck", "2026", "#T16"].joined(separator: "-")
        let wrongPassphrase = ["Nope", "SelfCheck", "2026", "#T16"].joined(separator: "-")
        let secret = ["sk", "live", String(4_242_424_242)].joined(separator: "_")
        let canary = "导出自检标记 " + ["QX", "EXPORT", String(8_642)].joined(separator: "-")

        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            var options = StoreOptions()
            options.deviceID = "selfcheck-export"
            let source = try Store.open(directory: workspace.appendingPathComponent("A", isDirectory: true),
                                        keyProvider: try InMemoryKeyProvider.random(), options: options)
            defer { source.close() }

            // 走采集端真实路径：先 Redactor 再入库，所以库里存的已经是脱敏后的正文。
            let raw = "\(canary)：api_key = \"\(secret)\"，卡号 4111 1111 1111 1111。"
            let redacted = Redactor.redact(raw).text
            check("入库前脱敏生效（库里没有脱敏前的密钥）", !redacted.contains(secret),
                  "\(redacted.prefix(28))…")
            let written = try source.record(ObservationInput(
                ts: Recorder.milliseconds(),
                app: AppRef(bundleID: "com.brosis.selfcheck.export", name: "brosis 自检"),
                windowTitle: "导出自检窗口",
                trigger: .manual, captureMethod: .ax, completeness: .complete,
                texts: [TextFragment(text: redacted, region: "ax:AXWebArea")]))

            // ① 弱口令：在写出任何字节之前就被拒（3.8「口令强度最低要求」）。
            let weakArchive = workspace.appendingPathComponent("weak", isDirectory: true)
            var weakRejected = false
            do {
                _ = try source.exportArchive(to: weakArchive, passphrase: "aaaa")
            } catch ExportError.weakPassphrase {
                weakRejected = true
            }
            check("弱口令被拒，且一个字节都没写出去",
                  weakRejected && !FileManager.default.fileExists(atPath: weakArchive.path),
                  "门槛：≥ \(ExportKeyring.minimumLength) 字符 / ≥ \(ExportKeyring.minimumClasses) 类字符")

            // ② 导出。
            let archive = workspace.appendingPathComponent("arch", isDirectory: true)
            let outcome = try source.exportArchive(to: archive, passphrase: passphrase)
            check("导出成功（\(outcome.counts.observations) 条观察 / \(outcome.blocks) 块）",
                  outcome.counts.observations == 1 && outcome.blocks == 1,
                  "archive_bytes=\(outcome.archiveBytes) archive_id=\(String(outcome.archiveID.prefix(8)))…")

            // ③ 清单是明文、但**一个字节的正文都没有**。
            let manifest = try ExportArchive.readManifest(root: archive)
            check("manifest 不需要口令就能读，且不含密钥材料",
                  manifest.format == ExportFormat.formatName
                    && manifest.sourceDevice == "selfcheck-export"
                    && manifest.kdf == ExportKeyring.kdfAlgorithm
                    && manifest.kdfIterations == ExportKeyring.kdfIterations,
                  "\(manifest.aead) / \(manifest.kdf) ×\(manifest.kdfIterations)")
            var leaked = 0
            for probe in [secret, redacted, canary, passphrase] {
                leaked += scan(archive, for: probe)
            }
            check("归档目录里搜不到正文、脱敏前明文与口令（含阳性对照）",
                  leaked == 0 && scan(archive, for: manifest.archiveID) > 0,
                  "命中 \(leaked) 次；阳性对照 archive_id 命中 \(scan(archive, for: manifest.archiveID)) 次")

            // ④ 口令错：在碰任何一块之前就判出来，且与"文件坏了"是两种错误。
            var wrongRejected = false
            do {
                _ = try ExportArchiveReader(root: archive, passphrase: wrongPassphrase)
            } catch ExportError.wrongPassphrase {
                wrongRejected = true
            }
            check("口令错误 → 明确报口令错，不泄漏内容", wrongRejected)

            // ⑤ 往返：导进一个空库，证据逐字节相同。
            let target = try Store.open(directory: workspace.appendingPathComponent("B", isDirectory: true),
                                        keyProvider: try InMemoryKeyProvider.random(), options: options)
            defer { target.close() }
            let stats = try target.importArchive(from: archive, passphrase: passphrase)
            let restored = try target.getEvidence(ids: [written.observationID]).items.first?.text
            check("往返一致：恢复模式、id 原样、正文逐字节相同",
                  stats.mode == ExportImportMode.restore.rawValue
                    && stats.observationsInserted == 1 && restored == redacted,
                  "mode=\(stats.mode) inserted=\(stats.observationsInserted)")
            check("导入后一致性检查全过", (try target.integrityReport()).allPassed)

            // ⑥ 再导一次：归档粒度幂等，一行都不动。
            let again = try target.importArchive(from: archive, passphrase: passphrase)
            let afterSecond = try target.count(table: "observations")
            check("同一份归档再导一次不翻倍", again.alreadyImported && afterSecond == 1,
                  "already_imported=\(again.alreadyImported) observations=\(afterSecond)")

            // ⑦ 3.8 的如实提示：**删除不能覆盖已导出的副本**。
            _ = try source.deleteObservations([written.observationID])
            let gone = try source.getEvidence(ids: [written.observationID])
            let reader = try ExportArchiveReader(root: archive, passphrase: passphrase)
            let report = try reader.verify()
            check("源库删掉之后：库里查不到，归档仍然完整（删除不影响已导出的副本）",
                  gone.missing == [written.observationID] && report.counts.observations == 1,
                  "归档仍有 \(report.counts.observations) 条观察 / \(report.rows) 行")

            // ⑧ 篡改一字节：拒绝，且报的是"文件坏了"而不是"口令错"。
            let blockURL = ExportArchive.blockURL(root: archive, seq: 0)
            var bytes = [UInt8](try Data(contentsOf: blockURL))
            bytes[bytes.count / 2] ^= 0x01
            try Data(bytes).write(to: blockURL)
            var tamperSeq = -1
            do {
                _ = try ExportArchiveReader(root: archive, passphrase: passphrase).verify()
            } catch ExportError.blockChecksumMismatch(let seq) {
                tamperSeq = seq
            }
            check("篡改一字节 → 校验失败并拒绝", tamperSeq == 0, "block seq=\(tamperSeq)")

            // ⑨ D7 的通知文案里必须有"先加密导出"与"不影响已导出副本"。
            var quotaOptions = options
            quotaOptions.quotaBytes = 512
            let small = try Store.open(directory: workspace.appendingPathComponent("C", isDirectory: true),
                                       keyProvider: try InMemoryKeyProvider.random(),
                                       options: quotaOptions)
            defer { small.close() }
            for index in 0..<3 {
                _ = try small.record(ObservationInput(
                    ts: Recorder.milliseconds() + Int64(index),
                    app: AppRef(bundleID: "com.brosis.selfcheck.export", name: "brosis 自检"),
                    trigger: .manual, captureMethod: .ax, completeness: .complete,
                    texts: [TextFragment(text: String(repeating: "甲", count: 200) + " \(index)")]))
            }
            let action = try small.quotaAction()
            var blocked = false
            if case .blocked = try small.expireAfterNotice() { blocked = true }
            check("配额满：通知带「先加密导出」，且没确认前不删（D7 / 3.8）",
                  action.level == .full && blocked
                    && action.message.contains("加密导出")
                    && action.message.contains("不会影响已经导出的副本"),
                  "used=\(action.usedBytes) quota=\(action.quotaBytes) "
                  + "would_delete=\(action.wouldDeleteObservations)")
            try small.acknowledgeQuotaAction(archiveID: outcome.archiveID)
            var expired = false
            if case .expired = try small.expireAfterNotice() { expired = true }
            check("确认之后才真的按最旧先删", expired,
                  "确认只管一次，删完就失效")
        } catch {
            check("加密导出自检没有异常", false, "\(error)")
        }
        return failures
    }

    /// 在归档目录的所有文件里数一段 UTF-8 字节出现了几次（不解码，逐字节找）。
    private static func scan(_ root: URL, for probe: String) -> Int {
        let needle = [UInt8](Data(probe.utf8))
        guard !needle.isEmpty else { return 0 }
        var total = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard let data = try? Data(contentsOf: url), data.count >= needle.count else { continue }
            let bytes = [UInt8](data)
            for start in 0...(bytes.count - needle.count)
            where Array(bytes[start..<(start + needle.count)]) == needle {
                total += 1
            }
        }
        return total
    }
}
