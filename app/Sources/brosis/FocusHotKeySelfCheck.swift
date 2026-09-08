import Carbon.HIToolbox
import Foundation

/// M2 d / T18：Focus 联动 + 全局热键的自检。无 GUI、无 TCC 弹窗、不碰钥匙串、不开库。
///
/// 五组：
/// 1. **Focus 探针的真实可读性**——如实报告这台机器上读不读得到那两个 JSON，读不到写原因；
/// 2. **Focus 解析向量**——合成的 Assertions / ModeConfigurations 样本，纯函数逐条断言；
/// 3. **暂停名单匹配向量**——名字 / 完整 id / id 末段 / 通配符 / 不命中；
/// 4. **热键注册两项 + 注销一项**——真的调 `RegisterEventHotKey`，装 → 卸 → 再装 → 再卸，
///    两轮结果必须相同（漏注销时第二轮会拿到 `eventHotKeyExistsErr`），
///    不给正在运行的那个 brosis 留下抢着的组合；
/// 5. **键位解析向量**——`HotKeyParser.parse` 的 \(HotKeyParser.cases.count) 条。
///
/// 由 `SelfCheck.run()` 调一次（那边只加一行），失败项数原样返回。
enum FocusHotKeySelfCheck {

    static func run() -> Int {
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        // ------------------------------------------------------- 1. 真实可读性（如实报）
        let assertionsURL = FocusProbe.assertionsURL()
        let configurationsURL = FocusProbe.configurationsURL()
        let assertionsRead = FocusProbe.read(assertionsURL)
        let configurationsRead = FocusProbe.read(configurationsURL)
        let live = FocusProbe.status(assertions: assertionsRead, configurations: configurationsRead)
        // 判定的是"探针给出了一个能解释的结论"，而不是"这台机器一定读得到"——
        // 读不到是 TCC 的既定事实（本机就是），不该让自检变红；但原因必须写得出来。
        let liveWellFormed: Bool
        switch live {
        case .unavailable(let reason): liveWellFormed = !reason.isEmpty
        case .inactive:                liveWellFormed = true
        case .active(let modes):       liveWellFormed = !modes.isEmpty
        }
        check("Focus 探针（本机实测，如实报可用性）", liveWellFormed,
              "\(live.eventDetail)；轮询间隔 \(Int(FocusMonitor.pollInterval)) s"
              + "（与 CaptureController.periodicInterval 同一个值）")
        print("       Assertions.json：\(describe(assertionsRead))")
        print("       ModeConfigurations.json：\(describe(configurationsRead))")
        print("       路径（相对主目录）：\(FocusProbe.assertionsRelativePath)"
              + " / \(FocusProbe.configurationsRelativePath)")

        // --------------------------------------------------------- 2. 解析向量（合成样本）
        // 样本运行时拼，不留完整 JSON 字面量在二进制里；内容全是模式 id 与模式名，无个人信息。
        let workID = ["com", "apple", "focus", "work"].joined(separator: ".")
        let dndID = ["com", "apple", "donotdisturb", "mode", "default"].joined(separator: ".")
        let sleepID = ["com", "apple", "sleep", "sleep"].joined(separator: ".")

        let activeAssertions = json([
            "data": [[
                "storeAssertionRecords": [[
                    "assertionDetails": [
                        "assertionDetailsIdentifier": "user-set",
                        "assertionDetailsModeIdentifier": workID,
                    ],
                    "assertionStartDateTimestamp": 763_000_000.0,
                ]],
            ]],
        ])
        let idleAssertions = json(["data": [["storeAssertionRecords": [] as [Any]]]])
        let twoAssertions = json([
            "data": [[
                "storeAssertionRecords": [
                    ["assertionDetails": ["assertionDetailsModeIdentifier": workID]],
                    ["assertionDetails": ["assertionDetailsModeIdentifier": dndID]],
                    // 重复一条：去重之后应该还是两个
                    ["assertionDetails": ["assertionDetailsModeIdentifier": workID]],
                ],
            ]],
        ])
        // 兜底形状：没有 assertionDetailsModeIdentifier，只有 modeIdentifier + assertion* 键
        let legacyAssertions = json([
            "records": [[
                "assertionIdentifier": "x",
                "modeIdentifier": sleepID,
            ]],
        ])
        let configurations = json([
            "data": [[
                "modeConfigurations": [
                    workID: ["mode": ["modeIdentifier": workID, "name": "工作"]],
                    // 第二种形状：只有键名 + 内层 mode.name，没有 modeIdentifier
                    dndID: ["mode": ["name": "勿扰模式"]],
                ],
            ]],
        ])

        var parseFailures: [String] = []
        func expect(_ name: String, _ got: FocusStatus, _ want: FocusStatus) {
            if got != want { parseFailures.append("\(name)：期望 \(want.eventDetail)，实得 \(got.eventDetail)") }
        }
        expect("Focus 开着（有名字）",
               FocusProbe.status(assertions: .data(activeAssertions),
                                 configurations: .data(configurations)),
               .active([FocusMode(identifier: workID, name: "工作")]))
        expect("Focus 关着",
               FocusProbe.status(assertions: .data(idleAssertions),
                                 configurations: .data(configurations)),
               .inactive)
        expect("两个 Focus 同时生效、重复项去重",
               FocusProbe.status(assertions: .data(twoAssertions),
                                 configurations: .data(configurations)),
               .active([FocusMode(identifier: workID, name: "工作"),
                        FocusMode(identifier: dndID, name: "勿扰模式")]))
        expect("名字表读不到时退回 id 末段",
               FocusProbe.status(assertions: .data(activeAssertions),
                                 configurations: .failed(code: EPERM, reason: "x")),
               .active([FocusMode(identifier: workID, name: "work")]))
        expect("兜底形状（只有 modeIdentifier + assertion* 键）",
               FocusProbe.status(assertions: .data(legacyAssertions),
                                 configurations: .data(configurations)),
               .active([FocusMode(identifier: sleepID, name: "sleep")]))
        expect("不是 JSON → 不可用，不是「没开」",
               FocusProbe.status(assertions: .data(Data("{ 这不是 json".utf8)),
                                 configurations: .data(configurations)),
               .unavailable(reason: "Assertions.json 解析失败（不是 JSON 或结构不认识）"))
        let epermStatus = FocusProbe.status(
            assertions: .failed(code: EPERM, reason: FocusProbe.describe(errno: EPERM)),
            configurations: .data(configurations))
        if epermStatus.isAvailable || !(epermStatus.unavailableReason ?? "").contains("TCC") {
            parseFailures.append("EPERM 应当是 unavailable 且原因提到 TCC，实得 \(epermStatus.eventDetail)")
        }
        check("Focus 解析向量 7 条（开 / 关 / 多个 / 无名字表 / 兜底形状 / 坏 JSON / EPERM）",
              parseFailures.isEmpty,
              parseFailures.isEmpty ? "「读不到」与「没开」始终分得清"
                                    : parseFailures.joined(separator: "；"))

        // ------------------------------------------------------------- 3. 暂停名单匹配
        let workMode = FocusMode(identifier: workID, name: "工作")
        let dndMode = FocusMode(identifier: dndID, name: "勿扰模式")
        let matchCases: [(name: String, status: FocusStatus, list: [String], expected: String?)] = [
            ("按显示名命中", .active([workMode]), ["工作"], workID),
            ("按完整 id 命中", .active([workMode]), [workID], workID),
            ("按 id 末段命中（大小写无关）", .active([workMode]), ["Work"], workID),
            ("多个生效时命中其中一个", .active([workMode, dndMode]), ["勿扰模式"], dndID),
            ("通配符命中任意 Focus", .active([workMode]), ["*"], workID),
            ("不在名单里 → 不暂停", .active([workMode]), ["勿扰模式"], nil),
            ("名单为空 → 不暂停（默认不联动）", .active([workMode]), [], nil),
            ("没有 Focus 生效 → 不暂停", .inactive, ["*"], nil),
            ("探针不可用 → 不暂停（不猜）", .unavailable(reason: "TCC"), ["*"], nil),
            ("名单里的空白项被忽略", .active([workMode]), ["  ", "工作"], workID),
        ]
        var matchFailures: [String] = []
        for item in matchCases {
            let got = FocusPausePolicy.match(status: item.status, list: item.list)?.identifier
            if got != item.expected {
                matchFailures.append("\(item.name)：期望 \(item.expected ?? "(不暂停)")，实得 \(got ?? "(不暂停)")")
            }
        }
        check("Focus 暂停名单匹配 \(matchCases.count) 条", matchFailures.isEmpty,
              matchFailures.isEmpty
                ? "UserDefaults 键 \(FocusPausePolicy.modesKey)，默认空 = 不联动；启动时探一次，之后空名单零 syscall"
                : matchFailures.joined(separator: "；"))

        // ----------------------------------------------------------- 4. 热键注册（两项）
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

        // --------------------------------------------------------------- 5. 键位解析
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

    private static func describe(_ outcome: FocusProbe.ReadOutcome) -> String {
        switch outcome {
        case .data(let data): return "读到 \(data.count) 字节"
        case .failed(let code, let reason): return "读不到（errno \(code)）——\(reason)"
        }
    }

    /// 合成样本：字典 → JSON Data。自检里出不了错（出错就让它崩在这一行，比静默通过好）。
    private static func json(_ object: [String: Any]) -> Data {
        // 序列化不该失败；真失败了就交出空 Data，让上面的向量当场变红，而不是静默通过。
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
