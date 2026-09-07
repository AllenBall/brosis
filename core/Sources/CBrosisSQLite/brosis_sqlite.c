/* brosis M1 / T2：见 include/brosis_sqlite.h。 */
#include "brosis_sqlite.h"
#include "sqlite-vec.h"

void brosis_secure_zero(void *p, unsigned long n){
  volatile unsigned char *q = (volatile unsigned char*)p;
  while(n--) *q++ = 0;
}

int brosis_register_vec(void){
  /* sqlite3_auto_extension 的入口点类型是 void(*)(void)，官方示例也是这样强转的。 */
  return sqlite3_auto_extension((void(*)(void))sqlite3_vec_init);
}

const char *brosis_vec_version(void){
  return SQLITE_VEC_VERSION;
}

sqlite3_destructor_type brosis_transient(void){
  return SQLITE_TRANSIENT;
}
