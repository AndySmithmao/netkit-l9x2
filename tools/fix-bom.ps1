# =============================================================================
#  fix-bom.ps1 —— 给「含非 ASCII 但缺 UTF-8 BOM」的文件补上 BOM
#
#  为什么需要这个脚本：
#    项目里大量 .cs / .xaml / .ps1 带中文。Windows PowerShell 5.1 读**没有 BOM**
#    的 .ps1 时会按当前 ANSI 代码页（中文系统上是 GBK）解码 —— 中文 UTF-8 字节
#    被两两强行配对后会 desync，把后面的引号当双字节尾字节吞掉，结果是
#    **脚本直接语法错误、根本跑不起来**（不是"乱码"那么温柔）。
#
#    C# / XAML 没这么致命（Roslyn 和 XAML 编译器都会先试 UTF-8），但混着不好维护。
#
#  实际踩过的：`edit` 类工具有的会抹掉 BOM，改完文件就中招。
#  所以改完代码跑一次 `tools\verify.ps1`，报 FAIL 就再跑这个脚本补回来。
#
#  用法:
#    powershell -ExecutionPolicy Bypass -File tools\fix-bom.ps1            # 只看不写
#    powershell -ExecutionPolicy Bypass -File tools\fix-bom.ps1 -Apply     # 真的补
#    powershell -ExecutionPolicy Bypass -File tools\fix-bom.ps1 -Apply -Root <某个目录>
# =============================================================================
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$Root = ''
)

$ErrorActionPreference = 'Continue'

# 注意：不能在 param() 默认值里用 $PSScriptRoot ——
# powershell -File 启动时它在绑定参数阶段还是空串，会直接抛
# "Cannot bind argument to parameter 'Path' because it is null"。
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }

# 按布局自动拼（老布局 wpf\ + dist\scripts；源码树 src\app + src\scripts）
$WpfDir = Join-Path $Root 'wpf'
if (-not (Test-Path -LiteralPath $WpfDir)) { $WpfDir = Join-Path $Root 'src\app' }
$SetupDir = Join-Path $WpfDir 'setup'
if (-not (Test-Path -LiteralPath $SetupDir)) { $SetupDir = Join-Path $Root 'src\setup' }
$targets = @(
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

function Test-HasBom([string]$path) {
    try {
        $b = [IO.File]::ReadAllBytes($path)
        return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    } catch { return $true }   # 读不了就不折腾它
}

function Test-HasNonAscii([string]$path) {
    try {
        $t = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        foreach ($ch in $t.ToCharArray()) { if ([int]$ch -gt 127) { return $true } }
        return $false
    } catch { return $false }
}

Write-Host ''
Write-Host '===== 补 UTF-8 BOM =====' -ForegroundColor Cyan
Write-Host ("根目录: " + $Root)
if (-not $Apply) { Write-Host '（预演模式，不会写文件。要真的补请加 -Apply）' -ForegroundColor DarkGray }
Write-Host ''

$scanned = 0
$fixed = 0
$failed = 0

foreach ($pat in $targets) {
    $files = @(Get-ChildItem -Path $pat -File -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '\\\\(bin|obj|publish|\.dist)\\\\' })
    foreach ($f in $files) {
        $scanned++
        $hasBom = Test-HasBom $f.FullName
        $hasCn = Test-HasNonAscii $f.FullName

        if ($hasBom) { continue }
        if (-not $hasCn) { continue }        # 纯 ASCII 带不带都行，不动它

        if (-not $Apply) {
            Write-Host ("  [待补] " + $f.FullName.Substring($Root.Length + 1)) -ForegroundColor Yellow
            $fixed++
            continue
        }

        try {
            # 严格 UTF-8 解码：文件若是 GBK，[Text.Encoding]::UTF8 会把它解成
            # U+FFFD 乱码，再按 UTF-8 写回 = 把文件彻底弄坏。这种情况必须拒绝。
            $strict = New-Object Text.UTF8Encoding($false, $true)
            $bytes  = [IO.File]::ReadAllBytes($f.FullName)
            $text   = $strict.GetString($bytes)
            [IO.File]::WriteAllText($f.FullName, $text, (New-Object Text.UTF8Encoding($true)))
            Write-Host ("  [已补] " + $f.FullName.Substring($Root.Length + 1)) -ForegroundColor Green
            $fixed++
        } catch {
            Write-Host ("  [失败] " + $f.FullName.Substring($Root.Length + 1) + " —— " + $_.Exception.Message) -ForegroundColor Red
            $failed++
        }
    }
}

Write-Host ''
Write-Host ("扫描 $scanned 个文件，" + $(if ($Apply) { '已补' } else { '待补' }) + " $fixed 个，失败 $failed 个") -ForegroundColor Cyan
if (-not $Apply -and $fixed -gt 0) { Write-Host '加 -Apply 才能真正写入。' -ForegroundColor DarkGray }
Write-Host ''

if ($failed -gt 0) { exit 1 }
exit 0
