import AppKit
import Carbon.HIToolbox
import Foundation

// =============================================================================
// M2 d / T18：**全局热键**——计划 4.2「暂停触发器（安全输入、私密浏览、锁屏、屏保、
// 热键）」里唯一没做的那一项，以及 3.5 触发表里的「显式锁定（菜单 / 热键）」。
//
// 为什么用 Carbon 的 `RegisterEventHotKey` 而不是 `NSEvent.addGlobalMonitorForEvents`
// 或 `CGEventTap`：
//
// - `NSEvent.addGlobalMonitorForEvents` 与 `CGEventTap` 都是**看得见所有按键**的接口，
//   macOS 因此要求「辅助功能」权限，而且看得见的远不止我们要的那两个组合——
//   一个"记录你在干什么"的 app 去申请一条能读全部击键的通道，与 2.2 的取向相反。
// - `RegisterEventHotKey` 只登记**一个具体组合**，由 WindowServer 在匹配时才回调，
//   拿不到别的按键，**也不需要辅助功能权限**。
//
// 依据 + 实测（2026-09-08，M4 Air / macOS 26.6，屏幕锁定状态下）：把测试进程用
// `responsibility_spawnattrs_setdisclaim` 断开与终端的 TCC 归属，使
// `AXIsProcessTrusted() == false`，此时 `RegisterEventHotKey` 仍然返回 `noErr`
// 并拿到 `EventHotKeyRef`；`UnregisterEventHotKey` 返回 `noErr`。
// 原始输出见 tools/bench/results/m2_d_focus_hotkey_2026-09-08.md 与
// ~/Library/Caches/brosis-build/m2-focus/results/hotkey_probe.txt。
//
// 三条**如实说明**，不要在 README 之外的地方吹得更好：
//
// 1. **注册成功 ≠ 按键一定到得了我们这儿。** 同一组合被系统快捷键（如 ⌘Space）或
//    别的进程占了时，`RegisterEventHotKey` 照样返回 `noErr`，按键只是永远不来。
//    Carbon 只在**本进程内**重复登记同一组合时才报 `eventHotKeyExistsErr (-9878)`
//    （实测：同 signature 不同 id、不同 signature 同组合，都是 -9878）。
//    所以菜单里显示的是"注册成功 / 失败 + 组合"，不敢写"热键可用"。
// 2. **处理器只发通知。** C 回调里除了取一个 `EventHotKeyID`、发一条
//    `NotificationCenter` 通知，什么都不做——真正的动作走既有的
//    `LockController.togglePause()` / `lockNow()`，与菜单点击是同一条路径。
// 3. **不改 `AppDelegate.swift`**（d 批并行约定）。接入方式一行：
//
//        // AppDelegate.applicationDidFinishLaunching(_:) 里，lock 建好之后：
//        HotKeys.shared.install(recorder: recorder,
//                               onPause: { [weak lock] in lock?.togglePause() },
//                               onLock:  { [weak lock] in lock?.lockNow() })
//
//    菜单里再加一行状态显示（注册失败要看得见）：
//
//        menu.addItem(disabledItem(HotKeys.shared.menuDescription))
//
//    退出时（`applicationWillTerminate`）可以 `HotKeys.shared.uninstall()`；
//    不调也不会泄漏到别的进程——进程一死 WindowServer 自己就清了。
// =============================================================================

// MARK: - 文件级常量与 C 回调
//
// 放在类型外面：`@convention(c)` 的回调是**非隔离**上下文，碰不了 `@MainActor`
// 类型的静态成员。全局 `let` 且类型 Sendable，在 Swift 6 语言模式下是合法的。

/// 'bros'。`EventHotKeyID.signature`，用来认出"这条热键是我们登记的"。
let brosisHotKeySignature = OSType(0x6272_6F73)

/// C 回调发出去的通知；`userInfo[brosisHotKeyIDKey]` 是 `UInt32`（见 `HotKeyAction.carbonID`）。
let brosisHotKeyNotification = Notification.Name("com.brosis.app.hotkey")
let brosisHotKeyIDKey = "hotKeyID"

/// Carbon 事件处理器本体。**只发通知**，不做任何动作、不碰数据库、不碰 UI。
///
/// 它跑在主线程的 Carbon 事件派发上（`GetEventDispatcherTarget()`），
/// `NotificationCenter.post` 因此是同步派发给主线程上的观察者。
private func brosisHotKeyHandler(_ callRef: EventHandlerCallRef?,
                                 _ event: EventRef?,
                                 _ context: UnsafeMutableRawPointer?) -> OSStatus {
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &identifier)
    guard status == noErr, identifier.signature == brosisHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    NotificationCenter.default.post(name: brosisHotKeyNotification, object: nil,
                                   userInfo: [brosisHotKeyIDKey: identifier.id])
    return noErr
}

// MARK: - 两个动作

/// 目前只有两个（计划 4.2 / 3.5）。加第三个只要在这里加一个 case。
enum HotKeyAction: String, Sendable, CaseIterable {
    /// 一键暂停 / 继续（2.2 硬约束 3）。
    case pause
    /// 显式锁定数据库（3.5 触发表）。
    case lock

    /// 出厂默认组合。⌃⌥⌘ 三修饰键是刻意的：单 ⌘ / ⌘⇧ 的两键组合几乎一定和别的
    /// app 撞车，而撞车在 Carbon 这一层**不报错**（见文件头第 1 条）。
    var defaultKeyString: String {
        switch self {
        case .pause: return "ctrl+alt+cmd+P"
        case .lock:  return "ctrl+alt+cmd+L"
        }
    }

    /// UserDefaults 键：`defaults write com.brosis.app hotkey.pause "ctrl+shift+cmd+P"`。
    var defaultsKey: String { "hotkey.\(rawValue)" }

    /// `EventHotKeyID.id`。必须两两不同。
    var carbonID: UInt32 {
        switch self {
        case .pause: return 1
        case .lock:  return 2
        }
    }

    var title: String {
        switch self {
        case .pause: return L("暂停 / 继续采集", "Pause / resume capture")
        case .lock:  return L("锁定数据库", "Lock database")
        }
    }

    static func action(carbonID: UInt32) -> HotKeyAction? {
        allCases.first { $0.carbonID == carbonID }
    }
}

// MARK: - 键位字符串 → (虚拟键码, Carbon 修饰键掩码)

/// 一个可注册的组合。
struct HotKeySpec: Sendable, Equatable, Hashable {
    /// ANSI 虚拟键码（`kVK_*`）。
    var keyCode: UInt32
    /// Carbon 修饰键掩码（`cmdKey` / `optionKey` / `controlKey` / `shiftKey` 的或）。
    var carbonModifiers: UInt32
    /// 给人看的形式，如 `⌃⌥⌘P`。
    var display: String
}

/// 解析 `"ctrl+alt+cmd+P"` / `"⌃⌥⌘P"` 这类字符串。**纯函数，有自检向量。**
enum HotKeyParser {

    /// 符号写法：出现在字符串任何位置都算数（`⌃⌥⌘P` 没有分隔符）。
    static let modifierSymbols: [(symbol: Character, mask: Int)] = [
        ("⌘", cmdKey), ("⌥", optionKey), ("⌃", controlKey), ("⇧", shiftKey),
    ]

    /// 单词写法，按 `+` / 空格拆开之后比对（小写）。
    static let modifierWords: [String: Int] = [
        "cmd": cmdKey, "command": cmdKey, "meta": cmdKey,
        "opt": optionKey, "option": optionKey, "alt": optionKey,
        "ctrl": controlKey, "control": controlKey,
        "shift": shiftKey,
    ]

    /// 非修饰键。只收**位置固定**的 ANSI 键与功能键：
    /// 键盘布局换了（Dvorak / 法语）虚拟键码不变、字符会变，这一点写在 README 里。
    static let keyCodes: [String: Int] = {
        var table: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "space": kVK_Space, "escape": kVK_Escape, "esc": kVK_Escape,
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
            "delete": kVK_Delete, "backspace": kVK_Delete,
            "-": kVK_ANSI_Minus, "minus": kVK_ANSI_Minus,
            "=": kVK_ANSI_Equal, "equal": kVK_ANSI_Equal,
            "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
            ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
                            kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13,
                            kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in functionKeys.enumerated() { table["f\(index + 1)"] = code }
        return table
    }()

    /// 反查：虚拟键码 → 显示名。一个键码常有多个别名（`esc` / `escape`），
    /// 所以这张表**显式**指定非字母数字键的写法，字母数字直接大写。
    static let preferredNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "SPACE", kVK_Escape: "ESC", kVK_Return: "RETURN",
            kVK_Tab: "TAB", kVK_Delete: "DELETE",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
        for (name, code) in keyCodes where names[code] == nil {
            names[code] = name.uppercased()
        }
        return names
    }()

    /// 解析失败回 `nil`。失败的三种情形：认不出的键、两个非修饰键、**一个修饰键都没有**。
    ///
    /// 为什么强制要有修饰键：不带修饰键的全局热键会把那个键从**所有** app 里抢走
    /// （实测 `F19` 无修饰键注册返回 `noErr`），这是个陷阱，不给用户踩。
    static func parse(_ raw: String) -> HotKeySpec? {
        var modifiers = 0
        var remaining = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remaining.isEmpty else { return nil }

        for (symbol, mask) in modifierSymbols where remaining.contains(symbol) {
            modifiers |= mask
            remaining = remaining.replacingOccurrences(of: String(symbol), with: "+")
        }

        var key: String?
        for piece in remaining.split(whereSeparator: { $0 == "+" || $0 == " " }) {
            let token = String(piece).lowercased()
            if let mask = modifierWords[token] {
                modifiers |= mask
                continue
            }
            if key != nil { return nil }        // 两个非修饰键
            key = token
        }

        guard let key, let code = keyCodes[key] else { return nil }
        guard modifiers != 0 else { return nil }
        return HotKeySpec(keyCode: UInt32(code), carbonModifiers: UInt32(modifiers),
                          display: display(keyCode: UInt32(code),
                                           carbonModifiers: UInt32(modifiers)))
    }

    /// `⌃⌥⇧⌘` 的顺序是 macOS 菜单的惯例，别改。
    static func display(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var text = ""
        if carbonModifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (preferredNames[Int(keyCode)] ?? "?\(keyCode)")
    }

    /// 自检向量。`expected == nil` 表示应当解析失败。
    static let cases: [(name: String, input: String, expected: HotKeySpec?)] = [
        ("出厂默认 · 暂停", "ctrl+alt+cmd+P",
         HotKeySpec(keyCode: UInt32(kVK_ANSI_P),
                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘P")),
        ("出厂默认 · 锁定", "ctrl+alt+cmd+L",
         HotKeySpec(keyCode: UInt32(kVK_ANSI_L),
                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘L")),
        ("符号写法等价", "⌃⌥⌘P",
         HotKeySpec(keyCode: UInt32(kVK_ANSI_P),
                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘P")),
        ("大小写 / 空格无所谓", "  Ctrl + Option + CMD + p ",
         HotKeySpec(keyCode: UInt32(kVK_ANSI_P),
                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘P")),
        ("别名 command / opt", "command+opt+shift+9",
         HotKeySpec(keyCode: UInt32(kVK_ANSI_9),
                    carbonModifiers: UInt32(cmdKey | optionKey | shiftKey), display: "⌥⇧⌘9")),
        ("功能键", "ctrl+shift+F12",
         HotKeySpec(keyCode: UInt32(kVK_F12),
                    carbonModifiers: UInt32(controlKey | shiftKey), display: "⌃⇧F12")),
        ("标点键", "cmd+ctrl+/",
         HotKeySpec(keyCode: UInt32(kVK_ANSI_Slash),
                    carbonModifiers: UInt32(cmdKey | controlKey), display: "⌃⌘/")),
        ("空格键的名字", "⌥⌘space",
         HotKeySpec(keyCode: UInt32(kVK_Space),
                    carbonModifiers: UInt32(optionKey | cmdKey), display: "⌥⌘SPACE")),
        ("重复修饰键只算一次", "cmd+cmd+ctrl+alt+P",
         HotKeySpec(keyCode: UInt32(kVK_ANSI_P),
                    carbonModifiers: UInt32(controlKey | optionKey | cmdKey), display: "⌃⌥⌘P")),
        ("没有修饰键 → 拒绝", "P", nil),
        ("只有修饰键 → 拒绝", "ctrl+cmd", nil),
        ("两个非修饰键 → 拒绝", "ctrl+cmd+P+L", nil),
        ("认不出的键名 → 拒绝", "ctrl+cmd+不存在", nil),
        ("空串 → 拒绝", "   ", nil),
    ]
}

// MARK: - 注册 / 注销

/// 一次注册的结果。自检与菜单都读它。
///
/// 放在 `HotKeys` 外面：`HotKeys` 是 `@MainActor`，嵌在里面的类型会跟着被隔离，
/// 而自检要在非隔离上下文里读这些字段。
struct HotKeyRegistration: Sendable, Equatable {
    var action: HotKeyAction
    /// 用户配的（或出厂默认的）字符串，原样留着，报错时要显示。
    var raw: String
    /// 解析结果；`nil` = 解析失败。
    var spec: HotKeySpec?
    /// `RegisterEventHotKey` 的返回值（没走到注册这一步时是我们自己填的错误码）。
    var status: OSStatus
    var registered: Bool
    /// 给人看的说明（成功时是组合，失败时是原因）。
    var note: String

    var summary: String {
        let combo = spec?.display ?? raw
        return registered
            ? "\(action.title) \(combo)"
            : L("\(action.title) \(combo) 注册失败（\(note)，OSStatus \(status)）",
                "\(action.title) \(combo) failed to register (\(note), OSStatus \(status))")
    }
}

/// 全局热键的登记处。单例，`@MainActor`。
@MainActor
final class HotKeys {

    static let shared = HotKeys()

    private(set) var registrations: [HotKeyRegistration] = []
    private(set) var installed = false

    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var observing = false
    private var onPause: (@MainActor () -> Void)?
    private var onLock: (@MainActor () -> Void)?
    private var recorder: Recorder?

    private init() {}

    /// 从 UserDefaults 读某个动作配的字符串（没配就是出厂默认）。
    nonisolated static func keyString(_ action: HotKeyAction,
                                     defaults: UserDefaults = .standard) -> String {
        let raw = (defaults.string(forKey: action.defaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? action.defaultKeyString : raw
    }

    /// 注册两个热键。重复调用是安全的（先 `uninstall()`）。
    ///
    /// - Returns: 每个动作一条结果，**成功与失败都在里面**——调用方（菜单 / 自检）
    ///   要能看见"注册失败了、为什么"。
    @discardableResult
    func install(defaults: UserDefaults = .standard,
                 recorder: Recorder? = nil,
                 onPause: @escaping @MainActor () -> Void,
                 onLock: @escaping @MainActor () -> Void) -> [HotKeyRegistration] {
        uninstall()
        self.recorder = recorder
        self.onPause = onPause
        self.onLock = onLock

        // 事件处理器只装一次；装不上就没必要往下注册了。
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        var handlerRef: EventHandlerRef?
        let handlerStatus = InstallEventHandler(GetEventDispatcherTarget(),
                                                brosisHotKeyHandler, 1, &eventSpec,
                                                nil, &handlerRef)
        guard handlerStatus == noErr, let handlerRef else {
            registrations = HotKeyAction.allCases.map { action in
                HotKeyRegistration(action: action, raw: Self.keyString(action, defaults: defaults),
                             spec: nil, status: handlerStatus, registered: false,
                             note: "InstallEventHandler 失败")
            }
            recorder?.logEvent(kind: "hotkey_register_failed",
                               detail: "stage=install_handler status=\(handlerStatus)")
            return registrations
        }
        handler = handlerRef

        if !observing {
            NotificationCenter.default.addObserver(self, selector: #selector(hotKeyFired(_:)),
                                                   name: brosisHotKeyNotification, object: nil)
            observing = true
        }

        var results: [HotKeyRegistration] = []
        var taken: [HotKeySpec: HotKeyAction] = [:]
        for action in HotKeyAction.allCases {
            let raw = Self.keyString(action, defaults: defaults)
            guard let spec = HotKeyParser.parse(raw) else {
                results.append(HotKeyRegistration(action: action, raw: raw, spec: nil,
                                            status: OSStatus(eventHotKeyInvalidErr),
                                            registered: false,
                                            note: "键位字符串解析失败（要形如 ctrl+alt+cmd+P，"
                                                + "至少一个修饰键）"))
                continue
            }
            // 本进程内两个动作配了同一个组合：Carbon 也会拒（-9878），但我们先说人话。
            if let other = taken[spec] {
                results.append(HotKeyRegistration(action: action, raw: raw, spec: spec,
                                            status: OSStatus(eventHotKeyExistsErr),
                                            registered: false,
                                            note: "与「\(other.title)」的热键相同"))
                continue
            }
            var ref: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: brosisHotKeySignature, id: action.carbonID)
            let status = RegisterEventHotKey(spec.keyCode, spec.carbonModifiers, identifier,
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
                taken[spec] = action
                results.append(HotKeyRegistration(action: action, raw: raw, spec: spec, status: status,
                                            registered: true, note: spec.display))
            } else {
                let note = status == OSStatus(eventHotKeyExistsErr)
                    ? L("组合已被本进程占用（eventHotKeyExistsErr）",
                        "this combination is already taken by this process (eventHotKeyExistsErr)")
                    : L("RegisterEventHotKey 失败", "RegisterEventHotKey failed")
                results.append(HotKeyRegistration(action: action, raw: raw, spec: spec, status: status,
                                            registered: false, note: note))
            }
        }

        registrations = results
        installed = true
        for result in results {
            recorder?.logEvent(kind: result.registered ? "hotkey_registered"
                                                       : "hotkey_register_failed",
                               detail: "action=\(result.action.rawValue) "
                                     + "combo=\(result.spec?.display ?? result.raw) "
                                     + "status=\(result.status) note=\(result.note)")
        }
        return results
    }

    /// 注销全部。**自检必须调**：不能给正在运行的那个 brosis 留下一个抢着的组合。
    ///
    /// - Returns: 每个曾经注册成功的动作对应的 `UnregisterEventHotKey` 返回值。
    @discardableResult
    func uninstall() -> [HotKeyAction: OSStatus] {
        var statuses: [HotKeyAction: OSStatus] = [:]
        for (action, ref) in refs {
            statuses[action] = UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        if observing {
            NotificationCenter.default.removeObserver(self, name: brosisHotKeyNotification,
                                                      object: nil)
            observing = false
        }
        registrations.removeAll()
        onPause = nil
        onLock = nil
        recorder = nil
        installed = false
        return statuses
    }

    /// 通知观察者。C 回调发通知 → 这里把它变成"点了菜单里那一项"。
    @objc private func hotKeyFired(_ note: Notification) {
        guard let raw = note.userInfo?[brosisHotKeyIDKey] as? UInt32,
              let action = HotKeyAction.action(carbonID: raw) else { return }
        recorder?.logEvent(kind: "hotkey_fired", detail: "action=\(action.rawValue)")
        switch action {
        case .pause: onPause?()
        case .lock:  onLock?()
        }
    }

    /// 菜单里那一行。注册失败要看得见（T18 的要求）。
    var menuDescription: String {
        guard installed, !registrations.isEmpty else {
            return L("全局热键：未注册", "Global hotkeys: not registered")
        }
        let failed = registrations.filter { !$0.registered }
        if failed.isEmpty {
            return L("全局热键：", "Global hotkeys: ") + registrations.map { "\($0.spec?.display ?? $0.raw) \($0.action.title)" }
                .joined(separator: " · ")
        }
        return L("全局热键：", "Global hotkeys: ") + failed.map(\.summary).joined(separator: "；")
    }
}
