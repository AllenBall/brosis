import AppKit
import BrosisCore
import Foundation

/// 「设置」窗口（2026-09-08 / D34）。基础设置集中在这里，重点是**最多占用磁盘**。
///
/// 只放"改了立刻有意义"的项；模型、MCP、同步、采集清单各有自己的窗口，不在这里重复。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private weak var recorder: Recorder?
    private var window: NSWindow?
    private var quotaField: NSTextField?
    private var quotaStepper: NSStepper?
    private var usageLabel: NSTextField?
    private var autoExpireSwitch: NSButton?
    private var periodicField: NSTextField?
    private var gpuField: NSTextField?
    private var autoIndexSwitch: NSButton?
    private var intervalField: NSTextField?
    private var vectorsSwitch: NSButton?
    private var strictLockSwitch: NSButton?
    private var noteLabel: NSTextField?
    private var lastAction: String?

    func configure(recorder: Recorder) { self.recorder = recorder }

    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "设置…", action: #selector(openFromMenu(_:)), keyEquivalent: ",")
        item.target = SettingsWindowController.shared
        return item
    }

    @objc private func openFromMenu(_ sender: Any?) { present() }

    func present() {
        if window == nil { buildWindow() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 窗口

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "brosis 设置"
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        var y = 386.0

        func section(_ title: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: 13)
            label.frame = NSRect(x: 20, y: y, width: 520, height: 18)
            content.addSubview(label)
            y -= 26
        }
        func row(_ title: String, _ control: NSView, note: String? = nil) {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.frame = NSRect(x: 20, y: y + 2, width: 170, height: 18)
            content.addSubview(label)
            control.frame.origin = CGPoint(x: 200, y: y)
            content.addSubview(control)
            if let note {
                let hint = NSTextField(labelWithString: note)
                hint.textColor = .secondaryLabelColor
                hint.font = .systemFont(ofSize: 11)
                hint.frame = NSRect(x: 200 + control.frame.width + 8, y: y + 2,
                                    width: 540 - (200 + control.frame.width + 8), height: 16)
                content.addSubview(hint)
            }
            y -= 28
        }

        // ---- 存储
        section("存储")
        let quota = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        quota.alignment = .right
        quota.target = self
        quota.action = #selector(quotaChanged)
        quotaField = quota
        let stepper = NSStepper(frame: NSRect(x: 0, y: 0, width: 16, height: 22))
        stepper.minValue = Settings.quotaGiBRange.lowerBound
        stepper.maxValue = Settings.quotaGiBRange.upperBound
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(quotaStepped)
        quotaStepper = stepper
        let quotaBox = NSView(frame: NSRect(x: 0, y: 0, width: 104, height: 22))
        quotaBox.addSubview(quota)
        stepper.frame.origin = CGPoint(x: 84, y: 0)
        quotaBox.addSubview(stepper)
        row("最多占用磁盘", quotaBox, note: "GiB · 指原文净载荷，不含索引与 WAL")

        let usage = NSTextField(labelWithString: "")
        usage.frame = NSRect(x: 0, y: 0, width: 340, height: 32)
        usage.lineBreakMode = .byWordWrapping
        usage.maximumNumberOfLines = 2
        usage.font = .systemFont(ofSize: 11)
        usage.textColor = .secondaryLabelColor
        usageLabel = usage
        row("当前用量", usage)
        y -= 6

        let autoExpire = NSButton(checkboxWithTitle: "到线后自动清理最旧的原文（关掉就只提示不删）",
                                  target: self, action: #selector(autoExpireToggled))
        autoExpire.frame = NSRect(x: 0, y: 0, width: 340, height: 20)
        autoExpireSwitch = autoExpire
        row("", autoExpire)

        let checkNow = NSButton(title: "现在检查并清理", target: self, action: #selector(checkNowClicked))
        checkNow.frame = NSRect(x: 0, y: 0, width: 130, height: 24)
        row("", checkNow)

        // ---- 采集
        section("采集")
        let periodic = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        periodic.alignment = .right
        periodic.target = self
        periodic.action = #selector(periodicChanged)
        periodicField = periodic
        row("定时兜底截图", periodic, note: "秒 · 3–120，事件触发之外的保底")

        let strict = NSButton(checkboxWithTitle: "锁屏时直接关库（不只是暂停采集）",
                              target: self, action: #selector(strictLockToggled))
        strict.frame = NSRect(x: 0, y: 0, width: 320, height: 20)
        strictLockSwitch = strict
        row("", strict)

        // ---- 索引与检索
        section("索引与检索")
        let vectors = NSButton(checkboxWithTitle: "在检索里使用向量（没装模型时强制关）",
                               target: self, action: #selector(vectorsToggled))
        vectors.frame = NSRect(x: 0, y: 0, width: 330, height: 20)
        vectorsSwitch = vectors
        row("", vectors)

        let autoIndex = NSButton(checkboxWithTitle: "打开时与每隔一段时间自动建索引",
                                 target: self, action: #selector(autoIndexToggled))
        autoIndex.frame = NSRect(x: 0, y: 0, width: 330, height: 20)
        autoIndexSwitch = autoIndex
        row("", autoIndex)

        let interval = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        interval.alignment = .right
        interval.target = self
        interval.action = #selector(intervalChanged)
        intervalField = interval
        row("自动建索引间隔", interval, note: "分钟 · 下限 5")

        let gpu = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        gpu.alignment = .right
        gpu.target = self
        gpu.action = #selector(gpuChanged)
        gpuField = gpu
        row("日均 GPU 预算", gpu, note: "秒 · 夜间增量任务用，整晚建索引另算")

        let note = NSTextField(labelWithString: "")
        note.frame = NSRect(x: 20, y: 12, width: 520, height: 32)
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 2
        content.addSubview(note)
        noteLabel = note

        window.contentView = content
        self.window = window
    }

    // MARK: - 读写

    private func reload() {
        quotaField?.doubleValue = Settings.quotaGiB
        quotaStepper?.doubleValue = Settings.quotaGiB
        autoExpireSwitch?.state = Settings.autoExpire ? .on : .off
        periodicField?.doubleValue = Settings.periodicInterval
        strictLockSwitch?.state = Settings.strictLock ? .on : .off
        vectorsSwitch?.state = Settings.vectorsEnabled ? .on : .off
        autoIndexSwitch?.state = Settings.autoIndex ? .on : .off
        intervalField?.doubleValue = Settings.autoIndexIntervalMinutes
        gpuField?.doubleValue = Settings.dailyGPUSeconds

        let action = recorder?.withStore { try $0.quotaAction() } ?? nil
        usageLabel?.stringValue = action?.message ?? "库没打开，用量未知（解锁后再看）"
        noteLabel?.stringValue = (lastAction.map { $0 + " · " } ?? "")
            + "上次配额检查：\(QuotaScheduler.shared.lastNote)"
    }

    /// 配额改了要**立刻推给正在开着的库**，否则要等下次开库才生效。
    private func applyQuota(_ giB: Double) {
        Settings.quotaGiB = giB
        _ = recorder?.withStore { $0.setQuotaBytes(Settings.quotaBytes) }
        recorder?.logEvent(kind: "settings_changed",
                           detail: "storage.quotaGiB=\(Settings.quotaGiB)")
        lastAction = "配额已设为 \(String(format: "%.0f", Settings.quotaGiB)) GiB"
        reload()
    }

    @objc private func quotaChanged() { applyQuota(quotaField?.doubleValue ?? Settings.quotaGiB) }
    @objc private func quotaStepped() { applyQuota(quotaStepper?.doubleValue ?? Settings.quotaGiB) }

    @objc private func autoExpireToggled() {
        Settings.autoExpire = autoExpireSwitch?.state == .on
        lastAction = Settings.autoExpire ? "自动清理已开" : "自动清理已关（到线只提示不删）"
        recorder?.logEvent(kind: "settings_changed", detail: "storage.autoExpire=\(Settings.autoExpire)")
        reload()
    }

    @objc private func checkNowClicked() {
        lastAction = QuotaScheduler.shared.checkNow()
        reload()
    }

    @objc private func periodicChanged() {
        Settings.periodicInterval = periodicField?.doubleValue ?? Settings.periodicInterval
        lastAction = "定时兜底改为 \(String(format: "%.0f", Settings.periodicInterval)) s（下次起流生效）"
        recorder?.logEvent(kind: "settings_changed",
                           detail: "capture.periodicInterval=\(Settings.periodicInterval)")
        reload()
    }

    @objc private func strictLockToggled() {
        Settings.strictLock = strictLockSwitch?.state == .on
        lastAction = "严格锁屏：\(Settings.strictLock ? "开" : "关")"
        reload()
    }

    @objc private func vectorsToggled() {
        Settings.vectorsEnabled = vectorsSwitch?.state == .on
        QueryEmbedderService.shared.setVectorsEnabled(Settings.vectorsEnabled,
                                                      store: recorder?.withStore { $0 } ?? nil)
        lastAction = "向量检索：\(Settings.vectorsEnabled ? "开" : "关")"
        reload()
    }

    @objc private func autoIndexToggled() {
        Settings.autoIndex = autoIndexSwitch?.state == .on
        if Settings.autoIndex { AutoIndexScheduler.shared.start() } else { AutoIndexScheduler.shared.stop() }
        lastAction = "自动建索引：\(Settings.autoIndex ? "开" : "关")"
        reload()
    }

    @objc private func intervalChanged() {
        Settings.autoIndexIntervalMinutes = intervalField?.doubleValue ?? Settings.autoIndexIntervalMinutes
        AutoIndexScheduler.shared.stop()
        if Settings.autoIndex { AutoIndexScheduler.shared.start() }
        lastAction = "自动建索引间隔改为 \(Int(Settings.autoIndexIntervalMinutes)) 分钟"
        reload()
    }

    @objc private func gpuChanged() {
        Settings.dailyGPUSeconds = gpuField?.doubleValue ?? Settings.dailyGPUSeconds
        lastAction = "日均 GPU 预算改为 \(Int(Settings.dailyGPUSeconds)) s"
        reload()
    }
}
