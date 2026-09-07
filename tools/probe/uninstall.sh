#!/bin/bash
# tools/probe/uninstall.sh —— 卸载 D2 应用切换探针（幂等）。
# 用法: ./uninstall.sh           停服务、删 LaunchAgent 与二进制，保留已采集数据
#       ./uninstall.sh --purge   连同 ~/Library/Application Support/brosis-probe 一起删除
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.brosis.probe"
TARGET="gui/$(id -u)"
DATA_DIR="${HOME}/Library/Application Support/brosis-probe"
PLIST_DST="${HOME}/Library/LaunchAgents/${LABEL}.plist"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "==> 停止服务"
if launchctl print "${TARGET}/${LABEL}" >/dev/null 2>&1; then
    launchctl bootout "${TARGET}/${LABEL}" || true
    echo "    已 bootout ${TARGET}/${LABEL}"
else
    echo "    服务未加载，跳过"
fi

echo "==> 删除 LaunchAgent"
rm -f "${PLIST_DST}" && echo "    ${PLIST_DST}"

echo "==> 删除已安装的二进制"
rm -f "${DATA_DIR}/bin/appswitch"
rmdir "${DATA_DIR}/bin" 2>/dev/null || true

if [ "${PURGE}" = "1" ]; then
    echo "==> --purge：删除数据目录 ${DATA_DIR}"
    rm -rf "${DATA_DIR}"
else
    echo "==> 保留数据目录 ${DATA_DIR}（加 --purge 可一并删除）"
    ls -la "${DATA_DIR}" 2>/dev/null || true
fi

echo "==> 编译缓存 ${HOME}/Library/Caches/brosis-build/probe 未删除，可手动 rm -rf"
echo "完成。"
