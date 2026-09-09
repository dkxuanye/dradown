#!/bin/bash
# 双击启动 dradown 终端向导
cd "$(dirname "$0")" || exit 1
printf '\n正在打开 iPhone 4S 刷机向导...\n'
if [[ ! -x bin/powdersn0w || ! -x bin/idevicerestore || ! -x bin/primepwn ]]; then
    printf '首次运行需要准备工具和资源，请保持网络连接。\n'
    ./dradown.sh setup || { printf '\n准备失败，请检查网络后重新打开本文件。\n'; read -r; exit 1; }
    printf '准备完成，正在打开向导...\n'
fi
printf '提示：刷机前请备份数据，并准备 Arduino/Pico checkm8-a5 工具。\n'
exec bash ./dradown.sh
