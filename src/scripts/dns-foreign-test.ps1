# 境外 DNS 服务器实测：港/台/日/韩/新 + 欧美，UDP53 / TCP53 / DoH 三种查询方式
$ProgressPreference = 'SilentlyContinue'
$DOMAIN = 'vrchat.com'
$CONTROL = 'www.yahoo.co.jp'   # 对照：不受干扰的域名，用来判断服务器本身是否可达

function New-DnsQuery {
    param([string]$Name, [int]$Id)
    $b = New-Object System.Collections.Generic.List[byte]
    $b.Add([byte](($Id -shr 8) -band 0xFF)); $b.Add([byte]($Id -band 0xFF))
    $b.AddRange([byte[]](0x01,0x00))
    $b.AddRange([byte[]](0x00,0x01, 0x00,0x00, 0x00,0x00, 0x00,0x00))
    foreach ($lbl in $Name.Split('.')) {
        $n = [System.Text.Encoding]::ASCII.GetBytes($lbl)
        $b.Add([byte]$n.Length); $b.AddRange($n)
    }
    $b.Add(0)
    $b.AddRange([byte[]](0x00,0x01, 0x00,0x01))
    return $b.ToArray()
}

function Parse-Dns {
    param([byte[]]$Buf, [int]$Len)
    $out = @{ Rcode = -1; Answers = @(); Flags = 0 }
    if ($Len -lt 12) { return $out }
    $out.Flags = ($Buf[2] -shl 8) + $Buf[3]
    $out.Rcode = $Buf[3] -band 0x0F
    $qd = ($Buf[4] -shl 8) + $Buf[5]
    $an = ($Buf[6] -shl 8) + $Buf[7]
    $p = 12
    for ($i = 0; $i -lt $qd -and $p -lt $Len; $i++) {
        while ($p -lt $Len -and $Buf[$p] -ne 0) {
            if (($Buf[$p] -band 0xC0) -eq 0xC0) { $p += 2; break }
            $p += [int]$Buf[$p] + 1
        }
        if ($p -lt $Len -and $Buf[$p] -eq 0) { $p++ }
        $p += 4
    }
    $ans = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $an -and $p -lt $Len; $i++) {
        if (($Buf[$p] -band 0xC0) -eq 0xC0) { $p += 2 }
        else { while ($p -lt $Len -and $Buf[$p] -ne 0) { $p += [int]$Buf[$p] + 1 }; $p++ }
        if ($p + 10 -gt $Len) { break }
        $type = ($Buf[$p] -shl 8) + $Buf[$p+1]
        $rdlen = ($Buf[$p+8] -shl 8) + $Buf[$p+9]
        $p += 10
        if ($type -eq 1 -and $rdlen -eq 4 -and $p + 4 -le $Len) {
            $ans.Add("$($Buf[$p]).$($Buf[$p+1]).$($Buf[$p+2]).$($Buf[$p+3])")
        }
        $p += $rdlen
    }
    $out.Answers = $ans
    return $out
}

function Query-Udp {
    param([string]$Server, [string]$Name, [int]$Timeout = 3000)
    try {
        $q = New-DnsQuery -Name $Name -Id (Get-Random -Min 1 -Max 65535)
        $c = New-Object System.Net.Sockets.UdpClient
        $c.Client.ReceiveTimeout = $Timeout
        $c.Connect($Server, 53)
        [void]$c.Send($q, $q.Length)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = $c.Receive([ref]$ep)
        $sw.Stop()
        $c.Close()
        $p = Parse-Dns -Buf $r -Len $r.Length
        return @{ OK = $true; Rcode = $p.Rcode; Answers = ($p.Answers -join ','); Ms = [int]$sw.ElapsedMilliseconds }
    } catch {
        return @{ OK = $false; Rcode = -1; Answers = 'TIMEOUT/ERR'; Ms = -1 }
    }
}

function Query-Tcp {
    param([string]$Server, [string]$Name, [int]$Timeout = 4000)
    try {
        $q = New-DnsQuery -Name $Name -Id (Get-Random -Min 1 -Max 65535)
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect($Server, 53, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($Timeout)) { $c.Close(); return @{ OK=$false; Rcode=-1; Answers='TCP_CONNECT_TIMEOUT'; Ms=-1 } }
        $c.EndConnect($ar)
        $c.ReceiveTimeout = $Timeout
        $s = $c.GetStream()
        $lenPfx = [byte[]]@([byte](($q.Length -shr 8) -band 0xFF), [byte]($q.Length -band 0xFF))
        $s.Write($lenPfx, 0, 2); $s.Write($q, 0, $q.Length); $s.Flush()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $h = New-Object byte[] 2
        if ($s.Read($h, 0, 2) -lt 2) { $c.Close(); return @{ OK=$false; Rcode=-1; Answers='SHORT_READ'; Ms=-1 } }
        $rl = ($h[0] -shl 8) + $h[1]
        $buf = New-Object byte[] ($rl + 16)
        $got = 0
        while ($got -lt $rl) { $n = $s.Read($buf, $got, $rl - $got); if ($n -le 0) { break }; $got += $n }
        $sw.Stop()
        $c.Close()
        $p = Parse-Dns -Buf $buf -Len $got
        return @{ OK = $true; Rcode = $p.Rcode; Answers = ($p.Answers -join ','); Ms = [int]$sw.ElapsedMilliseconds }
    } catch {
        return @{ OK = $false; Rcode = -1; Answers = "ERR:$($_.Exception.Message.Split([char]10)[0])"; Ms = -1 }
    }
}

function Query-Doh {
    param([string]$Url, [string]$Name, [int]$Timeout = 10)
    try {
        $r = Invoke-RestMethod -Uri "$Url`?name=$Name&type=A" -Headers @{ accept = 'application/dns-json' } -TimeoutSec $Timeout -ErrorAction Stop
        $a = ($r.Answer | Where-Object { $_.type -eq 1 } | ForEach-Object { $_.data }) -join ','
        if (-not $a) { $a = "(空, Status=$($r.Status))" }
        return @{ OK = $true; Answers = $a }
    } catch {
        return @{ OK = $false; Answers = 'ERR/TIMEOUT' }
    }
}

$servers = @(
    @{ n='HK 香港宽频 HKBN';   ip='203.80.96.10' },
    @{ n='HK 香港宽频 HKBN2';  ip='203.80.96.9' },
    @{ n='HK 电讯盈科 PCCW';   ip='205.252.144.228' },
    @{ n='HK 和记 HGC';        ip='202.67.220.220' },
    @{ n='HK Netvigator';      ip='218.102.23.228' },
    @{ n='TW 中华电信 HiNet';  ip='168.95.1.1' },
    @{ n='TW 中华电信 HiNet2'; ip='168.95.192.1' },
    @{ n='TW 数位联合 Seednet';ip='139.175.55.244' },
    @{ n='TW 台湾固网 TFN';    ip='61.31.233.1' },
    @{ n='JP IIJ';             ip='202.32.169.10' },
    @{ n='JP KDDI';            ip='210.196.3.183' },
    @{ n='JP NTT';             ip='210.130.1.1' },
    @{ n='JP @nifty';          ip='202.248.37.74' },
    @{ n='KR KT 韩国电信';     ip='168.126.63.1' },
    @{ n='KR SK Broadband';    ip='210.220.163.82' },
    @{ n='SG SingNet';         ip='165.21.83.88' },
    @{ n='US Google 8.8.8.8';  ip='8.8.8.8' },
    @{ n='US Quad9';           ip='9.9.9.9' },
    @{ n='US Cloudflare 1.1.1.1'; ip='1.1.1.1' },
    @{ n='CN 阿里 223.5.5.5';  ip='223.5.5.5' }
)

Write-Host '========================================================================'
Write-Host " 境外 DNS 服务器解析测试  目标: $DOMAIN"
Write-Host '========================================================================'
Write-Host ''
Write-Host '---- 先确认服务器本身可达（对照组: www.yahoo.co.jp）----'
$rows = New-Object System.Collections.Generic.List[object]
foreach ($s in $servers) {
    $u = Query-Udp -Server $s.ip -Name $CONTROL
    $t = Query-Tcp -Server $s.ip -Name $CONTROL
    $rows.Add([pscustomobject]@{
        服务器 = $s.n; IP = $s.ip
        UDP对照 = $u.Answers
        TCP对照 = if ($t.OK) { $t.Answers } else { $t.Answers }
    })
}
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 170

Write-Host ''
Write-Host "---- 正文: 用这些服务器解析 $DOMAIN ----"
$out = New-Object System.Collections.Generic.List[object]
foreach ($s in $servers) {
    $u = Query-Udp -Server $s.ip -Name $DOMAIN
    $t = Query-Tcp -Server $s.ip -Name $DOMAIN
    $out.Add([pscustomobject]@{
        服务器 = $s.n; IP = $s.ip
        UDP53 = $u.Answers
        UDP用时 = $u.Ms
        TCP53 = $t.Answers
    })
}
$out | Format-Table -AutoSize -Wrap | Out-String -Width 190
''
'真实值参考: 104.18.6.156 / 104.18.7.156 (Cloudflare)'

exit 0
