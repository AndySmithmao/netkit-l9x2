using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;

namespace VrcTool
{
    /// <summary>设置页「应用更新」界面 + 启动时的更新检查（应用 / mihomo / winws）。</summary>
    public partial class MainWindow
    {
        private UpdateInfo lastUpdate;
        private bool startupUpdateChecked;
        private bool updatingKernel;

        private void InitUpdateUi()
        {
            try
            {
                TxtAppVersion.Text = Updater.CurrentVersion;
                TxtUpdateStatus.Text = "点「检查更新」查询 GitHub Release。";
            }
            catch { }
        }

        // ------------------------------------------------------------ 启动检查

        /// <summary>
        /// 启动后延迟几秒做一次更新检查：应用 + mihomo + winws。
        /// 查到更新只弹窗询问，用户同意才下载安装 —— 绝不静默更新。
        /// </summary>
        private async Task RunStartupUpdateCheckAsync()
        {
            if (startupUpdateChecked) return;
            startupUpdateChecked = true;
            try
            {
                await Task.Delay(5000);

                Append("[更新] 检查应用与内核版本…");
                List<KernelUpdate> kernels = await KernelUpdater.CheckAsync(CancellationToken.None);
                UpdateInfo app = await Updater.CheckAsync(CancellationToken.None);

                List<KernelUpdate> newer = kernels.Where(k => k.Newer).ToList();
                bool appNewer = app.Newer && string.IsNullOrEmpty(app.Error);

                foreach (KernelUpdate k in kernels)
                    Append("[更新] " + k.Name + " 当前 " + (k.Installed.Length > 0 ? k.Installed : "?") +
                           " / 最新 " + (k.Latest.Length > 0 ? k.Latest : "查询失败") +
                           (k.Error.Length > 0 ? "（" + k.Error + "）" : ""));
                if (!string.IsNullOrEmpty(app.Error))
                    Append("[更新] 应用: " + app.Error.Replace("\r\n", " "));

                if (!appNewer && newer.Count == 0) return;

                System.Text.StringBuilder sb = new System.Text.StringBuilder();
                sb.AppendLine("发现可用更新：");
                sb.AppendLine();
                if (appNewer) sb.AppendLine("· 应用  " + Updater.CurrentVersion + " → " + app.Version);
                foreach (KernelUpdate k in newer) sb.AppendLine("· " + k.Name + "  " + k.Installed + " → " + k.Latest);
                sb.AppendLine();
                sb.AppendLine("要现在更新吗？");
                sb.AppendLine("· 更新应用会下载安装包并退出本程序");
                sb.AppendLine("· 更新内核会自动备份旧文件，新版起不来会自动回滚");
                sb.AppendLine("· 选「否」= 本次不更新，下次启动再问");

                if (!Ui.Question(sb.ToString().Trim(), "发现更新")) { Append("[更新] 用户选择稍后更新"); return; }

                if (appNewer)
                {
                    lastUpdate = app;
                    await InstallAppUpdateAsync(app);
                    return;
                }
                await UpdateKernelsAsync(newer);
            }
            catch (Exception ex)
            {
                Append("[更新] 检查异常: " + ex.Message);
                DriverManager.Log("启动更新检查异常: " + ex);
            }
        }

        // ------------------------------------------------------------ 应用更新

        private async void BtnCheckUpdate_Click(object sender, RoutedEventArgs e)
        {
            BtnCheckUpdate.IsEnabled = false;
            BtnDoSUpdate.IsEnabled = false;
            BarUpdate.Visibility = Visibility.Collapsed;
            TxtUpdateNotes.Visibility = Visibility.Collapsed;
            TxtUpdateStatus.Text = "正在查询 GitHub Release…";
            try
            {
                UpdateCache.Clear();   // 手动检查：强制刷新，不吃缓存
                lastUpdate = await Updater.CheckAsync(CancellationToken.None, true);
                if (!string.IsNullOrEmpty(lastUpdate.Error))
                {
                    TxtUpdateStatus.Text = "检查失败：" + lastUpdate.Error;
                    return;
                }
                TxtAppVersion.Text = Updater.CurrentVersion + "  →  最新 " + lastUpdate.Version;
                if (lastUpdate.Newer)
                {
                    BtnDoSUpdate.IsEnabled = true;
                    TxtUpdateStatus.Text = "发现新版本 " + lastUpdate.Tag +
                        (lastUpdate.AssetSize > 0 ? "（" + Math.Round(lastUpdate.AssetSize / 1048576.0, 1) + " MB）" : "") +
                        "，可下载并安装。";
                }
                else TxtUpdateStatus.Text = "已是最新版本（" + Updater.CurrentVersion + "）。";

                if (!string.IsNullOrEmpty(lastUpdate.Notes))
                {
                    TxtUpdateNotes.Text = lastUpdate.Notes;
                    TxtUpdateNotes.Visibility = Visibility.Visible;
                }
            }
            catch (Exception ex)
            {
                TxtUpdateStatus.Text = "检查异常：" + ex.Message;
                DriverManager.Log("更新检查异常: " + ex);
            }
            finally { BtnCheckUpdate.IsEnabled = true; }
        }

        private async void BtnDoUpdate_Click(object sender, RoutedEventArgs e)
        {
            if (lastUpdate == null || !lastUpdate.Newer) return;
            await InstallAppUpdateAsync(lastUpdate);
        }

        private async Task InstallAppUpdateAsync(UpdateInfo info)
        {
            BtnCheckUpdate.IsEnabled = false;
            BtnDoSUpdate.IsEnabled = false;
            BarUpdate.Visibility = Visibility.Visible;
            BarUpdate.Value = 0;
            string dest = Path.Combine(Path.GetTempPath(), "VrcTool-update-" + info.Version + ".exe");
            try
            {
                TxtUpdateStatus.Text = "正在下载 " + info.AssetName + " …";
                Append("[更新] 开始下载应用更新 " + info.Version);
                Progress<int> prog = new Progress<int>(p =>
                {
                    try { BarUpdate.Value = p; TxtUpdateStatus.Text = "正在下载… " + p + "%"; } catch { }
                });
                string err = await Updater.DownloadAsync(info, dest, prog, CancellationToken.None);
                if (!string.IsNullOrEmpty(err))
                {
                    TxtUpdateStatus.Text = "更新失败：" + err;
                    Append("[更新] 下载失败: " + err);
                    BarUpdate.Visibility = Visibility.Collapsed;
                    return;
                }
                TxtUpdateStatus.Text = "下载完成，SHA256 已核对，正在启动安装程序…";
                Append("[更新] 应用更新包已下载: " + dest);
                try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(dest) { UseShellExecute = true }); }
                catch (Exception ex)
                {
                    TxtUpdateStatus.Text = "无法启动安装程序：" + ex.Message + "\r\n文件位置：" + dest;
                    return;
                }
                await Task.Delay(1500);
                Application.Current.Shutdown();
            }
            catch (Exception ex)
            {
                TxtUpdateStatus.Text = "更新异常：" + ex.Message;
                DriverManager.Log("应用更新异常: " + ex);
            }
            finally { BtnCheckUpdate.IsEnabled = true; }
        }

        // ------------------------------------------------------------ 内核更新

        private async Task UpdateKernelsAsync(List<KernelUpdate> list)
        {
            if (updatingKernel) return;
            updatingKernel = true;
            BtnCheckUpdate.IsEnabled = false;
            BarUpdate.Visibility = Visibility.Visible;
            BarUpdate.IsIndeterminate = true;
            try
            {
                foreach (KernelUpdate k in list)
                {
                    TxtUpdateStatus.Text = "正在更新 " + k.Name + " " + k.Installed + " → " + k.Latest + " …";
                    Append("[更新] 更新 " + k.Name + " → " + k.Latest);
                    string err = k.Name == "mihomo"
                        ? await KernelUpdater.UpdateMihomoAsync(k, CancellationToken.None)
                        : await KernelUpdater.UpdateWinwsAsync(k, CancellationToken.None);
                    if (err.Length > 0)
                    {
                        Append("[更新] " + k.Name + " 失败: " + err.Replace("\r\n", " "));
                        Ui.Warn(k.Name + " 更新失败：\r\n" + err, "内核更新");
                    }
                    else
                    {
                        Append("[更新] " + k.Name + " 已更新到 " + k.Latest);
                        TxtUpdateStatus.Text = k.Name + " 已更新到 " + k.Latest;
                    }
                }
                RefreshKernelUi();
            }
            catch (Exception ex)
            {
                Append("[更新] 内核更新异常: " + ex.Message);
                DriverManager.Log("内核更新异常: " + ex);
            }
            finally
            {
                updatingKernel = false;
                BtnCheckUpdate.IsEnabled = true;
                BarUpdate.IsIndeterminate = false;
                BarUpdate.Visibility = Visibility.Collapsed;
            }
        }
    }
}
