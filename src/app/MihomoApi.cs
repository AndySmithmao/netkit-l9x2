using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace VrcTool
{
    /// <summary>
    /// mihomo 的 RESTful API 客户端（external-controller）。
    /// 用来：取节点列表、切换节点、延迟测试、看版本。
    /// </summary>
    internal sealed class MihomoApi
    {
        private readonly string baseUrl;
        private readonly string secret;
        private readonly HttpClient http;

        public MihomoApi()
        {
            baseUrl = "http://127.0.0.1:" + MihomoConfig.ApiPort;
            secret = MihomoConfig.Secret;
            http = Http.Create(15, "VRChat-Selector/1.0");
            http.Timeout = TimeSpan.FromSeconds(20);
            try { http.DefaultRequestHeaders.Add("Authorization", "Bearer " + secret); } catch { }
        }

        public bool Available { get; private set; }

        /// <summary>等 mihomo 的 API 起来（启动后需要几百毫秒）。</summary>
        public async Task<bool> WaitReadyAsync(int timeoutMs = 8000)
        {
            int waited = 0;
            while (waited < timeoutMs)
            {
                try
                {
                    string v = await GetStringAsync("/version");
                    if (!string.IsNullOrEmpty(v)) { Available = true; return true; }
                }
                catch { }
                await Task.Delay(300);
                waited += 300;
            }
            Available = false;
            return false;
        }

        public async Task<string> VersionAsync()
        {
            try
            {
                using (JsonDocument d = JsonDocument.Parse(await GetStringAsync("/version")))
                {
                    JsonElement v;
                    if (d.RootElement.TryGetProperty("version", out v)) return v.GetString();
                }
            }
            catch { }
            return "";
        }

        /// <summary>名称 -> 类型；组的话还会带 all（成员节点名）。</summary>
        public async Task<Dictionary<string, List<string>>> GetGroupsAsync()
        {
            Dictionary<string, List<string>> result = new Dictionary<string, List<string>>(StringComparer.Ordinal);
            try
            {
                string json = await GetStringAsync("/proxies");
                using (JsonDocument d = JsonDocument.Parse(json))
                {
                    JsonElement proxies;
                    if (!d.RootElement.TryGetProperty("proxies", out proxies)) return result;
                    foreach (JsonProperty p in proxies.EnumerateObject())
                    {
                        JsonElement all;
                        if (!p.Value.TryGetProperty("all", out all)) continue;
                        if (all.ValueKind != JsonValueKind.Array) continue;
                        List<string> list = new List<string>();
                        foreach (JsonElement e in all.EnumerateArray())
                        {
                            string n = e.GetString();
                            if (!string.IsNullOrEmpty(n)) list.Add(n);
                        }
                        result[p.Name] = list;
                    }
                }
            }
            catch (Exception ex) { DriverManager.Log("取节点列表失败: " + ex.Message); }
            return result;
        }

        public async Task<List<string>> GetNodesAsync(string group)
        {
            Dictionary<string, List<string>> g = await GetGroupsAsync();
            List<string> list;
            if (g.TryGetValue(group, out list)) return list;
            return new List<string>();
        }

        /// <summary>取某个组当前选中的节点名（/proxies/{group} 的 now 字段）。</summary>
        public async Task<string> GetGroupNowAsync(string group)
        {
            try
            {
                string json = await GetStringAsync("/proxies/" + Uri.EscapeDataString(group));
                using (JsonDocument d = JsonDocument.Parse(json))
                {
                    JsonElement now;
                    if (d.RootElement.TryGetProperty("now", out now) && now.ValueKind == JsonValueKind.String)
                        return now.GetString();
                }
            }
            catch { }
            return "";
        }
        public async Task<bool> SelectNodeAsync(string group, string node)
        {
            try
            {
                StringContent body = new StringContent("{\"name\":" + JsonSerializer.Serialize(node) + "}", Encoding.UTF8, "application/json");
                HttpResponseMessage r = await http.PutAsync(baseUrl + "/proxies/" + Uri.EscapeDataString(group), body);
                return r.IsSuccessStatusCode;
            }
            catch { return false; }
        }

        /// <summary>切换代理模式：rule / global / direct（PATCH /configs）。</summary>
        public async Task<bool> SetModeAsync(string mode)
        {
            try
            {
                HttpRequestMessage req = new HttpRequestMessage(new HttpMethod("PATCH"), baseUrl + "/configs");
                req.Content = new StringContent("{\"mode\":" + JsonSerializer.Serialize(mode) + "}", Encoding.UTF8, "application/json");
                HttpResponseMessage r = await http.SendAsync(req);
                return r.IsSuccessStatusCode;
            }
            catch { return false; }
        }

        /// <summary>让 mihomo 自己对某个节点做延迟测试（走 HTTP，不是真实游戏端口）。</summary>
        public async Task<int> DelayAsync(string node, string url, int timeoutMs = 5000)
        {
            try
            {
                string u = baseUrl + "/proxies/" + Uri.EscapeDataString(node) + "/delay?timeout=" + timeoutMs +
                           "&url=" + Uri.EscapeDataString(url);
                using (JsonDocument d = JsonDocument.Parse(await GetStringAsync(u, timeoutMs + 3000)))
                {
                    JsonElement delay;
                    if (d.RootElement.TryGetProperty("delay", out delay) && delay.ValueKind == JsonValueKind.Number)
                        return delay.GetInt32();
                }
            }
            catch { }
            return -1;
        }

        private async Task<string> GetStringAsync(string path, int timeoutMs = 8000)
        {
            using (CancellationTokenSource cts = new CancellationTokenSource(timeoutMs))
            {
                HttpResponseMessage r = await http.GetAsync(baseUrl + path, cts.Token);
                r.EnsureSuccessStatusCode();
                return await r.Content.ReadAsStringAsync();
            }
        }
    }
}
