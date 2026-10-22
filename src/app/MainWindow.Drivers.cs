using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net;
using System.Text;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace VrcTool
{
    /// <summary>trace 表格的一行。</summary>
    public sealed class TraceRow
    {
        public string Node { get; set; }
        public string MinText { get; set; }
        public string AvgText { get; set; }
        public string LossText { get; set; }
        /// <summary>排序用：最小延迟数值；无响应给 int.MaxValue，让它沉到最后。</summary>
        public int SortKey { get; set; } = int.MaxValue;
    }

    /// <summary>
    /// 节点卡片。做成卡片墙而不是下拉框，是为了像 Clash Verge 那样
    /// 一眼看到全部节点和延迟，点一下即切换。
    /// </summary>
    public sealed class NodeTile
    {
        public string Name { get; set; }
        public string Sub { get; set; }
        public int Lat { get; set; } = -1;
        public bool Selected { get; set; }

        public string LatText { get { return Lat < 0 ? "—" : Lat + " ms"; } }

        public System.Windows.Media.Brush LatBrush
        {
            get
            {
                if (Lat < 0) return System.Windows.Media.Brushes.Gray;
                if (Lat < 60) return System.Windows.Media.Brushes.SeaGreen;
                if (Lat < 120) return System.Windows.Media.Brushes.DarkOrange;
                if (Lat < 200) return System.Windows.Media.Brushes.OrangeRed;
                return System.Windows.Media.Brushes.Firebrick;
            }
        }

        public System.Windows.Media.Brush Bg
        {
            get
            {
                return Selected
                    ? new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(38, 0, 120, 215))
                    : System.Windows.Media.Brushes.Transparent;
            }
        }

        public System.Windows.Media.Brush Border
        {
            get
            {
                return Selected
                    ? new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(180, 0, 120, 215))
                    : new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromArgb(40, 128, 128, 128));
            }
        }
    }

    /// <summary>
    /// 主窗口的「内核」与「代理（mihomo）」两个导航页。
    ///
    /// 这两块内容放在左侧导航里，而不是弹一个独立窗口 ——
    /// 用户的操作路径是「左边点一下，右边就换页」，弹窗打断感太强。
    /// </summary>
    public partial class MainWindow
    {
        private readonly ObservableCollection<TraceRow> traceRows = new ObservableCollection<TraceRow>();
        private readonly ObservableCollection<NodeTile> nodeTiles = new ObservableCollection<NodeTile>();
        private List<string> currentNodeNames = new List<string>();
        private CancellationTokenSource traceCts;
        private bool mihomoUiLoading;
        private bool groupsLoadedOnce;
        private bool syncingKernelUi;

        // ---------------------------------------------------------------- 刷新

        /// <summary>刷新两个内核的版本 / 状态 / 按钮可用性，以及自启勾选。</summary>
        private void RefreshKernelUi()
        {
            syncingKernelUi = true;
            try
            {
                DriverState w = DriverManager.Get(DriverKind.Winws);
                TxtWinwsVersion.Text = "版本：" + (string.IsNullOrEmpty(w.Version) ? "内置（尚未释放）" : w.Version);
                TxtWinwsStatus.Text = "状态：" + w.StatusText;
                BtnWinwsStart.IsEnabled = !w.Running;
                BtnWinwsStop.IsEnabled = w.Running;
                BtnWinwsRestart.IsEnabled = w.Running;

                DriverState m = DriverManager.Get(DriverKind.Mihomo);
                TxtMihomoVersion.Text = "版本：" + (string.IsNullOrEmpty(m.Version) ? "内置（尚未释放）" : m.Version);
                TxtMihomoStatus.Text = "状态：" + m.StatusText;
                BtnMihomoStart.IsEnabled = !m.Running;
                BtnMihomoStop.IsEnabled = m.Running;
                BtnMihomoRestart.IsEnabled = m.Running;

                ChkAutoStart.IsChecked = DriverManager.AutoStartApp;
                ChkAutoStartDrivers.IsChecked = UiState.Current.AutoStartDrivers;

                if (!string.IsNullOrEmpty(MihomoConfig.Subscription))
                    TxtSubscription.Text = MihomoConfig.Subscription;
                ChkTun.IsChecked = MihomoConfig.TunEnabled;

                if (GridTrace.ItemsSource == null) GridTrace.ItemsSource = traceRows;

                // 节点列表懒加载：只在 mihomo 跑着且还没加载过时拉一次
                if (m.Running && !groupsLoadedOnce && !mihomoUiLoading) LoadGroupsAsync().ConfigureAwait(false);
            }
            catch (Exception __ex) { Swallowed(__ex); }
            finally { syncingKernelUi = false; }
        }

        private async Task LoadGroupsAsync()
        {
            try
            {
                mihomoUiLoading = true;
                MihomoApi api = new MihomoApi();
                if (!await api.WaitReadyAsync(2500)) return;

                Dictionary<string, List<string>> groups = await api.GetGroupsAsync();
                string keep = CmbGroup.SelectedItem as string;
                CmbGroup.Items.Clear();
                foreach (string name in groups.Keys) CmbGroup.Items.Add(name);

                string pick = null;
                if (!string.IsNullOrEmpty(keep) && groups.ContainsKey(keep)) pick = keep;
                else if (groups.ContainsKey(MihomoConfig.GroupPhoton)) pick = MihomoConfig.GroupPhoton;
                else if (CmbGroup.Items.Count > 0) pick = CmbGroup.Items[0] as string;

                if (pick != null)
                {
                    CmbGroup.SelectedItem = pick;
                    await FillNodeTilesAsync(api, pick);
                }
                if (groups.Count > 0) groupsLoadedOnce = true;
                try
                {
                    TxtSubInfo.Text = "已加载 " + groups.Count + " 个组" +
                                      (pick != null ? "，当前组 " + nodeTiles.Count + " 个节点" : "");
                    TxtNodeHint.Text = nodeTiles.Count > 0
                        ? "共 " + nodeTiles.Count + " 个节点，点卡片即切换（当前：" + (CmbGroup.SelectedItem as string) + "）"
                        : "节点列表为空 —— 先到「订阅」页导入，或到「内核」页开启 mihomo。";
                }
                catch { }
            }
            catch (Exception ex) { DriverManager.Log("加载节点失败: " + ex.Message); }
            finally { mihomoUiLoading = false; }
        }

        /// <summary>重启 mihomo 并重新加载节点（订阅更新后用）。</summary>
        private async Task RestartMihomoAndReloadAsync(string okTitle)
        {
            string msg;
            bool ok = DriverManager.Restart(DriverKind.Mihomo, out msg);
            Append("[内核] mihomo " + msg);
            if (!ok)
            {
                Ui.Warn(msg, "mihomo 重启失败");
                RefreshKernelUi();
                return;
            }
            MihomoApi api = new MihomoApi();
            bool ready = await api.WaitReadyAsync(10000);
            groupsLoadedOnce = false;
            await LoadGroupsAsync();
            RefreshKernelUi();
            if (!ready) Append("[内核] mihomo API 未就绪（看内核日志）");
            else Append("[内核] " + okTitle);
        }

        // ---------------------------------------------------------------- 节点卡片

        /// <summary>把某组里的节点铺成卡片，并标出当前选中的那个。</summary>
        private async Task FillNodeTilesAsync(MihomoApi api, string group)
        {
            List<string> nodes = await api.GetNodesAsync(group);
            // 机场会塞"剩余流量 / 套餐到期"这类假节点，测它们没意义，先剔除
            nodes = nodes.Where(n => !(n.Contains("剩余流量") || n.Contains("距离下次") || n.Contains("套餐到期") || n.Contains("建议") || n.Contains("更新") || n.Contains("很少节点"))).ToList();
            currentNodeNames = nodes;
            string now = await api.GetGroupNowAsync(group);

            nodeTiles.Clear();
            foreach (string n in nodes)
            {
                nodeTiles.Add(new NodeTile
                {
                    Name = n,
                    Sub = "点一下切换",
                    Selected = (n == now)
                });
            }
            NodeList.ItemsSource = nodeTiles;
            NodeList.Items.Refresh();
        }

        /// <summary>点节点卡片 = 切换到这个节点（像 Clash Verge 那样）。</summary>
        private async void NodeTile_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                Button b = sender as Button;
                if (b == null) return;
                string node = b.Tag as string;
                string group = CmbGroup.SelectedItem as string;
                if (string.IsNullOrEmpty(node) || string.IsNullOrEmpty(group)) return;

                MihomoApi api = new MihomoApi();
                bool ok = await api.SelectNodeAsync(group, node);
                Append("[内核] " + group + " → " + node + (ok ? " 已生效" : " 切换失败"));

                foreach (NodeTile t in nodeTiles) t.Selected = (t.Name == node);
                NodeList.Items.Refresh();
                TxtNodeHint.Text = "当前节点：" + node;
            }
            catch (Exception ex) { DriverManager.Log("切换节点异常: " + ex.Message); }
        }

        /// <summary>给所有节点测一遍延迟（逐节点走一次 HTTP 请求，量首字节）。</summary>
        private async void BtnProbeNodes_Click(object sender, RoutedEventArgs e)
        {
            if (nodeTiles.Count == 0) { Ui.Warn("当前组没有节点。先去「订阅」页导入。"); return; }
            string group = CmbGroup.SelectedItem as string;
            if (string.IsNullOrEmpty(group)) return;

            string keep = null;
            foreach (NodeTile t in nodeTiles) if (t.Selected) keep = t.Name;

            BtnProbeNodes.IsEnabled = false;
            CancellationTokenSource cts = new CancellationTokenSource();
            traceCts = cts;
            MihomoApi api = new MihomoApi();
            int done = 0;
            try
            {
                foreach (NodeTile t in nodeTiles)
                {
                    if (cts.IsCancellationRequested) break;
                    TxtNodeHint.Text = "测延迟 " + (done + 1) + "/" + nodeTiles.Count + "：" + t.Name;
                    TraceResult r = await TraceRunner.RunOneAsync(api, group, t.Name, "www.gstatic.com", 80, 1, cts.Token);
                    t.Lat = r.MinMs;
                    NodeList.Items.Refresh();
                    done++;
                }
            }
            catch (Exception ex) { DriverManager.Log("批量测延迟异常: " + ex.Message); }
            finally
            {
                // 测完把用户原来的选择恢复回去，别让测速把他当前节点改掉
                if (!string.IsNullOrEmpty(keep))
                {
                    bool okRestore = await api.SelectNodeAsync(group, keep);
                    foreach (NodeTile t in nodeTiles) t.Selected = (t.Name == keep);
                    if (okRestore) Append("[内核] 已恢复原节点：" + keep);
                }
                NodeList.Items.Refresh();
                BtnProbeNodes.IsEnabled = true;
                TxtNodeHint.Text = "已测 " + done + " 个节点（当前：" + (keep ?? "未选") + "）";
                if (traceCts == cts) traceCts = null;
                cts.Dispose();
            }
        }

        // ---------------------------------------------------------------- winws

        private void BtnWinwsStart_Click(object sender, RoutedEventArgs e)
        {
            string msg;
            bool ok = DriverManager.Start(DriverKind.Winws, out msg);
            Append("[内核] " + msg);
            if (!ok) Ui.Warn(msg, "winws 启动失败");
            RefreshKernelUi();
        }

        private void BtnWinwsStop_Click(object sender, RoutedEventArgs e)
        {
            string msg;
            DriverManager.Stop(DriverKind.Winws, true, out msg);
            Append("[内核] winws " + msg);
            RefreshKernelUi();
        }

        private void BtnWinwsRestart_Click(object sender, RoutedEventArgs e)
        {
            string msg;
            bool ok = DriverManager.Restart(DriverKind.Winws, out msg);
            Append("[内核] winws " + msg);
            if (!ok) Ui.Warn(msg, "winws 重启失败");
            RefreshKernelUi();
        }

        private void BtnWinwsUpdate_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                string dir = System.IO.Path.Combine(DriverManager.RootDir, "winws");
                string marker = System.IO.Path.Combine(dir, ".extracted");
                if (System.IO.File.Exists(marker)) System.IO.File.Delete(marker);
                string err;
                bool ok = EmbeddedDriver.Extract(DriverKind.Winws, dir, out err);
                Ui.Info(ok ? "已重新释放 winws 内核到：\r\n" + dir : "失败：" + err, "更新内核");
                RefreshKernelUi();
            }
            catch (Exception ex) { Ui.Error(ex.Message, "更新失败"); }
        }

        // ---------------------------------------------------------------- mihomo

        private async void BtnMihomoStart_Click(object sender, RoutedEventArgs e)
        {
            string msg;
            bool ok = DriverManager.Start(DriverKind.Mihomo, out msg);
            Append("[内核] " + msg);
            if (ok)
            {
                MihomoApi api = new MihomoApi();
                if (!await api.WaitReadyAsync(8000)) Append("[内核] mihomo API 还没就绪（节点列表可能为空）");
                groupsLoadedOnce = false;
                await LoadGroupsAsync();
            }
            else
            {
                Ui.Warn(msg, "mihomo 启动失败");
            }
            RefreshKernelUi();
        }

        private void BtnMihomoStop_Click(object sender, RoutedEventArgs e)
        {
            string msg;
            DriverManager.Stop(DriverKind.Mihomo, true, out msg);
            Append("[内核] mihomo " + msg);
            groupsLoadedOnce = false;
            RefreshKernelUi();
        }

        private async void BtnMihomoRestart_Click(object sender, RoutedEventArgs e)
        {
            string msg;
            bool ok = DriverManager.Restart(DriverKind.Mihomo, out msg);
            Append("[内核] mihomo " + msg);
            if (ok)
            {
                MihomoApi api = new MihomoApi();
                await api.WaitReadyAsync(8000);
                groupsLoadedOnce = false;
                await LoadGroupsAsync();
            }
            else
            {
                Ui.Warn(msg, "mihomo 重启失败");
            }
            RefreshKernelUi();
        }

        private void BtnMihomoUpdate_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                string dir = System.IO.Path.Combine(DriverManager.RootDir, "mihomo");
                string marker = System.IO.Path.Combine(dir, ".extracted");
                if (System.IO.File.Exists(marker)) System.IO.File.Delete(marker);
                string err;
                bool ok = EmbeddedDriver.Extract(DriverKind.Mihomo, dir, out err);
                Ui.Info(ok ? "已重新释放 mihomo 内核到：\r\n" + dir : "失败：" + err, "更新内核");
                RefreshKernelUi();
            }
            catch (Exception ex) { Ui.Error(ex.Message, "更新失败"); }
        }

        // ---------------------------------------------------------------- 订阅/节点/模式

        private async void BtnSaveSub_Click(object sender, RoutedEventArgs e)
        {
            string url = (TxtSubscription.Text ?? "").Trim();
            MihomoConfig.Subscription = url;

            string dir = System.IO.Path.Combine(DriverManager.RootDir, "mihomo");
            string err;
            bool got = MihomoConfig.DownloadSubscription(dir, out err);
            if (!got)
            {
                Ui.Warn("订阅下载失败：\r\n\r\n" + err, "订阅失败");
                try { TxtSubInfo.Text = "导入失败"; } catch { }
                if (!DriverManager.IsRunning(DriverKind.Mihomo)) return;
            }
            else
            {
                Append("[内核] 订阅已下载，准备重启 mihomo 生效");
            }

            if (!DriverManager.IsRunning(DriverKind.Mihomo))
            {
                // 导入后直接把它拉起来：否则用户会看到"导入成功但列表空的"，
                // 而列表空正是因为内核没运行、API 不上线。
                Append("[内核] 订阅已就绪，正在启动 mihomo…");
                string smsg;
                if (!DriverManager.Start(DriverKind.Mihomo, out smsg))
                {
                    Ui.Warn("订阅已保存，但 mihomo 启动失败：\r\n" + smsg, "启动失败");
                    try { TxtSubInfo.Text = "已保存（内核启动失败）"; } catch { }
                    RefreshKernelUi();
                    return;
                }
                Append("[内核] " + smsg);
                MihomoApi api0 = new MihomoApi();
                if (!await api0.WaitReadyAsync(10000)) Append("[内核] API 未就绪");
                groupsLoadedOnce = false;
                await LoadGroupsAsync();
                RefreshKernelUi();
                try { TxtSubInfo.Text = "订阅已导入，已自动启动 mihomo（" + nodeTiles.Count + " 个节点）"; } catch { }
                return;
            }

            await RestartMihomoAndReloadAsync("订阅已生效");
            Ui.Info("订阅已更新，节点列表已刷新。", "订阅");
        }

        private async void CmbGroup_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (mihomoUiLoading) return;
            string g = CmbGroup.SelectedItem as string;
            if (string.IsNullOrEmpty(g)) return;
            try
            {
                MihomoApi api = new MihomoApi();
                await FillNodeTilesAsync(api, g);
                TxtSubInfo.Text = "当前组：" + g + "（" + nodeTiles.Count + " 个节点）";
            }
            catch (Exception ex) { DriverManager.Log("切换组失败: " + ex.Message); }
        }

        private async void BtnApplyMode_Click(object sender, RoutedEventArgs e)
        {
            string mode = "rule";
            ComboBoxItem item = CmbMode.SelectedItem as ComboBoxItem;
            if (item != null && item.Tag != null) mode = item.Tag.ToString();
            MihomoApi api = new MihomoApi();
            bool ok = await api.SetModeAsync(mode);
            Append("[内核] 代理模式 → " + mode + (ok ? " 已生效" : " 失败"));
            if (!ok) Ui.Warn("切换失败（看内核日志）", "代理模式");
        }

        private void ChkTun_Changed(object sender, RoutedEventArgs e)
        {
            // RefreshKernelUi() 用代码设置 IsChecked 时也会触发本事件，必须跳过，
            // 否则"刷新界面"会被当成"用户改了设置"。
            if (syncingKernelUi) return;
            bool on = ChkTun.IsChecked == true;
            if (on && DriverManager.IsRunning(DriverKind.Winws))
            {
                if (Ui.Confirm("TUN 接管全部流量，和 winws 的伪装会互相破坏（实测会导致 vrchat.com 打不开）。\r\n\r\n先帮你关掉 winws 吗？", "TUN 与 winws 冲突"))
                {
                    string m;
                    DriverManager.Stop(DriverKind.Winws, true, out m);
                    Append("[内核] " + m);
                    RefreshKernelUi();
                }
                else
                {
                    ChkTun.IsChecked = false;
                    return;
                }
            }
            MihomoConfig.TunEnabled = on;
            Append("[内核] TUN 配置 → " + (on ? "开启" : "关闭") + "（重启 mihomo 生效）");
            Ui.Info("已" + (on ? "开启" : "关闭") + " TUN 配置。\r\n需要重启 mihomo 才生效。", "TUN");
        }

        // ---------------------------------------------------------------- trace

        private async void BtnTraceStart_Click(object sender, RoutedEventArgs e)
        {
            // Ping（经节点）：对用户填的 IP/域名，经每个节点做一次 TCP+TLS 握手，量往返。
            //
            // 为什么不是 ICMP：mihomo 的 ICMP 一律 DIRECT（日志里 "using DIRECT"），
            // 内核不支持 ICMP 走代理；而 TCP/TLS 是能真正穿过节点的，数字会随节点明显变化。
            // 实测：142.250.199.206:443 直连不通，经节点 香港 139ms / 日本 241ms / 美国 521ms。
            string host = (TxtTraceTarget.Text ?? "").Trim();
            if (string.IsNullOrEmpty(host)) { Ui.Warn("请填要 ping 的 IP 或域名"); return; }
            int tries;
            if (!int.TryParse(TxtTraceTries.Text, out tries) || tries <= 0 || tries > 20) tries = 3;

            // 443 是绝大多数公网服务的端口（Google / Cloudflare / 自建站都开）。
            const int port = 443;

            // SNI：填域名就用域名；填 IP 时先用 IP，握手失败再退回 www.google.com
            // （不少 Google IP 只认正确的 SNI，用 IP 当 SNI 会被直接拒绝）。
            bool isIp = System.Net.IPAddress.TryParse(host, out _);
            string sniPrimary = host;
            string sniFallback = isIp ? "www.google.com" : null;

            string group = CmbGroup.SelectedItem as string;
            if (string.IsNullOrEmpty(group)) { Ui.Warn("先去上面点一下「代理组」加载节点（mihomo 要在运行）"); return; }

            MihomoApi api = new MihomoApi();
            List<string> nodes = await api.GetNodesAsync(group);
            nodes = nodes.Where(n => !(n.Contains("剩余流量") || n.Contains("距离下次") || n.Contains("套餐到期") || n.Contains("建议") || n.Contains("更新") || n.Contains("很少节点"))).ToList();
            if (nodes.Count == 0) { Ui.Warn("这个组里没有节点"); return; }

            string prevGroupNode = await api.GetGroupNowAsync(group);
            traceRows.Clear();
            traceCts = new CancellationTokenSource();
            BtnTraceStart.IsEnabled = false;
            BtnTraceStop.IsEnabled = true;

            int done = 0;
            try
            {
                foreach (string node in nodes)
                {
                    if (traceCts.IsCancellationRequested) break;
                    TxtTraceStatus.Text = "Ping " + (done + 1) + "/" + nodes.Count + "：" + node;

                    // 关键：SOCKS 的出路由**规则**决定 —— 目标 IP 不属于 Photon 网段时命中 MATCH → 默认组。
                    // 只切 VRChat-Photon 的话，46 次请求全走同一个出口，数字当然全一样。
                    bool sel = await api.SelectNodeAsync(group, node);
                    await api.SelectNodeAsync(MihomoConfig.GroupDefault, node);
                    if (!sel)
                    {
                        traceRows.Add(new TraceRow { Node = node, MinText = "切换失败", AvgText = "-", LossText = "-" });
                        done++;
                        continue;
                    }
                    string nowNode = await api.GetGroupNowAsync(MihomoConfig.GroupDefault);
                    if (!string.IsNullOrEmpty(nowNode) && nowNode != node)
                        DriverManager.Log("[ping] 警告：默认组实际是 " + nowNode + "，与目标 " + node + " 不一致");
                    await Task.Delay(150);

                    List<int> okMs = new List<int>();
                    int loss = 0;
                    for (int t = 0; t < tries; t++)
                    {
                        if (traceCts.IsCancellationRequested) break;
                        string useSni = sniPrimary;
                        int ms = await Task.Run(() => TraceRunner.ProbeTls(host, port, useSni, 3000));
                        if (ms < 0 && !string.IsNullOrEmpty(sniFallback))
                            ms = await Task.Run(() => TraceRunner.ProbeTls(host, port, sniFallback, 3000));
                        if (ms >= 0) okMs.Add(ms); else loss++;
                    }

                    if (okMs.Count > 0)
                    {
                        int min = int.MaxValue, sum = 0;
                        foreach (int x in okMs) { if (x < min) min = x; sum += x; }
                        traceRows.Add(new TraceRow
                        {
                            Node = node,
                            MinText = min + " ms",
                            AvgText = (sum / okMs.Count) + " ms",
                            LossText = loss + "/" + tries,
                            SortKey = min
                        });
                    }
                    else
                    {
                        traceRows.Add(new TraceRow { Node = node, MinText = "无响应", AvgText = "-", LossText = tries + "/" + tries, SortKey = int.MaxValue });
                    }
                    done++;
                    if (done % 5 == 0 || done == nodes.Count) SortTraceRows();
                }
                TxtTraceStatus.Text = traceCts.IsCancellationRequested
                    ? "已停止（" + done + "/" + nodes.Count + "）"
                    : "完成：" + done + " 个节点（目标 " + host + ":" + port + "，TLS 握手）";
            }
            catch (Exception ex)
            {
                TxtTraceStatus.Text = "出错：" + ex.Message;
                DriverManager.Log("ping 异常: " + ex.Message);
            }
            finally
            {
                try
                {
                    if (!string.IsNullOrEmpty(prevGroupNode))
                    {
                        await api.SelectNodeAsync(group, prevGroupNode);
                        await api.SelectNodeAsync(MihomoConfig.GroupDefault, prevGroupNode);
                        Append("[ping] 已恢复原节点：" + prevGroupNode);
                    }
                }
                catch { }
                BtnTraceStart.IsEnabled = true;
                BtnTraceStop.IsEnabled = false;
                if (traceCts != null) { traceCts.Dispose(); traceCts = null; }
            }
        }




        /// <summary>把 Ping 结果按最小延迟从小到大排；无响应的排最后。</summary>
        private void SortTraceRows()
        {
            try
            {
                var sorted = traceRows.OrderBy(r => r.SortKey).ThenBy(r => r.Node, StringComparer.CurrentCulture).ToList();
                bool changed = false;
                for (int i = 0; i < sorted.Count; i++)
                {
                    if (i >= traceRows.Count || !ReferenceEquals(traceRows[i], sorted[i])) { changed = true; break; }
                }
                if (!changed) return;

                traceRows.Clear();
                foreach (TraceRow r in sorted) traceRows.Add(r);
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }
        private void BtnTraceStop_Click(object sender, RoutedEventArgs e)
        {
            try { if (traceCts != null) traceCts.Cancel(); } catch { }
        }

        // ---------------------------------------------------------------- 诊断/迁移/自启

        private void BtnKernelDiag_Click(object sender, RoutedEventArgs e)
        {
            try { Ui.Info(DriverManager.Diagnose(), "内核诊断"); }
            catch (Exception ex) { Ui.Error(ex.Message, "诊断失败"); }
        }

        private void BtnKernelMigrate_Click(object sender, RoutedEventArgs e)
        {
            if (!Ui.Confirm("旧版把 winws 注册成了 Windows 服务（VRChatBypass）。\r\n" +
                            "新版由程序托管，两者同时存在会抢同一份过滤器。\r\n\r\n" +
                            "迁移会：停止该服务 + 启动类型设为「禁用」（不删除服务键）。\r\n" +
                            "之后建议重启一次电脑。\r\n\r\n继续？", "迁移旧服务")) return;

            Ui.Info(DriverManager.MigrateLegacyService(), "迁移结果");
            RefreshKernelUi();
        }

        private void BtnKernelLog_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                if (!System.IO.File.Exists(DriverManager.LogPath))
                    System.IO.File.WriteAllText(DriverManager.LogPath, "（还没有日志）\r\n");
                Process.Start(new ProcessStartInfo(DriverManager.LogPath) { UseShellExecute = true });
            }
            catch (Exception ex) { Ui.Error(ex.Message, "打开失败"); }
        }

        private void BtnKernelRefresh_Click(object sender, RoutedEventArgs e)
        {
            groupsLoadedOnce = false;
            RefreshKernelUi();
        }

        // ---------------------------------------------------------------- 订阅页专用

        /// <summary>重启 mihomo，让新下载的订阅/新配置生效。</summary>
        private async void BtnSubRestart_Click(object sender, RoutedEventArgs e)
        {
            if (!DriverManager.IsRunning(DriverKind.Mihomo))
            {
                Ui.Info("mihomo 没在运行。请先到「内核」页点「开启」。", "还没启动");
                return;
            }
            await RestartMihomoAndReloadAsync("订阅已生效");
        }

        /// <summary>打开订阅落盘目录（排查"到底下没下下来"最直接）。</summary>
        private void BtnSubOpenDir_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                string dir = System.IO.Path.Combine(DriverManager.RootDir, "mihomo", "providers");
                System.IO.Directory.CreateDirectory(dir);
                Process.Start(new ProcessStartInfo(dir) { UseShellExecute = true });
            }
            catch (Exception ex) { Ui.Error(ex.Message, "打开失败"); }
        }
        private void ChkAutoStart_Changed(object sender, RoutedEventArgs e)
        {
            if (syncingKernelUi) return;
            DriverManager.AutoStartApp = ChkAutoStart.IsChecked == true;
        }

        private void ChkAutoStartDrivers_Changed(object sender, RoutedEventArgs e)
        {
            if (syncingKernelUi) return;
            UiState.Current.AutoStartDrivers = ChkAutoStartDrivers.IsChecked == true;
            UiState.Touch();
            Append("[内核] 程序启动时自动开启内核 → " + (UiState.Current.AutoStartDrivers ? "开" : "关"));
        }
    }
}
