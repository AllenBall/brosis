import Foundation

/// 一次调用送到处理器面前的全部上下文。
public struct IPCCall: Sendable {
    public var request: IPCRequest
    public var peer: PeerInfo
    /// **传输层已经判定的拒绝**（对端签名没过、限流）。非 nil 时处理器只负责写审计行，
    /// 它的返回值会被服务端丢掉、原样发这条拒绝——这样"能不能看数据"的判定不依赖处理器写对。
    public var refusal: IPCFailure?
    /// 本窗口内已用次数 / 上限，写进审计。
    public var rateUsed: Int
    public var rateLimit: Int

    public init(request: IPCRequest, peer: PeerInfo, refusal: IPCFailure?,
                rateUsed: Int, rateLimit: Int) {
        self.request = request
        self.peer = peer
        self.refusal = refusal
        self.rateUsed = rateUsed
        self.rateLimit = rateLimit
    }
}

public typealias IPCHandler = @Sendable (IPCCall) -> IPCResponse

/// 数据目录里的 Unix domain socket 服务端。
///
/// 计划 3.1：存储服务是唯一持钥者，`brosis-mcp` 经**本地 IPC** 查询。
/// 所以这个服务端跑在 `brosis.app` 进程里（`LockController` 那一层），
/// `brosis-store serve` 是它的测试替身（用 `FileKeyProvider` 开临时库）。
///
/// 每条连接一个线程；并发量个位数，不引入 `DispatchIO`。
public final class IPCServer: @unchecked Sendable {

    public struct Configuration: Sendable {
        /// socket 路径（数据目录下的 `ipc.sock`）。
        public var socketURL: URL
        /// 每客户端每分钟调用上限（2.2 硬约束 4）。
        public var requestsPerMinute: Int = 60
        /// 对端代码签名策略。**产品路径写死 `.requireSameTeam`**。
        public var peerPolicy: PeerCodeSigningPolicy = .requireSameTeam
        /// 同时在线的连接上限，超了直接关掉新连接。
        public var maxConnections: Int = 8
        public var maxRequestBytes: Int = IPCProtocol.maxRequestBytes

        public init(socketURL: URL) { self.socketURL = socketURL }
    }

    public let configuration: Configuration
    private let handler: IPCHandler
    private let limiter: RateLimiter
    /// 本进程自己的 Team ID，开服务时取一次。
    private let selfTeamID: String?
    /// 传输层的日志出口（连接建立 / 拒绝 / 坏输入）。不含正文。
    public var onEvent: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopping = false
    private var connections: Set<Int32> = []
    private var acceptThread: Thread?

    public init(configuration: Configuration, handler: @escaping IPCHandler) {
        self.configuration = configuration
        self.handler = handler
        self.limiter = RateLimiter(limit: configuration.requestsPerMinute, windowSeconds: 60)
        self.selfTeamID = PeerVerifier.selfTeamID()
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listenFD >= 0 && !stopping
    }

    /// 本进程 Team ID（自检 / 状态查询用）。
    public var hostTeamID: String? { selfTeamID }

    // MARK: - 启停

    public func start() throws {
        lock.lock()
        guard listenFD < 0 else { lock.unlock(); return }
        stopping = false
        lock.unlock()

        let path = configuration.socketURL.path
        // 上一次没清干净的 socket 文件会让 bind 直接 EADDRINUSE。
        // 只删「确实是 socket」的那个文件，绝不 unlink 别的东西。
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           (attrs[.type] as? FileAttributeType) == .typeSocket {
            try? FileManager.default.removeItem(atPath: path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCTransportError.posix(op: "socket", errno: errno) }

        do {
            try Self.bindTightly(fd: fd, path: path)
        } catch {
            Darwin.close(fd)
            throw error
        }

        guard Darwin.listen(fd, Int32(configuration.maxConnections)) == 0 else {
            let e = errno
            Darwin.close(fd)
            try? FileManager.default.removeItem(atPath: path)
            throw IPCTransportError.posix(op: "listen", errno: e)
        }

        lock.lock()
        listenFD = fd
        lock.unlock()

        onEvent?("ipc_listening path=\(configuration.socketURL.lastPathComponent) "
                 + "rate=\(configuration.requestsPerMinute)/min "
                 + "policy=\(configuration.peerPolicy == .skip ? "skip_codesign" : "require_same_team") "
                 + "team=\(selfTeamID ?? "-")")

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "brosis.ipc.accept"
        thread.stackSize = 512 * 1024
        acceptThread = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        guard !stopping, listenFD >= 0 else { stopping = true; lock.unlock(); return }
        stopping = true
        let fd = listenFD
        listenFD = -1
        let open = connections
        connections.removeAll()
        lock.unlock()

        Darwin.close(fd)
        for c in open { Darwin.shutdown(c, SHUT_RDWR) }
        try? FileManager.default.removeItem(atPath: configuration.socketURL.path)
        onEvent?("ipc_stopped")
    }

    /// bind + 收紧权限。socket 文件必须是 0600（数据目录本身是 0700）。
    ///
    /// **umask 是进程级的，还原不能漏**：`withAddress` 会在路径超长时抛错，
    /// 第一版写成"抛完就跳过还原"，于是整个进程的 umask 一直停在 `0o177`，
    /// 之后所有新建目录都变成 0600（没有 x 位），别的代码在里面建文件全部 `Permission denied`
    /// （本轮实测：一次跑挂 15 个测试用例）。所以收紧的窗口缩到只包住 `bind` 这一步，
    /// 并且用 `defer` 还原。
    private static func bindTightly(fd: Int32, path: String) throws {
        let previousMask = umask(0o177)
        defer { umask(previousMask) }
        var bindErrno: Int32 = 0
        let bound = try UnixSocketAddress.withAddress(path: path) { addr, len -> Bool in
            if Darwin.bind(fd, addr, len) != 0 { bindErrno = errno; return false }
            return true
        }
        guard bound else { throw IPCTransportError.posix(op: "bind", errno: bindErrno) }
        chmod(path, 0o600)      // chmod 不受 umask 影响，兜第二道
    }

    // MARK: - accept 循环

    private func acceptLoop(_ fd: Int32) {
        while true {
            lock.lock()
            let done = stopping
            lock.unlock()
            if done { return }

            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = withUnsafeMutablePointer(to: &poller) { poll($0, 1, 200) }
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if ready == 0 { continue }

            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            // 对端可能发完请求就挂断（关窗口、被 kill）。没有这一行，写响应时的 SIGPIPE
            // 会打死**整个宿主进程**——产品路径上那是 brosis.app 本身。
            // setsockopt 失败就不能收这条连接：否则后面一次 write 仍可能 SIGPIPE 打死宿主进程。
            guard IPCSocketOptions.suppressSIGPIPE(fd: client) else {
                let err = errno
                Darwin.close(client)
                onEvent?("ipc_connection_refused reason=no_sigpipe_setsockopt_failed errno=\(err)")
                continue
            }

            lock.lock()
            if stopping || connections.count >= configuration.maxConnections {
                lock.unlock()
                Darwin.close(client)
                onEvent?("ipc_connection_refused reason=too_many_connections")
                continue
            }
            connections.insert(client)
            lock.unlock()

            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "brosis.ipc.conn"
            thread.stackSize = 1024 * 1024
            thread.start()
        }
    }

    // MARK: - 单条连接

    private func serve(_ fd: Int32) {
        defer {
            lock.lock()
            connections.remove(fd)
            lock.unlock()
        }
        let stream = LineStream(fd: fd)
        defer { stream.closeStream() }

        // 1) uid + 代码签名：连接建立时查一次，之后这条连接上的每个请求都带着它。
        let peer = PeerVerifier.inspect(fd: fd, policy: configuration.peerPolicy,
                                        expectedTeamID: selfTeamID)
        let sameUID = peer.uid == getuid()
        var connectionRefusal: IPCFailure?
        if !sameUID {
            connectionRefusal = IPCFailure(code: .unauthorizedPeer,
                                           message: "对端 uid 与本进程不同，拒绝服务")
        } else if !peer.codeSigningVerified {
            connectionRefusal = IPCFailure(
                code: .unauthorizedPeer,
                message: "对端代码签名校验未通过（\(peer.codeSigningNote)）")
        }
        onEvent?("ipc_connection \(peer.auditDescription) "
                 + "accepted=\(connectionRefusal == nil)")

        while true {
            let line: Data?
            do {
                line = try stream.readLine(maxBytes: configuration.maxRequestBytes)
            } catch {
                onEvent?("ipc_read_error \(error)")
                return
            }
            guard let line, !line.isEmpty else { return }

            guard let request = try? IPCCodec.decode(IPCRequest.self, from: line) else {
                onEvent?("ipc_bad_request bytes=\(line.count)")
                try? stream.writeLine(IPCResponse(id: "", code: .badRequest,
                                                  message: "请求不是合法的 IPC JSON"))
                continue
            }
            guard request.v == IPCProtocol.version else {
                try? stream.writeLine(IPCResponse(
                    id: request.id, code: .unsupportedVersion,
                    message: "协议版本 \(request.v)，本服务端只认 \(IPCProtocol.version)"))
                continue
            }

            // 2) 限流。`ping` 不计入——它不查库，也不该把配额吃掉。
            var refusal = connectionRefusal
            var used = 0
            if request.op != .ping, refusal == nil {
                let decision = limiter.admit(client: request.client)
                used = decision.used
                if !decision.allowed {
                    refusal = IPCFailure(
                        code: .rateLimited,
                        message: String(format: "超过限流：%d 次 / 60 s，%.0f s 后重试",
                                        decision.limit, decision.retryAfterSeconds))
                }
            }

            // 3) 交给处理器（它负责写 mcp_audit，包括被拒的那几类）。
            let call = IPCCall(request: request, peer: peer, refusal: refusal,
                               rateUsed: used, rateLimit: configuration.requestsPerMinute)
            var response = handler(call)
            // 传输层的判定优先：处理器写错了也不可能把拒绝变成放行。
            if let refusal {
                response = IPCResponse(id: request.id, code: refusal.code, message: refusal.message)
            }
            do {
                try stream.writeLine(response)
            } catch {
                onEvent?("ipc_write_error \(error)")
                return
            }
        }
    }
}
