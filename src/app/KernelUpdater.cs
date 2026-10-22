using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace VrcTool
{
    /// <summary>一个可更新的内核组件。</summary>
    public sealed class KernelUpdate
    {
        public string Name = "";
        public string Installed = "";
        public string Latest = "";
        public bool Newer;
        public string AssetName = "";
        public string AssetUrl = "";
        public string Error = "";
    }

    /// <summary>
    /// 内核更新：从上游 GitHub 检查并下载 winws（bol-van/zapret）与 mihomo（MetaCubeX/mihomo）。
    ///
    /// 三个现实约束：
    ///   1. 在部分网络下直连 github.com 不通 → 下载走镜像链；
    ///   2. 匿名 API 每小时 60 次 → 检查结果缓存 6 小时；
    ///   3. 换内核有风险 → 先备份 .bak，试启动失败自动回滚。
    /// </summary>
    internal static class KernelUpdater
    {
        public const string ZapretRepo = "bol-van/zapret";
        public const string MihomoRepo = "MetaCubeX/mihomo";

        private static readonly string[] Mirrors = new string[]
        {
            "",
            "https://ghproxy.net/",
            "https://gh-proxy.com/",
            "https://ghfast.top/"
        };

        private static HttpClient NewApiClient()
        {
            HttpClient c = new HttpClient();
            c.Timeout = TimeSpan.FromSeconds(25);
            c.DefaultRequestHeaders.UserAgent.ParseAdd("VRChat-Selector-Updater/1.0");
            c.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
            return c;
        }

        /// <summary>读已安装版本（从 VERSION.txt 里抠 vX.YY 或 vX.Y.Z）。</summary>
        public static string InstalledVersion(DriverKind kind)
        {
            try
            {
                string dir = Path.Combine(DriverManager.RootDir, kind == DriverKind.Winws ? "winws" : "mihomo");
                string f = Path.Combine(dir, "VERSION.txt");
                if (!File.Exists(f)) return "";
                Match m = Regex.Match(File.ReadAllText(f), @"v\d+\.\d+(\.\d+)?");
                return m.Success ? m.Value : "";
            }
            catch { return ""; }
        }

        /// <summary>查两个内核的最新版本；不抛异常。</summary>
        public static async Task<List<KernelUpdate>> CheckAsync(CancellationToken ct, bool force = false)
        {
            List<KernelUpdate> list = new List<KernelUpdate>();

            KernelUpdate m = new KernelUpdate { Name = "mihomo", Installed = InstalledVersion(DriverKind.Mihomo) };
            string bm = await FetchReleaseJson("kernel-mihomo", MihomoRepo, m, ct, force);
            if (bm != null) ParseMihomo(m, bm);
            m.Newer = m.Latest.Length > 0 && m.Installed.Length > 0 && Updater.CompareVersion(m.Latest, m.Installed) > 0;
            list.Add(m);

            KernelUpdate w = new KernelUpdate { Name = "winws", Installed = InstalledVersion(DriverKind.Winws) };
            string bw = await FetchReleaseJson("kernel-zapret", ZapretRepo, w, ct, force);
            if (bw != null) ParseZapret(w, bw);
            w.Newer = w.Latest.Length > 0 && w.Installed.Length > 0 && Updater.CompareVersion(w.Latest, w.Installed) > 0;
            list.Add(w);

            return list;
        }

        private static async Task<string> FetchReleaseJson(string cacheKey, string repo, KernelUpdate target, CancellationToken ct, bool force)
        {
            string body = force ? null : UpdateCache.Get(cacheKey);
            if (body != null) return body;
            try
            {
                using (HttpClient c = NewApiClient())
                using (HttpResponseMessage r = await c.GetAsync("https://api.github.com/repos/" + repo + "/releases/latest", ct))
                {
                    body = await r.Content.ReadAsStringAsync();
                    if (!r.IsSuccessStatusCode)
                    {
                        target.Error = FriendlyHttp((int)r.StatusCode);
                        return null;
                    }
                    UpdateCache.Put(cacheKey, body);
                    return body;
                }
            }
            catch (Exception ex)
            {
                target.Error = ex.Message;
                return null;
            }
        }

        private static void ParseMihomo(KernelUpdate m, string body)
        {
            using (JsonDocument doc = JsonDocument.Parse(body))
            {
                JsonElement root = doc.RootElement;
                m.Latest = GetStr(root, "tag_name");
                JsonElement assets;
                if (!root.TryGetProperty("assets", out assets) || assets.ValueKind != JsonValueKind.Array) return;

                foreach (JsonElement a in assets.EnumerateArray())
                {
                    string n = GetStr(a, "name");
                    if (!n.StartsWith("mihomo-windows-amd64", StringComparison.OrdinalIgnoreCase)) continue;
                    bool plain = !n.Contains("-compatible-") && !n.Contains("-v1-go") && !n.Contains("-v2") && !n.Contains("-v3");
                    if (plain || m.AssetUrl.Length == 0)
                    {
                        m.AssetName = n;
                        m.AssetUrl = GetStr(a, "browser_download_url");
                        if (plain) break;
                    }
                }
            }
        }

        private static void ParseZapret(KernelUpdate w, string body)
        {
            using (JsonDocument doc = JsonDocument.Parse(body))
            {
                JsonElement root = doc.RootElement;
                w.Latest = GetStr(root, "tag_name");
                JsonElement assets;
                if (!root.TryGetProperty("assets", out assets) || assets.ValueKind != JsonValueKind.Array) return;

                foreach (JsonElement a in assets.EnumerateArray())
                {
                    string n = GetStr(a, "name");
                    if (!n.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) continue;
                    w.AssetName = n;
                    w.AssetUrl = GetStr(a, "browser_download_url");
                    break;
                }
            }
        }

        private static string FriendlyHttp(int code)
        {
            if (code == 403) return "GitHub API 限流（匿名每小时 60 次），稍后再试";
            if (code == 404) return "仓库不存在（HTTP 404）";
            return "HTTP " + code;
        }

        /// <summary>下载到 dest，自动尝试镜像。返回空字符串表示成功。</summary>
        public static async Task<string> DownloadWithMirrors(string url, string dest, CancellationToken ct)
        {
            string lastErr = "";
            foreach (string mirror in Mirrors)
            {
                string full = mirror.Length == 0 ? url : mirror + url;
                try
                {
                    using (HttpClient c = new HttpClient())
                    {
                        c.Timeout = TimeSpan.FromSeconds(mirror.Length == 0 ? 12 : 120);
                        c.DefaultRequestHeaders.UserAgent.ParseAdd("VRChat-Selector-Updater/1.0");
                        using (HttpResponseMessage r = await c.GetAsync(full, HttpCompletionOption.ResponseHeadersRead, ct))
                        {
                            if (!r.IsSuccessStatusCode)
                            {
                                lastErr = "HTTP " + (int)r.StatusCode + " @ " + (mirror.Length == 0 ? "直连" : mirror);
                                continue;
                            }
                            using (Stream s = await r.Content.ReadAsStreamAsync())
                            using (FileStream fs = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None, 81920, true))
                            {
                                await s.CopyToAsync(fs, 81920, ct);
                            }
                        }
                    }
                    if (new FileInfo(dest).Length > 100 * 1024)
                    {
                        DriverManager.Log("下载成功（源: " + (mirror.Length == 0 ? "github 直连" : mirror) + "）: " + dest);
                        return "";
                    }
                    lastErr = "文件过小";
                }
                catch (Exception ex)
                {
                    lastErr = (mirror.Length == 0 ? "直连" : mirror) + " 失败: " + ex.Message;
                    DriverManager.Log("下载尝试失败: " + lastErr);
                }
            }
            return "所有下载源都失败，最后一次：" + lastErr;
        }

        /// <summary>更新 mihomo：下载 zip → 提取 mihomo.exe → 备份替换 → 试启动（失败回滚）。</summary>
        public static async Task<string> UpdateMihomoAsync(KernelUpdate info, CancellationToken ct)
        {
            string dir = Path.Combine(DriverManager.RootDir, "mihomo");
            Directory.CreateDirectory(dir);
            string exe = Path.Combine(dir, "mihomo.exe");
            string bak = exe + ".bak";
            string zip = Path.Combine(Path.GetTempPath(), "mihomo-update.zip");

            string err = await DownloadWithMirrors(info.AssetUrl, zip, ct);
            if (err.Length > 0) return err;

            string tmpExe = Path.Combine(Path.GetTempPath(), "mihomo-new.exe");
            try
            {
                using (ZipArchive z = ZipFile.OpenRead(zip))
                {
                    ZipArchiveEntry hit = null;
                    foreach (ZipArchiveEntry e in z.Entries)
                        if (e.Name.Equals("mihomo.exe", StringComparison.OrdinalIgnoreCase) && hit == null) hit = e;
                    if (hit == null) return "压缩包里没有 mihomo.exe";
                    if (File.Exists(tmpExe)) File.Delete(tmpExe);
                    hit.ExtractToFile(tmpExe, true);
                }
            }
            catch (Exception ex) { return "解压失败：" + ex.Message; }

            bool wasRunning = DriverManager.IsRunning(DriverKind.Mihomo);
            if (wasRunning) { string m0; DriverManager.Stop(DriverKind.Mihomo, true, out m0); }

            try
            {
                if (File.Exists(bak)) File.Delete(bak);
                if (File.Exists(exe)) File.Move(exe, bak);
                File.Copy(tmpExe, exe, true);
                File.WriteAllText(Path.Combine(dir, "VERSION.txt"),
                    "Mihomo Meta " + info.Latest + " windows amd64 (updated " + DateTime.Now.ToString("yyyy-MM-dd") + ")", Encoding.UTF8);

                if (wasRunning)
                {
                    string msg;
                    if (!DriverManager.Restart(DriverKind.Mihomo, out msg))
                    {
                        try { File.Copy(bak, exe, true); } catch { }
                        DriverManager.Restart(DriverKind.Mihomo, out msg);
                        return "新版 mihomo 启动失败，已回滚到 " + info.Installed + "。\r\n" + msg;
                    }
                }
                return "";
            }
            catch (Exception ex)
            {
                try { if (File.Exists(bak)) File.Copy(bak, exe, true); } catch { }
                return "替换失败（已尝试回滚）：" + ex.Message;
            }
            finally
            {
                try { if (File.Exists(tmpExe)) File.Delete(tmpExe); } catch { }
                try { if (File.Exists(zip)) File.Delete(zip); } catch { }
            }
        }

        /// <summary>更新 winws：从 zapret 包里取 winws.exe / cygwin1.dll / WinDivert* → 备份替换 → 试启动。</summary>
        public static async Task<string> UpdateWinwsAsync(KernelUpdate info, CancellationToken ct)
        {
            string dir = Path.Combine(DriverManager.RootDir, "winws");
            Directory.CreateDirectory(dir);
            string zip = Path.Combine(Path.GetTempPath(), "zapret-update.zip");

            string err = await DownloadWithMirrors(info.AssetUrl, zip, ct);
            if (err.Length > 0) return err;

            string[] want = new string[] { "winws.exe", "cygwin1.dll", "WinDivert.dll", "WinDivert64.sys" };
            Dictionary<string, string> extracted = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                using (ZipArchive z = ZipFile.OpenRead(zip))
                {
                    foreach (string name in want)
                    {
                        ZipArchiveEntry hit = null;
                        foreach (ZipArchiveEntry e in z.Entries)
                        {
                            if (!e.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) continue;
                            if (e.FullName.IndexOf("win64", StringComparison.OrdinalIgnoreCase) >= 0) { hit = e; break; }
                            if (hit == null) hit = e;
                        }
                        if (hit == null) continue;
                        string dst = Path.Combine(Path.GetTempPath(), "zapret-" + name);
                        if (File.Exists(dst)) File.Delete(dst);
                        hit.ExtractToFile(dst, true);
                        extracted[name] = dst;
                    }
                }
            }
            catch (Exception ex) { return "解压失败：" + ex.Message; }

            if (!extracted.ContainsKey("winws.exe")) return "压缩包里没找到 winws.exe";

            bool wasRunning = DriverManager.IsRunning(DriverKind.Winws);
            if (wasRunning) { string m0; DriverManager.Stop(DriverKind.Winws, true, out m0); }

            List<string> replaced = new List<string>();
            try
            {
                foreach (KeyValuePair<string, string> kv in extracted)
                {
                    string target = Path.Combine(dir, kv.Key);
                    string bak = target + ".bak";
                    try { if (File.Exists(bak)) File.Delete(bak); } catch { }
                    if (File.Exists(target)) File.Move(target, bak);
                    File.Copy(kv.Value, target, true);
                    replaced.Add(kv.Key);
                }
                File.WriteAllText(Path.Combine(dir, "VERSION.txt"), "zapret-win-bundle " + info.Latest, Encoding.UTF8);
                File.WriteAllText(Path.Combine(dir, ".extracted"), "updated " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"), Encoding.UTF8);

                if (wasRunning)
                {
                    string msg;
                    if (!DriverManager.Restart(DriverKind.Winws, out msg))
                    {
                        foreach (string name in replaced)
                        {
                            string target = Path.Combine(dir, name);
                            string bak = target + ".bak";
                            try { if (File.Exists(bak)) File.Copy(bak, target, true); } catch { }
                        }
                        DriverManager.Restart(DriverKind.Winws, out msg);
                        return "新版 winws 启动失败，已回滚到 " + info.Installed + "。\r\n" + msg;
                    }
                }
                return "";
            }
            catch (Exception ex)
            {
                foreach (string name in replaced)
                {
                    string target = Path.Combine(dir, name);
                    string bak = target + ".bak";
                    try { if (File.Exists(bak)) File.Copy(bak, target, true); } catch { }
                }
                return "替换失败（已尝试回滚）：" + ex.Message;
            }
            finally
            {
                try { if (File.Exists(zip)) File.Delete(zip); } catch { }
                foreach (string p in extracted.Values) { try { if (File.Exists(p)) File.Delete(p); } catch { } }
            }
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
    }
}
