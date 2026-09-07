#!/bin/bash
# 用 Sparkle 的 generate_appcast 给 dist 归档目录里的 DMG 生成 appcast.xml。
#
# appcast 是 Sparkle 的更新源：一份 RSS，每个 <item> 里有版本号、下载地址、大小，
# 以及**用你的 Ed25519 私钥签出来的 sparkle:edSignature**。app 里嵌的是对应的公钥
# （Info.plist 的 SUPublicEDKey），验不过就不装——所以私钥是发版的唯一凭证，
# 它只在你自己的钥匙串里，不进仓库、不进 CI、也不经过这个脚本的任何变量。
#
# 用法：
#   ./make_appcast.sh                       # 用钥匙串里的私钥（会弹一次钥匙串授权）
#   ./make_appcast.sh --ed-key-file <file>  # 用导出的私钥文件（换机时用）
#   ./make_appcast.sh --archive-dir <dir>   # 换归档目录（默认 dist/appcast）
#
# 前置：先跑过 dist/build_dmg.sh（它会把每个版本的 DMG 硬链到归档目录）。
set -euo pipefail

DIST_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$DIST_SRC/.." && pwd)"
APP_SRC="$REPO/app"

DIST_ROOT="${DIST_ROOT:-$HOME/Library/Caches/brosis-build/dist}"
ARCHIVE="${ARCHIVE:-$DIST_ROOT/appcast}"
ACCOUNT="ed25519"                 # generate_keys / generate_appcast 的默认钥匙串账户名
KEY_SERVICE="https://sparkle-project.org"   # Sparkle 私钥在钥匙串里的 service
ED_KEY_FILE=""
REPO_URL="${BROSIS_REPO_URL:-https://github.com/AllenBall/brosis}"
DOWNLOAD_PREFIX=""
MAX_VERSIONS="${MAX_VERSIONS:-5}"

step() { printf '\n==> %s\n' "$1"; }
fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --archive-dir)          ARCHIVE="${2:-}"; shift 2 ;;
    --ed-key-file)          ED_KEY_FILE="${2:-}"; shift 2 ;;
    --account)              ACCOUNT="${2:-}"; shift 2 ;;
    --download-url-prefix)  DOWNLOAD_PREFIX="${2:-}"; shift 2 ;;
    -h|--help)              sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                      fail "不认识的参数：$1（--help 看用法）" ;;
  esac
done

# ---------------------------------------------------------------- 1. 版本号与归档
step "1. 归档目录"
VERSION="$(sed -n 's/^[[:space:]]*static let version = "\([^"]*\)".*/\1/p' \
            "$APP_SRC/Sources/brosis/BuildInfo.swift" | head -1)"
[ -n "$VERSION" ] || fail "从 app/Sources/brosis/BuildInfo.swift 读不到 version"
[ -d "$ARCHIVE" ] || fail "归档目录不存在：$ARCHIVE
      先跑 dist/build_dmg.sh，它会把 DMG 硬链到这里。"
DMG_COUNT="$(find "$ARCHIVE" -maxdepth 1 -name '*.dmg' | wc -l | tr -d ' ')"
[ "$DMG_COUNT" -gt 0 ] || fail "$ARCHIVE 里一个 .dmg 都没有。先跑 dist/build_dmg.sh。"
echo "归档目录：$ARCHIVE（$DMG_COUNT 个 DMG），当前版本 $VERSION"

# 当前版本的 .app 如果还是占位公钥，签出来的 appcast 对它毫无意义（它拒绝一切更新）。
MANIFEST="$DIST_ROOT/$VERSION/manifest.json"
if [ -f "$MANIFEST" ] && grep -q '"public_ed_key": "占位符' "$MANIFEST"; then
  fail "$VERSION 这份构建的 SUPublicEDKey 还是占位符（见 $MANIFEST）。
      先生成密钥对、把公钥写进
      ~/Library/Application Support/brosis-dev/sparkle_public_ed_key.txt，
      重跑 dist/build_dmg.sh，再生成 appcast。步骤见 dist/RELEASE.md。"
fi

# ---------------------------------------------------------------- 2. 找 generate_appcast
# 它随 Sparkle 的 SwiftPM binaryTarget 一起解压在 --scratch-path 的 artifacts/ 下，
# 不在仓库里、也不需要单独安装。
step "2. 找 generate_appcast"
TOOL="${SPARKLE_BIN:-}"
if [ -z "$TOOL" ]; then
  for root in "${SCRATCH:-}" "$HOME/Library/Caches/brosis-build/dist-app" \
              "$HOME/Library/Caches/brosis-build/m1-dist-app" \
              "$HOME/Library/Caches/brosis-build/m1-app" \
              "$HOME/Library/Caches/brosis-build/app"; do
    [ -n "$root" ] || continue
    cand="$root/artifacts/sparkle/Sparkle/bin/generate_appcast"
    if [ -x "$cand" ]; then TOOL="$cand"; break; fi
  done
fi
[ -n "$TOOL" ] && [ -x "$TOOL" ] || fail "找不到 generate_appcast。
      它在 SwiftPM 的 scratch 里：<scratch>/artifacts/sparkle/Sparkle/bin/generate_appcast，
      先跑一次 app/build_app.sh 让 SwiftPM 把 Sparkle 的 binaryTarget 解出来，
      或者用 SPARKLE_BIN=<路径> 指定。"
echo "generate_appcast：$TOOL"

# ---------------------------------------------------------------- 3. 私钥
step "3. 私钥"
if [ -n "$ED_KEY_FILE" ]; then
  [ -f "$ED_KEY_FILE" ] || fail "--ed-key-file 指的文件不存在：$ED_KEY_FILE"
  echo "用私钥文件：$ED_KEY_FILE（不会被打印，也不会被拷走）"
  KEY_ARGS=(--ed-key-file "$ED_KEY_FILE")
else
  # 只查**存在性**：不加 -w，security 不需要读出密文，所以不会弹钥匙串授权框。
  # 真正读私钥是 generate_appcast 自己干的事，那一步会弹一次框，需要你点「允许」。
  if ! security find-generic-password -s "$KEY_SERVICE" -a "$ACCOUNT" > /dev/null 2>&1; then
    fail "钥匙串里没有 Sparkle 的 Ed25519 私钥（service $KEY_SERVICE，account $ACCOUNT）。
      这一步只有你本人能做（会弹钥匙串授权框）：
        <scratch>/artifacts/sparkle/Sparkle/bin/generate_keys
      它会把**私钥**存进你的登录钥匙串并把**公钥**打印出来。把公钥那一串写进
        ~/Library/Application Support/brosis-dev/sparkle_public_ed_key.txt
      然后重跑 app/build_app.sh（会把它写进 Info.plist 的 SUPublicEDKey）。
      换机器时用 generate_keys -x <文件> 导出、-f <文件> 导入，或用 --ed-key-file。
      详见 dist/RELEASE.md。"
  fi
  echo "钥匙串里有私钥（service $KEY_SERVICE，account $ACCOUNT）。generate_appcast 读它时会弹一次授权框。"
  KEY_ARGS=(--account "$ACCOUNT")
fi

# ---------------------------------------------------------------- 4. 生成
step "4. 生成 appcast.xml"
# 下载地址前缀：GitHub Release 的资产 URL 是按 tag 走的，所以新条目用**本次 tag**的前缀。
# 已经在 appcast 里的老条目 generate_appcast 会原样保留（它复用现有文件），
# 生成完请按 RELEASE.md 的清单核一眼每个 item 的 enclosure url。
[ -n "$DOWNLOAD_PREFIX" ] || DOWNLOAD_PREFIX="$REPO_URL/releases/download/v$VERSION/"
echo "下载地址前缀：$DOWNLOAD_PREFIX"
"$TOOL" "${KEY_ARGS[@]}" \
        --download-url-prefix "$DOWNLOAD_PREFIX" \
        --link "$REPO_URL" \
        --maximum-versions "$MAX_VERSIONS" \
        -o "$ARCHIVE/appcast.xml" \
        "$ARCHIVE"

[ -f "$ARCHIVE/appcast.xml" ] || fail "generate_appcast 没有产出 $ARCHIVE/appcast.xml"

step "5. 自检"
# 每个 item 都必须有 edSignature，否则装不上（Sparkle 会拒）。
ITEMS="$(grep -c '<item>' "$ARCHIVE/appcast.xml" || true)"
SIGS="$(grep -c 'sparkle:edSignature' "$ARCHIVE/appcast.xml" || true)"
echo "item 数 $ITEMS，edSignature 数 $SIGS"
[ "$ITEMS" = "$SIGS" ] || fail "有 $((ITEMS - SIGS)) 个 item 没有 edSignature"
grep -o 'url="[^"]*"' "$ARCHIVE/appcast.xml" | sed 's/^/  /'

printf '\n完成：%s\n' "$ARCHIVE/appcast.xml"
printf '发版时把 appcast.xml 和 brosis-%s.dmg 一起作为资产传到 GitHub Release（tag v%s）。\n' \
  "$VERSION" "$VERSION"
printf 'app 里的 SUFeedURL 指的是 %s/releases/latest/download/appcast.xml，\n' "$REPO_URL"
printf '也就是说**每次**发版都必须带上 appcast.xml 这个资产，否则更新源会指向旧的那一份。\n'
