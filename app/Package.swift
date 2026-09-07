// swift-tools-version: 6.0
// brosis M0 采集骨架（计划 E4 / 3.1，报告 3.3–3.4）
// 构建产物不落在项目目录：一律用 --scratch-path ~/Library/Caches/brosis-build/app/

import PackageDescription

let package = Package(
    name: "brosis",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "brosis",
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
