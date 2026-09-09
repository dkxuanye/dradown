#!/bin/bash
# 双击启动 dradown (iPhone 4S 免SHSH全版本刷写)
cd "$(dirname "$0")" || exit 1
if [[ ! -x bin/powdersn0w ]]; then
    echo "首次运行: 正在下载工具与资源 (约15MB, 需要网络)..."
    ./dradown.sh setup || { echo "下载失败, 请检查网络后重试"; read -r; exit 1; }
fi
exec bash ./dradown.sh
