# 截取指定窗口（按标题匹配）
param([string]$TitlePart = 'VRChat', [string]$Out = "$env:TEMP\shot.png", [int]$ProcId = 0)

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
"@
[void][Dpi]::SetProcessDPIAware()   # 必须：否则 GetWindowRect 返回逻辑坐标，截不全
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win {
    [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string n);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    public static IntPtr Find(string part) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            string t = sb.ToString();
            if (t.Length > 0 && t.IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0) {
                found = h; return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

if ($ProcId -gt 0) {
    $pr = Get-Process -Id $ProcId -EA SilentlyContinue
    if (-not $pr) { "  PID $ProcId 不存在"; exit 1 }
    $h = $pr.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { "  PID $ProcId 没有主窗口"; exit 1 }
} else {
    $h = [Win]::Find($TitlePart)
}
if ($h -eq [IntPtr]::Zero) { "  找不到窗口"; exit 1 }
[void][Win]::ShowWindow($h, 9)      # SW_RESTORE
[void][Win]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 1200

$r = New-Object Win+RECT
[void][Win]::GetWindowRect($h, [ref]$r)
$w = $r.R - $r.L
$hh = $r.B - $r.T
"  窗口位置: ($($r.L),$($r.T))  尺寸: ${w}x${hh}"

$bmp = New-Object System.Drawing.Bitmap($w, $hh)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size($w, $hh)))
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"  已保存: $Out  ($([math]::Round((Get-Item $Out).Length/1KB,1)) KB)"
