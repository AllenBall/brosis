import AppKit
import Foundation

// 入口。--self-check 与 --version 都不创建 NSApplication、不碰任何 TCC API。
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print("brosis \(BuildInfo.version)（\(BuildInfo.stage)，bundle id \(BuildInfo.bundleIdentifier)）")
    exit(0)
}

if arguments.contains("--self-check") {
    exit(SelfCheck.run())
}

if arguments.contains("--dump-vectors") {
    exit(VectorDump.run())
}

// M2 c / T12：用**真实模型**跑一次叙述。故意不进 --self-check（要 8–30 s，见文件头）。
if arguments.contains("--narrative-smoke") {
    exit(NarrativeSmoke.run())
}

if arguments.contains("--dump-ocr") {
    exit(OCRDump.run())
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)   // 与 Info.plist 的 LSUIElement=1 一致
application.run()
