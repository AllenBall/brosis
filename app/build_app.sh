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
# 硬约束：构建产物不能落在项目目录。SCRATCH 必须是绝对路径且不含未展开的 ~（env SCRATCH=~/x 时 zsh 不展开）。
case "$SCRATCH" in
  /*) ;;
  *) printf 'ERROR: SCRATCH 必须是绝对路径（收到 "%s"）。用 SCRATCH="$HOME/…" 而不是 ~/…\n' "$SCRATCH" >&2; exit 1 ;;
esac
case "$SCRATCH" in *'~'*) printf 'ERROR: SCRATCH 含未展开的 ~：%s\n' "$SCRATCH" >&2; exit 1 ;; esac
# core 是另一个 SwiftPM 包，要单独一个 scratch（两个包不能共用一个）。
# brosis-mcp 是 core 的产品（3.6 的薄 MCP），要一起构建并放进 bundle。
CORE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../core" && pwd)"
CORE_SCRATCH="${CORE_SCRATCH:-${SCRATCH%/}-core}"
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

# ---------------------------------------------------------------- 1b. brosis-mcp
# 计划 3.6 的薄 MCP（stdio）。它只链接 BrosisIPC——不持钥、不开库，
# 经 <数据目录>/ipc.sock 问 brosis.app 里的存储服务要数据。
step "1b. swift build brosis-mcp（core 包，scratch=$CORE_SCRATCH）"
swift build --package-path "$CORE_SRC" --scratch-path "$CORE_SCRATCH" -c "$CONFIG" \
            --product brosis-mcp
CORE_BIN_DIR="$(swift build --package-path "$CORE_SRC" --scratch-path "$CORE_SCRATCH" \
                            -c "$CONFIG" --show-bin-path)"
MCP_BIN="$CORE_BIN_DIR/brosis-mcp"
[ -x "$MCP_BIN" ] || fail "找不到可执行文件 $MCP_BIN"
echo "MCP 二进制：$MCP_BIN（$(stat -f%z "$MCP_BIN") 字节）"

# ---------------------------------------------------------------- 2. 组装 .app
step "2. 组装 $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchAgents"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$MCP_BIN" "$APP_BUNDLE/Contents/MacOS/brosis-mcp"
cp "$APP_SRC/Support/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# 版本号单一来源：Sources/brosis/BuildInfo.swift 的 `static let version`。
# Info.plist 里放的是 __VERSION__ 占位符，这里替换成同一串：
#   CFBundleShortVersionString = CFBundleVersion = BuildInfo.version
# 规则：两者用同一串（本项目不上 App Store，不需要"同一版本多次构建"的递增号；
# 真要区分同一版本的多次构建，就在末尾追加 .N，短版本号仍保持三段）。
# 自检会从 Bundle.main 读回来和 BuildInfo.version 比一次，所以漏替换会当场失败。
VERSION="$(sed -n 's/^[[:space:]]*static let version = "\([^"]*\)".*/\1/p' \
            "$APP_SRC/Sources/brosis/BuildInfo.swift" | head -1)"
[ -n "$VERSION" ] || fail "从 Sources/brosis/BuildInfo.swift 读不到 version"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                        -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  got="$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP_BUNDLE/Contents/Info.plist")"
  [ "$got" = "$VERSION" ] || fail "Info.plist 的 $key = $got，应为 $VERSION"
done
echo "版本号：$VERSION（来自 BuildInfo.swift，已写进 CFBundleShortVersionString / CFBundleVersion）"
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
           NSAppleEventsUsageDescription CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP_BUNDLE/Contents/Info.plist" > /dev/null \
    || fail "Info.plist 缺少 $key"
done
echo "Info.plist 八个必备键齐全"
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
# 先签内嵌的 brosis-mcp，再签外层 bundle——`codesign` 对 bundle 签名不会替
# Contents/MacOS 里的**第二个** Mach-O 生成签名，漏了的话 --deep --strict 会报
# "code object is not signed at all"。不用 --deep 签（Apple 明确不建议）。
# 它不需要任何权利：不碰钥匙串、不开库、不要 TCC；Team ID 与主程序相同，
# 所以能过服务端「对端 Team ID 必须与本进程相同」那一关。
MCP_SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime
               --identifier "com.brosis.app.mcp" --generate-entitlement-der)
if [ "$TIMESTAMP" = "none" ]; then
  MCP_SIGN_ARGS+=(--timestamp=none)
else
  MCP_SIGN_ARGS+=(--timestamp)
fi
codesign "${MCP_SIGN_ARGS[@]}" "$APP_BUNDLE/Contents/MacOS/brosis-mcp"
codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

# ---------------------------------------------------------------- 4. 验证
step "4. codesign --verify --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign --verify --strict --verbose=2 "$APP_BUNDLE/Contents/MacOS/brosis-mcp"
MCP_TEAM="$(codesign -dv "$APP_BUNDLE/Contents/MacOS/brosis-mcp" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
APP_TEAM="$(codesign -dv "$APP_BUNDLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ -n "$MCP_TEAM" ] && [ "$MCP_TEAM" = "$APP_TEAM" ] \
  || fail "brosis-mcp 与 brosis.app 的 Team ID 不一致（$MCP_TEAM vs $APP_TEAM）：IPC 对端校验会拒"
echo "brosis-mcp 与主程序同一个 Team ID，IPC 对端校验能过"

step "5. codesign -dv --verbose=4"
codesign -dv --verbose=4 "$APP_BUNDLE"

step "6. codesign -d --entitlements"
codesign -d --entitlements - --xml "$APP_BUNDLE" | plutil -convert xml1 -o - -

step "7. spctl 评估（未公证，预期 rejected）"
spctl -a -vv -t exec "$APP_BUNDLE" || true

printf '\n完成：%s\n' "$APP_BUNDLE"
printf '给 Claude Code 加 MCP：\n'
printf '  claude mcp add brosis %s/Contents/MacOS/brosis-mcp\n' "$APP_BUNDLE"
printf '第一次要先授权（app 跑起来、已解锁时）：\n'
printf '  %s/Contents/MacOS/brosis-mcp admin grant add --client claude-code --fields evidence\n' \
  "$APP_BUNDLE"
printf '注意：本 app 未公证。首次运行请用 Finder 右键“打开”，或先执行\n'
printf '  xattr -dr com.apple.quarantine "%s"\n' "$APP_BUNDLE"
