# tools —— 开发期辅助工具

这些工具**不随产品分发**，仅供维护者本地构建与验收使用。

> 位置说明：本目录是 `<包根>\tools\`，历史上还堆着一批 DPI 绕过 / 优选 IP 的
> 实测产物（`*.zip`、`*.log`、`*-results.txt`、`hosts.bak-*` 等），那些是**测试残留**，
> 不是工具。真正的开发工具在下面三个地方：
>
> | 目录 | 放什么 |
> | --- | --- |
> | `tools\`（本目录） | 工程层工具：编码检查、一键盘点、vswhere 还原 |
> | `tools\` | GUI 自动化工具：截图、点击、vswhere shim 源码（**权威副本**） |
> | `tools_py\` | 上面那批工具的副本 + 一批 Python 辅助脚本（md 转换、图标生成……） |

---

## 1. check-encoding.ps1 —— UTF-8 BOM 断言

**为什么需要**：Windows PowerShell 5.1 遇到没有 BOM 的 `.ps1`，会按系统 ANSI(GBK) 解码。
中文一旦落进这个坑**不是乱码那么温柔，而是直接语法报错**，脚本根本起不来。
（`.cs` / `.xaml` 同理，无 BOM 的中文在部分工具链下会被按 GBK 处理。）

**判定规则**（重点）：不是「所有文件都必须带 BOM」——

- 文件里**含非 ASCII 字节**（中文、全角标点）→ **必须**带 UTF-8 BOM
- **纯 ASCII** 文件 → 带不带都行，不算错
- 扫到 UTF-16 编码的文件 → 报 FAIL，并单独点明（避免误以为「已经有 BOM 了」）

**扫描范围**（相对根目录，不递归）：

```
wpf\*.cs                wpf\*.xaml
wpf\Scripts\*.ps1       wpf\setup\*.ps1
wpf\setup\.inject\*.cs  dist\scripts\*.ps1
tools\*.ps1
```

**用法**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-encoding.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\check-encoding.ps1 -Root D:\repo
```

`-Root` 默认取脚本的上一级（即 `<包根>`）。

**退出码**：全部合规 `0`；有 FAIL `1`；根目录不存在 `1`。

**补 BOM**（就地，不改内容）：

```powershell
$f = '<包根>\src\scripts\lib-common.ps1'
[IO.File]::WriteAllText($f, [IO.File]::ReadAllText($f,[Text.Encoding]::UTF8), (New-Object Text.UTF8Encoding($true)))
```

---

## 2. verify.ps1 —— 一键盘点

把项目里那些「改错了但没人发现」的检查一次跑完。**提交前 / 构建前跑这个。**

| # | 组 | 查什么 | 失败会怎样 |
| --- | --- | --- | --- |
| 1 | 文件编码 | 调 `check-encoding.ps1`（`&` 调用 + 看 `$LASTEXITCODE`） | FAIL |
| 2 | 脚本语法 | `wpf\Scripts\*.ps1` 逐个 `[Parser]::ParseInput` | FAIL |
| 3 | 双份一致性 | `dist\scripts\*.ps1` ↔ `wpf\Scripts\*.ps1` 逐文件 SHA256；任一侧多/少文件也报 | FAIL |
| 4 | 硬编码残留 | `dist\scripts\*.ps1` + `wpf\*.cs` 里不得出现 `C:\vrchat-*`（正则 `C:\\+vrchat`，注释行豁免） | FAIL |
| 5 | 内嵌资源清单 | `wpf\Scripts\*.ps1` 文件名 ↔ `VrcTool.csproj` 的 `<EmbeddedResource Include="Scripts\*.ps1" />`，报数量 | FAIL |
| 6 | 版本号一致性 | `VrcTool.csproj` 的 `<Version>`、`setup\micasetup.json` 的 `"Version"`、`build-installer.ps1` 的 `$Version` 默认值 | **只 Warn，不 fail** |

**几个刻意的设计**：

- 读脚本一律 `[IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)`，**不用 `Get-Content`**。
  `Get-Content` 会按「无 BOM 就 ANSI 解码」的规则走，那正是我们要检出的问题本身，
  拿它当检查手段等于自己骗自己。
- 第 4 组「注释行豁免」：`trim` 后以 `#` 或 `//` 开头的行不算命中。
  注释不参与运行，留着旧路径说明来历是正常的。
- 第 6 组只是提醒。三处版本号不同步不会让构建炸，但会让安装包显示的版本和主程序对不上。
- `-Quiet` 只打印 WARN/FAIL 的汇总，适合塞进构建流程当门禁。

**用法**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -Quiet     # CI 用
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -Root D:\repo
```

**退出码**：有 FAIL → `1`；只有 WARN 或全通过 → `0`。

> 注意：`wpf\setup\build-installer.ps1` 内部已经自带一套「同步脚本 + SHA256 断言 +
> 语法断言 + 硬编码断言」。`verify.ps1` 是**只读**版本，不会改任何文件，
> 适合在没有完整构建环境（缺证书、缺 makemica）的机器上跑。
> 两者查的是同一批东西，别只跑一个就以为覆盖全了。

---

## 3. restore-vswhere.ps1 —— vswhere 转发 shim 的状态检查 / 还原

**背景**：makemica 内部执行 `vswhere -latest -property installationPath`，
而 vswhere **默认不把 VS BuildTools 算作 Visual Studio**（必须显式加 `-products *`），
所以装了 VS BuildTools 也报
`Microsoft Visual Studio Installer is not installed, register not found`。

当时把本机
`C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe` 换成了
`tools_py\vswhere-shim.cs` 编译出来的**转发 shim**（自动补 `-products *`），
原文件备份为 `vswhere_orig.exe`。

**默认（`-Status`，只读，不需要管理员）**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\restore-vswhere.ps1
```

报告：Installer 目录、`vswhere.exe` / `vswhere_orig.exe` 各自是否存在、大小、
`Get-FileHash`、文件版本，判定当前是「原版」还是「shim」，
并顺带做行为探测——同样的参数分别喂给两边，直接看输出差异：

```
makemica 的调用方式   -latest -property installationPath
原生 vswhere_orig     -latest -property installationPath
带上 -products *      -products * -latest -property installationPath
```

**还原（`-Restore`，需要管理员）**：

```powershell
# 先提权
powershell -NoProfile -ExecutionPolicy Bypass -File .\restore-vswhere.ps1 -Restore
```

流程：确认 `vswhere_orig.exe` 还在 → 检查管理员权限（不是管理员会给出明确的提权提示，
不会半路失败）→ 把当前 `vswhere.exe` 备份成 `vswhere-shim.bak.exe`（**不留后路不敢动系统目录**）
→ `vswhere_orig.exe` 改名回 `vswhere.exe` → 重新打印现状。

想再装回 shim：把 `vswhere-shim.bak.exe` 覆盖成 `vswhere.exe` 即可。

**⚠️ 什么时候必须还原**：

- 换机器 / 重装 VS / 交付安装包之前
- 发现 VS 安装器本身行为异常时（shim 会污染 VS 安装目录的语义）

---

## 4. vswhere-shim.cs

转发 shim 的源码。**权威副本在 `tools\vswhere-shim.cs`**，
`tools_py\` 下有同名副本（内容一致）。

逻辑：检查参数里有没有 `-products`，没有就补上 `-products *`，
再把请求转发给同目录的 `vswhere_orig.exe`（找不到就试 `vswhere.real.exe`），
原样透传 stdout / stderr / 退出码。

重新编译：

```powershell
$csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /target:exe /platform:anycpu "/out:$env:TEMP\vswhere-shim.exe" .\vswhere-shim.cs
# 然后提权拷到 Installer 目录（先把原文件改名成 vswhere_orig.exe）
```

（更推荐直接用 `restore-vswhere.ps1` 看现状 / 还原，别手动删文件。）

---

## 5. hardclick.ps1

**可靠的窗口点击器**，解决两个 GUI 自动化难题：

1. **DPI 虚拟化** —— 声明 `SetProcessDPIAware()`，让坐标系统和截图一致（都是物理像素）
2. **窗口遮挡** —— 先 `BringWindowToTop` + `SetForegroundWindow` 再点

带一个 `WhatAt(x, y)` 调试能力：**能报告某个坐标上实际是哪个窗口**（pid + 进程名 + 类名 + 标题），
点击失效时先看它。

```powershell
powershell -File hardclick.ps1 -Title 安装程序 -Points "1025,640;646,706" -Shot out.png
```

参数：`-Title`（窗口标题子串，默认 `安装程序`）、`-Points`（`"x,y;x,y"`，物理像素）、
`-Shot`（点完截个全屏图）、`-Settle`（激活后等待毫秒，默认 900）。

> ⚠️ 已知限制：安装器上的「开始安装」按钮仍然点不动（见 ISSUES）。
> 许可证复选框、自定义选项、取消按钮都能点。

---

## 6. shot.ps1

**DPI 感知的窗口截图**。

```powershell
powershell -File shot.ps1 -ProcId <PID>       -Out out.png
powershell -File shot.ps1 -TitlePart 安装程序 -Out out.png
```

**为什么要 DPI 感知**：不声明 `SetProcessDPIAware()` 的话，`GetWindowRect` 返回逻辑坐标，
在 125% 缩放下截出来的图会被裁掉约 24%。

**为什么不用 `PrintWindow`**：WPF 走硬件加速，`PrintWindow` + `PW_RENDERFULLCONTENT`
返回**全白**。必须用真实屏幕捕获（`Graphics.CopyFromScreen`）。
代价是窗口不能被别的窗口盖住。

---

## 7. tools_py\ 里的其它东西（顺带一提）

| 文件 | 干什么 |
| --- | --- |
| `check_env.py` | 环境自检（.NET / VC 运行库 / 证书） |
| `count_space.py` | 统计源码空白字符分布 |
| `make_icon.py` | 从 PNG 生成 `app.ico` |
| `md2docx.py` / `md2html.py` | 交付文档（`*.md`）转 Word / HTML |
| `inspect_docx.py` | 反向检查生成的 docx 结构 |
| `gen_launchers.ps1` | 批量生成 `dist\` 下的 `N-xxx.cmd` 启动器 |
| `elev.ps1` | 提权小工具 |
| `gui-click.ps1` / `gui-test.ps1` / `click-cache.ps1` | GUI 冒烟测试与点击缓存 |
| `test_tls_perf.ps1` | TLS 握手 / 吞吐实测 |

---

## 约定

- 本目录所有 `.ps1` **必须是 UTF-8 with BOM**（`check-encoding.ps1` 会断言）。
- **改完 `.ps1` 记得重跑一次 `check-encoding.ps1`**：
  不少编辑器和批量替换工具在写文件时会**吃掉 BOM**，
  内容看着没变，BOM 没了 —— 这个变化在编辑器里完全看不出来，只有检查能发现。
  本目录三个脚本在开发过程中就被这个坑咬过两次。
- 脚本要能在 **Windows PowerShell 5.1** 下跑，不要用 PS7 专属语法（`??`、`?.`、三元 `?:`）。
- 不要写死 `<包根>`，用 `$PSScriptRoot` 往上一级推导。
- 这些脚本**不参与构建、不进安装包**。
