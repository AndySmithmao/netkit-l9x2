# ============================================================================
#  【一键完成】从零到能用
#
#  自动按顺序跑:
#     [1/5] 环境检查（服务 / 驱动 / hosts）
#     [2/5] 全量扫描（ICMP + TLS 全测；已有且新鲜则跳过）
#     [3/5] 延迟实测（两组 Top40，多轮交替）
#     [4/5] 下载测速（真实文件下载）
#     [5/5] 列出清单 → 你选 → 写 hosts → 验证
#           带 -NoPick（GUI 用）时只生成清单，选用交给主界面的「清单选用」窗口
#
#  用法:
#     powershell -ExecutionPolicy Bypass -File all-in-one.ps1
#     powershell -ExecutionPolicy Bypass -File all-in-one.ps1 -Quick          # 快速（约 8 分钟）
#     powershell -ExecutionPolicy Bypass -File all-in-one.ps1 -ForceScan      # 强制重扫
#     powershell -ExecutionPolicy Bypass -File all-in-one.ps1 -AutoPick       # 不询问，自动选最优
#     powershell -ExecutionPolicy Bypass -File all-in-one.ps1 -NoPick         # GUI 用：跑完交给清单窗口
# ============================================================================
param(
    [switch]$Quick,
    [switch]$ForceScan,
    [switch]$AutoPick,
    [switch]$Yes,
    # GUI 专用。GUI 起的进程 stdin 是无效句柄，Read-Host 一定拿不到输入 ——
    # 原来 GUI 传 -Yes 但没传 -AutoPick，第 5 步会走到交互式 list-and-pick，
    # 三次 Read-Host 全部落空 → 静默「已取消」→ 界面却报「全部完成」，hosts 一个字没写。
    # 带这个开关时第 5 步只做交付，真正的选用由主界面的「清单选用」窗口完成。
    [switch]$NoPick,
    [int]$TopN = 40,
    [int]$Rounds = 5,
    [int]$SpeedRounds = 2,
    [int]$ScanRate = 45,
    [int]$ScanThreads = 32
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'lib-common.ps1')

$T0 = Get-Date

# 收集各步骤的硬失败，最后统一汇报。
# 原来完全不看子脚本退出码：任何一步炸了，进度条照样 100%、日志照样「全部完成」。
$failed = New-Object System.Collections.Generic.List[string]

Show ''
Rule '='
Show '  【一键完成】VRChat 优选 IP' Cyan
Rule '='
Show ''
if ($Quick) { Show '  模式: 快速' DarkGray }

# ================================================================ 1 环境
Step 1 5 '环境检查'
Head '[1/5] 环境检查'

# ★ 一键完成也先查 HVCI / SAC：否则会先装服务失败，再白扫 24 分钟 ★
$hvciOn = $false
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
    if ($dg.SecurityServicesRunning -contains 2) { $hvciOn = $true }
} catch { }
if ($hvciOn) {
    Warn '内存完整性（HVCI）已开启 —— WinDivert 装不上过滤规则，服务起不来'
    Show '      处理：Windows 安全中心 → 设备安全性 → 内核隔离 → 关闭内存完整性 → 重启' Yellow
    Show '      然后重新点「一键完成」。' Yellow
    exit 2
}
$sacState = $null
try { $sacState = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState } catch { }
if ($sacState -eq 1) { Warn '智能应用控制（SAC）强制模式：自签名程序可能被拦，如遇“已被阻止”请先关闭 SAC' }

$admin = Test-Admin
Show ("       管理员权限      : " + $(if ($admin) { '是' } else { '否（无法写 hosts）' })) $(if ($admin) { 'Green' } else { 'Yellow' })

$svcOk = $false
$svc = (& "$env:SystemRoot\System32\sc.exe" query VRChatBypass 2>&1 | Out-String)
if ($svc -match 'RUNNING') { $svcOk = $true; Ok '服务 VRChatBypass : 运行中' }
elseif ($svc -match 'SERVICE_NAME') { Warn '服务 VRChatBypass : 已安装但未运行' }
else { Warn '服务 VRChatBypass : 未安装（需要先跑【安装】）' }

$drv = (& "$env:SystemRoot\System32\sc.exe" query WinDivert 2>&1 | Out-String)
Show ("       WinDivert 驱动  : " + $(if ($drv -match 'RUNNING') { '运行中' } else { '未运行' })) $(if ($drv -match 'RUNNING') { 'Green' } else { 'Yellow' })

$curA = Get-HostsIp 'api.vrchat.cloud'
$curB = Get-HostsIp 'files.vrchat.cloud'
Show ("       当前 hosts  A 组: $(if($curA){$curA}else{'(无)'})") DarkGray
Show ("       当前 hosts  B 组: $(if($curB){$curB}else{'(无)'})") DarkGray

if (-not $svcOk) {
    Write-Host ''
    if ($Yes) {
        # ★ 一键完成就该"一键" ★
        #   以前这里只警告一句就往下跑 24 分钟扫描 —— hosts 没写、服务没起、
        #   组件（winws/WinDivert）也可能没下载，测出来的 IP 一个都不生效。
        #   现在服务没运行就先自动跑一遍【安装】，装完再继续；装不起来才中止。
        Warn '服务没有运行 —— 先自动执行【安装】（下载组件 + 写 hosts + 建服务）'
        $inst = Join-Path $PSScriptRoot 'install.ps1'
        if (-not (Test-Path $inst)) {
            Bad "找不到 install.ps1，无法自动安装（请手动跑【功能0】安装）"
            exit 2
        }
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $inst 2>&1 |
            ForEach-Object { Write-Host $_ }
        $instCode = $LASTEXITCODE
        $svc = (& "$env:SystemRoot\System32\sc.exe" query VRChatBypass 2>&1 | Out-String)
        if ($svc -match 'RUNNING') {
            $svcOk = $true
            Ok '服务已由【安装】建立并运行'
        } else {
            Bad ("自动安装后服务仍未运行（install.ps1 退出码 $instCode）—— 已中止，避免白扫一遍")
            Show '       常见原因：杀软拦了 winws.exe / WinDivert 驱动签名被拦。' Yellow
            Show '       处理：把安装目录加入白名单，或临时关闭实时保护后重跑。' Yellow
            exit 2
        }
    } else {
        Warn '服务没有运行 —— 优选结果将无法生效'
        Show '       请先运行【功能0】安装:  powershell -ExecutionPolicy Bypass -File install.ps1' White
        Write-Host ''
        $ans = Read-Host '       仍旧继续（只做扫描测速）？(y = 继续，其他 = 退出)'
        if ($ans -notmatch '^[yY]') { exit 1 }
    }
}

# ================================================================ 2 全量扫描
Step 2 5 '全量扫描'
Head '[2/5] 全量扫描（ICMP + TLS）'
Prog 15 100 '全量扫描'

$needScan = $ForceScan
if (-not $needScan) {
    if (-not (Test-Path $script:FileScanCf) -or -not (Test-Path $script:FileScanCfr)) { $needScan = $true }
    else {
        $ageH = [int]((Get-Date) - (Get-Item $script:FileScanCf).LastWriteTime).TotalHours
        if ($ageH -gt 24) { $needScan = $true; Show "       已有扫描数据但已 $ageH 小时，需要重扫" Yellow }
        else { Show "       已有扫描数据（$ageH 小时前），跳过" Green }
    }
}

if ($needScan) {
    Show "       限速 $ScanRate/秒   并发 $ScanThreads   预计约 24 分钟" DarkGray
    Write-Host ''
    $doScan = $Yes
    if (-not $Yes) {
        $ans = Read-Host '       开始全量扫描？(y = 是，其他 = 跳过并使用旧数据)'
        if ($ans -match '^[yY]') { $doScan = $true }
    }
    if ($doScan) {
        $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $PSScriptRoot 'full-scan.ps1'),
                    '-Rate', $ScanRate, '-Threads', $ScanThreads)
        & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @psArgs
        if ($LASTEXITCODE -ne 0) { $failed.Add("全量扫描（退出码 $LASTEXITCODE）") }
    } else {
        if (-not (Test-Path $script:FileScanCf)) { Bad '没有可用数据，无法继续'; exit 1 }
        Warn '跳过扫描，使用现有数据'
    }
} 
if (-not (Test-Path $script:FileScanCf)) { Bad '全量扫描数据不存在，无法继续'; exit 1 }

# ================================================================ 3 延迟
Step 3 5 '延迟实测'
Head '[3/5] 延迟实测'
Prog 65 100 '延迟实测'
$psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $PSScriptRoot 'latency-test.ps1'),
            '-TopN', $TopN, '-Rounds', $Rounds)
if ($Quick) { $psArgs += '-Quick' }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @psArgs
if ($LASTEXITCODE -ne 0) { $failed.Add("延迟实测（退出码 $LASTEXITCODE）") }

# ================================================================ 4 测速
Step 4 5 '下载测速'
Head '[4/5] 下载测速'
Prog 80 100 '下载测速'
$psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $PSScriptRoot 'speedtest-batch.ps1'),
            '-Rounds', $SpeedRounds)
if ($Quick) { $psArgs += '-Quick' }
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @psArgs
if ($LASTEXITCODE -ne 0) { $failed.Add("下载测速（退出码 $LASTEXITCODE）") }

# ================================================================ 5 选用
Step 5 5 '清单选用'
Head '[5/5] 清单选用'
Prog 95 100 '清单选用'

# 前面有硬失败就别往下走了 —— 拿半截数据去选 IP 只会选出错的来
if ($failed.Count -gt 0) {
    Write-Host ''
    Bad "前 $($failed.Count) 个步骤失败，不再进入选用环节："
    foreach ($f in $failed) { Show "      - $f" Red }
    Write-Host ''
    Done 'fail' ($failed -join '；')
    exit 1
}

# GUI 模式：不做交互式选用，交给主界面的「清单选用」窗口
if ($NoPick) {
    Show ''
    Ok '扫描 / 实测全部完成，候选清单已生成'
    Show '       请回到主界面点「清单选用」挑选并写入 hosts。' White
    Write-Host ''
    Done 'ok' '扫描实测完成，等待人工选用'
    exit 0
}

if (-not $admin) {
    Warn '没有管理员权限，只能查看清单不能写入'
    Show ''
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'list-and-pick.ps1') -NoApply
    Show ''
    Show '  要真正写入，请用管理员 PowerShell 重跑本脚本' Yellow
    exit 0
}

if ($AutoPick) {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'list-and-pick.ps1') -Apply
} else {
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'list-and-pick.ps1')
}
if ($LASTEXITCODE -ne 0) { $failed.Add("清单选用（退出码 $LASTEXITCODE）") }

$el = [int]((Get-Date) - $T0).TotalSeconds
Write-Host ''
Rule '='
if ($failed.Count -gt 0) {
    Prog 100 100 '有步骤失败'
    Done 'fail' ($failed -join '；')
    Show "  【一键完成】有 $($failed.Count) 步没成功，请按上面的提示处理" Red
    foreach ($f in $failed) { Show "      - $f" Red }
} else {
    Prog 100 100 '全部完成'
    Done 'ok' "总耗时 $(Format-Eta $el)"
    Show "  【一键完成】全部结束，总耗时 $(Format-Eta $el)" Cyan
}
Rule '='
Write-Host ''

if ($failed.Count -gt 0) { exit 1 }

exit 0
