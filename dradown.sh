#!/bin/bash
# dradown.sh — iPhone 4S 终端刷机向导
#
# 基于 De Rebus Antiquis v6 / checkm8-a5。菜单适合新手，命令行入口供高级用户使用。
# 基础版本 iOS 6.1.3 由工具自动准备；目标版本是刷完后设备实际运行的系统。
#
# 命令行入口:
#   ./dradown.sh                 打开新手向导
#   ./dradown.sh setup            检查/下载工具与资源
#   ./dradown.sh info             查看设备状态
#   ./dradown.sh ipsw <版本>      只构建目标版本固件
#   ./dradown.sh restore <ipsw>   刷入明确指定的固件
#   ./dradown.sh auto <版本>      高级一键流程（仍会要求确认）
#   ./dradown.sh clean            清理工作缓存

set -o pipefail

# ---------- 固定参数 (iPhone 4S / DRA v6) ----------
DEV="iPhone4,1"
MODEL="n94ap"
HWMODEL="n94"        # 不带 ap 的机型名 (options plist 使用, 同 restore.sh 的 device_model)
HW="n94"
BASE_VERS="6.1.3"
BASE_BUILD="10B329"
EXPLOIT_PATH="src/target/n94/10B329/exploit"
KEYS_COMMIT="af6bf5934dc61ed557a967a3f42ab7fb8ed8c45e"
LIK_RAW="https://raw.githubusercontent.com/LukeZGD/Legacy-iOS-Kit/main"
KEYS_RAW="https://raw.githubusercontent.com/LukeZGD/Legacy-iOS-Kit-Keys/$KEYS_COMMIT"
IPSW_ME="https://api.ipsw.me/v4/device/$DEV"
ALL_FLASH="Firmware/all_flash/all_flash.${MODEL}.production"
DRA_BOOT_ARGS="pio-error=0 debug=0x2014e serial=3"
EXPECTED_IBOOT="iBoot-3582.4"   # iPhone 4S iOS 6.1.3 的 iBoot 版本

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/bin"
RES="$DIR/resources"
KEYS="$DIR/keys"
IPSWDIR="$DIR/ipsw"
WORK="$DIR/work"
SAVED="$DIR/saved"
JQ="$BIN/jq"
PLBUDDY=/usr/libexec/PlistBuddy

if [[ -t 1 ]]; then
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_RED='\033[0;31m'
    C_RESET='\033[0m'
else
    C_GREEN=''
    C_YELLOW=''
    C_RED=''
    C_RESET=''
fi

log()  { printf '%b%s%b %s\n' "$C_GREEN" "$(date '+%H:%M:%S')" "$C_RESET" "$*"; }
warn() { printf '%b提示%b: %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%b失败%b: %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

ui_title() {
    printf '\n%s\n' '==============================================='
    printf '  %s\n' "$1"
    printf '%s\n' '==============================================='
}

ui_pause() {
    printf '\n按回车返回上一级...'
    read -r || true
}

ui_help() {
    ui_title '使用帮助'
    cat <<EOF
这是一台 iPhone 4S 的刷机向导。

目标版本 = 刷完后设备要运行的 iOS 版本。
基础版本 = iOS $BASE_VERS，只用于准备刷机引导链，由工具自动处理。

开始前准备：
  1. 备份设备上的重要数据（刷机会清除全部内容）
  2. 准备 Arduino/Pico checkm8-a5 工具
  3. 准备数据线，并将设备直接连接到 Mac

刷机时，向导会提示你进入 DFU 并完成 pwn；之后不要拔线。
刷 iOS 5 可能导致蜂窝/基带不可用。遇到问题请按屏幕提示重试。
EOF
    ui_pause
}

ui_restore_confirm() {
    local target="$1"
    ui_title '确认刷入'
    printf '目标系统: iOS %s\n' "$target"
    printf '刷机引导: iOS %s（自动准备，不会成为最终系统）\n' "$BASE_VERS"
    printf '\n这次操作会清除 iPhone 上的全部内容。\n'
    case "$target" in
        5.*)
            printf '重要提示: iOS 5 可能导致蜂窝/基带不可用。\n'
            ;;
    esac
    printf '\n请确认：已备份数据，并准备好 Arduino/Pico pwn 工具。\n'
    printf '输入“继续”开始，直接按回车取消: '
    local answer
    read -r answer || return 1
    [[ "$answer" == '继续' || "$answer" == 'YES' || "$answer" == 'yes' ]]
}

ui_failure() {
    local stage="$1" logfile="$2"
    printf '\n刷机在“%s”阶段停止。\n' "$stage"
    [[ -n "$logfile" && -s "$logfile" ]] && printf '详细日志: %s\n' "$logfile"
    printf '设备可以安全重试；请按提示重新进入 DFU 并 pwn。\n'
}

ui_success() {
    local target="$1"
    ui_title '刷入完成'
    printf '已安装: iOS %s\n' "$target"
    printf 'iPhone 正在重启，首次开机可能需要几分钟。\n'
    printf '看到设置界面后即可断开数据线。\n'
}

ui_stage() {
    printf '\n[%s/4] %s\n' "$1" "$2"
}

ui_zip() {
    if [[ $DRADOWN_GUIDED == 1 ]]; then
        zip -r0 "$@" >/dev/null 2>&1
    else
        zip -r0 "$@"
    fi
}

fetch() { # fetch <url> <file>
    [[ -s "$2" ]] && return 0
    [[ $FETCH_QUIET == 1 ]] || log "准备 $(basename "$2") ..."
    curl -fsSL -o "$2" "$1" || err "下载失败，请检查网络后重试"
}

ui_download_group() {
    # ui_download_group <说明> <总数> <url/file>...
    local label="$1" total="$2" pair url file index=0
    shift 2
    for pair in "$@"; do
        url="${pair%%|*}"
        file="${pair#*|}"
        index=$((index + 1))
        printf '\r  %-18s %d/%d' "$label" "$index" "$total"
        FETCH_QUIET=1 fetch "$url" "$file"
    done
    printf '\r  %-18s 完成\n' "$label"
}

# ---------- setup ----------
cmd_setup() {
    # 完整下载/修补所有工具与资源 (全新环境一条命令就绪)
    local TOOLS=(powdersn0w idevicerestore irecovery ideviceinfo ideviceenterrecovery \
                 xpwntool hfsplus iBoot32Patcher img3maker tsschecker primepwn jq)
    local LIBS=(libgeneral.0.dylib libideviceactivation-1.0.2.dylib libimg4tool.0.dylib \
                libimobiledevice-1.0.6.dylib libimobiledevice-glue-1.0.0.dylib \
                libirecovery-1.0.3.dylib libplist-2.0.4.dylib libusbmuxd-2.0.6.dylib)

    mkdir -p "$BIN/lib" "$KEYS" "$IPSWDIR" "$WORK" "$SAVED" \
        "$RES/firmware/src/target/n94/10B329" "$RES/jailbreak"

    local t l pairs=()
    for t in "${TOOLS[@]}"; do
        pairs+=("$LIK_RAW/bin/macos/$t|$BIN/$t")
    done
    ui_download_group '准备工具' "${#TOOLS[@]}" "${pairs[@]}"
    pairs=()
    for l in "${LIBS[@]}"; do
        pairs+=("$LIK_RAW/bin/macos/lib/$l|$BIN/lib/$l")
    done
    ui_download_group '准备动态库' "${#LIBS[@]}" "${pairs[@]}"
    chmod +x "$BIN"/* 2>/dev/null

    pairs=(
        "$LIK_RAW/resources/firmware/src/bin.tar|$RES/firmware/src/bin.tar"
        "$LIK_RAW/resources/firmware/src/ios9.tar|$RES/firmware/src/ios9.tar"
        "$LIK_RAW/resources/firmware/src/partition|$RES/firmware/src/partition"
        "$LIK_RAW/resources/firmware/src/target/n94/10B329/exploit|$RES/firmware/src/target/n94/10B329/exploit"
        "$LIK_RAW/resources/jailbreak/freeze.tar.gz|$RES/jailbreak/freeze.tar.gz"
        "$LIK_RAW/resources/jailbreak/LukeZGD.tar|$RES/jailbreak/LukeZGD.tar"
    )
    ui_download_group '准备 DRA 资源' "${#pairs[@]}" "${pairs[@]}"

    "$BIN/jq" --version >/dev/null 2>&1 || err "jq 无法运行"
    "$BIN/irecovery" -h >/dev/null 2>&1 || err "irecovery 无法运行 (检查 bin/lib 动态库)"
    log "工具与资源已准备好。"
}

# ---------- 固件版本解析与下载 ----------
resolve_build() { # -> echo "build"
    local ver="$1" json build
    json="$(curl -s --fail "$IPSW_ME")" || err "无法访问 api.ipsw.me"
    build="$(echo "$json" | "$JQ" -r --arg v "$ver" \
        '.firmwares[] | select(.version == $v) | .buildid' | head -1)"
    [[ -n "$build" && "$build" != "null" ]] || err "未找到 $DEV 的 iOS $ver 版本"
    echo "$build"
}

ipsw_path_for() { # <vers> <build> -> echo path (无扩展名)
    echo "$IPSWDIR/${DEV}_$1_$2_Restore"
}

ensure_ipsw() { # <vers> <build> -> echo path
    local p="$(ipsw_path_for "$1" "$2")"
    if [[ ! -s "$p.ipsw" || -s "$p.ipsw.aria2" ]]; then
        local url="$(curl -s --fail "$IPSW_ME" | "$JQ" -r --arg b "$2" \
            '.firmwares[] | select(.buildid == $b) | .url' | head -1)"
        [[ -n "$url" && "$url" != "null" ]] || err "无法获取 $1 ($2) 的下载地址"
        # 获取总大小 (用于显示百分比)
        local total=0 clen
        clen="$(curl -sIL --max-time 20 "$url" | awk -F': ' 'tolower($1)=="content-length"{n=$2; gsub(/\r/,"",n); print n}' | tail -1)"
        [[ "$clen" =~ ^[0-9]+$ ]] && total="$clen"
        log "开始下载 $DEV $1 ($2) 官方固件 (共 $((total/1048576)) MB), 请勿断开网络 ..."
        if command -v aria2c >/dev/null; then
            aria2c --ca-certificate=/etc/ssl/cert.pem -x8 -s8 -k1M --file-allocation=none -q \
                -o "$(basename "$p").ipsw" -d "$(dirname "$p")" "$url" &
            local apid=$!
        else
            curl -sL -o "$p.ipsw" "$url" &
            local apid=$!
        fi
        # 进度显示: 每 5 秒打印一次百分比 (aria2c 后台运行)
        local have=0 pct=0 sec=0
        while kill -0 "$apid" 2>/dev/null; do
            sleep 5
            have="$(stat -f%z "$p.ipsw" 2>/dev/null || echo 0)"
            if (( total > 0 )); then
                pct=$((have * 100 / total))
                printf "    下载进度: %3d%%  (%d MB / %d MB)\n" "$pct" "$((have/1048576))" "$((total/1048576))"
            else
                printf "    已下载: %d MB ...\n" "$((have/1048576))"
            fi
            sec=$((sec+5))
        done
        wait "$apid" || { rm -f "$p.ipsw" "$p.ipsw.aria2"; err "下载失败, 请检查网络后重试"; }
        local final_sz="$(stat -f%z "$p.ipsw" 2>/dev/null || echo 0)"
        printf "    下载完成: 100%% (%d MB)\n" "$((final_sz/1048576))"
    fi
    echo "$p"
}

sha1_of() { shasum "$1" | cut -d' ' -f1; }

# ---------- firmware keys ----------
cmd_keys() { # <build> [build...]
    local b
    for b in "$@"; do
        fetch "$KEYS_RAW/$DEV/$b/index.html" "$KEYS/$b.json"
        "$JQ" -e '.keys' "$KEYS/$b.json" >/dev/null || err "keys 文件无效: $KEYS/$b.json"
        log "keys/$b.json OK ($("$JQ" '.keys | length' "$KEYS/$b.json") 个组件)"
    done
}

key_field() { # <build.json> <image> <field: iv|key|filename>
    "$JQ" -j --arg i "$2" '.keys[] | select(.image == $i) | .'"$3"' // empty' "$1"
}

bm_path() { # <BuildManifest.plist> <component> -> basename
    $PLBUDDY -c "Print :BuildIdentities:0:Manifest:$2:Info:Path" "$1" 2>/dev/null | tr -d '"' | xargs -I{} basename {} 2>/dev/null
}

# 提取 ipsw 内单个文件 (macOS bsdtar 支持 zip)
ipsw_extract_file() { # <ipsw> <内部路径> [目标目录]
    (cd "${3:-.}" && tar -xzOf "$1" "$2" > "$(basename "$2")") || err "从 IPSW 提取失败: $2"
}

# 解密恢复 ramdisk 并提取 options plist -> 输出 ./options.$MODEL.plist, RootSize
get_root_size() { # <ipsw> <build.json> <BuildManifest.plist>
    local ramdisk_name iv key
    ramdisk_name="$(bm_path "$3" "RestoreRamDisk")"
    [[ -z "$ramdisk_name" ]] && ramdisk_name="$(key_field "$2" "RestoreRamdisk" "filename")"
    [[ -z "$ramdisk_name" ]] && err "找不到 RestoreRamdisk 文件名"
    iv="$(key_field "$2" "RestoreRamdisk" "iv")"
    key="$(key_field "$2" "RestoreRamdisk" "key")"
    rm -f "options.${HWMODEL}.plist" "options.${MODEL}.plist" options.plist Ramdisk.raw
    ipsw_extract_file "$1" "$ramdisk_name"
    # 注意: xpwntool 会向 STDOUT 打印 img3.c 日志, 必须屏蔽, 否则污染后续捕获
    "$BIN/xpwntool" "$(basename "$ramdisk_name")" Ramdisk.raw -iv "$iv" -k "$key" > /dev/null || err "ramdisk 解密失败"
    # iOS 6+ ramdisk 内为 options.<hw>.plist (n94) 或 options.<hw>ap.plist (n94ap), 逐个尝试
    for opt in "usr/local/share/restore/options.${HWMODEL}.plist" \
               "usr/local/share/restore/options.${MODEL}.plist" \
               "usr/local/share/restore/options.plist"; do
        "$BIN/hfsplus" Ramdisk.raw extract "$opt" 2>/dev/null || true
        for f in "options.${HWMODEL}.plist" "options.${MODEL}.plist" options.plist; do
            [[ -s "$f" ]] && break 2
        done
    done
    [[ -s "options.${HWMODEL}.plist" ]] || [[ -s "options.${MODEL}.plist" ]] || [[ -s options.plist ]] \
        || err "无法从 ramdisk 提取 options plist"
    [[ -s options.${HWMODEL}.plist ]] || { [[ -s options.${MODEL}.plist ]] && mv "options.${MODEL}.plist" "options.${HWMODEL}.plist"; }
    [[ -s options.${HWMODEL}.plist ]] || { [[ -s options.plist ]] && mv options.plist "options.${HWMODEL}.plist"; }
    plutil -extract SystemPartitionSize xml1 "options.${HWMODEL}.plist" -o size 2>/dev/null || err "解析 SystemPartitionSize 失败"
    local sz="$(sed -ne '/<integer>/,/<\/integer>/p' size | sed -e 's/<integer>//' -e 's/<\/integer>//' | sed '2d' | tr -d '[:space:]')"
    rm -f size
    [[ "$sz" =~ ^[0-9]+$ ]] || err "SystemPartitionSize 非数字: [$sz]"
    echo $((sz + 30))
}

# 从 BuildManifest/keys 取组件名
comp_name() { # <BuildManifest.plist> <bm_key> <build.json> <keys_image>
    local n="$(bm_path "$1" "$2")"
    [[ -z "$n" ]] && n="$(key_field "$3" "$4" "filename")"
    [[ -z "$n" ]] && err "无法解析组件 $2 的文件名"
    echo "$n"
}

# ---------- Info.plist 生成 ----------
emit_keys_entry() { # <comp名> <build.json> <keys_image> <File路径> [PatchTrue] [DecryptPath] [extra: NewiBoot->IV/Key]
    local comp="$1" kj="$2" img="$3" file="$4" patch="$5" dpath="$6" iv key
    echo -n "<key>$comp</key><dict><key>File</key><string>$file</string>"
    iv="$(key_field "$kj" "$img" "iv")"; key="$(key_field "$kj" "$img" "key")"
    if [[ -n "$iv" ]]; then
        echo -n "<key>IV</key><string>$iv</string><key>Key</key><string>$key</string>"
    fi
    [[ "$patch" == "patch" ]] && echo -n "<key>Patch</key><true/>"
    [[ -n "$dpath" ]] && echo -n "<key>DecryptPath</key><string>$dpath</string>"
    echo -n "<key>Decrypt</key><true/>"
    echo "</dict>"
}

emit_path_entry() { # <comp名> <File路径(不含前缀)> [IV] [Key]
    local comp="$1" file="$2" iv="$3" key="$4"
    echo -n "<key>$comp</key><dict><key>File</key><string>$ALL_FLASH/$file</string>"
    [[ -n "$iv" ]] && echo -n "<key>IV</key><string>$iv</string><key>Key</key><string>$key</string>"
    echo "</dict>"
}

write_target_bundle() { # <targetvers> <targetbuild> <jb:0/1> <verbose:0/1>
    local tv="$1" tb="$2" jb="${3:-0}" verbose="${4:-0}"
    local t_ipsw="$(ipsw_path_for "$tv" "$tb").ipsw"
    local t_keys="$KEYS/$tb.json" t_bm="BuildManifest_target.plist"
    local bundle="FirmwareBundles/${DEV}_${tv}_${tb}.bundle"
    mkdir -p "$bundle"

    local rootfs_name kc_key="KernelCache" kc_dpath=""
    rootfs_name="$(comp_name "$t_bm" "OS" "$t_keys" "RootFS")"
    case "$tv" in
        [57]* ) kc_key="RestoreKernelCache"; kc_comp="RestoreKernelCache"; kc_dpath="Downgrade/RestoreKernelCache";;
    esac
    local rootfs_key="$(key_field "$t_keys" "RootFS" "key")"
    local rootfs_size="$(get_root_size "$t_ipsw" "$t_keys" "$t_bm")"
    [[ "$rootfs_size" =~ ^[0-9]+$ ]] || err "RootSize 脏值: [$rootfs_size]"
    local ramdisk_name="$(comp_name "$t_bm" "RestoreRamDisk" "$t_keys" "RestoreRamdisk")"
    local ibss_name="$(comp_name "$t_bm" "iBSS" "$t_keys" "iBSS")"
    local ibec_name="$(comp_name "$t_bm" "iBEC" "$t_keys" "iBEC")"
    local dtree_name="$(comp_name "$t_bm" "RestoreDeviceTree" "$t_keys" "DeviceTree")"
    local kc_name="$(comp_name "$t_bm" "$kc_key" "$t_keys" "Kernelcache")"
    local logo_name="$(comp_name "$t_bm" "AppleLogo" "$t_keys" "AppleLogo")"
    local rec_name="$(comp_name "$t_bm" "RecoveryMode" "$t_keys" "RecoveryMode")"
    local llb_name="$(comp_name "$t_bm" "LLB" "$t_keys" "LLB")"
    local iboot_name="$(comp_name "$t_bm" "iBoot" "$t_keys" "iBoot")"
    local logo7="${logo_name/applelogo/applelogo7}"
    local rec7="${rec_name/recoverymode/recoverymode7}"
    local iboot2="${iboot_name/iBoot/iBoot2}"
    local b0="$(comp_name "$t_bm" "BatteryCharging0" "$t_keys" "BatteryCharging0")"
    local b1="$(comp_name "$t_bm" "BatteryCharging1" "$t_keys" "BatteryCharging1")"
    local bf="$(comp_name "$t_bm" "BatteryFull" "$t_keys" "BatteryFull")"
    local bl0="$(comp_name "$t_bm" "BatteryLow0" "$t_keys" "BatteryLow0")"
    local bl1="$(comp_name "$t_bm" "BatteryLow1" "$t_keys" "BatteryLow1")"
    local bp="$(comp_name "$t_bm" "BatteryPlugin" "$t_keys" "GlyphPlugin")"
    local iboot_iv="$(key_field "$t_keys" "iBoot" "iv")"
    local iboot_key="$(key_field "$t_keys" "iBoot" "key")"

    # target bundle manifest: 从目标 IPSW 提取并追加改名条目
    ipsw_extract_file "$t_ipsw" "$ALL_FLASH/manifest" .
    { echo "$logo7"; echo "$rec7"; echo "$iboot2"; } >> manifest
    mv manifest "$bundle/"

    local P="$bundle/Info.plist"
    {
        echo '<plist><dict>'
        echo "<key>Filename</key><string>../ipsw/${DEV}_${tv}_${tb}_Restore.ipsw</string>"
        echo "<key>RootFilesystem</key><string>$rootfs_name</string>"
        echo "<key>RootFilesystemKey</key><string>$rootfs_key</string>"
        echo "<key>RootFilesystemSize</key><integer>$rootfs_size</integer>"
        echo "<key>RamdiskOptionsPath</key><string>/usr/local/share/restore/options.${HWMODEL}.plist</string>"
        echo "<key>SHA1</key><string>$(sha1_of "$t_ipsw")</string>"
        echo "<key>FilesystemPackage</key><dict><key>bootstrap</key><string>freeze.tar</string>"
        # LIK: [89]* 目标在 FilesystemPackage 里附加 ios9.tar
        case "$tv" in
            [89]* ) echo "<key>package</key><string>src/ios9.tar</string>";;
        esac
        echo "</dict>"
        # LIK: JB 时 ios 标记带版本号 (ios8/ios9), 非 JB 为 "ios"
        local ios_marker="ios"
        [[ $jb == 1 ]] && ios_marker="ios${tv:0:1}"
        echo "<key>RamdiskPackage</key><dict><key>package</key><string>src/bin.tar</string><key>ios</key><string>$ios_marker</string></dict>"
        echo '<key>Firmware</key><dict>'
        emit_keys_entry "iBSS" "$t_keys" "iBSS" "Firmware/dfu/$ibss_name" patch
        emit_keys_entry "iBEC" "$t_keys" "iBEC" "Firmware/dfu/$ibec_name" patch
        emit_keys_entry "RestoreDeviceTree" "$t_keys" "DeviceTree" "$ALL_FLASH/$dtree_name" "" "Downgrade/RestoreDeviceTree"
        if [[ -n "$kc_dpath" ]]; then
            emit_keys_entry "$kc_key" "$t_keys" "Kernelcache" "$kc_name" "" "$kc_dpath"
        else
            emit_keys_entry "$kc_key" "$t_keys" "Kernelcache" "$kc_name" patch
        fi
        emit_keys_entry "Restore Ramdisk" "$t_keys" "RestoreRamdisk" "$ramdisk_name"
        echo '</dict>'
        echo '<key>FirmwareReplace</key><dict>'
        # APTicket 仅 iOS 4 需要, 此处省略
        emit_path_entry "AppleLogo" "$logo7"
        emit_path_entry "NewAppleLogo" "$logo_name"
        emit_path_entry "BatteryCharging0" "$b0"
        emit_path_entry "BatteryCharging1" "$b1"
        emit_path_entry "BatteryFull" "$bf"
        emit_path_entry "BatteryLow0" "$bl0"
        emit_path_entry "BatteryLow1" "$bl1"
        emit_path_entry "BatteryPlugin" "$bp"
        emit_path_entry "RecoveryMode" "$rec7"
        emit_path_entry "NewRecoveryMode" "$rec_name"
        emit_path_entry "LLB" "$llb_name"
        emit_path_entry "iBoot" "$iboot_name"
        emit_path_entry "NewiBoot" "$iboot2" "$iboot_iv" "$iboot_key"
        echo "<key>manifest</key><dict><key>File</key><string>$ALL_FLASH/manifest</string><key>manifest</key><string>manifest</string></dict>"
        echo '</dict>'
        echo '</dict></plist>'
    } > "$P"

    # config.plist — LIK: JB 时 FilesystemJailbreak=true; powder target 恒为 needPref=true
    local fsjb="false"
    [[ $jb == 1 ]] && fsjb="true"
    local bargs_enabled="false" bargs="$DRA_BOOT_ARGS"
    if [[ $verbose == 1 ]]; then
        bargs_enabled="true"
        bargs="pio-error=0 -v"
    fi
    cat > FirmwareBundles/config.plist <<EOF
<plist>
<dict>
    <key>FilesystemJailbreak</key>
    <$fsjb/>
    <key>needPref</key>
    <true/>
    <key>iBootPatches</key>
    <dict>
        <key>debugEnabled</key>
        <false/>
        <key>bootArgsInjection</key>
        <$bargs_enabled/>
        <key>bootArgsString</key>
        <string>$bargs</string>
    </dict>
</dict>
</plist>
EOF
    log "target bundle 完成: $bundle (RootSize=$rootfs_size)"
}

write_base_bundle() { # <basevers> <basebuild>
    local bv="$1" bb="$2"
    local b_ipsw="$(ipsw_path_for "$bv" "$bb").ipsw"
    local b_keys="$KEYS/$bb.json" b_bm="BuildManifest_base.plist"
    local bundle="FirmwareBundles/BASE_${DEV}_${bv}_${bb}.bundle"
    mkdir -p "$bundle"
    # base bundle 同样需要 manifest 文件 (与 restore.sh ipsw_prepare_bundle 公共代码一致)
    ipsw_extract_file "$b_ipsw" "$ALL_FLASH/manifest" .
    mv manifest "$bundle/"

    local rootfs_name="$(comp_name "$b_bm" "OS" "$b_keys" "RootFS")"
    local rootfs_key="$(key_field "$b_keys" "RootFS" "key")"
    local rootfs_size="$(get_root_size "$b_ipsw" "$b_keys" "$b_bm")"
    [[ "$rootfs_size" =~ ^[0-9]+$ ]] || err "Base RootSize 脏值: [$rootfs_size]"
    local logo_name="$(comp_name "$b_bm" "AppleLogo" "$b_keys" "AppleLogo")"
    local rec_name="$(comp_name "$b_bm" "RecoveryMode" "$b_keys" "RecoveryMode")"
    local llb_name="$(comp_name "$b_bm" "LLB" "$b_keys" "LLB")"
    local iboot_name="$(comp_name "$b_bm" "iBoot" "$b_keys" "iBoot")"
    local b0="$(comp_name "$b_bm" "BatteryCharging0" "$b_keys" "BatteryCharging0")"
    local b1="$(comp_name "$b_bm" "BatteryCharging1" "$b_keys" "BatteryCharging1")"
    local bf="$(comp_name "$b_bm" "BatteryFull" "$b_keys" "BatteryFull")"
    local bl0="$(comp_name "$b_bm" "BatteryLow0" "$b_keys" "BatteryLow0")"
    local bl1="$(comp_name "$b_bm" "BatteryLow1" "$b_keys" "BatteryLow1")"
    local bp="$(comp_name "$b_bm" "BatteryPlugin" "$b_keys" "GlyphPlugin")"

    local P="$bundle/Info.plist"
    {
        echo '<plist><dict>'
        echo "<key>Filename</key><string>../ipsw/${DEV}_${bv}_${bb}_Restore.ipsw</string>"
        echo "<key>RootFilesystem</key><string>$rootfs_name</string>"
        echo "<key>RootFilesystemKey</key><string>$rootfs_key</string>"
        echo "<key>RootFilesystemSize</key><integer>$rootfs_size</integer>"
        echo "<key>RamdiskOptionsPath</key><string>/usr/local/share/restore/options.${HWMODEL}.plist</string>"
        echo "<key>SHA1</key><string>$(sha1_of "$b_ipsw")</string>"
        echo "<key>RamdiskExploit</key><dict><key>exploit</key><string>$EXPLOIT_PATH</string><key>inject</key><string>partition</string></dict>"
        echo '<key>Firmware</key><dict/>'
        echo '<key>FirmwarePath</key><dict>'
        emit_path_entry "AppleLogo" "$logo_name"
        emit_path_entry "BatteryCharging0" "$b0"
        emit_path_entry "BatteryCharging1" "$b1"
        emit_path_entry "BatteryFull" "$bf"
        emit_path_entry "BatteryLow0" "$bl0"
        emit_path_entry "BatteryLow1" "$bl1"
        emit_path_entry "BatteryPlugin" "$bp"
        emit_path_entry "RecoveryMode" "$rec_name"
        emit_path_entry "LLB" "$llb_name"
        emit_path_entry "iBoot" "$iboot_name"
        echo '</dict>'
        echo '</dict></plist>'
    } > "$P"
    log "base bundle 完成: $bundle (RootSize=$rootfs_size)"
}

# ---------- 实例锁 (防多实例抢设备) + 清理 trap ----------
DRADOWN_LOCK="$DIR/.dradown.lock"

cleanup_on_exit() {
    rm -f "$DRADOWN_LOCK"
    # 恢复可能被暂停的 macOS USB 设备代理
    killall -CONT AMPDevicesAgent AMPDeviceDiscoveryAgent MobileDeviceUpdater 2>/dev/null
}

acquire_lock() {
    local lock_pid="$(cat "$DRADOWN_LOCK" 2>/dev/null)"
    if [[ -n "$lock_pid" && "$lock_pid" == "$$" ]]; then
        return 0
    fi
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
        err "另一个 dradown 实例正在运行 (PID $lock_pid), 请先等待其完成"
    fi
    echo $$ > "$DRADOWN_LOCK"
    trap cleanup_on_exit EXIT
}

# ---------- 构建自定义 IPSW ----------
cmd_ipsw() {
    acquire_lock
    local tv="${1:-}"
    [[ -z "$tv" ]] && err "用法: $0 ipsw <目标版本>  例如: $0 ipsw 8.4.1"
    case "$tv" in
        5.* | 6.* | 7.* | 8.* | 9.* ) :;;
        * ) err "目标版本须在 5.0 - 9.3.6 范围内 (DRA v6 支持范围)";;
    esac
    local tb="$(resolve_build "$tv")"
    log "构建固件: 目标版本 $tv ($tb) / 基础版本 $BASE_VERS ($BASE_BUILD, 引导链, 自动)"
    echo "  （基础版本 $BASE_VERS 仅用于刷机引导链；刷完后设备运行的是目标版本 $tv）"

    if [[ $DRADOWN_GUIDED == 1 ]]; then
        ui_stage 1 '准备官方固件'
    fi
    ensure_ipsw "$tv" "$tb"
    local t_ipsw="$IPSWDIR/${DEV}_${tv}_${tb}_Restore.ipsw"
    ensure_ipsw "$BASE_VERS" "$BASE_BUILD"
    local b_ipsw="$IPSWDIR/${DEV}_${BASE_VERS}_${BASE_BUILD}_Restore.ipsw"
    cmd_keys "$tb" "$BASE_BUILD"

    if [[ $DRADOWN_GUIDED == 1 ]]; then
        printf '  官方固件已准备好。\n'
        ui_stage 2 '创建刷机固件'
    fi
    # 干净的工作目录
    rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK" || err "无法进入 work 目录"

    # 提取两份 BuildManifest
    tar -xzOf "../ipsw/${DEV}_${tv}_${tb}_Restore.ipsw" BuildManifest.plist > BuildManifest_target.plist \
        || err "提取 target BuildManifest 失败"
    tar -xzOf "../ipsw/${DEV}_${BASE_VERS}_${BASE_BUILD}_Restore.ipsw" BuildManifest.plist > BuildManifest_base.plist \
        || err "提取 base BuildManifest 失败"


    # restore.sh ipsw_preference_set: 8.x-9.x 的 powdersn0w/DRA 恢复强制启用越狱选项。
    # LIK 实测成功的 8.4.1 固件即为 JB 构建 (CustomJP6V), 必须对齐。
    local jb=0
    local verbose=0
    case "$tv" in
        [98]*) jb=1; verbose=1; log "iOS 8.x-9.x powdersn0w detected. Enabling jailbreak option (与 LIK 一致, 含 verbose 启动参数)";;
    esac
    write_target_bundle "$tv" "$tb" "$jb" "$verbose"
    # 保存一份未被 base 覆盖的原版 target options (修复 ramdisk SystemPartitionSize 用)
    # 注意必须在 write_base_bundle 之前 (base 的 get_root_size 会覆盖同名文件)
    cp "options.${HWMODEL}.plist" "$SAVED/options_${tb}.plist" 2>/dev/null \
        || err "保存 target options 副本失败"
    write_base_bundle "$BASE_VERS" "$BASE_BUILD"


    # 资源: src 树 (bin.tar + exploit) 与 partition 脚本
    cp -R "$RES/firmware/src" .
    cp "$RES/firmware/src/partition" partition
    # iPhone4,1 + DRA v6: partition 脚本中移除 nvram boot-ramdisk 行 (与 restore.sh 一致)
    sed -i.bak '/^nvram boot-ramdisk/d' partition && rm -f partition.bak
    # restore.sh 在运行 powdersn0w 前 cwd 留存的是 base 的 BuildManifest.plist
    cp BuildManifest_base.plist BuildManifest.plist

    # LIK: JB 时 cwd 需要 freeze.tar, 并附加 LukeZGD.tar 越狱包
    local JBFiles=()
    if [[ $jb == 1 ]]; then
        cp "$RES/jailbreak/freeze.tar.gz" .
        gzip -d -f freeze.tar.gz
        JBFiles=("$RES/jailbreak/LukeZGD.tar")
    fi

    log "运行 powdersn0w 构建自定义 IPSW ..."
    local ExtraArgs="" build_log="$DIR/logs/build-${tv}-${tb}.log"
    mkdir -p "$DIR/logs"
    if [[ $DRADOWN_GUIDED == 1 ]]; then
        "$BIN/powdersn0w" "../ipsw/${DEV}_${tv}_${tb}_Restore.ipsw" temp.ipsw \
            -base "../ipsw/${DEV}_${BASE_VERS}_${BASE_BUILD}_Restore.ipsw" $ExtraArgs ${JBFiles[@]} >"$build_log" 2>&1
    else
        "$BIN/powdersn0w" "../ipsw/${DEV}_${tv}_${tb}_Restore.ipsw" temp.ipsw \
            -base "../ipsw/${DEV}_${BASE_VERS}_${BASE_BUILD}_Restore.ipsw" $ExtraArgs ${JBFiles[@]}
    fi
    [[ -s temp.ipsw ]] || { [[ $DRADOWN_GUIDED == 1 ]] && ui_failure '创建刷机固件' "$build_log"; err "powdersn0w 构建失败 (未生成 temp.ipsw)"; }
    [[ $DRADOWN_GUIDED == 1 ]] && printf '  刷机固件已创建。\n'

    # 目标 < 7.x: 补 patch_iboot --logo (iBoot2 logo 补丁 + ibob 魔数) 并加入 all_flash
    case "$tv" in
        [789]* ) :;;
        * )
            log "目标 < 7.x, 执行 patch_iboot --logo + ibob 魔数改写 ..."
            local t_keys="$KEYS/$tb.json"
            local iboot_name="$(comp_name BuildManifest_target.plist "iBoot" "$t_keys" "iBoot")"
            local iboot_iv="$(key_field "$t_keys" "iBoot" "iv")"
            local iboot_key="$(key_field "$t_keys" "iBoot" "key")"
            local iboot2_name="${iboot_name/iBoot/iBoot2}"
            tar -xzOf temp.ipsw "$ALL_FLASH/$iboot2_name" > "$iboot2_name" 2>/dev/null \
                || err "从 custom IPSW 提取 iBoot2 失败"
            mv "$iboot2_name" iBoot.orig
            "$BIN/xpwntool" iBoot.orig iBoot.dec -iv "$iboot_iv" -k "$iboot_key" > /dev/null 2>&1 || err "iBoot2 解密失败"
            # 二进制可能已给 iBoot2 打过补丁; patcher 报 Nothing to patch 时直接使用
            "$BIN/iBoot32Patcher" iBoot.dec iBoot.pwned > /dev/null 2>&1 || true
            [[ -s iBoot.pwned ]] || cp iBoot.dec iBoot.pwned
            "$BIN/xpwntool" iBoot.pwned iBoot -t iBoot.orig > /dev/null 2>&1
            # ibot -> ibob 魔数 (使补丁版 iBoot 写入 NOR 的 ibob 槽位)
            echo "0000010: 626F" | xxd -r - iBoot
            echo "0000020: 626F" | xxd -r - iBoot
            "$BIN/xpwntool" iBoot.pwned "$iboot2_name" -t iBoot -iv "$iboot_iv" -k "$iboot_key" > /dev/null 2>&1
            mkdir -p "$ALL_FLASH"
            mv iBoot*.img3 "$ALL_FLASH/" 2>/dev/null
            mv "$iboot2_name" "$ALL_FLASH/" 2>/dev/null
            ui_zip temp.ipsw "$ALL_FLASH/"iBoot*.img3
        ;;
    esac

    battery_images "$tv" "$tb"
    fix_ramdisk_options "$tv" "$tb"

    local out="$DIR/${DEV}_${tv}_${tb}_CustomP6.ipsw"
    mv temp.ipsw "$out"
    cd "$DIR" || err "无法返回项目目录"
    if [[ $DRADOWN_GUIDED == 1 ]]; then
        printf '  已创建目标固件: iOS %s\n' "$tv"
    else
        log "完成! 自定义 IPSW: $out"
        echo
        echo "下一步: ./dradown.sh restore \"$out\""
    fi
}

# powdersn0w 二进制会把 ramdisk options 的 SystemPartitionSize 清零,
# 导致 restored_external 把系统分区缩到 0, ASR 报 "Not enough space"。
# 用原版 target options 覆盖 ramdisk 里的 options plist。
fix_ramdisk_options() {
    local tv="$1" tb="$2"
    local t_keys="$KEYS/$tb.json"
    local rd_name="$(bm_path "$SAVED/bm_target.plist" "RestoreRamDisk" 2>/dev/null)"
    [[ -z "$rd_name" ]] && rd_name="$(comp_name BuildManifest_target.plist "RestoreRamDisk" "$t_keys" "RestoreRamdisk")"
    local iv key optpath="usr/local/share/restore/options.${HWMODEL}.plist"
    iv="$(key_field "$t_keys" "RestoreRamdisk" "iv")"
    key="$(key_field "$t_keys" "RestoreRamdisk" "key")"
    [[ -s "$SAVED/options_${tb}.plist" ]] || err "缺少原版 options 副本"
    rm -f rd_fix.dmg rd_fix.dec rd_fix.img3
    # 关键: 二进制会在 cwd 遗留同名工作文件, 必须先清掉, 否则最后 zip 会把
    # 未注入的遗留文件当成交换后的 ramdisk 打回 IPSW (注入成果丢失的元凶)
    rm -f "$rd_name"
    tar -xzOf temp.ipsw "$rd_name" > rd_fix.dmg || err "提取 ramdisk 失败"
    "$BIN/xpwntool" rd_fix.dmg rd_fix.dec -iv "$iv" -k "$key" > /dev/null 2>&1 || err "ramdisk 解密失败"
    # 提取二进制处理过的 options (含关键的 UpdateBaseband=false), 只修正分区大小两个坏值,
    # 不可整文件覆盖 (会丢 UpdateBaseband=false 导致设备端刷基带失败)
    "$BIN/hfsplus" rd_fix.dec extract "$optpath" 2>/dev/null
    [[ -s "options.${HWMODEL}.plist" ]] || err "无法从 ramdisk 提取 options"
    local sp min
    sp="$(plutil -extract SystemPartitionSize raw "$SAVED/options_${tb}.plist" 2>/dev/null)"
    min="$(plutil -extract MinimumSystemPartition raw "$SAVED/options_${tb}.plist" 2>/dev/null)"
    [[ -n "$sp" ]] || err "无法读取原版 SystemPartitionSize"
    plutil -replace SystemPartitionSize -integer "$sp" "options.${HWMODEL}.plist" 2>/dev/null
    if [[ -n "$min" ]]; then
        plutil -replace MinimumSystemPartition -integer "$min" "options.${HWMODEL}.plist" 2>/dev/null || \
        plutil -insert MinimumSystemPartition -integer "$min" "options.${HWMODEL}.plist"
    fi
    plutil -replace UpdateBaseband -bool false "options.${HWMODEL}.plist" 2>/dev/null || \
    plutil -insert UpdateBaseband -bool false "options.${HWMODEL}.plist"
    "$BIN/hfsplus" rd_fix.dec delete "$optpath" 2>/dev/null
    "$BIN/hfsplus" rd_fix.dec add "options.${HWMODEL}.plist" "$optpath" || err "写入 options 失败"
    "$BIN/xpwntool" rd_fix.dec rd_fix.img3 -t rd_fix.dmg > /dev/null 2>&1 || err "ramdisk 重打包失败"
    mv rd_fix.img3 "$rd_name"
    ui_zip temp.ipsw "$rd_name" || err "回写 ramdisk 失败"
    log "已修复 ramdisk options (SystemPartitionSize=$sp, UpdateBaseband=false)"
}

# base 电池镜像回填 (restore.sh ipsw_prepare_battery_images 的等价实现)
battery_images() {
    local tv="$1" tb="$2"
    log "回填 base iOS 电池镜像 ..."
    tar -xzOf temp.ipsw "$ALL_FLASH/manifest" > manifest
    local bm_base="$SAVED/bm_base.plist" bm_target="$SAVED/bm_target.plist"
    tar -xzOf "../ipsw/${DEV}_${BASE_VERS}_${BASE_BUILD}_Restore.ipsw" BuildManifest.plist > "$bm_base"
    tar -xzOf "../ipsw/${DEV}_${tv}_${tb}_Restore.ipsw" BuildManifest.plist > "$bm_target"
    mkdir -p "$ALL_FLASH"
    local comp bn tn
    for comp in BatteryCharging0 BatteryCharging1 BatteryFull BatteryLow0 BatteryLow1 BatteryCharging BatteryPlugin; do
        bn="$($PLBUDDY -c "Print :BuildIdentities:0:Manifest:$comp:Info:Path" "$bm_base" 2>/dev/null | tr -d '"' | xargs -I{} basename {} 2>/dev/null)"
        tn="$($PLBUDDY -c "Print :BuildIdentities:0:Manifest:$comp:Info:Path" "$bm_target" 2>/dev/null | tr -d '"' | xargs -I{} basename {} 2>/dev/null)"
        [[ -z "$bn" ]] && { log "base 无 $comp, 跳过"; continue; }
        if [[ -z "$tn" ]]; then
            echo "$bn" >> manifest
            tn="$bn"
        fi
        rm -f "$bn" "$ALL_FLASH/$tn"
        tar -xzOf "../ipsw/${DEV}_${BASE_VERS}_${BASE_BUILD}_Restore.ipsw" "$ALL_FLASH/$bn" > "$bn" 2>/dev/null || continue
        [[ -s "$bn" ]] || continue
        cp "$bn" "$ALL_FLASH/$tn"
        rm -f "$bn"
    done
    mv manifest "$ALL_FLASH/"
    ui_zip temp.ipsw "$ALL_FLASH/"*
}

# ---------- 设备检测 ----------
cmd_info() {
    echo "设备检测:"
    if "$BIN/ideviceinfo" -k ProductType >/dev/null 2>&1; then
        local type="$("$BIN/ideviceinfo" -k ProductType)"
        local vers="$("$BIN/ideviceinfo" -k ProductVersion)"
        local ecid="$("$BIN/ideviceinfo" -k UniqueChipID)"
        echo "  设备:     iPhone 4S ($type)  ECID: $ecid"
        echo "  ─────────────────────────────────────────────"
        echo "  当前系统: iOS $vers   (设备现在跑的系统)"
        echo "  基础版本: iOS $BASE_VERS  (自动处理, 无需你操作)"
        echo "            └ 刷机时作为引导链打包进固件, 不是要刷的系统"
        echo "  目标版本: 由你选择 — 在菜单 [1] 或 [2] 里输入想刷的版本"
        echo "  ─────────────────────────────────────────────"
        if [[ "$vers" == "$BASE_VERS" ]]; then
            echo "  状态: ✅ 可刷写任意目标版本 (5.0-9.3.6); 6.x 目标带免签引导"
        else
            echo "  状态: ✅ 可刷写任意目标版本 (5.0-9.3.6), 与当前系统无关"
        fi
    elif "$BIN/irecovery" -q 2>/dev/null | grep -q CPID; then
        local q="$("$BIN/irecovery" -q)"
        local mode="$(echo "$q" | grep '^MODE' | cut -c7-)"
        local pwnd="$(echo "$q" | grep -i '^PWND' | cut -c7-)"
        echo "  模式:   ${mode:-未知}${pwnd:+ (已 pwn: $pwnd)}"
        case "$mode" in
            *DFU* )
                if [[ -n "$pwnd" ]]; then
                    echo "  状态:   ✅ 可直接刷入 — 运行 [1] 开始刷机 即可"
                else
                    echo "  状态:   DFU 模式 (未 pwn) — 请先用 Arduino 工具 pwn, 再运行 [1] 开始刷机"
                fi
            ;;
            *Recovery* )
                echo "  状态:   恢复模式 — 可直接运行 [1] 开始刷机 刷入"
            ;;
        esac
    else
        printf '  未检测到设备。请连接 iPhone 4S 后再试。\n'
        return 0
    fi
}

# ---------- 保存 DRA 所需票据 ----------
# LukeZGD 版 idevicerestore 的 -w (FLAG_DOWNGRADE) 模式要求本地存在
# shsh/<ECID>-<机型>-<目标版本>.shsh; DRA 流程的做法是: 用特制 OTA manifest
# 保存 base (6.1.3) 票据 (苹果至今仍在签 4S 6.1.3 OTA), 再复制为目标版本文件名。
# iOS 6 票据不含 ApNonce, 可直接用于目标版本组件。
save_dra_blob() { # <目标版本>
    local tv="$1"
    # ECID 优先从已有票据文件名推导 (票据与目标版本无关); 无则从设备读取
    local ecid
    local any_ticket="$(ls -t shsh/*.shsh 2>/dev/null | head -1)"
    if [[ -n "$any_ticket" ]]; then
        ecid="$(basename "$any_ticket" | cut -d- -f1)"
        log "从已存票据推导 ECID: $ecid"
    else
        ecid="$("$BIN/irecovery" -q 2>/dev/null | grep -i '^ECID' | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' | tr -d '[:space:]')"
        [[ -z "$ecid" ]] && ecid="$("$BIN/ideviceinfo" -k UniqueChipID 2>/dev/null | tr -d '[:space:]')"
    fi
    # 归一化为十进制 (idevicerestore 按十进制 ECID 查找票据文件)
    if [[ -n "$ecid" && "$ecid" == *[a-fA-Fx]* ]]; then
        ecid="$(( 16#${ecid#0x} ))"
    fi
    mkdir -p shsh
    local dst
    if [[ -n "$ecid" ]]; then
        dst="shsh/${ecid}-${DEV}-${tv}.shsh"
    else
        # 设备不可读时, 复用已有的票据文件
        dst="$(ls -t shsh/*-${DEV}-${tv}.shsh 2>/dev/null | head -1)"
        if [[ -s "$dst" ]]; then
            log "设备不可读, 复用已有票据: $dst"
            return 0
        fi
        err "无法读取设备 ECID 且无已存票据, 请连接设备"
    fi
    if [[ ! -s "$dst" ]]; then
        log "保存 base ${BASE_VERS} OTA 票据 (tsschecker) ..."
        rm -f ./${ecid}_*.shsh* 2>/dev/null
        "$BIN/tsschecker" -d "$DEV" -i "$BASE_VERS" -e "$ecid" \
            -m "$RES/manifest/BuildManifest_${DEV}_${BASE_VERS}.plist" \
            -o -s -B "${HWMODEL}ap" -b -g 0x1111111111111111 || err "tsschecker 保存票据失败"
        local src="$(ls -t ./${ecid}*.shsh* 2>/dev/null | head -1)"
        [[ -z "$src" ]] && err "未找到 tsschecker 输出文件"
        cp "$src" "$dst"
        rm -f "$src"
    fi
    log "票据就绪: $dst"
}

# ---------- 刷入 ----------
cmd_restore() {
    acquire_lock
    local custom="${1:-}"
    if [[ -z "$custom" ]]; then
        # 防呆: 存在多个版本的固件时禁止猜测, 必须明确指定
        local all_ipsvs=("$DIR"/${DEV}_*_CustomP6.ipsw)
        local count=0 i
        for i in "${all_ipsvs[@]}"; do [[ -s "$i" ]] && count=$((count+1)); done
        if [[ $count -eq 0 ]]; then
            err "没有找到已构建的自定义 IPSW, 先运行: $0 ipsw <版本>"
        elif [[ $count -gt 1 ]]; then
            echo "检测到多个版本的固件, 必须明确指定 (避免刷错版本):"
            local n=1
            for i in "${all_ipsvs[@]}"; do
                [[ -s "$i" ]] && echo "  [$n] $(basename "$i")" && n=$((n+1))
            done
            err "请用: $0 restore <上面完整路径> 重试"
        fi
        custom="${all_ipsvs[0]}"
    fi
    [[ -s "$custom" ]] || err "文件不存在: $custom"
    log "即将刷入: $custom"

    # 从自定义 IPSW 文件名解析目标版本和 build (离线, 不依赖网络)
    local parsed="$(basename "$custom" | sed -E "s/^${DEV}_([0-9.]+)_([A-Za-z0-9]+)_CustomP6\.ipsw$/\1 \2/")"
    local tv="${parsed%% *}"
    local tb2="${parsed##* }"
    [[ -z "$tv" || -z "$tb2" || "$tv" == "$parsed" ]] && err "无法从文件名解析目标版本: $(basename "$custom")"
    save_dra_blob "$tv"

    # 软检测: 设备尚未连接时不中断, 继续 pwned DFU 等待流程
    if "$BIN/ideviceinfo" -k ProductType >/dev/null 2>&1; then
        local dtype="$("$BIN/ideviceinfo" -k ProductType)" dvers="$("$BIN/ideviceinfo" -k ProductVersion)"
        echo "  设备: $dtype  版本: $dvers"
        [[ "$dtype" != "$DEV" ]] && warn "设备类型不是 $DEV"
        if [[ "$dvers" != "$BASE_VERS" ]]; then
            warn "设备当前 iOS $dvers (非 $BASE_VERS)。机制上 pwned DFU 直刷可行但未实测;"
            warn "稳妥路径: 先用 Arduino 流程刷到 $BASE_VERS, 再走本脚本 (已实测)。"
        fi
    elif "$BIN/irecovery" -q 2>/dev/null | grep -q CPID; then
        "$BIN/irecovery" -q 2>/dev/null | grep -E 'CPID|MODE|PWND|SRTG'
    else
        log "设备尚未连接, 继续等待 pwned DFU ..."
    fi
    if [[ $DRADOWN_CONFIRMED == 1 ]]; then
        log "已确认: 清除数据并安装 iOS $tv"
    else
        ui_restore_confirm "$tv" || return 0
    fi

    # DRA v6 刷入链路: pwned DFU -> primepwn 发送解包裸 iBSS -> idevicerestore。
    # 目标 build 已从固件文件名解析，不重复联网查询。
    [[ -n "$tb2" ]] || tb2="$(resolve_build "$tv")"
    mkdir -p work/pwnibss
    (
        cd work/pwnibss || exit 1
        # 从目标 IPSW 的 BuildManifest 动态解析 iBSS 路径 (各版本命名不同: n94/n94ap)
        tar -xzOf "../../ipsw/${DEV}_${tv}_${tb2}_Restore.ipsw" BuildManifest.plist > bm_pwn.plist 2>/dev/null
        local ibss_path="$($PLBUDDY -c "Print :BuildIdentities:0:Manifest:iBSS:Info:Path" bm_pwn.plist 2>/dev/null | tr -d '"' | xargs basename 2>/dev/null)"
        [[ -z "$ibss_path" ]] && ibss_path="iBSS.${HW}.RELEASE.dfu"
        tar -xzOf "../../ipsw/${DEV}_${tv}_${tb2}_Restore.ipsw" "Firmware/dfu/$ibss_path" > iBSS 2>/dev/null || exit 1
        [[ -s iBSS ]] || exit 1
        local iv key
        iv="$("$BIN/jq" -j '.keys[] | select(.image=="iBSS") | .iv' "$KEYS/$tb2.json")"
        key="$("$BIN/jq" -j '.keys[] | select(.image=="iBSS") | .key' "$KEYS/$tb2.json")"
        "$BIN/xpwntool" iBSS iBSS.dec -iv "$iv" -k "$key" > /dev/null 2>&1 || exit 1
        # 注意: iBoot32Patcher 成功时也可能返回非零, 以产物文件为准
        "$BIN/iBoot32Patcher" iBSS.dec pwnediBSS --rsa >/dev/null 2>&1
        [[ -s pwnediBSS ]] || exit 1
    ) || err "pwnediBSS 制作失败"
    [[ -s work/pwnibss/pwnediBSS ]] || err "pwnediBSS 不存在"

    ui_stage 3 '连接设备'
    local pwned="$("$BIN/irecovery" -q 2>/dev/null | grep -i '^PWND' | cut -c7-)"
    if [[ -n "$pwned" ]]; then
        echo '已检测到设备已准备好，正在继续。'
    else
        echo '请现在操作设备:'
        echo '  1. 让 iPhone 进入 DFU 模式（屏幕保持全黑）'
        echo '  2. 用 Arduino/Pico checkm8-a5 工具完成 pwn'
        echo '  3. pwn 成功后保持数据线连接，不要再操作设备'
        echo
        printf '等待 Arduino pwn'
    fi
    local waited=0 tick=0
    while [[ $waited -lt 600 ]]; do
        pwned="$($BIN/irecovery -q 2>/dev/null | grep -i '^PWND' | cut -c7-)"
        [[ -n "$pwned" ]] && break
        sleep 2; waited=$((waited+2)); tick=$((tick+2))
        if [[ $tick -ge 10 ]]; then
            printf '  已等待 %02d:%02d（最多 10:00）\n' "$((waited/60))" "$((waited%60))"
            printf '等待 Arduino pwn'
            tick=0
        fi
    done
    printf '\n'
    [[ -z "$pwned" ]] && err "10 分钟内未检测到 pwn。请重新进入 DFU 后重试。"
    log "已检测到设备，正在继续 ..."
    if [[ $DRADOWN_GUIDED == 1 ]]; then
        ui_stage 4 '刷入 iOS'
        "$BIN/primepwn" work/pwnibss/pwnediBSS >"$DIR/logs/pwn-${tv}-${tb2}.log" 2>&1 \
            || { ui_failure '准备设备' "$DIR/logs/pwn-${tv}-${tb2}.log"; err '设备准备失败，请重新进入 DFU 后重试'; }
    else
        "$BIN/primepwn" work/pwnibss/pwnediBSS || err "primepwn 发送失败: 设备可能未正确进入 PWNED DFU, 请重新 pwn 后重试"
    fi
    sleep 1
    [[ $DRADOWN_GUIDED == 1 ]] && printf '  正在连接刷机环境，请保持数据线连接...\n'
    log "等待设备以补丁版 iBSS 进入恢复模式 ..."
    local waited3=0 srtg="iBoot"
    while [[ $waited3 -lt 30 ]]; do
        srtg="$("$BIN/irecovery" -q 2>/dev/null | grep -i '^SRTG' | cut -c7-)"
        [[ -z "$srtg" ]] && break
        sleep 1; waited3=$((waited3+1))
    done
    if [[ -z "$srtg" ]]; then
        log "设备已进入 pwned iBSS 模式 (SRTG N/A), 开始刷入 ..."
    else
        warn "SRTG 仍在 ($srtg), pwnediBSS 可能未执行, 继续尝试刷入 ..."
    fi
    # 暂停 macOS USB 设备代理，避免与刷入通信冲突 (与 LIK restore.sh 一致)
    # 中断安全: Ctrl-C/异常退出时通过 EXIT trap 恢复代理
    killall -STOP AMPDevicesAgent AMPDeviceDiscoveryAgent MobileDeviceUpdater 2>/dev/null
    AGENTS_STOPPED=1
    # 自动重试: 其它设备的 usbmuxd 事件/USB 枚举竞态可能导致 restore 模式连接失败 (254)
    local attempt ret
    local restore_log="$DIR/logs/restore-${tv}-${tb2}.log"
    mkdir -p "$DIR/logs"
    : > "$restore_log"
    for attempt in 1 2 3 4 5; do
        [[ $attempt -gt 1 ]] && { warn "第 $attempt/5 次尝试 ..."; sleep 5; }
        if [[ $DRADOWN_GUIDED == 1 ]]; then
            printf '  正在刷入 iOS %s（请不要断开数据线）...\n' "$tv"
            "$BIN/idevicerestore" -ew "$custom" >>"$restore_log" 2>&1
        else
            "$BIN/idevicerestore" -ew "$custom"
        fi
        ret=$?
        [[ $ret -eq 0 ]] && break
        [[ $ret -ne 254 && $ret -ne 255 ]] && break
        warn "idevicerestore 返回 $ret (第 $attempt/5 次), 等待设备回到 pwned DFU 后重试"
        local waited2=0
        until "$BIN/irecovery" -q 2>/dev/null | grep -qi '^PWND'; do
            sleep 2; waited2=$((waited2+2))
            [[ $waited2 -ge 300 ]] && break
        done
    done
    echo
    # 刷入结束后恢复 macOS USB 设备代理
    killall -CONT AMPDevicesAgent AMPDeviceDiscoveryAgent MobileDeviceUpdater 2>/dev/null
    if [[ $ret -eq 0 ]]; then
        if [[ $DRADOWN_GUIDED == 1 ]]; then
            ui_success "$tv"
        else
            log "刷入流程结束。设备重启时 DRA exploit 会自动触发 (boot-partition=2)"
            log "如设备卡在恢复模式: 重启一次即可; 如需关闭 exploit, 可清空 NVRAM (boot-partition)"
        fi
    else
        local restore_log="$DIR/logs/restore-${tv}-${tb2}.log"
        ui_failure '刷入设备' "$restore_log"
        warn "详细工具输出已保存到: $restore_log"
    fi
}

cmd_clean() {
    rm -rf "$WORK"
    log "work 目录已清理"
}

# ---------- 一键自动化: 构建(缺则) + 等待 pwn + 刷入 ----------
cmd_auto() {
    acquire_lock
    local tv="${1:-}"
    [[ -z "$tv" ]] && err "用法: $0 auto <目标版本>"
    local tb auto_ipsw
    # 先复用已有目标固件；只有缺少时才访问网络解析 build
    auto_ipsw="$(ls "$DIR/${DEV}_${tv}_"*_CustomP6.ipsw 2>/dev/null | head -1)"
    if [[ -s "$auto_ipsw" ]]; then
        log "已找到目标固件: $(basename "$auto_ipsw")"
    else
        tb="$(resolve_build "$tv")" || err "无法解析 $tv 的 build 号 (网络问题)"
        auto_ipsw="$DIR/${DEV}_${tv}_${tb}_CustomP6.ipsw"
        log "正在创建目标固件..."
        DRADOWN_GUIDED=1 cmd_ipsw "$tv"
        [[ -s "$auto_ipsw" ]] || err "构建后未找到目标固件"
    fi
    log "正在准备刷入，请按提示完成 DFU 和 Arduino pwn..."
    if [[ $DRADOWN_CONFIRMED == 1 ]]; then
        DRADOWN_GUIDED=1 DRADOWN_CONFIRMED=1 cmd_restore "$auto_ipsw"
    else
        DRADOWN_GUIDED=1 cmd_restore "$auto_ipsw"
    fi
}

# ---------- 新手向导 ----------
cmd_choose_target() {
    ui_title '选择目标系统'
    echo '目标系统 = 刷完后 iPhone 要运行的 iOS 版本。'
    echo '基础版本 6.1.3 由工具自动准备，不需要选择。'
    echo
    echo '  [1] iOS 5.1.1  （蜂窝/基带可能不可用）'
    echo '  [2] iOS 6.1.3'
    echo '  [3] iOS 7.1.2'
    echo '  [4] iOS 8.4.1'
    echo '  [5] iOS 9.3.5'
    echo '  [6] 输入其他版本'
    echo '  [0] 返回'
    printf '\n请选择: '
    local choice target
    read -r choice || return 1
    case "$choice" in
        1) target='5.1.1';;
        2) target='6.1.3';;
        3) target='7.1.2';;
        4) target='8.4.1';;
        5) target='9.3.5';;
        6) printf '输入目标版本（例如 7.1.2）: '; read -r target || return 1;;
        0) return 1;;
        *) echo '请输入列表中的编号。'; ui_pause; return 1;;
    esac
    [[ -n "$target" ]] || return 1
    cmd_guided_restore "$target"
}

cmd_guided_restore() {
    local target="$1"
    ui_title '准备刷机'
    echo "目标系统: iOS $target"
    echo "基础版本: iOS $BASE_VERS（自动准备，仅用于刷机引导）"
    echo "刷完后设备运行: iOS $target"
    echo
    echo '这次操作会清除 iPhone 上的全部内容。'
    case "$target" in
        5.*) echo '重要提示: iOS 5 可能导致蜂窝/基带不可用。';;
    esac
    echo
    echo '开始前请确认:'
    echo '  • 已备份重要数据'
    echo '  • 已准备 Arduino/Pico checkm8-a5 工具'
    echo '  • 设备会先进入 DFU，再由你完成 pwn'
    echo
    printf '输入“继续”开始，直接按回车返回: '
    local answer
    read -r answer || return 0
    [[ "$answer" == '继续' || "$answer" == 'YES' || "$answer" == 'yes' ]] || return 0
    DRADOWN_GUIDED=1 DRADOWN_CONFIRMED=1 cmd_auto "$target"
}

# ---------- 新手菜单 (双击启动默认进入) ----------
cmd_menu() {
    while true; do
        ui_title 'iPhone 4S 刷机工具'
        echo '  [1] 开始刷机（推荐）'
        echo '  [2] 只构建固件'
        echo '  [3] 查看设备状态'
        echo '  [4] 工具检查与修复'
        echo '  [H] 使用帮助 / 已知风险'
        echo '  [0] 退出'
        printf '\n请选择: '
        local choice
        read -r choice || { echo; exit 0; }
        case "$choice" in
            1) cmd_choose_target;;
            2) ui_title '构建固件'; echo '只需要选择目标系统；基础版本会自动处理。'; printf '目标版本: '; read -r v; [[ -n "$v" ]] && cmd_ipsw "$v"; ui_pause;;
            3) cmd_info; ui_pause;;
            4) cmd_setup; ui_pause;;
            h|H) ui_help;;
            0|q|Q) exit 0;;
            *) echo '请输入 1、2、3、4、H 或 0。'; sleep 1;;
        esac
    done
}

# ---------- 已构建固件选择（高级/兼容入口） ----------
# 当前未接入菜单，保留以备后续版本使用
cmd_restore_menu() {
    local all_ipsvs=("$DIR"/${DEV}_*_CustomP6.ipsw)
    local list=() i
    for i in "${all_ipsvs[@]}"; do [[ -s "$i" ]] && list+=("$i"); done
    if [[ ${#list[@]} -eq 0 ]]; then
        echo '还没有已构建的固件，请使用“开始刷机”或“只构建固件”。'
        return
    fi
    echo '请选择要安装的目标系统:'
    local n=1
    for f in "${list[@]}"; do echo "  [$n] $(basename "$f")"; n=$((n+1)); done
    echo '  [0] 返回'
    printf '请选择: '
    local pick
    read -r pick || return
    [[ "$pick" == 0 ]] && return
    if [[ "$pick" =~ ^[0-9]+$ && $pick -ge 1 && $pick -le ${#list[@]} ]]; then
        cmd_restore "${list[$((pick-1))]}"
    else
        echo '请输入列表中的编号。'
    fi
}

case "$1" in
    setup)   cmd_setup;;
    info)    cmd_info;;
    keys)    shift; cmd_keys "$@";;
    ipsw)    shift; cmd_ipsw "$@";;
    auto)    shift; cmd_auto "$@";;
    restore) shift; cmd_restore "$@";;
    ""|menu) cmd_menu;;
    clean)   cmd_clean;;
    *) sed -n '2,16p' "$0";;
esac
