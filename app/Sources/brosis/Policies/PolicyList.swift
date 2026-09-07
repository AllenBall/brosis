import BrosisCore
import Foundation

/// 3.12 应用采集清单的**视图模型**：数据源合并、分组判定、排序、过滤、改档流程的状态机。
///
/// 这个文件里**没有一行 AppKit**，全是纯函数与纯数据，理由有两个：
/// 1. 自检要整段跑它（`--self-check` 不许创建 `NSApplication`、不许弹窗）；
/// 2. 窗口本身（`PoliciesWindow.swift`）只剩"把行画出来、把点击转成一次调用"，
///    出错的余地小。
///
/// 数据源是三处的**并集**（计划 3.12：「来源是 NSWorkspace 的运行记录和本系统自己的观察记录」）：
///
/// | 来源 | 给出什么 | 为什么少不了 |
/// |---|---|---|
/// | `app_policies` 全表 | 已经定过档的应用（含内置清单里被记下来的） | 「不采集」的应用永远没有观察，只能从这里看到 |
/// | 最近 N 天的 `observations` 聚合 | 观察数、完整性分布、最近出现时间 | 3.12 要求每行显示这些 |
/// | `NSWorkspace` 当前运行的 GUI 应用 | 刚装上、还没被采集端碰到的应用 | 用户想"先设好再用"时得能找到它 |

// MARK: - 分组

/// 3.12「分组显示：有适配器 / 通用采集 / 默认不采集」。
enum PolicyGroup: Int, CaseIterable, Sendable, Comparable {
    case adapter = 0
    case generic = 1
    case denylisted = 2

    var title: String {
        switch self {
        case .adapter:    return "有适配器"
        case .generic:    return "通用采集"
        case .denylisted: return "默认不采集"
        }
    }

    static func < (lhs: PolicyGroup, rhs: PolicyGroup) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - 一行

/// 清单里的一行。**只有显示要用的东西**，没有任何正文。
struct PolicyListRow: Sendable, Equatable {
    var bundleID: String
    /// 显示名。优先级：`apps.name`（库里记过的）> `NSWorkspace` 的 localizedName > bundle id。
    var name: String
    /// **存下来的那一档**（弹出菜单显示它）。临时暂停不改它。
    var mode: CapturePolicyMode
    var source: CapturePolicySource
    var group: PolicyGroup
    /// 命中的适配规则 id（`group == .adapter` 时非空）。
    var adapterID: String?
    /// 最近 N 天的观察数与完整性分布（四项之和 == observations）。
    var observations: Int = 0
    var complete: Int = 0
    var partial: Int = 0
    var unavailable: Int = 0
    var excluded: Int = 0
    /// 最近一条观察的时间戳（Unix 毫秒）；0 表示窗口内没有观察。
    var lastSeenMS: Int64 = 0
    /// 现在是不是在运行（`NSWorkspace`）。
    var running: Bool = false
    /// 「今日暂停」的到期时刻；非 nil 时**实际**在用的是「不采集」。
    var temporaryUntil: Date?

    /// 这一刻真正生效的档（临时暂停压过存下来的那一档，与 `CapturePolicyStore.decide` 同一口径）。
    var effectiveMode: CapturePolicyMode { temporaryUntil == nil ? mode : .none }

    /// 用户显式设过档吗（列表里标一个"你设的"，好和默认判定区分开）。
    var isUserSet: Bool { source == .user }

    /// 完整性分布那一列。**四态都写出来，包括 0**——3.12 说这一列是给人判断"值不值得留"的，
    /// 少一态就看不出是"没发生"还是"没统计"。
    var completenessLabel: String {
        guard observations > 0 else { return "—" }
        return "完整 \(complete) · 部分 \(partial) · 不可用 \(unavailable) · 排除 \(excluded)"
    }

    /// 「最近出现」那一列。相对时间，避免把精确到秒的时间点摊在界面上。
    func lastSeenLabel(now: Date = Date()) -> String {
        guard lastSeenMS > 0 else { return running ? "运行中，无观察" : "—" }
        let seconds = now.timeIntervalSince1970 - Double(lastSeenMS) / 1000
        switch seconds {
        case ..<0:      return "刚刚"
        case ..<60:     return "\(Int(seconds)) 秒前"
        case ..<3600:   return "\(Int(seconds / 60)) 分钟前"
        case ..<86_400: return "\(Int(seconds / 3600)) 小时前"
        default:        return "\(Int(seconds / 86_400)) 天前"
        }
    }

    /// 状态那一列：运行中 / 今日暂停 / 用户设过。
    func statusLabel(now: Date = Date()) -> String {
        var parts: [String] = []
        if running { parts.append("运行中") }
        if let until = temporaryUntil, until > now {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            parts.append("今日暂停至 \(formatter.string(from: until))")
        }
        if isUserSet { parts.append("你设的") }
        if source == .builtinDenylist { parts.append("内置清单") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

// MARK: - 合并 / 分组 / 排序 / 过滤

enum PolicyList {

    /// 3.12 那一页默认的统计窗口：最近 7 天。
    static let statsWindowDays = 7

    /// `NSWorkspace` 那一路的入参。抽成结构体是为了让自检能喂合成数据
    /// （自检不许创建 `NSApplication`，也就不该去问 `NSWorkspace`）。
    struct RunningApp: Sendable, Equatable {
        var bundleID: String
        var name: String
    }

    /// 分组判定。**顺序是"内置清单 → 有适配器 → 通用"**，不是反过来：
    /// 一个应用既在内置默认不采集清单里、又碰巧有适配规则时，
    /// 用户最需要看到的是"它默认不被采集"，而不是"它有适配器"。
    ///
    /// 分组按的是**出厂分类**，不是当前档位——用户把某个密码管理器显式改成「事件 + 内容」之后，
    /// 它仍然留在「默认不采集」组里，只是那一行的状态列会标「你设的」。
    /// 这样"这台机器上哪些应用是默认被挡掉的"始终一眼看得全。
    static func group(bundleID: String,
                      isDenylisted: (String) -> Bool,
                      adapterID: (String) -> String?) -> (PolicyGroup, String?) {
        if isDenylisted(bundleID) { return (.denylisted, nil) }
        if let id = adapterID(bundleID) { return (.adapter, id) }
        return (.generic, nil)
    }

    /// 三处数据源合并成行。**纯函数**：不碰库、不碰 UserDefaults、不碰 NSWorkspace。
    ///
    /// - Parameters:
    ///   - policies: `Store.appPolicies()` 全表。
    ///   - stats: `Store.appObservationStats(since:)`（最近 N 天）。
    ///   - names: `Store.appNames()`，给没有近期观察的应用取显示名。
    ///   - running: `NSWorkspace` 里 activationPolicy == .regular 的应用。
    ///   - temporaryPauses: `bundle id → 今日暂停到期时刻`（已过期的不要传进来）。
    ///   - globalDefault: 没有策略行、也不在内置清单里的应用按哪一档显示。
    static func merge(policies: [AppPolicyRecord],
                      stats: [AppObservationStats],
                      names: [String: String],
                      running: [RunningApp],
                      temporaryPauses: [String: Date],
                      globalDefault: CapturePolicyMode,
                      isDenylisted: (String) -> Bool,
                      adapterID: (String) -> String?) -> [PolicyListRow] {
        var policyByID: [String: AppPolicyRecord] = [:]
        for row in policies { policyByID[row.bundleID] = row }
        var statsByID: [String: AppObservationStats] = [:]
        for row in stats { statsByID[row.bundleID] = row }
        var runningByID: [String: RunningApp] = [:]
        for app in running where !app.bundleID.isEmpty { runningByID[app.bundleID] = app }

        // 并集。用有序去重而不是 Set，保证同一份输入永远给出同一份输出（自检要逐行比）。
        var seen = Set<String>()
        var ids: [String] = []
        for id in policies.map(\.bundleID) + stats.map(\.bundleID) + running.map(\.bundleID)
        where !id.isEmpty && seen.insert(id).inserted {
            ids.append(id)
        }

        return ids.map { id in
            let stored = policyByID[id].map { (mode: $0.mode, source: $0.source) }
            // 没有策略行时按与采集端**同一个**判定函数给出应该显示的档，
            // 不在这里另写一套 if（否则界面显示的和实际采集的会分叉）。
            let resolved = CapturePolicyStore.decide(
                stored: stored, temporaryPausedUntil: nil,
                denylisted: isDenylisted(id), globalDefault: globalDefault)
            let (group, adapter) = group(bundleID: id, isDenylisted: isDenylisted,
                                         adapterID: adapterID)
            let stat = statsByID[id]
            let displayName = names[id] ?? stat?.name ?? runningByID[id]?.name ?? id
            return PolicyListRow(
                bundleID: id,
                name: displayName.isEmpty ? id : displayName,
                mode: resolved.mode,
                source: resolved.source,
                group: group,
                adapterID: adapter,
                observations: stat?.observations ?? 0,
                complete: stat?.complete ?? 0,
                partial: stat?.partial ?? 0,
                unavailable: stat?.unavailable ?? 0,
                excluded: stat?.excluded ?? 0,
                lastSeenMS: stat?.lastSeenMS ?? 0,
                running: runningByID[id] != nil,
                temporaryUntil: temporaryPauses[id])
        }
    }

    /// 排序：**先分组，组内按最近 N 天观察数倒序，再按最近出现倒序，最后按 bundle id**。
    /// 最后那一级是为了让结果全序（同名同数的两行不会随机换位置）。
    static func sorted(_ rows: [PolicyListRow]) -> [PolicyListRow] {
        rows.sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.observations != b.observations { return a.observations > b.observations }
            if a.lastSeenMS != b.lastSeenMS { return a.lastSeenMS > b.lastSeenMS }
            return a.bundleID.lowercased() < b.bundleID.lowercased()
        }
    }

    /// 搜索框过滤：按应用名或 bundle id 的**不区分大小写子串**匹配。
    /// 空串（或只有空白）= 不过滤。
    static func filtered(_ rows: [PolicyListRow], query: String) -> [PolicyListRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.bundleID.localizedCaseInsensitiveContains(needle)
        }
    }

    /// 合并 + 排序 + 过滤一条龙（窗口每次刷新调它）。
    static func build(policies: [AppPolicyRecord],
                      stats: [AppObservationStats],
                      names: [String: String],
                      running: [RunningApp],
                      temporaryPauses: [String: Date],
                      globalDefault: CapturePolicyMode,
                      query: String = "",
                      isDenylisted: (String) -> Bool,
                      adapterID: (String) -> String?) -> [PolicyListRow] {
        filtered(sorted(merge(policies: policies, stats: stats, names: names, running: running,
                              temporaryPauses: temporaryPauses, globalDefault: globalDefault,
                              isDenylisted: isDenylisted, adapterID: adapterID)),
                 query: query)
    }
}

// MARK: - 改档流程的状态机

/// 三档的高低。3.12「**改为更低档时**询问是否删除该应用已有数据」要靠它判定方向。
extension CapturePolicyMode {
    /// 不采集 0 < 只记事件 1 < 事件 + 内容 2。
    var rank: Int {
        switch self {
        case .none:             return 0
        case .eventsOnly:       return 1
        case .eventsAndContent: return 2
        }
    }

    var label: String {
        switch self {
        case .none:             return "不采集"
        case .eventsOnly:       return "只记事件"
        case .eventsAndContent: return "事件 + 内容"
        }
    }
}

/// 用户在某一行的弹出菜单里选了新的一档之后要做什么。
///
/// 拆成状态机而不是直接在点击回调里写 if，是因为这里有三条容易搞错的边：
/// 1. **库没开就不能改档**（`app_policies` 在库里，写不进去）。3.12 的临时暂停是 UserDefaults，
///    库没开也能用；改档不是。
/// 2. **只有降档才问删数据**，升档与平级不问——升档不会让已有数据变得"不该存在"。
/// 3. **这个应用一条数据都没有时不要弹框**。弹一个"是否删除 0 条"的框是纯噪音。
enum PolicyModeChange: Equatable {

    /// 库锁着，什么都不做，只提示。
    case blockedLocked
    /// 档位没变。
    case unchanged
    /// 直接写库，不问。
    case apply
    /// 先写库，再问"要不要删这个应用已有的 N 条观察"（默认不删）。
    case applyThenAskDelete(existing: Int)

    /// - Parameters:
    ///   - current: 这一行**存下来**的那一档（不是"临时暂停后的生效档"）。
    ///   - next: 用户刚选的那一档。
    ///   - storeOpen: 库开着吗。
    ///   - existingObservations: 这个应用**全库**未删除的观察数（不是最近 7 天）。
    static func plan(current: CapturePolicyMode,
                     next: CapturePolicyMode,
                     storeOpen: Bool,
                     existingObservations: Int) -> PolicyModeChange {
        guard storeOpen else { return .blockedLocked }
        guard current != next else { return .unchanged }
        guard next.rank < current.rank else { return .apply }
        return existingObservations > 0 ? .applyThenAskDelete(existing: existingObservations)
                                        : .apply
    }
}

// MARK: - 自检用例（`SelfCheck` 与 `--dump-vectors` 共用）

enum PolicyListVectors {

    /// 合成的一套输入：两个有适配器的应用、一个通用应用、一个内置清单里的应用、
    /// 一个只在运行没有任何记录的应用。
    static let bundleSafari = "com.apple.Safari"
    static let bundleWeChat = "com.tencent.xinWeChat"
    static let bundleTerminal = "com.apple.Terminal"
    static let bundle1Password = "com.1password.1password"
    static let bundleFreshApp = "com.example.brand-new"
    /// **既在内置清单里、又有适配规则**的那个：`com.tencent.WeChat` 是微信规则里的第二个
    /// bundle id，这里假设用户把它写进了 `exclusions.txt`。分组顺序那条规则
    /// （内置清单 > 有适配器）只有这一行测得出来——两者不重叠的行换个顺序结果一样。
    static let bundleBothDenylistAndAdapter = "com.tencent.WeChat"

    static let nowMS: Int64 = 1_757_000_000_000

    static var policies: [AppPolicyRecord] {
        [
            AppPolicyRecord(bundleID: bundleSafari, mode: .eventsAndContent,
                            source: .default, updatedAt: nowMS - 86_400_000),
            AppPolicyRecord(bundleID: bundleWeChat, mode: .eventsOnly,
                            source: .user, updatedAt: nowMS - 3_600_000),
            AppPolicyRecord(bundleID: bundleTerminal, mode: .eventsAndContent,
                            source: .default, updatedAt: nowMS - 7_200_000),
            AppPolicyRecord(bundleID: bundle1Password, mode: .none,
                            source: .builtinDenylist, updatedAt: nowMS - 600_000),
            AppPolicyRecord(bundleID: bundleBothDenylistAndAdapter, mode: .none,
                            source: .builtinDenylist, updatedAt: nowMS - 500_000),
        ]
    }

    static var stats: [AppObservationStats] {
        [
            AppObservationStats(bundleID: bundleSafari, name: "Safari", observations: 40,
                                complete: 30, partial: 8, unavailable: 2, excluded: 0,
                                lastSeenMS: nowMS - 60_000),
            AppObservationStats(bundleID: bundleWeChat, name: "微信", observations: 12,
                                complete: 0, partial: 0, unavailable: 0, excluded: 12,
                                lastSeenMS: nowMS - 120_000),
            AppObservationStats(bundleID: bundleTerminal, name: "终端", observations: 12,
                                complete: 12, partial: 0, unavailable: 0, excluded: 0,
                                lastSeenMS: nowMS - 30_000),
        ]
    }

    static var names: [String: String] {
        ["com.apple.Safari": "Safari", "com.tencent.xinWeChat": "微信",
         "com.apple.Terminal": "终端"]
    }

    static var running: [PolicyList.RunningApp] {
        [
            PolicyList.RunningApp(bundleID: bundleSafari, name: "Safari"),
            PolicyList.RunningApp(bundleID: bundleFreshApp, name: "全新应用"),
        ]
    }

    /// 内置清单的替身（自检里不依赖 `BuiltinDenylist` 读得到 bundle 资源）。
    static func isDenylisted(_ bundleID: String) -> Bool {
        bundleID == bundle1Password || bundleID == bundleBothDenylistAndAdapter
    }

    /// 适配规则的替身：直接问真的 `AdapterRegistry`（它是纯数据，不碰系统）。
    static func adapterID(_ bundleID: String) -> String? {
        let rule = AdapterRegistry.rule(for: bundleID)
        return rule.id == AdapterRegistry.generic.id ? nil : rule.id
    }

    /// 全套跑一遍，给自检用。
    static func build(query: String = "",
                      temporaryPauses: [String: Date] = [:],
                      globalDefault: CapturePolicyMode = .eventsAndContent) -> [PolicyListRow] {
        PolicyList.build(policies: policies, stats: stats, names: names, running: running,
                         temporaryPauses: temporaryPauses, globalDefault: globalDefault,
                         query: query, isDenylisted: isDenylisted, adapterID: adapterID)
    }

    /// 改档状态机的判定表。`name` 只用于失败时定位。
    struct ChangeCase: Sendable {
        var name: String
        var current: CapturePolicyMode
        var next: CapturePolicyMode
        var storeOpen: Bool
        var existing: Int
        var expected: PolicyModeChange
    }

    static let changeCases: [ChangeCase] = [
        ChangeCase(name: "库锁着 · 任何改档都被挡", current: .eventsAndContent, next: .none,
                   storeOpen: false, existing: 100, expected: .blockedLocked),
        ChangeCase(name: "库锁着 · 连升档也挡（app_policies 在库里）", current: .none,
                   next: .eventsAndContent, storeOpen: false, existing: 0,
                   expected: .blockedLocked),
        ChangeCase(name: "同一档 · 什么都不做", current: .eventsOnly, next: .eventsOnly,
                   storeOpen: true, existing: 50, expected: .unchanged),
        ChangeCase(name: "升档 · 不问删数据（只记事件 → 事件+内容）", current: .eventsOnly,
                   next: .eventsAndContent, storeOpen: true, existing: 50, expected: .apply),
        ChangeCase(name: "升档 · 不问删数据（不采集 → 只记事件）", current: .none,
                   next: .eventsOnly, storeOpen: true, existing: 50, expected: .apply),
        ChangeCase(name: "降一档 · 问删数据", current: .eventsAndContent, next: .eventsOnly,
                   storeOpen: true, existing: 37, expected: .applyThenAskDelete(existing: 37)),
        ChangeCase(name: "降两档 · 问删数据", current: .eventsAndContent, next: .none,
                   storeOpen: true, existing: 1, expected: .applyThenAskDelete(existing: 1)),
        ChangeCase(name: "降档但这个应用没有数据 · 不弹框", current: .eventsAndContent,
                   next: .none, storeOpen: true, existing: 0, expected: .apply),
    ]
}
