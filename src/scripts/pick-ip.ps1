# ============================================================================
#  VRChat 优选 IP —— 实测 & 交互选用
#
#  流程:
#     [1/5] 载入候选（来自全量扫描；没有就先跑一次）
#     [2/5] 延迟实测（两组各 Top40，多轮交替，取中位 + 抖动）
#     [3/5] 下载速度实测（同样两组，真实文件下载）
#     [4/5] 排名并【在窗口内列出清单】（标注域名、用途、延迟、速度）
#     [5/5] 你输入编号选用 → 写 hosts → 回归验证
#
#  用法:
#     powershell -ExecutionPolicy Bypass -File pick-ip.ps1
#     powershell -ExecutionPolicy Bypass -File pick-ip.ps1 -Rounds 7 -TopN 40
#     powershell -ExecutionPolicy Bypass -File pick-ip.ps1 -Quick          # 快速版
# ============================================================================
param(
    [int]$TopN = 40,
    [int]$Rounds = 5,          # 延迟实测轮次
    [int]$SpeedRounds = 2,     # 下载测速轮次
    [int]$DelayMs = 200,       # 每次请求间隔（抗风控）
    [switch]$Quick
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
$RootDir = if ($env:VRCTOOL_ROOT) { $env:VRCTOOL_ROOT } else { Split-Path $PSScriptRoot -Parent }
$DataDir = if ($env:VRCTOOL_DATA) { $env:VRCTOOL_DATA } else { Join-Path $RootDir 'data' }
$HostsPath  = "$env:SystemRoot\System32\drivers\etc\hosts"

# 改 hosts 的唯一入口（原地写会把文件截成 0 字节，见 lib-hosts.ps1 顶部说明）
. (Join-Path $PSScriptRoot 'lib-hosts.ps1')

# ★ 必须自己也 dot-source lib-common ★
#   Progress / IpTick 在 lib-common.ps1 里。GUI 是**另起进程**跑这个脚本的，
#   新进程继承不到父进程的函数 —— 不自己加载就是 undefined。
#   放在自己的 Show / Head / Rule 定义之前，让本脚本的同名函数覆盖 lib-common 的。
. (Join-Path $PSScriptRoot 'lib-common.ps1')

if ($Quick) { $Rounds = 3; $SpeedRounds = 1; $DelayMs = 120 }
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }

# ---------------------------------------------------------------------------
# 域名分组（用于在窗口里标注清楚）
# ---------------------------------------------------------------------------
$CF_GROUP = @(
    @{ H='api.vrchat.cloud';           D='游戏主 API（登录 / 账号 / 房间）' }
    @{ H='pipeline.vrchat.cloud';      D='内容流水线' }
    @{ H='dev-api.vrchat.cloud';       D='开发 API' }
    @{ H='vrchat.com';                 D='官网' }
    @{ H='www.vrchat.com';             D='官网' }
    @{ H='mail.vrchat.com';            D='邮件服务' }
    @{ H='creators.vrchat.com';        D='创作者中心' }
    @{ H='docs.vrchat.com';            D='官方文档' }
)
$CFR_GROUP = @(
    @{ H='files.vrchat.cloud';         D='游戏内容 CDN（资源 / 模型下载）' }
    @{ H='vrcpm.vrchat.cloud';         D='包管理' }
    @{ H='assets.vrchat.com';          D='游戏资源 CDN（SDK / 更新）' }
    @{ H='status.vrchat.com';          D='服务状态页' }
)

function Show  { param($s, $c='Gray') Write-Host $s -ForegroundColor $c }
function Head  { param($s) Write-Host ''; Write-Host "  $s" -ForegroundColor Cyan }
function Rule  { param($ch='=') Write-Host ("  " + ($ch * 94)) -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# C# 内核：延迟探测 + 限速
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net.Security;
using System.Net.Sockets;
using System.Threading;

public class PickProbe {
    public string Ip; public int Tls = -1; public string Err = "";
    public static PickProbe One(string ip, string sni, int timeoutMs) {
        var r = new PickProbe { Ip = ip };
        var sw = Stopwatch.StartNew();
        try {
            using (var c = new TcpClient()) {
                var ar = c.BeginConnect(ip, 443, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs)) { r.Err = "超时"; return r; }
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

# ---------------------------------------------------------------------------
# 载入候选
# ---------------------------------------------------------------------------
Show ''
Rule '='
Show '  VRChat 优选 IP  ——  实测 & 选用' Cyan
Rule '='
Show ''

Head '[1/5] 载入候选'
$cfCsv  = Join-Path $InstallDir 'full-scan-cloudflare.csv'
$cfrCsv = Join-Path $InstallDir 'full-scan-cloudfront.csv'

if (-not (Test-Path $cfCsv) -or -not (Test-Path $cfrCsv)) {
    Show '       没有找到全量扫描结果。' Yellow
    Show ''
    Show '       需要先做一次全量扫描（约 24 分钟，限速 45/秒）。' White
    Show "       命令: powershell -ExecutionPolicy Bypass -File full-scan.ps1" DarkGray
    Show ''
    $ans = Read-Host '       现在就跑？（y = 是，其他 = 退出）'
    if ($ans -match '^[yY]') {
        $fs = Join-Path (Split-Path -Parent $PSCommandPath) 'full-scan.ps1'
        if (Test-Path $fs) { & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $fs }
        else { Show "       找不到 full-scan.ps1" Red; exit 1 }
    } else { exit 1 }
}

$cfAll  = @(Import-Csv $cfCsv  | Where-Object { $_.Ok -eq 'True' } | Sort-Object { [int]$_.Tls })
$cfrAll = @(Import-Csv $cfrCsv | Where-Object { $_.Ok -eq 'True' } | Sort-Object { [int]$_.Tls })
if ($cfAll.Count -eq 0 -or $cfrAll.Count -eq 0) { Show '       扫描结果为空，请重跑 full-scan.ps1' Red; exit 1 }

$cfList  = @($cfAll  | Select-Object -First $TopN | ForEach-Object { $_.Ip })
$cfrList = @($cfrAll | Select-Object -First $TopN | ForEach-Object { $_.Ip })

$scanTime = (Get-Item $cfCsv).LastWriteTime
$ageH = [int]((Get-Date) - $scanTime).TotalHours
Show ("       A组 Cloudflare  承载 $($cfAll.Count) 个 → 取 Top $($cfList.Count)") Gray
Show ("       B组 CloudFront  承载 $($cfrAll.Count) 个 → 取 Top $($cfrList.Count)") Gray
Show ("       扫描数据时间: $($scanTime.ToString('MM-dd HH:mm'))  （$ageH 小时前）") $(if ($ageH -gt 24) { 'Yellow' } else { 'DarkGray' })
if ($ageH -gt 24) { Show '       [!] 数据超过 24 小时，建议重跑 full-scan.ps1' Yellow }

# ---------------------------------------------------------------------------
# 延迟实测（两组交替，多轮）
# ---------------------------------------------------------------------------
Head "[2/5] 延迟实测    $($cfList.Count + $cfrList.Count) 个 IP × $Rounds 轮（交替，${DelayMs}ms 间隔）"

$all = @()
foreach ($ip in $cfList)  { $all += @{ Ip=$ip; Sni='api.vrchat.cloud';   G='A' } }
foreach ($ip in $cfrList) { $all += @{ Ip=$ip; Sni='files.vrchat.cloud'; G='B' } }

$lat = @{}
foreach ($it in $all) { $lat[$it.Ip] = New-Object System.Collections.ArrayList }

$swAll = [Diagnostics.Stopwatch]::StartNew()
for ($r = 1; $r -le $Rounds; $r++) {
    $k = 0
    foreach ($it in $all) {
        $k++
        $res = [PickProbe]::One($it.Ip, $it.Sni, 4000)
        [void]$lat[$it.Ip].Add($res)
        $vv = @($lat[$it.Ip] | Where-Object { $_.Tls -ge 0 } | ForEach-Object { $_.Tls } | Sort-Object)
        $med2 = if($vv.Count){ $vv[[int](($vv.Count-1)/2)] } else { -1 }
        $j2 = if($vv.Count){ $vv[-1] - $vv[0] } else { -1 }
        IpTick -G $it.组 -Ip $it.Ip -Lat $res.Tls -Ok $vv.Count -Tot $lat[$it.Ip].Count `
               -Med $med2 -Jit $j2 -Note "第 $r/$Rounds 轮"
        if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }
    $el = [int]$swAll.Elapsed.TotalSeconds
    $eta = [int]($el / $r * ($Rounds - $r))
    Progress "延迟轮次 $r/$Rounds   已用 ${el}s   剩余约 ${eta}s" -MinIntervalMs 0 -Force
}
Write-Host ''
Show "       完成，耗时 $([int]$swAll.Elapsed.TotalSeconds) 秒" Green

# ---------------------------------------------------------------------------
# 下载速度实测
# ---------------------------------------------------------------------------
Head "[3/5] 下载速度实测    $($all.Count) 个 × $SpeedRounds 轮（真实文件下载）"

# 两组的测速目标不同 —— 各自的 IP 只承载自己那组的 domain
#   A 组（Cloudflare）: docs.vrchat.com 的首页（约 190KB）
#   B 组（CloudFront）: assets 分布域上的 SDK 文件（约 6.3MB）
$SPEED_TARGET = @{
    A = @{ Sni='docs.vrchat.com';                  Path='/' }
    B = @{ Sni='d14hwloucscbyy.cloudfront.net';    Path='/sdk/VRCSDK2-2022.04.20.16.27_Public.unitypackage' }
}
$speed = @{}

function Measure-Speed {
    param([string]$Ip, [string]$Sni, [string]$Path, [int]$Limit)
    if (-not $Path) { $Path = '/' }
    $x = & "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time $Limit --resolve "${Sni}:443:$Ip" `
         -w '%{speed_download}|%{http_code}' "https://$Sni$Path" 2>$null | Out-String
    $m = [regex]::Match($x.Trim(), '^([\d.]+)\|(\d{3})$')
    if ($m.Success -and $m.Groups[2].Value -ne '000') { return [math]::Round([double]$m.Groups[1].Value / 1024) }
    return 0
}

$swSp = [Diagnostics.Stopwatch]::StartNew()
$done = 0
foreach ($it in $all) {
    $t = $SPEED_TARGET[$it.G]
    $v = New-Object System.Collections.ArrayList
    for ($r = 1; $r -le $SpeedRounds; $r++) {
        $k = Measure-Speed -Ip $it.Ip -Sni $t.Sni -Path $t.Path -Limit 8
        [void]$v.Add($k)
        if ($r -lt $SpeedRounds) { Start-Sleep -Milliseconds 300 }
    }
    $speed[$it.Ip] = $v
    $done++
    $el = [int]$swSp.Elapsed.TotalSeconds
    Progress "测速 $done/$($all.Count)   当前 $($it.Ip)   已用 ${el}s" -MinIntervalMs 0 -Force
    $vv2 = @($v | Where-Object { $_ -gt 0 } | Sort-Object)
    IpTick -G $it.组 -Ip $it.Ip -Lat $it.中位 -Ok $vv2.Count -Tot $SpeedRounds `
           -Med $(if($vv2.Count){$vv2[[int](($vv2.Count-1)/2)]}else{-1}) -Jit -1 `
           -Note "$(if($vv2.Count){"$($vv2[-1]) KB/s"}else{'失败'})"
    Start-Sleep -Milliseconds 150
}
Write-Host ''
Show "       完成，耗时 $([int]$swSp.Elapsed.TotalSeconds) 秒" Green
Show "       A 组测速基准: docs.vrchat.com 首页（约 190KB，偏小，仅供参考）" DarkGray
Show "       B 组测速基准: assets 分布域 SDK 文件（约 6.3MB，准确）" DarkGray

# ---------------------------------------------------------------------------
# 汇总排名
# ---------------------------------------------------------------------------
Head '[4/5] 排名（延迟取中位 + 抖动惩罚；速度取中位）'

function Stat-Lat {
    param([string]$Ip)
    $v = @($lat[$Ip] | Where-Object { $_.Tls -ge 0 } | ForEach-Object { $_.Tls } | Sort-Object)
    $fail = @($lat[$Ip] | Where-Object { $_.Tls -lt 0 }).Count
    if ($v.Count -eq 0) { return @{ Med=99999; Min=99999; Max=99999; Jit=99999; Fail=$fail; OK=0 } }
    $med = $v[[int](($v.Count - 1) / 2)]
    return @{ Med=$med; Min=$v[0]; Max=$v[-1]; Jit=($v[-1] - $v[0]); Fail=$fail; OK=$v.Count }
}
function Stat-Speed {
    param([string]$Ip)
    $v = @($speed[$Ip] | Where-Object { $_ -gt 0 } | Sort-Object)
    if ($v.Count -eq 0) { return 0 }
    return $v[[int](($v.Count - 1) / 2)]
}

$rowsA = @()
$cfList | ForEach-Object {
    $s = Stat-Lat $_
    $rate = if ($s.OK + $s.Fail -gt 0) { $s.OK / ($s.OK + $s.Fail) } else { 0 }
    $rowsA += [pscustomobject]@{
        IP=$_; 中位=$s.Med; 最小=$s.Min; 最大=$s.Max; 抖动=$s.Jit
        速度=(Stat-Speed $_); 失败=$s.Fail; OK=$s.OK; 总=$Rounds
        成功率=[int]($rate * 100)
        # A 组：延迟导向。得分 = 中位 + 抖动/2，再按失败次数惩罚
        得分=[int]($s.Med + $s.Jit * 0.5 + $s.Fail * 150)
    }
}
# A 组：全失败的沉底，其余按得分升序
$rowsA = @($rowsA | Sort-Object @{e={ $_.OK -eq 0 }; Descending=$false}, 得分)

$rowsB = @()
$cfrList | ForEach-Object {
    $s = Stat-Lat $_
    $sp = Stat-Speed $_
    $rate = if ($s.OK + $s.Fail -gt 0) { $s.OK / ($s.OK + $s.Fail) } else { 0 }
    $rowsB += [pscustomobject]@{
        IP=$_; 中位=$s.Med; 最小=$s.Min; 最大=$s.Max; 抖动=$s.Jit
        速度=$sp; 失败=$s.Fail; OK=$s.OK; 总=$Rounds
        成功率=[int]($rate * 100)
        # B 组：下载导向。有效速度 = 速度中位 × 成功率（兼顾快和稳）
        有效速度=[int]($sp * $rate)
        得分=[int]($s.Med + $s.Jit * 0.5)
    }
}
# B 组：全失败沉底，其余按有效速度降序，同分再看延迟得分
$rowsB = @($rowsB | Sort-Object @{e={ $_.OK -eq 0 }; Descending=$false},
                            @{e={ $_.有效速度 }; Descending=$true},
                            得分)

# 显示辅助：全失败的不要显示 99999
function Fmt-Lat { param($v, $ok)
    if ($ok -eq 0) { return '全部失败' }
    return "$($v)ms"
}

# ---------------------------------------------------------------------------
# 窗口内展示清单 + 交互选择
# ---------------------------------------------------------------------------
Write-Host ''
Rule '='
Show '  请从下面两个清单里各选一个（输入编号）' Yellow
Rule '='

# ---- A 组 ----
Write-Host ''
Show '  +------------------------------------------------------------------------------------------+' DarkCyan
Show '  |  A 组 - Cloudflare                                                                       |' DarkCyan
Show '  +------------------------------------------------------------------------------------------+' DarkCyan
Show '     作用: API 调用 / 网页访问      指标: 延迟越低越好（速度仅作参考）' DarkGray
Show '     覆盖域名:' DarkGray
foreach ($g in $CF_GROUP) { Show ("       - {0,-24} {1}" -f $g.H, $g.D) DarkGray }
Write-Host ''
Show ("     {0,-5} {1,-16} {2,9} {3,7} {4,7} {5,7} {6,11} {7,7} {8,8}  {9}" -f '编号','IP','中位延迟','最小','最大','抖动','下载速度','成功','得分','评价') Cyan
Show ("     " + ('-' * 100)) DarkGray
$i = 0
foreach ($r in $rowsA) {
    $i++
    $tag = ''
    if ($r.OK -eq 0) { $tag = '不可用' }
    elseif ($i -eq 1) { $tag = '<== 最优' }
    elseif ($i -le 3) { $tag = '推荐' }
    elseif ($r.失败 -gt 0) { $tag = "有 $($r.失败) 次失败" }
    $c = 'Gray'
    if ($r.OK -eq 0) { $c = 'DarkGray' }
    elseif ($i -eq 1) { $c = 'Green' } elseif ($i -le 3) { $c = 'Cyan' } elseif ($r.失败 -gt 0) { $c = 'Yellow' }
    if ($r.OK -eq 0) {
        Show ("     {0,-5} {1,-16} {2,9} {3,7} {4,7} {5,7} {6,11} {7,8} {8,8}  {9}" -f `
              $i, $r.IP, '全部失败', '-', '-', '-', "$($r.速度) KB/s", "$($r.OK)/$($r.总)", '-', $tag) $c
    } else {
        Show ("     {0,-5} {1,-16} {2,7}ms {3,5}ms {4,5}ms {5,5}ms {6,8} KB/s {7,7} {8,7}  {9}" -f `
              $i, $r.IP, $r.中位, $r.最小, $r.最大, $r.抖动, $r.速度, "$($r.OK)/$($r.总)", $r.得分, $tag) $c
    }
}

# ---- B 组 ----
Write-Host ''
Show '  +------------------------------------------------------------------------------------------+' DarkCyan
Show '  |  B 组 - CloudFront                                                                       |' DarkCyan
Show '  +------------------------------------------------------------------------------------------+' DarkCyan
Show '     作用: 游戏资源 / 内容下载      指标: 下载速度越高越好（延迟仅作参考）' DarkGray
Show '     覆盖域名:' DarkGray
foreach ($g in $CFR_GROUP) { Show ("       - {0,-24} {1}" -f $g.H, $g.D) DarkGray }
Write-Host ''
Show ("     {0,-5} {1,-16} {2,10} {3,11} {4,9} {5,8} {6,7} {7,7} {8,6}  {9}" -f '编号','IP','下载速度','有效速度','中位延迟','抖动','成功','成功率','得分','评价') Cyan
Show ("     " + ('-' * 100)) DarkGray
$i = 0
foreach ($r in $rowsB) {
    $i++
    $tag = ''
    if ($r.OK -eq 0) { $tag = '不可用' }
    elseif ($i -eq 1) { $tag = '<== 最优' }
    elseif ($i -le 3) { $tag = '推荐' }
    elseif ($r.失败 -gt 0) { $tag = "有 $($r.失败) 次失败" }
    $c = 'Gray'
    if ($r.OK -eq 0) { $c = 'DarkGray' }
    elseif ($i -eq 1) { $c = 'Green' } elseif ($i -le 3) { $c = 'Cyan' } elseif ($r.失败 -gt 0) { $c = 'Yellow' }
    if ($r.OK -eq 0) {
        Show ("     {0,-5} {1,-16} {2,10} {3,11} {4,9} {5,8} {6,7} {7,7} {8,6}  {9}" -f `
              $i, $r.IP, '全部失败', '-', '-', '-', "$($r.OK)/$($r.总)", "$($r.成功率)%", '-', $tag) $c
    } else {
        Show ("     {0,-5} {1,-16} {2,7} KB/s {3,8} KB/s {4,6}ms {5,5}ms {6,7} {7,6} {8,7}  {9}" -f `
              $i, $r.IP, $r.速度, $r.有效速度, $r.中位, $r.抖动, "$($r.OK)/$($r.总)", "$($r.成功率)%", $r.得分, $tag) $c
    }
}

# ---- 选择 ----
Write-Host ''
Rule '-'
Show '  输入说明:  直接回车 = 用该组最优    0 = 该组不改    其他 = 输入上表编号' DarkGray
Rule '-'
Write-Host ''

$pickA = $rowsA[0].IP
$pickB = $rowsB[0].IP

$inA = Read-Host "  A 组（Cloudflare）选择 [回车=1号 $($rowsA[0].IP)]"
if ($inA -eq '0') { $pickA = '' }
elseif ($inA -match '^\d+$') { $n = [int]$inA; if ($n -ge 1 -and $n -le $rowsA.Count) { $pickA = $rowsA[$n-1].IP } }

$inB = Read-Host "  B 组（CloudFront）选择 [回车=1号 $($rowsB[0].IP)]"
if ($inB -eq '0') { $pickB = '' }
elseif ($inB -match '^\d+$') { $n = [int]$inB; if ($n -ge 1 -and $n -le $rowsB.Count) { $pickB = $rowsB[$n-1].IP } }

Write-Host ''
Show "  A 组将使用: $(if($pickA){$pickA}else{'(不改)'})" Cyan
Show "  B 组将使用: $(if($pickB){$pickB}else{'(不改)'})" Cyan
Write-Host ''
$go = Read-Host '  确认写入 hosts？(y = 是，其他 = 取消)'
if ($go -notmatch '^[yY]') { Show '  已取消，未做任何修改。' Yellow; exit 0 }

# ---------------------------------------------------------------------------
# 写入
# ---------------------------------------------------------------------------
Head '[5/5] 写入 hosts 并验证'
if (Test-Path $HostsPath) { Copy-Item $HostsPath (Join-Path $InstallDir 'hosts.before-optimize') -Force }

$BEGIN = '# ===== VRChat-bypass BEGIN ====='
$END   = '# ===== VRChat-bypass END ====='

function Get-Cur { param([string]$H)
    # 允许行尾内联注释（域名不再必须是行尾）
    $re = '^\s*\d{1,3}(?:\.\d{1,3}){3}\s+' + [regex]::Escape($H) + '(?:\s|$)'
    $l = Get-Content $HostsPath | Where-Object { $_ -match $re } | Select-Object -First 1
    if ($l -and $l -match '^\s*(\d+\.\d+\.\d+\.\d+)') { return $matches[1] }
    return '' }

# 剥离旧块：走 lib-hosts 的统一实现（只删成对块；不配对/读失败就中止）
$strip = Remove-HostsBlock -Path $HostsPath -Begin $BEGIN -End $END
if ($strip.Error) { Bad "读取 hosts 失败，已中止: $($strip.Error)"; exit 1 }
if ($strip.Unpaired) {
    Bad 'hosts 里的标记行不成对，为避免误删已中止；请手工删掉单独出现的 BEGIN/END 行后重试'
    exit 1
}
$keep = New-Object System.Collections.Generic.List[string]
foreach ($l in $strip.Lines) { $keep.Add($l) }
$keep.Add(''); $keep.Add($BEGIN)
$keep.Add("# picked $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$oldA = Get-Cur 'api.vrchat.cloud'
$oldB = Get-Cur 'files.vrchat.cloud'
if (-not $pickA) { $pickA = $oldA }
if (-not $pickB) { $pickB = $oldB }
foreach ($g in $CF_GROUP)  { if ($pickA) { $keep.Add(('{0,-16} {1}' -f $pickA, $g.H)) } }
foreach ($g in $CFR_GROUP) { if ($pickB) { $keep.Add(('{0,-16} {1}' -f $pickB, $g.H)) } }
foreach ($h in 'help.vrchat.com','feedback.vrchat.com','hello.vrchat.com','ask.vrchat.com') {
    $ip = Get-Cur $h
    if ($ip) { $keep.Add(('{0,-16} {1}' -f $ip, $h)) }
}
$keep.Add($END)

$written = Write-HostsSafe -Path $HostsPath -Lines $keep -ExpectIp $cfNew -Retry 8
if (-not $written) {
    Show '  [x] 写入 hosts 失败（被拦截或文件被占用）。' Red
    Show '      已保持原样 —— 不会留下空文件。可关闭杀软实时防护后重试。' DarkGray
    exit 1
}
& "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
Show '  已写入并刷新 DNS' Green
Write-Host ''

# 回归
Show '  回归验证（各 2 次）...' DarkGray
$bad = @()
foreach ($h in (@($CF_GROUP | ForEach-Object { $_.H }) + @($CFR_GROUP | ForEach-Object { $_.H }) + @('www.bing.com','www.baidu.com'))) {
    $ok = 0
    for ($i = 1; $i -le 2; $i++) {
        $c = (& "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time 15 -w '%{http_code}' "https://$h/" 2>&1 | Out-String).Trim()
        if ($c -match '^[1-5]\d\d$') { $ok++ }
    }
    if ($ok -eq 0) { $bad += $h }
    Show ("    {0} {1,-24} {2}/2" -f $(if ($ok -gt 0) { '[ok]' } else { '[x] ' }), $h, $ok) $(if ($ok -gt 0) { 'Gray' } else { 'Red' })
}

if ($bad.Count -gt 0) {
    Write-Host ''
    Show "  [!] $($bad.Count) 个失败，回滚" Red
    Copy-Item (Join-Path $InstallDir 'hosts.before-optimize') $HostsPath -Force
    & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
    Show '  已回滚' Yellow
    exit 1
}

Write-Host ''
Rule '='
Show '  完成！' Green
Show "    A 组（8 个域名）  ->  $pickA" White
Show "    B 组（4 个域名）  ->  $pickB" White
Rule '='
Write-Host ''

exit 0
