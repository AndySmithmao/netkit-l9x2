# ============================================================================
#  VRChat 优选 —— 【按清单】下载测速
#
#  给一串 IP，对每个做真实文件下载测速，输出吞吐排名
#
#  用法:
#     # 1) 从文件读（full-scan 导出的 -top.txt，或你自己写的清单）
#     powershell -ExecutionPolicy Bypass -File speedtest-list.ps1 -File <数据目录>\full-scan-cloudfront-top.txt
#
#     # 2) 直接贴 IP
#     powershell -ExecutionPolicy Bypass -File speedtest-list.ps1 -Ips "13.33.44.1,65.8.72.1,3.173.51.1"
#
#     # 3) 用 Cloudflare 的 IP 测（走 api 分布）
#     powershell -ExecutionPolicy Bypass -File speedtest-list.ps1 -Ips "104.16.1.1" -Sni api.vrchat.cloud
#
#  产出:
#     <数据目录>\speedtest-result.csv
#     屏幕上打印排名
# ============================================================================
param(
    [string]$Ips = '',
    [string]$File = '',
    [string]$Sni = '',
    [string]$Path = '',
    [int]$Rounds = 3,
    [int]$MaxTime = 12,
    [int]$Timeout = 8000,
    [int]$RoundDelayMs = 1500,   # 轮次之间的间隔（抗风控：不短时间连打同一 IP）
    [int]$IpDelayMs = 500,       # 切换到下一个 IP 前的间隔
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

# 路径相对 EXE 目录（GUI 通过环境变量传入）
$RootDir = if ($env:VRCTOOL_ROOT) { $env:VRCTOOL_ROOT } else { Split-Path $PSScriptRoot -Parent }
$DataDir = if ($env:VRCTOOL_DATA) { $env:VRCTOOL_DATA } else { Join-Path $RootDir 'data' }
if (-not $OutDir) { $OutDir = $DataDir }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ★ 必须自己 dot-source lib-common ★
#   Progress / IpClear / IpTick 在 lib-common.ps1 里。GUI 和父脚本都是**另起进程**
#   跑这个脚本的，新进程继承不到任何函数 —— 不自己加载就是一堆 undefined。
#   放在自己的 Show 定义之前，让本脚本的同名函数覆盖 lib-common 的。
. (Join-Path $PSScriptRoot 'lib-common.ps1')

function Show { param($s, $c = 'Gray') Write-Host $s -ForegroundColor $c }

# ---------------------------------------------------------------------------
# 收集 IP 清单
# ---------------------------------------------------------------------------
$list = New-Object System.Collections.Generic.List[string]
if ($File) {
    if (Test-Path $File) {
        Get-Content $File | ForEach-Object {
            $v = $_.Trim()
            if ($v -match '^\d{1,3}(\.\d{1,3}){3}$') { $list.Add($v) }
        }
    } else { Show "  [x] 文件不存在: $File" Red; exit 1 }
}
if ($Ips) {
    foreach ($v in ($Ips -split '[,;\s]+')) {
        $v = $v.Trim()
        if ($v -match '^\d{1,3}(\.\d{1,3}){3}$') { $list.Add($v) }
    }
}
$list = $list | Select-Object -Unique

Show ''
Show '============================================================' Cyan
Show '  VRChat 优选 —— 按清单下载测速' Cyan
Show '============================================================' Cyan
Show ''

if ($list.Count -eq 0) {
    Show '  [x] 没有提供 IP' Red
    Show ''
    Show '  用法:' Yellow
    Show '    -File <清单文件.txt>     每行一个 IP' White
    Show '    -Ips  "1.2.3.4,5.6.7.8"  逗号分隔' White
    Show ''
    exit 1
}

# ---------------------------------------------------------------------------
# 决定用哪个 SNI + 路径（按 IP 段自动判断，或手动指定）
# ---------------------------------------------------------------------------
function Guess-Target {
    param([string]$Ip)
    # Cloudflare 常用段
    if ($Ip -match '^(104\.1[6-9]|172\.6[4-6]|162\.15[89]|108\.162|141\.101|173\.245|103\.2|103\.3|188\.114|190\.93|197\.234|198\.41|131\.0)\.') {
        return @{ Sni = 'api.vrchat.cloud'; Path = '/' }
    }
    # CloudFront 常用段
    if ($Ip -match '^(13\.|18\.6|3\.16|3\.17|52\.84|54\.19|99\.84|108\.138|204\.246|65\.8|65\.9)\.') {
        return @{ Sni = 'd14hwloucscbyy.cloudfront.net'
                  Path = '/sdk/VRCSDK2-2022.04.20.16.27_Public.unitypackage' }
    }
    return $null
}

if (-not $Sni) {
    $g = Guess-Target $list[0]
    if ($g) { $Sni = $g.Sni; if (-not $Path) { $Path = $g.Path } }
    else { $Sni = 'files.vrchat.cloud'; $Path = '/' }
}
if (-not $Path) { $Path = '/' }

Show "  待测 $($list.Count) 个 IP" White
Show "  SNI  $Sni" DarkGray
Show "  路径 $Path" DarkGray
Show "  轮次 $Rounds   单次上限 ${MaxTime}s" DarkGray
Show ''

# ---------------------------------------------------------------------------
# 测速
# ---------------------------------------------------------------------------
function Measure-One {
    param([string]$Ip, [int]$Limit)
    $best = 0; $sum = 0; $n = 0
    for ($r = 1; $r -le $Rounds; $r++) {
        $x = & "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time $Limit --resolve "${Sni}:443:$Ip" `
             -w '%{speed_download}|%{size_download}|%{http_code}' "https://$Sni$Path" 2>$null | Out-String
        $m = [regex]::Match($x.Trim(), '^([\d.]+)\|(\d+)\|(\d{3})$')
        if ($m.Success -and $m.Groups[3].Value -ne '000') {
            $kb = [math]::Round([double]$m.Groups[1].Value / 1024)
            if ($kb -gt 0) { $sum += $kb; $n++; if ($kb -gt $best) { $best = $kb } }
        }
        # 抗风控：轮次之间歇一下，别短时间连打同一个 IP
        if ($r -lt $Rounds -and $RoundDelayMs -gt 0) { Start-Sleep -Milliseconds $RoundDelayMs }
    }
    if ($n -eq 0) { return $null }
    $avg = [math]::Round($sum / $n)
    return [pscustomobject]@{ IP = $Ip; 平均 = $avg; 最高 = $best; 命中 = "$n/$Rounds" }
}

$rows = New-Object System.Collections.Generic.List[object]
$i = 0
IpClear
foreach ($ip in $list) {
    $i++
    Progress "测速 $i/$($list.Count)   当前 $ip" -MinIntervalMs 0 -Force
    $r = Measure-One -Ip $ip -Limit $MaxTime
    if ($r) { $rows.Add($r) }
    IpTick -G '-' -Ip $ip -Lat -1 -Ok $(if($r){1}else{0}) -Tot 1 `
           -Med -1 -Jit -1 -Note "$(if($r -and $r.KBps){"$($r.KBps) KB/s"}else{'失败'})"
    # 抗风控：换 IP 前也歇一下
    if ($i -lt $list.Count -and $IpDelayMs -gt 0) { Start-Sleep -Milliseconds $IpDelayMs }
}
Write-Host ''

if ($rows.Count -eq 0) {
    Show ''
    Show '  [x] 全部失败 —— 检查 SNI / 路径 / 网络' Red
    exit 1
}

$ranked = @($rows | Sort-Object 平均 -Descending)

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
Show ''
Show '  ─── 吞吐排名 ───' Cyan
Show ("  {0,3}  {1,-16} {0,10} {0,10}   {4}" -f '#','IP','平均 KB/s','最高 KB/s','命中') DarkGray
$n = 0
foreach ($r in $ranked) {
    $n++
    $c = 'Gray'
    if ($r.平均 -ge 3000) { $c = 'Green' }
    elseif ($r.平均 -ge 1500) { $c = 'Cyan' }
    elseif ($r.平均 -lt 500) { $c = 'Red' }
    Show ("  {0,3}. {1,-16} {0,10} {0,10}   {4}" -f $n, $r.IP, $r.平均, $r.最高, $r.命中) $c
}

$csv = Join-Path $OutDir 'speedtest-result.csv'
$ranked | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
Show ''
Show "  完整结果 -> $csv" DarkGray

$best = $ranked | Select-Object -First 1
Show ''
Show ("  >>> 吞吐最优: $($best.IP)   平均 $($best.平均) KB/s") Green
$topTxt = Join-Path $OutDir 'speedtest-best.txt'
($ranked | ForEach-Object { $_.IP }) | Set-Content -Path $topTxt -Encoding ASCII
Show "  按吞吐排序的 IP 清单 -> $topTxt" DarkGray
Show ''
Show '  写进 hosts 的话，用这个（需管理员）：' DarkGray
Show "    sc.exe stop VRChatBypass" DarkGray
Show '    然后编辑 C:\Windows\System32\drivers\etc\hosts' DarkGray
Show '    跑：ipconfig /flushdns ; sc.exe start VRChatBypass' DarkGray
Show ''

exit 0
