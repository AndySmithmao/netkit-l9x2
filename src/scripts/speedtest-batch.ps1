# ============================================================================
#  【功能3】下载测速
#  对延迟实测出的候选做真实文件下载测速
#
#  输入: latency-result.csv （没有就先跑【功能2】延迟实测）
#        或者手动指定 IP 清单
#  输出: speed-result.csv
#
#  用法:
#     powershell -ExecutionPolicy Bypass -File speedtest-batch.ps1
#     powershell -ExecutionPolicy Bypass -File speedtest-batch.ps1 -Rounds 3
#     powershell -ExecutionPolicy Bypass -File speedtest-batch.ps1 -Ips "1.2.3.4,5.6.7.8" -Group B
#     powershell -ExecutionPolicy Bypass -File speedtest-batch.ps1 -File 我的清单.txt -Group A
# ============================================================================
param(
    [int]$Rounds = 2,
    [int]$LimitSec = 8,
    [int]$DelayMs = 300,
    [string]$Ips = '',
    [string]$File = '',
    [ValidateSet('A','B','auto')]
    [string]$Group = 'auto',
    [switch]$Quick
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib-common.ps1')

if ($Quick) { $Rounds = 1; $LimitSec = 6 }

Show ''
Rule '='
Show '  【功能3】下载测速' Cyan
Rule '='
Show ''

# ---- 收集待测 IP ----
$targets = @()   # @{ Ip=..; Group=.. }
if ($Ips -or $File) {
    $lst = New-Object System.Collections.Generic.List[string]
    if ($File -and (Test-Path $File)) {
        Get-Content $File | ForEach-Object { $v = $_.Trim(); if ($v -match '^\d{1,3}(\.\d{1,3}){3}$') { $lst.Add($v) } }
    }
    if ($Ips) { foreach ($v in ($Ips -split '[,;\s]+')) { $v = $v.Trim(); if ($v -match '^\d{1,3}(\.\d{1,3}){3}$') { $lst.Add($v) } } }
    $lst = $lst | Select-Object -Unique
    foreach ($ip in $lst) {
        $g = $Group
        if ($g -eq 'auto') {
            # 按网段猜
            if ($ip -match '^(104\.1[6-9]|172\.6[4-6]|162\.15[89]|108\.162|141\.101|173\.245|103\.2|188\.114|190\.93|197\.234|198\.41|131\.0)\.') { $g = 'A' }
            else { $g = 'B' }
        }
        $targets += [pscustomobject]@{ IP = $ip; 组 = $g; 中位 = 0; 抖动 = 0; 成功率 = 0 }
    }
    Head '[1/2] 手动清单'
    Show "       共 $($targets.Count) 个 IP" Gray
} else {
    if (-not (Test-Path $script:FileLatency)) {
        Bad '没有找到 latency-result.csv'
        Show ''
        Show '  请先运行【功能2】延迟实测:   powershell -ExecutionPolicy Bypass -File latency-test.ps1' White
        Show '  或者用 -Ips / -File 直接指定要测的 IP' White
        Show ''
        exit 1
    }
    $lat = @(Import-Csv $script:FileLatency)
    $targets = @($lat | ForEach-Object {
        [pscustomobject]@{ IP = $_.IP; 组 = $_.组; 中位 = [int]$_.中位; 抖动 = [int]$_.抖动; 成功率 = [int]$_.成功率 }
    })
    Head '[1/2] 载入候选'
    Show "       来自 latency-result.csv，共 $($targets.Count) 个 IP" Gray
    Show "       A 组 $(@($targets | Where-Object { $_.组 -eq 'A' }).Count) 个   B 组 $(@($targets | Where-Object { $_.组 -eq 'B' }).Count) 个" DarkGray
}

if ($targets.Count -eq 0) { Bad '没有待测 IP'; exit 1 }

# ---- 测速 ----
Head "[2/2] 下载测速    $($targets.Count) 个 × $Rounds 轮（单次上限 ${LimitSec}s）"
Show '       A 组基准: docs.vrchat.com 首页（约 190KB，偏小，仅供参考）' DarkGray
Show '       B 组基准: assets 分布域 SDK 文件（约 6.3MB，准确）' DarkGray
Write-Host ''

$sw = [Diagnostics.Stopwatch]::StartNew()
$out = @()
$i = 0
IpClear
foreach ($t in $targets) {
    $i++
    $v = New-Object System.Collections.ArrayList
    for ($r = 1; $r -le $Rounds; $r++) {
        $k = Measure-Speed -Ip $t.IP -Group $t.组 -Limit $LimitSec
        [void]$v.Add($k)
        # ★ 每测完一轮就汇报
        $hit = @($v | Where-Object { $_ -gt 0 }).Count
        IpTick -G $t.组 -Ip $t.IP -Lat $t.中位 -Ok $hit -Tot $r `
               -Med -1 -Jit -1 -Note "$(if($k -gt 0){"$k KB/s"}else{'失败'})"
        if ($r -lt $Rounds -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }
    $vv = @($v | Where-Object { $_ -gt 0 } | Sort-Object)
    $med = 0; $mx = 0
    if ($vv.Count -gt 0) { $med = $vv[[int](($vv.Count - 1) / 2)]; $mx = $vv[-1] }
    $out += [pscustomobject]@{
        组     = $t.组
        IP     = $t.IP
        速度   = $med
        最高   = $mx
        延迟中位 = $t.中位
        抖动   = $t.抖动
        延迟成功率 = $t.成功率
        测速命中 = "$($vv.Count)/$Rounds"
        有效速度 = [int]($med * $t.成功率 / 100)
    }
    $el = [int]$sw.Elapsed.TotalSeconds
    $eta = [int]($el / $i * ($targets.Count - $i))
    Progress "$i/$($targets.Count)   已测完 $($t.IP) = $(if($med){"$med KB/s"}else{"失败"})   已用 ${el}s   剩余约 $(Format-Eta $eta)" -MinIntervalMs 0 -Force
    Prog $i $targets.Count "测速 $i/$($targets.Count)"
    if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
}
Prop-Done
Prog 100 100 '测速完成'
Done 'ok' "测速完成，耗时 $(Format-Eta ([int]$sw.Elapsed.TotalSeconds))"
Ok "完成，耗时 $(Format-Eta ([int]$sw.Elapsed.TotalSeconds))"

$out | Export-Csv -Path $script:FileSpeed -NoTypeInformation -Encoding UTF8

# ---- 结果 ----
foreach ($g in 'A','B') {
    $r = @($out | Where-Object { $_.组 -eq $g })
    if ($r.Count -eq 0) { continue }
    if ($g -eq 'B') { $r = @($r | Sort-Object @{e={$_.有效速度};Descending=$true}, @{e={$_.速度};Descending=$true}) }
    else            { $r = @($r | Sort-Object @{e={$_.速度};Descending=$true}) }
    Write-Host ''
    $title = if ($g -eq 'A') { 'A 组 - Cloudflare（API / 网页）' } else { 'B 组 - CloudFront（内容下载）' }
    Show "  ── $title ──" Cyan
    Show ("     {0,-5} {1,-16} {2,10} {3,11} {4,9} {5,8} {6,9}" -f '编号','IP','下载速度','有效速度','中位延迟','测速命中','延迟成功率') DarkGray
    Show ('     ' + ('-' * 86)) DarkGray
    $i = 0
    foreach ($x in $r) {
        $i++
        $c = 'Gray'
        if ($x.速度 -ge 1500) { $c = 'Green' } elseif ($x.速度 -ge 500) { $c = 'Cyan' } elseif ($x.速度 -le 0) { $c = 'Red' }
        Show ("     {0,-5} {1,-16} {2,7} KB/s {3,8} KB/s {4,6}ms {5,8} {6,8}%" -f `
              $i, $x.IP, $x.速度, $x.有效速度, $x.延迟中位, $x.测速命中, $x.延迟成功率) $c
    }
}

Write-Host ''
Rule '='
Ok "结果已保存 -> $script:FileSpeed"
Show '  下一步: 【功能4】清单选用   powershell -ExecutionPolicy Bypass -File list-and-pick.ps1' White
Rule '='
Write-Host ''

exit 0
