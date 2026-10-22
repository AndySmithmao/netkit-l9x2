using System;
using System.Drawing;
using System.Windows;
using WinForms = System.Windows.Forms;

namespace VrcTool
{
    /// <summary>
    /// 托盘图标。
    ///
    /// 这是个常驻工具，用户大概率想让它缩在托盘里而不是一直占着任务栏。
    ///
    /// 为什么用 WinForms 的 NotifyIcon：
    ///   · WPF-UI 4.3.0 **没有**托盘类型（6 个 TFM 的 Wpf.Ui.xml 里搜
    ///     TaskBarIcon / NotifyIcon / TrayIcon 全是 0 命中）
    ///   · 第三方托盘包（Hardcodet 之类）要多一个 NuGet 依赖，自包含单文件会再涨体积
    ///   · WinForms 的 NotifyIcon 是 .NET 自带的，只是需要 <UseWindowsForms>true</UseWindowsForms>
    /// 代价：会把 System.Windows.Forms 打进产物。实测体积增量见改动记录。
    ///
    /// 注意：这里所有类型都用 WinForms 别名显式限定 —— WPF 和 WinForms 都叫
    /// Application / MessageBox / Clipboard，不加限定会撞名。
    /// </summary>
    internal sealed class TrayIcon
    {
        private WinForms.NotifyIcon notify;
        private readonly MainWindow owner;

        public TrayIcon(MainWindow window)
        {
            owner = window;
        }

        public bool Installed { get { return notify != null; } }

        public void Install()
        {
            try
            {
                WinForms.NotifyIcon ni = new WinForms.NotifyIcon();
                // NotifyIcon.Text 有 63 字符上限，超了会抛
                ni.Text = "VRChat优选工具";
                ni.Icon = LoadAppIcon();
                ni.Visible = true;

                WinForms.ContextMenuStrip menu = new WinForms.ContextMenuStrip();
                menu.Items.Add("显示主界面", null, delegate { owner.ShowFromTray(); });
                menu.Items.Add(new WinForms.ToolStripSeparator());
                menu.Items.Add("一键完成", null, delegate
                {
                    owner.ShowFromTray();
                    owner.StartNavByKey("oneclick");
                });
                menu.Items.Add("清单选用", null, delegate
                {
                    owner.ShowFromTray();
                    owner.OpenPickerFromTray();
                });
                menu.Items.Add("诊断", null, delegate
                {
                    owner.ShowFromTray();
                    owner.StartNavByKey("diagnose");
                });
                menu.Items.Add(new WinForms.ToolStripSeparator());
                menu.Items.Add("退出", null, delegate { owner.ExitFromTray(); });
                ni.ContextMenuStrip = menu;

                ni.DoubleClick += delegate { owner.ShowFromTray(); };

                notify = ni;
            }
            catch (Exception ex)
            {
                // 托盘建不起来不该影响主功能 —— 记一笔就降级（窗口照常，只是不能缩到托盘）
                Ui.WriteErrorLog("托盘图标创建失败（已降级为普通窗口）", ex);
                notify = null;
            }
        }

        /// <summary>托盘气泡提示（只用来在第一次缩到托盘时说一句"我在哪儿"）</summary>
        public void Balloon(string title, string text)
        {
            try
            {
                if (notify != null)
                    notify.ShowBalloonTip(4000, title, text, WinForms.ToolTipIcon.Info);
            }
            catch (Exception ex) { Ui.WriteErrorLog("托盘气泡失败", ex); }
        }

        /// <summary>
        /// 取本程序的图标。
        /// 优先用 exe 关联图标（部署后就是它）；开发时用 `dotnet xxx.dll` 启动
        /// 时 ProcessPath 是 dotnet.exe，会拿到错误的图标，所以退回找同目录的 apphost exe。
        /// </summary>
        private static Icon LoadAppIcon()
        {
            try
            {
                string dir = AppContext.BaseDirectory;
                string asm = System.Reflection.Assembly.GetExecutingAssembly().GetName().Name;
                string apphost = System.IO.Path.Combine(dir, asm + ".exe");
                if (System.IO.File.Exists(apphost))
                {
                    Icon i = Icon.ExtractAssociatedIcon(apphost);
                    if (i != null) return i;
                }
            }
            catch { }

            try
            {
                string exe = Environment.ProcessPath;
                if (!string.IsNullOrEmpty(exe))
                {
                    Icon i = Icon.ExtractAssociatedIcon(exe);
                    if (i != null) return i;
                }
            }
            catch { }

            try { return SystemIcons.Application; } catch { }
            return null;
        }

        public void Dispose()
        {
            try
            {
                if (notify != null)
                {
                    notify.Visible = false;
                    if (notify.ContextMenuStrip != null) notify.ContextMenuStrip.Dispose();
                    notify.Dispose();
                }
            }
            catch { }
            notify = null;
        }
    }
}
