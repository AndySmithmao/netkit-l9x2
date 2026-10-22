// vswhere.exe 转发 shim
// 原因：makemica 调用 `vswhere -latest -property installationPath`，
//       而 vswhere 默认不把 Visual Studio BuildTools 算作 Visual Studio
//       （需要 -products *）。本 shim 自动补上该参数后转发给真身。
// 原文件被改名为 vswhere_orig.exe，删除本文件并改回原名即可完全还原。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

class VswhereShim
{
    static int Main(string[] args)
    {
        string here = AppDomain.CurrentDomain.BaseDirectory;
        string real = Path.Combine(here, "vswhere_orig.exe");
        if (!File.Exists(real)) real = Path.Combine(here, "vswhere.real.exe");
        if (!File.Exists(real))
        {
            Console.Error.WriteLine("vswhere shim: 找不到真身 vswhere_orig.exe");
            return 1;
        }

        List<string> list = new List<string>(args);
        bool hasProducts = false;
        foreach (string a in list)
            if (a.Equals("-products", StringComparison.OrdinalIgnoreCase)) { hasProducts = true; break; }

        if (!hasProducts) { list.Add("-products"); list.Add("*"); }

        StringBuilder sb = new StringBuilder();
        foreach (string a in list)
        {
            if (sb.Length > 0) sb.Append(' ');
            if (a.IndexOf(' ') >= 0 || a.IndexOf('"') >= 0)
                sb.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
            else sb.Append(a);
        }

        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(real);
            psi.Arguments = sb.ToString();
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            psi.WorkingDirectory = here;

            Process p = Process.Start(psi);
            string o = p.StandardOutput.ReadToEnd();
            string e = p.StandardError.ReadToEnd();
            p.WaitForExit();
            if (o.Length > 0) Console.Out.Write(o);
            if (e.Length > 0) Console.Error.Write(e);
            return p.ExitCode;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("vswhere shim: " + ex.Message);
            return 1;
        }
    }
}
