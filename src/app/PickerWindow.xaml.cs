using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.VisualBasic.FileIO;
using Wpf.Ui.Controls;
using DataGrid = System.Windows.Controls.DataGrid;
using TextBlock = System.Windows.Controls.TextBlock;
// 对话框统一走 Ui（WPF-UI 的 Fluent MessageBox）

namespace VrcTool
{
    public partial class PickerWindow : FluentWindow
    {
        private string dataDir;
        private string curA = "", curB = "";
        private List<RawRow> rowsA = new List<RawRow>();
        private List<RawRow> rowsB = new List<RawRow>();
        private bool hasSpeed = false;

        /// <summary>用户选定、交给主窗口去写 hosts 的 A 组 IP（空 = 不改）</summary>
        public string ChosenA { get; private set; }
        /// <summary>同上，B 组</summary>
        public string ChosenB { get; private set; }

        /// <param name="dir">数据目录（= ScriptHost.DataDir）</param>
        /// <param name="currentA">hosts 里 A 组当前生效的 IP，用来标「使用中」</param>
        /// <param name="currentB">同上，B 组</param>
        public PickerWindow(string dir, string currentA, string currentB)
        {
            dataDir = dir;
            curA = currentA ?? "";
            curB = currentB ?? "";
            InitializeComponent();
            LoadData();
        }

        // ====================================================================
        private void LoadData()
        {
            try
            {
                rowsA.Clear();
                rowsB.Clear();

                string fLat = Path.Combine(dataDir, "latency-result.csv");
                string fSpd = Path.Combine(dataDir, "speed-result.csv");
                if (!File.Exists(fLat))
                {
                    // 不再把窗口留在"两个空表格"的状态：给一句明确的下一步，并禁掉写入按钮
                    Ui.Info("还没有实测数据。\r\n\r\n请先在主界面点「延迟实测」。", "提示");
                    ShowEmptyHint("还没有实测数据。请先在主界面点「延迟实测」，再回来打开这个清单。");
                    UpdateSel();
                    return;
                }

                List<Dictionary<string, string>> lat = Csv.Read(fLat);
                List<Dictionary<string, string>> spd = new List<Dictionary<string, string>>();
                if (File.Exists(fSpd)) spd = Csv.Read(fSpd);
                hasSpeed = false;

                List<RawRow> all = new List<RawRow>();
                foreach (Dictionary<string, string> r in lat)
                {
                    RawRow x = new RawRow();
                    x.Group = Csv.Get(r, "组");
                    x.Ip = Csv.Get(r, "IP");
                    if (x.Ip == "") continue;
                    x.Med = Csv.Int(r, "中位");
                    x.Min = Csv.Int(r, "最小");
                    x.Max = Csv.Int(r, "最大");
                    x.Jit = Csv.Int(r, "抖动");
                    x.OK = Csv.Int(r, "成功");
                    x.Tot = Csv.Int(r, "总轮次");
                    x.Rate = Csv.Int(r, "成功率");
                    x.Score = Csv.Int(r, "得分");
                    x.Speed = 0;
                    foreach (Dictionary<string, string> s in spd)
                        if (Csv.Get(s, "IP") == x.Ip) { x.Speed = Csv.Int(s, "速度"); break; }
                    x.Eff = (int)(x.Speed * x.Rate / 100.0);
                    if (x.Speed > 0) hasSpeed = true;
                    all.Add(x);
                }

                foreach (RawRow x in all)
                { if (x.Group == "A") rowsA.Add(x); else rowsB.Add(x); }

                rowsA.Sort(delegate(RawRow p, RawRow q)
                {
                    if ((p.OK == 0) != (q.OK == 0)) return p.OK == 0 ? 1 : -1;
                    return p.Score.CompareTo(q.Score);
                });
                rowsB.Sort(delegate(RawRow p, RawRow q)
                {
                    if ((p.OK == 0) != (q.OK == 0)) return p.OK == 0 ? 1 : -1;
                    int c = q.Eff.CompareTo(p.Eff);
                    return c != 0 ? c : p.Score.CompareTo(q.Score);
                });

                if (rowsA.Count == 0 && rowsB.Count == 0)
                {
                    ShowEmptyHint("latency-result.csv 里没有可用行。\r\n请重跑一次「延迟实测」。");
                }
                else
                {
                    TxtEmpty.Visibility = Visibility.Collapsed;
                }

                SetHeaders();
                GridA.ItemsSource = Build(rowsA, false, curA);
                GridB.ItemsSource = Build(rowsB, true, curB);

                if (GridA.Items.Count > 0) GridA.SelectedIndex = 0;
                if (GridB.Items.Count > 0) GridB.SelectedIndex = 0;
                UpdateSel();
            }
            catch (Exception ex)
            {
                Ui.Error("读取数据失败：" + ex.Message, "错误");
                ShowEmptyHint("读取实测数据失败：\r\n" + ex.Message);
            }
        }

        private void SetHeaders()
        {
            // A 组的列头固定写在 XAML 里，这里只管 B 组。
            // 原来是按 Columns[2..5] 下标硬改 —— 谁往 XAML 里插一列就静默错位，现在用命名列。
            if (hasSpeed)
            {
                BV1.Header = "下载速度";
                BV2.Header = "有效速度";
                BV3.Header = "中位延迟";
                BV4.Header = "抖动";
            }
            else
            {
                BV1.Header = "中位延迟";
                BV2.Header = "最小";
                BV3.Header = "最大";
                BV4.Header = "抖动";
            }
        }

        /// <summary>在两个表格中间显示一句说明（没数据 / 没匹配时用）</summary>
        private void ShowEmptyHint(string text)
        {
            try
            {
                TxtEmpty.Text = text;
                TxtEmpty.Visibility = Visibility.Visible;
            }
            catch { }
        }

        private List<PickRow> Build(List<RawRow> rows, bool bySpeed, string inUse)
        {
            List<PickRow> list = new List<PickRow>();
            int i = 0;
            foreach (RawRow x in rows)
            {
                i++;
                // 标出 hosts 里当前正在用的那一个 —— 换过 IP 之后能一眼看出哪个在生效
                bool used = (inUse.Length > 0 && x.Ip == inUse);
                string note = x.OK == 0 ? "不可用"
                            : (i == 1 ? "★ 最优" : (i <= 3 ? "推荐"
                            : (x.Rate < 100 ? "成功率 " + x.Rate + "%" : "")));
                if (used) note = (note.Length > 0 ? note + " · " : "") + "当前生效";
                PickRow p = new PickRow
                {
                    N = i, Ip = x.Ip,
                    Ok = x.OK + "/" + x.Tot,
                    Rate = x.Rate + "%",
                    Note = note,
                    InUse = used
                };
                if (bySpeed && hasSpeed)
                {
                    p.V1 = x.Speed + " KB/s";
                    p.V2 = x.Eff + " KB/s";
                    p.V3 = x.Med + " ms";
                    p.V4 = x.Jit + " ms";
                }
                else
                {
                    p.V1 = x.Med + " ms";
                    p.V2 = x.Min + " ms";
                    p.V3 = x.Max + " ms";
                    p.V4 = x.Jit + " ms";
                }
                list.Add(p);
            }
            return list;
        }

        // ====================================================================
        private PickRow SelA { get { return GridA.SelectedItem as PickRow; } }
        private PickRow SelB { get { return GridB.SelectedItem as PickRow; } }

        private void Grid_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            UpdateSel();
        }

        private void UpdateSel()
        {
            PickRow a = SelA, b = SelB;
            string sa = a == null ? "—" : a.Ip + "（" + a.V1 + "）";
            string sb = b == null ? "—" : b.Ip + "（" + b.V1 + "）";
            try
            {
                TxtSel.Text = "已选　A 组：" + sa + "　　B 组：" + sb;
            }
            catch { }
            try { BtnApply.IsEnabled = (a != null || b != null); } catch { }
        }

        private void GridA_MouseDoubleClick(object sender, MouseButtonEventArgs e)
        {
            if (SelA != null) Apply();
        }

        private void GridB_MouseDoubleClick(object sender, MouseButtonEventArgs e)
        {
            if (SelB != null) Apply();
        }

        private void Win_KeyDown(object sender, KeyEventArgs e)
        {
            // 只处理 Esc。Enter 交给 BtnApply 的 IsDefault 处理 ——
            // 两边都挂的话按一次回车会跑两次 Apply()，弹两个确认框。
            if (e.Key == Key.Escape) { Close(); }
        }

        private void BtnReload_Click(object sender, RoutedEventArgs e) { LoadData(); }

        private void BtnApply_Click(object sender, RoutedEventArgs e) { Apply(); }

        // ====================================================================
        /// <summary>
        /// 确认后把选择交给主窗口，由主窗口用它自己那套 RunScript 去跑
        /// apply-selected.ps1（日志进主界面、带进度条）。
        ///
        /// 原来是在这里自己起进程 + p.WaitForExit()：
        ///   · WaitForExit 在 UI 线程上等十几秒的回归验证 → 窗口「未响应」
        ///   · CreateNoWindow=false → 冒出一个黑控制台
        /// 现在这里只负责"选"，执行交给主窗口，两个问题一起没了。
        /// </summary>
        private void Apply()
        {
            PickRow a = SelA, b = SelB;
            string ipA = a == null ? "" : a.Ip;
            string ipB = b == null ? "" : b.Ip;

            if (ipA == "" && ipB == "")
            {
                Ui.Info("请先在表格里点选一行。", "提示");
                return;
            }

            if (!Ui.Confirm(
                "将写入 hosts：\r\n\r\n" +
                "  A 组（Cloudflare 8 个域名） = " + (ipA == "" ? "（不改）" : ipA) + "\r\n" +
                "  B 组（CloudFront 4 个域名） = " + (ipB == "" ? "（不改）" : ipB) +
                "\r\n\r\n" +
                "关闭本窗口后会在主界面执行写入，并自动回归验证；\r\n" +
                "任何一个域名失败都会自动回滚。\r\n\r\n确认？",
                "确认写入")) return;

            ChosenA = ipA;
            ChosenB = ipB;
            DialogResult = true;      // 关窗并让主窗口接手
        }
    }

    // ========================================================================
    /// <summary>
    /// 读取脚本用 Export-Csv 产出的结果文件。
    ///
    /// 原来是自己手写一个按逗号切的解析器：不支持 `""` 转义引号（引号会被直接丢掉），
    /// 一旦某个字段里出现引号或换行就会串列。改用 BCL 自带的 TextFieldParser
    /// （Microsoft.VisualBasic.FileIO，.NET 共享框架里就有，不引第三方包）。
    /// </summary>
    public static class Csv
    {
        public static List<Dictionary<string, string>> Read(string path)
        {
            List<Dictionary<string, string>> list = new List<Dictionary<string, string>>();

            using (TextFieldParser p = new TextFieldParser(path, Encoding.UTF8))
            {
                p.TextFieldType = FieldType.Delimited;
                p.SetDelimiters(",");
                p.HasFieldsEnclosedInQuotes = true;
                p.TrimWhiteSpace = false;

                string[] head = p.ReadFields();
                if (head == null || head.Length == 0) return list;

                // PowerShell 5.1 的 Export-Csv -Encoding UTF8 会写 UTF-8 BOM。
                // 万一解析器没把 BOM 吃掉，第一个列名会带上 \uFEFF，导致
                // 按列名取值全部落空（所有行会被误判成 B 组）。这里显式清一下。
                head[0] = (head[0] ?? "").TrimStart('\uFEFF');

                while (!p.EndOfData)
                {
                    string[] val;
                    try { val = p.ReadFields(); }
                    catch (MalformedLineException) { continue; }   // 坏行跳过，别让整个文件读不了
                    if (val == null) continue;

                    Dictionary<string, string> d = new Dictionary<string, string>();
                    for (int j = 0; j < head.Length; j++)
                        d[head[j].Trim()] = (j < val.Length ? val[j] : "");
                    list.Add(d);
                }
            }
            return list;
        }

        public static string Get(Dictionary<string, string> d, string k)
        { string v; return d.TryGetValue(k, out v) ? v : ""; }

        public static int Int(Dictionary<string, string> d, string k)
        { int r; int.TryParse(Get(d, k), out r); return r; }
    }
}
