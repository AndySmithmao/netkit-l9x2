# ============================================================================
#  一键诊断 —— 检查 VRChat 免代理访问的当前状态
#  用法: powershell -ExecutionPolicy Bypass -File diagnose.ps1
#  不需要管理员权限（只读检查）
# ============================================================================
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$RootDir = if ($env:VRCTOOL_ROOT) { $env:VRCTOOL_ROOT } else { Split-Path $PSScriptRoot -Parent }
$DataDir = if ($env:VRCTOOL_DATA) { $env:VRCTOOL_DATA } else { Join-Path $RootDir 'data' }
$HostsPath  = "$env:SystemRoot\System32\drivers\etc\hosts"
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

function Show { param($s, $color = 'Gray') Write-Host $s -ForegroundColor $color }

# 进度上报：发给 GUI 的 ##PROG## 协议。
# 本脚本不引用 lib-common.ps1（自己定义了 Show/Ok/Warn），所以本地实现一份。
# 原来这里直接调用 lib-common 的 Prog，导致每次调用都抛 CommandNotFoundException。
function Prog {
    param([int]$Cur, [int]$Tot, [string]$Label = '')
    Write-Host ("##PROG##$Cur|$Tot|$Label")
}
# 同上：Done 也不在 lib-common 的加载范围里，本地实现一份（GUI 靠它停掉转圈）
function Done {
    param([string]$State = 'ok', [string]$Msg = '')
    Write-Host ("##DONE##$State|$Msg")
}
function Head { param($s) Show ''; Show "  ====  $s  ====" Cyan }
function Ok   { param($s) Show "    [ok]  $s" Green }
function Warn { param($s) Show "    [!]   $s" Yellow }
function Bad  { param($s) Show "    [x]   $s" Red }
function Info { param($s) Show "          $s" DarkGray }

function Test-Url {
    param([string]$Url, [int]$Timeout = 12)
    $out = (& "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time $Timeout -w '%{http_code}|%{remote_ip}' $Url 2>&1 | Out-String).Trim()
    $m = [regex]::Match($out, '(\d{3})\|([\d.]+)\s*$')
    if ($m.Success) { return @{ code = $m.Groups[1].Value; ip = $m.Groups[2].Value } }
    return @{ code = '000'; ip = '' }
}
function Alive { param($c) return ($c -match '^[1-5]\d\d$') }

$problems = @()
$suggestions = @()

Show ''
Show '============================================================' Cyan
Show '  VRChat 免代理访问 —— 一键诊断' Cyan
Show '============================================================' Cyan

# ---------------------------------------------------------------- 环境
Head '环境'
Show ("    系统: {0}" -f [System.Environment]::OSVersion.VersionString)
Show ("    用户: {0}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
Show ("    时间: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$up = (Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1)
if ($up) {
    Show ("    网络: {0}  IP {1}  网关 {2}" -f $up.InterfaceAlias,
          ($up.IPv4Address | Select-Object -First 1).IPAddress,
          ($up.IPv4DefaultGateway | Select-Object -First 1).NextHop)
}

# ---------------------------------------------------------------- 服务
Head '服务与驱动'
$svc = (& "$env:SystemRoot\System32\sc.exe" query VRChatBypass 2>&1 | Out-String)
if ($svc -match 'SERVICE_NAME') {
    if ($svc -match 'RUNNING') { Ok 'VRChatBypass 服务: 运行中' }
    else { Bad 'VRChatBypass 服务: 已安装但未运行'; $problems += '服务未运行'; $suggestions += '管理员命令提示符里执行: sc start VRChatBypass' }
} else {
    Bad 'VRChatBypass 服务: 未安装'; $problems += '服务未安装'; $suggestions += '跑一遍「1-安装.cmd」'
}
$drv = (& "$env:SystemRoot\System32\sc.exe" query WinDivert 2>&1 | Out-String)
if ($drv -match 'RUNNING') { Ok 'WinDivert 驱动: 运行中' }
elseif ($drv -match 'SERVICE_NAME') { Warn 'WinDivert 驱动: 已安装但未运行' }
else { Warn 'WinDivert 驱动: 未加载（服务正常时通常没问题）' }

if (Get-Process winws -ErrorAction SilentlyContinue) { Ok 'winws 进程: 运行中' }
else { Bad 'winws 进程: 未运行'; $problems += 'winws 进程未运行' }

# ---------------------------------------------------------------- hosts
Head 'hosts 文件'
if (Test-Path $HostsPath) {
    $hl = @(Get-Content $HostsPath -ErrorAction SilentlyContinue)
    $block = @($hl | Where-Object { $_ -match '# ===== VRChat-bypass (BEGIN|END) =====' })
    $entries = @($hl | Where-Object { $_ -match '^\s*\d+\.\d+\.\d+\.\d+\s+\S*vrchat' })
    if ($entries.Count -gt 0) {
        Ok "找到 $($entries.Count) 条 VRChat 条目"
        $entries | ForEach-Object { Info $_.Trim() }
    } else {
        Bad 'hosts 里没有 VRChat 条目'; $problems += 'hosts 未配置'; $suggestions += '跑一遍「1-安装.cmd」'
    }
    if ($block.Count -eq 0 -and $entries.Count -gt 0) {
        Warn '条目存在但缺少 BEGIN/END 标记行（可能是手工加的）'
    }
} else {
    Bad "找不到 $HostsPath"
}

# ---------------------------------------------------------------- 解析
Head '实际解析与连通性'

$core = @('api.vrchat.cloud','files.vrchat.cloud','pipeline.vrchat.cloud',
          'vrchat.com','www.vrchat.com','docs.vrchat.com','creators.vrchat.com',
          'assets.vrchat.com','status.vrchat.com','mail.vrchat.com')
$third = @('help.vrchat.com','ask.vrchat.com','feedback.vrchat.com','hello.vrchat.com')

Show '    --- 核心域名 ---' DarkGray
foreach ($h in $core) {
    # 只试一次、5 秒超时：诊断要的是"通/不通"，不是"重试到通"。
    # 以前是 2 次 × 12 秒 —— 7~8 个域名不通就是 3 分钟打底，用户以为卡死。
    $last = Test-Url "https://$h/" 5
    if (Alive $last.code) { Ok ("{0,-24} {1}  @{2}" -f $h, $last.code, $last.ip) }
    else { Bad ("{0,-24} {1}" -f $h, '不通'); $problems += "$h 不通" }
}

Show '    --- 第三方域名（慢但应可用）---' DarkGray
foreach ($h in $third) {
    $r = Test-Url "https://$h/" 25
    if (Alive $r.code) { Ok ("{0,-24} {1}  @{2}" -f $h, $r.code, $r.ip) }
    else { Warn ("{0,-24} {1}  (第三方托管，不影响使用)" -f $h, '不通') }
}

if (Test-Path (Join-Path $DataDir 'hosts.original')) { Ok 'hosts.original 备份存在（可随时完全还原）' }
else { Warn 'hosts.original 备份不存在 —— 卸载时无法用备份还原（只会删标记块）' }

# ---------------------------------------------------------------- 其他站点
Head '普通网站是否受影响（必须正常）'
foreach ($h in 'www.bing.com','www.baidu.com','outlook.com','www.zhihu.com') {
    $r = Test-Url "https://$h/" 12
    if (Alive $r.code) { Ok ("{0,-20} {1}" -f $h, $r.code) }
    else { Bad ("{0,-20} {1}" -f $h, '被影响了！'); $problems += "$h 被影响"; $suggestions += '立刻跑「2-卸载.cmd」完全还原，然后反馈' }
}

# ---------------------------------------------------------------- 结论
Head '诊断结论'
if ($problems.Count -eq 0) {
    Show '    [ok] 一切正常，没有发现问题' Green
} else {
    Show "    发现 $($problems.Count) 个问题:" Yellow
    $problems | ForEach-Object { Show "      - $_" Yellow }
    if ($suggestions.Count -gt 0) {
Show ''
        Show '    建议:' Cyan
        $suggestions | Select-Object -Unique | ForEach-Object { Show "      * $_" Cyan }
    }
}
Show ''
Show '    如果问题依旧，请把本窗口整屏截图反馈。' DarkGray
Show ''

# 结束标记 + 退出码：有问题时给 1（GUI 会提示），全通则 0
if ($problems.Count -gt 0) {
    Done 'fail' ("发现 $($problems.Count) 个问题")
    exit 1
}
Prog 100 100 '诊断完成'
Done 'ok' '诊断完成，全部正常'
exit 0
