// swift-tools-version: 6.1
// brosis M1 采集端（计划 3.1 / 3.3 / 3.5 / 3.12）。
//
// M1 起采集端不再自己开库：唯一持钥者是 ../core 的 BrosisCore（计划 3.1「单一存储服务」）。
// 这里用本地路径依赖，是因为 core 与 app 是同一个仓库里一起演进的两个包（core 没有独立版本）；
// core 的清单**不带任何 .unsafeFlags**（M1 R2 已去掉），所以它并没有被限制成只能路径引用。
//
// 构建产物不落项目目录：一律 --scratch-path ~/Library/Caches/brosis-build/m1-app/

import PackageDescription

let package = Package(
    name: "brosis",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../core")
    ],
    targets: [
        .executableTarget(
            name: "brosis",
            dependencies: [
                .product(name: "BrosisCore", package: "core"),
                .product(name: "BrosisIPC", package: "core")
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
        )
    ]
)
