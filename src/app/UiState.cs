using System;
using System.IO;
using System.Text;
using System.Text.Json;

namespace VrcTool
{
    /// <summary>
    /// 界面状态的轻量持久化，存在 <c>&lt;程序目录&gt;\data\ui.json</c>。
    /// 跟着程序目录走 —— 卸载 / 清理数据时一起没了，不会在用户机器上留垃圾。
    ///
    /// 存的东西：
    ///   · 窗口 位置 / 大小 / 是否最大化（外接显示器拔掉后会夹回主屏）
    ///   · 「这一步会做什么」说明卡 显示 / 收起
    ///   · 两个抽屉（运行日志 / 实时 IP 结果）展开状态
    ///   · 日志自动滚动开关
    ///   · 主题：是否手动选过 + 选的哪个（没手动选过就跟随系统）
    ///
    /// 读写全部 try/catch 兜住：配置文件坏了最多是回到默认值，绝不能让程序起不来。
    /// </summary>
    internal sealed class UiStateData
    {
        public double? Left { get; set; }
        public double? Top { get; set; }
        public double Width { get; set; }
        public double Height { get; set; }
        public bool Maximized { get; set; }

        public bool HelpCardVisible { get; set; } = true;
        public bool LogExpanded { get; set; } = true;
        public bool IpExpanded { get; set; } = true;
        public bool AutoScroll { get; set; } = true;

        /// <summary>关掉之后就不再记住窗口大小/位置（设置页里的开关）</summary>
        public bool RememberWindow { get; set; } = true;

        /// <summary>最小化时缩到托盘而不是留在任务栏（设置页里的开关）</summary>
        public bool MinimizeToTray { get; set; } = true;

        /// <summary>界面缩放倍数（0.8 / 0.9 / 1.0）。默认 0.9 —— 高 DPI 屏幕上 1.0 会显得过大。</summary>
        public double UiScale { get; set; } = 0.9;

        /// <summary>已经给用户说过"我缩到托盘了"，不用每次都弹气泡</summary>
        public bool TrayHintShown { get; set; }

        /// <summary>手动切过主题之后就不再跟随系统，免得系统一变化把用户的选择冲掉</summary>
        public bool ManualTheme { get; set; }

        /// <summary>手动选的主题：true = 深色</summary>
        public bool Dark { get; set; } = true;

        /// <summary>
        /// 程序启动时是否自动开启"上次用的内核"。
        /// 默认 false —— 需求里明确：没开自启就不该在启动应用时拉起驱动/服务，
        /// 否则用户一开工具就悄悄改了系统网络。
        /// </summary>
        public bool AutoStartDrivers { get; set; }

        /// <summary>上次用的内核（重启后按需自动拉起时参考）。0=都不开 1=winws 2=mihomo</summary>
        public int LastDrivers { get; set; }
    }

    internal static class UiState
    {
        private static UiStateData cache;
        private static bool dirty;

        public static string FilePath
        {
            get { return Path.Combine(ScriptHost.DataDir, "ui.json"); }
        }

        public static UiStateData Current
        {
            get
            {
                if (cache != null) return cache;

                try
                {
                    if (File.Exists(FilePath))
                    {
                        string t = File.ReadAllText(FilePath, Encoding.UTF8);
                        if (!string.IsNullOrWhiteSpace(t))
                            cache = JsonSerializer.Deserialize<UiStateData>(t);
                    }
                }
                catch { cache = null; }

                if (cache == null) cache = new UiStateData();
                return cache;
            }
        }

        /// <summary>标脏。真正落盘在 <see cref="Save"/>，只在退出时调一次。</summary>
        public static void Touch()
        {
            dirty = true;
        }

        /// <summary>
        /// 回到默认值（设置页「重置界面状态」）。
        /// 只删文件是不够的：内存里的 cache 还在，退出时 Save() 会把旧值原样写回去，
        /// 用户看到的就是"点了重置、重启还是老样子"。
        /// </summary>
        public static void Reset()
        {
            cache = new UiStateData();
            dirty = true;
            try { if (File.Exists(FilePath)) File.Delete(FilePath); } catch { }
        }

        public static void Save()
        {
            try
            {
                Directory.CreateDirectory(ScriptHost.DataDir);
                JsonSerializerOptions opt = new JsonSerializerOptions();
                opt.WriteIndented = true;
                File.WriteAllText(FilePath, JsonSerializer.Serialize(Current, opt), new UTF8Encoding(true));
                dirty = false;
            }
            catch { }
        }

        public static bool IsDirty { get { return dirty; } }
    }
}
