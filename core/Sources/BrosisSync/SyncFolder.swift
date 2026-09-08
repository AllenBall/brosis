import Foundation

// =============================================================================
// D17 / 3.9 的目录：布局、列目录、iCloud 占位符触发下载、manifest 冲突副本检测、
// ack 读写与两边都 ack 后的清理。
//
// 目录结构（3.9 原文）：
//   <root>/manifest.json                   格式版本、创建时间、加密参数（不含密钥）
//   <root>/keyring/<device_id>.wrapped     口令包裹的同步密钥副本，供新设备加入
//   <root>/devices/<device_id>.json        设备名、加入时间、最后出站 seq
//   <root>/segments/<device_id>/<seq>.seg  加密段文件，写一次不改
//   <root>/acks/<device_id>.json           本机已导入各设备到哪个 seq
//
// **每台机器只写自己那几个文件**（自己的 keyring / devices / acks 条目和 segments/<自己>/），
// 这是整套设计不需要跨机器加锁的原因，也是"可以换成任意文件同步盘或 NAS"的原因。
// =============================================================================

public struct SyncFolder: Sendable {

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var manifestURL: URL { root.appendingPathComponent("manifest.json", isDirectory: false) }
    public var keyringDirectory: URL { root.appendingPathComponent("keyring", isDirectory: true) }
    public var devicesDirectory: URL { root.appendingPathComponent("devices", isDirectory: true) }
    public var segmentsDirectory: URL { root.appendingPathComponent("segments", isDirectory: true) }
    public var acksDirectory: URL { root.appendingPathComponent("acks", isDirectory: true) }

    public func segmentsDirectory(device: String) -> URL {
        segmentsDirectory.appendingPathComponent(device, isDirectory: true)
    }
    public func segmentURL(device: String, seq: Int64) -> URL {
        segmentsDirectory(device: device)
            .appendingPathComponent(SyncSegmentFile.fileName(seq: seq), isDirectory: false)
    }
    public func keyringURL(device: String) -> URL {
        keyringDirectory.appendingPathComponent("\(device).wrapped", isDirectory: false)
    }
    public func deviceURL(_ device: String) -> URL {
        devicesDirectory.appendingPathComponent("\(device).json", isDirectory: false)
    }
    public func ackURL(_ device: String) -> URL {
        acksDirectory.appendingPathComponent("\(device).json", isDirectory: false)
    }

    // MARK: - 建目录

    /// 建出 4 个子目录（幂等）。**不**加 0700 / 排除 Spotlight：这个目录是要被同步盘读写的，
    /// 收紧权限会让同步客户端读不到；它也不是数据目录（D16 明确禁止库文件进来，见 `validate`）。
    public func createSkeleton(device: String) throws {
        let fm = FileManager.default
        for directory in [root, keyringDirectory, devicesDirectory, segmentsDirectory,
                          acksDirectory, segmentsDirectory(device: device)] {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
    }

    /// D16 的另一半：**同步目录不能是数据目录**。
    /// 数据库不许放进同步盘（`DataDirectory.validate` 管那一头）；这里管反方向——
    /// 有人把同步目录设成了数据目录（或它的子目录），段文件与库文件混在一起，
    /// 一旦同步盘把 `brosis.db-wal` 传出去就等于把库传出去了。
    public func validate(against dataDirectory: URL) throws {
        let data = dataDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let sync = root.resolvingSymlinksInPath().path
        if sync == data || sync.hasPrefix(data + "/") || data.hasPrefix(sync + "/") {
            throw SyncError.directoryRejected(
                path: root.path,
                reason: "同步目录与数据目录重叠（数据目录 \(dataDirectory.lastPathComponent)）。"
                      + "库文件不允许进同步目录（D16），同步目录里只放加密段文件")
        }
        // 目录里出现库文件 = 有人把库拷进来了，直接拒绝。
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: root.path) {
            for name in entries where name.hasSuffix(".db") || name.hasSuffix(".db-wal")
                                   || name.hasSuffix(".db-shm") {
                throw SyncError.directoryRejected(
                    path: root.path,
                    reason: "同步目录里有数据库文件「\(name)」。SQLite 的文件锁不跨机器传播，"
                          + "WAL 的三个文件分别同步且顺序无保证（3.9），D16 明确禁止")
            }
        }
    }

    // MARK: - manifest 冲突副本（3.9「边界情况」）

    /// 两台机器几乎同时首次打开会各写一个 manifest，iCloud 保留冲突版本。
    /// 检测两路：① 根目录里出现 `manifest 2.json` 之类的旁支文件；
    /// ② `NSFileVersion` 报未解决的冲突版本。任一命中就**停下来让用户选**，不自动合并。
    public func manifestConflicts() -> [String] {
        var hits: [String] = []
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(atPath: root.path) {
            for name in entries.sorted() {
                let real = Self.realName(of: name)
                guard real != "manifest.json", real.hasSuffix(".json") else { continue }
                let stem = String(real.dropLast(5))
                if stem == "manifest" || stem.hasPrefix("manifest ") || stem.hasPrefix("manifest-")
                    || stem.hasPrefix("manifest_") || stem.hasPrefix("manifest（")
                    || stem.hasPrefix("manifest (") {
                    hits.append(real)
                }
            }
        }
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: manifestURL) ?? [] {
            hits.append(version.localizedName ?? version.url.lastPathComponent)
        }
        return hits
    }

    // MARK: - 列目录（占位符感知）

    /// iCloud 没下载的文件在目录里显示成 `.<真名>.icloud`。列目录时把它还原成真名，
    /// 于是"有没有这一段"与"下没下载"是两件事：**有**（可以按序号排队）但**要先下载**。
    public static func realName(of entry: String) -> String {
        guard entry.hasPrefix("."), entry.hasSuffix(".icloud") else { return entry }
        return String(entry.dropFirst().dropLast(".icloud".count))
    }

    public static func isPlaceholder(_ entry: String) -> Bool {
        entry.hasPrefix(".") && entry.hasSuffix(".icloud")
    }

    /// 目录里的条目真名（已还原占位符、已去掉 `.` 开头的系统文件）。
    public func entries(at directory: URL) -> [String] {
        let fm = FileManager.default
        guard let raw = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var names = Set<String>()
        for entry in raw {
            let real = Self.realName(of: entry)
            if real.hasPrefix(".") { continue }         // .DS_Store 之类
            names.insert(real)
        }
        return names.sorted()
    }

    /// 目录里出现过的设备（`segments/` 的子目录名 ∪ `devices/` 里的文件名）。
    public func knownDevices() -> [String] {
        var devices = Set(entries(at: segmentsDirectory))
        for name in entries(at: devicesDirectory) where name.hasSuffix(".json") {
            devices.insert(String(name.dropLast(5)))
        }
        return devices.sorted()
    }

    /// 某个设备目录下有哪些段序号（含还没下载的占位符）。
    public func segmentSequences(device: String) -> [Int64] {
        entries(at: segmentsDirectory(device: device))
            .compactMap { SyncSegmentFile.sequence(fromFileName: $0) }
            .sorted()
    }

    // MARK: - 占位符下载（3.9「段文件可能被 iCloud 驱逐成占位符，导入前触发下载并等待」）

    /// 确保文件真的在本地。非 iCloud 项目（普通目录、NAS）直接返回。
    ///
    /// 判据用 `URLResourceValues.ubiquitousItemDownloadingStatus == .current`，
    /// 不用"文件存不存在"——占位符存在的是 `.<name>.icloud`，真名那个路径此时并不存在。
    @discardableResult
    public func ensureDownloaded(_ url: URL, timeout: TimeInterval = 60,
                                 poll: TimeInterval = 0.2) throws -> Bool {
        let fm = FileManager.default
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + ".icloud", isDirectory: false)
        let hasPlaceholder = fm.fileExists(atPath: placeholder.path)
        if fm.fileExists(atPath: url.path) && !hasPlaceholder {
            // 普通文件（非 iCloud，或者已经下载好了）。再核一次下载状态，避免"占位符已消失但仍在下载"。
            if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
               values.isUbiquitousItem != true {
                return false
            }
        }
        guard hasPlaceholder || fm.fileExists(atPath: url.path) else {
            throw SyncError.missingFile(url.lastPathComponent)
        }
        do {
            try fm.startDownloadingUbiquitousItem(at: url)
        } catch {
            // 不是 iCloud 项目时这里会抛；文件本身在，就当作已就绪。
            if fm.fileExists(atPath: url.path) { return false }
            throw SyncError.downloadFailed(url.lastPathComponent, "\(error)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               values.ubiquitousItemDownloadingStatus == .current {
                return true
            }
            if fm.fileExists(atPath: url.path) && !fm.fileExists(atPath: placeholder.path) {
                return true
            }
            Thread.sleep(forTimeInterval: poll)
        }
        throw SyncError.downloadTimeout(url.lastPathComponent, timeout)
    }

    // MARK: - 原子写

    /// 写一个文件：先写同目录下的临时文件再 `replaceItemAt`，同步盘看到的永远是完整文件。
    public func writeAtomically(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let temporary = directory.appendingPathComponent(
            ".tmp-\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)", isDirectory: false)
        try data.write(to: temporary, options: [.atomic])
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: url)
        }
    }

    public func read(_ url: URL, timeout: TimeInterval = 60) throws -> Data {
        try ensureDownloaded(url, timeout: timeout)
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SyncError.missingFile(url.lastPathComponent)
        }
    }

    // MARK: - ack 与清理

    public func readAck(device: String, timeout: TimeInterval = 60) -> SyncAckRecord? {
        guard let data = try? read(ackURL(device), timeout: timeout) else { return nil }
        return try? JSONDecoder().decode(SyncAckRecord.self, from: data)
    }

    public func writeAck(_ record: SyncAckRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try writeAtomically(try encoder.encode(record), to: ackURL(record.device))
    }

    /// 3.9「清理」：两边都 ack 的段文件可删。
    ///
    /// 谁来删：**段的主人**（只有它写自己的 `segments/<自己>/`）。
    /// 删到哪：所有**其他已注册设备**的 ack 里，对本机的 seq 取**最小值**——
    /// 有一台机器还没导到，就不能删。一台都没有（只有自己）时不删任何东西：
    /// 那说明第二台机器还没加入，段还得留着等它。
    ///
    /// - Returns: (删掉的段数, 判定用的水位线)
    @discardableResult
    public func cleanupAckedSegments(device: String, timeout: TimeInterval = 60) throws
        -> (deleted: Int, watermark: Int64) {
        let peers = knownDevices().filter { $0 != device }
        guard !peers.isEmpty else { return (0, 0) }
        var watermark = Int64.max
        for peer in peers {
            let acked = readAck(device: peer, timeout: timeout)?.imported[device] ?? 0
            watermark = min(watermark, acked)
        }
        guard watermark > 0, watermark != Int64.max else { return (0, 0) }
        let fm = FileManager.default
        var deleted = 0
        for seq in segmentSequences(device: device) where seq <= watermark {
            let url = segmentURL(device: device, seq: seq)
            let placeholder = url.deletingLastPathComponent()
                .appendingPathComponent("." + url.lastPathComponent + ".icloud", isDirectory: false)
            // 占位符与真文件都可能存在，两个都试着删。
            if fm.fileExists(atPath: url.path), (try? fm.removeItem(at: url)) != nil { deleted += 1 }
            else if fm.fileExists(atPath: placeholder.path),
                    (try? fm.removeItem(at: placeholder)) != nil { deleted += 1 }
        }
        return (deleted, watermark)
    }

    /// 目录里段文件的总字节（状态显示与结果文件用）。占位符按 0 算（本地没有实体）。
    public func segmentBytes() -> Int {
        let fm = FileManager.default
        var total = 0
        for device in knownDevices() {
            for seq in segmentSequences(device: device) {
                let url = segmentURL(device: device, seq: seq)
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber
                total += size?.intValue ?? 0
            }
        }
        return total
    }
}
