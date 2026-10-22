# 提权辅助：以管理员身份重启目标脚本，并等待其结束
# 由 auto-optimize.cmd 调用，也可单独使用：
#   powershell -NoProfile -ExecutionPolicy Bypass -File elevate.ps1 <目标文件>
# 退出码: 0 = 提权后的进程正常结束; 1 = 提权被拒/失败

param([Parameter(Mandatory = $true)][string]$Target)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Target)) {
    Write-Host ''
    Write-Host "  [X] 目标文件不存在: $Target" -ForegroundColor Red
    exit 1
}
$Target = (Resolve-Path $Target).Path

# 已经是管理员就直接跑，不用再提权
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    & $Target
    exit $LASTEXITCODE
}

try {
    # -Wait 很关键：本进程要一直活着，外层 .cmd 的窗口才不会一闪而过
    $p = Start-Process -FilePath $Target -Verb RunAs -PassThru -Wait
    exit $p.ExitCode
}
catch {
    $msg = $_.Exception.Message
    Write-Host ''
    Write-Host '  [X] 提权失败' -ForegroundColor Red
    Write-Host "      原因: $msg" -ForegroundColor DarkGray
    Write-Host ''
    if ($msg -match 'canceled|cancelled|取消') {
        Write-Host '  UAC 提示被取消了。请注意：提示出现在【变暗的安全桌面】上，' -ForegroundColor Yellow
        Write-Host '  不是普通窗口 —— 整个屏幕会先变暗，然后才出现按钮。' -ForegroundColor Yellow
    }
    exit 1
}
