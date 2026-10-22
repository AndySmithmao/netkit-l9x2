# =============================================================================
#  hardclick.ps1 —— 可靠的窗口点击器
#    1) 声明 DPI 感知，让坐标和截图一致（都是物理像素）
#    2) 先把目标窗口拉到前台，避免点到别的窗口
#    3) 用真实的 SetCursorPos + mouse_event 点击
#
#  用法: powershell -File hardclick.ps1 -Title 安装程序 -Points "1025,640;646,706"
# =============================================================================
param(
    [string]$Title  = '安装程序',
    [string]$Points = '',          # "x,y;x,y" 物理像素
    [string]$Shot   = '',
    [int]   $Settle = 900
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class HardClick
{
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }

    public static IntPtr Found = IntPtr.Zero;

    public static bool Find(string part)
    {
        Found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p)
        {
            if (!IsWindowVisible(h) || IsIconic(h)) return true;
            StringBuilder sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            if (sb.ToString().IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                Found = h;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return Found != IntPtr.Zero;
    }

    public static void Activate()
    {
        if (Found == IntPtr.Zero) return;
        ShowWindow(Found, 9);              // SW_RESTORE
        BringWindowToTop(Found);
        SetForegroundWindow(Found);
    }

    public static void Click(int x, int y)
    {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(180);
        mouse_event(0x0002, 0, 0, 0, IntPtr.Zero);   // LEFTDOWN
        System.Threading.Thread.Sleep(90);
        mouse_event(0x0004, 0, 0, 0, IntPtr.Zero);   // LEFTUP
    }

    public static string WhatAt(int x, int y)
    {
        POINT p; p.X = x; p.Y = y;
        IntPtr h = WindowFromPoint(p);
        if (h == IntPtr.Zero) return "(none)";
        IntPtr root = GetAncestor(h, 2);
        StringBuilder t = new StringBuilder(512); GetWindowText(root, t, 512);
        StringBuilder c = new StringBuilder(256); GetClassName(root, c, 256);
        uint pid; GetWindowThreadProcessId(root, out pid);
        string pn = "?";
        try { pn = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
        return "pid=" + pid + "(" + pn + ") " + c + " '" + t + "'";
    }
}
'@

[void][HardClick]::SetProcessDPIAware()

Write-Output "DPI 感知: 已开启（坐标 = 物理像素）"

if (-not [HardClick]::Find($Title)) {
    Write-Output "找不到标题含「$Title」的窗口"
    exit 1
}
Write-Output ("找到窗口 hwnd=" + [HardClick]::Found)

[HardClick]::Activate()
Start-Sleep -Milliseconds $Settle

if ($Points) {
    foreach ($pt in ($Points -split ';')) {
        $xy = $pt -split ','
        if ($xy.Count -ne 2) { continue }
        $x = [int]$xy[0].Trim()
        $y = [int]$xy[1].Trim()
        Write-Output ("点击 ($x,$y)   该处窗口: " + [HardClick]::WhatAt($x, $y))
        [HardClick]::Click($x, $y)
        Start-Sleep -Milliseconds 700
        [HardClick]::Activate()
        Start-Sleep -Milliseconds 250
    }
}

if ($Shot) {
    Start-Sleep -Milliseconds 700
    [HardClick]::Activate()
    Start-Sleep -Milliseconds 400
    $bmp = New-Object System.Drawing.Bitmap([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width,
                                            [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
    $bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Output "截图 -> $Shot"
}
