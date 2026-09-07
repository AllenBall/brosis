// brosis M0 / T8（E6）：确定性中英混排语料 + bigram 预处理（对齐 D22 / tools/bench/fts_compare.py）。
import Foundation

enum Corpus {
    /// 明文金丝雀：每一条正文里都埋这两串。任何一处明文泄漏都会被 §「无明文泄漏」检查抓到。
    static let canaryEN = "BROSISLEAKCANARY7F3A2D"
    static let canaryZH = "饕餮鑫垚焱淼"
    /// 额外的探针：一个高频普通词，用来验证不是只挡住了生僻字。
    static let commonZH = "会议纪要"

    static var needles: [(String, [UInt8])] {
        [("canary_en", Array(canaryEN.utf8)),
         ("canary_zh", Array(canaryZH.utf8)),
         ("canary_zh_short", Array("饕餮".utf8)),
         ("common_zh", Array(commonZH.utf8))]
    }

    static let zhWords = [
        "会议纪要", "项目进度", "需求评审", "技术方案", "架构设计", "数据模型", "接口文档", "测试用例",
        "上线计划", "回归验证", "性能优化", "内存占用", "磁盘空间", "加密存储", "密钥管理", "权限申请",
        "隐私政策", "合规审查", "风险评估", "应急预案", "值班安排", "客户反馈", "产品定位", "竞品分析",
        "用户画像", "转化漏斗", "留存曲线", "增长实验", "预算拆分", "成本核算", "报销流程", "采购申请",
        "供应商", "合同条款", "结算周期", "发票抬头", "季度目标", "复盘总结", "行动项", "责任人",
        "截止日期", "优先级", "阻塞问题", "依赖关系", "灰度发布", "回滚方案", "监控告警", "日志检索",
        "全文检索", "向量检索", "语义相似", "召回率", "准确率", "分词方案", "索引重建", "查询延迟",
        "并发写入", "事务隔离", "崩溃恢复", "增量备份", "跨设备同步", "冲突合并", "墓碑记录", "配额过期",
        "屏幕录制", "辅助功能", "系统权限", "后台任务", "热状态", "电源管理", "睡眠唤醒", "锁屏解锁",
        "飞书群聊", "微信消息", "邮件往来", "日程冲突", "远程会议", "共享文档", "在线表格", "白板协作",
        "研发同学", "设计稿", "交互细节", "视觉走查", "埋点方案", "数据看板", "指标口径", "同比环比",
        "一线城市", "海外市场", "本地化", "多语言", "字符编码", "时区换算", "夏令时", "节假日",
        "股权激励", "绩效考核", "晋升答辩", "培训计划", "新人入职", "离职交接", "工位调整", "团建活动",
        "深圳分部", "北京总部", "上海办公室", "杭州团队", "成都基地", "武汉中心", "西安研发", "南京运营",
        "早班车", "加班餐", "健身房", "咖啡机", "打印机", "会议室", "工位号", "门禁卡"
    ]

    static let enWords = [
        "SQLite", "SQLCipher", "FTS5", "unicode61", "bigram", "tokenizer", "contentless", "dbstat",
        "sqlite-vec", "embedding", "cosine", "int8", "quantization", "recall", "precision", "latency",
        "throughput", "checkpoint", "WAL", "PRAGMA", "keychain", "PBKDF2", "HMAC", "AES-256-CBC",
        "CommonCrypto", "LibTomCrypt", "SwiftPM", "GRDB", "XPC", "entitlement", "sandbox", "notarize",
        "Developer-ID", "ScreenCaptureKit", "Accessibility", "NSWorkspace", "bundleIdentifier", "AXUIElement",
        "OCR", "Vision", "MLX", "Qwen3-Embedding", "Gemma", "inference", "quota", "tombstone",
        "idempotent", "manifest", "segment", "device_id", "observation", "occurrence", "text_version",
        "ledger", "session", "grant", "audit", "redaction", "canary", "vacuum", "secure_delete",
        "auto_vacuum", "page_size", "cache_size", "temp_store", "journal_mode", "foreign_keys",
        "roadmap", "backlog", "standup", "retro", "handoff", "postmortem", "runbook", "SLA",
        "p50", "p95", "MiB", "GiB", "nanoseconds", "monotonic", "uptime", "wallclock"
    ]

    static let appNames = ["com.apple.Safari", "com.google.Chrome", "com.electron.lark", "com.tencent.xinWeChat",
                           "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.apple.mail", "com.figma.Desktop"]

    /// 一条正文：中英混排，长度在 60–140 个 token 之间，中间随机位置插入两个金丝雀。
    static func document(index: Int, rng: inout SplitMix64) -> String {
        let n = rng.range(60, 140)
        var tokens: [String] = []
        tokens.reserveCapacity(n + 4)
        for _ in 0..<n {
            if rng.int(100) < 70 {
                tokens.append(zhWords[rng.int(zhWords.count)])
            } else {
                tokens.append(enWords[rng.int(enWords.count)])
            }
        }
        let at = rng.int(max(1, tokens.count - 2))
        tokens.insert(canaryZH, at: at)
        tokens.insert(canaryEN, at: min(at + 3, tokens.count))
        tokens.append("docid\(index)")   // 唯一 token，contentless_delete 验证要用
        // 中文之间不加空格（贴近真实正文），中英之间加一个空格。
        var out = ""
        var prevWasCJK = false
        for t in tokens {
            let isCJK = t.unicodeScalars.first.map { isCJKScalar($0) } ?? false
            if !out.isEmpty && !(isCJK && prevWasCJK) { out += " " }
            out += t
            prevWasCJK = isCJK
        }
        return out
    }

    static func isCJKScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    /// D22 的 bigram 预处理：汉字连续段切成重叠 bigram，其余片段原样保留，统一空格分隔。
    /// 与 tools/bench/fts_compare.py 的 bigram_join 行为一致（含长度为 1 的段保留原字）。
    static func bigramJoin(_ text: String) -> String {
        var parts: [String] = []
        var run: [Character] = []
        var other: [Character] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count == 1 {
                parts.append(String(run[0]))
            } else {
                for i in 0..<(run.count - 1) { parts.append(String(run[i...i+1])) }
            }
            run.removeAll(keepingCapacity: true)
        }
        func flushOther() {
            guard !other.isEmpty else { return }
            parts.append(String(other))
            other.removeAll(keepingCapacity: true)
        }
        for ch in text {
            if let s = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, isCJKScalar(s) {
                flushOther(); run.append(ch)
            } else {
                flushRun(); other.append(ch)
            }
        }
        flushRun(); flushOther()
        return parts.joined(separator: " ")
    }

    /// 512 维 int8 向量。确定性、有簇结构（同一 cluster 的向量互相接近），
    /// 这样 KNN 查询不是在随机噪声里找最近邻。
    static func vector(index: Int, dim: Int = 512) -> [Int8] {
        var centroid = SplitMix64(seed: UInt64(index % 64) &* 0x1234_5678 &+ 99)
        var jitter = SplitMix64(seed: UInt64(index) &* 0x9E37_79B9 &+ 7)
        var v = [Int8](repeating: 0, count: dim)
        for i in 0..<dim {
            let base = Int(centroid.byte())
            let noise = Int(jitter.byte()) / 8
            v[i] = Int8(clamping: base + noise)
        }
        return v
    }
}
