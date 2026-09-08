import CryptoKit
import Darwin
import Foundation

// =============================================================================
// 通用小件。搬自 tools/e9/Sources/brosis-e9/Util.swift，只做 public 化与裁剪。
// 口径统一：MiB = 2^20、GiB = 2^30（评审 F8）。
// =============================================================================

public enum ModelBytes {
    public static let mib = 1024.0 * 1024.0
    public static let gib = 1024.0 * 1024.0 * 1024.0

    public static func mibString(_ n: some BinaryInteger) -> String {
        String(format: "%.2f MiB", Double(n) / mib)
    }
    public static func gibString(_ n: some BinaryInteger) -> String {
        String(format: "%.3f GiB", Double(n) / gib)
    }
    public static func human(_ n: some BinaryInteger) -> String {
        Double(n) >= gib ? gibString(n) : mibString(n)
    }
}

/// 进程内存与热状态。
///
/// **口径（评审 F8 / D27）**：Apple Silicon 统一内存里 Metal 缓冲计入 `phys_footprint`
/// 而**不**计入 RSS，批量嵌入时 RSS 会把 6.21 GiB 的工作负载报成 766 MiB。
/// 所有内存验收一律看 `peakFootprintBytes()`（= `/usr/bin/time -l` 的 `peak memory footprint`）。
public enum ModelProc {

    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }

    /// 当前物理内存足迹（字节）。等价于活动监视器的 “Memory” 列。
    public static func footprintBytes() -> UInt64 { vmInfo()?.phys_footprint ?? 0 }

    /// 生命周期内的 footprint 峰值（字节）。与 `/usr/bin/time -l` 的 `peak memory footprint` 同源。
    public static func peakFootprintBytes() -> UInt64 {
        guard let i = vmInfo() else { return 0 }
        return UInt64(Swift.max(0, i.ledger_phys_footprint_peak))
    }

    public static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// 机器型号，如 `Mac16,12`。
    public static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        // 去掉结尾的 NUL 再解码：`String(cString:)` 在 Swift 6.3 上已废弃。
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// 热状态：`nominal` / `fair` / `serious` / `critical`。
    /// **无风扇 Air 上必须看它**：D27 实测持续负载 2 分 10 秒后转 `fair`、嵌入吞吐掉 33.6%。
    public static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// 热状态是否允许跑重活（只有 `nominal` 才算）。
    public static var thermalAllowsWork: Bool {
        ProcessInfo.processInfo.thermalState == .nominal
    }
}

public enum ModelHashing {
    /// 流式计算文件 sha256。
    ///
    /// **逐块的循环必须包 `autoreleasepool`**（3.11「下载器与导入的 M1 要求」）：
    /// `read(upToCount:)` 返回的 `Data` 是 autorelease 对象，命令行工具主线程没有 RunLoop，
    /// 池子到循环结束才清空。2026-09-07 Air 实测：不包时校验 2.9 GiB 模型 peak footprint
    /// 2,935.8 MiB，包上之后 9.4 MiB。
    public static func sha256(ofFileAt url: URL, chunk: Int = 4 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let done: Bool = try autoreleasepool {
                guard let data = try handle.read(upToCount: chunk), !data.isEmpty else { return true }
                hasher.update(data: data)
                return false
            }
            if done { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 清单与其他随包资源的查找。
public enum ModelResources {
    /// 环境变量覆盖（测试与验收用）。
    public static let overrideKey = "BROSIS_MODEL_RESOURCES"

    /// 依次找：环境变量 → SwiftPM 资源 bundle（`Bundle.module`）→ 主 bundle 的
    /// `Contents/Resources` → 可执行文件同目录 → 可执行文件旁的 `brosis_BrosisModels.bundle`。
    public static func url(named name: String) -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment[overrideKey] {
            candidates.append(URL(filePath: override).appending(path: name))
        }
        candidates.append(Bundle.module.bundleURL.appending(path: name))
        if let resources = Bundle.module.resourceURL { candidates.append(resources.appending(path: name)) }
        if let main = Bundle.main.resourceURL { candidates.append(main.appending(path: name)) }
        let exeDir = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appending(path: name))
        candidates.append(exeDir.appending(path: "brosis_BrosisModels.bundle").appending(path: name))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
