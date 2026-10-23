<div align="center">

<h1>VRChat 网络优化工具</h1>

<p>面向 VRChat 的 Windows 网络优化工具 —— hosts 优选，另可选配 winws（DPI 绕过）与 mihomo（Clash.Meta）内核。</p>

<a href="https://github.com/AndySmithmao/netkit-l9x2/releases"><img alt="Release" src="https://img.shields.io/github/v/release/AndySmithmao/netkit-l9x2?style=flat-square&color=1E9BFA"></a>
<a href="https://github.com/AndySmithmao/netkit-l9x2/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/AndySmithmao/netkit-l9x2/total?style=flat-square&color=1E9BFA"></a>
<img alt="Platform" src="https://img.shields.io/badge/platform-Windows%2010%2F11%20x64-1E9BFA?style=flat-square">
<img alt="License" src="https://img.shields.io/badge/license-MIT-green?style=flat-square">

</div>

<div align="center">

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md) · [Español](README.es.md)

</div>

基于 .NET 10 / WPF 的桌面工具，用来改善 VRChat 的联机网络质量。提供两条相互独立的路径：
优化 hosts 让 VRChat 相关域名解析到表现好的 IP，或让匹配的流量经代理内核转发。两条路可以单独用，也可以同时开。

当前版本 `0.0.2-beta`，功能和界面仍在调整。

## 功能

* **hosts 优选** —— 扫描 Cloudflare 与 CloudFront 网段，实测延迟和下载速度，写入表现最好的 IP
  * 全量扫描覆盖 Cloudflare 5956 个 /24 与 CloudFront 16552 个 /24，先用 ICMP 与 TLS 粗筛
  * 多轮延迟实测加真实下载测速，排除"延迟低但带宽差"的地址
  * 写入时用一对标记包住，卸载可按标记精确清理
* **一键完成** —— 环境检查 → 全量扫描 → 延迟实测 → 下载测速 → 候选清单 → 写 hosts → 自动验证
* **内核管理**
  * `winws`（zapret）负责 DPI 绕过，`mihomo`（Clash.Meta）负责代理分流
  * 每个内核可独立开启、关闭、重启，并显示当前版本
  * 以应用托管的子进程运行，退出程序时一并停止
* **订阅与节点**
  * 导入 Clash 订阅，请求时携带 Clash UA，兼容 base64 的 v2ray 链接格式
  * 卡片式节点列表（交互参考 Clash Verge），点一下切换，支持批量测延迟
  * TUN 与代理模式开关
* **Ping** —— 对指定 IP 或域名，经每个节点做 TCP + TLS 握手取真实往返，结果按延迟升序排列
* **更新** —— 启动时检查应用与两个内核，弹窗询问后才更新；内核更新前备份，起不来自动回滚
* **多语言** —— 简体中文 / English / 日本語 / 한국어 / Русский / Español，设置页可切换
* **按区域扫描** —— 首次进入时选择大陆板块与国家/地区，全量扫描只探测该区域的网段：
  候选从约 2.2 万个 /24 收窄到几百个，速度提升明显。IP 归属库（DB-IP Lite，约 36 万条）随安装包内置，
  也可以在应用内重新查询更新
* **正常最小化** —— 点最小化留在任务栏；托盘改为响应"关闭"按钮
* **托盘与自启** —— 可最小化到托盘；只有显式开启时，启动程序才会拉起内核

## 下载

> [!NOTE]
> 资产名固定，所以下面两条链接始终指向最新版本。
>
> 如果你的网络访问 `github.com` 不稳定，可以在链接前加镜像前缀：`https://ghproxy.net/`

| 版本 | 链接 |
| --- | --- |
| 安装包（推荐） | [VRChat-Selector-Setup.exe](https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe) |
| 便携版（免安装） | [VRChat-Selector-Portable.exe](https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Portable.exe) |

全部版本见 [Releases](https://github.com/AndySmithmao/netkit-l9x2/releases)。

## 运行要求

* Windows 10 / 11，x64
* 管理员权限 —— 写 hosts、加载 WinDivert 驱动、开启 TUN 都需要
* 无需预装 .NET 运行时（单文件自包含发布）

## 使用方法

**只用 hosts 优选。** 打开「一键完成」点开始，等扫描和测速结束，在清单里挑一个 IP，工具会写入 hosts 并验证。

**用代理节点。** 在「订阅」页填入 Clash 订阅，到「节点」页选节点，再在「内核」页启动 mihomo。
如果希望整机流量都走代理，在节点页勾选 TUN 并重启 mihomo。

**DPI 绕过。** 在「内核」页启动 winws。如果旧版本注册过 `VRChatBypass` 服务，先点「迁移旧服务」，
否则两个过滤器会抢同一份句柄。

> [!IMPORTANT]
> 工具会修改系统 hosts、加载内核驱动，并可能开启 TUN 接管整机流量。在依赖正常网络的机器上使用前，请先评估风险。

## 常见问题

* **为什么逐节点测试不用 ICMP？**
  mihomo 对 ICMP 一律按 DIRECT 处理，内核无法把 ICMP 交给代理。分别经美国、日本、香港节点 ping 同一 IP，
  结果都在 172 ms 左右，那是本机直连路径。所以这里的 Ping 是对 443 端口做 TCP + TLS 握手，
  这样才能区分节点（同一次测试里 87 / 80 / 551 ms）。
* **为什么有些目标测不出逐节点延迟？**
  如果目标只响应 ICMP 或专用 UDP 协议（Photon 游戏服就是这样），就没有可用的 TCP 端口，逐节点延迟无从观测，
  只能看直连路由。
* **为什么检查更新有时提示限流？**
  GitHub 匿名 API 每小时 60 次，而一次启动检查要发三个请求。结果缓存六小时，手动检查会强制刷新。
* **为什么内核不做成 Windows 服务？**
  早期版本把 winws 注册成服务，`sc stop` 之后 WFP 过滤器对象没有释放，再次启动报 `FWP_E_IN_USE 0x8032000A`，
  只能重启系统。改成子进程后没有这个问题。
* **导入订阅后节点列表是空的？**
  mihomo 使用 7891 和 9097 端口，本机已有其他实例在跑就会冲突。结束它，再从内核页重启 mihomo。

## 从源码构建

需要 .NET 10 SDK；生成安装器还需要 Visual Studio 2022 或 2026 的 MSBuild。

```powershell
git clone https://github.com/AndySmithmao/netkit-l9x2.git
cd netkit-l9x2

dotnet build src\app\VrcTool.csproj -c Release

powershell -File src\setup\build-installer.ps1
```

构建脚本会先跑 `tools\verify.ps1`，检查文件编码（含非 ASCII 的必须是带 BOM 的 UTF-8）、脚本语法、
两套脚本是否一致、有无残留硬编码路径、内嵌资源清单、版本号一致性。任一项失败即中止。

`src\drivers\mihomo.exe` 约 61 MB，没有放进仓库。构建前从上游下载 `mihomo-windows-amd64-vX.Y.Z.zip`，
解压出 `mihomo.exe` 放进 `src\drivers\`，并写入 `mihomo.VERSION.txt`（例如 `Mihomo Meta v1.19.32 windows amd64`），
更新器靠它比较版本。winws.exe、cygwin1.dll 与两个 WinDivert 文件已随仓库提供。

## 致谢

本项目依赖以下项目：

* [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) —— 代理内核
* [zapret](https://github.com/bol-van/zapret) / [zapret-win-bundle](https://github.com/bol-van/zapret-win-bundle) —— DPI 绕过
* [WinDivert](https://github.com/basil00/WinDivert) —— 数据包拦截驱动
* [Cygwin](https://cygwin.com/) —— winws 使用的 POSIX 层
* [WPF-UI](https://github.com/lepoco/wpfui) —— Fluent 控件库
* [MicaSetup](https://github.com/LemonPrefect/MicaSetup) —— 安装器骨架
* [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) —— 节点卡片的交互参考

第三方组件的许可细节（含 WinDivert 与 cygwin1.dll 的 LGPL 义务）见 [NOTICE.md](NOTICE.md)。

## 许可证

项目代码使用 MIT，见 [LICENSE](LICENSE)。随仓库分发的内核二进制遵循各自上游许可。

## 问题反馈

Bug 与建议请提 [Issue](https://github.com/AndySmithmao/netkit-l9x2/issues)，
并附上版本号、出问题时的页面，以及 `data\logs\session-*.log` 里相关的几行。

## 免责声明

本项目是通用的网络诊断与路由工具，不针对任何特定国家、地区或网络运营商。

使用者应当遵守其所在国家或地区的法律法规，以及网络运营商、VPN 或代理服务商的条款。
请勿将本工具用于规避你本应遵守的规则。

软件按"现状"提供，不附带任何担保。作者对使用本软件引起的损害、服务中断、账号处置或其他损失不承担责任。
