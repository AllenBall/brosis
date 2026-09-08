import Foundation

/// BrosisSync 对外抛出的全部错误。
///
/// 分得细，是因为 3.9 的「状态显示」要求把"缺段、校验失败、iCloud 未下载"分开报——
/// 用户能据此判断是等一等（未下载）、还是去另一台机器上看看（缺段）、还是目录坏了（校验失败）。
public enum SyncError: Error, CustomStringConvertible, Sendable {

    /// 同步目录不能用（与数据目录重叠、里面有库文件）。
    case directoryRejected(path: String, reason: String)
    /// 目录里没有 manifest.json（还没初始化）。
    case notInitialized(path: String)
    /// 两个 manifest：iCloud 保留了冲突副本（3.9「边界情况」）。**停止，不自动合并**。
    case manifestConflict(names: [String])
    /// manifest 不认识（格式名 / 版本对不上）。
    case unsupportedManifest(String)
    /// 段文件格式版本不认识。
    case unsupportedFormat(found: Int, supported: Int)
    /// 配对口令不合法（长度、字符集）。
    case invalidPassphrase(String)
    /// 口令错：解不开 keyring 里任何一份包裹（3.9「口令错误则不加入」）。
    case wrongPassphrase
    /// keyring / KDF 层的其他失败。
    case keyring(String)
    /// 本机还没有同步密钥，且没给口令。
    case keyRequired
    /// 库里存的同步密钥与目录 manifest 的指纹不符（换了一套目录 / 换了一套密钥）。
    case keyMismatch(expected: String, found: String)
    /// 段文件校验和不符：**文件坏了**（传输截断、同步盘写坏）。
    case checksumMismatch(device: String, seq: Int64)
    /// 段文件解密失败：密钥不对，或段头被改过（段头是 AAD）。
    case decryptFailed(device: String, seq: Int64)
    /// 段内容自相矛盾。
    case corruptSegment(String)
    /// 缺段：`expected` 那一段还没出现，**不跳过**（3.9「缺段或损坏时停止导入并提示」）。
    case missingSegment(device: String, expected: Int64, available: [Int64])
    /// 文件不在（既没有实体也没有占位符）。
    case missingFile(String)
    /// iCloud 触发下载失败。
    case downloadFailed(String, String)
    /// iCloud 下载超时（占位符一直没变成实体）。
    case downloadTimeout(String, TimeInterval)

    public var description: String {
        switch self {
        case .directoryRejected(let path, let reason):
            return "同步目录被拒绝：\(path)——\(reason)"
        case .notInitialized(let path):
            return "同步目录还没初始化（没有 manifest.json）：\(path)"
        case .manifestConflict(let names):
            return "同步目录里有多个 manifest（iCloud 冲突副本）：\(names.joined(separator: "、"))。"
                 + "两台机器几乎同时首次打开会这样；请保留一个再继续，本程序不自动合并（3.9）"
        case .unsupportedManifest(let m):
            return "manifest 不认识：\(m)"
        case .unsupportedFormat(let found, let supported):
            return "段文件格式版本 \(found)，本版本支持 \(supported)"
        case .invalidPassphrase(let m):
            return "配对口令不合法：\(m)"
        case .wrongPassphrase:
            return "配对口令错误，未加入这个同步目录"
        case .keyring(let m):
            return "同步密钥处理失败：\(m)"
        case .keyRequired:
            return "本机还没有这个目录的同步密钥，需要输入配对口令"
        case .keyMismatch(let expected, let found):
            return "同步密钥指纹不符：目录里是 \(expected)，本机存的是 \(found)。"
                 + "多半是换了一个同步目录或重新配过对"
        case .checksumMismatch(let device, let seq):
            return "段文件校验和不符（文件坏了）：\(device) 的第 \(seq) 段，停止导入"
        case .decryptFailed(let device, let seq):
            return "段文件解密失败（密钥不对或段头被改过）：\(device) 的第 \(seq) 段，停止导入"
        case .corruptSegment(let m):
            return "段文件损坏：\(m)"
        case .missingSegment(let device, let expected, let available):
            let list = available.prefix(8).map(String.init).joined(separator: ",")
            return "缺段：设备 \(device) 缺第 \(expected) 段（现有 \(list)\(available.count > 8 ? "…" : "")），"
                 + "停止导入、不跳过（3.9）"
        case .missingFile(let name):
            return "文件不在：\(name)"
        case .downloadFailed(let name, let reason):
            return "触发 iCloud 下载失败：\(name)——\(reason)"
        case .downloadTimeout(let name, let seconds):
            return "等 iCloud 下载超时（\(Int(seconds)) s）：\(name)。文件还是占位符，稍后重试"
        }
    }
}
