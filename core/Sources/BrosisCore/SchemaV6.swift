import Foundation

// =============================================================================
// schema v6（M2 c / T12）：叙述元数据一列（计划 4.3「可选叙述」、3.7「输出与台账分开标注」）
//
// `ledgers` 从 v1 起就有 `narrative` 与 `model` 两列，但 4.3 还要求记住
// **生成时刻**、**输入 token 数**、**忠实度是否核对过**、以及这条叙述是**依据哪一版台账**写的。
// 塞进 `model` 那一列会把"模型 id"这个字段变成 JSON 大杂烩，所以 v6 单加一列：
//
//     ALTER TABLE ledgers ADD COLUMN narrative_meta TEXT;   -- JSON，可空
//
// 纯新增、可空列，老库 `ALTER` 就地迁移，不重写数据、不重建库。
// 这一列**不是证据**：它是模型产物的标注，随台账重算一并置回 NULL（见 `Store+Ledger` 的
// `upsertLedger` 与 `Store+Narrative` 的 `clearNarrative`）。
// =============================================================================

public enum SchemaV6 {

    /// v5 → v6 给 `ledgers` 补的列。新库的 `Schema.createTables` 里已经带上。
    static let alterLedgersV6: [(column: String, sql: String)] = [
        ("narrative_meta", "ALTER TABLE ledgers ADD COLUMN narrative_meta TEXT;"),
    ]

    static let note = "v6：ledgers.narrative_meta（4.3 可选叙述的模型 / 生成时刻 / 输入 token / "
                    + "忠实度核对标注，3.7「输出与台账分开标注」）"
}

/// `ledgers.narrative_meta` 里那份 JSON。**与台账 JSON 完全分开**（3.7）。
public struct NarrativeMeta: Sendable, Codable, Equatable {
    /// 恒为 `"model"`：这一段是模型写的，不是台账算的。MCP 层原样透传成 `generatedBy`。
    public var generatedBy: String
    /// 模型标识（与 `ledgers.model` 同值，冗余一份是为了这份 JSON 自解释）。
    public var model: String
    /// 生成时刻（Unix 毫秒）。
    public var generatedAt: Int64
    /// 喂给模型的输入 token 数。真实分词器给得出就是真值，否则是 `NarrativeTokens.estimate` 的估算。
    public var inputTokens: Int
    /// `tokenizer`（真实分词器）/ `estimate`（core 的字符类别估算器）。
    public var inputTokenSource: String
    /// 生成出来的 token 数。
    public var outputTokens: Int
    /// 提示的压缩等级（`full` / `trimmed` / `session_summary` / `app_summary` / `minimal`）。
    public var compression: String
    /// 忠实度核对跑过了没有。**入库的叙述这一项恒为 true**（没过的直接丢弃，不入库）。
    public var faithfulnessChecked: Bool
    /// 核对里比对过的数字个数 / 应用个数（报告用）。
    public var checkedNumbers: Int
    public var checkedApps: Int
    /// 因为超过汉字数上限被截断过。
    public var truncated: Bool
    /// 这条叙述是依据哪一版台账写的（= 写入时 `ledgers.computed_at`）。
    /// 台账重算之后这个数就对不上，叙述随即作废（`narrativeIsStale`）。
    public var ledgerComputedAt: Int64
    /// 生成耗时与吞吐（结果文件里要报）。
    public var timeToFirstTokenSeconds: Double
    public var tokensPerSecond: Double
    public var elapsedSeconds: Double
    /// 本机热状态与峰值内存（D27）。app 注入；core 的用例里是 nil。
    public var thermalState: String?
    public var peakFootprintMiB: Double?

    public init(generatedBy: String = "model", model: String, generatedAt: Int64,
                inputTokens: Int, inputTokenSource: String, outputTokens: Int,
                compression: String, faithfulnessChecked: Bool,
                checkedNumbers: Int, checkedApps: Int, truncated: Bool,
                ledgerComputedAt: Int64, timeToFirstTokenSeconds: Double = 0,
                tokensPerSecond: Double = 0, elapsedSeconds: Double = 0,
                thermalState: String? = nil, peakFootprintMiB: Double? = nil) {
        self.generatedBy = generatedBy
        self.model = model
        self.generatedAt = generatedAt
        self.inputTokens = inputTokens
        self.inputTokenSource = inputTokenSource
        self.outputTokens = outputTokens
        self.compression = compression
        self.faithfulnessChecked = faithfulnessChecked
        self.checkedNumbers = checkedNumbers
        self.checkedApps = checkedApps
        self.truncated = truncated
        self.ledgerComputedAt = ledgerComputedAt
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.tokensPerSecond = tokensPerSecond
        self.elapsedSeconds = elapsedSeconds
        self.thermalState = thermalState
        self.peakFootprintMiB = peakFootprintMiB
    }
}
