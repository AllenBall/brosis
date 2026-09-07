import BrosisCore
import BrosisIPC
import Foundation

/// 采集端里的**本地 IPC 服务端**（计划 3.1：存储服务是唯一持钥者，`brosis-mcp` 经本地 IPC 查询）。
///
/// 它挂在 `LockController` 上——那是本进程里唯一持有 `Store` 的地方：
///
/// | 3.5 的相位 | 这里做什么 | MCP 客户端看到什么 |
/// |---|---|---|
/// | `unlocked` 且没有暂停原因 | 正常服务 | 工具照常返回（仍受 grant 与限流限制） |
/// | `unlocked` 但有暂停原因 | 拒绝，但库开着，审计直接落库 | `paused` |
/// | `unlocking` / `locking` / `locked` | 拒绝，审计先攒内存，解锁后补写 | `locked` |
///
/// **socket 起来了就不再关**（除非退出）：这样客户端拿到的是一句"brosis 锁着"，
/// 而不是 `connect: No such file or directory`——后者分不清"没装"和"锁着"。
///
/// 对端校验策略在这里是**写死的常量** `.requireSameTeam`，不读任何环境变量：
/// 测试用的 `BROSIS_IPC_SKIP_CODESIGN` 只由 `brosis-store serve` 读（core 的 CLI），
/// 产品进程里没有这个口子。
final class MCPIPCService: @unchecked Sendable {

    /// 每客户端每分钟的调用上限（2.2 硬约束 4）。可用
    /// `defaults write com.brosis.app mcp.requestsPerMinute -int 120` 改。
    static let rateLimitKey = "mcp.requestsPerMinute"
    static let defaultRequestsPerMinute = 60

    private let recorder: Recorder
    private let lock = NSLock()
    private var service: StoreMCPService?
    private var paused = false
    private var server: IPCServer?
    private var gate: MCPGate!
    private var lastError: String?

    init(recorder: Recorder) {
        self.recorder = recorder
        self.gate = MCPGate { [weak self] in
            guard let self else { return (.locked, nil) }
            return self.currentState()
        }
        self.gate.onEvent = { [weak self] line in
            self?.recorder.logEvent(kind: "mcp_ipc", detail: line)
        }
    }

    private func currentState() -> (state: MCPServiceState, service: StoreMCPService?) {
        lock.lock()
        defer { lock.unlock() }
        guard let service else { return (.locked, nil) }
        return (paused ? .paused : .unlocked, service)
    }

    // MARK: - 生命周期

    /// 起 socket。数据目录必须已经存在（`Store.open` 会建），所以由第一次开库成功后调用。
    /// 可重复调用，已经在跑就什么都不做。
    func startIfNeeded(directory: URL, defaults: UserDefaults = .standard) {
        lock.lock()
        let running = server != nil
        lock.unlock()
        guard !running else { return }

        var configuration = IPCServer.Configuration(
            socketURL: IPCProtocol.socketURL(dataDirectory: directory))
        let configured = defaults.integer(forKey: Self.rateLimitKey)
        configuration.requestsPerMinute = configured > 0 ? configured : Self.defaultRequestsPerMinute
        configuration.peerPolicy = .requireSameTeam       // 产品路径写死，见类型注释

        let created = IPCServer(configuration: configuration) { [gate] call in
            gate!.handle(call)
        }
        created.onEvent = { [weak self] line in
            self?.recorder.logEvent(kind: "mcp_ipc", detail: line)
        }
        do {
            try created.start()
            lock.lock()
            server = created
            lastError = nil
            lock.unlock()
            recorder.logEvent(
                kind: "mcp_ipc_started",
                detail: "socket=\(configuration.socketURL.lastPathComponent) "
                      + "rate=\(configuration.requestsPerMinute)/min policy=require_same_team "
                      + "team=\(created.hostTeamID ?? "none")"
                      + (created.hostTeamID == nil
                         ? "（本进程没有 Team ID：未签名 / ad-hoc 构建，所有对端都会被拒）" : ""))
        } catch {
            lock.lock()
            lastError = "\(error)"
            lock.unlock()
            recorder.logEvent(kind: "mcp_ipc_failed", detail: "\(error)")
        }
    }

    /// 进入 `unlocked`：把库交给 MCP 服务。
    func attach(store: Store) {
        lock.lock()
        service = StoreMCPService(store: store)
        let handle = service
        lock.unlock()
        if let handle { _ = gate.flush(into: handle) }   // 补写锁定期间攒下的审计
    }

    /// 离开 `unlocked`：**在关库之前**摘掉，之后所有调用回 `locked`。
    func detach() {
        lock.lock()
        service = nil
        lock.unlock()
    }

    func setPaused(_ value: Bool) {
        lock.lock()
        paused = value
        lock.unlock()
    }

    /// 退出时停 socket 并删掉 socket 文件。
    func stop() {
        lock.lock()
        let running = server
        server = nil
        service = nil
        lock.unlock()
        running?.stop()
    }

    // MARK: - 菜单显示

    /// 菜单里那一行：socket 起没起、现在什么状态、攒了多少条没写的审计。
    var menuDescription: String {
        lock.lock()
        let running = server != nil
        let state: String = service == nil ? "locked" : (paused ? "paused" : "unlocked")
        let error = lastError
        lock.unlock()
        if let error { return "MCP：socket 起不来（\(error)）" }
        guard running else { return "MCP：socket 未启动（等首次解锁）" }
        let pending = gate.pendingAuditCount
        return "MCP：socket 已就绪 · \(state)" + (pending > 0 ? " · 待写审计 \(pending) 条" : "")
    }

    var socketIsRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return server != nil
    }
}
