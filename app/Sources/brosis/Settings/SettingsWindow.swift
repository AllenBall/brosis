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
    //
    // 用 NSGridView + NSBox 排版，不再手工算坐标：上一版每行固定 28pt、而"当前用量"是个
    // 32pt 的两行字段，直接压到上一行去了（截图上看得很清楚）。网格自己对齐标签列与控件列，
    // 分组框给出原生的视觉分区，窗口高度由内容撑出来。

    private func buildWindow() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 14, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // ---------------------------------------------------------------- 存储
        let quota = numberField(width: 72)
        quota.action = #selector(quotaChanged)
        quotaField = quota
        let stepper = NSStepper()
        stepper.minValue = Settings.quotaGiBRange.lowerBound
        stepper.maxValue = Settings.quotaGiBRange.upperBound
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(quotaStepped)
        quotaStepper = stepper
        let quotaRow = NSStackView(views: [quota, stepper, unit("GiB")])
        quotaRow.orientation = .horizontal
        quotaRow.spacing = 6
        quotaRow.alignment = .centerY

        let usage = NSTextField(wrappingLabelWithString: "")
        usage.font = .systemFont(ofSize: 11)
        usage.textColor = .secondaryLabelColor
        usage.preferredMaxLayoutWidth = 330
        usageLabel = usage

        let autoExpire = NSButton(checkboxWithTitle: "到线后自动清理最旧的原文（关掉就只提示不删）",
                                  target: self, action: #selector(autoExpireToggled))
        autoExpireSwitch = autoExpire
        let checkNow = NSButton(title: "现在检查并清理", target: self, action: #selector(checkNowClicked))
        checkNow.bezelStyle = .rounded

        stack.addArrangedSubview(section("存储", rows: [
            Row(label: "最多占用磁盘", control: quotaRow,
                hint: "口径是原文净载荷——FTS 索引、向量、WAL 都不算在内，所以磁盘上的文件会比这个数大"),
            Row(label: "当前用量", control: usage),
            Row(label: nil, control: autoExpire),
            Row(label: nil, control: checkNow),
        ]))

        // ---------------------------------------------------------------- 采集
        let periodic = numberField(width: 72)
        periodic.action = #selector(periodicChanged)
        periodicField = periodic
        let periodicRow = NSStackView(views: [periodic, unit("秒")])
        periodicRow.orientation = .horizontal
        periodicRow.spacing = 6
        periodicRow.alignment = .centerY

        let strict = NSButton(checkboxWithTitle: "锁屏时直接关库（不只是暂停采集）",
                              target: self, action: #selector(strictLockToggled))
        strictLockSwitch = strict

        stack.addArrangedSubview(section("采集", rows: [
            Row(label: "定时兜底截图", control: periodicRow,
                hint: "3–120 秒。事件触发之外的保底，间隔越短越费电"),
            Row(label: nil, control: strict),
        ]))

        // ---------------------------------------------------------------- 索引与检索
        let vectors = NSButton(checkboxWithTitle: "在检索里使用向量（没装模型时强制关）",
                               target: self, action: #selector(vectorsToggled))
        vectorsSwitch = vectors
        let autoIndex = NSButton(checkboxWithTitle: "打开时与每隔一段时间自动建索引",
                                 target: self, action: #selector(autoIndexToggled))
        autoIndexSwitch = autoIndex

        let interval = numberField(width: 72)
        interval.action = #selector(intervalChanged)
        intervalField = interval
        let intervalRow = NSStackView(views: [interval, unit("分钟")])
        intervalRow.orientation = .horizontal
        intervalRow.spacing = 6
        intervalRow.alignment = .centerY

        let gpu = numberField(width: 72)
        gpu.action = #selector(gpuChanged)
        gpuField = gpu
        let gpuRow = NSStackView(views: [gpu, unit("秒")])
        gpuRow.orientation = .horizontal
        gpuRow.spacing = 6
        gpuRow.alignment = .centerY

        stack.addArrangedSubview(section("索引与检索", rows: [
            Row(label: nil, control: vectors),
            Row(label: nil, control: autoIndex),
            Row(label: "自动建索引间隔", control: intervalRow, hint: "下限 5 分钟"),
            Row(label: "日均 GPU 预算", control: gpuRow, hint: "夜间增量任务用；「现在开始建索引」另有一本账"),
        ]))

        // ---------------------------------------------------------------- 底部状态
        let note = NSTextField(wrappingLabelWithString: "")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 500
        noteLabel = note
        stack.addArrangedSubview(note)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "brosis 设置"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setContentSize(stack.fittingSize)
        window.center()
        self.window = window
    }

    /// 一行：标签（可空，空的话控件从控件列开始）、控件、可选的灰色说明。
    private struct Row {
        var label: String?
        var control: NSView
        var hint: String?
    }

    /// 一个分组：标题 + 网格。网格负责把标签列右对齐、控件列左对齐。
    private func section(_ title: String, rows: [Row]) -> NSView {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        box.boxType = .primary
        box.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.rowAlignment = .firstBaseline

        for row in rows {
            let label = NSTextField(labelWithString: row.label.map { $0 + "：" } ?? "")
            let gridRow = grid.addRow(with: [label, row.control])
            gridRow.yPlacement = .center
            if let hint = row.hint {
                let hintLabel = NSTextField(wrappingLabelWithString: hint)
                hintLabel.font = .systemFont(ofSize: 11)
                hintLabel.textColor = .secondaryLabelColor
                hintLabel.preferredMaxLayoutWidth = 330
                let hintRow = grid.addRow(with: [NSGridCell.emptyContentView, hintLabel])
                hintRow.topPadding = -2
                hintRow.bottomPadding = 2
            }
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        box.contentView = container
        return box
    }

    private func numberField(width: CGFloat) -> NSTextField {
        let field = NSTextField()
        field.alignment = .right
        field.target = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    private func unit(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
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
