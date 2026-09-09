import Foundation

/// 自检用的临时 `UserDefaults` 域：建、用、**连文件一起删**。
///
/// 由来（2026-09-09）：自检要在不碰用户真实设置的前提下试各种开关，做法是
/// `UserDefaults(suiteName: "…-\(pid)")`。每处都老老实实写了
/// `defer { removePersistentDomain(forName:) }`，也确实生效了——可这台机器上仍然攒下
/// **582 个** `~/Library/Preferences/brosis-*.plist`。
///
/// 原因是 `removePersistentDomain` 只清值、**不删文件**：那 582 个文件每个 42 字节，
/// 是空 plist，占 2.3 MB（几乎全是 4 KiB 块的浪费）。而 `defaults domains` 按文件列域，
/// 所以它们一直挂在那儿。实测删掉文件，域立刻消失。
///
/// 所以正确的收尾是三步而不是一步。两条保证：收尾逻辑只有 `discard` 一份，
/// 调用点抄不歪；而崩溃时 `defer` 根本跑不到，所以自检开头还会 `sweepStale()`
/// 扫一遍——**这一条才是真正兜底的**，光靠收尾永远清不干净。
enum SelfCheckDefaults {

    /// 所有新建的临时域都用这个前缀，扫残留时只认它一条规则。
    static let prefix = "com.brosis.selfcheck."

    /// 历史上用过的别的前缀（含拼错的那个），只为把老机器上的残留也扫掉。
    /// 新代码不该再产生这些名字；等两台机器都清干净可以删掉这个清单。
    static let legacyPrefixes = [
        "brosis-selfcheck-", "brosis-selcheck-", "brosis-settings-check-", "brosis-veccheck-"
    ]

    private static let counter = Counter()

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    /// 造一个不会撞的临时域名字。带 pid 和自增序号：同一进程里多处自检、
    /// 以及并行跑的两个进程，都不会用到同一个域。
    static func name(_ label: String) -> String {
        "\(prefix)\(label)-\(ProcessInfo.processInfo.processIdentifier)-\(counter.next())"
    }

    /// 清值 → 让 cfprefsd 落盘 → 删文件。少任何一步域都还在。
    static func discard(_ defaults: UserDefaults, name: String) {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
        try? FileManager.default.removeItem(at: plistURL(name))
    }

    /// 扫掉早先跑崩、或旧版本留下的残留。返回删掉几个。
    ///
    /// 自检开头调一次：崩溃时 `defer` 不一定跑得到，光靠收尾清不干净。
    @discardableResult
    static func sweepStale() -> Int {
        let directory = preferencesDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return 0 }
        let prefixes = [prefix] + legacyPrefixes
        var removed = 0
        for entry in entries where entry.hasSuffix(".plist")
            && prefixes.contains(where: { entry.hasPrefix($0) }) {
            let name = String(entry.dropLast(".plist".count))
            // 当前进程正在用的那几个别扫（名字里带自己的 pid）。
            guard !name.hasSuffix("-\(ProcessInfo.processInfo.processIdentifier)"),
                  !name.contains("-\(ProcessInfo.processInfo.processIdentifier)-") else { continue }
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry)))
                != nil {
                removed += 1
            }
        }
        return removed
    }

    /// 还剩几个残留（自检打出来，好看出扫干净没有）。
    static func staleCount() -> Int {
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: preferencesDirectory.path) else { return 0 }
        let prefixes = [prefix] + legacyPrefixes
        return entries.filter { entry in
            entry.hasSuffix(".plist") && prefixes.contains { entry.hasPrefix($0) }
        }.count
    }

    private static var preferencesDirectory: URL {
        (FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library"))
            .appendingPathComponent("Preferences", isDirectory: true)
    }

    private static func plistURL(_ name: String) -> URL {
        preferencesDirectory.appendingPathComponent("\(name).plist")
    }
}
