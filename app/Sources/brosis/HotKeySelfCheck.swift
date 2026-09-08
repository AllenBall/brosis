import Carbon.HIToolbox
import Foundation

/// M2 d / T18：全局热键的自检。无 GUI、无 TCC 弹窗、不碰钥匙串、不开库。
///
/// 两组：
/// 1. **热键注册两项 + 注销一项**——真的调 `RegisterEventHotKey`，装 → 卸 → 再装 → 再卸，
///    两轮结果必须相同（漏注销时第二轮会拿到 `eventHotKeyExistsErr`），
///    不给正在运行的那个 brosis 留下抢着的组合；
/// 2. **键位解析向量**——`HotKeyParser.parse` 的 \(HotKeyParser.cases.count) 条。
///
/// 由 `SelfCheck.run()` 调一次（那边只加一行），失败项数原样返回。
///
/// 2026-09-08：Focus（专注模式）联动整条删除，本文件原来的第 1–3 组（探针可读性、
/// 解析向量、暂停名单匹配）随之去掉，文件名从 `FocusHotKeySelfCheck.swift` 改到这里。
enum HotKeySelfCheck {

    static func run() -> Int {
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        // ----------------------------------------------------------- 1. 热键注册（两项）
        // 真的注册，**跑完立刻注销**。`--self-check` 跑在主线程（main.swift 的顶层代码），
        // 所以 assumeIsolated 是安全的。
        //
        // 装 → 卸 → **再装一次** → 再卸：第二轮是"真的注销掉了"的唯一硬证据。
        // 只看 `UnregisterEventHotKey` 的返回值不够——把它换成常量 `noErr` 也照样绿；
        // 但如果第一轮没真放掉，Carbon 会在第二轮回 `eventHotKeyExistsErr (-9878)`
        // （实测：同组合、不同 id、不同 signature 都是 -9878）。
        let outcome = MainActor.assumeIsolated { () -> HotKeyProbe in
            let first = HotKeys.shared.install(onPause: {}, onLock: {})
            let installedFlag = HotKeys.shared.installed
            let unregister = HotKeys.shared.uninstall()
            let leftover = HotKeys.shared.registrations.count
            let stillInstalled = HotKeys.shared.installed
            let second = HotKeys.shared.install(onPause: {}, onLock: {})
            HotKeys.shared.uninstall()
            return HotKeyProbe(reports: first,
                               secondRound: second,
                               installedDuring: installedFlag,
                               unregister: unregister,
                               leftover: leftover,
                               stillInstalled: stillInstalled,
                               finalLeftover: HotKeys.shared.registrations.count,
                               finalInstalled: HotKeys.shared.installed)
        }
        for action in HotKeyAction.allCases {
            guard let report = outcome.reports.first(where: { $0.action == action }) else {
                check("热键注册 · \(action.title)", false, "没有返回这个动作的结果")
                continue
            }
            // 判定的是**一致性**，不是"一定注册得上"：注册不上（组合被占、解析失败）
            // 也是要如实报出来的结论，但 registered 与 status 必须对得上，
            // 注册成功的必须能注销掉。
            let consistent = report.registered == (report.status == noErr) && !report.note.isEmpty
            let unregistered = report.registered ? (outcome.unregister[action] == noErr) : true
            let again = outcome.secondRound.first { $0.action == action }
            let repeatable = again?.registered == report.registered
                && again?.status == report.status
            check("热键注册 · \(action.title)（\(action.defaultKeyString)）",
                  consistent && unregistered && repeatable,
                  "combo=\(report.spec?.display ?? report.raw) OSStatus=\(report.status) "
                  + "registered=\(report.registered) note=\(report.note) "
                  + "unregister=\(outcome.unregister[action].map(String.init) ?? "(没注册过)") "
                  + "第二轮 OSStatus=\(again.map { String($0.status) } ?? "(没结果)") "
                  + "UserDefaults 键 \(action.defaultsKey)")
        }
        // 第二轮全部成功 = 第一轮真的把组合还给了系统（而不是只清了自己的簿子）。
        let bookkeepingClean = outcome.installedDuring && outcome.leftover == 0
            && !outcome.stillInstalled && outcome.finalLeftover == 0 && !outcome.finalInstalled
        let reallyReleased = outcome.secondRound.count == outcome.reports.count
            && zip(outcome.reports.sorted { $0.action.rawValue < $1.action.rawValue },
                   outcome.secondRound.sorted { $0.action.rawValue < $1.action.rawValue })
                .allSatisfy { $0.status == $1.status && $0.registered == $1.registered }
        check("热键注销干净：组合真的还给了系统（装 → 卸 → 再装，两轮结果必须相同）",
              bookkeepingClean && reallyReleased,
              "第一轮 " + outcome.reports.map { "\($0.action.rawValue)=\($0.status)" }
                  .joined(separator: " ")
              + "；第二轮 " + outcome.secondRound.map { "\($0.action.rawValue)=\($0.status)" }
                  .joined(separator: " ")
              + "；簿子 registrations=\(outcome.finalLeftover) installed=\(outcome.finalInstalled)"
              + "（漏注销时第二轮会是 eventHotKeyExistsErr \(eventHotKeyExistsErr)）")

        // --------------------------------------------------------------- 2. 键位解析
        var parserFailures: [String] = []
        for item in HotKeyParser.cases {
            let got = HotKeyParser.parse(item.input)
            if got != item.expected {
                parserFailures.append("\(item.name)「\(item.input)」：期望 "
                                      + "\(item.expected?.display ?? "(拒绝)")，实得 "
                                      + "\(got?.display ?? "(拒绝)")")
            }
        }
        check("键位解析 \(HotKeyParser.cases.count) 条（单词 / 符号 / 别名 / 三种拒绝）",
              parserFailures.isEmpty,
              parserFailures.isEmpty
                ? "至少一个修饰键才收；无修饰键的全局热键会把那个键从所有 app 里抢走，直接拒"
                : parserFailures.joined(separator: "；"))

        print("       热键依据：RegisterEventHotKey 只登记一个具体组合，不需要辅助功能权限"
              + "（实测：断开 TCC 归属后 AXIsProcessTrusted=false 仍返回 noErr）；"
              + "同一进程内重复登记同一组合报 eventHotKeyExistsErr(\(eventHotKeyExistsErr))；"
              + "被别的进程 / 系统快捷键占用时**不报错**，按键只是不来。")
        return failures
    }

    /// `install → uninstall` 一整趟的观察结果。
    private struct HotKeyProbe: Sendable {
        var reports: [HotKeyRegistration]
        /// 卸载之后再装一次的结果。与第一轮不同就说明上一轮没真放掉。
        var secondRound: [HotKeyRegistration]
        var installedDuring: Bool
        var unregister: [HotKeyAction: OSStatus]
        var leftover: Int
        var stillInstalled: Bool
        var finalLeftover: Int
        var finalInstalled: Bool
    }
}
