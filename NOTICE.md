# NOTICE — 第三方组件与许可

本仓库 **代码** 采用 [MIT 许可](LICENSE)。
**随附的第三方二进制**各自遵循上游许可，列表如下；如需再分发，请同时满足对应许可的条款。

## 运行期二进制

| 组件 | 文件 | 许可 | 上游 |
|---|---|---|---|
| mihomo（Clash.Meta） | `src/drivers/mihomo.exe`（不在仓库，需自行放入） | MIT | https://github.com/MetaCubeX/mihomo |
| zapret（winws） | `src/drivers/winws.exe` | 自定义（仓库未附标准 LICENSE，请遵循上游说明） | https://github.com/bol-van/zapret |
| zapret-win-bundle | Windows 打包来源 | 同上 | https://github.com/bol-van/zapret-win-bundle |
| WinDivert | `src/drivers/WinDivert.dll`、`WinDivert64.sys` | **LGPL-3.0 或 GPL-2.0（双许可，二选一）** | https://github.com/basil00/WinDivert |
| Cygwin | `src/drivers/cygwin1.dll` | **LGPL-3.0 + 链接例外** | https://cygwin.com/ |

### LGPL 合规说明

- `WinDivert.dll` / `WinDivert64.sys` / `cygwin1.dll` 以**独立文件**形式随包分发，
  本项目未链接、未修改其源码，符合 LGPL 动态链接要求；
- 若你需要替换或修改这些组件，可直接用上游编译的版本覆盖 `src\drivers\` 下的同名文件，无需改动本项目代码；
- 上游源码与许可全文见上表链接。

## 框架与依赖

| 组件 | 用途 | 许可 | 上游 |
|---|---|---|---|
| .NET / WPF | 运行时与界面框架 | MIT | https://github.com/dotnet/wpf |
| WPF-UI（lepoco） | Fluent 控件库 | MIT | https://github.com/lepoco/wpfui |
| MicaSetup | 安装器骨架 | MIT | https://github.com/LemonPrefect/MicaSetup |

## 数据来源

| 来源 | 用途 |
|---|---|
| Cloudflare IP Ranges | hosts 优选的候选网段 |
| AWS CloudFront ip-ranges.json | hosts 优选的候选网段 |
| APNIC / ipinfo | IP 归属查询 |

## 灵感与参考

- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev)：节点卡片墙的交互参考。