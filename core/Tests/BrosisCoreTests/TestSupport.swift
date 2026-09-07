import Foundation
import XCTest
@testable import BrosisCore

/// 测试夹具：每个用例一个独立的临时目录（在 `~/Library/Caches/brosis-build/m1-core-tests/` 下，
/// 不落项目目录），用完删掉。密钥用 `InMemoryKeyProvider`，不碰钥匙串、不弹授权。
final class Fixture {
    let root: URL
    let dataDirectory: URL
    let keyProvider: InMemoryKeyProvider
    private(set) var store: Store!

    static var testRoot: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/brosis-build/m1-core-tests", isDirectory: true)
        return base
    }

    init(_ name: String, options: StoreOptions = StoreOptions(), keySeed: UInt8 = 0x11) throws {
        root = Fixture.testRoot.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))",
                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        keyProvider = try InMemoryKeyProvider.deterministic(seed: keySeed)
        store = try Store.open(directory: dataDirectory, keyProvider: keyProvider, options: options)
    }

    /// 关库再开，用于验证持久化与崩溃恢复之外的"重开一致"。
    func reopen(options: StoreOptions = StoreOptions()) throws {
        store.close()
        store = try Store.open(directory: dataDirectory, keyProvider: keyProvider, options: options)
    }

    func closeStore() { store?.close(); store = nil }

    deinit {
        store?.close()
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - 合成观察

enum Synth {
    static let baseTS: Int64 = 1_757_000_000_000   // 2026-09-04 附近，固定值

    static func observation(ts: Int64,
                            bundle: String = "com.apple.Safari",
                            appName: String = "Safari",
                            window: String = "窗口 A",
                            host: String? = "example.com",
                            path: String? = nil,
                            file: String? = nil,
                            thumb: String? = nil,
                            trigger: CaptureTrigger = .timer,
                            texts: [String]) -> ObservationInput {
        let url: URLRef? = host.map {
            let locator = "https://\($0)\(path ?? "/doc/1")"
            return URLRef(rawLocator: locator, canonicalURL: locator, host: $0, kind: .web)
        }
        return ObservationInput(
            ts: ts, displayID: 1,
            app: AppRef(bundleID: bundle, name: appName),
            windowTitle: window, url: url, filePath: file,
            trigger: trigger, captureMethod: .ax, completeness: .complete,
            sourceState: .ok, thumbRef: thumb,
            texts: texts.enumerated().map { TextFragment(text: $1, region: "{\"ord\":\($0)}") })
    }
}

// MARK: - 明文扫描

enum LeakScan {
    struct Hit {
        var path: String
        var bytes: Int
        var count: Int
    }

    /// 在一个文件里数一段 UTF-8 字节串出现了几次（不解码，逐字节找）。
    static func countOccurrences(of needle: String, inFileAt path: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return count(needle: Array(needle.utf8), in: data)
    }

    static func count(needle: [UInt8], in data: Data) -> Int {
        guard !needle.isEmpty, data.count >= needle.count else { return 0 }
        var hits = 0
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            let limit = data.count - needle.count
            var i = 0
            while i <= limit {
                if base[i] == needle[0] {
                    var match = true
                    for k in 1..<needle.count where base[i + k] != needle[k] { match = false; break }
                    if match { hits += 1; i += needle.count; continue }
                }
                i += 1
            }
        }
        return hits
    }

    /// 递归扫描一个目录下所有普通文件。返回每个文件的命中数。
    /// `maxFileBytes` 之上的文件跳过（TMPDIR 里可能有别的进程的大文件），跳过数在返回值第二项。
    static func scanDirectory(_ directory: URL, for needles: [String],
                              maxFileBytes: Int = 256 * 1024 * 1024) -> (hits: [Hit], skipped: Int) {
        var out: [Hit] = []
        var skipped = 0
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory,
                                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                    options: []) else { return ([], 0) }
        for case let url as URL in e {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            if (values.fileSize ?? 0) > maxFileBytes { skipped += 1; continue }
            guard let data = fm.contents(atPath: url.path) else { skipped += 1; continue }
            let total = needles.reduce(0) { $0 + count(needle: Array($1.utf8), in: data) }
            out.append(Hit(path: url.path, bytes: data.count, count: total))
        }
        return (out, skipped)
    }
}

// MARK: - 可执行文件定位

enum Products {
    /// `swift test` 下 xctest bundle 与 brosis-store 在同一个 products 目录里。
    static var brosisStore: URL? {
        if let override = ProcessInfo.processInfo.environment["BROSIS_STORE_BIN"] {
            return URL(fileURLWithPath: override)
        }
        let dir = Bundle(for: Fixture.self).bundleURL.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("brosis-store")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// M1 / T5：brosis-mcp（stdio 上的 MCP，端到端测试里由 Python 客户端拉起）。
    static var brosisMCP: URL? {
        if let override = ProcessInfo.processInfo.environment["BROSIS_MCP_BIN"] {
            return URL(fileURLWithPath: override)
        }
        let dir = Bundle(for: Fixture.self).bundleURL.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("brosis-mcp")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// 只用标准库的 MCP 客户端脚本（`core/Tests/mcp_client.py`）。
    /// 按本文件的源码路径推出来，验收者也可以直接手跑它。
    static var mcpClientScript: URL? {
        if let override = ProcessInfo.processInfo.environment["BROSIS_MCP_CLIENT"] {
            return URL(fileURLWithPath: override)
        }
        // .../core/Tests/BrosisCoreTests/TestSupport.swift → .../core/Tests/mcp_client.py
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // BrosisCoreTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("mcp_client.py")
        return FileManager.default.fileExists(atPath: script.path) ? script : nil
    }

    @discardableResult
    static func run(_ executable: URL, _ arguments: [String],
                    environment: [String: String]? = nil) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self))
    }
}

/// 把 CLI 的 JSON 输出解析成字典。
func parseJSONOutput(_ text: String) -> [String: Any] {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

/// 让 `@Sendable` 回调能安全地往外写一个值（严格并发下不能直接捕获 var）。
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ initial: T) { storage = initial }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
