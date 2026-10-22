# VRChat 网络优化工具

> 一款面向 VRChat 玩家的 Windows 网络优化工具：内置 **winws**（zapret DPI 绕过）与 **mihomo**（Clash.Meta 内核），
> 通过 hosts 优选 + 内核代理两条链路改善联机质量，并提供订阅管理、节点测速、逐节点 Ping 与在线更新。

![platform](https://img.shields.io/badge/platform-Windows%2010%2F11%20x64-0078D4)
![.NET](https://img.shields.io/badge/.NET-10-512BD4)
![UI](https://img.shields.io/badge/UI-WPF--UI%204.3-6C5CE7)
![version](https://img.shields.io/badge/version-0.0.1--beta-orange)

---

## 目录

- [这是什么](#这是什么)
- [功能特性](#功能特性)
- [下载与安装](#下载与安装)
- [快速开始](#快速开始)
- [界面说明](#界面说明)
- [工作原理](#工作原理)
- [在线更新](#在线更新)
- [从源码构建](#从源码构建)
- [目录结构](#目录结构)
- [常见问题](#常见问题)
- [已知限制](#已知限制)
- [开源许可与致谢](#开源许可与致谢)
- [免责声明](#免责声明)

---

## 这是什么

VRChat 的连接质量高度依赖**到 Photon 服务器的链路**。国内直连常见问题是：

- DNS 解析到境外劣质节点 → 高延迟、丢包；
- 运营商国际出口绕路（例如移动 → PCCW 东京，单跳就 +160 ms）；
- 部分链路被 DPI 干扰，握手失败或频繁重连。

本工具提供两条互补的优化路径：

| 路径 | 原理 | 适用 |
|---|---|---|
| **hosts 优选** | 扫描 Cloudflare / CloudFront 网段，实测延迟与下载速度，挑最快的 IP 写入 hosts | 不想开代理、只想让域名解析到好 IP |
| **内核代理** | mihomo（Clash.Meta）按规则把 Photon 网段分流到订阅节点；winws 做 DPI 绕过 | 需要稳定绕路或跨区域加速 |

两条路径可独立使用，也可同时启用。

---

## 功能特性

### 一键完成

从零到可用一条龙：

1. 环境检查（服务 / 驱动 / hosts 状态）
2. 全量扫描 —— Cloudflare 5956 个 /24 + CloudFront 16552 个 /24，ICMP + TLS 双测
3. 延迟实测 —— 两组 Top 40，多轮交替
4. 下载测速 —— 真实文件下载
5. 自动弹出候选清单 → 选一个 → 写 hosts → 自动验证

### 优选流程

| 功能 | 说明 |
|---|---|
| 全量扫描 | 网段级扫描，输出候选 IP 池 |
| 延迟实测 | 对候选池做多轮延迟测量，剔除抖动大的 |
| 下载测速 | 真实下载测吞吐，避免"低延迟低带宽"陷阱 |
| 清单选用 | 手工挑选并写入 hosts，支持回滚 |

### 内核与代理

| 页面 | 能力 |
|---|---|
| **内核** | winws / mihomo 各自 **开启 / 关闭 / 重启**，独立版本区（更新 + 当前版本），一键诊断、迁移旧服务 |
| **订阅** | Clash 订阅导入与更新（自动带 Clash UA，兼容 base64 v2ray 链接），保存后自动拉起 mihomo |
| **节点** | Clash Verge 风格**卡片墙**，点卡片即切换，支持批量测延迟 |
| **Ping** | 经每个节点对指定 IP/域名做 **TCP + TLS 握手**，量真实往返，结果按延迟升序排列 |

> 为什么 Ping 不用 ICMP：mihomo 对 ICMP 一律走 `DIRECT`（内核不支持 ICMP 走代理），
> 实测切到美国/日本/香港节点 ping 同一 IP 都是 ~172 ms。TCP+TLS 才能真正体现节点差异。

### 其他

- **退出联动**：关闭应用时自动停止所有内核进程，不留后台残留
- **开机自启**：可选，未开启时启动应用不会自动拉起内核
- **托盘常驻**：最小化到托盘，不占任务栏
- **界面缩放 / 主题**：跟随系统 / 浅色 / 深色，80%~100% 缩放
- **开机自检**：检测旧版残留服务（`VRChatBypass`）并支持一键迁移
- **应用与内核更新**：启动自动检查（弹窗询问）+ 设置页手动检查

---

## 下载与安装

### 系统要求

- Windows 10 / 11 x64
- **管理员权限**（写 hosts、加载 WinDivert 驱动、开启 TUN 均需要）
- 无需预装 .NET 运行时（单文件自包含发布）

### 下载

| 版本 | 链接 |
|---|---|
| **安装包（推荐）** | [`VRChat-Selector-Setup.exe`](https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe) |
| **便携版（免安装）** | [`VRChat-Selector-Portable.exe`](https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Portable.exe) |

> **国内网络提示**：`github.com` 可能无法直连。可在链接前加镜像前缀：
>
> ```
> https://ghproxy.net/https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe
> ```
>
> 应用内置的更新器已经做了镜像回退，从这里下载不到时用上面这条。

### 安装

1. 双击安装包，点「开始安装」（默认装到 `C:\Program Files\VRChat优选工具`）
2. 安装完成后点「打开」
3. 首次启动会请求管理员权限（UAC），点「是」

**卸载**：控制面板 → 程序 → 卸载，或开始菜单里的「Uninstall VRChat优选工具」。

> 安装包使用自签名证书，SmartScreen 可能提示「未知发布者」，选择「仍要运行」即可。

---

## 快速开始

### 路线 A：只用 hosts 优选（最简单）

```
1. 打开工具 → 「一键完成」→ 开始一键完成
2. 等待扫描 / 测速完成，在弹出的清单里挑一个 IP
3. 工具自动写入 hosts 并验证
4. 启动 VRChat，观察延迟是否改善
```

### 路线 B：用代理节点

```
1. 「订阅」页 → 填入订阅链接 → 导入 / 更新
2. 「节点」页 → 点卡片选择节点（可先批量测延迟）
3. 「内核」页 → mihomo 开启（如需 TUN，在节点页勾选 TUN 后重启 mihomo）
4. 「Ping」页 → 填目标 IP（如 142.250.199.206）→ 开始 Ping，比较各节点
```

### 路线 C：winws DPI 绕过

```
「内核」页 → winws 开启
```

winws 使用 WinDivert 拦截并改写特定流量，配合内置的 desync 配置绕过 DPI 干扰。
若之前装过旧版服务（`VRChatBypass`），先点「迁移旧服务」，否则两份过滤器会冲突。

---

## 界面说明

左侧导航按用途分组：

```
一键完成
运维
  ├ 安装 / 卸载 / 诊断
优选流程
  ├ 全量扫描 / 延迟实测 / 下载测速 / 清单选用
内核与代理
  ├ 内核    winws 与 mihomo 的启停、版本、诊断
  ├ 订阅    订阅链接导入与更新
  ├ 节点    节点卡片墙 + 批量测延迟 + TUN / 代理模式
  └ Ping    逐节点 TCP+TLS 延迟（按延迟升序）
设置
  ├ 外观 / 窗口 / 界面缩放
  └ 应用更新（当前版本、检查更新、下载并安装）
```

底部还有：清理缓存、自动优选·标准、自动优选·快速。

---

## 工作原理

### hosts 优选

1. 从 Cloudflare（5956 个 /24）与 CloudFront（16552 个 /24）网段生成候选 IP；
2. 用 ICMP + TLS 双指标粗筛，得到候选池；
3. 多轮延迟实测 + 真实下载测速，综合排序；
4. 把选中 IP 写入 `C:\Windows\System32\drivers\etc\hosts`，带标记块便于回滚：

```
# ===== VRChat-bypass BEGIN =====
104.18.26.36  gctok.example.com
...
# ===== VRChat-bypass END =====
```

### 内核

| 内核 | 作用 | 运行方式 |
|---|---|---|
| **winws**（zapret） | WinDivert 抓包 + desync 改写，绕过 DPI | 应用托管的子进程 |
| **mihomo**（Clash.Meta） | 订阅节点代理，可开 TUN 接管全局流量 | 应用托管的子进程 |

> **为什么不用 Windows 服务**：早期版本把 winws 注册为服务，`sc stop` 会泄漏 WFP 过滤器对象
> （错误码 `FWP_E_IN_USE 0x8032000A`），只能重启系统恢复。改为应用托管子进程后，
> 关闭→重开循环稳定（实测连续 3 次无异常）。

### 运行时目录

| 路径 | 内容 |
|---|---|
| `C:\Program Files\VRChat优选工具\tools\` | 运行时组件（winws / WinDivert / cygwin） |
| `C:\Program Files\VRChat优选工具\data\logs\` | 会话日志 `session-*.log` |
| `C:\ProgramData\VrcTool\drivers\` | 内核二进制（首次使用时释放） |
| `C:\ProgramData\VrcTool\logs\drivers.log` | 内核日志 |
| `C:\ProgramData\VrcTool\drivers\mihomo\` | mihomo 配置、订阅缓存、`state.json` |

---

## 在线更新

应用启动 5 秒后自动检查，**只弹窗询问，绝不静默更新**；设置页也可手动触发。

```
发现可用更新：
· 应用  0.0.1-beta → 0.0.2-beta
· winws v72.12 → v72.13

要现在更新吗？
· 更新应用会下载安装包并退出本程序
· 更新内核会自动备份旧文件，新版起不来会自动回滚
· 选「否」= 本次不更新，下次启动再问
```

| 组件 | 来源 | 说明 |
|---|---|---|
| 应用 | 本仓库 Release | 下载 Setup → 校验 SHA256 → 启动安装程序 → 自身退出 |
| mihomo | [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) | 提取 `mihomo.exe`，旧版备份为 `.bak` |
| winws | [bol-van/zapret](https://github.com/bol-van/zapret) | 提取 `winws.exe` / `cygwin1.dll` / `WinDivert*` |

**下载失败会自动换源**：直连 → `ghproxy.net` → `gh-proxy.com` → `ghfast.top`。

**检查结果缓存 6 小时**：GitHub 匿名 API 每小时仅 60 次，启动检查一次要 3 个请求，缓存避免打爆配额。
手动点「检查更新」会强制刷新。

---

## 从源码构建

### 依赖

- [.NET 10 SDK](https://dotnet.microsoft.com/download)
- Visual Studio 2022 / 2026 的 MSBuild（生成安装器需要）

### 编译

```powershell
git clone https://github.com/AndySmithmao/netkit-l9x2.git
cd netkit-l9x2

# 编译主程序
dotnet build src\app\VrcTool.csproj -c Release

# 发布单文件
dotnet publish src\app\VrcTool.csproj -c Release -r win-x64 --self-contained true `
    -p:PublishSingleFile=true -o build\publish

# 打安装包（内置编码/一致性校验、签名、mica 打包）
powershell -File src\setup\build-installer.ps1
```

构建脚本会先跑 `tools\verify.ps1`，检查：

- 文件编码（含非 ASCII 的文件必须带 UTF-8 BOM）
- 脚本语法
- 双份脚本一致性
- 硬编码路径残留
- 内嵌资源清单
- 版本号一致性

### 补齐内核二进制

`src\drivers\mihomo.exe`（约 61 MB）**不在仓库中**，构建前请自行放置：

```powershell
# 1) 从上游下载（可用镜像）
#    https://github.com/MetaCubeX/mihomo/releases/latest
#    资产：mihomo-windows-amd64-vX.Y.Z.zip

# 2) 解压出 mihomo.exe，放入 src\drivers\

# 3) 写入版本标识（更新器靠它比较版本）
"Mihomo Meta v1.19.32 windows amd64" | Out-File src\drivers\mihomo.VERSION.txt -Encoding utf8
```

`winws.exe` / `cygwin1.dll` / `WinDivert.dll` / `WinDivert64.sys` 已随仓库提供。

### 常见构建问题

| 现象 | 原因 | 处理 |
|---|---|---|
| `error CS1566: 读取资源 WinDivert64.sys 失败` | 该文件被运行中的 winws 占用 | 停掉 winws / 清掉 `obj`、`bin` 后重编 |
| `verify.ps1` 报「缺 UTF-8 BOM」 | 编辑器保存成无 BOM | 跑 `tools\fix-bom.ps1` |
| 安装包只有 2~3 MB | `makemica` 只接受纯数字版本，传 `0.0.1-beta` 会静默失败 | 构建脚本已自动剥离后缀，若手改注意此项 |

---

## 目录结构

```
src/
  app/                WPF 主程序（C# / XAML）
    Drivers.cs          内核进程管理（启停、诊断、孤儿清理）
    EmbeddedDriver.cs   内嵌内核释放与版本戳
    MihomoApi.cs        mihomo REST API 封装
    MihomoConfig.cs     配置生成、订阅下载、TUN 开关
    TraceRunner.cs      SOCKS 探测（HTTP / TLS 握手）
    Updater.cs          应用更新（GitHub Release）
    KernelUpdater.cs    内核更新（mihomo / zapret）
    UpdateCache.cs      更新检查缓存（6 小时）
  scripts/            运行时 PowerShell 脚本（16 个）
  setup/              安装器构建脚本 + 自签名证书 + 环境检查
  drivers/            内核二进制（mihomo.exe 需自行放入）
tools/                构建辅助（verify.ps1 / fix-bom.ps1 / shot.ps1）
CHANGELOG.md          版本更新日志
docs/                 构建系统、踩坑记录、验证清单
```

---

## 常见问题

**Q：提示「GitHub API 限流」怎么办？**
匿名 API 每小时 60 次。等一小时，或直接点「检查更新」（会强制刷新），其余功能不受影响。

**Q：更新下载失败 / 卡住？**
国内直连 `github.com` 不通，更新器会自动尝试镜像。若全部失败，可手动从
`https://ghproxy.net/https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe`
下载后手动安装。

**Q：为什么"节点 Ping"测不出游戏服的延迟？**
游戏服（如 Photon `82.117.224.x`）通常只回 ICMP 或专用 UDP 协议。ICMP 无法走代理，
TCP 端口又不开放，所以逐节点测不出来。能测的是目标有 TCP 服务的场景（如 `142.250.199.206:443`）。

**Q：winws 开启后立刻退出（ExitCode 1）？**
先看「内核 → 打开内核日志」。常见原因：
- 旧版服务 `VRChatBypass` 仍在运行 → 点「迁移旧服务」
- 另一个 winws 已在跑（同一份过滤器）→ 任务管理器结束后再启

**Q：TUN 开了之后路由追踪只剩 1 跳？**
TUN 会接管 ICMP，属正常现象。需要真实路径时先关 TUN。

**Q：卸载后 hosts 还有残留？**
正常卸载会清理标记块。若手工删除目录，请检查
`C:\Windows\System32\drivers\etc\hosts` 里是否有 `VRChat-bypass` 块并手动删除。

**Q：必须装 .NET 吗？**
运行不需要（单文件自包含）。只有从源码构建才需要 .NET 10 SDK。

---

## 已知限制

- **ICMP 不能走代理**：mihomo 对 ICMP 一律 `DIRECT`，因此逐节点测速使用 TCP+TLS 握手；
- **GitHub 匿名 API 限额**：每小时 60 次，已用 6 小时缓存缓解；
- **国内直连 GitHub 不通**：下载依赖镜像链；
- **同机多实例**：mihomo 的 `7891` / `9097` 端口固定，多个实例会抢占，表现为「订阅成功但节点为空」；
- **仅 Windows x64**：依赖 WinDivert 与 WPF。

---

## 开源许可与致谢

本项目站在一群优秀开源项目的肩膀上。**本仓库代码采用 [MIT 许可](LICENSE)**（第三方组件的完整许可见 [NOTICE.md](NOTICE.md)），
随附的第三方二进制各自遵循上游许可（尤其注意 WinDivert 与 Cygwin 的 LGPL）。

### 运行期依赖

| 项目 | 用途 | 许可 | 链接 |
|---|---|---|---|
| **mihomo**（Clash.Meta） | 代理内核：订阅节点、规则分流、TUN | MIT | https://github.com/MetaCubeX/mihomo |
| **zapret**（winws） | DPI 绕过内核（WinDivert 抓包 + desync 改写） | 自定义（仓库未附标准 LICENSE，请遵循上游说明） | https://github.com/bol-van/zapret |
| **zapret-win-bundle** | Windows 版 winws / cygwin / WinDivert 打包 | 同上 | https://github.com/bol-van/zapret-win-bundle |
| **WinDivert** | 用户态网络包拦截驱动 | **LGPL-3.0 / GPL-2.0 双许可** | https://github.com/basil00/WinDivert |
| **Cygwin**（cygwin1.dll） | winws 的 POSIX 运行层 | **LGPL-3.0 + 链接例外** | https://cygwin.com/ |

### 界面与框架

| 项目 | 用途 | 许可 | 链接 |
|---|---|---|---|
| **.NET / WPF** | 应用运行时与界面框架 | MIT | https://github.com/dotnet/wpf |
| **WPF-UI**（lepoco） | Fluent 风格控件库（NavigationView / Card / Button…） | MIT | https://github.com/lepoco/wpfui |
| **MicaSetup** | 安装器骨架（生成 .dist 后由本项目构建脚本编译） | MIT | https://github.com/LemonPrefect/MicaSetup |

### 数据与灵感

| 来源 | 用途 |
|---|---|
| [Cloudflare IP Ranges](https://www.cloudflare.com/ips/) / [AWS CloudFront IP Ranges](https://ip-ranges.amazonaws.com/ip-ranges.json) | hosts 优选的候选网段 |
| [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) | 节点卡片墙的交互参考 |
| [APNIC](https://www.apnic.net/) / [ipinfo](https://ipinfo.io/) | IP 归属查询 |

### 关于 LGPL 组件的说明

`WinDivert.dll` / `WinDivert64.sys`、`cygwin1.dll` 属于 LGPL 组件，本项目**以独立文件形式随包分发、未做静态链接或修改**，
符合 LGPL 的动态链接要求。若你需要修改这些组件，请自行从上游获取源码并重新编译，替换 `src\drivers\` 下的同名文件即可。

### 特别致谢

- **bol-van**：zapret 及其 Windows 打包，让 DPI 绕过在普通 Windows 上可用；
- **MetaCubeX**：mihomo 内核与其 REST API，订阅/节点/TUN 全部基于它；
- **basil00**：WinDivert，Windows 上做包级处理绕不开的基石；
- **lepoco**：WPF-UI，让一个工具软件也能有像样的 Fluent 界面。
## 免责声明

本项目代码采用 **MIT 许可**（见 [LICENSE](LICENSE)），随附第三方二进制遵循各自上游许可。

本项目仅供**学习与个人使用**。

- 工具会修改系统 hosts、加载内核驱动、可能开启 TUN 接管全局流量，请自行评估风险；
- 使用第三方订阅节点时，请遵守当地法律法规与服务商条款；
- 因使用本工具导致的网络异常、账号风险或其他损失，作者不承担责任。

---

## 相关

- 更新日志：[`CHANGELOG.md`](CHANGELOG.md)
- 构建说明：[`docs/构建系统.md`](docs/构建系统.md)
- 踩坑记录：[`docs/踩坑记录.md`](docs/踩坑记录.md)
- 上游项目：[mihomo](https://github.com/MetaCubeX/mihomo) · [zapret](https://github.com/bol-van/zapret) · [WPF-UI](https://github.com/lepoco/wpfui)
