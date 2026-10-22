# ============================================================================
#  【功能4】清单选用
#  把实测结果整理成清单显示在窗口里，你选一个 → 写 hosts → 验证
#
#  输入: latency-result.csv（必须）+ speed-result.csv（可选，有则显示速度）
#  用法:
#     powershell -ExecutionPolicy Bypass -File list-and-pick.ps1
#     powershell -ExecutionPolicy Bypass -File list-and-pick.ps1 -Apply      # 免二次确认
#     powershell -ExecutionPolicy Bypass -File list-and-pick.ps1 -NoApply   # 只看不改
# ============================================================================
param(
    [switch]$Apply,
    [switch]$NoApply
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib-common.ps1')

Show ''
Rule '='
Show '  【功能4】清单选用' Cyan
Rule '='
Show ''

if (-not (Test-Path $script:FileLatency)) {
    Bad '没有找到 latency-result.csv'
    Show ''
    Show '  请先运行【功能2】延迟实测:  powershell -ExecutionPolicy Bypass -File latency-test.ps1' White
    Show ''
    exit 1
}

$lat = @(Import-Csv $script:FileLatency)
$spd = @()
if (Test-Path $script:FileSpeed) { $spd = @(Import-Csv $script:FileSpeed) }

# ---- 合并 ----
$rows = @()
foreach ($l in $lat) {
    $s = @($spd | Where-Object { $_.IP -eq $l.IP })
    $speed = 0
    if ($s.Count -gt 0) { $speed = [int]$s[0].速度 }
    $rows += [pscustomobject]@{
        组     = $l.组
        IP     = $l.IP
        中位   = [int]$l.中位
        最小   = [int]$l.最小
        最大   = [int]$l.最大
        抖动   = [int]$l.抖动
        成功   = [int]$l.成功
        总轮次 = [int]$l.总轮次
        成功率 = [int]$l.成功率
        速度   = $speed
        有效速度 = [int]($speed * [int]$l.成功率 / 100)
        得分   = [int]$l.得分
    }
}

$rowsA = @($rows | Where-Object { $_.组 -eq 'A' } |
    Sort-Object @{e={$_.成功 -eq 0}}, 得分)
$hasSpeedB = @($rows | Where-Object { $_.组 -eq 'B' -and $_.速度 -gt 0 }).Count -gt 0
if ($hasSpeedB) {
    $rowsB = @($rows | Where-Object { $_.组 -eq 'B' } |
        Sort-Object @{e={$_.成功 -eq 0}}, @{e={$_.有效速度};Descending=$true}, 得分)
} else {
    $rowsB = @($rows | Where-Object { $_.组 -eq 'B' } |
        Sort-Object @{e={$_.成功 -eq 0}}, 得分)
}

Write-Host ''
Rule '='
Show '  请从下面两个清单里各选一个（输入编号）' Yellow
Rule '='

# ---------- A 组 ----------
Write-Host ''
Show '  +------------------------------------------------------------------------------------------+' DarkCyan
Show '  |  A 组 - Cloudflare                                                                       |' DarkCyan
Show '  +------------------------------------------------------------------------------------------+' DarkCyan
Show '     作用: API 调用 / 网页访问          指标: 延迟越低越好（速度仅作参考）' DarkGray
Show '     覆盖域名:' DarkGray
foreach ($d in $script:CF_GROUP) { Show ("       - {0,-24} {1}" -f $d.H, $d.D) DarkGray }
Write-Host ''
Show ("     {0,-5} {1,-16} {2,9} {3,7} {4,7} {5,7} {6,7} {7,7} {8,8}  {9}" -f '编号','IP','中位延迟','最小','最大','抖动','成功','成功率','得分','评价') Cyan
Show ('     ' + ('-' * 100)) DarkGray
$i = 0
foreach ($x in $rowsA) {
    $i++
    $tag = ''
    if ($x.成功 -eq 0) { $tag = '不可用' }
    elseif ($i -eq 1) { $tag = '<== 最优' }
    elseif ($i -le 3) { $tag = '推荐' }
    elseif ($x.成功率 -lt 100) { $tag = "成功率 $($x.成功率)%" }
    $c = 'Gray'
    if ($x.成功 -eq 0) { $c = 'DarkGray' }
    elseif ($i -eq 1) { $c = 'Green' } elseif ($i -le 3) { $c = 'Cyan' } elseif ($x.成功率 -lt 100) { $c = 'Yellow' }
    if ($x.成功 -eq 0) {
        Show ("     {0,-5} {1,-16} {2,9} {3,7} {4,7} {5,7} {6,7} {7,7} {8,8}  {9}" -f `
              $i, $x.IP, '全部失败', '-', '-', '-', "$($x.成功)/$($x.总轮次)", $x.成功率, '-', $tag) $c
    } else {
        Show ("     {0,-5} {1,-16} {2,7}ms {3,5}ms {4,5}ms {5,5}ms {6,7} {7,6}% {8,7}  {9}" -f `
              $i, $x.IP, $x.中位, $x.最小, $x.最大, $x.抖动, "$($x.成功)/$($x.总轮次)", $x.成功率, $x.得分, $tag) $c
    }
}

# ---------- B 组 ----------
Write-Host ''
Show '  +------------------------------------------------------------------------------------------+' DarkCyan
Show '  |  B 组 - CloudFront                                                                       |' DarkCyan
Show '  +------------------------------------------------------------------------------------------+' DarkCyan
Show '     作用: 游戏资源 / 内容下载          指标: 下载速度越高越好（延迟仅作参考）' DarkGray
Show '     覆盖域名:' DarkGray
foreach ($d in $script:CFR_GROUP) { Show ("       - {0,-24} {1}" -f $d.H, $d.D) DarkGray }
Write-Host ''
if ($hasSpeedB) {
    Show ("     {0,-5} {1,-16} {2,10} {3,11} {4,9} {5,7} {6,7} {7,8}  {8}" -f '编号','IP','下载速度','有效速度','中位延迟','抖动','成功','成功率','评价') Cyan
} else {
    Show ("     {0,-5} {1,-16} {2,9} {3,7} {4,7} {5,7} {6,7} {7,8}  {8}" -f '编号','IP','中位延迟','最小','最大','抖动','成功','成功率','评价') Cyan
}
Show ('     ' + ('-' * 100)) DarkGray
$i = 0
foreach ($x in $rowsB) {
    $i++
    $tag = ''
    if ($x.成功 -eq 0) { $tag = '不可用' }
    elseif ($i -eq 1) { $tag = '<== 最优' }
    elseif ($i -le 3) { $tag = '推荐' }
    elseif ($x.成功率 -lt 100) { $tag = "成功率 $($x.成功率)%" }
    $c = 'Gray'
    if ($x.成功 -eq 0) { $c = 'DarkGray' }
    elseif ($i -eq 1) { $c = 'Green' } elseif ($i -le 3) { $c = 'Cyan' } elseif ($x.成功率 -lt 100) { $c = 'Yellow' }
    if ($x.成功 -eq 0) {
        Show ("     {0,-5} {1,-16} {2,10} {3,11} {4,9} {5,7} {6,7} {7,8}  {8}" -f `
              $i, $x.IP, '全部失败', '-', '-', '-', "$($x.成功)/$($x.总轮次)", $x.成功率, $tag) $c
    } elseif ($hasSpeedB) {
        Show ("     {0,-5} {1,-16} {2,7} KB/s {3,8} KB/s {4,6}ms {5,5}ms {6,7} {7,7}%  {8}" -f `
              $i, $x.IP, $x.速度, $x.有效速度, $x.中位, $x.抖动, "$($x.成功)/$($x.总轮次)", $x.成功率, $tag) $c
    } else {
        Show ("     {0,-5} {1,-16} {2,7}ms {3,5}ms {4,5}ms {5,5}ms {6,7} {7,7}%  {8}" -f `
              $i, $x.IP, $x.中位, $x.最小, $x.最大, $x.抖动, "$($x.成功)/$($x.总轮次)", $x.成功率, $tag) $c
    }
}

# ---------- 当前状态 ----------
Write-Host ''
$curA = Get-HostsIp 'api.vrchat.cloud'
$curB = Get-HostsIp 'files.vrchat.cloud'
Show "  当前 hosts:  A 组 = $(if($curA){$curA}else{'(无)'})     B 组 = $(if($curB){$curB}else{'(无)'})" DarkGray
$mulA = @(Get-HostsBlock 'api.vrchat.cloud').Count
$mulB = @(Get-HostsBlock 'files.vrchat.cloud').Count
if ($mulA -gt 1 -or $mulB -gt 1) { Warn "检测到 hosts 里有多条同名记录（A:$mulA B:$mulB），写入时会合并为一条" }

if ($NoApply) {
    Write-Host ''
    Warn '（-NoApply）只查看，不改 hosts'
    exit 0
}

# ---------- 选择 ----------
Write-Host ''
Rule '-'
Show '  输入说明:  直接回车 = 用该组最优    0 = 该组不改    其他 = 输入上表编号' DarkGray
Rule '-'
Write-Host ''

$pickA = $rowsA[0].IP
$pickB = $rowsB[0].IP

$inA = Read-Host "  A 组（Cloudflare）选择 [回车=1号 $($rowsA[0].IP)，0=不改]"
if ($inA -eq '0') { $pickA = '' }
elseif ($inA -match '^\d+$') { $n = [int]$inA; if ($n -ge 1 -and $n -le $rowsA.Count) { $pickA = $rowsA[$n-1].IP } }

$inB = Read-Host "  B 组（CloudFront）选择 [回车=1号 $($rowsB[0].IP)，0=不改]"
if ($inB -eq '0') { $pickB = '' }
elseif ($inB -match '^\d+$') { $n = [int]$inB; if ($n -ge 1 -and $n -le $rowsB.Count) { $pickB = $rowsB[$n-1].IP } }

Write-Host ''
Show "  A 组将使用: $(if($pickA){$pickA}else{'(不改)'})" Cyan
Show "  B 组将使用: $(if($pickB){$pickB}else{'(不改)'})" Cyan
Write-Host ''
if (-not $Apply) {
    $go = Read-Host '  确认写入 hosts？(y = 是，其他 = 取消)'
    if ($go -notmatch '^[yY]') { Warn '已取消，未做任何修改。'; exit 0 }
}

# ---------- 写入 ----------
Show ''
Head '写入 hosts'
if (-not (Test-Admin)) {
    Bad '需要管理员权限才能写 hosts'
    Show ''
    Show '  请用管理员 PowerShell 运行本脚本，或用「5-实测并选用IP.cmd」' Yellow
    exit 1
}
Copy-Item $script:HostsPath (Join-Path $script:InstallDir 'hosts.before-pick') -Force -EA SilentlyContinue
if (-not $pickA) { $pickA = $curA }
if (-not $pickB) { $pickB = $curB }
if (-not $pickA -and -not $pickB) { Warn '两组都没选，无需修改'; exit 0 }

$lines = Build-HostsLines -IpA $pickA -IpB $pickB
if (-not (Write-HostsRobust -Lines $lines)) { Bad '写入失败（文件可能被杀软占用）'; exit 1 }
& "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
Ok '已写入并刷新 DNS'

# ---------- 验证 ----------
Show ''
Head '回归验证'
$bad = @()
$allH = @($script:CF_GROUP | ForEach-Object { $_.H }) + @($script:CFR_GROUP | ForEach-Object { $_.H }) + @('www.bing.com','www.baidu.com')
foreach ($h in $allH) {
    $ok = 0
    for ($i = 1; $i -le 2; $i++) {
        $c = (& "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $script:UA --max-time 15 -w '%{http_code}' "https://$h/" 2>&1 | Out-String).Trim()
        if ($c -match '^[1-5]\d\d$') { $ok++ }
    }
    if ($ok -eq 0) { $bad += $h }
    Show ("    {0} {1,-24} {2}/2" -f $(if ($ok -gt 0) { '[ok]' } else { '[x] ' }), $h, $ok) $(if ($ok -gt 0) { 'Gray' } else { 'Red' })
}

Write-Host ''
if ($bad.Count -gt 0) {
    Warn "$($bad.Count) 个失败，回滚"
    $bak = Join-Path $script:InstallDir 'hosts.before-pick'
    if (Test-Path $bak) { Copy-Item $bak $script:HostsPath -Force; & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null }
    Bad '已回滚'
    exit 1
}

Rule '='
Show '  完成！' Green
Show "    A 组（8 个域名）  ->  $pickA" White
Show "    B 组（4 个域名）  ->  $pickB" White
Rule '='
Write-Host ''

exit 0
