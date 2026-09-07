import Foundation

/// 版本与固定标识。bundle id 必须与 Info.plist、LaunchAgent plist 保持一致，
/// 否则 TCC 授权会作废（报告 3.3）。
enum BuildInfo {
    static let version = "0.1.0"
    static let bundleIdentifier = "com.brosis.app"
    static let agentPlistName = "com.brosis.agent.plist"
}

/// 观察记录的触发原因。与计划 3.3 的事件骨架一一对应。
enum ObservationTrigger: String {
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
    case captureStopped = "capture_stopped"
    case selfCheck = "self_check"
}

/// 计划 3.2 的 `source_state`：权限丢失、超时、未活动、安全输入、锁定是不同状态，
/// 不能混成一个“空”（评审 F5）。
enum SourceState: String {
    case ok
    case permissionLost = "permission_lost"
    case timeout
    case userIdle = "user_idle"
    case secureInput = "secure_input"
    case locked
}

/// 计划 3.2 的 `completeness`。M0 只做占位：AX 非空 = partial，空 = unavailable。
enum Completeness: String {
    case complete
    case partial
    case unavailable
    case excluded
}
