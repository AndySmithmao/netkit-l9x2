# =============================================================================
#  restore-vswhere.ps1 —— vswhere 转发 shim 的状态检查 / 还原
#
#  背景：
#    makemica 内部执行 `vswhere -latest -property installationPath`，
#    而 vswhere 默认不把 Visual Studio BuildTools 算作 Visual Studio
#    （必须显式加 `-products *`），于是装了 VS BuildTools 也报
#    「Microsoft Visual Studio Installer is not installed, register not found」。
#    本机当时把真身改名为 vswhere_orig.exe，换成 tools_py\vswhere-shim.cs
#    编译出来的转发 shim（自动补 -products *）。
#
#  ⚠️ 这个 shim 是「开发机」级别的改动，会污染 VS 安装目录。
#     换机器 / 重装 VS / 交付前，先跑 -Restore 还原。
#
#  用法：
#    # 默认 -Status：报告现在是原版还是 shim（只读，不需要管理员）
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\restore-vswhere.ps1
#
#    # 还原（会改 C:\Program Files (x86)\...，必须管理员）
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\restore-vswhere.ps1 -Restore
#
#  退出码：状态正常 0；异常/失败 1。
# =============================================================================
[CmdletBinding()]
param(
    # 还原：把 vswhere_orig.exe 改回 vswhere.exe（需要管理员）
    [switch]$Restore,
    # 手动指定 Installer 目录（一般不用传）
    [string]$InstallerDir
)

$ShimName = 'vswhere.exe'
$OrigName = 'vswhere_orig.exe'
$RealAlt  = 'vswhere.real.exe'
$BakName  = 'vswhere-shim.bak.exe'

# 真身 vswhere.exe 大约 460KB，shim 只有几 KB。差距太大，拿来当兜底判据。
$OrigMinSize = 150KB

function Say  ([string]$m) { Write-Host "  $m" }
function Head ([string]$m) { Write-Host ''; Write-Host "===== $m =====" -ForegroundColor Cyan }
function Warn ([string]$m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Bad  ([string]$m) { Write-Host "  [X] $m" -ForegroundColor Red }

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Resolve-InstallerDir {
    param([string]$Preferred)
    $cands = @()
    if ($Preferred) { $cands += $Preferred }
    if (${env:ProgramFiles(x86)}) {
        $cands += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer')
    }
    if ($env:ProgramFiles) {
        $cands += (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\Installer')
    }
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    if ($cands.Count -gt 0) { return $cands[0] }
    return $null
}

function Get-FileDetail {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        $hash = $null
        try { $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { }
        $fv = $null
        try { if ($item.VersionInfo) { $fv = $item.VersionInfo.FileVersion } } catch { }
        return [PSCustomObject]@{
            Path        = $Path
            Length      = $item.Length
            Hash        = $hash
            FileVersion = $fv
            LastWrite   = $item.LastWriteTime
        }
    }
    catch { return $null }
}

# 判断一个 vswhere.exe 是转发 shim 还是微软原版。
# ⚠️ 坑：不能只按 ASCII 扫二进制。.NET 的字符串字面量在 PE 里是 **UTF-16LE** 存的
#        （C# 里写 "vswhere_orig.exe"，编译后就是 U+0000 间隔的字节），
#        只做 ASCII.Contains 会漏判，把 shim 认成原版。所以两种编码都要看。
function Get-VswhereKind {
    param($Detail)
    if (-not $Detail) {
        return [PSCustomObject]@{ Kind = 'missing'; Why = '文件不存在' }
    }

    try {
        $bytes = [IO.File]::ReadAllBytes($Detail.Path)
        $ascii = [Text.Encoding]::ASCII.GetString($bytes)
        $uni   = [Text.Encoding]::Unicode.GetString($bytes)
        foreach ($mark in @('vswhere_orig.exe', 'vswhere.real.exe', 'vswhere shim')) {
            if ($ascii.Contains($mark) -or $uni.Contains($mark)) {
                return [PSCustomObject]@{
                    Kind = 'shim'
                    Why  = ("二进制里含转发标记 '{0}'（ASCII / UTF-16LE 任一命中）" -f $mark)
                }
            }
        }
    }
    catch {
        return [PSCustomObject]@{ Kind = 'unknown'; Why = ('读不了内容: {0}' -f $_.Exception.Message) }
    }

    $size = $Detail.Length
    $fv   = "$($Detail.FileVersion)"

    if ($size -lt $OrigMinSize) {
        return [PSCustomObject]@{
            Kind = 'shim?'
            Why  = ("没找到转发标记，但体积只有 {0} 字节（真身约 460KB），**极可能**还是 shim" -f $size)
        }
    }
    if ($fv -and $fv -ne '0.0.0.0') {
        return [PSCustomObject]@{
            Kind = 'orig'
            Why  = ("体积 {0} 字节、文件版本 {1}，是微软原版" -f $size, $fv)
        }
    }
    return [PSCustomObject]@{
        Kind = 'unknown'
        Why  = ("体积 {0} 字节，但文件版本是 {1}，特征不足，请人工确认" -f $size, $fv)
    }
}

function Show-Detail {
    param($D, [string]$Label)
    if (-not $D) {
        Warn ("{0} 不存在" -f $Label)
        return
    }
    Say ("{0} {1}" -f $Label, $D.Path)
    Say ("      大小: {0} 字节   最后写入: {1}" -f $D.Length, $D.LastWrite)
    Say ("      SHA256: {0}" -f $D.Hash)
    if ($D.FileVersion -and $D.FileVersion -ne '0.0.0.0') {
        Say ("      文件版本: {0}" -f $D.FileVersion)
    }
    else {
        Say  '      文件版本: 0.0.0.0（csc 裸编译的产物就是这个值，真身是 3.x.x）'
    }
}

function Invoke-VswhereProbe {
    param([string]$Exe, [string[]]$ArgList)
    try {
        $out  = & $Exe @ArgList 2>&1
        $code = $LASTEXITCODE
        $txt  = (@($out | ForEach-Object { "$_" }) -join ' | ').Trim()
        if (-not $txt) { $txt = '(无输出)' }
        return ('exit={0}  {1}' -f $code, $txt)
    }
    catch {
        return ('执行失败: {0}' -f $_.Exception.Message)
    }
}

function Show-Status {
    param([string]$Dir)

    Head '1/3  定位'
    Say "Installer 目录: $Dir"
    if (-not (Test-Path -LiteralPath $Dir)) {
        Bad '目录不存在，本机大概没装过 Visual Studio / BuildTools'
        return 1
    }

    $curPath  = Join-Path $Dir $ShimName
    $origPath = Join-Path $Dir $OrigName
    $realPath = Join-Path $Dir $RealAlt

    $cur  = Get-FileDetail $curPath
    $orig = Get-FileDetail $origPath
    $real = Get-FileDetail $realPath

    Head '2/3  文件现状'
    Show-Detail $cur  '当前 vswhere.exe  '
    Show-Detail $orig '备份 vswhere_orig '
    if ($real) { Show-Detail $real '备份 vswhere.real ' }

    $kind = Get-VswhereKind -Detail $cur

    Head '3/3  判定'
    Say ("判定: {0} —— {1}" -f $kind.Kind, $kind.Why)

    switch ($kind.Kind) {
        'missing' {
            Bad 'vswhere.exe 不存在 —— VS 安装器体系可能已经损坏，需要重装 VS Installer'
            return 1
        }
        'shim' {
            Warn '当前 vswhere.exe 是「转发 shim」（会自动补 -products *）'
            if ($orig) { Say '  → 原文件还在，随时可以 -Restore 还原' }
            else       { Bad '原文件 vswhere_orig.exe 不见了 —— 没法还原，只能重装 VS Installer' }
            Say ''
            Say '这个 shim 是开发机专用补丁，会污染 VS 安装目录。'
            Say '换机器 / 重装 VS / 交付安装包之前，先跑：'
            Say '    powershell -NoProfile -ExecutionPolicy Bypass -File .\restore-vswhere.ps1 -Restore'
        }
        'shim?' {
            Warn '当前 vswhere.exe **极可能**是转发 shim，但没有命中转发标记字符串'
            Warn '（比如 shim 被重新编译过、改了提示文案）'
            if ($orig) {
                Say '  → 保险起见：先备份当前文件，再跑 -Restore 换回原版'
            }
            else {
                Bad '原文件 vswhere_orig.exe 不见了 —— 没法还原'
            }
        }
        'orig' {
            Say '当前 vswhere.exe 是微软原版'
            if ($orig) {
                Warn '但 vswhere_orig.exe 也还在 —— 大概是还原过之后没清理备份'
                Say  '  确认无误后可以直接删掉备份（保留也不影响运行）'
            }
        }
        default {
            Warn '无法判定，只能人工确认'
        }
    }

    if ($orig -and $cur -and $orig.Hash -eq $cur.Hash) {
        Warn 'vswhere.exe 与 vswhere_orig.exe 内容完全一致 —— 其实等于已经还原了，可以删备份'
    }

    Say ''
    Say '行为探测（对排障最有用的一节）：'
    Say  '  makemica 的调用方式  -latest -property installationPath'
    Say ('    {0}' -f (Invoke-VswhereProbe $curPath @('-latest', '-property', 'installationPath')))
    if ($orig) {
        Say  '  原生 vswhere_orig    -latest -property installationPath'
        Say ('    {0}' -f (Invoke-VswhereProbe $origPath @('-latest', '-property', 'installationPath')))
    }
    Say  '  带上 -products *      -products * -latest -property installationPath'
    Say ('    {0}' -f (Invoke-VswhereProbe $curPath @('-products', '*', '-latest', '-property', 'installationPath')))

    return 0
}

function Invoke-Restore {
    param([string]$Dir)

    Head 'vswhere 还原'
    Say "Installer 目录: $Dir"
    if (-not (Test-Path -LiteralPath $Dir)) {
        Bad "目录不存在: $Dir"
        return 1
    }

    $curPath  = Join-Path $Dir $ShimName
    $origPath = Join-Path $Dir $OrigName
    $realPath = Join-Path $Dir $RealAlt
    $bakPath  = Join-Path $Dir $BakName

    if (-not (Test-Path -LiteralPath $origPath) -and -not (Test-Path -LiteralPath $realPath)) {
        Bad "找不到 $OrigName（也没有 $RealAlt），没有东西可以还原"
        Say '  可能已经还原过了，或者当初备份被别人删了'
        return 1
    }

    if (-not (Test-Admin)) {
        Bad '需要管理员权限才能改 C:\Program Files (x86)\ 下的文件'
        Say ''
        Say '请用管理员身份打开 PowerShell 再执行：'
        Say ('    powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Restore' -f $PSCommandPath)
        Say ''
        Say '（或者右键 PowerShell → 以管理员身份运行，再 cd 到 tools 目录执行）'
        return 1
    }

    $source = $null
    if (Test-Path -LiteralPath $origPath) { $source = $origPath }
    else                                  { $source = $realPath }

    try {
        if (Test-Path -LiteralPath $curPath) {
            $curInfo = Get-FileDetail $curPath
            $curKind = Get-VswhereKind -Detail $curInfo
            if ($curKind.Kind -eq 'orig') {
                Warn '当前 vswhere.exe 看起来已经是原版了，仍然先备份再覆盖'
            }
            else {
                Say '先把当前 shim 备份成 vswhere-shim.bak.exe（不留后路不敢乱动系统目录）'
            }
            Copy-Item -LiteralPath $curPath -Destination $bakPath -Force
            Say ("  备份 -> {0}" -f $bakPath)
            Remove-Item -LiteralPath $curPath -Force
        }
        else {
            Warn '当前没有 vswhere.exe，直接放回原版'
        }

        Rename-Item -LiteralPath $source -NewName $ShimName -Force
        Say ("  还原 -> {0}" -f $curPath)

        $now = Get-FileDetail $curPath
        if ($now) {
            Say ("  现在大小 {0} 字节   SHA256 {1}" -f $now.Length, $now.Hash)
            Say ("  文件版本 {0}" -f $now.FileVersion)
            Say ("  判定 {0}" -f (Get-VswhereKind -Detail $now).Why)
        }
        Say ''
        Say '完成。makemica 又不认 VS BuildTools 了 —— 这是原版行为，不是新问题。'
        Say '想再装回 shim：把 vswhere-shim.bak.exe 覆盖成 vswhere.exe 即可。'
        return 0
    }
    catch {
        Bad ('还原失败: {0}' -f $_.Exception.Message)
        return 1
    }
}

# =============================================================================
$Dir = Resolve-InstallerDir -Preferred $InstallerDir
if (-not $Dir) {
    Bad '找不到 Visual Studio Installer 目录'
    exit 1
}

if ($Restore) {
    $code = Invoke-Restore -Dir $Dir
}
else {
    Head 'vswhere 状态检查（只读；要还原请加 -Restore）'
    $code = Show-Status -Dir $Dir
}

exit $code
