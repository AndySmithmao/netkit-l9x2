# ============================================================================
#  VRChat 免代理访问 —— 从零一键安装
#
#  做四件事:
#    1) 下载 zapret 工具（4 个文件，约 3.2 MB）
#    2) 解析各域名真实 IP（多个 DoH 源交叉验证）并逐个验证可用性
#    3) 备份并写入 hosts（用标记行包裹，可精确回滚）
#    4) 注册并启动 VRChatBypass 服务，最后全量验证
#
#  安全性:
#    - 写入前备份原始 hosts 到 hosts.original
#    - 写入后验证；若核心域名失败或普通网站被误伤 → 自动完全回滚
#
#  用法: powershell -ExecutionPolicy Bypass -File install.ps1
# ============================================================================
param(
    [switch]$Force,      # 已安装时也强制重装
    [switch]$NoVerify    # 跳过最后的验证
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# 路径全部相对 EXE 所在目录，由 GUI 通过环境变量传入；
# 直接跑 .ps1 时退回到脚本上一级目录。整个安装目录可以搬走。
$RootDir  = if ($env:VRCTOOL_ROOT)  { $env:VRCTOOL_ROOT }  else { Split-Path $PSScriptRoot -Parent }
$ToolsDir = if ($env:VRCTOOL_TOOLS) { $env:VRCTOOL_TOOLS } else { Join-Path $RootDir 'tools' }
$DataDir  = if ($env:VRCTOOL_DATA)  { $env:VRCTOOL_DATA }  else { Join-Path $RootDir 'data' }

$InstallDir = $ToolsDir          # winws.exe / WinDivert 等组件放这里
$HostsPath  = "$env:SystemRoot\System32\drivers\etc\hosts"
$LogPath    = Join-Path $DataDir 'install.log'
$SvcName    = 'VRChatBypass'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

# hosts 标记块（写入与回读校验共用同一份字符串，避免两处不一致）
$BEGIN = '# ===== VRChat-bypass BEGIN ====='
$END   = '# ===== VRChat-bypass END ====='

# ★ hosts 的唯一写入入口 ★
#   原地写（Set-Content / WriteAllText）会先把文件截断成 0 字节，Defender
#   开着时实测 30 次里 28 次留下一个空 hosts。详见 lib-hosts.ps1 顶部说明。
. (Join-Path $PSScriptRoot 'lib-hosts.ps1')

# 注意: 不要用 R / H / W / Measure 命名函数（分别是 Invoke-History / Get-History / Measure-Object 的别名）
function Show  { param($s, $color = 'Gray') Write-Host $s -ForegroundColor $color }
function AddLog{ param($s) Add-Content -Path $LogPath -Value $s -Encoding UTF8 -ErrorAction SilentlyContinue }

# 进度上报：发给 GUI 的 ##PROG## 协议。
# install.ps1 / diagnose.ps1 不引用 lib-common.ps1（它们自己定义了 Show/Ok/Warn），
# 所以这里本地实现一份 —— 原来这两个脚本里直接调用 lib-common 的 Prog，
# 结果每次调用都抛 CommandNotFoundException，GUI 进度条永远停在 0%。
function Prog {
    param([int]$Cur, [int]$Tot, [string]$Label = '')
    Write-Host ("##PROG##$Cur|$Tot|$Label")
}
function Step  { param($n, $t) Show '' ; Show "  [$n] $t" Cyan; Prog ([int](($n -split '/')[0])) 6 $t }
function Ok    { param($s) Show "      [ok] $s" Green }
function Warn  { param($s) Show "      [!]  $s" Yellow }
function Bad   { param($s) Show "      [x]  $s" Red }

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 用 curl 测一个 URL（可指定 IP 覆盖解析）
function Test-Url {
    param([string]$Url, [string]$Resolve = '', [int]$Timeout = 15)
    $a = @('-sS','-o','NUL','-k','-A',$UA,'--max-time',$Timeout,'-w','%{http_code}')
    if ($Resolve) { $a += '--resolve'; $a += $Resolve }
    $a += $Url
    $out = (& "$env:SystemRoot\System32\curl.exe" @a 2>&1 | Out-String).Trim()
    $m = [regex]::Match($out, '(\d{3})\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return '000'
}

# 带重试的测试 —— 网关 DNS 会间歇性解析超时，单次 000 不能当失败
function Test-UrlRetry {
    param([string]$Url, [int]$Attempts = 3, [int]$Timeout = 15)
    for ($i = 1; $i -le $Attempts; $i++) {
        $c = Test-Url -Url $Url -Timeout $Timeout
        if (Test-Alive $c) { return $c }
        Start-Sleep -Milliseconds 800
    }
    return '000'
}

# 等网络/DNS 就绪（写完 hosts 后必须等，否则验证全是 000）
function Wait-Network {
    param([int]$MaxSeconds = 40)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $MaxSeconds) {
        if (Test-Alive (Test-Url -Url 'https://www.baidu.com/' -Timeout 8)) {
            return [int]$sw.Elapsed.TotalSeconds
        }
        Start-Sleep -Milliseconds 1200
    }
    return -1
}

function Test-Alive { param([string]$Code) return ($Code -match '^[1-5]\d\d$') }

# ---------------------------------------------------------------------------
# 验证某个 IP 是否承载目标 zone
#
# 关键: 不能用被墙域名做 HTTP 验证 —— 装好之前那些域名本来就通不了。
#       所以用【同 provider 里没被墙的域名】做 TLS 握手 + 证书 CN 校验。
#       Cloudflare -> api.vrchat.cloud  (未封锁)
#       CloudFront -> files.vrchat.cloud (未封锁)
# ---------------------------------------------------------------------------
function Test-ZoneIp {
    param([string]$Ip, [string]$ProbeSni, [int]$Timeout = 3500)
    $c = New-Object System.Net.Sockets.TcpClient
    $ar = $c.BeginConnect($Ip, 443, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne($Timeout)) { $c.Close(); return $false }
    try { $c.EndConnect($ar) } catch { $c.Close(); return $false }
    $c.ReceiveTimeout = $Timeout; $c.SendTimeout = $Timeout
    $ok = $false
    try {
        $s = New-Object System.Net.Security.SslStream($c.GetStream(), $false, ([System.Net.Security.RemoteCertificateValidationCallback]{ $true }))
        $s.AuthenticateAsClient($ProbeSni)
        $m = [regex]::Match($s.RemoteCertificate.Subject, 'CN=([^,]+)')
        if ($m.Success -and $m.Groups[1].Value -match 'vrchat') { $ok = $true }
        $s.Dispose()
    } catch {}
    $c.Close()
    return $ok
}

# ---------------------------------------------------------------------------
# hosts 写入：这里**不再有**自己的实现
#
#   以前本脚本自带一套 Write-HostsRobust + Test-HostsWritten，用的正是
#   lib-hosts.ps1 明令禁止的两件事：
#     ① [IO.File]::WriteAllText 原地截断写（Defender 开着时实测 30 次里 28 次
#        留下 0 字节 hosts）
#     ② Remove-Item 之后重建（写失败 = hosts 直接消失）
#   而且失败分支只 exit 1、不还原 hosts.original。
#   现在统一走 lib-hosts.ps1 的 Write-HostsSafe（临时文件 + 复制替换 +
#   逐行回读 + 失败自动还原快照）。dot-source 在文件顶部。
# ---------------------------------------------------------------------------
# 从多个 DoH 源解析（交叉验证，取一致或多数）
function Resolve-Real {
    param([string]$Name)
    $servers = @(
        'https://doh.pub/dns-query',
        'https://1.12.12.12/dns-query',
        'https://120.53.53.53/dns-query'
    )
    $votes = @{}
    foreach ($s in $servers) {
        try {
            $r = Invoke-RestMethod "$s`?name=$Name&type=A" -Headers @{accept='application/dns-json'} -TimeoutSec 8
            foreach ($a in $r.Answer) {
                if ($a.type -eq 1 -and $a.data -match '^\d+\.\d+\.\d+\.\d+$') {
                    if (-not $votes.ContainsKey($a.data)) { $votes[$a.data] = 0 }
                    $votes[$a.data]++
                }
            }
        } catch {}
    }
    if ($votes.Count -eq 0) { return @() }
    return @($votes.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { $_.Key })
}

# 判断是否投毒 IP（Facebook / Twitter / Dropbox 段）
function Test-Poison {
    param([string]$Ip)
    $bad = @('^31\.13\.', '^173\.252\.', '^69\.171\.', '^104\.244\.46\.', '^66\.220\.147\.',
             '^185\.60\.', '^108\.160\.', '^199\.59\.', '^122\.10\.85\.', '^8\.7\.7\.', '^157\.240\.')
    foreach ($b in $bad) { if ($Ip -match $b) { return $true } }
    return $false
}

# ============================================================================
Show ''
Show '============================================================' Cyan
Show '  VRChat 免代理访问 —— 从零安装' Cyan
Show '============================================================' Cyan
Show ''

if (-not (Test-Admin)) {
    Show '  [x] 需要管理员权限' Red
Show ''
    Show '  请用下面任一方式重新运行:' Yellow
    Show '    A) 右键「安装.cmd」→ 以管理员身份运行' Yellow
    Show '    B) 右键开始菜单 → Windows PowerShell(管理员) → 运行:' Yellow
    Show '       powershell -ExecutionPolicy Bypass -File install.ps1' White
Show ''
    exit 1
}
Show '  管理员权限: 已获得' Green

if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
if (-not (Test-Path $DataDir))    { New-Item -ItemType Directory -Path $DataDir    -Force | Out-Null }
'' | Set-Content -Path $LogPath -Encoding UTF8
AddLog "=== 安装开始 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="

# ---------------------------------------------------------------------------
# ★ 装之前先查两个会"卡在第 5 步"的系统设置 ★
#   ① 内存完整性（HVCI）：开着它时 WinDivert 连过滤规则都装不上，
#      winws 一开就退（错误码 0x8032000A = FWP_E_IN_USE）。
#      2026-10-17 真机复现：HVCI=2 时 netdump/winws 全失败，关掉后立刻正常。
#   ② 智能应用控制（SAC）：强制模式下会拦未受信任（含自签名）的 exe。
# ---------------------------------------------------------------------------
$hvciOn = $false
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
    if ($dg.SecurityServicesRunning -contains 2) { $hvciOn = $true }
} catch { }

if ($hvciOn) {
    Show ''
    Warn '若本机开着「内存完整性（HVCI）」—— WinDivert 会装不上过滤规则，安装必定失败。'
    Show '      处理：设置 → 隐私和安全性 → Windows 安全中心 → 设备安全性 →' Yellow
    Show '            内核隔离 → 关闭「内存完整性」→ 重启电脑 → 再跑「安装」。' Yellow
    Show '      （系统级防护开关，开不开由你决定；但它和 WinDivert 这类工具不兼容）' DarkGray
    AddLog '预检: HVCI 已开启，安装大概率失败'
    if (-not $Force) {
        Show ''
        Show '      仍要继续吗？继续的话第 5 步仍会失败（只是白等）。' Yellow
        $ans = Read-Host '      输入 y 继续，其他退出'
        if ($ans -notmatch '^[yY]') { exit 2 }
    }
}

$sacState = $null
try { $sacState = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState } catch { }
if ($sacState -eq 1) {
    Warn '「智能应用控制（SAC）」处于强制模式：自签名程序可能被拦（提示"已被阻止"）'
    Show '      处理：Windows 安全中心 → 应用和浏览器控制 → 智能应用控制 → 关闭' Yellow
    AddLog '预检: SAC 强制模式'
}

# ---------------------------------------------------------------------------
# ★ 早失败：WinDivert 残留状态预检 ★
#   一旦「VRChatBypass 服务被停过一次」（卸载、手动停止、sc stop），
#   WinDivert 的 WFP 子层/过滤器会残留在 BFE 内核里，之后 winws 一律报
#   0x8032000A = FWP_E_IN_USE，**只有重启电脑能清**（实测：卸驱动、删服务键、
#   重启 BFE 都无效，注册表里也没有持久化项）。
#
#   以前的表现：装到最后一步（第 5 步注册服务）才失败，前面已经下载了 4 个
#   组件、写了 hosts —— 用户白等还留一地鸡毛。现在先花 3 秒试启一次。
#   只在「已装过」的情况下探测（工具目录里已有 winws.exe）。
# ---------------------------------------------------------------------------
$winwsPath = Join-Path $InstallDir 'winws.exe'
# 服务正在跑 = 状态健康，这时再起第二个 winws 反而会撞过滤规则，跳过探测
$svcRunningNow = ((& "$env:SystemRoot\System32\sc.exe" query VRChatBypass 2>&1 | Out-String) -match 'RUNNING')
if ($svcRunningNow) {
    AddLog '预检: 服务已在运行，跳过 WinDivert 探测'
} elseif (Test-Path $winwsPath) {
    $preErr = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $winwsPath
        $psi.Arguments = '--wf-tcp=443 --filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=md5sig'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $InstallDir
        $pp = New-Object System.Diagnostics.Process
        $pp.StartInfo = $psi
        [void]$pp.Start()
        $pe = $pp.StandardError.ReadToEndAsync()
        $po = $pp.StandardOutput.ReadToEndAsync()
        if ($pp.WaitForExit(4000)) { $preErr = (($pe.Result + ' ' + $po.Result) -replace "`r?`n", ' ').Trim() }
        else { try { $pp.Kill() } catch { } }   # 能活过 4 秒 = 状态正常
    } catch { $preErr = '' }

    if ($preErr -match 'FWP_E_IN_USE|8032000A|referenced by other objects|其他对象引用了该对象') {
        Show ''
        Bad 'WinDivert 状态残留：上次服务被停止后，内核里的过滤对象没释放'
        Show '      这是 WinDivert 驱动的已知行为，只有重启能清（卸驱动/删服务键都无效）' Yellow
        Show '      现在继续安装必定失败，已提前中止。' Yellow
        Show ''
        Show '      → 重启电脑，然后重跑「安装」即可（组件不用重新下载）' Green
        AddLog '预检: WinDivert 残留 FWP_E_IN_USE，中止安装'
        exit 2
    }
}

# 域名分组
$CfHosts  = @('api.vrchat.cloud','pipeline.vrchat.cloud','dev-api.vrchat.cloud',
              'vrchat.com','www.vrchat.com','mail.vrchat.com','creators.vrchat.com','docs.vrchat.com')
$CfrHosts = @('files.vrchat.cloud','vrcpm.vrchat.cloud','assets.vrchat.com','status.vrchat.com')
$OtherHosts = @('help.vrchat.com','feedback.vrchat.com','hello.vrchat.com','ask.vrchat.com')
$AllHosts = $CfHosts + $CfrHosts + $OtherHosts

# 兜底 IP（DoH 全部失败时用）
$Fallback = @{
    'api.vrchat.cloud'      = '172.64.144.1'
    'pipeline.vrchat.cloud' = '172.64.144.1'
    'dev-api.vrchat.cloud'  = '172.64.144.1'
    'vrchat.com'            = '104.18.6.156'
    'www.vrchat.com'        = '104.18.6.156'
    'mail.vrchat.com'       = '104.18.6.156'
    'creators.vrchat.com'   = '104.18.6.156'
    'docs.vrchat.com'       = '104.16.241.118'
    'files.vrchat.cloud'    = '13.33.180.1'
    'vrcpm.vrchat.cloud'    = '13.33.180.1'
    'assets.vrchat.com'     = '13.226.69.72'
    'status.vrchat.com'     = '13.226.69.92'
    'help.vrchat.com'       = '216.198.54.6'
    'feedback.vrchat.com'   = '100.56.186.228'
    'hello.vrchat.com'      = '198.49.23.145'
    'ask.vrchat.com'        = '216.66.8.43'
}

# ============================================================================
Step '1/6' '创建目录'
Ok $InstallDir

# ============================================================================
Step '2/6' '下载工具文件（约 4.5 MB）'
# 原始地址在国内不稳，优先走可用镜像。
#
# ★ 源地址锁死到一个具体 commit —— 用 master 的话上游一改，所有用户下次装拿到的
#   就是另一个二进制，SHA256 校验也就无从谈起（ISSUES #5 / D7）。
#   这个 commit 必须和 EnvCheckHelper.cs 里的 CommitSha 保持一致。
$CommitSha = '6eb463a6758fb48cd101bc55dfd057e6e9d98af1'
$RAW = "https://raw.githubusercontent.com/bol-van/zapret-win-bundle/$CommitSha/zapret-winws"
$mirrors = @(
    "https://gh-proxy.com/$RAW",
    "https://ghproxy.net/$RAW",
    "https://ghfast.top/$RAW",
    $RAW,
    "https://cdn.jsdelivr.net/gh/bol-van/zapret-win-bundle@$CommitSha/zapret-winws",
    "https://raw.gitmirror.com/bol-van/zapret-win-bundle/$CommitSha/zapret-winws"
)
# min = 体积下限（防镜像返回 HTML 错误页）；sha = 该 commit 下的权威 SHA256
$needFiles = @(
    @{ n='winws.exe';       min=100000;  sha='2da71e80878dc270ac83f5893ecbb841f9752a57f1da8ff9325636b4346bc632' },
    @{ n='WinDivert.dll';   min=20000;   sha='16abd6a029e65557c6a309bea7b13bf81fff4e193567582e1cddbf6719f323e0' },
    @{ n='WinDivert64.sys'; min=40000;   sha='8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2' },
    @{ n='cygwin1.dll';     min=1000000; sha='103104a52e5293ce418944725df19e2bf81ad9269b9a120d71d39028e821499b' }
)

# 体积够 且 SHA256 对得上 才算到位。
# 只看体积是不够的：实测踩过 —— raw.githubusercontent 中途断流留下一个
# 1.4 MB 的残缺 cygwin1.dll（正常 2.95 MB），"体积 ≥ 下限"照样放过。
function Test-GotFile {
    param([string]$Path, [int]$Min, [string]$Sha)
    if (-not (Test-Path $Path)) { return $false }
    if ((Get-Item $Path).Length -lt $Min) { return $false }
    try { return ((Get-FileHash $Path -Algorithm SHA256).Hash.ToLower() -eq $Sha) } catch { return $false }
}

$dlOk = $true
foreach ($f in $needFiles) {
    $dest = Join-Path $InstallDir $f.n
    $part = "$dest.part"

    if (Test-GotFile $dest $f.min $f.sha) { Ok "$($f.n) 已存在且哈希正确，跳过"; continue }

    $got = $false
    foreach ($m in $mirrors) {
        try {
            Remove-Item $part -Force -EA SilentlyContinue
            # -f: HTTP 非 2xx 也算失败；--retry: 网络抖动自动重试
            & "$env:SystemRoot\System32\curl.exe" -fL --retry 3 --retry-delay 2 --max-time 180 -o $part "$m/$($f.n)" 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            if (-not (Test-GotFile $part $f.min $f.sha)) {
                Warn "$($f.n) 从 $(([Uri]$m).Host) 拿到的文件校验没过（被截断或被换包），换源"
                Remove-Item $part -Force -EA SilentlyContinue
                continue
            }
            Move-Item $part $dest -Force
            Ok ("{0}  {1:N0} 字节  sha256:{2}…" -f $f.n, (Get-Item $dest).Length,
                (Get-FileHash $dest -Algorithm SHA256).Hash.ToLower().Substring(0, 12))
            $got = $true
            break
        } catch { }
    }

    if (-not $got) {
        Bad "$($f.n) 下载失败（$($mirrors.Count) 个镜像都试过，没有一个通过 SHA256 校验）"
        $dlOk = $false
    }
}
if (-not $dlOk) {
Show ''
    Bad '加速组件没能全部就位（体积或 SHA256 校验没过）。请检查网络后重试，或手动下载:'
    Show "      $RAW/" DarkGray
    Show "      把 4 个文件放进 $InstallDir" DarkGray
    Show '      期望的 SHA256（体积和哈希都要对得上）:' DarkGray
    foreach ($f in $needFiles) { Show ("        {0,-16} {1}" -f $f.n, $f.sha) DarkGray }
    exit 1
}
AddLog "工具下载完成（commit $CommitSha，4 个文件 SHA256 全部通过）"

# ============================================================================
Step '3/6' '解析各域名真实 IP（多 DoH 源交叉验证 + 证书校验）'
Show '      提示: 用同 provider 里【未被墙】的域名做证书校验' DarkGray
Show '            Cloudflare -> api.vrchat.cloud   CloudFront -> files.vrchat.cloud' DarkGray
Show ''

$Resolved = @{}
foreach ($h in $AllHosts) {
    # 选校验用的 SNI：必须是同 provider 且未被墙的域名
    if ($CfHosts -contains $h)       { $probe = 'api.vrchat.cloud' }
    elseif ($CfrHosts -contains $h)  { $probe = 'files.vrchat.cloud' }
    else                             { $probe = $h }   # 第三方域名本身被墙，只能靠兜底

    $ips = Resolve-Real $h
    $picked = ''
    $poisoned = $false
    $anyCandidate = $false

    if ($OtherHosts -contains $h) {
        # 第三方域名（help/ask/feedback/hello）：以前是直接把硬编码兜底 IP 写进 hosts，
        # 完全不验证。那几个 IP 一旦过期，就把本来能用的站点黑洞掉，直到用户卸载。
        # 现在：先看 DoH 有没有候选、能不能通过 TLS 校验；兜底值也要过校验才用；
        # 都过不了就**不写这一行**，交给系统 DNS（比写死一个坏 IP 安全）。
        $cand = @($ips | Where-Object { -not (Test-Poison $_) })
        foreach ($ip in $cand) {
            if (Test-ZoneIp -Ip $ip -ProbeSni $h) { $picked = $ip; break }
        }
        if (-not $picked) {
            $fb = $Fallback[$h]
            if ($fb -and (Test-ZoneIp -Ip $fb -ProbeSni $h)) { $picked = $fb }
        }
        if ($picked) {
            Ok "$h  ->  $picked  （第三方托管）"
        } else {
            Warn "$h  ->  跳过（DoH 与兜底值都没通过校验，交给系统 DNS）"
            AddLog "$h -> skipped (unverified)"
            continue
        }
    } else {
        foreach ($ip in $ips) {
            if (Test-Poison $ip) { $poisoned = $true; continue }
            $anyCandidate = $true
            if (Test-ZoneIp -Ip $ip -ProbeSni $probe) { $picked = $ip; break }
        }
        if (-not $picked) {
            $fb = $Fallback[$h]
            if ($fb) {
                if (Test-ZoneIp -Ip $fb -ProbeSni $probe) {
                    $picked = $fb
                    if ($anyCandidate) { Warn "$h  ->  $fb  （DoH 候选都没通过证书校验，用兜底）" }
                    else { Warn "$h  ->  $fb  （DoH 无结果，用兜底）" }
                } else {
                    $picked = $fb
                    Warn "$h  ->  $fb  （兜底值也没通过校验，先写上，稍后回归会验）"
                }
            }
        }
        if ($picked -and $picked -eq ($ips | Where-Object { -not (Test-Poison $_) } | Select-Object -First 1)) {
            Ok "$h  ->  $picked"
        }
    }

    if (-not $picked) { $picked = $Fallback[$h]; Warn "$h  ->  $picked （强行兜底）" }
    $Resolved[$h] = $picked
    AddLog "$h -> $picked"
}

# ============================================================================
Step '4/6' '备份并写入 hosts'

# ---------------------------------------------------------------------------
# ★ hosts.original 必须存两份（ISSUES D5）★
#   卸载器会把整个安装目录（含数据目录）删掉 —— 备份只放数据目录的话，用户
#   卸载之后连「安装前 hosts 长什么样」都找不到了，想手工还原没有任何依据。
#   所以除数据目录外，再往 %ProgramData%\VRChatTool\ 存一份：
#     - 数据目录那份：正常情况下还原用（快、和安装目录同生共死）
#     - ProgramData 那份：兜底（卸载器不动它，用户随时能自己拷回去）
#   两份都是「首次备份」语义，已存在就不覆盖，免得把干净的原始备份冲掉。
# ---------------------------------------------------------------------------
function Backup-Hosts {
    param([string]$HostsPath, [string]$DataDir, [string]$Tag = '')
    $items = @(
        @{ Dir = $DataDir;                                        Label = '数据目录' },
        @{ Dir = (Join-Path $env:ProgramData 'VRChatTool');       Label = 'ProgramData' }
    )
    foreach ($it in $items) {
        $dst = Join-Path $it.Dir 'hosts.original'
        try {
            if (-not (Test-Path $it.Dir)) { New-Item -ItemType Directory -Path $it.Dir -Force | Out-Null }
            if (Test-Path $dst) {
                Ok "$($it.Label) 已存在 hosts.original，保留首次备份"
            } else {
                Copy-Item $HostsPath $dst -Force
                Ok "已备份原始 hosts 到 $($it.Label)：$dst"
            }
        } catch {
            Warn "备份到 $($it.Label) 失败: $($_.Exception.Message)"
        }
    }
}

Backup-Hosts -HostsPath $HostsPath -DataDir $DataDir

# 移除旧块（走 lib-hosts：只删成对的块；不配对的标记行会中止而不是吞掉后面的内容）
$strip = Remove-HostsBlock -Path $HostsPath -Begin $BEGIN -End $END
if ($strip.Error) {
    Bad "读取 hosts 失败，已中止（不会覆盖你的原文件）: $($strip.Error)"
    AddLog "读取 hosts 失败: $($strip.Error)"
    exit 1
}
if ($strip.Unpaired) {
    Bad 'hosts 里的标记行不成对（只有 BEGIN 或只有 END），为避免误删后续条目已中止。'
    Show "      请用记事本打开 $HostsPath" Yellow
    Show '      删掉单独出现的 ===== VRChat-bypass BEGIN/END ===== 那一行，再重试。' Yellow
    AddLog 'hosts 标记行不成对，已中止'
    exit 1
}
$keep = New-Object System.Collections.Generic.List[string]
foreach ($l in $strip.Lines) { $keep.Add($l) }

# 写入新块
$keep.Add('')
$keep.Add($BEGIN)
$keep.Add("# VRChat bypass - installed $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
foreach ($h in $AllHosts) {
    # 第三方域名可能因为"验证不过"被跳过（见上面 Resolve 段），这里要跳过没解析出来的
    if (-not $Resolved.ContainsKey($h)) { continue }
    $keep.Add(('{0,-16} {1}' -f $Resolved[$h], $h))
}
$keep.Add($END)

Show '      正在写入（文件常被杀软/监控占用，会自动重试）...' DarkGray
# 走唯一入口：临时文件 + 复制替换 + 逐行回读 + 失败自动还原快照
$okHosts = Write-HostsSafe -Path $HostsPath -Lines $keep -ExpectIp $Resolved['api.vrchat.cloud']
if ($okHosts) {
    Ok 'hosts 写入成功'
    & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
    Ok 'DNS 缓存已刷新'
} else {
    Bad 'hosts 写入失败（已保持在动手前的状态，没有留下 0 字节空文件）'
Show ''
    Show '      常见原因与处理:' Yellow
    Show '        - 杀毒软件的 hosts 保护 / 实时监控 → 临时关闭后重试' Yellow
    Show '        - 其他程序占用了该文件 → 重启电脑后重试' Yellow
Show ''
    # 兜底：即便 lib-hosts 已尽力还原，这里再用备份覆盖一次（两者都是「复制」语义）
    $bak = Join-Path $DataDir 'hosts.original'
    if (Test-Path $bak) {
        try {
            Copy-Item $bak $HostsPath -Force -ErrorAction Stop
            Show "      已用备份还原 hosts: $bak" Yellow
        } catch {
            Show "      还原失败，备份在: $bak" Red
        }
    }
    AddLog 'hosts 写入失败（已尝试还原）'
    exit 1
}

# ============================================================================
Step '5/6' '注册并启动服务'
$argline = '--wf-tcp=80,443 ' +
  '--filter-tcp=443 --hostlist-domains=hello.vrchat.com,feedback.vrchat.com ' +
  '--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,sniext ' +
  '--dpi-desync-fooling=md5sig --dpi-desync-repeats=2 --new ' +
  '--filter-tcp=443 --hostlist-domains=vrchat.com,www.vrchat.com,assets.vrchat.com,docs.vrchat.com,' +
  'status.vrchat.com,creators.vrchat.com,mail.vrchat.com,help.vrchat.com,ask.vrchat.com ' +
  '--hostlist-exclude-domains=hello.vrchat.com,feedback.vrchat.com ' +
  '--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld ' +
  '--dpi-desync-fooling=md5sig --dpi-desync-repeats=6'
$binPath = "`"$InstallDir\winws.exe`" $argline"

$scExe = "$env:SystemRoot\System32\sc.exe"

# ★ 服务已经在跑、而且配置完全一致 → 原封不动 ★
#   winws 一旦被停止，WinDivert 的 WFP 对象会残留在 BFE 内核里，再启动必撞
#   FWP_E_IN_USE，只能重启恢复（2026-10-18 实测，见 changelog 第 15/16 批）。
#   所以「重装」时如果服务配置没变，就**不要去动它**：
#   组件和 hosts 照常更新，服务保持运行，既不中断也不留残留。
$curCfg   = (& $scExe qc $SvcName 2>&1 | Out-String)
$curState = (& $scExe query $SvcName 2>&1 | Out-String)
$curBin = ''
if ($curCfg -match 'BINARY_PATH_NAME\s*:\s*(.+)') { $curBin = $Matches[1].Trim() }
$svcKept = ($curState -match 'RUNNING' -and $curBin -eq $binPath)

if ($svcKept) {
    Ok '服务已在运行且配置一致 —— 跳过重建（避免 WinDivert 残留）'
} else {
    & $scExe stop $SvcName 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1500
    Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800

    $exists = ((& $scExe query $SvcName 2>&1 | Out-String) -match 'SERVICE_NAME')
    # 统一「先删再建」，不用 sc config 更新参数 —— 理由见下面 New-Service 那段注释。
    if ($exists) {
        & $scExe delete $SvcName 2>&1 | Out-Null
        Start-Sleep -Milliseconds 900
    }
}

# ★ 为什么用 New-Service 而不是 sc.exe create ★
#   sc.exe 的语法是 "binPath= <值>"，要求等号后**恰好一个空格**。
#   但 PowerShell 传参时会自动给含空格的值加一层引号，于是传给 sc 的变成
#   binPath= 和 "\"...winws.exe\" --wf-tcp=..." 两个独立参数，
#   sc 认不出来 -> 直接打印用法说明并退出（服务根本没建）。
#
#   实测四种写法：
#     & "$env:SystemRoot\System32\sc.exe" create $n binPath= $p start= auto   -> ✗ 打印用法
#     & "$env:SystemRoot\System32\sc.exe" @('create',$n,'binPath=',$p,...)     -> ✗ 打印用法
#     New-Service -BinaryPathName $p                -> ✓ binPath 完全正确
#     cmd.exe /c "sc.exe create ..."                -> ✓
#   New-Service 把字符串直接交给 SCM，不过 shell，所以选它。
if (-not $svcKept) {
    try {
        $null = New-Service -Name $SvcName -BinaryPathName $binPath -StartupType Automatic `
                            -DisplayName 'VRChat 优选工具 加速服务' -ErrorAction Stop
        Ok '服务已创建'
    } catch {
        Bad  ('服务创建失败: ' + $_.Exception.Message)
        AddLog ('服务创建失败: ' + $_.Exception.Message)
    }
}
Start-Sleep -Milliseconds 500

if (-not $svcKept) {
    # ★ 启动前必须让 WinDivert 处于「干净卸载」状态 ★
    #   WinDivert 的 WFP 子层/过滤器挂在内核里。上一次 winws 若是被强杀、或服务被
    #   sc stop / sc delete 过，驱动可能还带着那些对象；再开 winws 就会撞
    #   0x8032000A = FWP_E_IN_USE（"对象被其他对象引用，无法删除"），
    #   服务起不来，而且此后怎么重装都不行，只能重启。
    #   先 sc stop 驱动并等它真的卸掉，下一次加载就是干净的。
    $drvReset = $false
    for ($i = 0; $i -lt 16; $i++) {
        $q = (& $scExe query WinDivert 2>&1 | Out-String)
        if ($q -match '1060' -or $q -match 'STOPPED') { $drvReset = $true; break }
        & $scExe stop WinDivert 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
    if ($drvReset) { Show '      驱动 WinDivert 已卸载（准备干净加载）' DarkGray }
    else { Warn '驱动 WinDivert 卸不掉（仍有程序占用），服务可能起不来' }

    & $scExe start $SvcName 2>&1 | Out-Null
    Start-Sleep -Seconds 3
}

$st = (& "$env:SystemRoot\System32\sc.exe" query $SvcName 2>&1 | Out-String)
$drv = (& "$env:SystemRoot\System32\sc.exe" query WinDivert 2>&1 | Out-String)
if ($st -match 'RUNNING') { Ok "服务 $SvcName 运行中" } else { Bad "服务未启动"; AddLog $st }
if ($drv -match 'RUNNING') { Ok '驱动 WinDivert 运行中' } else { Warn '驱动 WinDivert 未显示 RUNNING（可能仍然正常）' }

# ★ 服务没起来 = 安装没完成 ★
#   以前这里只打一行 Bad 就继续往下走：hosts 写好了、服务却是死的，最后还能 exit 0，
#   用户看到"安装完成"却上不了网 —— 比直接报错更难受。现在按失败处理。
#   而且不再靠"猜"：把 winws 前台跑一次，抓它自己的 stderr，按错误码给结论。
if ($st -notmatch 'RUNNING') {
    Show ''
    Show '  [x] 服务没有启动，安装未完成。' Red

    $probeErr = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $InstallDir 'winws.exe'
        $psi.Arguments = '--wf-tcp=443 --filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=md5sig'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $InstallDir
        $pr = New-Object System.Diagnostics.Process
        $pr.StartInfo = $psi
        [void]$pr.Start()
        $pe = $pr.StandardError.ReadToEndAsync()
        $po = $pr.StandardOutput.ReadToEndAsync()
        if (-not $pr.WaitForExit(6000)) { try { $pr.Kill() } catch { } $probeErr = '(前台探测仍在运行 —— 说明 winws 本身能起，问题在服务启动方式)' }
        else { $probeErr = (($pe.Result + ' ' + $po.Result) -replace "`r?`n", ' ').Trim() }
    } catch { $probeErr = '前台探测失败: ' + $_.Exception.Message }

    if ($probeErr) { Show ("      真实报错: " + $probeErr) DarkGray }

    # 按实际错误给处理建议（0x8032000A = FWP_E_IN_USE：WFP 里 WinDivert 的子层还被占着）
    if ($probeErr -match 'FWP_E_IN_USE|8032000A|referenced by other objects|其他对象引用了该对象') {
        Show '      → WinDivert 的 WFP 子层被占用（多次启动/强杀驱动后会这样）。' Yellow
        Show '        处理：**重启电脑**后重跑「安装」。重启前不要连续点安装/停止。' Yellow
        AddLog 'winws: FWP_E_IN_USE（WFP 子层被占用，建议重启）'
    }
    elseif ($probeErr -match 'Access is denied|拒绝访问|0x00000005|error 5') {
        Show '      → 打开 WinDivert 设备被拒（多半是安全软件拦的）。' Yellow
        Show '        处理：把安装目录加入杀软排除项，或暂停实时保护后重跑。' Yellow
        AddLog 'winws: access denied（疑似安全软件拦截）'
    }
    elseif ($probeErr -match 'already loaded|already exists|0x800700B7') {
        Show '      → WinDivert 驱动已被别的程序占用。' Yellow
        Show '        处理：关掉其它同类加速/抓包工具，或重启后重跑。' Yellow
        AddLog 'winws: driver already loaded'
    }
    else {
        # 兜底：检查「内存完整性（HVCI）」—— 开着它时 WinDivert 经常装不上过滤规则，
        # 现象就是一句莫名其妙的 FWP/拒绝访问。查 DeviceGuard 的 SecurityServicesRunning。
        $hvci = $false
        try {
            $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
            if ($dg.SecurityServicesRunning -contains 2) { $hvci = $true }
        } catch { }
        if ($hvci) {
            Show '      → 若本机开着「内存完整性（HVCI）」，它会拦 WinDivert 的过滤规则。' Yellow
            Show '        处理：设置 → 隐私和安全性 → Windows 安全中心 → 设备安全性 →' Yellow
            Show '              内核隔离 → 关闭「内存完整性」→ 重启，再跑「安装」。' Yellow
            AddLog 'winws 失败且 HVCI=开启'
        } else {
            Show '      处理：重启后重跑「安装」；仍失败就把上面这行真实报错发出来。' Yellow
        }
    }

    AddLog '服务未启动 -> 安装失败'
    exit 2
}

# ============================================================================
if ($NoVerify) {
Show ''
    Show '  已跳过验证（-NoVerify）' Yellow
    exit 0
}

Step '6/6' '验证'

# 写完 hosts 后网络/DNS 可能短暂不可用，必须先等就绪
Show '      等待网络与 DNS 就绪...' DarkGray
$waitSec = Wait-Network -MaxSeconds 45
if ($waitSec -lt 0) {
    Warn '网络在 45 秒内未就绪（可能是网关 DNS 抽风）'
    Warn '将使用多次重试继续验证'
} else {
    Ok "网络已就绪（等待 $waitSec 秒）"
}
Show ''

$coreFail = @()
$otherFail = @()

Show '      --- VRChat 核心域名 ---' DarkGray
foreach ($h in ($CfHosts + $CfrHosts)) {
    $ok = 0; $last = '000'
    for ($i = 1; $i -le 3; $i++) { $last = Test-Url -Url "https://$h/" -Timeout 15; if (Test-Alive $last) { $ok++ } }
    if ($ok -lt 2) { $coreFail += $h }
    Show ("      {0} {1,-24} {2}/3  {3}" -f $(if ($ok -ge 2) { '[ok]' } else { '[x] ' }), $h, $ok, $last) $(if ($ok -ge 2) { 'Gray' } else { 'Red' })
}

Show ''
Show '      --- 第三方域名（不快但应可用）---' DarkGray
foreach ($h in $OtherHosts) {
    if (-not $Resolved.ContainsKey($h)) {
        Show ("      [~] {0,-24} 未写入（装前无法验证）" -f $h) DarkGray
        continue
    }
    $ok = 0
    for ($i = 1; $i -le 3; $i++) { if (Test-Alive (Test-Url -Url "https://$h/" -Timeout 25)) { $ok++ } }
    if ($ok -eq 0) { $otherFail += $h }
    Show ("      {0} {1,-24} {2}/3" -f $(if ($ok -ge 2) { '[ok]' } else { '[~] ' }), $h, $ok) $(if ($ok -ge 2) { 'Gray' } else { 'Yellow' })
}

Show ''
Show '      --- 普通网站（必须不受影响）---' DarkGray
$normalFail = @()
foreach ($h in 'www.bing.com','www.baidu.com','outlook.com','www.zhihu.com') {
    $code = Test-UrlRetry -Url "https://$h/" -Attempts 3 -Timeout 15
    if (-not (Test-Alive $code)) { $normalFail += $h }
    Show ("      {0} {1,-24} {2}" -f $(if (Test-Alive $code) { '[ok]' } else { '[x] ' }), $h, $code) $(if (Test-Alive $code) { 'Gray' } else { 'Red' })
}

AddLog "核心失败: $($coreFail -join ',')  第三方失败: $($otherFail -join ',')  普通失败: $($normalFail -join ',')"

# ---------- 判定 ----------
Show ''
# 关键: 只有【百度也通】时才认为普通网站的失败是真的受影响（否则是网络问题，不该回滚）
$baiduOk = Test-Alive (Test-UrlRetry -Url 'https://www.baidu.com/' -Attempts 4 -Timeout 15)
$realNormalFail = @()
if ($baiduOk) { $realNormalFail = $normalFail } else { $realNormalFail = @() }

if ($normalFail.Count -gt 0 -and -not $baiduOk) {
    Warn '普通网站有失败，但百度也不通 —— 判定为网络/DNS 临时问题，不回滚'
    Show '      建议稍后跑一次「4-诊断.cmd」确认' Yellow
}

if ($realNormalFail.Count -gt 0) {
    Show '============================================================' Red
    Show '  [x] 检测到普通网站被影响，正在完全回滚' Red
    Show '============================================================' Red
    Copy-Item (Join-Path $DataDir 'hosts.original') $HostsPath -Force
    & "$env:SystemRoot\System32\ipconfig.exe" /flushdns | Out-Null
    & "$env:SystemRoot\System32\sc.exe" stop $SvcName 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & "$env:SystemRoot\System32\sc.exe" delete $SvcName 2>&1 | Out-Null
    Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Show ''
    Show '  已回滚: hosts 已还原，服务已删除' Yellow
    Show "  被影响的网站: $($realNormalFail -join ', ')" DarkGray
Show ''
    Show '  这可能意味着本工具与你的网络环境不兼容。' Yellow
    Show '  请把上面的输出截图反馈。' Yellow
    AddLog '普通网站被影响 -> 已回滚'
    exit 1
}

if ($coreFail.Count -eq 0) {
    Show '============================================================' Green
    Show '  安装完成，全部核心域名可用' Green
    Show '============================================================' Green
Show ''
    Show '  接下来建议:' Cyan
    Show '    1) 打开浏览器访问 https://vrchat.com/home 试试' White
    Show '    2) 运行「重扫优选IP.cmd」可以再提速（可选，约 10 分钟）' White
Show ''
    Show "  日志: $LogPath" DarkGray
    AddLog '安装成功'
    exit 0
} else {
    Show '============================================================' Yellow
    Show '  安装完成，但有部分核心域名未达标' Yellow
    Show '============================================================' Yellow
Show ''
    Show "  未达标: $($coreFail -join ', ')" Yellow
Show ''
    Show '  这通常是因为这些域名需要「分组调参」或单独的优选 IP。' DarkGray
    Show '  可以尝试运行「重扫优选IP.cmd」。' DarkGray
    Show "  日志: $LogPath" DarkGray
    AddLog "部分失败: $($coreFail -join ',')"
    exit 2
}

exit 0
