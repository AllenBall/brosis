import Foundation
import CryptoKit

/// 入库前的文本处理：SHA-256（**按原文**） + 索引侧的 NFKC 折叠 → bigram 预处理。
///
/// 对应计划 3.3、3.4 / D22（中文按字符 bigram 预处理写入 unicode61 FTS）、
/// D23（sha256 存 32 字节 BLOB）。
///
/// **口径（M1 R1 之后定案）：NFKC 折叠只用于索引，不改原文。**
/// `text_versions.text` 存进去什么就是什么，`sha256` / `byte_len` 都按原文的 UTF-8 字节算；
/// 折叠只发生在两个地方——写 `text_fts` 的 bigram 预处理列、以及查询串。
/// 换来的是「证据必须原样」：`get_evidence` 展开出来的正文与屏幕上看到的逐字节相同。
/// 代价是去重变严——同一段内容的全角写法与半角写法是**两个**文本版本（这是有意的）。
public enum TextPipeline {

    // MARK: - NFKC（索引侧）

    /// **索引侧** NFKC 折叠。全角 / 半角、兼容字形、组合字都收敛到同一形式，
    /// 让「同一段屏幕文本从 AX 读到半角、从 OCR 读到全角」这两种写法在 FTS 里对得上
    /// （`tools/bench/ocr_report_conclusions.md` §2 实测：accurate 模型把代码里的
    /// `(` `)` `:` `,` 全转成全角）。
    ///
    /// **它不参与入库**：正文、sha256、byte_len 一律按原文。
    public static func foldForIndex(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    // MARK: - SHA-256

    /// **原文** UTF-8 字节的 SHA-256，32 字节 BLOB（D23）。
    /// 去重语义因此是「逐字节相同才复用版本」。
    public static func sha256(_ text: String) -> Data {
        Data(SHA256.hash(data: Data(text.utf8)))
    }

    /// 容量口径统一按**原文** UTF-8 字节（2.4 存储行）。
    public static func byteLength(_ text: String) -> Int {
        text.utf8.count
    }

    // MARK: - bigram（D22）

    // 与 tools/bench/fts_compare.py 的 CJK_RANGES 逐字对应。
    private static let cjkRanges: [(UInt32, UInt32)] = [
        (0x3400, 0x4DBF),   // 扩展 A
        (0x4E00, 0x9FFF),   // 基本区
        (0xF900, 0xFAFF),   // 兼容区
    ]

    @inlinable
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    /// 把汉字连续段切成重叠 bigram，其余片段原样保留，统一用空格分隔。
    ///
    /// `"知识图谱 research"` → `"知识 识图 图谱  research"`
    ///
    /// 长度为 1 的汉字连续段保留该字本身——单字查询在 bigram 索引里命中不了，
    /// 计划 3.4 规定这类查询走"限定时间 / 应用范围的 LIKE 扫描"，由 T3 的检索层负责。
    ///
    /// 这是 `tools/bench/fts_compare.py` 里 `bigram_join()` 的 Swift 重写：
    /// 按 Unicode 标量逐个判定（与 Python 的按码点迭代等价），保证两边产出逐字节相同。
    public static func bigram(_ text: String) -> String {
        var parts: [String] = []
        var run: [Unicode.Scalar] = []
        var other: [Unicode.Scalar] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count == 1 {
                parts.append(String(String.UnicodeScalarView(run)))
            } else {
                for i in 0..<(run.count - 1) {
                    parts.append(String(String.UnicodeScalarView(run[i...(i + 1)])))
                }
            }
            run.removeAll(keepingCapacity: true)
        }
        func flushOther() {
            guard !other.isEmpty else { return }
            parts.append(String(String.UnicodeScalarView(other)))
            other.removeAll(keepingCapacity: true)
        }

        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                flushOther()
                run.append(scalar)
            } else {
                flushRun()
                other.append(scalar)
            }
        }
        flushRun()
        flushOther()
        return parts.joined(separator: " ")
    }

    /// **写 `text_fts` 用的唯一入口**：先折叠再切 bigram，顺便告诉调用方折叠有没有改动原文。
    ///
    /// 原文一律不折叠，所以「折叠」这一步只能出现在这里和查询侧（`ftsPhrase`）。
    /// 写入（`Store.upsertTextVersion`）与夜间对账（`Store.maintenance`）都必须走它，
    /// 否则补写出来的 FTS 行与写入时的对不上。
    ///
    /// `foldedDiffers` 是给 `Store.hasCompatibilityText` 用的：库里到底有没有
    /// 「折叠会变样」的正文，决定扫描通道要不要展开查询串（展开是按条数线性变慢的）。
    /// 折叠本来就要算一次，顺手回报，不额外多跑一遍 NFKC。
    public static func indexBody(_ rawText: String) -> (body: String, foldedDiffers: Bool) {
        let folded = foldForIndex(rawText)
        return (bigram(folded), folded != rawText)
    }

    /// `indexBody(_:).body` 的简写。
    public static func bigramForIndex(_ rawText: String) -> String {
        indexBody(rawText).body
    }

    /// 查询侧：把用户输入折叠 + bigram 化后包成 FTS5 phrase。
    /// 与写入侧用同一个 `foldForIndex` + `bigram`，这是 D22 方案能对上的前提。
    public static func ftsPhrase(_ query: String) -> String {
        let processed = bigram(foldForIndex(query))
        return "\"" + processed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 纯汉字且长度为 1 的查询在 bigram 索引里永远不命中（D22 的已知限制）。
    /// 检索层（T3）用它决定是否改走扫描通道。
    public static func requiresScanFallback(_ query: String) -> Bool {
        let scalars = Array(foldForIndex(query).unicodeScalars)
        return scalars.count == 1 && isCJK(scalars[0])
    }

    // MARK: - 子串复核（FTS 通道）

    /// FTS 候选的子串复核，**按索引口径**：先按原文比一次，不中再把候选正文**现折叠**一遍重比。
    ///
    /// 为什么必须有第二遍：正文现在存原文，索引存折叠后的形式。
    /// 一段全角正文（`"ＳＱＬ 100"`）在 FTS 里以半角形式建了索引，半角查询 `SQL` 能 MATCH 到它，
    /// 复核如果只在原文上做子串就会把它误杀。折叠只在**候选**上做（默认 ≤ 200 条、
    /// 带过滤时 ≤ 2000 条），不落存储、不改正文。
    ///
    /// `foldedTerm` 必须已经是 `foldForIndex` 之后的查询串。大小写不敏感。
    public static func indexContains(_ text: String, foldedTerm: String) -> Bool {
        guard !foldedTerm.isEmpty else { return true }
        if text.range(of: foldedTerm, options: [.caseInsensitive]) != nil { return true }
        return foldForIndex(text).range(of: foldedTerm, options: [.caseInsensitive]) != nil
    }

    // MARK: - 扫描通道的查询串展开

    /// SQL 的 `LIKE` 只对 **ASCII** 大小写不敏感，对全角字母是敏感的：`LIKE '%ＳＱ%'`
    /// 命中不了 `ｓｑ`。所以前像表按「折叠后再小写」归并，查 `SQ` 时两种全角大小写都会被展开进来。
    /// （实测过：不归并时同一批语料改成全角后，`SQ` 从 5 条掉到 3 条。）
    private static func caseKey(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        let lower = String(scalar).lowercased().unicodeScalars
        return lower.count == 1 ? lower.first! : scalar
    }

    /// NFKC 兼容折叠的**单标量前像**表，键是「折叠后再小写」的那个标量：
    /// `s` → `Ｓ` / `ｓ`、` ` → `　`、`:` → `：` / `﹕` / `︓`，
    /// 汉字则是兼容区（U+F900–FAFF / U+2F800–2FA1F）与康熙部首折到统一汉字的那些。
    ///
    /// 只覆盖下面这几段兼容区——它们正是本项目里真实会出现的差异来源
    /// （OCR 把半角标点识别成全角、AX 读到半角）；不是完整的 NFKC 逆映射。
    /// 多标量前像（`ﬁ` → `fi`、`㍿` → `株式会社`）不在表里，见 `scanVariants` 的说明。
    /// 单键最大扇出是 6（`_`），字母是 2，标点是 3。
    static let compatibilityPreimages: [Unicode.Scalar: [Unicode.Scalar]] = {
        let ranges: [(UInt32, UInt32)] = [
            (0x2F00, 0x2FDF),      // 康熙部首
            (0x3000, 0x3000),      // 表意空格
            (0xF900, 0xFAFF),      // CJK 兼容汉字
            (0xFB00, 0xFB4F),      // 字母表现形式（单标量的那几个）
            (0xFE10, 0xFE6F),      // 竖排 / 小写形式
            (0xFF00, 0xFFEF),      // 半角与全角形式
            (0x2F800, 0x2FA1F),    // CJK 兼容汉字增补
        ]
        var map: [Unicode.Scalar: [Unicode.Scalar]] = [:]
        for (lo, hi) in ranges {
            for v in lo...hi {
                guard let scalar = Unicode.Scalar(v) else { continue }
                let folded = String(scalar).precomposedStringWithCompatibilityMapping
                let out = Array(folded.unicodeScalars)
                guard out.count == 1, out[0] != scalar else { continue }
                map[caseKey(out[0]), default: []].append(scalar)
            }
        }
        return map
    }()

    /// 1–2 字扫描通道用：把已折叠的查询串展开成「原文里可能长什么样」的若干个写法（含它自己）。
    ///
    /// 扫描通道要在**原文**上做 `LIKE`，而原文不再折叠，于是有两个方向要顾：
    /// 全角查询 → 半角原文（折叠查询串就够），半角查询 → 全角原文（折叠查询串**没用**，
    /// 得反过来把查询串展开成全角写法）。把整个时间窗的正文现折叠再比也能做到，
    /// 但那是 7 天窗口里三十多 MiB 正文的逐条 NFKC，扫描档 150 ms 的目标兜不住
    /// （见 `Store.scanChannel` 的注释）。
    ///
    /// **展开不是免费的**：这条通道按定义要扫完整个时间窗，代价与模式条数近似成正比。
    /// 1 个月合成库上实测同一条 ASCII 两字查询（`--short-queries SQ`，命中 10 条、不触发
    /// `LIMIT` 短路）：1 个 `LIKE` 热 p95 **117.4 ms**，展开成 9 个 `LIKE` **721.0 ms**。
    /// 试过把 9 种写法压成**一个 GLOB 字符类**（`*[SsＳｓ][QqＱｑ]*`）一遍扫完，
    /// 反而更慢——SQLite 的 GLOB 走的是带 UTF-8 逐字符解码的通用匹配器：同一条查询 **605.1 ms**，
    /// 连纯汉字单字 `熵` 都从 122.3 ms 掉到 **398.5 ms**。已退回 `LIKE`。
    /// 所以真正的省法是**只在需要时展开**：`Store.hasCompatibilityText` 记录库里到底有没有
    /// 「折叠会变样」的正文，没有就只发一个 `LIKE`（这也是 1 个月合成库的情形，零回归）。
    ///
    /// 代价（明写）：只覆盖 `compatibilityPreimages` 那几段兼容区的**单标量**前像。
    /// 连字（`ﬁ`）这类一个字符折成多个字符的写法、以及兼容区之外的折叠，扫描通道仍然会漏；
    /// 这类正文由 FTS 通道兜底（那条通道对候选做的是真折叠，没有这个限制）。
    /// 组合数超过 `limit`（默认 16）时退回只用折叠后的查询串本身——
    /// 纯汉字查询 1 个、ASCII 两字 9 个（每个字母 3 种写法）、两个标点 16 个都在界内。
    public static func scanVariants(_ foldedTerm: String, limit: Int = 16) -> [String] {
        let scalars = Array(foldedTerm.unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        var choices: [[Unicode.Scalar]] = []
        choices.reserveCapacity(scalars.count)
        var total = 1
        for scalar in scalars {
            var options = [scalar]
            if let pre = compatibilityPreimages[caseKey(scalar)] { options += pre }
            total *= options.count
            if total > limit { return [foldedTerm] }
            choices.append(options)
        }
        var out: [String] = [""]
        for options in choices {
            var next: [String] = []
            next.reserveCapacity(out.count * options.count)
            for prefix in out {
                for option in options { next.append(prefix + String(Character(option))) }
            }
            out = next
        }
        return out
    }
}
