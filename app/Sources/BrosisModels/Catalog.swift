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
    /// 计划 3.11 允许"高级入口手填任意 HF 仓库 id"，但那条路标记为未验证；
    /// 本轮（M2 c）只放行清单里这两项，界面上其余项一律置灰。
    public var isApproved: Bool { Catalog.approvedIDs.contains(id) }
}

public struct Catalog: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String?
    public let note: String?
    public let models: [CatalogModel]

    /// 用户已批准、已下载的模型。
    /// 2026-09-08 起只剩嵌入模型：用户决定不要叙述功能，生成模型（D19 的 Qwen3.5-4B）
    /// 连同清单条目一起去掉，`Catalog.generationModelID` 只留给休眠的叙述代码引用。
    public static let approvedIDs: Set<String> = ["Qwen3-Embedding-0.6B-8bit"]

    /// 嵌入模型的固定 id（3.4「模型固定为 Qwen3-Embedding-0.6B」）。
    public static let embeddingModelID = "Qwen3-Embedding-0.6B-8bit"

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

    public var embeddingModel: CatalogModel? {
        models.first { $0.id == Catalog.embeddingModelID }
    }
}

public struct ModelsError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
    public var localizedDescription: String { description }
}
