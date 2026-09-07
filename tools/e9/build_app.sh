#!/bin/bash
# brosis M0 · E9：把 brosis-e9 组装成 .app + Developer ID 签名 + hardened runtime + 验证
#
# 用法：
#   ./build_app.sh                       # release 构建、签名、验证
#   SKIP_SIGN=1 ./build_app.sh           # 只组装不签名
#   ENTITLEMENTS=path ./build_app.sh     # 指定 entitlements（默认不带任何 entitlement）
#   MLX_METALLIB=path ./build_app.sh     # 指定现成的 mlx.metallib
#   TIMESTAMP=none ./build_app.sh        # 离线时跳过时间戳（这样就不能公证）
#
# 产物一律落在 ~/Library/Caches/brosis-build/e9/，绝不写进 iCloud 项目目录。
#
# 关于 Metal 着色器库：
#   `swift build`（SwiftPM 命令行）不编译 .metal，mlx-swift README 明说要用 Xcode/xcodebuild。
#   mlx 运行时的查找顺序里，能同时满足"在 .app 里"和"codesign 不报错"的只有 SwiftPM 资源
#   bundle 这一条：Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib
#   （Contents/MacOS/ 下的**任何**文件都被 codesign 当作嵌套代码；metallib 是 MTLB 格式、
#     不是可签名的 Mach-O，所以放那儿必然报 "code object is not signed at all"）。
#   本脚本按下面的顺序拿到这个文件：
#     1. $MLX_METALLIB
#     2. xcrun metal 可用时，用 Support/build_metallib.sh 现编（需要 Metal Toolchain 组件）
#     3. 本机已装的 MLX Python wheel 里的 mlx.metallib（版本要对得上，只当应急）
set -euo pipefail

E9_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/brosis-build/e9}"
# 硬约束：构建产物不能落在项目目录。SCRATCH 必须是绝对路径且不含未展开的 ~（env SCRATCH=~/x 时 zsh 不展开）。
case "$SCRATCH" in
  /*) ;;
  *) printf 'ERROR: SCRATCH 必须是绝对路径（收到 "%s"）。用 SCRATCH="$HOME/…" 而不是 ~/…\n' "$SCRATCH" >&2; exit 1 ;;
esac
case "$SCRATCH" in *'~'*) printf 'ERROR: SCRATCH 含未展开的 ~：%s\n' "$SCRATCH" >&2; exit 1 ;; esac
CONFIG="${CONFIG:-release}"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
TEAM_ID="${TEAM_ID:-$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')}"
APP_NAME="brosis-e9"
APP_BUNDLE="$SCRATCH/$APP_NAME.app"
TIMESTAMP="${TIMESTAMP:-yes}"
BUNDLE_ID="com.brosis.e9"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

mkdir -p "$SCRATCH"

# ---------------------------------------------------------------- 0. 签名身份
if [ "${SKIP_SIGN:-0}" != "1" ]; then
  step "0. 确认签名身份"
  [ -n "$IDENTITY" ] || fail "钥匙串里没有 Developer ID Application 的 codesigning 身份。请先导入证书，或用 IDENTITY=... 指定。"
  echo "签名身份：$IDENTITY（Team ID ${TEAM_ID:-?}）"
fi

# ---------------------------------------------------------------- 1. swift build
step "1. swift build（$CONFIG，scratch=$SCRATCH）"
swift build --package-path "$E9_SRC" --scratch-path "$SCRATCH" -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$E9_SRC" --scratch-path "$SCRATCH" -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || fail "找不到可执行文件 $BIN"
echo "二进制：$BIN（$(stat -f%z "$BIN") 字节）"

# ---------------------------------------------------------------- 2. mlx.metallib
step "2. 准备 mlx.metallib"
METALLIB=""
METALLIB_SOURCE=""
if [ -n "${MLX_METALLIB:-}" ] && [ -f "$MLX_METALLIB" ]; then
  METALLIB="$MLX_METALLIB"; METALLIB_SOURCE="MLX_METALLIB 指定"
elif xcrun -sdk macosx metal --version > /dev/null 2>&1; then
  bash "$E9_SRC/Support/build_metallib.sh" "$SCRATCH/mlx.metallib"
  METALLIB="$SCRATCH/mlx.metallib"; METALLIB_SOURCE="xcrun metal 现编（Metal Toolchain 已装）"
else
  CAND="$(ls -t "$HOME"/.lmstudio/extensions/backends/vendor/_amphibian/*/lib/python3.11/site-packages/mlx/lib/mlx.metallib 2>/dev/null | head -1 || true)"
  if [ -n "$CAND" ]; then
    METALLIB="$CAND"
    METALLIB_SOURCE="应急：借用本机 MLX Python wheel 的 metallib（$CAND）"
    printf '警告：没装 Metal Toolchain，无法自己编 metallib。\n'
    printf '      正式发版必须先执行：xcodebuild -downloadComponent MetalToolchain\n'
  else
    fail "拿不到 mlx.metallib：既没有 Metal Toolchain，也没找到可借用的。请先 xcodebuild -downloadComponent MetalToolchain"
  fi
fi
echo "metallib：$METALLIB（$(stat -f%z "$METALLIB") 字节）来源：$METALLIB_SOURCE"

# ---------------------------------------------------------------- 3. 组装 .app
step "3. 组装 $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# mlx 在 .app 里能找到、且 codesign 不报错的位置：主 bundle 的 Resources 下的 SwiftPM 资源 bundle
# （放 Contents/MacOS/mlx.metallib 会被 codesign 当成未签名的嵌套代码而拒绝，见上面的注释）
#   device.cpp: load_swiftpm_library -> NS::Bundle::allBundles() -> 主 bundle 的 resourceURL
#   -> <resourceURL>/mlx-swift_Cmlx.bundle -> 平铺 bundle 的 resourceURL 就是它自己 -> default.metallib
mkdir -p "$APP_BUNDLE/Contents/Resources/mlx-swift_Cmlx.bundle"
cp "$METALLIB" "$APP_BUNDLE/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
cp "$E9_SRC/Sources/$APP_NAME/catalog.json" "$APP_BUNDLE/Contents/Resources/catalog.json"
cp "$E9_SRC/Sources/$APP_NAME/corpus.json" "$APP_BUNDLE/Contents/Resources/corpus.json"
cp "$E9_SRC/Support/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
plutil -lint "$APP_BUNDLE/Contents/Info.plist" > /dev/null
find "$APP_BUNDLE" -type f | sed "s|$APP_BUNDLE|  $APP_NAME.app|"

APP_BYTES=$(find "$APP_BUNDLE" -type f -exec stat -f%z {} + | awk '{s+=$1} END {print s}')
BIN_BYTES=$(stat -f%z "$APP_BUNDLE/Contents/MacOS/$APP_NAME")
LIB_BYTES=$(stat -f%z "$APP_BUNDLE/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib")
printf '\n体积：app 合计 %s 字节（%.2f MiB）= 可执行 %.2f MiB + metallib %.2f MiB + 其他\n' \
  "$APP_BYTES" "$(echo "$APP_BYTES/1048576" | bc -l)" \
  "$(echo "$BIN_BYTES/1048576" | bc -l)" "$(echo "$LIB_BYTES/1048576" | bc -l)"

# ---------------------------------------------------------------- 4. 签名
if [ "${SKIP_SIGN:-0}" = "1" ]; then
  step "4. 跳过签名（SKIP_SIGN=1）"; echo "$APP_BUNDLE"; exit 0
fi

step "4. Developer ID 签名 + hardened runtime"
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime
           --identifier "$BUNDLE_ID" --generate-entitlement-der)
if [ -n "${ENTITLEMENTS:-}" ]; then
  SIGN_ARGS+=(--entitlements "$ENTITLEMENTS")
  echo "使用 entitlements：$ENTITLEMENTS"
else
  echo "不带任何 entitlement（E9 实测：mlx + Metal + safetensors 在 hardened runtime 下不需要额外 entitlement）"
fi
if [ "$TIMESTAMP" = "none" ]; then
  SIGN_ARGS+=(--timestamp=none); echo "注意：无安全时间戳，不能用于公证"
else
  SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

# ---------------------------------------------------------------- 5. 验证
step "5. codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

step "6. codesign -dv --verbose=4"
codesign -dv --verbose=4 "$APP_BUNDLE"

step "7. entitlements"
codesign -d --entitlements - --xml "$APP_BUNDLE" 2>/dev/null | plutil -convert xml1 -o - - \
  || echo "（没有 entitlements）"

step "8. spctl 评估（未公证时预期 rejected）"
spctl -a -vv -t exec "$APP_BUNDLE" || true

step "9. 公证凭据检查"
if xcrun notarytool history --keychain-profile brosis > /dev/null 2>&1; then
  echo "钥匙串里有 notarytool 配置 brosis，可以提交公证："
  echo "  ditto -c -k --keepParent \"$APP_BUNDLE\" \"$SCRATCH/$APP_NAME.zip\""
  echo "  xcrun notarytool submit \"$SCRATCH/$APP_NAME.zip\" --keychain-profile brosis --wait"
  echo "  xcrun stapler staple \"$APP_BUNDLE\""
else
  cat <<'NOTE'
没有找到 notarytool 的钥匙串配置 brosis，跳过公证。
需要你先做一次性配置（要 Apple ID + App 专用密码，Team ID 是 <TEAMID>）：
  xcrun notarytool store-credentials brosis \
      --apple-id <你的 Apple ID> --team-id <TEAMID> --password <App 专用密码>
或者用 App Store Connect API key：
  xcrun notarytool store-credentials brosis \
      --key <AuthKey_XXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>
配好之后：
  ditto -c -k --keepParent <app> <zip>
  xcrun notarytool submit <zip> --keychain-profile brosis --wait
  xcrun stapler staple <app> && spctl -a -vv -t exec <app>
NOTE
fi

printf '\n完成：%s\n' "$APP_BUNDLE"
printf '直接跑签名后的可执行文件：\n  "%s/Contents/MacOS/%s" bench --id Qwen3-Embedding-0.6B-8bit\n' \
  "$APP_BUNDLE" "$APP_NAME"
