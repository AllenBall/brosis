#!/bin/bash
# tools/probe/install.sh —— 编译并把 D2 应用切换探针装成 LaunchAgent（幂等）。
# 用法: ./install.sh            正常安装
#       ./install.sh --rebuild  强制重新编译
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.brosis.probe"
UID_NUM="$(id -u)"
TARGET="gui/${UID_NUM}"

BUILD_DIR="${HOME}/Library/Caches/brosis-build/probe"     # 编译产物：不放项目目录（iCloud）
DATA_DIR="${HOME}/Library/Application Support/brosis-probe"
BIN_DIR="${DATA_DIR}/bin"
BIN="${BIN_DIR}/appswitch"
PLIST_SRC="${SRC_DIR}/${LABEL}.plist"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
STDOUT_LOG="${DATA_DIR}/probe.log"
STDERR_LOG="${DATA_DIR}/probe.err.log"

REBUILD=0
[ "${1:-}" = "--rebuild" ] && REBUILD=1

echo "==> 目录准备"
mkdir -p "${BUILD_DIR}" "${BIN_DIR}" "${HOME}/Library/LaunchAgents"

echo "==> 编译 appswitch.swift"
if [ "${REBUILD}" = "1" ] || [ ! -x "${BUILD_DIR}/appswitch" ] || [ "${SRC_DIR}/appswitch.swift" -nt "${BUILD_DIR}/appswitch" ]; then
    swiftc -O "${SRC_DIR}/appswitch.swift" -o "${BUILD_DIR}/appswitch"
    echo "    已编译: ${BUILD_DIR}/appswitch"
else
    echo "    复用已有二进制: ${BUILD_DIR}/appswitch"
fi
"${BUILD_DIR}/appswitch" --version >/dev/null

echo "==> 安装二进制到 ${BIN}"
cp -f "${BUILD_DIR}/appswitch" "${BIN}"
chmod 755 "${BIN}"

echo "==> 渲染 LaunchAgent 到 ${PLIST_DST}"
sed -e "s|__BIN__|${BIN}|g" \
    -e "s|__DATADIR__|${DATA_DIR}|g" \
    -e "s|__STDOUT__|${STDOUT_LOG}|g" \
    -e "s|__STDERR__|${STDERR_LOG}|g" \
    "${PLIST_SRC}" > "${PLIST_DST}"
plutil -lint "${PLIST_DST}" >/dev/null

echo "==> 加载（已加载则先卸载，保证幂等）"
if launchctl print "${TARGET}/${LABEL}" >/dev/null 2>&1; then
    launchctl bootout "${TARGET}/${LABEL}" || true
fi
launchctl bootstrap "${TARGET}" "${PLIST_DST}"
launchctl enable "${TARGET}/${LABEL}" 2>/dev/null || true
launchctl kickstart "${TARGET}/${LABEL}" 2>/dev/null || true

echo "==> 状态"
launchctl print "${TARGET}/${LABEL}" | sed -n '1,12p'
echo
echo "数据文件: ${DATA_DIR}/appswitch.jsonl"
echo "日志:     ${STDOUT_LOG}"
echo "出报告:   python3 \"${SRC_DIR}/report.py\" --days 3 --top 20 > \"${SRC_DIR}/results/d2_\$(date +%F).md\""
echo "卸载:     \"${SRC_DIR}/uninstall.sh\""
