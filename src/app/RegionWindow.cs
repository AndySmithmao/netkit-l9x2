using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Wpf.Ui.Controls;
using TextBlock = System.Windows.Controls.TextBlock;
using ComboBox = System.Windows.Controls.ComboBox;
using ComboBoxItem = System.Windows.Controls.ComboBoxItem;
using Button = System.Windows.Controls.Button;
using Grid = System.Windows.Controls.Grid;
using RowDefinition = System.Windows.Controls.RowDefinition;
using ColumnDefinition = System.Windows.Controls.ColumnDefinition;
using StackPanel = System.Windows.Controls.StackPanel;

namespace VrcTool
{
    /// <summary>
    /// 区域选择窗口：大陆板块 + 国家/地区。
    ///
    /// 首次进入时弹一次，用来确定「就近测试」的基准区域；
    /// 之后可以在设置页重新打开修改。
    ///
    /// 用代码构建界面而不是 XAML：这个窗口只有两个下拉框，
    /// 走 XAML 还要加 BAML 资源和编码校验，得不偿失。
    /// </summary>
    internal sealed class RegionWindow : FluentWindow
    {
        private readonly ComboBox cmbContinent = new ComboBox();
        private readonly ComboBox cmbCountry = new ComboBox();
        private readonly TextBlock txtHint = new TextBlock();

        public Continent SelectedContinent { get; private set; }
        public string SelectedCountry { get; private set; } = "";

        public RegionWindow(Continent continent, string country)
        {
            Title = "选择所在区域";
            Width = 460;
            Height = 340;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            ResizeMode = ResizeMode.NoResize;
            // 不设 Mica：FluentWindow 未开 ExtendsContentIntoTitleBar 时设背景会抛异常

            Grid root = new Grid { Margin = new Thickness(24) };
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

            TextBlock title = new TextBlock
            {
                Text = "先选择你所在的区域",
                FontSize = 18,
                FontWeight = FontWeights.SemiBold
            };
            Grid.SetRow(title, 0);
            root.Children.Add(title);

            TextBlock desc = new TextBlock
            {
                Text = "IP 优选会优先测试同区域（邻近国家/地区）的地址，范围更小、速度更快。\n选择只影响测试范围，不会上传任何信息。",
                Margin = new Thickness(0, 8, 0, 16),
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]
            };
            Grid.SetRow(desc, 1);
            root.Children.Add(desc);

            TextBlock lbC = new TextBlock { Text = "大陆板块", Margin = new Thickness(0, 0, 0, 6) };
            Grid.SetRow(lbC, 2);
            root.Children.Add(lbC);

            foreach (Continent c in new[] { Continent.Asia, Continent.Europe, Continent.NorthAmerica, Continent.SouthAmerica, Continent.Oceania, Continent.Africa })
                cmbContinent.Items.Add(new ComboBoxItem { Content = GeoIp.ContinentName(c), Tag = c });
            cmbContinent.Height = 34;
            cmbContinent.SelectionChanged += (s, e) => FillCountries();
            Grid.SetRow(cmbContinent, 3);
            root.Children.Add(cmbContinent);

            TextBlock lbN = new TextBlock { Text = "国家 / 地区", Margin = new Thickness(0, 14, 0, 6) };
            Grid.SetRow(lbN, 4);
            root.Children.Add(lbN);

            cmbCountry.Height = 34;
            Grid.SetRow(cmbCountry, 5);
            cmbCountry.VerticalAlignment = VerticalAlignment.Top;
            root.Children.Add(cmbCountry);

            txtHint.Margin = new Thickness(0, 8, 0, 0);
            txtHint.TextWrapping = TextWrapping.Wrap;
            txtHint.FontSize = 12;
            txtHint.Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"];
            Grid.SetRow(txtHint, 6);
            root.Children.Add(txtHint);

            StackPanel buttons = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 18, 0, 0)
            };
            Button ok = new Button { Content = "确定", Width = 96, Height = 32, IsDefault = true };
            ok.Click += (s, e) => Accept();
            Button cancel = new Button { Content = "稍后再说", Width = 96, Height = 32, Margin = new Thickness(8, 0, 0, 0) };
            cancel.Click += (s, e) => { DialogResult = false; Close(); };
            buttons.Children.Add(ok);
            buttons.Children.Add(cancel);
            Grid.SetRow(buttons, 6);
            buttons.VerticalAlignment = VerticalAlignment.Bottom;
            buttons.Margin = new Thickness(0, 44, 0, 0);
            root.Children.Add(buttons);

            Content = root;

            // 预选当前值
            foreach (ComboBoxItem it in cmbContinent.Items)
            {
                if ((Continent)it.Tag == continent) { cmbContinent.SelectedItem = it; break; }
            }
            if (cmbContinent.SelectedItem == null && cmbContinent.Items.Count > 0) cmbContinent.SelectedIndex = 0;
            FillCountries();
            if (!string.IsNullOrEmpty(country)) SelectCountry(country);
        }

        private void FillCountries()
        {
            cmbCountry.Items.Clear();
            ComboBoxItem sel = cmbContinent.SelectedItem as ComboBoxItem;
            if (sel == null) return;
            Continent c = (Continent)sel.Tag;
            List<string> list = GeoIp.CountriesOf(c);
            foreach (string cc in list)
                cmbCountry.Items.Add(new ComboBoxItem { Content = GeoIp.CountryName(cc) + "  (" + cc + ")", Tag = cc });
            if (cmbCountry.Items.Count > 0) cmbCountry.SelectedIndex = 0;

            txtHint.Text = GeoIp.RecordCount > 0
                ? "该区域共 " + list.Count + " 个国家/地区；IP 归属库 " + GeoIp.RecordCount.ToString("N0") + " 条（来源：" + GeoIp.Source + "）"
                : "IP 归属库未加载，区域仅作为提示，不会影响测试范围";
        }

        private void SelectCountry(string cc)
        {
            foreach (ComboBoxItem it in cmbCountry.Items)
            {
                if (string.Equals(it.Tag as string, cc, StringComparison.OrdinalIgnoreCase))
                {
                    cmbCountry.SelectedItem = it;
                    return;
                }
            }
        }

        private void Accept()
        {
            ComboBoxItem c = cmbContinent.SelectedItem as ComboBoxItem;
            ComboBoxItem n = cmbCountry.SelectedItem as ComboBoxItem;
            if (c == null || n == null) { DialogResult = false; Close(); return; }
            SelectedContinent = (Continent)c.Tag;
            SelectedCountry = (string)n.Tag;
            DialogResult = true;
            Close();
        }
    }
}
