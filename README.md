# 启动代理与壁纸 · start-proxy-wallpaper

一个 Windows PowerShell 脚本：双击桌面快捷方式，自动完成

1. 启动 **Clash Verge**
2. 打开**系统代理**（并防止被 Clash 的 proxy guard 改回去）
3. 启动 **Wallpaper Engine**（自动点掉 Steam 的「选择启动选项」弹窗）
4. 把 Clash 和 Steam 窗口**最小化**，只留桌面壁纸

## 环境要求

- Windows 10 / 11
- Windows PowerShell 5.1（系统自带，无需安装）
- 已安装 [Clash Verge (Rev)](https://github.com/clash-verge-rev/clash-verge-rev) 并能正常启动
- Steam 已登录，且已安装 **Wallpaper Engine**（AppID `431960`）

## 快速开始

1. 把本文件夹放到任意位置（路径含中文也没关系）
2. 双击 `install-shortcut.bat` → 桌面上会生成 `启动代理与壁纸.lnk`
3. 以后双击桌面上那个快捷方式即可

不想建快捷方式，也可以直接跑：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "start-proxy-wallpaper.ps1"
```

## 它到底做了什么

| 步骤 | 动作 |
| --- | --- |
| 1 | 启动 Clash Verge（已在运行则跳过），并把它的 `enable_system_proxy` 配置改回 `true` |
| 2 | 轮询 `7897` 端口，等内核**真正就绪**（而不是死等固定秒数） |
| 3 | 写注册表 `ProxyEnable` / `ProxyServer`，再 `InternetSetOption` 让系统立即生效 |
| 4 | **立即**拉起 `steam://rungameid/431960`，让 Steam 冷启动与后续步骤重叠 |
| 5 | 看门狗 3 秒：代理一旦被改回去就重设 |
| 6 | 处理 Wallpaper Engine 的「选择启动选项」弹窗：UIA 点「开始游戏」→ 回车 → 按比例坐标点击（三层兜底），并尝试勾选「始终使用此选项」 |
| 7 | 壁纸起来后，把 Clash Verge 和 Steam 窗口最小化 |

## 可配置项

全部集中在脚本顶部的 `# ================= 可配置项 =================` 区域：

- `$ClashExe` — Clash Verge 可执行文件路径
- `$ProxyServer` — 代理地址，默认 `127.0.0.1:7897`（Clash Verge 2.x 默认端口）
- `$WallpaperUrl` — 壁纸引擎的 Steam 启动链接
- `$ShortcutName` — 生成的桌面快捷方式名称
- `$ClashConfigDir` — Clash Verge 配置目录
- `$ClashReadyTimeout` / `$ProxyWatchSeconds` / `$WEDialogTimeout` — 各阶段超时（秒）
- `$WEDialogTitle` / `$WEButtonName` / `$WEAlwaysName` — 弹窗标题与按钮文字
- `$WEAutoCheckAlways` — 是否自动勾选「始终使用此选项」
- `$WEButtonRatioX` / `$WEButtonRatioY` — 坐标兜底时点击位置在弹窗内的相对比例
- `$MinimizeAfterStart` — 是否在壁纸启动后最小化 Clash / Steam
- `$MinimizeProcessNames` / `$MinimizeWindowTitles` — 最小化目标（进程名 / 窗口标题正则）
- `$MinimizeSettleMs` — 最小化前等待时间（毫秒）
- `-StartupDelay <秒>` — 启动参数，用于开机自启场景延时执行（默认 0）

## 日志

运行日志写在脚本同目录的 `last-run.log`（超过 200 KB 会自动删除重建）。
每次运行的开始与结束分别记为 `=== 开始 ===` / `=== 结束 ===`。

## 注意事项 / 已知限制

- **不需要管理员权限**。但如果 Clash 开启了 TUN / 虚拟网卡模式，本脚本不做处理。
- 首次运行 Steam 会弹「选择启动选项」。脚本会尝试勾选「始终使用此选项」，成功一次后 Steam 会记住，以后不再弹窗。
- 如果双击时 Clash 已经在托盘运行，脚本**不会**改写 `verge.yaml`（避免抢写配置文件），此时 Clash 界面的开关可能仍显示为「关」，但系统代理照样会被设置。
- 代理端口按 Clash Verge 2.x 默认的 `7897` 处理；如果你的端口不同，改 `$ProxyServer`。
- 安全软件可能提示「修改系统代理」「修改注册表」，需要允许。
- 最小化靠「进程名 + 窗口标题」双重匹配，标题正则默认锚定为 `^Clash Verge$` / `^Steam$`；如果你的窗口标题不同，改 `$MinimizeWindowTitles`。

## 文件说明

```
start-proxy-wallpaper.ps1   主脚本，全部逻辑（约 590 行，19 个函数）
install-shortcut.bat        双击即运行一次脚本（用于生成桌面快捷方式）
last-run.log                运行日志（自动生成，不建议提交到仓库）
```

## 免责声明

自用脚本，按现状提供。它会修改 Windows 系统代理设置与 Clash 配置文件，请自行确认风险。
