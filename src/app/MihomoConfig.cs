using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace VrcTool
{
    /// <summary>mihomo 的配置生成与状态持久化。</summary>
    internal static class MihomoConfig
    {
        public const string GroupPhoton = "VRChat-Photon";
        public const string GroupDefault = "默认";
        public const int MixedPort = 7891;          // 避开 Clash Verge 的 7897
        public const int ApiPort = 9097;

        private sealed class State
        {
            public string Subscription { get; set; }
            public bool Tun { get; set; }
            public string Secret { get; set; }
        }

        private static State cached;

        private static string StatePath(string dir)
        {
            return Path.Combine(dir, "state.json");
        }

        private static State Load(string dir)
        {
            if (cached != null) return cached;
            State s = null;
            try
            {
                string p = StatePath(dir);
                if (File.Exists(p))
                    s = JsonSerializer.Deserialize<State>(File.ReadAllText(p, Encoding.UTF8));
            }
            catch { }
            if (s == null) s = new State();
            if (string.IsNullOrEmpty(s.Secret))
                s.Secret = Guid.NewGuid().ToString("N").Substring(0, 16);
            cached = s;
            return s;
        }

        private static void Save(string dir, State s)
        {
            try
            {
                File.WriteAllText(StatePath(dir), JsonSerializer.Serialize(s, new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            }
            catch { }
        }

        public static string Subscription
        {
            get { return Load(DriverManagerRoot()).Subscription ?? ""; }
            set
            {
                string dir = DriverManagerRoot();
                State s = Load(dir);
                s.Subscription = value ?? "";
                Save(dir, s);
                DriverManager.Log("订阅已设置: " + (string.IsNullOrEmpty(value) ? "(清空)" : value));
            }
        }

        public static bool TunEnabled
        {
            get { return Load(DriverManagerRoot()).Tun; }
            set
            {
                string dir = DriverManagerRoot();
                State s = Load(dir);
                s.Tun = value;
                Save(dir, s);
                DriverManager.Log("TUN -> " + value);
            }
        }

        public static string Secret { get { return Load(DriverManagerRoot()).Secret; } }

        private static string DriverManagerRoot()
        {
            // 与 DriverManager 用同一个目录约定
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "VrcTool", "drivers", "mihomo");
        }

        public static bool IsTunEnabled(string dir)
        {
            try { return Load(dir).Tun; } catch { return false; }
        }

        /// <summary>
        /// 下载订阅并落盘成 mihomo 的 file provider。
        /// 关键点：必须带 Clash 系 User-Agent —— 订阅站按 UA 决定返回格式，
        /// 不带 UA 会拿到 base64 的 v2ray 链接（mihomo 解析不了，节点列表会是空的）。
        /// </summary>
        /// <summary>
        /// 下载订阅到 providers\sub.yaml。
        ///
        /// 订阅站按 User-Agent 决定返回格式：带 Clash 系 UA 才给 YAML，否则给 base64 的 v2ray 链接。
        /// 所以轮流试几个常见 UA，先拿到 YAML 的算成功。校验必须看全文 —— proxies: 常在 1 KB 之后。
        /// </summary>
        public static bool DownloadSubscription(string dir, out string error)
        {
            error = "";
            try
            {
                State s = Load(dir);
                string url = s.Subscription;
                if (string.IsNullOrWhiteSpace(url))
                {
                    error = "订阅地址为空";
                    return false;
                }

                string pdir = Path.Combine(dir, "providers");
                Directory.CreateDirectory(pdir);
                string target = Path.Combine(pdir, "sub.yaml");

                string[] uas = new string[]
                {
                    "clash-verge/v2.0.0",
                    "Clash/Meta",
                    "clash.meta/1.19.0",
                    "mihomo/v1.19.0",
                    "ClashforWindows/0.20.39"
                };

                string lastDetail = "";
                foreach (string ua in uas)
                {
                    try
                    {
                        // 共享连接池；UA 决定返回格式，所以每个 UA 建一个轻量客户端
                        using (HttpClient hc = Http.Create(40, ua))
                        {
                            hc.DefaultRequestHeaders.TryAddWithoutValidation("Accept", "text/yaml, text/plain, */*");

                            byte[] data = hc.GetByteArrayAsync(url).GetAwaiter().GetResult();
                            if (data == null || data.Length < 200)
                            {
                                lastDetail = ua + " -> 内容过小（" + (data == null ? 0 : data.Length) + " 字节）";
                                continue;
                            }

                            string full = Encoding.UTF8.GetString(data).TrimStart('\uFEFF', ' ', '\r', '\n', '\t');
                            string firstLine = full;
                            int nl = full.IndexOf('\n');
                            if (nl > 0) firstLine = full.Substring(0, nl).Trim();

                            bool looksClash = full.IndexOf("proxies:", StringComparison.Ordinal) >= 0
                                           || full.IndexOf("proxy-groups:", StringComparison.Ordinal) >= 0
                                           || full.IndexOf("proxy-providers:", StringComparison.Ordinal) >= 0
                                           || firstLine.StartsWith("mixed-port:", StringComparison.OrdinalIgnoreCase)
                                           || firstLine.StartsWith("port:", StringComparison.OrdinalIgnoreCase)
                                           || firstLine.StartsWith("proxies:", StringComparison.OrdinalIgnoreCase);
                            if (looksClash)
                            {
                                File.WriteAllBytes(target, data);
                                DriverManager.Log("订阅已下载: " + data.Length + " 字节（UA=" + ua + "）-> " + target);
                                return true;
                            }

                            lastDetail = ua + " -> 不是 Clash 格式（首行：" + SafeHead(firstLine) + "，共 " + data.Length + " 字节）";
                        }
                    }
                    catch (Exception ex)
                    {
                        lastDetail = ua + " -> " + ex.Message;
                        DriverManager.Log("订阅下载尝试失败: " + lastDetail);
                    }
                }

                error = "订阅返回的不是 Clash 格式。\r\n\r\n最后一次尝试：" + lastDetail + "\r\n\r\n" +
                        "常见原因：\r\n" +
                        "  · 机场只给了 v2ray/base64 订阅 —— 请到机场后台复制「Clash」格式的订阅链接；\r\n" +
                        "  · 链接需要登录态或已过期；\r\n" +
                        "  · 中间有代理/防火墙改写了内容。";
                DriverManager.Log("订阅下载失败: " + lastDetail);
                return false;
            }
            catch (Exception ex)
            {
                error = ex.Message;
                DriverManager.Log("订阅下载异常: " + ex.Message);
                return false;
            }
        }

        private static string SafeHead(string s)
        {
            if (string.IsNullOrEmpty(s)) return "(空)";
            string one = s.Replace("\r", " ").Replace("\n", " ");
            if (one.Length > 60) one = one.Substring(0, 60) + "…";
            return one;
        }
        /// <summary>写 config.yaml，返回路径。调用后需重启 mihomo 生效。</summary>
        public static string EnsureConfig(string dir)
        {
            Directory.CreateDirectory(dir);
            State s = Load(dir);
            string cfg = Path.Combine(dir, "config.yaml");
            string sub = s.Subscription ?? "";

            StringBuilder b = new StringBuilder();
            b.AppendLine("# 由 VRChat优选工具 自动生成，手工修改会在下次启动时被覆盖");
            b.AppendLine("mixed-port: " + MixedPort);
            b.AppendLine("allow-lan: false");
            b.AppendLine("bind-address: 127.0.0.1");
            b.AppendLine("mode: rule");
            b.AppendLine("log-level: info");
            b.AppendLine("ipv6: true");
            b.AppendLine("unified-delay: true");
            b.AppendLine("tcp-concurrent: true");
            b.AppendLine("external-controller: 127.0.0.1:" + ApiPort);
            b.AppendLine("secret: \"" + s.Secret + "\"");
            b.AppendLine("profile:");
            b.AppendLine("  store-selected: true");
            b.AppendLine();
            b.AppendLine("dns:");
            b.AppendLine("  enable: true");
            b.AppendLine("  ipv6: false");
            b.AppendLine("  enhanced-mode: fake-ip");
            b.AppendLine("  fake-ip-range: 198.18.0.1/16");
            b.AppendLine("  nameserver:");
            b.AppendLine("    - 223.5.5.5");
            b.AppendLine("    - 119.29.29.29");
            b.AppendLine();

            // 订阅文件由应用自己下载（见 DownloadSubscription）。
            // 为什么不用 http provider：
            //   1) 订阅站按 User-Agent 决定返回格式 —— 不带 UA 会返回 base64 的 v2ray 链接，
            //      mihomo 解析不了，表现为"节点列表空"；
            //   2) 自己下载还能在失败时给出明确错误（HTTP 码 / 字节数）。
            string subFile = Path.Combine(dir, "providers", "sub.yaml");
            if (File.Exists(subFile))
            {
                b.AppendLine("proxy-providers:");
                b.AppendLine("  sub:");
                b.AppendLine("    type: file");
                b.AppendLine("    path: ./providers/sub.yaml");
                b.AppendLine("    health-check:");
                b.AppendLine("      enable: true");
                b.AppendLine("      url: http://www.gstatic.com/generate_204");
                b.AppendLine("      interval: 300");
                b.AppendLine();
            }

            b.AppendLine("proxy-groups:");
            bool useProvider = File.Exists(subFile);
            AppendGroup(b, GroupPhoton, useProvider ? "sub" : null);
            AppendGroup(b, GroupDefault, useProvider ? "sub" : null);
            b.AppendLine();

            b.AppendLine("rules:");
            // Photon 网段走专用组（可单独选节点），其余走默认组
            foreach (string r in PhotonCidrs)
                b.AppendLine("  - IP-CIDR," + r + "," + GroupPhoton + ",no-resolve");
            b.AppendLine("  - MATCH," + GroupDefault);
            b.AppendLine();

            b.AppendLine("tun:");
            b.AppendLine("  enable: " + (s.Tun ? "true" : "false"));
            b.AppendLine("  stack: gvisor");
            b.AppendLine("  auto-route: true");
            b.AppendLine("  auto-detect-interface: true");
            b.AppendLine("  dns-hijack:");
            b.AppendLine("    - any:53");

            File.WriteAllText(cfg, b.ToString(), new UTF8Encoding(false));
            return cfg;
        }

        private static void AppendGroup(StringBuilder b, string name, string sub)
        {
            b.AppendLine("  - name: " + name);
            b.AppendLine("    type: select");
            if (!string.IsNullOrEmpty(sub))
            {
                b.AppendLine("    use:");
                b.AppendLine("      - sub");
            }
            else
            {
                b.AppendLine("    proxies:");
                b.AppendLine("      - DIRECT");
            }
        }

        /// <summary>Photon 的地址段（VRChat 实时链路）。集中在这里，便于以后补网段。</summary>
        public static readonly string[] PhotonCidrs = new[]
        {
            "82.117.224.0/24",
            "87.120.0.0/16",
            "80.93.0.0/16",
            "85.234.0.0/16",
            "5.8.93.0/24",
            "37.9.33.0/24"
        };
    }
}
