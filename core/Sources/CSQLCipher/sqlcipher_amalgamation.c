// SQLCipher amalgamation 的**唯一编译单元**。
//
// 为什么不直接把 Vendor/SQLCipher/src 当作 target 的 sources：只为了两行 #include 的顺序。
//
// 上游 amalgamation 在第 ~15915 行定义了自己的 MIN / MAX（带 `#ifndef` 保护），
// 之后在 unix VFS 那段（`#if SQLITE_ENABLE_LOCKING_STYLE`，Apple 平台默认为 1）
// 才 `#include <sys/param.h>`，而 SDK 的 sys/param.h 里也有一份 MIN / MAX。
// SwiftPM 的 C 目标是带模块（`-fmodules`）编的，sys/param.h 的那份是**模块宏**：
// 模块宏在本文件已有一份文本定义**之后**才被引入，clang 认为两份定义都可见且不一致，
// 于是对 68 处 MIN / MAX 调用报 `-Wambiguous-macro`（两份定义语义完全相同，纯噪声）。
//
// 把 <sys/param.h> 提到 amalgamation **之前**引入，顺序就反过来了：
// 模块宏先到，amalgamation 里那份文本定义后到 —— 后到的本地定义直接覆盖模块宏，
// 不再有"两份都可见"的歧义，警告消失，一行 `.unsafeFlags(["-Wno-ambiguous-macro"])` 也就不用了
// （`.unsafeFlags` 会让整个包不能被按版本解析的依赖引用）。
//
// 上游源码一个字节都没改（它是 core/setup.sh 从上游生成的，也不该改）；
// 编译开关仍然全部由 Package.swift 的 `sqlCipherSettings` 给。
// 引号包含的相对路径按**本文件所在目录**解析，所以不需要任何 header search path。
#include <sys/param.h>

#include "../../Vendor/SQLCipher/src/sqlite3.c"
