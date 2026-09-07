// brosis M0 · E9：通用工具
//
// 口径统一（评审 F8）：字节量一律按 2^20 = MiB、2^30 = GiB 换算并在输出里写明单位。

import CryptoKit
import Darwin
import Foundation

// MARK: - 单位换算（2^20 / 2^30）

enum Bytes {
    static let mib = 1024.0 * 1024.0
    static let gib = 1024.0 * 1024.0 * 1024.0

    static func mibString(_ n: some BinaryInteger) -> String {
        String(format: "%.2f MiB", Double(n) / mib)
    }

    static func gibString(_ n: some BinaryInteger) -> String {
        String(format: "%.3f GiB", Double(n) / gib)
    }

    static func human(_ n: some BinaryInteger) -> String {
        Double(n) >= gib ? gibString(n) : mibString(n)
    }
}

// MARK: - 进程与内存

enum Proc {
    /// 真正的进程启动时刻（含 dyld 加载），取自 sysctl kinfo_proc.kp_proc.p_starttime。
    static let startDate: Date = {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard rc == 0 else { return Date() }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()

    static var sinceStart: Double { Date().timeIntervalSince(startDate) }

    /// 本进程的常驻内存峰值（字节），等价于 /usr/bin/time -l 的 "maximum resident set size"。
    static func peakResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size_max : 0
    }

    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    // MARK: phys_footprint（评审 F8：Apple Silicon 统一内存下 RSS 会严重低估）
    //
    // Metal 的缓冲（含 MLX 的缓冲池）在统一内存里计入进程的 phys_footprint 而**不**计入
    // resident set size。所以批量推理的真实内存占用要看 footprint：/usr/bin/time -l 打印的
    // "peak memory footprint" 就是这个，对应 TASK_VM_INFO 的 ledger_phys_footprint_peak。
    // 只报 RSS 会把 6.2 GiB 的工作负载说成 766 MiB，差约 8 倍。

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

    /// 当前物理内存足迹（字节）。等价于 Activity Monitor 的 "Memory" 列。
    static func footprintBytes() -> UInt64 {
        vmInfo()?.phys_footprint ?? 0
    }

    /// 生命周期内的 footprint 峰值（字节）。与 `/usr/bin/time -l` 的 "peak memory footprint" 同源。
    static func peakFootprintBytes() -> UInt64 {
        guard let i = vmInfo() else { return 0 }
        return UInt64(Swift.max(0, i.ledger_phys_footprint_peak))
    }

    static var physicalMemory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    /// 机器型号，如 Mac16,6
    static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// 热状态：nominal / fair / serious / critical（Air 上要看这一项）
    static var thermalState: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

// MARK: - 哈希

enum Hashing {
    /// 流式计算文件 sha256，不把整文件读进内存。
    static func sha256(ofFileAt url: URL, chunk: Int = 4 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        // read(upToCount:) 返回的 Data 是 autorelease 对象。命令行工具的主线程没有跑 RunLoop，
        // 自动释放池在循环结束前不会清空，整个文件的块会一直攒着：2026-09-07 在 Air 上实测
        // 校验 2.9 GiB 模型时 peak footprint 到 2.9 GiB。每块包一层 autoreleasepool 即可释放。
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

// MARK: - 资源查找

enum Resources {
    /// 依次找：环境变量覆盖 → .app 的 Contents/Resources → 可执行文件同目录
    /// → SwiftPM 资源 bundle（brosis-e9_brosis-e9.bundle）→ 源码目录。
    static func url(named name: String) -> URL? {
        if let override = ProcessInfo.processInfo.environment["BROSIS_E9_RESOURCES"] {
            let u = URL(filePath: override).appending(path: name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appending(path: name)) }
        let exeDir = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appending(path: name))
        candidates.append(
            exeDir.appending(path: "brosis-e9_brosis-e9.bundle").appending(path: name))
        candidates.append(URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "tools/e9/Sources/brosis-e9/\(name)"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - JSON 输出

enum JSONOut {
    static func write(_ value: Any, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func string(_ value: Any) -> String {
        (try? String(
            data: JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .withoutEscapingSlashes]),
            encoding: .utf8)) ?? "{}"
    }
}

// MARK: - 小工具

func log(_ s: String) {
    let t = String(format: "%7.2fs", Proc.sinceStart)
    FileHandle.standardError.write("[\(t)] \(s)\n".data(using: .utf8)!)
}

func fail(_ s: String) -> Never {
    FileHandle.standardError.write("ERROR: \(s)\n".data(using: .utf8)!)
    exit(1)
}

extension Array where Element == Double {
    var mean: Double { isEmpty ? 0 : reduce(0, +) / Double(count) }
    var stdev: Double {
        guard count > 1 else { return 0 }
        let m = mean
        return (map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(count - 1)).squareRoot()
    }
    func percentile(_ p: Double) -> Double {
        guard !isEmpty else { return 0 }
        let s = sorted()
        let idx = Swift.max(0, Swift.min(s.count - 1, Int((Double(s.count - 1) * p).rounded())))
        return s[idx]
    }
}
