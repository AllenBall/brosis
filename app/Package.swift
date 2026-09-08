// swift-tools-version: 6.1
// brosis M1 采集端（计划 3.1 / 3.3 / 3.5 / 3.12）。
//
// M1 起采集端不再自己开库：唯一持钥者是 ../core 的 BrosisCore（计划 3.1「单一存储服务」）。
// 这里用本地路径依赖，是因为 core 与 app 是同一个仓库里一起演进的两个包（core 没有独立版本）；
// core 的清单**不带任何 .unsafeFlags**（M1 R2 已去掉），所以它并没有被限制成只能路径引用。
//
// 构建产物不落项目目录：一律 --scratch-path ~/Library/Caches/brosis-build/m1-app/
//
// 唯一的外部依赖是 Sparkle 2（自动更新）。SwiftPM 把 Sparkle.framework 拷到 bin 目录，
// build_app.sh 再把它放进 brosis.app/Contents/Frameworks/ 并逐个签内嵌代码。
// 主程序的 rpath 由 build_app.sh 用 install_name_tool 补 @executable_path/../Frameworks
// （不用 .unsafeFlags：带 unsafeFlags 的清单不能被别的包按版本引用）。

import PackageDescription

let package = Package(
    name: "brosis",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../core"),
        // Sparkle 2 签名更新（计划 4.2「签名更新」）。固定到确切版本，不用区间：
        // 更新框架换版本必须是一次显式决定，Package.resolved 里再钉一次 revision。
        // 它是 binaryTarget（Sparkle.xcframework），下载后落在 --scratch-path 的
        // artifacts/ 下，不进项目目录。
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
        // M2 c / T11：本地推理运行时（3.10「本地实现走 mlx-swift」、3.11 模型管理器）。
        // 版本**固定**到 E9 实测过的那两个（tools/e9/README.md 的依赖表），不用区间。
        // 放在 app 包而不是 core 包，理由见 Sources/BrosisModels 的头注释与
        // tools/bench/results/m2_c_vectors_2026-09-08.md 的「二选一」一节：
        // core 要保持零 mlx 依赖，`swift test --package-path core` 才不必解析、编译 mlx-swift。
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4")
    ],
    targets: [
        // M2 c / T11：模型管理器 + 本地嵌入运行时（3.11 / D18 / D27）。
        // 清单 catalog.json 随包，运行时**不联网拉清单**。
        .target(
            name: "BrosisModels",
            dependencies: [
                .product(name: "BrosisCore", package: "core"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // M2 c / T12：可选叙述（4.3 / D19）要的因果语言模型运行时。
                // 与 tools/e9 的 generate 子命令用的是同一个产品、同一个 3.31.4。
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/BrosisModels",
            resources: [.copy("catalog.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "brosis",
            dependencies: [
                .product(name: "BrosisCore", package: "core"),
                .product(name: "BrosisIPC", package: "core"),
                // D17 / 3.9 跨设备同步（M2 c / T13）：段文件格式、加密、同步目录与两个循环。
                .product(name: "BrosisSync", package: "core"),
                .product(name: "Sparkle", package: "Sparkle"),
                "BrosisModels"
            ],
            path: "Sources/brosis",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Carbon")
            ]
        ),
        // M2 c / T11：嵌入任务与查询向量的命令行入口，供 tools/eval 的 D8 实验与验收使用。
        // 它**不是**产品的一部分（产品路径是 app 里的夜间调度器），但会随 .app 打包，
        // 这样验收者拿签名后的 bundle 就能重放整套实验。
        .executableTarget(
            name: "brosis-embed",
            dependencies: [
                .product(name: "BrosisCore", package: "core"),
                // M2 d / T15：`serve-search` 要起一个真的 IPC 服务端（与产品同款），
                // 好让 brosis-mcp / 评估脚本在没有 GUI 的机器上走真实的 MCP 路径。
                .product(name: "BrosisIPC", package: "core"),
                "BrosisModels"
            ],
            path: "Sources/brosis-embed",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
