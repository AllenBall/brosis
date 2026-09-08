#!/bin/bash
# 让 `xcrun metal` / `xcrun metallib` 可用，必要时把 DEVELOPER_DIR 指到 Xcode。
#
# 由来（2026-09-09）：本机 `xcode-select -p` 指向 CommandLineTools，那里**没有** metal /
# metallib，而 mlx 的着色器库必须现编。`app/build_app.sh` 曾因此在编了 40 分钟之后才报错，
# `tools/eval/run_d8.sh` 则是给 swift build 传了 DEVELOPER_DIR、唯独漏给 build_metallib.sh。
# 所以判断放在**用得到它的地方**，谁要编 metallib 谁 source 一下，而不是指望每个调用方记得传。
#
#   source "<repo>/app/Support/ensure_metal_toolchain.sh"   # 探不到会 return 1
#
# 只改本进程的 DEVELOPER_DIR，不动全局 xcode-select（那要 sudo，而且会影响用户自己的构建）。
ensure_metal_toolchain() {
    if xcrun -sdk macosx metal --version > /dev/null 2>&1 \
       && xcrun -sdk macosx metallib --version > /dev/null 2>&1; then
        return 0
    fi
    local candidate
    for candidate in "${DEVELOPER_DIR:-}" /Applications/Xcode.app/Contents/Developer; do
        [ -n "$candidate" ] || continue
        if DEVELOPER_DIR="$candidate" xcrun -sdk macosx metal --version > /dev/null 2>&1 \
           && DEVELOPER_DIR="$candidate" xcrun -sdk macosx metallib --version > /dev/null 2>&1; then
            export DEVELOPER_DIR="$candidate"
            echo "注意：当前 xcode-select 没有 metal/metallib，改用 DEVELOPER_DIR=$candidate" >&2
            return 0
        fi
    done
    echo "ERROR: 拿不到 metal/metallib 编译器。装 Metal Toolchain（xcodebuild -downloadComponent MetalToolchain），
       或者 DEVELOPER_DIR=<Xcode>/Contents/Developer。" >&2
    return 1
}
