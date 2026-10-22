using System;
using System.Windows;
using System.Windows.Controls;

namespace VrcTool
{
    /// <summary>界面语言切换：加载、保存、刷新可见文字。</summary>
    public partial class MainWindow
    {
        private bool syncingLanguage;

        /// <summary>启动时按保存的语言初始化下拉框和界面。</summary>
        private void InitLanguageUi()
        {
            try
            {
                string code = UiState.Current.Language;
                Localization.Current = Localization.Parse(code);

                if (CmbLanguage != null)
                {
                    syncingLanguage = true;
                    foreach (object item in CmbLanguage.Items)
                    {
                        ComboBoxItem ci = item as ComboBoxItem;
                        if (ci != null && string.Equals(ci.Tag as string, Localization.Code(Localization.Current), StringComparison.OrdinalIgnoreCase))
                        {
                            CmbLanguage.SelectedItem = ci;
                            break;
                        }
                    }
                    syncingLanguage = false;
                }

                DriverManager.Log("[i18n] 界面语言: " + Localization.Code(Localization.Current));
            }
            catch (Exception ex) { DriverManager.Log("[i18n] 初始化失败: " + ex.Message); }
        }

        /// <summary>把当前语言应用到整棵树（窗口内容已实体化之后再调用）。</summary>
        private void ApplyLanguage()
        {
            try
            {
                Localization.Apply(this);
                // 导航栏、页脚等不在可视树里的部分，单独再刷一次
                if (RootNav != null)
                {
                    Localization.Apply(RootNav);
                    foreach (object item in RootNav.MenuItems)
                    {
                        DependencyObject dep = item as DependencyObject;
                        if (dep != null) Localization.Apply(dep);
                    }
                }
            }
            catch (Exception ex) { DriverManager.Log("[i18n] 应用失败: " + ex.Message); }
        }

        private void CmbLanguage_SelectionChanged(object sender, SelectionChangedEventArgs e)
        {
            if (syncingLanguage || !uiReady) return;
            try
            {
                ComboBoxItem item = CmbLanguage.SelectedItem as ComboBoxItem;
                if (item == null) return;
                string code = item.Tag as string;
                UiLang lang = Localization.Parse(code);

                // 切回中文时，需要把已翻译的文字还原 —— 重新载入界面状态成本太高，
                // 这里提示用户重启一次，切到其他语言则即时生效。
                bool turningChinese = lang == UiLang.ChineseSimplified && Localization.Current != UiLang.ChineseSimplified;

                Localization.Current = lang;
                UiState.Current.Language = Localization.Code(lang);
                UiState.Save();

                if (turningChinese)
                {
                    Ui.Info("已切换为中文。部分文字需要重启程序后才会完全恢复。", "语言已切换");
                }
                else
                {
                    ApplyLanguage();
                }
                Append("[i18n] 界面语言切换为 " + Localization.Code(lang));
            }
            catch (Exception ex) { DriverManager.Log("[i18n] 切换失败: " + ex.Message); }
        }
    }
}
