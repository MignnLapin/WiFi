#!/system/bin/sh
# 卸载时清理
MODDIR=${0%/*}
[ -z "$MODDIR" ] && MODDIR=/data/adb/modules/wifi_guard

# 清理运行时缓存与日志
rm -rf "$MODDIR/run"    2>/dev/null
rm -f  "$MODDIR/wifi-guard.log" 2>/dev/null

# 不强制改动 WiFi 开关状态，保留用户退出前的设置
exit 0