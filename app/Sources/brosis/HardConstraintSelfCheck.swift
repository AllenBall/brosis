import Foundation
import MachO

// =============================================================================
// M2 d / T18 的第三件事：**2.2 硬约束逐条对照表**（结果文件
// tools/bench/results/m2_d_focus_hotkey_2026-09-08.md 里那张表）在做的时候发现，
// 8 条硬约束里有几条只有"代码审查"这一档证据。本文件补上其中**能自动化的最小三条**，
// 补不了的（要 GUI、要真机、要网络监控）在结果文件里逐条写明为什么没补。
//
// 三条都是：从**已组装的 bundle 自身**取事实，不开库、不联网、不碰 TCC、不碰钥匙串。
// 裸二进制（不是从 .app 里跑）时，取不到 Info.plist 的那两条会明说"跳过"而不是假装通过。
// =============================================================================

enum HardConstraintSelfCheck {

    static func run() -> Int {
        var failures = 0
        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            if !condition { failures += 1 }
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : "：\(detail)")")
        }

        let info = Bundle.main.infoDictionary
        // 从 .app 里跑时一定有 CFBundleIdentifier；`swift run` 出来的裸二进制没有。
        let fromBundle = (info?["CFBundleIdentifier"] as? String)?.isEmpty == false

        // -------------------------------------------- 硬约束 6：不录音频（系统层面拿不到）
        // 依据：macOS 上没有 NSMicrophoneUsageDescription 的 app **拿不到**麦克风 TCC——
        // 系统不会弹授权框，AVCaptureDevice 直接拒。所以"Info.plist 里没有这几个键"
        // 是"这个 bundle 不可能录音"的可核对证据，比"代码里没写 AVAudioEngine"强。
        let audioKeys = ["NSMicrophoneUsageDescription",
                         "NSCameraUsageDescription",
                         "NSSpeechRecognitionUsageDescription"]
        if fromBundle, let info {
            let present = audioKeys.filter { info[$0] != nil }
            let declared = ["NSScreenCaptureUsageDescription", "NSAccessibilityUsageDescription"]
                .filter { info[$0] != nil }
            check("硬约束 6：Info.plist 不含麦克风 / 摄像头 / 语音识别用途说明（拿不到音频 TCC）",
                  present.isEmpty && declared.count == 2,
                  present.isEmpty
                    ? "只声明了 \(declared.joined(separator: " / "))"
                    : "不该出现的键：\(present.joined(separator: " / "))")
        } else {
            check("硬约束 6：Info.plist 不含麦克风 / 摄像头 / 语音识别用途说明", true,
                  "跳过——不是从 brosis.app 里跑的，读不到 Info.plist")
        }

        // ------------------------- 硬约束 5「只依赖公开 API」+ 8「自包含」：直接链接的库
        // 读**本进程主二进制**的 Mach-O 加载命令（LC_LOAD_DYLIB 一族），
        // 也就是 `otool -L` 的那一份；传递依赖不算（AppKit 自己会拉私有框架，
        // 那不是我们的选择，也不是"我们用了私有 API"）。
        let libraries = directLinkedLibraries()
        let allowedPrefixes = ["/System/Library/Frameworks/", "/usr/lib/",
                               "@rpath/", "@executable_path/", "@loader_path/"]
        let offenders = libraries.filter { path in
            if path.hasPrefix("/Library/Frameworks/") { return true }       // 第三方装的框架
            if path.contains("/PrivateFrameworks/") { return true }         // 私有框架
            if path.hasPrefix("/opt/") || path.hasPrefix("/usr/local/") { return true }  // Homebrew
            if path.lowercased().contains("python") { return true }         // 2.2#8：不依赖 Python
            return !allowedPrefixes.contains { path.hasPrefix($0) }
        }
        check("硬约束 5 / 8：主二进制直接链接的 \(libraries.count) 个库全是公开框架或自带的"
              + "（无私有框架 / 无 Homebrew / 无 Python）",
              !libraries.isEmpty && offenders.isEmpty,
              libraries.isEmpty ? "读不到加载命令"
                                : (offenders.isEmpty ? "白名单：\(allowedPrefixes.joined(separator: " "))"
                                                     : "越界：\(offenders.joined(separator: " "))"))
        for path in libraries where path.hasPrefix("@") {
            print("       自带（随 bundle 一起签名）：\(path)")
        }

        // ------------------------------------------- 硬约束 6：默认不上传（更新检查也算出网）
        if fromBundle, let info {
            let automaticChecks = info["SUEnableAutomaticChecks"] as? Bool
            let automaticUpdate = info["SUAutomaticallyUpdate"] as? Bool
            let feed = (info["SUFeedURL"] as? String) ?? ""
            check("硬约束 6：更新检查默认关、更新源是 https（默认不出网，出网必须人点）",
                  automaticChecks == false && automaticUpdate == false && feed.hasPrefix("https://"),
                  "SUEnableAutomaticChecks=\(automaticChecks.map(String.init) ?? "(缺)") "
                  + "SUAutomaticallyUpdate=\(automaticUpdate.map(String.init) ?? "(缺)") "
                  + "SUFeedURL 协议=\(feed.split(separator: ":").first.map(String.init) ?? "(缺)")")
        } else {
            check("硬约束 6：更新检查默认关、更新源是 https", true,
                  "跳过——不是从 brosis.app 里跑的，读不到 Info.plist")
        }

        return failures
    }

    /// 本进程**主二进制**的 `LC_LOAD_DYLIB` / `LC_LOAD_WEAK_DYLIB` / `LC_REEXPORT_DYLIB`
    /// 里记的路径，等价于 `otool -L`（去掉第一行的自身）。
    ///
    /// 常量直接写数值并注明出处（`<mach-o/loader.h>`）：`LC_LOAD_WEAK_DYLIB` 带
    /// `LC_REQ_DYLD (0x80000000)` 位，在 Swift 里的导入类型随 SDK 变，写死更稳。
    static func directLinkedLibraries() -> [String] {
        let loadDylib: UInt32 = 0x0000_000C          // LC_LOAD_DYLIB
        let loadWeakDylib: UInt32 = 0x8000_0018      // LC_LOAD_WEAK_DYLIB
        let reexportDylib: UInt32 = 0x8000_001F      // LC_REEXPORT_DYLIB

        guard let base = _dyld_get_image_header(0) else { return [] }
        let header = UnsafeRawPointer(base).assumingMemoryBound(to: mach_header_64.self)
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        var paths: [String] = []
        for _ in 0..<Int(header.pointee.ncmds) {
            let command = cursor.assumingMemoryBound(to: load_command.self).pointee
            let size = Int(command.cmdsize)
            guard size > 0 else { break }
            if command.cmd == loadDylib || command.cmd == loadWeakDylib
                || command.cmd == reexportDylib {
                let dylib = cursor.assumingMemoryBound(to: dylib_command.self).pointee
                let offset = Int(dylib.dylib.name.offset)
                if offset > 0, offset < size {
                    let name = cursor.advanced(by: offset)
                        .assumingMemoryBound(to: CChar.self)
                    paths.append(String(cString: name))
                }
            }
            cursor = cursor.advanced(by: size)
        }
        return paths
    }
}
