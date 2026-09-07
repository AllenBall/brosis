// swift-tools-version: 6.1
// brosis M0 / T8（E6）：SQLCipher 构建与密钥、数据边界验证包。
//
// 两条构建路线，用环境变量 BROSIS_SQLCIPHER_ROUTE 选择（默认 a）：
//   a = 依赖社区 SwiftPM 包 skiptools/swift-sqlcipher（自带 SQLCipher 合并源 + LibTomCrypt）
//   b = 自带 SQLCipher 源码作 C 目标（setup.sh 从 github.com/sqlcipher/sqlcipher 取源、
//       用树内 jimsh 生成 amalgamation，crypto 后端用 Apple CommonCrypto）
//
// 两条路线都把模块名暴露为 `SQLCipher`，所以 Sources/SQLCipherProbe 的 Swift 代码一字不改。
//
// 构建产物一律不落项目目录：
//   swift run --scratch-path ~/Library/Caches/brosis-build/sqlcipher/scratch-<route>
// 路线 b 的 C 源码也不落项目目录：RouteB/SQLCipher 是指向
// ~/Library/Caches/brosis-build/sqlcipher/vendor/route-b 的符号链接（setup.sh 创建）。
// Sources/CSqliteVec 同理，指向 vendor/sqlite-vec-target。

import PackageDescription
import Foundation

let route = (ProcessInfo.processInfo.environment["BROSIS_SQLCIPHER_ROUTE"] ?? "a").lowercased()

// ---------------------------------------------------------------- 路线 b 的编译开关
// 计划 3.5 / T8 要求：FTS5、DBSTAT_VTAB、HAS_CODEC、TEMP_STORE=2，SQLite ≥ 3.43。
// 其余开关对齐路线 a 的默认 trait 集，让两条路线的对比只反映 crypto 后端与版本差异。
let routeBCipherSettings: [CSetting] = [
    // —— T8 必须验证的四项 ——
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_ENABLE_DBSTAT_VTAB"),
    .define("SQLITE_HAS_CODEC"),
    .define("SQLITE_TEMP_STORE", to: "2"),
    // 必须显式给 NDEBUG。amalgamation 内部有一段"没定义 SQLITE_DEBUG 就自动 #define NDEBUG"，
    // 但 SwiftPM 的 C 目标是带 -fmodules 编的，crypto_cc.c 里 #include <CommonCrypto/...> 会触发
    // framework 模块导入，assert 宏按模块构建时的状态（未定义 NDEBUG）重新生效，那段自动 NDEBUG 就失效了，
    // 于是 SQLITE_DEBUG-only 的 assert 辅助函数变成"未声明函数"直接编译失败。
    // 顺带：SQLite 官方也建议发行版用 -DNDEBUG。
    .define("NDEBUG"),
    // —— SQLCipher 自身 ——
    .define("SQLCIPHER_CRYPTO_CC"),          // Apple CommonCrypto，走 ARMv8 AES 指令
    .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
    .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
    // —— 对齐路线 a 的默认集 ——
    .define("SQLITE_THREADSAFE", to: "1"),
    .define("SQLITE_DQS", to: "0"),
    .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
    .define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
    .define("SQLITE_LIKE_DOESNT_MATCH_BLOBS"),
    .define("SQLITE_MAX_EXPR_DEPTH", to: "0"),
    .define("SQLITE_OMIT_DEPRECATED"),
    .define("SQLITE_OMIT_PROGRESS_CALLBACK"),
    .define("SQLITE_USE_ALLOCA"),
    .define("SQLITE_STRICT_SUBTYPE", to: "1"),
    .define("SQLITE_ENABLE_MATH_FUNCTIONS"),
    .define("SQLITE_ENABLE_RTREE"),
    .define("SQLITE_ENABLE_STMTVTAB"),
    .define("SQLITE_ENABLE_STAT4"),
    .define("SQLITE_ENABLE_SNAPSHOT"),
    .define("SQLITE_ENABLE_COLUMN_METADATA"),   // GRDB 的一些 API 需要
    .define("SQLITE_ENABLE_PREUPDATE_HOOK"),    // GRDB 的 DatabaseObservation 需要
    .define("SQLITE_ENABLE_SESSION"),
    .define("SQLITE_ENABLE_API_ARMOR"),
    .define("SQLITE_ENABLE_UNKNOWN_SQL_FUNCTION"),
    .define("SQLITE_ENABLE_UNLOCK_NOTIFY"),
    .define("SQLITE_ENABLE_MEMORY_MANAGEMENT"),
    .define("SQLITE_SECURE_DELETE"),
    .define("SQLITE_USE_URI"),
    .define("SQLITE_MAX_VARIABLE_NUMBER", to: "250000"),
    .define("HAVE_ISNAN", to: "1"),
    .define("HAVE_USLEEP", to: "1"),
    .define("HAVE_UTIME", to: "1"),
    .define("HAVE_STDINT_H"),
    .define("HAVE_GETHOSTUUID", to: "0"),
    .define("SQLITE_OMIT_LOAD_EXTENSION", to: "0"),
]

var packageDeps: [Package.Dependency] = []
var cipherTargets: [Target] = []
let cipherDep: Target.Dependency

if route == "b" {
    cipherTargets.append(
        .target(
            name: "SQLCipher",
            path: "RouteB/SQLCipher",
            exclude: [],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: routeBCipherSettings,
            linkerSettings: [
                // crypto_cc.c 用 CommonCrypto（libSystem）+ SecRandomCopyBytes（Security.framework）
                .linkedFramework("Security"),
            ]
        )
    )
    cipherDep = .target(name: "SQLCipher")
} else {
    packageDeps.append(
        .package(url: "https://github.com/skiptools/swift-sqlcipher.git", exact: "1.9.0")
    )
    cipherDep = .product(name: "SQLCipher", package: "swift-sqlcipher")
}

let package = Package(
    name: "brosis-sqlcipher-probe",
    platforms: [.macOS("26.0")],
    dependencies: packageDeps,
    targets: cipherTargets + [
        // sqlite-vec 固定 v0.1.9，静态编进同一个包，用 SQLITE_CORE 走直接链接
        .target(
            name: "CSqliteVec",
            dependencies: [cipherDep],
            path: "Sources/CSqliteVec",
            sources: ["sqlite-vec.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),        // 不走扩展 API 指针表，直接链接
                .define("SQLITE_VEC_STATIC"),
                .define("SQLITE_VEC_OMIT_FS"), // 不要 npy 文件读取，避免任何文件路径
            ]
        ),
        // 统计型 VFS 垫片：在系统调用层证明"没有明文落盘""没有临时文件"
        .target(
            name: "CBrosisShim",
            dependencies: [cipherDep, "CSqliteVec"],
            path: "Sources/CBrosisShim",
            publicHeadersPath: "include",
            cSettings: [
                // 让 shim.c 里的 sqlite-vec.h 走 SQLITE_CORE 分支（直接链接，不用扩展 API 指针表）
                .define("SQLITE_CORE"),
            ]
        ),
        .executableTarget(
            name: "SQLCipherProbe",
            dependencies: [cipherDep, "CBrosisShim"],
            path: "Sources/SQLCipherProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
