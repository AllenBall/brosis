import Foundation

/// 按客户端的滑动窗口限流（2.2 硬约束 4「MCP 只读、限流、审计、按客户端范围限制」）。
///
/// 口径写死成「每客户端每 `windowSeconds` 秒最多 `limit` 次」，默认 60 次 / 60 s。
/// 滑动窗口而不是固定窗口：固定窗口在边界上能放进两倍的量。
///
/// **限的是 `client_id`，不是连接**。一个客户端反复重连不能把配额重置；
/// 反过来，`client_id` 是客户端自己报的，换个名字就是另一份配额——但换了名字也就没有
/// 对应的 grant，所有工具一律拒绝（见 `StoreMCPService`），所以这条不是绕过限流的路子。
public final class RateLimiter: @unchecked Sendable {

    public struct Decision: Sendable {
        public var allowed: Bool
        /// 本窗口内已经用掉的次数（含这一次）。
        public var used: Int
        public var limit: Int
        /// 窗口内最早那一次调用还有多少秒过期（被拒时给客户端一个「等多久」）。
        public var retryAfterSeconds: Double
    }

    private let lock = NSLock()
    private var hits: [String: [Double]] = [:]
    public let limit: Int
    public let windowSeconds: Double
    /// 记住的客户端上限，防止有人用随机 client_id 撑内存。
    private let maxClients: Int

    public init(limit: Int = 60, windowSeconds: Double = 60, maxClients: Int = 256) {
        self.limit = max(1, limit)
        self.windowSeconds = max(0.001, windowSeconds)
        self.maxClients = max(1, maxClients)
    }

    /// 单调时钟（自开机起的秒数，休眠不计）。
    ///
    /// **不能用墙钟**：系统时钟往回拨之后，窗口里那些"未来"的记录一条都不会过期，
    /// 但 `count >= limit` 的判定又要等它们过期——回拨反而能放大配额。
    /// 单调钟只会前进，最坏情况（休眠）是窗口显得更长、判定更严。
    public static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// 记一次调用并判定。`now` 只给测试用；默认值是上面的单调钟，
    /// 同一个 `RateLimiter` 的所有调用必须用同一套时钟。
    public func admit(client: String, now: Double = RateLimiter.now()) -> Decision {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now - windowSeconds
        var window = (hits[client] ?? []).filter { $0 > cutoff }

        if window.count >= limit {
            let oldest = window.first ?? now
            hits[client] = window
            return Decision(allowed: false, used: window.count, limit: limit,
                            retryAfterSeconds: max(0, oldest + windowSeconds - now))
        }
        window.append(now)
        // 先淘汰整窗都空了的客户端，还是超了就淘汰最久没来的那个。
        if hits[client] == nil, hits.count >= maxClients {
            for (k, v) in hits where v.allSatisfy({ $0 <= cutoff }) { hits.removeValue(forKey: k) }
            if hits.count >= maxClients,
               let stalest = hits.min(by: { ($0.value.last ?? 0) < ($1.value.last ?? 0) })?.key {
                hits.removeValue(forKey: stalest)
            }
        }
        hits[client] = window
        return Decision(allowed: true, used: window.count, limit: limit, retryAfterSeconds: 0)
    }

    /// 当前窗口内的用量（不计一次调用），只给状态查询与测试用。
    public func used(client: String, now: Double = RateLimiter.now()) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = now - windowSeconds
        return (hits[client] ?? []).filter { $0 > cutoff }.count
    }

    public func reset() {
        lock.lock()
        hits.removeAll()
        lock.unlock()
    }
}
