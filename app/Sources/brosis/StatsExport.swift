import BrosisCore
import Foundation

/// 「导出存储统计…」：把 `Store.stats()` 与 `Store.statsDetail()` 落成数据目录下的一个 JSON。
///
/// 为什么要有这个出口：产品库是 SQLCipher 加密的、钥匙在钥匙串里，`sqlite3` 与
/// `brosis-store --key-file` 都读不了它（app/README 第 5 节第 6 条）。
/// 于是"这个库现在有多大、正文占多少、索引占多少、有多少行"这类数字，
/// 除了菜单栏那一行实时计数之外没有任何可核对的出口。
/// M1 第二轮的月报脚本（T6）要按 2.4 的存储行报数，需要一个稳定的、离线可读的格式——就是这个文件。
///
/// **文件里没有任何正文、没有窗口标题、没有 URL、也没有绝对路径**：只有计数与字节数，
/// 以及 `dbstat` 的每个 b-tree 名字（表名 / 索引名，schema 的一部分，不是用户数据）。
/// 落在数据目录里，跟着库一起受 0700 与"排除同步盘"的约束（D16）。
enum StatsExport {

    /// 格式版本。字段有增删就 +1；月报脚本按它判断能不能读。
    static let schemaVersion = 1

    /// 文件名：`stats-<yyyy-MM-dd>.json`（本地时区的日期）。同一天重复导出会**覆盖**当天那份。
    static func fileName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "stats-%04d-%02d-%02d.json",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// 导出文件的结构。键名用 snake_case（`JSONEncoder` 的 `convertToSnakeCase`），
    /// `store` / `dbstat` 两段直接是 core 的 `StoreStats` / `[StatsRow]`。
    struct Payload: Codable {
        var schemaVersion: Int
        /// 写这份文件的版本，等于 `BuildInfo.version`。
        var generatedBy: String
        /// D17：主键里的 `device_id`，跨设备合并月报时用。
        var deviceID: String
        /// 导出时刻，ISO 8601（UTC，秒精度）。
        var exportedAt: String
        /// 同一时刻的 Unix **毫秒**，与 `observations.ts` 同口径。
        var exportedAtMs: Int64
        var store: StoreStats
        /// `dbstat` 逐 b-tree 明细，按字节倒序（bucket ∈ content / index / fts / metadata）。
        var dbstat: [StatsRow]
    }

    struct Outcome: Sendable {
        var url: URL
        var fileBytes: Int
        /// 写进 `runtime_event:stats_exported` 的 detail，也用来在菜单里回显。
        var detail: String
    }

    /// 导出。**同一个函数**给菜单项与自检用（自检拿的是 `InMemoryKeyProvider` 的临时库）。
    ///
    /// - 注意：`dbstat` 只统计已经落进主库文件的页，WAL 里没 checkpoint 的脏页不计
    ///   （core 的 `stats()` 口径）。菜单项因此先做一次 `checkpoint()`，
    ///   自检为了同时验 `wal_bytes` 不做。
    @discardableResult
    static func export(store: Store, directory: URL, now: Date = Date()) throws -> Outcome {
        let stats = try store.stats()
        let detail = try store.statsDetail()
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let payload = Payload(schemaVersion: schemaVersion,
                              generatedBy: BuildInfo.version,
                              deviceID: store.deviceID,
                              exportedAt: formatter.string(from: now),
                              exportedAtMs: Recorder.milliseconds(now),
                              store: stats,
                              dbstat: detail)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)

        let url = directory.appendingPathComponent(fileName(for: now), isDirectory: false)
        try data.write(to: url, options: .atomic)
        // 数据目录本身是 0700（DataDirectory 保证），文件再收一次到 0600。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        return Outcome(
            url: url,
            fileBytes: data.count,
            detail: "file=\(url.lastPathComponent) schema=\(schemaVersion) bytes=\(data.count)"
                  + " db_file=\(stats.dbFileBytes) wal=\(stats.walBytes)"
                  + " content=\(stats.contentBytes) index=\(stats.indexBytes) fts=\(stats.ftsBytes)"
                  + " metadata=\(stats.metadataBytes)"
                  + " observations=\(stats.observations) text_versions=\(stats.textVersions)"
                  + " occurrences=\(stats.occurrences) dbstat_rows=\(detail.count)")
    }
}
