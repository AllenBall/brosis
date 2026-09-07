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

if arguments.contains("--dump-ocr") {
    exit(OCRDump.run())
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)   // 与 Info.plist 的 LSUIElement=1 一致
application.run()
