import Foundation

/// OCR 触发原因（计划 3.3：**只对三类区域做 accurate OCR**）。
enum OCRTriggerReason: String, Sendable, CaseIterable {
    /// ① 规则声明 AX 不可用的区域（`read = .ocr`，或声明了 `ocrFallback` 且 AX 读到空）。
    case ruleDeclared = "rule_declared"
    /// ② 帧变化超阈值，但该区域的 AX 值没变。
    case frameChangedAXStable = "frame_changed_ax_stable"
    /// ③ 覆盖检查失败的区域（采样审计算出的覆盖率低于阈值）。
    case coverageFailed = "coverage_failed"

    var explanation: String {
        switch self {
        case .ruleDeclared: return "规则声明 AX 不可用（或 AX 读到空且规则允许回退）"
        case .frameChangedAXStable: return "帧变化超阈值但该区域 AX 值未变"
        case .coverageFailed: return "上一次采样审计的覆盖检查未通过"
        }
    }
}

/// 触发判定 + 频率限制。
///
/// **判定是纯函数**（`reason(...)`），限流是有状态的（`allow(...)`）。分开是为了让
/// 三类触发条件的用例不依赖时钟，也让"同一窗口区域最少间隔"能单独测。
final class OCRTriggerGate: @unchecked Sendable {

    /// 同一个窗口区域两次 OCR 的最小间隔（秒）。默认 **5 s**（计划 3.3「避免 OCR 刷屏」）。
    ///
    /// 改法不用重新编译：
    /// `defaults write com.brosis.app capture.ocrMinInterval -float 10`
    /// 值会被夹到下限 1 s 以上；设成非法值（≤ 0 / NaN）时用默认 5 s。
    static let minIntervalKey = "capture.ocrMinInterval"
    static let minIntervalDefault: TimeInterval = 5
    static let minIntervalMinimum: TimeInterval = 1

    static func resolveMinInterval(_ defaults: UserDefaults = .standard)
        -> (value: TimeInterval, source: String) {
        guard defaults.object(forKey: minIntervalKey) != nil else {
            return (minIntervalDefault, "default")
        }
        let raw = defaults.double(forKey: minIntervalKey)
        guard raw.isFinite, raw > 0 else { return (minIntervalDefault, "defaults_invalid") }
        let clamped = max(minIntervalMinimum, raw)
        return (clamped, clamped == raw ? "defaults" : "defaults_clamped")
    }

    /// **三类触发条件的判定**（纯函数，自检逐条覆盖）。返回 nil = 这一帧不该 OCR。
    ///
    /// 顺序是有意的：规则声明 > 帧变化 + AX 未变 > 覆盖检查失败。
    /// 特别注意第二类的**反例**：AX 值变了就说明 AX 通道还在工作，这时候再 OCR 是白花钱
    /// （计划 3.3「文本是否变化以 AX 通知与值比较为准」）。
    static func reason(ruleDeclaresOCR: Bool,
                       ocrFallback: Bool,
                       axEmpty: Bool,
                       axChanged: Bool,
                       frameChanged: Bool,
                       coverageFailed: Bool) -> OCRTriggerReason? {
        if ruleDeclaresOCR { return .ruleDeclared }
        if ocrFallback && axEmpty { return .ruleDeclared }
        // 注意这里的 `!axEmpty`：AX 读到空 + 规则允许回退的情况已经被上一行判成 `ruleDeclared`
        // 了，所以"帧变化 + AX 空"这一支永远到不了这里（曾经写过一条，是死代码，已删）。
        if frameChanged && !axChanged && !axEmpty { return .frameChangedAXStable }
        if coverageFailed { return .coverageFailed }
        return nil
    }

    /// 限流判定的结果。
    enum Decision: Equatable {
        case allow(OCRTriggerReason)
        /// 同一区域距上次 OCR 不足最小间隔。
        case rateLimited(remaining: TimeInterval)

        var isAllowed: Bool { if case .allow = self { return true }; return false }
    }

    private let lock = NSLock()
    private var lastRunAt: [String: TimeInterval] = [:]
    private var blockedCount = 0
    let minInterval: TimeInterval
    let minIntervalSource: String

    init(defaults: UserDefaults = .standard) {
        let resolved = Self.resolveMinInterval(defaults)
        minInterval = resolved.value
        minIntervalSource = resolved.source
    }

    /// 允许就把时钟推进去；被限流不推进（否则会把间隔越推越远）。
    /// `key` 是「窗口区域」：`<bundle id>|<区域名>`。
    func allow(key: String, reason: OCRTriggerReason, now: TimeInterval) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastRunAt[key] {
            let elapsed = now - last
            if elapsed < minInterval {
                blockedCount += 1
                return .rateLimited(remaining: minInterval - elapsed)
            }
        }
        lastRunAt[key] = now
        return .allow(reason)
    }

    var rateLimitedTotal: Int { lock.withLock { blockedCount } }

    /// 只给测试与自检用：把时钟状态清掉。
    func reset() { lock.withLock { lastRunAt.removeAll(); blockedCount = 0 } }
}
