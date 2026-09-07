import AppKit
import ApplicationServices
import BrosisCore
import CoreGraphics
import Foundation
import Carbon.HIToolbox
import ScreenCaptureKit

/// TCC 权限探测与请求。
///
/// 重要：本文件里只有 `requestScreenRecording()` 与 `requestAccessibility()` 会弹窗，
/// 它们只由 `AppDelegate.promptForPermissions`（GUI 启动时权限缺失、权限丢失、菜单“请求权限…”）
/// 调用。自检路径（`--self-check`）与构建流程一律只走 preflight，
/// 保证构建与测试阶段不触发任何授权弹窗（报告 3.3）。
enum Permissions {

    struct Snapshot: Sendable {
        var screenRecording: Bool
        var accessibility: Bool

        var allGranted: Bool { screenRecording && accessibility }

        var missingDescription: String {
            var missing: [String] = []
            if !screenRecording { missing.append("屏幕录制") }
            if !accessibility { missing.append("辅助功能") }
            return missing.joined(separator: "、")
        }
    }

    /// 不弹窗：CGPreflightScreenCaptureAccess 与 AXIsProcessTrusted 都只查询状态。
    static func snapshot() -> Snapshot {
        Snapshot(screenRecording: CGPreflightScreenCaptureAccess(),
                 accessibility: AXIsProcessTrusted())
    }

    /// 会弹窗（或在已拒绝时静默返回 false）。仅供 AppDelegate.promptForPermissions 调用。
    ///
    /// 2026-09-07 公司机（macOS 26.6）实测：只调 `CGRequestScreenCaptureAccess()` 既不弹系统框、
    /// 「录屏与系统录音」列表里也不登记 brosis——那张列表只在 app 真正通过 ScreenCaptureKit
    /// 请求过内容后才出现条目。所以未授权时再异步取一次 `SCShareableContent`：
    /// 这一步会让系统弹出授权对话框并把 brosis 登记进列表（未授权时调用必然抛错，抛错正是预期）。
    static func requestScreenRecording() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            Task.detached {
                do {
                    _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                } catch {
                    // 未授权：系统已弹框 / 已登记；这里不需要处理。
                }
            }
        }
        return granted
    }

    /// 会弹出“打开系统设置”提示。仅供 AppDelegate.promptForPermissions 调用。
    static func requestAccessibility() -> Bool {
        // 常量 kAXTrustedCheckOptionPrompt 在 Swift 6 下不是并发安全的全局变量，
        // 直接用它的文档值，避免引入 nonisolated(unsafe)。
        let key = "AXTrustedCheckOptionPrompt"
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @MainActor
    static func openScreenRecordingSettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @MainActor
    static func openAccessibilitySettings() {
        openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @MainActor
    private static func openSettings(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 输入与会话状态。全部是无权限 API。
enum SystemState {

    /// 距上次任意输入事件的秒数（CGEventSource，只有频率没有内容）。
    static func idleSeconds() -> Double {
        let anyInput = CGEventType(rawValue: ~UInt32(0))!
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    /// 键盘 + 鼠标事件累计计数（只做活跃度判定，不记内容）。
    static func inputCounts() -> (keys: Int64, clicks: Int64) {
        let keys = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
        let clicks = CGEventSource.counterForEventType(.hidSystemState, eventType: .leftMouseDown)
            + CGEventSource.counterForEventType(.hidSystemState, eventType: .rightMouseDown)
        return (Int64(keys), Int64(clicks))
    }

    /// 安全键盘输入（密码框、开了 secure input 的终端）。此时不做内容采集。
    static func secureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// 锁屏 / 快速用户切换。
    static func screenLocked() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let locked = dictionary["CGSSessionScreenIsLocked"] as? Bool { return locked }
        if let locked = dictionary["CGSSessionScreenIsLocked"] as? Int { return locked != 0 }
        return false
    }

    /// 计划 3.3 的状态分离：把当前系统状态映射成一个 `source_state`。
    /// 顺序：锁定 > 权限丢失 > 安全输入 > 未活动 > ok。
    static func sourceState(permissions: Permissions.Snapshot, idleThreshold: Double = 30) -> SourceState {
        if screenLocked() { return .locked }
        if !permissions.allGranted { return .permissionLost }
        if secureInputEnabled() { return .secureInput }
        if idleSeconds() >= idleThreshold { return .userIdle }
        return .ok
    }
}
