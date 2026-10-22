# =============================================================================
#  生成代码签名证书（自签名）
#
#  说明：
#    自签名证书能消除「未知发布者」，但无法消除 SmartScreen 的
#    「Windows 已保护你的电脑」提示 —— 那需要 CA 签发的 EV/OV 代码签名证书。
#    想要彻底免提示，把本脚本产出的 .cer 发给用户装一次（或企业内预置）。
#
#  用法：右键「使用 PowerShell 运行」，或在提权 PowerShell 里执行
# =============================================================================
[CmdletBinding()]
param(
    [string]$Subject  = 'CN=VRChat Tool, O=VRChat-Tool, C=CN',
    [string]$PfxPwd   = 'vrctool',
    [int]   $Years    = 10
)

$ErrorActionPreference = 'Stop'
$CertDir = Join-Path $PSScriptRoot 'cert'
New-Item -ItemType Directory -Path $CertDir -Force | Out-Null
$Pfx = Join-Path $CertDir 'vrctool-codesign.pfx'
$Cer = Join-Path $CertDir 'vrctool-codesign.cer'

function Say($m) { Write-Host "  $m" }

Write-Host "===== 生成自签名代码签名证书 =====" -ForegroundColor Cyan
$c = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -EA SilentlyContinue |
     Where-Object { $_.Subject -eq $Subject } | Select-Object -First 1

if (-not $c) {
    $c = New-SelfSignedCertificate -Type CodeSigningCert `
            -Subject $Subject `
            -KeyUsage DigitalSignature `
            -KeyAlgorithm RSA -KeyLength 2048 `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -NotAfter (Get-Date).AddYears($Years) `
            -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    Say "新证书已创建"
} else {
    Say "已存在，复用"
}
Say "主题    : $($c.Subject)"
Say "指纹    : $($c.Thumbprint)"
Say "有效期至: $($c.NotAfter)"

$sec = ConvertTo-SecureString -String $PfxPwd -Force -AsPlainText
Export-PfxCertificate -Cert $c -FilePath $Pfx -Password $sec -Force | Out-Null
Export-Certificate   -Cert $c -FilePath $Cer -Force | Out-Null
Say "已导出  : $Pfx  (密码 $PfxPwd)"
Say "已导出  : $Cer"

# 让本机信任这张证书，否则签名包在别人机器上仍显示「未知发布者」
Write-Host "===== 导入本机信任链 =====" -ForegroundColor Cyan
$cert2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Cer)
foreach ($storeName in @('Root', 'TrustedPublisher')) {
    try {
        $st = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, 'CurrentUser')
        $st.Open('ReadWrite'); $st.Add($cert2); $st.Close()
        Say "已导入 CurrentUser\$storeName"
    } catch {
        Say "导入 $storeName 失败: $($_.Exception.Message)"
    }
}

Write-Host ""
Say "下一步：把 cert\vrctool-codesign.cer 一起发出去，"
Say "        用户双击导入后，签名就显示为可信的「VRChat Tool」。"
