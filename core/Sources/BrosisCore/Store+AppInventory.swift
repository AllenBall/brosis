import Foundation

/// 3.12「应用采集清单」窗口要的那几行数据的**数据层**。
///
/// 计划 3.12 要求每一行显示「最近 7 天的观察数与完整性分布，方便判断值不值得留」。
/// 这一段必须在 core 里用一条聚合 SQL 出结果，**不能让采集端扫全表再自己数**：
/// 12 个月的库里 `observations` 是百万行量级（`tools/proto/results/capacity_2026-09-06.md`），
/// 把行拉到进程里再分组，等于每开一次窗口就把整张表读一遍。
///
/// 三个口径写死在这里，窗口只负责显示：
/// 1. **只算未删除的观察**（`deleted_at IS NULL`）。墓碑行不该再出现在"值不值得留"的判断里。
/// 2. **只算本机**（`device_id = ?`）。D17 同步过来的另一台机器的观察不参与本机策略判断——
///    `app_policies` 本来就是"本机配置，不随 iCloud 同步"。
/// 3. **窗口下界是调用方给的 `since`**（Unix 毫秒）。3.12 说的 7 天由调用方算，
///    core 不假设 7 这个数字。
public struct AppObservationStats: Sendable, Equatable, Codable {

    /// `apps.bundle_id`。
    public var bundleID: String
    /// `apps.name`（写入时那次观察给的应用名）。
    public var name: String
    /// 窗口内未删除的观察总数。
    public var observations: Int
    /// `completeness` 四态的分布，四项之和 == `observations`。
    public var complete: Int
    public var partial: Int
    public var unavailable: Int
    public var excluded: Int
    /// 窗口内最近一条观察的时间戳（Unix 毫秒）。窗口里那列「最近出现」用它。
    public var lastSeenMS: Int64

    public init(bundleID: String, name: String, observations: Int,
                complete: Int, partial: Int, unavailable: Int, excluded: Int,
                lastSeenMS: Int64) {
        self.bundleID = bundleID
        self.name = name
        self.observations = observations
        self.complete = complete
        self.partial = partial
        self.unavailable = unavailable
        self.excluded = excluded
        self.lastSeenMS = lastSeenMS
    }
}

/// `app_policies` 的一行（3.12 的权威存储）。
public struct AppPolicyRecord: Sendable, Equatable, Codable {
    public var bundleID: String
    public var mode: CapturePolicyMode
    public var source: CapturePolicySource
    /// 最后一次写入时间（Unix 毫秒）。
    public var updatedAt: Int64

    public init(bundleID: String, mode: CapturePolicyMode,
                source: CapturePolicySource, updatedAt: Int64) {
        self.bundleID = bundleID
        self.mode = mode
        self.source = source
        self.updatedAt = updatedAt
    }
}

extension Store {

    /// 按应用汇总 `[since, ∞)` 内的观察数与完整性分布，按观察数倒序。
    ///
    /// 走的索引是 `idx_obs_live(device_id, ts) WHERE deleted_at IS NULL`——
    /// 它是**部分索引**，条件正好是这里的 `deleted_at IS NULL`，所以 7 天窗口是一次范围扫，
    /// 不是全表扫（`appObservationStatsPlan()` 把 `EXPLAIN QUERY PLAN` 原样返回，测试盯着它）。
    ///
    /// - Parameter since: Unix 毫秒下界（含）。传 0 就是全库。
    public func appObservationStats(since: Int64) throws -> [AppObservationStats] {
        try withLock { conn in
            let st = try conn.prepare(Self.appObservationStatsSQL)
            defer { st.finalize() }
            try st.bind([.text(deviceID), .int(since)])
            var out: [AppObservationStats] = []
            while try st.step() {
                out.append(AppObservationStats(
                    bundleID: st.text(0) ?? "",
                    name: st.text(1) ?? "",
                    observations: Int(st.int(2) ?? 0),
                    complete: Int(st.int(3) ?? 0),
                    partial: Int(st.int(4) ?? 0),
                    unavailable: Int(st.int(5) ?? 0),
                    excluded: Int(st.int(6) ?? 0),
                    lastSeenMS: st.int(7) ?? 0))
            }
            return out
        }
    }

    /// `EXPLAIN QUERY PLAN` 的原文行。只给测试与结果文件用：证明上面那条 SQL 走的是
    /// `idx_obs_live` 而不是全表扫。
    public func appObservationStatsPlan() throws -> [String] {
        try withLock { conn in
            let st = try conn.prepare("EXPLAIN QUERY PLAN " + Self.appObservationStatsSQL)
            defer { st.finalize() }
            try st.bind([.text(deviceID), .int(0)])
            var out: [String] = []
            while try st.step() { out.append(st.text(3) ?? "") }
            return out
        }
    }

    /// 只有一处定义，`appObservationStats` 与 `appObservationStatsPlan` 共用——
    /// 否则"测的计划"与"跑的语句"会各自漂移。
    ///
    /// `SUM(o.completeness = 'x')` 在 SQLite 里是对 0/1 求和，等价于 `COUNT(... FILTER ...)`，
    /// 但不依赖 SQLite 3.30 的 FILTER 语法。
    static let appObservationStatsSQL = """
        SELECT a.bundle_id,
               a.name,
               COUNT(*),
               SUM(o.completeness = 'complete'),
               SUM(o.completeness = 'partial'),
               SUM(o.completeness = 'unavailable'),
               SUM(o.completeness = 'excluded'),
               MAX(o.ts)
          FROM observations o
          JOIN apps a ON a.id = o.app_id
         WHERE o.device_id = ? AND o.ts >= ? AND o.deleted_at IS NULL
         GROUP BY o.app_id
         ORDER BY COUNT(*) DESC, a.bundle_id;
        """

    /// 一个应用**全库**（不限时间窗口）未删除的观察数。
    ///
    /// 3.12「改为更低档时询问是否删除该应用已有数据」要用它决定**要不要弹那个框**：
    /// 这个应用一条数据都没有的时候弹"是否删除 0 条"是纯噪音。
    /// 用的是 `idx_obs_app_ts(app_id, ts)`，只扫这一个应用的那一段，不是全表。
    public func appObservationCount(bundleID: String) throws -> Int {
        try withLock { conn in
            Int(try conn.scalarInt("""
                SELECT COUNT(*) FROM observations o JOIN apps a ON a.id = o.app_id
                 WHERE o.device_id = ? AND a.bundle_id = ? AND o.deleted_at IS NULL;
                """, [.text(deviceID), .text(bundleID)]) ?? 0)
        }
    }

    /// `app_policies` 全表（3.12 的清单窗口要用它当数据源之一）。按 bundle id 排序。
    ///
    /// 表里每个应用一行、本机配置，行数就是"本机见过的应用数"（几十到几百），
    /// 所以整表读回来是合适的；窗口不需要分页。
    public func appPolicies() throws -> [AppPolicyRecord] {
        try withLock { conn in
            let st = try conn.prepare("""
                SELECT bundle_id, mode, source, updated_at FROM app_policies ORDER BY bundle_id;
                """)
            defer { st.finalize() }
            var out: [AppPolicyRecord] = []
            while try st.step() {
                guard let bundleID = st.text(0),
                      let mode = st.text(1).flatMap(CapturePolicyMode.init(rawValue:)),
                      let source = st.text(2).flatMap(CapturePolicySource.init(rawValue:))
                else { continue }
                out.append(AppPolicyRecord(bundleID: bundleID, mode: mode, source: source,
                                           updatedAt: st.int(3) ?? 0))
            }
            return out
        }
    }

    /// `apps` 表里 bundle id → 应用名。清单窗口给"有策略行但最近 7 天没观察"的应用取显示名用。
    ///
    /// `apps` 是规范化对象表（一个应用一行），不是观察表，整表读回来不贵。
    public func appNames() throws -> [String: String] {
        try withLock { conn in
            let st = try conn.prepare("SELECT bundle_id, name FROM apps;")
            defer { st.finalize() }
            var out: [String: String] = [:]
            while try st.step() {
                guard let bundleID = st.text(0), let name = st.text(1) else { continue }
                out[bundleID] = name
            }
            return out
        }
    }
}
