# VRChat 网络优化工具

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md) · [Español](README.es.md)

Windows 桌面工具，用来改善 VRChat 的联机网络质量。内置两个内核：winws（zapret 的 DPI 绕过）与 mihomo（Clash.Meta 代理），
另外提供一条不依赖代理的 hosts 优选路径。界面用 WPF，.NET 10，运行时需要管理员权限。

当前版本 0.0.1-beta，功能和接口都还可能变动。

## 它解决什么问题

VRChat 的连接质量取决于到 Photon 服务器的链路。在某些网络环境中常见这几种情况：

一是 DNS 返回的 IP 质量差，延迟高或丢包；二是国际出口绕路，某一跳就直接增加上百毫秒；
三是部分链路存在 DPI 干扰，表现为握手失败或频繁重连。

针对前两种，工具扫描 Cloudflare 与 CloudFront 的网段，实测延迟和下载速度，把结果好的 IP 写入 hosts。
针对第三种以及需要从其他地区出入的情况，用代理内核按规则分流。两条路可以单独用，也可以同时开。

## 下载

Release 里的资产名是固定的，所以下面两个链接始终指向最新版本：

- 安装包：`https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe`
- 便携版：`https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Portable.exe`

部分网络访问 github.com 不稳定，可以在链接前加镜像前缀：

```
https://ghproxy.net/https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe
```

程序内置的更新器也走镜像，依次尝试 ghproxy.net、gh-proxy.com、ghfast.top。

安装包是自签名证书，SmartScreen 可能提示"未知发布者"，选择"仍要运行"。默认装到 `C:\Program Files\VRChat优选工具`。
运行时会请求一次管理员权限——写 hosts、加载 WinDivert 驱动、开启 TUN 都需要。

## 三种使用方式

**只用 hosts 优选。** 打开"一键完成"并开始。工具会做环境检查、全量扫描、延迟实测、下载测速，
最后给出候选清单，选一个 IP 后自动写入并验证。适合不希望引入代理的场景。

**用代理节点。** 在"订阅"页填入 Clash 订阅，在"节点"页选节点，然后在内核页启动 mihomo。
如果希望整机流量都经代理，在节点页勾选 TUN 并重启 mihomo。选节点前可以用"Ping"页比较各节点的延迟。

**用 winws 做 DPI 绕过。** 在内核页启动 winws，参数用内置的 desync 配置。
如果此前的版本注册过 `VRChatBypass` 服务，先点"迁移旧服务"，否则两个过滤器会抢同一份句柄。

## 页面说明

左侧导航按用途分组。一键完成是前面说的全自动流程；运维下是安装、卸载、诊断；
优选流程提供全量扫描、延迟实测、下载测速、清单选用四个单独入口，方便只做其中一步。

内核与代理分四页：

- 内核：winws 与 mihomo 各自的开、关、重启，显示当前版本，另有诊断与旧服务迁移
- 订阅：订阅链接的导入与更新，保存后自动拉起 mihomo
- 节点：卡片式节点列表，点一下切换，可批量测延迟，带 TUN 与代理模式开关
- Ping：对指定 IP 或域名，经每个节点做一次 TCP + TLS 握手，结果按延迟从低到高排列

设置页包含主题、界面缩放和应用更新入口。

## 关于 Ping 为什么不用 ICMP

mihomo 对 ICMP 的处理是一律 DIRECT，内核不支持把 ICMP 交给代理。
分别经美国、日本、香港节点 ping 同一个 IP，结果都在 172 ms 左右，说明走的是本机直连路径，
这个数字没有参考价值。所以这里的"节点 Ping"实际是 TCP 握手——对 443 端口做完整 TLS 握手取真实往返时间。
实测同一个 Google IP：香港 87 ms、日本 80 ms、美国 551 ms，区分度足够。

反过来，如果目标只响应 ICMP 或专用 UDP 协议（Photon 游戏服即如此），逐节点无法测出延迟，
只能观察直连路由。

## hosts 是怎么写的

选中的 IP 会写入系统 hosts，用一对标记包住，卸载时按标记清理：

```
# ===== VRChat-bypass BEGIN =====
104.18.26.36  example.com
# ===== VRChat-bypass END =====
```

候选 IP 来自 Cloudflare 的 5956 个 /24 与 CloudFront 的 16552 个 /24，先用 ICMP 与 TLS 粗筛，
再对留下的做多轮延迟实测和真实下载测速。

## 内核为什么不用 Windows 服务

早期版本把 winws 注册成 Windows 服务。`sc stop` 之后 WFP 过滤器对象没有被释放，
再次启动报 `FWP_E_IN_USE 0x8032000A`，只能重启系统恢复。
现在改为应用托管的子进程，按可执行文件路径清理，连续三次开关都正常。

两个内核的运行方式：

- winws 通过 WinDivert 抓包并改写报文，使用内置的 desync 配置
- mihomo 负责订阅节点与规则分流，TUN 模式需要管理员权限

## 运行时目录

```
C:\Program Files\VRChat优选工具\
  tools\                    运行时组件（winws.exe、WinDivert、cygwin1.dll）
  data\logs\session-*.log   会话日志

C:\ProgramData\VrcTool\
  drivers\winws\            首次启动时释放
  drivers\mihomo\           mihomo、配置、订阅缓存、state.json
  logs\drivers.log          两个内核的输出
```

关闭应用时会一并停止内核进程，不会留下后台残留。

## 更新

启动约五秒后检查一次应用与两个内核的版本，发现新版本会弹窗询问，选择"否"本次跳过。设置页也可以手动检查。

应用更新会下载安装包、校验 SHA256、启动安装程序并退出自身。
内核更新先把旧文件改名为 `.bak`，替换后尝试启动，失败则回滚。

检查结果缓存六小时。GitHub 匿名 API 每小时 60 次配额，一次启动检查要发三个请求，
反复启动容易触发限流，手动检查会强制刷新。

## 从源码构建

需要 .NET 10 SDK；生成安装器还需要 Visual Studio 2022 或 2026 的 MSBuild。

```
git clone https://github.com/AndySmithmao/netkit-l9x2.git
cd netkit-l9x2

dotnet build src\app\VrcTool.csproj -c Release

powershell -File src\setup\build-installer.ps1
```

构建脚本会先运行 `tools\verify.ps1`，检查文件编码（含非 ASCII 内容必须是带 BOM 的 UTF-8）、脚本语法、
两套脚本是否一致、是否残留硬编码路径、内嵌资源清单、版本号一致性。任一项失败即中止。

### mihomo.exe 需要自行提供

`src\drivers\mihomo.exe` 约 61 MB，未提交到仓库。构建前从上游下载
`mihomo-windows-amd64-vX.Y.Z.zip`，解压出 `mihomo.exe` 放入 `src\drivers\`，
并写入 `mihomo.VERSION.txt`（更新器用它比较版本），内容形如 `Mihomo Meta v1.19.32 windows amd64`。

winws.exe、cygwin1.dll 与两个 WinDivert 文件已包含在仓库中。

### 可能遇到的构建问题

`error CS1566: 读取资源 WinDivert64.sys 失败` 说明该文件被运行中的 winws 占用。
停止 winws，或删除 `obj`、`bin` 后重新构建。

若 `verify.ps1` 报缺少 BOM，运行一次 `tools\fix-bom.ps1`。

安装包只有两三兆，说明 mica 打包步骤没有把 payload 塞进去，通常是因为版本号带了后缀（如 `0.0.1-beta`），
而 makemica 只接受数字版本。构建脚本会自动剥离后缀，手工调用时需要注意。

## 已知问题

ICMP 无法经代理，逐节点测试只能依赖 TCP 握手，仅响应 ICMP 的目标无法测量。

GitHub 匿名 API 每小时 60 次，反复启动可能触发限流，有六小时缓存兜底。

mihomo 固定监听 7891 与 9097。若本机已有其他实例在运行会发生端口冲突，
表现为订阅导入成功但节点列表为空。

仅支持 Windows x64，因为依赖 WinDivert 与 WPF。

## 许可与第三方组件

项目代码使用 MIT 许可，见 `LICENSE`。随仓库分发的内核二进制不适用 MIT，各自遵循上游许可，
明细见 `NOTICE.md`。其中 WinDivert 为 LGPL-3.0 与 GPL-2.0 双许可，cygwin1.dll 为 LGPL-3.0 加链接例外，
两者均以独立文件形式分发，未做静态链接或修改。

主要依赖：

- mihomo（Clash.Meta）— https://github.com/MetaCubeX/mihomo
- zapret / zapret-win-bundle — https://github.com/bol-van/zapret
- WinDivert — https://github.com/basil00/WinDivert
- Cygwin — https://cygwin.com/
- .NET 与 WPF — https://github.com/dotnet/wpf
- WPF-UI — https://github.com/lepoco/wpfui

## 免责声明

本项目是通用的网络诊断与路由工具，不针对任何特定国家、地区或网络运营商。

软件会修改系统 hosts、加载内核驱动，并可能开启 TUN 接管整机流量，运行前请自行评估风险。

使用者应当遵守其所在国家或地区的法律法规，以及网络运营商、VPN 或代理服务商的条款。
请勿将本工具用于规避你本应遵守的规则。

作者按"现状"提供本软件，不附带任何担保，对使用本软件引起的任何损害、服务中断、账号处置或其他损失不承担责任。
