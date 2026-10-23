# =============================================================================
#  verify.ps1 —— 一键盘点
#
#  把项目里那些「改错了但没人发现」的检查一次跑完：
#    1) 文件编码：调 check-encoding.ps1（UTF-8 BOM 断言）
#    2) 脚本语法：wpf\Scripts\*.ps1 逐个 Parser::ParseInput
#    3) 脚本双份一致性：dist\scripts\*.ps1 ↔ wpf\Scripts\*.ps1（SHA256）
#    4) 硬编码残留：不能出现 C:\vrchat-*（注释行豁免）
#    5) 内嵌资源清单：wpf\Scripts\*.ps1 ↔ VrcTool.csproj 的 EmbeddedResource
#    6) 版本号一致性：csproj / micasetup.json / build-installer.ps1（不一致只 Warn）
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -Quiet
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -Root D:\repo
#
#  退出码：有 FAIL 1；否则 0。
# =============================================================================
[CmdletBinding()]
param(
    # 检查根目录；不传就取脚本的上一级（本脚本位于 <Root>\tools\）
    [string]$Root,
    # 只打印 WARN/FAIL 的汇总
    [switch]$Quiet
)

# ⚠️ 不能在 param() 的默认值里写 (Split-Path $PSScriptRoot -Parent)：
#    Windows PowerShell 5.1 用 -File 启动时，那个位置 $PSScriptRoot 还是空的。
if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $PSScriptRoot }

$Root        = (Resolve-Path -LiteralPath $Root -ErrorAction SilentlyContinue).Path
if (-not $Root) { Write-Host '根目录不存在: 请用 -Root 指定' -ForegroundColor Red; exit 1 }

$WpfDir      = Join-Path $Root 'wpf'
# 交付包布局：主程序在 src\app\，构建脚本在 src\setup\（没有 wpf\ 这一层）
if (-not (Test-Path -LiteralPath $WpfDir)) { $WpfDir = Join-Path $Root 'src\app' }
$SetupDir    = Join-Path $WpfDir 'setup'
# 交付包布局：src\setup 与 src\app 并列，不在 app 下面
if (-not (Test-Path -LiteralPath $SetupDir)) { $SetupDir = Join-Path $Root 'src\setup' }
$Csproj      = Join-Path $WpfDir 'VrcTool.csproj'
$InstallerPs1  = Join-Path $SetupDir 'build-installer.ps1'
$MicasetupJson = Join-Path $SetupDir 'micasetup.json'

# 脚本目录可能有三处：dist\scripts（老源头）、src\scripts（交付包源头）、
# <wpf>\Scripts（编译副本）。按顺序收集，存在几个就查几个 ——
# 以前写死 dist\scripts ↔ wpf\Scripts，交付包布局下「一个文件都扫不到还报 ok」。
$ScriptDirs = @()
foreach ($d in @((Join-Path $Root 'dist\scripts'),
                 (Join-Path $Root 'src\scripts'),
                 (Join-Path $WpfDir 'Scripts'))) {
    if (Test-Path -LiteralPath $d) { $ScriptDirs += (Resolve-Path -LiteralPath $d).Path }
}
$DistScripts = if ($ScriptDirs.Count -gt 0) { $ScriptDirs[0] } else { Join-Path $Root 'src\scripts' }
$WpfScripts  = if ($ScriptDirs.Count -gt 1) { $ScriptDirs[1] } else { Join-Path $WpfDir 'Scripts' }

$script:Results = @()

function Section([string]$Title) {
    if (-not $Quiet) {
        Write-Host ''
        Write-Host "===== $Title =====" -ForegroundColor Cyan
    }
}

function SayOk([string]$m)   { if (-not $Quiet) { Write-Host "  ok    $m" -ForegroundColor Green } }
function SayWarn([string]$m) { Write-Host "  WARN  $m" -ForegroundColor Yellow }
function SayFail([string]$m) { Write-Host "  FAIL  $m" -ForegroundColor Red }

function Add-Result([string]$Name, [string]$Status, [string]$Summary, $Details) {
    if (-not $Details) { $Details = @() }
    $script:Results += [PSCustomObject]@{
        Name    = $Name
        Status  = $Status
        Summary = $Summary
        Details = @($Details)
    }
}

# 读文本一律走 UTF-8：不用 Get-Content，因为它会受「无 BOM 文件按 ANSI 解码」影响，
# 那正是我们要检出的问题本身，拿来当检查手段会自己骗自己。
function Read-Utf8([string]$Path) {
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

# =============================================================================
# 1/6  文件编码
# =============================================================================
Section '1/6  文件编码（UTF-8 BOM 断言）'
$encScript = Join-Path $PSScriptRoot 'check-encoding.ps1'
if (-not (Test-Path -LiteralPath $encScript)) {
    SayFail "找不到 $encScript"
    Add-Result '文件编码' 'FAIL' 'check-encoding.ps1 缺失' @($encScript)
}
else {
    $encOut  = @()
    $encCode = -1
    try {
        # 6>&1 把子脚本的 Write-Host（information 流）一起抓出来
        $encOut  = @(& $encScript -Root $Root 2>&1 6>&1)
        $encCode = [int]$LASTEXITCODE
    }
    catch {
        $encOut  = @($_.Exception.Message)
        $encCode = -1
    }

    $badLines = @($encOut | ForEach-Object { "$_" } | Where-Object { $_ -match '^\s*FAIL\s' })

    if ($encCode -eq 0) {
        SayOk '所有应带 BOM 的文件都合规'
        Add-Result '文件编码' 'ok' '全部合规' @()
    }
    else {
        if (-not $Quiet) { foreach ($l in $encOut) { Write-Host $l } }
        SayFail "check-encoding.ps1 退出码 $encCode，$($badLines.Count) 个文件不合规"
        Add-Result '文件编码' 'FAIL' "$($badLines.Count) 个文件不合规" $badLines
    }
}

# =============================================================================
# 2/6  脚本语法
# =============================================================================
Section '2/6  脚本语法'
$scriptFiles = @()
foreach ($d in $ScriptDirs) {
    $scriptFiles += @(Get-ChildItem -Path (Join-Path $d '*.ps1') -File -ErrorAction SilentlyContinue)
}
$scriptFiles = @($scriptFiles | Sort-Object FullName)
$parseBad = @()
if ($scriptFiles.Count -eq 0) {
    SayFail "没找到任何脚本（查过: $($ScriptDirs -join ' / ')）"
    Add-Result '脚本语法' 'FAIL' '脚本目录为空或不存在' @($ScriptDirs)
}
else {
    foreach ($f in $scriptFiles) {
        try {
            $text = Read-Utf8 $f.FullName
        }
        catch {
            $parseBad += ('{0}    读取失败: {1}' -f $f.Name, $_.Exception.Message)
            continue
        }
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput(
            $text, $f.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            foreach ($e in $errors) {
                $parseBad += ('{0}    第 {1} 行 第 {2} 列: {3}' -f `
                              $f.Name, $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
            }
        }
    }

    if ($parseBad.Count -eq 0) {
        SayOk "$($scriptFiles.Count) 个脚本语法全部通过"
        Add-Result '脚本语法' 'ok' "$($scriptFiles.Count) 个脚本通过" @()
    }
    else {
        foreach ($b in $parseBad) { SayFail $b }
        Add-Result '脚本语法' 'FAIL' "$($parseBad.Count) 条语法错误" $parseBad
    }
}

# =============================================================================
# 3/6  脚本双份一致性
# =============================================================================
Section '3/6  脚本副本一致性'
$diffBad = @()

if ($ScriptDirs.Count -eq 0) {
    SayFail '没有任何脚本目录，无法比对'
    Add-Result '双份一致性' 'FAIL' '脚本目录缺失' @()
}
elseif ($ScriptDirs.Count -lt 2) {
    SayOk "只有一份脚本（$($ScriptDirs[0])），无需比对"
    Add-Result '双份一致性' 'ok' '只有一份脚本' @()
}
else {
    $srcFiles = @(Get-ChildItem -Path (Join-Path $DistScripts '*.ps1') -File | Sort-Object Name)
    $compared = 0
    foreach ($other in @($ScriptDirs | Select-Object -Skip 1)) {
        $dstFiles = @(Get-ChildItem -Path (Join-Path $other '*.ps1') -File | Sort-Object Name)
        foreach ($f in $srcFiles) {
            $d = Join-Path $other $f.Name
            if (-not (Test-Path -LiteralPath $d)) {
                $diffBad += "目标侧缺失（$other）: $($f.Name)"
                continue
            }
            $h1 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $h2 = (Get-FileHash -LiteralPath $d -Algorithm SHA256).Hash
            if ($h1 -ne $h2) {
                $diffBad += ("SHA256 不一致（{2}）: {0}  ({1} 字节 / {3} 字节)" -f `
                             $f.Name, $f.Length, $other, (Get-Item -LiteralPath $d).Length)
            }
            $compared++
        }
        foreach ($f in $dstFiles) {
            if ($srcFiles.Name -notcontains $f.Name) {
                $diffBad += "源侧没有这个文件（$other 多出）: $($f.Name)"
            }
        }
    }

    if ($diffBad.Count -eq 0) {
        SayOk "$compared 个脚本副本逐字节一致"
        Add-Result '双份一致性' 'ok' "$compared 个文件一致" @()
    }
    else {
        foreach ($b in $diffBad) { SayFail $b }
        Add-Result '双份一致性' 'FAIL' "$($diffBad.Count) 处差异" $diffBad
    }
}

# =============================================================================
# 4/6  硬编码残留
# =============================================================================
Section '4/6  硬编码残留（C:\vrchat-*）'
$hardBad  = @()
$hardScan = @()
foreach ($d in $ScriptDirs) {
    $hardScan += @(Get-ChildItem -Path (Join-Path $d '*.ps1') -File -ErrorAction SilentlyContinue)
}
$hardScan += @(Get-ChildItem -Path (Join-Path $WpfDir '*.cs') -File -ErrorAction SilentlyContinue)
$rxVrchat = 'C:\\+vrchat'

foreach ($f in $hardScan) {
    try {
        $text = Read-Utf8 $f.FullName
    }
    catch {
        $hardBad += ('{0}    读取失败: {1}' -f $f.Name, $_.Exception.Message)
        continue
    }
    $lines = $text -split "`r`n|`n|`r"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $t = $line.Trim()
        # 注释行豁免：注释不参与运行，留着旧路径说明来历是正常的
        if ($t.StartsWith('#') -or $t.StartsWith('//')) { continue }
        if ($line -match $rxVrchat) {
            $rel = $f.FullName.Substring($Root.Length).TrimStart('\')
            $hardBad += ('{0}:{1}    {2}' -f $rel, ($i + 1), $t)
        }
    }
}

if ($hardScan.Count -eq 0) {
    # 「扫了 0 个文件」不是干净，是检查没生效 —— 必须报错，否则最危险的假绿
    SayFail '没有扫描到任何文件（脚本目录和 *.cs 都没找到），本组检查无效'
    Add-Result '硬编码残留' 'FAIL' '扫描 0 个文件' @()
}
elseif ($hardBad.Count -eq 0) {
    SayOk "扫描 $($hardScan.Count) 个文件，没有 C:\vrchat-* 残留"
    Add-Result '硬编码残留' 'ok' "$($hardScan.Count) 个文件干净" @()
}
else {
    foreach ($b in $hardBad) { SayFail $b }
    Add-Result '硬编码残留' 'FAIL' "$($hardBad.Count) 处残留" $hardBad
}

# =============================================================================
# 5/6  内嵌资源清单
# =============================================================================
Section '5/6  内嵌资源清单（csproj ↔ 脚本目录）'
$embBad  = @()
$embInfo = @()

if (-not (Test-Path -LiteralPath $Csproj)) {
    SayFail "找不到 $Csproj"
    Add-Result '内嵌资源清单' 'FAIL' 'csproj 缺失' @($Csproj)
}
else {
    $srcDir = $DistScripts
    $actual = @(Get-ChildItem -Path (Join-Path $srcDir '*.ps1') -File -ErrorAction SilentlyContinue |
                Sort-Object Name)
    $csprojText = Read-Utf8 $Csproj

    # 支持两种写法：
    #   ① <EmbeddedResource Include="..\scripts\*.ps1" ... />
    #   ② <ScriptPs1 Include="..\scripts\*.ps1" /> + <EmbeddedResource Include="@(ScriptPs1)" ... />
    # 以前只认 ① 的字面量路径，换成 ② 之后本组会「看起来没有声明」，需要跟上。
    # ③ 路径里带 $(ScriptsDir) 属性（源码树用 ..\scripts、构建布局用 Scripts\）：
    #    这里按 csproj 的同一条规则替换掉，否则 glob 不到任何文件。
    $scriptsDirVal = ''
    if ($csprojText -match '\$\(ScriptsDir\)') {
        if (Test-Path (Join-Path $WpfDir 'Scripts')) { $scriptsDirVal = 'Scripts' } else { $scriptsDirVal = '..\scripts' }
        $embInfo += "csproj 用 `$(ScriptsDir) 属性 → 解析为 $scriptsDirVal"
    }

    # 只校验脚本资源；数据类资源（geoip.bin 等由 tools\build-geoip.ps1 生成）不参与清单比对
    $dataResources = @('geoip.bin')
    $patterns = @()
    foreach ($m in [regex]::Matches($csprojText, '<EmbeddedResource\s+Include\s*=\s*"([^"]+)"')) {
        $v = $m.Groups[1].Value
        if ($v -match '^@\((.+?)\)$') {
            $itemName = $Matches[1]
            $rxItem = '<' + [regex]::Escape($itemName) + '\s+Include\s*=\s*"([^"]+)"'
            foreach ($im in [regex]::Matches($csprojText, $rxItem)) { $patterns += $im.Groups[1].Value }
        }
        else { $patterns += $v }
    }
    # 内置内核（drivers\*）不是脚本，本组只校验脚本清单 —— 先把它们剔掉，
    # 否则会按"脚本数量"去比对，永远对不上。
    $patterns = @($patterns | Where-Object { $_ -notmatch 'DriversDir|\\drivers\\|^drivers\\|geoip\.bin' })
    $patterns = @($patterns | ForEach-Object { $_.Replace('$(ScriptsDir)', $scriptsDirVal) } |
                  Where-Object { $_ } | Sort-Object -Unique)

    $matched = @()
    foreach ($pat in $patterns) {
        $embInfo += "csproj 声明: $pat"
        $hit = @(Get-ChildItem -Path (Join-Path $WpfDir $pat) -File -ErrorAction SilentlyContinue)
        if ($hit.Count -eq 0) { $embBad += "csproj 声明的内嵌资源没匹配到任何文件: $pat" }
        foreach ($h in $hit) { $matched += $h.Name }
    }

    # csproj 里显式排除了「开发期脚本」：这些不该被要求内嵌，
    # 但排除清单本身也要校验 —— 如果它写的是个不存在的文件，说明维护者手滑了。
    $excluded = @()
    foreach ($m in [regex]::Matches($csprojText, '<[A-Za-z0-9_]+\s+[^>]*Exclude\s*=\s*"([^"]+)"')) {
        foreach ($e in ($m.Groups[1].Value -split ';')) {
            $leaf = Split-Path ($e.Trim()) -Leaf
            if ($leaf) { $excluded += $leaf }
        }
    }
    $excluded = @($excluded | Sort-Object -Unique)
    foreach ($x in $excluded) {
        if (($actual | ForEach-Object { $_.Name }) -notcontains $x) {
            $embBad += "csproj 的 Exclude 里列了不存在的脚本: $x"
        }
    }
    # 上面是按 Include 的通配符 glob 出来的，未应用 Exclude —— 这里补上，
    # 否则会把"被排除的脚本"仍然算成"已内嵌"（数字对不上，检查也就失去意义）。
    if ($excluded.Count -gt 0) {
        $matched = @($matched | Where-Object { $excluded -notcontains $_ })
    }

    $matchedUnique = @($matched | Sort-Object -Unique)
    $embInfo += "脚本目录实际 .ps1: $($actual.Count) 个（$srcDir）"
    $embInfo += "csproj 内嵌清单命中: $($matchedUnique.Count) 个"
    if ($excluded.Count -gt 0) { $embInfo += "按 Exclude 排除（开发脚本）: $($excluded.Count) 个 —— $($excluded -join ', ')" }

    if ($patterns.Count -eq 0) {
        $embBad += 'csproj 里没有找到任何 <EmbeddedResource Include=...> 声明'
    }
    foreach ($a in $actual) {
        if ($excluded -contains $a.Name) { continue }
        if ($matchedUnique -notcontains $a.Name) { $embBad += "脚本没被内嵌: $($a.Name)" }
    }
    foreach ($n in $matchedUnique) {
        if (($actual | ForEach-Object { $_.Name }) -notcontains $n) {
            $embBad += "csproj 里声明了但脚本目录里不存在: $n"
        }
    }

    if (-not $Quiet) { foreach ($l in $embInfo) { Write-Host "  · $l" -ForegroundColor DarkGray } }

    $expectCount = $actual.Count - $excluded.Count
    if ($embBad.Count -eq 0 -and $matchedUnique.Count -eq $expectCount -and $matchedUnique.Count -gt 0) {
        SayOk "内嵌 $($matchedUnique.Count) 个脚本（目录 $($actual.Count) 个，排除 $($excluded.Count) 个开发脚本）"
        Add-Result '内嵌资源清单' 'ok' "$($matchedUnique.Count)/$expectCount 一致（排除 $($excluded.Count)）" $embInfo
    }
    else {
        if ($actual.Count -eq 0) { $embBad += "脚本目录里一个 .ps1 都没有: $srcDir" }
        foreach ($b in $embBad) { SayFail $b }
        Add-Result '内嵌资源清单' 'FAIL' ("目录 $($actual.Count) 个 / 清单 $($matchedUnique.Count) 个") ($embBad + $embInfo)
    }
}

# =============================================================================
# 6/6  版本号一致性（只 Warn）
# =============================================================================
Section '6/6  版本号一致性'
$csVersion   = $null
$jsonVersion = $null
$biVersion   = $null
$verNotes    = @()

if (Test-Path -LiteralPath $Csproj) {
    $t = Read-Utf8 $Csproj
    if ($t -match '<Version>\s*([^<\s]+)\s*</Version>') { $csVersion = $Matches[1] }
    else { $verNotes += 'VrcTool.csproj 里没有找到 <Version>' }
}
else { $verNotes += "找不到 $Csproj" }

if (Test-Path -LiteralPath $MicasetupJson) {
    try {
        $jsonVersion = (Read-Utf8 $MicasetupJson | ConvertFrom-Json).Version
    }
    catch { $verNotes += "micasetup.json 解析失败: $($_.Exception.Message)" }
}
else { $verNotes += "找不到 $MicasetupJson" }

if (Test-Path -LiteralPath $InstallerPs1) {
    $t = Read-Utf8 $InstallerPs1
    # 定位 param 块里 $Version 的默认值
    if ($t -match '(?m)\[string\]\s*\$Version\s*=\s*[''"]([^''"]+)[''"]') { $biVersion = $Matches[1] }
    else { $verNotes += 'build-installer.ps1 里没有找到 [string]$Version = ''...''' }
}
else { $verNotes += "找不到 $InstallerPs1" }

$verInfo = @(
    "VrcTool.csproj          <Version>          = $csVersion"
    "micasetup.json          ""Version""         = $jsonVersion"
    "build-installer.ps1     param `$Version     = $biVersion"
)
if (-not $Quiet) { foreach ($l in $verInfo) { Write-Host "  · $l" -ForegroundColor DarkGray } }

$distinct = @(@($csVersion, $jsonVersion, $biVersion) | Where-Object { $_ } | Sort-Object -Unique)
if ($distinct.Count -eq 1 -and $verNotes.Count -eq 0) {
    SayOk "三处版本号一致: $($distinct[0])"
    Add-Result '版本号一致性' 'ok' "三处均为 $($distinct[0])" $verInfo
}
else {
    foreach ($n in $verNotes) { SayWarn $n }
    if ($distinct.Count -ne 1) { SayWarn "版本号不一致: $($distinct -join ' / ')" }
    Add-Result '版本号一致性' 'WARN' "不一致或有缺失: $($distinct -join ' / ')" ($verNotes + $verInfo)
}

# =============================================================================
# 汇总
# =============================================================================
Write-Host ''
Write-Host '===== 汇总 =====' -ForegroundColor Cyan
foreach ($r in $script:Results) {
    $color = 'Green'
    if ($r.Status -eq 'WARN') { $color = 'Yellow' }
    if ($r.Status -eq 'FAIL') { $color = 'Red' }
    Write-Host ('  [{0,-4}] {1,-14} {2}' -f $r.Status, $r.Name, $r.Summary) -ForegroundColor $color
}

foreach ($r in $script:Results) {
    if ($r.Status -eq 'ok') { continue }
    $color = 'Yellow'
    if ($r.Status -eq 'FAIL') { $color = 'Red' }
    Write-Host ('  --- {0}（{1}）---' -f $r.Name, $r.Status) -ForegroundColor $color
    foreach ($d in $r.Details) { Write-Host "      $d" -ForegroundColor $color }
}

$failGroups = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
$warnGroups = @($script:Results | Where-Object { $_.Status -eq 'WARN' })

Write-Host ''
if ($failGroups.Count -gt 0) {
    Write-Host ("结果: FAIL —— {0} 组失败，{1} 组告警" -f $failGroups.Count, $warnGroups.Count) -ForegroundColor Red
    exit 1
}
if ($warnGroups.Count -gt 0) {
    Write-Host ("结果: PASS（{0} 组告警，不阻塞）" -f $warnGroups.Count) -ForegroundColor Yellow
    exit 0
}
Write-Host '结果: PASS —— 全部通过' -ForegroundColor Green
exit 0
