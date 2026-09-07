// brosis M0 · E9：模型目录管理（计划 3.11）
//
// 存放：~/Library/Application Support/brosis-m0/models/<id>/
// 安装完写 installed.json（revision、字节、时间、来源）。
// 另有"本地导入"：从任意目录复制进来，同样逐文件校验 sha256。

import Foundation

struct InstalledRecord: Codable, Sendable {
    let id: String
    let repoId: String
    let revision: String?
    /// huggingface / local-import
    let source: String
    let baseURLUsed: String?
    let importedFrom: String?
    let totalBytes: Int64
    let fileCount: Int
    let installedAt: String
    let verifiedAt: String
    let catalogSchemaVersion: Int
}

enum ModelStore {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["BROSIS_E9_MODELS"] {
            return URL(filePath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/brosis-m0/models")
    }

    static func directory(for id: String) -> URL { root.appending(path: id) }

    static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: id).appending(path: "installed.json").path)
    }

    static func record(for id: String) -> InstalledRecord? {
        let u = directory(for: id).appending(path: "installed.json")
        guard let data = try? Data(contentsOf: u) else { return nil }
        return try? JSONDecoder().decode(InstalledRecord.self, from: data)
    }

    static func stagingDirectory(for id: String) throws -> URL {
        let u = root.appending(path: ".staging-\(id)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 把 staging 整目录原子换到最终位置：先搬走旧的，再搬入新的，最后删旧的。
    static func commit(staging: URL, to id: String) throws -> URL {
        let fm = FileManager.default
        let final = directory(for: id)
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

    static func writeRecord(_ r: InstalledRecord, id: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(r).write(to: directory(for: id).appending(path: "installed.json"), options: .atomic)
    }

    /// 逐文件核对清单里的 sha256。
    @discardableResult
    static func verify(model: CatalogModel, in dir: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for f in model.files {
            let u = dir.appending(path: f.path)
            guard FileManager.default.fileExists(atPath: u.path) else {
                throw E9Error.message("缺文件：\(f.path)")
            }
            let size = (try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? -1
            guard size == f.size else {
                throw E9Error.message("\(f.path) 字节数不符：\(size) != \(f.size)")
            }
            let d = try Hashing.sha256(ofFileAt: u)
            guard d == f.sha256 else {
                throw E9Error.message("\(f.path) sha256 不符：\(d) != \(f.sha256)")
            }
            digests[f.path] = d
        }
        return digests
    }

    /// 本地导入：从 from 目录复制清单里列出的文件到 staging，校验后提交。
    /// 只复制不引用，避免外部目录变动影响（计划 3.11）。
    static func importLocal(model: CatalogModel, from: URL, schemaVersion: Int) throws -> (URL, Int64, Double) {
        let fm = FileManager.default
        let t0 = Date()
        let staging = try stagingDirectory(for: model.id)
        var total: Int64 = 0
        for f in model.files {
            let src = from.appending(path: f.path)
            guard fm.fileExists(atPath: src.path) else {
                try? fm.removeItem(at: staging)
                throw E9Error.message("源目录缺文件：\(src.path)")
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
        let final = try commit(staging: staging, to: model.id)
        let now = ISO8601DateFormatter().string(from: Date())
        try writeRecord(
            InstalledRecord(
                id: model.id, repoId: model.repoId, revision: model.revision,
                source: "local-import", baseURLUsed: nil, importedFrom: from.path,
                totalBytes: total, fileCount: model.files.count,
                installedAt: now, verifiedAt: now, catalogSchemaVersion: schemaVersion),
            id: model.id)
        return (final, total, Date().timeIntervalSince(t0))
    }

    static func directorySize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}
