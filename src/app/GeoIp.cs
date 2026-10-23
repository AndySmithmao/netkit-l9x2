using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Text;
using System.Threading.Tasks;

namespace VrcTool
{
    /// <summary>大陆板块。</summary>
    public enum Continent
    {
        Unknown = 0,
        Asia,
        Europe,
        NorthAmerica,
        SouthAmerica,
        Oceania,
        Africa
    }

    /// <summary>
    /// IP 归属查询（离线库）。
    ///
    /// 数据随安装包发布：src\app\geoip.bin 由 tools\build-geoip.ps1 从 DB-IP Lite 生成，
    /// 编译时作为嵌入资源打包。运行时优先用 ProgramData 下的覆盖文件（应用内"重新查询"写入），
    /// 没有才用内置的那份。
    ///
    /// 文件格式（小端）：
    ///   "VGT1" | count(u32) | ccCount(u16) | cc 表(2 * ccCount) | 记录(9 * count)
    ///   记录：start(u32) count(u32) ccIndex(u8)，按 start 升序
    /// </summary>
    internal static class GeoIp
    {
        private static readonly object gate = new object();
        private static bool loaded;
        private static uint[] starts;
        private static uint[] counts;
        private static byte[] ccIdx;
        private static string[] ccTable;
        private static string source = "内置";

        /// <summary>覆盖文件：应用内重新查询后写这里，优先级高于嵌入资源。</summary>
        public static string OverridePath
        {
            get { return Path.Combine(DriverManager.RootDir, "geoip.bin"); }
        }

        public static string Source { get { EnsureLoaded(); return source; } }
        public static int RecordCount { get { EnsureLoaded(); return starts == null ? 0 : starts.Length; } }

        private static void EnsureLoaded()
        {
            lock (gate)
            {
                if (loaded) return;
                loaded = true;

                byte[] data = null;
                try
                {
                    if (File.Exists(OverridePath)) { data = File.ReadAllBytes(OverridePath); source = "已更新"; }
                }
                catch { data = null; }

                if (data == null)
                {
                    try
                    {
                        var asm = typeof(GeoIp).Assembly;
                        Stream s = asm.GetManifestResourceStream("GeoIp.bin");
                        if (s == null)
                        {
                            // 资源名可能被 csproj 的 LogicalName 改了，兜底按后缀找
                            foreach (string n in asm.GetManifestResourceNames())
                            {
                                if (n.EndsWith("geoip.bin", StringComparison.OrdinalIgnoreCase)) { s = asm.GetManifestResourceStream(n); break; }
                            }
                        }
                        if (s != null)
                        {
                            using (s)
                            using (MemoryStream ms = new MemoryStream())
                            {
                                s.CopyTo(ms);
                                data = ms.ToArray();
                            }
                        }
                        source = "内置";
                    }
                    catch (Exception ex) { DriverManager.Log("geoip 读取失败: " + ex.Message); }
                }

                if (data == null || data.Length < 16) return;
                try { Parse(data); }
                catch (Exception ex) { DriverManager.Log("geoip 解析失败: " + ex.Message); }
            }
        }

        private static void Parse(byte[] data)
        {
            int p = 0;
            if (data[0] != 0x56 || data[1] != 0x47 || data[2] != 0x54 || data[3] != 0x31) throw new InvalidDataException("magic 不匹配");
            p = 4;
            int count = BitConverter.ToInt32(data, p); p += 4;
            int ccCount = BitConverter.ToUInt16(data, p); p += 2;

            ccTable = new string[ccCount];
            for (int i = 0; i < ccCount; i++)
            {
                ccTable[i] = ((char)data[p]).ToString() + (char)data[p + 1];
                p += 2;
            }

            starts = new uint[count];
            counts = new uint[count];
            ccIdx = new byte[count];
            for (int i = 0; i < count; i++)
            {
                starts[i] = BitConverter.ToUInt32(data, p); p += 4;
                counts[i] = BitConverter.ToUInt32(data, p); p += 4;
                ccIdx[i] = data[p]; p += 1;
            }
        }

        /// <summary>查国家码；未收录返回空字符串。</summary>
        public static string Country(string ip)
        {
            EnsureLoaded();
            if (starts == null) return "";

            uint u;
            if (!TryParse(ip, out u)) return "";

            int lo = 0, hi = starts.Length - 1;
            while (lo <= hi)
            {
                int mid = (lo + hi) / 2;
                uint s = starts[mid];
                uint c = counts[mid];
                if (u < s) hi = mid - 1;
                else if (u >= s + c) lo = mid + 1;
                else
                {
                    int idx = ccIdx[mid];
                    return (ccTable != null && idx >= 0 && idx < ccTable.Length) ? ccTable[idx] : "";
                }
            }
            return "";
        }

        public static bool TryParse(string ip, out uint value)
        {
            value = 0;
            if (string.IsNullOrEmpty(ip)) return false;
            string[] p = ip.Split('.');
            if (p.Length != 4) return false;
            uint r = 0;
            for (int i = 0; i < 4; i++)
            {
                byte b;
                if (!byte.TryParse(p[i], out b)) return false;
                r = (r << 8) | b;
            }
            value = r;
            return true;
        }

        public static string CountryName(string cc)
        {
            if (string.IsNullOrEmpty(cc) || cc == "ZZ") return "未知";
            try { return new RegionInfo(cc).NativeName; }
            catch { return cc; }
        }

        /// <summary>国家码 -> 大陆。</summary>
        public static Continent Of(string cc)
        {
            if (string.IsNullOrEmpty(cc)) return Continent.Unknown;
            string c = cc.ToUpperInvariant();
            if (AsiaSet.Contains(c)) return Continent.Asia;
            if (EuropeSet.Contains(c)) return Continent.Europe;
            if (NorthAmericaSet.Contains(c)) return Continent.NorthAmerica;
            if (SouthAmericaSet.Contains(c)) return Continent.SouthAmerica;
            if (OceaniaSet.Contains(c)) return Continent.Oceania;
            if (AfricaSet.Contains(c)) return Continent.Africa;
            return Continent.Unknown;
        }

        public static string ContinentName(Continent c)
        {
            switch (c)
            {
                case Continent.Asia: return "亚洲";
                case Continent.Europe: return "欧洲";
                case Continent.NorthAmerica: return "北美洲";
                case Continent.SouthAmerica: return "南美洲";
                case Continent.Oceania: return "大洋洲";
                case Continent.Africa: return "非洲";
                default: return "未选择";
            }
        }

        /// <summary>该大陆的国家码列表（按国家码排序）。</summary>
        public static List<string> CountriesOf(Continent c)
        {
            List<string> list = new List<string>();
            foreach (string cc in AllCountries())
                if (Of(cc) == c) list.Add(cc);
            list.Sort(StringComparer.Ordinal);
            return list;
        }

        /// <summary>库里出现过的国家码；库里没加载出来时退回硬编码常见集。</summary>
        public static List<string> AllCountries()
        {
            EnsureLoaded();
            List<string> list = new List<string>();
            if (ccTable != null) list.AddRange(ccTable);
            if (list.Count == 0)
            {
                list.AddRange(AsiaSet); list.AddRange(EuropeSet); list.AddRange(NorthAmericaSet);
                list.AddRange(SouthAmericaSet); list.AddRange(OceaniaSet); list.AddRange(AfricaSet);
            }
            list.Sort(StringComparer.Ordinal);
            return list;
        }

        /// <summary>
        /// 应用内重新查询：下载 DB-IP Lite，转成同样的二进制写到 ProgramData，然后重新加载。
        /// 返回 (成功, 说明)。
        /// </summary>
        public static async Task<(bool ok, string message)> RefreshAsync(IProgress<string> progress)
        {
            try
            {
                DateTime d = DateTime.Now;
                string url = "";
                for (int i = 0; i < 4; i++)
                {
                    string m = d.AddMonths(-i).ToString("yyyy-MM");
                    string u = "https://download.db-ip.com/free/dbip-country-lite-" + m + ".csv.gz";
                    try
                    {
                        if (progress != null) progress.Report("尝试 " + m + " …");
                        using (HttpClient c = Http.Create(180, "VRChat-Selector/1.0"))
                        using (HttpResponseMessage r = await c.GetAsync(u, HttpCompletionOption.ResponseHeadersRead))
                        {
                            if (!r.IsSuccessStatusCode) continue;
                            using (Stream s = await r.Content.ReadAsStreamAsync())
                            using (GZipStream gz = new GZipStream(s, CompressionMode.Decompress))
                            using (StreamReader sr = new StreamReader(gz, Encoding.UTF8))
                            {
                                string body = await sr.ReadToEndAsync();
                                url = u;
                                if (progress != null) progress.Report("解析中…");
                                int total;
                                byte[] bin = BuildBinary(body, out total);
                                if (bin == null) continue;
                                Directory.CreateDirectory(DriverManager.RootDir);
                                File.WriteAllBytes(OverridePath, bin);
                                lock (gate) { loaded = false; loaded = true; }
                                // 重置并重载
                                lock (gate)
                                {
                                    loaded = false;
                                    starts = null; counts = null; ccIdx = null; ccTable = null;
                                }
                                EnsureLoaded();
                                return (true, "已更新：" + total + " 条记录（数据源 " + m + "）");
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        if (progress != null) progress.Report("失败：" + ex.Message);
                    }
                }
                return (false, "下载失败：DB-IP 不可达（可能需要代理）");
            }
            catch (Exception ex)
            {
                return (false, "刷新异常：" + ex.Message);
            }
        }

        private static byte[] BuildBinary(string csv, out int total)
        {
            total = 0;
            List<uint> st = new List<uint>();
            List<uint> ct = new List<uint>();
            List<int> ci = new List<int>();          // 每行对应的国家索引
            List<string> ccList = new List<string>();
            Dictionary<string, int> ccMap = new Dictionary<string, int>(StringComparer.Ordinal);

            foreach (string raw in csv.Split('\n'))
            {
                string line = raw.TrimEnd('\r');
                if (line.Length == 0) continue;
                string[] p = line.Split(',');
                if (p.Length < 3) continue;
                if (p[0].IndexOf(':') >= 0) continue;         // IPv6
                string cc = p[2];
                if (cc.Length != 2) continue;
                uint s, e;
                if (!TryParse(p[0], out s) || !TryParse(p[1], out e) || e <= s) continue;
                st.Add(s); ct.Add(e - s + 1);
                int idx;
                if (!ccMap.TryGetValue(cc, out idx)) { idx = ccList.Count; ccList.Add(cc); ccMap[cc] = idx; }
                ci.Add(idx);
                total++;
            }
            if (total == 0) return null;

            // 记录数可能远超内存友好范围，用 MemoryStream 直接写
            MemoryStream ms = new MemoryStream(total * 9 + ccList.Count * 2 + 16);
            BinaryWriter bw = new BinaryWriter(ms);
            bw.Write(new byte[] { 0x56, 0x47, 0x54, 0x31 });
            bw.Write((uint)total);
            bw.Write((ushort)ccList.Count);
            foreach (string cc in ccList) { bw.Write((byte)cc[0]); bw.Write((byte)cc[1]); }
            for (int i = 0; i < total; i++)
            {
                bw.Write(st[i]);
                bw.Write(ct[i]);
                bw.Write((byte)ci[i]);
            }
            bw.Flush();
            byte[] bytes = ms.ToArray();
            bw.Dispose(); ms.Dispose();
            return bytes;
        }


        private static readonly HashSet<string> AsiaSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "CN","HK","MO","TW","JP","KR","KP","MN","SG","MY","ID","PH","TH","VN","LA","KH","MM","BN",
            "IN","PK","BD","LK","NP","BT","MV","AF","IR","IQ","IL","JO","LB","SY","SA","AE","QA","BH",
            "KW","OM","YE","TR","GE","AM","AZ","KZ","UZ","TM","TJ","KG","RU","NP"
        };

        private static readonly HashSet<string> EuropeSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "GB","IE","FR","DE","NL","BE","LU","CH","AT","IT","ES","PT","GR","DK","SE","NO","FI","IS",
            "PL","CZ","SK","HU","RO","BG","HR","SI","RS","BA","ME","MK","AL","EE","LV","LT","BY","UA",
            "MD","MT","CY","AD","MC","SM","VA","LI","FO","GI","JE","GG","IM","AX","SJ","RE","GP","MQ"
        };

        private static readonly HashSet<string> NorthAmericaSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "US","CA","MX","GT","BZ","SV","HN","NI","CR","PA","CU","JM","HT","DO","PR","TT","BB","BS",
            "GD","LC","VC","DM","AG","KN","VI","KY","BM","GL","PM","AW","CW","SX","BQ","AI","MS","TC","VG"
        };

        private static readonly HashSet<string> SouthAmericaSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "BR","AR","CL","CO","PE","VE","EC","BO","PY","UY","GY","SR","GF","FK"
        };

        private static readonly HashSet<string> OceaniaSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "AU","NZ","PG","FJ","SB","VU","NC","PF","WS","TO","KI","TV","NR","PW","FM","MH","GU","AS","MP","CK","NU","TK","WF","PN","CC","CX","NF"
        };

        private static readonly HashSet<string> AfricaSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "ZA","EG","NG","KE","ET","GH","TZ","UG","AO","MZ","ZW","ZM","BW","NA","MW","MG","MU","SC","RW",
            "BI","CD","CG","CM","CI","SN","ML","BF","NE","TD","SD","SS","LY","TN","DZ","MA","EH","GM","GW",
            "GN","SL","LR","TG","BJ","MR","CV","ST","GQ","GA","CF","SO","DJ","ER","LS","SZ","KM","YT","SH"
        };
    }
}
