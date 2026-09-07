// swift-tools-version: 6.1
// brosis M1 采集端（计划 3.1 / 3.3 / 3.5 / 3.12）。
//
// M1 起采集端不再自己开库：唯一持钥者是 ../core 的 BrosisCore（计划 3.1「单一存储服务」）。
// core 的清单用 swift-tools 6.1 且带 .unsafeFlags（关掉 SQLCipher amalgamation 的
// -Wambiguous-macro 噪声），所以只能以本地路径依赖引用——按版本解析的依赖不允许 unsafeFlags。
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
                .product(name: "BrosisCore", package: "core")
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
