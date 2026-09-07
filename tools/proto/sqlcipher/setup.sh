#!/bin/sh
# brosis M0 / T8（E6）：准备两条构建路线的外部源码。
#
# 全部落到 ~/Library/Caches/brosis-build/sqlcipher/，项目目录里只留符号链接，
# 因为项目目录在 iCloud Drive 里（不放 9.7 MB 的 amalgamation 和上千个小文件）。
#
#   vendor/route-b/src/sqlite3.c            SQLCipher amalgamation（路线 b 的 C 目标源）
#   vendor/route-b/include/sqlite3.h        公共头
#   vendor/route-b/src/sqlite3ext.h        （私有头，见下方注释）
#   vendor/sqlite-vec-target/sqlite-vec.c   sqlite-vec 固定版本
#   vendor/sqlite-vec-target/include/sqlite-vec.h
#
# 用法： sh setup.sh [--force]
set -e

SQLCIPHER_TAG=v4.18.0
SQLITEVEC_TAG=v0.1.9

HERE=$(cd "$(dirname "$0")" && pwd)
BUILD="$HOME/Library/Caches/brosis-build/sqlcipher"
VENDOR="$BUILD/vendor"
WORK="$BUILD/work"

FORCE=0
[ "$1" = "--force" ] && FORCE=1

mkdir -p "$VENDOR" "$WORK" "$BUILD/run"

# ---------------------------------------------------------------- sqlite-vec
VEC="$VENDOR/sqlite-vec-target"
if [ $FORCE -eq 1 ] || [ ! -f "$VEC/sqlite-vec.c" ]; then
  echo "[setup] 取 sqlite-vec $SQLITEVEC_TAG"
  rm -rf "$VEC"; mkdir -p "$VEC/include"
  base="https://raw.githubusercontent.com/asg017/sqlite-vec/$SQLITEVEC_TAG"
  curl -sSfL -o "$VEC/sqlite-vec.c"          "$base/sqlite-vec.c"
  curl -sSfL -o "$VEC/include/.tmpl"          "$base/sqlite-vec.h.tmpl"
  # 上游的 sqlite-vec.h 由 Makefile 从 .tmpl 生成（填版本号），这里照做，
  # 只填版本，不填 DATE / SOURCE（那两个宏在本项目里没人读）。
  v=${SQLITEVEC_TAG#v}
  maj=$(echo "$v" | cut -d. -f1); min=$(echo "$v" | cut -d. -f2); pat=$(echo "$v" | cut -d. -f3 | cut -d- -f1)
  sed -e "s/\${VERSION}/$v/g" -e "s/\${DATE}/unset/g" -e "s/\${SOURCE}/$SQLITEVEC_TAG/g" \
      -e "s/\${VERSION_MAJOR}/$maj/g" -e "s/\${VERSION_MINOR}/$min/g" -e "s/\${VERSION_PATCH}/$pat/g" \
      "$VEC/include/.tmpl" > "$VEC/include/sqlite-vec.h"
  rm -f "$VEC/include/.tmpl"
fi

# ---------------------------------------------------------------- SQLCipher amalgamation（路线 b）
RB="$VENDOR/route-b"
if [ $FORCE -eq 1 ] || [ ! -f "$RB/src/sqlite3.c" ]; then
  echo "[setup] 取 sqlcipher $SQLCIPHER_TAG 并生成 amalgamation"
  rm -rf "$WORK/sqlcipher-src" "$RB"
  git clone --quiet --depth 1 --branch "$SQLCIPHER_TAG" \
      https://github.com/sqlcipher/sqlcipher.git "$WORK/sqlcipher-src"
  cd "$WORK/sqlcipher-src"
  # --disable-tcl：用树内 autosetup/jimsh0.c 做代码生成，不需要系统 tclsh
  #   （本机 /usr/bin/tclsh 是 8.5，SQLite 3.53 的测试套件要 8.6+，但生成 amalgamation 用不上）
  # --with-tempstore=yes：把 SQLITE_TEMP_STORE=2 写进 Makefile；真正生效的开关在 Package.swift 里再显式给一遍
  ./configure --disable-tcl --disable-shared --with-tempstore=yes \
              --fts5 --dbstat --all > "$BUILD/configure.log" 2>&1
  make sqlite3.c > "$BUILD/amalgamation.log" 2>&1
  mkdir -p "$RB/src" "$RB/include"
  cp sqlite3.c            "$RB/src/sqlite3.c"
  cp sqlite3.h    "$RB/include/"
  # sqlite3ext.h 只放私有目录：它在未定义 SQLITE_CORE 时会把所有 sqlite3_* 宏重定义成
  # sqlite3_api->*，一旦进了 publicHeadersPath，Swift 侧的 Clang 模块就会被污染。
  cp sqlite3ext.h "$RB/src/"
  cd "$HERE"
fi

# ---------------------------------------------------------------- 符号链接
ln -sfn "$VEC" "$HERE/Sources/CSqliteVec"
mkdir -p "$HERE/RouteB"
ln -sfn "$RB"  "$HERE/RouteB/SQLCipher"

echo "[setup] 完成"
echo "  sqlcipher   $SQLCIPHER_TAG  -> $RB"
echo "  sqlite-vec  $SQLITEVEC_TAG  -> $VEC"
shasum -a 256 "$RB/src/sqlite3.c" "$VEC/sqlite-vec.c" 2>/dev/null || true
