// brosis M0 / T8（E6）：入口。全部逻辑在 Probe.swift。
import Foundation

do {
    try Probe.main()
} catch {
    FileHandle.standardError.write("失败：\(error)\n".data(using: .utf8)!)
    exit(1)
}
