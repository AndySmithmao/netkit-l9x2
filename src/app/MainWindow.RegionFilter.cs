using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;

namespace VrcTool
{
    /// <summary>
    /// 按「所在区域」生成扫描前缀白名单。
    ///
    /// 全量扫描要覆盖 Cloudflare 5956 个 /24 + CloudFront 16552 个 /24，太慢。
    /// 这里用内置的 IP 归属库把候选网段按大陆筛一遍，只留下同区域（邻近国家）的 /16，
    /// 写成一个文本文件交给 full-scan.ps1 的 -PrefixFile。
    ///
    /// 注意：CDN 的 IP 注册国 ≠ 实际服务位置，所以这里的过滤只是"缩小范围"的启发式，
    /// 白名单为空或过滤后过少时会自动退回全量，避免把候选池压没。
    /// </summary>
    public partial class MainWindow
    {
        private static string RegionFilterPath
        {
            get { return Path.Combine(ScriptHost.DataDir, "region-prefixes.txt"); }
        }

        /// <summary>准备白名单文件；不需要过滤时返回空字符串。</summary>
        private string PrepareRegionFilterFile()
        {
            try
            {
                Continent want = Continent.Unknown;
                try { want = (Continent)Enum.Parse(typeof(Continent), UiState.Current.RegionContinent); } catch { }
                if (want == Continent.Unknown) return "";
                if (GeoIp.RecordCount == 0) return "";

                // 候选 CIDR：优先用脚本抓过的数据，没有再联网取
                List<string> cidrs = LoadCandidateCidrs();
                if (cidrs.Count == 0) return "";

                HashSet<string> allow = new HashSet<string>(StringComparer.Ordinal);
                int total16 = 0, unknown = 0;

                foreach (string cidr in cidrs)
                {
                    string[] p = cidr.Split('/');
                    if (p.Length != 2) continue;
                    uint baseIp;
                    if (!GeoIp.TryParse(p[0], out baseIp)) continue;
                    int bits;
                    if (!int.TryParse(p[1], out bits) || bits < 8 || bits > 32) continue;

                    // 拆成 /16 粒度
                    int step = 1 << Math.Max(0, 16 - bits);          // 小于 /16 的前缀按 /16 覆盖数展开
                    if (bits <= 16)
                    {
                        int count = 1 << (16 - bits);
                        for (int i = 0; i < count; i++)
                        {
                            uint ip = baseIp + (uint)(i << 16);
                            total16++;
                            string key = (ip >> 16).ToString(CultureInfo.InvariantCulture) + "." + ((ip >> 24) & 0xFF).ToString(CultureInfo.InvariantCulture);
                            // 组装 a.b
                            string a = ((ip >> 24) & 0xFF).ToString(CultureInfo.InvariantCulture);
                            string b = ((ip >> 16) & 0xFF).ToString(CultureInfo.InvariantCulture);
                            key = a + "." + b;

                            string probe = a + "." + b + ".0.0";
                            string cc = GeoIp.Country(probe);
                            Continent c = GeoIp.Of(cc);
                            if (cc.Length == 0) { unknown++; continue; }     // 未收录：不放进白名单
                            if (c == want) allow.Add(key);
                        }
                    }
                    else
                    {
                        // 比 /16 更细的前缀：直接看它自己
                        total16++;
                        string a = ((baseIp >> 24) & 0xFF).ToString(CultureInfo.InvariantCulture);
                        string b = ((baseIp >> 16) & 0xFF).ToString(CultureInfo.InvariantCulture);
                        string cc = GeoIp.Country(a + "." + b + ".0.0");
                        if (cc.Length == 0) unknown++;
                        else if (GeoIp.Of(cc) == want) allow.Add(a + "." + b);
                    }
                }

                if (allow.Count == 0)
                {
                    Append("[区域] 白名单为空（候选 " + total16 + " 个 /16，未收录 " + unknown + "），本次按全量扫描");
                    return "";
                }

                // 过滤过狠（不到 3%）也退回全量：宁可慢一点，也别把好 IP 筛没
                if (allow.Count < Math.Max(8, total16 / 33))
                {
                    Append("[区域] 白名单只有 " + allow.Count + " / " + total16 + " 个 /16，样本太少，本次按全量扫描");
                    return "";
                }

                List<string> list = new List<string>(allow);
                list.Sort(StringComparer.Ordinal);
                Directory.CreateDirectory(ScriptHost.DataDir);
                File.WriteAllLines(RegionFilterPath, list, new UTF8Encoding(false));

                Append("[区域] 本次只测同区域的 " + list.Count + " 个 /16（总候选 " + total16 + "，未收录 " + unknown + "），预计快 " +
                       Math.Round((double)total16 / Math.Max(1, list.Count), 1) + " 倍");
                return RegionFilterPath;
            }
            catch (Exception ex)
            {
                DriverManager.Log("生成区域白名单失败: " + ex.Message);
                return "";
            }
        }

        /// <summary>取 Cloudflare + CloudFront 的候选网段（缓存 24 小时）。</summary>
        private List<string> LoadCandidateCidrs()
        {
            List<string> list = new List<string>();
            try
            {
                string cache = Path.Combine(ScriptHost.DataDir, "cidr-cache.txt");
                if (File.Exists(cache) && (DateTime.Now - File.GetLastWriteTime(cache)).TotalHours < 24)
                {
                    foreach (string ln in File.ReadLines(cache))
                        if (ln.Trim().Length > 0) list.Add(ln.Trim());
                    if (list.Count > 0) return list;
                }

                using (HttpClient c = Http.Create(40, "VRChat-Selector/1.0"))
                {
                    try
                    {
                        string cf = c.GetStringAsync("https://www.cloudflare.com/ips-v4").GetAwaiter().GetResult();
                        foreach (string ln in cf.Split('\n'))
                        {
                            string t = ln.Trim();
                            if (t.Length > 0 && char.IsDigit(t[0])) list.Add(t);
                        }
                    }
                    catch (Exception ex) { DriverManager.Log("取 Cloudflare 网段失败: " + ex.Message); }

                    try
                    {
                        string aws = c.GetStringAsync("https://ip-ranges.amazonaws.com/ip-ranges.json").GetAwaiter().GetResult();
                        using (JsonDocument doc = JsonDocument.Parse(aws))
                        {
                            JsonElement prefixes;
                            if (doc.RootElement.TryGetProperty("prefixes", out prefixes) && prefixes.ValueKind == JsonValueKind.Array)
                            {
                                foreach (JsonElement e in prefixes.EnumerateArray())
                                {
                                    JsonElement svc, pre;
                                    if (!e.TryGetProperty("service", out svc) || svc.GetString() != "CLOUDFRONT") continue;
                                    if (!e.TryGetProperty("ip_prefix", out pre)) continue;
                                    list.Add(pre.GetString());
                                }
                            }
                        }
                    }
                    catch (Exception ex) { DriverManager.Log("取 CloudFront 网段失败: " + ex.Message); }
                }

                if (list.Count > 0)
                {
                    try
                    {
                        Directory.CreateDirectory(ScriptHost.DataDir);
                        File.WriteAllLines(cache, list, new UTF8Encoding(false));
                    }
                    catch { }
                }
            }
            catch (Exception ex) { DriverManager.Log("候选网段加载失败: " + ex.Message); }
            return list;
        }
    }
}
