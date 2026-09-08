import Foundation

// =============================================================================
// 模型目录（计划 3.11 / D18）
//
// **存放位置（D18）**：默认在**数据目录里**的 `models/`，与加密库同级但不在库里：
//     <数据目录>/models/<模型 id>/
// 权重是公开的，所以**不加密、不进 iCloud 同步**（D18 原话）。
// 可以用 `BROSIS_MODELS_DIR` 或 UserDefaults 的 `models.directory` 换路径。
//
// **2026-09-08 改过一次**：原来是"数据目录**旁**"（`<数据目录>/../models`），落到默认数据目录上
// 就是 `~/Library/Application Support/models` —— 名字通用、在 brosis 文件夹外面、卸载时清不干净。
// 挪进数据目录后 D18 的实质约束一条没变（库外、不加密、不同步；数据目录本身就禁止放同步盘，D16）。
// 旧路径由 `migrateLegacyDefaultRoot` 在启动时一次性搬过来。
//
// 与 tools/e9 的 `ModelStore.swift` 的差别只有三处：
//   1. 默认根目录换成"数据目录里的 models/"（e9 是 ~/Library/Application Support/brosis-m0/models）；
//   2. public 化；
//   3. `importLocal` 多返回一个"每个文件的 sha256"，界面上要显示校验明细。
// 断点续传、staging 复用、files 为空必须拒绝这几条 E9 验收发现都原样保留。
// =============================================================================

public struct InstalledRecord: Codable, Sendable {
    public let id: String
    public let repoId: String
    public let revision: String?
    /// `huggingface` / `local-import` / `linked`（D30：关联外部目录，权重不复制）
    public let source: String
    public let baseURLUsed: String?
    public let importedFrom: String?
    public let totalBytes: Int64
    public let fileCount: Int
    public let installedAt: String
    public let verifiedAt: String
    public let catalogSchemaVersion: Int
    /// D30「关联到别的目录」：权重的真实位置（例如 LM Studio 的模型目录）。
    /// 只有 `source == "linked"` 时有值；这时 `<模型根目录>/<id>/` 里只有这份 installed.json。
    public let linkedPath: String?
    /// 关联时看到的文件数与总字节数，用来发现外部目录被人动过（只提示，不阻止）。
    public let linkedFileCount: Int?
    public let linkedTotalBytes: Int64?

    public var isLinked: Bool { source == "linked" && linkedPath != nil }
}

public enum ModelStore {

    /// 环境变量覆盖（brosis-embed 与验收脚本用）。
    public static let directoryEnvKey = "BROSIS_MODELS_DIR"
    /// UserDefaults 覆盖键（app 用；写绝对路径）。
    public static let directoryDefaultsKey = "models.directory"

    /// 由数据目录推出模型目录：`<数据目录>/models`（D18 的 models/，2026-09-08 起在数据目录**里**）。
    public static func defaultRoot(dataDirectory: URL) -> URL {
        dataDirectory.appending(path: "models", directoryHint: .isDirectory)
    }

    /// 旧的默认模型根目录（0.2.0 及以前）：`<数据目录>/../models`。只给迁移和自检用。
    public static func legacyDefaultRoot(dataDirectory: URL) -> URL {
        dataDirectory.deletingLastPathComponent().appending(path: "models", directoryHint: .isDirectory)
    }

    /// 一次性迁移：把旧默认根目录里已装好的模型搬进新的默认根目录。
    ///
    /// 规矩（旧路径 `~/Library/Application Support/models` 是个通用名字，不能整目录搬走）：
    ///  - 只在**用默认根目录**时做：有 `BROSIS_MODELS_DIR` 或 `models.directory` 覆盖就一步不动；
    ///  - 只搬**目录里有 `installed.json`** 的模型目录，旧根目录里别的东西一概不碰；
    ///  - 新根目录已有同 id 就跳过（不覆盖已装模型），旧的留在原地等人工处置；
    ///  - 搬完旧根目录只剩隐藏文件（`.DS_Store`、半截 `.staging-*`）才删它。
    ///
    /// 幂等：旧根目录不存在时立刻返回。返回搬过去的模型 id（按字典序）。
    @discardableResult
    public static func migrateLegacyDefaultRoot(dataDirectory: URL,
                                                defaults: UserDefaults = .standard) throws -> [String] {
        let resolved = resolveRoot(dataDirectory: dataDirectory, defaults: defaults)
        guard resolved.source == "default" else { return [] }
        let target = resolved.url
        let legacy = legacyDefaultRoot(dataDirectory: dataDirectory)
        guard legacy.standardizedFileURL != target.standardizedFileURL else { return [] }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        var moved: [String] = []
        for child in (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? [] {
            let id = child.lastPathComponent
            guard !id.hasPrefix(".") else { continue }
            guard fm.fileExists(atPath: child.appending(path: "installed.json").path) else { continue }
            let destination = directory(root: target, id: id)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.moveItem(at: child, to: destination)
            moved.append(id)
        }
        let leftovers = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        let onlyHidden = !leftovers.contains { !$0.lastPathComponent.hasPrefix(".") }
        if onlyHidden, !moved.isEmpty || leftovers.isEmpty {
            try? fm.removeItem(at: legacy)
        }
        return moved.sorted()
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
                installedAt: now, verifiedAt: now, catalogSchemaVersion: schemaVersion,
                linkedPath: nil, linkedFileCount: nil, linkedTotalBytes: nil),
            root: root, id: model.id)
        return ImportReport(directory: final, totalBytes: total, fileCount: model.files.count,
                            seconds: Date().timeIntervalSince(t0))
    }

    // MARK: - 联网下载（D30：用户批准 Qwen3-Embedding 全系列可从 Hugging Face 下载）

    /// 下载清单里的一个模型。走已有的 `HFDownloader`：先探直连与镜像选源、HTTP Range 断点续传、
    /// 逐文件 sha256，全部通过后整目录原子移动，最后写 `installed.json`。
    ///
    /// 三道闸：必须是清单里的可下载项、必须属于已批准的家族（`Catalog.isApprovedID`）、
    /// 必须过本机内存判定。`onProgress` 每下完一个文件回调一次（界面画进度）。
    @discardableResult
    public static func downloadModel(
        _ model: CatalogModel, root: URL, schemaVersion: Int,
        primary: String = HFDownloader.defaultPrimary,
        mirror: String = HFDownloader.defaultMirror,
        forcedBase: String? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onFileStart: (@Sendable (_ file: String, _ bytes: Int64, _ index: Int,
                                 _ totalFiles: Int) -> Void)? = nil,
        onProgress: (@Sendable (_ file: String, _ doneFiles: Int, _ totalFiles: Int,
                                _ doneBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> DownloadReport {
        guard model.source == "huggingface", let revision = model.revision, !model.files.isEmpty else {
            throw ModelsError("\(model.id) 不是可下载项（source=\(model.source)），"
                            + "用「从本地目录导入」或「关联外部目录」")
        }
        guard model.isApproved else {
            throw ModelsError("\(model.id) 不在已批准的模型家族里（D30 只放行 Qwen3-Embedding 系列）")
        }
        guard model.fitsThisMachine else {
            throw ModelsError(model.unavailableReason ?? "本机内存不够")
        }
        let downloader = HFDownloader()
        let smallest = model.files.min { $0.size < $1.size }!.path
        var probes: [MirrorProbe] = []
        var base = forcedBase ?? primary
        if forcedBase == nil {
            (base, probes) = await downloader.chooseBase(
                primary: primary, mirror: mirror, repoId: model.repoId,
                revision: revision, smallFile: smallest)
        }
        // staging 按 id 固定、**不清空**：E9 验收发现断点续传必须跨进程，.part 要能复用。
        let staging = try stagingDirectory(root: root, id: model.id)
        let totalBytes = model.files.reduce(Int64(0)) { $0 + $1.size }
        var stats: [FileDownloadStat] = []
        var doneBytes: Int64 = 0
        let started = Date()
        // 小文件先下：早失败早报错，也让进度条一开始就动。
        for (index, file) in model.files.sorted(by: { $0.size < $1.size }).enumerated() {
            if isCancelled() { throw ModelsError("已取消（已下好的部分留在暂存目录，下次继续）") }
            // 单个文件内部没有细粒度进度：URLSession 先把整个响应下到临时文件，下完才 append 到 .part。
            // 权重是一个 2–4 GiB 的大文件，所以**开始下之前先报一声**，界面才不会看着像卡住。
            onFileStart?(file.path, file.size, index + 1, model.files.count)
            let stat = try await downloader.downloadFile(
                base: base, repoId: model.repoId, revision: revision,
                file: file, stagingDir: staging)
            stats.append(stat)
            doneBytes += file.size
            onProgress?(file.path, stats.count, model.files.count, doneBytes, totalBytes)
        }
        // 再整体核一遍 sha256：与本地导入同一把尺子，防止 .part 复用出错。
        try verify(model: model, in: staging)
        let final = try commit(staging: staging, root: root, id: model.id)
        let now = ISO8601DateFormatter().string(from: Date())
        try writeRecord(
            InstalledRecord(
                id: model.id, repoId: model.repoId, revision: revision,
                source: "huggingface", baseURLUsed: base, importedFrom: nil,
                totalBytes: doneBytes, fileCount: model.files.count,
                installedAt: now, verifiedAt: now, catalogSchemaVersion: schemaVersion,
                linkedPath: nil, linkedFileCount: nil, linkedTotalBytes: nil),
            root: root, id: model.id)
        return DownloadReport(baseUsed: base, probes: probes, files: stats,
                              totalBytes: doneBytes,
                              totalSeconds: Date().timeIntervalSince(started),
                              installedAt: final)
    }

    // MARK: - 关联外部目录（D30「也可以关联到别的目录，比如 LM Studio 的目录」）

    /// 权重真正在哪：关联的模型指向外部目录，其余就是模型根目录下的同名子目录。
    /// **所有加载模型的地方都要走这个函数**，不能再直接用 `directory(root:id:)`。
    public static func weightsDirectory(root: URL, id: String) -> URL {
        if let record = record(root: root, id: id), record.isLinked,
           let path = record.linkedPath {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return directory(root: root, id: id)
    }

    /// 外部目录的体检结果。
    public struct ExternalModelInfo: Sendable {
        public var modelType: String
        public var hiddenSize: Int
        public var quantizationBits: Int?
        public var fileCount: Int
        public var totalBytes: Int64
        public var weightFiles: Int
    }

    /// 体检一个外部模型目录。**不逐文件 sha256**——外部目录（LM Studio 等）的量化版本、
    /// 文件集合本来就和随包清单不一样，硬比哈希会把能用的目录也拒掉。改成结构校验：
    /// 架构认得出、隐藏维度够截、权重与分词器齐。校验不过一律抛可读的中文原因。
    public static func inspectExternal(directory dir: URL,
                                       minimumDimension: Int) throws -> ExternalModelInfo {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ModelsError("目录不存在：\(dir.path)")
        }
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        guard names.contains("config.json") else {
            throw ModelsError("这个目录里没有 config.json，不像是一个 MLX 模型目录")
        }
        let safetensors = names.filter { $0.hasSuffix(".safetensors") }
        if safetensors.isEmpty {
            if names.contains(where: { $0.hasSuffix(".gguf") }) {
                throw ModelsError("这是 GGUF 格式（llama.cpp / LM Studio 的默认下载格式），"
                                + "brosis 用的是 mlx-swift，只能加载 MLX 的 safetensors 权重。"
                                + "在 LM Studio 里下 MLX 版本，或用清单里的模型联网下载。")
            }
            throw ModelsError("目录里没有 .safetensors 权重文件")
        }
        guard names.contains("tokenizer.json") || names.contains("tokenizer_config.json") else {
            throw ModelsError("目录里没有 tokenizer.json / tokenizer_config.json")
        }
        let configData = try Data(contentsOf: dir.appending(path: "config.json"))
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw ModelsError("config.json 解析不了")
        }
        guard let modelType = config["model_type"] as? String else {
            throw ModelsError("config.json 里没有 model_type")
        }
        guard let hidden = config["hidden_size"] as? Int else {
            throw ModelsError("config.json 里没有 hidden_size，判断不了向量维度")
        }
        guard hidden >= minimumDimension else {
            throw ModelsError("这个模型原生 \(hidden) 维，低于本项目统一的 \(minimumDimension) 维，"
                            + "没法 MRL 截断到统一维度；换一个更大的模型")
        }
        var total: Int64 = 0
        for name in names {
            let u = dir.appending(path: name)
            if let size = try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64 { total += size }
        }
        let bits = (config["quantization"] as? [String: Any])?["bits"] as? Int
        return ExternalModelInfo(modelType: modelType, hiddenSize: hidden, quantizationBits: bits,
                                 fileCount: names.count, totalBytes: total,
                                 weightFiles: safetensors.count)
    }

    /// 关联外部目录：**一个字节都不复制**，只在模型根目录下写一个只含 installed.json 的标记目录。
    /// `id` 默认取外部目录名（LM Studio 的目录名就是仓库名）。
    /// 之后 `weightsDirectory` 会把加载路径指过去；外部目录被删 / 被改，
    /// `entries` 里这一项会显示为「关联失效」，向量检索按 3.11 降级为未启用。
    @discardableResult
    public static func linkExternal(id: String, from dir: URL, root: URL,
                                    minimumDimension: Int,
                                    schemaVersion: Int,
                                    repoId: String? = nil) throws -> ExternalModelInfo {
        let info = try inspectExternal(directory: dir, minimumDimension: minimumDimension)
        let fm = FileManager.default
        let marker = directory(root: root, id: id)
        // 已经有一份**复制进来的**同名模型时不许覆盖：那是几 GiB 的权重，只能由用户显式「移除」。
        if let existing = record(root: root, id: id), !existing.isLinked {
            throw ModelsError("\(id) 已经在模型目录里装着（复制的那份），先移除再关联")
        }
        try? fm.removeItem(at: marker)
        try fm.createDirectory(at: marker, withIntermediateDirectories: true)
        let now = ISO8601DateFormatter().string(from: Date())
        try writeRecord(
            InstalledRecord(
                id: id, repoId: repoId ?? "（外部目录）", revision: nil,
                source: "linked", baseURLUsed: nil, importedFrom: nil,
                totalBytes: info.totalBytes, fileCount: info.fileCount,
                installedAt: now, verifiedAt: now, catalogSchemaVersion: schemaVersion,
                linkedPath: dir.path, linkedFileCount: info.fileCount,
                linkedTotalBytes: info.totalBytes),
            root: root, id: id)
        return info
    }

    /// 关联是否还有效（外部目录还在、结构还对）。返回 nil 表示有效，否则是原因。
    public static func linkedProblem(root: URL, id: String, minimumDimension: Int) -> String? {
        guard let record = record(root: root, id: id), record.isLinked,
              let path = record.linkedPath else { return nil }
        do {
            let info = try inspectExternal(directory: URL(filePath: path, directoryHint: .isDirectory),
                                           minimumDimension: minimumDimension)
            if let was = record.linkedTotalBytes, was != info.totalBytes {
                return "关联的目录变了（当时 \(ModelBytes.human(was))，现在 \(ModelBytes.human(info.totalBytes))）"
            }
            return nil
        } catch {
            return "关联失效：\(error)"
        }
    }

    /// 删除一个已装模型（界面上的"移除"）。
    /// 关联的模型只删模型根目录下那个标记目录，**外部目录一个字节都不动**。
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
        /// D30：关联外部目录的那种（权重不在模型根目录里）。
        public var linkedPath: String?
        /// 关联失效 / 外部目录被动过时的原因，nil 表示没问题。
        public var linkProblem: String?
        /// 在不在随包清单里。关联进来的外部模型可能不在（界面上标「未验证」）。
        public var inCatalog: Bool = true

        public var isLinked: Bool { linkedPath != nil }
        /// 能不能真的拿来跑：装着、且（如果是关联的）关联还有效。
        public var usable: Bool { installed && linkProblem == nil }
    }

    /// 模型根目录里所有装着或关联着的模型 id（含不在随包清单里的），按名字排序。
    public static func installedIDs(root: URL) -> [String] {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(".") }
            .filter { fm.fileExists(atPath: directory(root: root, id: $0)
                                        .appending(path: "installed.json").path) }
            .sorted()
    }

    /// 清单 × 已装状态，供"模型"面板与 `--self-check` 直接渲染。
    ///
    /// D30 起还会把**清单里没有、但已经关联进来的**外部模型追加在后面（标 `inCatalog = false`），
    /// 否则用户关联了 LM Studio 的目录之后面板上看不见它。
    public static func entries(catalog: Catalog, root: URL,
                               minimumDimension: Int = 0) -> [Entry] {
        var out: [Entry] = catalog.models.map { m in
            entry(id: m.id, model: m, root: root, minimumDimension: minimumDimension)
        }
        let known = Set(catalog.models.map(\.id))
        for id in installedIDs(root: root) where !known.contains(id) {
            out.append(entry(id: id, model: nil, root: root, minimumDimension: minimumDimension))
        }
        return out
    }

    private static func entry(id: String, model: CatalogModel?, root: URL,
                              minimumDimension: Int) -> Entry {
        let installed = isInstalled(root: root, id: id)
        let record = installed ? record(root: root, id: id) : nil
        let linkedPath = record?.isLinked == true ? record?.linkedPath : nil
        let problem = linkedPath == nil ? nil
            : linkedProblem(root: root, id: id, minimumDimension: minimumDimension)
        let disk: Int64 = {
            guard installed else { return 0 }
            if let linkedPath { return record?.linkedTotalBytes ?? directorySize(URL(filePath: linkedPath)) }
            return directorySize(directory(root: root, id: id))
        }()
        return Entry(id: id,
                     purpose: model?.purpose ?? "embedding",
                     installed: installed,
                     approved: model?.isApproved ?? Catalog.isApprovedID(id),
                     sizeBytes: model?.totalBytes ?? record?.totalBytes ?? 0,
                     diskBytes: disk,
                     minRAMBytes: model?.minRAMBytes,
                     unavailableReason: model?.unavailableReason,
                     note: model?.note ?? (linkedPath.map { "关联的外部目录：\($0)" }
                                           ?? "不在随包清单里（未验证）"),
                     installedAt: record?.installedAt,
                     source: record?.source,
                     linkedPath: linkedPath,
                     linkProblem: problem,
                     inCatalog: model != nil)
    }
}
