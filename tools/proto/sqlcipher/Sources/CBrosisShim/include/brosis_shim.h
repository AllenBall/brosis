/* brosis M0 / T8（E6）：一个只做统计的 SQLite VFS 垫片。
 *
 * 目的：在系统调用层面证明两件事，而不是靠事后 grep 文件。
 *   1) SQLCipher 打开的库，任何经 xWrite 落盘的字节里都不含已知明文标记；
 *   2) temp_store = MEMORY 时，排序 / 中间结果不会触发任何临时文件的 xOpen。
 *
 * 用法：brosis_shim_register() 必须在第一次 sqlite3_open_v2 之前调用一次，
 * 它把 "brosisspy" 注册成默认 VFS，并把真实 VFS（unix）包在下面转发。
 */
#ifndef BROSIS_SHIM_H
#define BROSIS_SHIM_H

#include "sqlite3.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 文件类别，和 brosis_shim_counts() 的下标一一对应 */
#define BROSIS_KIND_MAIN_DB       0
#define BROSIS_KIND_MAIN_JOURNAL  1
#define BROSIS_KIND_WAL           2
#define BROSIS_KIND_TEMP_DB       3
#define BROSIS_KIND_TEMP_JOURNAL  4
#define BROSIS_KIND_TRANSIENT_DB  5
#define BROSIS_KIND_SUBJOURNAL    6
#define BROSIS_KIND_SUPER_JOURNAL 7
#define BROSIS_KIND_OTHER         8
#define BROSIS_KIND_COUNT         9

/* 把 sqlite-vec 注册成自动扩展（sqlite3_auto_extension），此后每个新连接都带 vec0。
 * 放在 C 侧是因为 sqlite-vec.h 在未定义 SQLITE_CORE 时会走 sqlite3ext.h 分支，
 * 不适合让 Swift 直接 import。 */
int  brosis_register_vec(void);

/* 用 volatile 写把一段内存清零，编译器不许优化掉。锁定状态机的密钥清零用它。 */
void brosis_secure_zero(void *p, unsigned long n);

/* 注册并设为默认 VFS；重复调用无副作用。成功返回 SQLITE_OK。 */
int  brosis_shim_register(void);

/* 登记一个明文标记（UTF-8 字节串）。每次 xWrite 都会在缓冲区里找它。 */
int  brosis_shim_add_marker(const char *bytes, int nbyte);

/* 清零全部计数（不清标记）。 */
void brosis_shim_reset(void);

/* 取某一类别的计数。kind 用上面的宏。 */
long long brosis_shim_opens(int kind);
long long brosis_shim_writes(int kind);
long long brosis_shim_bytes(int kind);
long long brosis_shim_marker_hits(int kind);

/* 全部类别的 xOpen 次数之和，方便断言。 */
long long brosis_shim_total_marker_hits(void);
long long brosis_shim_temp_opens(void);   /* TEMP_DB + TEMP_JOURNAL + TRANSIENT_DB + SUBJOURNAL */
long long brosis_shim_temp_bytes(void);

#ifdef __cplusplus
}
#endif
#endif /* BROSIS_SHIM_H */
