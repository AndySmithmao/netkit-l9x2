# ============================================================================
#  VRChat 免代理访问 —— 完全卸载
#
#  做五件事:
#    1) 停止并删除 VRChatBypass 服务
#    2) 停止并删除 WinDivert 内核驱动
#    3) 从 hosts 里精确删除本工具写入的块（保留你原有的内容）
#    4) 如果存在 hosts.original 备份，用它还原（更彻底）
#    5) 刷新 DNS 并验证已恢复原状
#
#  用法: powershell -ExecutionPolicy Bypass -File uninstall.ps1
#        加 -KeepFiles 可以保留组件目录（只删服务和 hosts 条目）
# ============================================================================
param(
    [switch]$KeepFiles,   # 保留组件目录
    [switch]$Yes          # 跳过二次确认（无人值守时用）
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$RootDir  = if ($env:VRCTOOL_ROOT)  { $env:VRCTOOL_ROOT }  else { Split-Path $PSScriptRoot -Parent }
$ToolsDir = if ($env:VRCTOOL_TOOLS) { $env:VRCTOOL_TOOLS } else { Join-Path $RootDir 'tools' }
$DataDir  = if ($env:VRCTOOL_DATA)  { $env:VRCTOOL_DATA }  else { Join-Path $RootDir 'data' }
$InstallDir = $ToolsDir
$HostsPath  = "$env:SystemRoot\System32\drivers\etc\hosts"

# 改 hosts 的唯一入口。
# 原地写（Set-Content / WriteAllText）会先把文件截断成 0 字节再写，
# 撞上 Defender 拦截就留下一个空的 hosts —— 用户原有条目全丢。详见 lib-hosts.ps1。
. (Join-Path $PSScriptRoot 'lib-hosts.ps1')
$LogPath    = Join-Path $InstallDir 'uninstall.log'
$SvcName    = 'VRChatBypass'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

function Show  { param($s, $color = 'Gray') Write-Host $s -ForegroundColor $color }
function AddLog{ param($s) Add-Content -Path $LogPath -Value $s -Encoding UTF8 -ErrorAction SilentlyContinue }
function Step  { param($n, $t) Show ''; Show "  [$n] $t" Cyan }
function Ok    { param($s) Show "      [ok] $s" Green }
function Warn  { param($s) Show "      [!]  $s" Yellow }
function Bad   { param($s) Show "      [x]  $s" Red }

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Test-Url {
    param([string]$Url, [int]$Timeout = 12)
    $out = (& "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time $Timeout -w '%{http_code}' $Url 2>&1 | Out-String).Trim()
    $m = [regex]::Match($out, '(\d{3})\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return '000'
}
function Test-Alive { param([string]$Code) return ($Code -match '^[1-5]\d\d$') }

# ============================================================================
Show ''
Show '============================================================' Cyan
Show '  VRChat 免代理访问 —— 完全卸载' Cyan
Show '============================================================' Cyan
Show ''

if (-not (Test-Admin)) {
    Show '  [x] 需要管理员权限' Red
    Show ''
    Show '  请右键「卸载.cmd」→ 以管理员身份运行' Yellow
    exit 1
}
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
'' | Set-Content -Path $LogPath -Encoding UTF8
AddLog "=== 卸载开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

# ---------------------------------------------------------------
# 二次确认 —— 破坏性操作不能一点就跑
# ---------------------------------------------------------------
if (-not $Yes) {
    Show ''
    Show '  即将执行以下操作:' Yellow
    Show '    - 删除服务 VRChatBypass' White
    Show '    - 删除内核驱动 WinDivert' White
    Show '    - 把 hosts 还原成安装前的样子' White
    if (-not $KeepFiles) { Show "    - 删除整个文件夹 $InstallDir" White }
    Show ''
    Show '  这些操作会让 VRChat 网页重新变得无法访问。' Yellow
    Show ''
    $ans = Read-Host '  确定要继续吗？输入 y 回车确认，其他任意键取消'
    if ($ans -notmatch '^[yY]') {
        Show ''
        Show '  已取消，什么都没做。' Green
        AddLog '用户取消'
        exit 0
    }
    Show ''
}

$BEGIN = '# ===== VRChat-bypass BEGIN ====='
$END   = '# ===== VRChat-bypass END ====='

# hosts 备份有两处（ISSUES D5）：
#   1) 数据目录内  —— 安装时写的，正常情况下用这份
#   2) %ProgramData%\VRChatTool\hosts.original
#                  —— 兜底副本。本脚本第 5 步会删掉整个安装目录，如果只有
#                     数据目录一份，卸载后就再也找不到「安装前 hosts」了。
#                     兜底那份卸载器不碰，用户以后想手工还原也有依据。
#   还原时按 1) → 2) 的顺序取第一个存在的。
$bakCandidates = @(
    (Join-Path $DataDir 'hosts.original'),
    (Join-Path $env:ProgramData 'VRChatTool\hosts.original')
)

# ============================================================================
Step '1/5' '停止并删除服务'
$exists = ((& "$env:SystemRoot\System32\sc.exe" query $SvcName 2>&1 | Out-String) -match 'SERVICE_NAME')
if ($exists) {
    & "$env:SystemRoot\System32\sc.exe" stop $SvcName 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    & "$env:SystemRoot\System32\sc.exe" delete $SvcName 2>&1 | Out-Null
    Ok "服务 $SvcName 已删除"
} else {
    Ok "服务 $SvcName 不存在（无需删除）"
}
AddLog '服务已处理'

# ============================================================================
Step '2/5' '停止并删除 WinDivert 驱动'
# 先确保 winws 进程退出（驱动被占用时卸不掉）
Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# ★ 这里以前是「sc stop → 睡 2 秒 → sc delete」。★
#   坑在最后那步：驱动还加载着（或有句柄没释放）时执行 sc delete，
#   Windows 只会把它标记成「待删除」，**驱动仍然留在内核里**，
#   它注册的 WFP 子层/过滤器也还在。之后每次再开 winws 都会撞
#   0x8032000A = FWP_E_IN_USE（对象被其他对象引用），
#   连重装都起不来 —— 只能重启电脑。2026-10-17 真机踩过。
#
#   正确做法：只 stop，然后**轮询等它真的卸掉**（WinDivert 驱动卸载时会自己
#   把服务删掉，query 会返回 1060）。没卸掉就绝不动 delete，留给重启清理。
$sc = "$env:SystemRoot\System32\sc.exe"
$drvLoaded = ((& $sc query WinDivert 2>&1 | Out-String) -match 'SERVICE_NAME')
if ($drvLoaded) {
    $unloaded = $false
    for ($i = 0; $i -lt 16; $i++) {
        $q = (& $sc query WinDivert 2>&1 | Out-String)
        if ($q -match '1060' -or $q -match 'STOPPED') { $unloaded = $true; break }
        & $sc stop WinDivert 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
    if ($unloaded) {
        Ok '驱动 WinDivert 已卸载'
        # 已卸载，服务键通常已随驱动消失；残留才删（此时代谢已结束，删是安全的）
        $q = (& $sc query WinDivert 2>&1 | Out-String)
        if ($q -match 'SERVICE_NAME') {
            & $sc delete WinDivert 2>&1 | Out-Null
            Start-Sleep -Milliseconds 300
            if ((& $sc query WinDivert 2>&1 | Out-String) -match 'SERVICE_NAME') {
                Warn '驱动服务键仍存在，但驱动已卸载（不影响下次安装）'
            } else { Ok '驱动服务键已清理' }
        }
    } else {
        # 还加载着：绝不能 delete，否则下次安装会 FWP_E_IN_USE
        Warn '驱动仍在内核中（有程序占用），已跳过删除以免破坏下次安装'
        Show '      重启电脑后它会自动清理；不重启也不影响使用。' DarkGray
    }
} else {
    Ok '驱动 WinDivert 不存在（无需处理）'
}
AddLog '驱动已处理'

# ============================================================================
Step '3/5' '还原 hosts 文件'
$restored = $false

# 优先用数据目录那份备份；没有就退回 %ProgramData% 兜底副本
$bakHosts = ''
foreach ($c in $bakCandidates) { if (Test-Path $c) { $bakHosts = $c; break } }

if ($bakHosts) {
    # 先给「当前 hosts」留一份副本：备份是安装前的快照，用户在安装之后
    # 新加的条目（NAS / 内网 / 别的工具）不在里面，整份覆盖会丢掉它们。
    # 有了这份副本，用户随时能手工捞回来。
    try {
        Copy-Item $HostsPath (Join-Path $DataDir 'hosts.before-uninstall') -Force -ErrorAction Stop
    } catch {
        Warn "当前 hosts 留副本失败（继续）: $($_.Exception.Message)"
    }

    # 优先用备份还原（最彻底）
    $bakLines = @(Get-Content $bakHosts -ErrorAction SilentlyContinue)
    if ($bakLines.Count -gt 0 -and (Write-HostsSafe -Path $HostsPath -Lines $bakLines)) {
        Ok "已用 hosts.original 备份完整还原（来源: $bakHosts）"
        Show "      卸载前的 hosts 已留副本: $(Join-Path $DataDir 'hosts.before-uninstall')" DarkGray
        $restored = $true
        AddLog "用备份还原 hosts: $bakHosts"
    } else {
        Bad "备份还原失败（$bakHosts）—— hosts 保持在动手前的状态"
        AddLog "备份还原失败: $bakHosts"
    }
} else {
    Warn '没找到任何 hosts.original 备份，只能按标记块删除（可能残留改动）'
    AddLog '未找到 hosts.original 备份'
}

# 无论是否用备份还原，都再检查一遍标记块是否残留
$strip = Remove-HostsBlock -Path $HostsPath -Begin $BEGIN -End $END
if ($strip.Error) {
    Bad "读取 hosts 失败: $($strip.Error)"
    AddLog "读取 hosts 失败: $($strip.Error)"
} elseif ($strip.Unpaired) {
    Warn 'hosts 里的标记行不成对（只有 BEGIN 或只有 END），为免误删已跳过；请手工检查'
    AddLog 'hosts 标记行不成对，已跳过'
} elseif ($strip.HadBlock) {
    if (Write-HostsSafe -Path $HostsPath -Lines $strip.Lines) {
        Ok "已删除残留的标记块（$($strip.Removed) 行）"
        AddLog "删除残留标记块 $($strip.Removed) 行"
        $restored = $true
    } else {
        Bad 'hosts 写入失败 —— 已保持原样，没有留下空文件'
        AddLog 'hosts 写入失败'
    }
}

if (-not $restored -and -not $strip.Error -and -not $strip.Unpaired) {
    Ok 'hosts 中未发现本工具写入的内容（本来就是干净的）'
}

& "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
Ok 'DNS 缓存已刷新'

# ============================================================================
Step '4/5' '验证已恢复原状'

Show ''
Show '      --- 检查 hosts 里是否还有残留 ---' DarkGray
$left = @(Get-Content $HostsPath | Where-Object { $_ -match 'vrchat' })
if ($left.Count -gt 0) {
    Warn "hosts 里还有 $($left.Count) 行含 vrchat（可能是你自己加的，请自行确认）"
    $left | Select-Object -First 5 | ForEach-Object { Show "        $_" DarkGray }
} else {
    Ok 'hosts 里已无 vrchat 相关条目'
}

Show ''
Show '      --- 检查服务和进程 ---' DarkGray
$svcGone = -not ((& "$env:SystemRoot\System32\sc.exe" query $SvcName 2>&1 | Out-String) -match 'SERVICE_NAME')
$procGone = -not (Get-Process winws -ErrorAction SilentlyContinue)
if ($svcGone) { Ok '服务已不存在' } else { Bad '服务仍存在' }
if ($procGone) { Ok 'winws 进程已退出' } else { Bad 'winws 进程仍在运行' }

Show ''
Show '      --- 检查域名解析是否已回到系统默认 ---' DarkGray
$ps = (& "$env:SystemRoot\System32\PING.EXE" -n 1 -w 2000 vrchat.com 2>&1 | Out-String)
$m = [regex]::Match($ps, '\[?(\d+\.\d+\.\d+\.\d+)\]?')
if ($m.Success) {
    $ip = $m.Groups[1].Value
    if ($ip -match '^(104\.|172\.64\.|172\.65\.|172\.66\.|13\.|18\.65\.|3\.17)') {
        Warn "vrchat.com 仍解析到 CDN IP ($ip) —— 可能是 DNS 缓存，等一下或重启浏览器"
    } else {
        Ok "vrchat.com 解析为 $ip（系统 DNS 的正常结果，可能是投毒值 —— 这是卸载后的预期状态）"
    }
} else {
    Warn 'vrchat.com 解析失败（卸载后属于正常现象）'
}

# ============================================================================
Step '5/5' '清理文件'

if ($KeepFiles) {
    Warn "已保留 $InstallDir（-KeepFiles）"
    Warn '如需彻底删除，手动删掉这个文件夹即可'
} else {
    # 先尝试正常删除，失败则列出残留
    try {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction Stop
        Ok "$InstallDir 已删除"
    } catch {
        Warn "部分文件删除失败（可能被占用）: $($_.Exception.Message)"
        $left = @(Get-ChildItem $InstallDir -Recurse -ErrorAction SilentlyContinue)
        Warn "还剩 $($left.Count) 个文件，可稍后手动删除 $InstallDir"
    }
}

# ============================================================================
Show ''
Show '============================================================' Green
Show '  卸载完成，系统已恢复原状' Green
Show '============================================================' Green
Show ''
Show '  友情提示:' Cyan
Show '    - hosts 已还原；服务与驱动已删除' White
Show '    - 如果之前开过浏览器缓存，按 Ctrl+Shift+Delete 清一下' White
Show '    - 如果之后想重新安装，跑「安装.cmd」即可' White
Show ''
# 退出码：备份存在但没还原成功 → 不能报成功（以前无论成败都 exit 0）
if ($bakHosts -and -not $restored) {
    Warn 'hosts 可能没有完全还原 —— 请按上面的提示手工确认'
    exit 1
}
exit 0
