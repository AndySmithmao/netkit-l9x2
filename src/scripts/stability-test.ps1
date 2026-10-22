# ============================================================================
#  稳定性复测 —— 同一个 IP 反复测，统计超时率
#  说明为什么「单次扫描选出来的最快 IP」不一定可靠
# ============================================================================
param(
    [int]$Rounds = 15,
    [int]$DelayMs = 200,
    [int]$Timeout = 4000,
    [int]$CfTop = 10,
    [int]$CfrTop = 10
)
$ErrorActionPreference = 'Continue'

# ★ 必须自己 dot-source lib-common ★
#   Progress / Prop-Done / IpClear / IpTick 在 lib-common.ps1 里。
#   本脚本是被**另起进程**调用的，继承不到任何函数 —— 不自己加载就是 undefined。
#   注意 lib-common 会 Add-Type 编译 VrcProbe，所以本脚本后面那段自己的 Add-Type
#   仍然保留（它定义的是本脚本专用的类，和 VrcProbe 不冲突）。
. (Join-Path $PSScriptRoot 'lib-common.ps1')

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Net.Security;
using System.Net.Sockets;
using System.Threading;

public class Stab {
    public string Ip; public int Tls = -1; public string Err = "";
    public static Stab One(string ip, string sni, int timeoutMs) {
        var r = new Stab { Ip = ip };
        var sw = Stopwatch.StartNew();
        try {
            using (var c = new TcpClient()) {
                var ar = c.BeginConnect(ip, 443, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs)) { r.Err = "tcp超时"; return r; }
                c.EndConnect(ar);
                c.ReceiveTimeout = timeoutMs; c.SendTimeout = timeoutMs;
                using (var s = new SslStream(c.GetStream(), false,
                       new RemoteCertificateValidationCallback((a, b, cc, d) => true))) {
                    sw.Restart();
                    s.AuthenticateAsClient(sni);
                    r.Tls = (int)sw.ElapsedMilliseconds;
                }
            }
        } catch (Exception e) { r.Err = e.GetType().Name; }
        return r;
    }
}
'@ -ErrorAction Stop

$cf  = @(Import-Csv (Join-Path $script:InstallDir 'full-scan-cloudflare.csv') | Where-Object { $_.Ok -eq 'True' } | Sort-Object { [int]$_.Tls })
$cfr = @(Import-Csv (Join-Path $script:InstallDir 'full-scan-cloudfront.csv') | Where-Object { $_.Ok -eq 'True' } | Sort-Object { [int]$_.Tls })

$items = @()
foreach ($r in ($cf  | Select-Object -First $CfTop))  { $items += @{ Ip = $r.Ip;  Sni = 'api.vrchat.cloud';   G = 'CF'  } }
foreach ($r in ($cfr | Select-Object -First $CfrTop)) { $items += @{ Ip = $r.Ip;  Sni = 'files.vrchat.cloud'; G = 'CFR' } }

Write-Host ''
Write-Host '============================================================' Cyan
Write-Host '  稳定性复测：同一 IP 反复测' Cyan
Write-Host '============================================================' Cyan
Write-Host "  对象 $($items.Count) 个 IP    每轮 $Rounds 次    间隔 ${DelayMs}ms    超时 ${Timeout}ms"
Write-Host "  轮次交替进行（消除时间偏置）"
Write-Host ''

$acc = @{}
foreach ($it in $items) { $acc[$it.Ip] = New-Object System.Collections.ArrayList }

IpClear
for ($r = 1; $r -le $Rounds; $r++) {
    foreach ($it in $items) {
        $res = [Stab]::One($it.Ip, $it.Sni, $Timeout)
        [void]$acc[$it.Ip].Add($res)
        $vv = @($acc[$it.Ip] | Where-Object { $_.Tls -ge 0 } | ForEach-Object { $_.Tls } | Sort-Object)
        $med2 = if($vv.Count){ $vv[[int](($vv.Count-1)/2)] } else { -1 }
        IpTick -G '-' -Ip $it.Ip -Lat $res.Tls -Ok $vv.Count -Tot $acc[$it.Ip].Count `
               -Med $med2 -Jit -1 -Note "第 $r/$Rounds 轮"
        Start-Sleep -Milliseconds $DelayMs
    }
    Progress "轮 $r/$Rounds   共 $($items.Count) 个 IP" -MinIntervalMs 0 -Force
}
Prop-Done
Write-Host ''

$rows = @()
foreach ($it in $items) {
    $all  = @($acc[$it.Ip])
    $ok   = @($all | Where-Object { $_.Tls -ge 0 })
    $to   = @($all | Where-Object { $_.Err -like '*超时*' -or $_.Err -like '*TimedOut*' })
    $fail = $all.Count - $ok.Count
    $lat  = @($ok | ForEach-Object { $_.Tls } | Sort-Object)
    $med = '-'; $mn = '-'; $mx = '-'
    if ($lat.Count -gt 0) { $mn = $lat[0]; $med = $lat[[int](($lat.Count-1)/2)]; $mx = $lat[-1] }
    $rows += [pscustomobject]@{
        组   = $it.G
        IP   = $it.Ip
        成功 = "$($ok.Count)/$($all.Count)"
        成功率 = [int]($ok.Count * 100 / $all.Count)
        超时 = $to.Count
        其他失败 = $fail - $to.Count
        最小 = $mn
        中位 = $med
        最大 = $mx
    }
}

Write-Host '  ── Cloudflare 组 ──' Cyan
Write-Host ("  {0,-16} {1,7} {2,6} {3,6} {4,7} {5,7} {6,7}" -f 'IP','成功','成功率','超时','最小','中位','最大') DarkGray
foreach ($r in ($rows | Where-Object { $_.组 -eq 'CF' })) {
    $c = 'Gray'
    if ($r.成功率 -eq 100) { $c = 'Green' } elseif ($r.成功率 -ge 80) { $c = 'Yellow' } else { $c = 'Red' }
    Write-Host ("  {0,-16} {1,7} {2,5}% {3,6} {4,7} {5,7} {6,7}" -f $r.IP, $r.成功, $r.成功率, $r.超时, $r.最小, $r.中位, $r.最大) $c
}

Write-Host ''
Write-Host '  ── CloudFront 组 ──' Cyan
Write-Host ("  {0,-16} {1,7} {2,6} {3,6} {4,7} {5,7} {6,7}" -f 'IP','成功','成功率','超时','最小','中位','最大') DarkGray
foreach ($r in ($rows | Where-Object { $_.组 -eq 'CFR' })) {
    $c = 'Gray'
    if ($r.成功率 -eq 100) { $c = 'Green' } elseif ($r.成功率 -ge 80) { $c = 'Yellow' } else { $c = 'Red' }
    Write-Host ("  {0,-16} {1,7} {2,5}% {3,6} {4,7} {5,7} {6,7}" -f $r.IP, $r.成功, $r.成功率, $r.超时, $r.最小, $r.中位, $r.最大) $c
}

Write-Host ''
Write-Host '  ── 汇总 ──' Cyan
$perfect = @($rows | Where-Object { $_.成功率 -eq 100 })
$flaky   = @($rows | Where-Object { $_.成功率 -lt 100 -and $_.成功率 -ge 80 })
$bad     = @($rows | Where-Object { $_.成功率 -lt 80 })
Write-Host "    100% 稳定 : $($perfect.Count) 个" Green
Write-Host "    80~99%    : $($flaky.Count) 个  （偶发超时）" Yellow
Write-Host "    < 80%     : $($bad.Count) 个  （不可靠）" Red
Write-Host ''
if ($perfect.Count -gt 0) {
    Write-Host '    >>> 100% 稳定的 IP（优先选这些）:' Green
    foreach ($r in $perfect) { Write-Host ("        {0,-16} 中位 {1}ms  最大 {2}ms" -f $r.IP, $r.中位, $r.最大) Green }
}
Write-Host ''

$rows | Export-Csv -Path (Join-Path $script:InstallDir 'stability-report.csv') -NoTypeInformation -Encoding UTF8
Write-Host ("  明细 -> " + (Join-Path $script:InstallDir 'stability-report.csv')) DarkGray
Write-Host ''

exit 0
