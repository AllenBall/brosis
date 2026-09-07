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
