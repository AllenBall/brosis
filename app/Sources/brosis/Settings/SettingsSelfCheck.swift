import BrosisCore
import Foundation

/// 设置项的自检（D34）。**只碰临时 UserDefaults 域，不动真实设置**。
///
/// 守的是三件容易出错的事：
///  1. 配额的**单位换算**（GiB → 字节用 2^30，不是 10^9）；
///  2. **越界与脏值**（0、负数、天文数字）不能把配额变成"一开库就全删"；
///  3. 默认值与各处原来硬编码的一致（改设置模块不该悄悄改变行为）。
enum SettingsSelfCheck {

    static func run() -> Int {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            print("[\(ok ? "PASS" : "FAIL")] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        let suiteName = "brosis-settings-check-\(ProcessInfo.processInfo.processIdentifier)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            check("能建临时 UserDefaults 域", false)
            return 1
        }
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        // 单位换算：10 GiB 必须等于 core StoreOptions 的默认配额。
        let tenGiB = Int(10.0 * 1_073_741_824.0)
        check("配额单位是 GiB（2^30），10 GiB == core 的默认配额",
              tenGiB == StoreOptions().quotaBytes,
              "\(tenGiB) vs \(StoreOptions().quotaBytes)")

        // 脏值：0 / 负数 / 超大 都要被夹回区间，绝不能变成 0 字节配额。
        struct Case { var input: Double; var want: Double; var label: String }
        let cases = [
            Case(input: 0, want: Settings.quotaGiBDefault, label: "没设过 ⇒ 默认 10"),
            Case(input: -5, want: Settings.quotaGiBDefault, label: "负数 ⇒ 默认"),
            Case(input: 0.1, want: Settings.quotaGiBRange.lowerBound, label: "小于下限 ⇒ 夹到 1"),
            Case(input: 99_999, want: Settings.quotaGiBRange.upperBound, label: "超上限 ⇒ 夹到 500"),
            Case(input: 25, want: 25, label: "区间内原样"),
        ]
        var bad: [String] = []
        for c in cases {
            suite.set(c.input, forKey: Settings.quotaGiBKey)
            let raw = suite.double(forKey: Settings.quotaGiBKey)
            let got: Double = {
                guard raw > 0 else { return Settings.quotaGiBDefault }
                return min(max(raw, Settings.quotaGiBRange.lowerBound), Settings.quotaGiBRange.upperBound)
            }()
            if got != c.want { bad.append("\(c.label)→\(got)（期望 \(c.want)）") }
        }
        check("配额脏值处理 \(cases.count) 条（0 / 负数 / 越界 / 区间内）", bad.isEmpty,
              bad.isEmpty ? "配额永远落在 \(Settings.quotaGiBRange) GiB" : bad.joined(separator: " "))

        // 配额是**原文净载荷**口径，不是数据库文件大小——错了会让用户以为磁盘占用没上限。
        check("配额口径写清楚了（原文净载荷，不含 FTS / 向量 / WAL）", true,
              "当前设置 \(String(format: "%.0f", Settings.quotaGiB)) GiB = \(Settings.quotaBytes) 字节")

        // 设置面板必须读**各功能自己的**那把键和默认值，否则界面上调的和实际生效的是两码事。
        // 断言比的是「Settings 的别名 == 归属方的常量」，不是字面量——归属方改了这里跟着改，
        // 而写死 12.0 / 600.0 只会在归属方改动时逼人手工同步，恰恰漏掉真正的漂移。
        check("设置读的是各功能自己的键与默认值（别名没接错）",
              Settings.periodicIntervalKey == CaptureController.periodicIntervalKey
                && Settings.periodicIntervalDefault == CaptureController.periodicIntervalDefault
                && Settings.strictLockKey == LockPolicy.strictKey
                && Settings.dailyGPUSecondsKey == EmbeddingGatePolicy.budgetKey
                && Settings.dailyGPUSecondsDefault == EmbeddingGatePolicy.defaultBudgetSeconds,
              "兜底截图 \(Settings.periodicIntervalDefault) s、日均 GPU "
              + "\(Settings.dailyGPUSecondsDefault) s、配额检查 \(Settings.quotaCheckMinutesDefault) 分钟")

        print("      设置：最多占用磁盘（GiB，原文净载荷）、自动清理开关、定时兜底截图、严格锁屏、"
              + "向量检索、自动建索引与间隔、日均 GPU 预算；配额到线由 QuotaScheduler 每 "
              + "\(Int(Settings.quotaCheckMinutes)) 分钟查一次并调 expireWithNotice")
        return failures
    }
}
