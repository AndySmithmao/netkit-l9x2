using System;
using System.Net;
using System.Net.Http;

namespace VrcTool
{
    /// <summary>
    /// 全进程共享的 HTTP 基础设施。
    ///
    /// 为什么要共享：HttpClient 每次 new 都会新建连接池，频繁调用（更新检查、订阅下载、
    /// 内核更新）会不断创建销毁连接，容易把本地端口耗尽。这里共享一个 SocketsHttpHandler，
    /// HttpClient 本身仍然按需创建（它很轻，真正的资源在 handler 里）。
    /// </summary>
    internal static class Http
    {
        private static readonly SocketsHttpHandler SharedHandler = CreateHandler();

        private static SocketsHttpHandler CreateHandler()
        {
            SocketsHttpHandler h = new SocketsHttpHandler();
            // 连接 5 分钟后回收，兼顾复用与 DNS 变化
            h.PooledConnectionLifetime = TimeSpan.FromMinutes(5);
            h.PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2);
            h.MaxConnectionsPerServer = 8;
            h.ConnectTimeout = TimeSpan.FromSeconds(10);
            h.AllowAutoRedirect = true;
            h.MaxAutomaticRedirections = 5;
            try
            {
                h.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli;
            }
            catch { /* 老系统不支持 Brotli 就退回默认 */ }
            return h;
        }

        /// <summary>创建一个使用共享连接池的 HttpClient。</summary>
        public static HttpClient Create(int timeoutSeconds = 25, string userAgent = null)
        {
            HttpClient c = new HttpClient(SharedHandler, false);
            c.Timeout = TimeSpan.FromSeconds(timeoutSeconds);
            c.DefaultRequestHeaders.UserAgent.ParseAdd(userAgent ?? "VRChat-Selector/1.0");
            return c;
        }
    }
}
