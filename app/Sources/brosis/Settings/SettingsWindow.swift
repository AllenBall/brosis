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
    private var registeredLanguageHandler = false
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
    /// 最近一次配额检查的结果，只在真查过之后才有值（查一次很贵，见 reload 的注释）。
    private var lastQuota: QuotaAction?

    func configure(recorder: Recorder) { self.recorder = recorder }

    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("设置…", "Settings…"), action: #selector(openFromMenu(_:)), keyEquivalent: ",")
        item.target = SettingsWindowController.shared
        return item
    }

    @objc private func openFromMenu(_ sender: Any?) { present() }

    func present() {
        if window == nil { buildWindow() }
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
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 窗口
    //
    // **手工坐标，自上而下排**。上一版试过 NSGridView + NSBox，结果盒子塌成只剩标题
    // （contentView 设成 TAMIC=false 的容器后没人给约束）、窗口又按布局前的 fittingSize
    // 缩成一小块。再上一版是手工排但假定每行都 28pt，两行高的「当前用量」压到上一行去了。
    //
    // 这一版的做法：先按"距顶部多少"把每个控件排好（每行的高度由内容决定，不是固定值），
    // 最后一次性换算成 AppKit 的左下原点坐标。全是算术，没有约束求解，结果可预测。

    private enum Metrics {
        static let windowWidth = 620.0
        static let margin = 20.0
        static let labelWidth = 150.0
        static let gap = 12.0
        static var controlX: Double { margin + labelWidth + gap }
        static var controlWidth: Double { windowWidth - controlX - margin }
        static let controlHeight = 24.0
        static let checkboxHeight = 20.0
        static let hintHeight = 16.0
        static let usageHeight = 34.0
        static let rowGap = 10.0
        static let sectionGapAbove = 16.0
        static let sectionHeaderHeight = 18.0
        static let sectionGapBelow = 10.0
    }

    /// 排版游标：只管"距顶部多少"，最后统一翻转成 AppKit 坐标。
    /// 嵌套类型不继承外层的 @MainActor，而它要建 AppKit 视图，所以显式标上。
    @MainActor
    private final class Layout {
        private(set) var top = Metrics.margin
        private var placed: [(NSView, Double, Double)] = []   // (view, top, height)
        private var first = true

        func section(_ title: String) {
            if !first { top += Metrics.sectionGapAbove }
            first = false
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            place(label, x: Metrics.margin, width: Metrics.windowWidth - 2 * Metrics.margin,
                  height: Metrics.sectionHeaderHeight)
            top += Metrics.sectionHeaderHeight + Metrics.sectionGapBelow
        }

        /// 一行：左边标签（可空）、右边控件。控件高度由调用方给。
        func row(_ title: String?, _ control: NSView, height: Double) {
            if let title {
                let label = NSTextField(labelWithString: title + "：")
                label.alignment = .right
                // 标签与控件按各自高度居中对齐，行高取两者较大的那个。
                let labelHeight = 17.0
                place(label, x: Metrics.margin, width: Metrics.labelWidth, height: labelHeight,
                      offset: (height - labelHeight) / 2)
            }
            place(control, x: Metrics.controlX, width: control.frame.width > 0
                  ? Double(control.frame.width) : Metrics.controlWidth, height: height)
            top += height + Metrics.rowGap
        }

        /// 灰色小字说明，挂在上一行控件正下方。长的给 2 行，别截成「…」。
        func hint(_ text: String, lines: Int = 1) {
            top -= Metrics.rowGap - 2
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = lines
            let height = Metrics.hintHeight * Double(lines)
            place(label, x: Metrics.controlX, width: Metrics.controlWidth, height: height)
            top += height + Metrics.rowGap
        }

        private func place(_ view: NSView, x: Double, width: Double, height: Double,
                           offset: Double = 0) {
            view.frame = NSRect(x: x, y: 0, width: width, height: height)
            placed.append((view, top + offset, height))
        }

        /// 收尾：算出总高，把所有 top 翻成 AppKit 的 y，装进一个 content view。
        func finish() -> NSView {
            let total = top - Metrics.rowGap + Metrics.margin
            let content = NSView(frame: NSRect(x: 0, y: 0, width: Metrics.windowWidth, height: total))
            for (view, top, height) in placed {
                view.frame.origin.y = total - top - height
                content.addSubview(view)
            }
            return content
        }
    }

    private func buildWindow() {
        let layout = Layout()

        // ---------------------------------------------------------------- 存储
        layout.section(L("通用", "General"))

        let language = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200,
                                                   height: Metrics.controlHeight))
        for option in UILanguage.allCases { language.addItem(withTitle: option.displayName) }
        language.selectItem(at: UILanguage.allCases.firstIndex(of: L10n.preference) ?? 0)
        language.target = self
        language.action = #selector(languageChanged)
        layout.row(L("界面语言", "Language"), language, height: Metrics.controlHeight)
        layout.hint(L("跟随系统时按系统语言判断：中文系统用中文，其余用英文。"
                      + "自检与命令行输出始终是中文（面向开发排障）。",
                      "\"Follow system\" uses Chinese on a Chinese system and English otherwise. "
                      + "Self-check and command-line output stay in Chinese (they are for debugging)."),
                    lines: 2)

        layout.section(L("存储", "Storage"))

        let quota = numberField(width: 76)
        quota.action = #selector(quotaChanged)
        quotaField = quota
        let stepper = NSStepper(frame: NSRect(x: 80, y: 0, width: 16, height: 24))
        stepper.minValue = Settings.quotaGiBRange.lowerBound
        stepper.maxValue = Settings.quotaGiBRange.upperBound
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(quotaStepped)
        quotaStepper = stepper
        let unitLabel = NSTextField(labelWithString: "GiB")
        unitLabel.textColor = .secondaryLabelColor
        unitLabel.frame = NSRect(x: 104, y: 3, width: 40, height: 17)
        let quotaRow = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: Metrics.controlHeight))
        quotaRow.addSubview(quota)
        quotaRow.addSubview(stepper)
        quotaRow.addSubview(unitLabel)
        layout.row(L("最多占用磁盘", "Disk limit"), quotaRow, height: Metrics.controlHeight)
        layout.hint(L("口径是原文净载荷——FTS 索引、向量、WAL 都不算在内，所以磁盘上的实际文件会比这个数大", "Counts raw text payload only — FTS index, vectors and WAL are excluded, so the files on disk are larger than this number"),
                    lines: 2)

        // labelWithString("") 会把自己缩成几个 pt 宽，进 row() 后文字被裁到一个字不剩，
        // 所以这里**显式给足宽度**（0.2.5 的「当前用量」和底部状态就是这么消失的）。
        let usage = NSTextField(wrappingLabelWithString: "")
        usage.font = .systemFont(ofSize: 11)
        usage.textColor = .secondaryLabelColor
        usage.maximumNumberOfLines = 2
        usage.frame = NSRect(x: 0, y: 0, width: Metrics.controlWidth, height: Metrics.usageHeight)
        usageLabel = usage
        layout.row(L("当前用量", "Current usage"), usage, height: Metrics.usageHeight)

        let autoExpire = NSButton(checkboxWithTitle: L("到线后自动清理最旧的原文（关掉就只提示不删）", "Delete the oldest text when the limit is reached (off: warn only, never delete)"),
                                  target: self, action: #selector(autoExpireToggled))
        autoExpireSwitch = autoExpire
        layout.row(nil, autoExpire, height: Metrics.checkboxHeight)

        let checkNow = NSButton(title: L("现在检查并清理", "Check and clean now"), target: self, action: #selector(checkNowClicked))
        checkNow.bezelStyle = .rounded
        checkNow.frame = NSRect(x: 0, y: 0, width: 130, height: 26)
        layout.row(nil, checkNow, height: 26)

        // ---------------------------------------------------------------- 采集
        layout.section(L("采集", "Capture"))

        let periodic = numberField(width: 76)
        periodic.action = #selector(periodicChanged)
        periodicField = periodic
        layout.row(L("定时兜底截图", "Fallback screenshot interval"), withUnit(periodic, L("秒", "s")), height: Metrics.controlHeight)
        layout.hint(L("3–120 秒。事件触发之外的保底，间隔越短越费电", "3–120 seconds. A safety net beyond event triggers; shorter intervals use more power"))

        let strict = NSButton(checkboxWithTitle: L("锁屏时直接关库（不只是暂停采集）", "Close the database on screen lock (not just pause capture)"),
                              target: self, action: #selector(strictLockToggled))
        strictLockSwitch = strict
        layout.row(nil, strict, height: Metrics.checkboxHeight)

        // ---------------------------------------------------------------- 索引与检索
        layout.section(L("索引与检索", "Indexing and search"))

        let vectors = NSButton(checkboxWithTitle: L("在检索里使用向量（没装模型时强制关）", "Use vectors in search (forced off when no model is installed)"),
                               target: self, action: #selector(vectorsToggled))
        vectorsSwitch = vectors
        layout.row(nil, vectors, height: Metrics.checkboxHeight)

        let autoIndex = NSButton(checkboxWithTitle: L("打开时与每隔一段时间自动建索引", "Build the index on launch and periodically"),
                                 target: self, action: #selector(autoIndexToggled))
        autoIndexSwitch = autoIndex
        layout.row(nil, autoIndex, height: Metrics.checkboxHeight)

        let interval = numberField(width: 76)
        interval.action = #selector(intervalChanged)
        intervalField = interval
        layout.row(L("自动建索引间隔", "Auto-index interval"), withUnit(interval, L("分钟", "min")), height: Metrics.controlHeight)
        layout.hint(L("下限 5 分钟", "Minimum 5 minutes"))

        let gpu = numberField(width: 76)
        gpu.action = #selector(gpuChanged)
        gpuField = gpu
        layout.row(L("日均 GPU 预算", "Daily GPU budget"), withUnit(gpu, L("秒", "s")), height: Metrics.controlHeight)
        layout.hint(L("夜间增量任务用；「现在开始建索引」另有一本账", "For the nightly incremental job; “Build index now” has its own budget"))

        // ---------------------------------------------------------------- 底部状态
        let note = NSTextField(wrappingLabelWithString: "")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2
        note.frame = NSRect(x: 0, y: 0, width: Metrics.controlWidth, height: 30)
        noteLabel = note
        layout.row(nil, note, height: 30)

        let content = layout.finish()
        let window = NSWindow(contentRect: content.frame,
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("brosis 设置", "brosis Settings")
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        self.window = window
    }

    /// 输入框 + 灰色单位，打包成一个定宽小容器。
    private func withUnit(_ field: NSTextField, _ unit: String) -> NSView {
        let label = NSTextField(labelWithString: unit)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 84, y: 3, width: 60, height: 17)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 150, height: Metrics.controlHeight))
        box.addSubview(field)
        box.addSubview(label)
        return box
    }

    private func numberField(width: Double) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.controlHeight))
        field.alignment = .right
        field.target = self
        return field
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

        // **不在这里查配额**：`quotaAction()` 会对 text_versions 做一次 SUM(byte_len) 全表扫描，
        // 而 text_versions 没有覆盖 byte_len 的索引、行里还带着正文，SQLCipher 要逐页解密，
        // 整个过程还占着 Store 的锁（采集写入被挡住）。以前每个 handler 都调 reload()，
        // 点一下步进器就扫一遍。现在只显示最近一次检查的结果，要新的就点「现在检查并清理」。
        usageLabel?.stringValue = lastQuota?.message ?? L("点「现在检查并清理」查看当前用量", "Click “Check and clean now” to see current usage")
        noteLabel?.stringValue = L("上次配额检查：\(lastAction ?? QuotaScheduler.shared.lastNote)",
                                   "Last quota check: \(lastAction ?? QuotaScheduler.shared.lastNote)")
    }

    /// 配额只写设置——判定与清理时由调用方把它作为参数传给 core
    /// （`quotaAction(quota:)` / `expire(toBytes:)`），库里不留可变副本。
    private func applyQuota(_ giB: Double) {
        Settings.quotaGiB = giB
        recorder?.logEvent(kind: "settings_changed",
                           detail: "storage.quotaGiB=\(Settings.quotaGiB)")
        lastAction = L("配额已设为 \(String(format: "%.0f", Settings.quotaGiB)) GiB",
                       "Disk limit set to \(String(format: "%.0f", Settings.quotaGiB)) GiB")
        reload()
    }

    /// 换语言：存下来 → 广播 → 登记过的窗口自己关掉，重开即新语言。
    /// 直接用 sender 的选中序号取值，与 `PoliciesWindow.globalDefaultChanged` 同一写法——
    /// 不额外存一个 popup 的 ivar，也不靠 representedObject 再解析一遍 rawValue。
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < UILanguage.allCases.count else { return }
        L10n.set(UILanguage.allCases[index])
    }

    @objc private func quotaChanged() { applyQuota(quotaField?.doubleValue ?? Settings.quotaGiB) }
    @objc private func quotaStepped() { applyQuota(quotaStepper?.doubleValue ?? Settings.quotaGiB) }

    @objc private func autoExpireToggled() {
        Settings.autoExpire = autoExpireSwitch?.state == .on
        lastAction = Settings.autoExpire ? L("自动清理已开", "Auto-clean on") : L("自动清理已关（到线只提示不删）", "Auto-clean off (warn only at the limit)")
        recorder?.logEvent(kind: "settings_changed", detail: "storage.autoExpire=\(Settings.autoExpire)")
        reload()
    }

    /// 扫描搬到后台队列：它是全表扫 + 解密 + 占 Store 锁，放主线程会卡住菜单栏。
    @objc private func checkNowClicked() {
        lastAction = L("正在检查…", "Checking…")
        reload()
        QuotaScheduler.shared.checkNowAsync { [weak self] note, action in
            self?.lastAction = note
            self?.lastQuota = action
            self?.reload()
        }
    }

    @objc private func periodicChanged() {
        Settings.periodicInterval = periodicField?.doubleValue ?? Settings.periodicInterval
        // CaptureController 的间隔是 `private static let` 一次性解析并缓存的，
        // 写 UserDefaults 不会让本进程重读——如实说要重启，别写"下次起流生效"。
        lastAction = L("定时兜底改为 \(String(format: "%.0f", Settings.periodicInterval)) s（重启 brosis 后生效）",
                       "Fallback interval set to \(String(format: "%.0f", Settings.periodicInterval))s "
                       + "(takes effect after restarting brosis)")
        recorder?.logEvent(kind: "settings_changed",
                           detail: "capture.periodicInterval=\(Settings.periodicInterval)")
        reload()
    }

    @objc private func strictLockToggled() {
        Settings.strictLock = strictLockSwitch?.state == .on
        lastAction = L("严格锁屏：", "Strict lock: ") + LOnOff(Settings.strictLock)
        reload()
    }

    // 这三个开关的副作用（推 store.retrieval、起停定时器、重建 timer）都在拥有者的
    // setter 里，两个窗口都只调这一个入口——以前两边各写一遍，向量那份还漏了 store.retrieval。
    @objc private func vectorsToggled() {
        QueryEmbedderService.shared.setVectorsEnabled(vectorsSwitch?.state == .on,
                                                      store: recorder?.withStore { $0 } ?? nil)
        lastAction = L("向量检索：", "Vector search: ") + LOnOff(Settings.vectorsEnabled)
        reload()
    }

    @objc private func autoIndexToggled() {
        Settings.autoIndex = autoIndexSwitch?.state == .on
        lastAction = L("自动建索引：", "Auto-index: ") + LOnOff(Settings.autoIndex)
        reload()
    }

    @objc private func intervalChanged() {
        Settings.autoIndexIntervalMinutes = intervalField?.doubleValue ?? Settings.autoIndexIntervalMinutes
        lastAction = L("自动建索引间隔改为 \(Int(Settings.autoIndexIntervalMinutes)) 分钟",
                       "Auto-index interval set to \(Int(Settings.autoIndexIntervalMinutes)) min")
        reload()
    }

    @objc private func gpuChanged() {
        Settings.dailyGPUSeconds = gpuField?.doubleValue ?? Settings.dailyGPUSeconds
        lastAction = L("日均 GPU 预算改为 \(Int(Settings.dailyGPUSeconds)) s",
                       "Daily GPU budget set to \(Int(Settings.dailyGPUSeconds))s")
        reload()
    }
}
