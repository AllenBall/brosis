#!/bin/bash
# brosis M0 采集骨架：构建 + 组装 .app + Developer ID 签名 + 验证
#
# 用法：
#   ./build_app.sh                 # release 构建、签名、验证
#   CONFIG=debug ./build_app.sh    # debug 构建
#   SKIP_SIGN=1 ./build_app.sh     # 只组装不签名（不做 TCC 相关验证）
#   TIMESTAMP=none ./build_app.sh  # 离线时跳过时间戳服务
#
# 产物一律落在 ~/Library/Caches/brosis-build/app/，绝不写进 iCloud 项目目录。
set -euo pipefail

APP_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/brosis-build/app}"
CONFIG="${CONFIG:-release}"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
TEAM_ID="${TEAM_ID:-$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')}"
APP_NAME="brosis"
APP_BUNDLE="$SCRATCH/$APP_NAME.app"
TIMESTAMP="${TIMESTAMP:-yes}"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

mkdir -p "$SCRATCH"

# ---------------------------------------------------------------- 0. 签名身份
if [ "${SKIP_SIGN:-0}" != "1" ]; then
  step "0. 确认签名身份"
  if [ -z "$IDENTITY" ]; then
    security find-identity -v -p codesigning || true
    fail "钥匙串里没有 Developer ID Application 的 codesigning 身份。请先导入证书，或用 IDENTITY=... 指定。"
  fi
  echo "签名身份：$IDENTITY（Team ID ${TEAM_ID:-?}）"
fi

# ---------------------------------------------------------------- 1. swift build
step "1. swift build（$CONFIG，scratch=$SCRATCH）"
swift build --package-path "$APP_SRC" --scratch-path "$SCRATCH" -c "$CONFIG"
BIN_DIR="$(swift build --package-path "$APP_SRC" --scratch-path "$SCRATCH" -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
[ -x "$BIN" ] || fail "找不到可执行文件 $BIN"
echo "二进制：$BIN（$(stat -f%z "$BIN") 字节）"

# ---------------------------------------------------------------- 2. 组装 .app
step "2. 组装 $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchAgents"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$APP_SRC/Support/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_SRC/Support/com.brosis.agent.plist" \
   "$APP_BUNDLE/Contents/Library/LaunchAgents/com.brosis.agent.plist"
# Resources 里目前只有采集排除清单；没有文件时也保证目录存在
if compgen -G "$APP_SRC/Resources/*" > /dev/null; then
  cp -R "$APP_SRC/Resources/." "$APP_BUNDLE/Contents/Resources/"
fi
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# 校验 plist 语法与必备键
plutil -lint "$APP_BUNDLE/Contents/Info.plist" > /dev/null
plutil -lint "$APP_BUNDLE/Contents/Library/LaunchAgents/com.brosis.agent.plist" > /dev/null
for key in CFBundleIdentifier CFBundleExecutable LSUIElement \
           NSScreenCaptureUsageDescription NSAccessibilityUsageDescription \
           NSAppleEventsUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP_BUNDLE/Contents/Info.plist" > /dev/null \
    || fail "Info.plist 缺少 $key"
done
echo "Info.plist 六个必备键齐全"
find "$APP_BUNDLE" -type f | sed "s|$APP_BUNDLE|  brosis.app|"

# ---------------------------------------------------------------- 3. 签名
if [ "${SKIP_SIGN:-0}" = "1" ]; then
  step "3. 跳过签名（SKIP_SIGN=1）"
  echo "未签名的 .app：$APP_BUNDLE"
  exit 0
fi

step "3. Developer ID 签名 + hardened runtime"
# 描述文件（不进仓库）：存在就内嵌并签受限权利（data-protection 钥匙串可用），
# 不存在就把受限权利整段去掉再签（app 退回登录钥匙串）。
PROFILE="${BROSIS_PROFILE:-$HOME/Library/Application Support/brosis-dev/brosis.provisionprofile}"
RENDERED_ENT="$SCRATCH/brosis.entitlements"
if [ -f "$PROFILE" ]; then
  cp "$PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
  sed "s/__TEAM_ID__/$TEAM_ID/g" "$APP_SRC/Support/brosis.entitlements" > "$RENDERED_ENT"
  echo "内嵌描述文件：$PROFILE（受限权利按 Team ID $TEAM_ID 渲染）"
else
  sed '/<!-- BEGIN restricted -->/,/<!-- END restricted -->/d' "$APP_SRC/Support/brosis.entitlements" > "$RENDERED_ENT"
  echo "注意：没有描述文件（$PROFILE），未签 application-identifier / keychain-access-groups；密钥将走登录钥匙串。"
fi
plutil -lint "$RENDERED_ENT" > /dev/null
SIGN_ARGS=(--force --sign "$IDENTITY"
           --options runtime
           --entitlements "$RENDERED_ENT"
           --identifier "com.brosis.app"
           --generate-entitlement-der)
if [ "$TIMESTAMP" = "none" ]; then
  SIGN_ARGS+=(--timestamp=none)
  echo "注意：TIMESTAMP=none，签名不带安全时间戳，不能用于公证。"
else
  SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

# ---------------------------------------------------------------- 4. 验证
step "4. codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

step "5. codesign -dv --verbose=4"
codesign -dv --verbose=4 "$APP_BUNDLE"

step "6. codesign -d --entitlements"
codesign -d --entitlements - --xml "$APP_BUNDLE" | plutil -convert xml1 -o - -

step "7. spctl 评估（未公证，预期 rejected）"
spctl -a -vv -t exec "$APP_BUNDLE" || true

printf '\n完成：%s\n' "$APP_BUNDLE"
printf '注意：本 app 未公证。首次运行请用 Finder 右键“打开”，或先执行\n'
printf '  xattr -dr com.apple.quarantine "%s"\n' "$APP_BUNDLE"
