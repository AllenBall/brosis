import BrosisCore
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

// =============================================================================
// 本地生成提供方（计划 3.10「提供方抽象：本地实现走 mlx-swift」、4.3 可选叙述、D19、D27）
//
// 生成器本体搬自 `tools/e9/Sources/brosis-e9/main.swift` 的 `generate` 子命令
// （`LLMModelFactory.loadContainer` + `ChatSession.streamDetails`），改动只有：
//   1. 实现 `BrosisCore.GenerationProvider`（同步接口，桥到 mlx 的 async）；
//   2. 加载前按 D27 设 `MLX.Memory.cacheLimit = 256 MiB`，`unload()` 里 `clearCache()`；
//   3. 加了 **两道保险**（D19 的硬性结论）：
//      * `enable_thinking = false` **写死在这里**，不是可选项：
//        思考模式在 Air 上 4,000 token / 124 s 仍不收敛，一个答案都拿不到；
//      * 逐 token 检查——墙钟超时就中止；万一输出里真的出现了 `<think>`，
//        再过 `thinkingAbortTokens` 个 token 还没见到 `</think>` 就当场中止。
//
// **本地实现，不接线上**（本轮用户指示）：这里没有任何网络调用。
// =============================================================================

/// 本项目的生成模型（D19 已定并实测）。放在扩展里而不是改 `Catalog.swift`，
/// 是为了不动并行任务的文件。
public extension Catalog {
    /// 生成 / 抽取模型的固定 id（D19）。
    static var generationModelID: String { "Qwen3.5-4B-MLX-4bit" }
    var generationModel: CatalogModel? { models.first { $0.id == Catalog.generationModelID } }
}

/// mlx-swift-lm 的本地生成实现。**加载即占内存**（Air 实测峰值 footprint 3.42 GiB），
/// 用完请 `unload()`。
public final class MLXGenerationProvider: GenerationProvider, @unchecked Sendable {

    public let modelID: String
    public let modelDirectory: URL
    /// 加载耗时（`LLMModelFactory.loadContainer` 起止）。D19 热态实测 0.800 s。
    public let loadSeconds: Double

    private let container: ModelContainer

    private init(container: ModelContainer, modelID: String, modelDirectory: URL,
                 loadSeconds: Double) {
        self.container = container
        self.modelID = modelID
        self.modelDirectory = modelDirectory
        self.loadSeconds = loadSeconds
    }

    /// 从已装好的模型目录加载。
    ///
    /// - Parameter cacheLimitMiB: **加载之前**设的 MLX 缓冲池上限（D27，默认 256 MiB）。
    ///   Air 实测：限 256 MiB 时叙述峰值 footprint 3,500.0 MiB，不限时 4,137.5 MiB，
    ///   而预填与生成速率差都在 0.2% 以内、输出逐字相同——限缓存是免费的。
    public static func load(directory: URL,
                            modelID: String = Catalog.generationModelID,
                            cacheLimitMiB: Int = MLXMemoryPolicy.defaultCacheLimitMiB)
        throws -> MLXGenerationProvider {
        guard FileManager.default.fileExists(
            atPath: directory.appending(path: "config.json").path) else {
            throw ModelsError("模型目录里没有 config.json：\(directory.lastPathComponent)")
        }
        MLXMemoryPolicy.applyCacheLimit(mib: cacheLimitMiB)
        let t0 = Date()
        let container = try runBlocking { () async throws -> ModelContainer in
            try await LLMModelFactory.shared.loadContainer(
                from: directory, using: TransformersTokenizerLoader())
        }
        return MLXGenerationProvider(container: container, modelID: modelID,
                                     modelDirectory: directory,
                                     loadSeconds: Date().timeIntervalSince(t0))
    }

    /// 真实分词器给的 token 数。叙述的 8,000 闸门优先按它判，估算器只是退路。
    public func tokenCount(_ text: String) -> Int? {
        try? runBlocking { () async -> Int in
            await self.container.perform { ctx in
                ctx.tokenizer.encode(text: text, addSpecialTokens: true).count
            }
        }
    }

    public func generate(system: String?, prompt: String,
                         options: GenerationOptions) throws -> GenerationResult {
        // 3.10：温度 0；D19：一律关思考。两条都不看调用方给什么——
        // 传进来的 `options` 只用来取上限与超时，语义部分在这里钉死。
        // `let` 而不是 `var`：下面那个 `@Sendable` 闭包捕获它，Swift 6 不允许捕获可变量。
        let params: GenerateParameters = {
            var p = GenerateParameters()
            p.maxTokens = options.maxTokens
            p.temperature = 0
            p.topP = 1
            return p
        }()

        let deadline = Date().addingTimeInterval(max(1, options.timeoutSeconds))
        let abortAfter = max(1, options.thinkingAbortTokens)

        return try runBlocking { () async throws -> GenerationResult in
            // 每次新建 ChatSession：它会保留 KV cache 与历史，复用会让第二次看见第一次的输出。
            let session = ChatSession(
                self.container, instructions: system, generateParameters: params,
                // Qwen3.5 的 chat_template.jinja：`enable_thinking` 已定义且为 false 时
                // 直接吐出 "<think>\n\n</think>\n\n" 前缀（= 非思考模式）。
                additionalContext: ["enable_thinking": false])
            let t0 = Date()
            var firstTokenAt: Double?
            var text = ""
            var info: GenerateCompletionInfo?
            var tokensSinceThinkOpen: Int?
            var stopReason = "stop"

            for try await chunk in session.streamDetails(to: prompt) {
                if let piece = chunk.chunk {
                    if firstTokenAt == nil { firstTokenAt = Date().timeIntervalSince(t0) }
                    text += piece
                    // 保险 1：真的进了思考段就限时中止（D19：Air 上它不收敛）。
                    if tokensSinceThinkOpen == nil, text.contains("<think>") {
                        tokensSinceThinkOpen = 0
                    } else if var seen = tokensSinceThinkOpen {
                        seen += 1
                        tokensSinceThinkOpen = seen
                        if text.contains("</think>") {
                            tokensSinceThinkOpen = nil
                        } else if seen >= abortAfter {
                            stopReason = "thinking_not_closed"
                            break
                        }
                    }
                    // 保险 2：墙钟超时。
                    if Date() > deadline { stopReason = "timeout"; break }
                }
                if let i = chunk.info { info = i }
            }
            let elapsed = Date().timeIntervalSince(t0)
            if stopReason == "stop", let i = info { stopReason = "\(i.stopReason)" }

            // 按 </think> 把输出切成思考段与答案段。非思考模式下模板已经在**提示**里
            // 吐过 "<think>\n\n</think>"，那部分不在输出里，所以正常切不出思考段。
            var thinkingDetected = false
            var answer = text
            if let range = text.range(of: "</think>") {
                thinkingDetected = true
                answer = String(text[range.upperBound...])
            } else if text.contains("<think>") {
                thinkingDetected = true
                answer = ""
            }
            return GenerationResult(
                text: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                promptTokens: info?.promptTokenCount ?? 0,
                generationTokens: info?.generationTokenCount ?? 0,
                promptTokensPerSecond: info?.promptTokensPerSecond ?? 0,
                tokensPerSecond: info?.tokensPerSecond ?? 0,
                timeToFirstTokenSeconds: firstTokenAt ?? 0,
                elapsedSeconds: elapsed,
                stopReason: stopReason,
                thinkingDetected: thinkingDetected)
        }
    }

    /// 任务结束：把缓冲池还给系统（3.11 / D27）。
    @discardableResult
    public func unload() -> MLXMemoryPolicy.Release { MLXMemoryPolicy.releaseCache() }
}
