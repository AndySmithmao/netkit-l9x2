# 精确定位 RST 来源 + 映射 SNI 阻断规则
# 原理: 手搓 TLS ClientHello，测量 "从发出 ClientHello 到被重置" 的耗时
#       如果这个耗时 ≪ 到服务器的 RTT，说明重置不是服务器发的，而是链路中间的盒子

$ProgressPreference = 'SilentlyContinue'

function New-ClientHello {
    param([string]$Name)
    $body = New-Object System.Collections.Generic.List[byte]
    $body.AddRange([byte[]](0x03,0x03))
    $rnd = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd)
    $body.AddRange($rnd)
    $body.Add(0x00)
    $cs = [byte[]](0xC0,0x2F, 0xC0,0x2B, 0xC0,0x30, 0xC0,0x2C, 0x00,0x9C, 0x00,0x9D)
    $body.Add([byte](($cs.Length -shr 8) -band 0xFF)); $body.Add([byte]($cs.Length -band 0xFF))
    $body.AddRange($cs)
    $body.Add(0x01); $body.Add(0x00)
    $ext = New-Object System.Collections.Generic.List[byte]
    $nm = [System.Text.Encoding]::ASCII.GetBytes($Name)
    $lst = New-Object System.Collections.Generic.List[byte]
    $lst.Add(0x00)
    $lst.Add([byte](($nm.Length -shr 8) -band 0xFF)); $lst.Add([byte]($nm.Length -band 0xFF))
    $lst.AddRange($nm)
    $sni = New-Object System.Collections.Generic.List[byte]
    $sni.Add([byte](($lst.Count -shr 8) -band 0xFF)); $sni.Add([byte]($lst.Count -band 0xFF))
    $sni.AddRange($lst)
    $ext.AddRange([byte[]](0x00,0x00))
    $ext.Add([byte](($sni.Count -shr 8) -band 0xFF)); $ext.Add([byte]($sni.Count -band 0xFF))
    $ext.AddRange($sni)
    $ext.AddRange([byte[]](0x00,0x0A, 0x00,0x06, 0x00,0x04, 0x00,0x1D, 0x00,0x17))
    $ext.AddRange([byte[]](0x00,0x0B, 0x00,0x02, 0x01,0x00))
    $ext.AddRange([byte[]](0x00,0x0D, 0x00,0x0C, 0x00,0x0A, 0x04,0x03, 0x05,0x03, 0x06,0x03, 0x08,0x04, 0x08,0x05))
    $body.Add([byte](($ext.Count -shr 8) -band 0xFF)); $body.Add([byte]($ext.Count -band 0xFF))
    $body.AddRange($ext)
    $hs = New-Object System.Collections.Generic.List[byte]
    $hs.Add(0x01); $hs.Add(0x00)
    $hs.Add([byte](($body.Count -shr 8) -band 0xFF)); $hs.Add([byte]($body.Count -band 0xFF))
    $hs.AddRange($body)
    $rec = New-Object System.Collections.Generic.List[byte]
    $rec.Add(0x16); $rec.Add(0x03); $rec.Add(0x01)
    $rec.Add([byte](($hs.Count -shr 8) -band 0xFF)); $rec.Add([byte]($hs.Count -band 0xFF))
    $rec.AddRange($hs)
    return $rec.ToArray()
}

function Probe {
    param([string]$Sni, [string]$Ip, [int]$Port = 443, [int]$TimeoutMs = 3000)
    $r = [ordered]@{ SNI = $Sni; 目标IP = "${Ip}:${Port}"; 连接RTT = -1; 重置耗时 = -1; 结果 = '' }
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $ar = $c.BeginConnect($Ip, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { $c.Close(); $r.结果 = 'TCP连接超时'; return $r }
        $c.EndConnect($ar)
        $r.连接RTT = [int]$sw.ElapsedMilliseconds
    } catch { $c.Close(); $r.结果 = 'TCP连接失败'; return $r }

    $sock = $c.Client
    $stream = $c.GetStream()
    $hello = New-ClientHello -Name $Sni
    $sw.Restart()
    try { $stream.Write($hello, 0, $hello.Length); $stream.Flush() }
    catch { $r.结果 = '发送时即被重置'; $r.重置耗时 = [int]$sw.ElapsedMilliseconds; $c.Close(); return $r }

    $done = $false
    while (-not $done -and $sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($sock.Poll(20000, [System.Net.Sockets.SelectMode]::SelectRead)) {
            $buf = New-Object byte[] 128
            try {
                $n = $stream.Read($buf, 0, 128)
                $r.重置耗时 = [int]$sw.ElapsedMilliseconds
                if ($n -eq 0) { $r.结果 = '连接被关闭(无数据)' }
                elseif ($buf[0] -eq 0x16) { $r.结果 = '✅ ServerHello 正常' }
                elseif ($buf[0] -eq 0x15) { $r.结果 = "TLS Alert 0x$($buf[5].ToString('X2'))" }
                else { $r.结果 = "非TLS响应 0x$($buf[0].ToString('X2'))" }
            } catch { $r.重置耗时 = [int]$sw.ElapsedMilliseconds; $r.结果 = '❌ RST(被重置)' }
            $done = $true
        }
    }
    if (-not $done) { $r.结果 = '无响应(静默丢弃)' }
    $c.Close()
    return $r
}

Write-Host '========================================================================'
Write-Host ' A. RST 来源定位：把 SNI=vrchat.com 发到完全无关的服务器上'
Write-Host '    （1.1.1.1 和 8.8.8.8 与 VRChat 毫无关系，它们的服务器不可能关心 vrchat.com）'
Write-Host '========================================================================'
$rows = New-Object System.Collections.Generic.List[object]
$rows.Add((Probe -Sni 'vrchat.com' -Ip '104.18.6.156'))
$rows.Add((Probe -Sni 'vrchat.com' -Ip '1.1.1.1'))
$rows.Add((Probe -Sni 'vrchat.com' -Ip '8.8.8.8'))
$rows.Add((Probe -Sni 'vrchat.com' -Ip '104.18.26.36'))
$rows.Add((Probe -Sni 'cloudflare.com' -Ip '104.18.6.156'))
$rows.Add((Probe -Sni 'api.vrchat.cloud' -Ip '104.18.6.156'))
$rows | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize | Out-String -Width 130

Write-Host ''
Write-Host '========================================================================'
Write-Host ' B. 阻断规则映射（都在真实 IP 104.18.6.156 上测，只变 SNI）'
Write-Host '========================================================================'
$variants = @(
    'vrchat.com', 'www.vrchat.com', 'xyz.vrchat.com', 'assets.vrchat.com',
    'VRChat.COM', 'vrchat.com.', 'notvrchat.com', 'vrchat.co',
    'vrchatcom.com', 'vrchat.cloud', 'api.vrchat.cloud', 'cloudflare.com'
)
$rows2 = New-Object System.Collections.Generic.List[object]
foreach ($v in $variants) { $rows2.Add((Probe -Sni $v -Ip '104.18.6.156')) }
$rows2 | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize | Out-String -Width 130

Write-Host ''
Write-Host '参考: 到 104.18.6.156 的 TCP 连接 RTT 约 180~200ms'
Write-Host '     如果"重置耗时"远小于 180ms，说明重置包不是服务器发的 —— 是链路中间的设备伪造的'

exit 0
