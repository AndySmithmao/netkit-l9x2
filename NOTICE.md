# 第三方组件

本仓库代码用 MIT（见 `LICENSE`）。随仓库分发的二进制不适用 MIT，各自跟随上游许可。

## 内核与运行时

`src/drivers/winws.exe` 来自 zapret 的 Windows 打包（bol-van/zapret-win-bundle）。
上游仓库没有附标准 LICENSE 文件，README 里引用了一份 LICENSE.txt 但仓库根目录找不到，
分发前请先确认上游的授权说明。

`src/drivers/cygwin1.dll` 是 Cygwin 的运行库，LGPL-3.0 加链接例外，源码在 https://cygwin.com/ 。

`src/drivers/WinDivert.dll` 和 `WinDivert64.sys` 来自 WinDivert，双许可：LGPL-3.0 或 GPL-2.0，可任选其一，
源码在 https://github.com/basil00/WinDivert 。

`mihomo.exe` 不随仓库分发，需要自己从 https://github.com/MetaCubeX/mihomo 下载，MIT 许可。

关于 LGPL：WinDivert 和 cygwin1.dll 都以独立文件形式随包分发，没有做静态链接，也没有修改源码，
符合 LGPL 对动态链接的要求。如果需要替换或修改，直接用上游编译的版本覆盖 `src\drivers\` 下的同名文件即可，
不用改本项目代码。

## 框架

.NET 与 WPF（https://github.com/dotnet/wpf），MIT。
WPF-UI（https://github.com/lepoco/wpfui），MIT，Fluent 风格控件。
MicaSetup（https://github.com/LemonPrefect/MicaSetup），MIT，安装器骨架。

## 数据来源

hosts 优选的候选网段来自 Cloudflare 公布的 IP 段和 AWS CloudFront 的 ip-ranges.json。
IP 归属查询用过 APNIC 和 ipinfo 的公开数据。

节点卡片墙的交互参考了 Clash Verge Rev（https://github.com/clash-verge-rev/clash-verge-rev）。
