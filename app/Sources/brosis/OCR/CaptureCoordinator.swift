import BrosisCore
import CoreGraphics
import Foundation

/// 把三条线接起来：**适配规则**（在主线程读 AX）→ **按需截图**（在 utility 队列拿 CGImage）
/// → **视口 OCR / 采样审计**（在同一个 utility 队列上跑 Vision，写回 core）。
///
/// 为什么需要一个协调者：两边的时机对不上。AX 在 `EventSkeleton` 里读，
/// 图像在 `CaptureController.analyze` 里才有，而 OCR 需要**同时**知道
/// "哪块区域要认"（规则给的）和"这块屏长什么样"（截图给的）。
/// 这个类只保存一份很小的上下文（当前前台应用 + 待办 OCR 请求 + 审计状态），
/// 用一把 `NSLock` 串行，两边都不用知道对方存在——所以接线不需要动 `AppDelegate`。
///
/// **它不持有 `Recorder`**：写库时由调用方把自己的 recorder 传进来。
/// 这样锁定状态机关库时两边各自的 recorder 一起变成空操作，协调者不需要跟着开合。
final class CaptureCoordinator: @unchecked Sendable {

    static let shared = CaptureCoordinator()

    // MARK: - 可调参数

    /// 采样审计的间隔：AX 非空的观察每 N 次取一次全窗口 OCR 对照（计划 3.3，M1 只做低频版）。
    /// `defaults write com.brosis.app capture.auditEvery -int 20`；0 = 关掉审计。
    static let auditEveryKey = "capture.auditEvery"
    static let auditEveryDefault = 50

    /// 覆盖率低于这个值就把该应用标成"覆盖检查失败"，下一轮触发第三类 OCR。
    static let coverageThresholdKey = "capture.coverageThreshold"
    static let coverageThresholdDefault = 0.6

    static func resolveAuditEvery(_ defaults: UserDefaults = .standard) -> (value: Int, source: String) {
        guard defaults.object(forKey: auditEveryKey) != nil else { return (auditEveryDefault, "default") }
        let raw = defaults.integer(forKey: auditEveryKey)
        guard raw >= 0 else { return (auditEveryDefault, "defaults_invalid") }
        return (raw, "defaults")
    }

    static func resolveCoverageThreshold(_ defaults: UserDefaults = .standard)
        -> (value: Double, source: String) {
        guard defaults.object(forKey: coverageThresholdKey) != nil else {
            return (coverageThresholdDefault, "default")
        }
        let raw = defaults.double(forKey: coverageThresholdKey)
        guard raw.isFinite, raw > 0, raw <= 1 else { return (coverageThresholdDefault, "defaults_invalid") }
        return (raw, "defaults")
    }

    // MARK: - 状态

    /// 一次 AX 扫描留下的上下文，供下一帧的 OCR 使用。
    struct Context: Sendable {
        var bundleID: String
        var appName: String
        var ruleID: String
        var displayID: UInt32?
        var windowFrame: CGRect?
        var windowTitle: String?
        /// 这条观察在库里的 id（写不进去时为 nil）。
        var observationID: Int64?
        /// AX / 适配器读到的正文（已脱敏），采样审计拿它跟 OCR 对照。
        var axText: String
        var regionTexts: [String: String]
        var ocrRequests: [OCRRequest]
        var chatLayout: ChatLayout?
        var completeness: Completeness
        /// 这条观察是用什么方法采的（`capture_audit.method` 照抄它，不再靠 completeness 猜）。
        var captureMethod: CaptureMethod = .ax
        var at: TimeInterval
    }

    private let lock = NSLock()
    private var context: Context?
    /// 上一次 AX 扫描各区域读到的文本，按 bundle id 存，用于"AX 值有没有变"。
    private var lastRegionTexts: [String: [String: String]] = [:]
    /// 帧门控判定为"有变化"的帧到了但还没被 AX 扫描消费。
    private var frameChangedPending: Set<String> = []
    /// 覆盖检查失败的应用（下一轮触发第三类 OCR），命中一次消费一次。
    private var coverageFailedApps: Set<String> = []
    /// AX 非空观察计数，用来定采样审计的节奏。
    private var axObservationCount = 0
    /// 这条观察轮到做审计。
    private var auditDue = false
    /// 上一次这个窗口区域 OCR 出来的正文（脱敏后）。**OCR 侧的新鲜度判定**：
    /// 文本一个字都没变就不再写第二条观察（计划 3.3「新鲜度判定」此前只在 AX 侧实现，
    /// 于是微信静止在前台时每 12 s 一条内容完全相同的 ocr 观察，约 300 条/小时）。
    private var lastOCRTexts: [String: String] = [:]
    /// 上一次从标题条认出来的会话身份，按 bundle id 存。
    /// 标题区域被限流挡掉的那些帧要靠它保住群聊判定与 `window_title`（M2）。
    private var lastConversationTitles: [String: ChatTitle.Resolved] = [:]

    let trigger: OCRTriggerGate
    let auditEvery: Int
    let auditEverySource: String
    let coverageThreshold: Double
    let coverageThresholdSource: String

    struct Stats: Sendable {
        var ocrRuns = 0
        var ocrRateLimited = 0
        var ocrEmpty = 0
        var ocrFailures = 0
        var ocrChars = 0
        var ocrTotalMS: Double = 0
        /// 前台已经换了应用，上一个应用留下的上下文被丢弃的次数。
        var ocrStaleContext = 0
        /// 区域认出来了但正文与上一次逐字节相同，没有写第二条观察的次数。
        var ocrUnchanged = 0
        /// 画面没变、该区域已 OCR 过，因此**没跑** Vision 的次数。
        /// 它和 `ocrUnchanged` 的区别就是省没省下算力：后者是跑完才发现文本没变。
        var ocrGatedUnchanged = 0
        var audits = 0
        var auditCoverageSum: Double = 0
        var observationsWritten = 0

        var summary: String {
            let averageMS = ocrRuns > 0 ? ocrTotalMS / Double(ocrRuns) : 0
            let averageCoverage = audits > 0 ? auditCoverageSum / Double(audits) : 0
            return "OCR \(ocrRuns) 次（限流 \(ocrRateLimited)，空 \(ocrEmpty)，失败 \(ocrFailures)，"
                 + "上下文过期 \(ocrStaleContext)，未变化 \(ocrUnchanged)，"
                 + "画面没变已跳过 \(ocrGatedUnchanged)）"
                 + "，平均 \(Int(averageMS)) ms，共 \(ocrChars) 字符；"
                 + "观察 \(observationsWritten) 条；采样审计 \(audits) 次"
                 + "，平均覆盖率 \(String(format: "%.3f", averageCoverage))"
        }
    }
    private var stats = Stats()
    var currentStats: Stats { lock.withLock { stats } }

    init(defaults: UserDefaults = .standard) {
        // 限流器跟协调者用同一份 defaults：不传的话独立 suite 里配不了 capture.ocrMinInterval，
        // 自检就只能被产品默认的 5 s 挡住（产品路径两边都是 .standard，行为不变）。
        trigger = OCRTriggerGate(defaults: defaults)
        let audit = Self.resolveAuditEvery(defaults)
        auditEvery = audit.value
        auditEverySource = audit.source
        let coverage = Self.resolveCoverageThreshold(defaults)
        coverageThreshold = coverage.value
        coverageThresholdSource = coverage.source
    }

    // MARK: - 事件骨架侧（主线程）

    /// 上一次这个应用各区域读到的文本（新鲜度判定）。
    func previousRegionTexts(bundleID: String?) -> [String: String] {
        lock.withLock { lastRegionTexts[bundleID ?? "(unknown)"] ?? [:] }
    }

    /// 有没有"帧变化超阈值但还没被 AX 消费"的帧。**读一次消费一次**：
    /// 同一次帧变化只能触发一轮判定，否则每条观察都会以为刚变过。
    func consumeFrameChanged(bundleID: String?) -> Bool {
        lock.withLock { frameChangedPending.remove(bundleID ?? "(unknown)") != nil }
    }

    /// 上一次采样审计判定这个应用覆盖不足。同样读一次消费一次。
    func consumeCoverageFailed(bundleID: String?) -> Bool {
        lock.withLock { coverageFailedApps.remove(bundleID ?? "(unknown)") != nil }
    }

    /// 一次 AX 扫描做完了。存上下文，并决定这条观察要不要做采样审计。
    func noteScan(_ newContext: Context) {
        lock.withLock {
            context = newContext
            lastRegionTexts[newContext.bundleID] = newContext.regionTexts
            guard !newContext.axText.isEmpty else { return }
            axObservationCount += 1
            if auditEvery > 0 && axObservationCount % auditEvery == 0 { auditDue = true }
        }
    }

    /// **这一轮没有扫描**（私密浏览 / AX 超时或读不到焦点窗口 / 「只记事件」档）。
    ///
    /// 必须把上下文清掉：这三支都不写正文，可截图那条通路并不知道，照样会调 `handleFrame`。
    /// 上下文留着的话，上一个应用（微信 / 飞书 / AX 为空的 Claude）排的 OCR 请求
    /// 就会在**新画面**上执行——把私密浏览窗口里的正文按旧应用的身份、
    /// 以 `capture_method = ocr` 入库，既违反「私密浏览正文一个都不存」也归错了应用。
    /// `handleFrame` 里还有一道 bundle id 校验兜底（两道是互补的：这里是"事前不留"，
    /// 那里是"事到临头再核一次身份"）。
    ///
    /// `auditDue` **不清**：轮到的那次采样审计只是被推迟到下一次真正扫描之后，不作废
    /// （没有上下文时 `handleFrame` 本来就直接返回）。
    ///
    /// **只清属于 `bundleID` 的那一份**（2026-09-09 修）。以前不带参数、见谁清谁，
    /// 而应用切换时系统事件的到达顺序是「新应用 activated」**先**、
    /// 「旧应用 deactivated」**后**（实测相差 6 ms）：
    ///
    ///     18:24:04.115 扫描：飞书会议 OCR请求=1  触发=app_activated
    ///     18:24:04.121 扫描：Claude   OCR请求=-1 触发=app_deactivated  ← 把上一行的上下文清了
    ///
    /// 失活那一支 `collectText=false` ⇒ 不扫描 ⇒ 走这里，于是**新应用刚排好的 OCR 请求
    /// 被上一个应用的谢幕事件顺手抹掉**。AX 树活的应用（Claude、飞书主窗口）看不出问题：
    /// 它们随后每秒都有 title_changed / value_changed 再扫一次，上下文立刻重建。
    /// AX 树是死的那些（飞书会议、微信）**只有激活那一次扫描**，抹掉就再也没有了——
    /// 这就是「规则命中了、OCR 请求也排了，却一个字都记不到」的真正原因。
    func clearContext(bundleID: String?) {
        lock.withLock {
            guard context?.bundleID == bundleID else { return }
            context = nil
        }
    }

    // MARK: - 截图侧（utility 队列）

    /// 帧门控的结果送进来：`gated == false` 就是"这一帧变化超阈值"。
    func noteFrameGate(bundleID: String?, gated: Bool) {
        guard !gated else { return }
        lock.withLock { _ = frameChangedPending.insert(bundleID ?? "(unknown)") }
    }

    /// **OCR 的挂点**：`CaptureController.analyze` 拿到 CGImage 的那一刻调这里。
    ///
    /// 做两件事，都可能一件都不做（绝大多数帧就是什么都不做）：
    /// 1. 把规则判定出来的待办 OCR 请求跑掉，结果写成一条 `capture_method = ocr / mixed` 的观察；
    /// 2. 轮到采样审计时，对整个窗口做一次 OCR 与 AX 文本对照，写 `capture_audit`。
    ///
    /// 返回这一帧实际跑了几个 OCR 区域（写进 `capture_stats.ocr_regions`）。
    /// - Parameter bundleID: **这一帧的前台应用**（`CaptureController` 自己记的
    ///   `frontmostBundleID`）。与上下文里的应用不一致就整帧不处理——上下文是上一次 AX 扫描
    ///   留下的，而私密浏览 / AX 超时 / 读不到焦点窗口这三支**不扫描**，截图这条通路却照常出图；
    ///   不核身份的话，上一个应用排的 OCR 请求会落到新应用的画面上（详见 `clearContext`）。
    /// - Parameter displayBoundsOverride: **这张图覆盖的 AX 矩形**，不传就是整块显示器
    ///   （`CGDisplayBounds(displayID)`，不需要任何权限）。两种情况会传：
    ///   窗口定向截图时传窗口矩形（M2，图就是那个窗口）；自检要在自绘位图上跑完整条通路时
    ///   传那张图的尺寸。裁剪那套换算对两者是同一套——只差原点与缩放。
    @discardableResult
    func handleFrame(_ image: CGImage, displayID: UInt32, recorder: Recorder,
                     gated: Bool, trigger reason: String,
                     bundleID: String?,
                     displayBoundsOverride: CGRect? = nil) -> Int {
        let frontmost = bundleID ?? "(unknown)"
        let pending: Context? = lock.withLock {
            guard let context else { return nil }
            // 前台已经换人：这份上下文对当前这张图没有任何意义，丢掉（不是留到下一帧）。
            guard context.bundleID == frontmost else {
                self.context = nil
                stats.ocrStaleContext += 1
                if !context.ocrRequests.isEmpty {
                    BrosisLog.capture.notice(
                        """
                        丢帧：上下文是 \(context.bundleID, privacy: .public)，                        这一帧的前台是 \(frontmost, privacy: .public)，                        \(context.ocrRequests.count, privacy: .public) 个 OCR 请求作废
                        """)
                }
                return nil
            }
            guard !context.ocrRequests.isEmpty || auditDue else { return nil }
            return context
        }
        guard let pending else { return 0 }
        let displayBounds = displayBoundsOverride ?? CGDisplayBounds(displayID)
        var regionsRun = 0

        // —— 1. 待办 OCR ——
        //
        // **分两趟**（M2 修正）：先把所有区域认完，再成文。
        // 原因是气泡归属需要先知道「这是不是群聊」，而这个信号只能从**另一个区域**
        // （标题条的人数后缀）拿到——微信的 AX 正文是空的、窗口标题恒为「微信」。
        // 一趟循环时区域按规则顺序处理，聊天面板排在会话名前面，拿不到这个信号，
        // 于是 `group` 只能写死成 false，群聊昵称永远认不出来。
        var fragments: [TextFragment] = []
        var lowConfidence = false
        var missingRegions = 0
        let now = Date().timeIntervalSince1970

        /// 认完但还没成文的一块区域。
        struct Recognized {
            var request: OCRRequest
            /// 实际送去识别的矩形（可能是量出来的，不一定等于 `request.rect`）。
            var rect: CGRect
            var result: ViewportOCR.Result
        }
        var recognized: [Recognized] = []

        // —— 0. 分栏边界：从这一帧的**窗口图像**现场量（M2）——
        //
        // 只能在这里做，不能在 AX 扫描那一步做：扫描跑在主线程，那一刻还没有图像。
        // 量出来的边界覆盖掉规则给的粗矩形；量不到就退回规则的兜底那一组（行为与之前一致）。
        var paneRects: [PaneRole: CGRect] = [:]
        var paneLayout: PaneLayout?
        let rule = AdapterRegistry.rule(for: pending.bundleID)
        if let windowFrame = pending.windowFrame,
           let paneFallback = rule.paneFallback,
           pending.ocrRequests.contains(where: { $0.pane != nil }),
           let windowImage = ViewportOCR.crop(image, axRect: windowFrame,
                                              displayBounds: displayBounds)?.image {
            let layout = PaneDetector.detect(
                window: windowImage, windowSize: windowFrame.size,
                fallback: paneFallback.layout(windowHeight: Double(windowFrame.height)))
            paneLayout = layout
            paneRects[.chatPanel] = layout.rect(for: .chatPanel, in: windowFrame)
            paneRects[.conversationTitle] = layout.rect(for: .conversationTitle, in: windowFrame)
        }

        /// 这块区域最终用哪个矩形：量出来的优先，其次规则给的。
        func resolvedRect(_ request: OCRRequest) -> CGRect {
            request.pane.flatMap { paneRects[$0] } ?? request.rect
        }

        for request in pending.ocrRequests {
            // 第二类触发条件（帧变化 + AX 未变）只在这一帧真的有变化时才算数。
            //
            // **已知局限**（M1 记录在案，要真机数据才能定怎么改，见结果文件第 10 节第 5 条）：请求是在
            // "变化帧之后"的那次 AX 扫描里排出来的，所以它只有在**再下一帧也未被门控**时才跑。
            // 「屏幕变了一次然后静止」（新消息到达）这种最典型的场景里，静止帧显示的恰恰就是
            // 变化后的内容，却会被这一行跳过，而上下文被下一次 `noteScan` 替换后请求就没了。
            if request.reason == .frameChangedAXStable && gated { continue }
            let key = "\(pending.bundleID)|\(request.regionName)"
            // 画面没变、而且这个区域**之前已经 OCR 过**：这一帧不可能产出新文本。
            //
            // 为什么要专门加这一条（2026-09-09）：`.ruleDeclared`（规则声明了 OCR 回退 + AX 读空）
            // 此前完全不吃帧门控，所以一个**静止不动**的窗口仍然每 5 秒烧一次整窗
            // `.accurate` OCR ≈ 720 次/小时。而"文本没变就不入库"那道检查在 Vision **跑完之后**
            // （见下面的 `lastOCRTexts` 比较），省下的只是一次写库，不是算力。
            // 首次必须放行——没有 `lastOCRTexts` 就说明这个区域还一个字都没读到过。
            if gated, lastOCRTexts[key] != nil {
                lock.withLock { stats.ocrGatedUnchanged += 1 }
                continue
            }
            switch trigger.allow(key: key, reason: request.reason, now: now) {
            case .rateLimited:
                lock.withLock { stats.ocrRateLimited += 1 }
                continue
            case .allow:
                break
            }
            let rect = resolvedRect(request)
            do {
                guard let result = try ViewportOCR.recognize(fullFrame: image,
                                                             axRect: rect,
                                                             displayBounds: displayBounds,
                                                             kind: request.kind) else {
                    missingRegions += 1
                    continue
                }
                regionsRun += 1
                lock.withLock {
                    stats.ocrRuns += 1
                    stats.ocrTotalMS += result.elapsedMS
                    stats.ocrChars += result.text.count
                }
                guard !result.isEmpty else {
                    lock.withLock { stats.ocrEmpty += 1 }
                    missingRegions += 1
                    continue
                }
                if result.meanConfidence < ViewportOCR.lowConfidenceThreshold { lowConfidence = true }
                recognized.append(Recognized(request: request, rect: rect, result: result))
            } catch {
                lock.withLock { stats.ocrFailures += 1 }
                recorder.logEvent(kind: "ocr_failed",
                                  detail: "bundle=\(pending.bundleID) region=\(request.regionName) "
                                        + "reason=\(request.reason.rawValue) error=\(error)")
                missingRegions += 1
            }
        }

        // —— 第二趟：先定会话身份，再成文 ——
        //
        // 会话名这一轮可能没认（限流、或者规则里压根没有标题区域），所以认到了就记住，
        // 没认到就用上一次记住的：否则每隔几帧就丢一次群聊身份，同一段对话里
        // 发送者一会儿是昵称一会儿是「对方」。
        var resolvedTitle: ChatTitle.Resolved?
        for item in recognized where item.request.kind == .title {
            if let candidate = ChatTitle.resolve(item.result.text) {
                resolvedTitle = candidate
                break
            }
        }
        lock.withLock {
            if let resolvedTitle {
                lastConversationTitles[pending.bundleID] = resolvedTitle
            } else {
                resolvedTitle = lastConversationTitles[pending.bundleID]
            }
        }

        // 会话名排到正文最前（`occurrences.ord = 0`）：它是这段对话的身份，而摘要是从头
        // 截断的——拼在尾巴上就永远进不了摘要。同一类区域之间保持规则里的原顺序。
        let ordered = recognized.enumerated().sorted { lhs, rhs in
            let lhsTitle = lhs.element.request.kind == .title
            let rhsTitle = rhs.element.request.kind == .title
            if lhsTitle != rhsTitle { return lhsTitle }
            return lhs.offset < rhs.offset
        }.map(\.element)

        for item in ordered {
            let request = item.request
            let result = item.result
            let rect = item.rect
            let key = "\(pending.bundleID)|\(request.regionName)"

            // 聊天类区域先做气泡归属，再入库（计划 3.3 微信 / 飞书）。
            var text = result.text
            if request.kind == .messageList, let layout = pending.chatLayout {
                let bubbles = BubbleAttribution.attribute(
                    items: result.lines, layout: layout,
                    group: resolvedTitle?.isGroup ?? false,
                    regionHeightPoints: Double(rect.height))
                if !bubbles.isEmpty { text = BubbleAttribution.text(bubbles) }
            }
            // —— 入库前脱敏（2.2 硬约束 2）：OCR 出来的文本走的是同一条脱敏管线 ——
            let redacted = Redactor.redact(text)
            // —— OCR 侧的新鲜度判定（3.3）：这块区域的正文与上一次逐字节相同就不再写 ——
            // 微信这类全 OCR 的规则每 12 s 一帧、过了 5 s 限流就会再认一次，
            // 屏幕静止时那都是同一段字；不判新鲜度的话一小时能写出约 300 条一模一样的观察。
            // AX 侧的观察照写（时间线不缺段），这里省掉的只是重复的 ocr 正文。
            let isFresh: Bool = lock.withLock {
                guard lastOCRTexts[key] != redacted.text else { return false }
                lastOCRTexts[key] = redacted.text
                return true
            }
            guard isFresh else {
                lock.withLock { stats.ocrUnchanged += 1 }
                continue
            }
            fragments.append(TextFragment(
                text: redacted.text,
                region: "ocr:\(pending.ruleID).\(request.regionName)",
                confidence: result.meanConfidence,
                note: result.note(rect: rect)))
        }

        if fragments.isEmpty, !pending.ocrRequests.isEmpty {
            // 本来该出字却一个字都没出：把每一种放弃的**当前累计值**打出来。
            // 只有这一行能区分「没跑」和「跑了但是空的」——两者在库里长得一模一样。
            let snapshot = lock.withLock { stats }
            BrosisLog.capture.notice(
                """
                没出字：\(pending.bundleID, privacy: .public) 规则 \(pending.ruleID, privacy: .public)，                请求 \(pending.ocrRequests.count, privacy: .public) 个、实跑 \(regionsRun, privacy: .public) 个、                裁剪或识别落空 \(missingRegions, privacy: .public) 个，gated=\(gated, privacy: .public)；                累计 限流 \(snapshot.ocrRateLimited, privacy: .public)、                画面没变跳过 \(snapshot.ocrGatedUnchanged, privacy: .public)、                认出来是空 \(snapshot.ocrEmpty, privacy: .public)、                文本没变 \(snapshot.ocrUnchanged, privacy: .public)、                失败 \(snapshot.ocrFailures, privacy: .public)、                上下文过期 \(snapshot.ocrStaleContext, privacy: .public)
                """)
        }

        if !fragments.isEmpty {
            // AX 也读到东西 = mixed；只有 OCR = ocr（计划 3.2 的 capture_method 枚举）。
            let method: CaptureMethod = pending.axText.isEmpty ? .ocr : .mixed
            let completeness: Completeness =
                (missingRegions == 0 && !lowConfidence) ? .complete : .partial
            let observationID = recorder.record(ObservationInput(
                ts: Recorder.milliseconds(),
                displayID: Int64(displayID),
                app: AppRef(bundleID: pending.bundleID, name: pending.appName),
                // 会话名优先于窗口标题（M2）：微信的窗口标题恒为「微信」，会话身份只在
                // 标题条的 OCR 里。写进 `windows.title` 之后，`title:` 前缀能搜到群名，
                // 摘要第二段也从「微信」变成实际会话名。认不出来时才退回窗口标题。
                windowTitle: resolvedTitle?.display ?? pending.windowTitle,
                trigger: .frameDirty,
                captureMethod: method,
                completeness: completeness,
                visibleRange: pending.ocrRequests.isEmpty ? nil
                    : ocrVisibleRangeJSON(pending: pending, ranRegions: regionsRun,
                                          paneRects: paneRects, layout: paneLayout),
                sourceState: .ok,
                texts: fragments))
            if observationID != nil { lock.withLock { stats.observationsWritten += 1 } }
            recorder.logEvent(kind: "ocr_regions_captured",
                              detail: "bundle=\(pending.bundleID) rule=\(pending.ruleID) "
                                    + "regions=\(fragments.count) method=\(method.rawValue) "
                                    + "completeness=\(completeness.rawValue) trigger=\(reason) "
                                    // 会话身份进事件（**只记形状不记会话名**）：真机校准侧栏宽度时
                                    // 要能看出"标题条到底认出会话了没有、判成群聊了没有"。
                                    + "title=\(resolvedTitle == nil ? "none" : "ok") "
                                    + "group=\(resolvedTitle?.isGroup == true ? "yes" : "no") "
                                    // 分栏边界同样只记形状：三个数字加一个来源，不含任何正文。
                                    + "pane=\(paneLayout?.label ?? "n/a")")
        }

        // —— 2. 采样审计 ——
        let shouldAudit: Bool = lock.withLock {
            guard auditDue else { return false }
            auditDue = false
            return true
        }
        if shouldAudit, !pending.axText.isEmpty {
            runAudit(image: image, displayID: displayID, displayBounds: displayBounds,
                     context: pending, recorder: recorder)
            regionsRun += 1
        }
        return regionsRun
    }

    /// 全窗口 OCR 与 AX 文本对照，写 `capture_audit`（3.3 的采样审计，M1 低频版）。
    private func runAudit(image: CGImage, displayID: UInt32, displayBounds: CGRect,
                          context: Context, recorder: Recorder) {
        let rect = context.windowFrame ?? displayBounds
        do {
            guard let result = try ViewportOCR.recognize(fullFrame: image, axRect: rect,
                                                         displayBounds: displayBounds,
                                                         kind: .body) else { return }
            let coverage = CaptureCoverage.coverage(axText: context.axText, ocrText: result.text)
            let row = CaptureAuditRow(ts: Recorder.milliseconds(),
                                      observationID: context.observationID,
                                      app: context.bundleID,
                                      coverage: coverage,
                                      method: context.captureMethod,
                                      region: "window",
                                      elapsedMS: result.elapsedMS)
            recorder.recordCaptureAudit(row)
            lock.withLock {
                stats.audits += 1
                stats.auditCoverageSum += coverage.coverage
                if coverage.coverage < coverageThreshold {
                    _ = coverageFailedApps.insert(context.bundleID)
                }
            }
            recorder.logEvent(kind: "capture_audit",
                              detail: "bundle=\(context.bundleID) ax_chars=\(coverage.axChars) "
                                    + "ocr_chars=\(coverage.ocrChars) "
                                    + "tokens=\(coverage.hitTokens)/\(coverage.axTokens) "
                                    + "coverage=\(String(format: "%.3f", coverage.coverage)) "
                                    + "threshold=\(coverageThreshold) "
                                    + "elapsed_ms=\(Int(result.elapsedMS))")
        } catch {
            recorder.logEvent(kind: "capture_audit_failed",
                              detail: "bundle=\(context.bundleID) error=\(error)")
        }
    }

    private func ocrVisibleRangeJSON(pending: Context, ranRegions: Int,
                                     paneRects: [PaneRole: CGRect],
                                     layout: PaneLayout?) -> String? {
        var payload: [String: Any] = ["rule": pending.ruleID, "source": "ocr",
                                      "regions_run": ranRegions]
        if let layout {
            // 边界怎么来的要能追溯：同一条观察日后被质疑"这块是不是切歪了"，
            // 光有矩形不够，还得知道它是量出来的还是兜底的。
            payload["pane"] = ["sidebar_right": Int(layout.sidebarRight.rounded()),
                               "title_bottom": Int(layout.titleBottom.rounded()),
                               "composer_top": Int(layout.composerTop.rounded()),
                               "source": layout.source.rawValue]
        }
        payload["regions"] = pending.ocrRequests.map { request -> [String: Any] in
            let rect = request.pane.flatMap { paneRects[$0] } ?? request.rect
            return ["name": request.regionName,
                    "reason": request.reason.rawValue,
                    "rect": [Int(rect.origin.x.rounded()), Int(rect.origin.y.rounded()),
                             Int(rect.width.rounded()), Int(rect.height.rounded())]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 只给自检用：清空状态。
    func reset() {
        lock.withLock {
            context = nil
            lastOCRTexts.removeAll()
            lastConversationTitles.removeAll()
            lastRegionTexts.removeAll()
            frameChangedPending.removeAll()
            coverageFailedApps.removeAll()
            axObservationCount = 0
            auditDue = false
            stats = Stats()
        }
        trigger.reset()
    }

    /// 只给自检用：强制下一帧做一次采样审计。
    func forceAuditDue() { lock.withLock { auditDue = true } }
}
