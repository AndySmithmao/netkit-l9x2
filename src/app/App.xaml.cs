using System;
using System.Windows;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;

namespace VrcTool
{
    public partial class App : Application
    {
        private static System.Threading.Mutex singleInstance;

        protected override void OnStartup(StartupEventArgs e)
        {
            base.OnStartup(e);

            // 单实例：脚本层没有跨进程锁，两个实例会同时改 hosts、抢服务、互相覆盖 data\ui.json。
            // 拿不到互斥体就提示并退出（而不是默默再开一个）。
            bool created = false;
            try
            {
                singleInstance = new System.Threading.Mutex(true, @"Global\VrcTool_SingleInstance", out created);
            }
            catch
            {
                created = true;      // 互斥体本身出问题就放行，别把程序拦在门外
            }

            if (!created)
            {
                System.Windows.MessageBox.Show(
                    "VRChat优选工具已经在运行了。\r\n\r\n" +
                    "请从任务栏右下角（可能收在 ^ 里）的托盘图标打开已有窗口。\r\n" +
                    "同时开两个实例会同时改写 hosts 和系统服务，容易出错。",
                    "已在运行",
                    System.Windows.MessageBoxButton.OK,
                    System.Windows.MessageBoxImage.Information);
                Shutdown();
                return;
            }

            // 跟随系统亮/暗。
            // 注意：App.xaml 里不再写死 Theme="Dark" —— 硬编码会让亮色系统上先闪一帧黑。
            ApplicationTheme start = ApplicationTheme.Dark;
            try
            {
                SystemTheme sys = ApplicationThemeManager.GetSystemTheme();
                start = (sys == SystemTheme.Light) ? ApplicationTheme.Light : ApplicationTheme.Dark;
            }
            catch { }

            ApplyTheme(start);

            // 全局异常兜底：给用户一句看得懂的话 + 把堆栈写进 data\error.log。
            // 以前是把 Exception.StackTrace 原样甩到对话框上 —— 用户看不懂，也没法反馈。
            DispatcherUnhandledException += OnUnhandledException;
        }

        protected override void OnExit(ExitEventArgs e)
        {
            try
            {
                if (singleInstance != null)
                {
                    singleInstance.ReleaseMutex();
                    singleInstance.Dispose();
                    singleInstance = null;
                }
            }
            catch { }
            base.OnExit(e);
        }

        private void OnUnhandledException(object sender,
                                          System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
        {
            Exception ex = e.Exception;
            string log = Ui.WriteErrorLog("未处理异常", ex);

            string msg = "程序遇到一个未处理的错误。\r\n\r\n" +
                         (ex == null ? "(没有异常信息)" : ex.Message) +
                         "\r\n\r\n完整信息已写入：\r\n" + log;
            Ui.Error(msg, "出错了");

            e.Handled = true;
        }

        /// <summary>
        /// 应用主题 + Mica 背景；Mica 失败就退回到「只换主题不换背景」。
        /// 返回 false 表示连主题都没换成功（详情已写进 data\error.log）。
        /// </summary>
        internal static bool ApplyTheme(ApplicationTheme theme)
        {
            try
            {
                ApplicationThemeManager.Apply(theme, WindowBackdropType.Mica, true);
                return true;
            }
            catch (Exception ex)
            {
                try { ApplicationThemeManager.Apply(theme); }
                catch (Exception ex2)
                {
                    Ui.WriteErrorLog("主题切换失败（连无背景模式也失败）", ex2);
                    return false;
                }
                Ui.WriteErrorLog("Mica 背景应用失败，已退回纯色背景", ex);
                return true;
            }
        }
    }
}
