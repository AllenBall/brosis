import Foundation

/// 界面语言。
///
/// **只管界面。** 自检输出、CLI（`--mcp list` / `--ax-probe` / `--dump-ocr`）、
/// 运行期事件的 `detail`、代码注释一律保持中文——它们面向的是开发和排障，
/// 翻译它们只会让日志和文档对不上号。
enum UILanguage: String, CaseIterable, Sendable {
    /// 跟随系统（默认）。
    case system
    case chinese = "zh-Hans"
    case english = "en"

    /// 设置面板里显示的名字。
    ///
    /// 两个具体语言写**自身的名字**（endonym）且永不翻译：一个看不懂当前界面语言的人，
    /// 也要能在列表里认出自己那一行。「跟随系统」没有 endonym 可言，只能跟着当前界面语言走，
    /// 所以只有它用 `L()`——这不是疏漏，是这条规则本身的例外。
    var displayName: String {
        switch self {
        case .system:  return L("跟随系统", "Follow system")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// 界面语言的解析、缓存与变更广播。
enum L10n {

    static let languageKey = "ui.language"

    // MARK: - 解析与缓存

    /// 缓存本体。Swift 6 不允许裸的可变全局，所以装进一个自带锁的小盒子。
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UILanguage?

        /// 命中就返回；没有就在**锁外**算（`Locale.preferredLanguages` 要走 CF 桥接，
        /// 不该攥着锁做），算完再存。两个线程同时算一遍无所谓——结果一样。
        func resolve(_ compute: () -> UILanguage) -> UILanguage {
            lock.lock()
            if let value { lock.unlock(); return value }
            lock.unlock()
            let computed = compute()
            lock.lock()
            value = computed
            lock.unlock()
            return computed
        }

        func clear() { lock.lock(); value = nil; lock.unlock() }
    }

    private static let cache = Cache()

    /// 用户存下来的选择（没设过就是 `.system`）。
    static var preference: UILanguage {
        UserDefaults.standard.string(forKey: languageKey)
            .flatMap(UILanguage.init(rawValue:)) ?? .system
    }

    /// 真正生效的语言，**永远不是 `.system`**。
    ///
    /// **必须缓存**：`Locale.preferredLanguages` 每次调用都要重读 `AppleLanguages` 并把
    /// NSArray 桥接成新的 Swift 数组，实测 1.15 µs；而 `L()` 有 450 多个调用点，
    /// 采集清单每重画一行要走十几次、搜索框每敲一个字符就整表重画。
    /// 缓存后一次读是 20 ns 量级。用锁而不是 `@MainActor`：整晚建索引的进度文案
    /// 是在后台线程拼的（`OvernightIndexJob`），`L()` 不是主线程专用。
    static var resolved: UILanguage { cache.resolve(resolveNow) }

    /// 显式选了语言时**根本不碰** `Locale`——那 1.15 µs 是白花的。
    private static func resolveNow() -> UILanguage {
        let preferred = preference
        guard preferred == .system else { return preferred }
        return resolve(preference: .system, preferredLanguages: Locale.preferredLanguages)
    }

    /// 纯函数，自检逐条盯着它。
    ///
    /// 跟随系统时按 `Locale.preferredLanguages` 的**第一项**判：以 `zh` 开头就是中文，
    /// 其余一律英文。不去区分简繁——界面文案只有简体一份，硬按 `zh-Hant` 分流
    /// 只会给出一个并不存在的选择。
    static func resolve(preference: UILanguage, preferredLanguages: [String]) -> UILanguage {
        guard preference == .system else { return preference }
        guard let first = preferredLanguages.first?.lowercased() else { return .english }
        return first.hasPrefix("zh") ? .chinese : .english
    }

    // MARK: - 变更

    static func set(_ language: UILanguage) {
        guard language != preference else { return }
        UserDefaults.standard.set(language.rawValue, forKey: languageKey)
        invalidate()
    }

    /// 系统语言变了（`.system` 档的解析结果会跟着变），由 `AppDelegate` 挂上通知。
    static func invalidate() {
        cache.clear()
        DispatchQueue.main.async { MainActor.assumeIsolated { notifyLanguageChanged() } }
    }

    // MARK: - 窗口登记表

    /// 语言变了要做的事，由各个窗口**自己登记**。
    ///
    /// 为什么不在 `AppDelegate` 里点名调用：点名要求每个窗口都是能从 AppDelegate 够得着的
    /// 单例，而实际上加密导出与跨设备同步的窗口控制器是别人的 `private lazy var`——
    /// 第一版的点名名单因此一开始就漏了它们俩，而且**结构上补不齐**。
    /// 改成谁搭窗口谁登记之后，新加窗口不可能被忘掉。
    @MainActor private static var changeHandlers: [() -> Void] = []

    /// 在窗口搭好时登记一次。闭包应当 `[weak self]` 捕获，控制器没了就是空操作。
    @MainActor
    static func onLanguageChange(_ handler: @escaping () -> Void) {
        changeHandlers.append(handler)
    }

    @MainActor
    private static func notifyLanguageChanged() {
        for handler in changeHandlers { handler() }
    }
}

/// 界面字符串。中文在前、英文在后，两种语言并排放着好审。
///
/// 用行内两参而不是 `NSLocalizedString` + `.lproj`：`.lproj` 要改 bundle 组装与
/// SwiftPM 资源处理，会给「app 不依赖构建目录」那道发布闸门增加变数；而且运行时切语言
/// 需要替换 bundle。
///
/// **注意这套写法保证不了什么**：编译器只保证**已经包起来**的字面量两种语言都在，
/// 对忘了包的那一句一个字都保证不了——首次全量转换就漏了 18 处。真正的兜底是
/// `build_app.sh` 里的 `check_ui_strings.py`，它扫界面文件里没包 `L()` 的中文字面量。
func L(_ zh: String, _ en: String) -> String {
    L10n.resolved == .chinese ? zh : en
}

/// 开 / 关这类两态值的统一说法。
///
/// 转换时这个映射被各写各的：`开/关`、`已开启/未开启`、`未启用` 三种中文对同一组英文，
/// 分散在 8 个调用点。新加一处时有三种先例可抄，等于没有先例。
func LOnOff(_ on: Bool) -> String { on ? L("开", "on") : L("关", "off") }
