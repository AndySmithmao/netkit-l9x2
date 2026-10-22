using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using Microsoft.Win32;

namespace VrcTool
{
    /// <summary>
    /// 内置内核的种类。目前两个：winws（DPI 伪装）和 mihomo（代理/TUN）。
    /// </summary>
    public enum DriverKind { Winws, Mihomo }

    /// <summary>某一时刻某个内核的状态快照（给 UI 用）。</summary>
    public sealed class DriverState
    {
        public DriverKind Kind;
        public string DisplayName = "";
        public string Version = "";
        public bool Running;
        public int Pid;
        public string Dir = "";
        public string LastError = "";
        public DateTime StartedAt = DateTime.MinValue;

        public string StatusText
        {
            get
            {
                if (Running) return "运行中" + (Pid > 0 ? "（PID " + Pid + "）" : "");
                if (!string.IsNullOrEmpty(LastError)) return "已停止（" + LastError + "）";
                return "已停止";
            }
        }
    }

    /// <summary>
    /// 内核（winws / mihomo）的生命周期管理。
    ///
    /// 设计要点（都是踩坑后定的）：
    ///
    /// 1) **不再用 Windows 服务跑 winws。**
    ///    以前 winws 由 SCM 拉起，用户一"停止服务"，WinDivert 在 BFE 里注册的
    ///    WFP 对象不会释放，之后再启动必然报 FWP_E_IN_USE(0x8032000A)，
    ///    试过卸驱动 / 删服务键 / 重启 BFE / 直接调 WFP API 删除，
    ///    只有重启电脑能清（2026-10-18 实测）。
    ///    改成应用自己托管的子进程后：停止 = 进程正常退出，句柄关闭，
    ///    内核对象随之释放，可以立刻再启动 —— 这就是"关闭后能重启"的修法。
    ///
    /// 2) **退出应用必须带走内核。** 主窗口关闭时调 StopAll()，
    ///    并对历史残留进程做一次清扫（按可执行文件路径匹配，避免误杀别的程序）。
    ///
    /// 3) **winws 与 mihomo TUN 互斥。** 两者都在网络层动手：winws 伪装 TLS
    ///    首包，TUN 会把包整个接管，叠加会互相破坏（实测 vrchat.com 直接打不开）。
    ///    所以开启 mihomo TUN 前先停 winws，反之亦然，并在日志里说明原因。
    /// </summary>
    public static class DriverManager
    {
        private static readonly object gate = new object();
        private static readonly Dictionary<DriverKind, Process> procs = new Dictionary<DriverKind, Process>();
        private static readonly Dictionary<DriverKind, string> lastErrors = new Dictionary<DriverKind, string>();
        // 用户主动关闭时，退出码会被记成"异常退出"，这里标记一下，避免吓人
        static readonly HashSet<DriverKind> intentionalStops = new HashSet<DriverKind>();
        private static readonly Dictionary<DriverKind, DateTime> startedAt = new Dictionary<DriverKind, DateTime>();
        private static readonly Dictionary<DriverKind, string> dirs = new Dictionary<DriverKind, string>();
        private static readonly Dictionary<DriverKind, string> versions = new Dictionary<DriverKind, string>();

        public static string RootDir
        {
            get
            {
                string b = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "VrcTool", "drivers");
                try { Directory.CreateDirectory(b); } catch { }
                return b;
            }
        }

        public static string LogPath
        {
            get
            {
                string d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "VrcTool", "logs");
                try { Directory.CreateDirectory(d); } catch { }
                return Path.Combine(d, "drivers.log");
            }
        }

        public static void Log(string line)
        {
            try
            {
                string s = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + line;
                File.AppendAllText(LogPath, s + "\r\n", new UTF8Encoding(true));
            }
            catch { }
        }

        // ---------------------------------------------------------------- 对外

        public static DriverState Get(DriverKind kind)
        {
            lock (gate)
            {
                Process p;
                procs.TryGetValue(kind, out p);
                bool running = p != null && !p.HasExited;
                DriverState st = new DriverState();
                st.Kind = kind;
                st.DisplayName = kind == DriverKind.Winws ? "winws（DPI 伪装）" : "mihomo（代理内核）";
                st.Running = running;
                st.Pid = running ? SafePid(p) : 0;
                st.Dir = DirOf(kind);
                string ver;
                if (versions.TryGetValue(kind, out ver) && !string.IsNullOrEmpty(ver)) st.Version = ver;
                else st.Version = DetectVersion(kind, st.Dir);
                string err;
                if (lastErrors.TryGetValue(kind, out err)) st.LastError = err;
                DateTime t;
                if (startedAt.TryGetValue(kind, out t)) st.StartedAt = t;
                return st;
            }
        }

        /// <summary>启动某个内核。已在运行则返回 true 并说明。</summary>
        public static bool Start(DriverKind kind, out string message, string extraArgs = null)
        {
            lock (gate)
            {
                string why;
                if (!EnsureRuntime(kind, out why))
                {
                    message = why;
                    lastErrors[kind] = why;
                    Log("启动失败 " + kind + ": " + why);
                    return false;
                }

                Process cur;
                if (procs.TryGetValue(kind, out cur) && cur != null && !cur.HasExited)
                {
                    message = "已经在运行了（PID " + SafePid(cur) + "）";
                    return true;
                }

                // 冲突协调：TUN 与 winws 不能共存
                if (kind == DriverKind.Mihomo && TuningEnabled())
                {
                    string m2;
                    if (IsRunning(DriverKind.Winws)) Stop(DriverKind.Winws, true, out m2);
                    Log("mihomo 启用 TUN：已先停止 winws（两者在数据包层会互相破坏）");
                }
                if (kind == DriverKind.Winws && TuningEnabled())
                {
                    message = "mihomo 的 TUN 正在运行，winws 会和它冲突。请先关闭 mihomo 的 TUN。";
                    lastErrors[kind] = "与 mihomo TUN 冲突";
                    Log("拒绝启动 winws: 原因同上");
                    return false;
                }

                try
                {
                    string dir = DirOf(kind);
                    string exe = Path.Combine(dir, kind == DriverKind.Winws ? "winws.exe" : "mihomo.exe");
                    if (!File.Exists(exe))
                    {
                        message = "找不到 " + exe;
                        lastErrors[kind] = "内核文件缺失";
                        return false;
                    }

                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = exe;
                    psi.WorkingDirectory = dir;
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    psi.RedirectStandardOutput = true;
                    psi.RedirectStandardError = true;

                    if (kind == DriverKind.Winws)
                    {
                        psi.Arguments = string.IsNullOrEmpty(extraArgs) ? BuildWinwsArgs(dir) : extraArgs;
                    }
                    else
                    {
                        string cfg = MihomoConfig.EnsureConfig(dir);
                        psi.Arguments = "-d \"" + dir + "\" -f \"" + cfg + "\"";
                    }

                    StringBuilder captured = new StringBuilder();
                    Process p = new Process();
                    p.StartInfo = psi;
                    p.EnableRaisingEvents = true;
                    p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) Log("[" + kind + "] " + e.Data); };
                    p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
                    {
                        if (e.Data == null) return;
                        Log("[" + kind + "]! " + e.Data);
                        // 留住 stderr，启动失败时用它给出人话解释（例如 FWP_E_IN_USE）
                        lock (captured)
                        {
                            captured.AppendLine(e.Data);
                            if (captured.Length > 8000) captured.Remove(0, captured.Length - 8000);
                        }
                    };
                    p.Exited += delegate
                    {
                        int code = -1;
                        try { code = p.ExitCode; } catch { }
                        Log(kind + " 退出，ExitCode=" + code);
                        bool byUser = intentionalStops.Remove(kind);
                        lastErrors[kind] = (code == 0 || byUser) ? "" : "异常退出（代码 " + code + "）";
                    };

                    p.Start();
                    try { p.BeginOutputReadLine(); p.BeginErrorReadLine(); } catch { }

                    procs[kind] = p;
                    startedAt[kind] = DateTime.Now;
                    lastErrors[kind] = "";

                    // 用 3 秒确认它没秒退（winws 撞 FWP / mihomo 配置错都会立刻退出）
                    Thread.Sleep(1200);
                    if (p.HasExited)
                    {
                        int code = -1;
                        try { code = p.ExitCode; } catch { }
                        string raw = "代码 " + code;
                        string text;
                        lock (captured) { text = captured.ToString(); }
                        string why2 = Explain(kind, text);
                        if (string.IsNullOrEmpty(why2)) why2 = Explain(kind, raw);
                        string hint = (kind == DriverKind.Winws
                            ? "winws 立刻退出了（" + raw + "）。"
                            : "mihomo 立刻退出了（" + raw + "）。多半是配置/订阅无效。")
                            + (string.IsNullOrEmpty(why2) ? " 详见 logs\\drivers.log。" : "\r\n\r\n" + why2);
                        lastErrors[kind] = string.IsNullOrEmpty(why2) ? "启动后立即退出" : why2;
                        Log(hint);
                        message = hint;
                        procs.Remove(kind);
                        return false;
                    }

                    message = "已启动（PID " + SafePid(p) + "）";
                    Log("启动 " + kind + " OK, pid=" + SafePid(p));
                    return true;
                }
                catch (Exception ex)
                {
                    lastErrors[kind] = ex.Message;
                    Log("启动 " + kind + " 异常: " + ex.Message);
                    message = "启动失败：" + ex.Message;
                    return false;
                }
            }
        }

        /// <summary>停止某个内核。graceful=true 先礼后兵（关标准输入/CloseMainWindow，再 Kill 树）。</summary>
        public static bool Stop(DriverKind kind, bool graceful, out string message)
        {
            lock (gate)
                intentionalStops.Add(kind);
            {
                Process p;
                if (!procs.TryGetValue(kind, out p) || p == null || p.HasExited)
                {
                    procs.Remove(kind);
                    SweepOrphans(kind);
                    message = "本来就没在运行";
                    return true;
                }

                try
                {
                    int pid = SafePid(p);
                    if (graceful)
                    {
                        try { p.CloseMainWindow(); } catch { }
                        try { p.StandardInput.Close(); } catch { }
                        if (!p.WaitForExit(2500))
                        {
                            KillTree(pid);
                            p.WaitForExit(3000);
                        }
                    }
                    else
                    {
                        KillTree(pid);
                        p.WaitForExit(3000);
                    }

                    bool gone = p.HasExited;
                    procs.Remove(kind);
                    startedAt.Remove(kind);
                    Log("停止 " + kind + " pid=" + pid + " -> " + (gone ? "已退出" : "仍在运行"));
                    message = gone ? "已停止" : "停止超时（进程可能仍在）";
                    return gone;
                }
                catch (Exception ex)
                {
                    Log("停止 " + kind + " 异常: " + ex.Message);
                    message = "停止失败：" + ex.Message;
                    return false;
                }
            }
        }

        public static bool Restart(DriverKind kind, out string message)
        {
            string m1;
            Stop(kind, true, out m1);
            Thread.Sleep(400);
            return Start(kind, out message);
        }

        public static bool IsRunning(DriverKind kind)
        {
            lock (gate)
            {
                Process p;
                return procs.TryGetValue(kind, out p) && p != null && !p.HasExited;
            }
        }

        /// <summary>关闭应用 / 系统退出时调用：把两个内核都收掉，并清扫历史残留。</summary>
        public static void StopAll()
        {
            Log("应用退出：停止所有内核");
            foreach (DriverKind k in new[] { DriverKind.Winws, DriverKind.Mihomo })
            {
                try
                {
                    string m;
                    if (IsRunning(k)) Stop(k, true, out m);
                    else SweepOrphans(k);
                }
                catch (Exception ex) { Log("StopAll " + k + " 异常: " + ex.Message); }
            }
        }

        /// <summary>
        /// 清理"上次没退干净"的进程：只杀 可执行文件路径落在我们 drivers 目录下的进程，
        /// 绝不按进程名乱杀（用户可能自己在别处跑 mihomo）。
        /// </summary>
        public static int SweepOrphans(DriverKind kind)
        {
            int killed = 0;
            try
            {
                string dir = DirOf(kind);
                if (!Directory.Exists(dir)) return 0;
                string exeName = kind == DriverKind.Winws ? "winws" : "mihomo";
                foreach (Process p in Process.GetProcessesByName(exeName))
                {
                    try
                    {
                        string path = null;
                        try { path = p.MainModule.FileName; } catch { }
                        if (string.IsNullOrEmpty(path)) continue;
                        if (!path.StartsWith(dir, StringComparison.OrdinalIgnoreCase)) continue;
                        KillTree(p.Id);
                        killed++;
                        Log("清扫残留 " + kind + " pid=" + p.Id + " " + path);
                    }
                    catch { }
                }
            }
            catch { }
            return killed;
        }

        // ---------------------------------------------------------------- 内部

        private static int SafePid(Process p)
        {
            try { return p.Id; } catch { return 0; }
        }

        private static void KillTree(int pid)
        {
            try
            {
                string tk = Path.Combine(Environment.SystemDirectory, "taskkill.exe");
                ProcessStartInfo psi = new ProcessStartInfo(tk, "/F /T /PID " + pid);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                Process.Start(psi).WaitForExit(5000);
            }
            catch { }
        }

        private static string DirOf(DriverKind kind)
        {
            string d;
            if (dirs.TryGetValue(kind, out d) && !string.IsNullOrEmpty(d)) return d;
            string baseDir = Path.Combine(RootDir, kind == DriverKind.Winws ? "winws" : "mihomo");
            dirs[kind] = baseDir;
            return baseDir;
        }

        private static bool EnsureRuntime(DriverKind kind, out string why)
        {
            why = "";
            string dir = DirOf(kind);
            try { Directory.CreateDirectory(dir); } catch { }

            string exe = Path.Combine(dir, kind == DriverKind.Winws ? "winws.exe" : "mihomo.exe");
            if (!File.Exists(exe))
            {
                string err;
                if (!EmbeddedDriver.Extract(kind, dir, out err))
                {
                    why = "释放内置内核失败：" + err;
                    return false;
                }
            }
            return true;
        }

        private static string BuildWinwsArgs(string dir)
        {
            // 与脚本版保持一致的 hostlist；域名列表集中在这里，避免和 install.ps1 漂移
            return "--wf-tcp=80,443 " +
                   "--filter-tcp=443 --hostlist-domains=hello.vrchat.com,feedback.vrchat.com " +
                   "--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,sniext " +
                   "--dpi-desync-fooling=md5sig --dpi-desync-repeats=2 --new " +
                   "--filter-tcp=443 --hostlist-domains=vrchat.com,www.vrchat.com,assets.vrchat.com,docs.vrchat.com," +
                   "status.vrchat.com,creators.vrchat.com,mail.vrchat.com,help.vrchat.com,ask.vrchat.com " +
                   "--hostlist-exclude-domains=hello.vrchat.com,feedback.vrchat.com " +
                   "--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld " +
                   "--dpi-desync-fooling=md5sig --dpi-desync-repeats=6";
        }

        internal static string DetectVersion(DriverKind kind, string dir)
        {
            try
            {
                string verFile = Path.Combine(dir, "VERSION.txt");
                if (File.Exists(verFile)) return File.ReadAllText(verFile).Trim();
            }
            catch { }
            return "内置";
        }

        // ---------------------------------------------------------------- 自启

        private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "VrcTool";

        public static bool AutoStartApp
        {
            get
            {
                try
                {
                    using (RegistryKey k = Registry.CurrentUser.OpenSubKey(RunKeyPath))
                    {
                        if (k == null) return false;
                        string v = k.GetValue(RunValueName) as string;
                        return !string.IsNullOrEmpty(v);
                    }
                }
                catch { return false; }
            }
            set
            {
                try
                {
                    using (RegistryKey k = Registry.CurrentUser.CreateSubKey(RunKeyPath))
                    {
                        if (k == null) return;
                        if (value)
                        {
                            string exe = Environment.ProcessPath;
                            if (string.IsNullOrEmpty(exe)) return;
                            k.SetValue(RunValueName, "\"" + exe + "\" --tray", RegistryValueKind.String);
                        }
                        else
                        {
                            k.DeleteValue(RunValueName, false);
                        }
                    }
                    Log("开机自启 -> " + value);
                }
                catch (Exception ex) { Log("设置开机自启失败: " + ex.Message); }
            }
        }

        /// <summary>TUN 是否开启（由 mihomo 配置决定，UI 改配置后需重启 mihomo 生效）。</summary>
        public static bool TuningEnabled()
        {
            try
            {
                string dir = DirOf(DriverKind.Mihomo);
                return MihomoConfig.IsTunEnabled(dir);
            }
            catch { return false; }
        }

        // ---------------------------------------------------------------- 诊断 / 迁移

        /// <summary>把原始错误翻译成"用户能照做"的话。</summary>
        public static string Explain(DriverKind kind, string raw)
        {
            if (string.IsNullOrEmpty(raw)) return "";
            string t = raw.ToLowerInvariant();
            if (t.Contains("referenced by other objects") || t.Contains("0x8032000a") || t.Contains("fwp_e_in_use"))
                return "WinDivert 的内核对象还占着（FWP_E_IN_USE）。这是驱动被异常终止留下的残留，" +
                       "软件层删不掉 —— 重启一次电脑即可恢复。之后内核由本程序托管，不会再出现这种情况。";
            if (t.Contains("access is denied") || t.Contains("拒绝访问"))
                return "权限不足。本程序需要以管理员身份运行。";
            if (t.Contains("hvci") || t.Contains("内存完整性") || t.Contains("0x80320003"))
                return "内存完整性（HVCI）开着，WinDivert 无法加载。请在「Windows 安全中心 → 设备安全性 → 内核隔离」关掉后重启。";
            if (t.Contains("cannot find") || t.Contains("not found") || t.Contains("找不到"))
                return "找不到内核文件，可能被杀软隔离了。检查 %ProgramData%\\VrcTool\\drivers\\ 并给该目录加白名单。";
            return "";
        }

        /// <summary>
        /// 体检：返回一段可读的状态报告，用来回答"为什么开不起来"。
        /// 只读 + 一次 3 秒的 WinDivert 试探，不改系统。
        /// </summary>
        public static string Diagnose()
        {
            StringBuilder b = new StringBuilder();
            try
            {
                b.AppendLine("=== 内核体检 " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " ===");
                b.AppendLine("数据目录: " + RootDir);

                foreach (DriverKind k in new[] { DriverKind.Winws, DriverKind.Mihomo })
                {
                    string d = DirOf(k);
                    string exe = Path.Combine(d, k == DriverKind.Winws ? "winws.exe" : "mihomo.exe");
                    DriverState st = Get(k);
                    b.AppendLine("");
                    b.AppendLine(k.ToString() + ": " + st.StatusText);
                    b.AppendLine("  目录: " + d);
                    b.AppendLine("  可执行: " + (File.Exists(exe) ? "存在" : "缺失") + "  版本: " + st.Version);
                }

                try
                {
                    object v = Registry.GetValue(@"HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity", "Enabled", null);
                    b.AppendLine("");
                    b.AppendLine("HVCI(内存完整性): " + (v == null ? "未设置（通常=关闭）" : v.ToString()) + "   （1=开启，会导致 WinDivert 加载失败）");
                }
                catch { }

                try
                {
                    string q = RunTool("sc.exe", "query VRChatBypass", 5000);
                    bool exists = q != null && !q.Contains("1060");
                    bool running = q != null && q.Contains("RUNNING");
                    b.AppendLine("");
                    b.AppendLine("旧服务 VRChatBypass: " + (exists ? (running ? "存在且运行中 ← 建议迁移（停掉并禁用）" : "存在（已停止）") : "不存在（已迁移）"));
                }
                catch { }

                string probe = ProbeWinDivert();
                b.AppendLine("");
                b.AppendLine("WinDivert 试探: " + probe);
                string hint = Explain(DriverKind.Winws, probe);
                if (!string.IsNullOrEmpty(hint)) b.AppendLine("  → 处置：" + hint);
            }
            catch (Exception ex)
            {
                b.AppendLine("体检异常: " + ex.Message);
            }
            Log("诊断:\r\n" + b.ToString());
            return b.ToString();
        }

        /// <summary>短暂起一个 winws 探针，看过滤器能不能开（不常驻，3 秒后杀掉）。</summary>
        private static string ProbeWinDivert()
        {
            try
            {
                string dir = DirOf(DriverKind.Winws);
                string exe = Path.Combine(dir, "winws.exe");
                if (!File.Exists(exe)) return "失败：winws.exe 不存在（先点一次「开启」让它释放内置内核）";

                ProcessStartInfo psi = new ProcessStartInfo(exe,
                    "--wf-tcp=443 --filter-tcp=443 --dpi-desync=fake --dpi-desync-fooling=md5sig");
                psi.WorkingDirectory = dir;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardError = true;
                psi.RedirectStandardOutput = true;
                Process p = Process.Start(psi);
                var err = p.StandardError.ReadToEndAsync();
                var o = p.StandardOutput.ReadToEndAsync();
                bool exited = p.WaitForExit(3000);
                if (!exited)
                {
                    try { p.Kill(); } catch { }
                    return "正常（能打开过滤器；探针已关闭）";
                }
                string msg = ((err.Result ?? "") + " " + (o.Result ?? "")).Replace("\r", " ").Replace("\n", " ").Trim();
                return "失败：" + msg;
            }
            catch (Exception ex) { return "失败：" + ex.Message; }
        }

        private static string RunTool(string file, string args, int timeoutMs)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(SystemToolPath(file), args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                Process p = Process.Start(psi);
                StringBuilder sb = new StringBuilder();
                sb.Append(p.StandardOutput.ReadToEnd());
                sb.Append(p.StandardError.ReadToEnd());
                p.WaitForExit(timeoutMs);
                return sb.ToString();
            }
            catch { return null; }
        }

        private static string SystemToolPath(string name)
        {
            if (name == "sc.exe") return Path.Combine(Environment.SystemDirectory, "sc.exe");
            return name;
        }

        /// <summary>
        /// 旧服务的当前状态：不存在 / RUNNING / STOPPED / DISABLED。
        /// 新版不再用服务，但旧安装会留下它 —— 不迁移的话，它会和新模型抢同一份过滤器。
        /// </summary>
        public static string LegacyServiceStatus()
        {
            try
            {
                string q = RunTool("sc.exe", "query VRChatBypass", 5000);
                if (q == null) return "未知";
                if (q.Contains("1060")) return "不存在";
                if (q.Contains("RUNNING")) return "RUNNING";
                if (q.Contains("STOPPED")) return "STOPPED";
                return "其他";
            }
            catch { return "未知"; }
        }
        /// <summary>
        /// 迁移：把旧版留下的 Windows 服务停掉并禁用，避免它和新模型抢 WinDivert。
        /// 只改状态和启动类型，**不删除服务键** —— 驱动仍加载时删除会造成更麻烦的残留。
        /// </summary>
        public static string MigrateLegacyService()
        {
            StringBuilder b = new StringBuilder();
            try
            {
                string q = RunTool("sc.exe", "query VRChatBypass", 5000);
                if (q == null || q.Contains("1060"))
                {
                    b.AppendLine("没有旧服务，无需迁移。");
                    return b.ToString();
                }

                if (q.Contains("RUNNING"))
                {
                    b.AppendLine(RunTool("sc.exe", "stop VRChatBypass", 15000));
                    System.Threading.Thread.Sleep(1500);
                }
                b.AppendLine(RunTool("sc.exe", "config VRChatBypass start= disabled", 8000));
                b.AppendLine("");
                b.AppendLine("已把旧服务设为「禁用」，重启后不会再自启。");
                b.AppendLine("建议重启一次：让 WinDivert 的残留对象彻底清空，之后内核全部由本程序托管。");
                Log("迁移旧服务:\r\n" + b.ToString());
            }
            catch (Exception ex)
            {
                b.AppendLine("迁移失败：" + ex.Message);
                Log("迁移旧服务失败: " + ex.Message);
            }
            return b.ToString();
        }
    }
}
