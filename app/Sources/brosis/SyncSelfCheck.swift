import BrosisCore
import BrosisSync
import CryptoKit
import Foundation

/// D17 / 3.9 的自检：**两个库的往返冒烟**，全程无 GUI、无 TCC、不碰钥匙串。
///
/// 用两个临时数据目录 + 两个 `Store`（不同 device_id）+ 一个临时"同步目录"模拟两台机器，
/// 走完 3.9 的主路径：建目录 → 出站 → 另一台用口令加入 → 入站 → 查得到 →
/// 删除 → 墓碑回传 → 两个入口都不再返回 → ack 后清理。
/// 另外三项是反例：口令错不加入、篡改一字节停下、段文件里没有明文。
///
/// 由 `SelfCheck.run()` 调一次（那边只加一行），失败项数原样返回。
enum SyncSelfCheck {

    static func run() -> Int {
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("brosis-synccheck-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // 运行时拼出来的稀有标记：不让这串字符以字面量形式留在二进制里。
        let canary = "同步自检标记 " + ["QT", "SELF", String(9_001)].joined(separator: "-")

        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let syncRoot = workspace.appendingPathComponent("sync", isDirectory: true)

            var optionsA = StoreOptions()
            optionsA.deviceID = "selfcheck-A"
            var optionsB = StoreOptions()
            optionsB.deviceID = "selfcheck-B"
            let storeA = try Store.open(directory: workspace.appendingPathComponent("A", isDirectory: true),
                                        keyProvider: try InMemoryKeyProvider.random(), options: optionsA)
            defer { storeA.close() }
            let storeB = try Store.open(directory: workspace.appendingPathComponent("B", isDirectory: true),
                                        keyProvider: try InMemoryKeyProvider.random(), options: optionsB)
            defer { storeB.close() }

            let written = try storeA.record(ObservationInput(
                ts: Int64(Date().timeIntervalSince1970 * 1000),
                app: AppRef(bundleID: "com.brosis.selfcheck.sync", appNameFallback: "自检"),
                windowTitle: "同步自检窗口",
                trigger: .manual, captureMethod: .ax, completeness: .complete,
                texts: [TextFragment(text: canary, region: "ax:AXWebArea")]))

            // ① 首台：建目录、生成密钥、拿到一次性配对口令。
            let openedA = try SyncEngine.openOrCreate(store: storeA, root: syncRoot)
            check("同步目录初始化：manifest + keyring + 一次性配对口令",
                  openedA.created && openedA.generatedPassphrase != nil
                    && FileManager.default.fileExists(atPath: SyncFolder(root: syncRoot).manifestURL.path),
                  "key_id \(openedA.engine.manifest.keyID)")
            let passphrase = openedA.generatedPassphrase ?? ""

            // ② 出站：段文件写出来，且里面没有明文。
            let exported = try openedA.engine.exportOnce()
            let segmentURL = SyncFolder(root: syncRoot).segmentURL(device: "selfcheck-A", seq: 1)
            let segmentBytes = (try? Data(contentsOf: segmentURL)) ?? Data()
            check("出站：1 个段文件、\(exported.observations) 条观察",
                  exported.segments == 1 && exported.observations == 1 && exported.fileBytes > 0,
                  "\(exported.fileBytes) 字节")
            check("段文件里没有明文（AES-256-GCM）",
                  !segmentBytes.isEmpty && segmentBytes.range(of: Data(canary.utf8)) == nil,
                  "扫了 \(segmentBytes.count) 字节")

            // ③ 口令错不加入（3.9）。
            let wrongPassphrase = String(passphrase.reversed())
            var rejected = false
            do {
                _ = try SyncEngine.openOrCreate(store: storeB, root: syncRoot,
                                                passphrase: wrongPassphrase)
            } catch SyncError.wrongPassphrase {
                rejected = true
            } catch {
                rejected = false
            }
            let leftoverKey = try storeB.syncKeyMaterial()
            check("口令错误不加入", rejected && leftoverKey == nil)

            // ④ 正确口令加入 + 入站 + 查得到。
            let openedB = try SyncEngine.openOrCreate(store: storeB, root: syncRoot,
                                                      passphrase: passphrase)
            let imported = try openedB.engine.importOnce()
            let hits = try storeB.search(q: canary)
            let evidence = try hits.hits.first.map { try storeB.getEvidence(ids: [$0.evidenceID]) }
            check("入站：B 导入 A 的观察并查得到、正文逐字节一致",
                  imported.ok && imported.stats.observationsInserted == 1
                    && hits.hits.count == 1 && evidence?.items.first?.text == canary,
                  imported.errors.joined(separator: "；"))
            check("入站记录带来源：(origin_device, origin_id) 指得回 A",
                  (try hits.hits.first.flatMap { try storeB.syncOrigin(observationID: $0.evidenceID) })?
                    .device == "selfcheck-A")

            // ⑤ 墓碑：B 删 → A 导入后两个入口都不再返回（3.8 的验收口径）。
            if let hit = hits.hits.first { _ = try storeB.deleteObservations([hit.evidenceID]) }
            _ = try openedB.engine.exportOnce()
            let backToA = try openedA.engine.importOnce()
            let stillFound = try storeA.search(q: canary).hits.count
            let stillText = try storeA.evidenceText(observationID: written.observationID)
            check("墓碑传播：A 上 search / get_evidence 都不再返回",
                  backToA.ok && backToA.stats.tombstonesApplied == 1
                    && stillFound == 0 && stillText == nil,
                  "tombstoned=\(backToA.stats.observationsTombstoned)")
            check("导入的墓碑不会被再转发回去",
                  (try storeA.syncState()).pendingTombstones == 0)

            // ⑥ 篡改一字节：停下，不导入。
            // A 先真的**再记一条**，否则出站集合是空的（A 应用的那条墓碑属于 B，不进 A 的出站集合），
            // 就没有新段可篡改，这一项会变成假通过。
            _ = try storeA.record(ObservationInput(
                ts: Int64(Date().timeIntervalSince1970 * 1000) + 1,
                app: AppRef(bundleID: "com.brosis.selfcheck.sync", appNameFallback: "自检"),
                windowTitle: "同步自检窗口 2",
                trigger: .manual, captureMethod: .ax, completeness: .complete,
                texts: [TextFragment(text: canary + "-二", region: "ax:AXWebArea")]))
            let secondExport = try openedA.engine.exportOnce()
            let folder = SyncFolder(root: syncRoot)
            if secondExport.segments == 1, let second = secondExport.lastSeq,
               var raw = try? Data(contentsOf: folder.segmentURL(device: "selfcheck-A", seq: second)),
               raw.count > 4 {
                let url = folder.segmentURL(device: "selfcheck-A", seq: second)
                let importedBefore = (try storeB.syncPeers().first { $0.deviceID == "selfcheck-A" })?
                    .importedSeq ?? 0
                raw[raw.count - 1] ^= 0x01
                try raw.write(to: url)
                let broken = try openedB.engine.importOnce()
                let importedAfter = (try storeB.syncPeers().first { $0.deviceID == "selfcheck-A" })?
                    .importedSeq ?? 0
                check("篡改一字节：校验失败即停，不跳过",
                      !broken.ok && broken.errors.joined().contains("校验和不符")
                        && importedAfter == importedBefore,
                      broken.errors.joined(separator: "；"))
                raw[raw.count - 1] ^= 0x01
                try raw.write(to: url)
                let repaired = try openedB.engine.importOnce()
                check("修好之后接着往下导", repaired.ok && repaired.segments == 1,
                      repaired.errors.joined(separator: "；"))
            } else {
                check("篡改一字节：校验失败即停，不跳过", false,
                      "没有可篡改的新段（导出 \(secondExport.segments) 个）")
            }

            // ⑦ ack 之后清理。
            let cleaned = try openedA.engine.cleanup()
            check("两边都 ack 的段可删", cleaned.deleted > 0,
                  "删 \(cleaned.deleted) 个，水位线 seq \(cleaned.watermark)")

            // ⑧ D16 反向：同步目录不许放库。
            var rejectedDirectory = false
            do {
                _ = try SyncEngine.openOrCreate(store: storeA, root: storeA.directory)
            } catch SyncError.directoryRejected {
                rejectedDirectory = true
            } catch {
                rejectedDirectory = false
            }
            check("D16：同步目录不能是数据目录", rejectedDirectory)

            print("      同步自检工作目录：\(workspace.path)（跑完删除）")
            print("      段文件格式：magic BRSSEG v\(SyncSegmentFile.formatVersion)、"
                + "AES-256-GCM、段头进 AAD、密文 SHA-256 校验和；"
                + "口令 \(SyncKeyring.passphraseGroups)×\(SyncKeyring.passphraseGroupLength) 字符 / "
                + "\(SyncKeyring.alphabet.count) 字母表 = "
                + "\(SyncKeyring.passphraseGroups * SyncKeyring.passphraseGroupLength * 5) bit；"
                + "KDF \(SyncKeyring.kdfAlgorithm) × \(SyncKeyring.kdfIterations)")
            print("      默认同步目录：iCloud Drive/brosis-sync/"
                + "（UserDefaults 键 \(SyncController.Key.directory)，"
                + "开关 \(SyncController.Key.enabled)，"
                + "间隔 \(Int(SyncController.defaultIntervalSeconds)) s / "
                + "\(SyncController.Key.intervalSeconds)）")
        } catch {
            check("跨设备同步往返冒烟", false, "\(error)")
        }
        return failures
    }
}

private extension AppRef {
    /// 自检里只想给一个 bundle id，名字随便填。
    init(bundleID: String, appNameFallback: String) {
        self.init(bundleID: bundleID, name: appNameFallback)
    }
}
