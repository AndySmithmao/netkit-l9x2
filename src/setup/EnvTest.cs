// EnvCheckHelper 的独立测试台
// 编译真实的 EnvCheckHelper.cs（补几个 MicaSetup 类型的桩），
// 然后调用 EnsureComponents 真下 4 个文件，验证镜像测速 + 自动切换 + 校验。
using System;
using System.IO;
using System.Text;

namespace MicaSetup
{
    // ---- 桩：EnvCheckHelper 只用到这几个成员 ----
    namespace Core
    {
        public static class Logger
        {
            public static void Information(params object[] v) { Console.WriteLine("  [INFO] " + string.Join(" ", v)); }
            public static void Warning(params object[] v) { Console.WriteLine("  [WARN] " + string.Join(" ", v)); }
            public static void Error(params object[] v) { Console.WriteLine("  [ERR ] " + string.Join(" ", v)); }
        }
    }

    namespace Helper
    {
        public static class RuntimeHelper
        {
            public static bool IsElevated { get { return true; } }
        }

        public class Option
        {
            public string InstallLocation { get; set; }
            public static Option Current = new Option { InstallLocation = @"C:\Program Files\VRChat优选工具" };
        }
    }
}

class Program
{
    static int Main(string[] args)
    {
        Console.OutputEncoding = Encoding.UTF8;

        string tools = args.Length > 0
            ? args[0]
            : Path.Combine(Path.GetTempPath(), "vrctool-envtest", "tools");

        if (Directory.Exists(tools)) Directory.Delete(tools, true);
        Directory.CreateDirectory(tools);

        Console.WriteLine("测试目录: " + tools);
        Console.WriteLine();

        Console.WriteLine("===== 1) 环境检测 =====");
        string report = MicaSetup.Helper.EnvCheckHelper.DescribeEnvironment();
        Console.Write(report);
        Console.WriteLine();

        Console.WriteLine("===== 2) 镜像测速 =====");
        MicaSetup.Helper.EnvCheckHelper.Source best =
            MicaSetup.Helper.EnvCheckHelper.PickFastestSource(s => Console.WriteLine("  " + s));
        Console.WriteLine("  最快源: " + (best == null ? "(无可用)" : best.Name));
        Console.WriteLine();

        if (best == null)
        {
            Console.WriteLine("结论: 所有镜像都不可用，测试失败");
            return 2;
        }

        Console.WriteLine("===== 3) 下载 4 个组件 =====");
        bool ok = MicaSetup.Helper.EnvCheckHelper.EnsureComponents(
            tools,
            (p, msg) => Console.WriteLine(string.Format("  [{0,3:0}%] {1}", p, msg)),
            s => Console.WriteLine("  LOG " + s));
        Console.WriteLine();

        Console.WriteLine("===== 4) 结果 =====");
        Console.WriteLine("  返回: " + (ok ? "成功" : "失败"));
        foreach (string f in Directory.GetFiles(tools))
        {
            FileInfo fi = new FileInfo(f);
            Console.WriteLine(string.Format("  {0,-20} {1,12:N0} 字节", fi.Name, fi.Length));
        }

        // 校验文件头，确认不是 HTML 错误页
        Console.WriteLine();
        Console.WriteLine("===== 5) 文件头校验（PE 头应为 MZ）=====");
        foreach (string f in Directory.GetFiles(tools))
        {
            byte[] head = new byte[2];
            using (FileStream fs = File.OpenRead(f)) fs.Read(head, 0, 2);
            bool isPE = head[0] == 0x4D && head[1] == 0x5A;
            string name = Path.GetFileName(f);
            bool expectPE = name.EndsWith(".exe") || name.EndsWith(".dll") || name.EndsWith(".sys");
            string mark = (isPE == expectPE) ? "OK " : "?? ";
            Console.WriteLine(string.Format("  {0} {1,-20} 首字节 0x{2:X2}{3:X2}  ({4})",
                mark, name, head[0], head[1], isPE ? "PE/MZ" : "非PE"));
        }

        return ok ? 0 : 1;
    }
}
