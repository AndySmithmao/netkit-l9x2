# 生成 IP 归属库（v4），产物：src\app\geoip.bin
#
# 数据源优先级：
#   1) DB-IP Lite country（CC-BY 4.0，覆盖完整，含 ARIN 段）
#      https://download.db-ip.com/free/dbip-country-lite-YYYY-MM.csv.gz
#   2) 五大 RIR delegated 文件（APNIC/RIPE/LACNIC/AFRINIC；ARIN 公开文件现在只含 ASN）
#
# 输出格式（小端）：
#   magic  "VGT1"         4 字节
#   count  uint32         记录数
#   ccCount uint16        国家码个数
#   cc 表  ccCount * 2    ASCII 国家码
#   records count * 9     uint32 start, uint32 count, uint8 ccIndex
#
# 记录按 start 升序，查询时二分。

param(
    [string]$CacheDir = 'C:\Opencode\.tmp\rir',
    [string]$OutFile  = 'C:\Opencode\vrctool\src\app\geoip.bin',
    [switch]$SkipDownload
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force $CacheDir | Out-Null

$records = New-Object System.Collections.Generic.List[object]
$ccSet = New-Object System.Collections.Generic.HashSet[string]

function U32([string]$ip) {
    $p = $ip.Split('.')
    if ($p.Count -ne 4) { return [uint32]0 }
    return [uint32]$p[0] * 16777216 + [uint32]$p[1] * 65536 + [uint32]$p[2] * 256 + [uint32]$p[3]
}

# ---------------------------------------------------------------- 1) DB-IP
$gz = Join-Path $CacheDir 'dbip.csv.gz'
$needDownload = $true
if (Test-Path $gz) {
    $age = ((Get-Date) - (Get-Item $gz).LastWriteTime).TotalDays
    if ($age -lt 30) { "  复用 DB-IP 缓存（$([math]::Round($age,1)) 天前）"; $needDownload = $false }
}
if ($needDownload -and -not $SkipDownload) {
    $d = Get-Date
    foreach ($i in 0..3) {
        $m = $d.AddMonths(-$i).ToString('yyyy-MM')
        $u = "https://download.db-ip.com/free/dbip-country-lite-$m.csv.gz"
        try {
            "  下载 DB-IP $m ..."
            Invoke-WebRequest -Uri $u -OutFile $gz -TimeoutSec 180 -UseBasicParsing
            if ((Get-Item $gz).Length -gt 1MB) { "  成功 $([math]::Round((Get-Item $gz).Length/1MB,2)) MB"; break }
        } catch {
            "    失败: $($_.Exception.Message)"
            if (Test-Path $gz) { Remove-Item $gz -Force }
        }
    }
}

if (Test-Path $gz) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fs = [IO.File]::OpenRead($gz)
    $gzs = New-Object System.IO.Compression.GzipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object System.IO.StreamReader($gzs)
    $n = 0
    while ($null -ne ($line = $sr.ReadLine())) {
        if ($line.Length -eq 0) { continue }
        $p = $line.Split(',')
        if ($p.Count -lt 3) { continue }
        if ($p[0].IndexOf(':') -ge 0) { continue }
        $cc = $p[2]
        if ($cc.Length -ne 2) { continue }
        $start = U32 $p[0]
        $end = U32 $p[1]
        if ($end -le $start) { continue }
        $count = [uint32]($end - [uint64]$start + 1)
        $records.Add([pscustomobject]@{ Start = $start; Count = $count; CC = $cc })
        $null = $ccSet.Add($cc)
        $n++
    }
    $sr.Close(); $fs.Close()
    "  DB-IP 解析 $n 条"
} else {
    "  DB-IP 不可用，退回 RIR 数据"
    $sources = [ordered]@{
        APNIC   = 'https://ftp.apnic.net/stats/apnic/delegated-apnic-latest'
        RIPE    = 'https://ftp.ripe.net/pub/stats/ripencc/delegated-ripencc-latest'
        LACNIC  = 'https://ftp.lacnic.net/pub/stats/lacnic/delegated-lacnic-latest'
        AFRINIC = 'https://ftp.afrinic.net/pub/stats/afrinic/delegated-afrinic-latest'
    }
    foreach ($k in $sources.Keys) {
        $f = Join-Path $CacheDir "$k.txt"
        if (-not (Test-Path $f) -and -not $SkipDownload) {
            try { Invoke-WebRequest -Uri $sources[$k] -OutFile $f -TimeoutSec 120 -UseBasicParsing } catch { }
        }
        if (-not (Test-Path $f)) { continue }
        foreach ($line in [IO.File]::ReadLines($f)) {
            if ($line.Length -eq 0 -or $line[0] -eq '#') { continue }
            $p = $line.Split('|')
            if ($p.Count -lt 7 -or $p[2] -ne 'ipv4') { continue }
            if ($p[6] -ne 'allocated' -and $p[6] -ne 'assigned' -and $p[6] -ne 'legacy') { continue }
            $cc = $p[1]
            if ($cc.Length -ne 2 -or $cc -eq 'ZZ') { continue }
            $cnt = 0
            if (-not [int]::TryParse($p[4], [ref]$cnt) -or $cnt -le 0) { continue }
            $records.Add([pscustomobject]@{ Start = (U32 $p[3]); Count = [uint32]$cnt; CC = $cc })
            $null = $ccSet.Add($cc)
        }
    }
    "  RIR 解析 $($records.Count) 条"
}

if ($records.Count -eq 0) { throw '没有解析到任何记录，检查数据源' }
"  合计 $($records.Count) 条，$($ccSet.Count) 个国家/地区"

$sorted = $records | Sort-Object Start
$merged = New-Object System.Collections.Generic.List[object]
foreach ($r in $sorted) {
    if ($merged.Count -gt 0) {
        $last = $merged[$merged.Count - 1]
        if ($last.CC -eq $r.CC -and ([uint64]$last.Start + [uint64]$last.Count) -ge [uint64]$r.Start) {
            $end = [Math]::Max([uint64]$last.Start + [uint64]$last.Count, [uint64]$r.Start + [uint64]$r.Count)
            $last.Count = [uint32]($end - [uint64]$last.Start)
            continue
        }
    }
    $merged.Add([pscustomobject]@{ Start = $r.Start; Count = $r.Count; CC = $r.CC })
}
"  合并后 $($merged.Count) 条"

$ccList = @($ccSet | Sort-Object)
$ccIndex = @{}
for ($i = 0; $i -lt $ccList.Count; $i++) { $ccIndex[$ccList[$i]] = $i }

$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([byte[]](0x56, 0x47, 0x54, 0x31))
$bw.Write([uint32]$merged.Count)
$bw.Write([uint16]$ccList.Count)
foreach ($cc in $ccList) { $bw.Write([byte][char]$cc[0]); $bw.Write([byte][char]$cc[1]) }
foreach ($r in $merged) {
    $bw.Write([uint32]$r.Start)
    $bw.Write([uint32]$r.Count)
    $bw.Write([byte]$ccIndex[$r.CC])
}
$bw.Flush()
$bytes = $ms.ToArray()
$bw.Dispose(); $ms.Dispose()
[IO.File]::WriteAllBytes($OutFile, $bytes)
"  已写入 $OutFile  $([math]::Round($bytes.Length/1MB,2)) MB"

foreach ($ip in @('1.1.1.1','8.8.8.8','104.16.0.1','114.114.114.114','203.0.113.1','142.250.199.206')) {
    $u = U32 $ip
    $lo = 0; $hi = $merged.Count - 1; $hit = $null
    while ($lo -le $hi) {
        $mid = [int](($lo + $hi) / 2)
        $r = $merged[$mid]
        if ($u -lt $r.Start) { $hi = $mid - 1 }
        elseif ($u -ge ($r.Start + $r.Count)) { $lo = $mid + 1 }
        else { $hit = $r; break }
    }
    "  查 $ip -> " + $(if ($hit) { $hit.CC } else { '(未收录)' })
}
