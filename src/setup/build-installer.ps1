# =============================================================================
#  VRChat优选工具 —— 一键构建安装包
#
#  流程：
#    1) dotnet publish 自包含单文件
#    2) 签名主程序（在打包前签，这样装出来的 exe 也是签名的）
#    3) 7z 打包成 publish.7z
#    4) makemica 生成安装器骨架（KeyName 只能传 ASCII，稍后改写）
#    5) 改写 .dist 源码：程序集信息 + option.KeyName/AppName/ExeName（支持中文）
#    6) MSBuild 编译 Uninst → 签名 → 塞回资源；再编译 Setup → 签名
#    7) 输出最终安装包
# =============================================================================
[CmdletBinding()]
param(
    [string]$Version    = '0.0.4-beta',
    # 决定默认安装目录 C:\Program Files\<InstallFolder>
    [string]$InstallFolder = 'VRChat优选工具',
    [string]$Publisher  = 'VRChat-Tool',
    # 下面两个留空就按「本脚本所在位置」自动推导 —— 换台机器 / 换目录也能构建
    [string]$WpfDir     = '',
    [string]$MicaTools  = '',
    # 工具链留空就自动找：dotnet 优先用 C:\Program Files\dotnet，找不到再扫 PATH；
    # MSBuild 优先 VS 18（2026），没有就用 vswhere 找最新一个。
    [string]$Dotnet     = '',
    [string]$MSBuildExe = '',
    [switch]$SkipSign
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# 路径推导：脚本就在 <ProbeRoot>\wpf\setup\ 下，所以 WpfDir = 上一级，
# MicaTools 默认在 <ProbeRoot>\micasetup\extract\build。
# 原来这两行是写死的 C:\Dsh\_probe\...，换台机器直接构不了。
if (-not $WpfDir)    { $WpfDir    = Split-Path $PSScriptRoot -Parent }
if (-not $MicaTools) { $MicaTools = Join-Path (Split-Path $WpfDir -Parent) 'micasetup\extract\build' }

$SetupDir  = Join-Path $WpfDir 'setup'
$DistDir   = Join-Path $SetupDir '.dist'
$CertDir   = Join-Path $SetupDir 'cert'
$Makemica  = Join-Path $MicaTools 'makemica.exe'
$SevenZip  = Join-Path $MicaTools 'bin\7z.exe'

# ------------------------------------------------------------------ 工具链定位
# 为什么不再写死：VS 2026 只在自己的机器上有，换台机器（或只有 VS 2022）就直接构不了；
# dotnet 也可能装在别处（例如便携解包到非系统目录）。
function Resolve-Dotnet {
    param([string]$Given)
    if ($Given -and (Test-Path $Given)) { return $Given }
    $cands = @(
        (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'),
        'C:\Opencode\.dotnet10\dotnet.exe',
        'C:\Opencode\.dotnet\dotnet.exe'
    )
    foreach ($c in $cands) {
        if (Test-Path $c) {
            $sdks = @(& $c --list-sdks 2>$null)
            if ($sdks.Count -gt 0) { return $c }
        }
    }
    $p = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($p) { return $p.Source }
    return (Join-Path $env:ProgramFiles 'dotnet\dotnet.exe')
}

function Resolve-MSBuild {
    param([string]$Given)
    if ($Given -and (Test-Path $Given)) { return $Given }
    $hard = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe'
    if (Test-Path $hard) { return $hard }
    # 退出码 0 表示找到；用 vswhere 而不是猜路径
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $found = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null
        $found = @($found) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
        if ($found) { return $found }
    }
    foreach ($v in @('2022','2019')) {
        $p = "C:\Program Files (x86)\Microsoft Visual Studio\$v\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
        if (Test-Path $p) { return $p }
    }
    return $hard
}

$Dotnet  = Resolve-Dotnet  $Dotnet
$MSBuild = Resolve-MSBuild $MSBuildExe

$AppName  = 'VRChat优选工具'
$ExeName  = "$AppName.exe"
$OutName  = "$AppName-安装包.exe"
$Cer      = Join-Path $CertDir 'vrctool-codesign.cer'
$Utf8NoBom = New-Object Text.UTF8Encoding($false)

function Say  ([string]$m) { Write-Host "  $m" }
function Head ([string]$m) { Write-Host ""; Write-Host "===== $m =====" -ForegroundColor Cyan }
function Warn ([string]$m) { Write-Host "  [!] $m" -ForegroundColor Yellow }

# ------------------------------------------------------------------ 签名
# 时间戳服务器备选列表。
# 为什么要多试几个：**打了时间戳的签名在证书过期后仍然有效**，
# 没打时间戳的会随证书一起失效。原来只试 digicert 一家，不通就直接放弃时间戳了。
$TimestampServers = @(
    'http://timestamp.digicert.com',
    'http://timestamp.sectigo.com',
    'http://timestamp.comodoca.com',
    'http://time.certum.pl'
)

function Get-SignCert {
    if ($script:SignCert) { return $script:SignCert }
    $c = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
         Where-Object { $_.HasPrivateKey } | Select-Object -First 1
    if (-not $c) { throw '证书存储里没有可用的代码签名证书（先跑 cert\make-cert.ps1）' }
    $script:SignCert = $c
    return $c
}

function Sign-File([string]$Path) {
    if ($SkipSign) { Say "跳过签名: $(Split-Path $Path -Leaf)"; return }
    $cert = Get-SignCert

    $res  = $null
    $used = ''
    foreach ($ts in $TimestampServers) {
        $res = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert `
                 -HashAlgorithm SHA256 -TimestampServer $ts -EA SilentlyContinue
        if ($res -and $res.Status -eq 'Valid') { $used = $ts; break }
        Warn ("时间戳服务器 {0} 不通，换下一个" -f $ts)
    }
    if (-not $res -or $res.Status -ne 'Valid') {
        Warn '所有时间戳服务器都不通，改为不打时间戳签名（证书过期后该签名会失效）'
        $res = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert -HashAlgorithm SHA256
    }

    $tail = if ($used) { "ts=" + ([Uri]$used).Host } else { '无时间戳' }
    Say ("签名 {0,-34} {1}   {2}" -f (Split-Path $Path -Leaf), $res.Status, $tail)
}

# =============================================================================
Head '0/7  环境检查'
foreach ($p in @($Makemica, $SevenZip, $Dotnet, $MSBuild)) {
    if (-not (Test-Path $p)) { throw "缺少: $p" }
    Say "ok  $p"
}
$null = Get-SignCert
Say "ok  代码签名证书 $((Get-SignCert).Thumbprint)"
Say "默认安装到: $env:ProgramFiles\$InstallFolder"

# =============================================================================
Head '0.5/7  同步脚本（dist\scripts → wpf\Scripts）+ 一致性断言'
# 脚本有两份：dist\scripts 是「源头」（人改这里），wpf\Scripts 是编译进 EXE 的那份。
# 踩过一次：改了 dist 忘了同步，结果交付的安装包里改动根本没生效（ISSUES #7）。
# 这里改成自动同步 + 硬断言，从根上杜绝。
# 顺带强制 UTF-8 BOM：Windows PowerShell 5.1 读没有 BOM 的 .ps1 会按 ANSI 解码，
# 中文一旦落在这个坑里会直接解析失败（不是乱码那么温柔）。
$ProbeRoot  = Split-Path $WpfDir -Parent
$SrcScripts = Join-Path $ProbeRoot 'dist\scripts'
$DstScripts = Join-Path $WpfDir 'Scripts'

# 布局兼容：老布局是 <root>\dist\scripts + <root>\wpf\Scripts；
# 交付包布局是 src\scripts + src\app（wpf 的对应物叫 src\app）。
# 以前只认第一种，于是「按包里的说明拼出来的目录」会在这里直接 throw。
if (-not (Test-Path $SrcScripts)) {
    $alt = Join-Path $ProbeRoot 'src\scripts'
    if (Test-Path $alt) {
        $SrcScripts = $alt
        Say "  脚本源目录改用交付包布局: $alt"
    }
}
if (-not (Test-Path $SrcScripts)) { throw "找不到脚本源目录: $SrcScripts（也没有 <root>\src\scripts）" }
if (-not (Test-Path $DstScripts)) { New-Item -ItemType Directory -Path $DstScripts -Force | Out-Null }

function Add-Utf8Bom([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return $false }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($true)))
    return $true
}

$srcFiles = @(Get-ChildItem $SrcScripts -Filter *.ps1 -File)
$dstFiles = @(Get-ChildItem $DstScripts -Filter *.ps1 -File)
foreach ($f in $dstFiles) {
    if ($srcFiles.Name -notcontains $f.Name) { Warn "wpf\Scripts 里多出一个源目录没有的脚本: $($f.Name)" }
}

$bomFixed = 0
foreach ($f in $srcFiles) { if (Add-Utf8Bom $f.FullName) { $bomFixed++ } }
if ($bomFixed -gt 0) { Say "  源目录补 UTF-8 BOM: $bomFixed 个" }

$copied = 0
foreach ($f in $srcFiles) {
    $d = Join-Path $DstScripts $f.Name
    if ((Test-Path $d) -and
        (Get-FileHash $f.FullName -Algorithm SHA256).Hash -eq (Get-FileHash $d -Algorithm SHA256).Hash) { continue }
    Copy-Item $f.FullName $d -Force
    $copied++
}
Say ("  dist\scripts {0} 个，本次同步 {1} 个" -f $srcFiles.Count, $copied)

# ---------------------------------------------------------------- 同步内置内核
# 与脚本同样的道理：csproj 会内嵌 $(DriversDir)\*，构建布局里这个目录是 <wpf>\drivers。
# 源目录按布局找：<root>\src\drivers 或 <root>\dist\drivers。
$SrcDrivers = Join-Path $ProbeRoot 'src\drivers'
if (-not (Test-Path $SrcDrivers)) { $SrcDrivers = Join-Path $ProbeRoot 'dist\drivers' }
$DstDrivers = Join-Path $WpfDir 'drivers'
if (Test-Path $SrcDrivers) {
    if (-not (Test-Path $DstDrivers)) { New-Item -ItemType Directory -Path $DstDrivers -Force | Out-Null }
    $drvFiles = @(Get-ChildItem $SrcDrivers -File)
    $drvCopied = 0
    foreach ($f in $drvFiles) {
        $d = Join-Path $DstDrivers $f.Name
        if ((Test-Path $d) -and
            (Get-FileHash $f.FullName -Algorithm SHA256).Hash -eq (Get-FileHash $d -Algorithm SHA256).Hash) { continue }
        Copy-Item $f.FullName $d -Force
        $drvCopied++
    }
    $sizeMb = [math]::Round((($drvFiles | Measure-Object Length -Sum).Sum / 1MB), 1)
    Say ("  内核 {0} 个（{1} MB），本次同步 {2} 个" -f $drvFiles.Count, $sizeMb, $drvCopied)
} else {
    Warn "找不到内置内核目录: $SrcDrivers（构建出来的 EXE 里将没有 winws/mihomo）"
}

# 断言 1：字节级一致
$mismatch = @()
foreach ($f in $srcFiles) {
    $d = Join-Path $DstScripts $f.Name
    if (-not (Test-Path $d)) { $mismatch += "缺失: $($f.Name)"; continue }
    if ((Get-FileHash $f.FullName -Algorithm SHA256).Hash -ne (Get-FileHash $d -Algorithm SHA256).Hash) {
        $mismatch += "SHA256 不一致: $($f.Name)"
    }
}
if ($mismatch.Count -gt 0) {
    $mismatch | ForEach-Object { Warn $_ }
    throw '脚本同步断言失败：dist\scripts 与 wpf\Scripts 不一致'
}
Say '  ok  两边 SHA256 全部一致'

# 断言 2：语法 + BOM
$parseErr = @()
foreach ($f in $srcFiles) {
    $err = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$err) | Out-Null
    if ($err -and $err.Count -gt 0) { $parseErr += "$($f.Name): $($err[0].Message)" }
}
if ($parseErr.Count -gt 0) {
    $parseErr | ForEach-Object { Warn $_ }
    throw '脚本语法校验失败（多半是 BOM 或编码问题）'
}
Say ("  ok  {0} 个脚本语法全部通过" -f $srcFiles.Count)

# 断言 3：不该再有硬编码的旧数据目录（注释行不算，注释不参与运行）
$hard = @(Select-String -Path (Join-Path $SrcScripts '*.ps1') -Pattern 'C:\\+vrchat' -EA SilentlyContinue |
          Where-Object { $_.Line.TrimStart() -notmatch '^#' })
$hard += @(Select-String -Path (Join-Path $WpfDir '*.cs') -Pattern 'C:\\+vrchat' -EA SilentlyContinue |
           Where-Object { $_.Line.TrimStart() -notmatch '^//' })
if ($hard.Count -gt 0) {
    $hard | ForEach-Object { Warn ("  {0}:{1}  {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim()) }
    throw '检测到残留的硬编码旧数据目录，构建中止'
}
Say '  ok  脚本与 C# 均无硬编码旧数据目录'

# 一键盘点（编码 / 脚本语法 / 双份一致 / 硬编码 / 内嵌资源清单 / 版本号一致）
$Verify = Join-Path $ProbeRoot 'tools\verify.ps1'
if (Test-Path $Verify) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $Verify -Quiet
    if ($LASTEXITCODE -ne 0) { throw 'tools\verify.ps1 未通过，构建中止（先修上面报出来的项）' }
    Say '  ok  tools\verify.ps1 全部通过'
} else {
    Warn "找不到 $Verify，跳过一键盘点"
}

# =============================================================================
Head '1/7  发布主程序（自包含单文件）'
$pub = Join-Path $WpfDir 'publish'
if (Test-Path $pub) { Remove-Item $pub -Recurse -Force }
# ★ 必须先切到 $WpfDir：dotnet 是按「当前工作目录」逐级向上找 global.json 的，
#   不切的话从别处启动就会挑系统里最新的 SDK（本机装了 10.0.402），
#   global.json 里锁的 8.0.x 等于白写，构建产物不可复现。
Push-Location $WpfDir
try {
    & $Dotnet publish (Join-Path $WpfDir 'VrcTool.csproj') -c Release -r win-x64 `
        --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true -o $pub -v quiet --nologo
} finally {
    Pop-Location
}
$appExe = Join-Path $pub $ExeName
if (-not (Test-Path $appExe)) { throw '发布失败' }
Say ("{0}  {1:N2} MB" -f $ExeName, ((Get-Item $appExe).Length / 1MB))

Head '2/7  签名主程序'
Sign-File $appExe

# =============================================================================
Head '3/7  用 7z 打包'
$pkg = Join-Path $SetupDir 'VRChatTool.7z'
if (Test-Path $pkg) { Remove-Item $pkg -Force }
& $SevenZip a $pkg (Join-Path $pub '*') -t7z -mx=5 -y | Out-Null
Say ("publish.7z  {0:N2} MB" -f ((Get-Item $pkg).Length / 1MB))

# =============================================================================
Head '4/7  makemica 生成安装器骨架'
$json = Join-Path $SetupDir 'micasetup.json'
# 显式 UTF-8 读写（PS 5.1 的 Get-Content -Raw 会按 ANSI 读，中文会乱）
$cfg = [IO.File]::ReadAllText($json, [Text.Encoding]::UTF8) | ConvertFrom-Json
# makemica 只接受纯数字版本（传 0.0.1-beta 会静默失败、payload 打不进去）；
# 带 -beta 后缀的展示版本仍在程序集信息与 Release 标签里。
$VersionForMica = ($Version -replace '-.*$', '')
$cfg.Version   = $VersionForMica
$cfg.AppName   = $AppName
$cfg.KeyName   = 'VRChatTool'          # makemica 只接受 ASCII，中文在第 5 步改写
$cfg.ExeName   = $ExeName
$cfg.Publisher = $Publisher
$cfg.Output    = "./$OutName"
$cfg.Template  = (Join-Path $MicaTools 'template\default.7z')
[IO.File]::WriteAllText($json, ($cfg | ConvertTo-Json -Depth 6), $Utf8NoBom)

& $Makemica $json 2>&1 | Select-String -Pattern 'ERR:' | Select-Object -First 5 | ForEach-Object { Warn $_.Line }
if (-not (Test-Path $DistDir)) { throw 'makemica 没有生成 .dist' }
Say '.dist 已生成'

# ---------------------------------------------------------------------------
# ★ C# 14 语法兜底（VS 2022 也能编）★
#   makemica 2.5.x 生成的 .dist 里有「null 条件赋值」：`x?.Prop = v;`
#   这是 C# 14 特性，只有 VS 2026 的 Roslyn 5.x 能编；VS 2022 会报 CS8652。
#   编译前把这种写法改写成等价的 if 包裹 —— 两种工具链都能过，
#   也让「没有 VS 2026 的机器」不用再卡在这一步（ISSUES #11 验证过这条路）。
# ---------------------------------------------------------------------------
$c14 = 0
Get-ChildItem $DistDir -Recurse -Filter *.cs -File -ErrorAction SilentlyContinue | ForEach-Object {
    $t = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
    if ($t -notmatch '\?\.\w+\s*=') { return }
    $n = [regex]::Replace($t, '(?m)^(\s*)([A-Za-z_][A-Za-z0-9_\.\[\]]*)\?\.([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;]+);',
                          '${1}if (${2} != null) ${2}.${3} = ${4};')
    if ($n -ne $t) {
        [IO.File]::WriteAllText($_.FullName, $n, (New-Object Text.UTF8Encoding($true)))
        $k = ([regex]::Matches($t, '\?\.\w+\s*=')).Count
        $c14 += $k
        Say ("  C#14 改写 {0} 处: {1}" -f $k, $_.Name)
    }
}
if ($c14 -gt 0) { Say ("C#14 语法共改写 $c14 处（兼容 VS 2022）") }

# ---------------------------------------------------------------------------
# ★ .NET Framework 目标版本自适应 ★
#   makemica 生成的是 net472。如果这台机器只装了 4.8 开发包（没有 4.7.2），
#   dotnet msbuild 会直接 MSB3644「找不到 v4.7.2 的引用程序集」。
#   4.8 是 Win10 1803+ 自带，重定向过去不影响目标机；反之不重定向就编不了。
# ---------------------------------------------------------------------------
$refRoot = 'C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework'
if ((Test-Path $refRoot) -and -not (Test-Path (Join-Path $refRoot 'v4.7.2')) -and (Test-Path (Join-Path $refRoot 'v4.8'))) {
    $rt = 0
    Get-ChildItem $DistDir -Recurse -Filter *.csproj -File | ForEach-Object {
        $t = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8)
        if ($t.Contains('<TargetFramework>net472</TargetFramework>')) {
            [IO.File]::WriteAllText($_.FullName,
                $t.Replace('<TargetFramework>net472</TargetFramework>', '<TargetFramework>net48</TargetFramework>'),
                (New-Object Text.UTF8Encoding($true)))
            $rt++
            Say ("  目标框架 net472 → net48: " + $_.Name)
        }
    }
    if ($rt -gt 0) { Say '本机没有 4.7.2 开发包，已重定向到 net48（Win10 1803+ 自带）' }
}

# =============================================================================
Head '5/7  改写源码（程序集信息 + 安装目录名）'
$pairs = @(
    # 程序集属性
    @('[assembly: AssemblyTitle("MicaApp Setup")]',        "[assembly: AssemblyTitle(`"$AppName 安装程序`")]"),
    @('[assembly: AssemblyTitle("MicaApp Uninst")]',       "[assembly: AssemblyTitle(`"$AppName 卸载程序`")]"),
    @('[assembly: AssemblyProduct("MicaApp")]',            "[assembly: AssemblyProduct(`"$AppName`")]"),
    @('[assembly: AssemblyDescription("MicaApp Setup")]',  "[assembly: AssemblyDescription(`"$AppName 安装程序 - 免代理直连 VRChat`")]"),
    @('[assembly: AssemblyDescription("MicaApp Uninst")]', "[assembly: AssemblyDescription(`"$AppName 卸载程序`")]"),
    @('[assembly: AssemblyCompany("Lemutec")]',            "[assembly: AssemblyCompany(`"$Publisher`")]"),
    @('[assembly: AssemblyCopyright("Under MIT License. Copyright (c) Lemutec Contributors.")]',
      "[assembly: AssemblyCopyright(`"Copyright (c) $Publisher`")]"),
    # option.*（KeyName 在这里改成中文 → 安装目录跟着变）
    @('option.KeyName = "VRChatTool";',  "option.KeyName = `"$InstallFolder`";"),
    @('option.Publisher = "VRChat-Tool";', "option.Publisher = `"$Publisher`";"),
    @('option.AppName = "VRChat优选工具";', "option.AppName = `"$AppName`";"),
    @('option.ExeName = "VRChat优选工具.exe";', "option.ExeName = `"$ExeName`";")
)

foreach ($f in @('Program.cs', 'Program.un.cs')) {
    $fp = Join-Path $DistDir $f
    if (-not (Test-Path $fp)) { continue }
    $t = [IO.File]::ReadAllText($fp, [Text.Encoding]::UTF8)
    foreach ($pr in $pairs) { $t = $t.Replace($pr[0], $pr[1]) }
    [IO.File]::WriteAllText($fp, $t, (New-Object Text.UTF8Encoding($true)))
    $left = @(Select-String -Path $fp -Pattern 'MicaApp|Lemutec' -EA SilentlyContinue)
    $kn   = (Select-String -Path $fp -Pattern 'option\.KeyName' -EA SilentlyContinue | Select-Object -First 1).Line.Trim()
    Say ("{0,-16} 残留 MicaApp/Lemutec: {1}   {2}" -f $f, $left.Count, $kn)
    if ($left.Count -gt 0) { $left | ForEach-Object { Warn "  行 $($_.LineNumber): $($_.Line.Trim())" } }
}

# =============================================================================
Head '5.5/7  注入环境检测 + 组件下载'
Copy-Item (Join-Path $SetupDir '.inject\EnvCheckHelper.cs') `
          (Join-Path $DistDir 'Helper\Setup\EnvCheckHelper.cs') -Force
Say 'EnvCheckHelper.cs → .dist\Helper\Setup\'

$vm = Join-Path $DistDir 'ViewModels\Inst\InstallViewModel.cs'
# 统一成 \n 再比较，否则 \r\n 的文件永远匹配不到 \n 的锚点
$vt = [IO.File]::ReadAllText($vm, [Text.Encoding]::UTF8).Replace("`r`n", "`n")

$anchor = @'
                using Stream uninstStream = ResourceHelper.GetStream("pack://application:,,,/MicaSetup;component/Resources/Setups/Uninst.exe");
                InstallHelper.CreateUninst(uninstStream);
'@.Replace("`r`n", "`n").Trim("`n")

$inject = @'
                using Stream uninstStream = ResourceHelper.GetStream("pack://application:,,,/MicaSetup;component/Resources/Setups/Uninst.exe");
                InstallHelper.CreateUninst(uninstStream);

                // ============================================================
                // 环境检测 + 依赖组件自动下载
                //   主程序是自包含 .NET 8，不需要系统装运行时；
                //   真正需要的是 winws.exe / WinDivert 这套加速组件。
                //   原始来源在 GitHub，部分网络下直连不稳，所以按镜像列表依次尝试。
                // ============================================================
                try
                {
                    ApplicationDispatcherHelper.BeginInvoke(() =>
                    {
                        InstallProgress = 0;
                        InstallInfo = "正在检测运行环境…";
                    });

                    string envReport = EnvCheckHelper.DescribeEnvironment();
                    foreach (string line in envReport.Split(new char[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                    {
                        Logger.Information("[Env] " + line);
                    }

                    string toolsDir = Path.Combine(Option.Current.InstallLocation, "tools");

                    bool componentsOk = EnvCheckHelper.EnsureComponents(
                        toolsDir,
                        (progress, message) =>
                        {
                            ApplicationDispatcherHelper.BeginInvoke(() =>
                            {
                                InstallProgress = progress;
                                InstallInfo = message;
                            });
                        },
                        s => Logger.Information("[Env] " + s));

                    if (!componentsOk)
                    {
                        Logger.Warning("[Env] 加速组件下载失败，主程序仍会装好，首次运行时程序内会自动重试");
                    }
                }
                catch (Exception envEx)
                {
                    Logger.Error(envEx);
                }
'@.Replace("`r`n", "`n").Trim("`n")

if ($vt.Contains($anchor)) {
    $vt = $vt.Replace($anchor, $inject)
    [IO.File]::WriteAllText($vm, $vt.Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding($true)))
    Say 'InstallViewModel.cs 已注入环境检测 + 下载步骤'
} else {
    Warn 'InstallViewModel.cs 未匹配到注入点！'
    Say ("  锚点前 80 字符: " + $anchor.Substring(0, [Math]::Min(80, $anchor.Length)))
}

# =============================================================================
Head '5.6/7  注入卸载器的系统清理'
# 为什么必须注入：MicaSetup 原生卸载器只做一件事 —— 把安装目录整个删掉。
# 但本工具在系统里还留了三样东西，而且顺序关键：
#   1) hosts 里的 *.vrchat.com 指向块  ← hosts.original 备份就存在
#      <安装目录>\data\ 里，会被一起删掉，所以**必须在删目录之前**还原
#   2) VRChatBypass 服务
#   3) winws.exe 进程 + WinDivert 内核驱动
# 不清理的后果：用户卸载后 hosts 仍指向旧 IP、winws 可能还在跑、驱动残留。
$un = Join-Path $DistDir 'Helper\Setup\UninstallHelper.cs'
if (-not (Test-Path $un)) { throw "找不到 UninstallHelper.cs: $un" }

$unAnchor = @'
        if (Option.Current.CloseApplications.Length > 0)
        {
            CloseApplicationHelper.CloseApplications();
        }
'@.Replace("`r`n", "`n").Trim("`n")

$unInject = @'
        if (Option.Current.CloseApplications.Length > 0)
        {
            CloseApplicationHelper.CloseApplications();
        }

        // ============================================================
        // 【构建期注入】卸载前的系统清理（见 build-installer.ps1 的 5.6/7 步）
        //
        // MicaSetup 原生卸载器只做一件事：把安装目录整个删掉。
        // 本工具在系统里还留了三样东西，而且顺序关键：
        //   1) hosts 里的 *.vrchat.com 指向块 —— hosts.original 备份就存在
        //      <安装目录>\data\ 里，会被一起删掉，所以必须在删目录之前还原
        //   2) VRChatBypass 服务
        //   3) winws.exe 进程 + WinDivert 内核驱动
        // 不清理的后果：用户卸载后 hosts 仍指向旧 IP、winws 可能还在跑、驱动残留。
        // 全程 try/catch —— 任何一步失败都不该让卸载本身失败。
        // ============================================================
        void __run(string __file, string __args)
        {
            try
            {
                System.Diagnostics.ProcessStartInfo __psi =
                    new System.Diagnostics.ProcessStartInfo(__file, __args);
                __psi.UseShellExecute = false;
                __psi.CreateNoWindow = true;
                System.Diagnostics.Process __p = System.Diagnostics.Process.Start(__psi);
                if (__p != null) { __p.WaitForExit(8000); }
            }
            catch { }
        }

        try
        {
            string __root = Option.Current.InstallLocation;
            string __bak = "";
            if (!string.IsNullOrEmpty(__root))
            {
                string __a = Path.Combine(__root, "data", "hosts.original");
                if (File.Exists(__a)) { __bak = __a; }
            }
            if (string.IsNullOrEmpty(__bak))
            {
                // 备用位置：安装目录被搬过 / 被手工删过时的兜底
                string __p = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    "VRChatTool", "hosts.original");
                if (File.Exists(__p)) { __bak = __p; }
            }
            if (!string.IsNullOrEmpty(__bak))
            {
                try
                {
                    if (progressCallback != null) { progressCallback(0.05, "正在把 hosts 还原成安装前的样子…"); }
                    string __hosts = Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.System),
                        @"drivers\etc\hosts");
                    File.Copy(__bak, __hosts, true);
                }
                catch { }
            }

            try
            {
                if (progressCallback != null) { progressCallback(0.10, "正在停止并删除 VRChatBypass 服务…"); }
                __run("sc.exe", "stop VRChatBypass");
                __run("sc.exe", "delete VRChatBypass");
            }
            catch { }

            try
            {
                if (progressCallback != null) { progressCallback(0.15, "正在停止并删除 WinDivert 驱动…"); }
                __run("sc.exe", "stop WinDivert");
                __run("sc.exe", "delete WinDivert");
            }
            catch { }

            try { __run("taskkill.exe", "/F /IM winws.exe"); } catch { }
        }
        catch { }
'@.Replace("`r`n", "`n").Trim("`n")

$ut = [IO.File]::ReadAllText($un, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
if ($ut.Contains($unAnchor)) {
    [IO.File]::WriteAllText($un, $ut.Replace($unAnchor, $unInject).Replace("`n", "`r`n"), (New-Object Text.UTF8Encoding($true)))
    Say 'UninstallHelper.cs 已注入 hosts 还原 + 服务/驱动清理'
} else {
    Warn 'UninstallHelper.cs 未匹配到注入点！'
    Say ("  锚点前 80 字符: " + $unAnchor.Substring(0, [Math]::Min(80, $unAnchor.Length)))
}

# =============================================================================
Head '6/7  编译 + 签名 卸载器 / 安装器'
$built  = Join-Path $DistDir 'bin\Release\MicaSetup.exe'
$uninst = Join-Path $DistDir 'Resources\Setups\Uninst.exe'

# .dist 是 SDK 风格工程（Microsoft.NET.Sdk）。两条路都试过：
#   · VS 的 MSBuild：如果那台机器的 VS 没装「.NET SDK」组件，会 MSB4236（找不到 Microsoft.NET.Sdk）
#   · dotnet msbuild：只要装了 .NET SDK 就能解析 SDK，最稳
# 所以这里用 dotnet msbuild（$Dotnet 在 0/7 已经确认可用），并在编译前 restore。
function Invoke-DistBuild {
    param([string]$Project)
    & $Dotnet restore $Project --nologo -v quiet 2>&1 | Out-Null
    & $Dotnet msbuild $Project /p:Configuration=Release /v:quiet /nologo 2>&1 | Out-Null
}

Invoke-DistBuild (Join-Path $DistDir 'MicaSetup.Uninst.csproj')
if (-not (Test-Path $built)) { throw 'Uninst 编译失败' }
Sign-File $built
Copy-Item $built $uninst -Force
Say ("Uninst.exe → Resources\Setups\  {0:N0} KB" -f ((Get-Item $uninst).Length / 1KB))

Invoke-DistBuild (Join-Path $DistDir 'MicaSetup.csproj')
if (-not (Test-Path $built)) { throw 'Setup 编译失败' }
Sign-File $built

$final = Join-Path $SetupDir $OutName
Copy-Item $built $final -Force

# =============================================================================
Head '7/7  结果'
$vi  = (Get-Item $final).VersionInfo
$sig = Get-AuthenticodeSignature $final
Say ("文件           : {0}" -f $final)
Say ("大小           : {0:N2} MB" -f ((Get-Item $final).Length / 1MB))
Say ("ProductName    : {0}" -f $vi.ProductName)
Say ("FileDescription: {0}" -f $vi.FileDescription)
Say ("CompanyName    : {0}" -f $vi.CompanyName)
Say ("FileVersion    : {0}" -f $vi.FileVersion)
Say ("LegalCopyright : {0}" -f $vi.LegalCopyright)
Say ("签名状态       : {0}" -f $sig.Status)
Say ("签名者         : {0}" -f $sig.SignerCertificate.Subject)
Say ("默认安装到     : {0}\{1}" -f $env:ProgramFiles, $InstallFolder)
Say ("配套证书       : {0}" -f $Cer)

# ---- 交付校验和（D8）：让用户能自己验证拿到的 exe 有没有被中间人改过 ----
try {
    $sumFile = Join-Path $SetupDir 'SHA256SUMS.txt'
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# VRChat优选工具 交付校验和")
    $lines.Add("# 生成时间: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add("# 校验方法: Get-FileHash <文件名> -Algorithm SHA256  ，比对本文件里的大小写不敏感值")
    $lines.Add("")
    foreach ($item in @($final, $Cer, $appExe)) {
        if (Test-Path $item) {
            $h = (Get-FileHash $item -Algorithm SHA256).Hash.ToLower()
            $n = Split-Path $item -Leaf
            $s = (Get-Item $item).Length
            $lines.Add(("{0}  {1}  {2}" -f $h, $s.ToString().PadLeft(12), $n))
        }
    }
    $lines.Add("")
    $lines.Add("# 说明：")
    $lines.Add("#   · 安装包是自签名证书签的，能去掉「未知发布者」但去不掉 SmartScreen 提示。")
    $lines.Add("#   · 想完全静默需要把 vrctool-codesign.cer 导入「受信任的根证书颁发机构」。")
    $lines.Add("#   · 加速组件（winws.exe / WinDivert / cygwin1.dll）的哈希锁在安装器里，")
    $lines.Add("#     下载时会逐个校验 SHA256，见 wpf\setup\.inject\EnvCheckHelper.cs 的 KnownSha256。")
    [IO.File]::WriteAllLines($sumFile, $lines, (New-Object Text.UTF8Encoding($true)))
    Say ("校验和文件     : {0}" -f $sumFile)
} catch {
    Warn ("生成 SHA256SUMS.txt 失败: " + $_.Exception.Message)
}
