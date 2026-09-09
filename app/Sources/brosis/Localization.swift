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

    /// 设置面板里显示的名字。**每一项都用它自己的语言写**——
    /// 一个看不懂当前界面语言的人，也要能在列表里认出自己的语言。
    var displayName: String {
        switch self {
        case .system:  return L("跟随系统", "Follow system")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// 界面语言的解析、存储与变更广播。
enum L10n {

    static let languageKey = "ui.language"

    /// 语言变了。菜单每次打开都重建，所以它自己会跟上；**窗口不会**——
    /// 窗口的 contentView 是打开时一次性搭出来的，所以收到这条通知要把已开的窗口关掉，
    /// 下次打开就是新语言。比起就地重排每一个控件，这个做法简单且不会漏。
    static let didChange = Notification.Name("brosis.uiLanguageChanged")

    /// 用户存下来的选择（没设过就是 `.system`）。
    static var preference: UILanguage {
        UserDefaults.standard.string(forKey: languageKey)
            .flatMap(UILanguage.init(rawValue:)) ?? .system
    }

    /// 真正生效的语言，**永远不是 `.system`**。
    static var resolved: UILanguage {
        resolve(preference: preference, preferredLanguages: Locale.preferredLanguages)
    }

    static func set(_ language: UILanguage) {
        guard language != preference else { return }
        UserDefaults.standard.set(language.rawValue, forKey: languageKey)
        NotificationCenter.default.post(name: didChange, object: nil)
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
}

/// 界面字符串。中文在前、英文在后，两种语言并排放着好审。
///
/// 用行内两参而不是 `NSLocalizedString` + `.lproj`：`.lproj` 要改 bundle 组装与
/// SwiftPM 资源处理，会给「app 不依赖构建目录」那道发布闸门增加变数；而且运行时切语言
/// 需要替换 bundle。行内写法里**编译器保证两种语言都在**，不存在"某个 key 漏翻"这种
/// 只在运行时才暴露的错误。
func L(_ zh: String, _ en: String) -> String {
    L10n.resolved == .chinese ? zh : en
}
