# ============================================================================
#  VRChat 优选 IP 一键重扫
#  用法: 右键“使用 PowerShell 运行”，或 powershell -ExecutionPolicy Bypass -File 本文件
#  产出: <数据目录>\优选结果.txt（可直接粘贴进 hosts）
#  建议: 每 1~2 个月重跑一次，或在游戏明显变卡时重跑
# ============================================================================
param(
    [int]$IcmpTimeout = 1000,
    [int]$Rounds      = 3,
    [int]$CfTopN      = 40,
    [int]$CfrTopN     = 30
)
$ProgressPreference = 'SilentlyContinue'

# 输出目录：优先用 GUI 传进来的数据目录（VRCTOOL_DATA），
# 直接双击/命令行跑时退回到脚本上一级目录下的 data\。
# 以前这里写死成开发机路径，打进 EXE 发给用户后会往不存在的目录里写。
$outDir = if ($env:VRCTOOL_DATA) { $env:VRCTOOL_DATA } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'data' }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$resultFile = Join-Path $outDir '优选结果.txt'

function Expand-Slash24 {
    param([string[]]$Cidrs)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Cidrs) {
        $p = $c.Split('/'); if ($p.Count -ne 2) { continue }
        try { $b = ([System.Net.IPAddress]::Parse($p[0])).GetAddressBytes() } catch { continue }
        $base = [uint64]$b[0]*16777216 + [uint64]$b[1]*65536 + [uint64]$b[2]*256 + [uint64]$b[3]
        $pref = [int]$p[1]
        if ($pref -ge 24) { $out.Add("$([int]$b[0]).$([int]$b[1]).$([int]$b[2]).1"); continue }
        $n = [int]([uint64][math]::Pow(2,32-$pref) / 256)
        for ($i=0; $i -lt $n; $i++) {
            $v = $base + [uint64]($i*256) + 1
            $out.Add("$([int](($v -shr 24) -band 255)).$([int](($v -shr 16) -band 255)).$([int](($v -shr 8) -band 255)).$([int]($v -band 255))")
        }
    }
    return ($out | Sort-Object -Unique)
}

function Invoke-IcmpSweep {
    param([string[]]$Ips, [int]$Timeout)
    $alive = New-Object System.Collections.Generic.List[object]
    $Batch = 256; $i = 0
    while ($i -lt $Ips.Count) {
        $end = [Math]::Min($i+$Batch-1, $Ips.Count-1)
        $slice = $Ips[$i..$end]
        $tasks = New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
        $pings = New-Object System.Collections.Generic.List[System.Net.NetworkInformation.Ping]
        foreach ($ip in $slice) { $pg = New-Object System.Net.NetworkInformation.Ping; $pings.Add($pg); $tasks.Add($pg.SendPingAsync($ip, $Timeout)) }
        [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray(), $Timeout + 800) | Out-Null
        foreach ($pg in $pings) { try { $pg.Dispose() } catch {} }
        for ($k=0; $k -lt $slice.Count; $k++) {
            try { if ($tasks[$k].Status -eq 'RanToCompletion' -and $tasks[$k].Result.Status -eq 'Success') {
                $alive.Add((New-Object psobject -Property @{ IP=$slice[$k]; MS=[int]$tasks[$k].Result.RoundtripTime }))
            } } catch {}
        }
        $i += $Batch
    }
    return ($alive | Sort-Object MS)
}

# 同步 TLS 握手 + stream 超时（异步方式在 PowerShell 里会因 runspace 缺失而失败）
function Test-Edge {
    param([string]$Sni, [string]$Ip, [int]$Timeout = 3000)
    $o = New-Object psobject -Property @{ Ip=$Ip; Tcp=-1; Tls=-1; Cn=''; Ok=$false }
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ar = $c.BeginConnect($Ip, 443, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($Timeout)) { $c.Close(); return $o }
        $c.EndConnect($ar); $o.Tcp = [int]$sw.ElapsedMilliseconds
    } catch { $c.Close(); return $o }
    $c.ReceiveTimeout = $Timeout; $c.SendTimeout = $Timeout
    try {
        $s = New-Object System.Net.Security.SslStream($c.GetStream(), $false, ([System.Net.Security.RemoteCertificateValidationCallback]{ $true }))
        $sw.Restart(); $s.AuthenticateAsClient($Sni); $o.Tls = [int]$sw.ElapsedMilliseconds
        $m = [regex]::Match($s.RemoteCertificate.Subject, 'CN=([^,]+)')
        if ($m.Success) { $o.Cn = $m.Groups[1].Value.Trim() }
        if ($o.Cn -like '*vrchat*') { $o.Ok = $true }
        $s.Dispose()
    } catch {}
    $c.Close()
    return $o
}

function Get-Best {
    param([string]$Sni, [string[]]$Pool, [int]$Rounds)
    $acc = @{}
    foreach ($ip in $Pool) { $acc[$ip] = New-Object System.Collections.Generic.List[object] }
    for ($r = 1; $r -le $Rounds; $r++) {
        foreach ($ip in $Pool) {
            $e = Test-Edge -Sni $Sni -Ip $ip
            if ($e.Ok) { $acc[$ip].Add($e) }
        }
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($ip in $Pool) {
        $s = $acc[$ip]; if ($s.Count -eq 0) { continue }
        $tl = @($s | ForEach-Object { $_.Tls } | Sort-Object)
        $tc = @($s | ForEach-Object { $_.Tcp } | Sort-Object)
        $rows.Add((New-Object psobject -Property @{
            IP = $ip
            TcpMin = $tc[0]; TcpMed = $tc[[int][math]::Floor(($tc.Count-1)/2)]
            TlsMin = $tl[0]; TlsMed = $tl[[int][math]::Floor(($tl.Count-1)/2)]
            Hit = "$($s.Count)/$Rounds"
        }))
    }
    return ($rows | Sort-Object TlsMed)
}

'================================================================'
'  VRChat 优选 IP 扫描开始'
'================================================================'

# ---------------- Cloudflare ----------------
Write-Host "[1/4] 获取 Cloudflare 官方 IP 段 ..."
$cfRanges = @()
try {
    $txt = (Invoke-WebRequest -Uri 'https://www.cloudflare.com/ips-v4' -TimeoutSec 15 -UseBasicParsing).Content
    $cfRanges = @($txt -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' })
} catch {}
if ($cfRanges.Count -eq 0) { Write-Host '[!] 官网拉取失败'; exit 1 }
Write-Host "      拿到 $($cfRanges.Count) 条"

Write-Host "[2/4] 展开 /24 并 ICMP 俯冲 ..."
$cfTargets = Expand-Slash24 -Cidrs $cfRanges
Write-Host "      候选 $($cfTargets.Count)，预计 30 秒"
$cfAlive = Invoke-IcmpSweep -Ips $cfTargets -Timeout $IcmpTimeout
Write-Host "      ICMP 存活 $($cfAlive.Count)，最快 $($cfAlive[0].MS)ms"

Write-Host "[3/4] 对最快 $CfTopN 个做 TLS 验证（api.vrchat.cloud）..."
$cfPool = @($cfAlive | Select-Object -First $CfTopN | ForEach-Object { $_.IP })
$cfBest = Get-Best -Sni 'api.vrchat.cloud' -Pool $cfPool -Rounds $Rounds
$cfBest | Select-Object -First 8 | Format-Table IP, TcpMin, TcpMed, TlsMin, TlsMed, Hit -AutoSize | Out-String -Width 100 | Write-Host

# ---------------- CloudFront ----------------
Write-Host "[4/4] CloudFront（files.vrchat.cloud）..."
$cfrRanges = @()
try {
    $j = Invoke-RestMethod -Uri 'https://ip-ranges.amazonaws.com/ip-ranges.json' -TimeoutSec 30
    $cfrRanges = @($j.prefixes | Where-Object { $_.service -eq 'CLOUDFRONT' } | ForEach-Object { $_.ip_prefix } | Select-Object -Unique)
} catch {}
$cfrBest = @()
if ($cfrRanges.Count -gt 0) {
    $cfrTargets = Expand-Slash24 -Cidrs $cfrRanges
    Write-Host "      候选 $($cfrTargets.Count)"
    $cfrAlive = Invoke-IcmpSweep -Ips $cfrTargets -Timeout $IcmpTimeout
    Write-Host "      ICMP 存活 $($cfrAlive.Count)"
    $cfrPool = @($cfrAlive | Select-Object -First $CfrTopN | ForEach-Object { $_.IP })
    $cfrBest = Get-Best -Sni 'files.vrchat.cloud' -Pool $cfrPool -Rounds $Rounds
    $cfrBest | Select-Object -First 8 | Format-Table IP, TcpMin, TcpMed, TlsMin, TlsMed, Hit -AutoSize | Out-String -Width 100 | Write-Host
} else {
    Write-Host '      [!] AWS ip-ranges 拉取失败，跳过'
}

# ---------------- 输出 ----------------
$cf1 = '-'; $cf2 = '-'; $cf3 = '-'
if ($cfBest.Count -ge 3) { $cf1=$cfBest[0].IP; $cf2=$cfBest[1].IP; $cf3=$cfBest[2].IP }
$fr1 = '-'; $fr2 = '-'
if ($cfrBest.Count -ge 2) { $fr1=$cfrBest[0].IP; $fr2=$cfrBest[1].IP }

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# VRChat hosts —— 优选 IP 扫描结果")
$lines.Add("# 生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("# 本轮延迟: api.vrchat.cloud=$($cfBest[0].TlsMed)ms  files.vrchat.cloud=$($cfrBest[0].TlsMed)ms")
$lines.Add("")
$lines.Add("$cf1`tapi.vrchat.cloud")
$lines.Add("$cf1`tpipeline.vrchat.cloud")
$lines.Add("$cf1`tdev-api.vrchat.cloud")
$lines.Add("")
$lines.Add("$fr1`tfiles.vrchat.cloud")
$lines.Add("$fr1`tvrcpm.vrchat.cloud")
$lines.Add("")
$lines.Add("# 备用（主 IP 失效时替换上面的）")
$lines.Add("# api/pipeline/dev-api  -> $cf2 / $cf3")
$lines.Add("# files/vrcpm           -> $fr2")
$lines.Add("")
$lines.Add("# SNI 被阻断，优选无意义，仅保证解析正确:")
$lines.Add("104.18.6.156`tvrchat.com")
$lines.Add("104.18.6.156`twww.vrchat.com")
$lines.Add("104.16.241.118`tdocs.vrchat.com")
$lines.Add("13.226.69.72`tassets.vrchat.com")
$lines.Add("13.226.69.92`tstatus.vrchat.com")
$lines.Add("104.18.6.156`tmail.vrchat.com")
$lines.Add("104.18.6.156`tcreators.vrchat.com")
$lines.Add("")
$lines.Add("# 第三方托管")
$lines.Add("216.198.53.6`thelp.vrchat.com")
$lines.Add("100.56.186.228`tfeedback.vrchat.com")
$lines.Add("128.242.240.212`thello.vrchat.com")
$lines.Add("216.66.8.43`task.vrchat.com")

$lines | Set-Content -Path $resultFile -Encoding UTF8

''
'================================================================'
"  完成！结果已写入: $resultFile"
'================================================================'
$lines | Write-Host
''
'提示: 用 fix-vrchat-hosts.cmd 可自动把上面的优选 IP 写入系统 hosts'

exit 0
