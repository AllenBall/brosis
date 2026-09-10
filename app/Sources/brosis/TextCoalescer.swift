import BrosisCore
import Foundation

/// 正文写入合并（2026-09-10 用户要求）。
///
/// 病灶：流式界面（Claude、ZCode、飞书）每秒扫描一次，每次读回**整窗**正文。
/// 一次回答生成过程中会留下几十份只差几个字的 4 KB 全文，而只有最后那个稳定态有价值。
/// 库里实测：11340 条观察 → 5297 条文本版本（sha256 挡掉 53%），平均 5.3 KB/条；
/// 一条 5.3 KB 的正文连同它的全文索引与向量，实际占库约 15 KB。
///
/// **为什么不是"算相似度、太像就不写"**：流式文本是**追加增长**的（`abc`→`abcd`→`abcde`），
/// 按相似度跳过会保留第一份、丢掉最完整的那份；反过来"变长就写"则一份都省不下。
/// 而"就地改写旧记录"这条路也堵死了——`text_versions.vrow` 是单调计数器，
/// 分块水位判据是 `vrow > watermark`，改写过的行永远不会被重新分块，向量就成了旧的。
///
/// **所以是等它停下来再写**：一次突发只落一条，且必然是最后那条。
/// 这不是启发式——不需要相似度阈值，不会误删，也没有参数要调准。
///
/// 代价（用户已确认）：突发**中间**那些观察没有正文。时间线仍然完整（应用、窗口、时刻
/// 照记），正文挂在这一串的最后一条上——而且挂的是**那条观察自己的时刻**，不是补写时的时刻。
@MainActor
final class TextCoalescer {

    /// 安静多久算"停下来了"。Claude 流式约 1 次/秒，3 秒没动静基本就是停了。
    ///
    /// **设成 0 就是关掉合并**：每次扫描的正文立刻落盘，回到 0.6.0 的行为
    /// （`decide` 里 `now - lastOfferedAt >= 0` 恒真，下一次 offer 会把上一份直接落掉）。
    /// 发布说明里承诺了这个开关，所以它必须真的能关——第一版的守卫写成 `raw > 0`，
    /// 0 会被当成非法值悄悄退回默认 3 秒，等于给了一个看起来能用、实际无效的开关。
    nonisolated static let quietKey = "capture.textCoalesceQuiet"
    nonisolated static let quietDefault: TimeInterval = 3
    /// 最长暂存。兜住"一直在变"的窗口（视频、滚动的日志），否则它永远不落盘。
    ///
    /// 60 s 是用户 2026-09-10 定的（方案里我提的是 30）。这个数只影响**一直在变**的窗口：
    /// 会停下来的内容由安静期收口，根本走不到这里。放大它 = 这类窗口的快照更稀疏、
    /// 省得更多，代价是崩溃时可能丢掉最多这么长时间的一份正文。
    nonisolated static let maxHoldKey = "capture.textCoalesceMaxHold"
    nonisolated static let maxHoldDefault: TimeInterval = 60

    /// 归一 key：换应用或换窗口就是换内容，不能合并。
    struct Key: Hashable, Sendable {
        var bundleID: String
        var windowTitle: String
    }

    /// 攒着的一份。
    struct Pending: Sendable {
        var key: Key
        /// 产生这份正文的那条观察。落盘时挂到它身上——时刻因此是准的。
        var observationID: Int64
        var fragments: [TextFragment]
        var firstOfferedAt: TimeInterval
        var lastOfferedAt: TimeInterval
    }

    struct Flush {
        var observationID: Int64
        var fragments: [TextFragment]
        var reason: String
    }

    /// 落盘的理由。**纯函数**：手上这份该不该落盘了，nil = 继续攒。
    ///
    /// `incoming` 是这一刻新来的 key（定时器来问时传 nil）。顺序有意义：
    /// 换 key 优先于安静期——换了应用就该立刻落盘，不必再等三秒。
    enum Reason: String, Sendable {
        case keyChanged = "key_changed"
        case maxHold = "max_hold"
        case quiet
        case stopping
    }

    /// `nonisolated`：这是纯函数，自检在非主线程上下文里也要能直接调。
    nonisolated static func decide(pending: Pending?, incoming: Key?, now: TimeInterval,
                                   quiet: TimeInterval, maxHold: TimeInterval) -> Reason? {
        guard let pending else { return nil }
        if let incoming, incoming != pending.key { return .keyChanged }
        if now - pending.firstOfferedAt >= maxHold { return .maxHold }
        if now - pending.lastOfferedAt >= quiet { return .quiet }
        return nil
    }

    private var pending: Pending?
    /// 排着的那次落盘。**只在手上有东西时才排**，每次 offer 取消重排——
    /// 与 `CaptureController.schedulePending()` 同一个形状。
    /// 上一版是每秒一跳的常驻 `Timer`（还没设 tolerance），空闲时也照跳：
    /// 一天 8.6 万次主线程唤醒，而 `pending` 绝大多数时间是 nil。
    private var scheduled: DispatchWorkItem?
    private let quiet: TimeInterval
    private let maxHold: TimeInterval
    /// 落盘动作。由 `EventSkeleton` 接到 `Recorder.attachTexts`。
    private var onFlush: ((Int64, [TextFragment]) -> Void)?

    /// 从 defaults 解出两个参数。**`nonisolated static`**：这是纯函数，
    /// 自检要能直接调它验"承诺的开关真的能关"，而 `TextCoalescer` 本身是 `@MainActor`。
    ///
    /// `quiet` 允许 0，那是**关掉合并**的开关（`decide` 里 `now - lastOfferedAt >= 0` 恒真，
    /// 下一次 offer 会把上一份直接落掉，等于回到每次扫描都落盘）。
    /// `maxHold` 不允许 0——0 的效果与 quiet=0 重复，却绕开了正路，语义难解释。
    /// 负数与 NaN 一律当没设过：宁可用默认值，也不要让一个手误把采集改成另一副样子。
    nonisolated static func resolve(_ defaults: UserDefaults)
        -> (quiet: TimeInterval, maxHold: TimeInterval) {
        func seconds(_ key: String, _ fallback: TimeInterval, allowZero: Bool) -> TimeInterval {
            guard defaults.object(forKey: key) != nil else { return fallback }
            let raw = defaults.double(forKey: key)
            guard raw.isFinite, allowZero ? raw >= 0 : raw > 0 else { return fallback }
            return raw
        }
        let quiet = seconds(quietKey, quietDefault, allowZero: true)
        // 夹住下限：`maxHold < quiet` 的话 `decide` 里那条安静期分支永远轮不到。
        return (quiet, max(seconds(maxHoldKey, maxHoldDefault, allowZero: false), quiet))
    }

    init(defaults: UserDefaults = .standard) {
        let resolved = Self.resolve(defaults)
        quiet = resolved.quiet
        maxHold = resolved.maxHold
    }

    func configure(onFlush: @escaping (Int64, [TextFragment]) -> Void) {
        self.onFlush = onFlush
    }

    /// 一次扫描读到了正文。**观察已经写好了**，这里只决定正文什么时候落盘。
    func offer(key: Key, observationID: Int64, fragments: [TextFragment],
               now: TimeInterval = Date().timeIntervalSince1970) {
        guard !fragments.isEmpty else { return }
        if Self.decide(pending: pending, incoming: key, now: now,
                       quiet: quiet, maxHold: maxHold) != nil {
            flush()
        }
        // 走到这里时 `pending` 要么是 nil，要么就是同一个 key（不同 key 上面已经落盘并清空），
        // 所以只有一条赋值：`firstOfferedAt` 沿用旧的（最长暂存从这一串的开头算）。
        pending = Pending(key: key, observationID: observationID, fragments: fragments,
                          firstOfferedAt: pending?.firstOfferedAt ?? now, lastOfferedAt: now)
        reschedule(from: now)
    }

    /// 锁库 / 退出 / 换 key：手上有什么立刻落盘，一个字都不能丢。
    func flush() {
        scheduled?.cancel()
        scheduled = nil
        guard let ready = pending else { return }
        pending = nil
        onFlush?(ready.observationID, ready.fragments)
    }

    func stop() {
        scheduled?.cancel()
        scheduled = nil
    }

    /// 下一次该醒来的时刻：安静期与最长暂存里更近的那个。
    private func reschedule(from now: TimeInterval) {
        scheduled?.cancel()
        guard let pending else { scheduled = nil; return }
        let delay = max(0, min(pending.lastOfferedAt + quiet,
                               pending.firstOfferedAt + maxHold) - now)
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Self.decide(pending: self.pending, incoming: nil,
                               now: Date().timeIntervalSince1970,
                               quiet: self.quiet, maxHold: self.maxHold) != nil {
                    self.flush()
                } else {
                    self.reschedule(from: Date().timeIntervalSince1970)
                }
            }
        }
        scheduled = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
