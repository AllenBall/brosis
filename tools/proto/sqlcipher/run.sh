#!/bin/sh
# brosis M0 / T8（E6）：两条路线各跑一遍完整探针，外加一次 cipher_memory_security = ON 的对照。
#
#   sh setup.sh          # 只需一次：取 sqlcipher / sqlite-vec 源码，建符号链接
#   sh run.sh            # 默认 2 万条
#   sh run.sh 50000      # 换规模
#
# 全部构建产物与数据库落在 ~/Library/Caches/brosis-build/sqlcipher/，不进项目目录。
set -e
ROWS=${1:-20000}
HERE=$(cd "$(dirname "$0")" && pwd)
B="$HOME/Library/Caches/brosis-build/sqlcipher"
mkdir -p "$B/run"

for R in a b; do
  echo "==== 路线 $R：release 构建 ===="
  ( cd "$HERE" && BROSIS_SQLCIPHER_ROUTE=$R swift build -c release --scratch-path "$B/scratch-$R" )
  echo "==== 路线 $R：跑探针（$ROWS 条）===="
  BROSIS_SQLCIPHER_ROUTE=$R "$B/scratch-$R/release/SQLCipherProbe" \
      --rows "$ROWS" --reps 100 --opens 20 \
      --work "$B/run/route-$R" --out "$B/run/route-$R.json"
done

echo "==== 路线 b：cipher_memory_security = ON 对照 ===="
BROSIS_SQLCIPHER_ROUTE=b "$B/scratch-b/release/SQLCipherProbe" \
    --rows "$ROWS" --reps 100 --opens 5 --memsec \
    --work "$B/run/route-b-memsec" --out "$B/run/route-b-memsec.json"

echo "==== strings/grep 交叉复核（Swift 侧已做逐字节扫描，这里再用命令行确认一遍）===="
for f in "$B/run/route-b/enc.db" "$B/run/route-b/enc.db-wal" "$B/run/route-b/plain.db"; do
  [ -f "$f" ] || continue
  n=$(strings -a "$f" | grep -c 'BROSISLEAKCANARY7F3A2D' || true)
  m=$(LC_ALL=C grep -a -c '饕餮' "$f" 2>/dev/null || true)
  echo "  $(basename "$f"): strings|grep BROSISLEAKCANARY7F3A2D = $n 行；grep 饕餮 = $m 行"
done

echo "==== 生成报告 ===="
python3 "$HERE/render_report.py"
