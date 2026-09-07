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
#
# 从 M1 R2b（T10 分发管线）起还做三件事：
#   - 把 SwiftPM 编出来的 Sparkle.framework 放进 Contents/Frameworks/，
#     给主程序补 @executable_path/../Frameworks 这条 rpath；
#   - 把 Info.plist 里的 SUPublicEDKey 占位符换成真公钥（没有就留占位符并告警：
#     fail-closed，Sparkle 会拒绝启动而不是不验签就装）；
#   - 逐个签 Sparkle 的内嵌代码（XPC、Updater.app、Autoupdate、框架本身），
#     不用 --deep，然后逐个 Mach-O 核对 Team ID。
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
# Sparkle 的 Ed25519 **公钥**（base64）。仓库里 Info.plist 放的是占位符，这里替换。
# 私钥永远只在用户自己的钥匙串里，不经过这个脚本，也不进仓库。
SPARKLE_PUBKEY_FILE="${SPARKLE_PUBKEY_FILE:-$HOME/Library/Application Support/brosis-dev/sparkle_public_ed_key.txt}"
SPARKLE_PUBKEY_PLACEHOLDER="__SUPublicEDKey__"

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

# ---- Sparkle.framework：SwiftPM 把 binaryTarget 解出来的框架拷到 bin 目录，
# 这里再放进 Contents/Frameworks/。主程序链出来只带一条 `@loader_path` 的 rpath
# （裸二进制跑得通，因为框架就在它旁边），装进 bundle 后 @loader_path 是
# Contents/MacOS，找不到框架，所以补一条 @executable_path/../Frameworks。
# 不用 Package.swift 的 .unsafeFlags：带 unsafeFlags 的清单不能被别的包按版本引用。
SPARKLE_SRC="$BIN_DIR/Sparkle.framework"
[ -d "$SPARKLE_SRC" ] || fail "找不到 $SPARKLE_SRC（SwiftPM 没有解出 Sparkle 的 binaryTarget？）"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
# 用 ditto 而不是 cp -R：框架是版本化 bundle，符号链接与扩展属性都要原样保留。
ditto "$SPARKLE_SRC" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
SPARKLE_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                "$SPARKLE_FW/Resources/Info.plist" 2>/dev/null || echo '?')"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -A2 LC_RPATH | grep -q 'Frameworks' \
  || fail "rpath @executable_path/../Frameworks 没加上"
echo "Sparkle.framework $SPARKLE_VER 已放进 Contents/Frameworks/，rpath 已补"

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

# ---- Sparkle 更新公钥。占位符 -> 真公钥；没有公钥文件就**保留占位符并告警**。
# 保留占位符不是"退化成不验签"：占位符不是合法 base64，Updater.swift 的
# UpdaterConfig.issues 会当场拦下，Sparkle 的 startUpdater 也会失败，
# 也就是这份构建根本装不上任何"更新"（fail-closed）。
SPARKLE_PUBKEY=""
if [ -n "${BROSIS_SPARKLE_PUBKEY:-}" ]; then
  SPARKLE_PUBKEY="$BROSIS_SPARKLE_PUBKEY"
  SPARKLE_PUBKEY_SRC="环境变量 BROSIS_SPARKLE_PUBKEY"
elif [ -f "$SPARKLE_PUBKEY_FILE" ]; then
  SPARKLE_PUBKEY="$(tr -d ' \t\r\n' < "$SPARKLE_PUBKEY_FILE")"
  SPARKLE_PUBKEY_SRC="$SPARKLE_PUBKEY_FILE"
fi
if [ -n "$SPARKLE_PUBKEY" ]; then
  # 32 字节 base64 = 44 个字符（末尾一个 '='）。长度不对就直接失败，
  # 免得签出一个"看着像 key"的东西。
  n="$(printf '%s' "$SPARKLE_PUBKEY" | base64 -d 2>/dev/null | wc -c | tr -d ' ')"
  [ "$n" = "32" ] || fail "Sparkle 公钥不是 32 字节（解出 ${n:-0} 字节，来源 $SPARKLE_PUBKEY_SRC）"
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBKEY" "$APP_BUNDLE/Contents/Info.plist"
  echo "Sparkle 更新公钥：已写入（来源 $SPARKLE_PUBKEY_SRC）"
else
  got="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_BUNDLE/Contents/Info.plist")"
  [ "$got" = "$SPARKLE_PUBKEY_PLACEHOLDER" ] \
    || fail "Info.plist 的 SUPublicEDKey 既不是占位符也没被替换：$got"
  printf '注意：没有 Sparkle 更新公钥（%s 不存在），SUPublicEDKey 保持占位符。\n' "$SPARKLE_PUBKEY_FILE"
  printf '      这份构建的「检查更新…」会明确报错并拒绝更新（fail-closed）。\n'
  printf '      生成密钥对（私钥进你自己的钥匙串，公钥写到上面那个文件）见 dist/RELEASE.md。\n'
fi
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
           NSAppleEventsUsageDescription CFBundleShortVersionString CFBundleVersion \
           SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP_BUNDLE/Contents/Info.plist" > /dev/null \
    || fail "Info.plist 缺少 $key"
done
# 「默认不联网」这条要在构建期就锁死：两个自动开关必须是 false，源必须是 https。
for key in SUEnableAutomaticChecks SUAutomaticallyUpdate; do
  got="$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP_BUNDLE/Contents/Info.plist")"
  [ "$got" = "false" ] || fail "Info.plist 的 $key = $got，必须为 false（默认不自动联网）"
done
case "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP_BUNDLE/Contents/Info.plist")" in
  https://*) ;;
  *) fail "SUFeedURL 必须是 https" ;;
esac
echo "Info.plist 十二个必备键齐全（含四个 Sparkle 键；两个自动开关都是 false，源是 https）"
find "$APP_BUNDLE" -type f -not -path "*/Sparkle.framework/*" | sed "s|$APP_BUNDLE|  brosis.app|"
printf '  brosis.app/Contents/Frameworks/Sparkle.framework（%s 个文件，%s）\n' \
  "$(find "$SPARKLE_FW" -type f | wc -l | tr -d ' ')" "$(du -sh "$SPARKLE_FW" | cut -f1)"

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

# ---- Sparkle：由内向外逐个签，**不用 --deep**。
# Sparkle 官方要求：XPC 服务 → Updater.app → Autoupdate → 框架本身，
# 每一件都要 hardened runtime + 安全时间戳（公证要求所有内嵌代码都带时间戳）。
# 顺序不能反：codesign 会把已签好的内嵌代码封进外层的 CodeResources，
# 先签外层再动内层的话，外层封印立刻作废。
# 这里不给它们任何 entitlements：brosis 不沙盒（entitlements 里 app-sandbox=false），
# 两个 XPC 只在沙盒应用里才会被用到，留着是为了将来真沙盒化时不用改脚本，
# 签好之后 --verify --deep --strict 也能把它们一起验掉。
SPARKLE_SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime --generate-entitlement-der)
if [ "$TIMESTAMP" = "none" ]; then
  SPARKLE_SIGN_ARGS+=(--timestamp=none)
else
  SPARKLE_SIGN_ARGS+=(--timestamp)
fi
SPARKLE_VERSIONS="$SPARKLE_FW/Versions/$(readlink "$SPARKLE_FW/Versions/Current")"
[ -d "$SPARKLE_VERSIONS" ] || fail "Sparkle.framework/Versions/Current 解不出来"
step "3a. 逐个签 Sparkle 的内嵌代码"
sparkle_signed=0
# 内嵌 bundle（.xpc / .app）：按路径深度从深到浅，保证子的先签。
while IFS= read -r item; do
  [ -n "$item" ] || continue
  codesign "${SPARKLE_SIGN_ARGS[@]}" "$item"
  echo "  签：${item#$APP_BUNDLE/Contents/Frameworks/}"
  sparkle_signed=$((sparkle_signed + 1))
done < <(find "$SPARKLE_VERSIONS" \( -name '*.xpc' -o -name '*.app' \) -type d \
         | awk '{ print gsub(/\//,"/") "\t" $0 }' | sort -rn | cut -f2-)
# 裸 Mach-O（Autoupdate）：不在任何内嵌 bundle 里、不是框架主 dylib 的可执行文件。
while IFS= read -r item; do
  [ -n "$item" ] || continue
  # 注意要拿**框架内部**的相对路径去匹配：绝对路径里有 "brosis.app/"，
  # 直接 case "$item" in *.app/* 会把所有文件都排掉（第一版就踩了这个坑）。
  rel="${item#"$SPARKLE_VERSIONS/"}"
  case "$rel" in *.xpc/*|*.app/*) continue ;; esac
  if [ "$rel" = "Sparkle" ]; then continue; fi
  file "$item" | grep -q 'Mach-O' || continue
  codesign "${SPARKLE_SIGN_ARGS[@]}" "$item"
  echo "  签：${item#$APP_BUNDLE/Contents/Frameworks/}"
  sparkle_signed=$((sparkle_signed + 1))
done < <(find "$SPARKLE_VERSIONS" -type f -perm +111)
# 最后签框架本身（对版本化框架要签 .framework，codesign 自己走 Versions/Current）。
codesign "${SPARKLE_SIGN_ARGS[@]}" "$SPARKLE_FW"
sparkle_signed=$((sparkle_signed + 1))
echo "  签：Sparkle.framework"
[ "$sparkle_signed" -ge 5 ] \
  || fail "Sparkle 内嵌代码只签了 $sparkle_signed 件（预期 ≥ 5：2 个 XPC + Updater.app + Autoupdate + 框架）"
echo "Sparkle 内嵌代码共签 $sparkle_signed 件"

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

# Sparkle 里每一个 Mach-O 都必须是**我们**签的（同一个 Team ID）：
# 只要漏一个，hardened runtime 的库校验会在加载时拒绝，公证也会退回。
# --deep --strict 会验封印，但不会告诉你"这是谁签的"，所以这里再逐个问一次。
step "4a. 核对 Sparkle 每个 Mach-O 的 Team ID"
sparkle_checked=0
while IFS= read -r macho; do
  [ -n "$macho" ] || continue
  file "$macho" | grep -q 'Mach-O' || continue
  t="$(codesign -dv "$macho" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [ "$t" = "$APP_TEAM" ] \
    || fail "$(basename "$macho") 的 Team ID 是 ${t:-<none>}，应为 $APP_TEAM（漏签或签错身份）"
  sparkle_checked=$((sparkle_checked + 1))
done < <(find "$SPARKLE_FW/Versions" -type f -perm +111)
[ "$sparkle_checked" -ge 5 ] || fail "Sparkle 里只找到 $sparkle_checked 个 Mach-O（预期 ≥ 5）"
echo "Sparkle 的 $sparkle_checked 个 Mach-O 全部由同一个 Team ID 签名"

# 主程序真的能加载框架：从 bundle 里跑一次 --version。
# dyld 找不到 Sparkle.framework 的话这一步会直接非零退出。
step "4b. 从 bundle 里跑 --version（验 dyld 能按 rpath 找到 Sparkle.framework）"
"$APP_BUNDLE/Contents/MacOS/$APP_NAME" --version

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
