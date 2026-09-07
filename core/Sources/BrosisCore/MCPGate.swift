import Foundation
import BrosisIPC

/// 3.5 的锁定状态在 MCP 这一侧的三种取值。
///
/// - `unlocked`：库开着、采集在跑 → 正常服务。
/// - `paused`：库开着，但采集暂停（用户暂停 / 锁屏 / 屏保）→ **拒绝 MCP**（3.5 原话）。
/// - `locked` / `locking` / `unlocking`：库关着 → 拒绝。
public enum MCPServiceState: String, Sendable, Codable {
    case unlocked, paused, locked
}

/// 锁定门：`brosis.app` 与 `brosis-store serve` 共用的那一层「现在能不能服务」。
///
/// 放在 core 里而不是各写一份，是因为这条判定同时决定**返回什么**和**审计怎么记**，
/// 两个进程必须一模一样，否则测试测的就不是产品跑的那条路径。
///
/// **库关着时的审计**：`locked` 是「库关着」，这时候写不进 `mcp_audit`。
/// 被拒的调用先攒在内存里（上限 `maxPending` 条，超了丢最老的并计数），
/// 下一次库可用时**补写**进去——与采集端 `Recorder` 处理"锁定期间丢弃的写入"是同一个套路，
/// 目的一样：不让"锁定期间有人来敲过门"这件事悄悄消失。
public final class MCPGate: @unchecked Sendable {

    /// 每次调用现问一次：现在是什么状态、库在不在。
    public typealias Provider = @Sendable () -> (state: MCPServiceState, service: StoreMCPService?)

    private let provider: Provider
    private let lock = NSLock()
    private var pending: [MCPAuditRow] = []
    private var droppedPending = 0
    private let maxPending: Int
    /// 传输 / 补写事件的日志出口（不含正文）。
    public var onEvent: (@Sendable (String) -> Void)?

    public init(maxPending: Int = 200, provider: @escaping Provider) {
        self.maxPending = max(1, maxPending)
        self.provider = provider
    }

    /// 交给 `IPCServer` 当 handler。
    public func handle(_ call: IPCCall) -> IPCResponse {
        let (state, service) = provider()

        // 库可用了就先把攒下的审计补上，再处理这一条。
        if let service { flush(into: service) }

        guard state == .unlocked, let service else {
            return refuse(call, state: state, service: service)
        }
        return service.handle(call)
    }

    /// 补写攒下的审计行。返回补写了几条。
    @discardableResult
    public func flush(into service: StoreMCPService) -> Int {
        lock.lock()
        let rows = pending
        let dropped = droppedPending
        pending.removeAll()
        droppedPending = 0
        lock.unlock()
        guard !rows.isEmpty || dropped > 0 else { return 0 }
        var written = 0
        for row in rows where service.appendAudit(row) { written += 1 }
        if dropped > 0 {
            _ = service.appendAudit(MCPAuditRow(
                clientID: "-", op: "gate", tool: "-",
                params: "pending_overflow", decision: .locked, resultCount: 0,
                peer: nil, elapsedMS: 0,
                note: "锁定期间被拒的审计行超过 \(maxPending) 条上限，丢弃了 \(dropped) 条"))
        }
        onEvent?("mcp_audit_flushed rows=\(written) dropped=\(dropped)")
        return written
    }

    /// 现在攒着多少条没写进库的审计（自检与测试用）。
    public var pendingAuditCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    // MARK: - 私有

    private func refuse(_ call: IPCCall, state: MCPServiceState,
                        service: StoreMCPService?) -> IPCResponse {
        let request = call.request

        // `ping` 在锁定 / 暂停时也要答，而且要把状态说清楚——
        // 客户端拿它区分"服务没起来"和"服务起来了但锁着"。
        if request.op == .ping {
            return IPCResponse(id: request.id, result: .object([
                "server": .string("brosis"),
                "state": .string(state.rawValue),
                "protocolVersion": .int(Int64(IPCProtocol.version)),
                "schemaVersion": .int(Int64(Schema.version)),
            ]))
        }

        let code: IPCErrorCode = (state == .paused) ? .paused : .locked
        let message = state == .paused
            ? "brosis 处于暂停状态（用户暂停 / 锁屏 / 屏保），按计划 3.5 拒绝 MCP 调用"
            : "brosis 处于锁定状态，库没有打开，按计划 3.5 拒绝 MCP 调用"

        // 传输层已经判过一次（签名 / 限流）的话，以传输层的判定为准记审计。
        let decision = call.refusal.map { MCPDecision($0.code) } ?? MCPDecision(code)
        let row = MCPAuditRow(
            clientID: request.client, op: request.op.rawValue,
            tool: request.name ?? "-",
            params: "-", decision: decision, resultCount: 0,
            peer: call.peer.auditDescription, elapsedMS: 0,
            note: "state=\(state.rawValue)")
        if let service {
            // `paused` 时库是开着的，直接写。
            _ = service.appendAudit(row)
        } else {
            enqueue(row)
        }
        if let refusal = call.refusal {
            return IPCResponse(id: request.id, code: refusal.code, message: refusal.message)
        }
        return IPCResponse(id: request.id, code: code, message: message)
    }

    private func enqueue(_ row: MCPAuditRow) {
        lock.lock()
        if pending.count >= maxPending {
            pending.removeFirst()
            droppedPending += 1
        }
        pending.append(row)
        lock.unlock()
    }
}
