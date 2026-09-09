import AppKit
import BrosisCore
import Foundation

// =============================================================================
// 3.8「加密导出另有独立口令；删除不能覆盖已导出的副本，需要在 UI 里如实提示」
// + D7「满后最旧先删且删前通知并可先加密导出」的界面。
//
// **本文件不改 AppDelegate**（M2 d 批的并行约定）。接入方式只有三处，由主会话加：
//
//     // ① AppDelegate.applicationDidFinishLaunching(_:) 里，recorder 建好之后：
//     exportController = ExportController()
//     exportController.install(recorder: recorder)
//
//     // ② 菜单里加一项：
//     menu.addItem(NSMenuItem(title: "加密导出…", action: #selector(openExport), keyEquivalent: ""))
//     @objc private func openExport() { exportController?.presentWindow() }
//
//     // ③ 夜间维护 / 配额检查那一处（3.8 的「满后最旧先删」），把
//     //    `try store.expire()` 换成：
//     exportController?.expireWithNotice()
//     //    它在没确认过通知时**不删**，而是弹出这个窗口并停在"先加密导出"上。
//
// 界面上只有 3.8 / D7 明确要求的东西：目标目录、范围（时间 + 应用）、口令两次输入、
// 进度、结果，以及两段如实提示：
//   - 口令与库密钥 / 同步口令都无关，**丢了没有任何找回通道**；
//   - **删除不会影响已经导出的副本**——归档写一次不改，要让它消失只能手动删归档目录。
//
// 本轮不做、界面上也没有入口的两件事（见结果文件的"未做"）：
//   - 从窗口里导入归档（导入是恢复动作，产品路径要先想清楚"往哪个库恢复"，见 core/README）；
//   - 归档目录的自动轮转 / 清理（归档在用户自己选的位置，app 不去动它）。
// =============================================================================

@MainActor
final class ExportController {

    enum Key {
        static let lastDirectory = "export.lastDirectory"
        static let lastRangeDays = "export.lastRangeDays"
    }

    /// 界面上那三档范围。"自定义"用起止毫秒，其余两档按天数算。
    enum RangePreset: Int, CaseIterable {
        case everything = 0
        case last30Days = 30
        case last90Days = 90

        var title: String {
            switch self {
            case .everything: return L("全部（整个库）", "Everything (whole database)")
            case .last30Days: return L("最近 30 天", "Last 30 days")
            case .last90Days: return L("最近 90 天", "Last 90 days")
            }
        }
    }

    struct Progress: Sendable {
        var observations = 0
        var blocks = 0
        var bytes = 0
    }

    enum Phase: Sendable {
        case idle
        case running(Progress)
        case done(ExportOutcome)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// D7 的通知内容；`nil` = 还没查过或库没开。
    private(set) var quota: QuotaAction?

    var onChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private weak var recorder: Recorder?
    /// 加密与文件 I/O 全在这条串行队列上，绝不占主线程。
    private let queue = DispatchQueue(label: "com.brosis.export", qos: .utility)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func install(recorder: Recorder) {
        self.recorder = recorder
        refreshQuota()
    }

    // MARK: - 配额（D7）

    /// 刷新配额通知内容。库没开时置 nil。
    func refreshQuota() {
        quota = recorder?.withStore { try $0.quotaAction() }
        onChange?()
    }

    /// 3.8 的「满后最旧先删，删前通知并可先加密导出」。
    ///
    /// 没确认过通知就**不删**，把窗口弹出来停在"先加密导出"上；确认过才真的删。
    /// 返回值是给调用方（夜间维护）记日志用的一行。
    @discardableResult
    func expireWithNotice() -> String {
        guard let outcome = recorder?.withStore({ try $0.expireAfterNotice() }) else {
            return L("库没打开，跳过配额过期", "database closed — skipped quota expiry")
        }
        switch outcome {
        case .notNeeded(let action):
            quota = action
            onChange?()
            return L("配额未到线（\(Int(action.ratio * 100))%）", "under quota (\(Int(action.ratio * 100))%)")
        case .blocked(let action):
            quota = action
            onChange?()
            presentWindow()
            return L("配额已满但通知还没确认，暂不删除；已弹出加密导出窗口", "quota reached but the notice is unacknowledged — nothing deleted; the export window was opened")
        case .expired(let action, let report):
            quota = action
            refreshQuota()
            return L("配额过期已执行：删 \(report.summary?.observationsAffected ?? 0) 条，"
                     + "释放 \(report.beforeBytes - report.afterBytes) 字节",
                     "quota expiry ran: deleted \(report.summary?.observationsAffected ?? 0) records, "
                     + "freed \(report.beforeBytes - report.afterBytes) bytes")
        }
    }

    /// 用户在窗口里点了"我知道了，继续删"。
    func acknowledgeQuota(archiveID: String?) {
        _ = recorder?.withStore { try $0.acknowledgeQuotaAction(archiveID: archiveID); return true }
        refreshQuota()
    }

    // MARK: - 导出

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// 开始导出。口令只在这次调用里存在，不写 UserDefaults、不进日志、不进事件。
    func startExport(directory: URL, request: ExportRequest, passphrase: String) {
        guard !isRunning else { return }
        guard let store = recorder?.withStore({ $0 }) else {
            phase = .failed(L("库没打开（锁定中），先解锁再导出", "Database not open (locked) — unlock before exporting"))
            onChange?()
            return
        }
        // 强度门槛在这里先判一次，省得等到写文件才报（core 里也会再判一次）。
        let strength = ExportKeyring.strength(of: passphrase)
        guard strength.ok else {
            phase = .failed(L("口令不合要求：\(strength.reason ?? "")",
                                  "Passphrase does not meet the requirements: \(strength.reason ?? "")"))
            onChange?()
            return
        }
        defaults.set(directory.deletingLastPathComponent().path, forKey: Key.lastDirectory)
        phase = .running(Progress())
        onChange?()

        queue.async { [weak self] in
            do {
                let outcome = try store.exportArchive(
                    to: directory, passphrase: passphrase, request: request,
                    progress: { progress in
                        let snapshot = Progress(observations: progress.observationsWritten,
                                                blocks: progress.blocksWritten,
                                                bytes: progress.bytesWritten)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self, self.isRunning else { return }
                                self.phase = .running(snapshot)
                                self.onChange?()
                            }
                        }
                    })
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.phase = .done(outcome)
                        self.refreshQuota()
                        self.onChange?()
                    }
                }
            } catch {
                // **只把错误描述带回来**：口令绝不出现在任何一条错误里（core 的错误也不带它）。
                let message = String(describing: error)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.phase = .failed(message)
                        self.onChange?()
                    }
                }
            }
        }
    }

    /// 默认的归档目录名：`brosis-export-<yyyyMMdd-HHmm>.brosisexport`（不含主机名与用户名）。
    static func suggestedName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "brosis-export-\(formatter.string(from: now)).\(ExportFormat.directorySuffix)"
    }

    var lastDirectory: URL {
        if let path = defaults.string(forKey: Key.lastDirectory), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
    }

    // MARK: - 窗口

    private lazy var windowController = ExportWindowController()

    func presentWindow() {
        windowController.configure(controller: self)
        windowController.present()
    }
}

// MARK: - 窗口

@MainActor
final class ExportWindowController: NSObject, NSWindowDelegate {

    private weak var controller: ExportController?
    private var window: NSWindow?

    private let directoryField = NSTextField(string: "")
    private let chooseButton = NSButton(title: L("选择位置…", "Choose location…"), target: nil, action: nil)
    private let rangePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appsField = NSTextField(string: "")
    private let passphraseField = NSSecureTextField(string: "")
    private let confirmField = NSSecureTextField(string: "")
    private let strengthLabel = NSTextField(labelWithString: "")
    private let quotaLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let exportButton = NSButton(title: L("开始加密导出", "Start encrypted export"), target: nil, action: nil)
    private let acknowledgeButton = NSButton(title: L("我已了解，允许按最旧先删", "I understand — allow deleting oldest first"), target: nil, action: nil)

    private var chosenDirectory: URL?

    func configure(controller: ExportController) {
        self.controller = controller
        controller.onChange = { [weak self] in self?.reload() }
    }

    func present() {
        if window == nil { buildWindow() }
        controller?.refreshQuota()
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 构建

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("加密导出", "Encrypted export")
        window.delegate = self
        window.center()
        self.window = window

        chooseButton.target = self
        chooseButton.action = #selector(chooseDirectory(_:))
        exportButton.target = self
        exportButton.action = #selector(startExport(_:))
        acknowledgeButton.target = self
        acknowledgeButton.action = #selector(acknowledge(_:))
        directoryField.isEditable = false
        directoryField.isSelectable = true
        directoryField.lineBreakMode = .byTruncatingMiddle
        appsField.placeholderString = L("留空 = 全部应用；多个 bundle id 用逗号分隔", "Empty = all apps; separate multiple bundle ids with commas")
        passphraseField.placeholderString = L("导出口令", "Export passphrase")
        confirmField.placeholderString = L("再输一次", "Enter it again")
        passphraseField.target = self
        passphraseField.action = #selector(passphraseChanged(_:))
        confirmField.target = self
        confirmField.action = #selector(passphraseChanged(_:))
        for preset in ExportController.RangePreset.allCases {
            rangePopUp.addItem(withTitle: preset.title)
        }
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true

        for label in [strengthLabel, quotaLabel, statusLabel] {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
        }
        strengthLabel.textColor = .secondaryLabelColor
        quotaLabel.textColor = .secondaryLabelColor

        let explain = NSTextField(labelWithString: Self.explainText)
        explain.lineBreakMode = .byWordWrapping
        explain.maximumNumberOfLines = 0
        explain.textColor = .secondaryLabelColor

        let requirement = NSTextField(labelWithString: L("口令要求：", "Passphrase requirements: ")
                                     + ExportKeyring.requirementText)
        requirement.lineBreakMode = .byWordWrapping
        requirement.maximumNumberOfLines = 0
        requirement.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            explain,
            ExportBox.separator(),
            quotaLabel,
            acknowledgeButton,
            ExportBox.separator(),
            labeled(L("导出到", "Export to"), directoryField, trailing: chooseButton),
            labeled(L("范围", "Range"), rangePopUp, trailing: nil),
            labeled(L("应用", "Apps"), appsField, trailing: nil),
            labeled(L("口令", "Passphrase"), passphraseField, trailing: nil),
            labeled(L("确认", "Confirm"), confirmField, trailing: nil),
            strengthLabel,
            requirement,
            ExportBox.separator(),
            exportButton,
            progressBar,
            statusLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
                directoryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
                appsField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
                passphraseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
                confirmField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
                explain.widthAnchor.constraint(lessThanOrEqualToConstant: 590),
                requirement.widthAnchor.constraint(lessThanOrEqualToConstant: 590),
                quotaLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 590),
                statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 590),
                progressBar.widthAnchor.constraint(equalToConstant: 380),
            ])
        }
    }

    /// 窗口顶部那段如实提示（3.8 的两条要求都在这里）。
    static let explainText =
        L("把库里的记录导成一份**加密归档**（AES-256-GCM，分块，每块与整份清单都有校验）。\n"
        + "① 口令是**独立**的：与登录密码、数据库密钥、跨设备同步的配对口令都无关，"
        + "也不会存在任何地方——丢了就再也打不开这份归档，没有找回通道。\n"
        + "② 归档写一次就不再改动：**以后在 app 里删掉这些记录，不会影响已经导出的副本**。"
        + "要让归档也消失，只能你自己去把归档目录删掉。\n"
        + "③ 导出的正文就是库里那一份——入库前已经脱敏，归档不做二次脱敏、也不还原。\n"
        + "④ 不含 MCP 访问审计、采集质量遥测与同步密钥。",
          "Exports the records into an encrypted archive (AES-256-GCM, chunked, with a checksum for "
        + "every chunk and for the manifest).\n"
        + "1. The passphrase is independent: unrelated to your login password, the database key and "
        + "the cross-device pairing passphrase. It is not stored anywhere — lose it and the archive "
        + "can never be opened again. There is no recovery path.\n"
        + "2. An archive is written once and never modified: deleting these records in the app later "
        + "does not affect the exported copy. To make the archive go away you must delete it yourself.\n"
        + "3. The exported text is exactly what is in the database — already redacted before storage. "
        + "The archive neither re-redacts nor restores anything.\n"
        + "4. It excludes MCP access audits, capture-quality telemetry and sync keys.")

    private func labeled(_ title: String, _ field: NSView, trailing: NSView?) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        var views: [NSView] = [label, field]
        if let trailing { views.append(trailing) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: - 动作

    @objc private func chooseDirectory(_ sender: Any?) {
        guard let controller else { return }
        let panel = NSSavePanel()
        panel.title = L("选择归档保存位置", "Choose where to save the archive")
        panel.prompt = L("导出", "Export")
        panel.nameFieldStringValue = ExportController.suggestedName()
        panel.directoryURL = controller.lastDirectory
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosenDirectory = url
        directoryField.stringValue = url.path
        reload()
    }

    @objc private func passphraseChanged(_ sender: Any?) { reload() }

    @objc private func acknowledge(_ sender: Any?) {
        controller?.acknowledgeQuota(archiveID: currentArchiveID)
    }

    private var currentArchiveID: String? {
        guard let controller else { return nil }
        if case .done(let outcome) = controller.phase { return outcome.archiveID }
        return controller.quota?.lastExportArchiveID
    }

    @objc private func startExport(_ sender: Any?) {
        guard let controller, let directory = chosenDirectory else {
            statusLabel.stringValue = "先选一个保存位置"
            return
        }
        let passphrase = passphraseField.stringValue
        guard passphrase == confirmField.stringValue else {
            statusLabel.stringValue = "两次输入的口令不一样"
            return
        }
        var request = ExportRequest()
        let preset = ExportController.RangePreset.allCases[rangePopUp.indexOfSelectedItem]
        if preset != .everything {
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            request.start = now - Int64(preset.rawValue) * 86_400_000
            request.end = now
        }
        request.apps = appsField.stringValue.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        controller.startExport(directory: directory, request: request, passphrase: passphrase)
        // 口令用完就从界面上清掉，不留在文本框里。
        passphraseField.stringValue = ""
        confirmField.stringValue = ""
    }

    // MARK: - 刷新

    private func reload() {
        guard window != nil, let controller else { return }
        if directoryField.stringValue.isEmpty, let directory = chosenDirectory {
            directoryField.stringValue = directory.path
        }
        let strength = ExportKeyring.strength(of: passphraseField.stringValue)
        if passphraseField.stringValue.isEmpty {
            strengthLabel.stringValue = ""
        } else {
            strengthLabel.stringValue = strength.ok
                ? "口令强度：够了（\(strength.length) 字符 / \(strength.classes) 类字符）"
                : "口令强度：\(strength.reason ?? "")"
        }

        if let quota = controller.quota {
            quotaLabel.stringValue = quota.message
            acknowledgeButton.isHidden = quota.level != .full || quota.acknowledgedAt != nil
        } else {
            quotaLabel.stringValue = "库没打开（锁定中），看不到存储用量。"
            acknowledgeButton.isHidden = true
        }

        exportButton.isEnabled = !controller.isRunning && chosenDirectory != nil
        switch controller.phase {
        case .idle:
            progressBar.isHidden = true
            statusLabel.stringValue = strengthLabel.stringValue
        case .running(let progress):
            progressBar.isHidden = false
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            statusLabel.stringValue = "正在导出：已写 \(progress.observations) 条观察、"
                + "\(progress.blocks) 块、\(progress.bytes) 字节…"
        case .done(let outcome):
            progressBar.stopAnimation(nil)
            progressBar.isHidden = true
            statusLabel.stringValue = Self.doneText(outcome)
        case .failed(let message):
            progressBar.stopAnimation(nil)
            progressBar.isHidden = true
            statusLabel.stringValue = "导出失败：\(message)"
        }
    }

    /// 结果文案：说清楚导了什么、在哪、以及"删除不影响它"。
    static func doneText(_ outcome: ExportOutcome) -> String {
        "导出完成：\(outcome.counts.observations) 条观察（其中已删除的墓碑 "
        + "\(outcome.counts.tombstonedObservations) 条）、\(outcome.counts.textVersions) 段正文、"
        + "\(outcome.counts.sessions) 条会话、\(outcome.counts.ledgers) 张台账，"
        + "共 \(outcome.blocks) 块 / \(outcome.archiveBytes) 字节。\n"
        + "归档编号 \(outcome.archiveID)，位置：\(outcome.directory)\n"
        + "这份副本从现在起独立存在：以后在 app 里删除记录**不会**影响它，"
        + "要让它消失请自己删掉这个目录。口令没有存在任何地方，请自行妥善保管。"
    }

    func windowWillClose(_ notification: Notification) {
        passphraseField.stringValue = ""
        confirmField.stringValue = ""
    }
}

@MainActor
private enum ExportBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
