// brosis M0 · E9：内嵌推理运行时、模型管理器与分发验证
//
// 子命令：
//   env                                     打印运行时环境（含 metallib 来源）
//   catalog                                 列出推荐清单
//   download --id <id> [选项]                按清单下载 + 校验 + 安装
//   import   --id <id> --from <dir>          从本地目录导入 + 校验 + 安装
//   verify   --id <id>                       重新逐文件校验已安装的模型
//   embed    --id <id> --text "..."          跑一条嵌入（证明运行时可用）
//   bench    --id <id> --out <a.json>        跑完整的嵌入验证与基准
//   generate --id <id> [--prompt ...]        跑生成（D19 叙述 / 抽取），带 token 计量
//
// embed / bench / generate 通用选项：
//   --out <a.json>             结果落盘（便于溯源）
//   --cache-limit-mib <n>      限制 MLX 缓冲池（0 = 关掉）。不给就是 MLX 默认（等于 memoryLimit，
//                              批处理时能涨到数 GiB 且进程结束前不还给系统）——这是 footprint
//                              峰值的主要来源，见结果文件第 3.5 节
//
// generate 专有选项（计划 3.10：温度 0、关闭思考）：
//   --id <id> / --dir <目录>    模型来源，默认 --id Qwen3.5-4B-MLX-4bit
//   --prompt <文本>             提示词
//   --prompt-file <路径>        从文件读提示词（长台账用这个）
//   --system <文本>             系统指令（ChatSession 的 instructions）
//   --no-think                 关闭思考模式（additionalContext enable_thinking=false）
//   --temperature <f>          默认 0
//   --top-p <f>                默认 1
//   --max-tokens <n>           真正的 GenerateParameters.maxTokens，默认 512
//   --repeat <n>               同一提示连跑 n 次（每次新建 ChatSession），默认 1；
//                              输出 answersIdentical 判断温度 0 下是否逐字相同
//
// 下载选项：
//   --primary <url>            默认 https://huggingface.co
//   --mirror  <url>            默认 https://hf-mirror.com
//   --force-base <url>         跳过探测，强制用这个源
//   --simulate-interrupt <n>   先只下前 n 字节再走 Range 续传，用来实测断点续传

import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// 尽早读一次，让"进程启动到第一条向量"的口径成立
_ = Proc.startDate

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }
func need(_ name: String, _ hint: String) -> String {
    guard let v = arg(name) else { fail("需要 \(name) \(hint)") }
    return v
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "env"

/// mlx 的 metallib 实际是从哪儿加载的（诊断用；查找顺序见 Support/build_metallib.sh 的注释）
func metallibCandidates() -> [[String: Any]] {
    let exeDir = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent()
    var paths: [URL] = [
        exeDir.appending(path: "mlx.metallib"),
        exeDir.appending(path: "Resources/mlx.metallib"),
        exeDir.appending(path: "mlx-swift_Cmlx.bundle/default.metallib"),
        exeDir.appending(path: "Resources/default.metallib"),
    ]
    if let r = Bundle.main.resourceURL {
        paths.append(r.appending(path: "mlx-swift_Cmlx.bundle/default.metallib"))
    }
    return paths.map { u in
        let exists = FileManager.default.fileExists(atPath: u.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? nil
        return [
            "path": u.path, "exists": exists,
            "sizeMiB": exists ? Double(size ?? 0) / Bytes.mib : 0,
        ] as [String: Any]
    }
}

func printEnv() {
    var info = Bench.environment()
    info["executable"] = CommandLine.arguments[0]
    info["bundleMainPath"] = Bundle.main.bundlePath
    info["metallibCandidates"] = metallibCandidates()
    info["modelsRoot"] = ModelStore.root.path
    // 真跑一次 GPU 运算，证明 Metal 可用
    do {
        let a = MLXArray([1.0, 2.0, 3.0] as [Float])
        let b = (a * 2 + 1).sum()
        b.eval()
        info["metalSmokeTest"] = ["ok": true, "value": b.item(Float.self)]
    }
    print(JSONOut.string(info))
}

do {
    switch command {

    case "env":
        printEnv()

    case "catalog":
        let c = try Catalog.load()
        print("清单版本 \(c.schemaVersion)，生成于 \(c.generatedAt ?? "-")")
        for m in c.models {
            let size = m.totalBytes.map { Bytes.human($0) } ?? "-"
            let ram = m.minRAMBytes.map { Bytes.gibString($0) } ?? "-"
            let state = ModelStore.isInstalled(m.id) ? "已安装" : (m.fitsThisMachine ? "可安装" : "内存不足（置灰）")
            print("""
              - \(m.id)
                用途 \(m.purpose) / 来源 \(m.source) / 量化 \(m.quantization ?? "-")
                仓库 \(m.repoId) @ \(m.revision ?? "-")
                体积 \(size)，最低内存 \(ram)，本机状态：\(state)，文件 \(m.files.count) 个
                \(m.note ?? "")
            """)
        }

    case "download":
        let id = need("--id", "<清单里的模型 id>")
        let c = try Catalog.load()
        let m = try c.model(id: id)
        guard m.source == "huggingface", let revision = m.revision else {
            fail("\(id) 不是可下载项（source=\(m.source)），请用 import 子命令")
        }
        guard m.fitsThisMachine else { fail("本机内存不足，清单要求 \(Bytes.gibString(m.minRAMBytes ?? 0))") }

        let primary = arg("--primary") ?? HFDownloader.defaultPrimary
        let mirror = arg("--mirror") ?? HFDownloader.defaultMirror
        let simulate = Int64(arg("--simulate-interrupt") ?? "0") ?? 0
        let dl = HFDownloader()
        let smallest = m.files.min { $0.size < $1.size }!.path

        var probes: [MirrorProbe] = []
        var base: String
        if let forced = arg("--force-base") {
            base = forced
            log("强制使用源：\(base)")
        } else {
            (base, probes) = await dl.chooseBase(
                primary: primary, mirror: mirror, repoId: m.repoId, revision: revision,
                smallFile: smallest)
            for p in probes {
                log("探测 \(p.base)：\(p.ok ? "通" : "不通") \(String(format: "%.3f", p.seconds))s（\(p.note)）")
            }
            log("选定源：\(base)")
        }

        let staging = try ModelStore.stagingDirectory(for: m.id)
        log("暂存目录：\(staging.path)")
        var stats: [FileDownloadStat] = []
        let t0 = Date()
        for f in m.files.sorted(by: { $0.size < $1.size }) {
            let sim = (f.path == "model.safetensors" && simulate > 0) ? simulate : 0
            let s = try await dl.downloadFile(
                base: base, repoId: m.repoId, revision: revision, file: f,
                stagingDir: staging, simulateInterruptBytes: sim)
            stats.append(s)
            let mibs = s.seconds > 0 ? Double(s.bytes) / Bytes.mib / s.seconds : 0
            log(String(
                format: "  ✓ %@  %@  %.2fs  %.1f MiB/s%@",
                f.path, Bytes.human(f.size), s.seconds, mibs,
                s.rangeStatus.map { "  Range->HTTP \($0)" } ?? ""))
        }
        let total = stats.reduce(Int64(0)) { $0 + $1.bytes }
        let elapsed = Date().timeIntervalSince(t0)
        let final = try ModelStore.commit(staging: staging, to: m.id)
        let now = ISO8601DateFormatter().string(from: Date())
        try ModelStore.writeRecord(
            InstalledRecord(
                id: m.id, repoId: m.repoId, revision: revision, source: "huggingface",
                baseURLUsed: base, importedFrom: nil, totalBytes: total,
                fileCount: m.files.count, installedAt: now, verifiedAt: now,
                catalogSchemaVersion: c.schemaVersion),
            id: m.id)

        let report: [String: Any] = [
            "id": m.id, "repoId": m.repoId, "revision": revision, "baseUsed": base,
            "probes": probes.map { ["base": $0.base, "ok": $0.ok, "seconds": $0.seconds, "note": $0.note] },
            "files": stats.map {
                ["path": $0.path, "bytes": $0.bytes, "seconds": $0.seconds,
                 "resumedFromBytes": $0.resumedFromBytes,
                 "rangeStatus": $0.rangeStatus as Any, "sha256OK": $0.sha256OK] as [String: Any]
            },
            "totalBytes": total,
            "totalMiB": Double(total) / Bytes.mib,
            "totalSeconds": elapsed,
            "avgMiBPerSecond": Double(total) / Bytes.mib / elapsed,
            "installedAt": final.path,
            "simulateInterruptBytes": simulate,
        ]
        if let out = arg("--out") { try JSONOut.write(report, to: URL(filePath: out)) }
        print(JSONOut.string(report))

    case "import":
        let id = need("--id", "<清单里的模型 id>")
        let from = need("--from", "<源目录>")
        let c = try Catalog.load()
        let m = try c.model(id: id)
        let (dir, bytes, secs) = try ModelStore.importLocal(
            model: m, from: URL(filePath: from), schemaVersion: c.schemaVersion)
        let report: [String: Any] = [
            "id": id, "from": from, "installedAt": dir.path,
            "totalBytes": bytes, "totalMiB": Double(bytes) / Bytes.mib,
            "seconds": secs, "verified": true, "fileCount": m.files.count,
        ]
        if let out = arg("--out") { try JSONOut.write(report, to: URL(filePath: out)) }
        print(JSONOut.string(report))

    case "verify":
        let id = need("--id", "<清单里的模型 id>")
        let c = try Catalog.load()
        let m = try c.model(id: id)
        let dir = arg("--dir").map { URL(filePath: $0) } ?? ModelStore.directory(for: id)
        let t0 = Date()
        let digests = try ModelStore.verify(model: m, in: dir)
        print(JSONOut.string([
            "id": id, "directory": dir.path, "files": digests.count,
            "seconds": Date().timeIntervalSince(t0), "allMatch": true,
        ]))

    case "embed":
        let id = arg("--id") ?? "Qwen3-Embedding-0.6B-8bit"
        let dir = arg("--dir").map { URL(filePath: $0) } ?? ModelStore.directory(for: id)
        let text = arg("--text") ?? "brosis 在本机记录我看过什么。"
        if let mib = Int(arg("--cache-limit-mib") ?? "") { MemoryPolicy.applyCacheLimit(mib: mib) }
        let e = try await Embedder.load(directory: dir)
        let (v, _) = await e.embedBatch([text])
        let firstVectorAt = Proc.sinceStart
        let embedReport: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "executable": CommandLine.arguments[0],
            "directory": dir.path,
            "loadSeconds": e.loadSeconds,
            "secondsFromProcessStartToFirstVector": firstVectorAt,
            "poolingStrategy": e.poolingStrategy,
            "dimension": v[0].count,
            "l2Norm": Vec.norm(v[0]),
            "first8": v[0].prefix(8).map { Double($0) },
            "gpuMemoryConfig": Bench.gpuMemoryConfig(),
            "memory": Bench.memorySnapshot(label: "after-first-vector"),
            "thermalState": Proc.thermalState,
        ]
        if let out = arg("--out") { try JSONOut.write(embedReport, to: URL(filePath: out)) }
        print(JSONOut.string(embedReport))

    case "bench":
        let id = arg("--id") ?? "Qwen3-Embedding-0.6B-8bit"
        let dir = arg("--dir").map { URL(filePath: $0) } ?? ModelStore.directory(for: id)
        let corpus = try Corpus.load()
        if let mib = Int(arg("--cache-limit-mib") ?? "") { MemoryPolicy.applyCacheLimit(mib: mib) }
        var result: [String: Any] = [
            "tool": "brosis-e9 bench",
            "date": ISO8601DateFormatter().string(from: Date()),
            "modelDirectory": dir.path,
            "modelId": id,
            "environment": Bench.environment(),
            "gpuMemoryConfig": Bench.gpuMemoryConfig(),
            "metallib": metallibCandidates(),
            "installed": ModelStore.record(for: id).map {
                ["repoId": $0.repoId, "revision": $0.revision as Any, "source": $0.source,
                 "baseURLUsed": $0.baseURLUsed as Any, "totalBytes": $0.totalBytes] as [String: Any]
            } as Any,
            "memoryBeforeLoad": Bench.memorySnapshot(label: "before-load"),
        ]

        log("加载模型 …")
        let e = try await Embedder.load(directory: dir)
        result["memoryAfterLoad"] = Bench.memorySnapshot(label: "after-load")

        // 5) 首次加载时间：进程启动 -> 第一条向量
        let (_, _) = await e.embedBatch(["预热"])
        result["load"] = [
            "containerLoadSeconds": e.loadSeconds,
            "secondsFromProcessStartToFirstVector": Proc.sinceStart,
            "poolingStrategy": e.poolingStrategy,
            "dimension": e.dimension,
            "padTokenId": e.padTokenId,
            "modelDirectoryBytes": ModelStore.directorySize(dir),
        ]
        result["memoryAfterFirstVector"] = Bench.memorySnapshot(label: "after-first-vector")

        log("1) 确定性 …")
        result["determinism"] = await Bench.determinism(
            e, texts: Array(corpus.crosscheck.prefix(8)))

        log("2) 语义合理性 …")
        result["semantics"] = await Bench.semantics(e, corpus: corpus)

        log("3) MRL 截断 …")
        result["mrl"] = await Bench.mrl(e, corpus: corpus)

        log("4) 吞吐 …")
        result["throughput"] = await Bench.throughput(e, corpus: corpus)

        if let cc = arg("--crosscheck-out") {
            log("6) 导出对照向量 …")
            result["crosscheck"] = try await Bench.crosscheckDump(
                e, corpus: corpus, to: URL(filePath: cc))
        }

        result["memoryAtEnd"] = Bench.memorySnapshot(label: "end")
        // 评审 F8：批量工作负载的内存峰值口径是 phys_footprint，不是 RSS。
        // MLX 的缓冲池计入 footprint 而不计入 RSS，两者能差 8 倍。
        result["peakFootprintMiB"] = Double(Proc.peakFootprintBytes()) / Bytes.mib
        result["peakFootprintBytes"] = Proc.peakFootprintBytes()
        result["peakResidentMiB"] = Double(Proc.peakResidentBytes()) / Bytes.mib
        result["peakResidentBytes"] = Proc.peakResidentBytes()
        result["gpuPeakMiB"] = Double(MLX.Memory.peakMemory) / Bytes.mib
        // 主动释放缓冲池，给 M1 夜间任务"跑完立刻还内存"做依据
        result["cacheRelease"] = MemoryPolicy.releaseCache()
        result["memoryAfterCacheRelease"] = Bench.memorySnapshot(label: "after-cache-release")
        result["totalSeconds"] = Proc.sinceStart

        if let out = arg("--out") {
            try JSONOut.write(result, to: URL(filePath: out))
            log("结果写入 \(out)")
        }
        print(JSONOut.string(result))

    case "generate":
        // 计划 3.10 对生成类任务的要求：温度 0、关闭思考、JSON 校验、失败重试一次。
        // 这里实现前两条与全部计量口径；JSON 校验与重试属于 M2 的提供方抽象，M0 由外部脚本校验。
        let id = arg("--id") ?? "Qwen3.5-4B-MLX-4bit"
        let dir = arg("--dir").map { URL(filePath: $0) } ?? ModelStore.directory(for: id)

        // 提示词：--prompt 直接给，或 --prompt-file 从文件读（长台账用后者，避免命令行长度限制）
        let prompt: String
        if let p = arg("--prompt") {
            prompt = p
        } else if let f = arg("--prompt-file") {
            prompt = try String(contentsOf: URL(filePath: f), encoding: .utf8)
        } else {
            prompt = "用一句话说明什么是断点续传。"
        }
        let system = arg("--system")
        let noThink = flag("--no-think")
        let maxTokens = Int(arg("--max-tokens") ?? "512") ?? 512
        let temperature = Float(arg("--temperature") ?? "0") ?? 0
        let topP = Float(arg("--top-p") ?? "1") ?? 1
        let repeatCount = Swift.max(1, Int(arg("--repeat") ?? "1") ?? 1)

        // 与 embed / bench 完全相同：在加载模型之前设缓冲池上限（D27）
        if let mib = Int(arg("--cache-limit-mib") ?? "") { MemoryPolicy.applyCacheLimit(mib: mib) }

        var out: [String: Any] = [
            "tool": "brosis-e9 generate",
            "date": ISO8601DateFormatter().string(from: Date()),
            "modelId": id,
            "directory": dir.path,
            "environment": Bench.environment(),
            "gpuMemoryConfigBeforeLoad": Bench.gpuMemoryConfig(),
            "memoryBeforeLoad": Bench.memorySnapshot(label: "before-load"),
            "promptChars": prompt.count,
            "prompt": prompt,
            "system": system as Any,
            "thinkingOn": !noThink,
            "maxTokens": maxTokens,
            "temperature": Double(temperature),
            "topP": Double(topP),
            "repeat": repeatCount,
            "thermalStateAtStart": Proc.thermalState,
        ]
        do {
            let t0 = Date()
            let container = try await LLMModelFactory.shared.loadContainer(
                from: dir, using: TransformersTokenizerLoader())
            out["loadSeconds"] = Date().timeIntervalSince(t0)
            out["memoryAfterLoad"] = Bench.memorySnapshot(label: "after-load")

            var params = GenerateParameters()
            params.maxTokens = maxTokens
            params.temperature = temperature
            params.topP = topP

            // 关闭思考：Qwen3.5 的 chat_template.jinja 在 add_generation_prompt 时，
            // 若模板变量 enable_thinking 已定义且为 false，就直接吐出 "<think>\n\n</think>\n\n"
            // 前缀（= 非思考模式）；否则只吐 "<think>\n"（= 思考模式）。
            // ChatSession 把 additionalContext 原样传给 tokenizer.applyChatTemplate。
            let additional: [String: any Sendable]? = noThink ? ["enable_thinking": false] : nil

            var runs: [[String: Any]] = []
            var answers: [String] = []
            for i in 0 ..< repeatCount {
                // 每轮新建一个 ChatSession：ChatSession 会保留 KV cache 与历史，
                // 复用会让第 2 轮看到第 1 轮的输出，测不出"同一提示的确定性"。
                let session = ChatSession(
                    container, instructions: system, generateParameters: params,
                    additionalContext: additional)
                let t1 = Date()
                var firstTokenAt: Double? = nil
                var text = ""
                var info: GenerateCompletionInfo? = nil
                for try await g in session.streamDetails(to: prompt) {
                    if let c = g.chunk {
                        if firstTokenAt == nil { firstTokenAt = Date().timeIntervalSince(t1) }
                        text += c
                    }
                    if let inf = g.info { info = inf }
                }
                let generateSeconds = Date().timeIntervalSince(t1)

                // 按 </think> 把输出切成思考段与答案段。非思考模式下模板已经吐过
                // "<think>\n\n</think>"，但那部分在提示里不在输出里，所以正常应当切不出思考段。
                let thinking: String
                let answer: String
                if let r = text.range(of: "</think>") {
                    thinking = String(text[text.startIndex ..< r.lowerBound])
                        .replacingOccurrences(of: "<think>", with: "")
                    answer = String(text[r.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    thinking = ""
                    answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                answers.append(answer)

                runs.append([
                    "index": i,
                    "promptTokens": info?.promptTokenCount as Any,
                    "generationTokens": info?.generationTokenCount as Any,
                    "promptTokensPerSecond": info?.promptTokensPerSecond as Any,
                    "tokensPerSecond": info?.tokensPerSecond as Any,
                    "promptSeconds": info?.promptTime as Any,
                    "generateTimeSeconds": info?.generateTime as Any,
                    "stopReason": info.map { "\($0.stopReason)" } as Any,
                    "timeToFirstTokenSeconds": firstTokenAt as Any,
                    "generateSeconds": generateSeconds,
                    "outputChars": text.count,
                    "output": text,
                    "thinkingChars": thinking.count,
                    "thinking": thinking,
                    "answerChars": answer.count,
                    "answer": answer,
                    "thinkingDetected": !thinking.isEmpty,
                    "memoryAfterRun": Bench.memorySnapshot(label: "after-run-\(i)"),
                    "thermalState": Proc.thermalState,
                ])
                log(String(
                    format: "  第 %d 次：prompt %d tok / %.1f tok/s，生成 %d tok / %.2f tok/s，TTFT %.3fs",
                    i + 1, info?.promptTokenCount ?? -1, info?.promptTokensPerSecond ?? 0,
                    info?.generationTokenCount ?? -1, info?.tokensPerSecond ?? 0,
                    firstTokenAt ?? -1))
            }

            out["runs"] = runs
            // 温度 0 下多次输出是否逐字相同（计划 3.10 的确定性要求）
            out["answersIdentical"] = answers.allSatisfy { $0 == answers[0] }
            // 模型还在内存里时的快照。不加 withExtendedLifetime 的话，Swift 会在最后一次
            // 使用 container 之后立刻释放它，下面 memoryAtEnd 量到的就是"已卸载"的数——
            // 那不是我们想报的"跑完还占多少"。
            withExtendedLifetime(container) {
                out["memoryWithModelLoaded"] = Bench.memorySnapshot(label: "model-loaded")
            }
            // 兼容旧字段：单次运行时把主要指标平铺到顶层，方便直接读
            if let first = runs.first {
                for k in ["promptTokens", "generationTokens", "promptTokensPerSecond",
                          "tokensPerSecond", "timeToFirstTokenSeconds", "generateSeconds",
                          "outputChars", "output", "thinkingChars", "answerChars", "answer"] {
                    out[k] = first[k] ?? NSNull()
                }
            }
            out["ok"] = true
        } catch {
            out["ok"] = false
            out["error"] = "\(error)"
        }
        out["memoryAtEnd"] = Bench.memorySnapshot(label: "end")
        out["peakFootprintMiB"] = Double(Proc.peakFootprintBytes()) / Bytes.mib
        out["peakFootprintBytes"] = Proc.peakFootprintBytes()
        out["peakResidentMiB"] = Double(Proc.peakResidentBytes()) / Bytes.mib
        out["peakResidentBytes"] = Proc.peakResidentBytes()
        out["gpuPeakMiB"] = Double(MLX.Memory.peakMemory) / Bytes.mib
        // 任务结束清空缓冲池（D27）
        out["cacheRelease"] = MemoryPolicy.releaseCache()
        out["memoryAfterCacheRelease"] = Bench.memorySnapshot(label: "after-cache-release")
        out["thermalStateAtEnd"] = Proc.thermalState
        out["totalSeconds"] = Proc.sinceStart
        if let o = arg("--out") { try JSONOut.write(out, to: URL(filePath: o)) }
        print(JSONOut.string(out))

    default:
        fail("未知子命令：\(command)。可用：env / catalog / download / import / verify / embed / bench / generate")
    }
} catch {
    fail("\(error)")
}
