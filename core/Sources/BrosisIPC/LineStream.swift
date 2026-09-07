import Foundation

public enum IPCTransportError: Error, CustomStringConvertible {
    case posix(op: String, errno: Int32)
    case closed
    /// 一行超过上限还没等到换行符——把连接掐掉，不再往缓冲区里塞。
    case lineTooLong(limit: Int)
    case pathTooLong(String)

    public var description: String {
        switch self {
        case .posix(let op, let e):
            return "\(op) 失败：errno \(e)（\(String(cString: strerror(e)))）"
        case .closed:
            return "连接已关闭"
        case .lineTooLong(let limit):
            return "单条消息超过 \(limit) 字节上限"
        case .pathTooLong(let path):
            return "socket 路径超过 sun_path 上限（104 字节）：\(path.count) 字节"
        }
    }
}

/// 一个文件描述符上的「换行分隔 JSON」读写。
///
/// 阻塞式：本项目的 IPC 是一问一答、并发量个位数，用阻塞 fd + 一连接一线程最简单，
/// 也不需要把 `DispatchIO` 的回调模型引进来。
public final class LineStream {

    public let fd: Int32
    private var buffer = Data()
    private var eof = false

    public init(fd: Int32) {
        self.fd = fd
    }

    deinit { closeStream() }

    private var isClosed = false

    public func closeStream() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }

    /// 读一行（返回内容不含换行符）。流结束返回 nil。
    public func readLine(maxBytes: Int) throws -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer = Data(buffer[buffer.index(after: nl)...])
                return line
            }
            if buffer.count > maxBytes { throw IPCTransportError.lineTooLong(limit: maxBytes) }
            if eof {
                if buffer.isEmpty { return nil }
                let line = buffer
                buffer = Data()
                return line
            }
            try fill()
        }
    }

    private func fill() throws {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { raw -> Int in
            var got = -1
            repeat {
                got = Darwin.read(fd, raw.baseAddress, raw.count)
            } while got < 0 && errno == EINTR
            return got
        }
        if n < 0 { throw IPCTransportError.posix(op: "read", errno: errno) }
        if n == 0 { eof = true; return }
        buffer.append(contentsOf: chunk[0..<n])
    }

    /// 写一整块（自动处理部分写）。
    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                var n = -1
                repeat {
                    n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                } while n < 0 && errno == EINTR
                if n <= 0 { throw IPCTransportError.posix(op: "write", errno: errno) }
                offset += n
            }
        }
    }

    public func writeLine<T: Encodable>(_ value: T) throws {
        try write(try IPCCodec.line(value))
    }
}

// MARK: - socket 选项

enum IPCSocketOptions {

    /// 关掉这条 socket 的 `SIGPIPE`：对端先挂断时，写它应该返回 `EPIPE` **错误**，
    /// 而不是给整个进程发信号。
    ///
    /// 产品路径上服务端就跑在 `brosis.app` 里（`LockController` 那一层持有 Store），
    /// 默认行为下，任何一个 MCP 客户端「发完请求就关窗口」都能把 brosis 整个打死——
    /// 采集、锁定状态机一起没。本轮实测：不设这个选项时 `brosis-store serve`
    /// 被信号 13 干掉（`swift test` 里则是整个测试进程 `exited with unexpected signal code 13`）。
    ///
    /// 选**每条 fd 的 `SO_NOSIGPIPE`**、不选进程级的 `signal(SIGPIPE, SIG_IGN)`：
    /// 这是个库，改进程级信号处置会顺手改掉宿主 app 别处的行为。
    ///
    /// 非 socket 的 fd（`brosis-mcp` 的 stdin / stdout 是管道）会拿到 `ENOTSOCK`，
    /// 保持默认行为反而是对的：宿主把管道关了，`brosis-mcp` 就该跟着退出。
    @discardableResult
    static func suppressSIGPIPE(fd: Int32) -> Bool {
        var on: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                          socklen_t(MemoryLayout<Int32>.size)) == 0
    }
}

// MARK: - Unix domain socket 地址

enum UnixSocketAddress {

    /// 把路径填进 `sockaddr_un`。`sun_path` 只有 104 字节，超了必须当场报错——
    /// 静默截断会连到别的路径去。
    static func withAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw IPCTransportError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &addr) { p in
            try p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                try body(sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
