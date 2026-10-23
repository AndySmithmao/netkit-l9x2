using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;
// WPF-UI 里也有 DataGrid / TextBlock 等，显式指向标准库的
using DataGrid = System.Windows.Controls.DataGrid;
using TextBlock = System.Windows.Controls.TextBlock;
using Panel = System.Windows.Controls.Panel;
// 对话框统一走 Ui（WPF-UI 的 Fluent MessageBox），不再用 System.Windows.MessageBox

namespace VrcTool
{
    public partial class MainWindow : FluentWindow
    {
        private string scriptDir;

        // 数据目录必须和脚本用的一致：脚本读 $env:VRCTOOL_DATA，值就是 <EXE目录>\data。
        // 历史上这里写死过 C:\vrchat-bypass（从旧单文件版继承下来的），后果是
        // 「清单选用」和「清理缓存」永远在看另一个目录 —— 换一台没有该目录的机器，
        // 清单选用直接读不到数据，缓存界面永远显示「空」。
        private string dataDir { get { return ScriptHost.DataDir; } }

        private List<NavDef> navDefs = new List<NavDef>();
        private Dictionary<string, int> navIndex = new Dictionary<string, int>();
        private int navSel = 0;

        private ObservableCollection<IpRow> ipRows = new ObservableCollection<IpRow>();
        private ICollectionView ipView;
        private Dictionary<string, IpRow> ipMap = new Dictionary<string, IpRow>();
        private List<string[]> ipQueue = new List<string[]>();
        private bool ipClearPending = false;
        private int ipTotal = 0;
        private DispatcherTimer ipTimer;
        private DispatcherTimer statusTimer;

        private ObservableCollection<CacheItem> cacheItems = new ObservableCollection<CacheItem>();

        // 一次任务的全部状态放在一个对象里。
        // 以前是 running / wrapperPath / lastScript 三个散字段：点「停止」后立刻开新任务，
        // 旧进程的 Exited 回调会把这个新任务的状态清掉、还会删掉新 wrapper —— 于是
        // 可能同时跑两个提权脚本、同时写 hosts。现在回调里先比对 ctx 归属。
        private sealed class RunCtx
        {
            public Process P;
            public string Wrapper;
            public string Script;
            public int Id;
        }
        private RunCtx ctx;
        private int ctxSeq = 0;

        private TrayIcon tray;
        private bool autoScroll = true;
        // 日志是否「贴着底部」。
        // 只有贴底时才自动跟着滚；用户往上翻之后就不动，让他安心看历史。
        // 之前是每来一行就无条件 ScrollToEnd，用户刚往上滚就被拽回底部，
        // 表现就是「日志根本没法手动滑」。
        private bool logPinned = true;
        private double logLastOffset = -1;
        // 进度写进日志的节流时间戳
        private DateTime lastProgLog = DateTime.MinValue;

        // 界面缩放：整棵可视树做 LayoutTransform（字体和布局一起缩）。
        // 默认 0.9 —— 实测在 1920×1080 @125% 上（工作区只有 1536×816 DIP），
        // 1180×780 的窗口会占掉 96% 的高度，字也偏大。
        private double uiScale = 0.9;
        private bool scaleChoiceSyncing = false;
        private const double BaseMinW = 900;
        private const double BaseMinH = 620;
        private bool isDark = true;
        private bool uiReady = false;
        private bool statusBusy = false;


        public MainWindow()
        {
            scriptDir = ScriptHost.RootDir;

            BuildNavDefs();
            BuildCacheItems();

            InitializeComponent();

            // CardExpander 的 Expanded / Collapsed 事件在 WPF-UI 里不触发，
            // 而 RowDefinition 不在可视化树上，ElementName 绑定会静默失败。
            // 所以用 DependencyPropertyDescriptor 监听 IsExpanded 属性变化，
            // 在代码里直接调整行高。
            try
            {
                DependencyPropertyDescriptor dpd = DependencyPropertyDescriptor.FromProperty(
                    CardExpander.IsExpandedProperty, typeof(CardExpander));
                if (dpd != null)
                {
                    dpd.AddValueChanged(ExpLog, delegate { LayoutDrawers(); });
                    dpd.AddValueChanged(ExpIp, delegate { LayoutDrawers(); });
                }

                // 拖 GridSplitter / 缩放窗口都会改变日志这一行的高度，
                // MaxHeight 必须跟着重算 —— 否则要么留一条空白，要么又滚不动。
                ExpLog.SizeChanged += delegate { ClampLogHeight(); };

                // 侧栏收起 / 展开时把标题和底部状态条藏好（48px 窄条放不下文字）
                RootNav.PaneOpened += delegate { ApplyPaneAdaptive(false); };
                RootNav.PaneClosed += delegate { ApplyPaneAdaptive(true); };
                ApplyPaneAdaptive(!RootNav.IsPaneOpen);
            }
            catch (Exception __ex) { Swallowed(__ex); }

            TxtScriptDir.Text = ScriptHost.RootDir;

            // IP 结果表走 ICollectionView —— 过滤框只要 Refresh 一下就行
            ipView = CollectionViewSource.GetDefaultView(ipRows);
            ipView.Filter = IpFilter;
            GridIp.ItemsSource = ipView;

            CacheList.ItemsSource = cacheItems;

            // 日志文档（RichTextBox）先建好空的，Append 才有地方写
            CreateLogDocument();

            // RichTextBox 内部的 ScrollViewer 会把 ScrollChanged 冒泡上来，挂一个就够。
            TxtLog.AddHandler(ScrollViewer.ScrollChangedEvent,
                new ScrollChangedEventHandler(Log_ScrollChanged));

            // 恢复上次退出时的界面状态（窗口位置 / 大小 / 说明卡 / 抽屉 / 主题）
            RestoreUiState();

            // 快捷键：F5 执行 / Esc 停止 / Ctrl+L 清空日志
            // F5 必须判两件事：按钮可用（任务跑着时 F5 不应再起一个）、焦点不在输入框
            // （否则在过滤框里敲字误按 F5，就会直接开跑 24 分钟的全量扫描）。
            PreviewKeyDown += delegate(object s, KeyEventArgs e)
            {
                if (e.Key == Key.F5)
                {
                    if (IsTypingTarget(Keyboard.FocusedElement))
                    {
                        return;      // 让输入框自己处理
                    }
                    if (BtnRun.IsEnabled)
                    {
                        BtnRun_Click(BtnRun, null);
                        e.Handled = true;
                    }
                }
                else if (e.Key == Key.Escape)
                {
                    if (BtnStop.IsEnabled) BtnStop_Click(BtnStop, null);
                    e.Handled = true;
                }
                else if (e.Key == Key.L && (Keyboard.Modifiers & ModifierKeys.Control) == ModifierKeys.Control)
                {
                    BtnClear_Click(BtnClear, null);
                    e.Handled = true;
                }
            };

            ipTimer = new DispatcherTimer();
            ipTimer.Interval = TimeSpan.FromMilliseconds(140);
            ipTimer.Tick += delegate { FlushIpQueue(); };
            ipTimer.Start();

            statusTimer = new DispatcherTimer();
            statusTimer.Interval = TimeSpan.FromSeconds(5);
            statusTimer.Tick += delegate { RefreshStatus(); };
            statusTimer.Start();

            Loaded += delegate
            {
                // 小屏（1366×768 这类）上 MinHeight 会顶到任务栏，夹一下
                try
                {
                    double wa = SystemParameters.WorkArea.Height;
                    double ww = SystemParameters.WorkArea.Width;
                    if (MinHeight > wa - 60) MinHeight = wa - 60;
                    if (MinWidth > ww - 60) MinWidth = ww - 60;
                }
                catch (Exception __ex) { Swallowed(__ex); }

                // 让第一项亮起来（NavigationView 靠 IsActive 画选中指示）
                try { HighlightNav(0); } catch (Exception __ex) { Swallowed(__ex); }

                ScriptHost.Prepare();
                RefreshStatus();
                SyncThemeIcon();
                UpdateIpEmptyState();

                // 跟随系统亮/暗。已经手动选过主题的（UiState.ManualTheme）不跟着走，
                // 免得系统一变化就把用户的选择覆盖掉。
                if (!UiState.Current.ManualTheme)
                {
                    try { SystemThemeWatcher.Watch(this, WindowBackdropType.Mica, true); } catch (Exception __ex) { Swallowed(__ex); }
                }

                Append("VRChat优选工具已启动  ·  界面：WPF-UI (Fluent)");
                Append("程序目录: " + ScriptHost.RootDir);
                Append("组件目录: " + ScriptHost.ToolsDir);
                Append("数据目录: " + ScriptHost.DataDir);
                Append("脚本已解压到临时目录 " + ScriptHost.ScriptNames.Count + " 个，退出时自动清理");
                if (!string.IsNullOrEmpty(ScriptHost.LastError)) Append("[x] " + ScriptHost.LastError);
                Append("");

                // 先放开启动保护，再刷新界面（否则 ApplyNav 会直接 return）
                uiReady = true;
                ApplyNav();
            try { InitLanguageUi(); } catch { }
            try { InitUpdateUi(); } catch { }
            // 启动后 5 秒再查更新（不拖慢启动；查到会弹窗问用户，绝不静默安装）
            _ = RunStartupUpdateCheckAsync();
                LayoutDrawers();
                // 语言要在布局完成、文字实体化之后应用
                ApplyLanguage();

                // 程序目录被搬过的话，服务里的绝对路径就失效了，自检并修回来
                CheckServicePath();

                // 托盘图标（常驻工具，用户大概率想让它缩起来）
                InstallTray();

                // 内核自启：只有用户在「内核与代理」里明确勾了才拉起来。
                // 需求明确：没开自启时，启动应用不应自动开启驱动/服务 ——
                // 否则用户只是打开工具看一眼，网络就被改了。
                if (UiState.Current.AutoStartDrivers)
                {
                    try
                    {
                        int last = UiState.Current.LastDrivers;
                        bool tun = MihomoConfig.TunEnabled;
                        if ((last & 2) != 0)
                        {
                            string m;
                            if (DriverManager.Start(DriverKind.Mihomo, out m)) Append("[内核] mihomo 已随程序启动");
                            else Append("[内核] mihomo 自启失败：" + m);
                        }
                        if ((last & 1) != 0)
                        {
                            if (tun)
                            {
                                Append("[内核] 检测到 mihomo 的 TUN 开启，跳过 winws 自启（两者冲突）");
                            }
                            else
                            {
                                string m;
                                if (DriverManager.Start(DriverKind.Winws, out m)) Append("[内核] winws 已随程序启动");
                                else Append("[内核] winws 自启失败：" + m);
                            }
                        }
                    }
                    catch (Exception __ex) { Swallowed(__ex); }
                }
                else
                {
                    // 旧版把 winws 注册成了 Windows 服务。不迁移的话，它会和新模型
                // 抢同一份 winws 过滤器（报 "A copy of winws is already running with
                // the same filter"），用户会以为新功能坏了。
                try
                {
                    string legacy = DriverManager.LegacyServiceStatus();
                    if (legacy == "RUNNING" || legacy == "STOPPED")
                    {
                        Append("[内核] 检测到旧服务 VRChatBypass（" + legacy + "）。");
                        Append("       新版内核由程序自己托管；请到「设置 → 内核与代理…」点【迁移旧服务】，");
                        Append("       并重启一次电脑让旧驱动对象清空，之后就不会再冲突。");
                    }
                }
                catch (Exception __ex) { Swallowed(__ex); }
                // 不自启时也要清一次历史残留（上次异常退出可能留下进程）
                    try
                    {
                        int killed = DriverManager.SweepOrphans(DriverKind.Winws) + DriverManager.SweepOrphans(DriverKind.Mihomo);
                        if (killed > 0) Append("[内核] 清理了 " + killed + " 个上次残留的进程");
                    }
                    catch (Exception __ex) { Swallowed(__ex); }
                }
            };

            // 最小化 → 缩到托盘（设置页可以关）
            StateChanged += delegate
            {
                try
                {
                    if (WindowState == WindowState.Minimized && UiState.Current.MinimizeToTray && tray != null)
                        HideToTray();
                }
                catch (Exception __ex) { Swallowed(__ex); }
            };

            Closing += delegate(object s, CancelEventArgs e)
            {
                if (ctx != null && ctx.P != null && !ctx.P.HasExited)
                {
                    if (!Ui.Question("任务还在运行，确定要退出吗？", "还没跑完"))
                    {
                        e.Cancel = true;
                        return;
                    }
                    KillTree(ctx);
                }
                try { ipTimer.Stop(); statusTimer.Stop(); } catch (Exception __ex) { Swallowed(__ex); }

                // 退出时必须把内核一起带走，否则会留下 winws/mihomo 孤儿进程
                // （需求验收项：退出应用后无残留驱动/服务进程）。
                // 顺便记住"这次开着哪些"，下次勾了自启就按这个恢复。
                try
                {
                    int last = 0;
                    if (DriverManager.IsRunning(DriverKind.Winws)) last |= 1;
                    if (DriverManager.IsRunning(DriverKind.Mihomo)) last |= 2;
                    UiState.Current.LastDrivers = last;
                    DriverManager.StopAll();
                }
                catch (Exception __ex) { Swallowed(__ex); }

                SaveUiState();
                CloseSessionLog();
                if (tray != null) { tray.Dispose(); tray = null; }
                ScriptHost.Cleanup();
            };
        }

        // ====================================================================
        //  界面状态持久化（data\ui.json）
        // ====================================================================
        /// <summary>
        /// 恢复上次退出时的界面状态。在构造函数里调（窗口还没 Show），
        /// 位置一次性落到位，不会先闪到屏幕中央再跳过去。
        /// </summary>
        private void RestoreUiState()
        {
            try
            {
                UiStateData s = UiState.Current;

                // 界面缩放要最先应用：它会改 MinWidth / MinHeight，
                // 而下面恢复窗口大小的代码要拿 Min 做夹取，顺序反了就会夹错。
                ApplyUiScale(s.UiScale, false);
                SyncScaleRadios();

                // 主题：手动选过就用存下来的，没选过就交给系统
                if (s.ManualTheme)
                {
                    isDark = s.Dark;
                    App.ApplyTheme(isDark ? ApplicationTheme.Dark : ApplicationTheme.Light);
                }

                // 窗口大小 / 位置
                try
                {
                    double wa = SystemParameters.WorkArea.Height;
                    double ww = SystemParameters.WorkArea.Width;
                    double wl = SystemParameters.WorkArea.Left;
                    double wt = SystemParameters.WorkArea.Top;

                    if (s.Width >= MinWidth && s.Height >= MinHeight)
                    {
                        Width = Math.Min(s.Width, ww - 24);
                        Height = Math.Min(s.Height, wa - 24);
                    }
                    else
                    {
                        // 没有可用的历史尺寸（首次运行）：XAML 里的 1180×780 是「设计尺寸」，
                        // 现在内容被缩放成了 uiScale 倍，窗口也必须等比缩，
                        // 否则内容只占窗口的 90%，右边和下边各留一条空白。
                        Width = Math.Min(1180 * uiScale, ww - 24);
                        Height = Math.Min(780 * uiScale, wa - 24);
                    }
                    // 不管走哪条路，最终都要夹进工作区（更小屏 / 更高缩放的机器）
                    if (Width > ww - 24) Width = ww - 24;
                    if (Height > wa - 24) Height = wa - 24;
                    if (s.Left.HasValue && s.Top.HasValue)
                    {
                        double x = s.Left.Value, y = s.Top.Value;
                        // 外接显示器拔掉 / 分辨率变小 / 上次是在更宽的屏上摆的 ——
                        // 存下来的坐标可能让窗口有一部分落到屏幕外。
                        // ★ 必须同时夹左右和上下边界：只夹左上角的话，
                        //   「Left 合法但 Left+Width 超出屏幕」就漏过去了。
                        if (x < wl) x = wl;
                        if (x + Width > wl + ww) x = Math.Max(wl, wl + ww - Width);
                        if (y < wt) y = wt;
                        if (y + Height > wt + wa) y = Math.Max(wt, wt + wa - Height);

                        WindowStartupLocation = WindowStartupLocation.Manual;
                        Left = x;
                        Top = y;
                    }
                    if (s.Maximized) WindowState = WindowState.Maximized;
                }
                catch (Exception __ex) { Swallowed(__ex); }

                // 抽屉 / 说明卡 / 自动滚动
                ExpLog.IsExpanded = s.LogExpanded;
                ExpIp.IsExpanded = s.IpExpanded;
                CardDesc.Visibility = s.HelpCardVisible ? Visibility.Visible : Visibility.Collapsed;
                BtnHelp.Visibility = s.HelpCardVisible ? Visibility.Collapsed : Visibility.Visible;
                autoScroll = s.AutoScroll;
                SwAutoScroll.IsChecked = s.AutoScroll;
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>退出时把界面状态写回 data\ui.json</summary>
        private void SaveUiState()
        {
            try
            {
                UiStateData s = UiState.Current;

                // 最大化时 Left/Top/Width/Height 是最大化后的值，要用 RestoreBounds 存"还原后应该多大"
                if (s.RememberWindow)
                {
                    Rect b = (WindowState == WindowState.Normal)
                        ? new Rect(Left, Top, Width, Height)
                        : RestoreBounds;
                    if (b.Width > 100 && b.Height > 100)
                    {
                        s.Left = b.Left;
                        s.Top = b.Top;
                        s.Width = b.Width;
                        s.Height = b.Height;
                    }
                    s.Maximized = (WindowState == WindowState.Maximized);
                }
                else
                {
                    // 用户在设置里关掉了"记住窗口" —— 顺手把已经存下来的抹掉，
                    // 否则下次他又打开开关会突然跳回很久以前的位置
                    s.Left = null;
                    s.Top = null;
                    s.Maximized = false;
                }

                s.HelpCardVisible = (CardDesc.Visibility == Visibility.Visible);
                s.LogExpanded = ExpLog.IsExpanded;
                s.IpExpanded = ExpIp.IsExpanded;
                s.AutoScroll = autoScroll;

                UiState.Touch();
                UiState.Save();
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        // ====================================================================
        //  被吞掉的异常
        //
        //  全篇原来是 31 个裸 catch{}：一旦哪里出错，运行日志里一个字都没有，
        //  用户只能反馈「某个功能没反应」，排查全靠猜。这里至少把
        //  「哪个方法 + 什么异常 + 什么消息」写进日志。
        //
        //  做成 static 是因为 QueryServiceBinPath / RunHidden 这类静态方法里也有裸 catch。
        //  用 inSwallow 防递归（Append 自己也有 catch，可能回卷到 Swallowed）。
        // ====================================================================
        private static bool inSwallow = false;

        private static void Swallowed(Exception ex)
        {
            if (inSwallow) return;
            inSwallow = true;
            try
            {
                // 找出是谁吞的：往上翻栈帧，跳过 Swallowed / Append 自己
                string who = "?";
                try
                {
                    System.Diagnostics.StackTrace st = new System.Diagnostics.StackTrace(true);
                    for (int i = 1; i < st.FrameCount; i++)
                    {
                        System.Diagnostics.StackFrame fr = st.GetFrame(i);
                        if (fr == null) continue;
                        System.Reflection.MethodBase mb = fr.GetMethod();
                        if (mb == null) continue;
                        string n = mb.Name;
                        if (n == "Swallowed" || n == "Append") continue;
                        who = n;
                        break;
                    }
                }
                catch { }

                string msg = "[内错] " + who + "：" + ex.GetType().Name + " " + ex.Message;

                MainWindow w = (Application.Current == null) ? null : Application.Current.MainWindow as MainWindow;
                if (w == null)
                {
                    // 窗口还没建好（构造函数阶段）或者已经关了 —— 只能落盘
                    Ui.WriteErrorLog("[内错] " + who, ex);
                    return;
                }
                if (w.Dispatcher.CheckAccess()) w.Append(msg);
                else w.Dispatcher.BeginInvoke(new Action(delegate { w.Append(msg); }));
            }
            catch { }
            finally { inSwallow = false; }
        }

        // ====================================================================
        private void BuildNavDefs()
        {
            navDefs.Add(new NavDef("oneclick", "一键完成",
                "从零到能用，一条龙全自动。\r\n\r\n" +
                "  1. 环境检查（服务 / 驱动 / hosts）\r\n" +
                "  2. 全量扫描 —— Cloudflare 5956 个 /24 + CloudFront 16552 个 /24，" +
                "ICMP + TLS 全测（已有新鲜数据会跳过）\r\n" +
                "  3. 延迟实测 —— 两组 Top 40，多轮交替\r\n" +
                "  4. 下载测速 —— 真实文件下载\r\n" +
                "  5. 跑完自动弹出候选清单 → 你挑一个 → 写 hosts → 自动验证",
                "all-in-one.ps1", "-Yes -NoPick", true));

            navDefs.Add(new NavDef("install", "安装",
                "下载工具 4 个文件（约 3.2 MB）、解析各域名真实 IP（多 DoH 源交叉验证）、\r\n" +
                "备份并写入 hosts、注册并启动 VRChatBypass 服务，最后全量验证。\r\n\r\n" +
                "如果检测到普通网站被影响，会自动完全回滚。\r\n\r\n预计耗时：1 ~ 3 分钟",
                "install.ps1", "", false));

            navDefs.Add(new NavDef("uninstall", "卸载",
                "停止并删除 VRChatBypass 服务、停止并删除 WinDivert 驱动、\r\n" +
                "从 hosts 里精确删除本工具写入的块、刷新 DNS、删除程序目录下的 data。\r\n\r\n" +
                "装之前什么样，卸之后就什么样。\r\n\r\n预计耗时：约 30 秒",
                "uninstall.ps1", "-Yes", false));

            navDefs.Add(new NavDef("diagnose", "诊断",
                "只读健康检查，不做任何修改，不需要管理员权限。\r\n\r\n" +
                "检查项：服务状态 / 驱动状态 / winws 进程 / hosts 内容 /\r\n" +
                "全部 VRChat 域名的实际解析与连通性 / 普通网站是否被影响。\r\n\r\n" +
                "★ 关于耗时：通的域名每个几秒，不通的每个要重试 2 次、各 12 秒。\r\n" +
                "   装之前很可能有七八个域名不通 —— 那就是两三分钟。别以为卡住了，\r\n" +
                "   日志每个域名都会打一行，看得到就走得动。\r\n\r\n预计耗时：1 ~ 5 分钟（取决于有多少域名不通）",
                "diagnose.ps1", "", false));

            navDefs.Add(new NavDef("scan", "全量扫描",
                "对 Cloudflare 5956 个 /24 和 CloudFront 16552 个 /24 做【全部】ICMP + TLS 测试，\r\n" +
                "不做 ICMP 前置过滤 —— 能覆盖那些「不回 ping 但 HTTPS 服务正常」的 IP\r\n" +
                "（实测有 370 个，旧方法会漏掉）。\r\n\r\n" +
                "抗风控设计：全局令牌桶限速 45 次/秒 · 并发 32 · 目标列表随机打乱 ·\r\n" +
                "主机位随机（不固定取 .1）· 阶段间停顿 · 结果增量落盘。\r\n\r\n" +
                "全程实时进度，随时可停止。预计耗时：约 24 分钟",
                "full-scan.ps1", "-Rate 45 -Threads 32", false));

            navDefs.Add(new NavDef("latency", "延迟实测",
                "取两组各 Top 40，多轮交替测 TLS 握手，统计中位 / 抖动 / 成功率。\r\n" +
                "每验证完一个 IP，下方「实时 IP 结果」立刻出现一行。\r\n\r\n" +
                "★ 为什么必须多轮：Cloudflare / CloudFront 用 Anycast，同一个 IP 在\r\n" +
                "不同时刻可能被路由到不同机房。实测有 IP 单次 42ms 但中位 142ms、\r\n" +
                "抖动 600ms —— 只看单次会选错。\r\n\r\n预计耗时：3 ~ 5 分钟",
                "latency-test.ps1", "-TopN 40 -Rounds 5", false));

            navDefs.Add(new NavDef("speedtest", "下载测速",
                "对延迟实测出的候选做真实文件下载测速。\r\n\r\n" +
                "  · B 组（CloudFront）基准：SDK 文件，约 6.3 MB（准确）\r\n" +
                "  · A 组（Cloudflare）基准：docs 首页，约 190 KB（粗略，仅供参考）\r\n\r\n" +
                "★ 延迟不能预测吞吐：实测同一批 IP 延迟只差 16ms，吞吐差 27 倍。\r\n\r\n" +
                "预计耗时：4 ~ 8 分钟",
                "speedtest-batch.ps1", "-Rounds 2", false));

            NavDef pick = new NavDef("picker", "清单选用",
                "把实测结果整理成清单，在弹出的表格窗口里显示，你选完直接写入 hosts。\r\n\r\n" +
                "表格里会标注清楚：每组覆盖哪些域名、每个域名是干什么的、\r\n" +
                "指标口径（A 组看延迟，B 组看速度）、每个 IP 的中位/抖动/速度/成功率。\r\n\r\n" +
                "写入后自动回归验证，有任何域名失败会自动回滚。\r\n\r\n预计耗时：约 1 分钟",
                "", "", false);
            pick.Special = "picker";
            navDefs.Add(pick);

            NavDef cache = new NavDef("cache", "清理缓存",
                "本工具会把扫描和实测结果存在程序目录的 data 下，下次跑会直接引用，\r\n" +
                "省掉重复测试。如果想强制重新测（例如换了网络、或怀疑数据过期），\r\n" +
                "就在这里把缓存清掉。\r\n\r\n" +
                "  · 扫描结果 1.3 MB 是最大的一项，清掉后「一键完成」会重扫（约 24 分钟）\r\n" +
                "  · 实测结果清掉后需重跑「延迟实测」和「下载测速」\r\n" +
                "  · 当前 hosts 配置和服务完全不受影响\r\n\r\n" +
                "勾选要清的类别，然后点「清理勾选项」。",
                "", "", false);
            cache.Special = "cache";
            navDefs.Add(cache);

            navDefs.Add(new NavDef("autostd", "自动优选·标准",
                "老版本的全自动优选：ICMP 先过滤，只对 Top-N 做 TLS 验证，\r\n" +
                "然后按「中位 + 抖动/4」挑最优，自动写入 hosts。\r\n\r\n" +
                "优点：快。缺点：有 ICMP 盲区 —— 不回 ping 的好 IP 会被漏掉。\r\n" +
                "想要完整覆盖请用「全量扫描 → 延迟实测 → 下载测速 → 清单选用」。\r\n\r\n" +
                "预计耗时：8 ~ 12 分钟",
                "auto-optimize.ps1", "", false));

            navDefs.Add(new NavDef("autofast", "自动优选·快速",
                "同上，但候选更少，适合「换了网络想快速弄好」。\r\n\r\n预计耗时：3 ~ 5 分钟",
                "auto-optimize.ps1", "-Quick", false));

            NavDef sub = new NavDef("sub", "订阅",
                "导入 / 更新 Clash 订阅，并选择要使用的订阅组。\r\n\r\n" +
                "  · 填订阅地址 → 点「导入 / 更新」，节点会自动下载到本机\r\n" +
                "  · 下面的「订阅组」就是这个订阅里的代理组，选一个作为默认组\r\n" +
                "  · 下载失败会显示具体原因（UA / 字节数 / 首行内容）",
                "", "", false);
            sub.Special = "sub";
            navDefs.Add(sub);

            NavDef nodes = new NavDef("nodes", "节点",
                "从订阅里挑节点：选一个 → 应用节点，立即生效，不用重启内核。\r\n\r\n" +
                "同一页还有代理模式（规则 / 全局 / 直连）和 TUN 开关。",
                "", "", false);
            nodes.Special = "nodes";
            navDefs.Add(nodes);

            NavDef trace = new NavDef("trace", "Ping",
                "逐节点测试：把订阅组依次切到每个节点，经该节点访问 Google 的中性探测点（HTTP 口径），\r\n" +
                "量到首字节的时间。\r\n\r\n" +
                "之所以不用 ICMP：mihomo 的 ICMP 一律走 DIRECT（不支持走代理）。\r\n" +
                "对不回 HTTP 的目标（例如 Photon 游戏服），请用「路由追踪」。",
                "", "", false);
            trace.Special = "trace";
            navDefs.Add(trace);

            NavDef drivers = new NavDef("drivers", "内核",
                "管理两个内置内核：何时开、何时关、用哪个版本。\r\n\r\n" +
                "  · winws —— DPI 伪装，解决 VRChat 域名被干扰\r\n" +
                "  · mihomo —— 代理内核，给游戏流量走代理（见「代理」页）\r\n\r\n" +
                "两个内核互相独立，可分别开启 / 关闭 / 重启；退出程序时会一起停掉。",
                "", "", false);
            drivers.Special = "drivers";
            navDefs.Add(drivers);
            NavDef settings = new NavDef("settings", "设置",
                "外观（跟随系统 / 浅色 / 深色）、是否记住窗口大小位置、\r\n" +
                "一键导出诊断包（运行日志 + hosts + 服务状态 + 目录清单 + 系统信息），\r\n" +
                "以及重置界面状态。\r\n\r\n" +
                "这一页不跑任何脚本，也就不会改动系统。",
                "", "", false);
            settings.Special = "settings";
            navDefs.Add(settings);

            // 建立 Key → 下标 的索引。XAML 里 Tag 存的是 Key，代码按 Key 查，
            // 两边不再依赖"下标必须对齐"这种一插就错的约定。
            for (int i = 0; i < navDefs.Count; i++) navIndex[navDefs[i].Key] = i;
        }

        private void BuildCacheItems()
        {
            cacheItems.Add(new CacheItem { Key = "Scan", Name = "扫描结果",
                Desc = "全量扫描候选池，清掉后需重扫（约 24 分钟）",
                Dir = dataDir, Pat = new string[] { "full-scan-*.csv", "full-scan-*-top.txt", "full-scan-*-partial.csv" } });
            cacheItems.Add(new CacheItem { Key = "Latency", Name = "实测结果",
                Desc = "延迟 / 测速结果，清掉后需重新实测",
                Dir = dataDir, Pat = new string[] { "latency-result.csv", "speed-result.csv", "pool-state.json", "speedtest-result.csv", "speedtest-best.txt" } });
            cacheItems.Add(new CacheItem { Key = "Reports", Name = "报告与清单",
                Desc = "稳定性报告、候选清单文本",
                Dir = dataDir, Pat = new string[] { "stability-report.csv", "候选*.txt", "候选清单.txt" } });
            cacheItems.Add(new CacheItem { Key = "Logs", Name = "日志",
                Desc = "安装 / 运行日志", Dir = dataDir, Pat = new string[] { "*.log" } });
            cacheItems.Add(new CacheItem { Key = "Baks", Name = "hosts 备份",
                Desc = "优选前自动备份，hosts.original 永不删",
                Dir = dataDir, Pat = new string[] { "hosts.before-*", "hosts.old*" } });
            cacheItems.Add(new CacheItem { Key = "Temp", Name = "临时文件",
                Desc = "GUI 运行时的临时脚本、诊断文件",
                Dir = Path.GetTempPath(), Pat = new string[] { "vrctool-*.ps1", "vrctool-*.txt" } });
            CacheItem dns = new CacheItem { Key = "Dns", Name = "DNS 缓存", Desc = "ipconfig /flushdns", Dir = "", Pat = new string[0], Dns = true };
            cacheItems.Add(dns);
            foreach (CacheItem c in cacheItems) c.Scan();
        }

        // ====================================================================
        //  主题
        // ====================================================================
        /// <summary>
        /// 抽屉收放时重排行高。
        ///   两个都展开 → 各占一半（*），分隔条显示
        ///   只开一个   → 那个占满（*），另一个压成 Auto
        ///   都收起     → 都压成 Auto，剩余高度交给 RowSlack 吃掉，
        ///                这样底部按钮和进度条仍然钉在底部
        /// </summary>
        private void LayoutDrawers()
        {
            try
            {
                if (RowLog == null || RowIp == null) return;

                bool logOpen = ExpLog.IsExpanded;
                bool ipOpen = ExpIp.IsExpanded;
                bool any = logOpen || ipOpen;

                // 关键：CardExpander 收起时不会把内容排除出测量，
                // 所以必须自己把内容层藏掉，DesiredSize 才会真的缩到只剩标题栏。
                LogBody.Visibility = logOpen ? Visibility.Visible : Visibility.Collapsed;
                IpBody.Visibility = ipOpen ? Visibility.Visible : Visibility.Collapsed;

                // CardExpander 收起后 DesiredSize 仍按内容算（≈186），
                // 所以 Auto 会留一大片空白。收起时给一个确定的行高，
                // 并把控件本身也夹住，避免溢出。
                double headerH = CollapsedHeaderHeight();
                GridLength off = new GridLength(headerH);

                ExpLog.MaxHeight = logOpen ? double.PositiveInfinity : headerH;
                ExpIp.MaxHeight = ipOpen ? double.PositiveInfinity : headerH;

                RowLog.Height = logOpen ? new GridLength(1, GridUnitType.Star) : off;
                RowIp.Height = ipOpen ? new GridLength(1, GridUnitType.Star) : off;

                // 抽屉被压到只剩几十像素时，空状态和表头会叠在一起。
                // 展开时给个下限（够放表头 + 一两行内容 / 两句提示），收起时清零。
                RowLog.MinHeight = logOpen ? 120 : 0;
                RowIp.MinHeight = ipOpen ? 120 : 0;

                RowDrawers.Height = any ? new GridLength(1, GridUnitType.Star) : GridLength.Auto;
                RowSlack.Height = any ? GridLength.Auto : new GridLength(1, GridUnitType.Star);

                SplHost.Visibility = (logOpen && ipOpen) ? Visibility.Visible : Visibility.Collapsed;

                ClampLogHeight();
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>
        /// 给日志的 RichTextBox 一个「有上限的高度」。
        ///
        /// ★ 这是「日志滚不动」的真正原因 ★
        ///   CardExpander 给内容的是**无上限**的高度，RichTextBox 于是跟着文档一起长高
        ///   （实测文档 73 行 → 元素高 1498px），整个元素被父容器直接裁掉。
        ///   而 RichTextBox 内部的 ScrollViewer 认为「我全都装得下，不用滚」——
        ///   于是既没有滚动条，滚轮和拖拽也完全没反应。
        ///
        ///   数据是对的（UIA 能读出全部 73 行），纯粹是布局没给它边界。
        ///   这里把 MaxHeight 夹到这一行的高度（RowLog 是 Star 行，有界）
        ///   减去 CardExpander 的标题栏高度，ScrollViewer 才会真正生效。
        ///
        /// 之所以不用固定值：GridSplitter 能拖、窗口能缩、界面缩放能变，
        /// 高度必须跟着走，所以由 ExpLog.SizeChanged 反复触发。
        /// </summary>
        private void ClampLogHeight()
        {
            try
            {
                if (TxtLog == null || RowLog == null) return;
                if (ExpLog == null || !ExpLog.IsExpanded) return;

                double row = RowLog.ActualHeight;
                if (row <= 0) return;

                double avail = row - CollapsedHeaderHeight();
                TxtLog.MaxHeight = (avail > 40) ? avail : 40;
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        private double _collapsedHeader = 0;

        /// <summary>
        /// PerMonitorV2 下把窗口拖到另一块缩放比例不同的屏幕时，抽屉标题栏高度要重新量。
        /// 原来只量一次就缓存住，换屏后收起抽屉要么剩一条缝、要么被切掉一截。
        /// </summary>
        protected override void OnDpiChanged(DpiScale oldDpi, DpiScale newDpi)
        {
            base.OnDpiChanged(oldDpi, newDpi);
            try
            {
                _collapsedHeader = 0;
                LayoutDrawers();
                // 语言要在布局完成、文字实体化之后应用
                ApplyLanguage();
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>
        /// 量出抽屉「只剩一个标题栏」时应该有多高。
        /// 做法：把内容层藏掉，强制重新测量一次，读回 DesiredSize。
        /// </summary>
        private double CollapsedHeaderHeight()
        {
            if (_collapsedHeader > 0) return _collapsedHeader;

            // 保存 → 隐藏内容 → 测量 → 还原，不能把可见性留在 Collapsed
            Visibility logVis = LogBody.Visibility;
            Visibility ipVis = IpBody.Visibility;

            try
            {
                LogBody.Visibility = Visibility.Collapsed;
                IpBody.Visibility = Visibility.Collapsed;

                ExpLog.Measure(new Size(ExpLog.ActualWidth > 0 ? ExpLog.ActualWidth : 800, double.PositiveInfinity));
                double h = ExpLog.DesiredSize.Height;

                // 兜底：量不出来就用 52（标题栏在 125% DPI 下约 50 DIP）
                _collapsedHeader = (h > 20 && h < 120) ? h : 52;
            }
            catch { _collapsedHeader = 52; }
            finally
            {
                LogBody.Visibility = logVis;
                IpBody.Visibility = ipVis;
            }

            return _collapsedHeader;
        }

        // 真实的管理员权限检测（EXE 清单声明了 requireAdministrator，
        // 所以正常情况下一定是 true；这里是为了万一被别的方式启动时也显示正确）
        private static bool IsElevated()
        {
            try
            {
                System.Security.Principal.WindowsIdentity id =
                    System.Security.Principal.WindowsIdentity.GetCurrent();
                System.Security.Principal.WindowsPrincipal pr =
                    new System.Security.Principal.WindowsPrincipal(id);
                return pr.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
            catch { return false; }
        }

        private Brush Res(string key)
        {
            try
            {
                object o = Application.Current.TryFindResource(key);
                Brush b = o as Brush;
                if (b != null) return b;
            }
            catch (Exception __ex) { Swallowed(__ex); }
            return null;
        }

        private void SyncThemeIcon()
        {
            try
            {
                isDark = (ApplicationThemeManager.GetAppTheme() == ApplicationTheme.Dark);
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        private Brush LatBrush(int lat)
        {
            if (lat < 0) return Res("TextFillColorDisabledBrush");
            if (lat <= 120) return Res("SystemFillColorSuccessBrush");
            if (lat <= 300) return Res("TextFillColorPrimaryBrush");
            return Res("SystemFillColorCautionBrush");
        }

        // ====================================================================
        private void NavItem_Click(object sender, RoutedEventArgs e)
        {
            // 启动阶段 NavigationView 内部会同步选中项，会误触发，这里挡掉
            if (!uiReady) return;

            object o = sender;
            NavigationViewItem nvi = o as NavigationViewItem;
            if (nvi == null)
            {
                FrameworkElement fe = o as FrameworkElement;
                if (fe != null) nvi = fe.Parent as NavigationViewItem;
            }
            if (nvi == null) return;

            string tag = (nvi.Tag as string ?? "").Trim();
            if (tag.Length == 0) return;               // 分组项：只负责展开 / 收起

            int idx;
            if (navIndex.TryGetValue(tag, out idx))
            {
                navSel = idx;
                ApplyNav();
            }
        }

        // NavigationView 不走 Frame 导航时，选中指示要自己设 IsActive。
        // 分组项（Tag 为空）只负责展开/收起，不参与选中。
        private void HighlightNav(int idx)
        {
            string key = (idx >= 0 && idx < navDefs.Count) ? navDefs[idx].Key : "";
            foreach (object o in RootNav.MenuItems) WalkHighlight(o, key);
            foreach (object o in RootNav.FooterMenuItems) WalkHighlight(o, key);
        }

        private void WalkHighlight(object o, string key)
        {
            NavigationViewItem nvi = o as NavigationViewItem;
            if (nvi == null) return;

            string tag = (nvi.Tag as string ?? "").Trim();
            nvi.IsActive = (tag.Length > 0) && (tag == key);

            foreach (object c in nvi.MenuItems) WalkHighlight(c, key);
        }

        private void ApplyNav()
        {
            try { HighlightNav(navSel); } catch (Exception __ex) { Swallowed(__ex); }
            if (!uiReady) return;
            NavDef it = navDefs[navSel];

            TxtTitle.Text = it.Title;
            // 去掉多余空行，文字更紧凑
            TxtDesc.Text = (it.Desc ?? "").Replace("\r\n\r\n", "\r\n").Replace("\n\n", "\n");

            bool isPicker = it.Special == "picker";
            bool isCache = it.Special == "cache";
            bool isSettings = it.Special == "settings";
            string runText;
            if (isCache) runText = "清理勾选项";
            else if (isPicker) runText = "打开候选清单";
            else runText = it.Big ? "开始一键完成" : "开始执行";
            BtnRun.Content = runText;
            BtnRun.Appearance = ControlAppearance.Primary;

            // 设置页不跑脚本，把操作按钮整排收掉，免得点了没反应
            bool noScript = isSettings || it.Special == "sub" || it.Special == "nodes" || it.Special == "trace" || it.Special == "drivers";
            Visibility runVis = noScript ? Visibility.Collapsed : Visibility.Visible;
            BtnRun.Visibility = runVis;
            BtnStop.Visibility = runVis;
            if (isSettings) Ring.Visibility = Visibility.Collapsed;

            try
            {
                bool admin = IsElevated();
                if (admin) { BadgeAdmin.Value = "管理员权限已就绪"; BadgeAdmin.Severity = InfoBadgeSeverity.Success; }
                else { BadgeAdmin.Value = "未取得管理员权限"; BadgeAdmin.Severity = InfoBadgeSeverity.Caution; }
            }
            catch (Exception __ex) { Swallowed(__ex); }

            CardCache.Visibility = isCache ? Visibility.Visible : Visibility.Collapsed;
            if (isCache)
            {
                foreach (CacheItem c in cacheItems) c.Scan();
                CacheList.Items.Refresh();
            }

            bool isSub = it.Special == "sub";
            bool isNodes = it.Special == "nodes";
            bool isTrace = it.Special == "trace";
            bool isDrivers = it.Special == "drivers";

            CardSettings.Visibility = isSettings ? Visibility.Visible : Visibility.Collapsed;
            if (CardUpdate != null) CardUpdate.Visibility = isSettings ? Visibility.Visible : Visibility.Collapsed;
            TxtSettingsInfo.Visibility = isSettings ? Visibility.Visible : Visibility.Collapsed;
            CardSub.Visibility = isSub ? Visibility.Visible : Visibility.Collapsed;
            CardNodes.Visibility = isNodes ? Visibility.Visible : Visibility.Collapsed;
            CardTrace.Visibility = isTrace ? Visibility.Visible : Visibility.Collapsed;
            CardDrivers.Visibility = isDrivers ? Visibility.Visible : Visibility.Collapsed;

            if (isSettings) RefreshSettingsUi();
            if (isSub || isNodes || isTrace || isDrivers) RefreshKernelUi();

            // 页面卡片是 Collapsed 的，启动时不在可视树里，语言没被应用过。
            // 每次切页都补一次，保证非中文界面下各页文字一致。
            if (Localization.Current != UiLang.ChineseSimplified) ApplyLanguage();
        }

        // ====================================================================
        // ---- 说明卡关闭 / 恢复 ----
        private void BtnCloseDesc_Click(object sender, RoutedEventArgs e)
        {
            CardDesc.Visibility = Visibility.Collapsed;
            BtnHelp.Visibility = Visibility.Visible;
        }

        private void BtnHelp_Click(object sender, RoutedEventArgs e)
        {
            CardDesc.Visibility = Visibility.Visible;
            BtnHelp.Visibility = Visibility.Collapsed;
        }


        private void BtnRun_Click(object sender, RoutedEventArgs e)
        {
            NavDef it = navDefs[navSel];
            if (it.Special == "picker") { OpenPicker(); return; }
            if (it.Special == "cache") { RunCacheClear(); return; }
            if (it.Special == "settings") return;      // 设置页不跑脚本
            if (string.IsNullOrEmpty(it.Script)) return;

            // 安装 / 卸载是真改系统的操作（hosts + 服务 + 驱动），点之前必须过一道确认。
            // 之前是点下去就执行 —— 我自己就误点过一次。
            if (it.Key == "install")
            {
                if (!Ui.Confirm(
                    "会做这些事：\r\n\r\n" +
                    "  · 下载 4 个加速组件到程序目录的 tools\\\r\n" +
                    "  · 解析各域名真实 IP（多 DoH 源交叉验证）\r\n" +
                    "  · 备份并写入 hosts\r\n" +
                    "  · 注册并启动 VRChatBypass 服务\r\n\r\n" +
                    "这会修改系统 hosts 和系统服务。检测到普通网站被影响会自动完全回滚。\r\n\r\n" +
                    "确认开始安装？",
                    it.Title)) return;
            }
            else if (it.Key == "uninstall")
            {
                if (!Ui.ConfirmDanger(
                    "会做这些事：\r\n\r\n" +
                    "  · 停止并删除 VRChatBypass 服务\r\n" +
                    "  · 停止并删除 WinDivert 驱动\r\n" +
                    "  · 把 hosts 还原成安装前的样子\r\n" +
                    "  · 刷新 DNS，删掉程序目录下的 data\\\r\n\r\n" +
                    "装之前什么样，卸之后就什么样。\r\n\r\n" +
                    "确认开始卸载？",
                    it.Title)) return;
            }

            RunScript(it.Script, it.Args, it.Title);
        }

        private void BtnStop_Click(object sender, RoutedEventArgs e) { StopRun(); }

        private void BtnClear_Click(object sender, RoutedEventArgs e)
        {
            try { TxtLog.Document.Blocks.Clear(); } catch (Exception __ex) { Swallowed(__ex); }
            logLines.Clear();
            logChars = 0;
            logPinned = true;
            logLastOffset = -1;
            CreateLogDocument();
            ipRows.Clear();
            ipMap.Clear();
            ipTotal = 0;
            TxtIpCount.Text = "";
            UpdateIpEmptyState();
        }

        private void BtnCopyLog_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                string txt = LogText();
                if (string.IsNullOrEmpty(txt))
                {
                    Ui.Info("日志是空的。", "提示");
                    return;
                }
                Clipboard.SetText(txt);
                Append("（日志已复制到剪贴板，共 " + txt.Length + " 个字符）");
            }
            catch (Exception ex)
            {
                Ui.Error("复制失败：" + ex.Message, "错误");
            }
        }

        private void BtnOpenDir_Click(object sender, RoutedEventArgs e)
        {
            try { Process.Start("explorer.exe", ScriptHost.RootDir); } catch (Exception __ex) { Swallowed(__ex); }
        }

        private void SwAutoScroll_Click(object sender, RoutedEventArgs e)
        {
            autoScroll = SwAutoScroll.IsChecked == true;
            // 手动打开「自动滚动」时，把它当成「我要追最新」，直接拉到底并重新贴底
            if (autoScroll) { logPinned = true; TxtLog.ScrollToEnd(); }
        }

        private void BtnSelAll_Click(object sender, RoutedEventArgs e)
        { foreach (CacheItem c in cacheItems) c.Checked = true; }

        private void BtnSelNone_Click(object sender, RoutedEventArgs e)
        { foreach (CacheItem c in cacheItems) c.Checked = false; }

        // ====================================================================
        private void RunScript(string scriptFile, string extraArgs, string title)
        {
            if (ctx != null && ctx.P != null && !ctx.P.HasExited)
            {
                Ui.Info("已有任务在运行，请先停止。", "提示");
                return;
            }

            // 落地 + SHA256 复核：目录本身只有管理员能写，这一层是防"被替换"的兜底
            if (!ScriptHost.EnsureScript(scriptFile))
            {
                string why = ScriptHost.LastError;
                Append("[x] 内置脚本不可用: " + scriptFile + (string.IsNullOrEmpty(why) ? "" : " —— " + why));
                Ui.Error("EXE 里的脚本 " + scriptFile + " 无法使用。\r\n\r\n" + (why ?? "落地校验失败"), "错误");
                return;
            }
            string sp = ScriptHost.Path2(scriptFile);

            ResetProgress(title);
            Append("");
            Append("▶ " + title + "    (" + scriptFile + " " + extraArgs + ")");

            StringBuilder sb = new StringBuilder();
            sb.AppendLine("$ErrorActionPreference='Continue'");
            sb.AppendLine("[Console]::OutputEncoding=[Text.Encoding]::UTF8");
            sb.AppendLine("$OutputEncoding=[Text.Encoding]::UTF8");
            ScriptHost.AppendEnvSetup(sb);          // 把 根目录/工具目录/数据目录 传给脚本
            sb.AppendLine("& '" + sp.Replace("'", "''") + "' " + extraArgs);
            // 退出码：约定只有 0/1/2 三种（脚本末尾必须显式 exit）。
            // 拿不到（$null）或超出范围（例如最后一条 curl 的 28、sc 的 6）说明脚本没显式退出，
            // 不能把它当任务结果 —— 否则"成功却显示退出码 28"。
            sb.AppendLine("$code = $LASTEXITCODE");
            sb.AppendLine("if ($null -eq $code -or $code -isnot [int]) { $code = 0 }");
            sb.AppendLine("if ($code -lt 0 -or $code -gt 2) { Write-Host ('[warn] 忽略非约定退出码 ' + $code + '（脚本没有显式 exit）'); $code = 0 }");
            sb.AppendLine("exit $code");

            string wrapper;
            try { wrapper = ScriptHost.WriteTempFile("run-", sb.ToString()); }
            catch (Exception ex)
            {
                SetBusy(false);
                Append("[x] 写 wrapper 失败: " + ex.Message);
                return;
            }
            if (string.IsNullOrEmpty(wrapper))
            {
                SetBusy(false);
                Append("[x] 写 wrapper 失败（受保护临时目录不可用）");
                return;
            }

            ProcessStartInfo psi = new ProcessStartInfo(PowerShellPath);
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + wrapper + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = Encoding.UTF8;
            psi.StandardErrorEncoding = Encoding.UTF8;
            psi.WorkingDirectory = scriptDir;

            RunCtx c = new RunCtx();
            c.Id = ++ctxSeq;
            c.Script = scriptFile;
            c.Wrapper = wrapper;

            try
            {
                Process p = new Process();
                p.StartInfo = psi;
                p.OutputDataReceived += delegate(object s, DataReceivedEventArgs ev)
                { if (ev.Data != null) Post(delegate { OnLine(ev.Data); }); };
                p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs ev)
                { if (ev.Data != null) Post(delegate { OnLine("[stderr] " + ev.Data); }); };
                p.EnableRaisingEvents = true;
                p.Exited += delegate(object s, EventArgs ev)
                {
                    int code = -1;
                    try { code = ((Process)s).ExitCode; } catch (Exception __ex) { Swallowed(__ex); }
                    RunCtx mine = c;
                    Post(delegate
                    {
                        // 不是当前任务（用户已经点了停止并开了新的）→ 只清理自己的文件，
                        // 绝不动界面状态，也不删别人的 wrapper。
                        if (!object.ReferenceEquals(ctx, mine))
                        {
                            CleanupWrapper(mine);
                            return;
                        }
                        ctx = null;
                        SetBusy(false);
                        Append("");
                        Append("---- 结束，退出码 " + code + " ----");
                        RefreshStatus();
                        CleanupWrapper(mine);
                        TrimMemory();
                        // 「一键完成」以 -NoPick 跑完（且全步成功）后，自动把候选清单窗口叫起来。
                        // 脚本侧已经跳过交互式选用，最后这一步必须由这个窗口接力完成。
                        if (code == 0 && mine.Script == "all-in-one.ps1") OpenPicker();
                    });
                };

                c.P = p;
                ctx = c;
                SetBusy(true);
                p.Start();
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
            }
            catch (Exception ex)
            {
                ctx = null;
                SetBusy(false);
                Append("[x] 启动失败: " + ex.Message);
                CleanupWrapper(c);
            }
        }

        /// <summary>UI 线程投递：退出瞬间 Dispatcher 可能已经关了，再投递会抛未处理异常</summary>
        private void Post(Action a)
        {
            try
            {
                Dispatcher d = Dispatcher;
                if (d == null || d.HasShutdownStarted || d.HasShutdownFinished) return;
                d.BeginInvoke(a);
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>
        /// 结束进程树。全部用绝对路径：CreateProcess 对裸文件名会按「当前目录 → 应用目录」
        /// 搜索，而本程序支持把整个目录搬到可写位置，同目录放个同名 exe 就能以管理员身份执行。
        /// </summary>
        private void KillTree(RunCtx c)
        {
            if (c == null || c.P == null) return;

            int pid = -1;
            try { pid = c.P.Id; } catch (Exception __ex) { Swallowed(__ex); }
            if (pid <= 0) return;

            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "taskkill.exe"));
                psi.Arguments = "/F /T /PID " + pid;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;

                using (Process k = Process.Start(psi))
                {
                    if (k != null)
                    {
                        string ignore = k.StandardOutput.ReadToEnd();
                        ignore = k.StandardError.ReadToEnd();
                        ignore = null;
                        k.WaitForExit(8000);
                    }
                }
            }
            catch (Exception __ex) { Swallowed(__ex); }

            // taskkill 未必成功（没权限/进程已退出/被杀软拦），再兜一次
            try { if (!c.P.HasExited) c.P.Kill(true); } catch (Exception __ex) { Swallowed(__ex); }
            try { c.P.WaitForExit(3000); } catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>删掉某个任务的 wrapper 脚本（每次运行的名字都不一样）</summary>
        private void CleanupWrapper(RunCtx c)
        {
            try
            {
                if (c != null && !string.IsNullOrEmpty(c.Wrapper) && File.Exists(c.Wrapper))
                    File.Delete(c.Wrapper);
            }
            catch (Exception __ex) { Swallowed(__ex); }
            if (c != null) c.Wrapper = "";
        }

        // powershell.exe 的绝对路径（System32\WindowsPowerShell\v1.0）
        private static string PowerShellPath
        {
            get
            {
                return Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
            }
        }

        // ====================================================================
        //  服务路径自检
        //
        //  Windows 服务的 binPath 必须是绝对路径，所以用户把整个程序目录搬到别的盘之后，
        //  服务里存的还是旧路径 —— 开机启动直接失败、直连失效，而且用户完全看不出原因。
        //  这里启动时自检一次：路径变了就自动改回来（只换可执行文件路径，参数原样保留）。
        // ====================================================================
        private void CheckServicePath()
        {
            System.Threading.Tasks.Task.Run(delegate
            {
                try
                {
                    string got = QueryServiceBinPath("VRChatBypass");
                    if (string.IsNullOrEmpty(got)) return;          // 没装服务，不用管

                    // got 形如： "C:\旧路径\tools\winws.exe" --wf-tcp=80,443
                    string exe = "", rest = "";
                    string t = got.Trim();
                    if (t.StartsWith("\""))
                    {
                        int end = t.IndexOf('"', 1);
                        if (end < 0) return;
                        exe = t.Substring(1, end - 1);
                        rest = t.Substring(end + 1).Trim();
                    }
                    else
                    {
                        int sp = t.IndexOf(' ');
                        exe = sp < 0 ? t : t.Substring(0, sp);
                        rest = sp < 0 ? "" : t.Substring(sp + 1).Trim();
                    }

                    string want = Path.Combine(ScriptHost.ToolsDir, "winws.exe");
                    if (string.Equals(exe, want, StringComparison.OrdinalIgnoreCase)) return;   // 路径没变
                    if (File.Exists(want) == false) return;          // 新位置没有 winws.exe，先别动

                    string value = "\"" + want + "\"" + (rest.Length > 0 ? " " + rest : "");
                    bool ok = RunHidden(SystemTool("sc.exe"), "config VRChatBypass binPath= " + value, 8000);

                    // 服务正在跑的时候改 binPath 不会生效，得重启一次
                    bool wasRunning = ServiceRunning("VRChatBypass");
                    if (ok && wasRunning)
                    {
                        RunHidden(SystemTool("sc.exe"), "stop VRChatBypass", 15000);
                        System.Threading.Thread.Sleep(800);
                        RunHidden(SystemTool("sc.exe"), "start VRChatBypass", 15000);
                    }

                    Post(delegate
                    {
                        if (ok)
                            Append("[自检] 程序目录移动过，已把 VRChatBypass 服务的路径改到 " + want
                                   + (wasRunning ? "（并已重启服务）" : "（服务当前未运行，下次启动生效）"));
                        else
                            Append("[自检] 程序目录移动过，但改服务路径失败（多半被杀软拦了），建议重新执行一次安装");
                        RefreshStatus();
                    });
                }
                catch (Exception __ex) { Swallowed(__ex); }
            });
        }

        /// <summary>
        /// 服务 binPath：直接读注册表，不再跑 sc.exe。
        /// 好处有三个：① 中文系统上 sc.exe 的输出是 GBK，读错编码会把中文路径读成乱码
        /// ② 少一次进程创建（这段在启动时跑）③ 不依赖 PATH / 不怕同名 exe 劫持。
        /// </summary>
        private static string QueryServiceBinPath(string name)
        {
            try
            {
                using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.LocalMachine
                           .OpenSubKey(@"SYSTEM\CurrentControlSet\Services\" + name))
                {
                    if (k == null) return "";
                    object v = k.GetValue("ImagePath");
                    return v == null ? "" : v.ToString();
                }
            }
            catch (Exception __ex) { Swallowed(__ex); }
            return "";
        }

        /// <summary>系统工具的绝对路径（防同名 exe 劫持）</summary>
        private static string SystemTool(string name)
        {
            return Path.Combine(Environment.SystemDirectory, name);
        }

        /// <summary>
        /// 跑一个外部命令并把 stdout + stderr 一起捞回来。
        /// 必须先起异步读、再 WaitForExit：反过来（先 ReadToEnd 再 WaitForExit）在
        /// 子进程写满管道时会把两边一起卡死，timeout 也就形同虚设。
        /// </summary>
        private static string RunCapture(string file, string args, int timeoutMs)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(file, args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;

                using (Process p = new Process())
                {
                    p.StartInfo = psi;
                    if (!p.Start()) return "";
                    System.Threading.Tasks.Task<string> o = p.StandardOutput.ReadToEndAsync();
                    System.Threading.Tasks.Task<string> e = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(timeoutMs))
                    {
                        try { p.Kill(true); } catch (Exception __ex) { Swallowed(__ex); }
                        return "";
                    }
                    string text = "";
                    try { text = o.Result; } catch (Exception __ex) { Swallowed(__ex); }
                    try { text = text + e.Result; } catch (Exception __ex) { Swallowed(__ex); }
                    return text ?? "";
                }
            }
            catch (Exception __ex) { Swallowed(__ex); }
            return "";
        }

        /// <summary>跑一个隐藏窗口的命令；返回 exit code 是否为 0</summary>
        private static bool RunHidden(string file, string args, int timeoutMs)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(file, args);
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;

                using (Process p = new Process())
                {
                    p.StartInfo = psi;
                    if (!p.Start()) return false;
                    System.Threading.Tasks.Task<string> o = p.StandardOutput.ReadToEndAsync();
                    System.Threading.Tasks.Task<string> e = p.StandardError.ReadToEndAsync();
                    if (!p.WaitForExit(timeoutMs))
                    {
                        try { p.Kill(true); } catch (Exception __ex) { Swallowed(__ex); }
                        return false;
                    }
                    return p.ExitCode == 0;
                }
            }
            catch (Exception __ex) { Swallowed(__ex); }
            return false;
        }

        private void StopRun()
        {
            RunCtx c = ctx;
            if (c == null || c.P == null || c.P.HasExited)
            {
                Append("[停止] 当前没有正在运行的任务");
                return;
            }

            int pid = -1;
            try { pid = c.P.Id; } catch (Exception __ex) { Swallowed(__ex); }

            Append("");
            Append("---- 正在停止（进程树 PID " + pid + "）... ----");

            // 先摘掉 ctx：这个进程的 Exited 回调随后会看到「不是当前任务」，
            // 于是只清理它自己的 wrapper，不会把新任务的状态清掉。
            ctx = null;
            KillTree(c);
            CleanupWrapper(c);

            SetBusy(false);
            TrimMemory();
            Append("---- 已停止 ----");
            RefreshStatus();
        }

        /// <summary>
        /// 侧栏收起 / 展开时适配。
        ///
        /// 收起后侧栏只剩 CompactPaneLength=48px。实测这个宽度下：
        ///   · PaneHeader 的「VRChat优选工具」被裁成「VRCh…」
        ///   · PaneFooter 的 TxtSidebar（三行状态文字 + TextWrapping=Wrap）
        ///     会被逐字换行，变成一竖条单字贴在左边缘 —— 非常难看
        /// 所以收起时把这两块文字直接藏掉，只留图标；
        /// 鼠标悬停在图标上 WPF-UI 自带 Tooltip，不会丢信息。
        /// </summary>
        private void ApplyPaneAdaptive(bool compact)
        {
            try
            {
                if (TxtPaneHeader != null)
                    TxtPaneHeader.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
                if (TxtSidebar != null)
                    TxtSidebar.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        private void SetBusy(bool busy)
        {
            BtnRun.IsEnabled = !busy;
            BtnStop.IsEnabled = busy;

            // 转圈图标。
            // 两个坑：
            //   ① WPF-UI 的 ProgressRing 只有在 IsIndeterminate=true 时才持续转，
            //      否则是按 Progress 值画的静态圆弧 —— 看着就是个不动的圈。
            //      （XAML 里已经写死 True，这里再兜一次。）
            //   ② Visibility 从 Collapsed 回到 Visible 时，模板里的动画不保证会自动重启，
            //      所以重新赋一遍 IsIndeterminate 把动画触发一次。
            try
            {
                Ring.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
                if (busy)
                {
                    Ring.IsIndeterminate = false;
                    Ring.IsIndeterminate = true;
                }
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        private void ResetProgress(string title)
        {
            try
            {
                ProgBox.Visibility = Visibility.Visible;
                // 还不知道总量 —— 先走不确定态（来回跑的马赛克），别停在 0% 装死。
                // 收到第一个 ##PROG## 再切成确定值。
                BarProg.IsIndeterminate = true;
                BarProg.Value = 0;
                TxtProgPct.Text = "";
                TxtProgStep.Text = title + " · 准备中";
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        // ====================================================================
        private void OnLine(string s)
        {
            if (s == null) { Append(""); return; }

            // 协议握手：脚本起手会吐一行 ##HELLO##proto=1。
            // 认不出来就说明 EXE 和脚本版本错位（比如 %TEMP% 里还留着上次的旧脚本副本）。
            if (s.StartsWith("##HELLO##"))
            {
                string body = s.Substring(9);
                if (body.IndexOf("proto=1", StringComparison.OrdinalIgnoreCase) < 0)
                {
                    Append("[x] 脚本协议版本不匹配（" + body + "）—— 请完全退出程序后重新打开。");
                }
                return;
            }

            if (s.StartsWith("##IP##"))
            {
                string body = s.Substring(6);
                if (body == "CLR") { ipClearPending = true; return; }
                string[] p = body.Split('|');
                if (p.Length >= 8) ipQueue.Add(p);
                return;
            }
            if (s.StartsWith("##PROG##")) { HandleProg(s.Substring(8)); return; }
            if (s.StartsWith("##STEP##")) { HandleStep(s.Substring(8)); return; }
            if (s.StartsWith("##DONE##")) { HandleDone(s.Substring(8)); return; }

            Append(s);
        }

        // ---- 进度事件 ----
        private void HandleProg(string body)
        {
            string[] p = body.Split('|');
            if (p.Length < 2) return;
            int cur, tot;
            if (!int.TryParse(p[0], out cur)) return;
            if (!int.TryParse(p[1], out tot) || tot <= 0) return;
            string label = p.Length >= 3 ? p[2] : "";

            ProgBox.Visibility = Visibility.Visible;
            // 有真实进度了，切回确定态
            BarProg.IsIndeterminate = false;
            double pct = cur * 100.0 / tot;
            if (pct < 0) pct = 0;
            if (pct > 100) pct = 100;
            BarProg.Value = Math.Round(pct, 1);
            TxtProgPct.Text = ((int)Math.Round(pct)) + "%";
            if (!string.IsNullOrEmpty(label)) TxtProgStep.Text = label;

            // 进度也要往日志里落一条。
            //
            // 为什么必须这么干：full-scan.ps1 的 ICMP 阶段（最长的一段，十几分钟）
            // 只吐 ##PROG##，##IP## 要等 TLS 阶段才开始有。而 ##PROG## 原来只更新
            // 上面那根进度条 —— 日志区一动不动、IP 表空白，用户看到的就是「卡死」。
            // 节流到 2.5 秒一条：24 分钟也就几百行，环形缓冲完全扛得住。
            if ((DateTime.UtcNow - lastProgLog).TotalMilliseconds >= 2500)
            {
                lastProgLog = DateTime.UtcNow;
                Append("  ▸ " + (string.IsNullOrEmpty(label) ? (((int)Math.Round(pct)) + "%") : label));
            }
        }

        private void HandleStep(string body)
        {
            string[] p = body.Split('|');
            if (p.Length < 3) return;
            int n2, tot;
            if (!int.TryParse(p[0], out n2)) return;
            if (!int.TryParse(p[1], out tot) || tot <= 0) return;

            ProgBox.Visibility = Visibility.Visible;
            TxtProgStep.Text = "步骤 " + n2 + "/" + tot + " · " + p[2];
            Append("");
            Append("▸ 步骤 " + n2 + "/" + tot + "  " + p[2]);
        }

        private void HandleDone(string body)
        {
            string[] p = body.Split('|');
            string state = p.Length >= 1 ? p[0] : "ok";
            string msg = p.Length >= 2 ? p[1] : "";

            if (state == "ok")
            {
                BarProg.IsIndeterminate = false;
                BarProg.Value = 100;
                TxtProgPct.Text = "100%";
                TxtProgStep.Text = string.IsNullOrEmpty(msg) ? "已完成" : msg;
            }
            else if (state == "cancel")
            {
                TxtProgStep.Text = "已取消";
            }
            else
            {
                TxtProgStep.Text = string.IsNullOrEmpty(msg) ? "执行失败" : ("失败：" + msg);
            }
        }

        // 日志用 RichTextBox 渲染（按行前缀着色），所以要做环形缓冲：
        // 一次全量扫描能堆上万行，无上限增长会让后期滚动明显掉帧。
        private const int MaxLogChars = 150000;   // 400k 时 RichTextBox 光排版就要几百 MB，长任务会卡
        private int logChars = 0;
        private Paragraph logPara;
        private readonly List<KeyValuePair<string, Brush>> logLines = new List<KeyValuePair<string, Brush>>();

        /// <summary>
        /// 判断日志该不该跟着新内容走。
        ///
        /// 关键是区分两种「变化」：
        ///   · VerticalOffset 变了  → 是人滚的（拖滚动条 / 滚轮 / PageUp 键）
        ///   · 只有 ExtentHeight 变了 → 是追加了新内容导致内容变长，不是人滚的
        /// 如果不区分，追加内容会让「离底部还有多远」变大，从而误判成
        /// 「用户离开了底部」，自动滚动就永久失效了。
        /// </summary>
        private void Log_ScrollChanged(object sender, ScrollChangedEventArgs e)
        {
            try
            {
                if (e.ExtentHeight <= e.ViewportHeight + 1)
                {
                    // 内容还没撑满一屏，谈不上跟不跟
                    logPinned = true;
                    logLastOffset = e.VerticalOffset;
                    return;
                }

                bool userScrolled = Math.Abs(e.VerticalOffset - logLastOffset) > 0.5;
                logLastOffset = e.VerticalOffset;
                if (!userScrolled) return;

                double bottom = e.ExtentHeight - e.ViewportHeight;
                // 离底部 3px 以内就算「贴底」，给浮点和行高留点余量
                logPinned = (bottom - e.VerticalOffset) <= 3.0;
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        // ---------------------------------------------------------------- 会话日志
        // 界面里这份日志只在内存里：程序崩溃 / 被任务管理器杀掉就全没了，
        // 用户事后只能说"它就是不动了"。所以同时落一份到 data\logs\，滚动保留 5 份。
        private static StreamWriter sessionLog;
        private static int sessionLogLines;

        private static void LogToFile(string line)
        {
            try
            {
                if (sessionLog == null)
                {
                    string dir = Path.Combine(ScriptHost.DataDir, "logs");
                    Directory.CreateDirectory(dir);

                    // 只保留最近 4 份，加上本次最多 5 份
                    try
                    {
                        string[] old = Directory.GetFiles(dir, "session-*.log");
                        Array.Sort(old, StringComparer.Ordinal);
                        for (int i = 0; i < old.Length - 4; i++)
                        {
                            try { File.Delete(old[i]); } catch (Exception __ex) { Swallowed(__ex); }
                        }
                    }
                    catch (Exception __ex) { Swallowed(__ex); }

                    string p = Path.Combine(dir, "session-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
                    FileStream fs = new FileStream(p, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
                    sessionLog = new StreamWriter(fs, new UTF8Encoding(true));
                    sessionLog.AutoFlush = true;
                    sessionLogLines = 0;

                    string ver = Updater.CurrentVersion;
                    try { if (string.IsNullOrEmpty(ver)) ver = System.Reflection.Assembly.GetExecutingAssembly().GetName().Version.ToString(); } catch (Exception __ex) { Swallowed(__ex); }
                    sessionLog.WriteLine("==== " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")
                                        + "  版本 " + ver + "  构建 " + BuildStamp() + " ====");
                }

                sessionLog.Write(line);
                sessionLogLines++;
                if (sessionLogLines > 200000)      // 单次会话写到 20 万行就收手，别把磁盘写满
                {
                    try { sessionLog.Dispose(); } catch (Exception __ex) { Swallowed(__ex); }
                    sessionLog = null;
                }
            }
            catch { }
        }

        private static void CloseSessionLog()
        {
            try { if (sessionLog != null) { sessionLog.Dispose(); sessionLog = null; } } catch { }
        }

        private void Append(string s)
        {
            string line = (s ?? "") + "\n";
            Brush br = LineBrush(s);
            logLines.Add(new KeyValuePair<string, Brush>(line, br));
            logChars += line.Length;
            LogToFile(s ?? "");

            try
            {
                if (logPara == null) CreateLogDocument();
                Run r = new Run(line);
                if (br != null) r.Foreground = br;
                logPara.Inlines.Add(r);
            }
            catch (Exception __ex) { Swallowed(__ex); }

            // 超上限就一次丢掉最前面的 1/4，然后整段重建。
            // 为什么要重建：WPF 的 InlineCollection 从头部删除是 O(n)，逐行删会退化成 O(n²)。
            // 重建这件事大约每 10 万字符才发生一次，摊下来可以忽略。
            if (logChars > MaxLogChars && logLines.Count > 1)
            {
                int drop = logLines.Count / 4;
                if (drop < 1) drop = 1;
                logLines.RemoveRange(0, drop);
                RebuildLogDocument();
            }

            // 贴底才跟着滚；用户翻上去看历史时就别打扰他
            if (autoScroll && logPinned) { try { TxtLog.ScrollToEnd(); } catch (Exception __ex) { Swallowed(__ex); } }
        }

        private void CreateLogDocument()
        {
            logPara = new Paragraph();
            logPara.Margin = new Thickness(0);
            FlowDocument doc = new FlowDocument(logPara);
            doc.PagePadding = new Thickness(0);
            TxtLog.Document = doc;
        }

        private void RebuildLogDocument()
        {
            try
            {
                logChars = 0;
                CreateLogDocument();
                if (logLines.Count > 0)
                {
                    Run hint = new Run("[…前面的日志已省略…]\n");
                    hint.Foreground = Res("TextFillColorTertiaryBrush");
                    logPara.Inlines.Add(hint);
                }
                foreach (KeyValuePair<string, Brush> kv in logLines)
                {
                    Run r = new Run(kv.Key);
                    if (kv.Value != null) r.Foreground = kv.Value;
                    logPara.Inlines.Add(r);
                    logChars += kv.Key.Length;
                }

                // 整段重建后偏移全变了，把「贴底」判定重置回跟随状态
                logPinned = true;
                logLastOffset = -1;
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>
        /// 按行前缀给日志上色。脚本侧本来就有 [ok] / [!] / [x] 这些标记，
        /// 但输出被 Process 重定向之后 ANSI 颜色丢了，全是一个色，很难扫读。
        /// </summary>
        private Brush LineBrush(string s)
        {
            if (!string.IsNullOrEmpty(s))
            {
                string t = s.TrimStart();
                if (t.StartsWith("----") || t.StartsWith("[…")) return Res("TextFillColorTertiaryBrush");
                if (t.StartsWith("[x]") || t.StartsWith("[stderr]")) return Res("SystemFillColorCriticalBrush");
                if (t.StartsWith("[!]")) return Res("SystemFillColorCautionBrush");
                if (t.StartsWith("[ok]")) return Res("SystemFillColorSuccessBrush");
                if (t.StartsWith("▶") || t.StartsWith("▸")) return Res("AccentTextFillColorPrimaryBrush");
            }
            return Res("TextFillColorPrimaryBrush");
        }

        /// <summary>把整段日志取成纯文本（复制日志 / 导出用）</summary>
        private string LogText()
        {
            try
            {
                return new TextRange(TxtLog.Document.ContentStart, TxtLog.Document.ContentEnd).Text;
            }
            catch { return ""; }
        }

        // 结果表的行数上限。
        // 全量扫描会逐个 IP 送 ##IP##，一台机器两轮就是 2 万多个 —— 之前没有上限，
        // 跑 20 多分钟后进程吃到 700+ MB，界面开始卡。表格只是"看着有动静"，
        // 真正的候选清单在 data\*.csv 里（清单窗口读的是 CSV，不依赖这张表）。
        private const int MaxIpRows = 3000;

        private void FlushIpQueue()
        {
            if (ipClearPending)
            {
                ipClearPending = false;
                ipRows.Clear();
                ipMap.Clear();
                ipQueue.Clear();
                ipTotal = 0;
                TxtIpCount.Text = "";
                UpdateIpEmptyState();
                return;
            }
            if (ipQueue.Count == 0) return;

            // 超额先从头部丢一批（旧的、已经没意义的探测结果），一次丢 500 个摊薄开销
            if (ipRows.Count > MaxIpRows)
            {
                int drop = Math.Min(500, ipRows.Count - MaxIpRows / 2);
                for (int i = 0; i < drop; i++)
                {
                    IpRow old = ipRows[0];
                    ipMap.Remove(old.Group + "|" + old.Ip);
                    ipRows.RemoveAt(0);
                }
            }

            foreach (string[] p in ipQueue)
            {
                string key = p[0] + "|" + p[1];
                int lat, ok, tot, med, jit;
                int.TryParse(p[2], out lat);
                int.TryParse(p[3], out ok);
                int.TryParse(p[4], out tot);
                int.TryParse(p[5], out med);
                int.TryParse(p[6], out jit);
                string note = p[7];

                IpRow row;
                if (!ipMap.TryGetValue(key, out row))
                {
                    row = new IpRow { Group = p[0], Ip = p[1], OkTot = "", Med = "-", Jit = "-" };
                    ipMap[key] = row;
                    ipRows.Add(row);
                    ipTotal++;
                }
                row.LastLat = lat;
                row.Lat = lat >= 0 ? lat + " ms" : "失败";
                row.OkTot = ok + "/" + tot;
                row.Med = med > 0 ? med + " ms" : "-";
                row.Jit = jit >= 0 ? jit + " ms" : "-";
                row.Note = note;
                row.Fg = LatBrush(lat);
            }
            ipQueue.Clear();

            TxtIpCount.Text = "已出现 " + ipTotal + " 个 IP（表格只保留最近 " + MaxIpRows + " 个）";
            UpdateIpEmptyState();

            // 每条 IPC 都 ScrollIntoView 会强制布局；限到 ~400ms 一次
            if (autoScroll && ipRows.Count > 0 && (Environment.TickCount - ipScrollTick) > 400)
            {
                ipScrollTick = Environment.TickCount;
                try { GridIp.ScrollIntoView(ipRows[ipRows.Count - 1]); } catch (Exception __ex) { Swallowed(__ex); }
            }
        }

        private int ipScrollTick = 0;

        // ------------------------------------------------------------------
        // 长任务收尾时把内存还一点回去。
        // 现象：跑完一次全量扫描（2 万多个 IP）后进程常驻 700 MB+，之后开什么都有点钝。
        // 那是 .NET 的堆 + WPF 的排版缓存，不会自己吐回给系统；跑完/停止时主动压一次。
        // 只在占用超过 400 MB 时做，避免每次小任务都去抖一下。
        // ------------------------------------------------------------------
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        private static extern bool SetProcessWorkingSetSize(IntPtr proc, IntPtr min, IntPtr max);

        private static void TrimMemory()
        {
            try
            {
                long mb = Process.GetCurrentProcess().WorkingSet64 / (1024 * 1024);
                if (mb < 400) return;

                System.Threading.Tasks.Task.Run(delegate
                {
                    try
                    {
                        GC.Collect(2, GCCollectionMode.Forced, true);
                        GC.WaitForPendingFinalizers();
                        GC.Collect(2, GCCollectionMode.Forced, true);
                    }
                    catch (Exception __ex) { Swallowed(__ex); }

                    try
                    {
                        using (Process p = Process.GetCurrentProcess())
                        {
                            SetProcessWorkingSetSize(p.Handle, new IntPtr(-1), new IntPtr(-1));
                        }
                    }
                    catch (Exception __ex) { Swallowed(__ex); }
                });
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        // ====================================================================
        //  设置页
        // ====================================================================
        private bool themeChoiceSyncing = false;

        private void RefreshSettingsUi()
        {
            try
            {
                UiStateData s = UiState.Current;

                // 刷新控件状态时 Checked 也会触发 —— 用一个标志避免被当成用户操作
                themeChoiceSyncing = true;
                if (!s.ManualTheme) RbThemeSystem.IsChecked = true;
                else if (s.Dark) RbThemeDark.IsChecked = true;
                else RbThemeLight.IsChecked = true;
                themeChoiceSyncing = false;

                CkRememberWindow.IsChecked = s.RememberWindow;
                CkTray.IsChecked = s.MinimizeToTray;
                SyncScaleRadios();

                TxtSettingsInfo.Text =
                    "程序目录：" + ScriptHost.RootDir + "\r\n" +
                    "数据目录：" + ScriptHost.DataDir + "\r\n" +
                    "界面状态：" + UiState.FilePath + (File.Exists(UiState.FilePath) ? "" : "（还没生成）") + "\r\n" +
                    "内置脚本：" + ScriptHost.ScriptNames.Count + " 个（运行时解压到 %TEMP%，退出时自动清理）";
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>
        /// 应用界面缩放。
        ///
        /// 为什么用 LayoutTransform 而不是改每个控件的 FontSize：
        ///   缩放要同时照顾「窗口太大」和「字太大」，一个个控件调字号会漏、而且布局
        ///   间距不会跟着缩。整棵树套一个 ScaleTransform，字体 + 间距 + 控件尺寸
        ///   一起等比缩，一个开关解决两件事。
        ///
        /// resizeWindow=true 时窗口尺寸也跟着缩 —— 否则缩了内容但窗口还是那么大，
        /// 白白浪费一块空白，而且缩到 0.8 之后窗口没法再变小（MinWidth 卡着）。
        /// </summary>
        private void ApplyUiScale(double k, bool resizeWindow)
        {
            if (k < 0.6) k = 0.6;
            if (k > 1.4) k = 1.4;

            double old = uiScale;
            uiScale = k;

            try
            {
                if (RootScale != null)
                    RootScale.LayoutTransform = new ScaleTransform(k, k);

                MinWidth = BaseMinW * k;
                MinHeight = BaseMinH * k;

                if (resizeWindow && old > 0.01 && Math.Abs(old - k) > 0.001)
                {
                    Width = Math.Max(MinWidth, Math.Round(Width / old * k));
                    Height = Math.Max(MinHeight, Math.Round(Height / old * k));
                }

                // 标题栏高度是按 DIP 量出来的，缩放变了必须重新量，
                // 否则日志的 MaxHeight 会用错一个值。
                _collapsedHeader = 0;
                ClampLogHeight();
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        private void ScaleChoice_Checked(object sender, RoutedEventArgs e)
        {
            if (scaleChoiceSyncing) return;
            try
            {
                double k = 0.9;
                if (RbScaleS != null && RbScaleS.IsChecked == true) k = 0.8;
                else if (RbScaleL != null && RbScaleL.IsChecked == true) k = 1.0;

                ApplyUiScale(k, true);
                UiState.Current.UiScale = k;
                UiState.Touch();
                Append("[设置] 界面缩放：" + (k * 100).ToString("0") + "%");
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>把单选按钮刷成当前缩放值（刷新时也会触发 Checked，用标志挡掉）</summary>
        private void SyncScaleRadios()
        {
            try
            {
                if (RbScaleS == null) return;
                scaleChoiceSyncing = true;
                if (Math.Abs(uiScale - 0.8) < 0.01) RbScaleS.IsChecked = true;
                else if (Math.Abs(uiScale - 1.0) < 0.01) RbScaleL.IsChecked = true;
                else RbScaleM.IsChecked = true;
            }
            catch (Exception __ex) { Swallowed(__ex); }
            finally { scaleChoiceSyncing = false; }
        }

        /// <summary>三选一主题：跟随系统 / 浅色 / 深色</summary>
        private void ThemeChoice_Checked(object sender, RoutedEventArgs e)
        {
            if (themeChoiceSyncing) return;
            try
            {
                UiStateData s = UiState.Current;
                string label;

                if (RbThemeSystem != null && RbThemeSystem.IsChecked == true)
                {
                    s.ManualTheme = false;
                    label = "跟随系统";

                    // 交回系统：重新挂上监听，并立刻按当前系统主题应用一次
                    try { SystemThemeWatcher.Watch(this, WindowBackdropType.Mica, true); } catch (Exception __ex) { Swallowed(__ex); }

                    ApplicationTheme t = ApplicationTheme.Dark;
                    try
                    {
                        SystemTheme st = ApplicationThemeManager.GetSystemTheme();
                        t = (st == SystemTheme.Light) ? ApplicationTheme.Light : ApplicationTheme.Dark;
                    }
                    catch (Exception __ex) { Swallowed(__ex); }

                    isDark = (t == ApplicationTheme.Dark);
                    App.ApplyTheme(t);
                }
                else
                {
                    bool dark = (RbThemeDark != null && RbThemeDark.IsChecked == true);
                    label = dark ? "深色" : "浅色";

                    // 手动选过就不再跟随系统，并且记下来，下次启动也保持
                    try { SystemThemeWatcher.UnWatch(this); } catch (Exception __ex) { Swallowed(__ex); }

                    isDark = dark;
                    s.ManualTheme = true;
                    s.Dark = dark;
                    App.ApplyTheme(dark ? ApplicationTheme.Dark : ApplicationTheme.Light);
                }

                // 主题换完，IP 行的颜色要重新取（之前拿的是旧主题的刷子）
                foreach (IpRow r in ipRows) r.Fg = LatBrush(r.LastLat);
                UiState.Touch();
                SyncThemeIcon();
                Append("[设置] 主题：" + label);
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        private void CkTray_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                UiState.Current.MinimizeToTray = (CkTray.IsChecked == true);
                UiState.Touch();
                Append("[设置] 最小化时缩到托盘：" + (CkTray.IsChecked == true ? "开" : "关"));
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        // ====================================================================
        //  托盘
        // ====================================================================
        private void InstallTray()
        {
            try
            {
                tray = new TrayIcon(this);
                tray.Install();
                if (!tray.Installed)
                {
                    Append("[警告] 托盘图标没建起来，最小化会留在任务栏（详情见 data\\error.log）");
                    tray = null;
                }
            }
            catch (Exception __ex)
            {
                Swallowed(__ex);
                tray = null;
            }
        }

        /// <summary>把窗口从托盘里叫回来</summary>
        public void ShowFromTray()
        {
            try
            {
                Show();
                if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
                Activate();
                // WPF 下抢前台焦点常见的两下小技巧
                Topmost = true;
                Topmost = false;
                Focus();
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>托盘菜单里的「退出」。有任务在跑就先露个面，好让确认框有归属窗口</summary>
        public void ExitFromTray()
        {
            try
            {
                if (ctx != null && ctx.P != null && !ctx.P.HasExited) ShowFromTray();
                Close();
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>托盘菜单里直达某个页面</summary>
        public void StartNavByKey(string key)
        {
            try
            {
                int idx;
                if (!navIndex.TryGetValue(key, out idx)) return;
                navSel = idx;
                ApplyNav();
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        /// <summary>托盘菜单里的「清单选用」</summary>
        public void OpenPickerFromTray()
        {
            try { OpenPicker(); } catch (Exception __ex) { Swallowed(__ex); }
        }

        private void HideToTray()
        {
            try
            {
                Hide();
                UiStateData s = UiState.Current;
                if (!s.TrayHintShown)
                {
                    s.TrayHintShown = true;
                    UiState.Touch();
                    if (tray != null) tray.Balloon("VRChat优选工具", "已经缩到托盘里了。双击托盘图标就能叫回来。");
                }
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        private void CkRememberWindow_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                UiState.Current.RememberWindow = (CkRememberWindow.IsChecked == true);
                UiState.Touch();
                Append("[设置] 记住窗口大小位置：" + (CkRememberWindow.IsChecked == true ? "开" : "关"));
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        private void BtnOpenData_Click(object sender, RoutedEventArgs e)
        {
            try
            {
                Directory.CreateDirectory(ScriptHost.DataDir);
                Process.Start("explorer.exe", ScriptHost.DataDir);
            }
            catch (Exception __ex)
            {
                Swallowed(__ex);
                Ui.Error("打开数据目录失败：" + __ex.Message, "失败");
            }
        }

        private void BtnResetUi_Click(object sender, RoutedEventArgs e)
        {
            if (!Ui.Confirm(
                "会清掉记住的窗口大小 / 位置、说明卡显隐、抽屉展开状态、主题选择。\r\n\r\n" +
                "下次启动回到默认样子。\r\n" +
                "不影响扫描 / 实测缓存，也不动 hosts 和系统服务。\r\n\r\n确认重置？",
                "重置界面状态")) return;

            try
            {
                // 内存里的缓存也要一起清，否则退出时 Save() 会把旧值原样写回去
                UiState.Reset();
                Append("[设置] 界面状态已重置，下次启动生效。");
            }
            catch (Exception __ex)
            {
                Swallowed(__ex);
                Ui.Error("重置失败：" + __ex.Message, "失败");
                return;
            }
            RefreshSettingsUi();
        }

        // ====================================================================
        //  「关闭加速服务」—— 破坏性操作，必须把后果讲透
        //
        //  为什么需要它：有些用户要临时让出网络（例如改用 TUN 模式代理），
        //  需要把 winws 停掉。
        //
        //  为什么标红 + 长文案：2026-10-18 真机实测确认 ——
        //  WinDivert 驱动被停止后，它在 BFE 内核里注册的 WFP 对象不会释放，
        //  再启动服务必然报 FWP_E_IN_USE（0x8032000A）。
        //  试过：sc stop/delete 驱动、卸服务、重启 BFE、直接调 WFP API 删除、
        //  退出杀软 —— 全部无效，**只有重启电脑能清**。
        //  所以这里的"确定"等于"我接受接下来要重启一次"。
        // ====================================================================
        private void BtnStopSvc_Click(object sender, RoutedEventArgs e)
        {
            if (!Ui.ConfirmDanger(
                "这会停止 VRChatBypass 加速服务。停止后：\r\n" +
                "  · VRChat 的 API、资源下载、官网都不可达，游戏进不去；\r\n" +
                "  · 想恢复必须**重启电脑** —— WinDivert 驱动停止后会残留内核对象，\r\n" +
                "    再启动服务会报 FWP_E_IN_USE，软件层清不掉（实测过）。\r\n\r\n" +
                "这个操作只适合「我要临时换成别的网络方案」的场景。\r\n\r\n" +
                "确定要关闭吗？", "关闭加速服务（关闭后需重启电脑恢复）"))
                return;

            try
            {
                SetBusy(true);
                Append("---- 正在停止加速服务 ----");

                RunHidden(SystemTool("sc.exe"), "stop VRChatBypass", 15000);
                System.Threading.Thread.Sleep(1800);

                string q = RunCapture(SystemTool("sc.exe"), "query VRChatBypass", 8000) ?? "";
                if (q.Contains("RUNNING"))
                {
                    Append("---- 停止失败：服务仍在运行（可能有进程占用）。----");
                    Ui.Warn("服务仍在运行，没有停掉。\r\n\r\n可以稍后重试，或用「导出诊断包」把状态发出来。",
                            "停止失败");
                    return;
                }

                Append("---- 加速服务已停止 ----");
                Append("要恢复：重启电脑后，打开本工具点【安装】（组件不用重新下载）。");
                Append("如果现在就想恢复，直接重启也是最快的。");

                Ui.Warn("加速服务已停止。\r\n\r\n" +
                        "VRChat 现在进不去（API/资源不可达）。\r\n" +
                        "要恢复：**重启电脑** → 打开本工具点【安装】。\r\n\r\n" +
                        "（这是 WinDivert 驱动的限制，不是本工具的 bug：停止后内核对象不释放，\r\n" +
                        "  再启动会报 FWP_E_IN_USE，只有重启能清。）",
                        "已停止 —— 恢复需要重启电脑");
            }
            catch (Exception __ex)
            {
                Swallowed(__ex);
                Append("---- 停止服务时出错：" + __ex.Message + " ----");
                Ui.Error("停止失败：" + __ex.Message, "失败");
            }
            finally
            {
                SetBusy(false);
            }
        }

        // ====================================================================
        //  一键导出诊断包
        //
        //  远程排障时最耗时的就是来回问「你机器上现在什么状态」。
        //  这里把需要的东西一次性打包：运行日志 / hosts / 服务与驱动状态 /
        //  目录清单（带每个文件的 SHA256 前 12 位）/ 系统信息 / error.log。
        // ====================================================================
        private async void BtnDiag_Click(object sender, RoutedEventArgs e)
        {
            string work = Path.Combine(Path.GetTempPath(), "vrctool-diag-" + Guid.NewGuid().ToString("N").Substring(0, 8));
            try
            {
                string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
                Directory.CreateDirectory(work);

                // 1) 运行日志（界面上这一份，含"[…前面的日志已省略…]"标记）
                File.WriteAllText(Path.Combine(work, "运行日志.txt"), LogText(), new UTF8Encoding(true));

                // 2) hosts（带行号，便于对照）
                try
                {
                    string hp = HostsPath;
                    if (File.Exists(hp))
                    {
                        string[] hl = File.ReadAllLines(hp);
                        StringBuilder hb = new StringBuilder();
                        for (int i = 0; i < hl.Length; i++)
                            hb.Append((i + 1).ToString("D4")).Append(": ").AppendLine(hl[i]);
                        File.WriteAllText(Path.Combine(work, "hosts.txt"), hb.ToString(), new UTF8Encoding(true));
                    }
                    else
                    {
                        File.WriteAllText(Path.Combine(work, "hosts.txt"), "(读不到 " + hp + ")", new UTF8Encoding(true));
                    }
                }
                catch (Exception __ex) { Swallowed(__ex); }

                // 3) 服务 / 驱动 / 进程
                StringBuilder sc = new StringBuilder();
                foreach (string n in new string[] { "VRChatBypass", "WinDivert" })
                {
                    sc.AppendLine("===== sc.exe qc " + n + " =====");
                    sc.AppendLine(CaptureText("sc.exe", "qc " + n));
                    sc.AppendLine();
                }
                sc.AppendLine("===== tasklist winws.exe =====");
                sc.AppendLine(CaptureText("tasklist.exe", "/FI \"IMAGENAME eq winws.exe\""));
                File.WriteAllText(Path.Combine(work, "服务与驱动.txt"), sc.ToString(), new UTF8Encoding(true));

                // 4) 目录清单 + 组件哈希
                //    这一步最慢（每个文件算一遍 SHA256），放后台线程，别把界面钉住。
                string dirText = await System.Threading.Tasks.Task.Run(delegate
                {
                    StringBuilder lsb = new StringBuilder();
                    foreach (string d in new string[] { ScriptHost.RootDir, ScriptHost.ToolsDir, ScriptHost.DataDir })
                    {
                        lsb.AppendLine("===== " + d + " =====");
                        try
                        {
                            if (Directory.Exists(d))
                            {
                                foreach (string f in Directory.GetFiles(d))
                                {
                                    FileInfo fi = new FileInfo(f);
                                    lsb.AppendLine(string.Format("{0,-44} {1,14:N0} B  {2:yyyy-MM-dd HH:mm}  sha256:{3}",
                                        fi.Name, fi.Length, fi.LastWriteTime, Sha256Head(f)));
                                }
                                foreach (string sub in Directory.GetDirectories(d))
                                    lsb.AppendLine("[DIR] " + Path.GetFileName(sub));
                            }
                            else
                            {
                                lsb.AppendLine("(不存在)");
                            }
                        }
                        catch (Exception __ex) { Swallowed(__ex); }
                        lsb.AppendLine();
                    }
                    return lsb.ToString();
                });
                File.WriteAllText(Path.Combine(work, "目录清单.txt"), dirText, new UTF8Encoding(true));

                // 5) 系统信息
                StringBuilder sys = new StringBuilder();
                sys.AppendLine("时间        : " + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));
                sys.AppendLine("程序目录    : " + ScriptHost.RootDir);
                sys.AppendLine("数据目录    : " + ScriptHost.DataDir);
                sys.AppendLine("OS          : " + Environment.OSVersion);
                sys.AppendLine("64 位进程   : " + Environment.Is64BitProcess);
                sys.AppendLine("管理员      : " + IsElevated());
                sys.AppendLine("运行时      : " + Environment.Version);
                sys.AppendLine("机器名      : " + Environment.MachineName);
                sys.AppendLine("内置脚本    : " + ScriptHost.ScriptNames.Count + " 个");
                // 用户报障时最常见的一句是"我装的是最新版吗" —— 把版本和构建时间写进诊断包
                try { sys.AppendLine("程序版本    : " + System.Reflection.Assembly.GetExecutingAssembly().GetName().Version); }
                catch (Exception __ex) { Swallowed(__ex); }
                sys.AppendLine("构建时间    : " + BuildStamp());
                try
                {
                    sys.AppendLine("主屏        : " + SystemParameters.PrimaryScreenWidth + " x " + SystemParameters.PrimaryScreenHeight);
                    sys.AppendLine("工作区      : " + SystemParameters.WorkArea);
                }
                catch (Exception __ex) { Swallowed(__ex); }
                if (!string.IsNullOrEmpty(ScriptHost.LastError)) sys.AppendLine("ScriptHost  : " + ScriptHost.LastError);
                File.WriteAllText(Path.Combine(work, "系统信息.txt"), sys.ToString(), new UTF8Encoding(true));

                // 6) error.log（如果有）
                try
                {
                    string el = Path.Combine(ScriptHost.DataDir, "error.log");
                    if (File.Exists(el)) File.Copy(el, Path.Combine(work, "error.log"), true);
                }
                catch (Exception __ex) { Swallowed(__ex); }

                // 打包（压缩也放后台，几十 MB 的目录在慢机器上要好几秒）
                Directory.CreateDirectory(ScriptHost.DataDir);
                string zip = Path.Combine(ScriptHost.DataDir, "诊断包-" + stamp + ".zip");
                if (File.Exists(zip)) File.Delete(zip);
                string workDir = work;
                await System.Threading.Tasks.Task.Run(delegate { ZipFile.CreateFromDirectory(workDir, zip); });

                Append("[设置] 诊断包已导出：" + zip);
                try { Process.Start(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"), "/select,\"" + zip + "\""); } catch (Exception __ex) { Swallowed(__ex); }

                Ui.Info("诊断包已导出：\r\n\r\n" + zip +
                        "\r\n\r\n里面有运行日志、hosts、服务与驱动状态、目录清单（带哈希）和系统信息。\r\n" +
                        "把这个 zip 发出去就能定位大部分问题。", "导出完成");
            }
            catch (Exception __ex)
            {
                Swallowed(__ex);
                Ui.Error("导出诊断包失败：" + __ex.Message, "失败");
            }
            finally
            {
                try { if (Directory.Exists(work)) Directory.Delete(work, true); } catch (Exception __ex) { Swallowed(__ex); }
            }
        }

        /// <summary>跑一个外部命令并把输出捞回来（诊断包用）</summary>
        private static string CaptureText(string file, string args)
        {
            string text = RunCapture(file, args, 8000);
            return string.IsNullOrEmpty(text) ? "(无输出 / 调用失败)" : text;
        }

        /// <summary>本程序 exe 的构建时间（写进诊断包，用来判断用户装的是哪一版）</summary>
        private static string BuildStamp()
        {
            try
            {
                string exe = Path.Combine(AppContext.BaseDirectory, "VRChat优选工具.exe");
                if (File.Exists(exe)) return File.GetLastWriteTime(exe).ToString("yyyy-MM-dd HH:mm");
            }
            catch (Exception __ex) { Swallowed(__ex); }
            return "未知";
        }

        /// <summary>文件 SHA256 的前 12 位（诊断包里列组件用，够对照了）</summary>
        private static string Sha256Head(string path)
        {
            try
            {
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
                {
                    byte[] h = sha.ComputeHash(fs);
                    StringBuilder sb = new StringBuilder();
                    for (int i = 0; i < 6 && i < h.Length; i++) sb.Append(h[i].ToString("x2"));
                    return sb.ToString();
                }
            }
            catch (Exception __ex) { Swallowed(__ex); return "------------"; }
        }

        // ====================================================================
        //  IP 结果：过滤 + 空状态
        // ====================================================================
        private bool IpFilter(object o)
        {
            IpRow r = o as IpRow;
            if (r == null) return false;

            string q = (TxtFilter == null ? "" : TxtFilter.Text).Trim();
            if (q.Length == 0) return true;

            return Has(r.Ip, q) || Has(r.Group, q) || Has(r.Note, q)
                || Has(r.Lat, q) || Has(r.Med, q) || Has(r.Jit, q) || Has(r.OkTot, q);
        }

        private static bool Has(string s, string q)
        {
            return !string.IsNullOrEmpty(s) && s.IndexOf(q, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        /// <summary>焦点是否在输入类控件上（这些控件里按 F5 不该触发"开始执行"）</summary>
        private static bool IsTypingTarget(object el)
        {
            return el is System.Windows.Controls.Primitives.TextBoxBase;
        }

        /// <summary>
        /// 校验 IPv4 字面量。
        /// 候选清单读的是 data\latency-result.csv —— 一个可以被任何本用户进程改写的文件。
        /// 这个值会被拼进以管理员身份执行的 PowerShell 命令行，所以必须在这里挡住，
        /// 不能指望脚本里那句正则（那时候注入已经执行完了）。
        /// </summary>
        private static bool IsIPv4(string s)
        {
            if (string.IsNullOrEmpty(s)) return false;
            string t = s.Trim();
            if (t.Length != s.Length) return false;      // 带空白的直接拒

            System.Net.IPAddress a;
            if (!System.Net.IPAddress.TryParse(t, out a)) return false;
            return a.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork;
        }

        private void TxtFilter_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (ipView == null) return;      // InitializeComponent 阶段会先触发一次
            ipView.Refresh();
            UpdateIpEmptyState();
        }

        /// <summary>没有数据 / 过滤后没匹配时，在表格位置显示一句说明而不是一片空白</summary>
        private void UpdateIpEmptyState()
        {
            try
            {
                if (TxtEmptyIp == null) return;

                bool hasAny = ipRows.Count > 0;
                bool empty = (ipView == null) ? !hasAny : ipView.IsEmpty;
                TxtEmptyIp.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;

                string q = (TxtFilter == null ? "" : TxtFilter.Text).Trim();
                if (empty)
                {
                    TxtEmptyIp.Text = (hasAny && q.Length > 0)
                        ? "没有匹配「" + q + "」的行。清掉过滤框就能看到全部 " + ipRows.Count + " 行。"
                        : "执行后会逐个显示候选 IP 的延迟、成功率和抖动。";
                }

                if (TxtFilterCount != null)
                {
                    int shown = (ipView == null) ? ipRows.Count : ipView.Cast<object>().Count();
                    TxtFilterCount.Text = hasAny ? ("显示 " + shown + " / " + ipRows.Count + " 行") : "";
                }
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        // ====================================================================
        /// <summary>
        /// 刷新侧栏状态条。
        ///
        /// 整个过程（两次 sc.exe + 读 hosts）都在**后台线程**上跑：
        /// 原来是在 UI 线程上同步 StandardOutput.ReadToEnd()，每 5 秒卡一次界面
        /// （最坏情况两次串起来能卡 6 秒，表现就是滚动/拖动时一顿一顿）。
        /// </summary>
        private void RefreshStatus()
        {
            if (statusBusy) return;      // 上一拍还没回来就跳过，别堆积
            statusBusy = true;

            System.Threading.Tasks.Task.Run(delegate
            {
                bool svc = false, drv = false;
                List<string> a = new List<string>();
                List<string> b = new List<string>();
                try
                {
                    svc = ServiceRunning("VRChatBypass");
                    drv = ServiceRunning("WinDivert");
                    a = HostsIps("api.vrchat.cloud");
                    b = HostsIps("files.vrchat.cloud");
                }
                catch (Exception __ex) { Swallowed(__ex); }

                Dispatcher.BeginInvoke(new Action(delegate
                {
                    statusBusy = false;
                    ApplyStatus(svc, drv, a, b);
                }));
            });
        }

        private void ApplyStatus(bool svc, bool drv, List<string> a, List<string> b)
        {
            try
            {
                if (TxtSidebar == null) return;

                string ta = (a.Count == 0) ? "—" : a[0];
                string tb = (b.Count == 0) ? "—" : b[0];
                if (a.Count > 1) ta += "（" + a.Count + " 条）";
                if (b.Count > 1) tb += "（" + b.Count + " 条）";

                // 服务/驱动没跑、hosts 里也没有我们的块 —— 那是「还没装」，不是「坏了」。
                // 以前一律写「未运行」，用户一看就以为程序出问题了（其实只是还没点安装）。
                bool installed = (a.Count > 0 || b.Count > 0);
                string svcTxt = svc ? "运行中" : (installed ? "未运行" : "未安装");
                string drvTxt = drv ? "运行中" : (installed ? "未运行" : "未安装");

                // 三行排布：248px 宽的侧栏里硬塞一行会挤成一团
                TxtSidebar.Text =
                    "服务 " + svcTxt +
                    " · 驱动 " + drvTxt +
                    "\r\nA 组 " + ta +
                    "\r\nB 组 " + tb;
                TxtSidebar.Foreground = (svc && drv)
                    ? (Brush)Res("SystemFillColorSuccessBrush")
                    : (Brush)Res("TextFillColorTertiaryBrush");
            }
            catch (Exception __ex) { Swallowed(__ex); }
        }

        private bool ServiceRunning(string name)
        {
            string o = RunCapture(SystemTool("sc.exe"), "query " + name, 3000);
            return o.IndexOf("RUNNING", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        private static string HostsPath
        {
            get
            {
                string sys = Environment.GetFolderPath(Environment.SpecialFolder.System);
                return Path.Combine(sys, @"drivers\etc\hosts");
            }
        }

        /// <summary>读 hosts 里某个域名对应的 IP（第一条）</summary>
        private string HostsIp(string host)
        {
            List<string> v = HostsIps(host);
            return v.Count > 0 ? v[0] : "";
        }

        /// <summary>
        /// 读 hosts 里某个域名对应的**全部** IP。
        ///
        /// 原来只跳过以 # 开头的整行，两个问题：
        ///   · 行内注释不认 —— `1.2.3.4 api.vrchat.cloud # 临时` 会多出一条
        ///   · 同名多条记录只取第一条，界面看不出"重复了"
        /// 这里先把行内 # 之后裁掉，再把所有匹配收集起来（多条会在侧栏标出来）。
        /// </summary>
        private List<string> HostsIps(string host)
        {
            List<string> r = new List<string>();
            try
            {
                foreach (string raw in File.ReadAllLines(HostsPath))
                {
                    string ln = raw;
                    int h = ln.IndexOf('#');
                    if (h >= 0) ln = ln.Substring(0, h);
                    ln = ln.Trim();
                    if (ln.Length == 0) continue;

                    string[] parts = ln.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length < 2) continue;
                    if (!parts[1].Equals(host, StringComparison.OrdinalIgnoreCase)) continue;
                    r.Add(parts[0]);
                }
            }
            catch (Exception __ex) { Swallowed(__ex); }
            return r;
        }

        // ====================================================================
        private void RunCacheClear()
        {
            List<string> args = new List<string>();
            int n = 0;
            long bytes = 0;
            foreach (CacheItem c in cacheItems)
            {
                if (!c.Checked) continue;
                args.Add("-" + c.Key);
                bytes += c.Bytes;
                n++;
            }
            if (n == 0)
            {
                Ui.Info("请先勾选要清理的类别。", "提示");
                return;
            }
            args.Add("-Yes");
            string sz = bytes >= 1048576
                ? (bytes / 1048576.0).ToString("0.00") + " MB"
                : (bytes / 1024.0).ToString("0.0") + " KB";

            if (!Ui.Confirm(
                "将清理 " + n + " 个类别，释放约 " + sz + "。\r\n\r\n" +
                "当前 hosts 配置和服务不受影响。\r\n" +
                "但扫描/实测缓存清掉后需要重新跑。\r\n\r\n确认清理？",
                "清理缓存")) return;

            RunScript("clear-cache.ps1", string.Join(" ", args.ToArray()), "清理缓存");
        }

        private void OpenPicker()
        {
            try
            {
                // 把 hosts 里当前生效的 A/B 组 IP 传进去，清单里对应行会标成绿色「当前生效」
                List<string> ca = HostsIps("api.vrchat.cloud");
                List<string> cb = HostsIps("files.vrchat.cloud");

                PickerWindow w = new PickerWindow(dataDir,
                    ca.Count > 0 ? ca[0] : "",
                    cb.Count > 0 ? cb[0] : "");
                w.Owner = this;
                bool? ok = w.ShowDialog();
                RefreshStatus();

                if (ok != true) return;

                // 清单窗口只负责"选"，真正写 hosts 回到这里跑 —— 这样日志进主界面、
                // 有进度条，也不会在清单窗口里同步等十几秒把窗口卡成"未响应"。
                List<string> args = new List<string>();
                if (!string.IsNullOrEmpty(w.ChosenA))
                {
                    if (!IsIPv4(w.ChosenA))
                    {
                        Ui.Error("候选清单里的 A 组 IP 不合法，已取消写入：\r\n" + w.ChosenA, "已取消");
                        return;
                    }
                    args.Add("-IpA " + w.ChosenA);
                }
                if (!string.IsNullOrEmpty(w.ChosenB))
                {
                    if (!IsIPv4(w.ChosenB))
                    {
                        Ui.Error("候选清单里的 B 组 IP 不合法，已取消写入：\r\n" + w.ChosenB, "已取消");
                        return;
                    }
                    args.Add("-IpB " + w.ChosenB);
                }
                if (args.Count == 0) return;

                RunScript("apply-selected.ps1", string.Join(" ", args.ToArray()), "写入 hosts");
            }
            catch (Exception ex)
            {
                Ui.WriteErrorLog("打开候选清单失败", ex);
                Ui.Error("打开清单失败：" + ex.Message, "错误");
            }
        }
    }
}
