import Foundation
import BrosisIPC

/// 一次 MCP 调用的判定结果（写进 `mcp_audit.decision`）。
///
/// 与 `IPCErrorCode` 一一对应，多一个 `ok`。分成两个类型是因为审计要记的是
/// 「这次调用发生了什么」，而 `IPCErrorCode` 是「回给客户端什么错误码」——
/// 将来协议加错误码不一定要改审计口径。
public enum MCPDecision: String, Sendable, Codable, CaseIterable {
    case ok
    case noGrant = "no_grant"
    case deniedByGrant = "denied_by_grant"
    case rateLimited = "rate_limited"
    case locked
    case paused
    case unauthorizedPeer = "unauthorized_peer"
    case badRequest = "bad_request"
    case unknownTool = "unknown_tool"
    case error

    public init(_ code: IPCErrorCode) {
        switch code {
        case .badRequest, .unsupportedVersion: self = .badRequest
        case .unknownTool:                     self = .unknownTool
        case .locked:                          self = .locked
        case .paused:                          self = .paused
        case .noGrant:                         self = .noGrant
        case .deniedByGrant:                   self = .deniedByGrant
        case .rateLimited:                     self = .rateLimited
        case .unauthorizedPeer:                self = .unauthorizedPeer
        case .internalError:                   self = .error
        }
    }
}

/// 一条审计行。**不含正文、不含查询串**（见 `Schema.createMCPAudit` 的注释）。
public struct MCPAuditRow: Sendable, Codable {
    public var id: Int64 = 0
    public var ts: Int64
    public var clientID: String
    /// `tool` / `admin` / `ping`。
    public var op: String
    /// 工具名或管理命令名。
    public var tool: String
    /// 参数摘要：只有形状（长度、条数、时间窗、粒度、bundle id），没有正文。
    public var params: String
    public var decision: MCPDecision
    public var resultCount: Int
    public var peer: String?
    public var elapsedMS: Double
    public var note: String?

    public init(ts: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
                clientID: String, op: String, tool: String, params: String,
                decision: MCPDecision, resultCount: Int = 0, peer: String? = nil,
                elapsedMS: Double = 0, note: String? = nil) {
        self.ts = ts
        self.clientID = clientID
        self.op = op
        self.tool = tool
        self.params = params
        self.decision = decision
        self.resultCount = resultCount
        self.peer = peer
        self.elapsedMS = elapsedMS
        self.note = note
    }
}

extension Store {

    /// 写一条 MCP 审计行（3.6「审计：每次调用记录客户端、工具、参数摘要、返回条数」）。
    ///
    /// 审计写失败**不能**把查询本身搞挂（也不能让它变成"查得到但没记账"）——
    /// 调用方拿返回值判断，`StoreMCPService` 会把写失败记进响应的 `auditWritten` 字段。
    @discardableResult
    public func appendMCPAudit(_ row: MCPAuditRow) -> Bool {
        do {
            _ = try withLock { conn in
                try conn.run("""
                    INSERT INTO mcp_audit(ts, client_id, op, tool, params, decision,
                                          result_count, peer, elapsed_ms, note)
                    VALUES (?,?,?,?,?,?,?,?,?,?);
                    """, [.int(row.ts), .text(row.clientID), .text(row.op), .text(row.tool),
                          .text(row.params), .text(row.decision.rawValue),
                          .int(Int64(row.resultCount)), .optionalText(row.peer),
                          .double(row.elapsedMS), .optionalText(row.note)])
            }
            return true
        } catch {
            return false
        }
    }

    /// 最近 N 条审计（倒序）。`admin audit` 与测试用。
    public func mcpAuditTail(limit: Int = 20, clientID: String? = nil) throws -> [MCPAuditRow] {
        try withLock { conn in
            let sql = clientID == nil
                ? """
                  SELECT id, ts, client_id, op, tool, params, decision, result_count, peer,
                         elapsed_ms, note FROM mcp_audit ORDER BY id DESC LIMIT ?;
                  """
                : """
                  SELECT id, ts, client_id, op, tool, params, decision, result_count, peer,
                         elapsed_ms, note FROM mcp_audit WHERE client_id = ?
                   ORDER BY id DESC LIMIT ?;
                  """
            let binds: [SQLValue] = clientID.map { [.text($0), .int(Int64(max(1, limit)))] }
                ?? [.int(Int64(max(1, limit)))]
            let st = try conn.prepare(sql)
            defer { st.finalize() }
            try st.bind(binds)
            var out: [MCPAuditRow] = []
            while try st.step() {
                var row = MCPAuditRow(
                    ts: st.int(1) ?? 0,
                    clientID: st.text(2) ?? "",
                    op: st.text(3) ?? "",
                    tool: st.text(4) ?? "",
                    params: st.text(5) ?? "",
                    decision: st.text(6).flatMap(MCPDecision.init(rawValue:)) ?? .error,
                    resultCount: Int(st.int(7) ?? 0),
                    peer: st.text(8),
                    elapsedMS: st.double(9) ?? 0,
                    note: st.text(10))
                row.id = st.int(0) ?? 0
                out.append(row)
            }
            return out
        }
    }

    public func mcpAuditCount() throws -> Int {
        try withLock { conn in Int(try conn.scalarInt("SELECT COUNT(*) FROM mcp_audit;") ?? 0) }
    }

    /// 列出全部 grant（`admin grant list`）。
    public func allGrants() throws -> [Grant] {
        try withLock { conn in
            let st = try conn.prepare("""
                SELECT client_id, mode, apps, time_window, fields, created_at
                  FROM grants ORDER BY client_id;
                """)
            defer { st.finalize() }
            var out: [Grant] = []
            while try st.step() {
                guard let id = st.text(0),
                      let mode = st.text(1).flatMap(GrantMode.init(rawValue:)),
                      let fields = st.text(4).flatMap(GrantFields.init(rawValue:)) else { continue }
                let apps = (st.text(2)?.data(using: .utf8))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? ["*"]
                out.append(Grant(clientID: id, mode: mode, apps: apps,
                                 timeWindowDays: Int(st.int(3) ?? 30), fields: fields,
                                 createdAt: st.int(5) ?? 0))
            }
            return out
        }
    }

    /// 删掉一份 grant（`admin grant remove`）。返回是否真的删掉了一行。
    @discardableResult
    public func removeGrant(clientID: String) throws -> Bool {
        try withLock { conn in
            try conn.run("DELETE FROM grants WHERE client_id = ?;", [.text(clientID)]) > 0
        }
    }
}
