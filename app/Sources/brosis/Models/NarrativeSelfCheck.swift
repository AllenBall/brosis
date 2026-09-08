import BrosisCore
import BrosisModels
import Foundation

/// M2 c / T12 的自检：夜间叙述的门控、提示裁剪、忠实度核对、端到端入库与丢弃。
///
/// **不加载任何模型、不联网、无 GUI、无 TCC、不碰钥匙串**：
/// 生成侧用 `ScriptedGenerationProvider`（脚本化假提供方），
/// 所以这一组在没装 2.85 GiB 生成模型的机器上照样能跑、照样应该全过。
/// 真实模型那一次跑在 `brosis --narrative-smoke` 里（约 30 s，故意不进默认自检）。
///
/// 由 `SelfCheck.run()` 调一次（那边只加一行），失败项数原样返回。
enum NarrativeSelfCheck {

    static func run() -> Int {
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        // ------------------------------------------------ 1. 门控（纯函数，15 条用例）
        var base = NarrativeGateInput(
            onACPower: true, idleSeconds: 600, thermalState: "nominal",
            lockPhase: .unlocked, paused: false, modelInstalled: true, enabledByUser: true,
            usedGPUSecondsToday: 0, budgetGPUSeconds: 600, pendingTargets: 2)
        var gateFailures = 0
        func gate(_ label: String, _ mutate: (inout NarrativeGateInput) -> Void,
                  expect: EmbeddingGateDecision) {
            var input = base
            mutate(&input)
            let got = NarrativeGatePolicy.decide(input)
            if got != expect {
                gateFailures += 1
                print("      叙述门控用例不符：\(label) 期望 \(expect)，实得 \(got)")
            }
        }
        gate("全部满足", { _ in }, expect: .run)
        gate("用户没开", { $0.enabledByUser = false }, expect: .skip("disabled_by_user"))
        gate("生成模型没装", { $0.modelInstalled = false }, expect: .skip("model_not_installed"))
        gate("没有待写的叙述", { $0.pendingTargets = 0 }, expect: .skip("nothing_pending"))
        gate("库锁着", { $0.lockPhase = .locked }, expect: .skip("locked_locked"))
        gate("采集暂停（锁屏）", { $0.paused = true }, expect: .skip("paused"))
        gate("在用电池", { $0.onACPower = false }, expect: .skip("on_battery"))
        gate("空闲不足 5 分钟", { $0.idleSeconds = 299 }, expect: .skip("not_idle"))
        gate("刚好 5 分钟", { $0.idleSeconds = 300 }, expect: .run)
        gate("热状态 fair 暂停（D27：Air 持续负载 2 分 10 秒转 fair）",
             { $0.thermalState = "fair" }, expect: .skip("thermal_fair"))
        gate("热状态 serious 暂停", { $0.thermalState = "serious" }, expect: .skip("thermal_serious"))
        gate("GPU 预算用完", { $0.usedGPUSecondsToday = 600 }, expect: .skip("gpu_budget_exhausted"))
        gate("GPU 预算还剩一点", { $0.usedGPUSecondsToday = 599.5 }, expect: .run)
        base.enabledByUser = false
        gate("没开时优先报「没开」而不是「没装模型」", { $0.modelInstalled = false },
             expect: .skip("disabled_by_user"))
        base.enabledByUser = true
        gate("没装模型时优先报「没装」而不是「没接电」",
             { $0.modelInstalled = false; $0.onACPower = false },
             expect: .skip("model_not_installed"))
        check("夜间叙述门控 15 条用例（接电 / 空闲 5 分钟 / 温度 / 锁定 / 预算 / 顺序）",
              gateFailures == 0, "失败 \(gateFailures) 条")

        // 预算与嵌入任务**共用一本账**（4.3 的「日均 GPU < 10 分钟」是两个任务合计）
        check("叙述与嵌入共用同一本每日 GPU 预算账",
              GPUBudgetLedger.usedKey == "embedding.gpuSecondsUsed"
                && EmbeddingGatePolicy.budgetKey == "embedding.dailyGPUSeconds",
              "预算键 \(EmbeddingGatePolicy.budgetKey)，默认 "
              + "\(Int(EmbeddingGatePolicy.defaultBudgetSeconds)) s")

        // ------------------------------------------------ 2. 生成参数：两条硬约束
        let options = GenerationOptions()
        check("生成参数：温度 0（3.10）、关闭思考（D19 硬性约束）、输入上限 8,000 token",
              options.temperature == 0 && !options.enableThinking
                && NarrativeConfig().maxInputTokens == 8_000,
              "temperature \(options.temperature)，enableThinking \(options.enableThinking)，"
              + "max tokens \(options.maxTokens)，超时 \(Int(options.timeoutSeconds)) s，"
              + "未见 </think> 中止阈值 \(options.thinkingAbortTokens) token，"
              + "重试 \(options.retries) 次")

        // ------------------------------------------------ 3. 提示构造、裁剪与端到端
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("brosis-narrcheck-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        do {
            var storeOptions = StoreOptions()
            storeOptions.deviceID = "selfcheck-narrative"
            let store = try Store.open(directory: workspace,
                                       keyProvider: try InMemoryKeyProvider.random(),
                                       options: storeOptions)
            defer { store.close() }
            store.retrieval.timeZone = TimeZone(identifier: "UTC")!

            // 一天：上午飞书、上午 Xcode（正文里带待办）、下午 Safari。与 D19 那份台账同构。
            let dayStart: Int64 = 1_756_944_000_000        // 2025-09-04T00:00:00Z
            let day = "2025-09-04"
            // 待办标记运行时拼出来，不让它以字面量形式留在二进制里当"示例正文"。
            let todoMark = ["TO", "DO"].joined()
            var batch: [ObservationInput] = []
            func rows(_ hour: Int64, bundle: String, name: String, window: String, text: String) {
                for i in 0..<5 {
                    batch.append(ObservationInput(
                        ts: dayStart + hour * 3_600_000 + Int64(i) * 300_000, displayID: 1,
                        app: AppRef(bundleID: bundle, name: name), windowTitle: window,
                        trigger: ObservationTrigger.selfCheck.coreTrigger,
                        captureMethod: .ax, completeness: .complete, sourceState: .ok,
                        texts: [TextFragment(text: text, region: "AXStaticText")]))
                }
            }
            rows(9, bundle: "com.electron.lark", name: "飞书", window: "群聊 · 采集器",
                 text: "采集器在 Air 上跑了 6 小时没崩，内存峰值 1.6 GiB。")
            rows(10, bundle: "com.apple.dt.Xcode", name: "Xcode",
                 window: "FrontmostObserver.swift",
                 text: "// \(todoMark): 切换事件在锁屏之后会漏一条，需要补一个监听。")
            rows(14, bundle: "com.apple.Safari", name: "Safari", window: "Metal 缓冲池讨论",
                 text: "论坛里在讨论 Metal 缓冲池的上限设置与内存占用。")
            try store.record(batch: batch)
            try store.buildSessions(force: true)

            let input = try store.narrativeDayInput(date: day)
            let prompt = NarrativePromptBuilder.build(input)
            let again = NarrativePromptBuilder.build(input)
            check("提示构造是确定性的（同一份台账两次逐字相同）", prompt.user == again.user)
            check("提示落在 8,000 token 闸门内（D19：TTFT 约 23.5 s）",
                  prompt.estimatedTokens <= NarrativeConfig().maxInputTokens
                    && !prompt.hardTruncated,
                  "估算 \(prompt.estimatedTokens) token，压缩等级 \(prompt.compression.label)，"
                  + "正文 \(prompt.user.count) 字符")
            check("系统指令带全三条禁令（禁编造 / 待办不得说成完成 / 时段不得错）",
                  prompt.system.contains("禁止编造") && prompt.system.contains("待办（未完成）")
                    && prompt.system.contains("不得把上午的事写成下午"))

            // 大台账的逐级压缩
            var big = input
            big.apps = (0..<120).map {
                NarrativeAppLine(bundleID: "com.example.app\($0)", name: "示例应用编号\($0)",
                                 dwellS: Double(3600 - $0), activeS: 100, switches: $0 + 1,
                                 firstTS: dayStart, lastTS: dayStart + 600_000)
            }
            big.sessions = (0..<120).map {
                NarrativeSessionLine(
                    start: dayStart + Int64($0) * 300_000,
                    end: dayStart + Int64($0) * 300_000 + 240_000,
                    bundleID: "com.example.app\($0)", appName: "示例应用编号\($0)",
                    dwellS: 240, interruptions: 0,
                    windowTitles: ["用来把提示撑长的窗口标题编号\($0)"],
                    excerpt: String(repeating: "这是一段用来把提示撑得很长的合成屏幕正文。", count: 6),
                    hasTODO: false)
            }
            let compressed = NarrativePromptBuilder.build(big)
            check("大台账逐级压缩后仍在闸门内（按应用 / 会话摘要压缩）",
                  compressed.estimatedTokens <= NarrativeConfig().maxInputTokens
                    && compressed.compression > .full,
                  "120 个应用 + 120 段会话 ⇒ \(compressed.compression.label)，"
                  + "\(compressed.estimatedTokens) token")

            // 忠实度：一正四反
            var faithFailures = 0
            func faith(_ label: String, _ text: String, expect rule: String?,
                       thinking: Bool = false) {
                let report = NarrativeFaithfulness.check(text, facts: prompt.facts,
                                                         thinkingDetected: thinking)
                let ok: Bool
                if let rule {
                    ok = !report.passed && report.violations.contains { $0.rule == rule }
                } else {
                    ok = report.passed
                }
                if !ok {
                    faithFailures += 1
                    print("      忠实度用例不符：\(label) 期望 \(rule ?? "通过")，"
                          + "实得 \(report.violations.map(\.rule))")
                }
            }
            faith("忠实的叙述",
                  "上午先在飞书跟进采集器的运行情况，随后在 Xcode 查看 FrontmostObserver，"
                  + "锁屏漏事件仍待处理。下午在 Safari 上查阅了 Metal 缓冲池的资料。",
                  expect: nil)
            faith("编造数字", "上午在飞书处理了 987654 条消息。", expect: "fabricated_number")
            faith("编造应用", "上午在飞书沟通后切到 Slack 继续讨论。", expect: "fabricated_app")
            faith("把待办说成已完成（D19 偏差 1）",
                  "上午在 Xcode 里完善 FrontmostObserver，解决了锁屏切换漏事件的问题。",
                  expect: "todo_claimed_done")
            faith("把上午说成下午（D19 偏差 2）", "下午在飞书跟进采集器的运行情况。",
                  expect: "wrong_time_band")
            faith("输出里出现思考段", "上午在飞书沟通。", expect: "thinking_detected", thinking: true)
            check("忠实度核对 6 条用例（1 正 5 反，两条反例照抄 D19 的实测偏差）",
                  faithFailures == 0, "失败 \(faithFailures) 条")

            // 端到端：通过 ⇒ 入库并打标；不通过 ⇒ 一个字都不入库
            let good = "上午先在飞书跟进采集器的运行情况，随后在 Xcode 查看 FrontmostObserver，"
                     + "锁屏漏事件仍待处理。下午在 Safari 上查阅了 Metal 缓冲池的资料。"
            let okReport = try store.runNarrative(
                .day(day), provider: ScriptedGenerationProvider(
                    modelID: Catalog.generationModelID, answers: [good]),
                thermalState: ModelProc.thermalState)
            let ledger = try store.getDayLedger(date: day)
            check("端到端（脚本化提供方）：过核对 ⇒ 写 ledgers.narrative + model + 标注",
                  okReport.saved && ledger.narrative == good
                    && ledger.model == Catalog.generationModelID
                    && ledger.narrativeMeta?.faithfulnessChecked == true
                    && ledger.narrativeMeta?.generatedBy == "model"
                    && !ledger.narrativeIsStale,
                  "输入 \(okReport.inputTokens) token（来源 \(okReport.inputTokenSource)）、"
                  + "输出 \(okReport.outputTokens) token、"
                  + "汉字 \(okReport.hanCharacters)、压缩 \(okReport.compression)")

            _ = try store.clearNarrative(level: "day", period: day)
            let badReport = try store.runNarrative(
                .day(day), provider: ScriptedGenerationProvider(
                    modelID: Catalog.generationModelID,
                    answers: ["上午在飞书沟通后切到 Slack 讨论了 987654 条消息。"]))
            let afterReject = try store.narrativeRecord(level: "day", period: day)
            check("端到端：没过核对 ⇒ 丢弃、不入库、只记事件",
                  !badReport.saved && badReport.outcome == "rejected" && afterReject == nil,
                  "违规 \(badReport.check?.violations.map(\.rule).joined(separator: ",") ?? "-")")

            // 台账重算 ⇒ 叙述作废并重新进待办
            _ = try store.runNarrative(.day(day), provider: ScriptedGenerationProvider(
                modelID: Catalog.generationModelID, answers: [good]))
            _ = try store.getDayLedger(date: day, recompute: true)
            let backlog = try store.narrativeBacklog(
                now: Date(timeIntervalSince1970: Double(dayStart) / 1000 + 86_400 * 2))
            let afterRecompute = try store.narrativeRecord(level: "day", period: day)
            check("台账重算 ⇒ 叙述作废并重新进待办清单（4.3）",
                  afterRecompute == nil && backlog.contains(.day(day)),
                  "待办 \(backlog.count) 篇")
        } catch {
            check("叙述端到端（脚本化提供方）", false, "\(error)")
        }

        // ------------------------------------------------ 4. 模型未装时显示「未启用」
        let dataDirectory = DataLocation.resolve().url
        let root = ModelStore.resolveRoot(dataDirectory: dataDirectory).url
        let installed = ModelStore.isInstalled(root: root, id: Catalog.generationModelID)
        let statusInput = NarrativeGateInput(
            onACPower: true, idleSeconds: 600, thermalState: "nominal", lockPhase: .unlocked,
            paused: false, modelInstalled: installed, enabledByUser: true,
            usedGPUSecondsToday: 0, budgetGPUSeconds: 600, pendingTargets: 1)
        let statusText = NarrativeGatePolicy.statusText(
            NarrativeGatePolicy.decide(statusInput), pending: 1)
        check("未安装生成模型时叙述显示为「未启用」（3.11 降级表）",
              installed || statusText.contains("未启用"),
              installed ? "本机已装 \(Catalog.generationModelID)" : statusText)

        print("      叙述模型：\(Catalog.generationModelID)（D19 实测：热加载 0.80 s、"
              + "生成 35 tok/s、一次叙述 7 s、峰值 footprint 3.42 GiB）；"
              + "UserDefaults 键 \(NarrativeGatePolicy.enabledKey) / "
              + "\(NarrativeGatePolicy.dailyEnabledKey) / \(NarrativeGatePolicy.weeklyEnabledKey)")
        print("      叙述配置：输入上限 \(NarrativeConfig().maxInputTokens) token、"
              + "输出上限 \(NarrativeConfig().maxOutputTokens) token / "
              + "\(NarrativeConfig().maxHanCharacters) 汉字、"
              + "补课窗口 \(NarrativeConfig().backlogDays) 天；"
              + "真实生成在 --narrative-smoke（约 30 s，不进默认自检）")
        return failures
    }
}
