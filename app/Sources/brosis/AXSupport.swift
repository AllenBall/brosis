import AppKit
import ApplicationServices
import BrosisCore
import Foundation

/// AX 读取工具。
///
/// **超时口径（务必按 SDK 头文件理解）**：`AXUIElementSetMessagingTimeout` 只对传进去的那个元素生效，
/// 只有传 `AXUIElementCreateSystemWide()` 才是**本进程全局**。`AXUIElement.h` 原文：
/// “Pass the system-wide accessibility object … if you want to set the timeout globally for this
/// process. Setting the timeout on another accessibility object sets it only for that object …”。
/// 所以只给应用元素和焦点窗口设超时是不够的——BFS 里通过 `kAXChildren` 拿到的每个子元素
/// 都会退回系统默认超时（约 6 s），目标应用一旦卡住，菜单栏 app 的主线程会跟着冻结。
/// 正确做法是进程启动时调用一次 `installGlobalMessagingTimeout()`（见 `AppDelegate`），
/// 之后所有 AX 元素（含遍历中新拿到的子元素）统一用 0.5 s（报告 3.1：0.5–1 s）。
enum AX {

    /// 单次 AX 调用的超时，单位秒。
    static let messagingTimeout: Float = 0.5

    /// 把 0.5 s 设成**本进程全局** AX 超时。必须在任何 AX 读取之前调用一次。
    ///
    /// 这个调用不向任何应用发消息、不需要辅助功能权限、不会触发 TCC 弹窗：
    /// 它只是把超时值写进本进程的 AX 客户端状态。返回 `AXError`，`.success` 才算装上了。
    @discardableResult
    static func installGlobalMessagingTimeout(_ timeout: Float = messagingTimeout) -> AXError {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
    }

    /// 默认遍历上限，防止 Electron 大树把主线程占满。按 bundle id 的收紧值见 `bfsLimitsByBundleID`。
    static let maxNodes = 1500
    static let maxDepth = 12
    /// 窗口 URL 搜索（找第一个 AXWebArea）的默认节点上限。
    static let webAreaSearchNodes = 400

    // MARK: - Chromium / Electron 系判定

    /// **第一路：显式 bundle id 清单。**Chromium / Electron 系应用读 AX 前必须先设
    /// `AXManualAccessibility`（报告 3.2）。这是公开属性，**默认只设它**；私有的
    /// `AXEnhancedUserInterface` 要用户显式打开开关才设，见 `enhancedUserInterfaceKey`。
    ///
    /// 清单只是第一路。M0 实测（`tools/bench/results/m0_closeout_2026-09-07.md` 2.2）：
    /// Claude 桌面版 `com.anthropic.claudefordesktop`（探针里停留时间第一）74 条观察、
    /// AX 正文字符合计 **0**，原因就是它不在这份清单里，没设过 `AXManualAccessibility`。
    /// 人工维护的清单追不上新装的应用，所以另加第二路通用判定（`bundleLooksChromium`）。
    static let chromiumFamilyBundleIDs: Set<String> = [
        // 飞书会议是 Lark Framework 里的 Chromium 辅助进程（Lark Helper (Iron)），
        // 它的 bundle 里没有 Contents/Frameworks，结构检测抓不到，只能进这份清单——
        // 不进的话 `enableManualAccessibilityIfNeeded` 会提前返回，两个属性一个都不设。
        "com.bytedance.macos.feishu.iron",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "company.thebrowser.Browser",
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.tinyspeck.slackmacgap", "md.obsidian", "com.hnc.Discord",
        "com.electron.lark", "com.larksuite.larkApp", "com.bytedance.macos.feishu",
        "com.anthropic.claudefordesktop"
    ]

    /// **第二路：通用框架检测。**判据是**结构**不是名字：`Contents/Frameworks/<任意>.framework`
    /// 底下有没有 `Helpers` 目录——Chromium 把渲染 / GPU / 工具子进程和 crashpad 放在那儿，
    /// 原生 app 的 framework 不长这样。
    ///
    /// 为什么不再按框架名匹配（2026-09-09 改）：原来只认 `Electron Framework.framework` 与
    /// `Chromium Embedded Framework.framework` 两个名字，而**四个 Chromium 应用里有两个改了名**
    /// （飞书叫 `Lark Framework`，ChatGPT / Codex 叫 `Codex Framework`），只能靠人工清单兜底，
    /// 而人工清单追不上新装的应用——Codex 就没在里面，判定结果是"不是 Chromium"。
    ///
    /// **光有 `Helpers` 目录不够，里面得真的装着 Chromium 的子进程。**
    /// 第一版只判目录在不在，全量扫 `/Applications` 后发现 6 个假阳性：
    /// Word / Excel / PowerPoint（`ai.framework/Helpers`）、iMovie（`Flexo.framework/Helpers`）
    /// ——这两个的 Helpers 是**空目录**——以及 BlueStacks 两个（`QtWebEngineCore.framework`）。
    /// 把 Office 判成 Chromium 的后果是给它们设 AXManualAccessibility、空树重扫、还开 OCR 回退。
    ///
    /// 收紧后的判据是 Chromium 的子进程命名：crashpad 处理器，或名字里带
    /// Helper / (Renderer) / (GPU) 的 `.app`。实测 13 个真 Chromium 一个不少
    /// （Chrome / Claude / ChatGPT / Lark / LM Studio / ZCode / Kimi / Figma / Eagle /
    /// 极空间 / Multica / OpenCode / WorkBuddy），6 个假阳性全部剔除。
    static let chromiumHelpersDirectory = "Helpers"

    static func helpersLooksChromium(_ entries: [String]) -> Bool {
        entries.contains { entry in
            entry.contains("crashpad_handler")
                || (entry.hasSuffix(".app")
                    && (entry.contains("Helper") || entry.contains("(Renderer)")
                        || entry.contains("(GPU)")))
        }
    }

    /// 判定依据，原样写进 `runtime_events.detail` 的 `detection=` 字段。
    enum ChromiumDetection: String, Sendable {
        /// 命中显式 bundle id 清单。
        case list = "list"
        /// 命中 Electron / CEF 框架。
        case framework = "framework"
        /// 两路都没命中，按原生应用处理（不设 AXManualAccessibility）。
        case notChromium = "none"

        /// "是不是 Chromium 系"只在这里定义一次——此前 `!= .notChromium` 抄在五个地方。
        var isChromium: Bool { self != .notChromium }
    }

    /// 判定结果按 bundle id 缓存：通用检测要摸文件系统，每次切应用都摸一遍没必要；
    /// 缓存同时用来决定要不要写 `runtime_events`——同一个 bundle id 只在第一次判定时写一条，
    /// 否则一天几百次应用切换会把 runtime_events 刷满。
    private final class KeyedCache<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Value] = [:]

        /// 只读，不算也不存。
        func peek(_ key: String) -> Value? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        /// 命中缓存就直接返回；没有就在**锁外**算一次再存进去。
        /// `firstSeen` = 这次是不是本进程第一次判定这个 bundle id。
        func resolve(_ key: String, compute: () -> Value) -> (value: Value, firstSeen: Bool) {
            lock.lock()
            if let cached = values[key] {
                lock.unlock()
                return (cached, false)
            }
            lock.unlock()
            let computed = compute()          // 文件系统探测不在锁里做
            lock.lock()
            defer { lock.unlock() }
            if let raced = values[key] { return (raced, false) }
            values[key] = computed
            return (computed, true)
        }
    }

    private static let detectionCache = KeyedCache<ChromiumDetection>()

    /// 「这个 bundle 是不是浏览器」的缓存。判据只读 Info.plist，但一次要解一整个 plist，
    /// 而 `rule(for:)` 每次扫描都会问，所以按 bundle id 缓存。
    private static let browserCache = KeyedCache<Bool>()

    /// 这个 bundle 有没有**把网页链接当成自己的主业**——即：`CFBundleURLTypes` 里存在一条
    /// **只含 http / https** 的类型。
    ///
    /// 判据为什么是"纯"而不是"含"：浏览器把网页 URL 声明成一条专用类型，而只想拦链接的
    /// 应用是把 http 塞进自己那条里。实测三家的声明形状：
    ///
    ///     Chrome ：{ name "Web site URL", schemes [http, https] }        ← 专用，另有一条 google-chrome
    ///     Safari ：{ name "Web site URL", schemes [http, https] }        ← 同上
    ///     ChatGPT：{ name "ChatGPT",      schemes [codex, http, https] } ← 混进了自有 scheme
    ///
    /// 第一版写的是"含 http 即可"，**自检当场抓出了误报**：ChatGPT（`com.openai.codex`）
    /// 在人工清单里算 Chromium 系、又声明了 http，于是被判成浏览器——和当初 `Helpers`
    /// 检测把 Word / iMovie 判成 Chromium 是同一类错误。改成"纯"之后重扫本机
    /// `/Applications`：声明 http 的 4 个应用里，Chrome / Safari / Zen 判是（三个都真是浏览器），
    /// ChatGPT 判否。零误报零漏报。
    ///
    /// **只读文件系统**：不发 AX 消息、不需要权限、不启动被检测的应用，自检可以直接调。
    static func bundleHandlesWebLinks(at bundleURL: URL?) -> Bool {
        guard let bundleURL,
              let plist = NSDictionary(contentsOf:
                  bundleURL.appendingPathComponent("Contents/Info.plist")),
              let types = plist["CFBundleURLTypes"] as? [[String: Any]]
        else { return false }
        return types.contains { type in
            guard let raw = type["CFBundleURLSchemes"] as? [String] else { return false }
            let schemes = Set(raw.map { $0.lowercased() })
            return !schemes.isDisjoint(with: ["http", "https"])
                && schemes.isSubset(of: ["http", "https"])
        }
    }

    /// `bundleHandlesWebLinks` 的带缓存版本。判据只读 Info.plist，但一次要解一整个 plist，
    /// 而 `rule(for:)` 每次扫描都会问。
    ///
    /// **只管"是不是浏览器"这一件事**，不再和 Chromium 判定 AND 在一起：
    /// 上一版写成 `isChromiumBrowser`，而唯一的调用点在八行之前就已经算出并持有
    /// `chromium` 这个局部量了——包起来只是让同一件事被算两遍，还多出一条永远走不到的
    /// 空 bundleID 分支。两个判据本来就正交（Safari、Firefox 是浏览器但不是 Chromium 系）。
    static func bundleIsBrowser(bundleID: String?, bundleURL: URL?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return bundleHandlesWebLinks(at: bundleURL) }
        return browserCache.resolve(bundleID) { bundleHandlesWebLinks(at: bundleURL) }.value
    }

    /// 通用检测：`<bundle>/Contents/Frameworks/` 下有没有 Electron / CEF 框架目录。
    ///
    /// **只读文件系统**：不发任何 AX 消息、不需要辅助功能权限、不启动被检测的应用，
    /// 所以 `--self-check` 可以直接调用它做验证。
    /// 名字改了（原来叫 `bundleLooksChromium`）：它找的早就不是某个 Electron 框架，
    /// 而是"任意框架底下有没有 Chromium 的子进程"。
    ///
    /// 只看 `<F>.framework/Helpers` 这一层就够：带版本目录的框架（飞书、Codex）按 macOS 惯例
    /// 都有顶层符号链接指向 `Versions/Current/Helpers`，`contentsOfDirectory` 会跟着走。
    /// 第一版还多写了一圈遍历 `Versions/<版本号>` 的循环——全量扫 `/Applications` 的 19 个
    /// 带 Helpers 的框架，**没有一个需要它**，唯一走到那条分支的是自检里手工造的假 bundle。
    static func bundleLooksChromium(at bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let fm = FileManager.default
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(atPath: frameworks.path) else { return false }
        for entry in entries where entry.hasSuffix(".framework") {
            let helpers = frameworks.appendingPathComponent(entry, isDirectory: true)
                .appendingPathComponent(chromiumHelpersDirectory, isDirectory: true)
            guard let children = try? fm.contentsOfDirectory(atPath: helpers.path) else { continue }
            if helpersLooksChromium(children) { return true }
        }
        return false
    }

    /// 只查缓存、**不摸文件系统也不写缓存**。给那些手头没有 bundleURL 的调用方用
    /// （策略列表、OCR 协调器）：采集端在应用激活时已经用带 URL 的那条算过并缓存了，
    /// 这里直接取答案；真没算过就返回 nil，调用方按"不是 Chromium"处理——
    /// 与其拿 nil 的 URL 去算出一个错的 `.notChromium` **并把它缓存起来**，不如不答。
    static func cachedChromiumDetection(bundleID: String?) -> ChromiumDetection? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return detectionCache.peek(bundleID)
    }

    /// 两路合一的判定：显式清单优先，其次通用框架检测；结果按 bundle id 缓存。
    /// 同样不发 AX 消息，自检可以调用。
    static func chromiumDetection(bundleID: String?, bundleURL: URL?)
        -> (detection: ChromiumDetection, firstSeen: Bool) {
        guard let bundleID, !bundleID.isEmpty else {
            // 没有 bundle id 就没法缓存（不同应用会撞同一个 key），也不写 runtime_events。
            return (bundleLooksChromium(at: bundleURL) ? .framework : .notChromium, false)
        }
        let cached = detectionCache.resolve(bundleID) {
            if chromiumFamilyBundleIDs.contains(bundleID) { return .list }
            return bundleLooksChromium(at: bundleURL) ? .framework : .notChromium
        }
        return (cached.value, cached.firstSeen)
    }

    /// 应用元素。这里再设一次是冗余的防守：全局超时正常时它与全局值相同，
    /// 万一 `installGlobalMessagingTimeout()` 没装上，至少这一层还是 0.5 s。
    static func applicationElement(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// 一次「是不是 Chromium 系 + 有没有设上 AXManualAccessibility」的结果。
    struct ManualAccessibilityResult: Sendable {
        var bundleID: String
        var detection: ChromiumDetection
        /// 是否真的设了 `AXManualAccessibility`（`detection == .notChromium` 时为 false）。
        var applied: Bool
        /// `AXUIElementSetAttributeValue` 的返回值；没设过时为 nil。
        var axError: AXError?
        /// 这个 bundle id 是不是本进程第一次判定。调用方用它决定要不要写 runtime_events。
        var firstSeen: Bool
        /// 设 `AXEnhancedUserInterface` 的返回值。nil = 开关关着，没设。
        var enhancedAXError: AXError?

        var succeeded: Bool { applied && axError == .success }

        /// 写进 `runtime_events.detail`：bundle id + 检测依据 + 设置结果。
        var detail: String {
            var text = "bundle=\(bundleID) detection=\(detection.rawValue)"
            if let axError {
                text += " set=\(axError == .success ? "ok" : "failed") AXError=\(axError.rawValue)"
            } else {
                text += " set=skipped"
            }
            // 私有属性单独记一段：出了事要能从审计里看出当时到底开没开。
            if let enhancedAXError {
                text += " enhanced=\(enhancedAXError == .success ? "ok" : "failed")"
                      + " AXError=\(enhancedAXError.rawValue)"
            }
            return text
        }
    }

    // MARK: - AXEnhancedUserInterface（私有属性，**默认开**，用户可关）

    /// 开关键。**默认 true**（2026-09-10 用户在看过实测数据与核实过的危害之后定的）。
    ///
    /// 为什么值得默认开：Chrome 不设这个属性就**没有 AXWebArea**，整棵树 43 个节点全是
    /// 浏览器外壳，正文只能 OCR——而 OCR 的中文错字率高到不可用（实测同一页
    /// 「轻松衔接初中化学」被认成「轻松衢換忉申化孕」）。设上之后走 DOM 文本：逐字准确、
    /// 含视口外内容、且**完全不跑 Vision**（Chrome 是重度使用的应用，这一项同时省电）。
    ///
    /// 代价见下。它仍然是开关，任何时候可以关：
    ///
    /// Chromium 收到它就进入无障碍模式并**镜像输入**；设置它的那个客户端**突然断开**时，
    /// 把最近缓冲的按键**重放进当时的焦点输入框**。
    ///
    /// 危害的确切形状（2026-09-10 核过原始出处 screenpipe #3884，不是转述）：
    /// 复现用例是在 Chromium 应用里输入 `abcd`，退出无障碍客户端后输入框变成
    /// **`abcdbcdbcd`**——是**把你刚敲的内容重复一遍**，不是塞进随机乱码。
    /// issue 里确认这是已知的 Chromium/AppKit 交互；1Password、Alfred、TextExpander 中过同一个。
    ///
    /// 所以风险窗口是**brosis 退出的那一刻**，落点是 Chromium 系应用里当时的焦点输入框。
    /// 平时开着不触发；而"退出"包括更新装新版时被杀掉——那正是 issue 说的 abrupt departure。
    /// 常驻后台的记录器要把这件事说清楚——所以它是开关、README 里写明了症状与触发时机，
    /// 而不是藏起来。**风险窗口只有退出那一刻**，这是它可以默认开的前提。
    ///
    /// 关掉：`defaults write com.brosis.app ax.enhancedUserInterface -bool false`（改完重启 app）
    /// 回到默认（开）：`defaults delete com.brosis.app ax.enhancedUserInterface`
    static let enhancedUserInterfaceKey = "ax.enhancedUserInterface"

    /// **`object(forKey:)` 而不是 `bool(forKey:)`**：后者读不到键时返回 false，
    /// 那样"没设过"就会被当成"用户关掉了"，默认值根本生效不了。
    static func enhancedUserInterfaceEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enhancedUserInterfaceKey) as? Bool ?? true
    }

    /// 对 Chromium / Electron 系应用打开手动无障碍。失败不影响其他通道。
    ///
    /// 两个属性的分工：`AXManualAccessibility` 是 Electron 层为第三方 AT 打的补丁（公开），
    /// 纯 Chromium（Chrome / Edge）不认，只吃私有的 `AXEnhancedUserInterface`。
    ///
    /// `wantsEnhanced`：**这个应用的规则真的会去读 AX 树吗**。只有会读的才设私有属性。
    /// 不加这道门的话，凡是被判为 Chromium 系的应用都会被设上——本机 `/Applications` 里
    /// 结构检测命中 19 个（Slack、VS Code、Discord、Codex、Claude 桌面版……），
    /// 而声明了 `enhancedRegions` 的只有 3 条规则。其余十几个应用要为此长期承担
    /// Chromium 侧的无障碍树维护开销（每个标签页 / webview 都建树并保持同步），
    /// 我们一个字都不读；更要紧的是，**按键重放的风险面被扩大到了零收益的应用上**。
    ///
    /// **设了就不再撤**：按键重放发生在"客户端断开"那一刻，我们能做的是不主动制造这个时刻——
    /// 不去把它设回 false。进程退出时系统那一侧的断开无法避免，这是开关本身的代价。
    @discardableResult
    static func enableManualAccessibilityIfNeeded(bundleID: String?, bundleURL: URL?, pid: pid_t,
                                                  wantsEnhanced: Bool,
                                                  defaults: UserDefaults = .standard)
        -> ManualAccessibilityResult {
        let (detection, firstSeen) = chromiumDetection(bundleID: bundleID, bundleURL: bundleURL)
        let key = bundleID ?? "(unknown)"
        guard detection != .notChromium else {
            return ManualAccessibilityResult(bundleID: key, detection: detection,
                                             applied: false, axError: nil, firstSeen: firstSeen)
        }
        let element = applicationElement(pid: pid)
        let error = AXUIElementSetAttributeValue(
            element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var enhanced: AXError?
        if wantsEnhanced, enhancedUserInterfaceEnabled(defaults) {
            enhanced = AXUIElementSetAttributeValue(
                element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        return ManualAccessibilityResult(bundleID: key, detection: detection,
                                         applied: true, axError: error, firstSeen: firstSeen,
                                         enhancedAXError: enhanced)
    }

    // MARK: - BFS 限额

    /// 一次遍历的限额。
    struct BFSLimits: Sendable {
        var maxNodes: Int
        var maxDepth: Int

        var label: String { "nodes=\(maxNodes) depth=\(maxDepth)" }
    }

    static let defaultBFSLimits = BFSLimits(maxNodes: maxNodes, maxDepth: maxDepth)

    /// 按 bundle id 的限额表。**默认不变**（1500 节点 / 12 层），只对已知会把 AX 拖慢的应用收紧。
    ///
    /// 访达：M0 实测 41 条观察里 9 条（**22%**）0.5 s 超时（m0_closeout 2.2），
    /// 大目录的列表节点极多，收到 400 节点 / 6 层。注意超时本身发生在
    /// `kAXFocusedWindow` 那一次调用上，限额只减少同一路径上的遍历开销，效果要授权后重跑才算数。
    static let bfsLimitsByBundleID: [String: BFSLimits] = [
        "com.apple.finder": BFSLimits(maxNodes: 400, maxDepth: 6)
    ]

    static func bfsLimits(bundleID: String?) -> BFSLimits {
        guard let bundleID, let limits = bfsLimitsByBundleID[bundleID] else { return defaultBFSLimits }
        return limits
    }

    /// 深度上限命中判定（纯函数，自检覆盖）。
    ///
    /// **R2 修正的语义**：`hit=depth` 表示"确实有子树因为深度上限没被展开"，
    /// 而不是"有元素刚好落在第 `maxDepth` 层"。旧写法只要取出一个 `depth == maxDepth`
    /// 的元素就置位，而这层元素通常是叶子（`AXStaticText` 之类），
    /// 于是限深的应用（访达 6 层）几乎每次遍历都报 `hit=depth`，事件里全是噪声。
    ///
    /// `hasChildren` 是 `@autoclosure`：**已经命中过就不再求值**，
    /// 所以一次遍历最多为这个标志位多发一轮 `kAXChildren` 消息。
    static func depthLimitHit(alreadyHit: Bool,
                              depth: Int,
                              limits: BFSLimits,
                              hasChildren: @autoclosure () -> Bool) -> Bool {
        if alreadyHit { return true }
        guard depth >= limits.maxDepth else { return false }
        return hasChildren()
    }

    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let url = value as? URL { return url.absoluteString }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func role(_ element: AXUIElement) -> String {
        string(element, kAXRoleAttribute as String) ?? "AXUnknown"
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, kAXChildrenAttribute as String) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let application = applicationElement(pid: pid)
        guard let value = copyAttribute(application, kAXFocusedWindowAttribute as String) else {
            return nil
        }
        let window = value as! AXUIElement
        AXUIElementSetMessagingTimeout(window, messagingTimeout)   // 同样是冗余防守
        return window
    }

    /// 窗口矩形（AX 坐标：原点左上，y 向下，跨屏全局）。
    static func frame(_ element: AXUIElement) -> CGRect? {
        // 同 `AXNodeSource.visibleCharacterRange`：属性值是被采集的应用给的，
        // **先验 CFTypeID 再强转**，不规范的 AX 实现不该让采集进程崩掉。
        guard let positionValue = copyAttribute(element, kAXPositionAttribute as String),
              let sizeValue = copyAttribute(element, kAXSizeAttribute as String),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - 焦点窗口的定位信息

    struct WindowInfo: Sendable {
        var title: String?
        var url: String?
        var document: String?
        var frame: CGRect?
        var timedOut: Bool
    }

    /// 读窗口标题、kAXDocument、kAXURL。任一调用失败都记为超时候选，由调用方决定 source_state。
    /// `bundleID` 只用来查 BFS 限额表（AXWebArea 搜索也吃这份限额）。
    static func windowInfo(pid: pid_t, bundleID: String? = nil) -> WindowInfo {
        focusedWindowInfo(pid: pid, bundleID: bundleID).info
    }

    /// 与 `windowInfo` 同一次读取，**顺便把焦点窗口元素本身带出来**。
    ///
    /// 存在的理由很实在：M1 R2 起适配规则要在同一个窗口上再跑一次子树遍历
    /// （`AdapterEngine`），如果各读各的就会多发一次 `kAXFocusedWindow`——
    /// 而 M0 实测访达 22% 的超时正好发生在这一次调用上（m0_closeout 2.2）。
    static func focusedWindowInfo(pid: pid_t, bundleID: String? = nil)
        -> (element: AXUIElement?, info: WindowInfo) {
        let limits = bfsLimits(bundleID: bundleID)
        guard let window = focusedWindow(pid: pid) else {
            return (nil, WindowInfo(title: nil, url: nil, document: nil, frame: nil, timedOut: true))
        }
        let title = string(window, kAXTitleAttribute as String)
        let document = string(window, kAXDocumentAttribute as String)
        var url = string(window, kAXURLAttribute as String)
        if url == nil {
            // Safari / Chromium 的 URL 挂在 AXWebArea 上，不在窗口上；地址栏那条是它的兜底，
            // 两者同一趟遍历里一起找（见 `urlSources`）。
            let isBrowser = bundleID.map(PrivateBrowsing.browserBundleIDs.contains) ?? false
            let sources = urlSources(in: window, limits: limits, includeAddressBar: isBrowser)
            url = sources.webArea ?? sources.addressBar.flatMap(normalizedAddressBarURL)
        }
        return (window, WindowInfo(title: title, url: url, document: document,
                                   frame: frame(window), timedOut: false))
    }

    /// 地址栏取到的原始值怎么变成一条能入库的 URL。两件事要小心：
    ///  1. **地址栏里未必是 URL**。用户正在输入时它是搜索词；新标签页是空的。所以只接受
    ///     "第一个 `/` 之前带点、且整串没有空白"的值，别的一律当没读到。
    ///  2. **Chrome 把 scheme 省掉了**（显示 `example.com/x` 而不是 `https://example.com/x`），
    ///     而 `EventSkeleton.urlRef` 要有 scheme 才认成 web、才抽得出 host。
    ///     没有 `://` 时补 `https://`：**这是个假设**，站点是 http 的话 scheme 会存错，
    ///     但 host 与 path 是对的，而这个字段的用途正是 `url:` / `host:` / `path:` 检索。
    /// 纯函数，自检逐条覆盖。
    static func normalizedAddressBarURL(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        // 已经带 scheme 的一律原样返回——http/https 不必单列一条，那条与这句结果相同。
        // `about:` 没有 `//`，单独放行。
        guard !value.contains("://"), !value.hasPrefix("about:") else { return value }
        let host = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        // `localhost` / `localhost:3000` 没有点，但它是开发时最常见的一类地址，单独放行。
        let looksLikeHost = (host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix("."))
            || host == "localhost" || host.hasPrefix("localhost:")
        guard looksLikeHost else { return nil }
        return "https://" + value
    }

    /// 地址栏在树里的最大深度。Chrome 实测在 `AXWindow → AXGroup → AXToolbar → AXTextField`
    /// 一带，深度 4 足够；网页正文比这深得多，所以这道界同时起到"别钻进 DOM 里找输入框"的作用
    /// （Safari / Firefox 的 `AXWebArea` 底下有成百上千个节点）。
    static let addressBarMaxDepth = 5

    /// 一次遍历，同时找**网页区的 URL** 与**地址栏的值**。
    ///
    /// 合并的理由是它们本来就走同一棵树：地址栏那条只在网页区那条落空时才用得上，而
    /// "落空"意味着上一趟已经把整棵树按上限走完了。分成两个函数就要走两遍，
    /// 每个节点两次跨进程调用（`role` + `children`），每次都挂着 0.5 s 的超时。
    /// 两条都拿到就提前收工。
    private static func urlSources(in window: AXUIElement, limits: BFSLimits,
                                   includeAddressBar: Bool) -> (webArea: String?, addressBar: String?) {
        let nodeCap = min(webAreaSearchNodes, limits.maxNodes)
        var webArea: String?
        var addressBar: String?
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (element, depth) = queue.first {
            queue.removeFirst()
            visited += 1
            if visited > nodeCap || depth > limits.maxDepth { break }
            switch role(element) {
            case "AXWebArea":
                if webArea == nil { webArea = string(element, kAXURLAttribute as String) }
            case "AXTextField":
                if includeAddressBar, addressBar == nil, depth <= addressBarMaxDepth,
                   let value = string(element, kAXValueAttribute as String), !value.isEmpty {
                    addressBar = value
                }
            default:
                break
            }
            if webArea != nil, !includeAddressBar || addressBar != nil { break }
            for child in children(element) { queue.append((child, depth + 1)) }
        }
        return (webArea, addressBar)
    }

    // MARK: - 正文文本统计

    /// **M1 起正文本身也要入库**（`text_versions` / `occurrences`），不再只留统计。
    /// completeness 仍是占位规则：非空 = partial，空 = unavailable
    /// （评审 F5：AX 非空不等于正文完整，真正的 complete 判定要等 E5 的适配规则与 OCR 对照）。
    /// 算作"带正文"的角色。
    ///
    /// `AXHeading` 是 2026-09-09 加的：Chromium 把网页里的标题层级映射成这个角色，
    /// 而聊天 / 文档界面的分节标题正是判断"这段在讲什么"的关键，漏掉它等于把目录扔了。
    static let textRoles = ["AXTextArea", "AXTextField", "AXStaticText", "AXWebArea", "AXHeading"]

    /// 单个角色一次遍历最多留多少字符。
    ///
    /// 为什么要有这个上限：`AXStaticText` 在长文档 / 长聊天记录里能轻松拼出几百 KB，
    /// 而这些内容**绝大部分不在视口内**（计划 3.3：只入库视口内实际显示的内容）。
    /// 视口裁剪要等 E5 的适配规则，本轮先用一个粗上限兜住内存与库体积，
    /// 命中上限时 `charLimitHit = true`，写进运行期事件，不静默截断。
    static let maxCharsPerRole = 20_000

    /// 一次正文遍历的结果：按角色的统计 + 这次遍历有没有被限额截断。
    ///
    /// 截断信息**不写进 `ax_texts.completeness`**，由调用方写 `runtime_events`，理由见
    /// `EventSkeleton.noteBFSLimitHit`。
    struct TextScan: Sendable {
        var summaries: [AXTextSummary]
        var limits: BFSLimits
        var visitedNodes: Int
        /// 节点数吃满上限，队列里还有没走的元素。
        var hitNodeLimit: Bool
        /// **确实有子树因为深度上限没被展开**：至少一个 `depth == maxDepth` 的元素还有子节点。
        /// 只落在最后一层的叶子不算（R2 修正；判定见 `AX.depthLimitHit`）。
        var reachedDepthLimit: Bool
        /// 至少一个角色的正文吃满了 `maxCharsPerRole`。
        var charLimitHit: Bool = false

        var truncated: Bool { hitNodeLimit || reachedDepthLimit || charLimitHit }

        /// 本次遍历读到的总字符数（脱敏前）。
        var totalChars: Int { summaries.reduce(0) { $0 + $1.charCount } }

        /// 写进 `runtime_events.detail`。
        var detail: String {
            var hits: [String] = []
            if hitNodeLimit { hits.append("node") }
            if reachedDepthLimit { hits.append("depth") }
            if charLimitHit { hits.append("chars") }
            return "limits=\(limits.label) visited=\(visitedNodes) chars=\(totalChars) "
                 + "hit=\(hits.isEmpty ? "none" : hits.joined(separator: "+"))"
        }
    }

    static func textScan(pid: pid_t, bundleID: String? = nil) -> TextScan {
        let limits = bfsLimits(bundleID: bundleID)
        guard let window = focusedWindow(pid: pid) else {
            return TextScan(summaries: [], limits: limits, visitedNodes: 0,
                            hitNodeLimit: false, reachedDepthLimit: false)
        }
        var nodeCounts: [String: Int] = [:]
        var charCounts: [String: Int] = [:]
        var pieces: [String: [String]] = [:]
        for role in textRoles {
            nodeCounts[role] = 0
            charCounts[role] = 0
            pieces[role] = []
        }

        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        var reachedDepthLimit = false
        var charLimitHit = false
        while !queue.isEmpty && visited < limits.maxNodes {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let elementRole = role(element)
            if textRoles.contains(elementRole) {
                nodeCounts[elementRole, default: 0] += 1
                let value = string(element, kAXValueAttribute as String)
                    ?? string(element, kAXDescriptionAttribute as String)
                if let value, !value.isEmpty {
                    charCounts[elementRole, default: 0] += value.count
                    if (charCounts[elementRole] ?? 0) <= maxCharsPerRole {
                        pieces[elementRole, default: []].append(value)
                    } else {
                        charLimitHit = true
                    }
                }
            }
            // AXSecureTextField 永不暴露值，直接跳过，不往下走。
            if elementRole == "AXSecureTextField" { continue }
            if depth < limits.maxDepth {
                for child in children(element) { queue.append((child, depth + 1)) }
            } else {
                // 只有当被深度上限截断的元素**确实还有子节点**时才算命中（见 depthLimitHit）。
                reachedDepthLimit = Self.depthLimitHit(alreadyHit: reachedDepthLimit,
                                                       depth: depth,
                                                       limits: limits,
                                                       hasChildren: !children(element).isEmpty)
            }
        }

        let summaries = textRoles.map { role -> AXTextSummary in
            let chars = charCounts[role] ?? 0
            // 同一角色的多个节点按遍历顺序用换行拼起来：AX 树里一段正文常被拆成几十个
            // AXStaticText 节点，逐节点入库会把 text_versions 打成碎片、也让 bigram 检索失去上下文。
            let text = (pieces[role] ?? []).joined(separator: "\n")
            return AXTextSummary(role: role,
                                 nodeCount: nodeCounts[role] ?? 0,
                                 charCount: chars,
                                 completeness: chars > 0 ? .partial : .unavailable,
                                 text: text)
        }
        return TextScan(summaries: summaries,
                        limits: limits,
                        visitedNodes: visited,
                        hitNodeLimit: visited >= limits.maxNodes && !queue.isEmpty,
                        reachedDepthLimit: reachedDepthLimit,
                        charLimitHit: charLimitHit)
    }
}
