# ============================================================================
#  VRChat 优选 —— 【全量】ICMP + TLS 扫描（抗风控版）
#
#  与 auto-optimize.ps1 的区别:
#     auto-optimize : ICMP 先过滤 → 只测 Top-N        （快，有盲区）
#     本脚本        : 对【全部候选】做 ICMP + TLS      （无盲区）
#
#  ★ 抗风控设计（重要）★
#     ① 全局令牌桶限速     —— 默认 30 次/秒（可用 -Rate 调）
#     ② 目标列表随机打乱   —— 避免连续打相邻网段
#     ③ 主机位随机化       —— 不再固定取 .1，消除规律性
#     ④ 低并发             —— 默认 24 线程
#     ⑤ 阶段间停顿         —— ICMP 和 TLS 之间歇一下
#     ⑥ 结果增量落盘       —— 中途中断不丢数据
#
#  用法:
#     powershell -ExecutionPolicy Bypass -File full-scan.ps1
#     powershell -ExecutionPolicy Bypass -File full-scan.ps1 -Group Cloudflare
#     powershell -ExecutionPolicy Bypass -File full-scan.ps1 -Rate 60 -Threads 48   # 想快一点
#     powershell -ExecutionPolicy Bypass -File full-scan.ps1 -Rate 15               # 想更保守
#
#  产出:
#     <数据目录>\full-scan-cloudflare.csv / full-scan-cloudfront.csv
#     <数据目录>\full-scan-<name>-top.txt            （TopN 纯 IP 清单）
# ============================================================================
param(
    [ValidateSet('Both','Cloudflare','CloudFront')]
    [string]$Group = 'Both',
    # ★ 必须 > 0 ★  Bucket 里 waitMs = (1-tokens)/rate，rate=0 会得到 Infinity，
    #   扫描会永久挂起（以前没校验，传错一个参数就得杀进程）。
    [ValidateRange(1, 1000)]
    [int]$Rate = 30,          # 全局每秒请求上限（抗风控核心参数）
    [ValidateRange(1, 128)]
    [int]$Threads = 24,       # 并发线程
    [ValidateRange(300, 30000)]
    [int]$Timeout = 2500,
    [ValidateRange(1, 1000)]
    [int]$TopN = 40,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# 路径相对 EXE 目录（GUI 通过环境变量传入）
$RootDir = if ($env:VRCTOOL_ROOT) { $env:VRCTOOL_ROOT } else { Split-Path $PSScriptRoot -Parent }
$DataDir = if ($env:VRCTOOL_DATA) { $env:VRCTOOL_DATA } else { Join-Path $RootDir 'data' }
if (-not $OutDir) { $OutDir = $DataDir }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# ★ 必须自己 dot-source lib-common ★
#   Prog / Progress / IpClear / IpTick / Warn / Prop-Done 全在 lib-common.ps1 里。
#
#   为什么不能指望调用方：all-in-one.ps1 是用
#       & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File full-scan.ps1
#   另起一个**新进程**来调这个脚本的（见 all-in-one.ps1 第 108 行），
#   新进程继承不到父进程的任何函数；GUI 的「全量扫描」页也是直接起进程跑它。
#
#   不自己加载的后果（实测踩过）：
#     Prog / Progress 未定义 → GUI 收不到 ##PROG## → 进度条永远 0%
#     IpClear / IpTick 未定义 → GUI 收不到 ##IP##   → IP 表永远空白
#   表现就是「跑了 24 分钟界面一动不动」，看着像卡死。
#
#   注意：要放在本脚本自己的 Show / Head 定义**之前**，
#         这样本脚本的同名函数才会覆盖 lib-common 的版本。
. (Join-Path $PSScriptRoot 'lib-common.ps1')

function Show { param($s, $c = 'Gray') Write-Host $s -ForegroundColor $c }
function Head { param($s) Show ''; Show "====  $s  ====" Cyan }

# ---------------------------------------------------------------------------
# C# 内核：令牌桶限速 + 并发探测
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Security;
using System.Net.Sockets;
using System.Threading;

// 全局令牌桶限速器
public class Bucket {
    private readonly double _rate;
    private readonly object _lk = new object();
    private double _tokens;
    private DateTime _last;
    public Bucket(double perSecond) {
        _rate = perSecond; _tokens = perSecond; _last = DateTime.UtcNow;
    }
    public void Take() {
        while (true) {
            double waitMs;
            lock (_lk) {
                var now = DateTime.UtcNow;
                _tokens += (now - _last).TotalSeconds * _rate;
                _last = now;
                if (_tokens > _rate) _tokens = _rate;
                if (_tokens >= 1.0) { _tokens -= 1.0; return; }
                waitMs = (1.0 - _tokens) / _rate * 1000.0;
            }
            Thread.Sleep((int)Math.Max(1, Math.Min(500, waitMs)));
        }
    }
}

public class Probe {
    public string Ip;
    public int Icmp = -1;
    public int Tcp  = -1;
    public int Tls  = -1;
    public string Cn  = "";
    public bool   Ok  = false;
    public string Err = "";

    public static Probe One(string ip, string sni, int timeoutMs) {
        var r = new Probe { Ip = ip };
        var sw = Stopwatch.StartNew();
        try {
            using (var c = new TcpClient()) {
                var ar = c.BeginConnect(ip, 443, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs)) { r.Err = "tcp-timeout"; return r; }
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

    // ------------------------------------------------------------------
    //  可轮询的批量执行器（PS 5.1 不能用脚本块回调，见下方长注释）
    // ------------------------------------------------------------------
    private static System.Collections.Concurrent.ConcurrentQueue<Probe> _q =
        new System.Collections.Concurrent.ConcurrentQueue<Probe>();
    private static volatile bool _done = true;
    private static int _icmpDone;
    private static int _icmpTotal;
    private static int[] _icmpResult;

    public static bool  Done      { get { return _done; } }
    public static int   IcmpDone  { get { return _icmpDone; } }
    public static int   IcmpTotal { get { return _icmpTotal; } }
    public static int[] IcmpResult{ get { return _icmpResult; } }

    // ★ 为什么不用 Action<Probe> 回调 ★
    //   PowerShell 5.1 的脚本块只能在自己的 Runspace 线程上执行；C# 在
    //   new Thread 里调用它会抛「此线程中没有可用于运行脚本的运行空间」，
    //   而外层 catch{} 会把这个异常吞掉 —— 于是扫描照跑、##IP##/##PROG##
    //   一条都发不出去，界面看起来完全卡死（实测复现过）。
    //   所以后台线程只跑 C#，结果进队列；PowerShell 主线程轮询并上报。
    public static void StartSweep(string[] ips, string sni, int timeoutMs, int threads, Bucket bucket) {
        _q = new System.Collections.Concurrent.ConcurrentQueue<Probe>();
        _done = false;
        var runner = new Thread(delegate() {
            try {
                int idx = -1;
                var workers = new Thread[threads];
                for (int w = 0; w < threads; w++) {
                    workers[w] = new Thread(delegate() {
                        int i;
                        while ((i = Interlocked.Increment(ref idx)) < ips.Length) {
                            bucket.Take();
                            Probe p = null;
                            try { p = One(ips[i], sni, timeoutMs); } catch { }
                            if (p != null) _q.Enqueue(p);
                        }
                    });
                    workers[w].IsBackground = true;
                    workers[w].Start();
                }
                foreach (var t in workers) t.Join();
            } finally { _done = true; }
        });
        runner.IsBackground = true;
        runner.Start();
    }

    // 取出最多 max 条已完成结果
    public static Probe[] Drain(int max) {
        var list = new List<Probe>();
        Probe p;
        while (list.Count < max && _q.TryDequeue(out p)) list.Add(p);
        return list.ToArray();
    }

    public static void StartIcmp(string[] ips, int timeoutMs, int threads, Bucket bucket) {
        _icmpTotal  = ips.Length;
        _icmpDone   = 0;
        _icmpResult = new int[ips.Length];
        _done = false;
        var runner = new Thread(delegate() {
            try {
                int idx = -1;
                var res = new int[ips.Length];
                var workers = new Thread[threads];
                for (int w = 0; w < threads; w++) {
                    workers[w] = new Thread(delegate() {
                        int i;
                        while ((i = Interlocked.Increment(ref idx)) < ips.Length) {
                            bucket.Take();
                            try {
                                using (var pg = new Ping()) {
                                    var rep = pg.Send(ips[i], timeoutMs);
                                    res[i] = (rep != null && rep.Status == IPStatus.Success)
                                             ? (int)rep.RoundtripTime : -1;
                                }
                            } catch { res[i] = -1; }
                            Interlocked.Increment(ref _icmpDone);
                        }
                    });
                    workers[w].IsBackground = true;
                    workers[w].Start();
                }
                foreach (var t in workers) t.Join();
                _icmpResult = res;
            } finally { _done = true; }
        });
        runner.IsBackground = true;
        runner.Start();
    }
}
'@ -ErrorAction Stop

# ---------------------------------------------------------------------------
# 工具
# ---------------------------------------------------------------------------
$rng = New-Object System.Random

# 随机打乱，避免连续打相邻网段
function Shuffle-Array {
    param([string[]]$In)
    $a = [string[]]$In.Clone()
    for ($i = $a.Length - 1; $i -gt 0; $i--) {
        $j = $rng.Next($i + 1)
        $tmp = $a[$i]; $a[$i] = $a[$j]; $a[$j] = $tmp
    }
    return $a
}

# 展开 CIDR，主机位随机化（不再是固定的 .1）
function Expand-Random {
    param([string[]]$Cidrs)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $Cidrs) {
        $p = $c.Split('/'); if ($p.Count -ne 2) { continue }
        $b = ([System.Net.IPAddress]::Parse($p[0])).GetAddressBytes()
        $base = [uint64]$b[0]*16777216 + [uint64]$b[1]*65536 + [uint64]$b[2]*256 + [uint64]$b[3]
        $pf = [int]$p[1]
        $n = if ($pf -ge 24) { 1 } else { [int]([uint64][math]::Pow(2, 32 - $pf) / 256) }
        for ($i = 0; $i -lt $n; $i++) {
            $net = $base + [uint64]($i * 256)
            # /24 内随机选一个主机位（2..254，避开网络地址和广播地址）
            $host_ = $rng.Next(2, 255)
            $v = $net + [uint64]$host_
            $out.Add("$([int](($v -shr 24) -band 255)).$([int](($v -shr 16) -band 255)).$([int](($v -shr 8) -band 255)).$([int]($v -band 255))")
        }
    }
    return ($out | Sort-Object -Unique)
}

function Get-Ranges {
    param([string]$Kind)
    if ($Kind -eq 'Cloudflare') {
        try {
            $txt = (Invoke-WebRequest 'https://www.cloudflare.com/ips-v4' -TimeoutSec 15 -UseBasicParsing).Content
            $r = @($txt -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' })
            if ($r.Count -gt 0) { return $r }
        } catch {}
        return @('173.245.48.0/20','103.21.244.0/22','103.22.200.0/22','103.31.4.0/22','141.101.64.0/18',
                 '108.162.192.0/18','190.93.240.0/20','188.114.96.0/20','197.234.240.0/22','198.41.128.0/17',
                 '162.158.0.0/15','104.16.0.0/13','104.24.0.0/14','172.64.0.0/13','131.0.72.0/22')
    } else {
        $j = Invoke-RestMethod 'https://ip-ranges.amazonaws.com/ip-ranges.json' -TimeoutSec 30
        return @($j.prefixes | Where-Object { $_.service -eq 'CLOUDFRONT' } |
                 ForEach-Object { $_.ip_prefix } | Select-Object -Unique)
    }
}

function Format-Eta {
    param([int]$Sec)
    if ($Sec -lt 60) { return "$Sec 秒" }
    return "$([int]($Sec/60)) 分 $($Sec % 60) 秒"
}

# ---------------------------------------------------------------------------
# 结果来源网络标记（ISSUES D4）
# full-scan 的结果反映的是「当时那台机器 / 那个网络对各 IP 的连通性」，
# 换个网络（换宽带、换公司、上代理）候选池就不准了。所以每份 CSV 边上
# 落一个 full-scan-<组>-meta.json，记录当时的网络身份，供下游脚本判断。
# ---------------------------------------------------------------------------
function Get-LocalIpv4 {
    # 取本机在用的 IPv4。全程 try/catch：取不到就返回空，绝不能因此中断扫描。
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
               Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -ne '127.0.0.1' } |
               Select-Object -First 1).IPAddress
        if ($ip) { return $ip }
    } catch {}
    # 老系统 / 精简环境退回到 DNS 反查本机名
    try {
        $a = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
             Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.IPAddressToString -ne '127.0.0.1' } |
             Select-Object -First 1
        if ($a) { return $a.IPAddressToString }
    } catch {}
    return ''
}

function Get-GatewayIp {
    try {
        $g = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
              Sort-Object RouteMetric | Select-Object -First 1).NextHop
        if ($g) { return $g }
    } catch {}
    try {
        # route print 的中文列名在不同语言版本下不一样，直接抓第一行 0.0.0.0 后面那个 IP
        $m = [regex]::Match((& "$env:SystemRoot\System32\ROUTE.EXE" print 0.0.0.0 2>$null | Out-String),
                           '0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch {}
    return ''
}

# 写 full-scan-<组>-meta.json（和 CSV 同目录）
function Write-ScanMeta {
    param(
        [string]$Dir, [string]$Group, [int]$Rate, [int]$Threads, [int]$OkCount
    )
    $meta = [ordered]@{
        Timestamp = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        LocalIp   = (Get-LocalIpv4)
        Gateway   = (Get-GatewayIp)
        Rate      = $Rate
        Threads   = $Threads
        Group     = $Group
        OkCount   = $OkCount
    }
    $p = Join-Path $Dir "full-scan-$($Group.ToLower())-meta.json"
    try {
        ($meta | ConvertTo-Json) | Set-Content -Path $p -Encoding UTF8
        Show "    来源网络标记 -> $p" DarkGray
    } catch {
        Warn "来源网络标记写入失败: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
$t0 = Get-Date
Show ''
Show '============================================================' Cyan
Show '  VRChat 优选 —— 全量 ICMP + TLS 扫描（抗风控版）' Cyan
Show '============================================================' Cyan
Show ''
Show "  限速      $Rate 次/秒（全局令牌桶）" White
Show "  并发      $Threads 线程" DarkGray
Show "  超时      ${Timeout}ms" DarkGray
Show "  目标      $Group" DarkGray
Show ''
Show '  抗风控措施: 限速 + 列表随机打乱 + 主机位随机 + 低并发 + 增量落盘' DarkGray
Prog 0 100 '准备扫描目标'

$jobs = @()
if ($Group -in 'Both','Cloudflare') { $jobs += @{ Name='Cloudflare'; Probe='api.vrchat.cloud' } }
if ($Group -in 'Both','CloudFront') { $jobs += @{ Name='CloudFront'; Probe='files.vrchat.cloud' } }
$script:scanFailed = $false

foreach ($job in $jobs) {
    $name = $job.Name
    Head "$name  （证书校验 SNI = $($job.Probe)）"

    $ranges = Get-Ranges $name
    Show "    段 $($ranges.Count) 条"
    $targets = @(Expand-Random $ranges)
    Show "    候选 $($targets.Count) 个（主机位已随机化）"

    # 拿不到候选（网段接口不可用）时以前会"0 个目标也照样跑完并报成功"，
    # GUI 侧看到的是"全部完成但候选池是空的"。现在明确失败。
    if ($targets.Count -eq 0) {
        Bad "没有拿到任何候选 IP（$name 的网段数据为空）"
        Show '      多半是上游网段接口不通。可重试，或先用 auto-optimize.ps1 -Quick。' Yellow
        $script:scanFailed = $true
        continue
    }

    # 打乱，避免连续打相邻网段
    $targets = @(Shuffle-Array $targets)
    Show '    已随机打乱顺序' DarkGray

    # ---------- ICMP ----------
    $icmpRate = [Math]::Min($Rate * 4, 200)   # ICMP 轻量，可以快 4 倍
    $est = [int]($targets.Count / $icmpRate)
    Show "    [1/2] ICMP 全测（限速 $icmpRate/秒，预计 $(Format-Eta $est)）..." DarkGray
    $bucket = New-Object Bucket($icmpRate)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    IpClear
    # 主线程轮询（不能用脚本块回调，见 Add-Type 里 StartSweep 上面的注释）
    [Probe]::StartIcmp([string[]]$targets, 900, $Threads, $bucket)
    $totIcmp = $targets.Count
    $lastIcmp = 0
    while (-not [Probe]::Done) {
        Start-Sleep -Milliseconds 700
        $n = [Probe]::IcmpDone
        if (($n - $lastIcmp) -lt 200 -and $n -lt $totIcmp) { continue }
        $lastIcmp = $n
        $el2 = [int]$sw.Elapsed.TotalSeconds
        $pct = if ($totIcmp -gt 0) { [int]($n * 100 / $totIcmp) } else { 100 }
        $eta = if ($pct -gt 0) { [int]($el2 * 100 / $pct - $el2) } else { 0 }
        Progress "ICMP 已完成 $n/$totIcmp ($pct%)   ETA $(Format-Eta $eta)" -MinIntervalMs 1200
        Prog ([int]($pct * 0.45)) 100 "ICMP 扫描 $pct%"
    }
    $icmp = [Probe]::IcmpResult
    $sw.Stop()
    Prop-Done
    $icmpAlive = 0
    for ($i = 0; $i -lt $icmp.Length; $i++) { if ($icmp[$i] -ge 0) { $icmpAlive++ } }
    Show ("    ICMP 存活 $icmpAlive / $($targets.Count)   耗时 $(Format-Eta ([int]$sw.Elapsed.TotalSeconds))") Green

    # 阶段间停顿（降低连续特征）
    Show '    停顿 5 秒...' DarkGray
    Start-Sleep -Seconds 5

    # ---------- TLS 全测 ----------
    $est = [int]($targets.Count / $Rate)
    Show "    [2/2] TLS 全测（全量，不做 ICMP 过滤；限速 $Rate/秒，预计 $(Format-Eta $est)）..." DarkGray
    $bucket = New-Object Bucket($Rate)
    $sw = [Diagnostics.Stopwatch]::StartNew()

    # 增量落盘：每 200 个写一次（以前只定义了变量、从没写，中断就全丢）
    $partialPath = Join-Path $OutDir "full-scan-$($name.ToLower())-partial.csv"
    Remove-Item $partialPath -Force -ErrorAction SilentlyContinue
    $tl = @{ n = 0; buf = (New-Object System.Collections.Generic.List[object]) }
    $res = New-Object System.Collections.Generic.List[object]

    [Probe]::StartSweep([string[]]$targets, $job.Probe, $Timeout, $Threads, $bucket)
    $lastTls = 0
    while ($true) {
        Start-Sleep -Milliseconds 200
        $batch = @([Probe]::Drain(400))
        foreach ($p in $batch) {
            $tl.n++
            $res.Add($p)
            $tl.buf.Add([pscustomobject]@{ Ip = $p.Ip; Icmp = $p.Icmp; Tcp = $p.Tcp; Tls = $p.Tls; Ok = $p.Ok; Err = $p.Err; Cn = $p.Cn })
            # ★ 每验证完一个 IP 就汇报（GUI 下方表格实时更新）
            IpTick -G $name -Ip $p.Ip -Lat $p.Tls -Ok $(if($p.Ok){1}else{0}) -Tot 1 `
                   -Med -1 -Jit -1 -Note $(if($p.Ok){"$($p.Cn)"}else{$p.Err})
        }
        if ($tl.buf.Count -ge 200) {
            $tl.buf | Export-Csv -Path $partialPath -NoTypeInformation -Encoding UTF8 -Append
            $tl.buf.Clear()
        }
        if (($tl.n - $lastTls) -ge 200) {
            $lastTls = $tl.n
            $el2 = [int]$sw.Elapsed.TotalSeconds
            $pct = if ($targets.Count -gt 0) { [int]($tl.n * 100 / $targets.Count) } else { 100 }
            $eta = if ($pct -gt 0) { [int]($el2 * 100 / $pct - $el2) } else { 0 }
            Progress "已完成 $($tl.n)/$($targets.Count) ($pct%)   速度 $([int]($tl.n/$el2))个/秒   ETA $(Format-Eta $eta)" -MinIntervalMs 1200
            Prog (45 + [int]($pct * 0.55)) 100 "TLS 全测 $pct%"
        }
        if ([Probe]::Done -and $batch.Count -eq 0) { break }
    }
    if ($tl.buf.Count -gt 0) {
        $tl.buf | Export-Csv -Path $partialPath -NoTypeInformation -Encoding UTF8 -Append
        $tl.buf.Clear()
    }
    $sw.Stop()
    Prop-Done
    Show ("    完成 $($res.Count) 个   耗时 $(Format-Eta ([int]$sw.Elapsed.TotalSeconds))") Green

    # 合并 ICMP
    $icmpMap = @{}
    for ($i = 0; $i -lt $targets.Count; $i++) { $icmpMap[$targets[$i]] = $icmp[$i] }
    foreach ($r in $res) { if ($icmpMap.ContainsKey($r.Ip)) { $r.Icmp = $icmpMap[$r.Ip] } }

    # ---------- 统计 ----------
    $okAll    = @($res | Where-Object { $_.Ok })
    $okIcmp   = @($okAll | Where-Object { $_.Icmp -ge 0 })
    $okNoIcmp = @($okAll | Where-Object { $_.Icmp -lt 0 })
    # 进 CSV 的是「连 443 有响应」的（$okAll.Count == Ok 列为 True 的行数），
    # OkCount 按同一口径记，下游 latency-test 才能和 CSV 行数对得上
    $okCount  = $okAll.Count
    Show ''
    Show "    承载该 zone 的      : $($okAll.Count) 个" Green
    Show "      其中 ICMP 有响应  : $($okIcmp.Count) 个" Gray
    Show "      其中 ICMP 无响应  : $($okNoIcmp.Count) 个   ← 老方法会漏掉" Yellow

    # ---------- 导出 ----------
    $csv = Join-Path $OutDir "full-scan-$($name.ToLower()).csv"
    $res | Sort-Object { if ($_.Ok) { 0 } else { 1 } }, Tls |
        Select-Object Ip, Icmp, Tcp, Tls, Ok, Err, Cn |
        Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    Show "    完整结果 -> $csv" DarkGray

    # ---------- 来源网络标记（ISSUES D4）----------
    # ICMP / TLS 结果都只对「扫的时候那个网络」成立，换网络后候选池会失真，
    # 所以把当时的网络身份和参数一起落盘，给 latency-test 做一致性判断。
    Write-ScanMeta -Dir $OutDir -Group $name -Rate $Rate -Threads $Threads -OkCount $okCount

    Remove-Item $partialPath -Force -EA SilentlyContinue

    # ---------- Top 清单 ----------
    Show ''
    Show "    ── TOP $TopN（按 TLS 握手延迟）──" Cyan
    Show '      注意：ICMP 无响应的也参赛，这才是「无盲区」' DarkGray
    $ranked = @($okAll | Sort-Object Tls | Select-Object -First $TopN)
    $n = 0
    foreach ($r in $ranked) {
        $n++
        $ic = if ($r.Icmp -ge 0) { "$($r.Icmp)ms" } else { '无响应' }
        Show ("      {0,3}. {1,-16} ICMP {2,6}   TCP {3,5}ms   TLS {4,5}ms" -f $n, $r.Ip, $ic, $r.Tcp, $r.Tls) Gray
    }
    $topTxt = Join-Path $OutDir "full-scan-$($name.ToLower())-top.txt"
    ($ranked | ForEach-Object { $_.Ip }) | Set-Content -Path $topTxt -Encoding ASCII
    Show ''
    Show "    TOP $TopN 纯 IP 清单 -> $topTxt" DarkGray

    # 一个可用 IP 都没有 = 这组白扫（网络异常 / 被限流 / 上游数据过期）
    if ($okCount -eq 0) {
        Bad "$name 没有一个可用 IP —— 这组结果不可用"
        $script:scanFailed = $true
    }
    # 只在最后一组发 ##DONE##（中途发会让 GUI 提前显示"完成"）
    if ([object]::ReferenceEquals($job, $jobs[$jobs.Count - 1])) {
        if ($script:scanFailed) { Done 'fail' '扫描有失败组' } else { Prog 100 100 '扫描完成'; Done 'ok' '扫描完成' }
    }

    # 阶段间停顿
    if ($name -eq 'Cloudflare' -and $jobs.Count -gt 1) {
        Show ''
        Show '    停顿 10 秒再做下一组（降低连续特征）...' DarkGray
        Start-Sleep -Seconds 10
    }
}

$el = [int]((Get-Date) - $t0).TotalSeconds
Show ''
Show '============================================================' Cyan
Show "  全部完成，总耗时 $(Format-Eta $el)" Cyan
Show '============================================================' Cyan
Show ''
Show '  下一步 —— 挑出你要的 IP，做下载测速:' Cyan
Show ("    powershell -ExecutionPolicy Bypass -File speedtest-list.ps1 -File " + (Join-Path $OutDir 'full-scan-cloudfront-top.txt')) White
Show ("    powershell -ExecutionPolicy Bypass -File speedtest-list.ps1 -Ips " + '"1.2.3.4,5.6.7.8" -Sni api.vrchat.cloud') White
Show ''

# 退出码：0 = 全部组都扫出可用结果；1 = 有组失败（GUI 侧据此提示，不再一律"成功"）
if ($script:scanFailed) { exit 1 }
exit 0
