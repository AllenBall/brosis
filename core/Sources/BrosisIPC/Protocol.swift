import Foundation

/// brosis 本地 IPC 协议（计划 3.1：`brosis-mcp` 「经本地 IPC 查询」，不持钥、不开库、不写库）。
///
/// **传输**：数据目录下的 Unix domain socket（`ipc.sock`，0600），
/// 换行分隔的 JSON——一行一个请求、一行一个响应，与 MCP 的 stdio 传输同一种朴素框架。
/// JSON 编码会把正文里的换行转义成 `\n`，所以「一行 = 一条消息」这个前提是成立的。
///
/// **谁在两端**：服务端在 `brosis.app` 里（`LockController` 持有 `Store` 的那一层，
/// 计划 3.1「存储服务是唯一持钥者」），客户端是 `brosis-mcp`（薄接口，只转发）。
public enum IPCProtocol {

    /// 协议版本。请求里的 `v` 与它不同就直接拒绝——两端在同一个 `.app` 里一起签名分发，
    /// 不需要向下兼容协商。
    public static let version = 1

    /// socket 文件名（在数据目录下）。
    public static let socketFileName = "ipc.sock"

    /// 单条请求的字节上限。MCP 侧的参数只有查询串与 id 列表，1 MiB 绰绰有余；
    /// 上限的作用是让「一直发不带换行的字节」这种客户端被立刻掐掉，而不是把服务端撑爆。
    public static let maxRequestBytes = 1 << 20

    /// 单条响应的字节上限（`get_context` 的正文可能不小，给到 16 MiB）。
    public static let maxResponseBytes = 16 << 20

    /// 数据目录 → socket 路径。
    public static func socketURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(socketFileName, isDirectory: false)
    }
}

// MARK: - 请求

/// 请求的类别。
public enum IPCOperation: String, Codable, Sendable, CaseIterable {
    /// 3.6 的六个工具之一，`name` 是工具名。
    case tool
    /// grant 管理（`brosis-mcp admin …`）。只接受同 uid + 通过对端签名校验的连接。
    case admin
    /// 存活探测：不查库、不写审计、不计入限流。
    case ping
}

public struct IPCRequest: Codable, Sendable {
    public var v: Int
    /// 请求 id，响应原样回传（一条连接上串行发请求，但留着便于排查）。
    public var id: String
    /// 客户端标识：MCP 的 `initialize.clientInfo.name`，或环境变量 `BROSIS_CLIENT_ID`。
    /// grant 与限流都按它算。
    public var client: String
    public var op: IPCOperation
    /// `op = .tool` 时是工具名，`op = .admin` 时是管理命令名。
    public var name: String?
    public var args: [String: JSONValue]

    public init(id: String = UUID().uuidString, client: String, op: IPCOperation,
                name: String? = nil, args: [String: JSONValue] = [:]) {
        self.v = IPCProtocol.version
        self.id = id
        self.client = client
        self.op = op
        self.name = name
        self.args = args
    }
}

// MARK: - 响应

public enum IPCErrorCode: String, Codable, Sendable, CaseIterable {
    /// 请求本身不合法（JSON 坏、字段缺、参数类型不对）。
    case badRequest = "bad_request"
    /// 协议版本不匹配。
    case unsupportedVersion = "unsupported_version"
    /// 不认识的工具 / 管理命令。
    case unknownTool = "unknown_tool"
    /// 3.5：`locked` / `locking` 状态，库关着。
    case locked
    /// 3.5：`paused` 子状态（用户暂停 / 锁屏 / 屏保），库开着但拒绝 MCP。
    case paused
    /// 3.6：这个客户端没有 grant，所有工具都拒绝。
    case noGrant = "no_grant"
    /// 3.6：有 grant，但这次调用被应用白名单 / 时间窗 / 字段级别挡下。
    case deniedByGrant = "denied_by_grant"
    /// 2.2 硬约束 4：限流。
    case rateLimited = "rate_limited"
    /// 对端不是同一个 uid，或代码签名校验没过（3.5「IPC 对端签名校验 + 审计」）。
    case unauthorizedPeer = "unauthorized_peer"
    /// 服务端内部错误（查询抛错等）。
    case internalError = "internal"
}

public struct IPCFailure: Codable, Sendable {
    public var code: IPCErrorCode
    public var message: String

    public init(code: IPCErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct IPCResponse: Codable, Sendable {
    public var v: Int
    public var id: String
    public var ok: Bool
    public var result: JSONValue?
    public var error: IPCFailure?

    public init(id: String, result: JSONValue) {
        self.v = IPCProtocol.version
        self.id = id
        self.ok = true
        self.result = result
        self.error = nil
    }

    public init(id: String, code: IPCErrorCode, message: String) {
        self.v = IPCProtocol.version
        self.id = id
        self.ok = false
        self.result = nil
        self.error = IPCFailure(code: code, message: message)
    }
}

// MARK: - 六个工具的名字（3.6）

/// 3.6 的 v1 工具清单。`recent_activity` / `get_patterns` / 周台账是 M2。
public enum MCPTool: String, Codable, Sendable, CaseIterable {
    case getContext = "get_context"
    case search
    case getEvidence = "get_evidence"
    case getTimeline = "get_timeline"
    case getDayLedger = "get_day_ledger"
    case getItem = "get_item"
}

/// grant 管理命令（`brosis-mcp admin grant add|list|remove`）。
public enum AdminCommand: String, Codable, Sendable, CaseIterable {
    case grantAdd = "grant_add"
    case grantList = "grant_list"
    case grantRemove = "grant_remove"
    /// 最近的审计行（排查用，不含正文）。
    case auditTail = "audit_tail"
    /// 服务端状态：schema 版本、锁定相位、限流参数。
    case status
}

// MARK: - 编解码

public enum IPCCodec {

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// 一行（不含换行符）。
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encode(value)
        data.append(0x0A)
        return data
    }
}
