# VRChat 网络优化工具

Windows 桌面工具，用来改善 VRChat 的联机网络质量。内置两个内核：winws（zapret 的 DPI 绕过）和 mihomo（Clash.Meta 代理），
同时提供一条不依赖代理的 hosts 优选路径。界面用 WPF，.NET 10，需要管理员权限运行。

当前版本 0.0.1-beta，功能和接口都还可能变。

## 它解决什么问题

VRChat 的连接质量取决于到 Photon 服务器的链路。国内直连常见的三种情况：

一是 DNS 给到的 IP 质量差，延迟高或丢包；二是国际出口绕路，比如从移动骨干到 PCCW 东京这一段，
一跳就多出 160 ms 左右；三是部分链路存在 DPI 干扰，表现为握手失败或频繁重连。

针对前两种，工具的做法是扫描 Cloudflare 和 CloudFront 的网段，实测延迟和下载速度，把结果好的 IP 写进 hosts。
针对第三种和需要跨区域的情况，用一个代理内核按规则分流。两条路可以单独用，也可以一起开。

## 下载

安装包和便携版都在 Releases 里，资产名是固定的，所以下面这两个链接始终指向最新版：

- 安装包：`https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe`
- 便携版：`https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Portable.exe`

国内访问 github.com 经常不通，下载时可以加镜像前缀，例如：

```
https://ghproxy.net/https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe
```

程序自带的更新器也走镜像，直连失败会依次尝试 ghproxy.net、gh-proxy.com、ghfast.top。

安装包是自签名证书，SmartScreen 可能报"未知发布者"，选"仍要运行"。默认装到 `C:\Program Files\VRChat优选工具`，
运行时会请求一次管理员权限——写 hosts、加载 WinDivert 驱动、开 TUN 都需要。

## 三条使用路径

**只用 hosts 优选。** 打开"一键完成"，点开始。工具会做环境检查、全量扫描、延迟实测、下载测速，
最后弹一份候选清单，选一个 IP 后自动写入 hosts 并验证。适合不想开代理的情况。

**用代理节点。** 在"订阅"页填订阅链接导入，到"节点"页点卡片选节点，然后在内核页启动 mihomo。
如果想让全局流量都走代理，在节点页勾上 TUN 并重启 mihomo。选节点前可以先在"Ping"页比较各节点对目标 IP 的延迟。

**用 winws 做 DPI 绕过。** 在内核页启动 winws 即可，参数用内置的 desync 配置。
如果装过旧版本、系统里还有 `VRChatBypass` 服务，先点"迁移旧服务"，否则两个过滤器会抢同一份句柄。

## 页面说明

左侧导航按用途分组。一键完成是前面说的全自动流程；运维下面是安装、卸载、诊断；
优选流程包含全量扫描、延迟实测、下载测速、清单选用四个单独入口，方便只做其中一步。

内核与代理这一组有四个页面：

- 内核：winws 和 mihomo 各自的开、关、重启，显示当前版本，另有诊断和旧服务迁移
- 订阅：订阅链接的导入与更新，保存后会自动拉起 mihomo
- 节点：卡片式节点列表，点一下切换，可以批量测延迟，带 TUN 和代理模式开关
- Ping：对指定 IP 或域名，经每个节点做一次 TCP + TLS 握手，结果按延迟从低到高排

设置页里除了主题和界面缩放，还有应用更新入口。

## 关于 Ping 为什么不用 ICMP

试过。mihomo 对 ICMP 的处理是一律走 DIRECT，内核不支持把 ICMP 交给代理。
把节点切到美国、日本、香港分别 ping 同一个 IP，数字都在 172 ms 上下，说明走的是本机直连路径，
再测也没有意义。所以这里的"节点 Ping"实际是 TCP 握手，对 443 端口做完整 TLS 握手来拿真实往返时间。
实测同一个 Google IP：香港 87 ms、日本 80 ms、美国 551 ms，区分度是够的。

反过来说，如果目标只有 ICMP 或专用 UDP 协议（Photon 的游戏服就是这样），逐节点就测不出延迟，
这种情况只能看直连路由。

## hosts 是怎么写的

扫描出来的 IP 会写进系统 hosts，用一对标记包住，卸载时按标记清理：

```
# ===== VRChat-bypass BEGIN =====
104.18.26.36  example.com
# ===== VRChat-bypass END =====
```

候选 IP 来自 Cloudflare 的 5956 个 /24 和 CloudFront 的 16552 个 /24，先用 ICMP 和 TLS 粗筛一轮，
再对留下的做多轮延迟和真实下载测速。

## 内核为什么不用 Windows 服务

早期版本把 winws 注册成 Windows 服务，`sc stop` 之后 WFP 过滤器对象没有被释放，
再启动就报 `FWP_E_IN_USE 0x8032000A`，只能重启系统。后来改成由应用托管子进程，
关闭时按 exe 路径清理，连续开关三次都正常。

两个内核现在的运行方式：

- winws 用 WinDivert 抓包并改写报文，参数是内置的 desync 配置
- mihomo 负责订阅节点和规则分流，TUN 模式需要管理员权限

## 运行时目录

```
C:\Program Files\VRChat优选工具\
  tools\                    运行时组件（winws.exe、WinDivert、cygwin1.dll）
  data\logs\session-*.log   会话日志

C:\ProgramData\VrcTool\
  drivers\winws\            首次启动时释放的 winws
  drivers\mihomo\           mihomo 与配置、订阅缓存、state.json
  logs\drivers.log          两个内核的输出
```

应用退出时会一起停掉内核进程，不会留后台残留。

## 更新

启动后大约 5 秒做一次检查，同时看应用和两个内核的版本，有新版就弹窗问，选"否"本次跳过。设置页也能手动检查。

应用更新会下载安装包、核对 SHA256、启动安装程序、然后自己退出。内核更新会先把旧文件改名成 `.bak` 再替换，
替换后试启动，起不来就回滚。

检查结果缓存 6 小时。原因是 GitHub 匿名 API 每小时只有 60 次配额，一次启动检查要发三个请求，
反复开程序很容易触发限流。手动点检查时会强制刷新。

## 从源码构建

需要 .NET 10 SDK，打包安装器还要 Visual Studio 2022 或 2026 的 MSBuild。

```
git clone https://github.com/AndySmithmao/netkit-l9x2.git
cd netkit-l9x2

dotnet build src\app\VrcTool.csproj -c Release

powershell -File src\setup\build-installer.ps1
```

构建脚本会先跑 `tools\verify.ps1`，检查文件编码（含中文的必须带 UTF-8 BOM）、脚本语法、
两份脚本是否一致、有没有残留的硬编码路径、内嵌资源清单、版本号是否一致。任一项不过就中止。

### mihomo.exe 需要自己放

`src\drivers\mihomo.exe` 有 61 MB，没有放进仓库。构建前从上游下一个
`mihomo-windows-amd64-vX.Y.Z.zip`，解压出 `mihomo.exe` 放到 `src\drivers\`，
再写一个 `mihomo.VERSION.txt` 记录版本（更新器靠它比较），内容形如
`Mihomo Meta v1.19.32 windows amd64`。

winws.exe、cygwin1.dll、WinDivert 的两个文件已经随仓库提供。

### 几个会碰到的构建问题

`error CS1566: 读取资源 WinDivert64.sys 失败` 是因为该文件被运行中的 winws 占用，
停掉 winws 或者清掉 `obj`、`bin` 再编。

`verify.ps1` 报缺 BOM 的话，跑一次 `tools\fix-bom.ps1`。

如果安装包只有两三 MB，说明 mica 打包那一步没有把 payload 塞进去。原因通常是版本号带了后缀
（`0.0.1-beta` 这种），makemica 只接受纯数字版本。构建脚本会自动剥掉后缀，手改的时候要注意。

## 已知问题

ICMP 不能走代理，所以逐节点测速只能用 TCP 握手，只有 ICMP 的目标测不了。

GitHub 匿名 API 每小时 60 次，连续启动程序可能触发限流，有 6 小时缓存兜底。

国内直连 github.com 不稳，下载依赖镜像。

mihomo 的端口固定是 7891 和 9097，如果本机同时跑着别的实例，会抢端口。
表现是订阅导入成功但节点列表为空。

只支持 Windows x64，因为依赖 WinDivert 和 WPF。

## 许可与第三方组件

本项目代码用 MIT，见 `LICENSE`。随仓库分发的内核二进制不适用 MIT，各自跟随上游许可，
明细在 `NOTICE.md`。其中 WinDivert 是 LGPL-3.0 与 GPL-2.0 双许可，cygwin1.dll 是 LGPL-3.0 加链接例外，
两者都以独立文件分发，未做静态链接或修改。

主要依赖：

- mihomo（Clash.Meta）https://github.com/MetaCubeX/mihomo
- zapret / zapret-win-bundle https://github.com/bol-van/zapret
- WinDivert https://github.com/basil00/WinDivert
- Cygwin https://cygwin.com/
- .NET 与 WPF https://github.com/dotnet/wpf
- WPF-UI https://github.com/lepoco/wpfui

## 免责声明

工具会修改系统 hosts、加载内核驱动、可能开启 TUN 接管全局流量，用之前自己评估风险。
使用第三方订阅节点时请遵守当地法律和服务商条款。因使用本工具造成的问题由使用者自行承担。
