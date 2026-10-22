# ============================================================================
#  公共库 —— 被其他脚本 dot-source 使用
#  提供: 常量 / 域名分组 / 输出辅助 / C# 探测内核 / 延迟与测速 / hosts 读写
# ============================================================================

$script:LibVersion = '1.0'

# ---------------------------------------------------------------- 路径
# 全部相对于 EXE 所在目录，由 GUI 通过环境变量传入。
# 直接双击 .cmd 跑时（没有环境变量）退回到脚本所在目录的上一级。
$script:RootDir = if ($env:VRCTOOL_ROOT) { $env:VRCTOOL_ROOT } else { Split-Path $PSScriptRoot -Parent }
$script:ToolsDir = if ($env:VRCTOOL_TOOLS) { $env:VRCTOOL_TOOLS } else { Join-Path $script:RootDir 'tools' }

# 数据目录（缓存）：安装目录下的 data\
$script:InstallDir = if ($env:VRCTOOL_DATA) { $env:VRCTOOL_DATA } else { Join-Path $script:RootDir 'data' }

$script:HostsPath  = "$env:SystemRoot\System32\drivers\etc\hosts"
$script:UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

$script:FileScanCf   = Join-Path $script:InstallDir 'full-scan-cloudflare.csv'
$script:FileScanCfr  = Join-Path $script:InstallDir 'full-scan-cloudfront.csv'
$script:FileLatency  = Join-Path $script:InstallDir 'latency-result.csv'
$script:FileSpeed    = Join-Path $script:InstallDir 'speed-result.csv'
$script:FilePool     = Join-Path $script:InstallDir 'pool-state.json'

if (-not (Test-Path $script:InstallDir)) { New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null }

# ---------------------------------------------------------------- 域名分组
$script:CF_GROUP = @(
    @{ H='api.vrchat.cloud';      D='游戏主 API（登录 / 账号 / 房间）' }
    @{ H='pipeline.vrchat.cloud'; D='内容流水线' }
    @{ H='dev-api.vrchat.cloud';  D='开发 API' }
    @{ H='vrchat.com';            D='官网' }
    @{ H='www.vrchat.com';        D='官网' }
    @{ H='mail.vrchat.com';       D='邮件服务' }
    @{ H='creators.vrchat.com';   D='创作者中心' }
    @{ H='docs.vrchat.com';       D='官方文档' }
)
$script:CFR_GROUP = @(
    @{ H='files.vrchat.cloud';    D='游戏内容 CDN（资源 / 模型下载）' }
    @{ H='vrcpm.vrchat.cloud';    D='包管理' }
    @{ H='assets.vrchat.com';     D='游戏资源 CDN（SDK / 更新）' }
    @{ H='status.vrchat.com';     D='服务状态页' }
)
$script:THIRD_GROUP = @(
    @{ H='help.vrchat.com';       D='帮助中心（Zendesk）' }
    @{ H='ask.vrchat.com';        D='社区论坛（Discourse）' }
    @{ H='feedback.vrchat.com';   D='反馈板（Canny）' }
    @{ H='hello.vrchat.com';      D='营销首页（Squarespace）' }
)

# 测速基准
$script:SPEED_TARGET = @{
    A = @{ Sni='docs.vrchat.com';               Path='/' }
    B = @{ Sni='d14hwloucscbyy.cloudfront.net'; Path='/sdk/VRCSDK2-2022.04.20.16.27_Public.unitypackage' }
}
$script:PROBE_SNI = @{ A='api.vrchat.cloud'; B='files.vrchat.cloud' }

# ---------------------------------------------------------------- 输出辅助
function Show { param($s, $c = 'Gray') Write-Host $s -ForegroundColor $c }
function Head { param($s) Write-Host ''; Write-Host "  $s" -ForegroundColor Cyan }
function Rule { param($ch = '=')
    # GUI 模式下不输出 ASCII 分隔线（难看）
    if (Test-Gui) { return }
    Write-Host ("  " + ($ch * 94)) -ForegroundColor DarkGray
}

# 是否运行在 GUI 里（输出被重定向）
function Test-Gui {
    if (-not $script:__guiKnown) {
        $script:__guiKnown = $true
        try { $script:__gui = [Console]::IsOutputRedirected } catch { $script:__gui = $false }
    }
    return $script:__gui
}
function Ok   { param($s) Write-Host "      [ok] $s" -ForegroundColor Green }
function Warn { param($s) Write-Host "      [!]  $s" -ForegroundColor Yellow }
function Bad  { param($s) Write-Host "      [x]  $s" -ForegroundColor Red }

function Format-Eta {
    param([int]$Sec)
    if ($Sec -lt 60) { return "$Sec 秒" }
    return "$([int]($Sec/60)) 分 $($Sec % 60) 秒"
}

# ---------------------------------------------------------------- 进度输出
# 控制台：用 \r 覆盖同一行（好看）
# 被重定向（GUI / 管道 / 写文件）：输出完整行，否则读不到、要等下一个换行才吐
$script:__progLast = 0

function Progress {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [int]$MinIntervalMs = 900,     # 重定向时的最小输出间隔，避免刷屏
        [switch]$Force                 # 强制立刻输出（阶段结束/重要节点）
    )

    if (-not $script:__progRedir) {
        $script:__progRedir = $true
        try { $script:__progOutRedirected = [Console]::IsOutputRedirected }
        catch { $script:__progOutRedirected = $false }
    }

    if ($script:__progOutRedirected) {
        $now = [DateTime]::Now.Ticks / 10000
        if ($Force -or ($now - $script:__progLast) -ge $MinIntervalMs) {
            $script:__progLast = $now
            Write-Host "      $Text"
        }
    } else {
        Write-Host ("`r" + $Text) -NoNewline
        if ($Force) { Write-Host '' }
    }
}

# 阶段分隔（重定向时也要换行，保证可见）
function Stage {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host ''
    Write-Host "      >> $Text" -ForegroundColor $Color
}

function Prop-Done {
    # 进度条收尾：控制台换行，重定向不用管
    if (-not $script:__progOutRedirected) { Write-Host '' }
}

# ---------------------------------------------------------------- 逐 IP 实时结果
# 输出结构化行，GUI 会把它分流到下方的「实时 IP 结果」表格，不混进普通日志。
# 前缀 ##IP## 后面用 | 分隔；控制台下也可见，方便排查。
#
# ★ 字段转义（ISSUES A16 / C-S9）★
#   协议是「##IP## + 字段用 | 分隔」，字段里一旦出现 | 就会串列。
#   最危险的是 Note：脚本自己拼的测速结果 / 证书 CN / 错误原因，内容完全不可控
#   （例如 curl 报错文本、证书 Subject 里的逗号与竖线）。所以所有字符串参数
#   统一过 Esc()：| → /，CR/LF → 空格，顺带干掉 Tab（会破坏列对齐）。
$script:IP_MARK = '##IP##'

function Esc {
    param([string]$s)
    if ($null -eq $s) { return '' }
    $t = $s -replace '\|', '/'          # 竖线是字段分隔符，必须换掉
    $t = $t -replace "`r", ' '          # 换行会让 GUI 把半行当新日志读
    $t = $t -replace "`n", ' '
    $t = $t -replace "`t", ' '          # Tab 会把表格列顶开
    return $t
}

function IpClear {
    # 清空 GUI 下方表格（每次开跑前调一次）
    Write-Host ($script:IP_MARK + 'CLR')
}

function IpTick {
    param(
        [string]$G,          # 组：A / B / CF / CFR / -
        [string]$Ip,
        [int]$Lat = -1,      # 本次延迟 ms，-1 = 失败
        [int]$Ok = 0,        # 累计成功次数
        [int]$Tot = 0,       # 累计总次数
        [int]$Med = -1,      # 当前中位
        [int]$Jit = -1,      # 当前抖动
        [string]$Note = ''   # 附加说明（如测速结果）
    )
    # 数值字段由 PowerShell 数字转字符串，天然不含 | 和换行
    Write-Host ($script:IP_MARK + (Esc $G) + '|' + (Esc $Ip) + '|' + $Lat + '|' + $Ok + '|' +
                $Tot + '|' + $Med + '|' + $Jit + '|' + (Esc $Note))
}

# ---------------------------------------------------------------- 进度事件
# 给 GUI 画进度条用。控制台下这些行也可见（简单文本），不影响使用。
$script:PROG_MARK = '##PROG##'
$script:STEP_MARK = '##STEP##'
$script:DONE_MARK = '##DONE##'

function Prog {
    param(
        [int]$Cur,           # 当前进度
        [int]$Tot,           # 总量
        [string]$Label = ''  # 显示文字
    )
    Write-Host ($script:PROG_MARK + $Cur + '|' + $Tot + '|' + (Esc $Label))
}

function Step {
    param(
        [int]$N,             # 第几步
        [int]$Tot,           # 共几步
        [string]$Name        # 步骤名
    )
    Write-Host ($script:STEP_MARK + $N + '|' + $Tot + '|' + (Esc $Name))
}

function Done {
    param(
        [string]$State = 'ok',   # ok / fail / cancel
        [string]$Msg = ''        # 结果说明
    )
    Write-Host ($script:DONE_MARK + (Esc $State) + '|' + (Esc $Msg))
}

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- C# 内核（只加载一次）
if (-not ([System.Management.Automation.PSTypeName]'VrcProbe').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net.Security;
using System.Net.Sockets;
using System.Threading;

public class VrcProbe {
    public string Ip; public int Tcp = -1; public int Tls = -1;
    public string Cn = ""; public bool Ok = false; public string Err = "";

    public static VrcProbe One(string ip, string sni, int timeoutMs) {
        var r = new VrcProbe { Ip = ip };
        var sw = Stopwatch.StartNew();
        try {
            using (var c = new TcpClient()) {
                var ar = c.BeginConnect(ip, 443, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs)) { r.Err = "tcp超时"; return r; }
                c.EndConnect(ar);
                r.Tcp = (int)sw.ElapsedMilliseconds;
                c.ReceiveTimeout = timeoutMs; c.SendTimeout = timeoutMs;
                using (var s = new SslStream(c.GetStream(), false,
                       new RemoteCertificateValidationCallback((a, b, cc, d) => true))) {
                    sw.Restart();
                    s.AuthenticateAsClient(sni);
                    r.Tls = (int)sw.ElapsedMilliseconds;
                    if (s.RemoteCertificate != null) r.Cn = s.RemoteCertificate.Subject;
                    r.Ok = (r.Cn.IndexOf("vrchat", StringComparison.OrdinalIgnoreCase) >= 0);
                }
            }
        } catch (Exception e) { r.Err = e.GetType().Name; }
        return r;
    }
}
public class VrcRate {
    private readonly double _rate; private readonly object _lk = new object();
    private double _tokens; private DateTime _last;
    public VrcRate(double perSecond) { _rate = perSecond; _tokens = perSecond; _last = DateTime.UtcNow; }
    public void Take() {
        while (true) {
            double waitMs;
            lock (_lk) {
                var now = DateTime.UtcNow;
                _tokens += (now - _last).TotalSeconds * _rate; _last = now;
                if (_tokens > _rate) _tokens = _rate;
                if (_tokens >= 1.0) { _tokens -= 1.0; return; }
                waitMs = (1.0 - _tokens) / _rate * 1000.0;
            }
            Thread.Sleep((int)Math.Max(1, Math.Min(500, waitMs)));
        }
    }
}
'@ -ErrorAction Stop
}

# ---------------------------------------------------------------- 延迟测量
# 对一组 IP 做多轮交替 TLS 握手，返回 @{ Ip -> ArrayList<VrcProbe> }
function Measure-Latency {
    param(
        [string[]]$Items,          # 格式 "IP|组"
        [int]$Rounds = 5,
        [int]$DelayMs = 200,
        [int]$Timeout = 4000,
        [switch]$Silent
    )
    $acc = @{}
    foreach ($it in $Items) {
        $ip = $it.Split('|')[0]
        $acc[$ip] = New-Object System.Collections.ArrayList
    }
    IpClear
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($r = 1; $r -le $Rounds; $r++) {
        foreach ($it in $Items) {
            $p = $it.Split('|')
            $ip = $p[0]; $g = $p[1]
            $sni = $script:PROBE_SNI[$g]
            $res = [VrcProbe]::One($ip, $sni, $Timeout)
            [void]$acc[$ip].Add($res)

            # ★ 每探完一个 IP 就汇报一次（GUI 下方表格实时更新）
            $done = @($acc[$ip] | Where-Object { $_.Tls -ge 0 } | ForEach-Object { $_.Tls } | Sort-Object)
            $okN = $done.Count
            $med = if ($okN) { $done[[int](($okN - 1) / 2)] } else { -1 }
            $jit = if ($okN) { $done[-1] - $done[0] } else { -1 }
            IpTick -G $g -Ip $ip -Lat $res.Tls -Ok $okN -Tot $acc[$ip].Count `
                   -Med $med -Jit $jit -Note "第 $r/$Rounds 轮"

            if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        }
        if (-not $Silent) {
            $el = [int]$sw.Elapsed.TotalSeconds
            $eta = [int]($el / $r * ($Rounds - $r))
            $tot = 0
            foreach ($k in $acc.Keys) { $tot += $acc[$k].Count }
            Progress ("轮 $r/$Rounds   已探测 $tot 次   已用 ${el}s   剩余约 $(Format-Eta $eta)") -MinIntervalMs 0 -Force
        }
    }
    if (-not $Silent) { Prop-Done }
    return $acc
}

function Stat-Latency {
    param($Probes)
    $v = @($Probes | Where-Object { $_.Tls -ge 0 } | ForEach-Object { $_.Tls } | Sort-Object)
    $fail = @($Probes | Where-Object { $_.Tls -lt 0 }).Count
    if ($v.Count -eq 0) {
        return @{ Med = 0; Min = 0; Max = 0; Jit = 0; Fail = $fail; OK = 0; Rate = 0 }
    }
    $med = $v[[int](($v.Count - 1) / 2)]
    $tot = $v.Count + $fail
    return @{
        Med = $med; Min = $v[0]; Max = $v[-1]; Jit = ($v[-1] - $v[0])
        Fail = $fail; OK = $v.Count; Rate = [int]($v.Count * 100 / $tot)
    }
}

# ---------------------------------------------------------------- 下载测速
function Measure-Speed {
    param([string]$Ip, [string]$Group, [int]$Limit = 8)
    $t = $script:SPEED_TARGET[$Group]
    $x = & "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $script:UA --max-time $Limit `
         --resolve "$($t.Sni):443:$Ip" -w '%{speed_download}|%{http_code}' `
         "https://$($t.Sni)$($t.Path)" 2>$null | Out-String
    $m = [regex]::Match($x.Trim(), '^([\d.]+)\|(\d{3})$')
    if ($m.Success -and $m.Groups[2].Value -ne '000') {
        return [math]::Round([double]$m.Groups[1].Value / 1024)
    }
    return 0
}

# ---------------------------------------------------------------- hosts 读写

# 标记块统一在这里定义，避免「写块的地方」和「校验块的地方」字符串不一致
# （ISSUES C-S10：以前校验靠一个容易撞车的裸字符串 VRChat-bypass）
$script:HostsBegin = '# ===== VRChat-bypass BEGIN ====='
$script:HostsEnd   = '# ===== VRChat-bypass END ====='

function Get-HostsIp {
    param([string]$HostName)
    $l = Get-Content $script:HostsPath -ErrorAction SilentlyContinue |
         Where-Object { $_ -match "^\s*\d+\.\d+\.\d+\.\d+\s+$([regex]::Escape($HostName))\s*$" } |
         Select-Object -First 1
    if ($l -and $l -match '^\s*(\d+\.\d+\.\d+\.\d+)') { return $matches[1] }
    return ''
}

function Get-HostsBlock {
    param([string]$HostName)
    # 允许行尾内联注释 / 一行多个域名。旧正则要求域名必须是行尾，
    # 于是 "1.2.3.4 api.vrchat.cloud # 备用" 会被漏掉 → 侧栏误判「未安装」。
    $re = '^\s*\d{1,3}(?:\.\d{1,3}){3}\s+' + [regex]::Escape($HostName) + '(?:\s|$)'
    $v = @(Get-Content $script:HostsPath -ErrorAction SilentlyContinue |
           Where-Object { $_ -match $re } |
           ForEach-Object { ($_ -split '\s+')[0] })
    return $v
}

# 回读校验：确认标记块真的存在，且包含指定 IP（ISSUES C-S10）
# 判定依据是「块存在」+「块内容 = 这次的 IP」，不再凭一个裸字符串猜。
function _AssertHostsWritten {
    param([string]$ExpectIp = '')
    $raw = ''
    try { $raw = [IO.File]::ReadAllText($script:HostsPath) } catch { return $false }
    if ([string]::IsNullOrEmpty($raw)) { return $false }
    if ($raw.IndexOf($script:HostsBegin, [StringComparison]::Ordinal) -lt 0) { return $false }
    if ($raw.IndexOf($script:HostsEnd,   [StringComparison]::Ordinal) -lt 0) { return $false }
    if ($ExpectIp) {
        # 二次确认：写进去的确实是这次要写的那个 IP
        return $raw.Contains($ExpectIp)
    }
    return $true
}

# ============================================================================
#  改 hosts 的唯一入口 —— 实现在 lib-hosts.ps1
#
#  lib-hosts.ps1 没有任何加载期副作用（不建目录、不 Add-Type、不输出握手），
#  所以 install.ps1 / uninstall.ps1 / pick-ip.ps1 那些自己定义了 Show/Ok/Warn
#  的脚本也能安全引用它 —— 不用把整个 lib-common 拖进去。
#
#  ★ 为什么绝不原地写 hosts ★
#     Set-Content / WriteAllText 都以 Create 模式打开文件，打开瞬间就把它截断成
#     0 字节。本机（Defender 实时+行为监控开着）实测连写 30 次有 28 次留下一个
#     0 字节的 hosts —— 用户原有条目全部丢失。详见 lib-hosts.ps1 顶部完整说明。
# ============================================================================
. (Join-Path $PSScriptRoot 'lib-hosts.ps1')

function Write-HostsRobust {
    param(
        [string[]]$Lines,
        [string]$ExpectIp = '',   # 本次要写入的 IP；传了就额外要求读回内容里含这个 IP
        [switch]$Quiet
    )
    return (Write-HostsSafe -Path $script:HostsPath -Lines $Lines -ExpectIp $ExpectIp -Quiet:$Quiet)
}

function Build-HostsLines {
    param([string]$IpA, [string]$IpB)
    $BEGIN = $script:HostsBegin
    $END   = $script:HostsEnd

    # 统一走 lib-hosts 的剥离逻辑：只删成对的块；读失败/标记不配对都返回
    # 错误或 Unpaired，由调用方中止，绝不把用户的条目当块内容吞掉。
    $strip = Remove-HostsBlock -Path $script:HostsPath -Begin $BEGIN -End $END
    if ($strip.Error -or $strip.Unpaired) {
        throw ('hosts 无法安全解析，已中止：' + $(if ($strip.Error) { $strip.Error } else { '标记行不成对' }))
    }
    $keep = New-Object System.Collections.Generic.List[string]
    foreach ($l in $strip.Lines) { $keep.Add($l) }

    $keep.Add(''); $keep.Add($BEGIN)
    $keep.Add("# picked $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
    foreach ($g in $script:CF_GROUP)  { if ($IpA) { $keep.Add(('{0,-16} {1}' -f $IpA, $g.H)) } }
    foreach ($g in $script:CFR_GROUP) { if ($IpB) { $keep.Add(('{0,-16} {1}' -f $IpB, $g.H)) } }
    foreach ($h in 'help.vrchat.com','feedback.vrchat.com','hello.vrchat.com','ask.vrchat.com') {
        $ip = Get-HostsIp $h
        if ($ip) { $keep.Add(('{0,-16} {1}' -f $ip, $h)) }
    }
    $keep.Add($END)
    return $keep
}

function Test-HostsApplied {
    param([string]$Ip)
    $v = @(Get-HostsBlock 'api.vrchat.cloud')
    if ($v.Count -gt 0 -and $v[0] -eq $Ip) { return $true }
    return $false
}

# ---------------------------------------------------------------- 候选池状态
function Save-PoolState {
    param([string]$Stage, [int]$Cf, [int]$Cfr)
    $o = [pscustomobject]@{
        Stage = $Stage
        CloudflareCount = $Cf
        CloudFrontCount = $Cfr
        Updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    $o | ConvertTo-Json | Set-Content $script:FilePool -Encoding UTF8
}
function Load-PoolState {
    if (Test-Path $script:FilePool) {
        try { return (Get-Content $script:FilePool -Raw | ConvertFrom-Json) } catch {}
    }
    return $null
}

# ============================================================================
#  协议版本握手（ISSUES C-S9）
#
#  为什么放在文件末尾：lib-common.ps1 是被别的脚本 dot-source 的，不是每个
#  脚本都走同一处入口。放在末尾就保证「任何 dot-source 了本库的脚本」在加载
#  完成的那一刻都已经握手过，不需要每个脚本自己记得输出这一行。
#
#  同一进程内只输出一次（$script:__helloDone 标志）：有些脚本会重复 dot-source
#  或嵌套调用，重复的握手行会让 EXE 重复弹警告。
#
#  EXE 侧约定（MainWindow.xaml.cs 的 OnLine）：
#    - 认识 "##HELLO##proto=1"        -> 正常，两者协议版本一致
#    - 不认识 / 没收到                 -> 进度条、实时表格会全部失灵，
#                                        EXE 会在日志区打红字警告
#                                        「脚本版本不匹配，请完全退出程序重开」
#    - 以后协议有破坏性改动就把 proto 加 1，EXE 侧比对不上同样告警。
# ============================================================================
# 没有这个标志就握手（用 $null -eq 判断，避免脚本开了 Set-StrictMode 后读未定义变量报错）
if ($null -eq $script:__helloDone) {
    $script:__helloDone = $true
    Write-Host '##HELLO##proto=1'
}

