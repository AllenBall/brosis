#!/bin/bash
# brosis 分发管线（计划 4.2「打包与分发管线：Developer ID 签名、公证、DMG、签名更新」）。
#
# 一条命令从源码走到可分发的 DMG：
#   build_app.sh（签名的 .app）→ hdiutil 压缩 DMG（含 /Applications 快捷方式）
#   → codesign 签 DMG → 公证 + stapler → spctl 评估 → sha256 与清单
#
# 用法：
#   ./build_dmg.sh                      # 全流程，含公证（缺凭据会明确报错）
#   ./build_dmg.sh --skip-notarize      # 跳过公证（本机屏幕锁定时只能这样）
#   ./build_dmg.sh --app <已签好的.app> # 复用现成的 .app，不重新构建
#   ./build_dmg.sh --keychain-profile X # 换 notarytool 的钥匙串配置名（默认 brosis）
#
# 产物一律落在 ~/Library/Caches/brosis-build/dist/<version>/，绝不写进项目目录。
set -euo pipefail

DIST_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIST_SRC/.." && pwd)"
APP_SRC="$REPO/app"

DIST_ROOT="${DIST_ROOT:-$HOME/Library/Caches/brosis-build/dist}"
SCRATCH="${SCRATCH:-$HOME/Library/Caches/brosis-build/dist-app}"
NOTARY_PROFILE="${NOTARY_PROFILE:-brosis}"
APP_NAME="brosis"
DO_NOTARIZE=1
PREBUILT_APP=""

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-notarize) DO_NOTARIZE=0; shift ;;
    --notarize)      DO_NOTARIZE=1; shift ;;
    --app)           PREBUILT_APP="${2:-}"; shift 2 ;;
    --keychain-profile) NOTARY_PROFILE="${2:-}"; shift 2 ;;
    -h|--help)       sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)               fail "不认识的参数：$1（--help 看用法）" ;;
  esac
done

# 硬约束：产物不能落进项目目录（它在同步盘里）。两个路径都必须是绝对路径。
for var in DIST_ROOT SCRATCH; do
  eval "value=\$$var"
  case "$value" in
    /*) ;;
    *) fail "$var 必须是绝对路径（收到 \"$value\"）。用 \"\$HOME/…\" 而不是 ~/…" ;;
  esac
  case "$value" in *'~'*) fail "$var 含未展开的 ~：$value" ;; esac
  case "$value" in "$REPO"|"$REPO"/*) fail "$var 落在项目目录里：$value" ;; esac
done

# ---------------------------------------------------------------- 1. 版本号
# 与 build_app.sh 同一个来源：app/Sources/brosis/BuildInfo.swift 的 `static let version`。
step "1. 版本号"
VERSION="$(sed -n 's/^[[:space:]]*static let version = "\([^"]*\)".*/\1/p' \
            "$APP_SRC/Sources/brosis/BuildInfo.swift" | head -1)"
[ -n "$VERSION" ] || fail "从 app/Sources/brosis/BuildInfo.swift 读不到 version"
echo "版本号：$VERSION（来自 BuildInfo.swift）"

OUT="$DIST_ROOT/$VERSION"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
STAGE="$OUT/stage"
MNT="$OUT/mnt"

# ---------------------------------------------------------------- 2. .app
step "2. 取签名好的 $APP_NAME.app"
if [ -n "$PREBUILT_APP" ]; then
  APP="$PREBUILT_APP"
  [ -d "$APP" ] || fail "--app 指的目录不存在：$APP"
  echo "复用现成的：$APP（没有重新构建）"
else
  APP="$SCRATCH/$APP_NAME.app"
  echo "调 app/build_app.sh（SCRATCH=$SCRATCH）"
  SCRATCH="$SCRATCH" "$APP_SRC/build_app.sh"
fi
[ -d "$APP" ] || fail "找不到 $APP"

# 三件事必须当场核对，不能等公证被退回才发现：
#   a. .app 的版本号与 BuildInfo 一致（DMG 名字用的是后者）
#   b. 签名有效、内嵌代码全签到了（--deep --strict）
#   c. 签名带安全时间戳（没有时间戳的包公证一定被拒）
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$APP_VERSION" = "$VERSION" ] || fail ".app 的版本 $APP_VERSION 与 BuildInfo 的 $VERSION 不一致"
codesign --verify --deep --strict "$APP" || fail "$APP 的签名验证没过"
IDENTITY_LINE="$(codesign -dv --verbose=2 "$APP" 2>&1)"
TEAM_ID="$(printf '%s' "$IDENTITY_LINE" | sed -n 's/^TeamIdentifier=//p')"
[ -n "$TEAM_ID" ] && [ "$TEAM_ID" != "not set" ] || fail "$APP 没有 Team ID（是不是 SKIP_SIGN=1 构建的？）"
if printf '%s' "$IDENTITY_LINE" | grep -q '^Timestamp='; then
  HAS_TIMESTAMP=1
else
  HAS_TIMESTAMP=0
  printf '注意：.app 的签名**没有**安全时间戳（TIMESTAMP=none 构建的），不能公证。\n'
fi
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
[ -n "$IDENTITY" ] || fail "钥匙串里没有 Developer ID Application 身份，签不了 DMG"
echo ".app 版本 $VERSION，签名有效，Team ID $TEAM_ID，时间戳 $([ "$HAS_TIMESTAMP" = 1 ] && echo 有 || echo 无)"

# ---------------------------------------------------------------- 3. 公证前置检查
# 放在做 DMG 之前：缺凭据就早点失败，不要白花几十秒压完再报错。
if [ "$DO_NOTARIZE" = "1" ]; then
  step "3. 公证前置检查"
  [ "$HAS_TIMESTAMP" = "1" ] || fail "签名没有安全时间戳，公证一定被拒。重新构建（不要 TIMESTAMP=none），或加 --skip-notarize。"
  # notarytool 的凭据存在 **data-protection 钥匙串**里，屏幕锁定时读不到
  # （会报 "No Keychain password item found for profile"）。这里先自己判一次，
  # 报一句人看得懂的话，而不是让 notarytool 在传完包之后才失败。
  if ioreg -n Root -d1 -a 2>/dev/null | grep -A1 'IOConsoleLocked' | grep -q '<true/>'; then
    fail "屏幕当前锁定：data-protection 钥匙串不可用，取不到 notarytool 的凭据。
      解锁屏幕后再跑，或者加 --skip-notarize 先出一个未公证的 DMG。"
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json > /dev/null 2>&1; then
    fail "notarytool 的钥匙串配置 \"$NOTARY_PROFILE\" 不可用（没配过、或者当前取不到）。
      先做一次性配置（二选一，Team ID 用上面探到的那个）：
        xcrun notarytool store-credentials $NOTARY_PROFILE \\
            --apple-id <你的 Apple ID> --team-id $TEAM_ID --password <App 专用密码>
        xcrun notarytool store-credentials $NOTARY_PROFILE \\
            --key <AuthKey_XXXXXXXX.p8> --key-id <KEY_ID> --issuer <ISSUER_UUID>
      或者加 --skip-notarize 先出一个未公证的 DMG（spctl 会 rejected，装的时候要右键打开）。"
  fi
  echo "notarytool 配置 \"$NOTARY_PROFILE\" 可用"
else
  step "3. 跳过公证（--skip-notarize）"
  echo "产出的 DMG 会是「已签名、未公证」：spctl 预期 rejected，装的时候要 Finder 右键「打开」。"
fi

# ---------------------------------------------------------------- 4. 组装 DMG
step "4. 组装 DMG"
# 挂着的旧盘先卸掉，否则 rm -rf 会失败
if mount | grep -q " $MNT "; then hdiutil detach "$MNT" -quiet || true; fi
rm -rf "$OUT"
mkdir -p "$STAGE" "$MNT"
# ditto 而不是 cp -R：要原样保留签名、符号链接与扩展属性
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
# 背景图与窗口布局这版不做（纯功能性 DMG：一个 .app + 一个 /Applications 快捷方式）。
printf '把 %s.app 拖到 Applications 里即可安装。\n' "$APP_NAME" > "$STAGE/安装说明.txt"

VOLNAME="$APP_NAME $VERSION"
# UDZO + zlib-level=9：只读压缩，兼容性最好；HFS+ 保证 /Applications 那个符号链接原样保留。
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" \
               -fs HFS+ -format UDZO -imagekey zlib-level=9 \
               -quiet -ov "$DMG"
DMG_BYTES="$(stat -f%z "$DMG")"
echo "DMG：$DMG（$DMG_BYTES 字节，卷名「$VOLNAME」）"

# ---------------------------------------------------------------- 5. 签 DMG
step "5. codesign 签 DMG"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [ "$HAS_TIMESTAMP" = "1" ]; then SIGN_ARGS+=(--timestamp); else SIGN_ARGS+=(--timestamp=none); fi
codesign "${SIGN_ARGS[@]}" "$DMG"
codesign --verify --verbose=2 "$DMG"

# ---------------------------------------------------------------- 6. 公证
NOTARIZED=0
if [ "$DO_NOTARIZE" = "1" ]; then
  step "6. 公证（notarytool submit --wait → stapler staple）"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  NOTARIZED=1
else
  step "6. 跳过公证"
fi

# ---------------------------------------------------------------- 7. 评估
step "7. spctl 评估"
# DMG 自己（Gatekeeper 打开磁盘映像走的是 -t open）
DMG_SPCTL="$(spctl -a -vv -t open --context context:primary-signature "$DMG" 2>&1 || true)"
printf 'DMG：%s\n' "$DMG_SPCTL"
# 挂上去，验里面那份 .app
cleanup() { if mount | grep -q " $MNT "; then hdiutil detach "$MNT" -quiet || true; fi; }
trap cleanup EXIT
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" -quiet
INNER="$MNT/$APP_NAME.app"
[ -d "$INNER" ] || fail "DMG 里没有 $APP_NAME.app"
[ -L "$MNT/Applications" ] || fail "DMG 里没有 /Applications 快捷方式"
codesign --verify --deep --strict --verbose=2 "$INNER"
INNER_SPCTL="$(spctl -a -vv -t exec "$INNER" 2>&1 || true)"
printf '里面的 .app：%s\n' "$INNER_SPCTL"
# 清单里只记判定与来源，不记本机路径（DMG 的挂载点是临时目录，写进去没意义）
# 注意 BSD sed 的 BRE 不支持 \|，要用 -E 的 ERE。
verdict() { printf '%s' "$1" | sed -n -E 's/.*: (accepted|rejected).*/\1/p; s/^(source=.*)/ \1/p' | tr -d '\n'; }
DMG_VERDICT="$(verdict "$DMG_SPCTL")"
INNER_VERDICT="$(verdict "$INNER_SPCTL")"
INNER_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INNER/Contents/Info.plist")"
[ "$INNER_VERSION" = "$VERSION" ] || fail "DMG 里的 .app 版本是 $INNER_VERSION"
INNER_SPARKLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                  "$INNER/Contents/Frameworks/Sparkle.framework/Resources/Info.plist")"
INNER_PUBKEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INNER/Contents/Info.plist")"
INNER_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INNER/Contents/Info.plist")"
if [ "$INNER_PUBKEY" = "__SUPublicEDKey__" ]; then
  PUBKEY_STATE="占位符（这份构建不接受任何更新）"
else
  PUBKEY_STATE="已配置（sha256 前 8 位 $(printf '%s' "$INNER_PUBKEY" | shasum -a 256 | cut -c1-8)）"
fi
echo "DMG 里：$APP_NAME $INNER_VERSION，Sparkle $INNER_SPARKLE，更新源 $INNER_FEED，公钥 $PUBKEY_STATE"
DMG_MOUNTED_APP_BYTES="$(du -sk "$INNER" | cut -f1)"
hdiutil detach "$MNT" -quiet
trap - EXIT

# ---------------------------------------------------------------- 8. 清单
step "8. sha256 与清单"
DMG_SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
APP_CDHASH="$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^CDHash=//p')"
MANIFEST="$OUT/manifest.json"
cat > "$MANIFEST" <<JSON
{
  "product": "$APP_NAME",
  "version": "$VERSION",
  "built_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "dmg": {
    "name": "$(basename "$DMG")",
    "bytes": $DMG_BYTES,
    "sha256": "$DMG_SHA",
    "volume_name": "$VOLNAME",
    "format": "UDZO/zlib-9, HFS+"
  },
  "app": {
    "bundle_id": "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")",
    "cdhash": "$APP_CDHASH",
    "installed_kib": $DMG_MOUNTED_APP_BYTES,
    "sparkle_version": "$INNER_SPARKLE",
    "feed_url": "$INNER_FEED",
    "public_ed_key": "$PUBKEY_STATE"
  },
  "signing": {
    "team_id": "$TEAM_ID",
    "secure_timestamp": $([ "$HAS_TIMESTAMP" = 1 ] && echo true || echo false),
    "notarized": $([ "$NOTARIZED" = 1 ] && echo true || echo false)
  },
  "gatekeeper": {
    "dmg": "$DMG_VERDICT",
    "app_in_dmg": "$INNER_VERDICT"
  }
}
JSON
# plutil -lint 不认 JSON（会按 plist 解析后报 "Unexpected character {"），用 stdlib 的 json 校验。
PYTHONDONTWRITEBYTECODE=1 python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANIFEST" \
  || fail "manifest.json 不是合法 JSON"
printf '%s  %s\n' "$DMG_SHA" "$(basename "$DMG")" > "$OUT/SHA256SUMS.txt"
rm -rf "$STAGE" "$MNT"

# appcast 用的归档目录：每个版本的 DMG 都硬链一份过去，
# generate_appcast 要在一个目录里看到所有历史版本才能生成完整的 appcast。
ARCHIVE="$DIST_ROOT/appcast"
mkdir -p "$ARCHIVE"
rm -f "$ARCHIVE/$(basename "$DMG")"
ln "$DMG" "$ARCHIVE/$(basename "$DMG")" 2>/dev/null || cp "$DMG" "$ARCHIVE/"

step "完成"
printf 'DMG      ：%s\n' "$DMG"
printf 'sha256   ：%s\n' "$DMG_SHA"
printf '清单     ：%s\n' "$MANIFEST"
printf 'appcast 归档：%s\n' "$ARCHIVE/$(basename "$DMG")"
if [ "$NOTARIZED" = "0" ]; then
  printf '\n未公证：这份 DMG 只能自己装（Finder 右键「打开」），不要发给别人。\n'
  printf '解锁屏幕、配好 notarytool 凭据之后重跑（不加 --skip-notarize）即可。\n'
fi
printf '\n下一步（发版）：dist/make_appcast.sh 生成 appcast.xml，再看 dist/RELEASE.md。\n'
