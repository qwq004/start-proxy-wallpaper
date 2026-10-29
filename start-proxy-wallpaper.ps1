<#
  一键启动：Clash Verge + 系统代理 + Wallpaper Engine

  首次运行会自动在桌面生成快捷方式；之后双击桌面快捷方式即可。
  - 无需管理员权限
  - 可重复运行（幂等）：已启动的不会重复开，代理重复设置无副作用
  - Wallpaper Engine 会经过 Steam 启动，并自动点掉「选择启动选项」弹窗里的「开始游戏」
  - 壁纸起来后，自动把 Clash Verge 和 Steam 的窗口最小化，只留桌面

  若路径/端口有变，改下面“可配置项”即可。
  运行日志写在脚本同目录 last-run.log，出问题可发回来定位。

  开机自启用法：把快捷方式放到启动文件夹（Win+R 输入 shell:startup），
  并给快捷方式的参数加上  -StartupDelay 20 ，让登录后再等 20 秒，避免和系统启动抢资源。
#>

param(
    [int]$StartupDelay = 0    # 登录自启时的等待秒数，手动双击时为 0
)

$ErrorActionPreference = 'SilentlyContinue'

if ($StartupDelay -gt 0) {
    Start-Sleep -Seconds $StartupDelay
}

# ================= 可配置项 =================
$ClashExe     = 'C:\Program Files\Clash Verge\clash-verge.exe'
$ProxyServer  = '127.0.0.1:7897'           # Clash Verge 端口（设置页「端口设置」= 7897）
$WallpaperUrl = 'steam://rungameid/431960' # Wallpaper Engine 的 Steam 游戏 ID
$ShortcutName = '启动代理与壁纸.lnk'

# ---- Clash Verge ----
$ClashConfigDir    = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"
$ClashReadyTimeout = 25         # 等内核真正监听端口的最长秒数（新版启动更慢，别再死等 3 秒）
$ProxyWatchSeconds = 3          # 写完代理后再盯几秒，防 Clash 的 proxy guard 覆盖（此时 WE 已在后台启动，不额外占时间）

# ---- Wallpaper Engine 启动弹窗处理 ----
$WEDialogTimeout   = 150        # 最多等待弹窗出现的秒数（Steam 冷启动较慢）
$WEDialogTitle     = 'Wallpaper Engine: 壁纸引擎'   # 弹窗标题，Win32 兜底用（留空则不用该兜底）
$WEAutoCheckAlways = $true      # 自动勾选「始终使用此选项」：成功一次后，以后不再弹窗
$WEButtonName      = '开始游戏'
$WEAlwaysName      = '始终使用此选项'
$WEButtonRatioX    = 0.50       # 兜底：按弹窗宽高比例的点击位置
$WEButtonRatioY    = 0.93

# ---- 收尾：壁纸起来后把这两个窗口最小化 ----
$MinimizeAfterStart  = $true
$MinimizeProcessNames = @('clash-verge', 'steam', 'steamwebhelper')  # 新版 Steam 的界面窗口常挂在 steamwebhelper 上
$MinimizeWindowTitles = @('^Clash Verge$', '^Steam$')               # 认不出进程时按窗口标题兜底（锚定，避免误伤浏览器标签页）
$MinimizeSettleMs    = 1500     # 等 Steam 把启动选项弹窗关干净再动手
# ===========================================

# ---------- 日志 ----------
$LogFile = Join-Path (Split-Path -Parent $PSCommandPath) 'last-run.log'
function Write-Log {
    param([string]$msg)
    try {
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 200KB)) {
            Remove-Item -LiteralPath $LogFile -Force
        }
        $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $msg
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }
}

# ---------- Win32 ----------
try {
    Add-Type -Namespace Dsh -Name Win32 -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern System.IntPtr FindWindowW(string lpClassName, string lpWindowName);

[DllImport("user32.dll")]
public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);

[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, System.UIntPtr dwExtraInfo);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr hWnd);
'@
} catch { }

# ---------- UI Automation ----------
$script:HasUia = $false
try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $script:HasUia = $true
} catch { }

function Get-TopLevelWindows {
    $out = New-Object System.Collections.ArrayList
    if (-not $script:HasUia) { return $out }
    try {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $kids = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Children,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($w in $kids) {
            if ($w.Current.Name) { [void]$out.Add($w) }
        }
    } catch { }
    return $out
}

function Find-ChildByName {
    param($Parent, [string]$Name)
    if (-not $Parent) { return $null }
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Name)
        return $Parent.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
    } catch { return $null }
}

function Click-AtPoint {
    param([int]$X, [int]$Y)
    try {
        [Dsh.Win32]::SetCursorPos($X, $Y) | Out-Null
        Start-Sleep -Milliseconds 150
        [Dsh.Win32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)  # LEFTDOWN
        Start-Sleep -Milliseconds 70
        [Dsh.Win32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)  # LEFTUP
    } catch { }
}

function Click-UiElement {
    param($El)
    if (-not $El) { return $false }
    # 方式 1：InvokePattern（不需要窗口获得焦点，最稳）
    try {
        $pat = $El.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
        if ($pat) { $pat.Invoke(); return $true }
    } catch { }
    # 方式 2：取按钮矩形，移动鼠标并真实点击
    try {
        $r = $El.Current.BoundingRectangle
        if ($r.Width -gt 0 -and $r.Height -gt 0) {
            Click-AtPoint -X ([int]($r.X + $r.Width / 2)) -Y ([int]($r.Y + $r.Height / 2))
            return $true
        }
    } catch { }
    return $false
}

function Set-AlwaysUseOption {
    param($Dialog)
    $cb = Find-ChildByName -Parent $Dialog -Name $WEAlwaysName
    if (-not $cb) { return $false }
    try {
        $pat = $cb.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($pat) {
            if ($pat.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { $pat.Toggle() }
            return $true
        }
    } catch { }
    return (Click-UiElement -El $cb)
}

function Test-WallpaperRunning {
    $procs = @(Get-Process -Name 'wallpaper64', 'wallpaper32', 'wallpaperui' -ErrorAction SilentlyContinue)
    return ($procs.Count -gt 0)
}

function Get-WallpaperDialog {
    foreach ($w in (Get-TopLevelWindows)) {
        try {
            if ($w.Current.Name -match 'Wallpaper\s*Engine|壁纸引擎') { return $w }
        } catch { }
    }
    return $null
}

# 弹窗矩形：优先 UIA，取不到就用 Win32 按标题找窗口（不依赖 UIA 是否暴露控件）
function Get-DialogRect {
    param($DialogEl)
    if ($DialogEl) {
        try {
            $r = $DialogEl.Current.BoundingRectangle
            if ($r.Width -gt 100 -and $r.Height -gt 100) { return $r }
        } catch { }
    }
    if ($WEDialogTitle) {
        try {
            # 注意：$null 传给 P/Invoke 的 string 参数会变成空串 ""，FindWindowW 就永远返回 0，必须用 [NullString]::Value
            $h = [Dsh.Win32]::FindWindowW([NullString]::Value, $WEDialogTitle)
            if ($h -ne [IntPtr]::Zero) {
                $rc = New-Object -TypeName 'Dsh.Win32+RECT'
                if ([Dsh.Win32]::GetWindowRect($h, [ref]$rc)) {
                    $o = New-Object psobject
                    $o | Add-Member -NotePropertyName X      -NotePropertyValue $rc.Left
                    $o | Add-Member -NotePropertyName Y      -NotePropertyValue $rc.Top
                    $o | Add-Member -NotePropertyName Width  -NotePropertyValue ($rc.Right - $rc.Left)
                    $o | Add-Member -NotePropertyName Height -NotePropertyValue ($rc.Bottom - $rc.Top)
                    return $o
                }
            }
        } catch { }
    }
    return $null
}

function Launch-WallpaperEngine {
    param([string]$Url)
    if (Test-WallpaperRunning) {
        Write-Log 'WE: 已在运行，跳过'
        return $false
    }
    Write-Log ('WE: 启动 ' + $Url)
    Start-Process -FilePath $Url
    return $true
}

# 只负责等弹窗出现并点掉「开始游戏」；不负责启动（启动已由 Launch-WallpaperEngine 提前发出，
# 这样 Steam 冷启动可以和代理看门狗重叠，不必干等）
function Wait-WallpaperEngine {
    param([int]$TimeoutSeconds)

    $deadline  = (Get-Date).AddSeconds($TimeoutSeconds)
    $attempts  = 0
    $lastKey   = [DateTime]::MinValue
    $sawDialog = $false

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 600

        if (Test-WallpaperRunning) {
            Write-Log 'WE: 启动成功'
            return
        }

        $dlg  = Get-WallpaperDialog
        $rect = Get-DialogRect -DialogEl $dlg
        if (-not $rect) { continue }
        if ($rect.Width -le 100 -or $rect.Height -le 100) { continue }

        if (-not $sawDialog) {
            $sawDialog = $true
            Write-Log ('WE: 检测到弹窗，rect=' + [int]$rect.X + ',' + [int]$rect.Y + ' ' + [int]$rect.Width + 'x' + [int]$rect.Height)
        }

        # 首选：UIA 精确定位「开始游戏」
        if ($dlg) {
            $btn = Find-ChildByName -Parent $dlg -Name $WEButtonName
            if ($btn) {
                if ($WEAutoCheckAlways -and $attempts -eq 0) {
                    $okCb = Set-AlwaysUseOption -Dialog $dlg
                    Write-Log ('WE: 勾选「始终使用此选项」 => ' + $okCb)
                }
                $ok = Click-UiElement -El $btn
                $attempts++
                Write-Log ('WE: 点击「开始游戏」(UIA) 第 ' + $attempts + ' 次 => ' + $ok)
                Start-Sleep -Milliseconds 2500
                continue
            }
        }

        # 兜底 1：弹窗有键盘焦点时直接回车（弹窗默认按钮就是「开始游戏」）
        if (((Get-Date) - $lastKey).TotalSeconds -gt 5) {
            $lastKey  = Get-Date
            $focused  = $null
            try { $focused = [System.Windows.Automation.AutomationElement]::FocusedElement } catch { }
            $inside = $false
            if ($dlg -and $focused) {
                try {
                    if ($focused.Current.ProcessId -eq $dlg.Current.ProcessId) { $inside = $true }
                } catch { }
            }
            if ($inside -and $attempts -lt 3) {
                $attempts++
                try {
                    Add-Type -AssemblyName System.Windows.Forms
                    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
                    Write-Log ('WE: 未取到按钮元素，已发送回车（第 ' + $attempts + ' 次）')
                    Start-Sleep -Milliseconds 2000
                    continue
                } catch { }
            }
        }

        # 兜底 2：按弹窗比例点坐标（完全不依赖 UIA）
        if ($attempts -lt 6) {
            $x = [int]($rect.X + $rect.Width  * $WEButtonRatioX)
            $y = [int]($rect.Y + $rect.Height * $WEButtonRatioY)
            Click-AtPoint -X $x -Y $y
            $attempts++
            Write-Log ('WE: 按比例坐标点击 (' + $x + ',' + $y + ') 第 ' + $attempts + ' 次')
            Start-Sleep -Milliseconds 2500
            continue
        }
    }

    if ($sawDialog) {
        Write-Log 'WE: 超时，弹窗仍在。请手动点一次「开始游戏」并勾选「始终使用此选项」，以后就不会再弹。'
    } else {
        Write-Log 'WE: 超时，未检测到弹窗也未检测到 WE 进程。'
    }
}

# 把指定进程的顶层窗口最小化
# 思路：用 UIA 只为“找到真实 HWND”，真正的最小化交给 ShowWindow(SW_MINIMIZE)——
# 实测在这里 ShowWindow 稳定生效，而 UIA 的 WindowPattern 状态切换并不总是落地。
function Minimize-AppWindows {
    param([string[]]$Names, [string[]]$Titles)

    $procs = @()
    foreach ($n in $Names) {
        $procs += @(Get-Process -Name $n -ErrorAction SilentlyContinue)
    }
    $procs = @($procs | Where-Object { $_ })

    $targetPids = @($procs | ForEach-Object { $_.Id })
    $handles    = New-Object System.Collections.ArrayList

    # ① UIA 顶层窗口扫描拿 HWND：先按进程 pid 认，认不出再按窗口标题认
    if ($script:HasUia) {
        try {
            $root = [System.Windows.Automation.AutomationElement]::RootElement
            $kids = $root.FindAll(
                [System.Windows.Automation.TreeScope]::Children,
                [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($w in $kids) {
                try {
                    $hit = $false
                    if ($targetPids -contains $w.Current.ProcessId) {
                        $hit = $true
                    } elseif ($Titles) {
                        foreach ($t in $Titles) {
                            if ($w.Current.Name -match $t) { $hit = $true; break }
                        }
                    }
                    if (-not $hit) { continue }
                    $hn = [IntPtr]$w.Current.NativeWindowHandle
                    if ($hn -eq [IntPtr]::Zero) { continue }
                    [void]$handles.Add([pscustomobject]@{ H = $hn; Name = $w.Current.Name })
                } catch { }
            }
        } catch { }
    }

    # ② 补上进程主窗口句柄（有些窗口不在顶层窗口列表里）
    $known = @($handles | ForEach-Object { $_.H })
    foreach ($pr in $procs) {
        try {
            $hm = $pr.MainWindowHandle
            if ($hm -eq [IntPtr]::Zero) { continue }
            if ($known -contains $hm) { continue }
            [void]$handles.Add([pscustomobject]@{ H = $hm; Name = $pr.ProcessName })
        } catch { }
    }

    if ($handles.Count -eq 0) {
        Write-Log ('最小化: 没有可最小化的窗口（' + ($Names -join '/') + '）')
        return
    }

    $done = 0
    foreach ($it in $handles) {
        try {
            $wasIconic = [Dsh.Win32]::IsIconic($it.H)
            if (-not $wasIconic) {
                [void][Dsh.Win32]::ShowWindow($it.H, 6)
            }
            # ShowWindow 被系统挡掉时的第二手：UIA WindowPattern
            if (-not [Dsh.Win32]::IsIconic($it.H) -and $script:HasUia) {
                try {
                    $el2 = [System.Windows.Automation.AutomationElement]::FromHandle($it.H)
                    $wp2 = $el2.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
                    $wp2.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Minimized)
                } catch { }
            }
            if ([Dsh.Win32]::IsIconic($it.H)) {
                $done++
                if ($wasIconic) { Write-Log ('最小化: 本来就已经最小化 ' + $it.Name) }
                else            { Write-Log ('最小化: ' + $it.Name) }
            } else {
                Write-Log ('最小化: 未能确认生效 ' + $it.Name)
            }
        } catch { }
    }

    Write-Log ('最小化: 完成 ' + $done + '/' + $handles.Count + '（' + ($Names -join '/') + '）')
}

function Find-ClashExe {
    $candidates = @(
        $ClashExe,
        "$env:LOCALAPPDATA\Programs\clash-verge\clash-verge.exe",
        "$env:LOCALAPPDATA\Programs\clash-verge-rev\clash-verge.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Ensure-DesktopShortcut {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName
    if (Test-Path -LiteralPath $lnk) { return }
    $exe = Find-ClashExe
    if ($exe) { $icon = $exe + ',0' } else { $icon = 'powershell.exe,0' }
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath       = 'powershell.exe'
        $sc.Arguments        = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
        $sc.WorkingDirectory = Split-Path $PSCommandPath -Parent
        $sc.IconLocation     = $icon
        $sc.Description      = '启动 Clash Verge + 系统代理 + Wallpaper Engine'
        $sc.Save()
        Write-Log ('快捷方式已创建: ' + $lnk)
    } catch { Write-Log ('快捷方式创建失败: ' + $_.Exception.Message) }
}

function Enable-SystemProxy {
    param([string]$Server)
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    # 只改 ProxyEnable / ProxyServer，保留你原有的 ProxyOverride 白名单
    try { Set-ItemProperty -Path $reg -Name ProxyEnable -Value 1       -Type DWord  -ErrorAction Stop } catch { }
    try { Set-ItemProperty -Path $reg -Name ProxyServer -Value $Server -Type String -ErrorAction Stop } catch { }
    try {
        Add-Type -Namespace Wininet -Name Api -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr h, int opt, IntPtr buf, int len);
'@
        [Wininet.Api]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null  # SETTINGS_CHANGED
        [Wininet.Api]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null  # REFRESH
    } catch { }
    # 回读确认：$ErrorActionPreference 是 SilentlyContinue，不回读就不知道到底写成功没有
    $k = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue
    return ($null -ne $k -and $k.ProxyEnable -eq 1 -and $k.ProxyServer -eq $Server)
}

# ================= 代理相关（Clash Verge 2.5.x 之后）=================
# 新版 Clash Verge 在内核就绪那一刻会跑一次 system proxy guard：
# 读自己 verge.yaml 里的 enable_system_proxy，然后把系统代理同步成那个状态。
# 更新常把这个键重置成 false，于是我们写的注册表会在几秒后被它踩回去
# （日志特征：Core running mode changed: NotRunning -> Sidecar 紧跟 System proxy is disabled）。
# 所以这里顺它的逻辑走：启动前先把开关拨成 true，让它自己把代理打开。

function Set-ClashSystemProxyPreference {
    $yaml = Join-Path $ClashConfigDir 'verge.yaml'
    if (-not (Test-Path -LiteralPath $yaml)) {
        Write-Log ('Clash: 找不到 ' + $yaml)
        return $false
    }
    try {
        $bytes  = [System.IO.File]::ReadAllBytes($yaml)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $text   = [System.IO.File]::ReadAllText($yaml, [System.Text.Encoding]::UTF8)
        $new    = [System.Text.RegularExpressions.Regex]::Replace(
                      $text, '(?m)^(\s*enable_system_proxy:\s*)false\s*$', '${1}true')
        if ($new -ne $text) {
            $bak = $yaml + '.dsh-bak'
            try {
                if (-not (Test-Path -LiteralPath $bak)) {
                    Copy-Item -LiteralPath $yaml -Destination $bak -Force -ErrorAction Stop
                }
            } catch { Write-Log ('Clash: 备份失败，不影响继续 ' + $_.Exception.Message) }

            [System.IO.File]::WriteAllText($yaml, $new, (New-Object System.Text.UTF8Encoding($hasBom)))

            # 回读确认真的落盘了（没有写权限时这里会露馅）
            $check = [System.IO.File]::ReadAllText($yaml, [System.Text.Encoding]::UTF8)
            if ($check -match '(?m)^\s*enable_system_proxy:\s*true\s*$') {
                Write-Log 'Clash: enable_system_proxy 原为 false（更新后被重置），已改为 true'
                return $true
            }
            Write-Log 'Clash: 写入了但回读仍不是 true，可能没写权限；靠后面的看门狗兜底'
            return $false
        }
        Write-Log 'Clash: enable_system_proxy 已是 true'
        return $false
    } catch {
        Write-Log ('Clash: 改配置失败 ' + $_.Exception.Message)
        return $false
    }
}

function Test-PortListening {
    param([int]$Port)
    try {
        $c = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        return ($c.Count -gt 0)
    } catch { return $false }
}

function Wait-ClashCoreReady {
    param([int]$Port, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortListening -Port $Port) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# 看门狗：Clash 的 proxy guard 可能把 ProxyEnable 改回去，发现不一致就重写
function Watch-SystemProxy {
    param([string]$Server, [int]$Seconds)
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $deadline = (Get-Date).AddSeconds($Seconds)
    $fixed = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $k = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue
        if ($null -eq $k) { continue }
        if (($k.ProxyEnable -ne 1) -or ($k.ProxyServer -ne $Server)) {
            if (Enable-SystemProxy -Server $Server) {
                $fixed++
                Write-Log ('代理: 被改回去了，已重设（第 ' + $fixed + ' 次）')
            } else {
                Write-Log '代理: 重设失败，注册表写入被拒绝'
            }
        }
    }
    return $fixed
}

# ==================== 主流程 ====================
Write-Log '=== 开始 ==='

Ensure-DesktopShortcut

# 1) Clash Verge：没运行就先拨开它自己的系统代理开关，再启动
$exe = Find-ClashExe
$clashWasRunning = [bool](Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)

if ($exe) {
    if (-not $clashWasRunning) {
        Set-ClashSystemProxyPreference | Out-Null
        Start-Process -FilePath $exe
        Write-Log ('Clash: 已启动 ' + $exe)
    } else {
        Write-Log 'Clash: 已在运行（不改 verge.yaml，免得和它抢写）'
        $vy = Join-Path $ClashConfigDir 'verge.yaml'
        $hit = Select-String -LiteralPath $vy -Pattern '^\s*enable_system_proxy:\s*false' -ErrorAction SilentlyContinue
        if ($hit) {
            Write-Log 'Clash: 它界面里的系统代理开关仍是关闭的；代理功能照样会被打开，若想界面也一致，退出 Clash 后再双击一次'
        }
    }
} else {
    Write-Log 'Clash: 未找到 clash-verge.exe'
}

# 2) 等内核真正开始监听端口（比固定 sleep 3 秒可靠）
$port = 7897
if ($ProxyServer -match '(\d+)\s*$') { $port = [int]$Matches[1] }
if (-not $clashWasRunning) {
    if (Wait-ClashCoreReady -Port $port -TimeoutSeconds $ClashReadyTimeout) {
        Write-Log ('Clash: 内核已就绪，端口 ' + $port)
    } else {
        Write-Log ('Clash: 等端口 ' + $port + ' 超过 ' + $ClashReadyTimeout + 's，仍然继续设代理')
    }
}

# 3) 打开系统代理（先等 guard 把话说完，只等 0.4s）
if (-not $clashWasRunning) { Start-Sleep -Milliseconds 400 }
if (Enable-SystemProxy -Server $ProxyServer) {
    Write-Log ('代理: 已开启 ' + $ProxyServer)
} else {
    Write-Log ('代理: 写入失败，注册表被拒绝或值没生效（当前 ProxyServer=' + (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).ProxyServer + '）')
}

# 4) 立即拉起 WE——Steam 冷启动本身就慢，先让它跑着
Launch-WallpaperEngine -Url $WallpaperUrl | Out-Null

# 5) 看门狗（此时 WE/Steam 正在后台启动，这段时间不算额外等待）
if (-not $clashWasRunning) {
    $fixed = Watch-SystemProxy -Server $ProxyServer -Seconds $ProxyWatchSeconds
    if ($fixed -gt 0) { Write-Log ('代理: 看门狗共纠正 ' + $fixed + ' 次') }
}

# 6) 处理 WE 的「选择启动选项」弹窗
Wait-WallpaperEngine -TimeoutSeconds $WEDialogTimeout

# 7) 收尾：壁纸已经起来了，就把 Clash 和 Steam 的窗口最小化，只留桌面壁纸
if ($MinimizeAfterStart) {
    Start-Sleep -Milliseconds $MinimizeSettleMs
    if (Test-WallpaperRunning) {
        Minimize-AppWindows -Names $MinimizeProcessNames -Titles $MinimizeWindowTitles
    } else {
        Write-Log '最小化: WE 未在运行，跳过（避免把 Clash/Steam 关了却什么都没起来）'
    }
}

Write-Log '=== 结束 ==='
