import Foundation

// =============================================================================
// 模型目录（计划 3.11 / D18）
//
// **存放位置（D18）**：默认在**数据目录旁**的 `models/`，与加密库同级但不在库里：
//     <数据目录>/../models/<模型 id>/
// 权重是公开的，所以**不加密、不进 iCloud 同步**（D18 原话）。
// 可以用 `BROSIS_MODELS_DIR` 或 UserDefaults 的 `models.directory` 换路径。
//
// 与 tools/e9 的 `ModelStore.swift` 的差别只有三处：
//   1. 默认根目录换成"数据目录旁的 models/"（e9 是 ~/Library/Application Support/brosis-m0/models）；
//   2. public 化；
//   3. `importLocal` 多返回一个"每个文件的 sha256"，界面上要显示校验明细。
// 断点续传、staging 复用、files 为空必须拒绝这几条 E9 验收发现都原样保留。
// =============================================================================

public struct InstalledRecord: Codable, Sendable {
    public let id: String
    public let repoId: String
    public let revision: String?
    /// `huggingface` / `local-import`
    public let source: String
    public let baseURLUsed: String?
    public let importedFrom: String?
    public let totalBytes: Int64
    public let fileCount: Int
    public let installedAt: String
    public let verifiedAt: String
    public let catalogSchemaVersion: Int
}

public enum ModelStore {

    /// 环境变量覆盖（brosis-embed 与验收脚本用）。
    public static let directoryEnvKey = "BROSIS_MODELS_DIR"
    /// UserDefaults 覆盖键（app 用；写绝对路径）。
    public static let directoryDefaultsKey = "models.directory"

    /// 由数据目录推出模型目录：`<数据目录>/../models`（D18「默认在数据目录旁的 models/」）。
    public static func defaultRoot(dataDirectory: URL) -> URL {
        dataDirectory.deletingLastPathComponent().appending(path: "models", directoryHint: .isDirectory)
    }

    /// 解析实际使用的模型根目录，并说明来源（自检与界面要显示）。
    public static func resolveRoot(dataDirectory: URL,
                                   defaults: UserDefaults = .standard) -> (url: URL, source: String) {
        if let override = ProcessInfo.processInfo.environment[directoryEnvKey],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return (URL(filePath: (override as NSString).expandingTildeInPath), "env")
        }
        if let custom = defaults.string(forKey: directoryDefaultsKey),
           !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return (URL(filePath: (custom as NSString).expandingTildeInPath), "defaults")
        }
        return (defaultRoot(dataDirectory: dataDirectory), "default")
    }

    public static func directory(root: URL, id: String) -> URL { root.appending(path: id) }

    public static func isInstalled(root: URL, id: String) -> Bool {
        FileManager.default.fileExists(
            atPath: directory(root: root, id: id).appending(path: "installed.json").path)
    }

    public static func record(root: URL, id: String) -> InstalledRecord? {
        let u = directory(root: root, id: id).appending(path: "installed.json")
        guard let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(InstalledRecord.self, from: data)
    }

    /// staging 目录**按模型 id 固定**（E9 验收发现：断点续传必须跨进程，所以不能带随机后缀）。
    public static func stagingDirectory(root: URL, id: String) throws -> URL {
        let u = root.appending(path: ".staging-\(id)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 把 staging 整目录原子换到最终位置：先搬走旧的，再搬入新的，最后删旧的。
    @discardableResult
    public static func commit(staging: URL, root: URL, id: String) throws -> URL {
        let fm = FileManager.default
        let final = directory(root: root, id: id)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var backup: URL? = nil
        if fm.fileExists(atPath: final.path) {
            let b = root.appending(path: ".old-\(id)-\(UUID().uuidString.prefix(8))")
            try fm.moveItem(at: final, to: b)
            backup = b
        }
        do {
            try fm.moveItem(at: staging, to: final)
        } catch {
            if let backup { try? fm.moveItem(at: backup, to: final) }
            throw error
        }
        if let backup { try? fm.removeItem(at: backup) }
        return final
    }

    public static func writeRecord(_ r: InstalledRecord, root: URL, id: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(r).write(to: directory(root: root, id: id).appending(path: "installed.json"),
                                options: .atomic)
    }

    /// 逐文件核对清单里的 sha256。返回每个文件的摘要。
    @discardableResult
    public static func verify(model: CatalogModel, in dir: URL) throws -> [String: String] {
        guard !model.files.isEmpty else {
            // E9 验收发现：清单项 files 为空时必须拒绝，不能写出空的 installed.json。
            throw ModelsError("清单里的 \(model.id) 没有文件列表，拒绝校验 / 导入")
        }
        var digests: [String: String] = [:]
        for f in model.files {
            let u = dir.appending(path: f.path)
            guard FileManager.default.fileExists(atPath: u.path) else {
                throw ModelsError("缺文件：\(f.path)")
            }
            let size = (try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? -1
            guard size == f.size else {
                throw ModelsError("\(f.path) 字节数不符：\(size) != \(f.size)")
            }
            let d = try ModelHashing.sha256(ofFileAt: u)
            guard d == f.sha256 else {
                throw ModelsError("\(f.path) sha256 不符")
            }
            digests[f.path] = d
        }
        return digests
    }

    public struct ImportReport: Sendable {
        public var directory: URL
        public var totalBytes: Int64
        public var fileCount: Int
        public var seconds: Double
    }

    /// 本地导入：从 `from` 目录复制清单里列出的文件到 staging，校验后提交。
    /// **只复制不引用**，避免外部目录变动影响（3.11）。
    public static func importLocal(model: CatalogModel, from: URL, root: URL,
                                   schemaVersion: Int) throws -> ImportReport {
        let fm = FileManager.default
        let t0 = Date()
        guard !model.files.isEmpty else {
            throw ModelsError("清单里的 \(model.id) 没有文件列表，拒绝导入")
        }
        let staging = try stagingDirectory(root: root, id: model.id)
        // 固定 staging 目录要先清干净：上一次失败可能留了半个文件。
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var total: Int64 = 0
        for f in model.files {
            let src = from.appending(path: f.path)
            guard fm.fileExists(atPath: src.path) else {
                try? fm.removeItem(at: staging)
                throw ModelsError("源目录缺文件：\(f.path)")
            }
            let dst = staging.appending(path: f.path)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src, to: dst)
            total += f.size
        }
        do {
            try verify(model: model, in: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        let final = try commit(staging: staging, root: root, id: model.id)
        let now = ISO8601DateFormatter().string(from: Date())
        try writeRecord(
            InstalledRecord(
                id: model.id, repoId: model.repoId, revision: model.revision,
                source: "local-import", baseURLUsed: nil, importedFrom: from.path,
                totalBytes: total, fileCount: model.files.count,
                installedAt: now, verifiedAt: now, catalogSchemaVersion: schemaVersion),
            root: root, id: model.id)
        return ImportReport(directory: final, totalBytes: total, fileCount: model.files.count,
                            seconds: Date().timeIntervalSince(t0))
    }

    /// 删除一个已装模型（界面上的"移除"）。
    public static func remove(root: URL, id: String) throws {
        let dir = directory(root: root, id: id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    public static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: - 界面用的一行状态

    public struct Entry: Sendable {
        public var id: String
        public var purpose: String
        public var installed: Bool
        public var approved: Bool
        public var sizeBytes: Int64
        public var diskBytes: Int64
        public var minRAMBytes: Int64?
        public var unavailableReason: String?
        public var note: String?
        public var installedAt: String?
        public var source: String?
    }

    /// 清单 × 已装状态，供"模型"面板与 `--self-check` 直接渲染。
    public static func entries(catalog: Catalog, root: URL) -> [Entry] {
        catalog.models.map { m in
            let dir = directory(root: root, id: m.id)
            let installed = isInstalled(root: root, id: m.id)
            let record = installed ? record(root: root, id: m.id) : nil
            return Entry(id: m.id, purpose: m.purpose, installed: installed,
                         approved: m.isApproved,
                         sizeBytes: m.totalBytes ?? 0,
                         diskBytes: installed ? directorySize(dir) : 0,
                         minRAMBytes: m.minRAMBytes,
                         unavailableReason: m.unavailableReason,
                         note: m.note,
                         installedAt: record?.installedAt,
                         source: record?.source)
        }
    }
}
