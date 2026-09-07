// swift-tools-version: 6.1
// brosis M0 · E9 内嵌推理运行时与分发验证（计划 4.1 E9 / 3.11 / D18 / D19）
//
// 构建产物一律不落在项目目录（iCloud Drive）：
//   swift build --package-path tools/e9 --scratch-path ~/Library/Caches/brosis-build/e9
//
// 依赖锁定（2026-09-07 解析）：
//   ml-explore/mlx-swift-lm 3.31.4  -> MLXEmbedders / MLXLMCommon / MLXLLM
//   huggingface/swift-transformers 1.3.4 -> Tokenizers（自己写 TokenizerLoader 适配器，
//     不用 MLXHuggingFace 宏，省掉 swift-syntax 宏插件与 swift-huggingface 下载器）
//   mlx-swift 由 mlx-swift-lm 传递引入（0.31.x）

import PackageDescription

let package = Package(
    name: "brosis-e9",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "brosis-e9", targets: ["brosis-e9"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        .executableTarget(
            name: "brosis-e9",
            dependencies: [
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/brosis-e9",
            resources: [
                .copy("catalog.json"),
                .copy("corpus.json")
            ]
        )
    ]
)
