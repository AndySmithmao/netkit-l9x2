using System;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Threading;
using Wpf.Ui.Controls;
using WpfMessageBox = Wpf.Ui.Controls.MessageBox;
using WpfMessageBoxResult = Wpf.Ui.Controls.MessageBoxResult;

namespace VrcTool
{
    /// <summary>
    /// Fluent 对话框门面。
    ///
    /// 为什么不用 System.Windows.MessageBox：它是 Win32 灰白框，和 Mica + Fluent 的界面
    /// 完全两个画风（一个 Fluent 窗口里弹出 Win95 风格的框，很出戏）。
    ///
    /// 为什么需要这一层：WPF-UI 的 MessageBox 只有异步接口 ShowDialogAsync()，
    /// 而本项目好几个调用点根本没法改成 async ——
    ///   · PickerWindow 的构造函数里（构造函数不能 async）
    ///   · MainWindow.Closing 里（必须在处理函数返回前同步设好 e.Cancel，async 会让窗口先关掉）
    /// 所以这里用 DispatcherFrame 把对话框同步地跑起来：需要时 PushFrame 继续泵消息，
    /// 对话框照常响应，调用方拿到的却是已经出结果的同步返回值。
    ///
    /// 失败时**不抛异常**：对话框出问题返回 None（等价于"取消"），这是最安全的默认值，
    /// 失败详情写进 data\error.log。
    /// </summary>
    internal static class Ui
    {
        public const string AppTitle = "VRChat优选工具";

        // ================================================================== 对外
        /// <summary>只有「确定」的信息框</summary>
        public static void Info(string content, string title = null)
        {
            Dialog(title, content, null, null, "确定", ControlAppearance.Primary);
        }

        /// <summary>只有「知道了」的警告框</summary>
        public static void Warn(string content, string title = null)
        {
            Dialog(title, content, null, null, "知道了", ControlAppearance.Caution);
        }

        /// <summary>出错了。细节建议同时写进日志，别只弹框。</summary>
        public static void Error(string content, string title = null)
        {
            Dialog(title, content, null, null, "关闭", ControlAppearance.Danger);
        }

        /// <summary>是 / 否。点「是」返回 true。</summary>
        public static bool Question(string content, string title = null)
        {
            return Dialog(title, content, "是", null, "否", ControlAppearance.Primary) == WpfMessageBoxResult.Primary;
        }

        /// <summary>确定 / 取消。点「确定」返回 true。danger=true 时「确定」按钮染红。</summary>
        public static bool Confirm(string content, string title = null, bool danger = false)
        {
            ControlAppearance ap = danger ? ControlAppearance.Danger : ControlAppearance.Primary;
            // 注意第 6 个参数是「取消」按钮的样式：以前这里传的是 ap，
            // 于是破坏性操作把「取消」染成了红色、「确定」还是蓝色 —— 视觉引导正好反了。
            return Dialog(title, content, "确定", null, "取消", ControlAppearance.Secondary, ap)
                   == WpfMessageBoxResult.Primary;
        }

        /// <summary>破坏性操作（清理缓存 / 卸载）：确定按钮染红，逼用户看一眼再点</summary>
        public static bool ConfirmDanger(string content, string title = null)
        {
            return Confirm(content, title, true);
        }

        // ================================================================== 内部
        /// <summary>
        /// primary = 主动作（确定 / 是）；secondary = 第三选项（一般不用）；close = 取消 / 关闭。
        /// 只给 close 时它就是个信息框；closeAppearance 决定它是 Primary 还是 Danger 还是 Secondary。
        /// primaryAppearance 只影响主动作按钮（破坏性操作要把它染红）。
        /// </summary>
        private static WpfMessageBoxResult Dialog(string title, string content,
                                                  string primary, string secondary, string close,
                                                  ControlAppearance closeAppearance,
                                                  ControlAppearance primaryAppearance = ControlAppearance.Primary)
        {
            if (string.IsNullOrEmpty(title)) title = AppTitle;

            WpfMessageBoxResult result = WpfMessageBoxResult.None;
            Exception error = null;

            try
            {
                WpfMessageBox box = new WpfMessageBox();
                box.Title = title;
                box.Content = content ?? "";
                box.ShowTitle = true;

                try
                {
                    Window owner = OwnerWindow();
                    if (owner != null) box.Owner = owner;
                }
                catch { }

                if (!string.IsNullOrEmpty(primary))
                {
                    box.PrimaryButtonText = primary;
                    box.PrimaryButtonAppearance = primaryAppearance;
                    box.IsPrimaryButtonEnabled = true;
                }
                else
                {
                    box.IsPrimaryButtonEnabled = false;
                }

                box.IsSecondaryButtonEnabled = !string.IsNullOrEmpty(secondary);
                if (!string.IsNullOrEmpty(secondary)) box.SecondaryButtonText = secondary;

                if (string.IsNullOrEmpty(close))
                {
                    box.IsCloseButtonEnabled = false;
                }
                else
                {
                    box.CloseButtonText = close;
                    box.CloseButtonAppearance = closeAppearance;
                    box.IsCloseButtonEnabled = true;
                }

                DispatcherFrame frame = new DispatcherFrame();
                bool needPump = false;

                // async void：异常都在内部吃掉，不会漏到 SynchronizationContext 上炸掉进程
                async void Drive()
                {
                    try { result = await box.ShowDialogAsync(); }
                    catch (Exception ex) { error = ex; }
                    finally { frame.Continue = false; }
                }

                Drive();                 // 同步跑到第一个 await
                needPump = frame.Continue;
                if (needPump) Dispatcher.PushFrame(frame);
            }
            catch (Exception ex)
            {
                error = ex;
            }

            if (error != null)
            {
                WriteErrorLog("对话框显示失败（" + title + "）", error);
                // 别把用户晾在"点了没反应"的状态：Fluent 对话框起不来就退回系统对话框。
                // 典型场景：MainWindow.Closing 里问「任务还在运行，确定退出吗」，
                // 这里返回 None = 取消，但用户看不到任何东西，只会以为程序卡死了。
                try
                {
                    System.Windows.MessageBox.Show(content ?? "", title,
                        System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Warning);
                }
                catch { }
                return WpfMessageBoxResult.None;
            }
            return result;
        }

        /// <summary>挑一个合适的 owner：优先主窗口，其次当前激活窗口</summary>
        private static Window OwnerWindow()
        {
            Application app = Application.Current;
            if (app == null) return null;

            Window main = app.MainWindow;
            if (main != null && main.IsVisible && main.IsLoaded) return main;

            foreach (Window w in app.Windows)
            {
                if (w.IsActive) return w;
            }
            return null;
        }

        // ================================================================== 日志
        /// <summary>把异常堆栈写到 data\error.log，返回文件路径。写不进去就返回说明文字。</summary>
        public static string WriteErrorLog(Exception ex)
        {
            return WriteErrorLog(null, ex);
        }

        /// <summary>把一段文本（可带异常）追加到 data\error.log，返回文件路径。</summary>
        public static string WriteErrorLog(string context, Exception ex)
        {
            try
            {
                string dir = ScriptHost.DataDir;
                Directory.CreateDirectory(dir);
                string path = Path.Combine(dir, "error.log");

                // 上限 1 MB：超了就把旧文件滚成 error.log.1（只留一份）。
                // 以前是无上限追加，用户反复崩溃/切主题能把日志堆到几十 MB，
                // 而且每次 AppendAllText 都越来越慢。
                try
                {
                    FileInfo old = new FileInfo(path);
                    if (old.Exists && old.Length > 1024 * 1024)
                    {
                        string bak = path + ".1";
                        try { if (File.Exists(bak)) File.Delete(bak); } catch { }
                        File.Move(path, bak);
                    }
                }
                catch { }

                StringBuilder sb = new StringBuilder();
                sb.Append("===== ").Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")).Append(" =====").AppendLine();
                if (!string.IsNullOrEmpty(context)) sb.Append(context).AppendLine();
                if (ex != null) sb.Append(ex.ToString()).AppendLine();
                sb.AppendLine();

                File.AppendAllText(path, sb.ToString(), new UTF8Encoding(true));
                return path;
            }
            catch
            {
                return "(日志写入失败)";
            }
        }
    }
}
