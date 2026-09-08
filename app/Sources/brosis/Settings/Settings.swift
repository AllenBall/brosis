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

    /// 定时兜底截图间隔（秒）。键沿用 CaptureController 原来那个。
    static let periodicIntervalKey = "capture.periodicInterval"
    static let periodicIntervalDefault = 12.0
    static let periodicIntervalRange = 3.0...120.0
    static var periodicInterval: Double {
        get {
            let raw = UserDefaults.standard.double(forKey: periodicIntervalKey)
            guard raw > 0 else { return periodicIntervalDefault }
            return clamp(raw, periodicIntervalRange)
        }
        set { UserDefaults.standard.set(clamp(newValue, periodicIntervalRange),
                                        forKey: periodicIntervalKey) }
    }

    /// 严格锁屏：屏幕一锁就关库（不只是暂停采集）。默认关。
    static let strictLockKey = "lock.strict"
    static var strictLock: Bool {
        get { UserDefaults.standard.bool(forKey: strictLockKey) }
        set { UserDefaults.standard.set(newValue, forKey: strictLockKey) }
    }

    // MARK: - 索引与检索（键沿用各调度器已有的，不改名）

    static var autoIndex: Bool {
        get { AutoIndexScheduler.isEnabled }
        set { UserDefaults.standard.set(newValue, forKey: AutoIndexScheduler.enabledKey) }
    }

    static var autoIndexIntervalMinutes: Double {
        get { AutoIndexScheduler.intervalMinutes }
        set { UserDefaults.standard.set(max(AutoIndexScheduler.minimumIntervalMinutes, newValue),
                                        forKey: AutoIndexScheduler.intervalKey) }
    }

    static let dailyGPUSecondsKey = "embedding.dailyGPUSeconds"
    static let dailyGPUSecondsDefault = 600.0
    static var dailyGPUSeconds: Double {
        get {
            let raw = UserDefaults.standard.double(forKey: dailyGPUSecondsKey)
            return raw > 0 ? raw : dailyGPUSecondsDefault
        }
        set { UserDefaults.standard.set(max(60, newValue), forKey: dailyGPUSecondsKey) }
    }

    static var vectorsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: QueryEmbedderService.vectorsEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: QueryEmbedderService.vectorsEnabledKey) }
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
