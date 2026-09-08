import Foundation
import XCTest
@testable import BrosisCore
import BrosisIPC

/// M2 d / T15：把向量通道接进 MCP 检索这一层。
///
/// 覆盖四件事：
///  1. **注入 nil 与注入伪嵌入器**下 `StoreMCPService.search` 的行为（前者必须与 c 批逐位相同）；
///  2. **零模型调用**：开关关、查询带字段前缀、库锁着这三种情况一次都不许调模型；
///  3. **不持库锁**：算查询向量的时候另一个线程能照常读库（持锁就会死锁 / 超时）；
///  4. **常驻 + 空闲卸载状态机**的五种事件（纯函数）。
///
/// **不需要任何模型**：伪嵌入用 `HashEmbeddingProvider`（确定性、无语义）。
/// 真实模型那一层在 `brosis-embed selftest`（app 包）与 `tools/eval/d8_mcp_compare.py` 里。
final class QueryEmbedderTests: XCTestCase {

    // MARK: - 夹具

    private var fixture: Fixture!
    private var store: Store { fixture.store }
    private var baseTS: Int64 = 0
    /// 运行时拼出来的稀有词：不让检索标记以字面量形式留在二进制里（硬约束 5）。
    private let marker = "向量接口标记" + ["K", "W", String(7_351)].joined()

    override func setUpWithError() throws {
        fixture = try Fixture("query-embedder")
        store.retrieval.timeZone = TimeZone(identifier: "UTC")!
        baseTS = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        var inputs: [ObservationInput] = []
        for i in 0..<8 {
            let body = i == 5
                ? "\(marker) 就写在这一段里，后面再补一点长度好切出一整块来。"
                : "干扰正文第 \(i) 段，长度也够切出一块，内容与目标完全无关，只是凑数。"
            inputs.append(Synth.observation(ts: baseTS + Int64(i) * 10_000,
                                            bundle: "com.brosis.test", appName: "brosis 测试",
                                            window: "窗口 \(i)", host: "docs.internal",
                                            texts: [body]))
        }
        try store.record(batch: inputs)
        try store.setGrant(Grant(clientID: "claude-code", mode: .strictLocal, apps: ["*"],
                                 timeWindowDays: 30, fields: .evidence))
    }

    override func tearDown() {
        fixture = nil
    }

    // MARK: - 工具

    private func service(_ embedder: QueryEmbedder? = nil) -> StoreMCPService {
        StoreMCPService(store: store, queryEmbedder: embedder)
    }

    private func search(_ service: StoreMCPService, _ q: String,
                        limit: Int = 10) throws -> [String: JSONValue] {
        let call = IPCCall(request: IPCRequest(client: "claude-code", op: .tool,
                                               name: MCPTool.search.rawValue,
                                               args: ["q": .string(q), "limit": .int(Int64(limit))]),
                           peer: PeerInfo(uid: getuid(), gid: getgid(), pid: getpid(),
                                          teamID: "TESTTEAM", signingID: "com.brosis.test",
                                          codeSigningVerified: true,
                                          codeSigningNote: "skipped(test_host)"),
                           refusal: nil, rateUsed: 1, rateLimit: 60)
        let response = service.handle(call)
        XCTAssertTrue(response.ok, response.error?.message ?? "")
        return try XCTUnwrap(response.result?.objectValue)
    }

    private func embedded(_ chunks: Int = 8) throws {
        let report = try store.runEmbeddingJob(provider: HashEmbeddingProvider(),
                                               options: EmbeddingJobOptions(batchSize: 4))
        XCTAssertEqual(report.state, "done")
        XCTAssertGreaterThan(report.chunksEmbedded, 0)
    }

    // MARK: - 1. 注入 nil：与 c 批逐位相同

    func testNilEmbedderKeepsNoQueryVectorBehaviour() throws {
        try embedded()
        let service = service(nil)

        // 开关关着（产品默认）：`disabled`，一条向量都不查
        var result = try search(service, marker)
        XCTAssertEqual(result["vectorsUnavailable"]?.boolValue, true)
        XCTAssertEqual(result["vectorUnavailableReason"]?.stringValue, "disabled")
        XCTAssertEqual(result["fusion"]?.stringValue, "union")
        XCTAssertEqual(result["queryEmbed"]?.objectValue?["source"]?.stringValue, "disabled")
        XCTAssertGreaterThan(result["hitCount"]?.intValue ?? 0, 0, "前三条通道照常工作")

        // 开关开着但没注入嵌入器：还是 c 批那条老路 `no_query_vector`
        store.retrieval.vectorsEnabled = true
        result = try search(service, marker)
        XCTAssertEqual(result["vectorsUnavailable"]?.boolValue, true)
        XCTAssertEqual(result["vectorUnavailableReason"]?.stringValue, "no_query_vector")
        XCTAssertEqual(result["fusion"]?.stringValue, "union")
        XCTAssertEqual(result["queryEmbed"]?.objectValue?["source"]?.stringValue, "no_embedder")
        XCTAssertNil(result["queryEmbed"]?.objectValue?["elapsedMS"])
        XCTAssertGreaterThan(result["hitCount"]?.intValue ?? 0, 0)
    }

    // MARK: - 2. 注入伪嵌入器：向量通道真的参与

    func testInjectedEmbedderFeedsTheVectorChannel() throws {
        try embedded()
        store.retrieval.vectorsEnabled = true
        // 伪嵌入没有语义，距离普遍在 0.4 以上，产品默认闸会全挡掉；开到最大才量得到通道。
        store.retrieval.vectorMaxDistance = 2
        let embedder = ProviderQueryEmbedder(HashEmbeddingProvider())
        let service = service(embedder)

        let result = try search(service, marker)
        XCTAssertEqual(result["vectorsUnavailable"]?.boolValue, false)
        XCTAssertNil(result["vectorUnavailableReason"])
        XCTAssertEqual(result["fusion"]?.stringValue, "rrf")
        XCTAssertGreaterThan(result["vectorCandidates"]?.intValue ?? 0, 0)
        XCTAssertEqual(embedder.callCount, 1, "一次 search 只算一条查询向量")

        let timing = try XCTUnwrap(result["queryEmbed"]?.objectValue)
        XCTAssertEqual(timing["source"]?.stringValue, "embedder")
        XCTAssertEqual(timing["dimension"]?.intValue, Int64(SchemaV4.dimension))
        let ms = try XCTUnwrap(timing["elapsedMS"]?.doubleValue)
        XCTAssertGreaterThanOrEqual(ms, 0)
        // 伪嵌入是纯 CPU 哈希，理应远远快于真实模型的 150 ms 目标；
        // 这里只是把「有这个数、而且量的是嵌入这一段」钉住。
        XCTAssertLessThan(ms, QueryEmbedTiming.hotBudgetMS)

        // 注入的向量与调用方自己算的必须逐元素一致（同一条 provider、同样的批构造 1）
        let direct = try HashEmbeddingProvider().embed([marker])[0]
        let injected = try XCTUnwrap(embedder.queryVector(for: marker))
        XCTAssertEqual(direct, injected)
    }

    /// 库里一条向量都没有时（模型没装 / 没跑过嵌入任务）：即使注入了嵌入器也降级到 `no_index`。
    func testEmptyIndexStillDegradesToNoIndex() throws {
        store.retrieval.vectorsEnabled = true
        let embedder = ProviderQueryEmbedder(HashEmbeddingProvider())
        let result = try search(service(embedder), marker)
        XCTAssertEqual(result["vectorUnavailableReason"]?.stringValue, "no_index")
        XCTAssertEqual(result["fusion"]?.stringValue, "union")
        XCTAssertGreaterThan(result["hitCount"]?.intValue ?? 0, 0)
    }

    // MARK: - 3. 零模型调用

    func testSwitchOffMeansZeroModelCalls() throws {
        try embedded()
        let embedder = ProviderQueryEmbedder(HashEmbeddingProvider())
        let service = service(embedder)
        XCTAssertFalse(store.retrieval.vectorsEnabled, "产品默认关（D8 条件 1）")
        for _ in 0..<3 { _ = try search(service, marker) }
        XCTAssertEqual(embedder.callCount, 0, "开关关着时一次模型调用都不许发")
    }

    func testFieldPrefixQueriesNeverTouchTheModel() throws {
        try embedded()
        store.retrieval.vectorsEnabled = true
        let embedder = ProviderQueryEmbedder(HashEmbeddingProvider())
        let service = service(embedder)
        for q in ["app:com.brosis.test", "host:docs.internal", "title:窗口 1"] {
            let result = try search(service, q)
            XCTAssertEqual(result["vectorUnavailableReason"]?.stringValue, "field_prefix")
            XCTAssertEqual(result["queryEmbed"]?.objectValue?["source"]?.stringValue, "field_prefix")
        }
        XCTAssertEqual(embedder.callCount, 0, "带字段前缀的查询本来就不走向量通道，算了也是白算")
    }

    func testLockedGateNeverTouchesTheModel() throws {
        try embedded()
        store.retrieval.vectorsEnabled = true
        let embedder = ProviderQueryEmbedder(HashEmbeddingProvider())
        let service = service(embedder)
        // 3.5：`locked` 时 MCPGate 连 service 都不交出去；`paused` 时交出去但直接拒。
        for state in [MCPServiceState.locked, .paused] {
            let gate = MCPGate { (state, state == .locked ? nil : service) }
            let response = gate.handle(IPCCall(
                request: IPCRequest(client: "claude-code", op: .tool,
                                    name: MCPTool.search.rawValue, args: ["q": .string(marker)]),
                peer: PeerInfo(uid: getuid(), gid: getgid(), pid: getpid(), teamID: "TESTTEAM",
                               signingID: "com.brosis.test", codeSigningVerified: true,
                               codeSigningNote: "skipped(test_host)"),
                refusal: nil, rateUsed: 1, rateLimit: 60))
            XCTAssertFalse(response.ok, "\(state) 下必须拒绝")
        }
        XCTAssertEqual(embedder.callCount, 0, "库锁着 / 采集暂停时一次模型调用都不许发")
    }

    // MARK: - 4. 算查询向量时不持库锁

    /// 嵌入器里再去读一次库：如果 `runSearch` 是**持锁**调用它的，这一读会死等到超时。
    func testQueryVectorIsComputedWithoutHoldingTheStoreLock() throws {
        try embedded()
        store.retrieval.vectorsEnabled = true
        let store = self.store
        final class ReentrantEmbedder: QueryEmbedder, @unchecked Sendable {
            let store: Store
            let inner = HashEmbeddingProvider()
            var innerReadOK = false
            init(store: Store) { self.store = store }
            func queryVector(for text: String) throws -> [Float]? {
                // 另一个线程去读库，5 s 内读到就说明调用方没有持锁。
                let semaphore = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var ok = false
                DispatchQueue.global().async {
                    ok = ((try? self.store.count(table: "observations")) ?? 0) > 0
                    semaphore.signal()
                }
                innerReadOK = semaphore.wait(timeout: .now() + 5) == .success && ok
                return try inner.embed([text]).first
            }
        }
        let embedder = ReentrantEmbedder(store: store)
        _ = try search(service(embedder), marker)
        XCTAssertTrue(embedder.innerReadOK,
                      "算查询向量的时候库锁必须是放开的，否则采集线程会被 GPU 活卡住")
    }

    // MARK: - 5. 常驻 + 空闲卸载状态机（纯函数）

    func testIdleUnloadStateMachine() {
        var state = QueryEmbedderState()

        // ① 首次查询 → 加载
        var step = QueryEmbedderPolicy.next(state, on: .query(at: 1_000))
        XCTAssertEqual(step.action, .load)
        XCTAssertTrue(step.state.loaded)
        XCTAssertEqual(step.state.lastQueryAt, 1_000)
        state = step.state

        // ② 再来一次查询 → 复用，不重新加载
        step = QueryEmbedderPolicy.next(state, on: .query(at: 1_100))
        XCTAssertEqual(step.action, .reuse)
        XCTAssertEqual(step.state.lastQueryAt, 1_100)
        state = step.state

        // ③ 空闲不到 10 分钟 → 什么都不做（599 s 与 600 s 的边界都钉住）
        XCTAssertEqual(QueryEmbedderPolicy.next(state, on: .tick(at: 1_100 + 599)).action, .none)
        step = QueryEmbedderPolicy.next(state, on: .tick(at: 1_100 + 600))
        XCTAssertEqual(step.action, .unload("idle_600s"))
        XCTAssertFalse(step.state.loaded)
        XCTAssertNil(step.state.lastQueryAt)

        // ④ 锁屏 / 暂停、关库、用户关开关：立刻卸载
        for (event, reason) in [(QueryEmbedderEvent.paused, "paused"),
                                (.storeClosed, "store_closed"),
                                (.disabledByUser, "disabled_by_user")] {
            let unloaded = QueryEmbedderPolicy.next(state, on: event)
            XCTAssertEqual(unloaded.action, .unload(reason))
            XCTAssertFalse(unloaded.state.loaded)
            // 没加载的时候这三种事件是空操作，不该报"卸载了"
            XCTAssertEqual(QueryEmbedderPolicy.next(QueryEmbedderState(), on: event).action, .none)
        }

        // ⑤ 卸载之后再查一次 → 重新加载（而不是复用一个已经不在的模型）
        XCTAssertEqual(QueryEmbedderPolicy.next(QueryEmbedderState(), on: .query(at: 9_999)).action,
                       .load)
        // 没加载时的 tick 也是空操作
        XCTAssertEqual(QueryEmbedderPolicy.next(QueryEmbedderState(), on: .tick(at: 9_999)).action,
                       .none)
    }
}
