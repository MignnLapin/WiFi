#!/system/bin/sh
# =====================================================================
#  KernelSU action.sh —— 在 KSU 中按"执行"按钮时触发
#  功能：立即重启守护进程，使 wifi-guard.conf 的新配置生效
# =====================================================================

MODDIR=${0%/*}
case "$MODDIR" in
    /data/adb/modules/*) : ;;
    *) MODDIR=/data/adb/modules/wifi_guard ;;
esac

RUN="$MODDIR/run"
DBG_DIR="/data/local/tmp/wifiguard"
PIDFILE="$RUN/daemon.pid"

# 杀掉所有 wifi-guard.sh 进程
_pids=$(ps -ef 2>/dev/null | grep "wifi-guard.sh" | grep -v grep | grep -v "sh -c" | awk '{print $2}')
if [ -n "$_pids" ]; then
    for _p in $_pids; do
        kill -9 "$_p" 2>/dev/null
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') [action.sh] 已杀掉守护进程 ($_pids)" >> "$DBG_DIR/boot.log" 2>/dev/null
fi
rm -f "$PIDFILE" 2>/dev/null

# 启动新的守护进程
chmod 755 "$MODDIR"/*.sh 2>/dev/null
setsid sh "$MODDIR/wifi-guard.sh" </dev/null >/dev/null 2>&1 &
_new_pid=$!
sleep 2
echo "$(date '+%Y-%m-%d %H:%M:%S') [action.sh] 已启动新守护进程 (PID=$_new_pid)" >> "$DBG_DIR/boot.log" 2>/dev/null
echo "配置已生效"
exit 0
