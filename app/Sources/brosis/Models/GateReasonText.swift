import Foundation

/// 门控原因码 → 人话。**唯一一份**。
///
/// 由来（2026-09-09）：这张表原先长在 `ModelsWindowController` 上，而那个类是 `@MainActor`，
/// 于是在后台线程跑的 `OvernightIndexJob` 够不着，只好照抄一份。抄完两份就开始漂——
/// 同一个 `on_battery` 一处写「等接电」一处写「插上电源就继续」，英文也跟着分成两版。
/// 加了英文之后每个原因码要维护 2 份 × 2 种语言。
///
/// 根因不是"抄"，是**表放错了层**：它属于产生这些原因码的调度层，不属于某一个窗口。
/// 挪到这里（nonisolated）之后主线程与后台线程都能读，各调用方只补自己特有的那几个码。
///
/// 原因码本身**保持字符串**、不改成枚举：它们同时是 `logEvent(kind:detail:)` 的载荷，
/// 自检里按字面量断言，`thermal_` / `locked_` 还带后缀。改成枚举要重写自检与日志格式，
/// 换不来任何用户可见的好处。字符串这个边界是对的，错的只是表的位置。
enum GateReasonText {

    /// 三个调度器共用的那些码。认不出来就原样返回（原因码本身也是可读的）。
    static func text(_ reason: String) -> String {
        switch reason {
        case "disabled_by_user":
            L("夜间自动建索引没打开", "nightly auto-index is off")
        case "model_not_installed":
            L("嵌入模型未安装（功能显示为未启用）",
              "no embedding model installed (feature shows as off)")
        case "nothing_pending":
            L("没有待办的块，索引已经是最新的", "nothing pending — the index is up to date")
        case "paused":
            L("采集已暂停（锁屏 / 用户暂停）", "capture is paused (screen locked or paused by you)")
        case "on_battery":
            // 两个调度器都是"暂停、来电继续"，所以说法只需要一种。
            L("在用电池，接上电源就继续", "on battery — plug in to continue")
        case "not_idle":
            L("你还在用这台机器，等空闲 5 分钟",
              "you are still using this Mac — waiting for 5 minutes idle")
        case "gpu_budget_exhausted":
            L("今天的 GPU 预算已用完", "today’s GPU budget is used up")
        case "store_unavailable":
            L("库不可用（已关库）", "database unavailable (closed)")
        case "load_failed":
            L("模型加载失败", "model failed to load")
        default:
            if reason.hasPrefix("thermal_") {
                L("机器偏热（\(reason.dropFirst(8))），等降温",
                  "running hot (\(reason.dropFirst(8))) — waiting to cool down")
            } else if reason.hasPrefix("locked_") {
                L("数据库未解锁（\(reason.dropFirst(7))）", "database is locked (\(reason.dropFirst(7)))")
            } else {
                reason
            }
        }
    }
}
