# 干净 A/B：关掉 bypass 服务测一遍，开着再测一遍，逐站点对比
# 这是唯一能排除"我的工具是否影响这些站点"的方法
$ErrorActionPreference = 'Continue'
$svcName = 'VRChatBypass'
$RootDir = if ($env:VRCTOOL_ROOT) { $env:VRCTOOL_ROOT } else { Split-Path $PSScriptRoot -Parent }
$DataDir = if ($env:VRCTOOL_DATA) { $env:VRCTOOL_DATA } else { Join-Path $RootDir 'data' }
$log = Join-Path $DataDir 'ab-test.log'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[!] 需要管理员权限'; exit 1
}
'' | Set-Content -Path $log -Encoding UTF8
function L($s) { Write-Host $s; Add-Content -Path $log -Value $s -Encoding UTF8 -ErrorAction SilentlyContinue }

$sites = @(
    @{ n='google';          h='www.google.com';        grp='争议' },
    @{ n='github';          h='github.com';            grp='争议' },
    @{ n='stackoverflow';   h='stackoverflow.com';     grp='争议' },
    @{ n='wikipedia';       h='www.wikipedia.org';     grp='争议' },
    @{ n='steamcommunity';  h='steamcommunity.com';    grp='争议' },
    @{ n='bing';            h='www.bing.com';          grp='正常' },
    @{ n='outlook';         h='outlook.com';           grp='正常' },
    @{ n='百度';            h='www.baidu.com';         grp='正常' },
    @{ n='淘宝';            h='www.taobao.com';        grp='正常' },
    @{ n='vrchat.com';      h='vrchat.com';            grp='VRChat' },
    @{ n='docs.vrchat.com'; h='docs.vrchat.com';       grp='VRChat' },
    @{ n='assets.vrchat.com';h='assets.vrchat.com';    grp='VRChat' },
    @{ n='creators.vrchat'; h='creators.vrchat.com';   grp='VRChat' },
    @{ n='api.vrchat.cloud';h='api.vrchat.cloud';      grp='VRChat' }
)

function Run-Round {
    param([string]$Tag)
    $out = @{}
    foreach ($s in $sites) {
        $ok = 0; $detail = ''
        for ($i = 1; $i -le 3; $i++) {
            $raw = & "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time 10 -w '%{http_code}|%{remote_ip}' "https://$($s.h)/" 2>&1 | Out-String
            $m = [regex]::Match($raw.Trim(), '^(\d{3})\|([^|]+)$')
            if ($m.Success -and $m.Groups[1].Value -ne '000') { $ok++; $detail = "HTTP $($m.Groups[1].Value) @ $($m.Groups[2].Value)" }
            elseif ($raw -match 'Connection was reset') { $detail = 'RST' }
            elseif ($raw -match 'timed out') { $detail = 'TCP超时' }
        }
        if ($ok -gt 0 -and $detail -eq '') { $detail = 'HTTP ok' }
        $out[$s.h] = @{ ok = $ok; detail = $detail }
    }
    L ""
    L "---- [$Tag] ----"
    foreach ($s in $sites) {
        $r = $out[$s.h]
        $mark = if ($r.ok -eq 3) { '[ok]' } elseif ($r.ok -eq 0) { '[x] ' } else { '[~] ' }
        L ("  {0} {1,-20} {2}/3   {3}" -f $mark, $s.n, $r.ok, $r.detail)
    }
    return $out
}

L '=== 干净 A/B 测试：bypass 服务 关 vs 开 ==='
L ("时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
L ''

# ---------- 阶段1: 服务运行中 ----------
L '>>> 阶段 1/3：bypass 服务【运行中】'
$a = Run-Round -Tag 'ON (服务运行)'

# ---------- 阶段2: 停服务 ----------
L ''
L '>>> 阶段 2/3：停止 bypass 服务'
& "$env:SystemRoot\System32\sc.exe" stop $svcName 2>&1 | Out-Null
Start-Sleep -Milliseconds 2000
Get-Process winws,winws2 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 1500
$st = & "$env:SystemRoot\System32\sc.exe" query $svcName 2>&1 | Out-String
if ($st -match 'STOPPED') { L '  服务已停止' } else { L '  [!] 服务状态未知'; L $st }
$b = Run-Round -Tag 'OFF (服务已停)'

# ---------- 阶段3: 重启服务 ----------
L ''
L '>>> 阶段 3/3：重启 bypass 服务'
& "$env:SystemRoot\System32\sc.exe" start $svcName 2>&1 | Out-Null
Start-Sleep -Milliseconds 3500
$st2 = & "$env:SystemRoot\System32\sc.exe" query $svcName 2>&1 | Out-String
if ($st2 -match 'RUNNING') { L '  服务已恢复' } else { L '  [!] 服务未恢复！'; L $st2 }
$c = Run-Round -Tag 'ON (服务恢复)'

# ---------- 汇总对比 ----------
L ''
L '================ 汇总对比 ================'
L ("  {0,-22} {1,-8} {2,-10} {3,-10} {4}" -f '站点', '分组', 'ON(1)', 'OFF', 'ON(2/恢复)')
$diffCount = 0
foreach ($s in $sites) {
    $x = $a[$s.h].ok; $y = $b[$s.h].ok; $z = $c[$s.h].ok
    $flag = ''
    if ($y -gt $x -or $y -gt $z) { $flag = '  <<< 关掉服务后变好 => 是我的工具影响'; $diffCount++ }
    L ("  {0,-22} {1,-8} {2,-10} {3,-10} {4}{5}" -f $s.n, $s.grp, "$x/3", "$y/3", "$z/3", $flag)
}
L ''
if ($diffCount -eq 0) {
    L '结论：没有任何站点在"关掉服务"后变好 => 那些失败与被安装的 bypass 无关，是网络/GFW 本身的问题'
} else {
    L "结论：有 $diffCount 个站点在关掉服务后变好 => 需要为它们加 exclude"
}

exit 0
