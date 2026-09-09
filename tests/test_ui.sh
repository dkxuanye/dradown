#!/bin/bash
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/dradown.sh"
PASS=0
FAIL=0

check() {
    local name="$1"
    shift
    if "$@"; then
        printf 'ok - %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf 'not ok - %s\n' "$name"
        FAIL=$((FAIL + 1))
    fi
}

contains() {
    local haystack="$1"
    local needle="$2"
    [[ "$haystack" == *"$needle"* ]]
}

menu_output="$(printf '0\n' | bash "$SCRIPT" 2>/dev/null)"
check "menu has one recommended guided action" contains "$menu_output" "[1] 开始刷机（推荐）"
check "menu keeps advanced concepts out of the first screen" bash -c '! grep -q "懒人模式\|pwnediBSS\|SRTG" <<< "$1"' _ "$menu_output"

info_output="$(bash "$SCRIPT" info 2>/dev/null || true)"
check "info prints detection header" contains "$info_output" "设备检测"
check "info reports device state or absence" bash -c 'grep -q "当前系统\|未检测到设备\|模式:" <<< "$1"' _ "$info_output"

restore_output="$(bash "$SCRIPT" restore 2>/dev/null || true)"
check "restore refuses to guess among multiple IPSWs" contains "$restore_output" "必须明确指定"

check "auto path does not bypass confirmation" bash -c '! grep -q "DRADOWN_YES=1 cmd_restore" "$1"' _ "$SCRIPT"
check "lock is re-entrant for the same process" bash -c 'grep -q "lock_pid" "$1" && grep -q "return 0" "$1"' _ "$SCRIPT"
check "download reports a known or unknown total clearly" bash -c 'grep -q "下载进度" "$1"' _ "$SCRIPT"

# bash 3.2 + set -u 回归防护
check "no bare \$VAR directly before non-ASCII (bash 3.2 misparse)" bash -c '! grep -qE "\$[A-Za-z_][A-Za-z0-9_]*[^ -~]" "$1"' _ "$SCRIPT"
check "set -u flags have defaults" bash -c 'grep -q "DRADOWN_GUIDED:=0" "$1" && grep -q "DRADOWN_CONFIRMED:=0" "$1" && grep -q "FETCH_QUIET:=0" "$1"' _ "$SCRIPT"
check "optional positional params (\$5+) use :- defaults" bash -c '! grep -qE "=\"\\\$[5-9]\"" "$1"' _ "$SCRIPT"
check "empty-array expansion is guarded" bash -c 'grep -q "JBFiles\[@\]+" "$1"' _ "$SCRIPT"

ipsw_usage="$(bash "$SCRIPT" ipsw 2>&1 || true)"
check "direct CLI ipsw path runs without unbound-variable crash" bash -c 'grep -q "用法" <<< "$1" && ! grep -q "unbound variable" <<< "$1"' _ "$ipsw_usage"

# 健壮性: 工作目录固定 / 下载完整性 / 上游锁定
check "script pins cwd to project dir" bash -c 'grep -q "^cd \"\$DIR\"" "$1"' _ "$SCRIPT"
check "curl downloads via .part temp file" bash -c 'grep -q "ipsw.part" "$1"' _ "$SCRIPT"
check "LIK upstream is pinned to a commit" bash -c 'grep -qE "LIK_COMMIT=\"[0-9a-f]{40}\"" "$1"' _ "$SCRIPT"
check "sha256 manifest verifies all bundled files" bash -c 'cd "$1" && shasum -a 256 -c sha256sums.txt >/dev/null 2>&1' _ "$ROOT"

other_cwd_output="$(cd /tmp && bash "$SCRIPT" info 2>/dev/null || true)"
check "info works when invoked from another directory" contains "$other_cwd_output" "设备检测"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
