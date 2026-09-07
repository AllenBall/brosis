// swift-tools-version: 6.1
// brosis M1 / T2：加密存储核心包。
//
// 对应 docs/实施计划.md 的 3.1（存储服务）、3.2（数据模型）、3.5（密钥）、3.8（保留与删除）、
// 3.12（app_policies），决策 D16 / D17 / D22 / D23 / D25。
//
// 构建产物一律不落项目目录（项目目录在同步盘里）：
//   swift build --package-path core -c release --scratch-path ~/Library/Caches/brosis-build/m1-core
// C 源码同理不进包：Vendor/SQLCipher 与 Vendor/SqliteVec 是指向 ~/Library/Caches/brosis-build/
// sqlcipher/vendor/ 的符号链接，由 core/setup.sh 创建。

import PackageDescription

// ---------------------------------------------------------------- SQLCipher 编译开关
// 直接沿用 M0 / E6 路线 b 实测通过的清单（tools/proto/sqlcipher/Package.swift 的
// routeBCipherSettings），只做三处改动，理由写在各自行上。
let sqlCipherSettings: [CSetting] = [
    // —— D25 要求的四项 ——
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_ENABLE_DBSTAT_VTAB"),
    .define("SQLITE_HAS_CODEC"),
    // 【改动 1 / D25】TEMP_STORE 从 2 改成 3：编译期强制临时存储在内存，PRAGMA 改不回文件。
    // E6 实测 temp_store=FILE 时一次全表排序会写出 22.64 MiB **明文**溢出文件，
    // 里面能命中金丝雀 73,494 次（tools/proto/results/sqlcipher_2026-09-07.md §6.3）。
    // 值 2 的语义只是"默认内存但 PRAGMA 可改回"，不够安全。
    .define("SQLITE_TEMP_STORE", to: "3"),
    // 必须显式给 NDEBUG。amalgamation 内部那段"没定义 SQLITE_DEBUG 就自动 #define NDEBUG"
    // 在 SwiftPM 的 -fmodules C 目标里会失效（crypto_cc.c 引入 CommonCrypto framework 模块时
    // assert 宏按模块构建时的状态重新生效），于是 SQLITE_DEBUG-only 的 assert 辅助函数
    // 变成"未声明函数"，直接编译失败。
    .define("NDEBUG"),
    // —— SQLCipher 自身 ——
    .define("SQLCIPHER_CRYPTO_CC"),          // Apple CommonCrypto，走 ARMv8 AES 指令（E6：写入 1.54× vs LibTomCrypt 4.45×）
    .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
    .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
    // —— 其余沿用 E6 路线 b ——
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
    // 【改动 2】去掉 SQLITE_ENABLE_COLUMN_METADATA 与 SQLITE_ENABLE_PREUPDATE_HOOK。
    // 这两项在 E6 里是为"将来接 GRDB"打开的（前者供 Database.columnInfo，后者供 ValueObservation）。
    // D25 已定 M1 不上 GRDB、先用薄 C API 封装，BrosisCore 一行都没用到这两个 API，
    // 留着只是白白增大二进制与 API 面。M2 若真的接 GRDB，把这两行加回来即可，是纯增量改动。
    .define("SQLITE_ENABLE_SESSION"),
    .define("SQLITE_ENABLE_API_ARMOR"),
    .define("SQLITE_ENABLE_UNKNOWN_SQL_FUNCTION"),
    .define("SQLITE_ENABLE_UNLOCK_NOTIFY"),
    .define("SQLITE_ENABLE_MEMORY_MANAGEMENT"),
    .define("SQLITE_SECURE_DELETE"),        // 3.8：逻辑删除后覆写页内残留
    .define("SQLITE_USE_URI"),
    .define("SQLITE_MAX_VARIABLE_NUMBER", to: "250000"),
    .define("HAVE_ISNAN", to: "1"),
    .define("HAVE_USLEEP", to: "1"),
    .define("HAVE_UTIME", to: "1"),
    .define("HAVE_STDINT_H"),
    .define("HAVE_GETHOSTUUID", to: "0"),
    .define("SQLITE_OMIT_LOAD_EXTENSION", to: "0"),
    // 【改动 3 已删除，M1 R2 恢复成"没有任何 unsafeFlags"】
    // 原来这里有一行 `.unsafeFlags(["-Wno-ambiguous-macro"])`，用来关掉 amalgamation 与
    // SDK 的 sys/param.h 各有一份 MIN / MAX 引起的 68 处 -Wambiguous-macro。
    // 代价是**整个包不能被按版本解析的依赖引用**（SwiftPM 对 unsafeFlags 的硬规则）。
    // 现在改成调整包含顺序：Sources/CSQLCipher/sqlcipher_amalgamation.c 先 #include <sys/param.h>
    // 再 #include 上游的 sqlite3.c，后到的本地定义覆盖先到的模块宏，警告自然消失。
    // 上游源码没有改动，编译开关也没有变。理由写在那个文件的注释里。
]

let package = Package(
    name: "brosis-core",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BrosisCore", targets: ["BrosisCore"]),
        // 本地 IPC 协议 + socket 客户端 / 服务端（3.1）。app 与 brosis-mcp 都用它；
        // 它自己**不依赖 BrosisCore**，所以 brosis-mcp 里没有 SQLCipher、没有任何开库能力。
        .library(name: "BrosisIPC", targets: ["BrosisIPC"]),
        .executable(name: "brosis-store", targets: ["brosis-store"]),
        // 3.6 的薄 MCP（stdio）。不持钥、不开库、不写库，只把 tools/call 转成 IPC 请求。
        .executable(name: "brosis-mcp", targets: ["brosis-mcp"]),
    ],
    targets: [
        // SQLCipher v4.18.0 amalgamation。
        // 源码在构建缓存里（Vendor/SQLCipher 是符号链接），本目标只编一个包装文件
        // Sources/CSQLCipher/sqlcipher_amalgamation.c，由它 #include 上游的 sqlite3.c——
        // 只为了把 <sys/param.h> 的引入提到前面，见那个文件的注释（替代原来的 unsafeFlags）。
        // Sources/CSQLCipher/include 也是符号链接，指向 Vendor/SQLCipher/include（只有 sqlite3.h）。
        .target(
            name: "SQLCipher",
            path: "Sources/CSQLCipher",
            sources: ["sqlcipher_amalgamation.c"],
            publicHeadersPath: "include",   // 只暴露 sqlite3.h；sqlite3ext.h 留在私有的 Vendor/.../src/
            cSettings: sqlCipherSettings,
            linkerSettings: [
                // crypto_cc.c 用 CommonCrypto（libSystem）+ SecRandomCopyBytes（Security.framework）
                .linkedFramework("Security"),
            ]
        ),
        // sqlite-vec v0.1.9：静态编入，D8 通过前不注册、不建表，只保证能链接（3.4）
        .target(
            name: "CSqliteVec",
            dependencies: ["SQLCipher"],
            path: "Vendor/SqliteVec",
            sources: ["sqlite-vec.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("SQLITE_CORE"),        // 直接链接，不走扩展 API 指针表
                .define("SQLITE_VEC_STATIC"),
                .define("SQLITE_VEC_OMIT_FS"), // 不要 npy 文件读取，避免任何文件路径
            ]
        ),
        // 薄 C 垫片：volatile 清零 + sqlite-vec 注册入口。
        // Swift 侧不能直接 import CSqliteVec —— sqlite-vec.h 在未定义 SQLITE_CORE 时会走
        // #include "sqlite3ext.h" 分支，把所有 sqlite3_* 宏重定义成 sqlite3_api->*，
        // 而 C 目标的 cSettings 不会传播给依赖它的 Swift 目标。
        .target(
            name: "CBrosisSQLite",
            dependencies: ["SQLCipher", "CSqliteVec"],
            path: "Sources/CBrosisSQLite",
            publicHeadersPath: "include",
            cSettings: [.define("SQLITE_CORE")]
        ),
        // 本地 IPC：协议类型、换行分隔 JSON 编解码、Unix domain socket 客户端 / 服务端、
        // 对端 uid 与代码签名校验、按客户端限流。**不依赖 BrosisCore**（见 products 的注释）。
        .target(
            name: "BrosisIPC",
            path: "Sources/BrosisIPC",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // SecCodeCopyGuestWithAttributes / SecCodeCheckValidity（对端签名校验）
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "BrosisCore",
            dependencies: ["SQLCipher", "CBrosisSQLite", "BrosisIPC"],
            path: "Sources/BrosisCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "brosis-store",
            dependencies: ["BrosisCore", "BrosisIPC"],
            path: "Sources/brosis-store",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // 只依赖 BrosisIPC：编译期就保证它拿不到 Store、拿不到密钥。
        .executableTarget(
            name: "brosis-mcp",
            dependencies: ["BrosisIPC"],
            path: "Sources/brosis-mcp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BrosisCoreTests",
            dependencies: ["BrosisCore", "BrosisIPC", "SQLCipher"],
            path: "Tests/BrosisCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
