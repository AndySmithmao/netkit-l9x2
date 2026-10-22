# ============================================================================
#  【GUI 专用】非交互式应用选中的 IP
#  被 VRChat优选工具.exe 的「清单选用」窗口调用
#
#  用法:
#     apply-selected.ps1 -IpA 1.2.3.4 -IpB 5.6.7.8 -Yes
#     apply-selected.ps1 -IpA 1.2.3.4            # 只改 A 组
#     apply-selected.ps1 -Verify                 # 只验证当前配置
# ============================================================================
param(
    [string]$IpA = '',
    [string]$IpB = '',
    [switch]$Yes,
    [switch]$Verify,
    [switch]$NoRollback
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib-common.ps1')

function Out { param($s, $c = 'Gray') Write-Host $s -ForegroundColor $c }

if (-not (Test-Admin)) {
    Out '需要管理员权限才能写 hosts' Red
    exit 1
}

$curA = Get-HostsIp 'api.vrchat.cloud'
$curB = Get-HostsIp 'files.vrchat.cloud'

if ($Verify) {
    $IpA = $curA; $IpB = $curB
    Out "验证当前配置:  A=$IpA   B=$IpB" Cyan
}

if (-not $IpA) { $IpA = $curA }
if (-not $IpB) { $IpB = $curB }

if (-not $IpA -and -not $IpB) { Out '没有任何 IP 可写，退出' Yellow; exit 1 }
if ($IpA -and $IpA -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Out "A 组 IP 格式不对: $IpA" Red; exit 1 }
if ($IpB -and $IpB -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { Out "B 组 IP 格式不对: $IpB" Red; exit 1 }

# ---- 备份 ----
$bak = Join-Path $script:InstallDir 'hosts.before-apply'
Copy-Item $script:HostsPath $bak -Force -ErrorAction SilentlyContinue

# ---- 写入 ----
Out ''
Out "写入 hosts:" Cyan
Out "  A 组（Cloudflare 8 个域名） -> $IpA"
Out "  B 组（CloudFront 4 个域名） -> $IpB"
Out ''
$lines = Build-HostsLines -IpA $IpA -IpB $IpB
if (-not (Write-HostsRobust -Lines $lines)) { Out '写入失败（文件被占用？）' Red; exit 1 }
& "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
Out '已写入并刷新 DNS' Green

# ---- 验证 ----
Out ''
Out '回归验证（各 2 次）...' DarkGray
Start-Sleep -Seconds 2
$bad = @()
$allH = @($script:CF_GROUP | ForEach-Object { $_.H }) +
        @($script:CFR_GROUP | ForEach-Object { $_.H }) +
        @('www.bing.com','www.baidu.com')
foreach ($h in $allH) {
    $ok = 0
    for ($i = 1; $i -le 2; $i++) {
        $c = (& "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $script:UA --max-time 15 -w '%{http_code}' "https://$h/" 2>&1 | Out-String).Trim()
        if ($c -match '^[1-5]\d\d$') { $ok++ }
    }
    if ($ok -eq 0) { $bad += $h }
    Out ("  {0} {1,-24} {2}/2" -f $(if ($ok -gt 0) { '[ok]' } else { '[x] ' }), $h, $ok) $(if ($ok -gt 0) { 'Gray' } else { 'Red' })
}

if ($bad.Count -gt 0 -and -not $NoRollback) {
    Out ''
    Out "$($bad.Count) 个失败，回滚" Yellow
    if (Test-Path $bak) { Copy-Item $bak $script:HostsPath -Force; & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null }
    Out '已回滚' Yellow
    exit 1
}

Out ''
Out '完成，全部通过' Green
exit 0
