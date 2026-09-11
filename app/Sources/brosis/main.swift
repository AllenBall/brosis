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

// D33：MCP 集成的命令行入口。brosis 是 LSUIElement，自动化工具看不见它的窗口，
// 所以同一套逻辑给一个能脚本化的入口（跑的是和窗口一样的 MCPIntegration）。
if arguments.contains("--mcp") {
    exit(MCPIntegrationCLI.run(arguments))
}

if arguments.contains("--dump-vectors") {
    exit(VectorDump.run())
}

// M2 c / T12：用**真实模型**跑一次叙述。故意不进 --self-check（要 8–30 s，见文件头）。
if arguments.contains("--narrative-smoke") {
    exit(NarrativeSmoke.run())
}

if arguments.contains("--key-status") {
    exit(KeyStatus.run())
}

if arguments.contains("--dump-ocr") {
    exit(OCRDump.run())
}

// `--ax-probe [bundle id ...]`：量 Electron 应用的 AX 树要多久才有内容。
// 不给 bundle id 就探所有正在运行的 Chromium 系应用。
// 再加 `--dump-webarea [<AXTitle>|all]` 就不取样，改成把 AXWebArea 的子树逐节点打出来。
if let index = arguments.firstIndex(of: "--ax-probe") {
    var rest = Array(arguments[(index + 1)...])
    var dumpWebArea: String?
    if let dumpIndex = rest.firstIndex(of: "--dump-webarea") {
        rest.remove(at: dumpIndex)
        if dumpIndex < rest.count, !rest[dumpIndex].hasPrefix("--") {
            dumpWebArea = rest.remove(at: dumpIndex)
        } else {
            dumpWebArea = "all"
        }
    }
    exit(AXProbe.run(bundleIDs: rest.filter { !$0.hasPrefix("--") }, dumpWebArea: dumpWebArea))
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)   // 与 Info.plist 的 LSUIElement=1 一致
application.run()
