import Foundation

/// 数据目录的准备与 D16 的同步盘拒绝。
///
/// D16：数据目录可配置，默认 `~/Library/Application Support/<bundle-id>/`；
/// **数据库文件不允许放在 iCloud Drive 或其他文件同步目录**，检测到时拒绝并提示改用 D17 的同步段文件。
/// 原因见 3.9：SQLite 靠文件锁协调并发写，锁不跨机器传播；WAL 下 `.db` / `-wal` / `-shm`
/// 三个文件分别同步且顺序无保证；iCloud 还会把不常用文件驱逐成占位符。SQLCipher 不改变以上任何一点。
///
/// 硬约束 7（2.2）：目录 0700，排除 Time Machine / Spotlight。
public enum DataDirectory {

    /// 默认目录：`~/Library/Application Support/<bundleID>/`。
    public static func defaultURL(bundleID: String = "com.brosis.app") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    // MARK: - D16 拒绝规则

    /// 路径组件里出现这些名字就拒绝。大小写不敏感比较。
    /// 只列常见同步盘；命中不了的（自建 rsync、企业客户端）由下面的 iCloud / 网络卷检查兜底。
    static let syncFolderNames: [String] = [
        "Mobile Documents",          // iCloud Drive 的真实位置
        "com~apple~CloudDocs",
        "iCloud Drive",
        "iCloud Drive (Archive)",
        "Dropbox",
        "Google Drive",
        "GoogleDrive",
        "My Drive",
        "OneDrive",
        "Box",
        "Box Sync",
        "pCloud Drive",
        "Nextcloud",
        "ownCloud",
        "Seafile",
        "MEGA",
        "MEGAsync",
        "Sync",
        "Yandex.Disk",
        "Nutstore",
        "坚果云",
        "百度网盘",
        "Creative Cloud Files",
        "Resilio Sync",
        "Syncthing",
        "brosis-sync",               // D17 的同步段文件目录：段文件可以放，库文件不行
    ]

    /// 前缀匹配的路径组件（例如公司版 OneDrive 目录名是 `OneDrive - <公司名>`）。
    static let syncFolderPrefixes: [String] = ["OneDrive -", "Dropbox (", "Google Drive "]

    /// 检查一个目录（或它将来所在的位置）能不能放数据库。抛 `.directoryRejected` 表示不行。
    ///
    /// 三层检查，任一命中即拒绝：
    ///  1. 路径组件名命中已知同步盘（不要求目录已存在）；
    ///  2. 最近的已存在祖先是 iCloud 项目（`URLResourceValues.isUbiquitousItem`）；
    ///  3. 最近的已存在祖先所在卷不是本地卷（网络盘 / NAS —— SQLite 官方同样列为已知损坏来源）。
    public static func validate(_ directory: URL) throws {
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath()

        // —— 1. 名字层 ——
        for component in resolved.pathComponents {
            for name in syncFolderNames where component.compare(name, options: .caseInsensitive) == .orderedSame {
                throw StoreError.directoryRejected(
                    path: resolved.path,
                    reason: "路径里含同步目录「\(name)」。数据库文件不允许放在 iCloud Drive 或其他文件同步目录（D16）；"
                          + "跨设备共享请用 D17 的加密同步段文件，不要共享数据库本体")
            }
            for prefix in syncFolderPrefixes where component.lowercased().hasPrefix(prefix.lowercased()) {
                throw StoreError.directoryRejected(
                    path: resolved.path,
                    reason: "路径里含同步目录「\(component)」。数据库文件不允许放在文件同步目录（D16）")
            }
        }

        // 找最近的已存在祖先，后两层检查对它做。
        var probe = resolved
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        guard fm.fileExists(atPath: probe.path) else { return }

        // —— 2. iCloud 层 ——
        if let values = try? probe.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            throw StoreError.directoryRejected(
                path: resolved.path,
                reason: "该位置是 iCloud 同步项（isUbiquitousItem = true），数据库不允许放在这里（D16）")
        }

        // —— 3. 卷层 ——
        if let values = try? probe.resourceValues(forKeys: [.volumeIsLocalKey]),
           values.volumeIsLocal == false {
            throw StoreError.directoryRejected(
                path: resolved.path,
                reason: "该位置在网络卷上。SQLite 的文件锁不跨主机传播，官方把网络卷列为已知损坏来源（同 3.9）")
        }
    }

    // MARK: - 准备目录

    /// 建目录（若无）、chmod 0700、写 `.metadata_never_index`、排除 Time Machine。
    /// 调用前必须先 `validate`。
    @discardableResult
    public static func prepare(_ directory: URL) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDir) {
            guard isDir.boolValue else {
                throw StoreError.filesystem("\(directory.lastPathComponent) 已存在但不是目录")
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        }
        // 已存在的目录也要收紧到 0700（硬约束 7）。
        try fm.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))],
                             ofItemAtPath: directory.path)

        // Spotlight：目录里放 .metadata_never_index，整棵子树不被索引。
        let marker = directory.appendingPathComponent(".metadata_never_index", isDirectory: false)
        if !fm.fileExists(atPath: marker.path) {
            guard fm.createFile(atPath: marker.path, contents: Data(),
                                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
                throw StoreError.filesystem("无法写 .metadata_never_index")
            }
        }

        // Time Machine：CSBackupSetItemExcluded 的 Swift 等价物是
        // URLResourceValues.isExcludedFromBackup（同一个 com.apple.metadata:com_apple_backup_excludeItem
        // 扩展属性），CoreServices 的 C 函数在 Swift 6 里已不可用。
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
        } catch {
            throw StoreError.filesystem("排除 Time Machine 失败：\(error.localizedDescription)")
        }
        return directory
    }

    /// 自查：目录权限是否 0700、两个排除标记是否都在。`--self-check` 与测试用。
    public static func auditFlags(_ directory: URL) -> (mode: UInt16, neverIndex: Bool, excludedFromBackup: Bool) {
        let fm = FileManager.default
        let mode = ((try? fm.attributesOfItem(atPath: directory.path)[.posixPermissions]) as? NSNumber)?
            .uint16Value ?? 0
        let neverIndex = fm.fileExists(
            atPath: directory.appendingPathComponent(".metadata_never_index").path)
        let excluded = (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?
            .isExcludedFromBackup ?? false
        return (mode & 0o7777, neverIndex, excluded)
    }
}
