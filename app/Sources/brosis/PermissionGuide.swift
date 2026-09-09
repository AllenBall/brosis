import AppKit
import Foundation

/// 启动时的权限引导窗口（2026-09-07 新增，用户要求）。
///
/// 打开 app 时若辅助功能 / 屏幕录制任一缺失：AppDelegate 先直接触发系统授权框，
/// 再显示这个窗口——两行实时状态、各自一键打开对应的系统设置面板、每 1.5 s 自动复查，
/// 两项都打开后自动收起并回调开始采集。屏幕录制在 macOS 上通常要重新打开 app 才生效，
/// 所以窗口上有「退出并重新打开」。
///
/// 本文件不调用任何会弹 TCC 框的 API（只读 `Permissions.snapshot()`）；弹框的两个调用仍在
/// `Permissions` 里，由 AppDelegate 决定何时触发。`--self-check` 路径不会走到这里。
@MainActor
final class PermissionGuide: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var registeredLanguageHandler = false
    private var timer: Timer?
    private let axStatus = NSTextField(labelWithString: "")
    private let screenStatus = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let relaunchButton = NSButton(title: "", target: nil, action: nil)

    private let onAllGranted: () -> Void
    private let onRerequest: () -> Void
    private let log: (String, String) -> Void

    var isVisible: Bool { window?.isVisible ?? false }

    init(onAllGranted: @escaping () -> Void,
         onRerequest: @escaping () -> Void,
         log: @escaping (String, String) -> Void) {
        self.onAllGranted = onAllGranted
        self.onRerequest = onRerequest
        self.log = log
        super.init()
    }

    /// 显示（已显示则前置）并开始轮询。
    func show() {
        if window == nil { window = makeWindow() }
        // 语言换了就把窗口关掉：contentView 是搭窗口时一次性造出来的，
        // 就地把每个控件的文案换一遍既繁琐又容易漏，重开一次全对。
        // **谁搭窗口谁登记**——不靠 AppDelegate 点名，那份名单结构上补不齐。
        if !registeredLanguageHandler {
            registeredLanguageHandler = true
            L10n.onLanguageChange { [weak self] in
                self?.window?.close()
                self?.window = nil
            }
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
        log("permission_guide_shown", Permissions.snapshot().missingDescription)
    }

    func close() {
        stopPolling()
        window?.orderOut(nil)
    }

    // MARK: - 轮询

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let snapshot = refresh()
        if snapshot.allGranted {
            log("permission_guide_completed", "两项权限已就绪，自动收起引导窗口")
            close()
            onAllGranted()
        }
    }

    @discardableResult
    private func refresh() -> Permissions.Snapshot {
        let snapshot = Permissions.snapshot()
        apply(granted: snapshot.accessibility, to: axStatus)
        apply(granted: snapshot.screenRecording, to: screenStatus)
        if !snapshot.screenRecording {
            hint.stringValue = L("在系统设置「录屏与系统录音」里把 brosis 打开；macOS 通常要求重新打开 app 才生效，"
                + "打开开关后这里仍显示「未授权」就点「退出并重新打开 brosis」。"
                + "如果列表里没有 brosis，先点「重新请求授权」；仍没有就在该页点「+」手动添加 /Applications/brosis.app。",
                "Turn brosis on in System Settings → Screen & System Audio Recording. macOS usually "
                + "requires reopening the app before it takes effect: if this still says “Not granted” "
                + "after flipping the switch, click “Quit and reopen brosis”. If brosis is not in the "
                + "list, click “Request again”; if it still is not there, use “+” on that page to add "
                + "/Applications/brosis.app manually.")
            relaunchButton.isHidden = false
        } else if !snapshot.accessibility {
            hint.stringValue = L("在系统设置的「辅助功能」列表里把 brosis 打开即可，不需要重新启动。", "Turn brosis on in System Settings → Accessibility. No restart needed.")
            relaunchButton.isHidden = true
        } else {
            hint.stringValue = L("两项权限都已就绪。", "Both permissions are granted.")
            relaunchButton.isHidden = true
        }
        return snapshot
    }

    private func apply(granted: Bool, to field: NSTextField) {
        field.stringValue = granted ? L("✓ 已授权", "✓ Granted") : L("✗ 未授权", "✗ Not granted")
        field.textColor = granted ? .systemGreen : .systemRed
    }

    // MARK: - 动作

    @objc private func openAccessibility() {
        log("permission_guide_open_settings", "accessibility")
        Permissions.openAccessibilitySettings()
    }

    @objc private func openScreenRecording() {
        log("permission_guide_open_settings", "screen_recording")
        Permissions.openScreenRecordingSettings()
    }

    @objc private func rerequest() {
        log("permission_guide_rerequest", Permissions.snapshot().missingDescription)
        onRerequest()
        refresh()
    }

    @objc private func relaunch() {
        log("app_relaunch_requested", "来自权限引导窗口")
        PermissionGuide.relaunchApp()
    }

    @objc private func later() {
        log("permission_guide_dismissed", "用户选择稍后再说")
        close()
    }

    /// 退出当前进程并重新打开同一个 bundle：用 /bin/sh 延迟 0.7 s 再 `open -n`，
    /// 避免新旧两个实例同时在菜单栏出现。新实例仍由 launchd 负责，TCC 归属不变。
    static func relaunchApp() {
        let bundlePath = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.7; /usr/bin/open -n \"$0\"", bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopPolling()
    }

    // MARK: - 界面

    private func makeWindow() -> NSWindow {
        relaunchButton.title = L("退出并重新打开 brosis", "Quit and reopen brosis")
        let title = NSTextField(labelWithString: L("brosis 需要两项权限才能开始记录", "brosis needs two permissions before it can record"))
        title.font = .boldSystemFont(ofSize: 15)

        let intro = NSTextField(wrappingLabelWithString:
            L("刚才弹出的系统授权框只负责把你带到设置页；请在「隐私与安全性」里把下面两项打开。"
            + "这个窗口会自动检测，两项都打开后会自动开始采集。",
            "The system prompt only takes you to the settings page. Turn on both items below under "
            + "Privacy & Security. This window checks automatically and capture starts as soon as "
            + "both are on."))
        intro.textColor = .secondaryLabelColor

        let axRow = makeRow(name: L("辅助功能", "Accessibility"),
                            description: L("读取焦点窗口的标题、网址和可见正文，是文字记录的主要来源。", "Reads the focused window’s title, URL and visible text — the main source of the record."),
                            status: axStatus,
                            action: #selector(openAccessibility))
        let screenRow = makeRow(name: L("屏幕录制", "Screen Recording"),
                                description: L("按 1 秒间隔读取屏幕变化区域与窗口标题。画面不保存，只留文字与统计。", "Reads changed screen regions and window titles about once a second. Images are never saved — only text and statistics."),
                                status: screenStatus,
                                action: #selector(openScreenRecording))

        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let rerequestButton = NSButton(title: L("重新请求授权", "Request again"), target: self, action: #selector(rerequest))
        relaunchButton.target = self
        relaunchButton.action = #selector(relaunch)
        let laterButton = NSButton(title: L("稍后再说", "Later"), target: self, action: #selector(later))
        let buttons = NSStackView(views: [laterButton, NSView(), rerequestButton, relaunchButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        buttons.spacing = 8
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, intro, axRow, screenRow, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 520),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])

        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = L("brosis 权限设置", "brosis Permissions")
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.setContentSize(content.fittingSize)
        return window
    }

    private func makeRow(name: String, description: String,
                         status: NSTextField, action: Selector) -> NSView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .boldSystemFont(ofSize: 13)
        status.font = .systemFont(ofSize: 13)
        let button = NSButton(title: L("打开系统设置…", "Open System Settings…"), target: self, action: action)
        let top = NSStackView(views: [nameLabel, status, NSView(), button])
        top.orientation = .horizontal
        top.spacing = 10
        let desc = NSTextField(wrappingLabelWithString: description)
        desc.textColor = .secondaryLabelColor
        desc.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let row = NSStackView(views: [top, desc])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 4
        NSLayoutConstraint.activate([
            top.widthAnchor.constraint(equalToConstant: 480),
            desc.widthAnchor.constraint(equalToConstant: 480),
        ])
        return row
    }
}
