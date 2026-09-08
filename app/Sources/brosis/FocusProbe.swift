import BrosisCore
import Darwin
import Foundation

// =============================================================================
// M2 d / T18：**Focus（专注模式）联动**——计划 4.5 M3「Focus 联动」、
// 4.2「暂停触发器」、4.1 M0 表里「Focus 状态 JSON 是否可用 → 延到 M3」的那一条。
//
// 口径先说死，免得后面有人以为这里能做得更多：
//
// 1. **只读两个 JSON 文件，绝不用别的接口。** macOS 没有公开 API 报告"当前生效的
//    Focus 是哪个"。系统把它写在
//        ~/Library/DoNotDisturb/DB/Assertions.json         （当前生效的断言）
//        ~/Library/DoNotDisturb/DB/ModeConfigurations.json （模式 id → 名字）
//    这两个文件受 TCC 的「完全磁盘访问」保护。**读不到就是读不到**：
//    `open(2)` 直接回 EPERM，**不弹任何窗**（这一类 TCC 服务没有用户提示，
//    只有用户自己去「系统设置 → 隐私与安全性 → 完全磁盘访问」加白名单）。
//    本文件不会去碰任何会弹窗的东西（不用 EventKit、不用 UNUserNotificationCenter、
//    不用 AppleScript / Apple 事件、不去 spawn 别的进程）。
//
// 2. **文件格式没有公开契约。** 所以解析写成"在整棵 JSON 树里找这几个键"的
//    宽容遍历，而不是照着某一版的结构逐层下钻：系统换个包装层不至于直接失效。
//    解析不出来算 `unavailable(解析失败)`，不算"没有 Focus"——
//    "读不到"和"确定没开"必须分得清，否则会静默地把联动关掉。
//
// 3. **默认不联动。** 暂停名单（`focus.pauseModes`）默认空。
//    口径要说准：`FocusMonitor.start()` **启动时探一次**（`poll(force: true)`，为的是
//    菜单第一次打开就能说清"可不可用、为什么"），此后名单为空的每一轮轮询都**零 syscall**。
//
// 本机（M4 Air，macOS 26.6，2026-09-08）实测：两个文件 `stat(2)` 成功（TCC 不拦
// stat），`open(2)` 回 EPERM，0.03–0.18 ms 返回、不阻塞、不弹窗。
// 也就是说 Focus 联动在**没有授予完全磁盘访问**的机器上恒为不可用，
// 菜单要如实写出原因。数字见 tools/bench/results/m2_d_focus_hotkey_2026-09-08.md。
// =============================================================================

/// 一个生效中的 Focus。`name` 读不到（ModeConfigurations 不可读 / 里面没有这条）时
/// 退回 identifier 的最后一段。
struct FocusMode: Sendable, Equatable {
    var identifier: String
    var name: String

    var label: String { name.isEmpty ? identifier : name }
}

/// 探针的三种结果。计划 4.3.2 T18 要求的 `available / unavailable(reason) / active(modeName)`
/// 在这里是：`.inactive`（可读、当前没有生效的 Focus）、`.unavailable(reason)`、`.active([模式])`。
///
/// **不要**把 `.unavailable` 折叠成 `.inactive`：前者是"我不知道"，后者是"我知道，没开"。
enum FocusStatus: Sendable, Equatable {
    /// 读不到 / 解析不了。`reason` 会原样进菜单与事件。
    case unavailable(reason: String)
    /// 可读，当前没有任何 Focus 生效。
    case inactive
    /// 可读，这些 Focus 正生效（同时生效多个是可能的，所以是数组）。
    case active([FocusMode])

    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    var modes: [FocusMode] {
        if case .active(let modes) = self { return modes }
        return []
    }

    var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// 进事件 detail 的一行（不含用户正文，只有模式名与 id）。
    var eventDetail: String {
        switch self {
        case .unavailable(let reason): return "focus=unavailable reason=\(reason)"
        case .inactive:                return "focus=inactive"
        case .active(let modes):
            let list = modes.map { "\($0.label)(\($0.identifier))" }.joined(separator: ",")
            return "focus=active modes=[\(list)]"
        }
    }
}

/// 读两个 JSON 文件、判定当前 Focus。解析部分是纯函数，自检拿合成样本直接跑。
enum FocusProbe {

    /// 相对**当前用户主目录**的路径。绝对路径一律运行时用 `homeDirectoryForCurrentUser` 拼，
    /// 源码里不出现任何写死的主目录绝对路径。
    static let assertionsRelativePath = "Library/DoNotDisturb/DB/Assertions.json"
    static let configurationsRelativePath = "Library/DoNotDisturb/DB/ModeConfigurations.json"

    /// 单个文件的读取上限。正常只有几 KiB；给 8 MiB 是为了万一系统换了格式也不至于
    /// 把内存吃光。超了算不可用（宁可不联动，也不冒险）。
    static let maxFileBytes = 8 * 1024 * 1024

    static func assertionsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(assertionsRelativePath)
    }

    static func configurationsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(configurationsRelativePath)
    }

    // MARK: - 读文件

    /// 一次读取的结果。`failed` 带上真正的 errno，方便菜单里说人话。
    enum ReadOutcome: Sendable, Equatable {
        case data(Data)
        case failed(code: Int32, reason: String)
    }

    /// 用 `open(2)` / `read(2)` 直接读，不走 `Data(contentsOf:)`：
    /// 要的是**真实 errno**（EPERM 1 / ENOENT 2 / EACCES 13），
    /// NSError 会把它们都揉成 NSFileReadNoPermissionError，分不出"被 TCC 拦了"还是"文件没了"。
    ///
    /// 只读、不创建、不跟随不了的符号链接也无所谓；`O_NONBLOCK` 防住万一路径是个 FIFO。
    static func read(_ url: URL, limit: Int = maxFileBytes) -> ReadOutcome {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else {
            let code = errno
            return .failed(code: code, reason: describe(errno: code))
        }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            return .failed(code: code, reason: describe(errno: code))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .failed(code: 0, reason: "不是普通文件")
        }
        guard info.st_size <= off_t(limit) else {
            return .failed(code: 0, reason: "文件超过 \(limit / 1024) KiB 上限（\(info.st_size) 字节）")
        }

        let capacity = max(Int(info.st_size), 1)
        var buffer = [UInt8](repeating: 0, count: capacity)
        var filled = 0
        var readErrno: Int32 = 0
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while filled < capacity {
                let got = Darwin.read(fd, base.advanced(by: filled), capacity - filled)
                if got > 0 { filled += got; continue }
                if got == 0 { break }                 // EOF：文件比 fstat 说的短
                if errno == EINTR { continue }
                readErrno = errno
                return
            }
        }
        if readErrno != 0 {
            return .failed(code: readErrno, reason: describe(errno: readErrno))
        }
        return .data(Data(buffer[0..<filled]))
    }

    /// errno → 一句中文。EPERM 是本机最常见的那一种，要写清楚"不会弹窗、只能手动加白名单"。
    static func describe(errno code: Int32) -> String {
        let system = String(cString: strerror(code))
        switch code {
        case EPERM, EACCES:
            return "TCC 拒绝（errno \(code) \(system)）——需要在「系统设置 → 隐私与安全性 → "
                 + "完全磁盘访问」里勾上 brosis；系统不会为这一类权限弹窗"
        case ENOENT:
            return "文件不存在（errno \(code) \(system)）——这台机器可能从没设置过专注模式"
        default:
            return "读取失败（errno \(code) \(system)）"
        }
    }

    // MARK: - 判定

    /// 真读文件的入口。
    static func probe(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> FocusStatus {
        status(assertions: read(assertionsURL(home: home)),
               configurations: read(configurationsURL(home: home)))
    }

    /// 纯函数：给定两次读取结果，判定当前 Focus。自检拿合成样本直接跑这个。
    static func status(assertions: ReadOutcome, configurations: ReadOutcome) -> FocusStatus {
        switch assertions {
        case .failed(_, let reason):
            return .unavailable(reason: "Assertions.json \(reason)")
        case .data(let data):
            guard let identifiers = activeModeIdentifiers(inAssertions: data) else {
                return .unavailable(reason: "Assertions.json 解析失败（不是 JSON 或结构不认识）")
            }
            guard !identifiers.isEmpty else { return .inactive }
            var names: [String: String] = [:]
            if case .data(let configData) = configurations {
                names = modeNames(inConfigurations: configData)
            }
            return .active(identifiers.map {
                FocusMode(identifier: $0, name: names[$0] ?? shortName($0))
            })
        }
    }

    /// `com.apple.donotdisturb.mode.default` → `default`；没有点就原样返回。
    static func shortName(_ identifier: String) -> String {
        identifier.split(separator: ".").last.map(String.init) ?? identifier
    }

    // MARK: - 解析（宽容遍历，纯函数）

    /// Assertions.json 里当前生效的模式 id。
    ///
    /// 主键是 `assertionDetailsModeIdentifier`；万一以后换名字，退一步找
    /// "同一个字典里既有 `modeIdentifier` 又有以 `assertion` 开头的键"的情况。
    /// 返回 `nil` 表示**解析失败**（≠ 空数组"没有 Focus 生效"）。
    static func activeModeIdentifiers(inAssertions data: Data) -> [String]? {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var primary: [String] = []
        var fallback: [String] = []
        walk(root) { dict in
            if let value = dict["assertionDetailsModeIdentifier"] as? String, !value.isEmpty {
                primary.append(value)
            } else if let value = dict["modeIdentifier"] as? String, !value.isEmpty,
                      dict.keys.contains(where: { $0.hasPrefix("assertion") }) {
                fallback.append(value)
            }
        }
        return deduplicate(primary.isEmpty ? fallback : primary)
    }

    /// ModeConfigurations.json 里的 `模式 id → 显示名`。读不到就是空表（退回 id 末段）。
    ///
    /// 认两种形状：① 某个字典里同时有 `modeIdentifier` 与 `name`；
    /// ② 以模式 id 作键、值里（或值的 `mode` 里）有 `name`。
    static func modeNames(inConfigurations data: Data) -> [String: String] {
        guard !data.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: data) else { return [:] }
        var names: [String: String] = [:]
        walk(root) { dict in
            if let identifier = dict["modeIdentifier"] as? String,
               let name = dict["name"] as? String,
               !identifier.isEmpty, !name.isEmpty {
                if names[identifier] == nil { names[identifier] = name }
            }
            for (key, value) in dict where key.contains(".") {
                guard let inner = value as? [String: Any] else { continue }
                let name = (inner["name"] as? String)
                    ?? ((inner["mode"] as? [String: Any])?["name"] as? String)
                if let name, !name.isEmpty, names[key] == nil { names[key] = name }
            }
        }
        return names
    }

    /// 深度设上限：JSONSerialization 自己不会给出无限深的树，但格式不受我们控制，
    /// 加一道保险比出事之后再查栈溢出便宜。
    private static let maxDepth = 32

    private static func walk(_ node: Any, depth: Int = 0, _ visit: ([String: Any]) -> Void) {
        guard depth < maxDepth else { return }
        if let dict = node as? [String: Any] {
            visit(dict)
            for value in dict.values { walk(value, depth: depth + 1, visit) }
        } else if let array = node as? [Any] {
            for value in array { walk(value, depth: depth + 1, visit) }
        }
    }

    private static func deduplicate(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}

// MARK: - 暂停名单（3.12 之外的一条独立开关）

/// "这些 Focus 生效时暂停采集"的名单。**默认空 = 不联动**：启动时探一次
/// （`FocusMonitor.start()` 里的 `poll(force: true)`），之后空名单零 syscall。
enum FocusPausePolicy {

    /// UserDefaults 键，值是字符串数组：
    ///     defaults write com.brosis.app focus.pauseModes -array 工作 勿扰
    /// 名字、模式 id、id 末段都能写；`*` 表示"任何 Focus 生效就暂停"。
    static let modesKey = "focus.pauseModes"
    static let wildcard = "*"

    static func configured(_ defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.array(forKey: modesKey) as? [String] ?? []
        return raw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 比较前的归一化：去空白、大小写折叠。**不**做别的（中文没有大小写，
    /// 系统语言不同名字就不同，这一点如实写在 README 里）。
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 名单命中了哪一个模式；没命中 / 名单空 / 状态不是 active 都回 nil。
    ///
    /// 一个模式的三种写法都算命中：显示名、完整 id、id 末段。
    static func match(status: FocusStatus, list: [String]) -> FocusMode? {
        guard case .active(let modes) = status, !list.isEmpty else { return nil }
        let wanted = Set(list.map(normalize))
        if wanted.contains(wildcard) { return modes.first }
        for mode in modes {
            let candidates = [mode.name, mode.identifier, FocusProbe.shortName(mode.identifier)]
                .map(normalize)
                .filter { !$0.isEmpty }
            if candidates.contains(where: { wanted.contains($0) }) { return mode }
        }
        return nil
    }
}

// MARK: - 运行期：轮询 + 接到暂停触发器上

/// Focus 轮询器。**本文件不改 `AppDelegate.swift`**（d 批的并行约定）。接入方式两行：
///
///     // AppDelegate.applicationDidFinishLaunching(_:) 里，lock 建好之后：
///     focus = FocusMonitor()
///     focus.install(lock: lock, recorder: recorder)
///
///     // 菜单里加一行状态显示（可选但建议，不可用时要让用户看见原因）：
///     menu.addItem(disabledItem(focus?.menuDescription ?? "Focus 联动：未启动"))
///
/// 暂停走的是**现有那条路**：`LockController.apply(.focusPauseStarted / .focusPauseEnded)`，
/// 与安全输入 / 锁屏 / 屏保 / 私密浏览同一个 `pauseReasons` 集合、同一个恢复路径。
/// 这里不直接碰 `CaptureController`，也不自己判断"要不要截图"。
@MainActor
final class FocusMonitor {

    private(set) var status: FocusStatus = .unavailable(reason: "还没探测")
    private(set) var pausing = false
    private(set) var matched: FocusMode?
    /// 上一次真读文件的时刻（诊断用）。
    private(set) var lastProbeAt: Date?

    private weak var lock: LockController?
    private var recorder: Recorder?
    private let defaults: UserDefaults
    private var timer: Timer?

    /// 轮询间隔**与 `CaptureController` 的定时兜底同一个节奏**（默认 12 s，
    /// UserDefaults 键 `capture.periodicInterval`，下限 3 s）。
    /// 不另设一个键：多一个节奏就多一份要解释的东西，而 Focus 的变化频率远低于 12 s。
    nonisolated static var pollInterval: TimeInterval { CaptureController.periodicInterval }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 挂到锁定状态机上。与 `SyncController.install` 同样的写法：不覆盖已有回调。
    func install(lock: LockController, recorder: Recorder) {
        self.lock = lock
        self.recorder = recorder
        start()
    }

    func start() {
        stop()
        // 起步先探一次：名单是空的也探，这样菜单第一次打开就能说清楚"可不可用、为什么"。
        poll(force: true)
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 一次轮询。
    ///
    /// - Parameter force: 名单为空时也去读文件（只有 `start()` 用）。
    ///   平时名单为空就**一个 syscall 都不做**——默认不联动就该是零成本。
    func poll(force: Bool = false) {
        let list = FocusPausePolicy.configured(defaults)
        guard !list.isEmpty || force else {
            // 名单空：不读文件。但如果之前因为联动暂停过，必须把暂停放掉。
            if pausing { setPausing(false, mode: nil, because: "暂停名单已清空") }
            return
        }

        let previous = status
        let next = FocusProbe.probe()
        status = next
        lastProbeAt = Date()

        // 可用性变了就记一条（不可用 → 可用 也记），别的变化不刷事件表。
        if previous.isAvailable != next.isAvailable || previous.unavailableReason != next.unavailableReason {
            recorder?.logEvent(kind: "focus_probe",
                               detail: next.eventDetail + " poll_s=\(Int(Self.pollInterval))")
        }

        let hit = FocusPausePolicy.match(status: next, list: list)
        setPausing(hit != nil, mode: hit, because: nil)
    }

    private func setPausing(_ wanted: Bool, mode: FocusMode?, because note: String?) {
        guard wanted != pausing else {
            matched = mode
            return
        }
        pausing = wanted
        matched = mode
        let detail: String
        if let mode {
            detail = "mode=\(mode.label) id=\(mode.identifier) poll_s=\(Int(Self.pollInterval))"
        } else {
            detail = note ?? "focus 已退出 poll_s=\(Int(Self.pollInterval))"
        }
        recorder?.logEvent(kind: wanted ? "focus_pause" : "focus_resume", detail: detail)
        // 走现有暂停触发器，恢复也走同一条。
        lock?.apply(wanted ? .focusPauseStarted : .focusPauseEnded)
    }

    /// 菜单里那一行。不可用时**必须**把原因写出来（T18 的要求）。
    /// 不可用且原因是 TCC 拒绝（EPERM / EACCES）：菜单要给一个「打开完全磁盘访问设置」的入口。
    /// 这一类 TCC 服务系统不会弹窗，只能用户自己去勾，所以入口比一行灰字有用得多。
    var needsFullDiskAccess: Bool {
        status.unavailableReason?.contains("TCC 拒绝") == true
    }

    /// 「系统设置 → 隐私与安全性 → 完全磁盘访问」的直达链接（不触发任何授权弹窗）。
    static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var menuDescription: String {
        let list = FocusPausePolicy.configured(defaults)
        if let reason = status.unavailableReason {
            return "Focus 联动不可用（\(reason)）"
        }
        if list.isEmpty {
            return "Focus 联动：未配置（UserDefaults 键 \(FocusPausePolicy.modesKey)）"
        }
        switch status {
        case .unavailable:
            return "Focus 联动不可用"
        case .inactive:
            return "Focus 联动：待命（当前没有 Focus 生效，名单 \(list.count) 条）"
        case .active(let modes):
            let names = modes.map(\.label).joined(separator: "、")
            if let matched {
                return "Focus 联动：\(matched.label) 生效 → 已暂停采集"
            }
            return "Focus：\(names) 生效，不在暂停名单（名单 \(list.count) 条）"
        }
    }
}
