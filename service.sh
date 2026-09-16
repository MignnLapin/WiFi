#!/system/bin/sh
# =====================================================================
#  KernelSU / SukiSU service.sh —— 开机后以 root(u:r:ksu:s0) 执行
#  设计原则：本脚本必须"秒退"，绝不 sleep 等待。
#  原因：KSU 会等待 service.sh 返回，在这里 sleep 30 会拖慢整机开机流程，
#        也容易被框架判定为卡死。等待开机的逻辑已移入 wifi-guard.sh 内部。
# =====================================================================

MODDIR=${0%/*}
case "$MODDIR" in
    /data/adb/modules/*) : ;;
    *) MODDIR=/data/adb/modules/wifi_guard ;;
esac

RUN="$MODDIR/run"
DBG_DIR="/data/local/tmp/wifiguard"
mkdir -p "$RUN" "$DBG_DIR" 2>/dev/null
chmod 777 "$DBG_DIR" 2>/dev/null

# 关键：保证脚本可执行位。KSU 从 zip 解包时权限可能是 644，
# 那样 init 无法执行 service.sh，表现为"模块装了但完全没反应"。
chmod 755 "$MODDIR" 2>/dev/null
for f in "$MODDIR"/*.sh; do
    [ -f "$f" ] && chmod 755 "$f" 2>/dev/null
done

# 开机日志：adb shell 无需 root 即可读 /data/local/tmp/wifiguard/boot.log
{
    echo "$(date '+%Y-%m-%d %H:%M:%S') [service.sh] 被 KernelSU 调起 (PID=$$, MODDIR=$MODDIR, ctx=$(id -Z 2>/dev/null))"
} >> "$DBG_DIR/boot.log" 2>/dev/null
chmod 666 "$DBG_DIR/boot.log" 2>/dev/null

# 允许 WiFi 关闭时后台扫描（失败也无妨，守护进程会重试）
settings put global wifi_scan_always_enabled 1 >/dev/null 2>&1

# 清理上一轮开机残留的 PID 文件（进程已随重启消失）
rm -f "$RUN/daemon.pid" 2>/dev/null

# 用 setsid 让守护进程脱离本脚本的会话与进程组，
# 避免 service.sh 退出时被 KSU 连带回收。
setsid sh "$MODDIR/wifi-guard.sh" </dev/null >/dev/null 2>&1 &

echo "$(date '+%Y-%m-%d %H:%M:%S') [service.sh] 已拉起 wifi-guard.sh" >> "$DBG_DIR/boot.log" 2>/dev/null
exit 0
