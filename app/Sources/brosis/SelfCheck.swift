import BrosisCore
import BrosisIPC
import CoreGraphics
import Foundation

/// 无 GUI、无 TCC、**不碰钥匙串**的自检。
///
/// 明确保证：本函数不调用 CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess /
/// AXIsProcessTrusted / AXIsProcessTrustedWithOptions / SCShareableContent / AXUIElement*，
/// 不创建 NSApplication，**也不使用 `KeychainKeyProvider`**（那会弹钥匙串授权框），
/// 因此在任何环境下都不会触发授权弹窗，可以在构建流水线里直接跑。
///
/// 它验证六组事情：
/// 1. **core 往返**：用 `InMemoryKeyProvider` 在临时目录开一个真加密库，写一条带正文的观察，
///    读回来逐字节比对，再核 13 项悬空引用与三项内建检查，
///    **另加一次"锁定 → 解锁"往返，确认用户显式策略不会被默认判定覆盖**，
///    最后关库并复查密钥已清零；
/// 2. **入库前脱敏**：21 条正例（含窗口标题 / URL 三条）+ 12 条反例全部逐字符比对；
/// 3. **3.12 三档策略**：三档的"生效方式"开关表 + 解析优先级（临时暂停 > 库 > 内置清单 > 全局默认）；
/// 4. **3.5 锁定状态机**：21 条转移用例 + 7 条"locking 期间的开库触发要补做"用例
///    （纯函数，不开库、不发通知）；
/// 5. dHash 区分度；
/// 6. Electron / CEF 通用检测（纯文件系统判定）。
enum SelfCheck {

    static func run() -> Int32 {
        var failures = 0

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        print("brosis \(BuildInfo.version) 自检（\(BuildInfo.stage)；不触发任何 TCC 授权、不碰钥匙串）")

        // ---------------------------------------------------------------- 1. core 往返
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("brosis-selfcheck-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        var storeSummary = "—"
        /// 存储统计导出文件的实际字段，跑完在参数快照里打出来（T6 的月报脚本按它读）。
        var statsExportShape = "—"
        do {
            let provider = try InMemoryKeyProvider.random()
            var options = StoreOptions()
            options.deviceID = "selfcheck-device"
            let store = try Store.open(directory: workspace, keyProvider: provider, options: options)

            let build = try store.buildInfo()
            check("SQLCipher 已链接", !build.cipherVersion.isEmpty && build.cipherVersion != "?",
                  "cipher \(build.cipherVersion) / \(build.cipherProvider)，SQLite \(build.sqliteVersion)")
            check("cipher_page_size = 16384", build.cipherPageSize == 16384, "\(build.cipherPageSize)")
            check("journal_mode = wal", build.journalMode.lowercased() == "wal", build.journalMode)
            check("auto_vacuum = INCREMENTAL(2)", build.autoVacuum == 2, "\(build.autoVacuum)")
            check("foreign_keys = ON", build.foreignKeys == 1, "\(build.foreignKeys)")
            check("TEMP_STORE 编译期 = 3（D25）", build.tempStoreCompiled == 3,
                  "\(build.tempStoreCompiled)")

            let flags = DataDirectory.auditFlags(store.directory)
            check("数据目录 0700", flags.mode == 0o700, String(flags.mode, radix: 8))
            check("排除 Spotlight / Time Machine", flags.neverIndex && flags.excludedFromBackup,
                  "never_index=\(flags.neverIndex) tm_excluded=\(flags.excludedFromBackup)")

            // 一条真观察：两个片段，region 用 AX 角色；其中一段刻意带密钥与卡号，
            // 走的是采集端真实路径（先 Redactor 再入库），所以库里应该只有占位符。
            let rawBody = "第一段正文。api_key = \"s3cr3t_value_1234\"，卡号 4111 1111 1111 1111。"
            let redacted = Redactor.redact(rawBody)
            let title = "自检窗口标题 self-check window"
            let result = try store.record(ObservationInput(
                ts: Recorder.milliseconds(),
                displayID: 1,
                app: AppRef(bundleID: "com.brosis.selfcheck", name: "brosis 自检"),
                windowTitle: title,
                url: EventSkeleton.urlRef("https://example.invalid/brosis/self-check?q=1"),
                filePath: EventSkeleton.filePath("file:///dev/null"),
                trigger: ObservationTrigger.selfCheck.coreTrigger,
                captureMethod: .ax,
                completeness: .partial,
                sourceState: .ok,
                texts: [
                    TextFragment(text: redacted.text, region: "AXWebArea"),
                    TextFragment(text: "第二段：只有普通文字，用来验证多片段按 ord 重建。",
                                 region: "AXStaticText"),
                ]))
            check("写入 observations + text_versions", result.observationID > 0
                    && result.textVersionIDs.count == 2 && result.newTextVersions == 2,
                  "observation=\(result.observationID) 新建版本 \(result.newTextVersions)")

            // 入库不做 NFKC 折叠（折叠只用于索引），所以读回来的应当与写进去的逐字节相同，
            // 全角冒号 U+FF1A 原样保留。
            let expected = redacted.text + "\n"
                + "第二段：只有普通文字，用来验证多片段按 ord 重建。"
            let readBack = try store.evidenceText(observationID: result.observationID)
            check("读回正文与写入逐字符相同（按 ord 重建）", readBack == expected,
                  readBack == expected ? "\(expected.count) 个字符"
                                       : "实得 \(readBack ?? "(nil)")")
            check("库里没有脱敏前的明文",
                  !(readBack ?? "").contains("s3cr3t_value_1234")
                    && !(readBack ?? "").contains("4111 1111 1111 1111"),
                  "占位符 \(redacted.detail)")

            // 运行期事件与遥测（app 的 runtime_events / frame_stats 就搬到这两处）
            try store.recordRuntimeEvent(kind: "self_check", detail: "failures=\(failures)")
            try store.recordCaptureStat(ts: Recorder.milliseconds(), displayID: 1,
                                        status: "complete", trigger: "self_check",
                                        width: 640, height: 400, contentScale: 1.0,
                                        dhash: "0f1e2d3c4b5a6978", hamming: 0,
                                        dirtyRects: 0, dirtyAreaRatio: 0.0, gated: true,
                                        axChars: rawBody.count)
            check("运行期事件写入 jobs", try store.count(table: "jobs") == 1,
                  "\(try store.count(table: "jobs")) 行")
            check("采集遥测写入 capture_stats", try store.count(table: "capture_stats") == 1,
                  "\(try store.count(table: "capture_stats")) 行")

            // 3.12 三档在库里的往返
            var policyOK = true
            for mode in CapturePolicyMode.allCases {
                try store.setAppPolicy(bundleID: "com.brosis.policy.\(mode.rawValue)",
                                       mode: mode, source: .user)
                let read = try store.appPolicy(bundleID: "com.brosis.policy.\(mode.rawValue)")
                if read?.mode != mode || read?.source != .user { policyOK = false }
            }
            check("app_policies 三档写入 / 读回", policyOK,
                  CapturePolicyMode.allCases.map(\.rawValue).joined(separator: " / "))

            // 3.12 优先级要扛得住一次锁定周期（R1 复核抓到的问题：库没开时的默认判定
            // 被当成"新应用"补写回库，把用户设的「不采集」改回「事件 + 内容」）。
            // 这里把 LockController 的两条真实路径原样走一遍：
            // locking = recorder.detach() + invalidateCache()；
            // unlocking 完成 = recorder.attach() + invalidateCache() + policy.attach()。
            let suiteName = "com.brosis.selfcheck.policy-\(ProcessInfo.processInfo.processIdentifier)"
            let policyDefaults = UserDefaults(suiteName: suiteName) ?? .standard
            defer { policyDefaults.removePersistentDomain(forName: suiteName) }
            let policyStore = CapturePolicyStore(defaults: policyDefaults)
            let policyRecorder = Recorder()
            policyRecorder.attach(store)
            policyStore.attach(recorder: policyRecorder)

            let pinned = "com.brosis.selfcheck.pinned"          // 用户显式设成「不采集」
            let unseenWhileLocked = "com.brosis.selfcheck.unseen-while-locked"
            policyStore.setMode(.none, bundleID: pinned, source: .user)

            policyRecorder.detach()                              // ← locking
            policyStore.invalidateCache()
            let lockedPinned = policyStore.resolve(bundleID: pinned)
            let lockedUnseen = policyStore.resolve(bundleID: unseenWhileLocked)

            policyRecorder.attach(store)                         // ← unlocking 完成
            policyStore.invalidateCache()
            policyStore.attach(recorder: policyRecorder)
            let pinnedRow = try store.appPolicy(bundleID: pinned)
            let pinnedAfter = policyStore.resolve(bundleID: pinned)
            check("用户策略经「锁定 → 解锁」往返后不变",
                  (pinnedRow.map { $0.mode == CapturePolicyMode.none && $0.source == .user } ?? false)
                    && pinnedAfter.mode == CapturePolicyMode.none && pinnedAfter.source == .user,
                  "库里 \(pinnedRow?.mode.rawValue ?? "(空行)")/\(pinnedRow?.source.rawValue ?? "-")"
                  + "，解析 \(pinnedAfter.mode.rawValue)/\(pinnedAfter.source.rawValue)")
            let unseenRow = try store.appPolicy(bundleID: unseenWhileLocked)
            check("库没开时的判定是临时的：不缓存、不落库",
                  lockedPinned.provisional && lockedUnseen.provisional && unseenRow == nil,
                  "锁定期间解析过的 bundle id 没有写进 app_policies")

            // 「导出存储统计…」菜单项走的是同一个 StatsExport.export：
            // 这里用临时库调它，再把 JSON 解析回来逐字段核对（T6 的月报脚本按这个格式读）。
            let exportedAt = Date()
            let exported = try StatsExport.export(store: store, directory: workspace, now: exportedAt)
            let exportedText = try String(contentsOf: exported.url, encoding: .utf8)
            let json = try JSONSerialization.jsonObject(with: Data(exportedText.utf8))
                as? [String: Any] ?? [:]
            let jsonStore = json["store"] as? [String: Any] ?? [:]
            let jsonRows = json["dbstat"] as? [[String: Any]] ?? []
            let exportOK = (json["schema_version"] as? Int) == StatsExport.schemaVersion
                && (json["device_id"] as? String) == "selfcheck-device"
                && (json["generated_by"] as? String) == BuildInfo.version
                && (json["exported_at_ms"] as? Int64) == Recorder.milliseconds(exportedAt)
                && (json["exported_at"] as? String)?.hasSuffix("Z") == true
                && (jsonStore["observations"] as? Int) == 1
                && (jsonStore["text_versions"] as? Int) == 2
                && (jsonStore["occurrences"] as? Int) == 2
                && jsonStore["wal_bytes"] is Int
                && jsonStore["db_file_bytes"] is Int
                && jsonStore["content_bytes"] is Int
                && !jsonRows.isEmpty
                && jsonRows.allSatisfy { $0["name"] is String && $0["bucket"] is String
                                          && $0["bytes"] is Int && $0["pages"] is Int }
                && exported.url.lastPathComponent == StatsExport.fileName(for: exportedAt)
            check("存储统计导出 JSON（stats() + statsDetail() 往返）", exportOK,
                  "\(exported.url.lastPathComponent)：\(exported.fileBytes) 字节，"
                  + "dbstat \(jsonRows.count) 项，schema_version "
                  + "\(json["schema_version"] as? Int ?? -1)")
            // 这份文件会被用户拷来拷去（月报脚本要读它），所以它里面**不能有任何路径**：
            // 没有 "/" 就意味着既没有绝对路径也没有用户名（dbstat 里只有表名与索引名）。
            statsExportShape = "顶层 {" + json.keys.sorted().joined(separator: ", ") + "}"
                + "；store {" + jsonStore.keys.sorted().joined(separator: ", ") + "}"
                + "；dbstat[] {" + (jsonRows.first?.keys.sorted().joined(separator: ", ") ?? "")
                + "}"
            check("存储统计导出里没有路径 / 正文",
                  !exportedText.contains("/") && !exportedText.contains(NSHomeDirectory())
                    && !exportedText.contains("第一段正文") && !exportedText.contains("自检窗口标题"),
                  "只有计数、字节数与 b-tree 名字")

            let integrity = try store.integrityReport()
            check("13 项悬空引用 + integrity_check + FTS", integrity.allPassed,
                  "integrity=\(integrity.integrityCheck) fk=\(integrity.foreignKeyViolations) "
                  + "fts=\(integrity.ftsIntegrityCheck) "
                  + "dangling_ok=\(integrity.danglingChecks.filter(\.ok).count)/\(integrity.danglingChecks.count)")

            let stats = try store.stats()
            storeSummary = "观察 \(stats.observations) / 文本版本 \(stats.textVersions)"
                + " / 出现 \(stats.occurrences) / FTS \(stats.ftsRows) 行"
                + "，原文净载荷 \(stats.textPayloadBytes) 字节，库文件 \(stats.dbFileBytes) 字节"

            try store.checkpoint()

            // 2.2 硬约束 1 + 2：库文件里既不该有正文明文（SQLCipher 全库加密），
            // 也不该有脱敏前的密钥 / 卡号（入库前那一道）。
            // 阳性对照同时验证扫描器本身是有效的——不然"什么都没搜到"可能只是扫描器坏了。
            let dbFiles = ["", "-wal", "-shm"].map {
                URL(fileURLWithPath: store.databaseURL.path + $0)
            }
            let needles = ["s3cr3t_value_1234", "4111 1111 1111 1111", "自检窗口标题"]
            let leaked = scanForPlaintext(in: dbFiles, needles: needles)
            let control = workspace.appendingPathComponent("plaintext-control.txt")
            try Data(needles.joined(separator: " ").utf8).write(to: control)
            let controlHits = scanForPlaintext(in: [control], needles: needles)
            check("库文件里搜不到正文与脱敏前明文（含阳性对照）",
                  leaked.isEmpty && controlHits.count == needles.count,
                  "扫了 \(dbFiles.filter { FileManager.default.fileExists(atPath: $0.path) }.count) 个文件"
                  + "，命中 \(leaked.count)；阳性对照命中 \(controlHits.count)/\(needles.count)")

            store.close()
            check("关库后密钥已清零（3.5 locking）", store.keyIsZeroized, "SecureKey.wasZeroized && isAllZero")
        } catch {
            print("[FAIL] core 往返：\(error)")
            failures += 1
        }

        // ------------------------------------------------- 1b. 锁定期间的丢弃计数何时落库
        // R2 修正的问题：原来 detach() 把当时的累计计数攒起来、下一次 attach() 才回放，
        // 而锁定期间的丢弃发生在 detach() 之后，于是每条 recorder_dropped 都晚一个锁定周期
        // （锁一次解一次库里什么都没有）。这里用一个**独立的**临时加密库把
        // 「attach → detach → 写入被丢弃 → attach」走一遍，数 jobs 行数。
        do {
            let dropWorkspace = workspace.appendingPathComponent("recorder-drop", isDirectory: true)
            let provider = try InMemoryKeyProvider.random()
            var options = StoreOptions()
            options.deviceID = "selfcheck-drop"
            let store = try Store.open(directory: dropWorkspace, keyProvider: provider,
                                       options: options)
            let recorder = Recorder()

            recorder.attach(store)                       // 第一次开库：没有丢过，不该写事件
            let jobsAfterFirstAttach = try store.count(table: "jobs")
            recorder.logEvent(kind: "self_check", detail: "recorder_dropped 时序用例")
            let jobsBeforeLock = try store.count(table: "jobs")

            let beforeDrops = recorder.stats
            recorder.detach()                            // ← locking：库指针摘掉
            recorder.logEvent(kind: "self_check", detail: "锁定期间的事件 1")
            recorder.logEvent(kind: "self_check", detail: "锁定期间的事件 2")
            recorder.record(ObservationInput(
                ts: Recorder.milliseconds(),
                app: AppRef(bundleID: "com.brosis.selfcheck.locked", name: "锁定期间"),
                trigger: ObservationTrigger.selfCheck.coreTrigger,
                captureMethod: .ax, completeness: .unavailable, sourceState: .locked))
            recorder.recordCaptureStat(status: "skipped", trigger: "self_check")
            let delta = recorder.stats - beforeDrops

            recorder.attach(store)                       // ← unlocking 完成：这里就该落一条
            let jobsAfterUnlock = try store.count(table: "jobs")
            recorder.attach(store)                       // 再开一次：这一段没丢过，不该再写
            let jobsAfterSecondUnlock = try store.count(table: "jobs")

            check("recorder_dropped 在解锁当次就落库（不再晚一个锁定周期）",
                  jobsAfterFirstAttach == 0 && jobsBeforeLock == 1
                    && jobsAfterUnlock == jobsBeforeLock + 1
                    && jobsAfterSecondUnlock == jobsAfterUnlock,
                  "jobs：首次开库 \(jobsAfterFirstAttach) → 锁定前 \(jobsBeforeLock) → "
                  + "解锁后 \(jobsAfterUnlock) → 再解锁一次 \(jobsAfterSecondUnlock)")
            check("recorder_dropped 的计数就是这一段丢掉的三类写入",
                  delta.droppedObservations == 1 && delta.droppedEvents == 2
                    && delta.droppedCaptureStats == 1 && delta.errors == 0,
                  delta.dropDetail)

            recorder.detach()
            store.close()
        } catch {
            print("[FAIL] recorder_dropped 时序：\(error)")
            failures += 1
        }

        // ---------------------------------------------------------------- 2. 入库前脱敏
        var redactionFailures: [String] = []
        for vector in RedactionVectors.positives {
            let result = Redactor.redact(vector.input)
            let typesOK = Set(result.counts.keys) == Set(vector.types)
            if result.text != vector.expected || !typesOK {
                redactionFailures.append("正例「\(vector.name)」得到 \(result.text)"
                                         + "（类型 \(result.counts.keys.map(\.rawValue).sorted())）")
            }
        }
        for vector in RedactionVectors.negatives {
            let result = Redactor.redact(vector.input)
            if result.hit || result.text != vector.input {
                redactionFailures.append("反例「\(vector.name)」被误伤成 \(result.text)")
            }
        }
        check("脱敏正例 \(RedactionVectors.positives.count) 条 + 反例 \(RedactionVectors.negatives.count) 条",
              redactionFailures.isEmpty,
              redactionFailures.isEmpty
                ? "\(Redactor.ruleCount) 条规则全部符合预期"
                : redactionFailures.joined(separator: "；"))
        check("Luhn 校验能区分卡号与订单号 / 时间戳",
              Redactor.luhnPassed("4111111111111111")
                && !Redactor.luhnPassed("1234567812345678")
                && !Redactor.luhnPassed("1757000000000"),
              "4111…1111=true，1234…5678=false，1757000000000=false")

        // ---------------------------------------------------------------- 3. 3.12 三档判定
        let gateCases: [(CapturePolicyMode, CapturePolicyStore.Gate)] = [
            (.none, .init(recordsEvents: false, readsContent: false, excludedFromScreenCapture: true)),
            (.eventsOnly, .init(recordsEvents: true, readsContent: false, excludedFromScreenCapture: false)),
            (.eventsAndContent, .init(recordsEvents: true, readsContent: true, excludedFromScreenCapture: false)),
        ]
        let gateOK = gateCases.allSatisfy { CapturePolicyStore.gate(for: $0.0) == $0.1 }
        check("三档的生效方式（不采集 / 只记事件 / 事件+内容）", gateOK,
              "不采集=不记事件+不读正文+进 SCContentFilter 排除；只记事件=不读正文；事件+内容=全开")

        let now = Date()
        let future = now.addingTimeInterval(3600)
        let past = now.addingTimeInterval(-3600)
        let decideCases: [(name: String, got: CapturePolicyStore.Resolution,
                           mode: CapturePolicyMode, source: CapturePolicySource)] = [
            ("今日临时暂停优先于库里的策略",
             CapturePolicyStore.decide(stored: (.eventsAndContent, .user),
                                       temporaryPausedUntil: future, denylisted: false, now: now),
             .none, .user),
            ("临时暂停过期后回到库里的策略",
             CapturePolicyStore.decide(stored: (.eventsOnly, .user),
                                       temporaryPausedUntil: past, denylisted: false, now: now),
             .eventsOnly, .user),
            ("库里的用户设置优先于内置清单",
             CapturePolicyStore.decide(stored: (.eventsAndContent, .user),
                                       temporaryPausedUntil: nil, denylisted: true, now: now),
             .eventsAndContent, .user),
            ("内置默认不采集清单",
             CapturePolicyStore.decide(stored: nil, temporaryPausedUntil: nil,
                                       denylisted: true, now: now),
             .none, .builtinDenylist),
            ("新应用按全局默认「事件 + 内容」",
             CapturePolicyStore.decide(stored: nil, temporaryPausedUntil: nil,
                                       denylisted: false, now: now),
             .eventsAndContent, .default),
        ]
        for item in decideCases {
            check("策略解析：\(item.name)",
                  item.got.mode == item.mode && item.got.source == item.source,
                  "\(item.got.mode.rawValue) / \(item.got.source.rawValue)"
                  + (item.got.firstSeen ? "（首次出现，会落库并记事件）" : ""))
        }

        let denylist = BuiltinDenylist.shared
        check("内置默认不采集清单已加载", denylist.count > 0,
              "\(denylist.count) 个 bundle id = 代码内 \(denylist.fromCode) ∪ "
              + "Resources/exclusions.txt \(denylist.fromResource)")
        check("清单覆盖 3.12 的四个类别",
              denylist.contains("com.apple.keychainaccess")
                && denylist.contains("com.1password.1password")
                && denylist.contains("com.authy.authy-mac")
                && denylist.contains("com.tigerbrokers.TigerTrade"),
              "钥匙串访问 / 密码管理器 / 验证器 / 券商 各抽一条")

        // ------------------------------------------ 3b. 3.12 应用采集清单（视图模型 + 改档状态机）
        // 窗口本身一行都不跑（自检不许创建 NSApplication），跑的是它背后的全部判定：
        // 数据源合并、分组、排序、过滤、改档状态机，外加一次真库端到端。
        let listRows = PolicyListVectors.build()
        let listIDs = listRows.map(\.bundleID)
        check("清单数据源三处合并（app_policies ∪ 最近 7 天观察 ∪ 运行中的 GUI 应用）",
              Set(listIDs) == Set([PolicyListVectors.bundleSafari, PolicyListVectors.bundleWeChat,
                                   PolicyListVectors.bundleTerminal,
                                   PolicyListVectors.bundle1Password,
                                   PolicyListVectors.bundleBothDenylistAndAdapter,
                                   PolicyListVectors.bundleFreshApp]),
              "\(listRows.count) 行：策略表 5 + 观察 3 + 运行中 2，去重后 6")

        let byID = Dictionary(uniqueKeysWithValues: listRows.map { ($0.bundleID, $0) })
        let groupsOK = byID[PolicyListVectors.bundleSafari]?.group == .adapter
            && byID[PolicyListVectors.bundleWeChat]?.group == .adapter
            && byID[PolicyListVectors.bundleTerminal]?.group == .generic
            && byID[PolicyListVectors.bundle1Password]?.group == .denylisted
            && byID[PolicyListVectors.bundleFreshApp]?.group == .generic
        check("分组判定（内置清单 > 有适配器 > 通用）", groupsOK,
              "Safari/微信=有适配器（\(byID[PolicyListVectors.bundleSafari]?.adapterID ?? "?")"
              + " / \(byID[PolicyListVectors.bundleWeChat]?.adapterID ?? "?")），"
              + "终端与全新应用=通用，1Password=默认不采集")

        // **分组顺序这条规则只有这一行测得出来**：`com.tencent.WeChat` 既在（合成的）内置清单里、
        // 又命中微信的适配规则。两者不重叠的行换个判定顺序结果一样，抓不到把顺序写反的改动。
        let both = byID[PolicyListVectors.bundleBothDenylistAndAdapter]
        check("既在内置清单又有适配器时归「默认不采集」（顺序不能反）",
              both?.group == .denylisted && both?.adapterID == nil
                && PolicyListVectors.adapterID(PolicyListVectors.bundleBothDenylistAndAdapter)
                    == "wechat",
              "\(PolicyListVectors.bundleBothDenylistAndAdapter) 命中适配规则 wechat，"
              + "但仍归 \(both?.group.title ?? "?")；"
              + "适配器列显示 \(both?.adapterID ?? "(空)")")

        // 没有策略行、也不在内置清单里的"全新应用"按全局默认显示；
        // 内置清单里的按 builtin_denylist；用户设过的保持 user。
        let fresh = byID[PolicyListVectors.bundleFreshApp]
        let defaultsOK = fresh?.mode == .eventsAndContent && fresh?.source == .default
            && fresh?.observations == 0 && fresh?.running == true
            && byID[PolicyListVectors.bundleWeChat]?.source == .user
            && byID[PolicyListVectors.bundle1Password]?.source == .builtinDenylist
        check("没有策略行的应用按全局默认显示，且与采集端同一个 decide()", defaultsOK,
              "全新应用 \(fresh?.mode.rawValue ?? "?")/\(fresh?.source.rawValue ?? "?")，"
              + "运行中=\(fresh?.running == true)，最近 7 天观察 \(fresh?.observations ?? -1)")

        let lowDefault = PolicyListVectors.build(globalDefault: .none)
        check("改全局默认只影响没有策略行的应用",
              lowDefault.first { $0.bundleID == PolicyListVectors.bundleFreshApp }?.mode
                    == CapturePolicyMode.none
                && lowDefault.first { $0.bundleID == PolicyListVectors.bundleSafari }?.mode
                    == .eventsAndContent,
              "全新应用跟着变，Safari（库里有 default 行）不动")

        check("排序：先分组，组内按最近 7 天观察数倒序、再按最近出现倒序、最后按 bundle id",
              listIDs == [PolicyListVectors.bundleSafari, PolicyListVectors.bundleWeChat,
                          PolicyListVectors.bundleTerminal, PolicyListVectors.bundleFreshApp,
                          PolicyListVectors.bundle1Password,
                          PolicyListVectors.bundleBothDenylistAndAdapter],
              listIDs.joined(separator: " → "))

        let filteredByName = PolicyListVectors.build(query: "微信").map(\.bundleID)
        let filteredByBundle = PolicyListVectors.build(query: "APPLE.TERM").map(\.bundleID)
        let filteredMiss = PolicyListVectors.build(query: "不存在的应用")
        check("搜索框过滤：应用名 / bundle id，不区分大小写",
              filteredByName == [PolicyListVectors.bundleWeChat]
                && filteredByBundle == [PolicyListVectors.bundleTerminal]
                && filteredMiss.isEmpty,
              "「微信」命中中文名；「APPLE.TERM」命中 bundle id；无命中返回空表")

        let pausedUntil = Date().addingTimeInterval(3600)
        let pausedRow = PolicyListVectors
            .build(temporaryPauses: [PolicyListVectors.bundleSafari: pausedUntil])
            .first { $0.bundleID == PolicyListVectors.bundleSafari }
        check("今日临时暂停不改存下来的那一档，只改生效档",
              pausedRow?.mode == .eventsAndContent && pausedRow?.effectiveMode == CapturePolicyMode.none
                && pausedRow?.temporaryUntil == pausedUntil,
              "弹出菜单显示「\(pausedRow?.mode.label ?? "?")」，这一刻生效的是"
              + "「\(pausedRow?.effectiveMode.label ?? "?")」")

        var changeFailures: [String] = []
        for item in PolicyListVectors.changeCases {
            let got = PolicyModeChange.plan(current: item.current, next: item.next,
                                            storeOpen: item.storeOpen,
                                            existingObservations: item.existing)
            if got != item.expected {
                changeFailures.append("\(item.name)：期望 \(item.expected)，实得 \(got)")
            }
        }
        check("改档状态机 \(PolicyListVectors.changeCases.count) 条（锁定挡下 / 只有降档问删数据 /"
              + " 没数据不弹框）", changeFailures.isEmpty,
              changeFailures.isEmpty
                ? "档位高低：不采集 0 < 只记事件 1 < 事件 + 内容 2"
                : changeFailures.joined(separator: "；"))

        // 端到端：真加密库 + 真查询，把"降档 → 删数据 → 统计归零"跑一遍。
        do {
            let uiWorkspace = workspace.appendingPathComponent("policy-ui", isDirectory: true)
            let uiStore = try Store.open(directory: uiWorkspace,
                                         keyProvider: try InMemoryKeyProvider.random(),
                                         options: StoreOptions())
            defer { uiStore.close() }
            let nowMS = Recorder.milliseconds()
            let dayMS: Int64 = 86_400_000
            let states: [Completeness] = [.complete, .complete, .partial, .unavailable, .excluded]
            for (index, completeness) in states.enumerated() {
                try uiStore.record(ObservationInput(
                    ts: nowMS - Int64(index) * dayMS, displayID: 1,
                    app: AppRef(bundleID: "com.brosis.policy-ui", name: "清单自检"),
                    windowTitle: "窗口 \(index)",
                    trigger: ObservationTrigger.selfCheck.coreTrigger,
                    captureMethod: .ax, completeness: completeness, sourceState: .ok,
                    texts: [TextFragment(text: "第 \(index) 条", region: "AXStaticText")]))
            }
            // 窗口外那一条（30 天前）不该被最近 7 天的统计数进来。
            try uiStore.record(ObservationInput(
                ts: nowMS - 30 * dayMS, displayID: 1,
                app: AppRef(bundleID: "com.brosis.policy-ui", name: "清单自检"),
                windowTitle: "很久以前",
                trigger: ObservationTrigger.selfCheck.coreTrigger,
                captureMethod: .ax, completeness: .complete, sourceState: .ok))
            try uiStore.setAppPolicy(bundleID: "com.brosis.policy-ui",
                                     mode: .eventsAndContent, source: .user)

            let since = nowMS - Int64(PolicyList.statsWindowDays) * dayMS
            let stat = try uiStore.appObservationStats(since: since)
                .first { $0.bundleID == "com.brosis.policy-ui" }
            check("最近 \(PolicyList.statsWindowDays) 天的观察数与完整性分布（一条聚合 SQL，不扫全表）",
                  stat?.observations == 5 && stat?.complete == 2 && stat?.partial == 1
                    && stat?.unavailable == 1 && stat?.excluded == 1
                    && stat?.lastSeenMS == nowMS,
                  "窗口内 \(stat?.observations ?? -1) 条 = 完整 \(stat?.complete ?? -1) / "
                  + "部分 \(stat?.partial ?? -1) / 不可用 \(stat?.unavailable ?? -1) / "
                  + "排除 \(stat?.excluded ?? -1)；30 天前那条没被数进来"
                  + "（全库 \(try uiStore.appObservationCount(bundleID: "com.brosis.policy-ui")) 条）")
            let plan = try uiStore.appObservationStatsPlan().joined(separator: " | ")
            check("清单统计走 idx_obs_live 部分索引", plan.contains("idx_obs_live"), plan)

            // 3.12 最后一条：降档 → 询问 → 选"删" → 走 3.8 的按应用删除并级联。
            let existing = try uiStore.appObservationCount(bundleID: "com.brosis.policy-ui")
            let decided = PolicyModeChange.plan(current: .eventsAndContent, next: .none,
                                                storeOpen: true, existingObservations: existing)
            let summary = try uiStore.deleteByApp(bundleID: "com.brosis.policy-ui", reason: .policy)
            let afterStats = try uiStore.appObservationStats(since: 0)
                .first { $0.bundleID == "com.brosis.policy-ui" }
            let policyRow = try uiStore.appPolicy(bundleID: "com.brosis.policy-ui")
            check("降档删数据端到端（deleteByApp reason=policy → 统计归零、策略行还在）",
                  decided == .applyThenAskDelete(existing: 6)
                    && summary.observationsAffected == 6 && summary.reason == .policy
                    && afterStats == nil && policyRow?.mode == .eventsAndContent,
                  "全库 \(existing) 条 → 删 \(summary.observationsAffected) 条观察 / "
                  + "\(summary.textVersionsDeleted) 个文本版本 / \(summary.ftsRowsDeleted) 行索引，"
                  + "释放 \(summary.bytesFreed) 字节；清单里这个应用的统计行消失，策略行保留")

            // 全局默认档存在 UserDefaults，走一次真的往返（用独立 suite，不碰用户的设置）。
            let suite = "com.brosis.selfcheck.ui-\(ProcessInfo.processInfo.processIdentifier)"
            let uiDefaults = UserDefaults(suiteName: suite) ?? .standard
            defer { uiDefaults.removePersistentDomain(forName: suite) }
            let uiPolicy = CapturePolicyStore(defaults: uiDefaults)
            let before = uiPolicy.globalDefault
            uiPolicy.setGlobalDefault(.eventsOnly)
            let after = uiPolicy.globalDefault
            check("全局默认档往返（出厂值 → 用户设的值）",
                  before == CapturePolicyStore.builtinGlobalDefault && after == .eventsOnly,
                  "出厂 \(before.rawValue) → 设成 \(after.rawValue)（存 UserDefaults 的 "
                  + "\(CapturePolicyStore.globalDefaultKey)，库没开也读得到）")

            // 新应用提示：每个 bundle id 只提示一次，点掉之后不再出现。
            let uiRecorder = Recorder()
            uiRecorder.attach(uiStore)
            uiPolicy.attach(recorder: uiRecorder)
            _ = uiPolicy.resolve(bundleID: "com.brosis.brand-new")
            let firstNotice = uiPolicy.pendingNewAppNotices()
            uiPolicy.invalidateCache()
            _ = uiPolicy.resolve(bundleID: "com.brosis.brand-new")   // 第二次遇见，已有策略行
            let stillOne = uiPolicy.pendingNewAppNotices()
            uiPolicy.clearNewAppNotice(bundleID: "com.brosis.brand-new")
            check("新应用菜单提示只出一次，点掉后不再出现",
                  firstNotice == ["com.brosis.brand-new"] && stillOne == firstNotice
                    && uiPolicy.pendingNewAppNotices().isEmpty,
                  "第一次落库时进提示队列，再遇见不重复提示，clear 之后为空")
        } catch {
            check("3.12 应用清单端到端", false, "\(error)")
        }

        // ---------------------------------------------------------------- 4. 3.5 锁定状态机
        var lockFailures: [String] = []
        for item in LockPolicy.transitionCases {
            let got = LockPolicy.next(item.from, on: item.trigger, strictScreenLock: item.strict)
            if got != item.expected {
                lockFailures.append("\(item.from.phase.rawValue) --\(item.trigger.rawValue)"
                                    + "(strict=\(item.strict))--> 期望 \(item.expected.phase.rawValue)"
                                    + "[\(item.expected.pauseDescription)]，实得 \(got.phase.rawValue)"
                                    + "[\(got.pauseDescription)]")
            }
        }
        check("锁定状态机 \(LockPolicy.transitionCases.count) 条转移", lockFailures.isEmpty,
              lockFailures.isEmpty
                ? "locked → unlocking → unlocked → locking，paused 子状态含屏幕锁定 / 屏保 / 用户暂停"
                : lockFailures.joined(separator: "；"))
        var deferredFailures: [String] = []
        for item in LockPolicy.deferredUnlockCases {
            let got = LockPolicy.deferredUnlock(from: LockSnapshot(phase: item.from),
                                                on: item.trigger, strictScreenLock: item.strict)
            if got != item.expected {
                deferredFailures.append("\(item.from.rawValue) --\(item.trigger.rawValue)"
                                        + "(strict=\(item.strict))--> 期望补做 "
                                        + "\(item.expected?.rawValue ?? "(不补)")，实得 "
                                        + "\(got?.rawValue ?? "(不补)")")
            }
        }
        check("locking 期间的唤醒 / 解锁触发会被补做（\(LockPolicy.deferredUnlockCases.count) 条）",
              deferredFailures.isEmpty,
              deferredFailures.isEmpty
                ? "关库是异步的，lockCompleted 之前到的 systemDidWake / menuUnlock 记下来补做"
                : deferredFailures.joined(separator: "；"))
        // 反向：关库过程中又来锁定类触发，要把攒下的补做取消掉。
        // R2 修正：非严格模式下 screenLocked 只进 paused、不关库，**不该**取消补做。
        var cancelFailures: [String] = []
        for item in LockPolicy.cancelDeferredCases {
            let got = LockPolicy.cancelsDeferredUnlock(item.trigger, strictScreenLock: item.strict)
            if got != item.expected {
                cancelFailures.append("\(item.trigger.rawValue)(strict=\(item.strict)) 期望 "
                                      + "\(item.expected ? "取消" : "不取消")，实得 "
                                      + "\(got ? "取消" : "不取消")")
            }
        }
        check("锁定类触发取消补做（\(LockPolicy.cancelDeferredCases.count) 条；"
              + "非严格模式的锁屏不取消）",
              cancelFailures.isEmpty,
              cancelFailures.isEmpty
                ? "⌘L / 睡眠 / 注销 / 低磁盘 / 热 critical 取消；锁屏只在 lock.strict=true 时取消"
                : cancelFailures.joined(separator: "；"))
        check("低磁盘阈值 = 2 GiB",
              LockPolicy.lowDiskThresholdBytes == 2 * 1024 * 1024 * 1024,
              "\(LockPolicy.lowDiskThresholdBytes) 字节")

        // ---------------------------------------------------------------- 5. 私密浏览
        check("私密浏览（Safari 标题含无痕标记）",
              PrivateBrowsing.isPrivate(bundleID: "com.apple.Safari", windowTitle: "无痕浏览")
                && PrivateBrowsing.isPrivate(bundleID: "com.apple.Safari",
                                             windowTitle: "Private Browsing — Example"),
              "命中时 completeness=excluded，正文 / 标题 / URL / 文件路径一个都不存")
        check("私密浏览不误伤非浏览器",
              !PrivateBrowsing.isPrivate(bundleID: "com.apple.Notes",
                                         windowTitle: "关于无痕浏览的笔记")
                && !PrivateBrowsing.isPrivate(bundleID: "com.apple.Safari", windowTitle: "普通标题"),
              "只对浏览器 bundle id 生效")

        // ---------------------------------------------------------------- 6. dHash
        let hasher = DHasher()
        guard let imageA = syntheticImage(seed: 0),
              let imageB = syntheticImage(seed: 1),
              let hashA = hasher.hash(cgImage: imageA),
              let hashA2 = hasher.hash(cgImage: imageA),
              let hashB = hasher.hash(cgImage: imageB) else {
            print("[FAIL] dHash 计算失败")
            return 1
        }
        check("同一图像 dHash 稳定", hashA == hashA2, "\(hashA.hex)")
        let distance = hashA.hamming(to: hashB)
        check("不同图像 dHash 汉明距离 > 6", distance > 6, "距离 \(distance) bit（门控阈值 6）")

        // ---------------------------------------------------------------- 7. Electron / CEF
        let electron = electronProbe()
        check("Electron 检测（伪造带框架的 .app）", electron.positivePassed, electron.positiveDetail)
        check("Electron 检测（伪造不带框架的 .app）", electron.negativePassed, electron.negativeDetail)
        for note in electron.installedNotes { print("       \(note)") }

        // ---------------------------------------------------------------- 8. 截图触发口径
        // R2 修正：finish() 重排队时以前会追加 "queued"，纯定时截图于是变成
        // "periodic+queued" 并被当成事件触发，压掉下一次兜底。现在判定是纯函数。
        let triggerCases: [(String, Bool)] = [
            ("periodic", false),
            ("queued", false),
            ("periodic+queued", false),
            ("armed", true),
            ("app_activated", true),
            ("app_activated+periodic", true),
            ("display_changed+periodic+queued", true),
        ]
        let triggerFailures = triggerCases.filter {
            CaptureController.isEventTrigger($0.0) != $0.1
        }
        check("截图触发口径：去掉 periodic / queued 后非空才算事件触发",
              triggerFailures.isEmpty,
              triggerFailures.isEmpty
                ? triggerCases.map { "\($0.0)→\($0.1 ? "事件" : "非事件")" }.joined(separator: "，")
                : triggerFailures.map { "\($0.0) 期望 \($0.1)" }.joined(separator: "；"))

        // setPaused 只在状态真的变了时写事件（否则 syncSubsystems 每次调都刷屏）。
        // 用一个没挂库的 Recorder 观察：写不进去的事件会计进"锁定期间丢弃"，正好当计数器。
        let pauseRecorder = Recorder()
        let pauseController = CaptureController(recorder: pauseRecorder) { _ in }
        pauseController.setPaused(false)                 // 初始就是 false：不该记
        pauseController.setPaused(false)
        let afterNoChange = pauseRecorder.stats.droppedEvents
        pauseController.setPaused(true)                  // 变了：capture_paused
        pauseController.setPaused(true)                  // 没变：不记
        pauseController.setPaused(false)                 // 变了：capture_resumed
        let afterChanges = pauseRecorder.stats.droppedEvents
        check("setPaused 只在状态变化时写 capture_paused / capture_resumed",
              afterNoChange == 0 && afterChanges == 2,
              "连调两次 false → \(afterNoChange) 条事件；true/true/false → 共 \(afterChanges) 条")

        // ---------------------------------------------------------------- 9. AX 深度上限语义
        // R2 修正：hit=depth 表示"确实有子树没展开"，不是"有元素落在最后一层"。
        var childrenCalls = 0
        let limits = AX.BFSLimits(maxNodes: 100, maxDepth: 6)
        let depthCases: [(name: String, got: Bool, expected: Bool)] = [
            ("没到上限的层不算命中",
             AX.depthLimitHit(alreadyHit: false, depth: 5, limits: limits, hasChildren: true), false),
            ("到上限但是叶子：不算命中",
             AX.depthLimitHit(alreadyHit: false, depth: 6, limits: limits, hasChildren: false), false),
            ("到上限且还有子节点：命中",
             AX.depthLimitHit(alreadyHit: false, depth: 6, limits: limits, hasChildren: true), true),
            ("已经命中过就保持命中，且不再取 children",
             AX.depthLimitHit(alreadyHit: true, depth: 6, limits: limits,
                              hasChildren: { childrenCalls += 1; return false }()), true),
        ]
        let depthFailures = depthCases.filter { $0.got != $0.expected }
        check("AX 深度上限：只有被截断的元素确实还有子节点才算 hit=depth",
              depthFailures.isEmpty && childrenCalls == 0,
              depthFailures.isEmpty && childrenCalls == 0
                ? "4 条用例全过；已命中时不再多发一轮 kAXChildren（求值次数 \(childrenCalls)）"
                : depthFailures.map(\.name).joined(separator: "；")
                  + (childrenCalls == 0 ? "" : "；已命中时仍求值了 \(childrenCalls) 次"))

        // ---------------------------------------------------------------- 10. 版本号单一来源
        // build_app.sh 组装时把 BuildInfo.version 写进 Info.plist 的两个键；
        // 这里从 Bundle.main 读回来比一次。裸二进制（swift build 的产物）没有 Info.plist，跳过。
        if let info = Bundle.main.infoDictionary,
           let shortVersion = info["CFBundleShortVersionString"] as? String,
           let bundleVersion = info["CFBundleVersion"] as? String {
            check("bundle 版本 == BuildInfo.version（单一来源）",
                  shortVersion == BuildInfo.version && bundleVersion == BuildInfo.version,
                  "CFBundleShortVersionString=\(shortVersion) CFBundleVersion=\(bundleVersion) "
                  + "BuildInfo.version=\(BuildInfo.version)")
        } else {
            print("[SKIP] bundle 版本 == BuildInfo.version：当前是裸二进制（没有 Info.plist），"
                  + "这一项只有从 brosis.app/Contents/MacOS/brosis 跑才验得到")
        }

        // ---------------------------------------------------------------- 11. 本地 IPC / MCP（3.6）
        // 起一个真的 Unix domain socket，用一个临时加密库（InMemoryKeyProvider，不碰钥匙串）
        // 跑一遍「没有 grant 全拒 → 加 grant → summary 不回原文 → evidence 回原文 → 审计留痕」。
        // 不启动 brosis-mcp、不碰产品数据目录、不触发任何授权弹窗。
        let ipcRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bmcp-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: ipcRoot) }
        do {
            try FileManager.default.createDirectory(at: ipcRoot, withIntermediateDirectories: true)
            let store = try Store.open(directory: ipcRoot.appendingPathComponent("db", isDirectory: true),
                                       keyProvider: try InMemoryKeyProvider.random())
            defer { store.close() }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            _ = try store.record(ObservationInput(
                ts: now - 60_000, displayID: 1,
                app: AppRef(bundleID: "com.apple.Safari", name: "Safari"),
                windowTitle: "自检窗口",
                trigger: .manual, captureMethod: .ax, completeness: .complete, sourceState: .ok,
                texts: [TextFragment(text: "自检正文 知识图谱 与 存储服务", region: nil)]))
            // 同一块屏上再放一条**别的应用**的观察：它是上面那条的相邻观察，
            // 用来验"应用白名单连出现上下文一起裁"（下面第 4 项之后那一条）。
            _ = try store.record(ObservationInput(
                ts: now - 55_000, displayID: 1,
                app: AppRef(bundleID: "com.microsoft.VSCode", name: "Code"),
                windowTitle: "白名单外的窗口",
                trigger: .manual, captureMethod: .ax, completeness: .complete, sourceState: .ok,
                texts: [TextFragment(text: "白名单外的一段正文", region: nil)]))

            let service = StoreMCPService(store: store)
            let gate = MCPGate { (.unlocked, service) }
            var configuration = IPCServer.Configuration(
                socketURL: ipcRoot.appendingPathComponent("s.sock", isDirectory: false))
            // 自检里先用 .skip 跑通功能，再单独验一次产品口径的 .requireSameTeam（见下）。
            configuration.peerPolicy = .skip
            let server = IPCServer(configuration: configuration) { gate.handle($0) }
            try server.start()
            defer { server.stop() }

            let mode = (try FileManager.default
                .attributesOfItem(atPath: configuration.socketURL.path)[.posixPermissions]
                as? NSNumber)?.uint16Value ?? 0
            check("ipc.sock 权限 0600", (mode & 0o777) == 0o600, String(mode & 0o777, radix: 8))

            let client = IPCClient(socketURL: configuration.socketURL, clientID: "selfcheck")
            defer { client.disconnect() }

            let denied = try client.send(op: .tool, name: MCPTool.search.rawValue,
                                         args: ["q": .string("知识图谱")])
            check("没有 grant 的客户端被拒（3.6）",
                  !denied.ok && denied.error?.code == .noGrant && denied.result == nil,
                  denied.error?.code.rawValue ?? "ok")

            try store.setGrant(Grant(clientID: "selfcheck", mode: .strictLocal, apps: ["*"],
                                     timeWindowDays: 30, fields: .summary))
            let searched = try client.send(op: .tool, name: MCPTool.search.rawValue,
                                           args: ["q": .string("知识图谱"), "limit": .int(5)])
            let ids = searched.result?["hits"]?.arrayValue?.compactMap { $0["evidenceID"]?.intValue } ?? []
            check("加了 grant 之后 search 命中", searched.ok && !ids.isEmpty,
                  "命中 \(ids.count) 条")

            let summaryOnly = try client.send(op: .tool, name: MCPTool.getEvidence.rawValue,
                                              args: ["ids": .array(ids.map { .int($0) })])
            let firstSummary = summaryOnly.result?["items"]?.arrayValue?.first
            check("fields = summary 不回原文",
                  summaryOnly.ok && firstSummary?["text"] == nil
                      && firstSummary?["redactedByGrant"]?.boolValue == true,
                  "text 字段\(firstSummary?["text"] == nil ? "缺席" : "存在")")

            try store.setGrant(Grant(clientID: "selfcheck", mode: .strictLocal, apps: ["*"],
                                     timeWindowDays: 30, fields: .evidence))
            let full = try client.send(op: .tool, name: MCPTool.getEvidence.rawValue,
                                       args: ["ids": .array(ids.map { .int($0) })])
            let text = full.result?["items"]?.arrayValue?.first?["text"]?.stringValue
            check("fields = evidence 回原文", full.ok && (text?.contains("知识图谱") ?? false),
                  text.map { String($0.prefix(24)) } ?? "nil")

            let audit = try store.mcpAuditTail(limit: 10)
            let noQueryText = audit.allSatisfy { !$0.params.contains("知识图谱") }
            check("mcp_audit 记了每次调用且不含查询串本身（3.6）",
                  audit.count == 4 && noQueryText
                      && audit.contains { $0.decision == .noGrant }
                      && audit.contains { $0.decision == .ok },
                  "\(audit.count) 行：" + audit.map { "\($0.tool)/\($0.decision.rawValue)" }
                      .joined(separator: " "))

            // 应用白名单连**出现上下文**一起裁：before / after 带 bundle id 与窗口标题，
            // 漏一条就等于绕过白名单（M1 第一轮验收抓到的口子，见 core 的同名断言）。
            try store.setGrant(Grant(clientID: "selfcheck", mode: .strictLocal,
                                     apps: ["com.apple.Safari"], timeWindowDays: 30,
                                     fields: .evidence))
            let scoped = try client.send(op: .tool, name: MCPTool.getEvidence.rawValue,
                                         args: ["ids": .array(ids.map { .int($0) }),
                                                "neighbors": .int(3)])
            let item = scoped.result?["items"]?.arrayValue?.first
            let neighbors = (item?["before"]?.arrayValue ?? []) + (item?["after"]?.arrayValue ?? [])
            let leaked = neighbors.compactMap { $0["appBundleID"]?.stringValue }
                .filter { $0 != "com.apple.Safari" }
            let droppedNeighbors = scoped.result?["grant"]?["droppedByGrant"]?.intValue ?? 0
            check("应用白名单也裁 get_evidence 的出现上下文（3.6）",
                  scoped.ok && leaked.isEmpty && droppedNeighbors > 0,
                  leaked.isEmpty ? "裁掉 \(droppedNeighbors) 条相邻观察"
                                 : "泄漏了 " + leaked.joined(separator: " "))

            // 产品口径：对端必须与本进程同一个 Team ID。签名过的 .app 里这一项真跑；
            // 裸二进制（swift build 产物、SKIP_SIGN=1 的 bundle）没有 Team ID，按设计**拒绝**。
            var strict = IPCServer.Configuration(
                socketURL: ipcRoot.appendingPathComponent("t.sock", isDirectory: false))
            strict.peerPolicy = .requireSameTeam
            let strictServer = IPCServer(configuration: strict) { gate.handle($0) }
            try strictServer.start()
            defer { strictServer.stop() }
            let strictClient = IPCClient(socketURL: strict.socketURL, clientID: "selfcheck")
            defer { strictClient.disconnect() }
            let strictResponse = try strictClient.send(op: .ping)
            if let team = strictServer.hostTeamID {
                check("对端签名校验：同 Team ID 放行（Team \(team)）", strictResponse.ok,
                      strictResponse.error?.message ?? "ok")
            } else {
                check("对端签名校验：本进程没有 Team ID 时一律拒绝（做不到就不放行）",
                      !strictResponse.ok && strictResponse.error?.code == .unauthorizedPeer,
                      strictResponse.error?.message ?? "竟然放行了")
            }
        } catch {
            check("本地 IPC / MCP 自检", false, "\(error)")
        }

        // ------------------------------------------------- 12. 适配器与视口 OCR（3.3 / D24）
        // 全部走合成 AX 树与合成布局：不启动应用、不发 AX 消息、不截屏、不要任何权限。
        // Vision 是本地推理，对自绘图像直接跑也不触发 TCC。

        // 12.1 规则路由：四个应用各自命中自己的规则，别的应用落到兜底规则。
        var routingOK = true
        for rule in AdapterRegistry.all {
            for bundleID in rule.bundleIDs where AdapterRegistry.rule(for: bundleID).id != rule.id {
                routingOK = false
            }
        }
        let fallbackRule = AdapterRegistry.rule(for: "com.apple.finder")
        check("适配规则路由：\(AdapterRegistry.all.count) 条首批规则 + 兜底",
              routingOK && fallbackRule.id == AdapterRegistry.generic.id
                && fallbackRule.limits.maxNodes == AX.bfsLimits(bundleID: "com.apple.finder").maxNodes,
              AdapterRegistry.all.map(\.id).joined(separator: " / ")
                + "；未知应用 → \(fallbackRule.id)（\(fallbackRule.limits.label)）")

        // 12.2 五条规则用例（合成树）：片段数、完整性、必含 / 必不含、OCR 请求区域。
        for item in AdapterVectors.ruleCases {
            let scan = AdapterEngine.scan(rule: item.rule, window: item.tree(),
                                          windowFrame: AdapterVectors.window)
            let text = scan.fragments.map(\.text).joined(separator: "\n")
            let missing = item.mustContain.filter { !text.contains($0) }
            let leaked = item.mustNotContain.filter { text.contains($0) }
            let ocrNames = scan.ocrRequests.map(\.regionName).sorted()
            let ok = scan.fragments.count == item.expectedFragments
                && scan.completeness == item.expectedCompleteness
                && missing.isEmpty && leaked.isEmpty
                && ocrNames == item.expectedOCRRegions.sorted()
            check("适配规则 · \(item.name)", ok,
                  ok ? "片段 \(scan.fragments.count)、\(scan.completeness.rawValue)、"
                     + "OCR 区域 [\(ocrNames.joined(separator: ","))]"
                     : "片段 \(scan.fragments.count)（期望 \(item.expectedFragments)）"
                     + "、\(scan.completeness.rawValue)（期望 \(item.expectedCompleteness.rawValue)）"
                     + "、缺 \(missing)、泄漏 \(leaked)、OCR \(ocrNames)")
        }

        // 12.3 视口相交（含回滚区）
        var viewportFailures: [String] = []
        for item in AdapterVectors.viewportCases {
            let got = Viewport.isVisible(item.frame, in: item.viewport)
            let scrollback = Viewport.isScrollback(item.frame, in: item.viewport)
            if got != item.expected || scrollback != item.scrollback {
                viewportFailures.append("\(item.name)→\(String(describing: got))/\(scrollback)")
            }
        }
        check("视口相交判定 \(AdapterVectors.viewportCases.count) 条（含回滚区）",
              viewportFailures.isEmpty,
              viewportFailures.isEmpty ? "全部一致" : viewportFailures.joined(separator: " "))

        // 12.4 AXVisibleCharacterRange 裁剪
        var rangeFailures: [String] = []
        for item in AdapterVectors.visibleRangeCases {
            let node = SyntheticAXNode(role: "AXTextArea", value: item.value,
                                       visibleCharacterRange: item.range)
            let got = node.viewportText()
            if got?.text != item.expectedText || got?.clipped != item.expectedClipped {
                rangeFailures.append(item.name)
            }
        }
        check("AXVisibleCharacterRange 裁剪 \(AdapterVectors.visibleRangeCases.count) 条",
              rangeFailures.isEmpty,
              rangeFailures.isEmpty ? "全部一致" : rangeFailures.joined(separator: " "))

        // 12.5 completeness 四态：三态由适配器判，excluded 由 3.12 与私密浏览先行判。
        var completenessFailures: [String] = []
        for item in AdapterVectors.completenessCases {
            let scan = AdapterEngine.scan(rule: item.rule, window: item.tree(),
                                          windowFrame: item.windowFrame)
            if scan.completeness != item.expected {
                completenessFailures.append("\(item.name)→\(scan.completeness.rawValue)")
            }
        }
        let excludedByMode = AdapterVectors.excludedByPolicy(mode: .eventsOnly, privateBrowsing: false)
        let excludedByPrivate = AdapterVectors.excludedByPolicy(mode: .eventsAndContent,
                                                                privateBrowsing: true)
        let notExcluded = AdapterVectors.excludedByPolicy(mode: .eventsAndContent,
                                                          privateBrowsing: false)
        check("completeness 四态各有用例（complete / partial / unavailable / excluded）",
              completenessFailures.isEmpty && excludedByMode == .excluded
                && excludedByPrivate == .excluded && notExcluded == nil,
              completenessFailures.isEmpty
                ? "适配器判三态 + 「只记事件」与私密浏览判 excluded"
                : completenessFailures.joined(separator: " "))

        // 12.6 OCR 触发条件三类 + 反例
        var ocrTriggerFailures: [String] = []
        for item in AdapterVectors.triggerCases {
            let got = OCRTriggerGate.reason(ruleDeclaresOCR: item.ruleDeclaresOCR,
                                            ocrFallback: item.ocrFallback,
                                            axEmpty: item.axEmpty,
                                            axChanged: item.axChanged,
                                            frameChanged: item.frameChanged,
                                            coverageFailed: item.coverageFailed)
            if got != item.expected {
                ocrTriggerFailures.append("\(item.name)→\(got?.rawValue ?? "(不触发)")")
            }
        }
        check("OCR 触发条件 \(AdapterVectors.triggerCases.count) 条（三类 + 反例）",
              ocrTriggerFailures.isEmpty,
              ocrTriggerFailures.isEmpty
                ? OCRTriggerReason.allCases.map(\.rawValue).joined(separator: " / ")
                : ocrTriggerFailures.joined(separator: " "))

        // 12.7 频率限制：同一窗口区域最少间隔
        let gate = OCRTriggerGate()
        let base = 1_000_000.0
        let first = gate.allow(key: "com.tencent.xinWeChat|chat_panel",
                               reason: .ruleDeclared, now: base)
        let tooSoon = gate.allow(key: "com.tencent.xinWeChat|chat_panel",
                                 reason: .ruleDeclared, now: base + gate.minInterval / 2)
        let otherRegion = gate.allow(key: "com.tencent.xinWeChat|conversation_title",
                                     reason: .ruleDeclared, now: base + gate.minInterval / 2)
        let later = gate.allow(key: "com.tencent.xinWeChat|chat_panel",
                               reason: .ruleDeclared, now: base + gate.minInterval + 0.01)
        check("OCR 频率限制：同一窗口区域最少间隔 \(gate.minInterval) s",
              first.isAllowed && !tooSoon.isAllowed && otherRegion.isAllowed && later.isAllowed
                && gate.rateLimitedTotal == 1,
              "首次放行、\(gate.minInterval / 2) s 后同区域被限、别的区域不受影响、"
                + "超过间隔后放行（来源 \(gate.minIntervalSource)）")

        // 12.8 阅读顺序（按 boundingBox 行聚类）
        var orderFailures: [String] = []
        for item in AdapterVectors.readingOrderCases {
            let got = ReadingOrder.text(item.items)
            if got != item.expected {
                orderFailures.append("\(item.name)→\(got.replacingOccurrences(of: "\n", with: "⏎"))")
            }
        }
        check("阅读顺序重建 \(AdapterVectors.readingOrderCases.count) 条", orderFailures.isEmpty,
              orderFailures.isEmpty ? "行聚类 + 行内按 x 排序"
                                    : orderFailures.joined(separator: " "))

        // 12.9 低置信 token（D24）
        let lowConfidencePositives = AdapterVectors.lowConfidencePositives
            .filter { !ReadingOrder.lowConfidenceTokens(in: $0).isEmpty }
        let lowConfidenceNegatives = AdapterVectors.lowConfidenceNegatives
            .filter { ReadingOrder.lowConfidenceTokens(in: $0).isEmpty }
        check("低置信 token 标记（D24）：正例 \(AdapterVectors.lowConfidencePositives.count) 条 /"
              + " 反例 \(AdapterVectors.lowConfidenceNegatives.count) 条",
              lowConfidencePositives.count == AdapterVectors.lowConfidencePositives.count
                && lowConfidenceNegatives.count == AdapterVectors.lowConfidenceNegatives.count,
              "短哈希 / 十六进制 / 内存地址标记低置信，不作证据")

        // 12.10 气泡归属（合成布局 JSON）
        let layouts = AdapterVectors.bubbleLayouts()
        var bubbleFailures: [String] = []
        for layout in layouts {
            let bubbles = BubbleAttribution.attribute(items: layout.items,
                                                      layout: ChatLayout(),
                                                      group: layout.group,
                                                      regionHeightPoints: layout.regionHeightPoints)
            let got = bubbles.map(\.line)
            if got != layout.expected { bubbleFailures.append("\(layout.name)→\(got)") }
        }
        check("气泡归属：\(layouts.count) 份合成布局（单聊左右 / 群聊昵称 / 语音标签）",
              layouts.count == 2 && bubbleFailures.isEmpty,
              bubbleFailures.isEmpty ? "单聊左 = 对方、右 = 自己；群聊取上方昵称；语音记 [语音]"
                                     : bubbleFailures.joined(separator: " "))

        // 12.10a 会话名与群聊判定（M2：`group` 曾被写死成 false，群聊昵称一条都认不出来）
        var titleFailures: [String] = []
        for item in AdapterVectors.chatTitleCases {
            let got = ChatTitle.resolve(item.raw)
            if got != item.expected {
                titleFailures.append("\(item.name)→\(got.map { "\($0.display)/\($0.isGroup)" } ?? "nil")")
            }
        }
        check("会话名与群聊判定：\(AdapterVectors.chatTitleCases.count) 条（含 2 条真机样本）",
              titleFailures.isEmpty,
              titleFailures.isEmpty ? "人数后缀「（29）」判群聊；图标残渣与人数后缀不进 windows.title"
                                    : titleFailures.joined(separator: " "))

        // 12.10b 定点内缩矩形（M2：比例切分在 1085 pt 宽的微信窗口上把半个会话列表当成了聊天面板）
        var insetFailures: [String] = []
        for item in AdapterVectors.windowInsetCases {
            let got = item.inset.resolve(in: item.window)
            if got != item.expected { insetFailures.append("\(item.name)→\(got)") }
        }
        check("定点内缩矩形：\(AdapterVectors.windowInsetCases.count) 条（含窄窗口退回比例兜底）",
              insetFailures.isEmpty,
              insetFailures.isEmpty ? "侧栏 / 标题条 / 输入框按点数让开，不随窗口宽度按比例伸缩"
                                    : insetFailures.joined(separator: " "))

        // 12.10c 分栏边界检测（M2：把写死的 340/60/180 换成从窗口图像现场量）
        var paneFailures: [String] = []
        var paneDetail: [String] = []
        for fixture in PaneFixture.all {
            guard let image = fixture.render() else {
                paneFailures.append("\(fixture.name)→构图失败")
                continue
            }
            let got = PaneDetector.detect(window: image,
                                          windowSize: CGSize(width: fixture.width,
                                                             height: fixture.height),
                                          fallback: fixture.fallback)
            let want = fixture.expected
            let offBy = max(abs(got.sidebarRight - want.sidebarRight),
                            max(abs(got.titleBottom - want.titleBottom),
                                abs(got.composerTop - want.composerTop)))
            if offBy > fixture.tolerance || got.source != want.source {
                paneFailures.append("\(fixture.name)→\(got.label) 期望 \(want.label)")
            } else {
                paneDetail.append(String(format: "%@ 误差 %.1f pt", fixture.name, offBy))
            }
        }
        check("分栏边界检测：\(PaneFixture.all.count) 份合成窗口（含气泡干扰 / 拖宽侧栏 / 纯色兜底）",
              paneFailures.isEmpty,
              paneFailures.isEmpty ? paneDetail.joined(separator: "；")
                                   : paneFailures.joined(separator: " "))

        // 12.10d 窗口定向截图的挑窗规则（M2）
        typealias Candidate = CaptureController.WindowCandidate
        let wechatBundle = "com.tencent.xinWeChat"
        let mainWindow = Candidate(id: 1, bundleID: wechatBundle, isOnScreen: true, layer: 0,
                                   frame: CGRect(x: 1601, y: 97, width: 1085, height: 846))
        let imageViewer = Candidate(id: 2, bundleID: wechatBundle, isOnScreen: true, layer: 0,
                                    frame: CGRect(x: 200, y: 200, width: 600, height: 500))
        let tooltip = Candidate(id: 3, bundleID: wechatBundle, isOnScreen: true, layer: 0,
                                frame: CGRect(x: 0, y: 0, width: 180, height: 60))
        let panel = Candidate(id: 4, bundleID: wechatBundle, isOnScreen: true, layer: 3,
                              frame: CGRect(x: 0, y: 0, width: 1200, height: 900))
        let offscreen = Candidate(id: 5, bundleID: wechatBundle, isOnScreen: false, layer: 0,
                                  frame: CGRect(x: 0, y: 0, width: 1400, height: 1000))
        let otherApp = Candidate(id: 6, bundleID: "com.apple.Safari", isOnScreen: true, layer: 0,
                                 frame: CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let pool = [tooltip, imageViewer, panel, offscreen, otherApp, mainWindow]
        var pickFailures: [String] = []
        func expectPick(_ name: String, _ candidates: [Candidate], _ bundle: String?,
                        _ expected: CGWindowID?) {
            let got = CaptureController.pickTarget(candidates, bundleID: bundle)
            if got?.id != expected { pickFailures.append("\(name)→\(got?.id.description ?? "nil")") }
        }
        expectPick("多窗口取面积最大的主窗口", pool, wechatBundle, 1)
        expectPick("跳过浮层 / 小窗 / 离屏 / 别的应用",
                   [tooltip, panel, offscreen, otherApp], wechatBundle, nil)
        expectPick("只剩图片查看窗口时就用它", [imageViewer, tooltip], wechatBundle, 2)
        expectPick("bundle id 为空 → 不定向截图（退回整屏）", pool, nil, nil)
        expectPick("这个应用一个窗口都没有 → 退回整屏", [otherApp], wechatBundle, nil)
        check("窗口定向截图挑窗：5 条（面积最大 / 排除浮层与离屏 / 退回整屏）",
              pickFailures.isEmpty,
              pickFailures.isEmpty ? "只认在屏的普通窗口层、边长 ≥ 200 pt，取面积最大的那个"
                                   : pickFailures.joined(separator: " "))

        // 12.11 裁剪坐标：AX 坐标 → 显示器局部 → 像素（含 2x 缩放与跨屏落空）
        var cropDetail = "构图失败"
        var cropOK = false
        if let canvas = OCRSelfTest.makeContext(width: 800, height: 600,
                                                background: (1, 1, 1))?.makeImage() {
            // 显示器：原点 (100, 50)、400×300 点；图像 800×600 像素 → scale = 2。
            let bounds = CGRect(x: 100, y: 50, width: 400, height: 300)
            let cropped = ViewportOCR.crop(canvas,
                                           axRect: CGRect(x: 150, y: 100, width: 200, height: 100),
                                           displayBounds: bounds)
            let offScreen = ViewportOCR.crop(canvas,
                                             axRect: CGRect(x: 2_000, y: 2_000,
                                                            width: 100, height: 100),
                                             displayBounds: bounds)
            cropOK = cropped?.pixelRect == CGRect(x: 100, y: 100, width: 400, height: 200)
                && cropped?.image.width == 400 && cropped?.image.height == 200
                && offScreen == nil
            let pixelLabel: String
            if let rect = cropped?.pixelRect {
                pixelLabel = "\(Int(rect.origin.x)),\(Int(rect.origin.y)),"
                           + "\(Int(rect.width)),\(Int(rect.height))"
            } else {
                pixelLabel = "nil"
            }
            let offScreenLabel = offScreen == nil ? "不裁（nil）" : "竟然裁了"
            cropDetail = "AX(150,100,200,100) @ 显示器(100,50,400,300)、2x → 像素 "
                       + pixelLabel + "；另一块屏上的矩形 → " + offScreenLabel
        }
        check("视口 OCR 裁剪：AX 坐标 → 显示器局部 → 像素（含跨屏落空）", cropOK, cropDetail)

        // 12.12 OCR 冒烟 + 自绘图像基准（Vision 本地推理，不触发任何授权）
        let outcomes = OCRSelfTest.run()
        let asserted = outcomes.filter(OCRSelfTest.isAsserted)
        let failedOutcomes = asserted.filter { !OCRSelfTest.passes($0) }
        check("视口 OCR 冒烟：\(outcomes.count) 组自绘图像（\(OCRSelfTest.samples.count) 样张 × 2x/1x）",
              outcomes.count == OCRSelfTest.samples.count * 2 && failedOutcomes.isEmpty,
              failedOutcomes.isEmpty
                ? "断言 \(asserted.count) 组：无标点标识符严格召回 ≥ \(OCRSelfTest.recallFloor)、"
                + "带标点标识符按检索侧折叠口径召回 ≥ \(OCRSelfTest.recallFloor)、"
                + "中文行 CER ≤ \(OCRSelfTest.chineseCERCeiling)"
                : failedOutcomes.map {
                    "\($0.sampleID)@\($0.scaleLabel) 严格 \(String(format: "%.2f", $0.identifierRecall))"
                    + " 折叠 \(String(format: "%.2f", $0.foldedIdentifierRecall))"
                    + " CER \(String(format: "%.3f", $0.chineseCER))"
                    + " 缺 \($0.missingIdentifiers) / \($0.foldedMissingIdentifiers)"
                  }.joined(separator: "；"))
        for outcome in outcomes {
            print("      \(outcome.sampleID)@\(outcome.scaleLabel) "
                  + "\(outcome.pixelWidth)×\(outcome.pixelHeight)："
                  + "无标点标识符严格召回 \(String(format: "%.3f", outcome.identifierRecall))、"
                  + "带标点标识符 折叠 \(String(format: "%.3f", outcome.foldedIdentifierRecall))"
                  + " / 严格 \(String(format: "%.3f", outcome.punctuatedStrictRecall))、"
                  + "CER \(String(format: "%.4f", outcome.cer))、"
                  + "中文行 CER \(String(format: "%.4f", outcome.chineseCER))、"
                  + "置信度 \(String(format: "%.3f", outcome.meanConfidence))、"
                  + "\(Int(outcome.elapsedMS)) ms、真值 \(outcome.truthChars) 字符 → "
                  + "\(outcome.ocrChars) 字符"
                  + (OCRSelfTest.isAsserted(outcome) ? "" : "（1x 代码小字按 D24 只报数不断言）"))
        }

        // 12.13 采样审计的覆盖率口径（core 的 CaptureCoverage，这里只做一次冒烟）
        let coverageSame = CaptureCoverage.coverage(axText: "适配器与视口 OCR",
                                                    ocrText: "适配器与视口 OCR 还有别的东西")
        let coverageHalf = CaptureCoverage.coverage(axText: "视口内的正文 视口外的正文 abcdef",
                                                    ocrText: "视口内的正文")
        check("采样审计覆盖率口径（AX token 在 OCR 文本里的命中比例）",
              coverageSame.coverage == 1.0 && coverageHalf.coverage > 0.2
                && coverageHalf.coverage < 0.8,
              "全命中 \(String(format: "%.3f", coverageSame.coverage))、"
                + "只读到一半 \(String(format: "%.3f", coverageHalf.coverage))"
                + "（阈值 \(CaptureCoordinator.coverageThresholdDefault)）")


        // 12.14 端到端：合成上下文 → 协调者 → 自绘"屏幕" → OCR 观察 + capture_audit
        // 走的是产品路径本身（`CaptureCoordinator.handleFrame`），只把"显示器有多大"喂进来。
        do {
            let ocrRoot = workspace.appendingPathComponent("ocr-e2e", isDirectory: true)
            var options = StoreOptions()
            options.deviceID = "selfcheck-ocr"
            let ocrStore = try Store.open(directory: ocrRoot,
                                          keyProvider: try InMemoryKeyProvider.random(),
                                          options: options)
            defer { ocrStore.close() }
            let ocrRecorder = Recorder()
            ocrRecorder.attach(ocrStore)

            let suite = "com.brosis.selfcheck.ocr-\(ProcessInfo.processInfo.processIdentifier)"
            let ocrDefaults = UserDefaults(suiteName: suite) ?? .standard
            defer { ocrDefaults.removePersistentDomain(forName: suite) }
            let coordinator = CaptureCoordinator(defaults: ocrDefaults)

            // 自绘一张 864×560 的"屏幕"（深色聊天面板样张的 1x），显示器就当成 864×560 点。
            guard let sample = OCRSelfTest.samples.first(where: { $0.id == "dark_ui" }),
                  let base = OCRSelfTest.render(sample),
                  let screen = OCRSelfTest.downscale(base, factor: 0.5,
                                                     background: sample.background) else {
                check("视口 OCR 端到端：自绘屏幕", false, "构图失败")
                throw CaptureController.CaptureError.noDisplay
            }
            let bounds = CGRect(x: 0, y: 0, width: Double(screen.width), height: Double(screen.height))

            // ① AX 全空的应用（微信形态）：规则声明 OCR → 写一条 capture_method = ocr 的观察。
            let wechatContext = CaptureCoordinator.Context(
                bundleID: "com.brosis.selfcheck.wechat", appName: "自检微信",
                ruleID: AdapterRegistry.wechat.id, displayID: 1, windowFrame: bounds,
                windowTitle: "自检会话", observationID: nil, axText: "",
                regionTexts: [:],
                ocrRequests: [OCRRequest(regionName: "chat_panel", kind: .messageList,
                                         rect: bounds, reason: .ruleDeclared)],
                chatLayout: ChatLayout(), completeness: .unavailable, captureMethod: .ocr,
                at: Date().timeIntervalSince1970)
            coordinator.noteScan(wechatContext)
            let ranOCR = coordinator.handleFrame(screen, displayID: 1, recorder: ocrRecorder,
                                                 gated: true, trigger: "self_check",
                                                 bundleID: "com.brosis.selfcheck.wechat",
                                                 displayBoundsOverride: bounds)
            let ocrIDs = try ocrStore.search(q: "适配器", limit: 5).hits.map(\.evidenceID)
            let ocrEvidence = try ocrStore.getEvidence(ids: ocrIDs, grant: nil, neighbors: 0)
            let ocrItem = ocrEvidence.items.first
            let ocrOccurrence = ocrItem?.occurrences.first
            check("视口 OCR 端到端：AX 全空 → capture_method = ocr 的观察入库",
                  ranOCR == 1 && ocrItem?.captureMethod == CaptureMethod.ocr.rawValue
                    && ocrOccurrence?.region == "ocr:wechat.chat_panel"
                    && (ocrOccurrence?.confidence ?? 0) > 0
                    && (ocrOccurrence?.note?.contains("lowconf=") ?? false)
                    && (ocrItem?.text?.contains("适配器") ?? false),
                  "区域 \(ocrOccurrence?.region ?? "nil")、"
                    + "置信度 \(String(format: "%.2f", ocrOccurrence?.confidence ?? 0))、"
                    + "note \(ocrOccurrence?.note ?? "nil")")

            // ①' **陈旧上下文**（R2 复核发现的缺陷，这里是它的复现）：上下文只在 AX 扫描时更新，
            // 而私密浏览 / AX 超时 / 读不到焦点窗口这三支**不扫描**，截图那条通路却照常出图。
            // 不核身份的话，上一个应用（这里是微信）排的 OCR 请求就会落到**另一个应用的画面**上，
            // 把无痕窗口的正文以微信的身份、`capture_method = ocr` 入库。
            // 这里换一张完全不同的自绘"屏幕"当作那个新应用：期望一个区域都不跑、一个字都不入库。
            guard let otherSample = OCRSelfTest.samples.first(where: { $0.id == "body_mixed" }),
                  let otherBase = OCRSelfTest.render(otherSample),
                  let otherScreen = OCRSelfTest.downscale(otherBase, factor: 0.5,
                                                          background: otherSample.background) else {
                check("视口 OCR 端到端：另一个应用的自绘屏幕", false, "构图失败")
                throw CaptureController.CaptureError.noDisplay
            }
            // 先把限流时钟清掉：要考的是"身份对不上"，不能让 5 s 限流替它挡住。
            coordinator.trigger.reset()
            let ranStale = coordinator.handleFrame(otherScreen, displayID: 1, recorder: ocrRecorder,
                                                   gated: true, trigger: "self_check",
                                                   bundleID: "com.brosis.selfcheck.private",
                                                   displayBoundsOverride: bounds)
            let leakedHits = try ocrStore.search(q: "采集守护进程", limit: 5).hits.count
            // 阳性对照：同一张图、同一时刻，只把前台应用换回上下文里的那个 → 照样会认、会入库。
            // （上一次调用发现身份对不上时已经把这份陈旧上下文丢掉了，所以这里要重新排一次。）
            coordinator.noteScan(wechatContext)
            coordinator.trigger.reset()
            let ranSameApp = coordinator.handleFrame(otherScreen, displayID: 1,
                                                     recorder: ocrRecorder,
                                                     gated: true, trigger: "self_check",
                                                     bundleID: "com.brosis.selfcheck.wechat",
                                                     displayBoundsOverride: bounds)
            let sameAppHits = try ocrStore.search(q: "采集守护进程", limit: 5).hits.count
            check("陈旧上下文：前台已换应用时不跑上一个应用的 OCR 请求（私密浏览 / AX 超时）",
                  ranStale == 0 && leakedHits == 0
                    && coordinator.currentStats.ocrStaleContext == 1
                    && ranSameApp == 1 && sameAppHits > 0,
                  "换应用后 跑 \(ranStale) 个区域 / 命中 \(leakedHits) 条（上下文过期计数 "
                    + "\(coordinator.currentStats.ocrStaleContext)）；"
                    + "阳性对照（同一张图换回原应用）跑 \(ranSameApp) 个区域 / 命中 "
                    + "\(sameAppHits) 条")

            // ①'' **OCR 侧的新鲜度判定**：同一区域再认一次同一张图，文本逐字节没变 →
            // OCR 照跑（拦不住，得认了才知道变没变），但**不写第二条观察**。
            let beforeRepeat = try ocrStore.count(table: "observations")
            coordinator.trigger.reset()
            let ranRepeat = coordinator.handleFrame(otherScreen, displayID: 1,
                                                    recorder: ocrRecorder,
                                                    gated: true, trigger: "self_check",
                                                    bundleID: "com.brosis.selfcheck.wechat",
                                                    displayBoundsOverride: bounds)
            let afterRepeat = try ocrStore.count(table: "observations")
            check("OCR 新鲜度：同一区域正文逐字节未变时不再写第二条观察",
                  ranRepeat == 1 && afterRepeat == beforeRepeat
                    && coordinator.currentStats.ocrUnchanged == 1,
                  "重复识别 \(ranRepeat) 个区域、观察 \(beforeRepeat) → \(afterRepeat) 条"
                    + "（未变化计数 \(coordinator.currentStats.ocrUnchanged)）")

            let ocrStats = coordinator.currentStats

            // ② AX 非空的应用：轮到采样审计 → 全窗口 OCR 对照 → 写 capture_audit。
            // reset() 会清掉上面那一段的统计，所以先把它存下来再清。
            coordinator.reset()
            coordinator.noteScan(CaptureCoordinator.Context(
                bundleID: "com.brosis.selfcheck.audit", appName: "自检审计",
                ruleID: AdapterRegistry.generic.id, displayID: 1, windowFrame: bounds,
                windowTitle: "自检窗口", observationID: 42,
                axText: "李四：确认了，飞书和微信都在里面",
                regionTexts: ["window": "李四：确认了，飞书和微信都在里面"],
                ocrRequests: [], chatLayout: nil, completeness: .partial, captureMethod: .ax,
                at: Date().timeIntervalSince1970))
            coordinator.forceAuditDue()
            _ = coordinator.handleFrame(screen, displayID: 1, recorder: ocrRecorder,
                                        gated: true, trigger: "self_check",
                                        bundleID: "com.brosis.selfcheck.audit",
                                        displayBoundsOverride: bounds)
            let auditRows = try ocrStore.captureAuditTail(limit: 5)
            let auditRow = auditRows.first
            check("采样审计端到端：全窗口 OCR 对照 → capture_audit 一行",
                  auditRows.count == 1 && auditRow?.observationID == 42
                    && auditRow?.app == "com.brosis.selfcheck.audit"
                    // method 照抄被审计那条观察的 capture_method（兜底规则 = ax），
                    // 不再靠 completeness 猜（R2 复核：excluded 的观察根本不会走到这里）。
                    && auditRow?.method == .ax
                    && (auditRow?.coverage ?? 0) >= 0.8 && (auditRow?.axTokens ?? 0) > 0,
                  "method \(auditRow?.method.rawValue ?? "nil")、"
                    + "覆盖率 \(String(format: "%.3f", auditRow?.coverage ?? 0))"
                    + "（token \(auditRow?.hitTokens ?? 0)/\(auditRow?.axTokens ?? 0)，"
                    + "AX \(auditRow?.axChars ?? 0) 字符 vs OCR \(auditRow?.ocrChars ?? 0) 字符，"
                    + "\(Int(auditRow?.elapsedMS ?? 0)) ms）")
            print("      协调者统计（区域 OCR）：\(ocrStats.summary)")
            print("      协调者统计（采样审计）：\(coordinator.currentStats.summary)")
        } catch {
            check("视口 OCR / 采样审计端到端", false, "\(error)")
        }

        // ------------------------------------------------ 7. 跨设备同步（M2 c / T13，3.9 / D17）
        // 实现在 SyncSelfCheck.swift（本文件只加这一行，避免与并行任务改同一段）。
        failures += SyncSelfCheck.run()

        // ------------------------------ 8. 模型管理器与向量检索（M2 c / T11，3.4 / 3.11 / D18 / D27）
        // 实现在 Models/ModelsSelfCheck.swift（本文件同样只加这一行）。
        // 它不加载任何模型（向量那段用确定性伪嵌入），所以没装模型的机器上照样应该全过。
        failures += ModelsSelfCheck.run()
        failures += MCPIntegrationSelfCheck.run()

        // ------------------------------------ 9. 夜间叙述（M2 c / T12，4.3 / 3.7 / 3.10 / D19）
        // 实现在 Models/NarrativeSelfCheck.swift（本文件同样只加这一行）。
        // 生成侧用脚本化假提供方，**不加载 2.85 GiB 的权重**，所以几毫秒跑完、
        // 没装模型的机器上照样全过；真实模型那一次在 `--narrative-smoke` 里。
        failures += NarrativeSelfCheck.run()

        // ------------------------- 10. MCP 检索的查询向量（M2 d / T15，3.4 / 3.6 / 4.3.2）
        // 实现在 Models/QueryEmbedderSelfCheck.swift（本文件同样只加这一行）。
        // 查询嵌入器用确定性伪嵌入，**不加载任何模型**；真实模型那一层在
        // `brosis-embed selftest` 与 tools/eval/d8_mcp_compare.py 里。
        failures += QueryEmbedderSelfCheck.run()

        // ------------------------------- 11. 加密导出 / 导入（M2 d / T16，3.8 / D7 / 4.3.2）
        // 实现在 ExportSelfCheck.swift（本文件同样只加这一行）。
        // 临时库往返冒烟：导出 → 归档里搜不到明文 → 导入 → 证据逐字节相同 →
        // 源库删掉之后归档仍然完整（3.8「删除不能覆盖已导出的副本」）。
        failures += ExportSelfCheck.run()

        // ------------------------------- 12. 全局热键（M2 d / T18，3.5 / 4.2 / 4.3.2）
        // 实现在 HotKeySelfCheck.swift（本文件同样只加这一行）。
        // 热键**真的注册**一遍再**立刻注销**，不给正在运行的那个 brosis 留下抢着的组合。
        // （原来同组的 Focus 联动三项已随该功能一起删除。）
        failures += HotKeySelfCheck.run()

        // ------------------------------- 13. 2.2 硬约束里能自动化的三条（M2 d / T18）
        // 实现在 HardConstraintSelfCheck.swift（本文件同样只加这一行）。
        // 逐条对照表在 tools/bench/results/m2_d_focus_hotkey_2026-09-08.md。
        failures += HardConstraintSelfCheck.run()

        // ---------------------------------------------------------------- 参数快照
        print("加密库自检工作目录：\(workspace.path)（跑完删除）")
        print("MCP：\(MCPTool.allCases.count) 个工具 "
              + MCPTool.allCases.map(\.rawValue).joined(separator: " ")
              + "；限流默认 \(MCPIPCService.defaultRequestsPerMinute) 次/分钟"
              + "（UserDefaults 键 \(MCPIPCService.rateLimitKey)）"
              + "；socket 名 \(IPCProtocol.socketFileName)"
              + "；本进程 Team ID \(PeerVerifier.selfTeamID() ?? "无（未签名 / ad-hoc）")")
        print("自检库统计：\(storeSummary)")
        print("存储统计导出：\(StatsExport.fileName(for: Date()))"
              + "（schema_version \(StatsExport.schemaVersion)）字段 \(statsExportShape)")
        print("产品数据目录：\(DataLocation.resolve().url.path)"
              + "（来源 \(DataLocation.resolve().source)，UserDefaults 键 \(DataLocation.directoryKey)）")
        print("M0 明文库目录：\(DataLocation.legacyM0URL.path)"
              + "（\(FileManager.default.fileExists(atPath: DataLocation.legacyM0URL.path) ? "存在，本版本不再读写、不迁移" : "不存在")）")
        print("严格锁定模式：\(LockPolicy.strictScreenLock()) （UserDefaults 键 \(LockPolicy.strictKey)；"
              + "true 时屏幕锁定也走 locking）")
        print("定时兜底间隔：\(CaptureController.periodicInterval) s"
              + "（来源 \(CaptureController.periodicIntervalSource)，"
              + "默认 \(CaptureController.periodicIntervalDefault) s，"
              + "下限 \(CaptureController.periodicIntervalMinimum) s，"
              + "UserDefaults 键 \(CaptureController.periodicIntervalKey)）")
        let finderLimits = AX.bfsLimits(bundleID: "com.apple.finder")
        print("AX BFS 限额：默认 \(AX.defaultBFSLimits.label)；"
              + "com.apple.finder \(finderLimits.label)；单角色正文上限 \(AX.maxCharsPerRole) 字符")
        print("内置默认不采集清单：" + BuiltinDenylist.shared.sorted.joined(separator: " "))
        print("全局热键：" + HotKeyAction.allCases
                .map { "\($0.defaultsKey)=\(HotKeys.keyString($0)) → \($0.title)" }
                .joined(separator: "；"))
        print(failures == 0 ? "自检通过" : "自检失败 \(failures) 项")
        return failures == 0 ? 0 : 1
    }

    /// 在给定文件的原始字节里找这些字符串（UTF-8）。文件不存在就跳过。
    private static func scanForPlaintext(in files: [URL], needles: [String]) -> [String] {
        var hits: [String] = []
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            for needle in needles where data.range(of: Data(needle.utf8)) != nil {
                hits.append("\(file.lastPathComponent):\(needle)")
            }
        }
        return hits
    }

    /// Electron / CEF 通用检测的验证。
    ///
    /// 正反两例都在临时目录里**伪造 .app 目录结构**（只 mkdir，不放任何可执行文件），
    /// 验证 `AX.bundleContainsElectronFramework` 返回 true / false；跑完删掉。
    /// 再对 `/Applications` 下真实装着的 Claude / 飞书各探一次并打印依据——
    /// 全程只读目录、只读 Info.plist，**不启动它们、不发 AX 消息、不请求任何权限**。
    private static func electronProbe()
        -> (positivePassed: Bool, positiveDetail: String,
            negativePassed: Bool, negativeDetail: String,
            installedNotes: [String]) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "brosis-selfcheck-electron-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let withFramework = root.appendingPathComponent("WithElectron.app", isDirectory: true)
        let withoutFramework = root.appendingPathComponent("NativeApp.app", isDirectory: true)

        var positivePassed = false
        var negativePassed = false
        var positiveDetail = ""
        var negativeDetail = ""
        do {
            try fm.createDirectory(
                at: withFramework.appendingPathComponent(
                    "Contents/Frameworks/\(AX.electronFrameworkNames[0])", isDirectory: true),
                withIntermediateDirectories: true)
            try fm.createDirectory(
                at: withoutFramework.appendingPathComponent("Contents/Frameworks", isDirectory: true),
                withIntermediateDirectories: true)
            let positive = AX.bundleContainsElectronFramework(at: withFramework)
            let negative = AX.bundleContainsElectronFramework(at: withoutFramework)
            positivePassed = positive == true
            negativePassed = negative == false
            positiveDetail = "WithElectron.app/Contents/Frameworks/\(AX.electronFrameworkNames[0])"
                           + " → \(positive)（期望 true）"
            negativeDetail = "NativeApp.app/Contents/Frameworks/（空目录）"
                           + " → \(negative)（期望 false）"
        } catch {
            positiveDetail = "创建伪造 bundle 失败：\(error)"
            negativeDetail = positiveDetail
        }

        // 真实应用探测：装了才探，没装就跳过（不同机器结果不同，所以只打印、不参与通过判定）。
        var notes: [String] = []
        let candidates = [
            ("Claude 桌面版", "/Applications/Claude.app"),
            ("飞书 Lark", "/Applications/Lark.app"),
            ("飞书 Feishu", "/Applications/Feishu.app")
        ]
        for (label, path) in candidates where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let bundleID = Bundle(url: url)?.bundleIdentifier
            let framework = AX.bundleContainsElectronFramework(at: url)
            let detection = AX.chromiumDetection(bundleID: bundleID, bundleURL: url).detection
            notes.append("\(label)：bundle=\(bundleID ?? "?") 依据=\(detection.rawValue)"
                         + " 框架检测=\(framework)（未启动，仅读目录）")
        }
        if notes.isEmpty {
            notes = ["/Applications 下没有 Claude / 飞书，跳过真实应用探测"]
        }
        return (positivePassed, positiveDetail, negativePassed, negativeDetail, notes)
    }

    /// 合成一张 640×400 的测试图：seed 0 是浅底深条，seed 1 是深底浅条（近似反色）。
    private static func syntheticImage(seed: Int) -> CGImage? {
        let width = 640, height = 400
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let background: CGFloat = seed == 0 ? 0.95 : 0.08
        let bar: CGFloat = seed == 0 ? 0.10 : 0.92
        context.setFillColor(red: background, green: background, blue: background, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: bar, green: bar, blue: bar, alpha: 1)
        for row in 0..<8 {
            let barWidth = 40 + row * 55
            context.fill(CGRect(x: (row % 2) * 60, y: row * 50 + 6, width: barWidth, height: 22))
        }
        return context.makeImage()
    }
}

/// `--dump-vectors`：把三张判定表逐条打印出来。
///
/// 存在的理由是**可核对**：自检只输出一行"18 条正例 + 12 条反例全过"，
/// 复核的人没法从那一行看出规则到底把什么替换成了什么。这个开关把每条向量的
/// 输入 → 输出、三档的开关表、状态机的 21 条转移与 7 条补做用例全部摊开，
/// 输出可以直接贴进结果文件。
/// 它同样不碰 TCC、不开库、不创建 NSApplication。
enum VectorDump {

    static func run() -> Int32 {
        print("brosis \(BuildInfo.version) 判定表转储（只读，不开库、不碰 TCC）")

        print("\n## 1. 入库前脱敏：正例 \(RedactionVectors.positives.count) 条")
        print("| # | 名称 | 输入 | 输出 | 类型 | 判定 |")
        print("|---|---|---|---|---|---|")
        for (index, vector) in RedactionVectors.positives.enumerated() {
            let result = Redactor.redact(vector.input)
            let ok = result.text == vector.expected
                && Set(result.counts.keys) == Set(vector.types)
            print("| \(index + 1) | \(vector.name) | `\(escape(vector.input))` "
                  + "| `\(escape(result.text))` | \(result.counts.keys.map(\.rawValue).sorted().joined(separator: ",")) "
                  + "| \(ok ? "PASS" : "FAIL") |")
        }

        print("\n## 2. 入库前脱敏：反例 \(RedactionVectors.negatives.count) 条（要求原样返回、0 命中）")
        print("| # | 名称 | 输入 | 命中数 | 判定 |")
        print("|---|---|---|---|---|")
        for (index, vector) in RedactionVectors.negatives.enumerated() {
            let result = Redactor.redact(vector.input)
            let ok = !result.hit && result.text == vector.input
            print("| \(index + 1) | \(vector.name) | `\(escape(vector.input))` | \(result.total) "
                  + "| \(ok ? "PASS" : "FAIL") |")
        }

        print("\n## 3. 3.12 三档的生效方式")
        print("| 模式 | 记事件 | 读正文 | 进 SCContentFilter 排除 |")
        print("|---|---|---|---|")
        for mode in CapturePolicyMode.allCases {
            let gate = CapturePolicyStore.gate(for: mode)
            print("| \(mode.rawValue) | \(gate.recordsEvents) | \(gate.readsContent) "
                  + "| \(gate.excludedFromScreenCapture) |")
        }

        print("\n## 4. 3.5 锁定状态机：\(LockPolicy.transitionCases.count) 条转移")
        print("| # | 起点 | 触发 | 严格模式 | 期望 | 实得 | 判定 |")
        print("|---|---|---|---|---|---|---|")
        for (index, item) in LockPolicy.transitionCases.enumerated() {
            let got = LockPolicy.next(item.from, on: item.trigger, strictScreenLock: item.strict)
            print("| \(index + 1) | \(describe(item.from)) | \(item.trigger.rawValue) | \(item.strict) "
                  + "| \(describe(item.expected)) | \(describe(got)) "
                  + "| \(got == item.expected ? "PASS" : "FAIL") |")
        }

        print("\n## 5. 3.5 锁定状态机：locking 期间的开库触发要补做（\(LockPolicy.deferredUnlockCases.count) 条）")
        print("| # | 起点相位 | 触发 | 严格模式 | 期望补做 | 实得 | 判定 |")
        print("|---|---|---|---|---|---|---|")
        for (index, item) in LockPolicy.deferredUnlockCases.enumerated() {
            let got = LockPolicy.deferredUnlock(from: LockSnapshot(phase: item.from),
                                                on: item.trigger, strictScreenLock: item.strict)
            print("| \(index + 1) | \(item.from.rawValue) | \(item.trigger.rawValue) | \(item.strict) "
                  + "| \(item.expected?.rawValue ?? "(不补)") | \(got?.rawValue ?? "(不补)") "
                  + "| \(got == item.expected ? "PASS" : "FAIL") |")
        }

        print("\n## 6. 3.5 锁定状态机：锁定类触发取消补做（\(LockPolicy.cancelDeferredCases.count) 条）")
        print("| # | 触发 | 严格模式 | 期望 | 实得 | 判定 |")
        print("|---|---|---|---|---|---|")
        for (index, item) in LockPolicy.cancelDeferredCases.enumerated() {
            let got = LockPolicy.cancelsDeferredUnlock(item.trigger, strictScreenLock: item.strict)
            print("| \(index + 1) | \(item.trigger.rawValue) | \(item.strict) "
                  + "| \(item.expected ? "取消" : "不取消") | \(got ? "取消" : "不取消") "
                  + "| \(got == item.expected ? "PASS" : "FAIL") |")
        }

        print("\n## 7. 内置默认不采集清单（\(BuiltinDenylist.shared.count) 个 bundle id）")
        for category in BuiltinDenylist.categories {
            print("- **\(category.name)**：\(category.bundleIDs.joined(separator: "、"))")
        }
        print("\nResources/exclusions.txt 读到 \(BuiltinDenylist.shared.fromResource) 条，"
              + "代码内 \(BuiltinDenylist.shared.fromCode) 条，取并集后 \(BuiltinDenylist.shared.count) 条。")

        print("\n## 8. 适配规则（3.3；首批 \(AdapterRegistry.all.count) 条 + 兜底）")
        for rule in AdapterRegistry.all + [AdapterRegistry.generic] {
            print("\n### \(rule.name)（id `\(rule.id)`）")
            print("- bundle id：\(rule.bundleIDs.isEmpty ? "（兜底，匹配不到别的规则时用）" : rule.bundleIDs.joined(separator: "、"))")
            print("- Electron：\(rule.electron ? "是（读树前先设 AXManualAccessibility）" : "否")"
                  + "；BFS 限额 \(rule.limits.label)；frame 探测上限 \(rule.maxFrameProbes)")
            print("- 区域：")
            for region in rule.regions { print("  - \(region.label)，字符上限 \(region.maxChars)") }
            if let layout = rule.chatLayout {
                print("- 气泡归属：自己侧阈值 \(layout.selfSideThreshold)、"
                      + "昵称间隔 \(layout.nicknameGap) pt、标签 \(layout.selfLabel) / \(layout.peerLabel)")
            }
            print("- 说明与局限：\(rule.notes)")
        }

        print("\n## 9. OCR 触发条件（3.3：只有三类）")
        print("| # | 用例 | 规则声明 | 允许回退 | AX 空 | AX 变了 | 帧变化 | 覆盖失败 | 期望 | 实得 | 判定 |")
        print("|---|---|---|---|---|---|---|---|---|---|---|")
        for (index, item) in AdapterVectors.triggerCases.enumerated() {
            let got = OCRTriggerGate.reason(ruleDeclaresOCR: item.ruleDeclaresOCR,
                                            ocrFallback: item.ocrFallback,
                                            axEmpty: item.axEmpty, axChanged: item.axChanged,
                                            frameChanged: item.frameChanged,
                                            coverageFailed: item.coverageFailed)
            print("| \(index + 1) | \(item.name) | \(item.ruleDeclaresOCR) | \(item.ocrFallback) "
                  + "| \(item.axEmpty) | \(item.axChanged) | \(item.frameChanged) "
                  + "| \(item.coverageFailed) | \(item.expected?.rawValue ?? "(不触发)") "
                  + "| \(got?.rawValue ?? "(不触发)") | \(got == item.expected ? "PASS" : "FAIL") |")
        }
        let gate = OCRTriggerGate()
        print("\n频率限制：同一「bundle id + 区域名」最少间隔 **\(gate.minInterval) s**"
              + "（来源 \(gate.minIntervalSource)，UserDefaults 键 `\(OCRTriggerGate.minIntervalKey)`，"
              + "下限 \(OCRTriggerGate.minIntervalMinimum) s）。")

        print("\n## 10. 完整性四态的判定来源")
        print("| 状态 | 谁判的 | 条件 |")
        print("|---|---|---|")
        print("| complete | AdapterEngine | 规则声明的必需区域全部读到，且没有视口外内容 / 限额命中 / 字符范围裁剪 / 待办 OCR |")
        print("| partial | AdapterEngine | 读到了一些，但上面任意一条成立 |")
        print("| unavailable | AdapterEngine | 一个字都没读到（含读不到焦点窗口） |")
        print("| excluded | EventSkeleton | 3.12 的「不采集」/「只记事件」档，或私密浏览命中——**读都不读** |")
        for item in AdapterVectors.completenessCases {
            let scan = AdapterEngine.scan(rule: item.rule, window: item.tree(),
                                          windowFrame: item.windowFrame)
            print("- \(item.name)：实得 `\(scan.completeness.rawValue)`"
                  + "（\(item.why)）\(scan.completeness == item.expected ? "PASS" : "FAIL")")
        }

        print("\n## 11. 视口 OCR 自绘样张基准（Vision accurate，zh-Hans + en-US，纠错关）")
        print("| 样张 | 尺寸 | 像素 | 无标点标识符严格召回 | 带标点 折叠 / 严格 | CER | 中文行 CER | 置信度 | 耗时 ms |")
        print("|---|---|---|---:|---:|---:|---:|---:|---:|")
        for outcome in OCRSelfTest.run() {
            print("| \(outcome.sampleName) | \(outcome.scaleLabel) "
                  + "| \(outcome.pixelWidth)×\(outcome.pixelHeight) "
                  + "| \(String(format: "%.3f", outcome.identifierRecall)) "
                  + "| \(String(format: "%.3f", outcome.foldedIdentifierRecall)) / "
                  + "\(String(format: "%.3f", outcome.punctuatedStrictRecall)) "
                  + "| \(String(format: "%.4f", outcome.cer)) "
                  + "| \(String(format: "%.4f", outcome.chineseCER)) "
                  + "| \(String(format: "%.3f", outcome.meanConfidence)) "
                  + "| \(Int(outcome.elapsedMS)) |")
        }
        print("\n判定线：无标点标识符严格召回 ≥ \(OCRSelfTest.recallFloor)、"
              + "带标点标识符按检索侧折叠口径召回 ≥ \(OCRSelfTest.recallFloor)、"
              + "中文行 CER ≤ \(OCRSelfTest.chineseCERCeiling)；"
              + "1x 的代码小字按 D24 只报数不断言。")

        print("\n## 12. 3.12 应用采集清单：合成数据源合并 → 分组 / 排序 / 每行显示什么")
        // 「最近出现」那一列是相对时间（"N 天前"），随跑的日子变，不放进转储表，
        // 免得同一份代码今天和明天转出来的表不一样。它的判定在 `lastSeenLabel`。
        print("| # | 分组 | 应用 | bundle id | 采集模式 | 来源 | 最近 7 天 | 完整性分布 | 状态 |")
        print("|---|---|---|---|---|---|---:|---|---|")
        for (index, row) in PolicyListVectors.build().enumerated() {
            print("| \(index + 1) | \(row.adapterID.map { "有适配器 · \($0)" } ?? row.group.title) "
                  + "| \(row.name) | `\(row.bundleID)` | \(row.mode.label) | \(row.source.rawValue) "
                  + "| \(row.observations) | \(row.completenessLabel) | \(row.statusLabel()) |")
        }
        print("\n数据源：`app_policies` 全表 ∪ 最近 \(PolicyList.statsWindowDays) 天的观察聚合 "
              + "∪ NSWorkspace 当前运行的 GUI 应用。分组顺序：内置清单 > 有适配器 > 通用；"
              + "组内按最近 7 天观察数倒序、再按最近出现倒序、再按 bundle id。")

        print("\n## 13. 3.12 改档流程的状态机（\(PolicyListVectors.changeCases.count) 条）")
        print("| # | 用例 | 原档 | 新档 | 库开着 | 全库观察数 | 期望 | 实得 | 判定 |")
        print("|---|---|---|---|---|---:|---|---|---|")
        for (index, item) in PolicyListVectors.changeCases.enumerated() {
            let got = PolicyModeChange.plan(current: item.current, next: item.next,
                                            storeOpen: item.storeOpen,
                                            existingObservations: item.existing)
            print("| \(index + 1) | \(item.name) | \(item.current.label) | \(item.next.label) "
                  + "| \(item.storeOpen) | \(item.existing) | \(item.expected) | \(got) "
                  + "| \(got == item.expected ? "PASS" : "FAIL") |")
        }
        print("\n档位高低：不采集 \(CapturePolicyMode.none.rank) < "
              + "只记事件 \(CapturePolicyMode.eventsOnly.rank) < "
              + "事件 + 内容 \(CapturePolicyMode.eventsAndContent.rank)；"
              + "只有 rank 变小才问删数据，删走 Store.deleteByApp(reason: .policy)，默认不删。")
        return 0
    }

    private static func describe(_ snapshot: LockSnapshot) -> String {
        snapshot.pauseReasons.isEmpty
            ? snapshot.phase.rawValue
            : "\(snapshot.phase.rawValue)[\(snapshot.pauseDescription)]"
    }

    /// Markdown 表格里 `|` 与换行会破表。
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
