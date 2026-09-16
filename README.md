# WiFi 智能开关（KernelSU 模块）

**v8.0.0** — 进入已保存 WiFi 区域自动开启手机 WiFi；WiFi 断开或离开范围后自动关闭。  
**v8 新增**：KSU "执行"按钮立即重启守护进程，使配置生效。  
目标平台：**Android 16 + KernelSU**（以 root 权限运行）。

---

## 工作原理

守护进程周期性地检测 WiFi 状态与周围已保存网络：

| 当前状态 | 动作 |
|---------|------|
| 飞行模式 | 静默，不做任何开关 |
| WiFi 关闭 | 触发扫描 → 若扫描结果包含任一已保存 SSID → 开启 WiFi + **关闭移动数据** |
| WiFi 开启 + 已连接 | 保持 |
| WiFi 开启 + 已断开 | 触发扫描 → 扫描结果无已保存 SSID → 关闭 WiFi + **开启移动数据** |
| 启动时 WiFi 已开启 | 自动关闭移动数据 |

关键开关：`settings put global wifi_scan_always_enabled 1`  
该设置允许在 WiFi 关闭时仍然进行后台扫描，是 Android 7 起被 Google 文档化的能力，Android 16 仍然支持。

---

## 文件结构

```
wifi_guard/
├── module.prop          模块元信息
├── service.sh           开机启动入口（KernelSU 在 late_start 阶段以 root 执行）
├── action.sh            KSU "执行"按钮触发的脚本（热重载配置）
├── post-fs-data.sh      post-fs-data 钩子（占位，未使用）
├── boot-completed.sh    开机完成后的双保险启动
├── wifi-guard.sh        守护进程主循环（核心逻辑）
├── wifi-guard.conf      配置文件（所有可调参数集中于此）
├── uninstall.sh         卸载清理
└── run/                 运行时缓存（运行后自动生成）
    ├── daemon.pid       守护进程 PID（单实例锁）
    ├── reload           重载信号文件（action.sh 写入）
    ├── armed            武装状态（0=解除，1=武装）
    ├── manual_off_ts    手动关闭时间戳
    ├── saved_ssids.txt  已保存网络列表
    └── scan_ssids.txt   当前扫描到的网络列表
```

---

## 安装

将本目录整体复制为 `/data/adb/modules/wifi_guard/`。

```bash
# 在电脑上
adb push WiFi /data/adb/modules/wifi_guard

# 给予所有 .sh 可执行权限（KSU 安装器通常会处理 service.sh 等顶层脚本；
# 但保险起见手动确认一次）
adb shell chmod +x /data/adb/modules/wifi_guard/*.sh
adb shell chmod 755 /data/adb/modules/wifi_guard
adb shell chmod 644 /data/adb/modules/wifi_guard/module.prop
```

然后在 KernelSU 应用中：
1. 启用 `wifi_guard` 模块
2. **重启手机**

启动后等待约 30 秒（`service.sh` 中的 sleep），守护进程即开始工作。

---

## 配置参数

所有可调参数集中在 `wifi-guard.conf` 文件中，每个参数都有详细注释。

### 热重载配置

修改 `wifi-guard.conf` 后，无需重启手机，在 KernelSU 中点击 `wifi_guard` 模块的 **"执行"** 按钮即可立即生效。

该操作会立即重启守护进程，新进程启动时读取最新配置。

### 参数一览

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `CHECK_INTERVAL` | 30 | 主循环检查间隔（秒） |
| `SCAN_INTERVAL` | 120 | WiFi 关闭时的扫描间隔（秒） |
| `SCAN_TIMEOUT` | 24 | 单次扫描超时（秒） |
| `GRACE_AFTER_ENABLE` | 60 | WiFi 开启后连接宽限期（秒） |
| `OFF_CONFIRM_ROUNDS` | 2 | 连续 N 轮确认不在范围才关闭 |
| `RESPECT_MANUAL_OFF` | 1 | 1=尊重手动关闭；0=强制开启 |
| `MANUAL_OFF_HOLD` | 900 | 手动关闭后最长保持时间（秒） |
| `MANAGE_MOBILE_DATA` | 1 | 1=同步切换移动数据 |
| `QUIET_LOG_INTERVAL` | 600 | 重复日志最小间隔（秒） |
| `LOG_MAX_BYTES` | 131072 | 日志上限（字节） |
| `WLAN_IFACE` | wlan0 | 无线网卡接口名 |

### 调灵敏度

- `SCAN_INTERVAL` 越小越灵敏，但更耗电
- 推荐：家用场景 60~120 秒；频繁移动场景可调至 30 秒

### 移动数据管理

- `MANAGE_MOBILE_DATA=1`（默认）：WiFi 开启时自动关闭移动数据，WiFi 关闭时自动开启
- `MANAGE_MOBILE_DATA=0`：不管理移动数据，保持用户原设置

---

## 查看日志

```bash
adb shell cat /data/adb/modules/wifi_guard/wifi-guard.log
```

日志超过 128KB 时自动截断为最近 500 行。

---

## 查看实时状态

```bash
adb shell cat /data/local/tmp/wifiguard/state.txt
```

输出示例：
```
pid=1827
version=v7
time=2026-09-15 17:47:08
wifi=on
connected=yes
mobile_data=off
manage_data=1
armed=1
saved_count=9
scan_count=6
```

---

## 卸载

在 KernelSU 中关闭模块即可。  
`uninstall.sh` 会清理 `run/` 缓存与日志文件，**不会**改动用户当前的 WiFi 开关状态。

---

## 注意事项

1. 部分 ROM（如部分 MIUI / HyperOS、ColorOS）会在系统层强制关闭后台扫描。  
   可在「设置 → 网络 → WiFi → 高级」中开启 "WiFi 始终可扫描" 之类的选项。  
   也可通过 ADB 检查：
   ```bash
   adb shell settings get global wifi_scan_always_enabled
   ```
   应为 `1`。

2. KernelSU 模块以 root 身份运行，本脚本不会改动用户的 WiFi 密码与已保存网络列表。

3. 飞行模式下脚本静默；飞行模式关闭后会自动恢复工作。

4. 如果你手动关闭 WiFi 立刻离开已保存网络范围，脚本不会"抢"着再开启；  
   它仅在你处于已保存网络范围内时维持 WiFi 开启。

5. 移动数据开关依赖 `svc data` 和 `settings put global mobile_data`，  
   部分定制 ROM 可能需要额外权限或不生效。

---

## 调试命令（无需 root）

```bash
# 查看状态
adb shell cat /data/local/tmp/wifiguard/state.txt

# 查看日志
adb shell tail -20 /data/local/tmp/wifiguard/wifi-guard.log

# 查看开机日志
adb shell cat /data/local/tmp/wifiguard/boot.log

# 查看进程
adb shell pgrep -af wifi-guard.sh
```
