import BrosisCore
import BrosisIPC
import BrosisModels
import Foundation

/// M2 d / T15 的自检：MCP 检索的查询向量这一段。
///
/// **不加载任何模型、无 GUI、无 TCC、不碰钥匙串**：
/// 查询嵌入器用 `ProviderQueryEmbedder(HashEmbeddingProvider())`（确定性伪嵌入，无语义），
/// 真实模型那一层在 `brosis-embed selftest` 与 `tools/eval/d8_mcp_compare.py` 里。
///
/// 五组：
///  1. 经 `StoreMCPService.search`（也就是 MCP 真正走的那条路）的向量通道：注入 nil vs 注入嵌入器；
///  2. **零模型调用**：开关关、字段前缀、库锁着；
///  3. 常驻 + 空闲卸载状态机的五种事件；
///  4. 「整晚建索引」的门控与夜间增量门控的**逐条差异**；
///  5. 进度（速率 / 预计剩余）与整晚 GPU 单独记账。
///
/// 由 `SelfCheck.run()` 调一次（那边只加一行），失败项数原样返回。
enum QueryEmbedderSelfCheck {

    static func run() -> Int {
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        // ------------------------------------------------ 1 / 2. 经 StoreMCPService 的检索
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("brosis-qveccheck-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            var options = StoreOptions()
            options.deviceID = "selfcheck-qvec"
            let store = try Store.open(directory: workspace,
                                       keyProvider: try InMemoryKeyProvider.random(),
                                       options: options)
            defer { store.close() }
            store.retrieval.timeZone = TimeZone(identifier: "UTC")!

            // 运行时拼出来的稀有词，不让它以字面量形式留在二进制里
            let marker = "查询向量标记" + ["V", "M", String(9_182)].joined()
            for i in 0..<6 {
                let body = i == 2
                    ? "\(marker) 写在这一段里，后面补一点长度好切出一整块来。"
                    : "干扰正文第 \(i) 段，长度也够切出一块，内容与目标无关。"
                _ = try store.record(ObservationInput(
                    ts: Recorder.milliseconds() - Int64(i) * 60_000,
                    displayID: 1,
                    app: AppRef(bundleID: "com.brosis.selfcheck", name: "brosis 自检"),
                    windowTitle: "自检窗口", url: EventSkeleton.urlRef("https://docs.invalid/qvec"),
                    trigger: ObservationTrigger.selfCheck.coreTrigger,
                    captureMethod: .ax, completeness: .complete, sourceState: .ok,
                    texts: [TextFragment(text: body, region: "AXStaticText")]))
            }
            try store.setGrant(Grant(clientID: "selfcheck", mode: .strictLocal, apps: ["*"],
                                     timeWindowDays: 30, fields: .summary))
            _ = try store.runEmbeddingJob(provider: HashEmbeddingProvider(),
                                          options: EmbeddingJobOptions(batchSize: 3))

            let embedder = ProviderQueryEmbedder(HashEmbeddingProvider())
            func search(_ q: String, service: StoreMCPService) -> [String: JSONValue] {
                let response = service.handle(IPCCall(
                    request: IPCRequest(client: "selfcheck", op: .tool,
                                        name: MCPTool.search.rawValue,
                                        args: ["q": .string(q), "limit": .int(10)]),
                    peer: PeerInfo(uid: getuid(), gid: getgid(), pid: getpid(),
                                   teamID: nil, signingID: nil, codeSigningVerified: true,
                                   codeSigningNote: "selfcheck"),
                    refusal: nil, rateUsed: 1, rateLimit: 60))
                return response.result?.objectValue ?? [:]
            }

            // ① 没注入嵌入器：与 c 批逐位相同的老行为
            store.retrieval.vectorsEnabled = true
            let plain = search(marker, service: StoreMCPService(store: store))
            check("MCP search 没有查询嵌入器时降级为 no_query_vector（与 c 批相同）",
                  plain["vectorUnavailableReason"]?.stringValue == "no_query_vector"
                    && plain["fusion"]?.stringValue == "union"
                    && (plain["hitCount"]?.intValue ?? 0) > 0,
                  "原因 \(plain["vectorUnavailableReason"]?.stringValue ?? "nil")，"
                  + "命中 \(plain["hitCount"]?.intValue ?? 0) 条")

            // ② 注入之后向量通道真的参与，而且带上了查询嵌入的耗时
            store.retrieval.vectorMaxDistance = 2      // 伪嵌入距离普遍 > 0.4，开闸才量得到
            let service = StoreMCPService(store: store, queryEmbedder: embedder)
            let hybrid = search(marker, service: service)
            let timing = hybrid["queryEmbed"]?.objectValue ?? [:]
            check("MCP search 注入查询嵌入器之后走加权 RRF、向量通道参与",
                  hybrid["vectorsUnavailable"]?.boolValue == false
                    && hybrid["fusion"]?.stringValue == "rrf"
                    && (hybrid["vectorCandidates"]?.intValue ?? 0) > 0,
                  "候选 \(hybrid["vectorCandidates"]?.intValue ?? 0) 块")
            let embedMS = timing["elapsedMS"]?.doubleValue ?? -1
            check("查询嵌入耗时随结果返回（3.4 分层目标 ≤ \(Int(QueryEmbedTiming.hotBudgetMS)) ms）",
                  timing["source"]?.stringValue == "embedder"
                    && embedMS >= 0
                    && timing["dimension"]?.intValue == Int64(SchemaV4.dimension),
                  String(format: "source=%@ %.3f ms 维度 %d",
                         timing["source"]?.stringValue ?? "?", embedMS,
                         timing["dimension"]?.intValue ?? -1))
            store.retrieval.vectorMaxDistance = RetrievalOptions().vectorMaxDistance

            // ③ 零模型调用：开关关 + 字段前缀
            let before = embedder.callCount
            store.retrieval.vectorsEnabled = false
            _ = search(marker, service: service)
            let afterDisabled = embedder.callCount
            store.retrieval.vectorsEnabled = true
            _ = search("app:com.brosis.selfcheck", service: service)
            _ = search("host:docs.invalid", service: service)
            let afterPrefix = embedder.callCount
            check("开关关闭时零模型调用", afterDisabled == before, "调用次数 \(before) → \(afterDisabled)")
            check("带字段前缀的查询零模型调用（本来就不走向量通道）",
                  afterPrefix == afterDisabled, "调用次数 \(afterDisabled) → \(afterPrefix)")

            // ④ 库锁着 / 采集暂停：MCPGate 连 service 都不交出去
            let locked = MCPGate { (.locked, nil) }
            let paused = MCPGate { (.paused, service) }
            let call = IPCCall(request: IPCRequest(client: "selfcheck", op: .tool,
                                                   name: MCPTool.search.rawValue,
                                                   args: ["q": .string(marker)]),
                               peer: PeerInfo(uid: getuid(), gid: getgid(), pid: getpid(),
                                              teamID: nil, signingID: nil,
                                              codeSigningVerified: true, codeSigningNote: "selfcheck"),
                               refusal: nil, rateUsed: 1, rateLimit: 60)
            let lockedResponse = locked.handle(call)
            let pausedResponse = paused.handle(call)
            check("锁定 / 暂停时 MCP 拒绝且零模型调用（3.5）",
                  !lockedResponse.ok && !pausedResponse.ok && embedder.callCount == afterPrefix,
                  "locked=\(lockedResponse.error?.code.rawValue ?? "-") "
                  + "paused=\(pausedResponse.error?.code.rawValue ?? "-") "
                  + "调用次数仍是 \(embedder.callCount)")
        } catch {
            check("MCP 检索的查询向量往返", false, "\(error)")
        }

        // ------------------------------------------------ 3. 空闲卸载状态机（纯函数）
        var machineFailures = 0
        func machine(_ label: String, _ state: QueryEmbedderState, _ event: QueryEmbedderEvent,
                     expect: QueryEmbedderAction) {
            let got = QueryEmbedderPolicy.next(state, on: event).action
            if got != expect {
                machineFailures += 1
                print("      状态机用例不符：\(label) 期望 \(expect)，实得 \(got)")
            }
        }
        let cold = QueryEmbedderState()
        let hot = QueryEmbedderState(loaded: true, lastQueryAt: 1_000)
        machine("冷态来查询 → 加载", cold, .query(at: 1), expect: .load)
        machine("热态来查询 → 复用", hot, .query(at: 1_050), expect: .reuse)
        machine("空闲 599 s → 不动", hot, .tick(at: 1_599), expect: .none)
        machine("空闲 600 s → 卸载", hot, .tick(at: 1_600), expect: .unload("idle_600s"))
        machine("锁屏 / 暂停 → 立刻卸载", hot, .paused, expect: .unload("paused"))
        machine("关库 → 立刻卸载", hot, .storeClosed, expect: .unload("store_closed"))
        machine("用户关开关 → 立刻卸载", hot, .disabledByUser, expect: .unload("disabled_by_user"))
        machine("冷态收到锁屏 → 空操作", cold, .paused, expect: .none)
        machine("冷态收到关库 → 空操作", cold, .storeClosed, expect: .none)
        machine("冷态 tick → 空操作", cold, .tick(at: 99_999), expect: .none)
        check("查询嵌入器空闲卸载状态机 10 条用例（加载 / 使用 / 空闲 / 锁定 / 关库）",
              machineFailures == 0, "失败 \(machineFailures) 条；"
              + "空闲门槛 \(Int(QueryEmbedderPolicy.idleUnloadSeconds)) s、"
              + "cacheLimit \(MLXMemoryPolicy.defaultCacheLimitMiB) MiB（D27）")

        // ------------------------------------------------ 4. 「整晚建索引」的门控
        //
        // 逐条对照夜间增量门控：**只有三处该不一样**（空闲、日预算、夜间开关），
        // 其余每一条都必须一致。写成对照表而不是各测各的，
        // 免得将来有人改了一边忘了另一边。
        let base = EmbeddingGateInput(
            onACPower: true, idleSeconds: 600, thermalState: "nominal",
            lockPhase: .unlocked, paused: false, modelInstalled: true, enabledByUser: true,
            usedGPUSecondsToday: 0, budgetGPUSeconds: 600, pendingChunks: 100)
        var diffFailures = 0
        func compare(_ label: String, _ mutate: (inout EmbeddingGateInput) -> Void,
                     nightly: EmbeddingGateDecision, overnight: OvernightDecision,
                     cancelled: Bool = false) {
            var input = base
            mutate(&input)
            let gotNightly = EmbeddingGatePolicy.decide(input)
            let gotOvernight = OvernightIndexPolicy.decide(input, cancelled: cancelled)
            if gotNightly != nightly || gotOvernight != overnight {
                diffFailures += 1
                print("      整晚门控对照不符：\(label) 期望 夜间 \(nightly) / 整晚 \(overnight)，"
                      + "实得 夜间 \(gotNightly) / 整晚 \(gotOvernight)")
            }
        }
        // —— 三处**故意不一样**的 ——
        compare("差异①：机器在用 ⇒ 夜间不跑，整晚照跑（用户按了按钮，知道机器要忙）",
                { $0.idleSeconds = 0 }, nightly: .skip("not_idle"), overnight: .run)
        compare("差异②：日 GPU 预算用完 ⇒ 夜间停，整晚照跑（单独记账）",
                { $0.usedGPUSecondsToday = 600 },
                nightly: .skip("gpu_budget_exhausted"), overnight: .run)
        compare("差异③：夜间自动开关没开 ⇒ 夜间不跑，整晚照跑（它本身就是显式动作）",
                { $0.enabledByUser = false },
                nightly: .skip("disabled_by_user"), overnight: .run)
        // —— 其余每一条都**一样** ——
        compare("一致：全部满足", { _ in }, nightly: .run, overnight: .run)
        compare("一致：模型没装", { $0.modelInstalled = false },
                nightly: .skip("model_not_installed"), overnight: .stop("model_not_installed"))
        compare("一致：没有待办的块", { $0.pendingChunks = 0 },
                nightly: .skip("nothing_pending"), overnight: .stop("complete"))
        compare("一致：库锁着", { $0.lockPhase = .locked },
                nightly: .skip("locked_locked"), overnight: .stop("locked_locked"))
        compare("一致：采集暂停（锁屏）", { $0.paused = true },
                nightly: .skip("paused"), overnight: .stop("paused"))
        compare("一致（口径不同）：在用电池 ⇒ 夜间不跑，整晚**暂停**等接电",
                { $0.onACPower = false },
                nightly: .skip("on_battery"), overnight: .pause("on_battery"))
        compare("一致（口径不同）：thermal fair ⇒ 夜间不跑，整晚**暂停**等降温",
                { $0.thermalState = "fair" },
                nightly: .skip("thermal_fair"), overnight: .pause("thermal_fair"))
        compare("一致：thermal serious ⇒ 两边都停", { $0.thermalState = "serious" },
                nightly: .skip("thermal_serious"), overnight: .stop("thermal_serious"))
        compare("一致：thermal critical ⇒ 两边都停", { $0.thermalState = "critical" },
                nightly: .skip("thermal_critical"), overnight: .stop("thermal_critical"))
        compare("取消优先于一切", { _ in }, nightly: .run, overnight: .stop("cancelled"),
                cancelled: true)
        check("「整晚建索引」门控 12 条对照用例（与夜间增量的差异逐条断言）",
              diffFailures == 0, "失败 \(diffFailures) 条")

        // ------------------------------------------------ 5. 进度与单独记账
        let progress = OvernightProgress.make(embedded: 4_000, remaining: 42_545,
                                              elapsedSeconds: 500, gpuSeconds: 480)
        check("进度：百分比 / 速率 / 预计剩余都算得出",
              progress.total == 46_545
                && abs((progress.chunksPerSecond ?? 0) - 8) < 1e-9
                && abs((progress.etaSeconds ?? 0) - 42_545.0 / 8.0) < 1e-6,
              progress.text)
        let cold2 = OvernightProgress.make(embedded: 0, remaining: 100, elapsedSeconds: 0.2,
                                           gpuSeconds: 0)
        check("进度：还没跑够 1 秒时不瞎报速率",
              cold2.chunksPerSecond == nil && cold2.etaSeconds == nil, cold2.text)

        let suiteName = "brosis-selfcheck-overnight-\(ProcessInfo.processInfo.processIdentifier)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let overnight = OvernightGPULedger(defaults: defaults)
            let nightly = GPUBudgetLedger(defaults: defaults, budgetSeconds: 600)
            let day = Date(timeIntervalSince1970: 1_788_000_000)
            _ = overnight.add(seconds: 5_400, now: day)      // 一夜 1.5 小时
            _ = nightly.add(seconds: 120, now: day)
            check("整晚建索引的 GPU 单独记账，不吞掉夜间增量的日预算",
                  abs(overnight.usedToday(now: day) - 5_400) < 1e-6
                    && abs(nightly.usedToday(now: day) - 120) < 1e-6
                    && abs(nightly.remaining(now: day) - 480) < 1e-6,
                  "整晚 \(Int(overnight.usedToday(now: day))) s / "
                  + "夜间 \(Int(nightly.usedToday(now: day))) s，夜间还剩 "
                  + "\(Int(nightly.remaining(now: day))) s")
            check("整晚记账跨日归零",
                  overnight.usedToday(now: day.addingTimeInterval(86_400 * 2)) == 0)
        }

        print("      查询嵌入器：模型 \(Catalog.embeddingModelID)、批构造固定 1、"
              + "空闲 \(Int(QueryEmbedderPolicy.idleUnloadSeconds)) s 卸载、"
              + "cacheLimit \(MLXMemoryPolicy.defaultCacheLimitMiB) MiB（D27）；"
              + "开关键 \(QueryEmbedderService.vectorsEnabledKey)；"
              + "整晚建索引记账键 \(OvernightGPULedger.usedKey)")
        return failures
    }
}
