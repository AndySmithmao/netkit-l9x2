# ============================================================================
#  VRChat 优选 IP 一键自动重扫 + 测速 + 配置
#
#  用法: 双击 auto-optimize.cmd（自动 UAC 提权）
#        powershell -ExecutionPolicy Bypass -File auto-optimize.ps1 [-Quick] [-Force] [-NoHosts]
#
#  逻辑: Cloudflare 按「TLS 握手延迟中位」选（API/网页场景）
#        CloudFront 按「真实文件下载吞吐中位」选（下载场景）
#        两者先验证能承载全部主机名，再写入 hosts；写入后回归失败自动回滚
# ============================================================================
param(
    [switch]$Quick,
    [switch]$Force,
    [switch]$NoHosts,
    [int]$MinImprovePct = 15
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$RootDir = if ($env:VRCTOOL_ROOT) { $env:VRCTOOL_ROOT } else { Split-Path $PSScriptRoot -Parent }
$DataDir = if ($env:VRCTOOL_DATA) { $env:VRCTOOL_DATA } else { Join-Path $RootDir 'data' }
$hostsPath  = "$env:SystemRoot\System32\drivers\etc\hosts"

# 改 hosts 的唯一入口（原地写会把文件截成 0 字节，见 lib-hosts.ps1 顶部说明）
. (Join-Path $PSScriptRoot 'lib-hosts.ps1')

# ★ 必须自己也 dot-source lib-common ★
#   Progress 在 lib-common.ps1 里。GUI 是**另起进程**跑这个脚本的，
#   新进程继承不到父进程的函数 —— 不自己加载就是 undefined。
#   放在自己的 Show 定义之前，让本脚本的同名函数覆盖 lib-common 的。
. (Join-Path $PSScriptRoot 'lib-common.ps1')
$reportPath = Join-Path $DataDir 'auto-optimize-report.txt'
$bakHosts   = Join-Path $DataDir 'hosts.before-optimize'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

$script:optimizeFailed = $false
Prog 0 100 '准备自动优选'

# 注意: 不要用 R / H / W / Measure 等名字做函数名（R->Invoke-History, H->Get-History, Measure->Measure-Object）
function Show  { param($s, $color = 'Gray') Write-Host $s -ForegroundColor $color }
function AddRep{ param($s) Add-Content -Path $reportPath -Value $s -Encoding UTF8 -ErrorAction SilentlyContinue }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

'' | Set-Content -Path $reportPath -Encoding UTF8
AddRep "======= VRChat 优选 IP 自动重扫 ======="
AddRep ("时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
AddRep "管理员: $isAdmin"
AddRep ""

Show ''
Show '===========================================================' Cyan
Show '  VRChat 优选 IP 自动重扫 + 测速 + 配置' Cyan
Show '===========================================================' Cyan
Show ''
if ($Quick) { Show '  模式: 快速' DarkGray }
if (-not $isAdmin) { Show '  [!] 未提权：可扫描测速，但无法写入 hosts' Yellow }
Show ''

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

# Cloudflare 承载的主机名（同一 IP 可服务全部这些）
$CF_HOSTS  = @('api.vrchat.cloud','pipeline.vrchat.cloud','dev-api.vrchat.cloud',
               'vrchat.com','www.vrchat.com','mail.vrchat.com','creators.vrchat.com','docs.vrchat.com')
# CloudFront 承载的主机名
$CFR_HOSTS = @('files.vrchat.cloud','vrcpm.vrchat.cloud','assets.vrchat.com','status.vrchat.com')
# 第三方托管，不参与优选
$THIRD = [ordered]@{
    'help.vrchat.com'     = '216.198.54.6'
    'feedback.vrchat.com' = '100.56.186.228'
    'hello.vrchat.com'    = '198.49.23.145'
    'ask.vrchat.com'      = '216.66.8.43'
}

function Expand-Slash24 {
    param([string[]]$Cidrs)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Cidrs) {
        $p = $c.Split('/'); if ($p.Count -ne 2) { continue }
        try { $b = ([System.Net.IPAddress]::Parse($p[0])).GetAddressBytes() } catch { continue }
        $base = [uint64]$b[0]*16777216 + [uint64]$b[1]*65536 + [uint64]$b[2]*256 + [uint64]$b[3]
        $pf = [int]$p[1]
        if ($pf -ge 24) { $out.Add("$([int]$b[0]).$([int]$b[1]).$([int]$b[2]).1"); continue }
        $n = [int]([uint64][math]::Pow(2, 32 - $pf) / 256)
        for ($i = 0; $i -lt $n; $i++) {
            $v = $base + [uint64]($i * 256) + 1
            $out.Add("$([int](($v -shr 24) -band 255)).$([int](($v -shr 16) -band 255)).$([int](($v -shr 8) -band 255)).$([int]($v -band 255))")
        }
    }
    return ($out | Sort-Object -Unique)
}

function Invoke-IcmpSweep {
    param([string[]]$Ips, [int]$Timeout = 1000)
    $alive = New-Object System.Collections.Generic.List[object]
    $B = 256; $i = 0; $total = $Ips.Count
    while ($i -lt $total) {
        $e = [Math]::Min($i + $B - 1, $total - 1)
        $slice = $Ips[$i..$e]
        $tasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
        $pings = New-Object System.Collections.Generic.List[System.Net.NetworkInformation.Ping]
        foreach ($ip in $slice) {
            $pg = New-Object System.Net.NetworkInformation.Ping
            $pings.Add($pg)
            $tasks.Add($pg.SendPingAsync($ip, $Timeout))
        }
        [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), $Timeout + 800) | Out-Null
        foreach ($pg in $pings) { try { $pg.Dispose() } catch {} }
        for ($k = 0; $k -lt $slice.Count; $k++) {
            try {
                if ($tasks[$k].Status -eq 'RanToCompletion' -and $tasks[$k].Result.Status -eq 'Success') {
                    $alive.Add((New-Object psobject -Property @{ IP = $slice[$k]; MS = [int]$tasks[$k].Result.RoundtripTime }))
                }
            } catch {}
        }
        $i += $B
        Progress "ICMP 扫描 $([int]($i*100/$total))%   存活 $($alive.Count)" -MinIntervalMs 1500
    }
    Write-Host ''
    return ($alive | Sort-Object MS)
}

# 同步 TLS 握手 + stream 超时（异步版在 PowerShell 里会因 runbook 缺失而失败）
function Test-TlsHandshake {
    param([string]$Sni, [string]$Ip, [int]$Timeout = 3000)
    $o = New-Object psobject -Property @{ IP = $Ip; TLS = -1; CN = ''; OK = $false }
    $c = New-Object System.Net.Sockets.TcpClient
    $ar = $c.BeginConnect($Ip, 443, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne($Timeout)) { $c.Close(); return $o }
    try { $c.EndConnect($ar) } catch { $c.Close(); return $o }
    $c.ReceiveTimeout = $Timeout; $c.SendTimeout = $Timeout
    try {
        $s = New-Object System.Net.Security.SslStream($c.GetStream(), $false, ([System.Net.Security.RemoteCertificateValidationCallback]{ $true }))
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $s.AuthenticateAsClient($Sni)
        $o.TLS = [int]$sw.ElapsedMilliseconds
        $m = [regex]::Match($s.RemoteCertificate.Subject, 'CN=([^,]+)')
        if ($m.Success) { $o.CN = $m.Groups[1].Value.Trim() }
        if ($o.CN -like '*vrchat*') { $o.OK = $true }
        $s.Dispose()
    } catch {}
    $c.Close()
    return $o
}

# 全文件下载测速（不用 Range，Range 会走源站偏慢）
function Measure-Throughput {
    param([string]$Ip, [string]$Sni, [string]$Path, [int]$MaxTime = 10)
    $x = & "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time $MaxTime --resolve "${Sni}:443:$Ip" `
         -w '%{speed_download}|%{size_download}' "https://$Sni$Path" 2>$null | Out-String
    $m = [regex]::Match($x.Trim(), '^([\d.]+)\|(\d+)$')
    if (-not $m.Success) { return 0 }
    return [math]::Round([double]$m.Groups[1].Value / 1024)
}

function Get-CurrentIp {
    param([string]$HostName)
    $l = Get-Content $hostsPath -ErrorAction SilentlyContinue |
         Where-Object { $_ -match "^\s*\d+\.\d+\.\d+\.\d+\s+$([regex]::Escape($HostName))\s*$" } | Select-Object -First 1
    if ($l -and $l -match '^\s*(\d+\.\d+\.\d+\.\d+)') { return $matches[1] }
    return ''
}

$curCf  = Get-CurrentIp 'api.vrchat.cloud'
$curCfr = Get-CurrentIp 'files.vrchat.cloud'
AddRep "当前 hosts: Cloudflare=$curCf  CloudFront=$curCfr"
Show ("  当前 hosts:  Cloudflare = " + $(if ($curCf) { $curCf } else { '(无)' }) + "    CloudFront = " + $(if ($curCfr) { $curCfr } else { '(无)' })) DarkGray
Show ''

$t0 = Get-Date

# ============================ [1/4] Cloudflare ============================
Show '---------- [1/4] Cloudflare（API / 网页，按 TLS 握手延迟）----------' Cyan
$cfRanges = @()
try {
    $txt = (Invoke-WebRequest 'https://www.cloudflare.com/ips-v4' -TimeoutSec 15 -UseBasicParsing).Content
    $cfRanges = @($txt -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' })
} catch {}
if ($cfRanges.Count -eq 0) {
    $cfRanges = @('173.245.48.0/20','103.21.244.0/22','103.22.200.0/22','103.31.4.0/22','141.101.64.0/18',
                  '108.162.192.0/18','190.93.240.0/20','188.114.96.0/20','197.234.240.0/22','198.41.128.0/17',
                  '162.158.0.0/15','104.16.0.0/13','104.24.0.0/14','172.64.0.0/13','131.0.72.0/22')
    Show '    (官网拉取失败，用内置快照)' Yellow
}
Show "    IP 段 $($cfRanges.Count) 条"
$cfTargets = Expand-Slash24 $cfRanges
Show "    候选 $($cfTargets.Count) 个"
$cfAlive = Invoke-IcmpSweep -Ips $cfTargets -Timeout $(if ($Quick) { 800 } else { 1000 })
Show "    ICMP 存活 $($cfAlive.Count)，最快 $($cfAlive[0].MS)ms" Green
AddRep "Cloudflare: 候选 $($cfTargets.Count)，ICMP 存活 $($cfAlive.Count)"

$verifyN = if ($Quick) { 50 } else { 120 }
$pool = @($cfAlive | Select-Object -First $verifyN | ForEach-Object { $_.IP })
if ($curCf -and $pool -notcontains $curCf) { $pool += $curCf }
Show "    TLS 验证 $($pool.Count) 个（须承载 api.vrchat.cloud）..."
$cfOk = New-Object System.Collections.Generic.List[object]
$done = 0
foreach ($ip in $pool) {
    $e = Test-TlsHandshake -Sni 'api.vrchat.cloud' -Ip $ip
    if ($e.OK) { $cfOk.Add([pscustomobject]@{ IP = $ip; TLS = $e.TLS }) }
    $done++
    Progress "TLS 验证 $done/$($pool.Count)   通过 $($cfOk.Count)" -MinIntervalMs 900
}
Write-Host ''
Show "    承载该 zone: $($cfOk.Count)/$($pool.Count)" Green
AddRep "Cloudflare: TLS 验证通过 $($cfOk.Count)/$($pool.Count)"

$benchN = if ($Quick) { 10 } else { 20 }
$cfRounds = if ($Quick) { 4 } else { 7 }
$cfTop = @($cfOk | Sort-Object TLS | Select-Object -First $benchN | ForEach-Object { $_.IP })
if ($curCf -and $cfTop -notcontains $curCf) { $cfTop += $curCf }   # 当前 IP 必须参与对比
Show "    对 $($cfTop.Count) 个做 $cfRounds 轮交替基准..."
$cfAcc = @{}
foreach ($ip in $cfTop) { $cfAcc[$ip] = New-Object System.Collections.Generic.List[int] }
for ($r = 1; $r -le $cfRounds; $r++) {
    foreach ($ip in $cfTop) {
        $e = Test-TlsHandshake -Sni 'api.vrchat.cloud' -Ip $ip
        if ($e.OK -and $e.TLS -ge 0) { $cfAcc[$ip].Add($e.TLS) }
    }
    Progress "延迟轮次 $r/$cfRounds   共 $($cfTop.Count) 个" -MinIntervalMs 0 -Force
}
Write-Host ''
# 评分: 中位 + 抖动惩罚(最大-最小)/4
#   只用中位会选到"中位好但尖峰大"的 IP（实测有中位 54ms 但尖峰 356ms 的），
#   对 API 体验来说稳定性比中位更重要。
$cfRows = foreach ($ip in $cfTop) {
    $v = @($cfAcc[$ip] | Sort-Object)
    if ($v.Count -eq 0) { continue }
    $med = $v[[int](($v.Count - 1) / 2)]
    $jit = $v[-1] - $v[0]
    [pscustomobject]@{
        IP   = $ip
        最小 = $v[0]
        中位 = $med
        最大 = $v[-1]
        抖动 = $jit
        得分 = [int]($med + $jit / 4)
        命中 = "$($v.Count)/$cfRounds"
    }
}
$cfRows = @($cfRows | Sort-Object 得分)
Show ''
Show '    Cloudflare 排名 TOP 6（得分 = 中位 + 抖动/4，越低越好）:' Cyan
$cfRows | Select-Object -First 6 | ForEach-Object { Show ("      {0,-16} 得分 {1,4}  中位 {2,4}ms  最小 {3,4}  最大 {4,4}  抖动 {5,4}  命中 {6}" -f $_.IP, $_.得分, $_.中位, $_.最小, $_.最大, $_.抖动, $_.命中) }
AddRep "Cloudflare 排名(得分=中位+抖动/4):"
$cfRows | Select-Object -First 8 | ForEach-Object { AddRep ("  {0,-16} 得分 {1}  中位 {2}ms  抖动 {3}ms  命中 {4}" -f $_.IP, $_.得分, $_.中位, $_.抖动, $_.命中) }
$cfBest = $cfRows | Select-Object -First 1
$cfNew = if ($cfBest) { $cfBest.IP } else { $curCf }
Show "    >>> 选 $cfNew" Green
Show "    (耗时 $([int]((Get-Date) - $t0).TotalSeconds)s)" DarkGray
Show ''

# ============================ [2/4] CloudFront ============================
Show '---------- [2/4] CloudFront（内容下载，按真实吞吐）----------' Cyan
$t1 = Get-Date
$cfrNew = $curCfr
$cfrRows = @()
$cfrRanges = @()
try {
    $j = Invoke-RestMethod 'https://ip-ranges.amazonaws.com/ip-ranges.json' -TimeoutSec 30
    $cfrRanges = @($j.prefixes | Where-Object { $_.service -eq 'CLOUDFRONT' } | ForEach-Object { $_.ip_prefix } | Select-Object -Unique)
} catch {}
if ($cfrRanges.Count -eq 0) {
    Show '    [!] AWS ip-ranges 拉取失败，跳过 CloudFront' Red
    AddRep 'CloudFront: 跳过（拉取失败）'
} else {
    Show "    前缀 $($cfrRanges.Count) 条"
    $cfrTargets = Expand-Slash24 $cfrRanges
    Show "    候选 $($cfrTargets.Count) 个"
    $cfrAlive = Invoke-IcmpSweep -Ips $cfrTargets -Timeout $(if ($Quick) { 800 } else { 900 })
    Show "    ICMP 存活 $($cfrAlive.Count)，最快 $($cfrAlive[0].MS)ms" Green
    AddRep "CloudFront: 候选 $($cfrTargets.Count)，ICMP 存活 $($cfrAlive.Count)"

    $cfrN = if ($Quick) { 12 } else { 20 }
    $cfrPool = @($cfrAlive | Select-Object -First $cfrN | ForEach-Object { $_.IP })
    foreach ($x in @($curCfr,'13.33.44.1','65.8.72.1','3.173.51.1','13.226.69.72')) {
        if ($x -and $cfrPool -notcontains $x) { $cfrPool += $x }
    }
    $BF = '/sdk/VRCSDK2-2022.04.20.16.27_Public.unitypackage'
    $BH = 'd14hwloucscbyy.cloudfront.net'
    Show "    对 $($cfrPool.Count) 个做初测（全文件 / 7 秒上限）..."
    $s1 = New-Object System.Collections.Generic.List[object]
    $done = 0
    foreach ($ip in $cfrPool) {
        $k = Measure-Throughput -Ip $ip -Sni $BH -Path $BF -MaxTime 7
        if ($k -gt 0) { $s1.Add([pscustomobject]@{ IP = $ip; KBps = $k }) }
        $done++
        Progress "测速 $done/$($cfrPool.Count)   当前 $ip" -MinIntervalMs 0 -Force
    }
    Write-Host ''
    $topN = if ($Quick) { 4 } else { 6 }
    $top = @($s1 | Sort-Object KBps -Descending | Select-Object -First $topN | ForEach-Object { $_.IP })
    if ($curCfr -and $top -notcontains $curCfr) { $top += $curCfr }   # 当前 IP 必须参与对比
    $cfrTimes = if ($Quick) { 3 } else { 5 }
    Show "    对前 $($top.Count) 个做 $cfrTimes 轮确认（全文件 / 12 秒上限）..."
    $cfrOut = New-Object System.Collections.Generic.List[object]
    foreach ($ip in $top) {
        $v = New-Object System.Collections.Generic.List[int]
        for ($r = 1; $r -le $cfrTimes; $r++) {
            $k = Measure-Throughput -Ip $ip -Sni $BH -Path $BF -MaxTime 12
            if ($k -gt 0) { $v.Add($k) }
        }
        if ($v.Count -eq 0) { continue }
        $vv = @($v | Sort-Object)
        $cfrOut.Add([pscustomobject]@{
            IP   = $ip
            中位 = $vv[[int](($vv.Count - 1) / 2)]
            最高 = $vv[-1]
            命中 = "$($v.Count)/$cfrTimes"
        })
    }
    $cfrRows = @($cfrOut | Sort-Object 中位 -Descending)
    Show ''
    Show '    CloudFront 排名（按吞吐中位）:' Cyan
    $cfrRows | ForEach-Object { Show ("      {0,-16} 中位 {1,6} KB/s  最高 {2,6} KB/s  命中 {3}" -f $_.IP, $_.中位, $_.最高, $_.命中) }
    AddRep "CloudFront 排名(按吞吐中位):"
    $cfrRows | ForEach-Object { AddRep ("  {0,-16} 中位 {1} KB/s  命中 {2}" -f $_.IP, $_.中位, $_.命中) }
    $cfrBest = $cfrRows | Where-Object { $_.命中 -notmatch '^0/' } | Select-Object -First 1
    if ($cfrBest) { $cfrNew = $cfrBest.IP }
    Show "    >>> 选 $cfrNew" Green
}
Show "    (耗时 $([int]((Get-Date) - $t1).TotalSeconds)s)" DarkGray
Show ''

# ==================== [3/4] 验证新 IP 承载全部主机名 ====================
Show '---------- [3/4] 验证新 IP 承载全部主机名 ----------' Cyan
$cfOkAll = $true; $cfBad = @()
if ($cfNew) {
    foreach ($h in $CF_HOSTS) {
        $c = (& "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time 10 --resolve "${h}:443:$cfNew" -w '%{http_code}' "https://$h/" 2>&1 | Out-String).Trim()
        if ($c -notmatch '^[1-5]\d\d$') { $cfOkAll = $false; $cfBad += $h }
    }
}
$cfrOkAll = $true; $cfrBad = @()
if ($cfrNew) {
    foreach ($h in $CFR_HOSTS) {
        $c = (& "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time 10 --resolve "${h}:443:$cfrNew" -w '%{http_code}' "https://$h/" 2>&1 | Out-String).Trim()
        if ($c -notmatch '^[1-5]\d\d$') { $cfrOkAll = $false; $cfrBad += $h }
    }
}
$cfMsg  = if ($cfOkAll)  { '全部通过 OK' } else { "失败: $($cfBad -join ',')" }
$cfrMsg = if ($cfrOkAll) { '全部通过 OK' } else { "失败: $($cfrBad -join ',')" }
Show ("    Cloudflare $cfNew : $cfMsg") $(if ($cfOkAll) { 'Green' } else { 'Red' })
Show ("    CloudFront $cfrNew : $cfrMsg") $(if ($cfrOkAll) { 'Green' } else { 'Red' })
AddRep "承载验证: Cloudflare=$cfOkAll ($cfMsg)  CloudFront=$cfrOkAll ($cfrMsg)"
Show ''

# ==================== [4/4] 对比与写入 ====================
Show '---------- [4/4] 对比与写入 ----------' Cyan

$cfCurMed = $null; $cfNewMed = $null
foreach ($x in $cfRows) { if ($x.IP -eq $curCf) { $cfCurMed = $x.中位 }; if ($x.IP -eq $cfNew) { $cfNewMed = $x.中位 } }
$cfrCurMed = $null; $cfrNewMed = $null
foreach ($x in $cfrRows) { if ($x.IP -eq $curCfr) { $cfrCurMed = $x.中位 }; if ($x.IP -eq $cfrNew) { $cfrNewMed = $x.中位 } }

$cfImp = 0; $cfrImp = 0
if ($cfCurMed -and $cfNewMed -and $cfCurMed -gt 0) { $cfImp = [int]((1 - $cfNewMed / $cfCurMed) * 100) }
if ($cfrCurMed -and $cfrNewMed -and $cfrCurMed -gt 0) { $cfrImp = [int](($cfrNewMed / $cfrCurMed - 1) * 100) }

$cfCurTxt  = if ($cfCurMed)  { "$curCf ($cfCurMed ms)" }  else { "$curCf (未参与基准)" }
$cfNewTxt  = if ($cfNewMed)  { "$cfNew ($cfNewMed ms)" }  else { "$cfNew (未参与基准)" }
$cfrCurTxt = if ($cfrCurMed) { "$curCfr ($cfrCurMed KB/s)" } else { "$curCfr (未参与基准)" }
$cfrNewTxt = if ($cfrNewMed) { "$cfrNew ($cfrNewMed KB/s)" } else { "$cfrNew (未参与基准)" }

Show ''
Show ("    Cloudflare: 当前 $cfCurTxt  ->  新 $cfNewTxt    提升 $cfImp%")
Show ("    CloudFront: 当前 $cfrCurTxt  ->  新 $cfrNewTxt    提升 $cfrImp%")
AddRep ""
AddRep ("对比: Cloudflare 提升 $cfImp%   CloudFront 提升 $cfrImp%")
Show ''

$worthIt  = $Force -or ($cfImp -ge $MinImprovePct) -or ($cfrImp -ge $MinImprovePct) -or (-not $curCf) -or (-not $curCfr)
$canWrite = $isAdmin -and (-not $NoHosts) -and $cfOkAll -and $cfrOkAll -and $cfNew -and $cfrNew

if (-not $canWrite) {
    $why = @()
    if (-not $isAdmin) { $why += '未提权' }
    if ($NoHosts) { $why += '-NoHosts' }
    if (-not $cfOkAll -or -not $cfrOkAll) { $why += '承载验证失败' }
    Show ("    跳过写入（" + ($why -join ' / ') + "）") Yellow
    Show ''
    Show '    建议手动写入:' Cyan
    Show ("      {0,-16} {1}" -f $cfNew, ($CF_HOSTS -join ' / '))
    Show ("      {0,-16} {1}" -f $cfrNew, ($CFR_HOSTS -join ' / '))
} elseif (-not $worthIt) {
    Show ("    提升不足 $MinImprovePct%，保持现状（加 -Force 可强制写入）") Yellow
    AddRep "提升不足，未写入"
} else {
    Copy-Item $hostsPath $bakHosts -Force
    Show "    已备份 -> $bakHosts" DarkGray
    $BEGIN = '# ===== VRChat-bypass BEGIN ====='
    $END   = '# ===== VRChat-bypass END ====='

    # 一次性算好「保留的旧内容 + 新块」，再整体原子写入。
    # 原来是 Set-Content（截断写）+ Add-Content（追加写）两步 —— 中间任何一步
    # 失败（Defender 拦截、进程被杀）都会留下半截 hosts，而且第一步已经把用户
    # 原有内容截掉了。
    $strip = Remove-HostsBlock -Path $hostsPath -Begin $BEGIN -End $END
    if ($strip.Error) {
        Show "    [x] 读取 hosts 失败，已中止（不会覆盖原文件）: $($strip.Error)" Red
        AddRep '读取 hosts 失败'
        Done 'fail' '读取 hosts 失败'
        exit 1
    }
    if ($strip.Unpaired) {
        Show '    [x] hosts 里的标记行不成对，为避免误删已中止；请手工删掉单独出现的 BEGIN/END 行后重试' Red
        AddRep 'hosts 标记行不成对'
        Done 'fail' 'hosts 标记行不成对'
        exit 1
    }
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($l in $strip.Lines) { $all.Add($l) }
    $all.Add(''); $all.Add($BEGIN)
    $all.Add("# auto-optimized $((Get-Date).ToString('yyyy-MM-dd HH:mm'))  CF=$cfNew  CFR=$cfrNew")
    foreach ($h in $CF_HOSTS)  { $all.Add(('{0,-16} {1}' -f $cfNew,  $h)) }
    foreach ($h in $CFR_HOSTS) { $all.Add(('{0,-16} {1}' -f $cfrNew, $h)) }
    foreach ($h in $THIRD.Keys){ $all.Add(('{0,-16} {1}' -f $THIRD[$h], $h)) }
    $all.Add($END)

    if (-not (Write-HostsSafe -Path $hostsPath -Lines $all -ExpectIp $cfNew)) {
        Show '    [x] 写入 hosts 失败 —— 已保持原样，没有留下空文件' Red
        AddRep '写入 hosts 失败'
        $script:optimizeFailed = $true
        Done 'fail' '写入 hosts 失败'
        exit 1
    } else {
        & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
        Show '    已写入 hosts 并刷新 DNS' Green
    }
    Show ''
    Show '    写入后回归验证...' Cyan
    $bad = @()
    foreach ($h in ($CF_HOSTS + $CFR_HOSTS)) {
        $ok = 0
        for ($i = 1; $i -le 2; $i++) {
            $c = (& "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time 12 -w '%{http_code}' "https://$h/" 2>&1 | Out-String).Trim()
            if ($c -match '^[1-5]\d\d$') { $ok++ }
        }
        if ($ok -eq 0) { $bad += $h }
        Show ("      {0} {1}" -f $(if ($ok -gt 0) { '[ok]' } else { '[x] ' }), $h) $(if ($ok -gt 0) { 'Gray' } else { 'Red' })
    }
    if ($bad.Count -gt 0) {
        Show ''
        Show ("    [!] $($bad.Count) 个域名失败，回滚 hosts") Red
        $rb = @(Get-Content $bakHosts -ErrorAction SilentlyContinue)
        if ($rb.Count -gt 0) { [void](Write-HostsSafe -Path $hostsPath -Lines $rb) }
        & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
        Show '    已回滚' Yellow
        AddRep "写入后回归失败，已回滚: $($bad -join ',')"
    } else {
        Show ''
        Show '    全部通过' Green
        AddRep '写入成功，全部验证通过'
    }
}

$elapsed = [int]((Get-Date) - $t0).TotalSeconds
Show ''
Show '===========================================================' Cyan
Show ("  完成，耗时 $([int]($elapsed/60)) 分 $($elapsed % 60) 秒") Cyan
Show '===========================================================' Cyan
Show ''
Show "  Cloudflare -> $cfNew" White
Show "  CloudFront -> $cfrNew" White
Show "  报告: $reportPath" DarkGray
Show ''
AddRep ""
AddRep "耗时 $elapsed 秒"
AddRep "最终: Cloudflare=$cfNew  CloudFront=$cfrNew"

# 结束标记 + 退出码（GUI 靠 ##DONE## 停掉转圈；退出码决定要不要提示失败）
if ($script:optimizeFailed) {
    Done 'fail' '优选过程中有失败项'
    exit 1
}
Prog 100 100 '完成'
Done 'ok' '自动优选完成'
exit 0
