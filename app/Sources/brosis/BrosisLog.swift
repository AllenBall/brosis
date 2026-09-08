import Foundation
import os

/// 进程级日志出口（2026-09-08 新增）。
///
/// 为什么要有：这天出了三件事——17:29 一次"干净退出"、18:19/18:58 两次 SIGTRAP 崩溃、
/// 21:48 换装后取钥失败停在 locked——**前两类只能靠 .ips 崩溃报告，第三类只写进菜单**，
/// 命令行完全查不到，每次都要花二十分钟反推。落进 os_log 之后：
///
///     log show --last 1h --predicate 'subsystem == "com.brosis.app"' --style compact
///
/// **只记"发生了什么"，不记任何被采集的内容**：正文、窗口标题、URL 一律不进日志
/// （2.2 硬约束：零遥测、原文不出库）。
enum BrosisLog {
    static let subsystem = "com.brosis.app"
    /// 进程生命周期：启动、退出、权限、致命错误。
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    /// 锁定状态机与开库结果。
    static let lock = Logger(subsystem: subsystem, category: "lock")
}
