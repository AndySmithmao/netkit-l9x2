using System;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace VrcTool
{
    /// <summary>一次更新检查的结果。</summary>
    public sealed class UpdateInfo
    {
        public string Tag = "";
        public string Version = "";
        public string Notes = "";
        public string AssetName = "";
        public string AssetApiUrl = "";
        public string AssetUrl = "";
        public long AssetSize = 0;
        public string SumsApiUrl = "";
        public string PageUrl = "";
        public bool Newer;
        public string Error = "";
        public bool FromCache;
    }

    /// <summary>
    /// 应用更新：查 GitHub Releases（公开仓库，匿名 API）。
    ///
    /// 两个现实约束：
    ///   1. 匿名 API 每小时 60 次 —— 启动检查会反复消耗，所以结果缓存 6 小时；
    ///   2. 国内直连 github.com 不通 —— 下载走镜像链（见 KernelUpdater.DownloadWithMirrors）。
    /// </summary>
    internal static class Updater
    {
        public const string Owner = "AndySmithmao";
        public const string Repo = "netkit-l9x2";

        private const string ApiBase = "https://api.github.com";

        public static string CurrentVersion
        {
            get
            {
                try
                {
                    object[] attrs = typeof(Updater).Assembly.GetCustomAttributes(
                        typeof(System.Reflection.AssemblyInformationalVersionAttribute), false);
                    if (attrs != null && attrs.Length > 0)
                    {
                        string s = ((System.Reflection.AssemblyInformationalVersionAttribute)attrs[0]).InformationalVersion;
                        if (!string.IsNullOrEmpty(s))
                        {
                            int plus = s.IndexOf('+');
                            if (plus > 0) s = s.Substring(0, plus);
                            return s.Trim();
                        }
                    }
                }
                catch { }
                try
                {
                    Version v = typeof(Updater).Assembly.GetName().Version;
                    return v.Major + "." + v.Minor + "." + v.Build;
                }
                catch { return "0.0.0"; }
            }
        }

        private static HttpClient NewClient()
        {
            HttpClient c = new HttpClient();
            c.Timeout = TimeSpan.FromSeconds(25);
            c.DefaultRequestHeaders.UserAgent.ParseAdd("VRChat-Selector-Updater/1.0");
            c.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            return c;
        }

        /// <summary>查询最新 Release；不抛异常，失败信息放 Error。</summary>
        public static async Task<UpdateInfo> CheckAsync(CancellationToken ct, bool force = false)
        {
            UpdateInfo info = new UpdateInfo();
            info.Version = CurrentVersion;
            try
            {
                string body = force ? null : UpdateCache.Get("app");
                if (body != null) info.FromCache = true;

                if (body == null)
                {
                    using (HttpClient c = NewClient())
                    using (HttpResponseMessage r = await c.GetAsync(ApiBase + "/repos/" + Owner + "/" + Repo + "/releases/latest", ct))
                    {
                        body = await r.Content.ReadAsStringAsync();
                        if (!r.IsSuccessStatusCode)
                        {
                            info.Error = FriendlyHttp((int)r.StatusCode, body);
                            return info;
                        }
                        UpdateCache.Put("app", body);
                    }
                }

                using (JsonDocument doc = JsonDocument.Parse(body))
                {
                    JsonElement root = doc.RootElement;
                    info.Tag = GetStr(root, "tag_name");
                    info.Version = info.Tag.TrimStart('v', 'V');
                    info.Notes = GetStr(root, "body");
                    info.PageUrl = GetStr(root, "html_url");

                    JsonElement assets;
                    if (root.TryGetProperty("assets", out assets) && assets.ValueKind == JsonValueKind.Array)
                    {
                        foreach (JsonElement a in assets.EnumerateArray())
                        {
                            string name = GetStr(a, "name");
                            if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                            {
                                bool isSetup = name.IndexOf("Setup", StringComparison.OrdinalIgnoreCase) >= 0;
                                bool haveSetup = info.AssetName.IndexOf("Setup", StringComparison.OrdinalIgnoreCase) >= 0;
                                bool better = info.AssetApiUrl.Length == 0 || (isSetup && !haveSetup);
                                if (better)
                                {
                                    info.AssetName = name;
                                    info.AssetApiUrl = GetStr(a, "url");
                                    info.AssetUrl = GetStr(a, "browser_download_url");
                                    long size = 0;
                                    try { if (a.TryGetProperty("size", out JsonElement sz)) size = sz.GetInt64(); } catch { }
                                    info.AssetSize = size;
                                }
                            }
                            else if (name.Equals("SHA256SUMS.txt", StringComparison.OrdinalIgnoreCase))
                            {
                                info.SumsApiUrl = GetStr(a, "url");
                            }
                        }
                    }
                }

                info.Newer = CompareVersion(info.Version, CurrentVersion) > 0;
                if (info.AssetApiUrl.Length == 0) info.Error = "这个 Release 里没有 .exe 资产";
            }
            catch (Exception ex)
            {
                info.Error = "检查更新异常：" + ex.Message;
                DriverManager.Log("更新检查异常: " + ex);
            }
            return info;
        }

        /// <summary>下载更新包到 dest，并校验 SHA256（有 SHA256SUMS.txt 的话）。</summary>
        public static async Task<string> DownloadAsync(UpdateInfo info, string dest, IProgress<int> progress, CancellationToken ct)
        {
            string url = !string.IsNullOrEmpty(info.AssetUrl) ? info.AssetUrl : info.AssetApiUrl;
            string dlErr = await KernelUpdater.DownloadWithMirrors(url, dest, ct);
            if (dlErr.Length > 0) return dlErr;
            if (progress != null) progress.Report(100);

            if (string.IsNullOrEmpty(info.SumsApiUrl)) return "";
            try
            {
                using (HttpClient c = NewClient())
                using (HttpRequestMessage req = new HttpRequestMessage(HttpMethod.Get, info.SumsApiUrl))
                {
                    req.Headers.Accept.Clear();
                    req.Headers.Accept.ParseAdd("application/octet-stream");
                    using (HttpResponseMessage r = await c.SendAsync(req, ct))
                    {
                        if (!r.IsSuccessStatusCode) return "";
                        string sums = await r.Content.ReadAsStringAsync();
                        string expect = FindHash(sums, info.AssetName);
                        string actual = Sha256File(dest);
                        if (!string.IsNullOrEmpty(expect) && !expect.Equals(actual, StringComparison.OrdinalIgnoreCase))
                            return "SHA256 校验失败：期望 " + expect.Substring(0, 16) + "…，实际 " + actual.Substring(0, 16) + "…";
                    }
                }
            }
            catch (Exception ex) { DriverManager.Log("校验和下载失败（忽略）: " + ex.Message); }
            return "";
        }

        public static string Sha256File(string path)
        {
            using (var sha = System.Security.Cryptography.SHA256.Create())
            using (FileStream fs = File.OpenRead(path))
            {
                byte[] h = sha.ComputeHash(fs);
                StringBuilder sb = new StringBuilder();
                foreach (byte b in h) sb.Append(b.ToString("x2"));
                return sb.ToString();
            }
        }

        private static string FindHash(string sums, string fileName)
        {
            foreach (string line in sums.Split('\n'))
            {
                string t = line.Trim();
                if (t.Length < 40) continue;
                int sp = t.IndexOf(' ');
                if (sp <= 0) continue;
                string hash = t.Substring(0, sp).Trim();
                string name = t.Substring(sp).Trim().TrimStart('*');
                if (name.Equals(fileName, StringComparison.OrdinalIgnoreCase)) return hash;
            }
            return "";
        }

        /// <summary>
        /// 语义化比较：先比数字，再比预发布标记。
        /// 0.0.1-beta &lt; 0.0.1；0.0.1-beta &lt; 0.0.2。
        /// </summary>
        public static int CompareVersion(string a, string b)
        {
            try
            {
                string ca, pa, cb, pb;
                SplitVersion(a, out ca, out pa);
                SplitVersion(b, out cb, out pb);

                string[] na = ca.Split(new char[] { '.' }, StringSplitOptions.RemoveEmptyEntries);
                string[] nb = cb.Split(new char[] { '.' }, StringSplitOptions.RemoveEmptyEntries);
                int n = Math.Max(na.Length, nb.Length);
                for (int i = 0; i < n; i++)
                {
                    int x = 0, y = 0;
                    if (i < na.Length) int.TryParse(na[i], out x);
                    if (i < nb.Length) int.TryParse(nb[i], out y);
                    if (x != y) return x < y ? -1 : 1;
                }
                bool preA = pa.Length > 0, preB = pb.Length > 0;
                if (preA == preB) return string.Compare(pa, pb, StringComparison.OrdinalIgnoreCase);
                return preA ? -1 : 1;
            }
            catch { return 0; }
        }

        private static void SplitVersion(string v, out string core, out string pre)
        {
            core = (v ?? "").Trim().TrimStart('v', 'V');
            pre = "";
            int i = core.IndexOf('-');
            int j = core.IndexOf('+');
            int cut = i > 0 ? i : (j > 0 ? j : -1);
            if (cut > 0)
            {
                pre = core.Substring(cut + 1);
                core = core.Substring(0, cut);
            }
        }

        private static string FriendlyHttp(int code, string body)
        {
            string head = SafeHead(body);
            if (code == 403 && head.IndexOf("rate limit", StringComparison.OrdinalIgnoreCase) >= 0)
                return "GitHub API 限流（匿名每小时 60 次），结果会缓存 6 小时，稍后再试。";
            if (code == 404) return "仓库或 Release 不存在（HTTP 404）。";
            return "查询失败 HTTP " + code + "\r\n" + head;
        }

        private static string GetStr(JsonElement e, string name)
        {
            try
            {
                JsonElement v;
                if (e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.String) return v.GetString();
            }
            catch { }
            return "";
        }

        private static string SafeHead(string s)
        {
            if (string.IsNullOrEmpty(s)) return "";
            s = s.Replace("\r", " ").Replace("\n", " ");
            return s.Length > 200 ? s.Substring(0, 200) + "…" : s;
        }
    }
}
