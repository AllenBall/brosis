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
# **只留最新一版**。`--download-url-prefix` 会把**本次新写**的条目全部指到同一个 tag，
# 而一次 GitHub Release 只传得了这一版的 DMG——留着老条目就等于在 appcast 里挂
# 4 个 404 链接（2026-09-09 实测：0.4.0 / 0.3.1 / 0.3.0 / 0.2.9 的 url 全变成了 v0.4.1）。
# Sparkle 判断"有没有新版"只看最新那条；老条目除了下载失败没有别的用处。
MAX_VERSIONS="${MAX_VERSIONS:-1}"
# **不发增量包**（2026-09-09 定的口径）。`generate_appcast` 默认会拿归档里每个旧 DMG
# 和最新版做二进制差分，生成最多 5 个 .delta 挂在 item 下面。它确实省流量
# （0.4.7→0.4.8 只要 1.2 MB，完整包 27 MB），但每个 delta 都是一条必须**跟着一起上传**
# 的资产：漏传一个，停在那个版本的机器就去下一个 404。发版清单因此从 2 个资产变成 7 个，
# 而这条路径一年也走不了几次、每次都要人肉核对。全量包是唯一一条"少传就当场看得见"的路。
# 想恢复增量，把这个数改回 5，并且把 RELEASE.md 第 5 步的资产清单一起改。
MAX_DELTAS=0

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
# 注意：`--download-url-prefix` 只对**本次新写**的条目生效，而 MAX_VERSIONS=1 之后
# 每次都只有一条，所以不会再出现老条目被改成新 tag 的情况（下面的 url 自检兜住）。
# 生成完请按 RELEASE.md 的清单核一眼每个 item 的 enclosure url。
[ -n "$DOWNLOAD_PREFIX" ] || DOWNLOAD_PREFIX="$REPO_URL/releases/download/v$VERSION/"
echo "下载地址前缀：$DOWNLOAD_PREFIX"
"$TOOL" "${KEY_ARGS[@]}" \
        --download-url-prefix "$DOWNLOAD_PREFIX" \
        --link "$REPO_URL" \
        --maximum-versions "$MAX_VERSIONS" \
        --maximum-deltas "$MAX_DELTAS" \
        -o "$ARCHIVE/appcast.xml" \
        "$ARCHIVE"

[ -f "$ARCHIVE/appcast.xml" ] || fail "generate_appcast 没有产出 $ARCHIVE/appcast.xml"

# 上一轮留下的 .delta 还躺在归档里。--maximum-deltas 0 只是不再**引用**它们，不会删文件，
# 留着迟早被谁按 `gh release upload …/*` 一把捞上去。既然不发增量，就地清掉。
if [ "$MAX_DELTAS" = 0 ]; then
  STALE="$(find "$ARCHIVE" -maxdepth 1 -name '*.delta' | wc -l | tr -d ' ')"
  if [ "$STALE" != 0 ]; then
    find "$ARCHIVE" -maxdepth 1 -name '*.delta' -delete
    echo "清掉 $STALE 个历史 .delta（本项目只发全量包）"
  fi
fi

step "5. 自检"
# 每个 item 都必须有 edSignature，否则装不上（Sparkle 会拒）。
ITEMS="$(grep -c '<item>' "$ARCHIVE/appcast.xml" || true)"
# **按 enclosure 数，不按 item 数**：一个 item 里除了正片还可能挂若干 delta，
# 每个 delta 也是一条 enclosure、也各有自己的签名。2026-09-09 首次带 delta 发版时，
# 老写法（item 数 == 签名数）算出「有 -5 个 item 没有 edSignature」这种假失败。
ENCLOSURES="$(grep -c '<enclosure' "$ARCHIVE/appcast.xml" || true)"
SIGS="$(grep -c 'sparkle:edSignature' "$ARCHIVE/appcast.xml" || true)"
echo "item 数 $ITEMS，enclosure 数 $ENCLOSURES，edSignature 数 $SIGS"
[ "$ENCLOSURES" = "$SIGS" ] \
  || fail "有 $((ENCLOSURES - SIGS)) 条 enclosure 没有 edSignature（缺签名的下载装不上）"

# **每个 url 都要指向本次的前缀，且文件真的在归档目录里。**
# 这是 2026-09-09 那次真出过的事：`--download-url-prefix` 把老条目的 url 也改成了新 tag，
# appcast 里挂了 4 个 404，而当时的自检只数签名、发现不了。这条在生成时就能拦住。
BAD_URL=0
for url in $(grep -oE 'url="[^"]*"' "$ARCHIVE/appcast.xml" | sed 's/url="//; s/"$//'); do
  case "$url" in
    "$DOWNLOAD_PREFIX"*) ;;
    *) printf 'ERROR: url 不指向本次前缀：%s\n' "$url" >&2; BAD_URL=1; continue ;;
  esac
  name="${url##*/}"
  [ -f "$ARCHIVE/$name" ] || { printf 'ERROR: 归档里没有这个文件：%s\n' "$name" >&2; BAD_URL=1; }
done
[ "$BAD_URL" = 0 ] || fail "appcast 里有指不到的下载链接（见上），发出去就是 404。"

# **条目版本必须等于 tag 版本。**
# 2026-09-09 差点发错一次：0.4.8 的 build_dmg 在装订那步失败退出，DMG 没被复制进归档，
# 于是归档里最新的还是 0.4.7，appcast 就把 0.4.7 那条挂到了 v0.4.8 的 tag 下。
# 上面那条 url 校验拦不住——它只验"文件在归档里"，而 0.4.7 的 DMG 确实在。
ITEM_VERSION="$(grep -oE '<sparkle:shortVersionString>[^<]+' "$ARCHIVE/appcast.xml" \
  | head -1 | sed 's/.*>//')"
[ "$ITEM_VERSION" = "$VERSION" ] \
  || fail "appcast 里的条目是 $ITEM_VERSION，而这次要发的是 $VERSION。
      多半是 build_dmg.sh 没跑完（DMG 没进归档目录 $ARCHIVE）。
      先确认 $ARCHIVE/brosis-$VERSION.dmg 在不在，再重跑这个脚本。"
# **不能再出现增量包。** 只发全量的前提是 appcast 里一条 delta 都不挂——挂了就等于
# 引用一个不会被上传的资产，停在旧版的机器会去下 404。
if grep -q 'sparkle:deltas\|\.delta"' "$ARCHIVE/appcast.xml"; then
  fail "appcast 里还有增量包条目，但本项目只发全量包（MAX_DELTAS=0）。"
fi
grep -o 'url="[^"]*"' "$ARCHIVE/appcast.xml" | sed 's/^/  /'

printf '\n完成：%s\n' "$ARCHIVE/appcast.xml"
printf '发版时把 appcast.xml 和 brosis-%s.dmg 一起作为资产传到 GitHub Release（tag v%s）。\n' \
  "$VERSION" "$VERSION"
printf 'app 里的 SUFeedURL 指的是 %s/releases/latest/download/appcast.xml，\n' "$REPO_URL"
printf '也就是说**每次**发版都必须带上 appcast.xml 这个资产，否则更新源会指向旧的那一份。\n'
