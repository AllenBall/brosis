import BrosisCore
import Foundation

/// 设置项的**唯一真源**（2026-09-08 / D34）。
///
/// 之前这些键散在各处（调度器、面板、LockController 各读各的），设置窗口要改哪一项都得翻代码。
/// 这里集中声明键名、默认值与取值范围，窗口与调度器都只经它读写。
///
/// **不改语义、只集中**：默认值与原来各处硬编码的一致；有的项补了上下限——
/// 比如配额不能填 0，否则一开库就把全部证据判成超额。
enum Settings {

    // MARK: - 存储

    /// 最多占用磁盘（GiB）。口径是**原文净载荷**（3.8 / D21），不是数据库文件大小：
    /// FTS 索引、向量、WAL 都不算在里面，所以磁盘上的实际文件会比这个数大。
    static let quotaGiBKey = "storage.quotaGiB"
    static let quotaGiBDefault = 10.0
    static let quotaGiBRange = 1.0...500.0

    static var quotaGiB: Double {
        get {
            let raw = UserDefaults.standard.double(forKey: quotaGiBKey)
            guard raw > 0 else { return quotaGiBDefault }
            return clamp(raw, quotaGiBRange)
        }
        set { UserDefaults.standard.set(clamp(newValue, quotaGiBRange), forKey: quotaGiBKey) }
    }

    /// 把 UserDefaults 里读到的原始值夹进合法区间。**抽成纯函数是为了让自检测到的是这一份**——
    /// 此前自检在自己那边手抄了一遍同样的逻辑，于是生产代码写错了它也照样通过。
    /// `raw <= 0` 表示没设过（`double(forKey:)` 读不到时返回 0），按默认值算。
    static func normalizedQuotaGiB(_ raw: Double) -> Double {
        guard raw > 0 else { return quotaGiBDefault }
        return min(max(raw, quotaGiBRange.lowerBound), quotaGiBRange.upperBound)
    }

    static var quotaBytes: Int { Int(quotaGiB * 1_073_741_824.0) }

    /// 到线后自动按配额过期（删最旧的原文）。**默认开**——不开的话配额只是个显示，库会一直涨。
    static let autoExpireKey = "storage.autoExpire"
    static var autoExpire: Bool {
        get { UserDefaults.standard.object(forKey: autoExpireKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoExpireKey) }
    }

    /// 多久查一次配额（分钟）。默认 30，下限 5。
    static let quotaCheckMinutesKey = "storage.quotaCheckMinutes"
    static let quotaCheckMinutesDefault = 30.0
    static var quotaCheckMinutes: Double {
        let raw = UserDefaults.standard.double(forKey: quotaCheckMinutesKey)
        return raw >= 5 ? raw : quotaCheckMinutesDefault
    }

    // MARK: - 采集

    /// 定时兜底截图间隔（秒）。**键、默认值、下限都取自拥有者 `CaptureController`**——
    /// 抄一份字面量就会两边劈叉（上一版这里自加了 120 的上限，拥有者那边根本没有上限）。
    static let periodicIntervalKey = CaptureController.periodicIntervalKey
    static let periodicIntervalDefault = CaptureController.periodicIntervalDefault
    static let periodicIntervalRange = CaptureController.periodicIntervalMinimum...120.0
    static var periodicInterval: Double {
        get {
            let raw = UserDefaults.standard.double(forKey: periodicIntervalKey)
            guard raw > 0 else { return periodicIntervalDefault }
            return clamp(raw, periodicIntervalRange)
        }
        set { UserDefaults.standard.set(clamp(newValue, periodicIntervalRange),
                                        forKey: periodicIntervalKey) }
    }

    /// 严格锁屏：屏幕一锁就关库（不只是暂停采集）。默认关。键的拥有者是 `LockPolicy`。
    static let strictLockKey = LockPolicy.strictKey
    static var strictLock: Bool {
        get { UserDefaults.standard.bool(forKey: strictLockKey) }
        set { UserDefaults.standard.set(newValue, forKey: strictLockKey) }
    }

    // MARK: - 索引与检索（键沿用各调度器已有的，不改名）

    /// 直接转发给拥有者的**可写属性**——它的 setter 自己写键、自己起停定时器。
    /// 真源不是键，是"改这个设置要连带做的那件事"。
    static var autoIndex: Bool {
        get { AutoIndexScheduler.isEnabled }
        set { AutoIndexScheduler.isEnabled = newValue }
    }

    static var autoIndexIntervalMinutes: Double {
        get { AutoIndexScheduler.intervalMinutes }
        set { AutoIndexScheduler.intervalMinutes = newValue }
    }

    /// 键与默认值的拥有者是 `EmbeddingGatePolicy`。
    static let dailyGPUSecondsKey = EmbeddingGatePolicy.budgetKey
    static let dailyGPUSecondsDefault = EmbeddingGatePolicy.defaultBudgetSeconds
    static var dailyGPUSeconds: Double {
        get {
            let raw = UserDefaults.standard.double(forKey: dailyGPUSecondsKey)
            return raw > 0 ? raw : dailyGPUSecondsDefault
        }
        set { UserDefaults.standard.set(max(60, newValue), forKey: dailyGPUSecondsKey) }
    }

    /// **只读**：写要走 `QueryEmbedderService.setVectorsEnabled(_:store:)`，
    /// 因为开关还要推 `store.retrieval`（core 的检索闸门）并加载 / 卸载权重。
    static var vectorsEnabled: Bool {
        UserDefaults.standard.object(forKey: QueryEmbedderService.vectorsEnabledKey) as? Bool ?? true
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
