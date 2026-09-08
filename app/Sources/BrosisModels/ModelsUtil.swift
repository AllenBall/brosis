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
///
/// **为什么不直接用 `Bundle.module`**（M2 d 收尾修复的第一件事，原本是发布阻断项）：
/// SwiftPM 生成的 `Bundle.module` 访问器只查两处——
///   ① `Bundle.main.bundleURL/brosis_BrosisModels.bundle`（对 `.app` 来说是 `brosis.app/`
///      **这一层**，而 bundle 根目录下不能放东西，放了 `codesign` 就报 bundle format 不对）；
///   ② **编译时写死的那个绝对构建目录**。
/// 两处都不在时它 `Swift.fatalError`，进程当场 exit 133。`build_app.sh` 把资源 bundle 拷进
/// `Contents/Resources/`，不在这两处里，所以打包好的 `.app` 只是**借着构建目录**才没崩：
/// 把构建目录改名 / 删掉 / 换台机器，任何一次 `Bundle.module` 求值都会杀掉进程
/// （2026-09-08 实测：改名构建目录后 `--self-check` 在第 88 项 exit 133）。
///
/// 所以这里自己按顺序找目录，**`Bundle.module` 排在最后，而且只在先确认它一定命中时才碰**
/// （见 `safeModuleBundle`）。全部候选都没有时返回 `nil`，由调用方给一句能读的错误
/// （清单缺失 ⇒ 模型相关功能显示「未启用」），不是让进程死。
public enum ModelResources {
    /// 环境变量覆盖（测试与验收用）：指向一个**目录**。
    public static let overrideKey = "BROSIS_MODEL_RESOURCES"

    /// SwiftPM 给 `BrosisModels` 目标生成的资源 bundle 名。
    /// 命名规则是 `<包名>_<目标名>.bundle`；改包名或目标名时这里要跟着改，
    /// `build_app.sh` 的构建后闸门会把改漏了当场打红。
    public static let bundleName = "brosis_BrosisModels.bundle"

    /// 按优先级排好的候选**目录**。资源既可能在资源 bundle 里，也可能被
    /// `build_app.sh` 平铺拷了一份到 `Contents/Resources/`，所以每一处都给两个候选。
    ///
    /// 顺序（前面的赢）：
    ///   1. `BROSIS_MODEL_RESOURCES`；
    ///   2. `Bundle.main.resourceURL`（= `.app/Contents/Resources`，产品路径就走这一条）；
    ///   3. `Bundle.main.bundleURL`（裸可执行文件时就是它所在的目录，构建目录里直接跑走这条）；
    ///   4. 可执行文件所在目录的 `../Resources`（`brosis-embed` / `brosis-mcp` 待在
    ///      `Contents/MacOS/`，它们的 `Bundle.main` 是 `.app`，但**万一**不是也能兜住）；
    ///   5. 可执行文件所在目录本身；
    ///   6. `Bundle.main.bundleURL` 的上一级（`swift test` 时 `.xctest` 与资源 bundle
    ///      是构建目录里的兄弟）。
    public static func searchDirectories() -> [URL] {
        var roots: [URL] = []
        func addRoot(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            if !roots.contains(where: { $0.path == standardized.path }) { roots.append(standardized) }
        }
        if let override = ProcessInfo.processInfo.environment[overrideKey], !override.isEmpty {
            addRoot(URL(filePath: (override as NSString).expandingTildeInPath))
        }
        addRoot(Bundle.main.resourceURL)
        addRoot(Bundle.main.bundleURL)
        for exeDir in executableDirectories() {
            addRoot(exeDir.deletingLastPathComponent().appending(path: "Resources"))
            addRoot(exeDir)
        }
        addRoot(Bundle.main.bundleURL.deletingLastPathComponent())

        // 每个根目录先看资源 bundle，再看平铺的那一份。
        var out: [URL] = []
        for root in roots {
            out.append(root.appending(path: bundleName))
            out.append(root)
        }
        return out
    }

    /// 找一个随包资源。找不到返回 `nil`——**不 fatalError**。
    public static func url(named name: String) -> URL? {
        let fm = FileManager.default
        for directory in searchDirectories() {
            let candidate = directory.appending(path: name)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        // 最后一招：SwiftPM 的资源 bundle 访问器。上面的候选假定 bundle 是**平铺**的
        // （macOS 上 SwiftPM 现在就是这么生成的）；万一哪天换成 `Contents/Resources/`
        // 那种结构化布局，这一条还能救回来。只有确认它不会 fatalError 时才碰。
        guard let bundle = safeModuleBundle else { return nil }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return bundle.url(forResource: base, withExtension: ext.isEmpty ? nil : ext)
    }

    /// 找不到时给调用方的一句话：把真正试过的地方列出来，好让人一眼看出打包漏了什么。
    public static func notFoundMessage(named name: String) -> String {
        let tried = searchDirectories().map { $0.path }.joined(separator: "\n  ")
        return "找不到随包资源 \(name)。按顺序试过（环境变量 \(overrideKey) 可覆盖）：\n  " + tried
    }

    /// 只有在 SwiftPM 的访问器**一定**命中时才返回 `Bundle.module`，否则 `nil`。
    ///
    /// 访问器的第一候选是 `Bundle.main.bundleURL/<bundleName>`，第二候选是编译期写死的
    /// 构建目录——后者在运行期看不见，也不该去赌它还在（正是它让"离开构建机就崩"这件事
    /// 一直没被发现）。所以只认第一候选：它在，`Bundle.module` 就不会 fatalError；
    /// 它不在，宁可返回 `nil`。
    private static var safeModuleBundle: Bundle? {
        let accessorPath = Bundle.main.bundleURL.appending(path: bundleName)
        guard FileManager.default.fileExists(atPath: accessorPath.path) else { return nil }
        return Bundle.module
    }

    /// 可执行文件所在目录。两条来源都取（`Bundle.main.executableURL` 与 `argv[0]`），
    /// 因为命令行工具被 `PATH` 找到时 `argv[0]` 可能只是个名字。
    private static func executableDirectories() -> [URL] {
        var out: [URL] = []
        func add(_ url: URL?) {
            guard let url else { return }
            let dir = url.standardizedFileURL
            if !out.contains(where: { $0.path == dir.path }) { out.append(dir) }
        }
        add(Bundle.main.executableURL?.deletingLastPathComponent())
        if let argv0 = CommandLine.arguments.first, argv0.contains("/") {
            add(URL(filePath: argv0).deletingLastPathComponent())
        }
        return out
    }
}
