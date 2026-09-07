#!/bin/bash
# brosis M0 · E9：手工编译 mlx 的 Metal 着色器库
#
# 背景：`swift build`（SwiftPM 命令行）不会编译 .metal 源码，mlx-swift 官方 README 也写明
# "SwiftPM (command line) cannot build the Metal shaders"。于是 CLI 构建出来的可执行文件
# 一跑就是 "Failed to load the default metallib"。
#
# mlx 的查找顺序（Source/Cmlx/mlx/mlx/backend/metal/device.cpp: load_default_library）：
#   1. <可执行文件所在目录>/mlx.metallib        <- 我们用这一条
#   2. <可执行文件所在目录>/Resources/mlx.metallib
#   3. Bundle 里的 mlx-swift_Cmlx.bundle/default.metallib
#   4. <可执行文件所在目录>/Resources/default.metallib
#   5. ./default.metallib
#
# 所以只要把编译好的 mlx.metallib 放在可执行文件旁边即可（.app 里就是 Contents/MacOS/）。
#
# 用法：build_metallib.sh <输出的 mlx.metallib 路径>
set -euo pipefail

OUT="${1:?用法: build_metallib.sh <输出路径/mlx.metallib>}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/brosis-build/e9}"
SRC="$SCRATCH/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
WORK="$SCRATCH/metal-air"

[ -d "$SRC" ] || { echo "找不到 metal 源码目录：$SRC（先跑一次 swift build 让 SwiftPM 检出依赖）" >&2; exit 1; }

mkdir -p "$WORK"
# CMake 里 build_kernel_base 用的就是这组 flag（mlx/backend/metal/kernels/CMakeLists.txt）
FLAGS=(-x metal -Wall -Wextra -fno-fast-math -Wno-c++17-extensions -Wno-c++20-extensions)

AIRS=()
while IFS= read -r m; do
  name="$(basename "$m" .metal)"
  air="$WORK/$name.air"
  if [ ! -e "$air" ] || [ "$m" -nt "$air" ]; then
    echo "  metal -c $(basename "$m")"
    xcrun -sdk macosx metal "${FLAGS[@]}" -c "$m" -I "$SRC" -o "$air"
  fi
  AIRS+=("$air")
done < <(find "$SRC" -name "*.metal" | sort)

echo "  metallib -> $OUT（$(printf '%s ' "${#AIRS[@]}")个 air）"
mkdir -p "$(dirname "$OUT")"
xcrun -sdk macosx metallib "${AIRS[@]}" -o "$OUT"
ls -l "$OUT"
