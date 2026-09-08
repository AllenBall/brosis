// brosis M1 / T2：core/ 的命令行工具，供测试与验收使用。
//
// 一切输出都是 JSON（除 --help），便于验收脚本直接解析。
// 不启动任何 GUI、不触发 TCC；密钥用 --key-file（FileKeyProvider，0600），
// 产品路径的钥匙串取钥归 T4。

import Foundation
import BrosisCore
import BrosisIPC
import BrosisSync

// MARK: - 参数

struct Args {
    var command: String
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    func string(_ name: String) -> String? { flags[name] }
    func int(_ name: String) -> Int? { flags[name].flatMap(Int.init) }
    func int64(_ name: String) -> Int64? { flags[name].flatMap(Int64.init) }
    func has(_ name: String) -> Bool { switches.contains(name) }

    func require(_ name: String) throws -> String {
        guard let v = flags[name] else { throw CLIError("缺少参数 --\(name)") }
        return v
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { description = m }
}

func parseArgs() throws -> Args {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first, !command.hasPrefix("-") else {
        throw CLIError("第一个参数必须是子命令，见 --help")
    }
    argv.removeFirst()
    var args = Args(command: command)
    var i = 0
    while i < argv.count {
        let token = argv[i]
        guard token.hasPrefix("--") else { throw CLIError("无法识别的参数：\(token)") }
        let name = String(token.dropFirst(2))
        if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
            args.flags[name] = argv[i + 1]
            i += 2
        } else {
            args.switches.insert(name)
            i += 1
        }
    }
    return args
}

// MARK: - 输出

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object,
                                            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
        ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("brosis-store: " + message + "\n").utf8))
    exit(1)
}

/// 把 Codable 结果转成 `emit` 能吃的 JSON 对象。
func jsonValue<T: Encodable>(_ value: T) -> Any {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
    return object
}

/// 逐行读一个可能很大的文件（1 个月合成流约 700 MiB，不能整个读进内存）。
/// 每读满一块就把已消费的前缀丢掉，所以内存占用是「一块 + 一行」。
func forEachLine(of url: URL, chunkBytes: Int = 4 << 20, _ body: (String) throws -> Void) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var buffer = Data()
    while true {
        let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
        if chunk.isEmpty { break }
        buffer.append(chunk)
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            if nl > start { try body(String(decoding: buffer[start..<nl], as: UTF8.self)) }
            start = buffer.index(after: nl)
        }
        buffer = start < buffer.endIndex ? Data(buffer[start...]) : Data()
    }
    if !buffer.isEmpty { try body(String(decoding: buffer, as: UTF8.self)) }
}

/// 与 tools/proto/measure.py 的 `percentile()` 同一个插值口径。
func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let s = values.sorted()
    if s.count == 1 { return s[0] }
    let k = Double(s.count - 1) * p
    let lo = Int(k), hi = min(lo + 1, s.count - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - Double(lo))
}

/// M2 c / T14：同一条查询在**同一个连接**上跑 `reps + 1` 次，报冷 / 热耗时。
///
/// 口径与 `bench` 一致但更轻：第一次是"进程内第一次"（连接刚开、页缓存空），单列成 `cold_ms`；
/// 其余 `reps` 次是热，给 p50 / p95 / min / max。冷 / 热的完整定义见 `bench` 的注释。
func repeatTimed(_ reps: Int, _ body: () throws -> Int) rethrows -> [String: Any] {
    var cold = 0.0
    var rows = 0
    do {
        let t = Date()
        rows = try body()
        cold = Date().timeIntervalSince(t) * 1000
    }
    var hot: [Double] = []
    hot.reserveCapacity(max(0, reps))
    for _ in 0..<max(0, reps) {
        let t = Date()
        rows = try body()
        hot.append(Date().timeIntervalSince(t) * 1000)
    }
    var out: [String: Any] = ["cold_ms": cold, "reps": hot.count, "rows": rows]
    if !hot.isEmpty {
        out["hot_p50_ms"] = percentile(hot, 0.5) ?? 0
        out["hot_p95_ms"] = percentile(hot, 0.95) ?? 0
        out["hot_min_ms"] = hot.min() ?? 0
        out["hot_max_ms"] = hot.max() ?? 0
        out["hot_mean_ms"] = hot.reduce(0, +) / Double(hot.count)
    }
    return out
}

// MARK: - 向量文件（v4 / M2 c / T11）

/// 从 JSON 文件读一条查询向量（数字数组）。core 不加载模型，向量一律由外面算好传进来。
func readVectorFile(_ path: String) throws -> [Float] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
        throw CLIError("\(path) 要是一个 JSON 数字数组")
    }
    return array.compactMap { ($0 as? NSNumber)?.floatValue }
}

/// 从 JSON 文件读一批查询向量：`{"<查询 id>": [数字, …], …}`。
func readVectorMap(_ path: String) throws -> [String: [Float]] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CLIError("\(path) 要是一个 {\"id\": [数字, …]} 的 JSON 对象")
    }
    var out: [String: [Float]] = [:]
    for (key, value) in object {
        guard let array = value as? [Any] else { continue }
        out[key] = array.compactMap { ($0 as? NSNumber)?.floatValue }
    }
    return out
}

// MARK: - 等退出信号

/// 等 `SIGINT` / `SIGTERM`，或者 `seconds` 到点。返回之后调用方做干净收尾。
///
/// **这段必须待在函数里，不能写在顶层**：Swift 6 语言模式下 `main.swift` 的顶层代码是
/// `@MainActor` 隔离的，而 `setEventHandler(handler:)` 的参数**不是** `@Sendable`，
/// 顶层写出来的那个闭包于是跟着带上 MainActor 隔离检查；libdispatch 在自己的信号队列上
/// 调它，`dispatch_assert_queue` 当场失败 → `SIGTRAP`。
/// 表现是 `serve` 一收到 SIGTERM 就崩（实测退出码 133 = 128 + 5），
/// 于是 socket 文件留在原地、库没有 checkpoint、密钥没清零——收尾代码一行都没跑到。
/// 文件作用域的函数默认 `nonisolated`，里面的闭包也就没有这个检查。
func waitForShutdownSignal(seconds: Int?) {
    let done = DispatchSemaphore(value: 0)
    let signalQueue = DispatchQueue(label: "brosis-store.serve.signal")
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)          // 交给 dispatch source，默认处置会直接杀进程
        let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
        source.setEventHandler { done.signal() }
        source.resume()
        sources.append(source)
    }
    if let seconds {
        signalQueue.asyncAfter(deadline: .now() + .seconds(seconds)) { done.signal() }
    }
    done.wait()
    for source in sources { source.cancel() }
}

// MARK: - 打开 store

func openStore(_ args: Args, createIfMissing: Bool = true) throws -> Store {
    let dir = URL(fileURLWithPath: try args.require("dir")).standardizedFileURL
    let keyPath = args.string("key-file")
        ?? dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".key").path
    var options = StoreOptions()
    options.createIfMissing = createIfMissing
    options.cipherMemorySecurity = args.has("memsec")
    if let q = args.int("quota-bytes") { options.quotaBytes = q }
    if let c = args.int("cache-kib") { options.cacheSizeKiB = c }
    if let d = args.string("device-id") { options.deviceID = d }
    if let r = args.int("capture-stats-days") { options.captureStatsRetentionDays = r }
    let provider = FileKeyProvider(url: URL(fileURLWithPath: keyPath),
                                   createIfMissing: !args.has("no-create-key"))
    let store = try Store.open(directory: dir, keyProvider: provider, options: options)
    // 检索层与会话常量：命令行可覆盖，缺省用包里的默认值（3.4 / 3.7）。
    if let tz = args.string("tz") {
        guard let zone = TimeZone(identifier: tz) else { throw CLIError("无法识别的时区：\(tz)") }
        store.retrieval.timeZone = zone
    }
    if let d = args.int("scan-days") { store.retrieval.scanWindowDays = d }
    // 对照口径：≤ 2 字一律扫（含纯汉字两字），用来量「纯汉字两字只走 FTS」省了多少。
    if args.has("scan-all-short") { store.retrieval.scanSkipsPureCJKBigram = false }
    if let c = args.int("fts-candidates") { store.retrieval.ftsCandidateLimit = c }
    if let c = args.int("fts-candidates-filtered") { store.retrieval.filteredFTSCandidateLimit = c }
    if let t = args.int("summary-tokens") { store.retrieval.summaryTokenBudget = t }
    // v4（M2 c / T11）：向量通道**默认关**，只有显式 --vectors 才打开（计划 3.4 / 4.3）。
    if args.has("vectors") { store.retrieval.vectorsEnabled = true }
    if let k = args.int("vector-k") { store.retrieval.vectorK = k }
    if let k = args.int("vector-k-filtered") { store.retrieval.filteredVectorK = k }
    if let d = args.flags["vector-max-distance"].flatMap(Double.init) {
        store.retrieval.vectorMaxDistance = d
    }
    if let w = args.flags["vector-weight"].flatMap(Double.init) { store.retrieval.vectorWeight = w }
    if let k = args.flags["rrf-k"].flatMap(Double.init) { store.retrieval.rrfK = k }
    if let v = args.flags["max-dwell-s"].flatMap(Double.init) { store.sessionConfig.maxDwellSeconds = v }
    if let v = args.flags["gap-s"].flatMap(Double.init) { store.sessionConfig.gapSeconds = v }
    if let v = args.flags["interruption-s"].flatMap(Double.init) {
        store.sessionConfig.interruptionSeconds = v
    }
    return store
}

// MARK: - 合成观察流

/// 确定性 PRNG（SplitMix64），和 tools/proto 的合成器同族，保证同 seed 结果一致。
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
}

enum Corpus {
    static let apps: [(String, String)] = [
        ("com.apple.Safari", "Safari"),
        ("com.microsoft.VSCode", "Code"),
        ("com.apple.Terminal", "终端"),
        ("com.tencent.xinWeChat", "微信"),
        ("com.electron.lark", "飞书"),
    ]
    static let cnPhrases = [
        "会议纪要", "知识图谱", "季度复盘", "设计评审", "接口文档", "全文检索",
        "存储服务", "删除级联", "配额过期", "崩溃恢复", "密钥轮换", "台账口径",
    ]
    static let enPhrases = [
        "SQLCipher", "contentless FTS5", "incremental vacuum", "WAL checkpoint",
        "bigram tokenizer", "device_id primary key", "peak footprint", "auto_vacuum",
    ]
    static let hosts = ["example.com", "docs.internal", "git.example.org", "mail.example.com"]

    static func text(_ rng: inout SplitMix64, index: Int) -> String {
        var parts: [String] = ["段落#\(index)"]
        for _ in 0..<(3 + rng.int(4)) {
            parts.append(rng.pick(cnPhrases))
            parts.append(rng.pick(enPhrases))
        }
        return parts.joined(separator: "，") + "。"
    }

    /// 合成一条观察。`reuseEvery` 控制多久复现一次旧文本（验证 sha256 复用）。
    static func observation(_ rng: inout SplitMix64, index: Int, ts: Int64,
                            reuseEvery: Int = 5) -> ObservationInput {
        let (bundle, name) = apps[index % apps.count]
        let host = hosts[index % hosts.count]
        // 每 reuseEvery 条一组：组内第一条产出新正文，其余 reuseEvery - 1 条复现它，
        // 用来验证 sha256 复用与共享文本版本。reuseEvery = 5 时新文本占 20%。
        let textIndex = (reuseEvery > 1 && index % reuseEvery != 0)
            ? (index / reuseEvery) * reuseEvery : index
        var local = SplitMix64(state: UInt64(bitPattern: Int64(textIndex)) &+ 0x5EED)
        return ObservationInput(
            ts: ts,
            displayID: Int64(1 + index % 2),
            app: AppRef(bundleID: bundle, name: name),
            windowTitle: "\(name) — 窗口 \(index % 7)",
            url: URLRef(rawLocator: "https://\(host)/doc/\(index % 40)?q=1",
                        canonicalURL: "https://\(host)/doc/\(index % 40)?q=1",
                        host: host, kind: .web),
            filePath: index % 3 == 0 ? "/tmp/brosis-synth/doc-\(index % 20).md" : nil,
            trigger: .timer,
            captureMethod: .ax,
            completeness: .complete,
            sourceState: .ok,
            texts: [TextFragment(text: Corpus.text(&local, index: textIndex), region: "{\"ord\":0}")])
    }
}

func jsonlLine(_ input: ObservationInput) -> String {
    var object: [String: Any] = [
        "ts": input.ts,
        "trigger": input.trigger.rawValue,
        "capture_method": input.captureMethod.rawValue,
        "completeness": input.completeness.rawValue,
        "source_state": input.sourceState.rawValue,
        "texts": input.texts.map { t -> [String: Any] in
            var d: [String: Any] = ["text": t.text]
            if let r = t.region { d["region"] = r }
            return d
        },
    ]
    if let d = input.displayID { object["display_id"] = d }
    if let a = input.app { object["app"] = ["bundle_id": a.bundleID, "name": a.name] }
    if let w = input.windowTitle { object["window"] = w }
    if let u = input.url {
        object["url"] = ["raw": u.rawLocator, "canonical": u.canonicalURL,
                         "host": u.host ?? "", "kind": u.kind.rawValue]
    }
    if let f = input.filePath { object["file"] = f }
    if let v = input.visibleRange { object["visible_range"] = v }
    if let h = input.frameHash { object["frame_hash"] = h }
    if let t = input.thumbRef { object["thumb_ref"] = t }
    let data = try! JSONSerialization.data(withJSONObject: object,
                                           options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

func parseJSONL(_ line: String) throws -> ObservationInput {
    guard let data = line.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CLIError("不是合法的 JSON 对象：\(line.prefix(80))")
    }
    guard let ts = (object["ts"] as? NSNumber)?.int64Value else { throw CLIError("缺少 ts") }
    func enumValue<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        (object[key] as? String).flatMap(T.init(rawValue:)) ?? fallback
    }
    var app: AppRef?
    if let a = object["app"] as? [String: Any],
       let bundle = a["bundle_id"] as? String {
        app = AppRef(bundleID: bundle, name: (a["name"] as? String) ?? bundle)
    }
    var url: URLRef?
    if let u = object["url"] as? [String: Any], let raw = u["raw"] as? String {
        let host = (u["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        url = URLRef(rawLocator: raw, canonicalURL: (u["canonical"] as? String) ?? raw,
                     host: host,
                     kind: (u["kind"] as? String).flatMap(URLKind.init(rawValue:)) ?? .web)
    }
    let texts = (object["texts"] as? [[String: Any]] ?? []).compactMap { d -> TextFragment? in
        guard let t = d["text"] as? String else { return nil }
        return TextFragment(text: t, region: d["region"] as? String)
    }
    return ObservationInput(
        ts: ts,
        displayID: (object["display_id"] as? NSNumber)?.int64Value,
        app: app,
        windowTitle: object["window"] as? String,
        url: url,
        filePath: object["file"] as? String,
        trigger: enumValue("trigger", CaptureTrigger.timer),
        captureMethod: enumValue("capture_method", CaptureMethod.ax),
        completeness: enumValue("completeness", Completeness.complete),
        visibleRange: object["visible_range"] as? String,
        sourceState: enumValue("source_state", SourceState.ok),
        frameHash: object["frame_hash"] as? String,
        thumbRef: object["thumb_ref"] as? String,
        texts: texts)
}

// MARK: - 帮助

let helpText = """
brosis-store —— core/ 加密存储核心的命令行工具（M1 / T2）

用法：brosis-store <子命令> --dir <数据目录> --key-file <密钥文件> [选项]

子命令：
  init              建库（或打开已有库），打印编译开关与连接配置
  stats             按 dbstat 分项报告字节（--detail 逐 b-tree，--json 只出数字）
  import-jsonl      从 JSONL 导入合成观察流（--file，--batch 默认 500）
  gen-jsonl         生成确定性合成观察流（--out --count [--seed] [--start-ts] [--step-ms] [--reuse-every]）
  delete            用户删除：--app <bundle_id> | --range <start,end> | --object <k=v> | --observations <逗号分隔 id>
                    --object 的 k ∈ host / url-prefix / raw-locator / file / file-prefix / window
  expire            配额过期（--to-bytes，缺省用 --quota-bytes 或默认 10 GiB；--batch 默认 200）
  maintenance       FTS 对账 + wal_checkpoint(TRUNCATE) + incremental_vacuum
  check             13 项悬空引用检查 + integrity_check + foreign_key_check + FTS integrity-check
  crash-after       写 N 条并提交，再开一个未提交事务写 --batch 条，然后自杀（SIGKILL），验证崩溃恢复
  dump-fts-count    打印 FTS 行数；带 --match <查询> 时打印该查询的命中条数

检索、会话与台账（M1 / T3，计划 3.4 / 3.6 / 3.7）：
  search            三通道检索（--q [--start --end --app] [--limit 20]）
                    --q 支持 url: / host: / path: / app: / title: 五个字段前缀，带前缀只走精确字段通道
  search-batch      一次跑一整套查询集（--file queries.json [--out r.json]），评估脚本用
  fts-only          只跑 FTS 通道的最小实现（T2 留的对照口）
  evidence          展开原文与出现上下文（--ids 1,2,3 [--client <grant>] [--neighbors 2]）
  grant             写 / 看一份 grant（--client [--mode --apps --time-window --fields] [--show]）
  item              get_item（--url | --path | --app [--start --end]）
  context           get_context（--hours 24 --max-tokens 2000 [--at <ms>] [--no-text]）
  timeline          get_timeline（--start --end --granularity hour|day|week）
  sessions          会话（[--build|--rebuild|--force] [--start --end] [--stale]）
  ledger            日台账（--date YYYY-MM-DD [--recompute]，或 --days 列出所有有观察的日子）

周台账、活动模式、最近活动（M2 c / T14，计划 3.6 / 3.7 / 4.3）：
  week-ledger       周台账（--week YYYY-Www 或周内任意一天的 YYYY-MM-DD [--recompute]，
                    或 --weeks 列出所有有观察的周）。周 = 该周 7 个日台账之和；
                    --check 额外打印"周 vs 7 天之和"的逐字段对照
  patterns          活动模式（--start --end [--focus-minutes 25] [--max-transitions 20]
                    [--max-apps 20] [--apps a,b] [--no-heatmap 只出汇总]）
  recent            最近活动（--minutes 30 [--max-items 20] [--apps a,b] [--at <ms>]
                    [--no-items 只出汇总]）
  以上三条都支持 --reps N：同一连接上跑 1 + N 次，报冷（第一次）与热 p50 / p95
  bench             四类查询的冷 / 热 p50 / p95（--cold-rounds 20 --hot-reps 20 [--out x.json]）
                    --cold-round 是它自己 spawn 的子进程模式，一般不手动用

向量检索（M2 c / T11，计划 3.4 / 4.3；**默认关**）：
  vec-status        分块 / 向量 / 模型状态 + 最近的嵌入任务行（--jobs 5）
  vec-plan          只分块不嵌入（--limit 处理多少个文本版本，--batch 每批多少个）
  vec-embed         跑嵌入任务（--provider hash：确定性伪嵌入，**没有语义**，只给测试用；
                    真实模型走 app 包里的 brosis-embed embed）
                    [--batch 16] [--max-chunks N] [--max-seconds S] [--model-id ID]
  vec-rebuild       清掉全部 chunks / vec_chunks 与嵌入元数据，下次任务从头再来
  vec-search        纯向量 kNN（--vector-file <JSON 数字数组> | --text <文本> [--k 20]）
  search / search-batch 的向量选项：
    --vectors                打开向量通道（不给就是关，与 v3 行为逐位相同）
    --vector-file <文件>     search：这一题的查询向量（JSON 数字数组）
    --query-vectors <文件>   search-batch：{"<题 id>": [数字, …]} 的查询向量表
    --hash-query             用确定性伪嵌入现算查询向量（**没有语义**，只给测试 / 自检用）
    --vector-k / --vector-k-filtered / --vector-max-distance / --vector-weight / --rrf-k

跨设备同步（M2 c / T13，计划 3.9 / D17）：
  sync-init         初始化或加入同步目录 --sync-dir <目录> [--passphrase <配对口令>] [--device-name <名字>]
                    首台会**打印一次**配对口令（之后再也拿不到）；已有目录时必须给口令
  sync-status       同步状态：出站水位线、各设备已导入到哪个 seq、待导入段数、目录字节
  sync-export       把待出站记录打成段文件（--max-segments 8 --max-observations 2000
                    --max-text-bytes 8388608）
  sync-import       按 seq 顺序导入其他设备的段（缺段 / 校验失败即停，不跳过）
  sync-cleanup      删掉所有对端都已 ack 的本机段文件
  sync-run          一轮完整同步：入站 → 出站 → 清理

本地 IPC / MCP（M1 / T5，计划 3.1 / 3.6）：
  serve             在 <数据目录>/ipc.sock 上起 IPC 服务端（**测试替身**，产品路径在 brosis.app 里）
                    [--rate 60] [--seconds N] [--state-file <文件：unlocked|paused|locked>]
                    [--socket <路径>] [--verbose]
  mcp-audit         打印最近的 mcp_audit 行（--limit 20 [--client <名字>]），不含正文

通用选项：
  --dir              数据目录（D16：不能在 iCloud Drive 或其他同步盘里）
  --key-file         32 字节原始密钥文件（0600）。不存在时自动用 SecRandomCopyBytes 生成
  --no-create-key    密钥文件不存在时直接报错，不生成
  --memsec           打开 PRAGMA cipher_memory_security（写入约 1.38×）
  --quota-bytes      配额（原文净载荷字节），默认 10 GiB = 10737418240
  --cache-kib        页缓存 KiB，默认 131072（128 MiB）
  --device-id        建库时写入的 device_id，默认随机 UUID
  --tz               台账 / 时间线 / getItem 的时区，默认本机时区；验收用 UTC
  --scan-days        1–2 字扫描通道的时间窗，默认 7 天（3.4）
  --scan-all-short   ≤ 2 字一律走扫描通道（默认纯汉字两字只走 FTS），对照用
  --fts-candidates   FTS 候选窗口（无过滤），默认 200
  --fts-candidates-filtered  FTS 候选窗口（带时间 / 应用过滤），默认 2000
  --summary-tokens   每条摘要的 token 预算，默认 100（3.6）
  --max-dwell-s      会话常量：停留上限，默认 90 s（3.7）
  --gap-s            会话常量：间隔上限，默认 300 s（3.7）
  --interruption-s   会话常量：打断上限，默认 20 s（3.7）
  --sync-dir         同步目录（D17）。默认 iCloud Drive/brosis-sync/，测试用任意临时目录
  --passphrase       配对口令（加入已有同步目录时必须给）
  --device-name      写进 devices/<id>.json 的设备名，只在同步目录里出现
"""

// MARK: - 同步（D17 / 3.9）

enum SyncDefaults {
    /// 3.9 的默认同步目录：`~/Library/Mobile Documents/com~apple~CloudDocs/brosis-sync/`。
    /// 普通文件系统路径，不需要 iCloud 容器 entitlement。
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/brosis-sync",
                                    isDirectory: true)
    }
}

func importJSON(_ report: SyncImportReport) -> [String: Any] {
    ["segments": report.segments, "ok": report.ok, "errors": report.errors,
     "peers": report.peers,
     "observations_inserted": report.stats.observationsInserted,
     "observations_skipped": report.stats.observationsSkipped,
     "occurrences_inserted": report.stats.occurrencesInserted,
     "text_versions_inserted": report.stats.textVersionsInserted,
     "text_versions_reused": report.stats.textVersionsReused,
     "tombstones_applied": report.stats.tombstonesApplied,
     "tombstones_skipped": report.stats.tombstonesSkipped,
     "observations_tombstoned": report.stats.observationsTombstoned,
     "sessions_stale": report.stats.sessionsStale,
     "ledgers_stale": report.stats.ledgersStale,
     "elapsed_ms": report.elapsedMS]
}

// MARK: - 主流程

do {
    if CommandLine.arguments.count < 2
        || CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
        print(helpText)
        exit(0)
    }
    let args = try parseArgs()

    switch args.command {

    case "init":
        let store = try openStore(args)
        defer { store.close() }
        let info = try store.buildInfo()
        let flags = DataDirectory.auditFlags(store.directory)
        emit([
            "command": "init",
            "directory": store.directory.path,
            "database": store.databaseURL.lastPathComponent,
            "device_id": store.deviceID,
            "schema_version": Schema.version,
            "sqlite_version": info.sqliteVersion,
            "cipher_version": info.cipherVersion,
            "cipher_provider": info.cipherProvider,
            "sqlite_vec_version": info.sqliteVecVersion,
            "cipher_page_size": info.cipherPageSize,
            "page_size": info.pageSize,
            "journal_mode": info.journalMode,
            "auto_vacuum": info.autoVacuum,
            "foreign_keys": info.foreignKeys,
            "secure_delete": info.secureDelete,
            "temp_store_compiled": info.tempStoreCompiled,
            "cipher_memory_security": info.cipherMemorySecurity,
            "compile_options": info.compileOptions,
            "dir_mode_octal": String(flags.mode, radix: 8),
            "metadata_never_index": flags.neverIndex,
            "excluded_from_backup": flags.excludedFromBackup,
            // 迁移审计：验收「v4 / v5 真的建过 / 迁过」直接看这一列
            "migrations": try store.migrationNotes().map {
                ["version": $0.version, "applied_at": $0.appliedAt, "note": $0.note]
            },
        ])

    case "stats":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let s = try store.stats()
        var object: [String: Any] = [
            "command": "stats",
            "page_size": s.pageSize, "page_count": s.pageCount, "freelist_pages": s.freelistPages,
            "db_file_bytes": s.dbFileBytes, "wal_bytes": s.walBytes, "shm_bytes": s.shmBytes,
            "content_bytes": s.contentBytes, "index_bytes": s.indexBytes, "fts_bytes": s.ftsBytes,
            "metadata_bytes": s.metadataBytes, "free_bytes": s.freeBytes,
            "text_payload_bytes": s.textPayloadBytes,
            "observations": s.observations, "live_observations": s.liveObservations,
            "tombstoned_observations": s.tombstonedObservations,
            "text_versions": s.textVersions, "occurrences": s.occurrences, "fts_rows": s.ftsRows,
            "apps": s.apps, "deletions": s.deletions,
        ]
        if args.has("detail") {
            object["detail"] = try store.statsDetail().map {
                ["name": $0.name, "bucket": $0.bucket, "bytes": $0.bytes, "pages": $0.pages]
            }
        }
        emit(object)

    case "gen-jsonl":
        let out = URL(fileURLWithPath: try args.require("out"))
        let count = args.int("count") ?? 100
        let seed = UInt64(args.int("seed") ?? 20_260_907)
        let startTS = args.int64("start-ts") ?? 1_757_000_000_000
        let stepMS = args.int64("step-ms") ?? 10_000
        let reuseEvery = args.int("reuse-every") ?? 5
        var rng = SplitMix64(state: seed)
        var lines: [String] = []
        lines.reserveCapacity(count)
        for i in 0..<count {
            let input = Corpus.observation(&rng, index: i, ts: startTS + Int64(i) * stepMS,
                                           reuseEvery: reuseEvery)
            lines.append(jsonlLine(input))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        emit(["command": "gen-jsonl", "out": out.path, "count": count, "seed": Int(seed)])

    case "import-jsonl":
        let store = try openStore(args)
        defer { store.close() }
        let file = URL(fileURLWithPath: try args.require("file"))
        let batchSize = args.int("batch") ?? 500
        var batch: [ObservationInput] = []
        var imported = 0
        var newVersions = 0
        var reused = 0
        let t0 = Date()
        // 逐行流式读：1 个月合成流约 628 MiB，整个读进内存在 16 GiB 机器上不合适。
        //
        // **每批一个 autoreleasepool**：`JSONSerialization.jsonObject` 返回的是自动释放对象，
        // 命令行工具的顶层只有一个池，不显式排就要等进程结束才释放，
        // 25.9 万条的导入会把峰值顶到 1 GiB 以上。峰值实测见结果文件 §3。
        try forEachLine(of: file) { line in
            try autoreleasepool {
                batch.append(try parseJSONL(line))
                if batch.count >= batchSize {
                    for r in try store.record(batch: batch) {
                        newVersions += r.newTextVersions; reused += r.reusedTextVersions
                    }
                    imported += batch.count
                    batch.removeAll(keepingCapacity: true)
                }
            }
        }
        if !batch.isEmpty {
            for r in try store.record(batch: batch) {
                newVersions += r.newTextVersions; reused += r.reusedTextVersions
            }
            imported += batch.count
        }
        let elapsed = Date().timeIntervalSince(t0)
        emit(["command": "import-jsonl", "imported": imported,
              "new_text_versions": newVersions, "reused_text_versions": reused,
              "fts_rows": try store.ftsRowCount(),
              "elapsed_s": elapsed,
              "observations_per_s": elapsed > 0 ? Double(imported) / elapsed : 0])

    case "delete":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let summary: DeletionSummary
        if let bundle = args.string("app") {
            summary = try store.deleteByApp(bundleID: bundle,
                                            start: args.int64("start"), end: args.int64("end"))
        } else if let range = args.string("range") {
            let parts = range.split(separator: ",").compactMap { Int64($0) }
            guard parts.count == 2 else { throw CLIError("--range 要写成 start,end（Unix 毫秒）") }
            summary = try store.deleteByTimeRange(start: parts[0], end: parts[1])
        } else if let object = args.string("object") {
            let parts = object.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { throw CLIError("--object 要写成 k=v") }
            let target: Store.DeletionObject
            switch parts[0] {
            case "host": target = .host(parts[1])
            case "url-prefix": target = .urlPrefix(parts[1])
            case "raw-locator": target = .rawLocator(parts[1])
            case "file": target = .filePath(parts[1])
            case "file-prefix": target = .filePathPrefix(parts[1])
            case "window": target = .windowTitle(parts[1])
            default: throw CLIError("--object 的 k 只能是 host/url-prefix/raw-locator/file/file-prefix/window")
            }
            summary = try store.deleteByObject(target)
        } else if let ids = args.string("observations") {
            summary = try store.deleteObservations(ids.split(separator: ",").compactMap { Int64($0) })
        } else {
            throw CLIError("delete 需要 --app / --range / --object / --observations 之一")
        }
        emit(["command": "delete", "deletion_id": summary.deletionID,
              "kind": summary.kind.rawValue, "reason": summary.reason.rawValue,
              "observations_affected": summary.observationsAffected,
              "occurrences_deleted": summary.occurrencesDeleted,
              "text_versions_deleted": summary.textVersionsDeleted,
              "fts_rows_deleted": summary.ftsRowsDeleted,
              "sessions_stale": summary.sessionsStale, "ledgers_stale": summary.ledgersStale,
              "thumbs_deleted": summary.thumbsDeleted, "bytes_freed": summary.bytesFreed,
              "fts_rows_after": try store.ftsRowCount()])

    case "expire":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let report = try store.expire(toBytes: args.int("to-bytes"), batchSize: args.int("batch") ?? 200)
        var object: [String: Any] = [
            "command": "expire", "quota_bytes": report.quotaBytes,
            "before_bytes": report.beforeBytes, "after_bytes": report.afterBytes,
            "warning_threshold_crossed": report.warningThresholdCrossed,
            "batches": report.batches,
        ]
        if let ts = report.oldestDeletedTS { object["oldest_deleted_ts"] = ts }
        if let ts = report.newestDeletedTS { object["newest_deleted_ts"] = ts }
        if let s = report.summary {
            object["deletion_id"] = s.deletionID
            object["observations_deleted"] = s.observationsAffected
            object["occurrences_deleted"] = s.occurrencesDeleted
            object["text_versions_deleted"] = s.textVersionsDeleted
            object["fts_rows_deleted"] = s.ftsRowsDeleted
            object["bytes_freed"] = s.bytesFreed
        }
        emit(object)

    case "maintenance":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let r = try store.maintenance()
        emit(["command": "maintenance",
              "orphan_fts_rows_deleted": r.orphanFTSRowsDeleted,
              "missing_fts_rows_inserted": r.missingFTSRowsInserted,
              "wal_bytes_before": r.walBytesBefore, "wal_bytes_after": r.walBytesAfter,
              "db_bytes_before": r.dbBytesBefore, "db_bytes_after": r.dbBytesAfter,
              "freelist_before": r.freelistBefore, "freelist_after": r.freelistAfter,
              "capture_stats_pruned": r.captureStatsPruned,
              "elapsed_ms": r.elapsedMS])

    case "check":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let report = try store.integrityReport()
        emit(["command": "check",
              "all_passed": report.allPassed,
              "integrity_check": report.integrityCheck,
              "foreign_key_violations": report.foreignKeyViolations,
              "fts_integrity_check": report.ftsIntegrityCheck,
              "short_text_versions": report.shortTextVersions,
              "dangling": report.danglingChecks.map {
                  ["name": $0.name, "value": $0.value, "expected": $0.expected, "ok": $0.ok]
              }])
        if !report.allPassed { exit(2) }

    case "crash-after":
        // 先写 N 条并逐批提交，再开一个**未提交**事务写 --batch 条，把进度 fsync 到
        // <db>.progress，然后 SIGKILL 自己。重开库后应当：已提交的 N 条都在，
        // 未提交的整批全部回滚，13 项悬空检查仍为 0。
        let store = try openStore(args)
        let count = args.int("count") ?? 200
        let batchSize = args.int("batch") ?? 50
        let seed = UInt64(args.int("seed") ?? 20_260_907)
        let startTS = args.int64("start-ts") ?? 1_757_000_000_000
        var rng = SplitMix64(state: seed)
        var index = 0
        while index < count {
            let n = min(batchSize, count - index)
            var batch: [ObservationInput] = []
            for k in 0..<n {
                batch.append(Corpus.observation(&rng, index: index + k,
                                                ts: startTS + Int64(index + k) * 10_000))
            }
            _ = try store.record(batch: batch)
            index += n
        }
        var pending: [ObservationInput] = []
        for k in 0..<batchSize {
            pending.append(Corpus.observation(&rng, index: count + k,
                                              ts: startTS + Int64(count + k) * 10_000))
        }
        try store.writeUncommittedForCrashTest(pending)

        let progress = store.databaseURL.path + ".progress"
        let payload = "{\"committed\":\(count),\"pending\":\(batchSize),\"device_id\":\"\(store.deviceID)\"}\n"
        let fd = open(progress, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 {
            _ = payload.withCString { write(fd, $0, strlen($0)) }
            fsync(fd)
            close(fd)
        }
        FileHandle.standardError.write(Data("crash-after: 已提交 \(count) 条，未提交 \(batchSize) 条，现在 SIGKILL\n".utf8))
        // 不 close()：故意让 WAL 与未提交事务留在原地。
        kill(getpid(), SIGKILL)
        // 到不了这里
        exit(9)

    case "dump-fts-count":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        var object: [String: Any] = ["command": "dump-fts-count",
                                     "fts_rows": try store.ftsRowCount(),
                                     "text_versions": try store.count(table: "text_versions")]
        if let q = args.string("match") {
            object["match"] = q
            object["match_count"] = try store.ftsMatchCount(q)
        }
        emit(object)

    case "search":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let q = try args.require("q")
        // --hash-query：用确定性伪嵌入把查询串现算成向量。**只给测试与自检用**，没有语义。
        var queryVector = try args.string("vector-file").map(readVectorFile)
        if queryVector == nil, args.has("hash-query") {
            queryVector = try HashEmbeddingProvider().embed([q])[0]
        }
        let result = try store.search(q: q, start: args.int64("start"), end: args.int64("end"),
                                      app: args.string("app"), limit: args.int("limit") ?? 20,
                                      queryVector: queryVector)
        var object: [String: Any] = ["command": "search"]
        if let dict = jsonValue(result) as? [String: Any] { object.merge(dict) { a, _ in a } }
        object["hit_count"] = result.hits.count
        object["evidence_ids"] = result.hits.map(\.evidenceID)
        object["max_summary_tokens"] = result.hits.map(\.summaryTokens).max() ?? 0
        emit(object)

    case "search-batch":
        // 评估用：一个进程跑完整套查询集，省掉每题一次开库。
        // 输入是 [{"id":…,"q":…,"start":…,"end":…,"app":…,"limit":…}, …]
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let file = URL(fileURLWithPath: try args.require("file"))
        guard let items = try JSONSerialization.jsonObject(with: try Data(contentsOf: file))
                as? [[String: Any]] else {
            throw CLIError("search-batch 的输入要是一个 JSON 数组")
        }
        // v4：--vectors <文件> 给每题一条查询向量（{"<题 id>": [数字, …]}）。
        // 只有同时给了 --vectors 与 --vectors-enabled（或 --vectors 开关）才走混合检索。
        // 注意：`--vectors` 是**开关**（打开向量通道），查询向量表走 `--query-vectors <文件>`。
        // 两者共用一个名字的话 `args.has("vectors")` 会因为后面跟了文件名而变成 false，
        // 于是"开了开关却没开"——第一版踩过这个坑。
        var vectorMap = try args.string("query-vectors").map(readVectorMap) ?? [:]
        if vectorMap.isEmpty, args.has("hash-query") {
            let provider = HashEmbeddingProvider()
            for item in items {
                guard let q = item["q"] as? String else { continue }
                vectorMap[item["id"] as? String ?? q] = try provider.embed([q])[0]
            }
        }
        var results: [[String: Any]] = []
        for item in items {
            guard let q = item["q"] as? String else { continue }
            let id = item["id"] as? String ?? q
            let t0 = Date()
            let r = try store.search(q: q,
                                     start: (item["start"] as? NSNumber)?.int64Value,
                                     end: (item["end"] as? NSNumber)?.int64Value,
                                     app: item["app"] as? String,
                                     limit: (item["limit"] as? NSNumber)?.intValue ?? 10,
                                     queryVector: vectorMap[id])
            results.append([
                "id": id,
                "q": q,
                "channels": r.channels.map(\.rawValue),
                "route": r.route.rawValue,
                "evidence_ids": r.hits.map(\.evidenceID),
                "hit_count": r.hits.count,
                "fts_candidates": r.ftsCandidates,
                "fts_candidates_truncated": r.ftsCandidatesTruncated,
                "fts_verified": r.ftsVerified,
                "max_summary_tokens": r.hits.map(\.summaryTokens).max() ?? 0,
                "elapsed_ms": Date().timeIntervalSince(t0) * 1000,
                "fusion": r.fusion,
                "vectors_unavailable": r.vectorsUnavailable,
                "vector_unavailable_reason": r.vectorUnavailableReason ?? "",
                "vector_candidates": r.vectorCandidates,
                "vector_observations": r.vectorObservations,
                "vector_best_distance": r.vectorBestDistance ?? -1,
            ])
        }
        var object: [String: Any] = ["command": "search-batch", "results": results]
        if let out = args.string("out") {
            try JSONSerialization.data(withJSONObject: object,
                                       options: [.prettyPrinted, .sortedKeys,
                                                 .withoutEscapingSlashes])
                .write(to: URL(fileURLWithPath: out))
            object = ["command": "search-batch", "results": results, "out": out]
        }
        emit(object)

    case "fts-only":
        // T2 留下的最小 FTS 通道，保留下来供对照（三通道 search 见上面的 search）。
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let q = try args.require("q")
        let hits = try store.searchFTS(q, limit: args.int("limit") ?? 20)
        emit(["command": "fts-only", "q": q, "hits": hits.count,
              "text_version_ids": hits.map { $0.textVersionID }])

    case "evidence":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let ids = try args.require("ids").split(separator: ",").compactMap { Int64($0) }
        let grant = try args.string("client").flatMap { try store.grant(clientID: $0) }
        let result = try store.getEvidence(ids: ids, grant: grant,
                                           neighbors: args.int("neighbors") ?? 2)
        var object: [String: Any] = ["command": "evidence"]
        if let dict = jsonValue(result) as? [String: Any] { object.merge(dict) { a, _ in a } }
        object["grant"] = grant.map { $0.clientID + ":" + $0.fields.rawValue } ?? "none"
        emit(object)

    case "grant":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let clientID = try args.require("client")
        if args.has("show") {
            emit(["command": "grant", "client_id": clientID,
                  "grant": (try store.grant(clientID: clientID)).map { jsonValue($0) } ?? "none"])
        } else {
            let grant = Grant(
                clientID: clientID,
                mode: args.string("mode").flatMap(GrantMode.init(rawValue:)) ?? .strictLocal,
                apps: (args.string("apps") ?? "*").split(separator: ",").map(String.init),
                timeWindowDays: args.int("time-window") ?? 30,
                fields: args.string("fields").flatMap(GrantFields.init(rawValue:)) ?? .summary)
            try store.setGrant(grant)
            emit(["command": "grant", "client_id": clientID, "grant": jsonValue(grant)])
        }

    case "item":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let selector: ItemSelector
        if let v = args.string("url") { selector = .url(v) }
        else if let v = args.string("path") { selector = .path(v) }
        else if let v = args.string("app") { selector = .app(v) }
        else { throw CLIError("item 需要 --url / --path / --app 之一") }
        let summary = try store.getItem(selector, start: args.int64("start"), end: args.int64("end"))
        var object: [String: Any] = ["command": "item"]
        if let dict = jsonValue(summary) as? [String: Any] { object.merge(dict) { a, _ in a } }
        emit(object)

    case "context":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let bundle = try store.getContext(hours: args.int("hours") ?? 24,
                                          maxTokens: args.int("max-tokens") ?? 2000,
                                          endingAt: args.int64("at"))
        var object: [String: Any] = ["command": "context"]
        if let dict = jsonValue(bundle) as? [String: Any] { object.merge(dict) { a, _ in a } }
        if args.has("no-text") { object["text"] = "(--no-text)" }
        emit(object)

    case "timeline":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let g = TimelineGranularity(rawValue: args.string("granularity") ?? "day") ?? .day
        let timeline = try store.getTimeline(start: try args.int64("start")
                                                ?? { throw CLIError("timeline 需要 --start") }(),
                                             end: try args.int64("end")
                                                ?? { throw CLIError("timeline 需要 --end") }(),
                                             granularity: g)
        var object: [String: Any] = ["command": "timeline"]
        if let dict = jsonValue(timeline) as? [String: Any] { object.merge(dict) { a, _ in a } }
        emit(object)

    case "sessions":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        var object: [String: Any] = ["command": "sessions",
                                     "config": jsonValue(store.sessionConfig)]
        if args.has("build") || args.has("rebuild") || args.has("force") {
            let report = try store.buildSessions(force: args.has("force"))
            object["build"] = jsonValue(report)
        }
        object["total"] = try store.sessionCount()
        if let start = args.int64("start"), let end = args.int64("end") {
            let rows = try store.sessions(from: start, to: end, includeStale: args.has("stale"))
            object["rows"] = jsonValue(rows)
            object["count"] = rows.count
        }
        object["stale"] = try store.staleFlags(table: "sessions").filter(\.stale).count
        emit(object)

    case "ledger":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        if args.has("days") {
            emit(["command": "ledger", "days": try store.observationDays()])
            break
        }
        let date = try args.require("date")
        let ledger = try store.getDayLedger(date: date, recompute: args.has("recompute"))
        var object: [String: Any] = ["command": "ledger"]
        if let dict = jsonValue(ledger) as? [String: Any] { object.merge(dict) { a, _ in a } }
        // 3.7：台账与叙述分开标注。M1 不产叙述，这里显式打出 null 而不是把键省掉。
        object["narrative"] = ledger.narrative ?? NSNull()
        object["model"] = ledger.model ?? NSNull()
        emit(object)

    // ------------------------------- 周台账 / 活动模式 / 最近活动（M2 c / T14）

    case "week-ledger":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        if args.has("weeks") {
            emit(["command": "week-ledger", "weeks": try store.observationWeeks()])
            break
        }
        let week = try args.require("week")
        if let reps = args.int("reps") {
            // 第一次按 --recompute 走（冷 = 真算），其余次走缓存（热 = 读回并校验 7 天指纹）
            var first = true
            let timing = try repeatTimed(reps) {
                let l = try store.getWeekLedger(weekStart: week,
                                                recompute: first && args.has("recompute"))
                first = false
                return l.apps.count
            }
            var object: [String: Any] = ["command": "week-ledger", "week": week]
            object.merge(timing) { a, _ in a }
            emit(object)
            break
        }
        let t0 = Date()
        let ledger = try store.getWeekLedger(weekStart: week, recompute: args.has("recompute"))
        var object: [String: Any] = ["command": "week-ledger",
                                     "elapsed_ms": Date().timeIntervalSince(t0) * 1000]
        if let dict = jsonValue(ledger) as? [String: Any] { object.merge(dict) { a, _ in a } }
        // 3.7：台账与叙述分开标注。叙述在 ledgers 的三个独立列上（T12 / schema v6），
        // 没有就显式打出 null 而不是把键省掉。
        object["narrative"] = ledger.narrative ?? NSNull()
        object["model"] = ledger.model ?? NSNull()
        object["narrative_meta"] = ledger.narrativeMeta.map { jsonValue($0) } ?? NSNull()
        object["narrative_is_stale"] = ledger.narrativeIsStale
        if args.has("check") {
            // "周 = 7 天之和"的逐字段对照：验收时不用自己去加 7 个数。
            var days: [DayLedger] = []
            for date in ledger.days { days.append(try store.getDayLedger(date: date)) }
            // 写成显式循环而不是 `reduce`：把一个非 Sendable 的闭包传进 `reduce` 的闭包里，
            // Swift 6 严格并发下是 `sending 'f' risks causing data races`（release 构建实测）。
            func sum(_ f: (DayLedger) -> Double) -> Double {
                var total = 0.0
                for day in days { total += f(day) }
                return total
            }
            func sumInt(_ f: (DayLedger) -> Int) -> Int {
                var total = 0
                for day in days { total += f(day) }
                return total
            }
            object["check"] = [
                "days": ledger.days,
                "sum_dwell_s": sum(\.totalDwellS), "week_dwell_s": ledger.totalDwellS,
                "sum_active_s": sum(\.totalActiveS), "week_active_s": ledger.totalActiveS,
                "sum_unknown_s": sum(\.totalUnknownS), "week_unknown_s": ledger.totalUnknownS,
                "sum_online_union_s": sum(\.onlineUnionS), "week_online_union_s": ledger.onlineUnionS,
                "sum_switches": sumInt(\.switches), "week_switches": ledger.switches,
                "sum_interruptions": sumInt(\.interruptions), "week_interruptions": ledger.interruptions,
                "sum_sessions": sumInt(\.sessions), "week_sessions": ledger.sessions,
                "sum_observations": sumInt(\.observations), "week_observations": ledger.observations,
            ]
        }
        emit(object)

    case "patterns":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        guard let start = args.int64("start"), let end = args.int64("end") else {
            throw CLIError("patterns 需要 --start 与 --end（Unix 毫秒）")
        }
        var patternOptions = PatternOptions()
        if let v = args.string("focus-minutes").flatMap(Double.init) {
            patternOptions.focusBlockMinMinutes = v
        }
        if let v = args.int("max-transitions") { patternOptions.maxTransitions = v }
        if let v = args.int("max-apps") { patternOptions.maxApps = v }
        if let v = args.int("top-hours") { patternOptions.topHoursPerApp = v }
        let appFilter = args.string("apps")?.split(separator: ",").map(String.init)
        if let reps = args.int("reps") {
            let timing = try repeatTimed(reps) {
                try store.getPatterns(start: start, end: end, apps: appFilter,
                                      options: patternOptions).heatmap.count
            }
            var object: [String: Any] = ["command": "patterns", "start": start, "end": end,
                                         "days": Double(end - start) / 86_400_000.0]
            object.merge(timing) { a, _ in a }
            emit(object)
            break
        }
        let t0 = Date()
        let patterns = try store.getPatterns(start: start, end: end, apps: appFilter,
                                             options: patternOptions)
        var object: [String: Any] = ["command": "patterns",
                                     "wall_ms": Date().timeIntervalSince(t0) * 1000]
        if let dict = jsonValue(patterns) as? [String: Any] { object.merge(dict) { a, _ in a } }
        if args.has("no-heatmap") {
            object["heatmap"] = "(--no-heatmap，\(patterns.heatmap.count) 格)"
        }
        emit(object)

    case "recent":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let appFilter = args.string("apps")?.split(separator: ",").map(String.init)
        if let reps = args.int("reps") {
            let timing = try repeatTimed(reps) {
                try store.recentActivity(minutes: args.int("minutes") ?? 30,
                                         maxItems: args.int("max-items") ?? 20,
                                         apps: appFilter, endingAt: args.int64("at")).items.count
            }
            var object: [String: Any] = ["command": "recent",
                                         "minutes": args.int("minutes") ?? 30]
            object.merge(timing) { a, _ in a }
            emit(object)
            break
        }
        let t0 = Date()
        let recent = try store.recentActivity(minutes: args.int("minutes") ?? 30,
                                              maxItems: args.int("max-items") ?? 20,
                                              apps: appFilter,
                                              endingAt: args.int64("at"))
        var object: [String: Any] = ["command": "recent",
                                     "wall_ms": Date().timeIntervalSince(t0) * 1000]
        if let dict = jsonValue(recent) as? [String: Any] { object.merge(dict) { a, _ in a } }
        if args.has("no-items") {
            object["items"] = "(--no-items，\(recent.items.count) 条)"
        }
        emit(object)

    case "bench":
        // 冷 = 全新子进程 + 全新连接（`--cold-round` 就是那个子进程）；
        // 热 = 同一连接预热一次后连测 N 次。口径与 tools/proto/measure.py 一致。
        let store = try openStore(args, createIfMissing: false)
        let ftsQueries = (args.string("fts-queries") ?? "采集覆盖率,checkpoint,蟠桃")
            .split(separator: ",").map(String.init)
        let shortQueries = (args.string("short-queries") ?? "预算,会")
            .split(separator: ",").map(String.init)
        let plan = try store.makeBenchPlan(ftsQueries: ftsQueries, shortQueries: shortQueries)

        if args.has("cold-round") {
            // 冷的定义与 tools/proto/measure.py 的 `run_cold_round` 一致：
            // 本进程是全新 spawn 出来的，**并且每条查询各开一条新连接跑一次就关**。
            // 和 M0 一样，这里只清掉了 SQLite 自己的页缓存，没有清 macOS 文件缓存
            // （清缓存要提权），所以冷数字是下界；取参数那几条小查询也会顺带预热一点。
            let ids = plan.queries.map(\.id)
            store.close()
            var samples: [BenchSample] = []
            for id in ids {
                let s = try openStore(args, createIfMissing: false)
                let p = try s.makeBenchPlan(ftsQueries: ftsQueries, shortQueries: shortQueries)
                let t0 = Date()
                do {
                    let rows = try p.run(id)
                    samples.append(BenchSample(id: id, ms: Date().timeIntervalSince(t0) * 1000,
                                               rows: rows, error: nil))
                } catch {
                    samples.append(BenchSample(id: id, ms: 0, rows: 0,
                                               error: String(describing: error)))
                }
                s.close()
            }
            emit(["round": samples.map { s -> [String: Any] in
                var d: [String: Any] = ["id": s.id, "ms": s.ms, "rows": s.rows]
                if let e = s.error { d["error"] = e }
                return d
            }])
            break
        }

        let coldRounds = args.int("cold-rounds") ?? 20
        let hotReps = args.int("hot-reps") ?? 20
        var cold: [String: [Double]] = [:]
        var coldRows: [String: Int] = [:]
        var errors: [String: String] = [:]

        // ---- 冷：spawn 自己 ----
        let selfPath = args.string("self") ?? CommandLine.arguments[0]
        var childArgs = ["bench", "--cold-round"]
        if args.has("scan-all-short") { childArgs.append("--scan-all-short") }
        for key in ["dir", "key-file", "cache-kib", "tz", "fts-queries", "short-queries",
                    "scan-days", "max-dwell-s", "gap-s", "interruption-s"] {
            if let v = args.flags[key] { childArgs += ["--" + key, v] }
        }
        for round in 0..<coldRounds {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: selfPath)
            process.arguments = childArgs
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.standardError
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["round"] as? [[String: Any]] else {
                throw CLIError("冷测子进程第 \(round) 轮失败（退出码 \(process.terminationStatus)）")
            }
            for row in rows {
                guard let id = row["id"] as? String else { continue }
                if let e = row["error"] as? String { errors[id] = e; continue }
                cold[id, default: []].append((row["ms"] as? NSNumber)?.doubleValue ?? 0)
                coldRows[id] = (row["rows"] as? NSNumber)?.intValue ?? 0
            }
        }

        // ---- 热：同一连接 ----
        var hot: [String: [Double]] = [:]
        var hotRows: [String: Int] = [:]
        for q in plan.queries {
            do { _ = try plan.run(q.id) } catch { errors[q.id] = String(describing: error); continue }
            var samples: [Double] = []
            var rows = 0
            for _ in 0..<hotReps {
                let t0 = Date()
                rows = try plan.run(q.id)
                samples.append(Date().timeIntervalSince(t0) * 1000)
            }
            hot[q.id] = samples
            hotRows[q.id] = rows
        }
        store.close()

        var perQuery: [[String: Any]] = []
        for q in plan.queries {
            var d: [String: Any] = ["category": q.category, "id": q.id, "label": q.label,
                                    "rows": hotRows[q.id] ?? coldRows[q.id] ?? 0,
                                    "cold_n": cold[q.id]?.count ?? 0,
                                    "hot_n": hot[q.id]?.count ?? 0]
            if let v = percentile(cold[q.id] ?? [], 0.50) { d["cold_p50"] = v }
            if let v = percentile(cold[q.id] ?? [], 0.95) { d["cold_p95"] = v }
            if let v = percentile(hot[q.id] ?? [], 0.50) { d["hot_p50"] = v }
            if let v = percentile(hot[q.id] ?? [], 0.95) { d["hot_p95"] = v }
            if let e = errors[q.id] { d["error"] = e }
            perQuery.append(d)
        }
        var byCategory: [[String: Any]] = []
        for category in NSOrderedSet(array: plan.queries.map(\.category)).array as? [String] ?? [] {
            let ids = plan.queries.filter { $0.category == category }.map(\.id)
            let coldAll = ids.flatMap { cold[$0] ?? [] }
            let hotAll = ids.flatMap { hot[$0] ?? [] }
            var d: [String: Any] = ["category": category, "queries": ids.count]
            if let v = percentile(coldAll, 0.50) { d["cold_p50"] = v }
            if let v = percentile(coldAll, 0.95) { d["cold_p95"] = v }
            if let v = percentile(hotAll, 0.50) { d["hot_p50"] = v }
            if let v = percentile(hotAll, 0.95) { d["hot_p95"] = v }
            d["hot_p95_max"] = ids.compactMap { percentile(hot[$0] ?? [], 0.95) }.max() ?? 0
            byCategory.append(d)
        }
        let object: [String: Any] = [
            "command": "bench", "cold_rounds": coldRounds, "hot_reps": hotReps,
            "parameters": plan.parameters, "per_query": perQuery, "by_category": byCategory,
            "hot_p95_max_ms": perQuery.compactMap { $0["hot_p95"] as? Double }.max() ?? 0,
        ]
        if let out = args.string("out") {
            let data = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys,
                                                            .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: out))
        }
        emit(object)

    // -------------------------------------------------------------- serve（M1 / T5）
    // 本地 IPC 服务端的**测试替身**：产品路径的服务端在 brosis.app 里（LockController 那一层，
    // 计划 3.1），这里用 FileKeyProvider 在给定目录开库再把同一个 `MCPGate` + `StoreMCPService`
    // 挂到同一个 `IPCServer` 上，好让 `swift test` 不启动 GUI 就能跑完整条链路。
    case "serve":
        let store = try openStore(args)
        let service = StoreMCPService(store: store)

        // 3.5 的锁定 / 暂停在测试里靠一个状态文件模拟：内容是 unlocked / paused / locked。
        // 产品路径读的是 LockController 的相位，不读文件。
        let stateFile = args.string("state-file")
        @Sendable func currentState() -> MCPServiceState {
            guard let stateFile,
                  let text = try? String(contentsOfFile: stateFile, encoding: .utf8) else {
                return .unlocked
            }
            return MCPServiceState(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
                ?? .unlocked
        }
        let gate = MCPGate {
            let state = currentState()
            // locked = 库关着：不把 service 交出去，被拒的审计先攒着，解锁后补写。
            return (state, state == .locked ? nil : service)
        }
        let verbose = args.has("verbose")
        gate.onEvent = { line in
            if verbose { FileHandle.standardError.write(Data(("serve: " + line + "\n").utf8)) }
        }

        // 默认就是产品路径的 `<数据目录>/ipc.sock`；`--socket` 只是给测试留的口子
        // （`sun_path` 只有 104 字节，测试的临时目录可能顶到上限）。
        var configuration = IPCServer.Configuration(
            socketURL: args.string("socket").map { URL(fileURLWithPath: $0) }
                ?? IPCProtocol.socketURL(dataDirectory: store.directory))
        if let rate = args.int("rate") { configuration.requestsPerMinute = rate }
        // **只有这里读这个环境变量**：`swift test` 编出来的测试进程没有 Developer ID，
        // 同 Team 校验必然过不去。产品路径（app/Sources/brosis/IPCService.swift）写死
        // `.requireSameTeam`，不读任何环境变量。
        let skipCodesign = ProcessInfo.processInfo.environment["BROSIS_IPC_SKIP_CODESIGN"] == "1"
        configuration.peerPolicy = skipCodesign ? .skip : .requireSameTeam

        let server = IPCServer(configuration: configuration) { call in gate.handle(call) }
        server.onEvent = { line in
            if verbose { FileHandle.standardError.write(Data(("serve: " + line + "\n").utf8)) }
        }
        try server.start()
        emit([
            "command": "serve", "ready": true,
            "socket": configuration.socketURL.path,
            "requests_per_minute": configuration.requestsPerMinute,
            "peer_policy": skipCodesign ? "skip_codesign" : "require_same_team",
            "host_team_id": server.hostTeamID ?? "none",
            "state_file": stateFile ?? "none",
            "schema_version": Schema.version,
        ])

        // 干净退出：把 socket 文件删掉、checkpoint、关库、清零密钥。
        waitForShutdownSignal(seconds: args.int("seconds"))
        server.stop()
        try? store.checkpoint()
        store.close()
        emit(["command": "serve", "stopped": true])

    // ------------------------------------------------- 向量（v4 / M2 c / T11）
    //
    // 这几条子命令**不加载任何模型**（core 里没有 mlx）。真实模型的那条路走
    // app 包里的 `brosis-embed`：它算好向量，`--provider` 这一侧只提供
    //   * `hash`：确定性的伪嵌入（`HashEmbeddingProvider`，没有语义，只给测试 / 复现用）
    // 两个动作因此可以分开验收：存储与检索在这里、模型在那里。
    case "vec-status":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let status = try store.vectorStatus()
        var object: [String: Any] = ["command": "vec-status"]
        if let dict = jsonValue(status) as? [String: Any] { object.merge(dict) { a, _ in a } }
        object["ready"] = status.ready
        object["jobs"] = try store.embeddingJobs(limit: args.int("jobs") ?? 5)
        emit(object)

    case "vec-plan":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        var config = ChunkConfig()
        if let v = args.int("target-chars") { config.targetCharacters = v }
        if let v = args.int("max-chars") { config.maxCharacters = v }
        if let v = args.int("overlap-chars") { config.overlapCharacters = v }
        let report = try store.planChunks(config: config, limit: args.int("limit"),
                                          batch: args.int("batch") ?? 2_000)
        var object: [String: Any] = ["command": "vec-plan",
                                     "chunk_config": config.fingerprint]
        if let dict = jsonValue(report) as? [String: Any] { object.merge(dict) { a, _ in a } }
        emit(object)

    case "vec-embed":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let providerName = args.string("provider") ?? "hash"
        guard providerName == "hash" else {
            throw CLIError("brosis-store 只带 --provider hash（确定性伪嵌入）。"
                           + "真实模型走 app 包里的 brosis-embed embed")
        }
        let provider = HashEmbeddingProvider(id: args.string("model-id") ?? "hash-test-provider")
        var options = EmbeddingJobOptions(batchSize: args.int("batch") ?? 16,
                                          maxChunks: args.int("max-chunks"),
                                          maxSeconds: args.flags["max-seconds"].flatMap(Double.init))
        if let v = args.int("target-chars") { options.chunkConfig.targetCharacters = v }
        if let v = args.int("max-chars") { options.chunkConfig.maxCharacters = v }
        if let v = args.int("overlap-chars") { options.chunkConfig.overlapCharacters = v }
        let report = try store.runEmbeddingJob(provider: provider, options: options)
        var object: [String: Any] = ["command": "vec-embed", "provider": providerName]
        if let dict = jsonValue(report) as? [String: Any] { object.merge(dict) { a, _ in a } }
        emit(object)

    case "vec-rebuild":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let removed = try store.rebuildEmbeddings()
        emit(["command": "vec-rebuild", "chunks_removed": removed])

    case "vec-search":
        // 纯向量 kNN。查询向量由 --vector-file 给（JSON 数字数组），不需要模型。
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        // --vector-file 给真实向量；--text 用确定性伪嵌入现算一条（**没有语义**，只给测试用）。
        let vector: [Float]
        if let path = args.string("vector-file") {
            vector = try readVectorFile(path)
        } else if let text = args.string("text") {
            vector = try HashEmbeddingProvider().embed([text])[0]
        } else {
            throw CLIError("vec-search 要 --vector-file <JSON 数字数组> 或 --text <文本>")
        }
        let t0 = Date()
        let hits = try store.vectorSearchChunks(queryVector: vector, k: args.int("k") ?? 20)
        emit(["command": "vec-search", "k": args.int("k") ?? 20,
              "dimension": vector.count, "hit_count": hits.count,
              "elapsed_ms": Date().timeIntervalSince(t0) * 1000,
              "hits": jsonValue(hits)])

    // -------------------------------------------------------------- mcp-audit
    case "mcp-audit":
        let store = try openStore(args, createIfMissing: false)
        defer { store.close() }
        let rows = try store.mcpAuditTail(limit: args.int("limit") ?? 20,
                                          clientID: args.string("client"))
        emit(["command": "mcp-audit", "count": rows.count,
              "total": try store.mcpAuditCount(), "rows": jsonValue(rows)])

    // -------------------------------------------------------------- 跨设备同步（D17 / 3.9）
    case "sync-init", "sync-status", "sync-export", "sync-import", "sync-cleanup", "sync-run":
        let store = try openStore(args, createIfMissing: args.command == "sync-init")
        defer { store.close() }
        let root = URL(fileURLWithPath: args.string("sync-dir") ?? SyncDefaults.directory.path)
        var options = SyncOptions()
        options.deviceName = args.string("device-name")
        if let n = args.int("max-segments") { options.maxSegmentsPerRun = n }
        if let n = args.int("max-observations") { options.maxObservationsPerSegment = n }
        if let n = args.int("max-text-bytes") { options.maxTextBytesPerSegment = n }
        if let n = args.int("download-timeout-s") { options.downloadTimeout = Double(n) }
        let opened = try SyncEngine.openOrCreate(
            store: store, root: root, passphrase: args.string("passphrase"), options: options,
            logEvent: { kind, detail in _ = try? store.recordRuntimeEvent(kind: kind, detail: detail) })
        let engine = opened.engine

        func statusObject() throws -> [String: Any] {
            let status = try engine.status()
            return [
                "directory": status.directory, "device_id": status.deviceID,
                "key_id": status.keyID, "peers": status.peers,
                "pending_imports": status.pendingImports,
                "pending_observations": status.state.pendingObservations,
                "pending_tombstones": status.state.pendingTombstones,
                "next_seq": status.state.nextSeq,
                "exported_observation_id": status.state.exportedObservationID,
                "exported_deletion_id": status.state.exportedDeletionID,
                "last_export_at": status.state.lastExportAt as Any,
                "last_import_at": status.state.lastImportAt as Any,
                "own_segments": status.ownSegments, "segment_bytes": status.segmentBytes,
                "peer_state": status.state.peers.map {
                    ["device_id": $0.deviceID, "name": $0.name as Any,
                     "imported_seq": $0.importedSeq, "observations": $0.observations,
                     "last_error": $0.lastError as Any]
                },
            ]
        }

        var out: [String: Any] = ["command": args.command, "created": opened.created]
        // 配对口令**只在建目录那一次**打印，之后任何命令都再也拿不到它。
        if let passphrase = opened.generatedPassphrase { out["pairing_passphrase"] = passphrase }

        switch args.command {
        case "sync-init":
            out["status"] = try statusObject()
        case "sync-status":
            out["status"] = try statusObject()
        case "sync-export":
            let report = try engine.exportOnce()
            out["export"] = ["segments": report.segments, "observations": report.observations,
                             "texts": report.texts, "occurrences": report.occurrences,
                             "tombstones": report.tombstones,
                             "text_payload_bytes": report.textPayloadBytes,
                             "file_bytes": report.fileBytes,
                             "first_seq": report.firstSeq as Any, "last_seq": report.lastSeq as Any,
                             "elapsed_ms": report.elapsedMS]
            out["status"] = try statusObject()
        case "sync-import":
            let report = try engine.importOnce()
            out["import"] = importJSON(report)
            out["status"] = try statusObject()
        case "sync-cleanup":
            let cleaned = try engine.cleanup()
            out["cleanup"] = ["deleted": cleaned.deleted, "watermark": cleaned.watermark]
            out["status"] = try statusObject()
        default:   // sync-run
            let round = try engine.runOnce()
            out["import"] = importJSON(round.imported)
            out["export"] = ["segments": round.exported.segments,
                             "observations": round.exported.observations,
                             "tombstones": round.exported.tombstones,
                             "file_bytes": round.exported.fileBytes,
                             "elapsed_ms": round.exported.elapsedMS]
            out["cleanup"] = ["deleted": round.cleaned]
            out["status"] = try statusObject()
        }
        emit(out)

    default:
        throw CLIError("未知子命令 \(args.command)，见 --help")
    }
} catch let e as CLIError {
    fail(e.description)
} catch let e as StoreError {
    fail(e.description)
} catch {
    fail(String(describing: error))
}
