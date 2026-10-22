# 逐个探测 VRChat 各主机名的 SNI 是否被 GFW 阻断
# 方法: 手搓 TLS ClientHello 打到任意一个 Cloudflare IP
#   RST        -> SNI 被阻断（中间人注入）
#   服务器应答  -> SNI 未被阻断
function New-CH { param([string]$Name)
    $body=New-Object System.Collections.Generic.List[byte]
    $body.AddRange([byte[]](0x03,0x03))
    $rnd=New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($rnd)
    $body.AddRange($rnd); $body.Add(0x00)
    $cs=[byte[]](0xC0,0x2F,0xC0,0x2B,0xC0,0x30,0xC0,0x2C,0x00,0x9C,0x00,0x9D)
    $body.Add([byte](($cs.Length -shr 8) -band 0xFF)); $body.Add([byte]($cs.Length -band 0xFF)); $body.AddRange($cs)
    $body.Add(0x01); $body.Add(0x00)
    $ext=New-Object System.Collections.Generic.List[byte]
    $nm=[Text.Encoding]::ASCII.GetBytes($Name)
    $lst=New-Object System.Collections.Generic.List[byte]
    $lst.Add(0x00); $lst.Add([byte](($nm.Length -shr 8) -band 0xFF)); $lst.Add([byte]($nm.Length -band 0xFF)); $lst.AddRange($nm)
    $sni=New-Object System.Collections.Generic.List[byte]
    $sni.Add([byte](($lst.Count -shr 8) -band 0xFF)); $sni.Add([byte]($lst.Count -band 0xFF)); $sni.AddRange($lst)
    $ext.AddRange([byte[]](0x00,0x00)); $ext.Add([byte](($sni.Count -shr 8) -band 0xFF)); $ext.Add([byte]($sni.Count -band 0xFF)); $ext.AddRange($sni)
    $ext.AddRange([byte[]](0x00,0x0A,0x00,0x06,0x00,0x04,0x00,0x1D,0x00,0x17))
    $ext.AddRange([byte[]](0x00,0x0B,0x00,0x02,0x01,0x00))
    $ext.AddRange([byte[]](0x00,0x0D,0x00,0x0C,0x00,0x0A,0x04,0x03,0x05,0x03,0x06,0x03,0x08,0x04,0x08,0x05))
    $body.Add([byte](($ext.Count -shr 8) -band 0xFF)); $body.Add([byte]($ext.Count -band 0xFF)); $body.AddRange($ext)
    $hs=New-Object System.Collections.Generic.List[byte]
    $hs.Add(0x01); $hs.Add(0x00); $hs.Add([byte](($body.Count -shr 8) -band 0xFF)); $hs.Add([byte]($body.Count -band 0xFF)); $hs.AddRange($body)
    $rec=New-Object System.Collections.Generic.List[byte]
    $rec.Add(0x16); $rec.Add(0x03); $rec.Add(0x01); $rec.Add([byte](($hs.Count -shr 8) -band 0xFF)); $rec.Add([byte]($hs.Count -band 0xFF)); $rec.AddRange($hs)
    return $rec.ToArray() }

function Probe { param([string]$Sni,[string]$Ip,[int]$Tmo=3000)
    $c=New-Object System.Net.Sockets.TcpClient
    $sw=[System.Diagnostics.Stopwatch]::StartNew()
    try{
        $ar=$c.BeginConnect($Ip,443,$null,$null)
        if(-not $ar.AsyncWaitHandle.WaitOne($Tmo)){ $c.Close(); return @{r='TCP超时';ms=-1} }
        $c.EndConnect($ar)
    }catch{ $c.Close(); return @{r='TCP失败';ms=-1} }
    $connectMs=[int]$sw.ElapsedMilliseconds
    $s=$c.GetStream(); $h=New-CH -Name $Sni
    $sw.Restart()
    try{ $s.Write($h,0,$h.Length); $s.Flush() }catch{ $c.Close(); return @{r='RST';ms=[int]$sw.ElapsedMilliseconds;tcp=$connectMs} }
    while($sw.ElapsedMilliseconds -lt $Tmo){
        if($c.Client.Poll(25000,[System.Net.Sockets.SelectMode]::SelectRead)){
            $buf=New-Object byte[] 64
            try{
                $n=$s.Read($buf,0,64)
                $c.Close()
                if($n -gt 0 -and $buf[0] -eq 0x16){ return @{r='服务器应答';ms=[int]$sw.ElapsedMilliseconds;tcp=$connectMs} }
                if($n -gt 0 -and $buf[0] -eq 0x15){ return @{r='服务器应答(Alert)';ms=[int]$sw.ElapsedMilliseconds;tcp=$connectMs} }
                if($n -eq 0){ return @{r='连接关闭';ms=[int]$sw.ElapsedMilliseconds;tcp=$connectMs} }
                return @{r="非TLS";ms=[int]$sw.ElapsedMilliseconds;tcp=$connectMs}
            }catch{ $c.Close(); return @{r='RST';ms=[int]$sw.ElapsedMilliseconds;tcp=$connectMs} }
        }
    }
    $c.Close(); return @{r='无响应';ms=$Tmo;tcp=$connectMs} }

$hosts = @(
 'vrchat.com','www.vrchat.com','mail.vrchat.com','creators.vrchat.com',
 'docs.vrchat.com','status.vrchat.com','assets.vrchat.com','redirect.vrchat.com',
 'hello.vrchat.com','help.vrchat.com','ask.vrchat.com','feedback.vrchat.com',
 'api.vrchat.cloud','files.vrchat.cloud','pipeline.vrchat.cloud',
 'dev-api.vrchat.cloud','vrcpm.vrchat.cloud'
)
'   主机名                       探测结果          重置耗时   连接RTT   判定'
'   ' + ('-'*88)
foreach($h in $hosts){
    $r = Probe -Sni $h -Ip '104.18.6.156'
    $verdict = '——'
    if($r.r -eq 'RST'){
        $verdict = '❌ SNI 被阻断'
        if($r.tcp -gt 0 -and $r.ms -ge 0 -and $r.ms -lt ($r.tcp/2)){ $verdict += '（中间人，早于服务器应答）' }
    } elseif($r.r -eq '服务器应答' -or $r.r -eq '服务器应答(Alert)'){ $verdict = '✅ 未被阻断' }
    "   {0,-28} {1,-18} {2,8} {3,9}   {4}" -f $h,$r.r,$r.ms,$r.tcp,$verdict
}
''
'说明: 目标是任意 Cloudflare anycast IP。未被阻断的 SNI 会拿到服务器的 TLS Alert/应答；'
'      被阻断的会在服务器应答之前被中间人注入 RST。'

exit 0
