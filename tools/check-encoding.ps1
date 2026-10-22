# =============================================================================
#  check-encoding.ps1 —— UTF-8 BOM 断言
#
#  判定规则（不是「所有文件都必须带 BOM」）：
#    文件里只要含非 ASCII 字节（中文、全角标点……），就必须带 UTF-8 BOM；
#    纯 ASCII 文件带不带都行，不算错。
#
#  为什么要有这条：
#    Windows PowerShell 5.1 遇到没有 BOM 的 .ps1，会按系统 ANSI(GBK) 解码。
#    中文一旦落进这个坑不是「乱码」那么温柔，而是直接语法报错、脚本根本起不来。
#    .cs / .xaml 同理：无 BOM 的中文在部分工具链下会被按 GBK 处理。
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\check-encoding.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\check-encoding.ps1 -Root D:\repo
#
#  退出码：全部合规 0；有 FAIL 1；根目录不存在 1。
# =============================================================================
[CmdletBinding()]
param(
    # 扫描根目录；不传就取脚本的上一级（本脚本位于 <Root>\tools\）
    [string]$Root
)

# ⚠️ 不能在 param() 的默认值里写 (Split-Path $PSScriptRoot -Parent)：
#    Windows PowerShell 5.1 用 -File 启动时，那个位置 $PSScriptRoot 还是空的，
#    会直接抛「Cannot bind argument to parameter 'Path' because it is an empty string」。
#    所以老老实实在脚本体里推导。
if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $PSScriptRoot }

# 应当受检查的清单（按布局自动拼，不再写死 wpf\ / dist\）
#   老布局：<root>\wpf + <root>\dist\scripts
#   交付包：<root>\src\app + <root>\src\scripts
$WpfDir = Join-Path $Root 'wpf'
if (-not (Test-Path -LiteralPath $WpfDir)) { $WpfDir = Join-Path $Root 'src\app' }
$SetupDir = Join-Path $WpfDir 'setup'
if (-not (Test-Path -LiteralPath $SetupDir)) { $SetupDir = Join-Path $Root 'src\setup' }

$Targets = @(
    (Join-Path $WpfDir '*.cs'),
    (Join-Path $WpfDir '*.xaml'),
    (Join-Path $WpfDir '*.csproj'),
    (Join-Path $WpfDir 'Scripts\*.ps1'),
    (Join-Path $SetupDir '*.ps1'),
    (Join-Path $SetupDir '.inject\*.cs'),
    (Join-Path $Root 'dist\scripts\*.ps1'),
    (Join-Path $Root 'src\scripts\*.ps1'),
    (Join-Path $PSScriptRoot '*.ps1')
)
Write-Host "主程序目录: $WpfDir"

if (-not (Test-Path -LiteralPath $Root)) {
    Write-Host "根目录不存在: $Root" -ForegroundColor Red
    exit 1
}
$Root = (Resolve-Path -LiteralPath $Root).Path

Write-Host ''
Write-Host '===== UTF-8 BOM 检查 =====' -ForegroundColor Cyan
Write-Host "根目录: $Root"

$total    = 0
$okCount  = 0
$failCount = 0
$failList = @()

foreach ($pat in $Targets) {
    $files = @(Get-ChildItem -Path $pat -File -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '\\\\(bin|obj|publish|\.dist)\\\\' } |
               Sort-Object FullName)
    if ($files.Count -eq 0) {
        Write-Host ('  --    {0}  (路径不存在或无匹配文件)' -f $pat) -ForegroundColor DarkGray
        continue
    }

    foreach ($f in $files) {
        $total++
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\')

        try {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
        }
        catch {
            $failCount++
            $failList += ('{0}    读取失败: {1}' -f $rel, $_.Exception.Message)
            Write-Host ('  FAIL  {0}    读取失败: {1}' -f $rel, $_.Exception.Message) -ForegroundColor Red
            continue
        }

        $hasBom = ($bytes.Length -ge 3 -and
                   $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        # UTF-16/UTF-32 的 BOM 也算「不是 UTF-8 with BOM」，单独点出来，免得看着像已带 BOM
        $isUtf16 = ($bytes.Length -ge 2 -and
                    (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or
                     ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)))

        $nonAscii = $false
        foreach ($b in $bytes) {
            if ($b -ge 0x80) { $nonAscii = $true; break }
        }

        if ($isUtf16) {
            $failCount++
            $failList += ('{0}    编码是 UTF-16，需要改存成 UTF-8 with BOM' -f $rel)
            Write-Host ('  FAIL  {0}    编码是 UTF-16，需要改存成 UTF-8 with BOM' -f $rel) -ForegroundColor Red
        }
        elseif ($nonAscii -and -not $hasBom) {
            $failCount++
            $failList += ('{0}    含非 ASCII 但缺 UTF-8 BOM' -f $rel)
            Write-Host ('  FAIL  {0}    含非 ASCII 但缺 UTF-8 BOM' -f $rel) -ForegroundColor Red
        }
        else {
            $okCount++
            if ($nonAscii)     { $tag = 'BOM + 非 ASCII' }
            elseif ($hasBom)   { $tag = '纯 ASCII（带 BOM）' }
            else               { $tag = '纯 ASCII' }
            Write-Host ('  OK    {0}    {1}' -f $rel, $tag) -ForegroundColor Green
        }
    }
}

Write-Host ''
Write-Host '===== 汇总 =====' -ForegroundColor Cyan
$sumColor = if ($failCount -gt 0) { 'Red' } else { 'Green' }
Write-Host ('扫描 {0} 个文件：OK {1}，FAIL {2}' -f $total, $okCount, $failCount) -ForegroundColor $sumColor

if ($total -eq 0) {
    Write-Host '一个文件都没扫到 —— 检查清单与目录布局不匹配（本组失效，按失败处理）。' -ForegroundColor Red
    exit 1
}

if ($failCount -gt 0) {
    Write-Host ''
    Write-Host '不合规清单（含中文却没 BOM 的文件，Windows PowerShell 5.1 下会解析失败）：' -ForegroundColor Yellow
    foreach ($x in $failList) {
        Write-Host "  - $x" -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '补 BOM（就地，不改内容）：' -ForegroundColor Yellow
    Write-Host '  $f = ''路径\xxx.ps1''' -ForegroundColor DarkGray
    Write-Host '  [IO.File]::WriteAllText($f, [IO.File]::ReadAllText($f,[Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding($true)))' -ForegroundColor DarkGray
    exit 1
}

Write-Host '全部合规。' -ForegroundColor Green
exit 0
