// brosis M0 · T3 附加实测：Swift 侧有没有和 jieba 同级的中文分词能力。
// 方案 D（jieba）是 Python 库，产品是 Swift app，用不了。这里探两个系统 API，
// 都不需要第三方依赖：NaturalLanguage 的 NLTokenizer 和 CoreFoundation 的 CFStringTokenizer。
//
// 编译运行（产物不要放进项目目录）：
//   mkdir -p ~/Library/Caches/brosis-build/t3-fts
//   swiftc -O tools/bench/nl_tokenize_probe.swift -o ~/Library/Caches/brosis-build/t3-fts/nl_probe
//   ~/Library/Caches/brosis-build/t3-fts/nl_probe

import Foundation
import NaturalLanguage

func nlWords(_ s: String, _ t: NLTokenizer) -> [String] {
    t.string = s
    var out: [String] = []
    t.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in
        let w = String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !w.isEmpty { out.append(w) }
        return true
    }
    return out
}

func cfWords(_ s: String) -> [String] {
    let ns = s as NSString
    guard let tk = CFStringTokenizerCreate(nil, s as CFString,
            CFRangeMake(0, ns.length), kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "zh_CN") as CFLocale) as CFStringTokenizer? else { return [] }
    var out: [String] = []
    while CFStringTokenizerAdvanceToNextToken(tk) != [] {
        let r = CFStringTokenizerGetCurrentTokenRange(tk)
        let w = ns.substring(with: NSRange(location: r.location, length: r.length))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !w.isEmpty { out.append(w) }
    }
    return out
}

let tok = NLTokenizer(unit: .word)
tok.setLanguage(.simplifiedChinese)

print("== 切分结果对照（与 tools/bench/fts_compare.py 方案 D 的 jieba 输出对比）==")
let samples = [
    "知识图谱与实施计划的采集覆盖率",
    "SQLCipher 构建与 FTS5 分词对照",
    "数据保留策略需要再确认一遍",
    "双击标题栏可以最大化窗口",
    "无障碍权限没打开导致采集失败",
    "复核parseObservation的边界条件",
    "预算从 100 改成 200",
]
for s in samples {
    print("IN : \(s)")
    print("NL : \(nlWords(s, tok).joined(separator: "/"))")
    print("CF : \(cfWords(s).joined(separator: "/"))")
}

print("")
print("== 吞吐（复用同一个 NLTokenizer 实例）==")
let unit = "采集器的采集覆盖率需要再确认一遍。存储服务的删除级联已经按评审改掉了。"
    + "这一轮实测 3200 条观察，索引体积 42 MB，p95 延迟 12 ms。锁屏时库保持打开，接电时夜间任务照跑。"
    + "MCP 接口的证据展开留到 M2 再做。"
let docs = (0..<3200).map { unit + " #\($0)" }
let chars = docs.reduce(0) { $0 + $1.count }
var total = 0
var t0 = Date()
for d in docs { total += nlWords(d, tok).count }
var ms = Date().timeIntervalSince(t0) * 1000
print(String(format: "复用实例  : %d 条 / %d 字符 / %d token，%.0f ms → %.2f M 字符/秒",
             docs.count, chars, total, ms, Double(chars) / ms / 1000))

print("")
print("== 反例：每次新建实例 ==")
total = 0
t0 = Date()
for d in docs.prefix(400) {
    let t = NLTokenizer(unit: .word)
    t.setLanguage(.simplifiedChinese)
    total += nlWords(d, t).count
}
ms = Date().timeIntervalSince(t0) * 1000
let chars400 = docs.prefix(400).reduce(0) { $0 + $1.count }
print(String(format: "每次新建  : 400 条 / %d 字符，%.0f ms → %.2f M 字符/秒（慢一个量级，实例必须复用）",
             chars400, ms, Double(chars400) / ms / 1000))
