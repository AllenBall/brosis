// brosis M0 · E9：模型推荐清单（计划 3.11 D18）
//
// 清单随 app 打包、随 app 更新，运行时不联网拉清单。
// 每项含用途、Hugging Face 仓库与固定 revision、文件列表与 SHA-256、磁盘大小、最低内存。

import Foundation

struct CatalogFile: Codable, Sendable {
    let path: String
    let size: Int64
    let sha256: String
    /// "lfs-oid"：HF API tree 里 LFS 的 oid 本身就是 sha256；"downloaded"：小文件由生成脚本下载后自算
    let sha256Source: String?
}

struct CatalogModel: Codable, Sendable {
    let id: String
    /// embedding / generation
    let purpose: String
    /// huggingface / local-import
    let source: String
    let repoId: String
    let revision: String?
    let quantization: String?
    let totalBytes: Int64?
    let minRAMBytes: Int64?
    let files: [CatalogFile]
    let note: String?

    /// 本机内存是否够（不够就置灰，计划 3.11）
    var fitsThisMachine: Bool {
        guard let minRAMBytes else { return true }
        return Int64(Proc.physicalMemory) >= minRAMBytes
    }
}

struct Catalog: Codable, Sendable {
    let schemaVersion: Int
    let generatedAt: String?
    let note: String?
    let models: [CatalogModel]

    static func load() throws -> Catalog {
        guard let url = Resources.url(named: "catalog.json") else {
            throw E9Error.message("找不到 catalog.json（试过 Bundle.main、可执行文件同目录、SwiftPM 资源 bundle）")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    func model(id: String) throws -> CatalogModel {
        guard let m = models.first(where: { $0.id == id }) else {
            throw E9Error.message("清单里没有 id = \(id)；已有：\(models.map(\.id).joined(separator: ", "))")
        }
        return m
    }
}

enum E9Error: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): m }
    }
    var localizedDescription: String { description }
}
