using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;

namespace VrcTool
{
    /// <summary>
    /// 更新检查结果缓存。
    ///
    /// 为什么需要：GitHub 匿名 API 每小时只有 60 次配额，
    /// 而启动检查一次就要 3 个请求（应用 + mihomo + winws）。
    /// 反复启动程序很容易把配额打爆（实测 403 rate limit）。
    /// 所以结果缓存 6 小时；用户手动点「检查更新」时强制刷新。
    /// </summary>
    internal static class UpdateCache
    {
        private const int TtlHours = 6;

        private static string CachePath
        {
            get { return Path.Combine(DriverManager.RootDir, "update.cache.json"); }
        }

        private sealed class Entry
        {
            public DateTime Time { get; set; }
            public string Payload { get; set; }
        }

        private static Dictionary<string, Entry> Load()
        {
            try
            {
                if (!File.Exists(CachePath)) return new Dictionary<string, Entry>();
                string json = File.ReadAllText(CachePath);
                return JsonSerializer.Deserialize<Dictionary<string, Entry>>(json) ?? new Dictionary<string, Entry>();
            }
            catch { return new Dictionary<string, Entry>(); }
        }

        private static void Save(Dictionary<string, Entry> map)
        {
            try
            {
                Directory.CreateDirectory(DriverManager.RootDir);
                File.WriteAllText(CachePath, JsonSerializer.Serialize(map));
            }
            catch { }
        }

        /// <summary>取缓存（过期或不存在返回 null）。</summary>
        public static string Get(string key)
        {
            try
            {
                Dictionary<string, Entry> map = Load();
                Entry e;
                if (!map.TryGetValue(key, out e) || e == null || string.IsNullOrEmpty(e.Payload)) return null;
                if ((DateTime.Now - e.Time).TotalHours > TtlHours) return null;
                return e.Payload;
            }
            catch { return null; }
        }

        /// <summary>写缓存。</summary>
        public static void Put(string key, string payload)
        {
            try
            {
                Dictionary<string, Entry> map = Load();
                map[key] = new Entry { Time = DateTime.Now, Payload = payload };
                Save(map);
            }
            catch { }
        }

        /// <summary>
        /// 把 GitHub Release 的完整 JSON 压成只含必要字段的形状。
        ///
        /// 为什么需要：完整 JSON 里有更新说明正文（release body）、上传者、digest 等，
        /// 实测三万字的说明会让缓存文件涨到 300 KB 以上。这里只保留版本号与资产列表，
        /// 两个解析方（应用更新 / 内核更新）都只读这些字段。
        /// </summary>
        public static string CompactRelease(string body)
        {
            try
            {
                using (JsonDocument doc = JsonDocument.Parse(body))
                {
                    JsonElement root = doc.RootElement;
                    string tag = "";
                    JsonElement v;
                    if (root.TryGetProperty("tag_name", out v) && v.ValueKind == JsonValueKind.String) tag = v.GetString();

                    List<object> assets = new List<object>();
                    JsonElement arr;
                    if (root.TryGetProperty("assets", out arr) && arr.ValueKind == JsonValueKind.Array)
                    {
                        foreach (JsonElement a in arr.EnumerateArray())
                        {
                            assets.Add(new
                            {
                                name = Str(a, "name"),
                                browser_download_url = Str(a, "browser_download_url"),
                                url = Str(a, "url"),
                                size = Num(a, "size")
                            });
                        }
                    }

                    return JsonSerializer.Serialize(new { tag_name = tag, assets });
                }
            }
            catch { return body; }   // 压不动就原样存，功能不受影响
        }

        private static string Str(JsonElement e, string name)
        {
            try
            {
                JsonElement v;
                if (e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.String) return v.GetString();
            }
            catch { }
            return "";
        }

        private static long Num(JsonElement e, string name)
        {
            try
            {
                JsonElement v;
                if (e.TryGetProperty(name, out v) && v.ValueKind == JsonValueKind.Number) return v.GetInt64();
            }
            catch { }
            return 0;
        }
        /// <summary>手动检查时清掉缓存。</summary>
        public static void Clear()
        {
            try { if (File.Exists(CachePath)) File.Delete(CachePath); } catch { }
        }
    }
}
