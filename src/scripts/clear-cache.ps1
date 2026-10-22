# ============================================================================
#  【功能】清理缓存
#
#  分类说明:
#    Scan     扫描结果    full-scan-*.csv / *-top.txt        (~1.3 MB)
#    Latency  实测结果    latency-result / speed-result / pool-state
#    Reports  报告与清单  stability-report.csv / 候选*.txt
#    Logs     日志        install.log 等
#    Baks     hosts 备份  hosts.before-* ※ hosts.original 永不删
#    Temp     临时文件    %TEMP%\vrctool-*
#    Dns      刷新 DNS 缓存（ipconfig /flushdns）
#
#  用法:
#     clear-cache.ps1 -List          # 只看有什么，不删
#     clear-cache.ps1 -All           # 全清
#     clear-cache.ps1 -Scan -Latency # 只清指定的
#     clear-cache.ps1 -All -Yes      # 不问直接清（GUI 用）
# ============================================================================
param(
    [switch]$List,
    [switch]$All,
    [switch]$Scan,
    [switch]$Latency,
    [switch]$Reports,
    [switch]$Logs,
    [switch]$Baks,
    [switch]$Temp,
    [switch]$Dns,
    [switch]$Yes
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib-common.ps1')

function Out { param($s, $c = 'Gray') Write-Host $s -ForegroundColor $c }
function KB  { param($b) if ($b -ge 1MB) { "{0:N2} MB" -f ($b/1MB) } else { "{0:N1} KB" -f ($b/1KB) } }

if ($All) { $Scan = $Latency = $Reports = $Logs = $Baks = $Temp = $Dns = $true }
$any = $Scan -or $Latency -or $Reports -or $Logs -or $Baks -or $Temp -or $Dns
if (-not $any) { $List = $true }

$D = $script:InstallDir        # 数据目录
$T = $env:TEMP

# ---------------------------------------------------------------- 分类定义
# 每项: @{ Key; Name; Desc; Paths; Pattern; Protect }
$cats = @(
    @{
        Key = 'Scan'; Name = '扫描结果'; Desc = '全量扫描的候选池（清掉后下次会重扫）'
        Dir = $D
        Pat = @('full-scan-*.csv','full-scan-*-top.txt','full-scan-*-partial.csv')
    }
    @{
        Key = 'Latency'; Name = '实测结果'; Desc = '延迟 / 测速结果（清掉后需重跑实测和测速）'
        Dir = $D
        Pat = @('latency-result.csv','speed-result.csv','pool-state.json',
                'speedtest-result.csv','speedtest-best.txt')
    }
    @{
        Key = 'Reports'; Name = '报告与清单'; Desc = '稳定性报告与候选清单文本'
        Dir = $D
        Pat = @('stability-report.csv','候选*.txt','候选清单.txt')
    }
    @{
        Key = 'Logs'; Name = '日志'; Desc = '安装 / 运行日志'
        Dir = $D
        Pat = @('*.log')
    }
    @{
        Key = 'Baks'; Name = 'hosts 备份'; Desc = '优选前自动备份的 hosts（hosts.original 永不删）'
        Dir = $D
        Pat = @('hosts.before-*','hosts.old*')
    }
    @{
        Key = 'Temp'; Name = '临时文件'; Desc = 'GUI 运行时的临时脚本与诊断文件'
        Dir = $T
        Pat = @('vrctool-*.ps1','vrctool-*.txt','vrctool-diag.txt')
    }
)

# ---------------------------------------------------------------- 收集
$plan = @()
foreach ($c in $cats) {
    $files = @()
    foreach ($p in $c.Pat) {
        $files += @(Get-ChildItem -Path $c.Dir -Filter $p -File -ErrorAction SilentlyContinue)
    }
    $files = @($files | Sort-Object FullName -Unique)
    $bytes = 0; foreach ($f in $files) { $bytes += $f.Length }
    $plan += [pscustomobject]@{
        Key = $c.Key; Name = $c.Name; Desc = $c.Desc
        Files = $files; Count = $files.Count; Bytes = $bytes
        Enabled = [bool](Get-Variable -Name $c.Key -ValueOnly -EA SilentlyContinue)
    }
}

# 受保护的文件（永远列出但不删）
$protected = @(
    'hosts.original','winws.exe','WinDivert.dll','WinDivert64.sys','cygwin1.dll'
)

# ---------------------------------------------------------------- 列出
Out ''
Rule '='
Out '  缓存清单' Cyan
Rule '='
Write-Host ''
Out ("  {0,-4} {1,-12} {2,-8} {3,-6} {4}" -f '选中','分类','大小','文件数','说明') DarkGray
Out ('  ' + ('-' * 92)) DarkGray
foreach ($p in $plan) {
    $mk = if ($p.Enabled) { '[x]' } else { '[ ]' }
    $cl = if ($p.Enabled) { 'White' } else { 'DarkGray' }
    Out ("  {0,-4} {1,-12} {2,-8} {3,-6} {4}" -f $mk, $p.Name, $(if ($p.Count) { KB $p.Bytes } else { '-' }), $p.Count, $p.Desc) $cl
}
$mk = if ($Dns) { '[x]' } else { '[ ]' }
Out ("  {0,-4} {1,-12} {2,-8} {3,-6} {4}" -f $mk, 'DNS 缓存', '-', '-', 'ipconfig /flushdns')
Write-Host ''
$totBytes = 0; foreach ($p in $plan) { $totBytes += $p.Bytes }
$totCount = 0; foreach ($p in $plan) { $totCount += $p.Count }
Out "  合计: $totCount 个文件，$(KB $totBytes)" DarkGray
Write-Host ''
Out '  ※ 以下文件受保护，永不清理:' DarkGray
foreach ($f in $protected) {
    $q = Join-Path $D $f
    if (Test-Path $q) { Out ("      {0,-22} {1}" -f $f, (KB (Get-Item $q).Length)) DarkGray }
}
Write-Host ''
Rule '='

if ($List) {
    Out ''
    Out '  （-List 模式，未做任何删除）' Yellow
    Out ''
    exit 0
}

if ($totCount -eq 0 -and -not $Dns) { Out ''; Out '  没有可清理的内容' Green; Out ''; exit 0 }

# ---------------------------------------------------------------- 确认
if (-not $Yes) {
    Write-Host ''
    $a = Read-Host '  确认清理？(y = 是，其他 = 取消)'
    if ($a -notmatch '^[yY]') { Out '  已取消'; exit 0 }
}

# ---------------------------------------------------------------- 执行
Write-Host ''
Out '  清理中...' Cyan
Write-Host ''
$del = 0; $freed = 0; $fail = 0
foreach ($p in $plan) {
    if (-not $p.Enabled) { continue }
    if ($p.Count -eq 0) { Out ("      {0,-12} 无内容" -f $p.Name) DarkGray; continue }
    $okN = 0; $okB = 0
    foreach ($f in $p.Files) {
        try {
            $sz = $f.Length
            Remove-Item $f.FullName -Force -ErrorAction Stop
            $okN++; $okB += $sz
        } catch { $fail++; Out ("      无法删除 {0}: {1}" -f $f.Name, $_.Exception.Message.Split([char]10)[0]) Red }
    }
    $del += $okN; $freed += $okB
    Out ("      {0,-12} 删除 {1} 个文件，释放 {2}" -f $p.Name, $okN, (KB $okB)) Green
    Prog $del $totCount "清理 $($p.Name)"
}

if ($Dns) {
    try { & "$env:SystemRoot\System32\ipconfig.exe" /flushdns 2>&1 | Out-Null; Out '      DNS 缓存      已刷新' Green }
    catch { Out '      DNS 缓存      刷新失败' Yellow }
}

# 顺手清掉脚本自己产生的临时壳
if ($Temp) {
    Get-ChildItem "$T\vrctool-*" -File -EA SilentlyContinue | ForEach-Object {
        try { Remove-Item $_.FullName -Force -EA Stop } catch {}
    }
}

Write-Host ''
Prog 100 100 '清理完成'
Done $(if($fail){'fail'}else{'ok'}) "删除 $del 个文件，释放 $(KB $freed)"
Rule '='
Out "  完成：删除 $del 个文件，释放 $(KB $freed)$(if($fail){"，$fail 个失败"})" Cyan
Write-Host ''
if ($Scan -or $Latency) {
    Out '  注意：扫描/实测缓存已清除，下次跑「一键完成」会重新测。' DarkGray
}
Out '        当前 hosts 配置和服务完全不受影响。' DarkGray
Rule '='
Write-Host ''
exit 0
