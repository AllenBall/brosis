import Foundation

/// 采样审计的覆盖率口径（计划 3.3「AX 非空的观察每 N 次取一次全窗口 OCR 对照，
/// 计算覆盖率写入审计表」）。
///
/// **为什么不是"字符数之比"**：AX 与 OCR 的空白、换行、标点几乎从不一致——
/// AX 把一段正文拆成几十个节点用 `\n` 拼起来，OCR 按视觉行分行并且会把
/// 半角括号 / 冒号 / 逗号识别成全角（`ocr_bench_2026-09-06.md` 实测）。
/// 用字符数比会算出一堆假的"覆盖不足"。所以口径定成：
///
/// > **AX 文本切出的 token 里，有多少比例能在 OCR 文本里找到**。
///
/// 切分与比较的三步（两边完全对称，见 `normalize` / `tokens`）：
/// 1. **NFKC 折叠**：把全角标点、全角数字字母折叠成半角（与索引侧 `TextPipeline.foldForIndex`
///    同一个函数，口径不分叉）；
/// 2. **去空白与标点**：空白、标点、符号全部当作分隔符丢掉——这正是 2.4「不用 AX 字符数代替」
///    之后仍然要能比较的那部分内容；
/// 3. **切 token**：连续的汉字段按**字符 bigram**切（与 D22 的 FTS 预处理同一个切法，
///    单字段保留单字），非汉字段按分隔符切成"词"。
///
/// 命中判定是**子串**：token 出现在 OCR 侧的规范化文本里就算命中。用子串而不是集合相等，
/// 是因为 OCR 侧会多出 AX 读不到的东西（图片里的字、被 AX 漏掉的行），多出来的不该扣分。
public enum CaptureCoverage {

    /// 一次对照的结果。**不含任何正文**。
    public struct Result: Sendable, Codable, Equatable {
        public var axChars: Int
        public var ocrChars: Int
        public var axTokens: Int
        public var hitTokens: Int
        /// `hitTokens / axTokens`；`axTokens == 0` 时为 0（AX 什么都没读到，谈不上覆盖率）。
        public var coverage: Double

        public init(axChars: Int, ocrChars: Int, axTokens: Int, hitTokens: Int, coverage: Double) {
            self.axChars = axChars
            self.ocrChars = ocrChars
            self.axTokens = axTokens
            self.hitTokens = hitTokens
            self.coverage = coverage
        }
    }

    /// NFKC 折叠 + 去掉全部空白 / 标点 / 符号，只留下"字与词"。
    ///
    /// 保留的类别：字母、数字、汉字与其它文字。丢弃的类别：空白、标点、符号、控制符。
    /// 丢弃的地方补一个 `\u{1}` 分隔符，好让 token 切分知道"这里断开了"，
    /// 同时保证 `contains` 判定不会把两个相邻词粘成一个假命中。
    public static func normalize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var lastWasSeparator = true
        for scalar in TextPipeline.foldForIndex(text).unicodeScalars {
            if isContentScalar(scalar) {
                out.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                out.append(Unicode.Scalar(1)!)
                lastWasSeparator = true
            }
        }
        return String(out)
    }

    static func isContentScalar(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        if properties.isWhitespace { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .nonspacingMark, .spacingMark:
            return true
        default:
            return false
        }
    }

    /// 规范化后的文本切成 token：汉字连续段按 bigram（单字段保留单字），其余段整段成词。
    public static func tokens(_ normalized: String) -> [String] {
        var out: [String] = []
        for piece in normalized.split(separator: Character(Unicode.Scalar(1)!)) {
            var cjkRun: [Unicode.Scalar] = []
            var other: [Unicode.Scalar] = []
            func flushCJK() {
                guard !cjkRun.isEmpty else { return }
                if cjkRun.count == 1 {
                    out.append(String(String.UnicodeScalarView(cjkRun)))
                } else {
                    for i in 0..<(cjkRun.count - 1) {
                        out.append(String(String.UnicodeScalarView(cjkRun[i...(i + 1)])))
                    }
                }
                cjkRun.removeAll(keepingCapacity: true)
            }
            func flushOther() {
                guard !other.isEmpty else { return }
                out.append(String(String.UnicodeScalarView(other)))
                other.removeAll(keepingCapacity: true)
            }
            for scalar in piece.unicodeScalars {
                if TextPipeline.isCJK(scalar) {
                    flushOther()
                    cjkRun.append(scalar)
                } else {
                    flushCJK()
                    other.append(scalar)
                }
            }
            flushCJK()
            flushOther()
        }
        return out
    }

    /// 一次对照。`axText` 是被审计的那条观察入库的正文（按 ord 拼起来），
    /// `ocrText` 是同一时刻全窗口 OCR 的文本。
    public static func coverage(axText: String, ocrText: String) -> Result {
        let axNormalized = normalize(axText)
        let ocrNormalized = normalize(ocrText)
        // 去重后再算：同一个 token 在 AX 侧出现十次不该让它在覆盖率里占十票。
        var seen = Set<String>()
        var unique: [String] = []
        for token in tokens(axNormalized) where seen.insert(token).inserted { unique.append(token) }
        let hits = unique.reduce(into: 0) { total, token in
            if ocrNormalized.contains(token) { total += 1 }
        }
        return Result(axChars: axText.count,
                      ocrChars: ocrText.count,
                      axTokens: unique.count,
                      hitTokens: hits,
                      coverage: unique.isEmpty ? 0 : Double(hits) / Double(unique.count))
    }
}

/// 一条采样审计行（`capture_audit`）。**不含正文**。
public struct CaptureAuditRow: Sendable, Codable {
    public var id: Int64 = 0
    public var ts: Int64
    /// 弱引用 `observations.id`（同 device）；观察被删掉后这条度量仍然留着。
    public var observationID: Int64?
    public var app: String
    public var axChars: Int
    public var ocrChars: Int
    public var axTokens: Int
    public var hitTokens: Int
    public var coverage: Double
    /// 被对照的那条观察的 `capture_method`。
    public var method: CaptureMethod
    /// 被 OCR 的区域名（适配规则里的 region 名）；全窗口时写 `window`。
    public var region: String?
    public var elapsedMS: Double

    public init(ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                observationID: Int64? = nil,
                app: String,
                coverage result: CaptureCoverage.Result,
                method: CaptureMethod,
                region: String? = nil,
                elapsedMS: Double = 0) {
        self.ts = ts
        self.observationID = observationID
        self.app = app
        self.axChars = result.axChars
        self.ocrChars = result.ocrChars
        self.axTokens = result.axTokens
        self.hitTokens = result.hitTokens
        self.coverage = result.coverage
        self.method = method
        self.region = region
        self.elapsedMS = elapsedMS
    }
}

extension Store {

    /// 写一条采样审计行（3.3）。与 `appendMCPAudit` 同样的语义：
    /// 写失败**不能**把采集本身搞挂，返回值告诉调用方成不成。
    @discardableResult
    public func appendCaptureAudit(_ row: CaptureAuditRow) -> Bool {
        do {
            _ = try withLock { conn in
                try conn.run("""
                    INSERT INTO capture_audit(ts, observation_id, app, ax_chars, ocr_chars,
                                              ax_tokens, hit_tokens, coverage, method, region,
                                              elapsed_ms)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?);
                    """, [.int(row.ts), .optionalInt(row.observationID), .text(row.app),
                          .int(Int64(row.axChars)), .int(Int64(row.ocrChars)),
                          .int(Int64(row.axTokens)), .int(Int64(row.hitTokens)),
                          .double(row.coverage), .text(row.method.rawValue),
                          .optionalText(row.region), .double(row.elapsedMS)])
            }
            return true
        } catch {
            return false
        }
    }

    /// 最近 N 条采样审计（倒序）。菜单、自检与结果文件用。
    public func captureAuditTail(limit: Int = 20, app: String? = nil) throws -> [CaptureAuditRow] {
        try withLock { conn in
            let sql = app == nil
                ? """
                  SELECT id, ts, observation_id, app, ax_chars, ocr_chars, ax_tokens, hit_tokens,
                         coverage, method, region, elapsed_ms
                    FROM capture_audit ORDER BY id DESC LIMIT ?;
                  """
                : """
                  SELECT id, ts, observation_id, app, ax_chars, ocr_chars, ax_tokens, hit_tokens,
                         coverage, method, region, elapsed_ms
                    FROM capture_audit WHERE app = ? ORDER BY id DESC LIMIT ?;
                  """
            let binds: [SQLValue] = app.map { [.text($0), .int(Int64(max(1, limit)))] }
                ?? [.int(Int64(max(1, limit)))]
            let st = try conn.prepare(sql)
            defer { st.finalize() }
            try st.bind(binds)
            var out: [CaptureAuditRow] = []
            while try st.step() {
                let result = CaptureCoverage.Result(axChars: Int(st.int(4) ?? 0),
                                                    ocrChars: Int(st.int(5) ?? 0),
                                                    axTokens: Int(st.int(6) ?? 0),
                                                    hitTokens: Int(st.int(7) ?? 0),
                                                    coverage: st.double(8) ?? 0)
                var row = CaptureAuditRow(
                    ts: st.int(1) ?? 0,
                    observationID: st.int(2),
                    app: st.text(3) ?? "",
                    coverage: result,
                    method: st.text(9).flatMap(CaptureMethod.init(rawValue:)) ?? .ax,
                    region: st.text(10),
                    elapsedMS: st.double(11) ?? 0)
                row.id = st.int(0) ?? 0
                out.append(row)
            }
            return out
        }
    }

    public func captureAuditCount() throws -> Int {
        try withLock { conn in Int(try conn.scalarInt("SELECT COUNT(*) FROM capture_audit;") ?? 0) }
    }

    /// 按应用汇总的平均覆盖率（结果文件与月报用）。`since` 是 Unix 毫秒下界。
    public func captureCoverageByApp(since: Int64 = 0)
        -> [(app: String, samples: Int, coverage: Double)] {
        (try? withLock { conn -> [(String, Int, Double)] in
            let st = try conn.prepare("""
                SELECT app, COUNT(*), AVG(coverage) FROM capture_audit
                 WHERE ts >= ? GROUP BY app ORDER BY COUNT(*) DESC;
                """)
            defer { st.finalize() }
            try st.bind([.int(since)])
            var out: [(String, Int, Double)] = []
            while try st.step() {
                out.append((st.text(0) ?? "", Int(st.int(1) ?? 0), st.double(2) ?? 0))
            }
            return out
        }) ?? []
    }
}
