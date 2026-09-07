import CoreGraphics
import Foundation

/// 无 GUI、无 TCC 的自检。
///
/// 明确保证：本函数不调用 CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess /
/// AXIsProcessTrusted / AXIsProcessTrustedWithOptions / SCShareableContent / AXUIElement*，
/// 也不创建 NSApplication，因此在任何环境下都不会触发授权弹窗，可以在构建流水线里直接跑。
/// 它只验证三件事：SQLite schema 能建起来、四张表能写能读、dHash 能算出区分度。
///
/// 写入目标是**独立的** `m0-selfcheck.sqlite`，不碰 GUI 用的 `m0.sqlite`：
/// 自检写的全是合成行，混进真实观测库会污染 E4 的数据与统计口径。
/// 每次运行前会先删掉上一轮的自检库，让计数可复现。
enum SelfCheck {

    static func run() -> Int32 {
        var failures = 0

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        print("brosis \(BuildInfo.version) 自检（不触发任何 TCC 授权）")

        // 1. 打开 / 建库（独立的自检库，每次从零开始）
        for suffix in ["", "-wal", "-shm"] {
            let path = Store.selfCheckURL.path + suffix
            try? FileManager.default.removeItem(atPath: path)
        }
        let store: Store
        do {
            store = try Store(url: Store.selfCheckURL)
        } catch {
            print("[FAIL] 打开自检库：\(error)")
            return 1
        }
        check("自检库路径", FileManager.default.fileExists(atPath: store.url.path), store.url.path)
        check("自检库与 GUI 测试库分离", store.url != Store.defaultURL,
              "GUI 库 \(Store.defaultURL.lastPathComponent) 未被自检写入")

        check("SQLite 版本", !store.sqliteVersion.isEmpty, store.sqliteVersion)
        check("journal_mode = wal", store.scalarText("PRAGMA journal_mode") == "wal",
              store.scalarText("PRAGMA journal_mode") ?? "?")
        check("foreign_keys = ON", store.scalarInt("PRAGMA foreign_keys") == 1,
              "\(store.scalarInt("PRAGMA foreign_keys"))")

        let tables = store.scalarInt("""
            SELECT COUNT(*) FROM sqlite_master WHERE type='table'
              AND name IN ('meta','observations','ax_texts','frame_stats','runtime_events')
            """)
        check("schema 表数量 = 5", tables == 5, "实得 \(tables)")

        // 2. 写一条观察 + AX 文本统计
        let beforeObservations = store.scalarInt("SELECT COUNT(*) FROM observations")
        let observationID = store.insertObservation(ObservationRow(
            app: "com.brosis.selfcheck",
            appName: "brosis 自检",
            pid: ProcessInfo.processInfo.processIdentifier,
            title: "自检窗口标题 self-check window",
            url: "https://example.invalid/brosis/self-check?q=1",
            document: "file:///dev/null",
            trigger: .selfCheck,
            sourceState: .ok,
            idleSeconds: 0,
            displayID: 1))
        check("写入 observations", observationID > 0, "rowid=\(observationID)")

        store.insertAXText(observationID: observationID,
                           summary: AXTextSummary(role: "AXTextArea", nodeCount: 1,
                                                  charCount: 1234, completeness: .partial))
        store.insertAXText(observationID: observationID,
                           summary: AXTextSummary(role: "AXWebArea", nodeCount: 0,
                                                  charCount: 0, completeness: .unavailable))
        let axRows = store.scalarInt(
            "SELECT COUNT(*) FROM ax_texts WHERE observation_id = \(observationID)")
        check("写入 ax_texts", axRows == 2, "实得 \(axRows)")
        let unavailable = store.scalarInt(
            "SELECT COUNT(*) FROM ax_texts WHERE is_empty = 1 AND completeness = 'unavailable'")
        check("空 AX 记为 unavailable", unavailable >= 1, "实得 \(unavailable)")

        // 3. dHash 区分度：同图 = 0，反色图应明显不同
        let hasher = DHasher()
        guard let imageA = syntheticImage(seed: 0),
              let imageB = syntheticImage(seed: 1),
              let hashA = hasher.hash(cgImage: imageA),
              let hashA2 = hasher.hash(cgImage: imageA),
              let hashB = hasher.hash(cgImage: imageB) else {
            print("[FAIL] dHash 计算失败")
            return 1
        }
        check("同一图像 dHash 稳定", hashA == hashA2, "\(hashA.hex)")
        let distance = hashA.hamming(to: hashB)
        check("不同图像 dHash 汉明距离 > 6", distance > 6, "距离 \(distance) bit（门控阈值 6）")

        // 4. 帧统计写入
        store.insertFrameStat(FrameStat(displayID: 1, status: "complete",
                                        width: imageA.width, height: imageA.height,
                                        contentScale: 1.0, dHashHex: hashA.hex, hamming: 0,
                                        dirtyRectCount: 0, dirtyAreaRatio: 0.0, gated: true))
        store.insertFrameStat(FrameStat(displayID: 1, status: "complete",
                                        width: imageB.width, height: imageB.height,
                                        contentScale: 1.0, dHashHex: hashB.hex, hamming: distance,
                                        dirtyRectCount: 3, dirtyAreaRatio: 0.31, gated: false))
        store.insertFrameStat(FrameStat(displayID: 1, status: "idle_batch", idleCount: 60))
        let frames = store.scalarInt("SELECT COUNT(*) FROM frame_stats")
        check("写入 frame_stats", frames >= 3, "累计 \(frames) 行")

        store.logEvent(kind: "self_check", detail: "failures=\(failures)")

        // 5. 排除清单可读
        let exclusions = ExclusionList.shared
        check("排除清单已加载", exclusions.count > 0,
              "\(exclusions.count) 个 bundle id，来源="
              + (exclusions.loadedFromResource ? "Contents/Resources/exclusions.txt" : "代码内默认集合"))

        let afterObservations = store.scalarInt("SELECT COUNT(*) FROM observations")
        print("自检库 observations 由 \(beforeObservations) 增至 \(afterObservations) 行；"
              + "库文件 \(fileSize(store.url)) 字节")
        let guiExists = FileManager.default.fileExists(atPath: Store.defaultURL.path)
        print("GUI 测试库 \(Store.defaultURL.path)：\(guiExists ? "存在（本次自检未写入）" : "尚未创建")")
        print(failures == 0 ? "自检通过" : "自检失败 \(failures) 项")
        return failures == 0 ? 0 : 1
    }

    private static func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 合成一张 640×400 的测试图：seed 0 是浅底深条，seed 1 是深底浅条（近似反色）。
    private static func syntheticImage(seed: Int) -> CGImage? {
        let width = 640, height = 400
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let background: CGFloat = seed == 0 ? 0.95 : 0.08
        let bar: CGFloat = seed == 0 ? 0.10 : 0.92
        context.setFillColor(red: background, green: background, blue: background, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: bar, green: bar, blue: bar, alpha: 1)
        for row in 0..<8 {
            let barWidth = 40 + row * 55
            context.fill(CGRect(x: (row % 2) * 60, y: row * 50 + 6, width: barWidth, height: 22))
        }
        return context.makeImage()
    }
}
