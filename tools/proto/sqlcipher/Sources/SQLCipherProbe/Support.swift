// brosis M0 / T8（E6）：小工具——计时、百分位、确定性随机数、JSON 输出。
import Foundation

@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

@inline(__always) func msSince(_ t0: UInt64) -> Double { Double(nowNs() - t0) / 1_000_000.0 }

/// 计时一段代码，返回毫秒。
@discardableResult
func timedMs<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let t0 = nowNs()
    let v = try body()
    return (v, msSince(t0))
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    if sorted.isEmpty { return .nan }
    if sorted.count == 1 { return sorted[0] }
    let idx = p * Double(sorted.count - 1)
    let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
    if lo == hi { return sorted[lo] }
    let f = idx - Double(lo)
    return sorted[lo] * (1 - f) + sorted[hi] * f
}

struct LatencyStats {
    let n: Int, p50: Double, p95: Double, min: Double, max: Double, mean: Double
    init(_ samples: [Double]) {
        let s = samples.sorted()
        n = s.count
        p50 = percentile(s, 0.50)
        p95 = percentile(s, 0.95)
        min = s.first ?? .nan
        max = s.last ?? .nan
        mean = s.isEmpty ? .nan : s.reduce(0, +) / Double(s.count)
    }
    var json: [String: Any] {
        ["n": n, "p50_ms": r(p50), "p95_ms": r(p95), "min_ms": r(min), "max_ms": r(max), "mean_ms": r(mean)]
    }
}

/// 保留 3 位小数，避免 JSON 里出现一长串浮点噪声。
func r(_ v: Double, _ digits: Int = 3) -> Double {
    if v.isNaN || v.isInfinite { return -1 }
    let m = pow(10.0, Double(digits))
    return (v * m).rounded() / m
}

/// SplitMix64：确定性、无依赖，保证同一 seed 每次生成同样的语料。
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
    mutating func range(_ lo: Int, _ hi: Int) -> Int { lo + int(hi - lo + 1) }
    mutating func byte() -> Int8 { Int8(truncatingIfNeeded: Int(next() & 0xFF) - 128) }
}

/// 在一段字节里数某个字节串出现了多少次（朴素搜索，语料小，够用）。
func countOccurrences(of needle: [UInt8], in haystack: UnsafeRawBufferPointer) -> Int {
    guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
    var hits = 0
    let n = needle.count
    let limit = haystack.count - n
    var i = 0
    while i <= limit {
        if haystack[i] == needle[0] {
            var j = 1
            while j < n && haystack[i + j] == needle[j] { j += 1 }
            if j == n { hits += 1 }
        }
        i += 1
    }
    return hits
}

func scanFile(_ path: String, needles: [(String, [UInt8])]) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path) else {
        return ["exists": false]
    }
    var hits: [String: Int] = [:]
    data.withUnsafeBytes { raw in
        for (name, bytes) in needles { hits[name] = countOccurrences(of: bytes, in: raw) }
    }
    return ["exists": true, "bytes": data.count, "hits": hits, "total_hits": hits.values.reduce(0, +)]
}

func jsonString(_ obj: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: obj,
                                           options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return String(data: data, encoding: .utf8)!
}
