# ============================================================================
#  【功能2】延迟实测
#  对候选池做多轮交替 TLS 握手，统计中位 / 抖动 / 成功率
#
#  输入: full-scan-cloudflare.csv + full-scan-cloudfront.csv（没有就先跑【功能1】全量扫描）
#  输出: latency-result.csv
#
#  用法:
#     powershell -ExecutionPolicy Bypass -File latency-test.ps1
#     powershell -ExecutionPolicy Bypass -File latency-test.ps1 -TopN 40 -Rounds 5
#     powershell -ExecutionPolicy Bypass -File latency-test.ps1 -Quick
# ============================================================================
param(
    [int]$TopN = 40,
    [int]$Rounds = 5,
    [int]$DelayMs = 200,
    [int]$Timeout = 4000,
    [switch]$Quick
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib-common.ps1')

if ($Quick) { $Rounds = 3; $DelayMs = 120 }

Show ''
Rule '='
Show '  【功能2】延迟实测' Cyan
Rule '='
Show ''

# ---- 载入候选 ----
if (-not (Test-Path $script:FileScanCf) -or -not (Test-Path $script:FileScanCfr)) {
    Bad '没有找到全量扫描结果'
    Show ''
    Show '  请先运行【功能1】全量扫描:  powershell -ExecutionPolicy Bypass -File full-scan.ps1' White
    Show ''
    exit 1
}
$cfAll  = @(Import-Csv $script:FileScanCf  | Where-Object { $_.Ok -eq 'True' } | Sort-Object { [int]$_.Tls })
$cfrAll = @(Import-Csv $script:FileScanCfr | Where-Object { $_.Ok -eq 'True' } | Sort-Object { [int]$_.Tls })
if ($cfAll.Count -eq 0 -or $cfrAll.Count -eq 0) { Bad '扫描结果为空，请重跑全量扫描'; exit 1 }

$cfList  = @($cfAll  | Select-Object -First $TopN | ForEach-Object { $_.Ip })
$cfrList = @($cfrAll | Select-Object -First $TopN | ForEach-Object { $_.Ip })

$age = [int]((Get-Date) - (Get-Item $script:FileScanCf).LastWriteTime).TotalHours
Step 1 2 '载入候选池'
Head '[1/2] 候选池'
Prog 10 100 '载入候选池'
Show ("       A 组 Cloudflare  承载 $($cfAll.Count) 个  →  取 Top $($cfList.Count)") Gray
Show ("       B 组 CloudFront  承载 $($cfrAll.Count) 个  →  取 Top $($cfrList.Count)") Gray
Show ("       扫描数据: $(((Get-Item $script:FileScanCf).LastWriteTime).ToString('MM-dd HH:mm'))  （$age 小时前）") $(if ($age -gt 24) { 'Yellow' } else { 'DarkGray' })
if ($age -gt 24) { Warn '数据超过 24 小时，建议先重跑全量扫描' }

# ---- 扫描数据来源网络一致性检查（ISSUES D4）----
# full-scan.ps1 会写一份 full-scan-<组>-meta.json，记下当时那台机器 / 那个网络
# 的身份。如果本机 IP 和当时不一样（换了宽带、换了电脑、挂过代理），旧候选池
# 是按另一个网络的连通性挑出来的，直接拿来做延迟实测意义不大。
function Get-LocalIpv4 {
    # 取本机在用的 IPv4，取不到就返回空 —— 绝不能因为查 IP 失败就中断实测
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
               Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -ne '127.0.0.1' } |
               Select-Object -First 1).IPAddress
        if ($ip) { return $ip }
    } catch {}
    try {
        $a = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
             Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.IPAddressToString -ne '127.0.0.1' } |
             Select-Object -First 1
        if ($a) { return $a.IPAddressToString }
    } catch {}
    return ''
}

$scanMeta = $null
foreach ($mp in @((Join-Path $script:InstallDir 'full-scan-cloudflare-meta.json'),
                  (Join-Path $script:InstallDir 'full-scan-cloudfront-meta.json'))) {
    if (-not (Test-Path $mp)) { continue }
    try {
        $mObj = Get-Content $mp -Raw -EA Stop | ConvertFrom-Json
        if ($mObj -and $mObj.LocalIp) { $scanMeta = $mObj; break }
    } catch {}
}

if ($scanMeta) {
    $nowIp = Get-LocalIpv4
    if ($nowIp -and $scanMeta.LocalIp -and ($scanMeta.LocalIp -ne $nowIp)) {
        Warn "扫描数据来自另一个网络（当时 $($scanMeta.LocalIp)，现在 $nowIp），结果可能不准，建议重跑全量扫描"
    } else {
        Show "       扫描数据来源网络: $($scanMeta.LocalIp)（与本机一致）" DarkGray
    }
}

# ---- 组装配测列表 ----
$items = @()
foreach ($ip in $cfList)  { $items += "$ip|A" }
foreach ($ip in $cfrList) { $items += "$ip|B" }

Head "[2/2] 延迟实测    $($items.Count) 个 × $Rounds 轮（交替，${DelayMs}ms 间隔）"
Step 2 2 '延迟实测'
Prog 30 100 '开始多轮探测'
$acc = Measure-Latency -Items $items -Rounds $Rounds -DelayMs $DelayMs -Timeout $Timeout
Prog 85 100 '汇总统计'

# ---- 汇总落盘 ----
$rows = @()
foreach ($it in $items) {
    $p = $it.Split('|')
    $ip = $p[0]; $g = $p[1]
    $s = Stat-Latency $acc[$ip]
    $sp = 0
    if (Test-Path $script:FileSpeed) {
        $old = @(Import-Csv $script:FileSpeed | Where-Object { $_.IP -eq $ip })
        if ($old.Count -gt 0) { $sp = [int]$old[0].速度 }
    }
    $rows += [pscustomobject]@{
        组     = $g
        IP     = $ip
        中位   = $s.Med
        最小   = $s.Min
        最大   = $s.Max
        抖动   = $s.Jit
        成功   = $s.OK
        失败   = $s.Fail
        总轮次 = $Rounds
        成功率 = $s.Rate
        速度   = $sp
        得分   = [int]($s.Med + $s.Jit * 0.5 + $s.Fail * 150)
    }
}
$rows | Export-Csv -Path $script:FileLatency -NoTypeInformation -Encoding UTF8
Save-PoolState -Stage 'latency-done' -Cf $cfList.Count -Cfr $cfrList.Count

# ---- 打印结果 ----
function Print-Group {
    param($Group, $Title, $Desc, $Domains, [switch]$BySpeed)
    $r = @($rows | Where-Object { $_.组 -eq $Group })
    if ($BySpeed) { $r = @($r | Sort-Object @{e={$_.成功 -eq 0}}, @{e={$_.速度};Descending=$true}, 得分) }
    else          { $r = @($r | Sort-Object @{e={$_.成功 -eq 0}}, 得分) }
    Write-Host ''
    Show "  +--------------------------------------------------------------------------------------+" DarkCyan
    Show "  |  $Title" DarkCyan
    Show "  +--------------------------------------------------------------------------------------+" DarkCyan
    Show "     作用: $Desc" DarkGray
    Show '     覆盖域名:' DarkGray
    foreach ($d in $Domains) { Show ("       - {0,-24} {1}" -f $d.H, $d.D) DarkGray }
    Write-Host ''
    if ($BySpeed) {
        Show ("     {0,-5} {1,-16} {2,10} {3,11} {4,9} {5,7} {6,7} {7,7}  {8}" -f '编号','IP','下载速度','有效速度','中位延迟','抖动','成功','成功率','评价') Cyan
    } else {
        Show ("     {0,-5} {1,-16} {2,9} {3,7} {4,7} {5,7} {6,7} {7,7} {8,6}  {9}" -f '编号','IP','中位延迟','最小','最大','抖动','成功','成功率','得分','评价') Cyan
    }
    Show ('     ' + ('-' * 98)) DarkGray
    $i = 0
    foreach ($x in $r) {
        $i++
        $tag = ''
        if ($x.成功 -eq 0) { $tag = '不可用' }
        elseif ($i -eq 1) { $tag = '<== 最优' }
        elseif ($i -le 3) { $tag = '推荐' }
        elseif ($x.失败 -gt 0) { $tag = "有 $($x.失败) 次失败" }
        $c = 'Gray'
        if ($x.成功 -eq 0) { $c = 'DarkGray' }
        elseif ($i -eq 1) { $c = 'Green' } elseif ($i -le 3) { $c = 'Cyan' } elseif ($x.失败 -gt 0) { $c = 'Yellow' }
        if ($x.成功 -eq 0) {
            Show ("     {0,-5} {1,-16} {2,9} {3,7} {4,7} {5,7} {6,7} {7,7} {8,6}  {9}" -f `
                  $i, $x.IP, '全部失败', '-', '-', '-', "$($x.成功)/$($x.总轮次)", $x.成功率, '-', $tag) $c
        } elseif ($BySpeed) {
            $eff = [int]($x.速度 * $x.成功率 / 100)
            Show ("     {0,-5} {1,-16} {2,7} KB/s {3,8} KB/s {4,6}ms {5,5}ms {6,7} {7,6}%  {8}" -f `
                  $i, $x.IP, $x.速度, $eff, $x.中位, $x.抖动, "$($x.成功)/$($x.总轮次)", $x.成功率, $tag) $c
        } else {
            Show ("     {0,-5} {1,-16} {2,7}ms {3,5}ms {4,5}ms {5,5}ms {6,7} {7,6}% {8,7}  {9}" -f `
                  $i, $x.IP, $x.中位, $x.最小, $x.最大, $x.抖动, "$($x.成功)/$($x.总轮次)", $x.成功率, $x.得分, $tag) $c
        }
    }
}

# 是否有速度数据（决定 B 组用哪种排序/显示）
$hasSpeed = $false
if (Test-Path $script:FileSpeed) {
    $hasSpeed = @(Import-Csv $script:FileSpeed | Where-Object { [int]$_.速度 -gt 0 }).Count -gt 0
}

Print-Group -Group 'A' -Title 'A 组 - Cloudflare' `
    -Desc 'API 调用 / 网页访问      指标: 延迟越低越好' -Domains $script:CF_GROUP
if ($hasSpeed) {
    Print-Group -Group 'B' -Title 'B 组 - CloudFront' `
        -Desc '游戏资源 / 内容下载      指标: 下载速度越高越好' -Domains $script:CFR_GROUP -BySpeed
} else {
    Print-Group -Group 'B' -Title 'B 组 - CloudFront' `
        -Desc '游戏资源 / 内容下载      （还没测速，暂按延迟显示 —— 请跑【功能3】）' -Domains $script:CFR_GROUP
}

Write-Host ''
Rule '='
Prog 100 100 '完成'
Done 'ok' "结果已保存"
Ok "结果已保存 -> $script:FileLatency"
Show '  下一步: 【功能3】下载测速   powershell -ExecutionPolicy Bypass -File speedtest-batch.ps1' White
Show '     或直接: 【功能4】清单选用 powershell -ExecutionPolicy Bypass -File list-and-pick.ps1' White
Rule '='
Write-Host ''

exit 0
