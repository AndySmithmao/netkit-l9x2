using System;
using System.IO;
using System.Reflection;
using System.Text;

namespace VrcTool
{
    /// <summary>
    /// 内置内核的释放：把打包进程序集的 winws / mihomo 二进制释放到磁盘。
    ///
    /// 为什么要内置：以前内核要靠脚本从 GitHub 下载（国内经常失败），
    /// 而且下载失败时用户看到的只是"服务没启动"。内置之后开箱即用，
    /// 也能保证版本可控。
    ///
    /// 释放策略：
    ///   · 目录：%ProgramData%\VrcTool\drivers\{winws|mihomo}
    ///   · 用程序集版本号 + 文件长度做"是否需要重放"的判据，升级后自动覆盖
    ///   · 释放前先清扫占用该目录的残留进程（否则文件被占用写不进去）
    /// </summary>
    internal static class EmbeddedDriver
    {
        private static readonly string[] WinwsFiles = { "winws.exe", "cygwin1.dll", "WinDivert.dll", "WinDivert64.sys" };
        private static readonly string[] MihomoFiles = { "mihomo.exe" };

        public static bool Extract(DriverKind kind, string dir, out string error)
        {
            error = "";
            try
            {
                Directory.CreateDirectory(dir);
                string[] files = kind == DriverKind.Winws ? WinwsFiles : MihomoFiles;
                string stamp = Stamp(kind);

                // 已经释放过且标记一致 -> 直接用
                string marker = Path.Combine(dir, ".extracted");
                if (File.Exists(marker))
                {
                    try
                    {
                        if (File.ReadAllText(marker).Trim() == stamp)
                        {
                            bool all = true;
                            foreach (string f in files)
                                if (!File.Exists(Path.Combine(dir, f))) { all = false; break; }
                            if (all) return true;
                        }
                    }
                    catch { }
                }

                // 有进程占着就杀（只杀本目录下的）
                try { DriverManager.SweepOrphans(kind); } catch { }
                System.Threading.Thread.Sleep(200);

                Assembly asm = Assembly.GetExecutingAssembly();
                foreach (string f in files)
                {
                    string res = "Drivers/" + f;
                    Stream s = asm.GetManifestResourceStream(res);
                    if (s == null)
                    {
                        error = "程序集里缺少资源 " + res;
                        DriverManager.Log("释放失败: " + error);
                        return false;
                    }
                    string target = Path.Combine(dir, f);
                    try
                    {
                        if (File.Exists(target)) File.SetAttributes(target, FileAttributes.Normal);
                    }
                    catch { }
                    using (s)
                    using (FileStream fs = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        s.CopyTo(fs);
                    }
                }

                // 版本文字一并落盘，UI 直接读它
                string verName = kind == DriverKind.Winws ? "winws.VERSION.txt" : "mihomo.VERSION.txt";
                string verRes = "Drivers/" + verName;
                Stream vs = asm.GetManifestResourceStream(verRes);
                string ver = "";
                if (vs != null)
                {
                    using (vs)
                    using (StreamReader sr = new StreamReader(vs, Encoding.UTF8))
                    {
                        ver = sr.ReadToEnd().Trim();
                    }
                    try { File.WriteAllText(Path.Combine(dir, "VERSION.txt"), ver, new UTF8Encoding(false)); } catch { }
                }

                File.WriteAllText(marker, stamp, new UTF8Encoding(false));
                DriverManager.Log("已释放内置内核 " + kind + " -> " + dir + "  版本 " + ver);
                return true;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                DriverManager.Log("释放 " + kind + " 异常: " + ex.Message);
                return false;
            }
        }

        /// <summary>当前程序集里内核的"版本指纹"，升级后自动触发重新释放。</summary>
        private static string Stamp(DriverKind kind)
        {
            string v = "";
            try { v = Assembly.GetExecutingAssembly().GetName().Version.ToString(); } catch { }
            try
            {
                Assembly asm = Assembly.GetExecutingAssembly();
                string[] files = kind == DriverKind.Winws ? WinwsFiles : MihomoFiles;
                long total = 0;
                foreach (string f in files)
                {
                    Stream s = asm.GetManifestResourceStream("Drivers/" + f);
                    if (s != null) { total += s.Length; s.Dispose(); }
                }
                v += "|" + total;
            }
            catch { }
            return v;
        }
    }
}
