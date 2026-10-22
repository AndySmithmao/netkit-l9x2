# 换网络后重扫 CloudFront 优选项 —— 这次按【吞吐】挑，因为影响的是下载
$ProgressPreference='SilentlyContinue'
$H='d14hwloucscbyy.cloudfront.net'   # assets.vrchat.com 的分布域（用于测同一批边缘）
$F='/sdk/VRCSDK2-2022.04.20.16.27_Public.unitypackage'
$UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

"  拉取 AWS CLOUDFRONT 段..."
$pre=@()
try{
  $j=Invoke-RestMethod 'https://ip-ranges.amazonaws.com/ip-ranges.json' -TimeoutSec 30
  $pre=@($j.prefixes | Where-Object { $_.service -eq 'CLOUDFRONT' } | ForEach-Object { $_.ip_prefix } | Select-Object -Unique)
}catch{}
"  CLOUDFRONT 前缀: $($pre.Count)"

function Expand24($cidrs){
  $o=New-Object System.Collections.Generic.List[string]
  foreach($c in $cidrs){
    $p=$c.Split('/'); if($p.Count -ne 2){continue}
    $b=([System.Net.IPAddress]::Parse($p[0])).GetAddressBytes()
    $base=[uint64]$b[0]*16777216+[uint64]$b[1]*65536+[uint64]$b[2]*256+[uint64]$b[3]
    $pf=[int]$p[1]
    if($pf -ge 24){ $o.Add("$([int]$b[0]).$([int]$b[1]).$([int]$b[2]).1"); continue }
    $n=[int]([uint64][math]::Pow(2,32-$pf)/256)
    for($i=0;$i -lt $n;$i++){
      $v=$base+[uint64]($i*256)+1
      $o.Add("$([int](($v -shr 24) -band 255)).$([int](($v -shr 16) -band 255)).$([int](($v -shr 8) -band 255)).$([int]($v -band 255))")
    }
  }
  return ($o | Sort-Object -Unique)
}
$tg = Expand24 $pre
"  候选: $($tg.Count)"

$alive=New-Object System.Collections.Generic.List[object]
$B=256; $PT=900; $i=0
while($i -lt $tg.Count){
  $e=[Math]::Min($i+$B-1,$tg.Count-1); $s=$tg[$i..$e]
  $t=New-Object System.Collections.Generic.List[System.Threading.Tasks.Task]
  $pings=New-Object System.Collections.Generic.List[System.Net.NetworkInformation.Ping]; foreach($ip in $s){ $pg=New-Object System.Net.NetworkInformation.Ping; $pings.Add($pg); $t.Add($pg.SendPingAsync($ip,$PT)) }
  [System.Threading.Tasks.Task]::WaitAll($t.ToArray(),$PT+800)|Out-Null; foreach($pg in $pings){ try{$pg.Dispose()}catch{} }
  for($k=0;$k -lt $s.Count;$k++){ try{ if($t[$k].Status -eq 'RanToCompletion' -and $t[$k].Result.Status -eq 'Success'){ $alive.Add([pscustomobject]@{IP=$s[$k];MS=[int]$t[$k].Result.RoundtripTime}) } }catch{} }
  $i+=$B
}
$alive = $alive | Sort-Object MS
"  ICMP 存活 $($alive.Count)，最快 $($alive[0].MS)ms"

# 候选 = ICMP 最快 18 个 + 历史已知可用 + 当前在用的
$cands = New-Object System.Collections.Generic.List[string]
foreach($x in ($alive | Select-Object -First 18)){ $cands.Add($x.IP) }
foreach($x in '13.33.180.1','13.33.178.1','18.65.14.1','3.175.214.74','13.226.69.72','3.175.214.13'){ $cands.Add($x) }
$cands = $cands | Select-Object -Unique
"  进入吞吐实测: $($cands.Count) 个"

function Speed { param([string]$ip,[int]$Rounds=2,[int]$MaxTime=12)
  $sp=@(); $full=0
  for($r=1;$r -le $Rounds;$r++){
    $x = & "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time $MaxTime --resolve "${H}:443:$ip" `
         -w '%{speed_download}|%{size_download}' "https://$H$F" 2>$null | Out-String
    $m=[regex]::Match($x.Trim(),'^([\d.]+)\|(\d+)$')
    if($m.Success){ $sp += [double]$m.Groups[1].Value; if([int]$m.Groups[2].Value -ge 6600000){ $full++ } }
  }
  if($sp.Count -eq 0){ return @{avg=0;max=0;full=0;ok=$false} }
  return @{ avg=[math]::Round((($sp|Measure-Object -Average).Average)/1024); max=[math]::Round((($sp|Measure-Object -Maximum).Maximum)/1024); full=$full; ok=$true } }

$rows=New-Object System.Collections.Generic.List[object]
foreach($ip in $cands){
  $s = Speed $ip
  if(-not $s.ok){ continue }
  $rows.Add([pscustomobject]@{ IP=$ip; 平均KBps=$s.avg; 最高KBps=$s.max; 完整="$($s.full)/2" })
}
$rows = $rows | Sort-Object 平均KBps -Descending

""
'============== CloudFront 边缘吞吐排名（新网络）=============='
$rows | Select-Object -First 18 | Format-Table -AutoSize | Out-String -Width 100 | Write-Host

$best = $rows | Where-Object { $_.完整 -eq '2/2' } | Select-Object -First 4
$rec = '  (无)'
if($best){ $rec = ($best | ForEach-Object { "$($_.IP)($($_.平均KBps)KB/s)" }) -join '  ' }
"  推荐（2/2 完整下载且平均最高）: $rec"
''
'  对照（当前 hosts 里在用的）:'
foreach($ip in '13.33.180.1','172.64.144.1'){
  $r = $rows | Where-Object { $_.IP -eq $ip }
  if($r){ "    $ip  ->  $($r.平均KBps) KB/s  (完整 $($r.完整))" } else { "    $ip  ->  未进入候选/失败" }
}

exit 0
