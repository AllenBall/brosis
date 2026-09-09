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
    /// （`brosis-veccheck-` 曾经列在这里，但它从来只是 `$TMPDIR` 下的临时**目录**名，
    /// 不是 UserDefaults 域，扫这里永远扫不到。）
    static let legacyPrefixes = [
        "brosis-selfcheck-", "brosis-selcheck-", "brosis-settings-check-"
    ]

    /// 造一个不会撞的临时域名字。
    ///
    /// `label` 在调用点本来就互不相同（policy / ui / ocr / settings / overnight / budget /
    /// selection），加上 pid 就已经跨进程唯一——曾经还挂过一个带锁的自增序号，
    /// 它没有消除任何一次碰撞，反而让下面 sweep 里的"跳过本进程"判断多出一条永远为假的分支。
    static func name(_ label: String) -> String {
        "\(prefix)\(label)-\(ProcessInfo.processInfo.processIdentifier)"
    }

    /// 清值 → 让 cfprefsd 落盘 → 删文件。少任何一步域都还在。
    static func discard(_ defaults: UserDefaults, name: String) {
        defaults.removePersistentDomain(forName: name)
        UserDefaults.standard.removeSuite(named: name)
        try? FileManager.default.removeItem(at: plistURL(name))
    }

    /// 扫掉早先跑崩、或旧版本留下的残留。返回 (删掉几个, 还剩几个)。
    ///
    /// 自检开头调一次：崩溃时 `defer` 跑不到，光靠收尾清不干净。
    /// **一次目录遍历出两个数**——曾经拆成 `sweepStale()` + `staleCount()` 两个函数，
    /// 结果不但把 `~/Library/Preferences`（几百个条目）扫了两遍，两边的判据还漂了：
    /// 一个跳过本进程的域、一个不跳，于是同一句自检消息里的两个数**数的不是同一批东西**。
    @discardableResult
    static func sweepStale() -> (removed: Int, remaining: Int) {
        let directory = preferencesDirectory
        let mine = "\(prefix)"
        let pid = "-\(ProcessInfo.processInfo.processIdentifier)"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return (0, 0) }
        let prefixes = [prefix] + legacyPrefixes
        var removed = 0
        var remaining = 0
        for entry in entries where entry.hasSuffix(".plist")
            && prefixes.contains(where: { entry.hasPrefix($0) }) {
            // 本进程正在用的那几个不扫（名字里带自己的 pid），但要数进 remaining，
            // 否则"还剩几个"会显得比实际少。
            if entry.hasPrefix(mine), entry.dropLast(".plist".count).hasSuffix(pid) {
                remaining += 1
                continue
            }
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry)))
                != nil {
                removed += 1
            } else {
                remaining += 1
            }
        }
        return (removed, remaining)
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
