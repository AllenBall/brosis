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

    /// **纯函数**：手上这份该不该落盘了。返回 nil = 继续攒。
    ///
    /// `incoming` 是这一刻新来的 key（定时器来问时传 nil）。顺序有意义：
    /// 换 key 优先于安静期——换了应用就该立刻落盘，不必再等三秒。
    /// `nonisolated`：这是纯函数，自检在非主线程上下文里也要能直接调。
    nonisolated static func decide(pending: Pending?, incoming: Key?, now: TimeInterval,
                                   quiet: TimeInterval, maxHold: TimeInterval) -> String? {
        guard let pending else { return nil }
        if let incoming, incoming != pending.key { return "key_changed" }
        if now - pending.firstOfferedAt >= maxHold { return "max_hold" }
        if now - pending.lastOfferedAt >= quiet { return "quiet" }
        return nil
    }

    private var pending: Pending?
    private var timer: Timer?
    private let quiet: TimeInterval
    private let maxHold: TimeInterval
    /// 落盘动作。由 `EventSkeleton` 接到 `Recorder.attachTexts`。
    private var onFlush: ((Flush) -> Void)?

    init(defaults: UserDefaults = .standard) {
        func seconds(_ key: String, _ fallback: TimeInterval) -> TimeInterval {
            guard defaults.object(forKey: key) != nil else { return fallback }
            let raw = defaults.double(forKey: key)
            return raw.isFinite && raw > 0 ? raw : fallback
        }
        quiet = seconds(Self.quietKey, Self.quietDefault)
        maxHold = max(seconds(Self.maxHoldKey, Self.maxHoldDefault),
                      seconds(Self.quietKey, Self.quietDefault))
    }

    func install(onFlush: @escaping (Flush) -> Void) {
        self.onFlush = onFlush
        guard timer == nil else { return }
        // 每秒问一次。安静期与最长暂存都是秒级判据，1 s 的粒度足够，
        // 而且这个定时器什么都不做时的代价就是一次比较。
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 一次扫描读到了正文。**观察已经写好了**，这里只决定正文什么时候落盘。
    func offer(key: Key, observationID: Int64, fragments: [TextFragment],
               now: TimeInterval = Date().timeIntervalSince1970) {
        guard !fragments.isEmpty else { return }
        if let reason = Self.decide(pending: pending, incoming: key, now: now,
                                    quiet: quiet, maxHold: maxHold) {
            emit(reason: reason)
        }
        if var current = pending, current.key == key {
            // 同一个 key 又来一份：直接覆盖，旧的从来没落过盘，丢掉不留痕迹。
            current.observationID = observationID
            current.fragments = fragments
            current.lastOfferedAt = now
            pending = current
        } else {
            pending = Pending(key: key, observationID: observationID, fragments: fragments,
                              firstOfferedAt: now, lastOfferedAt: now)
        }
    }

    /// 锁库 / 退出：手上有什么立刻落盘，一个字都不能丢。
    func flushNow(reason: String) {
        emit(reason: reason)
    }

    private func tick() {
        if let reason = Self.decide(pending: pending, incoming: nil,
                                    now: Date().timeIntervalSince1970,
                                    quiet: quiet, maxHold: maxHold) {
            emit(reason: reason)
        }
    }

    private func emit(reason: String) {
        guard let ready = pending else { return }
        pending = nil
        onFlush?(Flush(observationID: ready.observationID, fragments: ready.fragments,
                       reason: reason))
    }
}
