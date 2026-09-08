// brosis-embed —— 嵌入任务与查询向量的命令行入口（M2 c / T11）
//
// 对应计划 3.4「向量检索」、3.11「模型管理器」、4.3「若 D8 通过：嵌入任务…」。
//
// 分工：
//   * **模型**在这里（链接 BrosisModels ⇒ mlx-swift）；
//   * **存储与检索**在 core 的 brosis-store 里（零 mlx 依赖）。
// 所以 D8 实验是「brosis-embed 算向量 → brosis-store 用产品检索路径查」，
// 量到的就是产品行为，不是另写一套。
//
// 一切输出都是 JSON（除 --help）。不启动 GUI、不触发 TCC；密钥用 --key-file（FileKeyProvider）。

import BrosisCore
import BrosisModels
import Foundation

// MARK: - 参数

struct Args {
    var command: String
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    func string(_ name: String) -> String? { flags[name] }
    func int(_ name: String) -> Int? { flags[name].flatMap(Int.init) }
    func double(_ name: String) -> Double? { flags[name].flatMap(Double.init) }
    func has(_ name: String) -> Bool { switches.contains(name) }
    func require(_ name: String) throws -> String {
        guard let v = flags[name] else { throw EmbedError("缺少参数 --\(name)") }
        return v
    }
}

struct EmbedError: Error, CustomStringConvertible {
    let description: String
    init(_ m: String) { description = m }
}

func parseArgs() throws -> Args {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first, !command.hasPrefix("-") else {
        throw EmbedError("第一个参数必须是子命令，见 --help")
    }
    argv.removeFirst()
    var args = Args(command: command)
    var i = 0
    while i < argv.count {
        let token = argv[i]
        guard token.hasPrefix("--") else { throw EmbedError("无法识别的参数：\(token)") }
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

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object,
                                            options: [.prettyPrinted, .sortedKeys,
                                                      .withoutEscapingSlashes]))
        ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func jsonValue<T: Encodable>(_ value: T) -> Any {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
    return object
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("brosis-embed: " + message + "\n").utf8))
    exit(1)
}

// MARK: - 共用

func modelsRoot(_ args: Args) throws -> URL {
    if let explicit = args.string("models-dir") {
        return URL(filePath: (explicit as NSString).expandingTildeInPath)
    }
    let dir = URL(filePath: try args.require("dir")).standardizedFileURL
    return ModelStore.resolveRoot(dataDirectory: dir).url
}

func openStore(_ args: Args) throws -> Store {
    let dir = URL(filePath: try args.require("dir")).standardizedFileURL
    let keyPath = args.string("key-file")
        ?? dir.deletingLastPathComponent().appending(path: dir.lastPathComponent + ".key").path
    var options = StoreOptions()
    options.createIfMissing = false
    let provider = FileKeyProvider(url: URL(filePath: keyPath), createIfMissing: false)
    return try Store.open(directory: dir, keyProvider: provider, options: options)
}

func loadEmbedder(_ args: Args) throws -> MLXEmbeddingProvider {
    let id = args.string("model-id") ?? Catalog.embeddingModelID
    let directory: URL
    if let explicit = args.string("model-dir") {
        directory = URL(filePath: (explicit as NSString).expandingTildeInPath)
    } else {
        directory = ModelStore.directory(root: try modelsRoot(args), id: id)
    }
    guard FileManager.default.fileExists(atPath: directory.path) else {
        throw EmbedError("模型未安装：\(id)（找的是 \(directory.lastPathComponent)）。"
                         + "先用 brosis-embed models import 导入，或在 app 的「模型」面板里装")
    }
    return try MLXEmbeddingProvider.load(
        directory: directory, modelID: id,
        cacheLimitMiB: args.int("cache-limit-mib") ?? MLXMemoryPolicy.defaultCacheLimitMiB,
        maxTokensPerText: args.int("max-tokens") ?? 1024)
}

let helpText = """
brosis-embed —— 嵌入任务与查询向量（M2 c / T11，计划 3.4 / 3.11 / 4.3）

用法：brosis-embed <子命令> [选项]

子命令：
  env               打印运行时环境：metallib 找到没、GPU 能不能跑、清单里有什么、装了哪些模型
  models            模型管理器（--list | --import --id <id> --from <目录> | --verify --id <id>
                    | --remove --id <id>）；根目录默认是**数据目录旁**的 models/（D18）
  embed             跑嵌入任务：分块 → 批量嵌入 → 写 vec_chunks
                    --dir <数据目录> --key-file <密钥> [--model-id] [--batch 16]
                    [--max-chunks N] [--max-seconds S] [--cache-limit-mib 256]
                    [--require-nominal 只在 thermalState=nominal 时跑]
  queries           把一份查询集的检索串批量嵌成向量表（D8 实验用）
                    --file <[{"id":…,"q":…}, …]> --out <{"id": [数字…]}> [--model-id]
  rebuild           清掉全部 chunks / vec_chunks，下次 embed 从头再来（--dir --key-file）
  selftest          **用真实模型**跑一组断言（维度 / 归一化 / 确定性 / 语义分离 / MRL 截断）。
                    模型没装时打印 skipped 并以退出码 0 结束（CI 上没有模型，见 app/README 13.6）

通用选项：
  --dir             数据目录（同 brosis-store）
  --key-file        32 字节原始密钥文件
  --models-dir      模型根目录（默认 <数据目录>/../models，D18：不加密、不进 iCloud）
  --model-dir       直接指定某个模型的目录（跳过模型根目录与 id）
  --model-id        清单 id，默认 \(Catalog.embeddingModelID)
  --cache-limit-mib 加载模型**之前**设的 MLX 缓冲池上限，默认 \(MLXMemoryPolicy.defaultCacheLimitMiB)（D27）
  --out             结果另存为 JSON
"""

// MARK: - 主流程

do {
    if CommandLine.arguments.count < 2
        || CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
        print(helpText)
        exit(0)
    }
    let args = try parseArgs()

    switch args.command {

    // ---------------------------------------------------------------- env
    case "env":
        let catalog = try Catalog.load()
        var object: [String: Any] = [
            "command": "env",
            "hardware": ModelProc.hardwareModel,
            "physical_memory_gib": Double(ModelProc.physicalMemory) / ModelBytes.gib,
            "thermal_state": ModelProc.thermalState,
            "catalog_schema_version": catalog.schemaVersion,
            "catalog_models": catalog.models.map(\.id),
            "sqlite_vec_version": Store.sqliteVecVersion,
            "sqlite_vec_registered": Store.sqliteVecRegistered,
            "vector_dimension": SchemaV4.dimension,
            "vector_element_type": SchemaV4.elementType,
        ]
        if let dir = args.string("dir") {
            let root = ModelStore.resolveRoot(dataDirectory: URL(filePath: dir))
            object["models_root"] = root.url.lastPathComponent
            object["models_root_source"] = root.source
            object["installed"] = ModelStore.entries(catalog: catalog, root: root.url)
                .filter(\.installed).map(\.id)
        }
        // 真跑一次 GPU 运算：metallib 缺失 / 版本对不上都会在这里炸出来。
        object["gpu_smoke"] = MLXSmoke.run()
        object.merge(MLXMemoryPolicy.snapshot) { a, _ in a }
        emit(object)

    // ---------------------------------------------------------------- models
    case "models":
        let catalog = try Catalog.load()
        let root = try modelsRoot(args)
        if args.has("list") || args.switches.isEmpty && args.flags["id"] == nil {
            let entries = ModelStore.entries(catalog: catalog, root: root)
            emit(["command": "models", "action": "list",
                  "root": root.lastPathComponent,
                  "installed_count": entries.filter(\.installed).count,
                  "models": entries.map { e -> [String: Any] in
                      var row: [String: Any] = [
                          "id": e.id, "purpose": e.purpose, "installed": e.installed,
                          "approved": e.approved,
                          "size_mib": Double(e.sizeBytes) / ModelBytes.mib,
                          "disk_mib": Double(e.diskBytes) / ModelBytes.mib,
                      ]
                      if let r = e.minRAMBytes { row["min_ram_gib"] = Double(r) / ModelBytes.gib }
                      if let r = e.unavailableReason { row["unavailable_reason"] = r }
                      if let s = e.source { row["source"] = s }
                      if let t = e.installedAt { row["installed_at"] = t }
                      return row
                  }])
        } else if args.has("import") {
            let model = try catalog.model(id: try args.require("id"))
            let from = URL(filePath: (try args.require("from") as NSString).expandingTildeInPath)
            let report = try ModelStore.importLocal(model: model, from: from, root: root,
                                                    schemaVersion: catalog.schemaVersion)
            emit(["command": "models", "action": "import", "id": model.id,
                  "file_count": report.fileCount,
                  "total_mib": Double(report.totalBytes) / ModelBytes.mib,
                  "disk_mib": Double(ModelStore.directorySize(report.directory)) / ModelBytes.mib,
                  "seconds": report.seconds,
                  "peak_footprint_mib": Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib])
        } else if args.has("verify") {
            let model = try catalog.model(id: try args.require("id"))
            let dir = ModelStore.directory(root: root, id: model.id)
            let digests = try ModelStore.verify(model: model, in: dir)
            emit(["command": "models", "action": "verify", "id": model.id,
                  "files_verified": digests.count,
                  "peak_footprint_mib": Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib])
        } else if args.has("remove") {
            let id = try args.require("id")
            try ModelStore.remove(root: root, id: id)
            emit(["command": "models", "action": "remove", "id": id,
                  "installed": ModelStore.isInstalled(root: root, id: id)])
        } else {
            throw EmbedError("models 要 --list / --import / --verify / --remove 之一")
        }

    // ---------------------------------------------------------------- embed
    case "embed":
        let store = try openStore(args)
        defer { store.close() }
        let provider = try loadEmbedder(args)
        var options = EmbeddingJobOptions(batchSize: args.int("batch") ?? 16,
                                          maxChunks: args.int("max-chunks"),
                                          maxSeconds: args.double("max-seconds"))
        if let v = args.int("target-chars") { options.chunkConfig.targetCharacters = v }
        if let v = args.int("max-chars") { options.chunkConfig.maxCharacters = v }

        // 热门控（D27）：Air 上持续负载 2 分 10 秒就会转 fair，吞吐掉 33.6%。
        // --require-nominal 让任务在转 fair 的那一刻干净停下（已经写进去的块保留）。
        let requireNominal = args.has("require-nominal")
        let gate: EmbeddingGate = {
            if requireNominal && !ModelProc.thermalAllowsWork {
                return "thermal_" + ModelProc.thermalState
            }
            return nil
        }
        let thermalAtStart = ModelProc.thermalState
        let report = try store.runEmbeddingJob(provider: provider, options: options, gate: gate)
        let release = provider.unload()
        let throughput = provider.throughput

        var object: [String: Any] = ["command": "embed"]
        if let dict = jsonValue(report) as? [String: Any] { object.merge(dict) { a, _ in a } }
        object["model_load_seconds"] = provider.loadSeconds
        object["pooling"] = provider.poolingStrategy
        object["native_dimension"] = provider.nativeDimension
        object["texts_per_second"] = throughput.textsPerSecond
        object["tokens_per_second"] = throughput.tokensPerSecond
        object["total_tokens"] = provider.totalTokens
        object["thermal_at_start"] = thermalAtStart
        object["thermal_at_end"] = ModelProc.thermalState
        object["cache_limit_mib"] = (MLXMemoryPolicy.appliedCacheLimitBytes ?? 0) / (1 << 20)
        object["release"] = jsonValue(release)
        object["peak_footprint_mib"] = Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib
        if let out = args.string("out") {
            try JSONSerialization.data(withJSONObject: object,
                                       options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: URL(filePath: out))
            object["out"] = out
        }
        emit(object)

    // ---------------------------------------------------------------- queries
    case "queries":
        // 输入与 brosis-store search-batch 的一样：[{"id":…, "q":…}, …]
        // 输出是 {"<id>": [数字, …]}，喂给 `brosis-store search-batch --vectors`。
        let file = URL(filePath: try args.require("file"))
        guard let items = try JSONSerialization.jsonObject(with: try Data(contentsOf: file))
                as? [[String: Any]] else {
            throw EmbedError("queries 的输入要是一个 JSON 数组")
        }
        let provider = try loadEmbedder(args)
        // 查询串里的字段前缀（app: / host: / …）对语义没有意义，嵌入之前去掉。
        func plainQuery(_ q: String) -> String {
            for prefix in ["url:", "host:", "path:", "app:", "title:"] where q.hasPrefix(prefix) {
                return String(q.dropFirst(prefix.count))
            }
            return q
        }
        var ids: [String] = []
        var texts: [String] = []
        for item in items {
            guard let q = item["q"] as? String else { continue }
            // 自然语言问句比检索串更贴近"用户会怎么问"，有就优先用它（D8 的改写题就是这么设计的）。
            let natural = (item["embed_text"] as? String) ?? (item["nl"] as? String)
            ids.append(item["id"] as? String ?? q)
            texts.append(natural ?? plainQuery(q))
        }
        let batch = args.int("batch") ?? 16
        var vectors: [String: [Float]] = [:]
        let t0 = Date()
        var index = 0
        while index < texts.count {
            let slice = Array(texts[index..<min(index + batch, texts.count)])
            let embedded = try provider.embed(slice)
            for (k, v) in embedded.enumerated() { vectors[ids[index + k]] = v }
            index += batch
        }
        let seconds = Date().timeIntervalSince(t0)
        let release = provider.unload()
        let out = URL(filePath: try args.require("out"))
        try JSONSerialization.data(withJSONObject: vectors.mapValues { $0.map { Double($0) } },
                                   options: [.sortedKeys])
            .write(to: out)
        emit(["command": "queries", "count": vectors.count, "dimension": SchemaV4.dimension,
              "seconds": seconds, "model_load_seconds": provider.loadSeconds,
              "tokens_per_second": provider.throughput.tokensPerSecond,
              "peak_footprint_mib": Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib,
              "release": jsonValue(release), "out": out.lastPathComponent])

    // ---------------------------------------------------------------- selftest
    //
    // core 的 `swift test` 不碰模型（那边用确定性伪嵌入），所以「真实模型到底对不对」
    // 只能在这里验。**模型没装时不算失败**：打印 skipped 并 exit 0，CI 上没有模型。
    case "selftest":
        let id = args.string("model-id") ?? Catalog.embeddingModelID
        let root = try? modelsRoot(args)
        let directory: URL? = args.string("model-dir").map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
            ?? root.map { ModelStore.directory(root: $0, id: id) }
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else {
            emit(["command": "selftest", "status": "skipped", "model": id,
                  "reason": "模型未安装（本机没有这个模型目录）；"
                          + "core 的 swift test 不需要模型，这一组是给装了模型的机器补的"])
            exit(0)
        }
        let provider = try MLXEmbeddingProvider.load(directory: directory, modelID: id)
        var failures: [String] = []
        func check(_ label: String, _ ok: Bool, _ detail: String) -> [String: Any] {
            if !ok { failures.append(label) }
            return ["check": label, "ok": ok, "detail": detail]
        }
        // 三句话：前两句近义，第三句完全无关（E9 用的是同一类对照）
        let near1 = "今天下午和同事复核了下个季度的预算安排。"
        let near2 = "下午跟同事一起把下季度的花钱计划又对了一遍。"
        let far = "砚台是磨墨用的石制文具，常见于书房。"
        let vectors = try provider.embed([near1, near2, far])
        // 同一批构造（都是 1 条）跑两次，必须逐位相同。
        let single1 = try provider.embed([near1])
        let single2 = try provider.embed([near1])
        var checks: [[String: Any]] = []
        checks.append(check("维度 = \(SchemaV4.dimension)（MRL 截断自 \(provider.nativeDimension)）",
                            vectors.allSatisfy { $0.count == SchemaV4.dimension },
                            "\(vectors.map(\.count))"))
        let norms = vectors.map { v -> Double in
            var n = 0.0; for x in v { n += Double(x) * Double(x) }; return n.squareRoot()
        }
        checks.append(check("截断后重新 L2 归一化", norms.allSatisfy { abs($0 - 1) < 1e-4 },
                            norms.map { String(format: "%.6f", $0) }.joined(separator: " ")))
        checks.append(check("同一批构造下两次嵌入逐位相同（确定性）", single1[0] == single2[0],
                            single1[0] == single2[0] ? "逐位相同" : "不同"))
        // E9 已知限制：**换批大小会改变向量数值**（4.04×10⁻⁴ 量级），
        // 所以比较向量要用余弦阈值而不是字节相等，入库时固定批构造。
        // 这一条不是 bug，是把那条已知限制钉住，免得将来有人改批大小时以为出问题了。
        let batchShapeCosine = EmbeddingVector.cosine(single1[0], vectors[0])
        checks.append(check("换批大小只改动 1e-3 量级（E9 已知限制，不是 bug）",
                            single1[0] != vectors[0] && batchShapeCosine > 0.999,
                            String(format: "批 1 vs 批 3 的余弦 %.6f，逐位相同 = %@",
                                   batchShapeCosine, single1[0] == vectors[0] ? "是" : "否")))
        let nearCosine = EmbeddingVector.cosine(vectors[0], vectors[1])
        let farCosine = EmbeddingVector.cosine(vectors[0], vectors[2])
        checks.append(check("近义句余弦 > 无关句余弦 + 0.2", nearCosine > farCosine + 0.2,
                            String(format: "近义 %.4f vs 无关 %.4f", nearCosine, farCosine)))
        // int8 量化不改变排序
        func quantizedCosine(_ a: [Float], _ b: [Float]) -> Double {
            EmbeddingVector.cosine(EmbeddingVector.dequantizeInt8(EmbeddingVector.quantizeInt8(a)),
                                   EmbeddingVector.dequantizeInt8(EmbeddingVector.quantizeInt8(b)))
        }
        let qNear = quantizedCosine(vectors[0], vectors[1])
        let qFar = quantizedCosine(vectors[0], vectors[2])
        checks.append(check("int8 量化后余弦误差 < 0.01 且排序不变",
                            abs(qNear - nearCosine) < 0.01 && abs(qFar - farCosine) < 0.01
                              && qNear > qFar,
                            String(format: "近义 %.4f→%.4f，无关 %.4f→%.4f",
                                   nearCosine, qNear, farCosine, qFar)))
        let release = provider.unload()
        emit(["command": "selftest", "status": failures.isEmpty ? "passed" : "failed",
              "model": id, "native_dimension": provider.nativeDimension,
              "load_seconds": provider.loadSeconds, "pooling": provider.poolingStrategy,
              "checks": checks, "failures": failures,
              "peak_footprint_mib": Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib,
              "release": jsonValue(release)])
        if !failures.isEmpty { exit(1) }

    // ---------------------------------------------------------------- rebuild
    case "rebuild":
        let store = try openStore(args)
        defer { store.close() }
        emit(["command": "rebuild", "chunks_removed": try store.rebuildEmbeddings()])

    default:
        throw EmbedError("未知子命令 \(args.command)，见 --help")
    }
} catch let e as EmbedError {
    fail(e.description)
} catch let e as ModelsError {
    fail(e.description)
} catch let e as StoreError {
    fail(e.description)
} catch {
    fail(String(describing: error))
}
