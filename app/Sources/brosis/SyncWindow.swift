import AppKit
import BrosisSync
import Foundation

// =============================================================================
// D17 / 3.9 的设置界面：一个开关 + 目录 + 配对口令 + 状态显示。
//
// **本文件不改 AppDelegate**：窗口由 `SyncController.presentWindow()` 拉起，
// 接入方式见 SyncController.swift 的文件头。
//
// 界面上只有 3.9 明确要求的东西：
//   - 开关（默认关）；
//   - 目录（默认 iCloud Drive/brosis-sync/，高级选项可改成任意同步盘 / NAS）；
//   - 首台把配对口令**显示一次**（可拷贝），新机输入口令加入；
//   - 状态：上次同步时间、待导出与待导入段数、其他设备最后出现时间、错误。
//
// 本轮不做的两件事，界面上也没有入口（见结果文件的"未做"）：
//   - iCloud 钥匙串自动同步密钥（要真人点钥匙串授权，本轮不允许触发）；
//   - "退出并删除本机段文件"。
// =============================================================================

@MainActor
final class SyncWindowController: NSObject, NSWindowDelegate {

    private weak var controller: SyncController?
    private var window: NSWindow?
    private var registeredLanguageHandler = false

    private let toggle = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let directoryField = NSTextField(string: "")
    private let chooseButton = NSButton(title: "", target: nil, action: nil)
    private let passphraseField = NSSecureTextField(string: "")
    private let statusText = NSTextField(labelWithString: "")
    private let peersText = NSTextField(labelWithString: "")
    private let syncNowButton = NSButton(title: "", target: nil, action: nil)

    func configure(controller: SyncController) {
        self.controller = controller
        controller.onChange = { [weak self] in self?.reload() }
    }

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

    // MARK: - 构建

    private func buildWindow() {
        // 同上：标题在搭窗口时设，属性初始化里设的话切语言不会变。
        toggle.title = L("打开跨设备同步", "Enable cross-device sync")
        chooseButton.title = L("选择目录…", "Choose folder…")
        syncNowButton.title = L("立即同步", "Sync now")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = L("跨设备同步", "Cross-device sync")
        window.delegate = self
        window.center()
        self.window = window

        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))
        chooseButton.target = self
        chooseButton.action = #selector(chooseDirectory(_:))
        syncNowButton.target = self
        syncNowButton.action = #selector(syncNow(_:))
        directoryField.isEditable = false
        directoryField.isSelectable = true
        directoryField.lineBreakMode = .byTruncatingMiddle
        passphraseField.placeholderString = L("加入已有同步目录时，输入另一台机器显示过的配对口令", "To join an existing sync folder, enter the pairing passphrase shown on the other Mac")
        statusText.lineBreakMode = .byWordWrapping
        statusText.maximumNumberOfLines = 0
        peersText.lineBreakMode = .byWordWrapping
        peersText.maximumNumberOfLines = 0
        peersText.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

        let explain = NSTextField(labelWithString:
            L("只上传加密的追加日志段文件到你自己的 iCloud，数据库本体不会离开这台机器。"
            + "每台机器只写自己的文件，不需要跨机器加锁。",
            "Only encrypted append-only segment files go to your own iCloud; the database itself never "
            + "leaves this Mac. Each machine writes only its own files, so no cross-machine locking "
            + "is needed."))
        explain.lineBreakMode = .byWordWrapping
        explain.maximumNumberOfLines = 0
        explain.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            toggle,
            explain,
            labeled(L("同步目录", "Sync folder"), directoryField, trailing: chooseButton),
            labeled(L("配对口令", "Pairing passphrase"), passphraseField, trailing: nil),
            NSBox.separator(),
            statusText,
            peersText,
            syncNowButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
                directoryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
                passphraseField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            ])
        }
    }

    private func labeled(_ title: String, _ field: NSView, trailing: NSView?) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        var views: [NSView] = [label, field]
        if let trailing { views.append(trailing) }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    // MARK: - 刷新

    private func reload() {
        guard let controller else { return }
        let status = controller.status
        toggle.state = status.enabled ? .on : .off
        directoryField.stringValue = status.directory
        syncNowButton.isEnabled = status.enabled
        passphraseField.isEnabled = !status.enabled

        var lines: [String] = [status.summary]
        if status.enabled {
            lines.append(L("本机设备 \(status.deviceID)（密钥指纹 \(status.keyID)）",
                           "This device \(status.deviceID) (key fingerprint \(status.keyID))"))
            lines.append(L("待出站：\(status.pendingExportObservations) 条观察、"
                       + "\(status.pendingExportTombstones) 条删除；",
                       "Pending outbound: \(status.pendingExportObservations) observations, "
                       + "\(status.pendingExportTombstones) deletions; ")
                       + L("本机段文件 \(status.ownSegments) 个、目录里共 "
                           + "\(status.segmentBytes / 1024) KiB",
                           "\(status.ownSegments) local segment files, "
                           + "\(status.segmentBytes / 1024) KiB in the folder"))
        }
        statusText.stringValue = lines.joined(separator: "\n")

        if status.peers.isEmpty {
            peersText.stringValue = status.enabled
                ? L("还没有其他设备加入。在另一台机器上打开同一个目录并输入配对口令即可。", "No other device has joined yet. Open the same folder on another Mac and enter the pairing passphrase.") : ""
        } else {
            peersText.stringValue = status.peers.map { peer in
                let seen = peer.lastSeen.map { SyncController.Status.timeFormatter.string(from: $0) }
                    ?? "—"
                let error = peer.lastError.map { L("，错误：\($0)", ", error: \($0)") } ?? ""
                return L("\(peer.name ?? peer.deviceID)：已导入到第 \(peer.importedSeq) 段，"
                         + "待导入 \(peer.pendingSegments) 段，最后出现 \(seen)\(error)",
                         "\(peer.name ?? peer.deviceID): imported through segment \(peer.importedSeq), "
                         + "\(peer.pendingSegments) pending, last seen \(seen)\(error)")
            }.joined(separator: "\n")
        }
    }

    // MARK: - 动作

    @objc private func toggleChanged(_ sender: NSButton) {
        guard let controller else { return }
        if sender.state == .off {
            controller.disable()
            return
        }
        do {
            let passphrase = passphraseField.stringValue.isEmpty ? nil : passphraseField.stringValue
            let generated = try controller.enable(
                directory: URL(fileURLWithPath: directoryField.stringValue, isDirectory: true),
                passphrase: passphrase)
            passphraseField.stringValue = ""
            if let generated { presentPairingPassphrase(generated) }
        } catch {
            sender.state = .off
            present(alert: L("打不开同步", "Could not enable sync"), body: "\(error)")
        }
        reload()
    }

    /// 3.9：首台**显示一次**配对口令。之后任何界面都不再显示它——库里只存同步密钥本身，
    /// 口令根本没存过，想再看只能重新配对。
    private func presentPairingPassphrase(_ passphrase: String) {
        let alert = NSAlert()
        alert.messageText = L("配对口令（只显示这一次）", "Pairing passphrase (shown only once)")
        alert.informativeText = L("在另一台机器上打开同一个同步目录时输入它：\n\n\(passphrase)\n\n"
            + "它不会被保存在任何地方。忘了就只能删掉同步目录重新配对。",
            "Enter it on the other Mac when opening the same sync folder:\n\n\(passphrase)\n\n"
            + "It is not stored anywhere. If you lose it, the only way forward is to delete the sync "
            + "folder and pair again.")
        alert.addButton(withTitle: L("拷贝并关闭", "Copy and close"))
        alert.addButton(withTitle: L("关闭", "Close"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(passphrase, forType: .string)
        }
    }

    @objc private func chooseDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("选择同步目录", "Choose sync folder")
        panel.directoryURL = URL(fileURLWithPath: directoryField.stringValue, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directoryField.stringValue = url.path
        UserDefaults.standard.set(url.path, forKey: SyncController.Key.directory)
    }

    @objc private func syncNow(_ sender: Any?) {
        controller?.runNow()
    }

    private func present(alert title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: L("好", "OK"))
        alert.runModal()
    }

    func windowWillClose(_ notification: Notification) {
        controller?.onChange = nil
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
