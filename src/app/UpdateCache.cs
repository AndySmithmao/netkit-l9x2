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

        /// <summary>手动检查时清掉缓存。</summary>
        public static void Clear()
        {
            try { if (File.Exists(CachePath)) File.Delete(CachePath); } catch { }
        }
    }
}
