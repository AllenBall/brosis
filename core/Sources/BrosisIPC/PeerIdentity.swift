import Foundation
import Security

/// 连接对端的身份（计划 3.5 最后一条：「解锁期间，任何已获同用户权限的进程理论上可以经 IPC
/// 或内存读取数据。缓解手段是 **IPC 对端签名校验 + 审计日志**，不承诺更多」）。
public struct PeerInfo: Sendable {
    /// `getpeereid` 拿到的有效 uid。
    public var uid: uid_t
    public var gid: gid_t
    /// 对端进程号（只用于审计与排查，判定不靠它）。
    public var pid: pid_t?
    /// 对端签名里的 Team ID。
    public var teamID: String?
    /// 对端签名里的 signing identifier（`com.brosis.app` 之类）。
    public var signingID: String?
    /// 代码签名校验有没有过。
    public var codeSigningVerified: Bool
    /// 没过（或没做）的原因，写进审计。
    public var codeSigningNote: String

    public init(uid: uid_t, gid: gid_t, pid: pid_t?, teamID: String?, signingID: String?,
                codeSigningVerified: Bool, codeSigningNote: String) {
        self.uid = uid
        self.gid = gid
        self.pid = pid
        self.teamID = teamID
        self.signingID = signingID
        self.codeSigningVerified = codeSigningVerified
        self.codeSigningNote = codeSigningNote
    }

    /// 审计行里的一行描述，不含路径、不含主机名。
    public var auditDescription: String {
        var parts = ["uid=\(uid)"]
        if let pid { parts.append("pid=\(pid)") }
        parts.append("team=\(teamID ?? "-")")
        parts.append("signing_id=\(signingID ?? "-")")
        parts.append("codesign=\(codeSigningVerified ? "ok" : "fail")")
        if !codeSigningNote.isEmpty { parts.append("note=\(codeSigningNote)") }
        return parts.joined(separator: " ")
    }
}

/// 对端代码签名策略。
///
/// **产品路径永远是 `.requireSameTeam`**；`.skip` 只由 `brosis-store serve`
/// 在测试 host 里按环境变量 `BROSIS_IPC_SKIP_CODESIGN=1` 传进来。
/// 本包**不读任何环境变量**——策略是构造参数，`brosis.app` 那一侧是写死的常量，
/// 所以产品进程里没有任何"设个环境变量就关掉校验"的口子。
public enum PeerCodeSigningPolicy: Sendable, Equatable {
    /// 要求对端签名有效，且 Team ID 与本进程相同。
    /// 本进程自己没有 Team ID（未签名 / ad-hoc 的开发构建）时**判定为失败并拒绝**：
    /// 这时候无从比较，宁可不服务，也不能默认放行。
    case requireSameTeam
    /// 只查 uid，不查签名。仅供测试（测试进程是 `swift test` 编出来的，没有 Developer ID）。
    case skip
}

public enum PeerVerifier {

    /// 本进程的 Team ID（签名里的 `kSecCodeInfoTeamIdentifier`）。未签名时是 nil。
    public static func selfTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return signingInfo(of: code)?.team
    }

    /// 取连接对端的身份并按策略判定。
    public static func inspect(fd: Int32, policy: PeerCodeSigningPolicy,
                               expectedTeamID: String?) -> PeerInfo {
        var uid: uid_t = 0
        var gid: gid_t = 0
        let credOK = getpeereid(fd, &uid, &gid) == 0
        var info = PeerInfo(uid: credOK ? uid : uid_t.max, gid: credOK ? gid : gid_t.max,
                            pid: peerPID(fd: fd), teamID: nil, signingID: nil,
                            codeSigningVerified: false, codeSigningNote: "")
        if !credOK {
            info.codeSigningNote = "getpeereid_failed"
            return info
        }

        switch policy {
        case .skip:
            // 仍然把能读到的签名信息填进审计，只是不作为判定依据。
            if let code = peerCode(fd: fd), let signing = signingInfo(of: code) {
                info.teamID = signing.team
                info.signingID = signing.identifier
            }
            info.codeSigningVerified = true
            info.codeSigningNote = "skipped(test_host)"
            return info

        case .requireSameTeam:
            guard let expectedTeamID, !expectedTeamID.isEmpty else {
                // 本进程没签名就没法比 Team ID。如实记下来并拒绝（3.5「做不到就写明」）。
                info.codeSigningNote = "self_has_no_team_id"
                return info
            }
            guard let code = peerCode(fd: fd) else {
                info.codeSigningNote = "peer_code_unavailable"
                return info
            }
            if let signing = signingInfo(of: code) {
                info.teamID = signing.team
                info.signingID = signing.identifier
            }
            // 1) 签名本身有效（二进制没被改过）。
            let validity = SecCodeCheckValidity(code, [], nil)
            guard validity == errSecSuccess else {
                info.codeSigningNote = "invalid_signature(\(validity))"
                return info
            }
            // 2) 苹果签发的链 + leaf 证书的 OU 等于本进程的 Team ID。
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
                  let requirement else {
                info.codeSigningNote = "requirement_build_failed"
                return info
            }
            let matched = SecCodeCheckValidity(code, [], requirement)
            guard matched == errSecSuccess else {
                info.codeSigningNote = "team_mismatch(\(matched))"
                return info
            }
            info.codeSigningVerified = true
            info.codeSigningNote = "same_team"
            return info
        }
    }

    // MARK: - 私有

    private static func peerPID(fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return pid
    }

    /// 取对端的 `SecCode`。
    ///
    /// 首选 `LOCAL_PEERTOKEN`（audit token）：它是内核在 connect 那一刻绑定的，
    /// **不受 pid 复用影响**。取不到时退回 `LOCAL_PEERPID` + `kSecGuestAttributePid`——
    /// 那条路存在「对端退出、pid 被别的进程复用」的理论窗口，所以只当兜底。
    private static func peerCode(fd: Int32) -> SecCode? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let gotToken = withUnsafeMutableBytes(of: &token) { raw -> Bool in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, raw.baseAddress, &length) == 0
        }
        if gotToken, length == socklen_t(MemoryLayout<audit_token_t>.size) {
            let data = withUnsafeBytes(of: &token) { Data($0) }
            let attributes = [kSecGuestAttributeAudit: data] as CFDictionary
            var code: SecCode?
            if SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess {
                return code
            }
        }
        guard let pid = peerPID(fd: fd) else { return nil }
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }

    private static func signingInfo(of code: SecCode) -> (team: String?, identifier: String?)? {
        var information: CFDictionary?
        // SecCodeCopySigningInformation 收的是 SecStaticCodeRef；SecCodeRef 在 C 里是它的子类型，
        // Swift 把两者当成不同类型，所以这里必须 bitCast（这是 Apple 文档认可的用法）。
        let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dict = information as? [String: Any] else { return nil }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String,
                dict[kSecCodeInfoIdentifier as String] as? String)
    }
}
