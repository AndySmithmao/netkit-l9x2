using System;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace VrcTool
{
    /// <summary>trace 的单条结果。</summary>
    public sealed class TraceResult
    {
        public string Node = "";
        public int MinMs = -1;
        public int AvgMs = -1;
        public int Loss = 0;
        public int Tries = 0;
        public string Error = "";

        public string Display
        {
            get
            {
                if (MinMs < 0) return Error == "" ? "失败" : "失败（" + Error + "）";
                return MinMs + " ms" + (Loss > 0 ? "  丢 " + Loss + "/" + Tries : "");
            }
        }
    }

    /// <summary>
    /// 逐节点 trace：把 mihomo 的组切到某个节点，再通过本地 SOCKS5 端口对目标
    /// 发一个最小的 HTTP 请求，量「到首字节」的时间。
    ///
    /// 为什么不用 mihomo 自带的 /delay 接口：
    ///   实测对 proxy-provider 里的节点直接返回 404（Resource not found），拿不到数。
    ///
    /// 为什么不能量「SOCKS5 CONNECT 的返回耗时」：
    ///   mihomo 对 CONNECT 是乐观应答，收到请求立刻回成功、不等上游建连，
    ///   量出来永远 0~1ms（这个坑实测过）。
    ///
    /// 所以这里走真实往返：建隧道 → 发 HTTP 请求 → 等第一个字节。
    /// 对不回应 TCP/HTTP 的目标（例如 Photon 的 UDP 27002）会明确报"目标无响应"，
    /// 而不是给一个假的 0ms。
    /// </summary>
    internal static class TraceRunner
    {
        public static async Task<TraceResult> RunOneAsync(MihomoApi api, string group, string node,
                                                          string host, int port, int tries,
                                                          CancellationToken ct)
        {
            TraceResult r = new TraceResult();
            r.Node = node;
            r.Tries = tries;

            bool ok = await api.SelectNodeAsync(group, node);
            if (!ok) { r.Error = "切换节点失败"; return r; }
            await Task.Delay(120, ct);

            // 443 是 TLS 端口：发明文 HTTP 会一直等到超时（这正是"延迟 1600ms"的来源）。
            // 所以 443 走真正的 TLS 握手计时；其它端口发普通 HTTP 请求量首字节。
            string hostHeader = (port == 80 || port == 443) ? host : host + ":" + port;
            bool useTls = (port == 443);
            string path = (host == "www.gstatic.com") ? "/generate_204" : "/";
            byte[] req = Encoding.ASCII.GetBytes(
                "GET " + path + " HTTP/1.0\r\nHost: " + hostHeader + "\r\nUser-Agent: VrcToolTrace/1.0\r\nConnection: close\r\n\r\n");

            System.Collections.Generic.List<int> samples = new System.Collections.Generic.List<int>();
            for (int i = 0; i < tries; i++)
            {
                if (ct.IsCancellationRequested) break;
                int ms = await Task.Run(() => Probe(host, port, req, 5000, useTls), ct);
                if (ms >= 0) samples.Add(ms);
                else r.Loss++;
            }

            if (samples.Count > 0)
            {
                int min = int.MaxValue, sum = 0;
                foreach (int s in samples) { if (s < min) min = s; sum += s; }
                r.MinMs = min;
                r.AvgMs = sum / samples.Count;
            }
            else
            {
                r.Error = "目标无响应（不回应 TCP/HTTP）";
            }
            return r;
        }

        /// <summary>
        /// 经本地 SOCKS5 对目标做 TLS 握手，返回耗时（ms），失败 -1。
        /// 用于"逐节点 ping 一个 IP"：ICMP 内核不支持走代理（日志里全是 using DIRECT），
        /// 所以用 TCP+TLS 握手当等效延迟 —— 对 443 有服务的 IP（如 Google）完全够用。
        /// </summary>
        public static int ProbeTls(string host, int port, string sni, int timeoutMs)
        {
            Stopwatch sw = new Stopwatch();
            try
            {
                using (TcpClient c = new TcpClient())
                {
                    if (!c.ConnectAsync("127.0.0.1", MihomoConfig.MixedPort).Wait(timeoutMs)) return -1;
                    NetworkStream s = c.GetStream();
                    s.ReadTimeout = timeoutMs;
                    s.WriteTimeout = timeoutMs;

                    s.Write(new byte[] { 0x05, 0x01, 0x00 }, 0, 3);
                    byte[] buf = new byte[2];
                    if (!ReadExact(s, buf, 2) || buf[1] != 0x00) return -1;

                    IPAddress ip;
                    byte[] head;
                    if (IPAddress.TryParse(host, out ip) && ip.AddressFamily == AddressFamily.InterNetwork)
                    {
                        head = new byte[10];
                        head[0] = 0x05; head[1] = 0x01; head[2] = 0x00; head[3] = 0x01;
                        Array.Copy(ip.GetAddressBytes(), 0, head, 4, 4);
                        head[8] = (byte)(port >> 8); head[9] = (byte)(port & 0xFF);
                    }
                    else
                    {
                        byte[] name = Encoding.ASCII.GetBytes(host);
                        head = new byte[5 + name.Length + 2];
                        head[0] = 0x05; head[1] = 0x01; head[2] = 0x00; head[3] = 0x03;
                        head[4] = (byte)name.Length;
                        Array.Copy(name, 0, head, 5, name.Length);
                        head[5 + name.Length] = (byte)(port >> 8);
                        head[6 + name.Length] = (byte)(port & 0xFF);
                    }
                    s.Write(head, 0, head.Length);

                    byte[] rep = new byte[4];
                    if (!ReadExact(s, rep, 4) || rep[1] != 0x00) return -1;
                    int addrLen = rep[3] == 0x01 ? 4 : (rep[3] == 0x04 ? 16 : (rep[3] == 0x03 ? ReadOne(s) : 0));
                    byte[] skip = new byte[addrLen + 2];
                    if (!ReadExact(s, skip, skip.Length)) return -1;

                    sw.Start();
                    using (System.Net.Security.SslStream ssl = new System.Net.Security.SslStream(s, false,
                               delegate { return true; }))
                    {
                        ssl.AuthenticateAsClient(sni);
                    }
                    sw.Stop();
                    return (int)sw.ElapsedMilliseconds;
                }
            }
            catch { return -1; }
        }
        /// <summary>经本地 SOCKS5 向目标发 HTTP 请求，返回首字节耗时（ms），失败 -1。</summary>
        private static int Probe(string host, int port, byte[] request, int timeoutMs, bool useTls)
        {
            Stopwatch sw = new Stopwatch();
            try
            {
                using (TcpClient c = new TcpClient())
                {
                    if (!c.ConnectAsync("127.0.0.1", MihomoConfig.MixedPort).Wait(timeoutMs)) return -1;
                    NetworkStream s = c.GetStream();
                    s.ReadTimeout = timeoutMs;
                    s.WriteTimeout = timeoutMs;

                    s.Write(new byte[] { 0x05, 0x01, 0x00 }, 0, 3);
                    byte[] buf = new byte[2];
                    if (!ReadExact(s, buf, 2) || buf[0] != 0x05 || buf[1] != 0x00) return -1;

                    IPAddress ip;
                    byte[] head;
                    if (IPAddress.TryParse(host, out ip) && ip.AddressFamily == AddressFamily.InterNetwork)
                    {
                        head = new byte[10];
                        head[0] = 0x05; head[1] = 0x01; head[2] = 0x00; head[3] = 0x01;
                        Array.Copy(ip.GetAddressBytes(), 0, head, 4, 4);
                        head[8] = (byte)(port >> 8); head[9] = (byte)(port & 0xFF);
                    }
                    else
                    {
                        byte[] name = Encoding.ASCII.GetBytes(host);
                        head = new byte[5 + name.Length + 2];
                        head[0] = 0x05; head[1] = 0x01; head[2] = 0x00; head[3] = 0x03;
                        head[4] = (byte)name.Length;
                        Array.Copy(name, 0, head, 5, name.Length);
                        head[5 + name.Length] = (byte)(port >> 8);
                        head[6 + name.Length] = (byte)(port & 0xFF);
                    }
                    s.Write(head, 0, head.Length);

                    byte[] rep = new byte[4];
                    if (!ReadExact(s, rep, 4) || rep[0] != 0x05 || rep[1] != 0x00) return -1;
                    int addrLen = rep[3] == 0x01 ? 4 : (rep[3] == 0x04 ? 16 : (rep[3] == 0x03 ? ReadOne(s) : 0));
                    byte[] skip = new byte[addrLen + 2];
                    if (!ReadExact(s, skip, skip.Length)) return -1;

                    sw.Start();
                    if (useTls)
                    {
                        // TLS 握手耗时 ≈ 节点到目标的真实 RTT + 1 RTT（含证书）
                        using (System.Net.Security.SslStream ssl = new System.Net.Security.SslStream(s, false,
                                   delegate { return true; }))
                        {
                            ssl.AuthenticateAsClient(host);
                        }
                        sw.Stop();
                        return (int)sw.ElapsedMilliseconds;
                    }

                    s.Write(request, 0, request.Length);
                    byte[] one = new byte[1];
                    int n = s.Read(one, 0, 1);
                    sw.Stop();
                    if (n <= 0) return -1;
                    return (int)sw.ElapsedMilliseconds;
                }
            }
            catch { return -1; }
        }

        private static int ReadOne(NetworkStream s)
        {
            byte[] b = new byte[1];
            if (!ReadExact(s, b, 1)) return 0;
            return b[0];
        }

        private static bool ReadExact(NetworkStream s, byte[] buf, int count)
        {
            int got = 0;
            while (got < count)
            {
                int n = s.Read(buf, got, count - got);
                if (n <= 0) return false;
                got += n;
            }
            return true;
        }
    }
}
