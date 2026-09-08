import BrosisCore
import BrosisModels
import Foundation

// =============================================================================
// `brosis --narrative-smoke`：用**真实模型**跑一次叙述（M2 c / T12）
//
// 为什么单独一个子命令、不进 `--self-check`：加载 2.85 GiB 权重 + 一次生成在 Air 上
// 约 8–30 s（D19 实测：热加载 0.80 s、预填 340 tok/s、生成 35 tok/s），
// 而 `--self-check` 是每次构建都要跑的东西，不能因为它变成半分钟。
// 默认自检里那一组（`NarrativeSelfCheck`）用脚本化提供方，几毫秒跑完、不碰 GPU。
//
// 用法（全部用绝对路径；不启动 GUI、不碰钥匙串，密钥走 `--key-file`）：
//
//   brosis --narrative-smoke \
//       --dir <数据目录> --key-file <32 字节密钥文件> \
//       --models-dir <模型目录> [--date YYYY-MM-DD | --week YYYY-Www] \
//       [--repeat 2] [--dry-run] [--out result.json]
//
// `--dry-run`（默认开）= 只生成与核对，**不写库**；加 `--commit` 才真的入库。
// 验收在合成库上跑，本来也不该往库里留东西。
// =============================================================================

enum NarrativeSmoke {

    static func run() -> Int32 {
        var flags: [String: String] = [:]
        var switches: Set<String> = []
        var argv = Array(CommandLine.arguments.dropFirst())
        argv.removeAll { $0 == "--narrative-smoke" }
        var i = 0
        while i < argv.count {
            let token = argv[i]
            guard token.hasPrefix("--") else { i += 1; continue }
            let name = String(token.dropFirst(2))
            if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                flags[name] = argv[i + 1]; i += 2
            } else {
                switches.insert(name); i += 1
            }
        }

        func emit(_ object: [String: Any]) {
            let data = (try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                ?? Data("{}".utf8)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            if let path = flags["out"] { try? data.write(to: URL(filePath: path)) }
        }

        guard let directory = flags["dir"], let keyFile = flags["key-file"] else {
            emit(["ok": false,
                  "error": "缺少 --dir 或 --key-file（用法见 Models/NarrativeSmoke.swift 的文件头）"])
            return 2
        }
        let commit = switches.contains("commit")
        let repeats = max(1, Int(flags["repeat"] ?? "2") ?? 2)

        var out: [String: Any] = [
            "tool": "brosis --narrative-smoke",
            "date": ISO8601DateFormatter().string(from: Date()),
            "model": Catalog.generationModelID,
            "hardware": ModelProc.hardwareModel,
            "physicalMemoryMiB": Double(ModelProc.physicalMemory) / ModelBytes.mib,
            "cacheLimitMiB": MLXMemoryPolicy.defaultCacheLimitMiB,
            "thermalStateAtStart": ModelProc.thermalState,
            "commit": commit,
            "repeat": repeats,
        ]

        do {
            let dataDirectory = URL(filePath: (directory as NSString).expandingTildeInPath)
            let modelsRoot = URL(filePath:
                ((flags["models-dir"]
                  ?? ModelStore.defaultRoot(dataDirectory: dataDirectory).path)
                 as NSString).expandingTildeInPath)
            let modelDirectory = ModelStore.directory(root: modelsRoot,
                                                      id: Catalog.generationModelID)
            guard ModelStore.isInstalled(root: modelsRoot, id: Catalog.generationModelID) else {
                out["ok"] = false
                out["error"] = "模型未安装：\(Catalog.generationModelID)（功能显示为未启用）"
                emit(out)
                return 3
            }

            var storeOptions = StoreOptions()
            storeOptions.createIfMissing = false
            let provider = FileKeyProvider(
                url: URL(filePath: (keyFile as NSString).expandingTildeInPath),
                createIfMissing: false)
            let store = try Store.open(directory: dataDirectory, keyProvider: provider,
                                       options: storeOptions)
            defer { store.close() }
            if let tz = flags["tz"], let zone = TimeZone(identifier: tz) {
                store.retrieval.timeZone = zone
            }

            let config = NarrativeScheduler.configuration()
            let target: NarrativeTarget
            if let week = flags["week"] {
                target = .week(week)
            } else if let date = flags["date"] {
                target = .day(date)
            } else {
                // 没指定就挑库里最后一个完整的自然日。
                guard let last = try store.observationDays().dropLast().last
                                 ?? store.observationDays().last else {
                    throw ModelsError("库里没有观察，没什么可叙述的")
                }
                target = .day(last)
            }
            out["requestedTarget"] = ["level": target.level, "period": target.period]

            // 输入与提示（不加载模型也算得出来，先记下来）
            let input = target.level == "week"
                ? try store.narrativeWeekInput(week: target.period, config: config)
                : try store.narrativeDayInput(date: target.period, config: config)
            // 周可以用周内任意一天来指；`ledgers` 行的 period 是规范化之后的 `YYYY-Www`。
            let resolved = NarrativeTarget(level: input.level, period: input.period)
            out["target"] = ["level": resolved.level, "period": resolved.period]
            let estimated = NarrativePromptBuilder.build(input, config: config)
            // `--prompt-out <路径>`：把**喂给模型的那份提示原文**落盘，验收要逐字核对它。
            if let path = flags["prompt-out"] {
                try? (estimated.system + "\n\n----- 台账 -----\n" + estimated.user)
                    .write(to: URL(filePath: path), atomically: true, encoding: .utf8)
            }
            out["promptEstimatedTokens"] = estimated.estimatedTokens
            out["promptCharacters"] = estimated.user.count
            out["compression"] = estimated.compression.label
            out["ledgerObservations"] = input.observations
            out["ledgerSessions"] = input.sessionCount
            out["ledgerApps"] = input.apps.count
            out["memoryBeforeLoad"] = MLXMemoryPolicy.snapshot

            // D27：加载前设 256 MiB 缓冲池
            let model = try MLXGenerationProvider.load(directory: modelDirectory)
            out["loadSeconds"] = model.loadSeconds
            out["memoryAfterLoad"] = MLXMemoryPolicy.snapshot
            // 真实分词器给的 token 数（估算器的校准点）
            let realTokens = model.tokenCount(estimated.system + "\n" + estimated.user)
            out["promptTokensByTokenizer"] = realTokens as Any
            if let realTokens {
                out["estimatorRatio"] = Double(estimated.estimatedTokens) / Double(max(1, realTokens))
            }

            var runs: [[String: Any]] = []
            var answers: [String] = []
            for index in 0..<repeats {
                let report = try store.runNarrative(
                    target, provider: model, config: config,
                    thermalState: ModelProc.thermalState,
                    peakFootprintMiB: Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib)
                answers.append(report.text)
                runs.append([
                    "index": index,
                    "saved": report.saved,
                    "outcome": report.outcome,
                    "inputTokens": report.inputTokens,
                    "inputTokenSource": report.inputTokenSource,
                    "outputTokens": report.outputTokens,
                    "compression": report.compression,
                    "hanCharacters": report.hanCharacters,
                    "truncated": report.truncated,
                    "timeToFirstTokenSeconds": report.timeToFirstTokenSeconds,
                    "tokensPerSecond": report.tokensPerSecond,
                    "elapsedSeconds": report.elapsedSeconds,
                    "stopReason": report.stopReason,
                    "thinkingDetected": report.thinkingDetected,
                    "faithfulnessPassed": report.check?.passed as Any,
                    "violations": (report.check?.violations ?? []).map {
                        ["rule": $0.rule, "detail": $0.detail]
                    },
                    "checkedNumbers": report.check?.checkedNumbers as Any,
                    "checkedApps": report.check?.checkedApps as Any,
                    "text": report.text,
                    "thermalState": ModelProc.thermalState,
                    "memoryAfterRun": MLXMemoryPolicy.snapshot,
                ])
                // 默认不留痕：跑完就把这一轮写进去的叙述清掉（除非 --commit）。
                if !commit {
                    _ = try store.clearNarrative(level: resolved.level, period: resolved.period)
                }
            }
            out["runs"] = runs
            // 温度 0 的确定性：同一输入多次生成必须逐字相同（3.10 / D19 结论 7）
            out["answersIdentical"] = answers.allSatisfy { $0 == answers[0] }
            out["memoryWithModelLoaded"] = MLXMemoryPolicy.snapshot
            let release = model.unload()
            out["release"] = [
                "gpuCacheBeforeMiB": release.gpuCacheBeforeMiB,
                "gpuCacheAfterMiB": release.gpuCacheAfterMiB,
                "footprintBeforeMiB": release.footprintBeforeMiB,
                "footprintAfterMiB": release.footprintAfterMiB,
                "peakFootprintMiB": release.peakFootprintMiB,
                "gpuPeakMiB": release.gpuPeakMiB,
            ]
            out["peakFootprintMiB"] = Double(ModelProc.peakFootprintBytes()) / ModelBytes.mib
            out["thermalStateAtEnd"] = ModelProc.thermalState
            out["ok"] = runs.allSatisfy { ($0["outcome"] as? String) != "failed" }
            emit(out)
            return (out["ok"] as? Bool) == true ? 0 : 1
        } catch {
            out["ok"] = false
            out["error"] = "\(error)"
            emit(out)
            return 1
        }
    }
}
