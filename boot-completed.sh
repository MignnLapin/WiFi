#!/system/bin/sh
# =====================================================================
#  KernelSU / SukiSU boot-completed.sh
#  在系统 BOOT_COMPLETED 之后由 KSU 调起，作为 service.sh 的双保险。
#  wifi-guard.sh 内部有单实例仲裁，重复调用不会有副作用。
# =====================================================================

MODDIR=${0%/*}
case "$MODDIR" in
    /data/adb/modules/*) : ;;
    *) MODDIR=/data/adb/modules/wifi_guard ;;
esac

DBG_DIR="/data/local/tmp/wifiguard"
mkdir -p "$MODDIR/run" "$DBG_DIR" 2>/dev/null
chmod 777 "$DBG_DIR" 2>/dev/null

for f in "$MODDIR"/*.sh; do
    [ -f "$f" ] && chmod 755 "$f" 2>/dev/null
done

echo "$(date '+%Y-%m-%d %H:%M:%S') [boot-completed.sh] 被调起 (PID=$$, ctx=$(id -Z 2>/dev/null))" >> "$DBG_DIR/boot.log" 2>/dev/null
chmod 666 "$DBG_DIR/boot.log" 2>/dev/null

# 守护进程若已在运行，它自己会检测到并退出，不会重复
if ! pgrep -f "$MODDIR/wifi-guard.sh" >/dev/null 2>&1; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') [boot-completed.sh] 未检测到守护进程，补拉起" >> "$DBG_DIR/boot.log" 2>/dev/null
    setsid sh "$MODDIR/wifi-guard.sh" </dev/null >/dev/null 2>&1 &
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [boot-completed.sh] 守护进程已在运行，跳过" >> "$DBG_DIR/boot.log" 2>/dev/null
fi

exit 0
