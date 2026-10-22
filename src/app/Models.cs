using System;
using System.ComponentModel;
using System.IO;
using System.Windows.Media;

namespace VrcTool
{
    // =========================================================================
    //  界面/数据模型。原来这些类都塞在 MainWindow.xaml.cs / PickerWindow.xaml.cs
    //  里，改个文案都得动窗口代码；拆出来单独放。
    // =========================================================================

    /// <summary>
    /// 一个导航项的定义（页面标题 / 说明 / 要跑哪个脚本 / 传什么参数）。
    ///
    /// Key 是稳定标识：XAML 里 NavigationViewItem 的 Tag 存这个字符串，
    /// 代码里按 Key 查表。以前用的是「Tag 必须等于 navDefs 的下标」，
    /// 往中间插一条就整列错位，而且是静默错位（点「自动优选·快速」跑「标准」）。
    /// </summary>
    public class NavDef
    {
        public string Key = "";
        public string Title = "";
        public string Desc = "";
        public string Script = "";
        public string Args = "";
        public bool Big = false;
        public string Special = "";

        public NavDef(string key, string title, string desc, string script, string args, bool big)
        {
            Key = key;
            Title = title;
            Desc = desc;
            Script = script;
            Args = args;
            Big = big;
        }
    }

    /// <summary>「实时 IP 结果」表格的一行</summary>
    public class IpRow : INotifyPropertyChanged
    {
        private string _lat = "", _okTot = "", _med = "-", _jit = "-", _note = "";
        private Brush _fg = null;

        public string Group { get; set; }
        public string Ip { get; set; }

        public string Lat { get { return _lat; } set { _lat = value; OnP("Lat"); } }
        public string OkTot { get { return _okTot; } set { _okTot = value; OnP("OkTot"); } }
        public string Med { get { return _med; } set { _med = value; OnP("Med"); } }
        public string Jit { get { return _jit; } set { _jit = value; OnP("Jit"); } }
        public string Note { get { return _note; } set { _note = value; OnP("Note"); } }
        public Brush Fg { get { return _fg; } set { _fg = value; OnP("Fg"); } }

        public int LastLat = -1;

        public event PropertyChangedEventHandler PropertyChanged;
        private void OnP(string n)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(n));
        }
    }

    /// <summary>「清理缓存」页里可勾选的一个缓存类别</summary>
    public class CacheItem : INotifyPropertyChanged
    {
        public string Key = "", Name = "", Desc = "", Dir = "";
        public string[] Pat = new string[0];
        public bool Dns = false;

        private bool _chk = false;
        public bool Checked
        {
            get { return _chk; }
            set { _chk = value; OnP("Checked"); }
        }
        public string Text { get; set; }
        public string Sub { get; set; }

        public long Bytes = 0;
        public int Count = 0;

        public void Scan()
        {
            Bytes = 0; Count = 0;
            if (Dns) return;
            foreach (string p in Pat)
            {
                try
                {
                    foreach (string f in Directory.GetFiles(Dir, p))
                    { try { Bytes += new FileInfo(f).Length; Count++; } catch { } }
                }
                catch { }
            }
            Text = Name + "    " + SizeText() + (Dns ? "" : "    " + Count + " 个");
            Sub = Desc;
        }

        public string SizeText()
        {
            if (Dns) return "-";
            if (Count == 0) return "空";
            if (Bytes >= 1048576) return (Bytes / 1048576.0).ToString("0.00") + " MB";
            return (Bytes / 1024.0).ToString("0.0") + " KB";
        }

        public event PropertyChangedEventHandler PropertyChanged;
        private void OnP(string n)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(n));
        }
    }

    /// <summary>候选清单窗口的一行</summary>
    public class PickRow
    {
        public int N { get; set; }
        public string Ip { get; set; }
        public string V1 { get; set; }
        public string V2 { get; set; }
        public string V3 { get; set; }
        public string V4 { get; set; }
        public string Ok { get; set; }
        public string Rate { get; set; }
        public string Note { get; set; }

        /// <summary>这个 IP 是不是 hosts 里当前正在用的（A 组看 api，B 组看 files）</summary>
        public bool InUse { get; set; }
    }

    /// <summary>从 CSV 读出来的原始行（还没排序 / 格式化）</summary>
    public class RawRow
    {
        public string Group = "", Ip = "";
        public int Med, Min, Max, Jit, OK, Tot, Rate, Score, Speed, Eff;
    }
}
