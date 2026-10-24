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
                TxtUpdateStatus.Text = "当前版本 " + Updater.CurrentVersion + "，点按钮查看最新版本与更新说明。";
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

                // 区域选择还没做完时不要弹更新框：两个模态会互相遮挡，点谁都不对
                if (regionDialogOpen)
                {
                    Append("[更新] 跳过本次检查（正在选择所在区域）");
                    return;
                }

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
                sb.AppendLine(Localization.T("发现可用更新："));
                sb.AppendLine();
                if (appNewer) sb.AppendLine("· " + Localization.T("应用") + "  " + Updater.CurrentVersion + " → " + app.Version);
                foreach (KernelUpdate k in newer) sb.AppendLine("· " + k.Name + "  " + k.Installed + " → " + k.Latest);
                sb.AppendLine();
                sb.AppendLine(Localization.T("要现在更新吗？"));
                sb.AppendLine("· 更新应用会下载安装包并退出本程序");
                sb.AppendLine("· 更新内核会自动备份旧文件，新版起不来会自动回滚");
                sb.AppendLine("· 选「否」= 本次不更新，下次启动再问");

                if (!Ui.Question(sb.ToString().Trim(), Localization.T("发现更新"))) { Append("[更新] 用户选择稍后更新"); return; }

                if (appNewer)
                {
                    lastUpdate = app;
                    ShowUpdateWindow();
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

        /// <summary>设置页的「检查更新」入口：打开独立更新窗口，版本 / 说明 / 进度都在窗口里。</summary>
        private void BtnCheckUpdate_Click(object sender, RoutedEventArgs e)
        {
            ShowUpdateWindow();
        }

        /// <summary>打开更新窗口。启动检查发现新版本时也走这里。</summary>
        private void ShowUpdateWindow()
        {
            try
            {
                UpdateWindow w = new UpdateWindow();
                w.Owner = this;
                w.ShowDialog();
                TxtUpdateStatus.Text = "当前版本 " + Updater.CurrentVersion;
                Append("[更新] 已打开更新窗口");
            }
            catch (Exception ex)
            {
                DriverManager.Log("打开更新窗口失败: " + ex.Message);
                TxtUpdateStatus.Text = "打开更新窗口失败：" + ex.Message;
            }
        }

        // ------------------------------------------------------------ 内核更新

        private async Task UpdateKernelsAsync(List<KernelUpdate> list)
        {
            if (updatingKernel) return;
            updatingKernel = true;
            BtnCheckUpdate.IsEnabled = false;
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
            }
        }
    }
}
