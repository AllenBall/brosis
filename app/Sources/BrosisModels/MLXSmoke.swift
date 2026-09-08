import Foundation
import MLX

/// 真跑一次 GPU 运算，把「metallib 找不到 / 版本对不上」这类问题当场炸出来。
///
/// 背景（E9）：`swift build`（SwiftPM 命令行）**不编译 `.metal`**，
/// 不额外处理的话跑起来就是 `MLX error: Failed to load the default metallib`。
/// 正式构建由 `app/build_app.sh` 用 Metal Toolchain 现编 `mlx.metallib` 放进
/// `Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib`（**不能**放
/// `Contents/MacOS/`：那里的任何文件都被 codesign 当作嵌套代码，而 metallib 是 MTLB 格式、
/// 不是可签名的 Mach-O，必然报 “code object is not signed at all”）。
public enum MLXSmoke {

    /// 返回一份可直接塞进 JSON 的结果。跑不起来时 `ok = false` 并带上错误信息，不抛。
    public static func run() -> [String: Any] {
        let a = MLXArray([1.0, 2.0, 3.0, 4.0] as [Float])
        let b = MLXArray([10.0, 20.0, 30.0, 40.0] as [Float])
        let c = (a * b).sum()
        c.eval()
        let value = c.item(Float.self)
        return [
            "ok": value == 300,
            "value": Double(value),
            "expected": 300,
            "metallib": metallibPath() ?? "(未在已知位置找到；mlx 也可能从别处加载)",
        ]
    }

    /// 按 mlx 的查找顺序找 metallib，只作诊断信息用（找不到不代表跑不起来）。
    public static func metallibPath() -> String? {
        let exeDir = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent()
        var candidates: [URL] = [
            exeDir.appending(path: "mlx.metallib"),
            exeDir.appending(path: "Resources/mlx.metallib"),
            exeDir.appending(path: "default.metallib"),
        ]
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appending(path: "mlx-swift_Cmlx.bundle/default.metallib"))
            candidates.append(resources.appending(path: "default.metallib"))
        }
        candidates.append(exeDir.appending(path: "mlx-swift_Cmlx.bundle/default.metallib"))
        guard let hit = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else { return nil }
        // 只回相对位置，不回绝对路径（入库文件不得出现 /Users/<用户名> 之类）。
        return hit.pathComponents.suffix(3).joined(separator: "/")
    }
}
