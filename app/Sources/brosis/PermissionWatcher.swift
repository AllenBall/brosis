import Foundation

/// 权限状态巡检（e 批 ⑤：月度屏幕录制再授权）。
///
/// 已有的**被动**路径是完整的：截图失败且 `CGPreflightScreenCaptureAccess()` 为假时
/// `CaptureController` 会解除武装并抛 `.stopped(permissionLost: true)`，`AppDelegate`
/// 接着弹引导，引导里两项都授权后自动重新武装。
///
/// 缺的是**主动**那一半：macOS 大约每月撤一次屏幕录制授权，而撤销发生时如果机器正空闲
/// （没有应用切换 → 没有截图尝试），就没有任何东西会去碰那个失败路径，用户看到的是
/// "菜单显示录制中，但什么都没记下来"。所以隔一段时间主动比一次。
///
/// 判定是纯函数，自检逐条盯着；定时器和真正的动作在 `AppDelegate`——
/// 那里本来就握着引导窗口与重新武装的入口，为这点逻辑再开一个调度器类不值。
enum PermissionWatcher {

    /// 巡检间隔。月度撤销用 10 分钟的粒度绰绰有余；
    /// 每次巡检要走一趟 WindowServer（`CGPreflight…`）与 TCC（`AXIsProcessTrusted`），
    /// 不该更密。定时器另加宽容度，让系统合并唤醒。
    static let interval: TimeInterval = 600
    static let tolerance: TimeInterval = 120

    enum Action: Equatable {
        /// 什么都没变。
        case none
        /// 权限刚被撤销：解除武装 + 弹引导。
        case lost(description: String)
        /// 权限刚补齐：重新武装。
        case regained
    }

    /// - Parameters:
    ///   - previous: 上一次巡检看到的状态；首次巡检传 nil。
    ///   - current: 这一次看到的状态。
    ///
    /// **首次巡检不产生动作**：启动路径已经查过一遍权限并弹过引导了，
    /// 这里再弹一次只会重复打扰。
    static func decide(previous: Permissions.Snapshot?,
                       current: Permissions.Snapshot) -> Action {
        guard let previous else { return .none }
        if previous.allGranted && !current.allGranted {
            return .lost(description: current.missingDescription)
        }
        if !previous.allGranted && current.allGranted { return .regained }
        return .none
    }
}
