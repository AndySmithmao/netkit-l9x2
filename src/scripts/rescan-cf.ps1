# 换网络后重扫 Cloudflare 优选项（按 TLS 握手延迟）
$ProgressPreference='SilentlyContinue'
$RANGES = @()
try{
  $txt = (Invoke-WebRequest 'https://www.cloudflare.com/ips-v4' -TimeoutSec 15 -UseBasicParsing).Content
  $RANGES = @($txt -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+$' })
}catch{}
if($RANGES.Count -eq 0){ $RANGES = @('173.245.48.0/20','103.21.244.0/22','103.22.200.0/22','103.31.4.0/22','141.101.64.0/18','108.162.192.0/18','190.93.240.0/20','188.114.96.0/20','197.234.240.0/22','198.41.128.0/17','162.158.0.0/15','104.16.0.0/13','104.24.0.0/14','172.64.0.0/13','131.0.72.0/22') }
"  Cloudflare 段: $($RANGES.Count) 条"

function Expand24($cidrs){
  $o=New-Object System.Collections.Generic.List[string]
  foreach($c in $cidrs){
    $p=$c.Split('/'); if($p.Count -ne 2){continue}
    $b=([System.Net.IPAddress]::Parse($p[0])).GetAddressBytes()
    $base=[uint64]$b[0]*16777216+[uint64]$b[1]*65536+[uint64]$b[2]*256+[uint64]$b[3]
    $pref=[int]$p[1]
    if($pref -ge 24){ $o.Add("$([int]$b[0]).$([int]$b[1]).$([int]$b[2]).1"); continue }
    $n=[int]([uint64][math]::Pow(2,32-$pref)/256)
    for($i=0;$i -lt $n;$i++){
      $v=$base+[uint64]($i*256)+1
      $o.Add("$([int](($v -shr 24) -band 255)).$([int](($v -shr 16) -band 255)).$([int](($v -shr 8) -band 255)).$([int]($v -band 255))")
    }
  }
  return ($o | Sort-Object -Unique)
}
$targets = Expand24 $RANGES
"  候选: $($targets.Count)"

# ICMP 俯冲
$alive=New-Object System.Collections.Generic.List[object]
$B=256; $PT=1000; $i=0
while($i -lt $targets.Count){
  $e=[Math]::Min($i+$B-1,$targets.Count-1); $s=$targets[$i..$e]
  $t=New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
  $pings=New-Object System.Collections.Generic.List[System.Net.NetworkInformation.Ping]; foreach($ip in $s){ $pg=New-Object System.Net.NetworkInformation.Ping; $pings.Add($pg); $t.Add($pg.SendPingAsync($ip,$PT)) }
  [System.Threading.Tasks.Task]::WaitAll($t.ToArray(),$PT+800)|Out-Null; foreach($pg in $pings){ try{$pg.Dispose()}catch{} }
  for($k=0;$k -lt $s.Count;$k++){ try{ if($t[$k].Status -eq 'RanToCompletion' -and $t[$k].Result.Status -eq 'Success'){ $alive.Add([pscustomobject]@{IP=$s[$k];MS=[int]$t[$k].Result.RoundtripTime}) } }catch{} }
  $i+=$B
}
$alive = $alive | Sort-Object MS
"  ICMP 存活 $($alive.Count)，最快 $($alive[0].MS)ms"

function ConnectT { param([string]$ip,[int]$tmo=2500)
  $c=New-Object System.Net.Sockets.TcpClient
  $ar=$c.BeginConnect($ip,443,$null,$null)
  if(-not $ar.AsyncWaitHandle.WaitOne($tmo)){ $c.Close(); return $null }
  try{ $c.EndConnect($ar) }catch{ $c.Close(); return $null }
  return $c }
function TryEdge { param([string]$ip)
  $o=New-Object psobject -Property @{IP=$ip;TLS=-1;CN='';OK=$false}
  $c=ConnectT $ip; if($null -eq $c){ return $o }
  $c.ReceiveTimeout=3000; $c.SendTimeout=3000
  try{
    $s=New-Object System.Net.Security.SslStream($c.GetStream(),$false,([System.Net.Security.RemoteCertificateValidationCallback]{$true}))
    $sw=[Diagnostics.Stopwatch]::StartNew(); $s.AuthenticateAsClient('api.vrchat.cloud'); $o.TLS=[int]$sw.ElapsedMilliseconds
    $m=[regex]::Match($s.RemoteCertificate.Subject,'CN=([^,]+)'); if($m.Success){$o.CN=$m.Groups[1].Value.Trim()}
    if($o.CN -like '*vrchat*'){ $o.OK=$true }
    $s.Dispose()
  }catch{}
  $c.Close(); return $o }

# 先测当前在用的那个
""
'--- 当前在用的 172.64.144.1 ---'
$cur = TryEdge '172.64.144.1'
"  TLS $($cur.TLS)ms  证书 $($cur.CN)  可用 $($cur.OK)"

# 取 ICMP 最快的 120 个进 TLS 验证（分档：既看速度也看稳定性）
$pool = @($alive | Select-Object -First 120 | ForEach-Object { $_.IP })
""
"  进入 TLS 验证: $($pool.Count) 个（约 2 分钟）"
$ok=New-Object System.Collections.Generic.List[object]
foreach($ip in $pool){
  $e = TryEdge $ip
  if($e.OK){ $ok.Add([pscustomobject]@{ IP=$ip; TLS=$e.TLS; MS=($alive | Where-Object {$_.IP -eq $ip}).MS }) }
}
"  承载该 zone 的: $($ok.Count)/$($pool.Count)"

# 前 30 个做 3 轮取中位
$top = $ok | Sort-Object TLS | Select-Object -First 30
""
"  对前 $($top.Count) 个做 3 轮基准..."
$res=New-Object System.Collections.Generic.List[object]
foreach($c in $top){
  $v=@()
  for($r=1;$r -le 3;$r++){ $e=TryEdge $c.IP; if($e.OK -and $e.TLS -ge 0){ $v += $e.TLS } }
  if($v.Count -eq 0){ continue }
  $v=$v|Sort-Object
  $res.Add([pscustomobject]@{ IP=$c.IP; ICMP=$c.MS; TLSmin=$v[0]; TLSmed=$v[[int](($v.Count-1)/2)]; 命中="$($v.Count)/3" })
}
$res = $res | Sort-Object TLSmed
""
'============== Cloudflare 优选项（新网络）=============='
$res | Select-Object -First 15 | Format-Table -AutoSize -AutoSize | Out-String -Width 110 | Write-Host
$best = $res | Where-Object { $_.命中 -eq '3/3' } | Select-Object -First 3
"  推荐（3/3 且中位最低）: " + (($best | ForEach-Object { "$($_.IP)($($_.TLSmed)ms)" }) -join '  ')
"  旧网络的 172.64.144.1 现在: TLS $($cur.TLS)ms"

exit 0
