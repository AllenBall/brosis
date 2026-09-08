import Foundation

// =============================================================================
// 模型推荐清单（计划 3.11 / D18）
//
// 由 tools/e9 的 `Catalog.swift` 搬进产品，改动只有三处，其余逐字保留：
//   1. 换成 public API（app 与 brosis-embed 两个目标都要用）；
//   2. 清单文件的查找顺序换成 `ModelResources`（`.app/Contents/Resources` 优先，
//      `Bundle.module` 只在确认不会 fatalError 时才碰——见 ModelsUtil.swift 的头注释）；
//   3. `fitsThisMachine` 之外再给一个 `unavailableReason`，界面上要显示"为什么置灰"。
//
// 清单**随 app 打包、随 app 更新，运行时不联网拉清单**（3.11）。
// 文件本身是 tools/e9/catalog.json 的副本（`Support/gen_catalog.py` 用 HF 只读 API 生成，
// 含每个文件的 sha256），换模型必须改这份文件并重新发版，不能在运行时改。
// =============================================================================

public struct CatalogFile: Codable, Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String
    /// `lfs-oid`：HF API tree 里 LFS 的 oid 本身就是 sha256；`downloaded`：小文件由生成脚本下载后自算。
    public let sha256Source: String?
}

public struct CatalogModel: Codable, Sendable {
    public let id: String
    /// `embedding` / `generation`
    public let purpose: String
    /// `huggingface` / `local-import`
    public let source: String
    public let repoId: String
    public let revision: String?
    public let quantization: String?
    public let totalBytes: Int64?
    public let minRAMBytes: Int64?
    public let files: [CatalogFile]
    public let note: String?

    /// 本机内存够不够（不够就置灰，计划 3.11）。
    public var fitsThisMachine: Bool {
        guard let minRAMBytes else { return true }
        return Int64(ProcessInfo.processInfo.physicalMemory) >= minRAMBytes
    }

    /// 置灰的原因，没有就返回 nil。界面上直接显示这句话。
    public var unavailableReason: String? {
        if !fitsThisMachine, let minRAMBytes {
            return "本机内存 \(ModelBytes.human(ProcessInfo.processInfo.physicalMemory))"
                 + "，低于该模型要求的 \(ModelBytes.human(minRAMBytes))"
        }
        if files.isEmpty {
            return "清单里没有文件列表，只能从本地目录导入（E9 验收：files 为空时导入必须拒绝）"
        }
        return nil
    }

    /// 这一项是不是本项目**已批准**的模型。
    /// 计划 3.11 允许"高级入口手填任意 HF 仓库 id"，但那条路标记为未验证。
    /// D30 起批准的是**整个 Qwen3-Embedding 家族**（多个尺寸可下载、可切换），不再是写死的两个 id。
    public var isApproved: Bool { Catalog.isApprovedID(id) }
}

public struct Catalog: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String?
    public let note: String?
    public let models: [CatalogModel]

    /// 用户已批准的模型家族（D30，2026-09-08）：**Qwen3-Embedding 全系列**，
    /// 允许联网下载、允许在面板里切换尺寸。0.6B 由用户决定去掉（太小），清单里不再列。
    /// D29 之后清单里没有生成模型；`Catalog.generationModelID` 只留给休眠的叙述代码引用。
    public static let approvedPrefixes: [String] = ["Qwen3-Embedding-"]

    public static func isApprovedID(_ id: String) -> Bool {
        approvedPrefixes.contains { id.hasPrefix($0) }
    }

    public static func load() throws -> Catalog {
        guard let url = ModelResources.url(named: "catalog.json") else {
            // **抛错，不 fatalError**：清单缺失只该让模型相关功能显示「未启用」（3.11 降级表），
            // 不该杀掉进程。消息里把真正试过的目录逐条列出来，好定位是打包漏了哪一步。
            throw ModelsError(ModelResources.notFoundMessage(named: "catalog.json"))
        }
        return try JSONDecoder().decode(Catalog.self, from: try Data(contentsOf: url))
    }

    public func model(id: String) throws -> CatalogModel {
        guard let m = models.first(where: { $0.id == id }) else {
            throw ModelsError("清单里没有 id = \(id)；已有：\(models.map(\.id).joined(separator: ", "))")
        }
        return m
    }

    /// 清单里的全部嵌入模型，按清单顺序（面板按这个顺序显示；小的排前面）。
    public var embeddingModels: [CatalogModel] { models.filter { $0.purpose == "embedding" } }

    /// 兜底用的"默认嵌入模型"＝清单里第一个。真正生效的是 `EmbeddingSelection.effectiveID`。
    public var embeddingModel: CatalogModel? { embeddingModels.first }
}

/// 当前生效的嵌入模型（D30：清单里有多个尺寸，用户可以在面板里切换）。
///
/// **向量不能跨模型比较**：换模型等于整个向量索引作废，所以切换动作必须伴随一次
/// `Store.rebuildEmbeddings()`（面板负责问一句再做）。库里的 `meta.embed_model`
/// 记着索引是用哪个模型建的，检索侧据此判断索引是不是过期。
public enum EmbeddingSelection {

    /// UserDefaults 键，写模型 id。没写过就按"第一个装着的"推断。
    public static let defaultsKey = "models.embedding.current"

    public static func selectedID(_ defaults: UserDefaults = .standard) -> String? {
        let v = defaults.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespaces)
        return (v?.isEmpty == false) ? v : nil
    }

    public static func select(_ id: String?, defaults: UserDefaults = .standard) {
        if let id, !id.isEmpty { defaults.set(id, forKey: defaultsKey) }
        else { defaults.removeObject(forKey: defaultsKey) }
    }

    /// 装着（或关联着）的嵌入模型 id：清单里的 + 关联进来的清单外的。
    public static func installedIDs(catalog: Catalog?, root: URL?) -> [String] {
        guard let root else { return [] }
        let catalogIDs = (catalog?.embeddingModels.map(\.id)) ?? []
        let onDisk = ModelStore.installedIDs(root: root)
        // 清单顺序优先，清单外的按名字排在后面。
        return catalogIDs.filter(onDisk.contains) + onDisk.filter { !catalogIDs.contains($0) }
    }

    /// 实际生效的模型 id。顺序：用户选过且它还装着 → 第一个装着的 → 用户选过的（还没装）→ 清单第一个。
    /// 返回 nil 表示一个嵌入模型都没有（向量检索显示未启用，3.11 降级表）。
    public static func effectiveID(catalog: Catalog?, root: URL?,
                                   defaults: UserDefaults = .standard) -> String? {
        let installed = installedIDs(catalog: catalog, root: root)
        if let chosen = selectedID(defaults), installed.contains(chosen) { return chosen }
        if let first = installed.first { return first }
        return selectedID(defaults) ?? catalog?.embeddingModel?.id
    }
}

public struct ModelsError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
    public var localizedDescription: String { description }
}
