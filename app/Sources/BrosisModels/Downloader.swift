import Foundation

// =============================================================================
// 模型下载器（计划 3.11 / D18）
//
// 逐字搬自 tools/e9/Sources/brosis-e9/Downloader.swift，只做三处改动：
//   1. public 化，并把 staging 目录改成由调用方传入（`ModelStore.stagingDirectory` 按 id 固定，
//      E9 验收发现「断点续传必须跨进程」）；
//   2. `E9Error` -> `ModelsError`、`Bytes` -> `ModelBytes`、`log` -> `ModelLog.line`；
//   3. 进度写 `ModelLog`（app 里接菜单栏，命令行里写 stderr）。
// 要求不变：URLSession 实现、尊重系统代理、HTTP Range 断点续传、可配置镜像源、
// 逐文件 sha256 校验后整目录原子移动。
//
// **本轮（M2 c / T11）没有跑过任何下载**：两个模型是用户此前已批准并下载好的，
// 走的是 `ModelStore.importLocal`（本地导入 + 重新校验 sha256）。
// 这份代码与 E9 实测过的那份逐字相同，数字见 tools/bench/results/e9_air_2026-09-07.md。
// =============================================================================

public struct MirrorProbe: Sendable {
    public let base: String
    public let ok: Bool
    public let seconds: Double
    public let note: String
}

public struct FileDownloadStat: Sendable {
    public let path: String
    public let bytes: Int64
    public let seconds: Double
    public let resumedFromBytes: Int64
    /// 服务器对带 Range 的请求返回的状态码（206 = 支持断点续传）
    public let rangeStatus: Int?
    public let sha256OK: Bool
    public let sha256: String
}

public struct DownloadReport: Sendable {
    public let baseUsed: String
    public let probes: [MirrorProbe]
    public let files: [FileDownloadStat]
    public let totalBytes: Int64
    public let totalSeconds: Double
    public let installedAt: URL
}

public actor HFDownloader {
    public static let defaultPrimary = "https://huggingface.co"
    public static let defaultMirror = "https://hf-mirror.com"

    private let session: URLSession

    public init() {
        let cfg = URLSessionConfiguration.default
        // 不设 connectionProxyDictionary，URLSession 默认就走系统代理（scutil --proxy）
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = true
        cfg.httpAdditionalHeaders = ["User-Agent": "brosis/1.0 (macOS; MLX)"]
        session = URLSession(configuration: cfg)
    }

    /// 拼出权重文件的下载地址。**不强解包**：base 由用户填（镜像源、公司代理），
    /// 拼不出合法 URL 时要报错而不是让 app 崩。
    private func resolveURL(base: String, repoId: String, revision: String,
                            path: String) throws -> URL {
        let text = "\(base)/\(repoId)/resolve/\(revision)/\(path)"
        guard let url = URL(string: text) else {
            throw ModelsError("拼不出合法的下载地址（base = \(base)）")
        }
        return url
    }

    /// 探测一个源：拿仓库里最小的一个文件，量首字节到完成的耗时。
    public func probe(base: String, repoId: String, revision: String, smallFile: String) async -> MirrorProbe {
        guard let url = try? resolveURL(base: base, repoId: repoId,
                                        revision: revision, path: smallFile) else {
            return MirrorProbe(base: base, ok: false, seconds: 0, note: "地址拼不出来")
        }
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
    public func chooseBase(
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
    public func downloadFile(
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
        let url = try resolveURL(base: base, repoId: repoId, revision: revision,
                                 path: file.path)
        let t0 = Date()

        // 第一步（可选）：制造一个"下了一半断掉"的现场
        if simulateInterruptBytes > 0, currentSize(part) == 0 {
            var req = URLRequest(url: url)
            req.setValue("bytes=0-\(simulateInterruptBytes - 1)", forHTTPHeaderField: "Range")
            let (tmp, resp) = try await session.download(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 206 || code == 200 else {
                throw ModelsError("模拟中断请求失败：HTTP \(code) \(url.absoluteString)")
            }
            try append(tmp, to: part, limit: simulateInterruptBytes)
            try? fm.removeItem(at: tmp)
            ModelLog.line("  模拟中断：\(file.path) 已写入 \(ModelBytes.mibString(currentSize(part)))，接下来走 Range 续传")
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
                ModelLog.line("  \(file.path)：服务器忽略 Range（HTTP 200），从头下载")
                try truncate(part)
                resumedFrom = 0
            }
            guard code == 200 || code == 206 else {
                try? fm.removeItem(at: tmp)
                throw ModelsError("下载失败：HTTP \(code) \(url.absoluteString)")
            }
            try append(tmp, to: part, limit: nil)
            try? fm.removeItem(at: tmp)
        }

        let got = currentSize(part)
        guard got == file.size else {
            throw ModelsError("\(file.path) 字节数不符：得到 \(got)，清单写的是 \(file.size)")
        }
        let digest = try ModelHashing.sha256(ofFileAt: part)
        guard digest == file.sha256 else {
            throw ModelsError("\(file.path) sha256 不符：得到 \(digest)，清单写的是 \(file.sha256)")
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

// MARK: - 日志

/// 下载器与导入过程的进度行。app 里接到菜单状态，命令行里写 stderr。
public enum ModelLog {
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)?
    public static func line(_ s: String) {
        if let sink { sink(s) } else { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    }
}
