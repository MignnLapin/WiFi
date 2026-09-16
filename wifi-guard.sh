#!/system/bin/sh
# =====================================================================
#  WiFi Guard v6 —— 按位置自动开关 WiFi 的常驻守护进程
#  环境：Android 16 + KernelSU / SukiSU-Ultra（以 root 运行）
#
#  逻辑：
#   · WiFi 关闭时：周期扫描，若扫到"已保存网络"的 SSID → 开启 WiFi
#   · WiFi 开启但未连接时：扫描确认，连续多轮都不在范围 → 关闭 WiFi
#   · 飞行模式：完全静默
#   · 尊重用户手动关闭：手动关掉后，须先离开范围再回来才会自动开启
# =====================================================================

MODDIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
case "$MODDIR" in
    ""|"/") MODDIR=/data/adb/modules/wifi_guard ;;
esac

RUN="$MODDIR/run"
LOG="$MODDIR/wifi-guard.log"
SAVED_FILE="$RUN/saved_ssids.txt"
SCAN_FILE="$RUN/scan_ssids.txt"
ARM_FILE="$RUN/armed"
OFF_MARK="$RUN/off_by_guard"
PIDFILE="$RUN/daemon.pid"
MANUAL_FILE="$RUN/manual_off_ts"

# 调试镜像：/data/local/tmp 下的文件 adb shell 无需 root 即可读取
DBG_DIR="/data/local/tmp/wifiguard"
DBG_LOG="$DBG_DIR/wifi-guard.log"
DBG_STATE="$DBG_DIR/state.txt"

mkdir -p "$RUN" "$DBG_DIR" 2>/dev/null
chmod 777 "$DBG_DIR" 2>/dev/null

# ------------------------- 默认参数（可被 wifi-guard.conf 覆盖）----------
CHECK_INTERVAL=30
SCAN_INTERVAL=120
SCAN_TIMEOUT=24
GRACE_AFTER_ENABLE=60
OFF_CONFIRM_ROUNDS=2
RESPECT_MANUAL_OFF=1
MANUAL_OFF_HOLD=900
MANAGE_MOBILE_DATA=1
QUIET_LOG_INTERVAL=600
LOG_MAX_BYTES=131072
WLAN_IFACE=wlan0

# 加载用户配置（wifi-guard.conf 中的值会覆盖上面的默认值）
CONF="$MODDIR/wifi-guard.conf"
if [ -f "$CONF" ]; then
    . "$CONF" 2>/dev/null
fi

logger() {
    _m="[$(date '+%m-%d %H:%M:%S')] $*"
    echo "$_m" >> "$LOG" 2>/dev/null
    echo "$_m" >> "$DBG_LOG" 2>/dev/null
    /system/bin/log -t WiFiGuard "$*" 2>/dev/null
    _sz=$(stat -c%s "$LOG" 2>/dev/null)
    if [ -n "$_sz" ] && [ "$_sz" -gt "$LOG_MAX_BYTES" ]; then
        tail -n 400 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
        tail -n 400 "$DBG_LOG" > "$DBG_LOG.tmp" 2>/dev/null && mv "$DBG_LOG.tmp" "$DBG_LOG" 2>/dev/null
    fi
}

# 只在状态发生跃迁时记一条日志，避免刷屏
last_state=""
state_change() {
    [ "$last_state" = "$1" ] && return 1
    last_state="$1"
    logger "状态: $2"
    return 0
}

# ------------------------- 状态检测 -------------------------

is_airplane_mode() {
    [ "$(settings get global airplane_mode_on 2>/dev/null)" = "1" ]
}

# cmd wifi status 首行："Wifi is enabled" / "Wifi is disabled"
# 注意必须先判断 disabled，因为 "disabled" 不含 "enabled" 子串但顺序更安全
wifi_enabled() {
    _s=$(cmd wifi status 2>/dev/null | head -1)
    case "$_s" in
        *disabled*|*Disabled*|*DISABLED*) return 1 ;;
        *enabled*|*Enabled*|*ENABLED*)    return 0 ;;
    esac
    [ "$(settings get global wifi_on 2>/dev/null)" = "1" ] && return 0
    return 1
}

# 修复要点：本机 dumpsys wifi 里没有 "Wi-Fi is connected"，
# 只有 cmd wifi status 才输出 "Wifi is connected to \"SSID\""，以它为准。
wifi_connected() {
    _s=$(cmd wifi status 2>/dev/null)
    echo "$_s" | grep -qi "is connected to" && return 0
    echo "$_s" | grep -q "Supplicant state: COMPLETED" && return 0
    # 兜底：网卡拿到 IPv4 地址即视为已连接
    ip addr show "$WLAN_IFACE" 2>/dev/null | grep -q "inet " && return 0
    return 1
}

# ------------------------- SSID 集合 -------------------------

# 已保存网络。实测格式（空格分隔，SSID 可能含空格，末列是安全类型）：
#   Network Id      SSID                         Security type
#   2            HUAWEI Mate 60 RS 非凡大师           wpa2-psk
# 修复要点：旧版只取 $2，会把带空格的 SSID 截断，这里拼接 2..NF-1
get_saved_ssids() {
    cmd wifi list-networks 2>/dev/null | awk '
        NR==1 { next }
        $1 ~ /^[0-9]+$/ && NF>=3 {
            s = ""
            for (i = 2; i <= NF-1; i++) s = s (s == "" ? "" : " ") $i
            if (s != "") print s
        }' | sort -u
}

# 扫描结果。实测格式：
#   BSSID              Frequency      RSSI           Age(sec)     SSID              Flags
#   a4:a4:6b:ab:db:01       5785        -63             11.421    GAOBU-LIBRARY     [WPA2-PSK-CCMP-128][ESS]
# 修复要点：SSID 从第 5 列拼到 Flags（以 "[" 开头）之前，兼容含空格的 SSID
get_scan_ssids() {
    cmd wifi list-scan-results 2>/dev/null | awk '
        NR==1 { next }
        NF>=6 && $1 ~ /^[0-9a-fA-F][0-9a-fA-F]:/ {
            s = ""
            for (i = 5; i <= NF; i++) {
                if ($i ~ /^\[/) break
                s = s (s == "" ? "" : " ") $i
            }
            if (s != "" && s != "<unknown ssid>") print s
        }' | sort -u
}

# 触发一次扫描并等待结果刷新（用最小 Age 判断新鲜度，比固定 sleep 可靠）
do_scan() {
    settings put global wifi_scan_always_enabled 1 >/dev/null 2>&1
    cmd wifi start-scan >/dev/null 2>&1
    _n=0
    while [ "$_n" -lt "$SCAN_TIMEOUT" ]; do
        sleep 3
        _n=$((_n + 3))
        _age=$(cmd wifi list-scan-results 2>/dev/null | awk 'NR>1 && $4 ~ /^[0-9]/ {print $4}' | sort -n | head -1)
        _ai=${_age%%.*}
        if [ -n "$_ai" ] && [ "$_ai" -le 20 ] 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# 求交集，命中则输出第一个匹配的 SSID
ssid_match() {
    [ -s "$SAVED_FILE" ] || return 1
    [ -s "$SCAN_FILE" ]  || return 1
    while IFS= read -r _s; do
        [ -z "$_s" ] && continue
        if grep -qxF -- "$_s" "$SCAN_FILE" 2>/dev/null; then
            echo "$_s"
            return 0
        fi
    done < "$SAVED_FILE"
    return 1
}

collect_ssids() {
    get_saved_ssids > "$SAVED_FILE" 2>/dev/null
    get_scan_ssids  > "$SCAN_FILE"  2>/dev/null
    SAVED_N=$(wc -l < "$SAVED_FILE" 2>/dev/null | tr -d ' ')
    SCAN_N=$(wc -l < "$SCAN_FILE" 2>/dev/null | tr -d ' ')
    [ -z "$SAVED_N" ] && SAVED_N=0
    [ -z "$SCAN_N" ]  && SCAN_N=0
}

# ------------------------- WiFi 控制 -------------------------

# 移动数据状态检测与控制
mobile_data_on() {
    [ "$(settings get global mobile_data 2>/dev/null)" = "1" ]
}

set_mobile_data() {
    # 参数：1=开启 0=关闭
    if [ "$1" = "1" ]; then
        svc data enable >/dev/null 2>&1
        settings put global mobile_data 1 >/dev/null 2>&1
    else
        svc data disable >/dev/null 2>&1
        settings put global mobile_data 0 >/dev/null 2>&1
    fi
}

enable_wifi() {
    logger "动作: 开启 WiFi"
    cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 || svc wifi enable >/dev/null 2>&1
    rm -f "$OFF_MARK" 2>/dev/null
    enable_ts=$(date +%s)
    off_confirm=0
    # 开启 WiFi 时关闭移动数据
    if [ "$MANAGE_MOBILE_DATA" = "1" ] && mobile_data_on; then
        logger "动作: 关闭移动数据（WiFi 已开启）"
        set_mobile_data 0
    fi
}

disable_wifi() {
    logger "动作: 关闭 WiFi（已连续 $off_confirm 轮确认不在已保存网络范围）"
    # 先落标记再关闭，用于区分"守护进程关的"和"用户手动关的"
    date +%s > "$OFF_MARK" 2>/dev/null
    cmd wifi set-wifi-enabled disabled >/dev/null 2>&1 || svc wifi disable >/dev/null 2>&1
    # 关闭 WiFi 时开启移动数据
    if [ "$MANAGE_MOBILE_DATA" = "1" ] && ! mobile_data_on; then
        logger "动作: 开启移动数据（WiFi 已关闭）"
        set_mobile_data 1
    fi
}

# ------------------------- 状态发布 -------------------------

publish_state() {
    {
        echo "pid=$$"
        echo "version=v8"
        echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "uptime_sec=$(( $(date +%s) - start_ts ))"
        echo "airplane=$(is_airplane_mode && echo on || echo off)"
        echo "wifi=$(wifi_enabled && echo on || echo off)"
        echo "connected=$(wifi_connected && echo yes || echo no)"
        echo "mobile_data=$(mobile_data_on && echo on || echo off)"
        echo "manage_data=$MANAGE_MOBILE_DATA"
        echo "armed=$ARMED"
        echo "off_confirm=$off_confirm"
        echo "saved_count=$SAVED_N"
        echo "scan_count=$SCAN_N"
        echo "last_match=$MATCHED"
        echo "loops=$loops"
    } > "$DBG_STATE" 2>/dev/null
    chmod 666 "$DBG_STATE" 2>/dev/null
}

# ------------------------- 主循环 -------------------------

ARMED=1
[ -f "$ARM_FILE" ] && ARMED=$(cat "$ARM_FILE" 2>/dev/null | tr -dc '01')
[ -z "$ARMED" ] && ARMED=1

off_confirm=0
enable_ts=0
last_scan=0
SAVED_N=0
SCAN_N=0
MATCHED=""
loops=0
quiet_ts=0
start_ts=$(date +%s)

set_armed() {
    [ "$ARMED" = "$1" ] && return 0
    ARMED=$1
    echo "$ARMED" > "$ARM_FILE" 2>/dev/null
    if [ "$ARMED" = "1" ]; then
        logger "布防: 已重新武装（下次扫到已保存网络会自动开启 WiFi）"
        rm -f "$MANUAL_FILE" 2>/dev/null
    else
        logger "布防: 检测到用户手动关闭 WiFi，需先离开范围或等待 ${MANUAL_OFF_HOLD}s 才会再次自动开启"
        date +%s > "$MANUAL_FILE" 2>/dev/null
    fi
}

# ---------- 单实例保护（PID 文件 + 延迟验证）----------
# 修复要点：并发启动时两个进程可能同时通过检查。
# 方案：写入 PID 后等待 3 秒，再次检查 PID 文件，如果不是自己则退出。
# 这样第二个进程会发现 PID 文件已被第一个进程写入，从而退出。
is_same_script() {
    [ -d "/proc/$1" ] || return 1
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q "wifi-guard.sh"
}

PIDFILE="$RUN/daemon.pid"
if [ -f "$PIDFILE" ]; then
    _old=$(cat "$PIDFILE" 2>/dev/null | tr -dc '0-9')
    if [ -n "$_old" ] && [ "$_old" != "$$" ] && is_same_script "$_old"; then
        echo "[$(date '+%m-%d %H:%M:%S')] 已有实例 PID=$_old 在运行，本进程 $$ 退出" >> "$DBG_LOG" 2>/dev/null
        exit 0
    fi
fi
echo $$ > "$PIDFILE" 2>/dev/null
chmod 666 "$PIDFILE" 2>/dev/null
sleep 3
_win=$(cat "$PIDFILE" 2>/dev/null | tr -dc '0-9')
if [ -n "$_win" ] && [ "$_win" != "$$" ]; then
    echo "[$(date '+%m-%d %H:%M:%S')] 竞争失败，由 PID=$_win 接管，本进程 $$ 退出" >> "$DBG_LOG" 2>/dev/null
    exit 0
fi

# ---------- 等待系统就绪 ----------
# service.sh 在开机早期就会被执行，此时 wifi / settings 服务可能还没起来，
# 必须等 sys.boot_completed，否则首轮 cmd wifi 全部失败。
wait_boot_completed() {
    _i=0
    while [ "$_i" -lt 100 ]; do
        [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
        sleep 3
        _i=$((_i + 1))
    done
    sleep 10
    # 再确认 cmd wifi 真的可用，最多重试 6 次（30 秒）
    _i=0
    while [ "$_i" -lt 6 ]; do
        cmd wifi status >/dev/null 2>&1 && break
        sleep 5
        _i=$((_i + 1))
    done
}

wait_boot_completed

logger "==== WiFi Guard v8 启动 (PID=$$, MODDIR=$MODDIR) ===="
logger "参数: CHECK=${CHECK_INTERVAL}s SCAN=${SCAN_INTERVAL}s 确认轮数=${OFF_CONFIRM_ROUNDS} 尊重手动关闭=${RESPECT_MANUAL_OFF} 管理流量=${MANAGE_MOBILE_DATA}"

# 初始化 last_state 为当前 WiFi 状态，避免启动时误判为"用户手动关闭"
if wifi_enabled; then
    last_state="on"
else
    last_state="off"
fi

# 首轮立即采集一次已保存网络，便于尽早发现问题
collect_ssids
logger "初始化: 已保存网络 ${SAVED_N} 个，当前扫描 ${SCAN_N} 个"
if [ "$SAVED_N" -eq 0 ]; then
    logger "警告: 已保存网络列表为空！请确认 cmd wifi list-networks 可用，否则不会有任何自动开启动作"
fi

# 启动时同步移动数据状态：WiFi 已开启则关流量，WiFi 已关闭则开流量
if [ "$MANAGE_MOBILE_DATA" = "1" ]; then
    if wifi_enabled && mobile_data_on; then
        logger "初始化: WiFi 已开启，关闭移动数据"
        set_mobile_data 0
    elif ! wifi_enabled && ! mobile_data_on; then
        logger "初始化: WiFi 已关闭，开启移动数据"
        set_mobile_data 1
    fi
fi

while true; do
    loops=$((loops + 1))
    now=$(date +%s)

    # ---------- 飞行模式：完全静默 ----------
    if is_airplane_mode; then
        state_change "airplane" "飞行模式开启，暂停所有动作"
        publish_state
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if wifi_enabled; then
        # ================= WiFi 已开启 =================
        if state_change "on" "WiFi 已开启"; then
            enable_ts=$now        # 给足连接宽限期，避免刚开就被关
            off_confirm=0
            set_armed 1           # WiFi 是开着的，说明在范围内
        fi

        if wifi_connected; then
            off_confirm=0
            publish_state
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # 已开启但未连接：宽限期内不做任何关闭判断
        if [ "$enable_ts" -gt 0 ] && [ $((now - enable_ts)) -lt "$GRACE_AFTER_ENABLE" ]; then
            publish_state
            sleep 10
            continue
        fi

        if [ $((now - last_scan)) -lt "$SCAN_INTERVAL" ]; then
            publish_state
            sleep "$CHECK_INTERVAL"
            continue
        fi

        logger "WiFi 已开启但未连接，扫描确认是否仍在已保存网络范围内"
        do_scan
        last_scan=$(date +%s)
        collect_ssids

        # 安全阀：读不到已保存网络时绝不关闭 WiFi（防止命令失效导致误关）
        if [ "$SAVED_N" -eq 0 ]; then
            logger "警告: 已保存网络为 0，本轮跳过关闭判断（安全阀）"
            off_confirm=0
            publish_state
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if MATCHED=$(ssid_match); then
            logger "未连接但仍在范围内（命中 $MATCHED），保持开启，等待系统自动重连"
            off_confirm=0
            set_armed 1
        else
            off_confirm=$((off_confirm + 1))
            logger "不在任何已保存网络范围内（已保存 ${SAVED_N}/扫描 ${SCAN_N}），确认轮次 ${off_confirm}/${OFF_CONFIRM_ROUNDS}"
            if [ "$off_confirm" -ge "$OFF_CONFIRM_ROUNDS" ]; then
                disable_wifi
                set_armed 1
                off_confirm=0
                last_state="off"
                publish_state
                sleep 5
                continue
            fi
        fi
    else
        # ================= WiFi 已关闭 =================
        if state_change "off" "WiFi 已关闭"; then
            last_scan=0     # 立即安排一次扫描
            # 判断这次关闭是不是守护进程干的
            if [ "$RESPECT_MANUAL_OFF" = "1" ] && [ ! -f "$OFF_MARK" ]; then
                set_armed 0
            fi
        fi

        if [ $((now - last_scan)) -lt "$SCAN_INTERVAL" ]; then
            publish_state
            sleep "$CHECK_INTERVAL"
            continue
        fi

        do_scan
        last_scan=$(date +%s)
        collect_ssids

        if [ "$SAVED_N" -eq 0 ]; then
            logger "警告: 已保存网络为 0，无法判断是否在范围内，跳过本轮"
            publish_state
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if MATCHED=$(ssid_match); then
            if [ "$ARMED" = "1" ]; then
                logger "检测到已保存网络 [$MATCHED]（已保存 ${SAVED_N}/扫描 ${SCAN_N}）"
                enable_wifi
                set_armed 1
                last_state="on"
                publish_state
                sleep 15
                continue
            else
                # 手动关闭后仍在原地：检查是否超过保持时间
                manual_ts=$(cat "$MANUAL_FILE" 2>/dev/null | tr -dc '0-9')
                if [ -n "$manual_ts" ] && [ $((now - manual_ts)) -ge "$MANUAL_OFF_HOLD" ]; then
                    logger "手动关闭已超过 ${MANUAL_OFF_HOLD}s，恢复自动开启"
                    rm -f "$MANUAL_FILE" 2>/dev/null
                    set_armed 1
                    logger "检测到已保存网络 [$MATCHED]（已保存 ${SAVED_N}/扫描 ${SCAN_N}）"
                    enable_wifi
                    last_state="on"
                    publish_state
                    sleep 15
                    continue
                fi
                # 手动关闭后仍在原地，不重复提示
                if [ $((now - quiet_ts)) -ge "$QUIET_LOG_INTERVAL" ]; then
                    quiet_ts=$now
                    logger "在范围内（$MATCHED）但 WiFi 是用户手动关闭的，保持关闭；离开范围或超过 ${MANUAL_OFF_HOLD}s 后会自动恢复"
                fi
            fi
        else
            # 离开范围了 → 重新布防，这样下次回到范围会自动开启
            set_armed 1
            if [ $((now - quiet_ts)) -ge "$QUIET_LOG_INTERVAL" ]; then
                quiet_ts=$now
                logger "未检测到已保存网络（已保存 ${SAVED_N}/扫描 ${SCAN_N}），保持关闭"
            fi
        fi
    fi

    publish_state
    sleep "$CHECK_INTERVAL"
done
