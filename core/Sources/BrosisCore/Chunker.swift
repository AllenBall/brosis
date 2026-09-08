import Foundation

/// 分块参数（计划 4.3「嵌入任务」）。改任何一项都会让已嵌入的向量作废，
/// 所以它有一个指纹写进 `meta.embed_chunk_config`，开库时比对。
public struct ChunkConfig: Sendable, Codable, Equatable {
    /// 目标块长（字符数，按 `Character` 计）。攒到这个长度就收一块。
    ///
    /// 取 500 的理由：合成语料与真实屏幕正文一段大多 200–800 字符；
    /// Qwen3-Embedding 的输入上限按 E9 的用法取 1024 token，中英混排按
    /// `TokenBudget` 的口径（字符数 ÷ 2）折算约 250 token，离上限有很大余量，
    /// 不会因为截断丢掉块尾。
    public var targetCharacters: Int = 500
    /// 单块硬上限。段落本身超过它就按固定字符窗切开。
    public var maxCharacters: Int = 700
    /// 固定字符窗切开时相邻块的重叠字符数。只作用于「超长段落」这一条路径，
    /// 按段落收下来的块**没有重叠**（段落边界本身就是语义边界）。
    public var overlapCharacters: Int = 80
    /// 小于它的块直接丢掉（纯空白、单个标点之类，嵌入没有意义还占一条向量）。
    public var minCharacters: Int = 8
    /// 一个文本版本最多切多少块。挡住"一屏抓到十万字"这类异常，避免一条观察吃掉整批预算。
    public var maxChunksPerVersion: Int = 64

    public init() {}

    /// 参数指纹。写进 `meta`，与库里已有的不一致就说明分块口径变了。
    public var fingerprint: String {
        "t\(targetCharacters)-m\(maxCharacters)-o\(overlapCharacters)-n\(minCharacters)-c\(maxChunksPerVersion)"
    }
}

/// 一块：原文里的一段（**UTF-8 字节**偏移与长度，与 `text_versions.byte_len` 同口径）。
public struct TextChunk: Sendable, Equatable {
    public var ord: Int
    /// 原文 UTF-8 字节偏移。
    public var offset: Int
    /// 原文 UTF-8 字节长度。
    public var length: Int
    /// 字符数（`Character` 计）。
    public var characters: Int
    /// 这一段的正文。`Chunker.split` 直接给出来，写库时不存（存的是 offset / len）。
    public var text: String
}

/// **确定性**分块器：同一段输入永远切出逐字节相同的块（没有随机数、不依赖时间与本机状态）。
///
/// 策略（计划 4.3 要求"分块策略（按段落 / 固定字符窗，写明）"）：
///
/// 1. **先按段落切**。段落边界 = 换行符 `\n`（一次或多次连续换行都算一次边界）。
///    屏幕正文的自然单元就是行 / 段，AX 与 OCR 两条采集路径都按行给文本，
///    所以段落边界与语义边界重合得最好。
/// 2. **再按目标长度攒**。连续段落一直往当前块里塞，直到再塞一段就会超过
///    `targetCharacters`；此时收一块。段与段之间用 `\n` 连接，重建出来与原文一致。
/// 3. **超长段落走固定字符窗**。单个段落比 `maxCharacters` 还长（代码块、日志、
///    没有换行的长文），按 `maxCharacters` 切窗，窗与窗之间留 `overlapCharacters`
///    个字符重叠，免得答案正好被切在缝上。
/// 4. **丢掉太短的块**（`< minCharacters`）与纯空白块。
/// 5. **每个版本最多 `maxChunksPerVersion` 块**，超出直接截断（记在报告里）。
///
/// 偏移单位是 UTF-8 字节而不是字符：容量、`byte_len`、sha256 三处口径都按 UTF-8 字节，
/// 分块跟着同一套单位，验收时能直接拿 `offset + len ≤ byte_len` 对账。
/// 切点永远落在 `Character` 边界上（块是从 `Character` 序列拼出来的），所以按字节切回去安全。
public enum Chunker {

    /// 把一段原文切成块。返回的块按 `ord` 升序，`offset` 严格递增。
    public static func split(_ text: String, config: ChunkConfig = ChunkConfig()) -> [TextChunk] {
        guard !text.isEmpty else { return [] }
        let target = max(1, config.targetCharacters)
        let hardMax = max(target, config.maxCharacters)
        let overlap = max(0, min(config.overlapCharacters, hardMax - 1))

        // 段落：按 \n 切，保留每段在原文里的字节偏移。空段（连续换行）跳过但偏移照走。
        var paragraphs: [(offset: Int, characters: [Character])] = []
        var byteCursor = 0
        var current: [Character] = []
        var currentOffset = 0
        for ch in text {
            if ch == "\n" {
                if !current.isEmpty { paragraphs.append((currentOffset, current)) }
                current.removeAll(keepingCapacity: true)
                byteCursor += String(ch).utf8.count
                currentOffset = byteCursor
                continue
            }
            if current.isEmpty { currentOffset = byteCursor }
            current.append(ch)
            byteCursor += String(ch).utf8.count
        }
        if !current.isEmpty { paragraphs.append((currentOffset, current)) }

        var out: [TextChunk] = []
        var pendingOffset: Int? = nil
        var pending: [Character] = []
        var pendingBytes = 0

        func flushPending() {
            defer {
                pending.removeAll(keepingCapacity: true)
                pendingOffset = nil
                pendingBytes = 0
            }
            guard let offset = pendingOffset, !pending.isEmpty else { return }
            append(String(pending), offset: offset, bytes: pendingBytes, into: &out, config: config)
        }

        for (offset, chars) in paragraphs {
            // 3) 超长段落：固定字符窗 + 重叠
            if chars.count > hardMax {
                flushPending()
                // 前缀字节数一次算完（否则每个窗都重算一遍前缀，长段落上是 O(n²)）。
                var cumulative = [Int](repeating: 0, count: chars.count + 1)
                for (i, ch) in chars.enumerated() {
                    cumulative[i + 1] = cumulative[i] + String(ch).utf8.count
                }
                var start = 0
                while start < chars.count {
                    let end = min(start + hardMax, chars.count)
                    let sliceString = String(chars[start..<end])
                    append(sliceString, offset: offset + cumulative[start],
                           bytes: cumulative[end] - cumulative[start], into: &out, config: config)
                    if end == chars.count { break }
                    start = max(start + 1, end - overlap)
                }
                continue
            }
            // 2) 攒到目标长度
            let paragraphBytes = String(chars).utf8.count
            if !pending.isEmpty, pending.count + 1 + chars.count > target {
                flushPending()
            }
            if pending.isEmpty {
                pendingOffset = offset
                pending = chars
                pendingBytes = paragraphBytes
            } else {
                // 段与段之间补回那个被吃掉的 "\n"，重建出来与原文的这一段逐字节相同。
                pending.append("\n")
                pending.append(contentsOf: chars)
                pendingBytes += 1 + paragraphBytes
            }
        }
        flushPending()

        // 5) 每个版本的块数上限
        if out.count > config.maxChunksPerVersion {
            out = Array(out.prefix(config.maxChunksPerVersion))
        }
        for i in out.indices { out[i].ord = i }
        return out
    }

    private static func append(_ body: String, offset: Int, bytes: Int,
                               into out: inout [TextChunk], config: ChunkConfig) {
        // 4) 太短 / 纯空白的块不要
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, body.count >= max(1, config.minCharacters) else { return }
        out.append(TextChunk(ord: out.count, offset: offset, length: bytes,
                             characters: body.count, text: body))
    }

    /// 按 `offset` / `len`（UTF-8 字节）从原文取回一块。越界返回 nil。
    ///
    /// 与 `split` 是一对：`split` 给出的每一块，用它取回来都与 `TextChunk.text` 逐字节相同
    /// （`ChunkerTests.testSliceRoundTrip` 钉住这条）。
    public static func slice(_ text: String, offset: Int, length: Int) -> String? {
        guard offset >= 0, length >= 0 else { return nil }
        let utf8 = text.utf8
        guard let start = utf8.index(utf8.startIndex, offsetBy: offset, limitedBy: utf8.endIndex),
              let end = utf8.index(start, offsetBy: length, limitedBy: utf8.endIndex) else { return nil }
        // 按字节切片再解码，而不是 `text[start..<end]`：后者要求下标落在 Character 边界上，
        // 越界或落在多字节序列中间的行为不友好。`split` 给出的偏移一定是边界，
        // 但这个函数也会被"库里读出来的 offset / len"调用，必须对坏输入也安全。
        return String(decoding: utf8[start..<end], as: UTF8.self)
    }
}
