import Foundation

/// IPC 客户端：`brosis-mcp` 用它把 MCP 的 `tools/call` 转成一条本地请求。
///
/// **不持钥、不开库**——这个类型只认识 socket 与 JSON，链接的是 `BrosisIPC` 一个目标，
/// 里面没有 SQLCipher、没有 `BrosisCore`（计划 3.1「`brosis-mcp` 不持钥、不写库」）。
public final class IPCClient: @unchecked Sendable {

    public let socketURL: URL
    public let clientID: String
    private let lock = NSLock()
    private var stream: LineStream?
    /// 连接空闲多久之后重连（服务端可能因为锁定 / 重启把连接断了）。
    private let connectTimeout: TimeInterval

    public init(socketURL: URL, clientID: String, connectTimeout: TimeInterval = 5) {
        self.socketURL = socketURL
        self.clientID = clientID
        self.connectTimeout = connectTimeout
    }

    deinit { disconnect() }

    public func disconnect() {
        lock.lock()
        stream?.closeStream()
        stream = nil
        lock.unlock()
    }

    /// 这一次**服务端肯定没执行**，重发一次是安全的。只有两种情况算数：
    /// ① 连接没建起来 / 写请求时就断了（请求根本没出去）；
    /// ② 复用的那条闲置连接被服务端先关了，一个响应字节都没读到就干净 EOF。
    private struct SafeToResend: Error { let underlying: Error }

    /// 发一条请求并等一条响应。
    ///
    /// **重试只覆盖「服务端没执行过」的那两种断链**（见 `SafeToResend`）。
    /// 读响应超时（`SO_RCVTIMEO`）、或读到一半才断，**一律不重发**：
    /// 服务端可能已经把这次调用执行完了，重发会让它再跑一遍，限流也会算两次。
    public func send(op: IPCOperation, name: String? = nil,
                     args: [String: JSONValue] = [:]) throws -> IPCResponse {
        let request = IPCRequest(client: clientID, op: op, name: name, args: args)
        do {
            return try roundTrip(request)
        } catch let first as SafeToResend {
            // 服务端退出 / 重启导致的断链是正常情况：重连一次再试。
            // 注意**不是**"锁定"：`brosis.app` 锁定只摘掉库（`ipc.detach()`），
            // socket 与既有连接都留着，客户端拿到的是一条 `[locked]` 响应而不是断链。
            disconnect()
            // 等一下再重连：服务端**起 socket** 时 bind 与 listen 中间有个极短的窗口
            //（`brosis.app` 是启动后第一次解锁时起一次，`brosis-store serve` 是每次启动时），
            // 撞上它 connect 会 ECONNREFUSED。立刻重试（微秒级）等于没重试。
            // 服务端确实不在时，代价也只是慢 150 ms。
            // 如实说明：这 150 ms **没有回归用例覆盖**（那个窗口在测试里稳定复现不了），
            // 删掉它不影响本文件另一处 `SO_NOSIGPIPE` 的修复。
            usleep(150_000)
            do {
                return try roundTrip(request)
            } catch let again as SafeToResend {
                _ = first
                throw again.underlying          // 错误类型不外泄，抛底层的 IPCTransportError
            }
        }
    }

    private func roundTrip(_ request: IPCRequest) throws -> IPCResponse {
        lock.lock()
        defer { lock.unlock() }
        let reused = stream != nil
        do {
            if stream == nil { stream = try connect() }
            guard let stream else { throw IPCTransportError.closed }
            try stream.writeLine(request)
        } catch {
            stream = nil
            throw SafeToResend(underlying: error)   // ① 请求没出去
        }
        guard let stream else { throw IPCTransportError.closed }
        do {
            guard let line = try stream.readLine(maxBytes: IPCProtocol.maxResponseBytes) else {
                self.stream = nil
                // ② 一个字节都没读到的干净 EOF：复用的闲置连接才当作"没执行过"。
                // 新连上就 EOF 说明服务端把这次调用收下了又断了，不能替它重来。
                if reused { throw SafeToResend(underlying: IPCTransportError.closed) }
                throw IPCTransportError.closed
            }
            return try IPCCodec.decode(IPCResponse.self, from: line)
        } catch {
            // 读到一半失败的连接可能停在半条消息上，不能复用。
            self.stream = nil
            throw error
        }
    }

    private func connect() throws -> LineStream {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCTransportError.posix(op: "socket", errno: errno) }
        // 服务端**退出 / 重启 / 崩溃**会把连接断掉：`IPCServer.stop()` 对每条存活连接
        // `shutdown(SHUT_RDWR)`，进程被杀则由内核收尾。锁定**不**断连接（那只是 `[locked]` 响应），
        // 所以这条路径对应的是"brosis.app 退出或重启，而 Claude Code 里的 brosis-mcp 还挂着"。没有这一行，
        // 往那条已经断了的连接上写下一个请求就是 SIGPIPE，`brosis-mcp` 当场死掉，
        // 宿主（Claude Code）得重启才能再用；有了它，写失败变成 EPIPE，
        // 走下面 `SafeToResend` 的重连重试，用户那边只是慢了一下。
        guard IPCSocketOptions.suppressSIGPIPE(fd: fd) else {
            let err = errno
            Darwin.close(fd)
            throw IPCTransportError.posix(op: "setsockopt(SO_NOSIGPIPE)", errno: err)
        }
        var timeout = timeval(tv_sec: Int(connectTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var connectErrno: Int32 = 0
        let ok = try UnixSocketAddress.withAddress(path: socketURL.path) { addr, len -> Bool in
            if Darwin.connect(fd, addr, len) != 0 { connectErrno = errno; return false }
            return true
        }
        guard ok else {
            Darwin.close(fd)
            throw IPCTransportError.posix(op: "connect", errno: connectErrno)
        }
        return LineStream(fd: fd)
    }
}
