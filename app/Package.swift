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
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "brosis",
            dependencies: [
                .product(name: "BrosisCore", package: "core"),
                .product(name: "BrosisIPC", package: "core"),
                .product(name: "Sparkle", package: "Sparkle")
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
