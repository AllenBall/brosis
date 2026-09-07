#!/bin/sh
# brosis M1 / T2：准备 core/ 需要的外部 C 源码（SQLCipher amalgamation + sqlite-vec）。
#
# 源码一律不进项目目录（项目目录在同步盘里，不放 9.3 MiB 的 amalgamation）：
# 真正的文件落在 ~/Library/Caches/brosis-build/sqlcipher/vendor/，
# 包里只留符号链接（SwiftPM 的 target path 必须在包内，但实测接受指向包外的符号链接）。
#
#   core/Vendor/SQLCipher -> ~/Library/Caches/brosis-build/sqlcipher/vendor/route-b
#   core/Vendor/SqliteVec -> ~/Library/Caches/brosis-build/sqlcipher/vendor/sqlite-vec-target
#
# 另外再建一个**相对**符号链接（它本身进仓库，重跑本脚本也是幂等的）：
#   core/Sources/CSQLCipher/include -> ../../Vendor/SQLCipher/include
# SQLCipher 目标的源码只有一个包装文件 Sources/CSQLCipher/sqlcipher_amalgamation.c，
# 由它 #include 上游 amalgamation（为了把 <sys/param.h> 提前，见那个文件的注释）。
#
# 取源与 amalgamation 生成复用 M0 已验证的脚本 tools/proto/sqlcipher/setup.sh
# （SQLCipher v4.18.0、sqlite-vec v0.1.9，SHA-256 由该脚本打印）。
#
# 用法： sh core/setup.sh [--force]
#   --force 透传给 tools/proto/sqlcipher/setup.sh，强制重新取源并重建 amalgamation。
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
PROJECT=$(cd "$HERE/.." && pwd)
PROTO_SETUP="$PROJECT/tools/proto/sqlcipher/setup.sh"
VENDOR="$HOME/Library/Caches/brosis-build/sqlcipher/vendor"

if [ ! -f "$PROTO_SETUP" ]; then
  echo "[core/setup] 找不到 $PROTO_SETUP" >&2
  exit 1
fi

echo "[core/setup] 1/3 调用 tools/proto/sqlcipher/setup.sh 准备 vendor（首次需要 clone + 生成 amalgamation，数分钟）"
sh "$PROTO_SETUP" "$@"

RB="$VENDOR/route-b"
VEC="$VENDOR/sqlite-vec-target"
for f in "$RB/src/sqlite3.c" "$RB/include/sqlite3.h" "$VEC/sqlite-vec.c" "$VEC/include/sqlite-vec.h"; do
  if [ ! -f "$f" ]; then
    echo "[core/setup] vendor 不完整，缺少 $f" >&2
    exit 1
  fi
done

echo "[core/setup] 2/3 建符号链接 core/Vendor/{SQLCipher,SqliteVec} 与 Sources/CSQLCipher/include"
mkdir -p "$HERE/Vendor"
ln -sfn "$RB"  "$HERE/Vendor/SQLCipher"
ln -sfn "$VEC" "$HERE/Vendor/SqliteVec"
# SQLCipher 目标的 publicHeadersPath 指向这里；它是**相对**链接（进仓库），
# 指向上面刚建好的 Vendor/SQLCipher/include，所以只有 sqlite3.h 会被暴露出去。
mkdir -p "$HERE/Sources/CSQLCipher"
ln -sfn ../../Vendor/SQLCipher/include "$HERE/Sources/CSQLCipher/include"

# ---------------------------------------------------------------- .gitignore
# 指向本机缓存目录的那两个符号链接不能进仓库；换机器重跑本脚本即可重建。
# （Sources/CSQLCipher/include 是相对链接，它本身可以进仓库。）
echo "[core/setup] 3/3 把符号链接路径写进项目根 .gitignore（幂等）"
GI="$PROJECT/.gitignore"
add_ignore() {
  if [ ! -f "$GI" ] || ! grep -qxF "$1" "$GI"; then
    printf '%s\n' "$1" >> "$GI"
    echo "  + $1"
  fi
}
if [ -f "$GI" ] && ! grep -qxF "# core/ 的 vendor 符号链接，由 core/setup.sh 重建" "$GI"; then
  printf '\n%s\n' "# core/ 的 vendor 符号链接，由 core/setup.sh 重建" >> "$GI"
fi
add_ignore "core/Vendor/SQLCipher"
add_ignore "core/Vendor/SqliteVec"

echo "[core/setup] 完成"
echo "  SQLCipher  -> $RB"
echo "  sqlite-vec -> $VEC"
shasum -a 256 "$RB/src/sqlite3.c" "$VEC/sqlite-vec.c" 2>/dev/null || true
echo ""
echo "接着跑："
echo "  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \\"
echo "    swift build --package-path core -c release \\"
echo "    --scratch-path ~/Library/Caches/brosis-build/m1-core"
