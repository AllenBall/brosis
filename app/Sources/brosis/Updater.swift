import AppKit
import Foundation
import Sparkle

// 自动更新（计划 4.2「打包与分发管线 … 签名更新（Sparkle 或同类）」）。
//
// 三条口径，改代码前先看清楚：
//
// 1. **默认不联网。** `Info.plist` 里 `SUEnableAutomaticChecks = false`、
//    `SUAutomaticallyUpdate = false`，并且 `AppDelegate` 里**没有**在启动时创建
//    updater——`SPUStandardUpdaterController` 只在用户点「检查更新…」的那一刻才创建。
//    Sparkle 的更新周期是在 `startUpdater` 之后的下一个 runloop 才起的，没被创建就
//    一个字节都不会发出去。这条对齐 2.2 硬约束 6「默认不上传」的精神：更新检查也是
//    一次出网，必须由人显式发起（或将来在设置里显式打开）。
// 2. **fail-closed。** `SUPublicEDKey` 在仓库里是占位符 `__SUPublicEDKey__`
//    （不是合法 base64，更不是 32 字节的 Ed25519 公钥）。没有把真公钥注进去时，
//    `UpdaterConfig.issues` 会当场拦下，`startUpdater` 也会失败——也就是
//    **没配公钥的构建永远装不上任何"更新"**，而不是"没验签就装"。
//    真公钥由用户用 Sparkle 的 `generate_keys` 生成（私钥进他自己的钥匙串），
//    放到 `~/Library/Application Support/brosis-dev/sparkle_public_ed_key.txt`，
//    `build_app.sh` 组装 bundle 时替换占位符。见 dist/RELEASE.md。
// 3. **不碰数据库、不碰钥匙串。** 这个文件里没有任何 `BrosisCore` 调用，
//    也不读 app 的数据目录；锁定状态与它无关。
//
// 接入方式（本任务**不改** `AppDelegate.swift`，由主会话接）：在
// `AppDelegate.menuWillOpen` 里「导出存储统计…」之后、`.separator()` 之前加一行
//
//     menu.addItem(UpdaterController.shared.makeMenuItem())
//
// 就够了：菜单项自带 target/action 与可用性判定，`UpdaterController.shared` 是
// `@MainActor` 单例，`menuWillOpen` 本身就在主线程。

// MARK: - 配置检查（纯函数，不联网、不建 updater）

/// `Info.plist` 里那几个 `SU*` 键的检查。
///
/// 单独拎成一个非隔离的 enum，是为了让它可以在**任何**线程、任何上下文里调用：
/// 菜单点击前拦一道、`build_app.sh` 之外再核一道、将来自检也可以直接调它。
enum UpdaterConfig {
    /// 仓库里 `Support/Info.plist` 中 `SUPublicEDKey` 的占位符。
    /// 故意选一个**不是合法 base64** 的串：万一 `build_app.sh` 的替换漏了，
    /// Sparkle 自己也会拒绝启动，而不是拿一个"看着像 key"的东西去验签。
    static let publicKeyPlaceholder = "__SUPublicEDKey__"

    /// Ed25519 公钥的字节数。Sparkle 的 `SUPublicEDKey` 是它的 base64。
    static let publicKeyByteCount = 32

    /// 返回**所有**配置问题（空数组 = 可以启动 updater）。
    ///
    /// - Parameter info: 一般传 `Bundle.main.infoDictionary`；测试可以传自造的字典。
    static func issues(in info: [String: Any]?) -> [String] {
        guard let info else {
            return ["读不到 Info.plist（多半是从裸二进制而不是 brosis.app 里跑的）"]
        }
        var problems: [String] = []

        // ---- SUFeedURL：必须有、必须 https（Sparkle 对 http 源会拒绝，这里先说清楚）
        let feed = (info["SUFeedURL"] as? String) ?? ""
        if feed.isEmpty {
            problems.append("Info.plist 缺 SUFeedURL")
        } else if let url = URL(string: feed) {
            if url.scheme?.lowercased() != "https" {
                problems.append("SUFeedURL 不是 https：\(feed)")
            }
        } else {
            problems.append("SUFeedURL 不是合法 URL：\(feed)")
        }

        // ---- SUPublicEDKey：必须有、不能是占位符、必须是 32 字节的 base64
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        if key.isEmpty {
            problems.append("Info.plist 缺 SUPublicEDKey")
        } else if key == publicKeyPlaceholder {
            problems.append(
                "SUPublicEDKey 还是占位符 \(publicKeyPlaceholder)："
                + "这份构建没有更新公钥，任何「更新」都会被拒。"
                + "先用 Sparkle 的 generate_keys 生成密钥对，把公钥放进 "
                + "~/Library/Application Support/brosis-dev/sparkle_public_ed_key.txt 再重新构建。")
        } else if let raw = Data(base64Encoded: key) {
            if raw.count != publicKeyByteCount {
                problems.append("SUPublicEDKey 解出来是 \(raw.count) 字节，应为 \(publicKeyByteCount)")
            }
        } else {
            problems.append("SUPublicEDKey 不是合法 base64")
        }

        // ---- SUEnableAutomaticChecks：必须显式为 false（"默认不联网"这条不许被悄悄改掉）
        switch info["SUEnableAutomaticChecks"] {
        case let flag as Bool where flag == false:
            break
        case nil:
            problems.append("Info.plist 缺 SUEnableAutomaticChecks（必须显式 false：默认不自动联网）")
        default:
            problems.append("SUEnableAutomaticChecks 不是 false：默认不自动联网这条被改了")
        }

        return problems
    }

    /// 菜单上要显示的一行状态（不联网）。
    static func statusLine(in info: [String: Any]?) -> String {
        let problems = issues(in: info)
        if problems.isEmpty {
            let feed = (info?["SUFeedURL"] as? String) ?? "?"
            return "更新源已配置：\(feed)"
        }
        return "更新未启用：\(problems[0])"
    }
}

// MARK: - 菜单入口

/// 「检查更新…」的持有者。**只有它会创建 Sparkle 的对象**。
@MainActor
final class UpdaterController: NSObject {

    static let shared = UpdaterController()

    /// 懒创建：第一次点「检查更新…」才有值。为 nil 表示这个进程还没起过 updater。
    private var controller: SPUStandardUpdaterController?

    private override init() { super.init() }

    /// 给 `AppDelegate` 的菜单用。每次 `menuWillOpen` 重建菜单时调一次。
    ///
    /// 菜单项**默认可点**：配置有问题时点下去会弹一个说清楚原因的框，
    /// 而不是灰掉让人不知道为什么。只有 Sparkle 已经在跑一次更新会话时才灰掉，
    /// 判定在下面的 `validateMenuItem`。
    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "检查更新…",
                              action: #selector(checkForUpdates(_:)),
                              keyEquivalent: "")
        item.target = self
        return item
    }

    /// 菜单里那行只读状态（可选，主会话要不要显示都行）。
    nonisolated func statusLine() -> String {
        UpdaterConfig.statusLine(in: Bundle.main.infoDictionary)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        // 第一道：配置不对就不联网，直接说清楚。
        let problems = UpdaterConfig.issues(in: Bundle.main.infoDictionary)
        guard problems.isEmpty else {
            presentAlert(title: "更新功能未启用",
                         body: problems.joined(separator: "\n\n"))
            return
        }

        // 第二道：懒启动 Sparkle。startingUpdater: false + 自己调 updater.start()，
        // 是为了拿到真正的 NSError 自己弹框，而不是让 Sparkle 弹一句
        // "请联系开发者"。启动失败就把 controller 丢掉，下次点还能重试。
        if controller == nil {
            let created = SPUStandardUpdaterController(startingUpdater: false,
                                                       updaterDelegate: nil,
                                                       userDriverDelegate: nil)
            do {
                try created.updater.start()
                controller = created
            } catch {
                presentAlert(title: "更新器启动失败",
                             body: "\(error.localizedDescription)\n\n"
                                 + "（brosis 不会因此自动重试，也不会在后台再联网。）")
                return
            }
        }

        controller?.updater.checkForUpdates()
    }

    private func presentAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// NSMenu 默认走自动启用（`autoenablesItems == true`）：这时候直接设 `isEnabled` 会被覆盖，
// 真正说了算的是这个方法。实现它，两种设置下行为都一致。
extension UpdaterController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        // controller 还没建（没点过）时一律可点；建过之后由 Sparkle 说了算。
        guard let updater = controller?.updater else { return true }
        return updater.canCheckForUpdates
    }
}
