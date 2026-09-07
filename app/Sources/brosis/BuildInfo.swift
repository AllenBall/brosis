import BrosisCore
import Foundation

/// 版本与固定标识。bundle id 必须与 Info.plist、LaunchAgent plist 保持一致，
/// 否则 TCC 授权会作废（报告 3.3）。
enum BuildInfo {
    static let version = "0.2.0"
    static let bundleIdentifier = "com.brosis.app"
    static let agentPlistName = "com.brosis.agent.plist"
    /// 菜单与自检里打印的阶段名。
    static let stage = "M1 采集端接入加密存储核心"
}

/// 观察记录的触发原因（采集端口径，与计划 3.3 的事件骨架一一对应）。
///
/// **M1 起它不再直接入库**：库里的 `observations."trigger"` 用的是
/// `BrosisCore.CaptureTrigger` 那七个取值（schema 有 CHECK 约束），
/// 这里的细分原因通过 `coreTrigger` 收敛过去，原始细分值保留在
/// `capture_stats."trigger"` 与运行期事件里，不丢信息。
enum ObservationTrigger: String, Sendable {
    case appActivated = "app_activated"
    case appDeactivated = "app_deactivated"
    case focusedWindowChanged = "focused_window_changed"
    case focusedElementChanged = "focused_element_changed"
    case titleChanged = "title_changed"
    case screenLocked = "screen_locked"
    case screenUnlocked = "screen_unlocked"
    // NSWorkspace.sessionDidResignActive/DidBecomeActive 只在**快速用户切换**时触发，
    // 锁屏不会触发，所以它们单独记一种 trigger，不能当锁屏用（锁屏见 screenLocked）。
    case userSwitchedAway = "user_switched_away"
    case userSwitchedBack = "user_switched_back"
    case systemWillSleep = "system_will_sleep"
    case systemDidWake = "system_did_wake"
    case screensaverStarted = "screensaver_started"
    case screensaverStopped = "screensaver_stopped"
    case selfCheck = "self_check"

    /// 收敛到 schema 的七个取值。
    ///
    /// - 应用激活 / 失活 → `app_switch`
    /// - 焦点窗口变化、标题变化 → `window_change`
    /// - 焦点元素变化 → `ax_notification`
    /// - 其余（系统级事件、自检）→ `manual`。系统级事件本身**不写观察记录**，
    ///   只写运行期事件；这里给一个值只是为了枚举完备。
    var coreTrigger: CaptureTrigger {
        switch self {
        case .appActivated, .appDeactivated:            return .appSwitch
        case .focusedWindowChanged, .titleChanged:      return .windowChange
        case .focusedElementChanged:                    return .axNotification
        default:                                        return .manual
        }
    }

    /// 系统级事件只写 `jobs`（运行期事件表），不写 `observations`：
    /// schema 的 `trigger` 枚举里没有"睡眠 / 锁屏"这类取值，硬塞成 `manual` 会让
    /// 台账把它们当成一次用户主动记录。时间轴上的空档由 T3 结合运行期事件补。
    var isSystemLevel: Bool {
        switch self {
        case .screenLocked, .screenUnlocked, .userSwitchedAway, .userSwitchedBack,
             .systemWillSleep, .systemDidWake, .screensaverStarted, .screensaverStopped:
            return true
        default:
            return false
        }
    }
}
