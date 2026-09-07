/* brosis M0 / T8（E6）：统计型 VFS 垫片实现。见 include/brosis_shim.h。 */
#include "brosis_shim.h"
#include "sqlite-vec.h"
#include <string.h>
#include <stdlib.h>

#define MAX_MARKERS 8

typedef struct SpyFile SpyFile;
struct SpyFile {
  sqlite3_file base;      /* 必须是第一个成员 */
  int kind;
  sqlite3_file *real;     /* 紧跟在本结构体后面的真实 file 对象 */
};

static struct {
  long long opens[BROSIS_KIND_COUNT];
  long long writes[BROSIS_KIND_COUNT];
  long long bytes[BROSIS_KIND_COUNT];
  long long hits[BROSIS_KIND_COUNT];
  int   nmarker;
  unsigned char *marker[MAX_MARKERS];
  int   markerLen[MAX_MARKERS];
} g;

static sqlite3_vfs *gReal = 0;
static sqlite3_vfs  gSpy;
static int gRegistered = 0;

static int kindOf(int flags){
  if( flags & SQLITE_OPEN_MAIN_DB )       return BROSIS_KIND_MAIN_DB;
  if( flags & SQLITE_OPEN_MAIN_JOURNAL )  return BROSIS_KIND_MAIN_JOURNAL;
  if( flags & SQLITE_OPEN_WAL )           return BROSIS_KIND_WAL;
  if( flags & SQLITE_OPEN_TEMP_DB )       return BROSIS_KIND_TEMP_DB;
  if( flags & SQLITE_OPEN_TEMP_JOURNAL )  return BROSIS_KIND_TEMP_JOURNAL;
  if( flags & SQLITE_OPEN_TRANSIENT_DB )  return BROSIS_KIND_TRANSIENT_DB;
  if( flags & SQLITE_OPEN_SUBJOURNAL )    return BROSIS_KIND_SUBJOURNAL;
  if( flags & SQLITE_OPEN_SUPER_JOURNAL ) return BROSIS_KIND_SUPER_JOURNAL;
  return BROSIS_KIND_OTHER;
}

/* 朴素子串搜索。缓冲区是页大小量级（16 KiB），标记只有几个，够用。 */
static long long scanMarkers(const void *buf, int n){
  const unsigned char *p = (const unsigned char*)buf;
  long long hits = 0;
  int i, m;
  for(m=0; m<g.nmarker; m++){
    int L = g.markerLen[m];
    if( L<=0 || n<L ) continue;
    for(i=0; i+L<=n; i++){
      if( p[i]==g.marker[m][0] && memcmp(p+i, g.marker[m], (size_t)L)==0 ) hits++;
    }
  }
  return hits;
}

/* ---------------- sqlite3_io_methods 转发 ---------------- */

static int spyClose(sqlite3_file *pF){
  SpyFile *p = (SpyFile*)pF;
  int rc = SQLITE_OK;
  if( p->real->pMethods ) rc = p->real->pMethods->xClose(p->real);
  p->base.pMethods = 0;
  return rc;
}
static int spyRead(sqlite3_file *pF, void *z, int n, sqlite3_int64 off){
  SpyFile *p = (SpyFile*)pF;
  return p->real->pMethods->xRead(p->real, z, n, off);
}
static int spyWrite(sqlite3_file *pF, const void *z, int n, sqlite3_int64 off){
  SpyFile *p = (SpyFile*)pF;
  g.writes[p->kind]++;
  g.bytes[p->kind] += n;
  g.hits[p->kind]  += scanMarkers(z, n);
  return p->real->pMethods->xWrite(p->real, z, n, off);
}
static int spyTruncate(sqlite3_file *pF, sqlite3_int64 sz){
  SpyFile *p = (SpyFile*)pF;
  return p->real->pMethods->xTruncate(p->real, sz);
}
static int spySync(sqlite3_file *pF, int flags){
  SpyFile *p = (SpyFile*)pF;
  return p->real->pMethods->xSync(p->real, flags);
}
static int spyFileSize(sqlite3_file *pF, sqlite3_int64 *pSize){
  SpyFile *p = (SpyFile*)pF;
  return p->real->pMethods->xFileSize(p->real, pSize);
}
static int spyLock(sqlite3_file *pF, int lock){
  SpyFile *p = (SpyFile*)pF;
  return p->real->pMethods->xLock(p->real, lock);
}
static int spyUnlock(sqlite3_file *pF, int lock){
  SpyFile *p = (SpyFile*)pF;
  return p->real->pMethods->xUnlock(p->real, lock);
}
static int spyCheckReservedLock(sqlite3_file *pF, int *pRes){
  SpyFile *p = (SpyFile*)pF;
  return p->real->pMethods->xCheckReservedLock(p->real, pRes);
}
static int spyFileControl(sqlite3_file *pF, int op, void *pArg){
  SpyFile *p = (SpyFile*)pF;
  return p->real->pMethods->xFileControl(p->real, op, pArg);
}
static int spySectorSize(sqlite3_file *pF){
  SpyFile *p = (SpyFile*)pF;
  return p->real->pMethods->xSectorSize(p->real);
}
static int spyDeviceCharacteristics(sqlite3_file *pF){
  SpyFile *p = (SpyFile*)pF;
  return p->real->pMethods->xDeviceCharacteristics(p->real);
}
static int spyShmMap(sqlite3_file *pF, int iPg, int pgsz, int b, void volatile **pp){
  SpyFile *p = (SpyFile*)pF;
  if( p->real->pMethods->iVersion<2 || !p->real->pMethods->xShmMap ) return SQLITE_IOERR_SHMMAP;
  return p->real->pMethods->xShmMap(p->real, iPg, pgsz, b, pp);
}
static int spyShmLock(sqlite3_file *pF, int offset, int n, int flags){
  SpyFile *p = (SpyFile*)pF;
  if( p->real->pMethods->iVersion<2 || !p->real->pMethods->xShmLock ) return SQLITE_IOERR_SHMLOCK;
  return p->real->pMethods->xShmLock(p->real, offset, n, flags);
}
static void spyShmBarrier(sqlite3_file *pF){
  SpyFile *p = (SpyFile*)pF;
  if( p->real->pMethods->iVersion>=2 && p->real->pMethods->xShmBarrier ){
    p->real->pMethods->xShmBarrier(p->real);
  }
}
static int spyShmUnmap(sqlite3_file *pF, int deleteFlag){
  SpyFile *p = (SpyFile*)pF;
  if( p->real->pMethods->iVersion<2 || !p->real->pMethods->xShmUnmap ) return SQLITE_OK;
  return p->real->pMethods->xShmUnmap(p->real, deleteFlag);
}
static int spyFetch(sqlite3_file *pF, sqlite3_int64 off, int n, void **pp){
  SpyFile *p = (SpyFile*)pF;
  if( p->real->pMethods->iVersion<3 || !p->real->pMethods->xFetch ){ *pp = 0; return SQLITE_OK; }
  return p->real->pMethods->xFetch(p->real, off, n, pp);
}
static int spyUnfetch(sqlite3_file *pF, sqlite3_int64 off, void *pPage){
  SpyFile *p = (SpyFile*)pF;
  if( p->real->pMethods->iVersion<3 || !p->real->pMethods->xUnfetch ) return SQLITE_OK;
  return p->real->pMethods->xUnfetch(p->real, off, pPage);
}

static const sqlite3_io_methods gSpyMethods = {
  3,                          /* iVersion */
  spyClose, spyRead, spyWrite, spyTruncate, spySync, spyFileSize,
  spyLock, spyUnlock, spyCheckReservedLock, spyFileControl,
  spySectorSize, spyDeviceCharacteristics,
  spyShmMap, spyShmLock, spyShmBarrier, spyShmUnmap,
  spyFetch, spyUnfetch
};

/* ---------------- sqlite3_vfs 转发 ---------------- */

static int spyOpen(sqlite3_vfs *pVfs, const char *zName, sqlite3_file *pF,
                   int flags, int *pOutFlags){
  SpyFile *p = (SpyFile*)pF;
  int rc;
  (void)pVfs;
  p->kind = kindOf(flags);
  p->real = (sqlite3_file*)((char*)p + sizeof(SpyFile));
  memset(p->real, 0, (size_t)gReal->szOsFile);
  rc = gReal->xOpen(gReal, zName, p->real, flags, pOutFlags);
  if( rc==SQLITE_OK && p->real->pMethods ){
    g.opens[p->kind]++;
    p->base.pMethods = &gSpyMethods;
  }else{
    p->base.pMethods = 0;
  }
  return rc;
}
static int spyDelete(sqlite3_vfs *v, const char *z, int s){ (void)v; return gReal->xDelete(gReal, z, s); }
static int spyAccess(sqlite3_vfs *v, const char *z, int f, int *r){ (void)v; return gReal->xAccess(gReal, z, f, r); }
static int spyFullPathname(sqlite3_vfs *v, const char *z, int n, char *o){ (void)v; return gReal->xFullPathname(gReal, z, n, o); }
static void *spyDlOpen(sqlite3_vfs *v, const char *z){ (void)v; return gReal->xDlOpen ? gReal->xDlOpen(gReal, z) : 0; }
static void spyDlError(sqlite3_vfs *v, int n, char *o){ (void)v; if(gReal->xDlError) gReal->xDlError(gReal, n, o); }
static void (*spyDlSym(sqlite3_vfs *v, void *h, const char *z))(void){ (void)v; return gReal->xDlSym ? gReal->xDlSym(gReal, h, z) : 0; }
static void spyDlClose(sqlite3_vfs *v, void *h){ (void)v; if(gReal->xDlClose) gReal->xDlClose(gReal, h); }
static int spyRandomness(sqlite3_vfs *v, int n, char *o){ (void)v; return gReal->xRandomness(gReal, n, o); }
static int spySleep(sqlite3_vfs *v, int n){ (void)v; return gReal->xSleep(gReal, n); }
static int spyCurrentTime(sqlite3_vfs *v, double *p){ (void)v; return gReal->xCurrentTime(gReal, p); }
static int spyGetLastError(sqlite3_vfs *v, int n, char *o){ (void)v; return gReal->xGetLastError ? gReal->xGetLastError(gReal, n, o) : 0; }
static int spyCurrentTimeInt64(sqlite3_vfs *v, sqlite3_int64 *p){ (void)v; return gReal->xCurrentTimeInt64 ? gReal->xCurrentTimeInt64(gReal, p) : SQLITE_ERROR; }

int brosis_shim_register(void){
  if( gRegistered ) return SQLITE_OK;
  gReal = sqlite3_vfs_find(0);
  if( gReal==0 ) return SQLITE_ERROR;
  memset(&gSpy, 0, sizeof(gSpy));
  gSpy.iVersion      = 2;
  gSpy.szOsFile      = (int)sizeof(SpyFile) + gReal->szOsFile;
  gSpy.mxPathname    = gReal->mxPathname;
  gSpy.zName         = "brosisspy";
  gSpy.pAppData      = 0;
  gSpy.xOpen         = spyOpen;
  gSpy.xDelete       = spyDelete;
  gSpy.xAccess       = spyAccess;
  gSpy.xFullPathname = spyFullPathname;
  gSpy.xDlOpen       = spyDlOpen;
  gSpy.xDlError      = spyDlError;
  gSpy.xDlSym        = spyDlSym;
  gSpy.xDlClose      = spyDlClose;
  gSpy.xRandomness   = spyRandomness;
  gSpy.xSleep        = spySleep;
  gSpy.xCurrentTime  = spyCurrentTime;
  gSpy.xGetLastError = spyGetLastError;
  gSpy.xCurrentTimeInt64 = spyCurrentTimeInt64;
  gRegistered = 1;
  return sqlite3_vfs_register(&gSpy, 1);
}

int brosis_shim_add_marker(const char *bytes, int nbyte){
  unsigned char *copy;
  if( g.nmarker>=MAX_MARKERS || nbyte<=0 ) return SQLITE_ERROR;
  copy = (unsigned char*)malloc((size_t)nbyte);
  if( !copy ) return SQLITE_NOMEM;
  memcpy(copy, bytes, (size_t)nbyte);
  g.marker[g.nmarker]    = copy;
  g.markerLen[g.nmarker] = nbyte;
  g.nmarker++;
  return SQLITE_OK;
}

void brosis_shim_reset(void){
  memset(g.opens, 0, sizeof(g.opens));
  memset(g.writes, 0, sizeof(g.writes));
  memset(g.bytes, 0, sizeof(g.bytes));
  memset(g.hits, 0, sizeof(g.hits));
}

long long brosis_shim_opens(int k){ return (k>=0 && k<BROSIS_KIND_COUNT) ? g.opens[k] : -1; }
long long brosis_shim_writes(int k){ return (k>=0 && k<BROSIS_KIND_COUNT) ? g.writes[k] : -1; }
long long brosis_shim_bytes(int k){ return (k>=0 && k<BROSIS_KIND_COUNT) ? g.bytes[k] : -1; }
long long brosis_shim_marker_hits(int k){ return (k>=0 && k<BROSIS_KIND_COUNT) ? g.hits[k] : -1; }

long long brosis_shim_total_marker_hits(void){
  long long t = 0; int i;
  for(i=0;i<BROSIS_KIND_COUNT;i++) t += g.hits[i];
  return t;
}
long long brosis_shim_temp_opens(void){
  return g.opens[BROSIS_KIND_TEMP_DB] + g.opens[BROSIS_KIND_TEMP_JOURNAL]
       + g.opens[BROSIS_KIND_TRANSIENT_DB] + g.opens[BROSIS_KIND_SUBJOURNAL];
}
long long brosis_shim_temp_bytes(void){
  return g.bytes[BROSIS_KIND_TEMP_DB] + g.bytes[BROSIS_KIND_TEMP_JOURNAL]
       + g.bytes[BROSIS_KIND_TRANSIENT_DB] + g.bytes[BROSIS_KIND_SUBJOURNAL];
}

int brosis_register_vec(void){
  /* sqlite3_auto_extension 的入口点类型是 void(*)(void)，官方示例也是这样强转的。 */
  return sqlite3_auto_extension((void(*)(void))sqlite3_vec_init);
}

void brosis_secure_zero(void *p, unsigned long n){
  volatile unsigned char *q = (volatile unsigned char*)p;
  while(n--) *q++ = 0;
}
