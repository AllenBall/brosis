import Foundation
import XCTest
@testable import BrosisCore
import BrosisIPC

/// M1 / T5：本地 IPC 这一层本身（编解码、框架、限流、socket 往返）。
/// 不开库、不起 MCP，只测 `BrosisIPC`。
final class IPCProtocolTests: XCTestCase {

    // MARK: - JSONValue 编解码

    func testJSONValueRoundTripKeepsTypesAndUnicode() throws {
        let value = JSONValue.object([
            "int": .int(9_007_199_254_740_993),        // > 2^53，按 Double 走会丢精度
            "double": .double(1.5),
            "bool": .bool(true),
            "null": .null,
            "text": .string("全角：ＳＱＬ／换\n行"),
            "array": .array([.int(1), .string("二"), .null]),
            "nested": .object(["k": .string("v")]),
        ])
        let data = try IPCCodec.encode(value)
        let back = try IPCCodec.decode(JSONValue.self, from: data)
        XCTAssertEqual(back, value)
        XCTAssertEqual(back["int"]?.intValue, 9_007_199_254_740_993)
        XCTAssertEqual(back["double"]?.doubleValue, 1.5)
        XCTAssertEqual(back["text"]?.stringValue, "全角：ＳＱＬ／换\n行")
        // 正文里的换行必须被转义，否则「一行一条消息」这个框架就不成立。
        XCTAssertFalse(data.contains(0x0A), "编码后的 JSON 不能含有裸换行字节")
    }

    func testJSONValueBridgesFoundationObjects() throws {
        let original: [String: Any] = ["a": 1, "b": "二", "c": [true, NSNull()], "d": 2.5]
        let value = JSONValue(foundation: original)
        XCTAssertEqual(value["a"]?.intValue, 1)
        XCTAssertEqual(value["b"]?.stringValue, "二")
        XCTAssertEqual(value["c"]?.arrayValue?.first?.boolValue, true)
        XCTAssertEqual(value["d"]?.doubleValue, 2.5)
        let object = value.foundationObject
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object))
    }

    func testRequestResponseRoundTrip() throws {
        let request = IPCRequest(id: "abc", client: "claude-code", op: .tool, name: "search",
                                 args: ["q": .string("知识图谱"), "limit": .int(5)])
        let decoded = try IPCCodec.decode(IPCRequest.self, from: try IPCCodec.encode(request))
        XCTAssertEqual(decoded.v, IPCProtocol.version)
        XCTAssertEqual(decoded.client, "claude-code")
        XCTAssertEqual(decoded.op, .tool)
        XCTAssertEqual(decoded.name, "search")
        XCTAssertEqual(decoded.args["q"]?.stringValue, "知识图谱")

        let ok = IPCResponse(id: "abc", result: .object(["hitCount": .int(3)]))
        let okBack = try IPCCodec.decode(IPCResponse.self, from: try IPCCodec.encode(ok))
        XCTAssertTrue(okBack.ok)
        XCTAssertEqual(okBack.result?["hitCount"]?.intValue, 3)

        let bad = IPCResponse(id: "abc", code: .noGrant, message: "没有 grant")
        let badBack = try IPCCodec.decode(IPCResponse.self, from: try IPCCodec.encode(bad))
        XCTAssertFalse(badBack.ok)
        XCTAssertEqual(badBack.error?.code, .noGrant)
    }

    func testMalformedInputIsRejected() {
        for text in ["", "{", "not json", "[1,2,3]", "{\"v\":1}", "null"] {
            XCTAssertNil(try? IPCCodec.decode(IPCRequest.self, from: Data(text.utf8)),
                         "「\(text)」不该被当成合法请求")
        }
    }

    // MARK: - 换行分隔框架

    func testLineStreamSplitsAcrossChunkBoundaries() throws {
        let pipe = Pipe()
        let stream = LineStream(fd: pipe.fileHandleForReading.fileDescriptor)
        // 一条 200 KiB 的行，肯定跨多次 read。
        // **必须在别的线程上写**：管道缓冲区只有 64 KiB，同一个线程写满就会阻塞在这里，
        // 而读的人正是它自己（第一版这么写，测试直接挂死）。
        let long = String(repeating: "夯", count: 70_000)
        let payload = "第一行\n" + long + "\n最后一行没有换行"
        let writer = pipe.fileHandleForWriting
        DispatchQueue.global().async {
            writer.write(Data(payload.utf8))
            try? writer.close()
        }

        XCTAssertEqual(try stream.readLine(maxBytes: 1 << 20).map { String(decoding: $0, as: UTF8.self) },
                       "第一行")
        XCTAssertEqual(try stream.readLine(maxBytes: 1 << 20).map { String(decoding: $0, as: UTF8.self) },
                       long)
        // 末尾没有换行也要吐出来，再下一次才是 nil（EOF）
        XCTAssertEqual(try stream.readLine(maxBytes: 1 << 20).map { String(decoding: $0, as: UTF8.self) },
                       "最后一行没有换行")
        XCTAssertNil(try stream.readLine(maxBytes: 1 << 20))
    }

    func testLineStreamRejectsOverlongLine() throws {
        let pipe = Pipe()
        let stream = LineStream(fd: pipe.fileHandleForReading.fileDescriptor)
        pipe.fileHandleForWriting.write(Data(String(repeating: "x", count: 5000).utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertThrowsError(try stream.readLine(maxBytes: 1024)) { error in
            guard case IPCTransportError.lineTooLong(let limit) = error else {
                return XCTFail("应该是 lineTooLong，实际 \(error)")
            }
            XCTAssertEqual(limit, 1024)
        }
    }

    func testOverlongSocketPathIsRejected() {
        let long = "/tmp/" + String(repeating: "d", count: 200) + "/ipc.sock"
        let server = IPCServer(configuration: .init(socketURL: URL(fileURLWithPath: long))) { call in
            IPCResponse(id: call.request.id, result: .null)
        }
        XCTAssertThrowsError(try server.start()) { error in
            guard case IPCTransportError.pathTooLong = error else {
                return XCTFail("应该是 pathTooLong，实际 \(error)")
            }
        }
    }

    // MARK: - 限流（2.2 硬约束 4）

    func testRateLimiterSlidingWindow() {
        let limiter = RateLimiter(limit: 3, windowSeconds: 60)
        let t0 = 1_000_000.0
        for i in 1...3 {
            let d = limiter.admit(client: "a", now: t0 + Double(i))
            XCTAssertTrue(d.allowed, "第 \(i) 次应该放行")
            XCTAssertEqual(d.used, i)
        }
        let denied = limiter.admit(client: "a", now: t0 + 4)
        XCTAssertFalse(denied.allowed)
        XCTAssertEqual(denied.limit, 3)
        XCTAssertGreaterThan(denied.retryAfterSeconds, 0)

        // 另一个客户端的配额互不影响（3.6：按客户端授权 / 限流）
        XCTAssertTrue(limiter.admit(client: "b", now: t0 + 4).allowed)

        // 窗口滑过去之后放行
        XCTAssertTrue(limiter.admit(client: "a", now: t0 + 62).allowed)
    }

    func testRateLimiterEvictsStaleClients() {
        let limiter = RateLimiter(limit: 5, windowSeconds: 1, maxClients: 4)
        for i in 0..<50 {
            _ = limiter.admit(client: "client-\(i)", now: 1_000 + Double(i))
        }
        // 只保留有限个客户端，不会被随机 client_id 撑爆
        XCTAssertLessThanOrEqual(limiter.used(client: "client-49", now: 1_049.5), 1)
    }

    // MARK: - 工具清单（3.6）

    func testToolCatalogHasSixReadOnlyTools() throws {
        XCTAssertEqual(MCPToolCatalog.all.count, 6)
        XCTAssertEqual(Set(MCPToolCatalog.all.map(\.name)),
                       Set(MCPTool.allCases.map(\.rawValue)))
        for tool in MCPToolCatalog.all {
            let json = tool.json
            XCTAssertEqual(json["annotations"]?["readOnlyHint"]?.boolValue, true, tool.name)
            XCTAssertEqual(json["inputSchema"]?["type"]?.stringValue, "object", tool.name)
            XCTAssertNotNil(json["inputSchema"]?["properties"]?.objectValue, tool.name)
            XCTAssertFalse(tool.description.isEmpty, tool.name)
            // schema 要能被 JSONSerialization 吃下去（客户端就是这么解析的）
            XCTAssertTrue(JSONSerialization.isValidJSONObject(json.foundationObject), tool.name)
        }
        XCTAssertEqual(MCPToolCatalog.descriptor(for: "search")?.name, "search")
        XCTAssertNil(MCPToolCatalog.descriptor(for: "delete_everything"))
    }

    // MARK: - socket 往返

    /// socket 路径要短（`sun_path` 只有 104 字节），所以放临时目录而不是 Fixture 里。
    private func makeSocketURL(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bt5-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("s.sock")
    }

    func testServerClientRoundTripAndSocketPermissions() throws {
        let socketURL = try makeSocketURL("rt")
        defer { try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent()) }

        var configuration = IPCServer.Configuration(socketURL: socketURL)
        configuration.peerPolicy = .skip          // 测试进程没有 Developer ID 签名
        let seen = Box<[String]>([])
        let server = IPCServer(configuration: configuration) { call in
            seen.value = seen.value + [call.request.name ?? "-"]
            return IPCResponse(id: call.request.id, result: .object([
                "echo": .string(call.request.args["q"]?.stringValue ?? ""),
                "client": .string(call.request.client),
                "uid": .int(Int64(call.peer.uid)),
                "codesign": .bool(call.peer.codeSigningVerified),
            ]))
        }
        try server.start()
        defer { server.stop() }

        // socket 文件必须是 0600（数据目录本身是 0700）
        let mode = (try FileManager.default.attributesOfItem(atPath: socketURL.path)[.posixPermissions]
                    as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(mode & 0o777, 0o600, "ipc.sock 权限应为 0600，实际 \(String(mode, radix: 8))")

        let client = IPCClient(socketURL: socketURL, clientID: "unit-test")
        defer { client.disconnect() }
        let response = try client.send(op: .tool, name: "search", args: ["q": .string("熵值")])
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["echo"]?.stringValue, "熵值")
        XCTAssertEqual(response.result?["client"]?.stringValue, "unit-test")
        XCTAssertEqual(response.result?["uid"]?.intValue, Int64(getuid()))
        XCTAssertEqual(seen.value, ["search"])

        // 同一条连接上连发多条
        for i in 0..<5 {
            let r = try client.send(op: .tool, name: "search", args: ["q": .string("q\(i)")])
            XCTAssertEqual(r.result?["echo"]?.stringValue, "q\(i)")
        }
        XCTAssertEqual(seen.value.count, 6)
    }

    func testServerRejectsWrongProtocolVersionAndGarbage() throws {
        let socketURL = try makeSocketURL("bad")
        defer { try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent()) }
        var configuration = IPCServer.Configuration(socketURL: socketURL)
        configuration.peerPolicy = .skip
        let handled = Box(0)
        let server = IPCServer(configuration: configuration) { call in
            handled.value += 1
            return IPCResponse(id: call.request.id, result: .null)
        }
        try server.start()
        defer { server.stop() }

        // 直接写裸字节，绕过 IPCClient
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let stream = LineStream(fd: fd)
        defer { stream.closeStream() }

        try stream.write(Data("这不是 JSON\n".utf8))
        var line = try XCTUnwrap(try stream.readLine(maxBytes: 1 << 20))
        var response = try IPCCodec.decode(IPCResponse.self, from: line)
        XCTAssertEqual(response.error?.code, .badRequest)

        try stream.write(Data(#"{"v":99,"id":"x","client":"c","op":"tool","name":"search","args":{}}"# .utf8))
        try stream.write(Data("\n".utf8))
        line = try XCTUnwrap(try stream.readLine(maxBytes: 1 << 20))
        response = try IPCCodec.decode(IPCResponse.self, from: line)
        XCTAssertEqual(response.error?.code, .unsupportedVersion)

        // 两条坏请求都不该到达处理器
        XCTAssertEqual(handled.value, 0)
    }

    func testServerEnforcesRateLimitAndExemptsPing() throws {
        let socketURL = try makeSocketURL("rate")
        defer { try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent()) }
        var configuration = IPCServer.Configuration(socketURL: socketURL)
        configuration.peerPolicy = .skip
        configuration.requestsPerMinute = 3
        let refusals = Box<[String]>([])
        let server = IPCServer(configuration: configuration) { call in
            if let refusal = call.refusal { refusals.value = refusals.value + [refusal.code.rawValue] }
            // 处理器故意"放行"：传输层的拒绝必须压过它（IPCServer 会丢掉这个返回值）
            return IPCResponse(id: call.request.id, result: .object(["leaked": .bool(true)]))
        }
        try server.start()
        defer { server.stop() }

        let client = IPCClient(socketURL: socketURL, clientID: "greedy")
        defer { client.disconnect() }
        for i in 1...3 {
            XCTAssertTrue(try client.send(op: .tool, name: "search").ok, "第 \(i) 次应该放行")
        }
        let denied = try client.send(op: .tool, name: "search")
        XCTAssertFalse(denied.ok)
        XCTAssertEqual(denied.error?.code, .rateLimited)
        XCTAssertNil(denied.result, "被限流的响应不能带结果（处理器返回的东西要被丢掉）")
        XCTAssertEqual(refusals.value, ["rate_limited"])

        // ping 不计入限流：超额之后还能 ping 通
        XCTAssertTrue(try client.send(op: .ping).ok)

        // 换个 client_id 是另一份配额（但它没有 grant，工具照样会被服务端拒）
        let other = IPCClient(socketURL: socketURL, clientID: "other")
        defer { other.disconnect() }
        XCTAssertTrue(try other.send(op: .tool, name: "search").ok)
    }

    // MARK: - 对端提前挂断（SIGPIPE）

    /// 客户端**发完请求就挂断、不读响应**，服务端不能因此死掉。
    ///
    /// 产品路径上这个服务端跑在 `brosis.app` 进程里（`LockController` 那一层）：
    /// 写一条对端已经关掉的 socket，默认行为是给整个进程发 `SIGPIPE`，
    /// 于是**任何一个 MCP 客户端只要提前挂断就能把 brosis 打死**——采集、锁定状态机一起没。
    /// 所以每条连接的 fd 都要带 `SO_NOSIGPIPE`，让这一步退化成 `EPIPE` 错误、只掐这条连接。
    ///
    /// 断言分两半：① 服务端确实撞上了写失败（否则这个用例什么都没验到）；
    /// ② 撞完之后它还活着、还能正常应答。
    func testServerSurvivesPeerHangUpBeforeReadingResponse() throws {
        let socketURL = try makeSocketURL("epipe")
        defer { try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent()) }

        var configuration = IPCServer.Configuration(socketURL: socketURL)
        configuration.peerPolicy = .skip
        let events = Box<[String]>([])
        let served = Box(0)
        let server = IPCServer(configuration: configuration) { call in
            served.value += 1
            // 故意慢一点：保证客户端先挂断，服务端写响应时才撞得上 EPIPE。
            usleep(150_000)
            // 再把响应撑大，超过 socket 缓冲区，写一定要真的落到内核。
            return IPCResponse(id: call.request.id,
                               result: .object(["pad": .string(String(repeating: "填", count: 64 * 1024))]))
        }
        server.onEvent = { line in events.value = events.value + [line] }
        try server.start()
        defer { server.stop() }

        for i in 0..<3 {
            let fd = try connectRaw(socketURL)
            let line = try IPCCodec.line(IPCRequest(client: "hang-up-\(i)", op: .ping))
            _ = line.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress, raw.count) }
            Darwin.close(fd)                      // 不读响应，直接挂断
            usleep(400_000)                       // 等服务端那条线程把响应写完（并失败）
        }

        XCTAssertEqual(served.value, 3, "三次请求都该到达处理器")
        XCTAssertTrue(events.value.contains { $0.hasPrefix("ipc_write_error") },
                      "没看到 ipc_write_error，说明这个用例没验到 EPIPE：\(events.value)")
        XCTAssertTrue(server.isRunning, "对端挂断之后服务端必须还在")

        // 还能正常服务：挂断只该掐掉那一条连接。
        let client = IPCClient(socketURL: socketURL, clientID: "after-hangup")
        defer { client.disconnect() }
        XCTAssertTrue(try client.send(op: .ping).ok, "挂断之后服务端应该照常应答")
        XCTAssertEqual(served.value, 4)
    }

    /// 裸连一个 Unix domain socket，绕过 `IPCClient`。
    private func connectRaw(_ socketURL: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketURL.path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0, "连不上 \(socketURL.lastPathComponent)")
        return fd
    }
}
