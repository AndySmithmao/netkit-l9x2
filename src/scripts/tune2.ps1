# 决定性测试：让第1组独占 hello/feedback（用 exclude 防止第2组的 vrchat.com 抢走）
# 上一轮失败原因: 第2组 hostlist 含 vrchat.com，会自动匹配子域名，把这两个也匹配走了，
#                 导致实际生效的一直是第2组的 md5sig，第1组调参无效（7种手法结果完全相同即为症状）
$ErrorActionPreference = 'Continue'
$RootDir = if ($env:VRCTOOL_ROOT) { $env:VRCTOOL_ROOT } else { Split-Path $PSScriptRoot -Parent }
$DataDir = if ($env:VRCTOOL_DATA) { $env:VRCTOOL_DATA } else { Join-Path $RootDir 'data' }
# 以前这里用了未定义的 $installDir：日志会写到当前盘根（C:\tune2.log），
# 第 34 行还会把服务 binPath 改成 "\winws.exe ..." —— 直接把线上服务改坏。
$installDir = if ($env:VRCTOOL_TOOLS) { $env:VRCTOOL_TOOLS } else { Join-Path $RootDir 'tools' }
if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }
$svcName = 'VRChatBypass'
$log = Join-Path $DataDir 'tune2.log'
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[!] 需要管理员权限'; exit 1
}
'' | Set-Content -Path $log -Encoding UTF8
function L($s) { Write-Host $s; Add-Content -Path $log -Value $s -Encoding UTF8 -ErrorAction SilentlyContinue }

L '=== 决定性测试：第1组独占 hello/feedback ==='
L '关键: 第2组加 --hostlist-exclude-domains，阻止 vrchat.com 的子域匹配抢走这两个'
L ''

$SUB  = 'hello.vrchat.com,feedback.vrchat.com'
$MAIN = 'vrchat.com,www.vrchat.com,assets.vrchat.com,docs.vrchat.com,status.vrchat.com,creators.vrchat.com,mail.vrchat.com,help.vrchat.com,ask.vrchat.com'

function Apply {
    param([string]$SubMethod)
    $a = "--wf-tcp=80,443 " +
         "--filter-tcp=443 --hostlist-domains=$SUB $SubMethod --new " +
         "--filter-tcp=443 --hostlist-domains=$MAIN --hostlist-exclude-domains=$SUB " +
         "--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=md5sig --dpi-desync-repeats=6"
    & "$env:SystemRoot\System32\sc.exe" stop $svcName 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1400
    Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
    & "$env:SystemRoot\System32\sc.exe" config $svcName binPath= "`"$installDir\winws.exe`" $a" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300
    & "$env:SystemRoot\System32\sc.exe" start $svcName 2>&1 | Out-Null
    Start-Sleep -Milliseconds 2600
    return (((& "$env:SystemRoot\System32\sc.exe" query $svcName 2>&1 | Out-String) -match 'RUNNING'))
}
function Hit { param([string]$H,[int]$N=4)
    $ok=0
    for($i=1;$i -le $N;$i++){
        $o = & "$env:SystemRoot\System32\curl.exe" -sS -o NUL -k -A $UA --max-time 8 -w '%{http_code}' "https://$H/" 2>&1 | Out-String
        if(($o.Trim() -split '\s+')[0] -match '^[1-5]\d\d$'){ $ok++ }
    }
    return $ok }

$methods = @(
    @{ n='md5sig';        a='--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=md5sig --dpi-desync-repeats=6' },
    @{ n='badseq';        a='--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq --dpi-desync-repeats=6' },
    @{ n='badsum';        a='--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badsum --dpi-desync-repeats=6' },
    @{ n='badseq,badsum'; a='--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq,badsum --dpi-desync-repeats=6' },
    @{ n='hopbyhop';      a='--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=hopbyhop --dpi-desync-repeats=6' },
    @{ n='split2纯重排';   a='--dpi-desync=split2 --dpi-desync-split-pos=1' },
    @{ n='disorder纯重排'; a='--dpi-desync=disorder --dpi-desync-split-pos=1' },
    @{ n='multidisorder'; a='--dpi-desync=multidisorder --dpi-desync-split-pos=1,midsld' },
    @{ n='fakedsplit';    a='--dpi-desync=fakedsplit --dpi-desync-split-pos=1' }
)

L ('手法'.PadRight(18) + 'hello'.PadRight(8) + 'feedback'.PadRight(10) + 'help'.PadRight(8) + 'ask'.PadRight(8) + 'vrchat.com')
L ('-'*64)
$rows = New-Object System.Collections.Generic.List[object]
foreach ($m in $methods) {
    if (-not (Apply -SubMethod $m.a)) { L ("{0,-18} 服务启动失败" -f $m.n); continue }
    $a=Hit 'hello.vrchat.com'; $b=Hit 'feedback.vrchat.com'; $c=Hit 'help.vrchat.com'
    $d=Hit 'ask.vrchat.com';   $e=Hit 'vrchat.com'
    L ("{0,-18} {1,-8} {2,-10} {3,-8} {4,-8} {5}" -f $m.n, "$a/4", "$b/4", "$c/4", "$d/4", "$e/4")
    $rows.Add([pscustomobject]@{ n=$m.n; a=$m.a; hello=$a; fb=$b; help=$c; ask=$d; vrc=$e })
}

L ''
$best = $rows | Where-Object { $_.help -ge 3 -and $_.ask -ge 3 -and $_.vrc -ge 3 } |
        Sort-Object @{e={$_.hello + $_.fb};Descending=$true}, @{e={$_.hello};Descending=$true} | Select-Object -First 1
if ($best) {
    L ">>> 最优: $($best.n)  hello=$($best.hello)/4 feedback=$($best.fb)/4"
    Apply -SubMethod $best.a | Out-Null
} else {
    L '>>> 没有一组能满足条件，回退 md5sig'
    Apply -SubMethod '--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=md5sig --dpi-desync-repeats=6' | Out-Null
}

L ''
L '--- 最终回归（各 3 次）---'
$check = @('www.bing.com','outlook.com','www.baidu.com','www.taobao.com','vrchat.com','www.vrchat.com',
           'docs.vrchat.com','assets.vrchat.com','status.vrchat.com','creators.vrchat.com','mail.vrchat.com',
           'api.vrchat.cloud','files.vrchat.cloud','hello.vrchat.com','help.vrchat.com','ask.vrchat.com','feedback.vrchat.com')
$bad=@()
foreach ($h in $check) {
    $r = Hit $h 3
    $mark='[ok]'; if($r -lt 3){ $mark = if($r -eq 0){'[x] '}else{'[~] '}; $bad += $h }
    L ("  {0} {1,-24} {2}/3" -f $mark, $h, $r)
}
L ''
if ($bad.Count -eq 0) { L '=== 全部通过 ===' } else { L ("未全通: " + ($bad -join ', ')) }
L '最终参数:'
L (((& "$env:SystemRoot\System32\sc.exe" qc $svcName 2>&1 | Out-String) -split "`n" | Where-Object { $_ -match 'BINARY_PATH' }) | ForEach-Object { $_.Trim() })

exit 0
