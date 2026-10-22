// =============================================================================
//  EnvCheckHelper —— 安装阶段的「环境检测 + 组件自动下载」
//
//  由 build-installer.ps1 注入到 MicaSetup 的 .dist 里，
//  在 InstallViewModel 解压完主程序之后调用。
//
//  依赖：winws.exe / WinDivert.dll / WinDivert64.sys / cygwin1.dll
//        原始来源在 GitHub（部分网络下直连不稳），所以按镜像列表尝试，
//        运行时先测速，从最快的源下载，失败自动换下一个。
//
//  本版本加固（对应「镜像投毒 / 断点续传 / 失败可见」三件事）：
//    1) 源地址锁 commit（RawBase 用 CommitSha 常量，不是 master）；
//    2) 下载内容做 SHA256 校验：内置 KnownSha256 清单强制校验，
//       没覆盖到的文件退回 components.lock「首次信任」；
//    3) 下载用 HttpWebRequest 手写 Range 续传循环，中断保留 .part 换源接着下；
//    4) 失败不再只写一行日志：LastFailureSummary 里带「哪个文件 / 试过哪些源 / 最后错误」。
//
//  版本锁定（2026-10-14 已填实，无需再补）：
//      CommitSha    = 6eb463a6758fb48cd101bc55dfd057e6e9d98af1
//      KnownSha256  = 4 个文件的 SHA256 全部填实，走强制校验模式
//  换 commit 时：必须用同一个 checkout 重算这 4 个哈希，并且同步
//  dist\scripts\install.ps1 里的 $CommitSha / $needFiles[].sha（脚本侧下载走另一条路径）。
// =============================================================================
using MicaSetup.Core;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace MicaSetup.Helper
{
    public static class EnvCheckHelper
    {
        // ---------------------------------------------------------------- 数据模型

        public sealed class Source
        {
            public string Name { get; private set; }
            public string Base { get; private set; }
            public long LatencyMs { get; set; }
            public bool Alive { get; set; }

            public Source(string name, string baseUrl)
            {
                Name = name;
                Base = baseUrl;
                LatencyMs = long.MaxValue;
                Alive = false;
            }
        }

        public sealed class Req
        {
            public string Name { get; private set; }
            public long MinBytes { get; private set; }
            public Req(string name, long minBytes) { Name = name; MinBytes = minBytes; }
        }

        // ---------------------------------------------------------------- 常量

        /// <summary>
        /// 上游 commit 锁定值 —— 这里必须锁具体 commit，绝对不能用 master。
        ///
        /// 原因：
        ///   · master 是随时移动的分支指针，上游任何一次新提交都会改变下载内容。
        ///     而下面的 KnownSha256 是写死的，两者一旦错位，用户侧只会看到
        ///     「莫名其妙校验失败」，排查成本极高。
        ///   · 分支指针可以被上游 force-push 改写甚至删除，等于把安装器的信任根
        ///     绑在一个会漂移的远端引用上；锁 commit 之后，内容在密码学上可复现。
        ///   · 镜像站（gh-proxy / ghproxy / ghfast / jsdelivr / gitmirror）都是按路径
        ///     透传的，锁了 commit 之后所有源返回的字节流必然同源，
        ///     断点续传时「A 源下一半、B 源接着下」也是安全的。
        ///
        /// 已锁定：bol-van/zapret-win-bundle @ 2026-09-18（见下面 CommitSha）。
        /// 换成别的 commit 时，必须用同一个 checkout 重算这 4 个哈希。
        /// 注意别自己编一个看起来像 SHA 的字符串 —— 拼错的 SHA 会让所有源都 404。
        /// </summary>
        private const string CommitSha = "6eb463a6758fb48cd101bc55dfd057e6e9d98af1";

        /// <summary>
        /// 组件来源基地址。格式：
        ///   https://raw.githubusercontent.com/bol-van/zapret-win-bundle/&lt;COMMIT_SHA&gt;/zapret-winws
        /// </summary>
        private const string RawBase =
            "https://raw.githubusercontent.com/bol-van/zapret-win-bundle/" + CommitSha + "/zapret-winws";

        /// <summary>下载源：镜像优先，GitHub 原始地址兜底。全部锁在同一个 commit 上。</summary>
        public static readonly Source[] Sources = new Source[]
        {
            new Source("gh-proxy",   "https://gh-proxy.com/" + RawBase),
            new Source("ghproxy",    "https://ghproxy.net/"  + RawBase),
            new Source("ghfast",     "https://ghfast.top/"   + RawBase),
            new Source("github",     RawBase),
            new Source("jsdelivr",   "https://cdn.jsdelivr.net/gh/bol-van/zapret-win-bundle@" + CommitSha + "/zapret-winws"),
            new Source("gitmirror",  "https://raw.gitmirror.com/bol-van/zapret-win-bundle/" + CommitSha + "/zapret-winws"),
        };

        /// <summary>需要的组件文件 + 最小合理大小（防止镜像返回 HTML 错误页）。</summary>
        public static readonly Req[] Files = new Req[]
        {
            new Req("winws.exe",       100 * 1024),
            new Req("WinDivert.dll",    20 * 1024),
            new Req("WinDivert64.sys",  40 * 1024),
            new Req("cygwin1.dll",    1000 * 1024),
        };

        /// <summary>
        /// 已固定版本的组件 SHA256 清单：键 = 文件名，值 = 64 位小写 hex。
        ///
        /// 上游没有发布官方哈希，所以这个清单初始为空 —— 此时走「首次信任」策略：
        ///   有记录 → **强制**校验；不匹配 = 该源失败，自动换源重试，并写日志；
        ///   无记录 → 下载成功后算一次 SHA256 存进 &lt;toolsDir&gt;\components.lock，
        ///            之后每次启动/重下都跟 lock 比对，不一致就报警并拒绝使用。
        ///
        /// 拿到真实 commit 后，用同一份产物把 4 个哈希补进来（小写 hex），例如：
        ///   KnownSha256.Add("winws.exe",       "<SHA256_winws.exe>");
        ///   KnownSha256.Add("WinDivert.dll",   "<SHA256_WinDivert.dll>");
        ///   KnownSha256.Add("WinDivert64.sys", "<SHA256_WinDivert64.sys>");
        ///   KnownSha256.Add("cygwin1.dll",     "<SHA256_cygwin1.dll>");
        /// 已填入真实哈希（2026-10-14 从 CommitSha 那个 commit 重新下载后逐个算的，
        /// 并且和本机既有安装里的 4 个文件字节一致），因此现在走**强制校验**模式，
        /// 「首次信任 + components.lock」那套只作为兜底。
        /// </summary>
        public static readonly Dictionary<string, string> KnownSha256 =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "winws.exe",       "2da71e80878dc270ac83f5893ecbb841f9752a57f1da8ff9325636b4346bc632" },
                { "WinDivert.dll",   "16abd6a029e65557c6a309bea7b13bf81fff4e193567582e1cddbf6719f323e0" },
                { "WinDivert64.sys", "8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2" },
                { "cygwin1.dll",     "103104a52e5293ce418944725df19e2bf81ad9269b9a120d71d39028e821499b" },
            };

        /// <summary>首次信任策略用的锁定文件名（放 tools 目录下，key=value 文本）。</summary>
        private const string LockFileName = "components.lock";

        // ---------------------------------------------------------------- 失败摘要

        /// <summary>
        /// 最近一次 EnsureComponents 失败的一句话摘要：
        /// 「哪个文件失败了、试过哪些源、最后什么错误」。
        /// 成功时为 null。安装界面只认 EnsureComponents 的 bool，
        /// 但把这里的内容读出来就能给用户一句人话解释（也会经 onLog 打出来）。
        /// </summary>
        public static string LastFailureSummary { get; private set; }

        // ---------------------------------------------------------------- 环境检测

        /// <summary>检测本机环境，返回多行可读报告（写进日志，也在界面上短暂显示）。</summary>
        public static string DescribeEnvironment()
        {
            StringBuilder sb = new StringBuilder();
            sb.AppendLine("===== 环境检测 =====");

            // Windows 版本
            try
            {
                OperatingSystem os = Environment.OSVersion;
                sb.AppendLine("系统      : " + os.VersionString +
                    "  (" + (Environment.Is64BitOperatingSystem ? "64 位" : "32 位") + ")");
            }
            catch { sb.AppendLine("系统      : 读取失败"); }

            // CPU 架构 —— 决定要不要下 WinDivert64.sys
            try
            {
                string arch = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE");
                sb.AppendLine("处理器    : " + (arch ?? "未知"));
            }
            catch { }

            // 进程位数
            try
            {
                sb.AppendLine("安装进程  : " + (Environment.Is64BitProcess ? "64 位" : "32 位"));
            }
            catch { }

            // 管理员
            try
            {
                sb.AppendLine("管理员    : " + (RuntimeHelper.IsElevated ? "是" : "否（可能需要提权）"));
            }
            catch { }

            // .NET Framework
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.LocalMachine
                    .OpenSubKey(@"SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full"))
                {
                    if (k != null)
                    {
                        object rel = k.GetValue("Release");
                        sb.AppendLine(".NET FW   : 已安装（Release=" + (rel ?? "?") + "）");
                    }
                    else sb.AppendLine(".NET FW   : 未检测到 v4");
                }
            }
            catch { sb.AppendLine(".NET FW   : 读取失败"); }

            // 主程序自带运行时，不依赖系统 .NET
            sb.AppendLine("主程序    : 自包含 .NET 8，无需额外安装运行时");

            // 磁盘剩余
            try
            {
                string root = Path.GetPathRoot(Option.Current.InstallLocation);
                DriveInfo di = new DriveInfo(root);
                if (di.IsReady)
                {
                    sb.AppendLine("磁盘剩余  : " + (di.AvailableFreeSpace / 1024 / 1024).ToString(CultureInfo.InvariantCulture) + " MB");
                }
            }
            catch { }

            // 是否已有旧服务
            try
            {
                string q = RunCapture("sc.exe", "query VRChatBypass");
                if (q.IndexOf("SERVICE_NAME", StringComparison.OrdinalIgnoreCase) >= 0)
                    sb.AppendLine("已有服务  : VRChatBypass 已存在（会被覆盖更新）");
                else
                    sb.AppendLine("已有服务  : 无（干净安装）");
            }
            catch { }

            // hosts 是否可写
            try
            {
                string hosts = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System), 
                    @"drivers\etc\hosts");
                hosts = @"C:\Windows\System32\drivers\etc\hosts";
                if (File.Exists(hosts))
                {
                    using (FileStream fs = File.Open(hosts, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite))
                    {
                        sb.AppendLine("hosts     : 可写（" + hosts + "）");
                    }
                }
                else sb.AppendLine("hosts     : 文件不存在！");
            }
            catch { sb.AppendLine("hosts     : 不可写（请用管理员身份运行安装程序）"); }

            // 加速组件是否已就位（4 个文件 + 哈希与记录是否一致）
            try
            {
                string toolsDir = Path.Combine(Option.Current.InstallLocation, "tools");
                sb.AppendLine("组件状态  : " + DescribeComponents(toolsDir));
            }
            catch { sb.AppendLine("组件状态  : 读取失败"); }

            sb.AppendLine("=====================");
            return sb.ToString();
        }

        /// <summary>
        /// 检查 tools 目录里 4 个组件是否齐全、哈希是否与（内置清单 / components.lock）记录一致。
        /// 只读不写、绝不抛异常，供 DescribeEnvironment 与安装日志使用。
        /// </summary>
        public static string DescribeComponents(string toolsDir)
        {
            try
            {
                if (string.IsNullOrEmpty(toolsDir))
                    return "安装目录未知，无法检查";

                if (!Directory.Exists(toolsDir))
                    return "tools 目录不存在（" + toolsDir + "，安装时会自动下载）";

                Dictionary<string, string> lockMap = LoadLockFile(toolsDir);
                bool lockExists = File.Exists(LockPath(toolsDir));

                int ready = 0;
                List<string> problems = new List<string>();

                foreach (Req f in Files)
                {
                    string p = Path.Combine(toolsDir, f.Name);
                    if (!File.Exists(p))
                    {
                        problems.Add("缺少 " + f.Name);
                        continue;
                    }

                    long len = FileLength(p);
                    if (len < f.MinBytes)
                    {
                        problems.Add(f.Name + " 体积异常（" + len + " 字节 < 下限 " + f.MinBytes + "）");
                        continue;
                    }

                    string exp = ExpectedHash(f.Name, lockMap);
                    if (exp == null)
                    {
                        ready++;   // 无哈希记录：只按体积算通过（首次信任阶段）
                        continue;
                    }

                    string act = Sha256OfFile(p);
                    if (act == null)
                    {
                        problems.Add(f.Name + " 哈希读取失败");
                        continue;
                    }
                    if (!string.Equals(act, exp, StringComparison.OrdinalIgnoreCase))
                    {
                        problems.Add(f.Name + " SHA256 与 " + (KnownSha256.ContainsKey(f.Name) ? "内置清单" : "components.lock") +
                            " 不符（" + Short(act) + " ≠ " + Short(exp) + "），需要用户确认");
                        continue;
                    }
                    ready++;
                }

                string head = "tools\\ 就绪 " + ready + "/" + Files.Length +
                    (lockExists ? "（含 components.lock 比对）" : "（无 components.lock，尚未建立首次信任）");
                if (problems.Count == 0)
                    return head + "，哈希校验通过";

                return head + "；" + string.Join("；", problems.ToArray());
            }
            catch (Exception e)
            {
                return "检测异常: " + e.Message;
            }
        }

        private static string RunCapture(string exe, string args)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(exe, args);
                psi.UseShellExecute = false;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.CreateNoWindow = true;
                using (Process p = Process.Start(psi))
                {
                    string o = p.StandardOutput.ReadToEnd();
                    p.WaitForExit(8000);
                    return o ?? string.Empty;
                }
            }
            catch { return string.Empty; }
        }

        // ---------------------------------------------------------------- 镜像测速

        /// <summary>对每个源下一小段数据测速，返回最快的可用源（失败返回 null）。</summary>
        public static Source PickFastestSource(Action<string> log)
        {
            List<Source> alive = new List<Source>();

            foreach (Source s in Sources)
            {
                try
                {
                    Stopwatch sw = Stopwatch.StartNew();
                    long got = ProbeBytes(s.Base + "/WinDivert.dll", 4096, 8000);
                    sw.Stop();

                    if (got > 512)
                    {
                        s.Alive = true;
                        s.LatencyMs = sw.ElapsedMilliseconds;
                        alive.Add(s);
                        if (log != null) log("镜像可用: " + s.Name + "  " + s.LatencyMs + " ms  " + got + " B");
                    }
                    else
                    {
                        if (log != null) log("镜像不可用: " + s.Name);
                    }
                }
                catch (Exception e)
                {
                    if (log != null) log("镜像异常: " + s.Name + "  " + e.Message);
                }
            }

            if (alive.Count == 0) return null;

            alive.Sort(delegate (Source a, Source b) { return a.LatencyMs.CompareTo(b.LatencyMs); });
            if (log != null) log("选用最快镜像: " + alive[0].Name);
            return alive[0];
        }

        /// <summary>只取前 n 字节，用来测速又不浪费流量。</summary>
        private static long ProbeBytes(string url, int want, int timeoutMs)
        {
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.UserAgent = "VRChatTool-Setup";
                req.Method = "GET";
                using (WebResponse resp = req.GetResponse())
                using (Stream st = resp.GetResponseStream())
                {
                    byte[] buf = new byte[want];
                    int total = 0;
                    while (total < want)
                    {
                        int n = st.Read(buf, total, want - total);
                        if (n <= 0) break;
                        total += n;
                    }
                    return total;
                }
            }
            catch { return 0; }
        }

        // ---------------------------------------------------------------- 下载

        /// <summary>
        /// 确保 4 个组件都在 toolsDir 里。
        /// report(进度百分比 0-100, 提示文字) 用于刷新安装界面。
        ///
        /// 返回 false 时，LastFailureSummary 里是「哪个文件 / 试过哪些源 / 最后什么错误」的摘要，
        /// 同时会经 onLog 以 [Env] 前缀打出来（调用方不必改签名也能看到原因）。
        /// </summary>
        public static bool EnsureComponents(string toolsDir, Action<double, string> report, Action<string> log)
        {
            LastFailureSummary = null;

            if (string.IsNullOrEmpty(toolsDir))
            {
                LastFailureSummary = "安装目录未知（toolsDir 为空）：1 个都没法检查，未尝试任何下载源。";
                LogWarn(log, LastFailureSummary);
                return false;
            }

            try
            {
                if (!Directory.Exists(toolsDir)) Directory.CreateDirectory(toolsDir);
            }
            catch (Exception e)
            {
                LastFailureSummary = "无法创建组件目录 " + toolsDir + "：" + e.Message + "；未尝试任何下载源。";
                LogWarn(log, LastFailureSummary);
                return false;
            }

            // 首次信任记录：读不出来（不存在 / 损坏 / 被占用）就当空表，不打断安装
            Dictionary<string, string> lockMap = LoadLockFile(toolsDir);
            bool lockDirty = false;

            List<Req> missing = new List<Req>();
            List<string> tampered = new List<string>();   // 哈希不符 → 需要用户确认的失败

            // 先看有没有已经齐的
            foreach (Req f in Files)
            {
                string dest = Path.Combine(toolsDir, f.Name);
                if (!File.Exists(dest) || FileLength(dest) < f.MinBytes)
                {
                    missing.Add(f);
                    continue;
                }

                string exp = ExpectedHash(f.Name, lockMap);
                if (exp == null)
                {
                    if (log != null) log("已存在，跳过（无哈希记录，首次信任）: " + f.Name);
                    continue;
                }

                string act = Sha256OfFile(dest);
                if (act != null && string.Equals(act, exp, StringComparison.OrdinalIgnoreCase))
                {
                    if (log != null) log("已存在，跳过（SHA256 校验通过）: " + f.Name);
                    continue;
                }

                // 哈希不符。分两种情况，处理方式不同：
                //
                //  a) 有**内置**哈希 → 我们知道"正确的字节"长什么样，而且来源是锁死的
                //     commit。本地文件不符要么是被投毒、要么是上次下载被截断（实测踩过：
                //     raw.githubusercontent 断流留下 1.4 MB 的残缺 cygwin1.dll）。
                //     这两种情况都该**重新下载**，而不是把用户卡在"需要确认"上。
                //     重下的内容同样会过内置哈希，所以不存在"越修越坏"。
                //
                //  b) 只有 components.lock（首次信任期，上游没给哈希）→ 我们无法判断
                //     哪个是对的，这时才拒绝并交给用户确认，绝不静默覆盖。
                bool builtin = KnownSha256.ContainsKey(f.Name);
                if (builtin)
                {
                    LogWarn(log, f.Name + " 与内置哈希不符（实际 " +
                        (act == null ? "读取失败" : Short(act)) + "），判定为损坏或被改过，改为重新下载");
                    missing.Add(f);
                }
                else
                {
                    string msg = f.Name + " 的 SHA256 与 components.lock 不符（记录 " + Short(exp) +
                        "，实际 " + (act == null ? "读取失败" : Short(act)) + "），已拒绝使用，需要用户确认";
                    tampered.Add(msg);
                    LogWarn(log, msg);
                }
            }

            if (tampered.Count > 0)
            {
                LastFailureSummary = tampered.Count + " 个组件哈希与 components.lock 不符，已拒绝使用：" +
                    string.Join("；", tampered.ToArray()) +
                    "。为避免覆盖可疑文件，本次未尝试任何下载源。";
                LogWarn(log, LastFailureSummary);
                if (report != null) report(100, "组件校验失败，需要用户确认");
                return false;
            }

            if (missing.Count == 0)
            {
                if (lockDirty) SaveLockFile(toolsDir, lockMap, log);
                if (report != null) report(100, "加速组件已就绪");
                return true;
            }

            if (report != null) report(2, "正在测速选择下载源…");
            Source best = PickFastestSource(log);
            if (best == null)
            {
                LastFailureSummary = "所有镜像都不可用（" + Sources.Length + " 个源在测速阶段全部失败），" +
                    "待下载：" + Names(missing) + "；最后错误：无可用下载源（DNS 或代理不可用）。";
                LogWarn(log, "所有镜像都不可用");
                LogWarn(log, LastFailureSummary);
                if (report != null) report(100, "组件下载失败：所有镜像都不可用");
                return false;
            }

            // 候选顺序：最快的那台排第一，其余兜底
            List<Source> order = new List<Source>();
            order.Add(best);
            foreach (Source s in Sources)
            {
                if (s != best && s.Alive) order.Add(s);
            }
            foreach (Source s in Sources)
            {
                if (!order.Contains(s)) order.Add(s);
            }

            int done = 0;
            List<string> failures = new List<string>();

            foreach (Req f in missing)
            {
                bool ok = false;
                int idx = done;
                string dest = Path.Combine(toolsDir, f.Name);
                List<string> tried = new List<string>();
                string lastError = "未知错误";

                foreach (Source s in order)
                {
                    string url = s.Base + "/" + f.Name;

                    try
                    {
                        if (report != null)
                            report(5 + 90.0 * idx / missing.Count, "下载 " + f.Name + "（" + s.Name + "）");

                        string exp = ExpectedHash(f.Name, lockMap);
                        string err;
                        string gotHash;

                        if (DownloadWithProgress(url, dest, f.MinBytes, exp, delegate (double p)
                        {
                            if (report != null)
                                report((5 + 90.0 * (idx + p / 100.0) / missing.Count),
                                       "下载 " + f.Name + " " + (int)p + "%（" + s.Name + "）");
                        }, log, out err, out gotHash))
                        {
                            long sz = FileLength(dest);
                            if (log != null)
                                log("下载成功: " + f.Name + "  " + sz + " 字节  SHA256 " + Short(gotHash) + "  来源 " + s.Name);

                            // 首次信任：这份内容第一次见，把它的哈希记进 lock 文件
                            if (exp == null && !string.IsNullOrEmpty(gotHash))
                            {
                                lockMap[f.Name] = gotHash;
                                lockDirty = true;
                                if (log != null) log("首次信任: " + f.Name + " 的 SHA256 已记入 " + LockFileName +
                                    "（" + Short(gotHash) + "），以后每次启动都会跟它比对");
                            }
                            ok = true;
                            break;
                        }

                        tried.Add(s.Name);
                        lastError = err ?? "下载失败";
                        if (log != null) log("该源失败，换下一个: " + s.Name + " / " + f.Name + "  " + lastError);
                    }
                    catch (Exception e)
                    {
                        tried.Add(s.Name);
                        lastError = e.Message;
                        if (log != null) log("下载异常: " + s.Name + " / " + f.Name + "  " + e.Message);
                    }
                }

                if (!ok)
                {
                    failures.Add(f.Name + "（试过 " + tried.Count + " 个源：" +
                        (tried.Count == 0 ? "无" : string.Join("、", tried.ToArray())) +
                        "；最后错误：" + lastError + "）");
                    if (log != null) log("所有源都下载失败: " + f.Name);
                }
                done++;
            }

            if (lockDirty) SaveLockFile(toolsDir, lockMap, log);

            // 复查：大小 + 哈希（含刚写进 lock 的记录）
            foreach (Req f in Files)
            {
                string dest = Path.Combine(toolsDir, f.Name);
                long sz = FileLength(dest);
                if (!File.Exists(dest) || sz < f.MinBytes)
                {
                    if (log != null) log("校验失败（文件缺失或体积不足）: " + f.Name);
                    continue;
                }

                string exp = ExpectedHash(f.Name, lockMap);
                if (exp == null) continue;

                string act = Sha256OfFile(dest);
                if (act == null || !string.Equals(act, exp, StringComparison.OrdinalIgnoreCase))
                {
                    string msg = f.Name + " 复查哈希不符（期望 " + Short(exp) + "，实际 " +
                        (act == null ? "读取失败" : Short(act)) + "）";
                    failures.Add(msg);
                    LogWarn(log, "校验失败: " + msg);
                }
            }

            if (failures.Count > 0)
            {
                LastFailureSummary = failures.Count + " 个组件没能就绪：" +
                    string.Join("；", failures.ToArray()) +
                    "。已失败的 .part 文件保留在 tools 目录，重试（或主程序内重试）会从断点续传。";
                LogWarn(log, "组件未能全部就绪：" + failures.Count + " 个");
                LogWarn(log, LastFailureSummary);
                if (report != null) report(100, "组件下载未完成（详见日志）");
                return false;
            }

            if (report != null) report(100, "加速组件下载完成");
            return true;
        }

        /// <summary>
        /// 手写下载循环：HttpWebRequest + Range 断点续传 + 进度回调 + 大小/SHA256 校验。
        ///
        /// 为什么不用 WebClient：
        ///   · WebClient 没有 Range，2.9 MB 的 cygwin1.dll 网络一抖就得从头再来；
        ///   · WebClient 的 DownloadProgressChanged 只报「本次会话」的百分比，续传时是错的；
        ///   · WebClient / ServicePoint 这套 API 已经过时（.NET 6+ 起是 SYSLIB0014）。
        /// 为什么不用 HttpClient：本文件要在 net472（MicaSetup 安装器）和 net8.0（EnvTest 测试台）
        /// 两边都编得过。net472 的 HttpClient 在 System.Net.Http.dll，那个程序集不保证被引用；
        /// 而 HttpWebRequest 在 System.dll（net472）/ System.Net.Requests（net8.0）里，两边都稳。
        /// 这里选保守 API。
        ///
        /// 续传规则：
        ///   · .part 已存在 → 用它的长度做 Range 起点，服务器回 206 就接着写；
        ///   · 服务器回 200（不支持 Range）→ 丢掉旧的，从头写；
        ///   · 网络中断 → **保留** .part，下一次（哪怕换源）继续从断点下。
        ///     因为源地址锁了 commit，各镜像返回的字节流同源，跨源续传是安全的。
        /// </summary>
        private static bool DownloadWithProgress(string url, string dest, long minBytes, string expectSha256,
            Action<double> onProgress, Action<string> log, out string error, out string gotSha256)
        {
            error = null;
            gotSha256 = null;
            string tmp = dest + ".part";
            HttpWebResponse resp = null;
            FileStream fs = null;

            try
            {
                // 断点起点：上一次留下的 .part 长度（读不到就当 0，从头下）
                long have = 0;
                try { if (File.Exists(tmp)) have = new FileInfo(tmp).Length; } catch { have = 0; }

                HttpWebRequest req = CreateRequest(url, have);

                try
                {
                    resp = (HttpWebResponse)req.GetResponse();
                }
                catch (WebException we)
                {
                    // 416：本地 .part 比远端文件还大（换过源 / 上次下歪了）→ 丢掉重来
                    HttpWebResponse errResp = null;
                    try { errResp = we.Response as HttpWebResponse; } catch { }
                    if (errResp != null && errResp.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable && have > 0)
                    {
                        TryDelete(tmp);
                        error = "服务器拒绝 Range 且本地 .part 已丢弃，需重下：" + DescribeWebError(we);
                        return false;
                    }
                    // 其它网络错误：保留 .part，下次续传
                    error = DescribeWebError(we) + "（已保留 " + have + " 字节断点）";
                    return false;
                }

                bool resumed = resp.StatusCode == HttpStatusCode.PartialContent && have > 0;
                long start = resumed ? have : 0;
                long total = resp.ContentLength >= 0 ? start + resp.ContentLength : -1;

                if (!resumed && have > 0)
                {
                    LogWarn(log, "该源不支持断点续传（返回 " + (int)resp.StatusCode + "），已丢弃 " + have + " 字节从头下载");
                }

                using (fs = new FileStream(tmp, resumed ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None))
                using (Stream net = resp.GetResponseStream())
                {
                    byte[] buf = new byte[64 * 1024];
                    long got = start;
                    int lastPct = -1;

                    while (true)
                    {
                        int n = net.Read(buf, 0, buf.Length);
                        if (n <= 0) break;
                        fs.Write(buf, 0, n);
                        got += n;

                        // 节流：只在整数百分比发生变化时上报，避免刷爆 UI
                        if (onProgress != null && total > 0)
                        {
                            int pct = (int)(got * 100L / total);
                            if (pct > 100) pct = 100;
                            if (pct != lastPct)
                            {
                                lastPct = pct;
                                onProgress(pct);
                            }
                        }
                    }
                    fs.Flush();
                }

                long size = FileLength(tmp);

                // 只下到一半就断了：保留 .part，交给下一次重试续
                if (total > 0 && size < total)
                {
                    error = "连接中断，收到 " + size + "/" + total + " 字节（断点已保留，下次续传）";
                    return false;
                }

                if (size < minBytes)
                {
                    TryDelete(tmp);
                    error = "文件只有 " + size + " 字节，小于下限 " + minBytes + "（镜像可能返回了错误页）";
                    return false;
                }

                gotSha256 = Sha256OfFile(tmp);
                if (gotSha256 == null)
                {
                    error = "无法计算 SHA256（文件读取失败）";
                    return false;
                }

                if (!string.IsNullOrEmpty(expectSha256) &&
                    !string.Equals(expectSha256, gotSha256, StringComparison.OrdinalIgnoreCase))
                {
                    // 内容不对（清单/lock 说应该是别的哈希）→ 丢掉，换源重试
                    TryDelete(tmp);
                    error = "SHA256 不匹配（期望 " + Short(expectSha256) + "，实际 " + Short(gotSha256) + "），已丢弃并换源";
                    LogWarn(log, "SHA256 不匹配: " + dest + "  " + error);
                    return false;
                }

                if (File.Exists(dest)) File.Delete(dest);
                File.Move(tmp, dest);
                return true;
            }
            catch (Exception e)
            {
                // 网络/IO 类异常一律保留 .part，下一次续传
                error = e.GetType().Name + ": " + e.Message;
                return false;
            }
            finally
            {
                if (fs != null) { try { fs.Dispose(); } catch { } }
                if (resp != null) { try { resp.Dispose(); } catch { } }
            }
        }

        /// <summary>
        /// 构造带 Range 的下载请求。
        /// Range: bytes=&lt;start&gt;- 是断点续传的关键；服务器若不支持会忽略它并返回 200，
        /// 调用方按 200 处理（从头写），不会写坏文件。
        /// </summary>
        private static HttpWebRequest CreateRequest(string url, long rangeStart)
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "GET";
            req.UserAgent = "VRChatTool-Setup";
            req.Timeout = 15000;            // 连接 + 首响应超时
            req.ReadWriteTimeout = 60000;   // 单次读超时（给 2.9 MB 的 cygwin1.dll 留余量）
            req.KeepAlive = true;
            if (rangeStart > 0) req.AddRange(rangeStart);
            return req;
        }

        // ---------------------------------------------------------------- SHA256 / 锁定文件

        /// <summary>计算文件的 SHA256（64 位小写 hex）。失败返回 null，绝不抛异常。</summary>
        public static string Sha256OfFile(string path)
        {
            try
            {
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (SHA256 sha = SHA256.Create())
                {
                    byte[] digest = sha.ComputeHash(fs);
                    StringBuilder sb = new StringBuilder(64);
                    for (int i = 0; i < digest.Length; i++)
                    {
                        sb.Append(digest[i].ToString("x2", CultureInfo.InvariantCulture));
                    }
                    return sb.ToString();
                }
            }
            catch { return null; }
        }

        /// <summary>
        /// 取某个文件的期望哈希：优先内置清单（强制校验），其次 components.lock（首次信任之后）。
        /// 都没有则返回 null，表示「无记录，走首次信任」。
        /// </summary>
        private static string ExpectedHash(string name, Dictionary<string, string> lockMap)
        {
            string v;
            if (KnownSha256.TryGetValue(name, out v) && IsHex64(v)) return v.ToLowerInvariant();
            if (lockMap != null && lockMap.TryGetValue(name, out v) && IsHex64(v)) return v.ToLowerInvariant();
            return null;
        }

        private static string LockPath(string toolsDir)
        {
            return Path.Combine(toolsDir, LockFileName);
        }

        /// <summary>
        /// 读 components.lock（key=value 文本：文件名=64 位小写 SHA256）。
        /// 容错要求：文件不存在 / 被占用 / 内容是二进制垃圾 / 某行格式不对 / 路径非法，
        /// 一律不抛异常 —— 坏行直接跳过，整体读不出来就返回空表（等于还没建立首次信任）。
        /// </summary>
        private static Dictionary<string, string> LoadLockFile(string toolsDir)
        {
            Dictionary<string, string> map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (string.IsNullOrEmpty(toolsDir)) return map;

                string path = LockPath(toolsDir);
                if (!File.Exists(path)) return map;

                string[] lines = File.ReadAllLines(path, Encoding.UTF8);
                foreach (string raw in lines)
                {
                    if (raw == null) continue;
                    string line = raw.Trim();
                    if (line.Length == 0) continue;
                    if (line[0] == '#' || line[0] == ';') continue;   // 注释行

                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;

                    string k = line.Substring(0, eq).Trim();
                    string v = line.Substring(eq + 1).Trim();
                    if (k.Length == 0) continue;
                    if (!IsHex64(v)) continue;    // 值不是 64 位 hex 的坏行丢掉，不打断安装

                    map[k] = v.ToLowerInvariant();
                }
            }
            catch (Exception e)
            {
                // lock 文件坏了不致命：当作「没有锁定记录」处理
                try { Logger.Warning("读取 " + LockFileName + " 失败，按首次信任处理: " + e.Message); } catch { }
            }
            return map;
        }

        /// <summary>
        /// 写回 components.lock（先写 .tmp 再替换，避免写一半断电留下半个文件）。
        /// 失败只写日志，不影响安装主流程；返回值仅表示是否写成。
        /// </summary>
        private static bool SaveLockFile(string toolsDir, Dictionary<string, string> map, Action<string> log)
        {
            if (map == null || string.IsNullOrEmpty(toolsDir)) return false;

            try
            {
                StringBuilder sb = new StringBuilder();
                sb.AppendLine("# VRChat优选工具 加速组件哈希锁定文件（首次下载自动生成，请勿手工修改）");
                sb.AppendLine("# 格式: 文件名=64位小写SHA256；改这里会让下次启动判定为哈希不符");
                sb.AppendLine("# 组件来源 commit: " + CommitSha);

                // 先按固定顺序写 4 个组件，再补上历史遗留记录
                foreach (Req f in Files)
                {
                    string v;
                    if (map.TryGetValue(f.Name, out v) && IsHex64(v))
                        sb.AppendLine(f.Name + "=" + v.ToLowerInvariant());
                }
                foreach (KeyValuePair<string, string> kv in map)
                {
                    bool known = false;
                    foreach (Req f in Files)
                    {
                        if (string.Equals(f.Name, kv.Key, StringComparison.OrdinalIgnoreCase)) { known = true; break; }
                    }
                    if (!known && IsHex64(kv.Value))
                        sb.AppendLine(kv.Key + "=" + kv.Value.ToLowerInvariant());
                }

                string path = LockPath(toolsDir);
                string tmp = path + ".tmp";
                File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
                if (File.Exists(path)) File.Delete(path);
                File.Move(tmp, path);

                if (log != null) log("哈希锁定文件已更新: " + path);
                return true;
            }
            catch (Exception e)
            {
                try { Logger.Warning("写 " + LockFileName + " 失败（不影响本次安装）: " + e.Message); } catch { }
                if (log != null) log("写 " + LockFileName + " 失败: " + e.Message);
                return false;
            }
        }

        // ---------------------------------------------------------------- 小工具

        private static bool IsHex64(string s)
        {
            if (s == null || s.Length != 64) return false;
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
                if (!hex) return false;
            }
            return true;
        }

        /// <summary>日志里只显示哈希前 12 位，避免刷屏。</summary>
        private static string Short(string hex)
        {
            if (string.IsNullOrEmpty(hex)) return "(空)";
            return hex.Length <= 12 ? hex : hex.Substring(0, 12) + "…";
        }

        private static long FileLength(string path)
        {
            try { return new FileInfo(path).Length; }
            catch { return -1; }
        }

        private static void TryDelete(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); } catch { }
        }

        private static string Names(List<Req> list)
        {
            List<string> n = new List<string>();
            foreach (Req r in list) n.Add(r.Name);
            return n.Count == 0 ? "无" : string.Join("、", n.ToArray());
        }

        private static string DescribeWebError(WebException we)
        {
            if (we == null) return "网络错误";
            try
            {
                HttpWebResponse r = we.Response as HttpWebResponse;
                if (r != null) return "HTTP " + (int)r.StatusCode + " " + r.StatusDescription;
            }
            catch { }
            return we.Status + ": " + we.Message;
        }

        private static void LogWarn(Action<string> log, string message)
        {
            try { Logger.Warning(message); } catch { }
            if (log != null)
            {
                try { log(message); } catch { }
            }
        }
    }
}
