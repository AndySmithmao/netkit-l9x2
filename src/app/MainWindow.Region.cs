using System;
using System.Threading.Tasks;
using System.Windows;

namespace VrcTool
{
    /// <summary>区域选择：首次进入引导 + 设置页修改。</summary>
    public partial class MainWindow
    {
        private bool regionPrompted;
        /// <summary>区域弹窗是否正在显示：此时不能再弹更新框，否则两个模态会互相遮挡。</summary>
        private bool regionDialogOpen;

        /// <summary>首次进入（没选过区域）时询问一次；之后由设置页手动修改。</summary>
        private void EnsureRegionChosen()
        {
            if (regionPrompted) return;
            regionPrompted = true;
            try
            {
                if (!string.IsNullOrEmpty(UiState.Current.RegionContinent)) return;

                RegionWindow w = new RegionWindow(Continent.Asia, "CN");
                w.Owner = this;
                regionDialogOpen = true;
                bool? ok;
                try { ok = w.ShowDialog(); }
                finally { regionDialogOpen = false; }
                if (ok == true)
                {
                    UiState.Current.RegionContinent = w.SelectedContinent.ToString();
                    UiState.Current.RegionCountry = w.SelectedCountry;
                    UiState.Save();
                    Append("[区域] 已选择 " + GeoIp.ContinentName(w.SelectedContinent) + " / " + w.SelectedCountry);
                }
                else
                {
                    Append("[区域] 暂未选择；IP 优选会按全部网段测试（较慢），可随时在设置页指定");
                }
            }
            catch (Exception ex) { DriverManager.Log("区域选择失败: " + ex.Message); Append("[区域] 弹窗失败: " + ex.Message); }
        }

        /// <summary>设置页「更改区域」。</summary>
        private void ChangeRegion()
        {
            try
            {
                Continent cur = Continent.Asia;
                UiLang dummy;
                if (!string.IsNullOrEmpty(UiState.Current.RegionContinent))
                {
                    try { cur = (Continent)Enum.Parse(typeof(Continent), UiState.Current.RegionContinent); } catch { }
                }

                RegionWindow w = new RegionWindow(cur, UiState.Current.RegionCountry);
                w.Owner = this;
                regionDialogOpen = true;
                bool? ok2;
                try { ok2 = w.ShowDialog(); }
                finally { regionDialogOpen = false; }
                if (ok2 == true)
                {
                    UiState.Current.RegionContinent = w.SelectedContinent.ToString();
                    UiState.Current.RegionCountry = w.SelectedCountry;
                    UiState.Save();
                    Append("[区域] 已改为 " + GeoIp.ContinentName(w.SelectedContinent) + " / " + w.SelectedCountry);
                    RefreshRegionText();
                }
            }
            catch (Exception ex) { DriverManager.Log("更改区域失败: " + ex.Message); }
        }

        private void BtnChangeRegion_Click(object sender, RoutedEventArgs e) { ChangeRegion(); }

        private async void BtnGeoRefresh_Click(object sender, RoutedEventArgs e) { await RefreshGeoDb(); }
        /// <summary>设置页显示当前区域。</summary>
        private void RefreshRegionText()
        {
            try
            {
                if (TxtRegion == null) return;
                Continent c = Continent.Unknown;
                try { c = (Continent)Enum.Parse(typeof(Continent), UiState.Current.RegionContinent); } catch { }
                string cc = UiState.Current.RegionCountry;
                TxtRegion.Text = c == Continent.Unknown
                    ? "未选择（IP 优选会测试全部网段）"
                    : GeoIp.ContinentName(c) + " · " + (string.IsNullOrEmpty(cc) ? "-" : GeoIp.CountryName(cc) + " (" + cc + ")");
            }
            catch { }
        }

        /// <summary>设置页「重新查询 IP 归属」。</summary>
        private async Task RefreshGeoDb()
        {
            if (BtnGeoRefresh == null) return;
            BtnGeoRefresh.IsEnabled = false;
            string old = TxtGeoStatus == null ? "" : TxtGeoStatus.Text;
            try
            {
                if (TxtGeoStatus != null) TxtGeoStatus.Text = "正在下载 IP 归属库…";
                Progress<string> prog = new Progress<string>(s => { try { if (TxtGeoStatus != null) TxtGeoStatus.Text = s; } catch { } });
                var r = await GeoIp.RefreshAsync(prog);
                if (TxtGeoStatus != null)
                    TxtGeoStatus.Text = r.ok
                        ? r.message
                        : "更新失败：" + r.message + "（可继续使用内置数据库）";
                Append("[区域] IP 归属库: " + (r.ok ? r.message : "更新失败 " + r.message));
                RefreshRegionText();
            }
            catch (Exception ex)
            {
                if (TxtGeoStatus != null) TxtGeoStatus.Text = old + " 更新异常：" + ex.Message;
            }
            finally { BtnGeoRefresh.IsEnabled = true; }
        }
    }
}
