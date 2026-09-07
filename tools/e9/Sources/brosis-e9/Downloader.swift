// brosis M0 · E9：模型下载器（计划 3.11）
//
// 要求：
//   - URLSession 实现，尊重系统代理（默认 URLSessionConfiguration 就会读系统代理设置）
//   - 支持 HTTP Range 断点续传
//   - 可配置镜像 base URL：默认直连 huggingface.co，探测失败或明显慢时切 hf-mirror.com
//   - 下载到临时目录，逐文件校验 sha256 后整目录原子移动到模型目录

import Foundation

struct MirrorProbe: Sendable {
    let base: String
    let ok: Bool
    let seconds: Double
    let note: String
}

struct FileDownloadStat: Sendable {
    let path: String
    let bytes: Int64
    let seconds: Double
    let resumedFromBytes: Int64
    /// 服务器对带 Range 的请求返回的状态码（206 = 支持断点续传）
    let rangeStatus: Int?
    let sha256OK: Bool
    let sha256: String
}

struct DownloadReport: Sendable {
    let baseUsed: String
    let probes: [MirrorProbe]
    let files: [FileDownloadStat]
    let totalBytes: Int64
    let totalSeconds: Double
    let installedAt: URL
}

actor HFDownloader {
    static let defaultPrimary = "https://huggingface.co"
    static let defaultMirror = "https://hf-mirror.com"

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        // 不设 connectionProxyDictionary，URLSession 默认就走系统代理（scutil --proxy）
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = ["User-Agent": "brosis-e9/0.1 (macOS; MLX)"]
        session = URLSession(configuration: cfg)
    }

    private func resolveURL(base: String, repoId: String, revision: String, path: String) -> URL {
        URL(string: "\(base)/\(repoId)/resolve/\(revision)/\(path)")!
    }

    /// 探测一个源：拿仓库里最小的一个文件，量首字节到完成的耗时。
    func probe(base: String, repoId: String, revision: String, smallFile: String) async -> MirrorProbe {
        let url = resolveURL(base: base, repoId: repoId, revision: revision, path: smallFile)
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let dt = Date().timeIntervalSince(t0)
            return MirrorProbe(
                base: base, ok: (200...299).contains(code), seconds: dt,
                note: "HTTP \(code)，\(data.count) 字节")
        } catch {
            return MirrorProbe(
                base: base, ok: false, seconds: Date().timeIntervalSince(t0),
                note: "失败：\(error.localizedDescription)")
        }
    }

    /// 选源：直连能用且不比镜像慢 3 倍以上就用直连，否则用镜像。
    func chooseBase(
        primary: String, mirror: String, repoId: String, revision: String, smallFile: String
    ) async -> (String, [MirrorProbe]) {
        let p = await probe(base: primary, repoId: repoId, revision: revision, smallFile: smallFile)
        let m = await probe(base: mirror, repoId: repoId, revision: revision, smallFile: smallFile)
        let probes = [p, m]
        if p.ok, !m.ok { return (primary, probes) }
        if !p.ok, m.ok { return (mirror, probes) }
        if !p.ok, !m.ok { return (primary, probes) }  // 都不通，交给后面报错
        return (p.seconds <= m.seconds * 3 ? primary : mirror, probes)
    }

    /// 下载单个文件到 dest（支持从已有 .part 续传），校验 sha256。
    /// simulateInterruptBytes > 0 时先只取前 N 字节写进 .part，再走正常续传路径，用来实测 Range。
    func downloadFile(
        base: String, repoId: String, revision: String, file: CatalogFile,
        stagingDir: URL, simulateInterruptBytes: Int64 = 0
    ) async throws -> FileDownloadStat {
        let fm = FileManager.default
        let dest = stagingDir.appending(path: file.path)
        try fm.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.appendingPathExtension("part")
        if !fm.fileExists(atPath: part.path) {
            fm.createFile(atPath: part.path, contents: nil)
        }
        let url = resolveURL(base: base, repoId: repoId, revision: revision, path: file.path)
        let t0 = Date()

        // 第一步（可选）：制造一个"下了一半断掉"的现场
        if simulateInterruptBytes > 0, currentSize(part) == 0 {
            var req = URLRequest(url: url)
            req.setValue("bytes=0-\(simulateInterruptBytes - 1)", forHTTPHeaderField: "Range")
            let (tmp, resp) = try await session.download(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 206 || code == 200 else {
                throw E9Error.message("模拟中断请求失败：HTTP \(code) \(url.absoluteString)")
            }
            try append(tmp, to: part, limit: simulateInterruptBytes)
            try? fm.removeItem(at: tmp)
            log("  模拟中断：\(file.path) 已写入 \(Bytes.mibString(currentSize(part)))，接下来走 Range 续传")
        }

        var resumedFrom = currentSize(part)
        var rangeStatus: Int? = nil

        if resumedFrom < file.size {
            var req = URLRequest(url: url)
            if resumedFrom > 0 {
                req.setValue("bytes=\(resumedFrom)-", forHTTPHeaderField: "Range")
            }
            let (tmp, resp) = try await session.download(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            if resumedFrom > 0 { rangeStatus = code }
            if resumedFrom > 0, code == 200 {
                // 服务器忽略了 Range，只能从头再来
                log("  \(file.path)：服务器忽略 Range（HTTP 200），从头下载")
                try truncate(part)
                resumedFrom = 0
            }
            guard code == 200 || code == 206 else {
                try? fm.removeItem(at: tmp)
                throw E9Error.message("下载失败：HTTP \(code) \(url.absoluteString)")
            }
            try append(tmp, to: part, limit: nil)
            try? fm.removeItem(at: tmp)
        }

        let got = currentSize(part)
        guard got == file.size else {
            throw E9Error.message("\(file.path) 字节数不符：得到 \(got)，清单写的是 \(file.size)")
        }
        let digest = try Hashing.sha256(ofFileAt: part)
        guard digest == file.sha256 else {
            throw E9Error.message("\(file.path) sha256 不符：得到 \(digest)，清单写的是 \(file.sha256)")
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: part, to: dest)
        return FileDownloadStat(
            path: file.path, bytes: file.size, seconds: Date().timeIntervalSince(t0),
            resumedFromBytes: resumedFrom, rangeStatus: rangeStatus, sha256OK: true, sha256: digest)
    }

    // MARK: - 文件小工具

    private func currentSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
    }

    private func truncate(_ url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.truncate(atOffset: 0)
    }

    private func append(_ src: URL, to dst: URL, limit: Int64?) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        try out.seekToEnd()
        var written: Int64 = 0
        while true {
            if let limit, written >= limit { break }
            var want = 8 << 20
            if let limit { want = Swift.min(want, Int(limit - written)) }
            // 同 Hashing.sha256：每块包 autoreleasepool，否则整个文件会攒在自动释放池里
            //（2026-09-07 Air 实测：下载 2.8 GiB 模型时 peak footprint 5.8 GiB）。
            let n: Int = try autoreleasepool {
                guard let chunk = try input.read(upToCount: want), !chunk.isEmpty else { return 0 }
                try out.write(contentsOf: chunk)
                return chunk.count
            }
            if n == 0 { break }
            written += Int64(n)
        }
    }
}
