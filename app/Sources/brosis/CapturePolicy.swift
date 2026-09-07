import AppKit
import BrosisCore
import Foundation

/// 3.12 应用采集清单的**数据层**。
///
/// 界面（设置里那一页"应用"清单窗口）不在本轮范围内，第二轮做；本轮做的是
/// 三档模式的存储、解析、默认清单、新应用首次出现的处理、以及"生效方式在采集时"这条规则。
///
/// 三档来自 `BrosisCore.CapturePolicyMode`（与库里 `app_policies.mode` 的 CHECK 一一对应）：
///
/// | 模式 | 记什么 | 采集端怎么执行 |
/// |---|---|---|
/// | `none` 不采集 | 什么都不记，连应用切换事件也不记 | 进 `SCContentFilter` 排除列表、跳过 AX、连观察记录都不写 |
/// | `eventsOnly` 只记事件 | 应用、窗口标题、URL / 路径、时长 | 不读正文、不做截图内容检查 |
/// | `eventsAndContent` 事件 + 内容 | 上一档再加正文 | 全开 |
///
/// **权威存储是库里的 `app_policies`**（3.12：本机配置，不随 iCloud 同步）。
/// 进程内只做一层缓存，miss 时查库；库里没有就按"内置默认不采集清单 → 全局默认"决定，
/// **只在库里确实没有这一行时插入**，并记一条运行期事件。
///
/// 「只插不改」与「库没开只给临时判定」这两条是硬的：库关着的时候读不到 `app_policies`，
/// 若把"读不到 = 新应用"的默认档缓存下来、开库后补写，用户显式设成「不采集」的应用
/// 会在一次锁定 / 解锁之后被悄悄改回「事件 + 内容」——那等于 3.12 的优先级失效。
final class CapturePolicyStore: @unchecked Sendable {

    static let shared = CapturePolicyStore()

    /// 3.12「新应用：首次出现时按全局默认处理（建议"事件 + 内容"）」的**出厂值**。
    /// 用户可以在应用清单窗口顶部改，改完存 UserDefaults 的 `policy.globalDefault`
    /// （见实例属性 `globalDefault`）；这个 static 只是"没设过时用哪个"。
    static let builtinGlobalDefault: CapturePolicyMode = .eventsAndContent

    /// 全局默认档的存放键。**存 UserDefaults 而不是库里**，理由同 `pausedTodayKey`：
    /// 库还没开（`locked`）的时候也要能读到它，否则锁定期间冒出来的新应用会按出厂值判定，
    /// 与用户设的全局默认不一致。
    static let globalDefaultKey = "policy.globalDefault"

    /// 已经在菜单栏提示过的新应用（3.12「菜单栏提示一次」的那个"一次"）。
    static let newAppNoticedKey = "policy.newAppNoticed"

    /// 一次解析的结果。
    struct Resolution: Sendable, Equatable {
        var mode: CapturePolicyMode
        var source: CapturePolicySource
        /// 「暂停采集当前应用（今天）」的到期时刻；nil 表示不是临时项。
        var temporaryUntil: Date?
        /// 本次解析是不是这个 bundle id 第一次被看到（要写事件、要落库）。
        var firstSeen: Bool
        /// **临时判定**：库没开（`locked` / `locking` / `unlocking`）或读库失败时给出的判定。
        /// 它只用于"这一刻要不要采"，**绝不缓存、绝不落库、也不记 `app_policy_new_app`**。
        /// 库没开的时候读不到 `app_policies`，把"读不到"当成"没有"写回去，
        /// 就会把用户显式设的「不采集」在一次锁定 / 解锁之后改回「事件 + 内容」。
        var provisional: Bool = false

        var isTemporary: Bool { temporaryUntil != nil }
    }

    /// 「生效方式在采集时，不是入库后过滤」——把模式翻译成三个开关。
    struct Gate: Sendable, Equatable {
        /// 记不记观察（含应用切换事件）。
        var recordsEvents: Bool
        /// 读不读正文（AX / 适配器 / OCR）。
        var readsContent: Bool
        /// 要不要进 `SCContentFilter(display:excludingApplications:)` 的排除列表。
        var excludedFromScreenCapture: Bool
    }

    static func gate(for mode: CapturePolicyMode) -> Gate {
        switch mode {
        case .none:
            return Gate(recordsEvents: false, readsContent: false, excludedFromScreenCapture: true)
        case .eventsOnly:
            return Gate(recordsEvents: true, readsContent: false, excludedFromScreenCapture: false)
        case .eventsAndContent:
            return Gate(recordsEvents: true, readsContent: true, excludedFromScreenCapture: false)
        }
    }

    // MARK: - 纯函数形式的判定（自检直接跑它，不碰库、不碰 UserDefaults）

    /// 解析优先级：**今日临时暂停 > 库里已有的策略 > 内置默认不采集清单 > 全局默认**。
    ///
    /// 临时暂停排在库之上，是因为它就是"临时把这个应用切到不采集"，
    /// 到期后必须自动回到原来那一档，所以不能覆盖写库。
    static func decide(stored: (mode: CapturePolicyMode, source: CapturePolicySource)?,
                       temporaryPausedUntil: Date?,
                       denylisted: Bool,
                       now: Date = Date(),
                       globalDefault: CapturePolicyMode = CapturePolicyStore.builtinGlobalDefault)
        -> Resolution {
        if let until = temporaryPausedUntil, until > now {
            return Resolution(mode: .none, source: .user, temporaryUntil: until, firstSeen: false)
        }
        if let stored {
            return Resolution(mode: stored.mode, source: stored.source,
                              temporaryUntil: nil, firstSeen: false)
        }
        if denylisted {
            return Resolution(mode: .none, source: .builtinDenylist,
                              temporaryUntil: nil, firstSeen: true)
        }
        return Resolution(mode: globalDefault, source: .default, temporaryUntil: nil, firstSeen: true)
    }

    // MARK: - 运行期状态

    /// 今日临时暂停的存放键：`[bundle id: 到期 Unix 秒]`。
    /// 放 UserDefaults 而不是库里，理由是它不是"策略"而是"临时开关"，
    /// 而且必须在库还没开（`locked`）的时候也能读到。
    static let pausedTodayKey = "policy.pausedToday"

    private let lock = NSLock()
    /// 3.12「新应用首次出现时菜单栏提示一次」：本次进程里还没被用户看掉的提示，按出现顺序。
    /// 只在 `resolve` 真的往 `app_policies` 插了一行、且这个 bundle id 从没提示过时才进来。
    private var pendingNewApps: [String] = []
    /// 串行化 `app_policies` 的「读 → 不存在才插入」与用户改档的写，
    /// 保证两者不会交错（本进程是这张表唯一的写者）。**取它的时候不持有 `lock`**。
    private let dbLock = NSLock()
    private var cache: [String: (mode: CapturePolicyMode, source: CapturePolicySource)] = [:]
    /// **只有用户显式改档**才会在库没开时攒进这里，等开库后补写。
    /// 默认判定（内置清单 / 全局默认）一律不攒——那正是 R1 复核抓到的覆盖用户设置的路径。
    private var pendingUserChoices: [String: (mode: CapturePolicyMode, source: CapturePolicySource)] = [:]
    private var recorder: Recorder?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func attach(recorder: Recorder) {
        lock.lock()
        self.recorder = recorder
        let pending = pendingUserChoices
        pendingUserChoices.removeAll()
        lock.unlock()
        for (bundleID, value) in pending {
            persistUserChoice(bundleID: bundleID, mode: value.mode, source: value.source)
            lock.withLock { cache[bundleID] = value }
        }
    }

    /// 库开着吗（菜单显示"这一档是不是真判定"要用）。
    var isStoreBacked: Bool { recorderHandle()?.isOpen == true }

    /// 解析一个 bundle id 的当前策略。线程安全，采集队列与主线程都会调。
    ///
    /// 三条口径（前两条是 R1 复核后改的）：
    /// 1. **库没开就只给临时判定**：不缓存、不落库、不写事件（`provisional = true`）。
    /// 2. **落库只在"库里确实没有这一行"时插入**，绝不 UPDATE 已有行——
    ///    覆盖只能来自用户显式改档（`setMode`）。
    /// 3. **读库失败等同于"不知道"**，同样只给临时判定，绝不当成"没有"去写。
    @discardableResult
    func resolve(bundleID: String?) -> Resolution {
        guard let bundleID, !bundleID.isEmpty else {
            // 拿不到 bundle id 的进程（少数无 bundle 的可执行文件）不落库，按全局默认处理。
            return Resolution(mode: globalDefault, source: .default,
                              temporaryUntil: nil, firstSeen: false, provisional: true)
        }
        if let until = temporaryPause(bundleID: bundleID) {
            return Resolution(mode: .none, source: .user, temporaryUntil: until,
                              firstSeen: false, provisional: false)
        }
        let denylisted = BuiltinDenylist.shared.contains(bundleID)
        let fallback = globalDefault
        if let cached = (lock.withLock { cache[bundleID] }) {
            return Self.decide(stored: cached, temporaryPausedUntil: nil, denylisted: denylisted,
                               globalDefault: fallback)
        }

        // 缓存 miss：查库。库没开就只给临时判定。
        guard let recorder = recorderHandle(), recorder.isOpen else {
            return Self.provisional(denylisted: denylisted, globalDefault: fallback)
        }
        // 「读 → 不存在才插入」放在同一把 dbLock 下，不与 setMode 的写交错。
        let outcome: (resolution: Resolution, inserted: Bool)? = dbLock.withLock {
            recorder.withStore { store -> (resolution: Resolution, inserted: Bool) in
                let stored = try store.appPolicy(bundleID: bundleID)
                let resolution = Self.decide(stored: stored, temporaryPausedUntil: nil,
                                             denylisted: denylisted, globalDefault: fallback)
                guard resolution.firstSeen else { return (resolution, false) }
                try store.setAppPolicy(bundleID: bundleID, mode: resolution.mode,
                                       source: resolution.source)
                return (resolution, true)
            }
        }
        guard let outcome else {
            return Self.provisional(denylisted: denylisted, globalDefault: fallback)
        }
        lock.withLock { cache[bundleID] = (outcome.resolution.mode, outcome.resolution.source) }
        if outcome.inserted {
            recorder.logEvent(
                kind: "app_policy_new_app",
                detail: "bundle=\(bundleID) mode=\(outcome.resolution.mode.rawValue) "
                      + "source=\(outcome.resolution.source.rawValue)")
            noteNewApp(bundleID: bundleID)
        }
        return outcome.resolution
    }

    /// 库没开 / 读不到时的临时判定：内置清单还是要认（它不依赖库），其余按全局默认。
    private static func provisional(denylisted: Bool,
                                    globalDefault: CapturePolicyMode) -> Resolution {
        var resolution = decide(stored: nil, temporaryPausedUntil: nil, denylisted: denylisted,
                                globalDefault: globalDefault)
        resolution.firstSeen = false
        resolution.provisional = true
        return resolution
    }

    /// 只读判定，不落库、不写事件——菜单刷新这种一秒几次的地方用它。
    /// 库没开时缓存是空的，返回的是"内置清单 → 全局默认"的临时值（菜单会标注"库未打开"）。
    func mode(for bundleID: String?) -> CapturePolicyMode {
        guard let bundleID, !bundleID.isEmpty else { return globalDefault }
        if let until = temporaryPause(bundleID: bundleID), until > Date() { return .none }
        if let cached = (lock.withLock { cache[bundleID] }) { return cached.mode }
        if BuiltinDenylist.shared.contains(bundleID) { return .none }
        return globalDefault
    }

    /// 用户显式改档（应用清单窗口与菜单快捷项都走这里）。**这是唯一会覆盖库里已有行的路径**。
    func setMode(_ mode: CapturePolicyMode, bundleID: String, source: CapturePolicySource = .user) {
        lock.withLock { cache[bundleID] = (mode, source) }
        clearTemporaryPause(bundleID: bundleID)
        persistUserChoice(bundleID: bundleID, mode: mode, source: source)
        recorderHandle()?.logEvent(kind: "app_policy_changed",
                                   detail: "bundle=\(bundleID) mode=\(mode.rawValue) "
                                         + "source=\(source.rawValue)")
    }

    // MARK: - 全局默认档（3.12 清单窗口顶部那一格）

    /// 新应用首次出现时按哪一档处理。没设过就是出厂值「事件 + 内容」。
    ///
    /// **改它不会动任何已有的 `app_policies` 行**：那些行是"已经定过的应用"，
    /// 其中还包括用户显式设过的档；全局默认只对"以后才第一次出现的应用"生效。
    var globalDefault: CapturePolicyMode {
        defaults.string(forKey: Self.globalDefaultKey)
            .flatMap(CapturePolicyMode.init(rawValue:)) ?? Self.builtinGlobalDefault
    }

    func setGlobalDefault(_ mode: CapturePolicyMode) {
        defaults.set(mode.rawValue, forKey: Self.globalDefaultKey)
        recorderHandle()?.logEvent(kind: "app_policy_global_default",
                                   detail: "mode=\(mode.rawValue)")
    }

    // MARK: - 新应用提示（3.12「菜单栏提示一次，可一键改档」）

    /// `resolve` 真的插了一行 `app_policies` 时调用。**每个 bundle id 只提示一次**：
    /// 提示过的写进 UserDefaults 的 `policy.newAppNoticed`，重启 app 也不会再提示同一个。
    private func noteNewApp(bundleID: String) {
        var noticed = Set(defaults.stringArray(forKey: Self.newAppNoticedKey) ?? [])
        guard !noticed.contains(bundleID) else { return }
        noticed.insert(bundleID)
        defaults.set(Array(noticed).sorted(), forKey: Self.newAppNoticedKey)
        lock.withLock {
            guard !pendingNewApps.contains(bundleID) else { return }
            pendingNewApps.append(bundleID)
            // 提示是给人看的，不是队列：只留最近 5 条，免得离开一天回来菜单里挂着几十行。
            if pendingNewApps.count > 5 { pendingNewApps.removeFirst(pendingNewApps.count - 5) }
        }
    }

    /// 菜单刷新时读：还没被看掉的新应用提示（最早的在前）。
    func pendingNewAppNotices() -> [String] { lock.withLock { pendingNewApps } }

    /// 用户点了提示行（或点了"知道了"）之后把它划掉。
    func clearNewAppNotice(bundleID: String) {
        lock.withLock { pendingNewApps.removeAll { $0 == bundleID } }
    }

    // MARK: - 菜单快捷项：暂停采集当前应用

    /// 「暂停采集当前应用（今天）」：临时切到不采集，到本地时间当日 24:00 自动失效。
    @discardableResult
    func pauseToday(bundleID: String, calendar: Calendar = .current, now: Date = Date()) -> Date {
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(24 * 3600)
        var table = pausedTodayTable()
        table[bundleID] = endOfDay.timeIntervalSince1970
        defaults.set(table, forKey: Self.pausedTodayKey)
        recorderHandle()?.logEvent(
            kind: "app_policy_paused_today",
            detail: "bundle=\(bundleID) until=\(Int(endOfDay.timeIntervalSince1970))")
        return endOfDay
    }

    /// 「暂停采集当前应用（永久）」：把这个应用真正改档到"不采集"，写库。
    func pauseForever(bundleID: String) {
        setMode(.none, bundleID: bundleID, source: .user)
    }

    /// 撤销临时暂停。
    func clearTemporaryPause(bundleID: String) {
        var table = pausedTodayTable()
        guard table.removeValue(forKey: bundleID) != nil else { return }
        defaults.set(table, forKey: Self.pausedTodayKey)
    }

    /// 当前仍然有效的临时暂停到期时刻。顺手清理已过期的条目。
    func temporaryPause(bundleID: String) -> Date? {
        let table = pausedTodayTable()
        guard let epoch = table[bundleID] else { return nil }
        let until = Date(timeIntervalSince1970: epoch)
        if until <= Date() {
            clearTemporaryPause(bundleID: bundleID)
            return nil
        }
        return until
    }

    /// 当前仍然有效的全部临时暂停（应用清单窗口那一列要用）。顺手把过期的条目清掉。
    func temporaryPauses(now: Date = Date()) -> [String: Date] {
        let table = pausedTodayTable()
        var live: [String: Date] = [:]
        var expired: [String] = []
        for (bundleID, epoch) in table {
            let until = Date(timeIntervalSince1970: epoch)
            if until > now { live[bundleID] = until } else { expired.append(bundleID) }
        }
        if !expired.isEmpty {
            var pruned = table
            for bundleID in expired { pruned.removeValue(forKey: bundleID) }
            defaults.set(pruned, forKey: Self.pausedTodayKey)
        }
        return live
    }

    private func pausedTodayTable() -> [String: Double] {
        (defaults.dictionary(forKey: Self.pausedTodayKey) as? [String: Double]) ?? [:]
    }

    // MARK: - 内部

    private func recorderHandle() -> Recorder? { lock.withLock { recorder } }

    /// 用户显式改档的落库。库开着直接写（覆盖旧值就是用户的本意）；
    /// 库没开就攒进 `pendingUserChoices`，下一次开库补写——用户在锁定期间点的
    /// 「永久不采集」不能丢。**默认判定不走这里**（见 `resolve`）。
    private func persistUserChoice(bundleID: String, mode: CapturePolicyMode,
                                   source: CapturePolicySource) {
        guard let recorder = recorderHandle(), recorder.isOpen else {
            lock.withLock { pendingUserChoices[bundleID] = (mode, source) }
            return
        }
        dbLock.withLock {
            _ = recorder.withStore { store in
                try store.setAppPolicy(bundleID: bundleID, mode: mode, source: source)
            }
        }
    }

    /// 换库 / 锁定后重新开库时清缓存，避免把上一个库的策略带过来。
    func invalidateCache() {
        lock.withLock { cache.removeAll() }
    }
}

// MARK: - 内置默认「不采集」清单

/// 3.12 的内置默认不采集清单：**`Resources/exclusions.txt` 与代码内清单取并集**。
///
/// 与 M0 的差别：M0 是"文件存在就整个覆盖代码默认集合"，M1 改成并集。
/// 覆盖语义在这里是错的——用户往文件里加一个自己的应用，不应该把密码管理器整类默默放开。
/// 要放开某一项，走 3.12 的应用清单把它改成"只记事件 / 事件+内容"，那是**用户显式操作**，
/// 优先级本来就高于内置清单（见 `CapturePolicyStore.decide`）。
final class BuiltinDenylist: @unchecked Sendable {

    static let shared = BuiltinDenylist()

    /// 代码内清单，按 3.12 的四个类别分组。
    ///
    /// **诚实说明**：密码管理器、钥匙串访问、验证器这三类的 bundle id 是常见发行版的取值；
    /// 银行券商类各家 mac 客户端的 bundle id 没有在本机逐一核对过（本机没装），
    /// 它们是"给个起点"，真正兜底的是用户在应用清单里自己勾。漏一个也不会静默出错：
    /// 新应用首次出现会写一条 `app_policy_new_app` 事件，用户能看见并改档。
    static let categories: [(name: String, bundleIDs: [String])] = [
        ("密码管理器", [
            "com.1password.1password",
            "com.agilebits.onepassword7",
            "com.agilebits.onepassword-osx",
            "com.lastpass.LastPass",
            "com.lastpass.lastpassmacdesktop",
            "org.keepassxc.keepassxc",
            "com.bitwarden.desktop",
            "com.dashlane.Dashlane",
            "in.sinew.Enpass-Desktop",
            "com.nordpass.macos",
            "com.apple.Passwords",
        ]),
        ("钥匙串访问", [
            "com.apple.keychainaccess",
        ]),
        ("验证器", [
            "com.authy.authy-mac",
            "com.yubico.Authenticator",
            "com.yubico.ykman",
            "com.mattrubin.Authenticator",
            "com.raivo-otp.macos",
        ]),
        ("银行 / 券商", [
            "com.futunn.FutuNiuNiu",
            "com.tigerbrokers.TigerTrade",
            "com.interactivebrokers.tws",
            "com.charlesschwab.schwab",
            "com.robinhood.Robinhood",
            "com.eastmoney.mac",
        ]),
        ("远程屏幕（会把别人的屏幕录进来）", [
            "com.apple.ScreenSharing",
            "com.apple.iPhoneMirroring",
        ]),
    ]

    private let ids: Set<String>
    /// 来自 `Contents/Resources/exclusions.txt` 的条数（0 = 没读到文件）。
    let fromResource: Int
    /// 代码内清单的条数。
    let fromCode: Int

    private init() {
        var code = Set<String>()
        for category in Self.categories { code.formUnion(category.bundleIDs) }
        var resource = Set<String>()
        if let url = Bundle.main.url(forResource: "exclusions", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            resource = Set(text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") })
        }
        fromCode = code.count
        fromResource = resource.count
        ids = code.union(resource)
    }

    func contains(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        // app_policies.bundle_id 是 COLLATE NOCASE，这里也按不区分大小写比。
        return ids.contains { $0.compare(bundleID, options: .caseInsensitive) == .orderedSame }
    }

    var count: Int { ids.count }
    var sorted: [String] { ids.sorted() }
}

// MARK: - 私密浏览（尽力而为）

/// 私密浏览检测。**只是"尽力"，不是保证**（计划 4.2 把它列在暂停触发器里，没有给可靠机制）。
///
/// 做法：窗口标题里出现无痕标记时，这次观察的 `completeness` 记 `excluded`、**不存正文**，
/// 事件（应用、标题、时间）照记——不然台账会凭空少一段时间。
///
/// 已知局限，三条都写在这里而不是藏起来：
/// 1. **靠标题就一定漏**。Safari 的无痕窗口标题带"无痕浏览"，但那是**系统语言相关**的；
///    换成别的语言环境（英文是 "Private Browsing"）要另一条标记，本表只列了中英两种。
/// 2. **网页可以改写标题**。`document.title` 是页面自己控制的，标题栏显示的是页面标题时，
///    无痕标记可能根本不出现在 `AXTitle` 里。
/// 3. **Chromium 系的无痕窗口标题不一定带标记**。Chrome 的无痕窗口标题就是页面标题，
///    "（无痕模式）"只出现在窗口边角的徽章上，AX 读不到。所以对 Chromium 系这条基本无效，
///    真要挡住只能靠 3.12 把整个浏览器改档，或者等 M3 的域名清单。
enum PrivateBrowsing {

    /// 标题里出现任意一条就算私密浏览。
    static let titleMarkers = [
        "无痕浏览", "私密浏览", "隐私浏览", "无痕式视窗",
        "Private Browsing", "InPrivate", "Incognito",
    ]

    /// 只对浏览器做这项判定：别的应用标题里出现"私密浏览"四个字大概率是在讨论它，不该被排除。
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "company.thebrowser.Browser", "org.mozilla.firefox",
    ]

    static func isPrivate(bundleID: String?, windowTitle: String?) -> Bool {
        guard let bundleID, browserBundleIDs.contains(bundleID),
              let title = windowTitle, !title.isEmpty else { return false }
        return titleMarkers.contains { title.localizedCaseInsensitiveContains($0) }
    }
}
