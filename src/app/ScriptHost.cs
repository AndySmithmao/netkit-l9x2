using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;

namespace VrcTool
{
    /// <summary>
    /// 脚本宿主：
    ///   1. 把编译进 EXE 的 .ps1 解压到一个**只有管理员能写**的目录
    ///   2. 通过环境变量把根目录 / 工具目录 / 数据目录传给脚本（全部相对 EXE 位置）
    ///   3. 程序退出时删除整个目录
    ///
    /// 为什么不再用 %TEMP%：
    ///   本程序是 requireAdministrator，而 %LOCALAPPDATA%\Temp 对当前用户是**完全控制**。
    ///   同用户的中等完整性进程（任何不需要 UAC 的程序）可以覆盖里面落地的 install.ps1，
    ///   等用户点「安装」时以管理员身份执行 —— 这是一条本地提权路径，也是杀软
    ///   「提权进程从用户可写目录跑 PowerShell」的典型特征。
    ///   现在落到 %ProgramData%\VrcTool\scripts\&lt;随机&gt;\，并用 icacls 把 ACL 收紧成
    ///   仅 SYSTEM + Administrators（继承也断开），再用 SHA256 复核落地内容。
    /// </summary>
    public static class ScriptHost
    {
        /// <summary>EXE 所在目录（整个安装目录可以随意搬走，这里跟着变）</summary>
        public static readonly string RootDir;

        /// <summary>组件目录：winws.exe / WinDivert 等放这里</summary>
        public static readonly string ToolsDir;

        /// <summary>数据目录：扫描结果 / 实测结果等缓存</summary>
        public static readonly string DataDir;

        /// <summary>本次运行的临时脚本目录</summary>
        public static string TempScriptDir { get; private set; }

        private static readonly List<string> scriptNames = new List<string>();
        // 文件名 → 内嵌资源的 SHA256（十六进制小写）。运行前用它复核落地文件没被替换。
        private static readonly Dictionary<string, string> scriptHash =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        static ScriptHost()
        {
            RootDir = AppContext.BaseDirectory.TrimEnd('\\');
            ToolsDir = Path.Combine(RootDir, "tools");
            DataDir = Path.Combine(RootDir, "data");
        }

        /// <summary>把嵌入的脚本解压到受保护目录</summary>
        public static void Prepare()
        {
            Prepare(false);
        }

        /// <summary>把嵌入的脚本解压到受保护目录（force = 丢弃旧目录重新落地）</summary>
        public static void Prepare(bool force)
        {
            if (TempScriptDir != null && !force) return;

            if (force && TempScriptDir != null)
            {
                try { if (Directory.Exists(TempScriptDir)) Directory.Delete(TempScriptDir, true); } catch { }
                TempScriptDir = null;
            }

            scriptNames.Clear();
            scriptHash.Clear();
            LastError = null;

            string tag = Guid.NewGuid().ToString("N").Substring(0, 8);
            TempScriptDir = CreateProtectedDir(tag);

            Assembly asm = Assembly.GetExecutingAssembly();
            foreach (string res in asm.GetManifestResourceNames())
            {
                if (!res.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)) continue;

                // 资源名由 csproj 的 LogicalName 定成 "Scripts/<文件名>"，
                // 例如 VRChat优选工具.dll 里的 Scripts/install.ps1。
                string name = res;
                if (name.StartsWith("Scripts/", StringComparison.OrdinalIgnoreCase))
                {
                    name = name.Substring("Scripts/".Length);
                }
                else
                {
                    int slash = name.LastIndexOf('/');
                    if (slash >= 0) name = name.Substring(slash + 1);
                }
                if (!name.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)) continue;

                try
                {
                    using (Stream s = asm.GetManifestResourceStream(res))
                    {
                        if (s == null) continue;
                        byte[] buf = new byte[s.Length];
                        int read = 0;
                        while (read < buf.Length)
                        {
                            int n = s.Read(buf, read, buf.Length - read);
                            if (n <= 0) break;
                            read += n;
                        }
                        File.WriteAllBytes(Path.Combine(TempScriptDir, name), buf);
                        scriptNames.Add(name);
                        scriptHash[name] = ToHex(SHA256.Create().ComputeHash(buf));
                    }
                }
                catch (Exception ex)
                {
                    // 以前这里是空 catch：某个脚本没落地时界面只会说「找不到内置脚本」，
                    // 完全不知道是写文件失败。现在至少留一条可查的原因。
                    LastError = "解压 " + name + " 失败: " + ex.Message;
                }
            }

            try { Directory.CreateDirectory(ToolsDir); } catch { }
            try { Directory.CreateDirectory(DataDir); } catch { }

            if (scriptNames.Count == 0)
            {
                LastError = "EXE 里一个内置脚本都没找到 —— 嵌入资源名可能和 ScriptHost 的约定不一致（csproj 的 LogicalName 应是 Scripts/<文件名>）。";
            }
        }

        /// <summary>在受保护目录里写一个临时文件（wrapper 用），返回完整路径</summary>
        public static string WriteTempFile(string prefix, string content)
        {
            Prepare();
            if (string.IsNullOrEmpty(TempScriptDir)) return null;
            string p = Path.Combine(TempScriptDir, prefix + Guid.NewGuid().ToString("N").Substring(0, 8) + ".ps1");
            File.WriteAllText(p, content, new UTF8Encoding(true));
            return p;
        }

        /// <summary>落地文件是否与内嵌资源逐字节一致（防替换）</summary>
        public static bool VerifyFile(string fileName)
        {
            try
            {
                if (string.IsNullOrEmpty(TempScriptDir)) return false;
                string p = Path.Combine(TempScriptDir, fileName);
                if (!File.Exists(p)) return false;

                string want;
                if (!scriptHash.TryGetValue(fileName, out want)) return false;

                byte[] bytes = File.ReadAllBytes(p);
                string got = ToHex(SHA256.Create().ComputeHash(bytes));
                return string.Equals(want, got, StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }

        /// <summary>准备并确认脚本可用：hash 不符就重新落地一次，仍不行返回 false</summary>
        public static bool EnsureScript(string fileName)
        {
            Prepare();
            if (VerifyFile(fileName)) return true;

            Prepare(true);
            if (VerifyFile(fileName)) return true;

            LastError = "脚本落地校验失败（可能被杀软改动或替换）: " + fileName;
            return false;
        }

        /// <summary>Prepare 期间的可疑情况（正常为 null）。调用方应该把它显示出来。</summary>
        public static string LastError { get; private set; }

        /// <summary>脚本在临时目录中的完整路径</summary>
        public static string Path2(string fileName)
        {
            Prepare();
            return Path.Combine(TempScriptDir, fileName);
        }

        public static bool Exists(string fileName)
        {
            return File.Exists(Path2(fileName));
        }

        public static IList<string> ScriptNames { get { return scriptNames.AsReadOnly(); } }

        /// <summary>退出时删除临时目录</summary>
        public static void Cleanup()
        {
            string dir = TempScriptDir;
            TempScriptDir = null;
            if (!string.IsNullOrEmpty(dir))
            {
                for (int i = 0; i < 5; i++)
                {
                    try
                    {
                        if (Directory.Exists(dir)) Directory.Delete(dir, true);
                        break;
                    }
                    catch { System.Threading.Thread.Sleep(200); }
                }
                try
                {
                    string parent = Path.GetDirectoryName(dir);
                    if (!string.IsNullOrEmpty(parent) && Directory.Exists(parent)
                        && Directory.GetFileSystemEntries(parent).Length == 0)
                    {
                        Directory.Delete(parent);
                    }
                }
                catch { }
            }

            // 顺手清掉上一版留在 %TEMP%\VrcTool 的残留（只删创建超过 1 小时的）
            CleanupLegacyTemp();
        }

        private static void CleanupLegacyTemp()
        {
            try
            {
                string parent = Path.Combine(Path.GetTempPath(), "VrcTool");
                if (!Directory.Exists(parent)) return;
                foreach (string d in Directory.GetDirectories(parent))
                {
                    try
                    {
                        if ((DateTime.Now - Directory.GetCreationTime(d)).TotalHours < 1) continue;
                        Directory.Delete(d, true);
                    }
                    catch { }
                }
                try { if (Directory.GetFileSystemEntries(parent).Length == 0) Directory.Delete(parent); }
                catch { }
            }
            catch { }
        }

        /// <summary>把路径信息写进 wrapper 脚本开头的环境变量设置</summary>
        public static void AppendEnvSetup(StringBuilder sb)
        {
            sb.AppendLine("$env:VRCTOOL_ROOT  = '" + RootDir.Replace("'", "''") + "'");
            sb.AppendLine("$env:VRCTOOL_TOOLS = '" + ToolsDir.Replace("'", "''") + "'");
            sb.AppendLine("$env:VRCTOOL_DATA  = '" + DataDir.Replace("'", "''") + "'");
            sb.AppendLine("$env:VRCTOOL_TEMP  = '" + (TempScriptDir ?? "").Replace("'", "''") + "'");
        }

        // ------------------------------------------------------------------ 私有

        /// <summary>建 ProgramData 下的受保护目录；失败就退回 %TEMP%（并记录原因）</summary>
        private static string CreateProtectedDir(string tag)
        {
            try
            {
                string baseDir = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                    "VrcTool", "scripts");
                Directory.CreateDirectory(baseDir);

                string dir = Path.Combine(baseDir, tag);
                Directory.CreateDirectory(dir);
                HardenAcl(dir);
                return dir;
            }
            catch (Exception ex)
            {
                string dir = Path.Combine(Path.GetTempPath(), "VrcTool", tag);
                try { Directory.CreateDirectory(dir); } catch { }
                LastError = "受保护目录不可用，已退回 %TEMP%（安全性下降）: " + ex.Message;
                return dir;
            }
        }

        /// <summary>
        /// 用 icacls 把目录 ACL 收紧成「仅 SYSTEM + Administrators，且不继承」。
        /// 用 SID 而不是组名：中文系统上组名是「Administrators」还是「管理员」不确定，
        /// SID 永远有效。失败也不致命 —— ProgramData 默认给 Users 只读，已能挡住大多数替换。
        /// </summary>
        private static void HardenAcl(string dir)
        {
            try
            {
                string icacls = Path.Combine(Environment.SystemDirectory, "icacls.exe");
                if (!File.Exists(icacls)) return;

                ProcessStartInfo psi = new ProcessStartInfo(icacls);
                psi.Arguments = "\"" + dir + "\" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F /q";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;

                using (Process p = Process.Start(psi))
                {
                    string ignore = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                    ignore = null;
                    p.WaitForExit(5000);
                }
            }
            catch (Exception ex)
            {
                LastError = "临时目录 ACL 收紧失败（安全性下降）: " + ex.Message;
            }
        }

        private static string ToHex(byte[] bytes)
        {
            StringBuilder sb = new StringBuilder(bytes.Length * 2);
            for (int i = 0; i < bytes.Length; i++) sb.Append(bytes[i].ToString("x2"));
            return sb.ToString();
        }
    }
}
