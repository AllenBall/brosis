/* brosis M1 / T2：BrosisCore 需要的一小段 C。
 *
 * Swift 侧不能直接 import CSqliteVec：sqlite-vec.h 在未定义 SQLITE_CORE 时会走
 * #include "sqlite3ext.h" 分支，把所有 sqlite3_* 宏重定义成 sqlite3_api->*，
 * 而 C 目标的 cSettings 不传播给依赖它的 Swift 目标。所以注册动作放在这里。
 */
#ifndef BROSIS_SQLITE_H
#define BROSIS_SQLITE_H

#include "sqlite3.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 用 volatile 写把一段内存清零，编译器不许优化掉。密钥与拼出来的 PRAGMA 缓冲区用它（3.5）。 */
void brosis_secure_zero(void *p, unsigned long n);

/* 把 sqlite-vec 注册成自动扩展（sqlite3_auto_extension），此后每条新连接都带 vec0。
 * D8 通过之前 BrosisCore 不调用它——sqlite-vec 只是静态编入、保证能链接（3.4）。 */
int brosis_register_vec(void);

/* sqlite-vec 的版本号，用来证明它确实被链接进来了（不需要开库）。 */
const char *brosis_vec_version(void);

/* SQLITE_TRANSIENT 在 Swift 里不能直接用（宏里是一个函数指针常量的强转）。 */
sqlite3_destructor_type brosis_transient(void);

#ifdef __cplusplus
}
#endif
#endif /* BROSIS_SQLITE_H */
