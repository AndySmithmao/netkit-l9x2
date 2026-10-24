using System;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Wpf.Ui.Controls;
using Button = System.Windows.Controls.Button;
using TextBlock = System.Windows.Controls.TextBlock;
using Grid = System.Windows.Controls.Grid;
using RowDefinition = System.Windows.Controls.RowDefinition;
using StackPanel = System.Windows.Controls.StackPanel;
using ProgressBar = System.Windows.Controls.ProgressBar;
using Orientation = System.Windows.Controls.Orientation;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using VerticalAlignment = System.Windows.VerticalAlignment;
using FontWeights = System.Windows.FontWeights;
using TextWrapping = System.Windows.TextWrapping;
using TextBox = System.Windows.Controls.TextBox;

namespace VrcTool
{
    /// <summary>
    /// 应用更新弹窗。
    ///
    /// 设置页只留一个「检查更新」入口，版本对比、更新说明、下载进度和安装动作都放在这个窗口里：
    /// 说明文本可能很长，塞进设置卡片会把整页撑开；单独弹窗也更容易让用户看清"要不要更新"。
    ///
    /// 和 RegionWindow 一样用代码构建界面，省掉一份 BAML 资源的编码校验。
    /// </summary>
    internal sealed class UpdateWindow : FluentWindow
    {
        private readonly TextBlock txtCurrent = new TextBlock();
        private readonly TextBlock txtLatest = new TextBlock();
        private readonly TextBlock txtStatus = new TextBlock();
        private readonly ProgressBar bar = new ProgressBar();
        private readonly TextBox notes = new TextBox();
        private readonly Button btnInstall = new Button();
        private readonly Button btnRecheck = new Button();

        private UpdateInfo info;

        public UpdateWindow()
        {
            Title = "应用更新";
            Width = 520;
            Height = 430;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ResizeMode = ResizeMode.NoResize;   // 固定尺寸，避免盖住整页设置

            Grid root = new Grid { Margin = new Thickness(24) };
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // 标题
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // 版本
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // 状态
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // 进度
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // 说明
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // 按钮

            TextBlock title = new TextBlock
            {
                Text = "应用更新",
                FontSize = 18,
                FontWeight = FontWeights.SemiBold
            };
            Grid.SetRow(title, 0);
            root.Children.Add(title);

            Grid verGrid = new Grid { Margin = new Thickness(0, 12, 0, 0) };
            verGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
            verGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

            TextBlock lb1 = new TextBlock { Text = "当前版本", Margin = new Thickness(0, 0, 0, 4) };
            Grid.SetRow(lb1, 0);
            Grid.SetColumn(lb1, 0);
            verGrid.Children.Add(lb1);
            txtCurrent.Text = Updater.CurrentVersion;
            txtCurrent.FontWeight = FontWeights.SemiBold;
            Grid.SetRow(txtCurrent, 0);
            Grid.SetColumn(txtCurrent, 1);
            verGrid.Children.Add(txtCurrent);

            TextBlock lb2 = new TextBlock { Text = "最新版本", Margin = new Thickness(0, 6, 0, 0) };
            Grid.SetRow(lb2, 1);
            Grid.SetColumn(lb2, 0);
            verGrid.Children.Add(lb2);
            txtLatest.Text = "正在查询…";
            txtLatest.Margin = new Thickness(0, 6, 0, 0);
            Grid.SetRow(txtLatest, 1);
            Grid.SetColumn(txtLatest, 1);
            verGrid.Children.Add(txtLatest);

            verGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            verGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            Grid.SetRow(verGrid, 1);
            root.Children.Add(verGrid);

            txtStatus.Text = "";
            txtStatus.Margin = new Thickness(0, 10, 0, 0);
            txtStatus.TextWrapping = TextWrapping.Wrap;
            txtStatus.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
            Grid.SetRow(txtStatus, 2);
            root.Children.Add(txtStatus);

            bar.Height = 6;
            bar.Margin = new Thickness(0, 10, 0, 0);
            bar.Minimum = 0;
            bar.Maximum = 100;
            bar.Visibility = Visibility.Collapsed;
            Grid.SetRow(bar, 3);
            root.Children.Add(bar);

            notes.IsReadOnly = true;
            notes.TextWrapping = TextWrapping.Wrap;
            notes.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
            notes.Margin = new Thickness(0, 12, 0, 0);
            notes.FontSize = 12;
            notes.MaxHeight = 150;
            notes.FontFamily = new FontFamily("Consolas");
            notes.Visibility = Visibility.Collapsed;
            Grid.SetRow(notes, 4);
            root.Children.Add(notes);

            StackPanel buttons = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 14, 0, 0)
            };
            btnInstall.Content = "下载并安装";
            btnInstall.Width = 120;
            btnInstall.Height = 32;
            btnInstall.IsEnabled = false;
            btnInstall.Click += async (s, e) => await InstallAsync();
            btnRecheck.Content = "重新检查";
            btnRecheck.Width = 96;
            btnRecheck.Height = 32;
            btnRecheck.Margin = new Thickness(8, 0, 0, 0);
            btnRecheck.Click += async (s, e) => await CheckAsync(true);
            Button close = new Button { Content = "关闭", Width = 88, Height = 32, Margin = new Thickness(8, 0, 0, 0) };
            close.Click += (s, e) => Close();
            buttons.Children.Add(btnInstall);
            buttons.Children.Add(btnRecheck);
            buttons.Children.Add(close);
            Grid.SetRow(buttons, 5);
            root.Children.Add(buttons);

            Content = root;

            Loaded += async (s, e) => await CheckAsync(false);
        }

        /// <summary>查询更新并刷新界面；force = 忽略缓存。</summary>
        private async System.Threading.Tasks.Task CheckAsync(bool force)
        {
            btnInstall.IsEnabled = false;
            btnRecheck.IsEnabled = false;
            bar.Visibility = Visibility.Collapsed;
            txtLatest.Text = "正在查询…";
            txtStatus.Text = "";
            try
            {
                if (force) UpdateCache.Clear();
                info = await Updater.CheckAsync(CancellationToken.None, force);

                if (!string.IsNullOrEmpty(info.Error))
                {
                    txtLatest.Text = "查询失败";
                    txtStatus.Text = info.Error;
                    return;
                }

                txtLatest.Text = info.Version + (info.FromCache ? "（缓存）" : "");
                if (info.Newer)
                {
                    btnInstall.IsEnabled = true;
                    txtStatus.Text = "发现新版本 " + info.Tag +
                        (info.AssetSize > 0 ? "，安装包 " + Math.Round(info.AssetSize / 1048576.0, 1) + " MB" : "") +
                        "。更新会下载安装包、校验 SHA256，然后启动安装程序并退出本程序。";
                }
                else
                {
                    txtStatus.Text = "已经是最新版本。";
                }

                if (!string.IsNullOrEmpty(info.Notes))
                {
                    notes.Text = info.Notes;
                    notes.Visibility = Visibility.Visible;
                }
                else
                {
                    notes.Visibility = Visibility.Collapsed;
                }
            }
            catch (Exception ex)
            {
                txtLatest.Text = "查询失败";
                txtStatus.Text = ex.Message;
                DriverManager.Log("更新弹窗查询异常: " + ex);
            }
            finally
            {
                btnRecheck.IsEnabled = true;
            }
        }

        private async System.Threading.Tasks.Task InstallAsync()
        {
            if (info == null || !info.Newer) return;
            if (!Ui.Confirm("将下载 " + info.Tag + " 的安装包并启动安装程序。\r\n\r\n" +
                            "安装过程中本程序会退出，安装完成后请重新打开。\r\n\r\n继续吗？", "下载并安装更新"))
                return;

            btnInstall.IsEnabled = false;
            btnRecheck.IsEnabled = false;
            bar.Visibility = Visibility.Visible;
            bar.Value = 0;

            string dest = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "VrcTool-update-" + info.Version + ".exe");
            try
            {
                txtStatus.Text = "正在下载 " + info.AssetName + " …";
                Progress<int> prog = new Progress<int>(p =>
                {
                    try { bar.Value = p; txtStatus.Text = "正在下载… " + p + "%"; } catch { }
                });
                string err = await Updater.DownloadAsync(info, dest, prog, CancellationToken.None);
                if (!string.IsNullOrEmpty(err))
                {
                    txtStatus.Text = "下载失败：" + err;
                    bar.Visibility = Visibility.Collapsed;
                    btnInstall.IsEnabled = true;
                    btnRecheck.IsEnabled = true;
                    return;
                }

                txtStatus.Text = "下载完成，SHA256 已核对，正在启动安装程序…";
                DriverManager.Log("更新包已下载: " + dest + " SHA256=" + Updater.Sha256File(dest));
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(dest) { UseShellExecute = true });
                }
                catch (Exception ex)
                {
                    txtStatus.Text = "无法启动安装程序：" + ex.Message + "\r\n文件位置：" + dest;
                    btnInstall.IsEnabled = true;
                    btnRecheck.IsEnabled = true;
                    return;
                }

                await System.Threading.Tasks.Task.Delay(1200);
                Application.Current.Shutdown();
            }
            catch (Exception ex)
            {
                txtStatus.Text = "更新异常：" + ex.Message;
                DriverManager.Log("更新异常: " + ex);
                btnInstall.IsEnabled = true;
                btnRecheck.IsEnabled = true;
            }
        }
    }
}
