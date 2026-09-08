import BrosisCore
import BrosisModels
import Foundation

/// M2 c / T11 的自检：模型清单、模型目录、向量索引往返、夜间任务门控、GPU 预算台账。
///
/// **不加载任何模型、不联网、无 GUI、无 TCC、不碰钥匙串**：
/// 向量那一段用 `HashEmbeddingProvider`（确定性伪嵌入，没有语义），
/// 所以这一组在没装模型的机器上照样能跑、照样应该全过。
/// 唯一碰 GPU 的是一次 `MLXSmoke.run()`——它证明 metallib 在位、Metal 真能算，
/// 那是 E9 里最容易在打包后翻车的一环。
///
/// 由 `SelfCheck.run()` 调一次（那边只加一行），失败项数原样返回。
enum ModelsSelfCheck {

    static func run() -> Int {
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        // ------------------------------------------------------------ 1. 清单（3.11 / D18）
        do {
            let catalog = try Catalog.load()
            check("模型清单随包读得到", !catalog.models.isEmpty,
                  "\(catalog.models.count) 项，schemaVersion \(catalog.schemaVersion)")
            // D29：叙述下架，清单里没有生成模型。
            // D30：嵌入模型多尺寸可切换，已批准的是整个 Qwen3-Embedding 家族。
            let approved = catalog.models.filter(\.isApproved)
            check("清单里的每一项都是已批准的 Qwen3-Embedding（D30）",
                  !catalog.models.isEmpty && approved.count == catalog.models.count,
                  catalog.models.map { "\($0.id)\($0.isApproved ? "" : "(未批准)")" }
                      .joined(separator: " "))
            check("清单里不再有生成模型（叙述已下架）",
                  !catalog.models.contains { $0.purpose == "generation" },
                  catalog.models.map { "\($0.id)(\($0.purpose))" }.joined(separator: " "))
            let embeddings = catalog.embeddingModels
            check("嵌入模型有多个尺寸可选（D30：面板里切换，向量维度统一 \(SchemaV4.dimension)）",
                  embeddings.count >= 2 && embeddings.allSatisfy { !$0.files.isEmpty },
                  embeddings.map { "\($0.id) \(ModelBytes.human($0.totalBytes ?? 0))" }
                      .joined(separator: "；"))
            // 内存不够的项必须置灰并说明原因（3.11「不符合本机内存的项置灰并说明原因」）
            let tooBig = catalog.models.filter { !$0.fitsThisMachine }
            check("内存不够的清单项置灰并给出原因",
                  tooBig.allSatisfy { $0.unavailableReason != nil },
                  tooBig.isEmpty
                      ? "本机 \(ModelBytes.human(ModelProc.physicalMemory))，清单里没有超内存的项"
                      : tooBig.map { "\($0.id)：\($0.unavailableReason ?? "?")" }.joined(separator: "；"))
            // E9 验收发现：清单项 files 为空时导入必须拒绝，不能写出空的 installed.json。
            // 清单里原本那个空 files 条目（gemma 高档位）随生成模型一起去掉了，这里就地造一个：
            // 这条验收不能因为清单变短就丢掉覆盖。
            let emptyFilesJSON = "{\"id\":\"selfcheck-empty-files\",\"purpose\":\"embedding\","
                               + "\"source\":\"local-import\",\"repoId\":\"selfcheck/empty\",\"files\":[]}"
            if let placeholder = try? JSONDecoder().decode(
                   CatalogModel.self, from: Data(emptyFilesJSON.utf8)) {
                let staging = FileManager.default.temporaryDirectory
                    .appendingPathComponent("brosis-modelcheck-\(ProcessInfo.processInfo.processIdentifier)",
                                            isDirectory: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                var rejected = false
                do {
                    _ = try ModelStore.importLocal(model: placeholder, from: staging,
                                                    root: staging, schemaVersion: catalog.schemaVersion)
                } catch { rejected = true }
                check("清单项没有文件列表时导入被拒（E9 验收发现）", rejected, placeholder.id)
            }
        } catch {
            check("模型清单随包读得到", false, "\(error)")
        }

        // ------------------------------------------------------------ 2. 模型目录（D18）
        let dataDirectory = DataLocation.resolve().url
        let resolved = ModelStore.resolveRoot(dataDirectory: dataDirectory)
        let expected = ModelStore.defaultRoot(dataDirectory: dataDirectory)
        check("模型目录默认在数据目录里的 models/（D18：不加密、不进 iCloud）",
              resolved.source != "default" || resolved.url.standardizedFileURL == expected.standardizedFileURL,
              "\(resolved.url.lastPathComponent)（来源 \(resolved.source)；"
              + "环境变量键 \(ModelStore.directoryEnvKey)，UserDefaults 键 \(ModelStore.directoryDefaultsKey)）")
        // 2026-09-08 搬过一次家（`<数据目录>/../models` → `<数据目录>/models`）。
        // 搬迁在 app 解锁后做，自检自己不动文件，所以这条**只报告不判失败**。
        let legacyRoot = ModelStore.legacyDefaultRoot(dataDirectory: dataDirectory)
        let legacyLeftovers = ((try? FileManager.default.contentsOfDirectory(
            at: legacyRoot, includingPropertiesForKeys: nil)) ?? [])
            .map(\.lastPathComponent)
            .filter { !$0.hasPrefix(".") }
        check("旧模型目录（数据目录旁的 models/）已搬空", true,
              legacyLeftovers.isEmpty
                  ? "旧目录不在了或已空"
                  : "还剩 \(legacyLeftovers.joined(separator: " "))，app 下次解锁时搬（有 installed.json 的才搬）")
        // D30：当前生效的模型由「用户选过的 → 第一个装着的」决定，这里把解析结果打出来。
        let catalogForSelection = try? Catalog.load()
        let effective = EmbeddingSelection.effectiveID(catalog: catalogForSelection, root: resolved.url)
        let installedIDs = EmbeddingSelection.installedIDs(catalog: catalogForSelection,
                                                          root: resolved.url)
        let installed = effective.map { ModelStore.isInstalled(root: resolved.url, id: $0) } ?? false
        check("未安装嵌入模型时功能显示为「未启用」（3.11 降级表）", true,
              installed ? "本机已装 \(installedIDs.joined(separator: " "))，当前生效 \(effective ?? "?")"
                        : "本机未装嵌入模型 ⇒ 向量检索显示未启用，精确字段与 FTS 不受影响")
        // 选择规则（D30）：在**临时模型根目录 + 临时 UserDefaults 域**上跑三条对照，
        // 造两个假的"已装"模型（只要有 installed.json 就算装着），不碰真实设置与真实权重。
        let selectionSuite = "brosis-selcheck-\(ProcessInfo.processInfo.processIdentifier)"
        if let suite = UserDefaults(suiteName: selectionSuite), let catalogForSelection {
            let fakeRoot = FileManager.default.temporaryDirectory
                .appending(path: selectionSuite, directoryHint: .isDirectory)
            defer {
                try? FileManager.default.removeItem(at: fakeRoot)
                UserDefaults().removePersistentDomain(forName: selectionSuite)
            }
            var ok = true
            for id in ["fake-A", "fake-B"] {
                let dir = fakeRoot.appending(path: id, directoryHint: .isDirectory)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try Data("{}".utf8).write(to: dir.appending(path: "installed.json"))
                } catch { ok = false }
            }
            func effective() -> String? {
                EmbeddingSelection.effectiveID(catalog: catalogForSelection, root: fakeRoot,
                                               defaults: suite)
            }
            EmbeddingSelection.select("fake-B", defaults: suite)
            let chosenAndInstalled = effective()
            EmbeddingSelection.select("模型-并不存在", defaults: suite)
            let chosenButMissing = effective()
            EmbeddingSelection.select(nil, defaults: suite)
            let neverChosen = effective()
            check("选择规则三条：选过且装着 ⇒ 用它；选过没装 ⇒ 退回第一个装着的；没选过 ⇒ 第一个装着的（D30）",
                  ok && chosenAndInstalled == "fake-B" && chosenButMissing == "fake-A"
                     && neverChosen == "fake-A",
                  "\(chosenAndInstalled ?? "nil") / \(chosenButMissing ?? "nil") / \(neverChosen ?? "nil")")
        }

        // -------------------------------------------- 2b. 自动建索引的判定（2026-09-08 用户要求）
        //
        // 「打开时跑一次、之后每小时一次」。这里只测判定这只纯函数：接电与温度那两道门在
        // `OvernightIndexPolicy`（第 4 组已经有 12 条对照），这条只管"要不要踢这一脚"。
        struct AutoCase {
            var label: String
            var enabled = true
            var modelUsable = true
            var running = false
            var pending = 100
            var phase: LockPhase = .unlocked
            var paused = false
            var want: String?
        }
        let autoCases: [AutoCase] = [
            AutoCase(label: "都满足 ⇒ 踢", want: nil),
            AutoCase(label: "开关关着", enabled: false, want: "auto_disabled"),
            AutoCase(label: "没有可用模型", modelUsable: false, want: "model_not_installed"),
            AutoCase(label: "上一轮还在跑 ⇒ 不叠加", running: true, want: "already_running"),
            AutoCase(label: "没有待办的块", pending: 0, want: "nothing_pending"),
            AutoCase(label: "库锁着", phase: .locked, want: "locked_locked"),
            AutoCase(label: "采集暂停", paused: true, want: "paused"),
            // 顺序：开关 > 模型 > 锁 > 暂停 > 在跑 > 待办。锁着时不该报"没待办"。
            AutoCase(label: "锁着且没待办 ⇒ 先报锁", pending: 0, phase: .locked, want: "locked_locked"),
        ]
        var autoFailures: [String] = []
        for c in autoCases {
            let got = AutoIndexScheduler.decide(enabled: c.enabled, modelUsable: c.modelUsable,
                                                alreadyRunning: c.running, pendingChunks: c.pending,
                                                lockPhase: c.phase, paused: c.paused)
            if got != c.want {
                autoFailures.append("\(c.label)→\(got ?? "踢")（期望 \(c.want ?? "踢")）")
            }
        }
        check("自动建索引判定 \(autoCases.count) 条（开关 / 模型 / 锁 / 暂停 / 在跑 / 待办，含优先级）",
              autoFailures.isEmpty,
              autoFailures.isEmpty
                  ? "默认开，打开时延迟 \(Int(AutoIndexScheduler.launchDelaySeconds)) s 跑第一次，"
                    + "之后每 \(Int(AutoIndexScheduler.intervalMinutes)) 分钟一次；"
                    + "接电与温度的门在 OvernightIndexPolicy"
                  : autoFailures.joined(separator: " "))

        // ------------------------------------------------------------ 3. 向量索引往返（v4）
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("brosis-veccheck-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            var options = StoreOptions()
            options.deviceID = "selfcheck-vectors"
            let store = try Store.open(directory: workspace,
                                       keyProvider: try InMemoryKeyProvider.random(),
                                       options: options)
            defer { store.close() }

            let status0 = try store.vectorStatus()
            check("schema v4：chunks / vec_chunks 建好了", status0.tablePresent && status0.chunks == 0,
                  "维度 \(status0.dimension)（\(status0.elementType)），"
                  + "sqlite-vec \(status0.sqliteVecVersion)，已注册 \(status0.extensionRegistered)")
            check("core 里新开的库向量开关默认关（3.4 / 4.3；app 解锁时按 retrieval.vectorsEnabled 恢复，"
              + "装了模型且用户没显式关过就默认开）", !store.retrieval.vectorsEnabled)

            // 运行时拼出来的稀有词，不让它以字面量形式留在二进制里
            let marker = "自检向量标记" + ["Z", "Q", String(4_217)].joined()
            var targetID: Int64 = 0
            for i in 0..<6 {
                let body = i == 3
                    ? "\(marker) 出现在这一段里，后面再补一点长度好切出一整块。"
                    : "干扰正文第 \(i) 段，长度也够切出一块来，内容与目标无关。"
                let result = try store.record(ObservationInput(
                    ts: Recorder.milliseconds() - Int64(i) * 60_000,
                    displayID: 1,
                    app: AppRef(bundleID: "com.brosis.selfcheck", name: "brosis 自检"),
                    windowTitle: "自检窗口",
                    trigger: ObservationTrigger.selfCheck.coreTrigger,
                    captureMethod: .ax, completeness: .complete, sourceState: .ok,
                    texts: [TextFragment(text: body, region: "AXStaticText")]))
                if i == 3 { targetID = result.observationID }
            }

            // ① 模型没装时的降级：开关开着、也给了向量，但库里一条向量都没有
            store.retrieval.vectorsEnabled = true
            let provider = HashEmbeddingProvider()
            let queryVector = try provider.embed([marker])[0]
            let degraded = try store.search(q: marker, limit: 10, queryVector: queryVector)
            check("模型未装（索引为空）时向量通道标记为不可用并降级",
                  degraded.vectorsUnavailable && degraded.vectorUnavailableReason == "no_index"
                    && degraded.fusion == "union" && !degraded.hits.isEmpty,
                  "原因 \(degraded.vectorUnavailableReason ?? "nil")，"
                  + "FTS 仍命中 \(degraded.hits.count) 条")

            // ② 跑一次嵌入任务（伪嵌入），再查
            let report = try store.runEmbeddingJob(provider: provider,
                                                   options: EmbeddingJobOptions(batchSize: 4))
            check("嵌入任务：分块 → 嵌入 → 写 vec_chunks",
                  report.state == "done" && report.chunksEmbedded == 6 && report.chunksRemaining == 0,
                  "\(report.chunksEmbedded) 块 / \(report.batches) 批，"
                  + "provider \(String(format: "%.3f", report.providerSeconds)) s")

            // 伪嵌入没有语义，距离普遍在 0.4 以上，产品默认闸（0.40）会把它们全挡掉；
            // 这里把闸门开到最大，好让向量通道**真的**参与，断言才有意义。
            store.retrieval.vectorMaxDistance = 2
            let hybrid = try store.search(q: marker, limit: 10, queryVector: queryVector)
            check("向量开着时走加权 RRF、向量通道真的参与、且精确命中仍排第一",
                  !hybrid.vectorsUnavailable && hybrid.fusion == "rrf"
                    && hybrid.channels.contains(.vector)
                    && hybrid.vectorObservations > 0
                    && hybrid.hits.first?.evidenceID == targetID,
                  "候选 \(hybrid.vectorCandidates) 块、展开 \(hybrid.vectorObservations) 条观察，"
                  + "最好距离 " + String(format: "%.4f", hybrid.vectorBestDistance ?? -1))
            check("向量通道给的命中带余弦距离（调用方的可信度信号）",
                  hybrid.hits.filter { $0.channel == .vector }
                        .allSatisfy { ($0.vectorDistance ?? -1) >= 0 },
                  "\(hybrid.hits.filter { $0.channel == .vector }.count) 条向量命中")
            // 闸门收回产品默认值，后面那条"开关关闭"的断言才是在默认配置下测的
            store.retrieval.vectorMaxDistance = RetrievalOptions().vectorMaxDistance

            // ③ 开关关掉 ⇒ 一次向量调用都不发
            store.retrieval.vectorsEnabled = false
            let off = try store.search(q: marker, limit: 10, queryVector: queryVector)
            check("开关关闭时无向量调用（通道不参与、fusion 退回 union）",
                  off.vectorsUnavailable && off.vectorUnavailableReason == "disabled"
                    && off.fusion == "union" && off.vectorCandidates == 0
                    && !off.channels.contains(.vector),
                  "原因 \(off.vectorUnavailableReason ?? "nil")")

            // ④ 删除级联：chunks 随外键走，vec_chunks 显式删
            let summary = try store.deleteObservations([targetID])
            let after = try store.vectorStatus()
            check("删除级联覆盖 chunks / vec_chunks",
                  summary.chunksDeleted == 1 && after.chunks == 5 && after.vectorRows == 5,
                  "块 \(after.chunks)、向量行 \(after.vectorRows)、"
                  + "本次删掉 \(summary.chunksDeleted) 块")
            check("删除之后一致性检查仍然全过（含 v4 三项）",
                  try store.integrityReport().allPassed)
        } catch {
            check("向量索引往返", false, "\(error)")
        }

        // ------------------------------------------------------------ 4. 夜间任务门控（纯函数）
        var base = EmbeddingGateInput(
            onACPower: true, idleSeconds: 600, thermalState: "nominal",
            lockPhase: .unlocked, paused: false, modelInstalled: true, enabledByUser: true,
            usedGPUSecondsToday: 0, budgetGPUSeconds: 600, pendingChunks: 100)
        var gateFailures = 0
        func gate(_ label: String, _ mutate: (inout EmbeddingGateInput) -> Void,
                  expect: EmbeddingGateDecision) {
            var input = base
            mutate(&input)
            let got = EmbeddingGatePolicy.decide(input)
            if got != expect {
                gateFailures += 1
                print("      门控用例不符：\(label) 期望 \(expect)，实得 \(got)")
            }
        }
        gate("全部满足", { _ in }, expect: .run)
        gate("用户没开", { $0.enabledByUser = false }, expect: .skip("disabled_by_user"))
        gate("模型没装", { $0.modelInstalled = false }, expect: .skip("model_not_installed"))
        gate("没有待办", { $0.pendingChunks = 0 }, expect: .skip("nothing_pending"))
        gate("库锁着", { $0.lockPhase = .locked }, expect: .skip("locked_locked"))
        gate("采集暂停（锁屏）", { $0.paused = true }, expect: .skip("paused"))
        gate("在用电池", { $0.onACPower = false }, expect: .skip("on_battery"))
        gate("空闲不足 5 分钟", { $0.idleSeconds = 299 }, expect: .skip("not_idle"))
        gate("刚好 5 分钟", { $0.idleSeconds = 300 }, expect: .run)
        gate("热状态 fair 暂停", { $0.thermalState = "fair" }, expect: .skip("thermal_fair"))
        gate("热状态 serious 暂停", { $0.thermalState = "serious" }, expect: .skip("thermal_serious"))
        gate("GPU 预算用完", { $0.usedGPUSecondsToday = 600 }, expect: .skip("gpu_budget_exhausted"))
        gate("GPU 预算还剩一点", { $0.usedGPUSecondsToday = 599.5 }, expect: .run)
        base.enabledByUser = false
        gate("没开时优先报「没开」而不是「没装模型」", { $0.modelInstalled = false },
             expect: .skip("disabled_by_user"))
        check("夜间任务门控 14 条用例（接电 / 空闲 5 分钟 / 温度 / 锁定 / 预算）",
              gateFailures == 0, "失败 \(gateFailures) 条")

        // 门控的三个**真实**输入也要各调一次：纯函数测不到它们，而它们里面有
        // 「Swift 没有对应 enum case、只能用原始值构造」这类容易在别的 SDK 上翻车的写法。
        let idle = EmbeddingEnvironment.idleSeconds()
        let onPower = EmbeddingEnvironment.onACPower()
        check("空闲秒数读得出来（不需要辅助功能权限，也不读事件内容）",
              idle.isFinite && idle >= 0, String(format: "%.1f s", idle))
        check("电源状态读得出来（IOKit，不触发任何授权）", true,
              onPower ? "接电" : "电池")
        check("热状态读得出来", ["nominal", "fair", "serious", "critical"]
                .contains(ModelProc.thermalState), ModelProc.thermalState)

        // ------------------------------------------------------------ 5. GPU 预算台账
        let suiteName = "brosis-selfcheck-budget-\(ProcessInfo.processInfo.processIdentifier)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let ledger = GPUBudgetLedger(defaults: defaults, budgetSeconds: 600)
            let day1 = Date(timeIntervalSince1970: 1_788_000_000)
            let day2 = day1.addingTimeInterval(86_400 * 2)
            _ = ledger.add(seconds: 120, now: day1)
            let total = ledger.add(seconds: 90, now: day1)
            check("GPU 预算台账累加",
                  abs(total - 210) < 1e-6 && abs(ledger.remaining(now: day1) - 390) < 1e-6,
                  "今日 \(total) s / 预算 \(Int(ledger.budgetSeconds)) s")
            check("GPU 预算跨日归零", abs(ledger.usedToday(now: day2)) < 1e-6,
                  "第三天读回 \(ledger.usedToday(now: day2)) s")
        }

        // ------------------------------------------------------------ 6. GPU 冒烟（metallib）
        let smoke = MLXSmoke.run()
        check("Metal 着色器库在位、GPU 真能算（E9 打包后最容易翻车的一环）",
              (smoke["ok"] as? Bool) == true,
              "metallib \(smoke["metallib"] as? String ?? "?")，"
              + "结果 \(smoke["value"] as? Double ?? -1)")

        print("      MLX 缓冲池策略（D27）：加载前 cacheLimit = "
              + "\(MLXMemoryPolicy.defaultCacheLimitMiB) MiB，任务结束 clearCache()；"
              + "本机 \(ModelProc.hardwareModel)，内存 "
              + ModelBytes.human(ModelProc.physicalMemory)
              + "，热状态 \(ModelProc.thermalState)")
        print("      向量索引：\(SchemaV4.elementType)[\(SchemaV4.dimension)] cosine"
              + "（512 维依据：E9 实测 MRL 截断 512 维 Recall@10 0.925 / 256 维 0.90）；"
              + "夜间任务默认预算 \(Int(EmbeddingGatePolicy.defaultBudgetSeconds)) s，"
              + "UserDefaults 键 \(EmbeddingGatePolicy.enabledKey) / \(EmbeddingGatePolicy.budgetKey)")
        return failures
    }
}
