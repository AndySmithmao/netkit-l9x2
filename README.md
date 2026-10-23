<div align="center">

<h1>VRChat Network Optimizer</h1>

<p>Windows network optimizer for VRChat — hosts optimization, plus optional winws (DPI) and mihomo (Clash.Meta) kernels.</p>

<a href="https://github.com/AndySmithmao/netkit-l9x2/releases"><img alt="Release" src="https://img.shields.io/github/v/release/AndySmithmao/netkit-l9x2?style=flat-square&color=1E9BFA"></a>
<a href="https://github.com/AndySmithmao/netkit-l9x2/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/AndySmithmao/netkit-l9x2/total?style=flat-square&color=1E9BFA"></a>
<img alt="Platform" src="https://img.shields.io/badge/platform-Windows%2010%2F11%20x64-1E9BFA?style=flat-square">
<img alt="License" src="https://img.shields.io/badge/license-MIT-green?style=flat-square">

</div>

<div align="center">

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md) · [Español](README.es.md)

</div>

WPF tool on .NET 10 for improving VRChat's network quality. It has two independent paths: optimize the `hosts` file
so VRChat domains resolve to well-performing IPs, or route matching traffic through a proxy kernel.
Both can be used alone or together.

Current version `0.0.2-beta`. Features and UI may still change.

## Features

* **hosts optimization** — scan Cloudflare and CloudFront ranges, measure latency and download throughput, write the best IPs
  * full scan over 5956 Cloudflare /24 and 16552 CloudFront /24 ranges, pre-filtered with ICMP + TLS
  * multi-round latency measurement and real download benchmarking, ruling out "low latency but low bandwidth" hosts
  * entries are written between markers, so uninstall can clean them precisely
* **one-click flow** — environment check → full scan → latency test → download test → candidate list → write hosts → verify
* **kernel management**
  * `winws` (zapret) for DPI desync, `mihomo` (Clash.Meta) for proxy routing
  * independent start / stop / restart per kernel, with version display
  * runs as application-managed child processes, stopped together when the app exits
* **subscription and nodes**
  * import Clash subscriptions; sends a Clash user agent, tolerates base64 v2ray link formats
  * card-style node list (inspired by Clash Verge), click to switch, batch latency test
  * TUN and proxy-mode toggles
* **Ping** — for a given IP or host, measure real round-trip through every node via TCP + TLS handshake, sorted ascending
* **updates** — startup check for app and both kernels, asks before updating; kernel updates back up and roll back on failure
* **localization** — 简体中文 / English / 日本語 / 한국어 / Русский / Español, switchable in settings
* **region-aware scanning** — first launch asks for continent and country; the full scan then only probes prefixes in that
  region, which cuts the candidate set from ~22k /24s to a few hundred. The bundled IP-geo database (DB-IP Lite, ~362k
  ranges) ships inside the installer, and can be refreshed from the app at any time
* **normal minimize** — minimizing keeps the window in the taskbar; the tray icon is used when closing the window
* **tray and autostart** — minimize to tray; kernels only start with the app if you explicitly enable it

## Download

> [!NOTE]
> Asset names are fixed, so both links always point at the latest build.
>
> If `github.com` is unreachable on your network, prepend a mirror: `https://ghproxy.net/` before the URL.

| Version | Link |
| --- | --- |
| Installer (recommended) | [VRChat-Selector-Setup.exe](https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe) |
| Portable (no install) | [VRChat-Selector-Portable.exe](https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Portable.exe) |

All builds: [Releases](https://github.com/AndySmithmao/netkit-l9x2/releases)

## Requirements

* Windows 10 or 11, x64
* Administrator rights — writing the hosts file, loading the WinDivert driver and enabling TUN all need it
* No .NET runtime installation required (single-file, self-contained build)

## Usage

**hosts only.** Open *One-click* and press start. Wait for the scan and benchmarks, pick an IP from the list,
the tool writes it to hosts and verifies.

**With proxy nodes.** Paste a Clash subscription in *Subscription*, pick a node in *Nodes*, start mihomo in *Kernel*.
Enable TUN on the Nodes page and restart mihomo if you want all traffic proxied.

**DPI desync.** Start winws in *Kernel*. If an older version registered a `VRChatBypass` service,
run *Migrate legacy service* first, otherwise two filters compete for the same handle.

> [!IMPORTANT]
> The tool modifies the system hosts file, loads a kernel driver and may enable TUN, which redirects machine-wide
> traffic. Review the risks before running it on a machine you rely on.

## FAQ

* **Why does per-node testing not use ICMP?**
  mihomo handles ICMP as an unconditional DIRECT, so the kernel cannot pass ICMP to a proxy. Measuring the same IP
  through US, Japanese and Hong Kong nodes returned about 172 ms every time — that is the local direct path.
  Node Ping therefore performs a TCP + TLS handshake against port 443, which does separate nodes properly
  (87 / 80 / 551 ms in the same test).
* **Why can some targets not be measured per node?**
  If a target only answers ICMP or a proprietary UDP protocol — Photon game servers behave this way — no TCP port is
  available and per-node latency is not observable. Only the direct route can be inspected.
* **Why does an update check sometimes report a rate limit?**
  GitHub's anonymous API allows 60 requests per hour, and one startup check costs three. Results are cached for six
  hours; a manual check forces a refresh.
* **Why are the kernels not Windows services?**
  Earlier builds registered winws as a service. After `sc stop` the WFP filter objects were not released and the next
  start failed with `FWP_E_IN_USE 0x8032000A`, recoverable only by rebooting. Child processes avoid that entirely.
* **Why is the node list empty after importing a subscription?**
  mihomo binds ports 7891 and 9097. Another instance already running will conflict; stop it and restart mihomo from
  the Kernel page.

## Building

Requires the .NET 10 SDK; producing the installer also needs MSBuild from Visual Studio 2022 or 2026.

```powershell
git clone https://github.com/AndySmithmao/netkit-l9x2.git
cd netkit-l9x2

dotnet build src\app\VrcTool.csproj -c Release

powershell -File src\setup\build-installer.ps1
```

The build script first runs `tools\verify.ps1`, checking file encodings (anything containing non-ASCII must be UTF-8
with BOM), script syntax, duplication between script trees, leftover hardcoded paths, the embedded resource list and
version consistency. Any failure aborts the build.

`src\drivers\mihomo.exe` (about 61 MB) is not committed. Download `mihomo-windows-amd64-vX.Y.Z.zip` from upstream,
extract `mihomo.exe` into `src\drivers\`, and write `mihomo.VERSION.txt` such as `Mihomo Meta v1.19.32 windows amd64`
(the updater compares against it). winws.exe, cygwin1.dll and both WinDivert files are included.

## Acknowledgements

This project depends on the work of:

* [mihomo (Clash.Meta)](https://github.com/MetaCubeX/mihomo) — proxy kernel
* [zapret](https://github.com/bol-van/zapret) / [zapret-win-bundle](https://github.com/bol-van/zapret-win-bundle) — DPI desync
* [WinDivert](https://github.com/basil00/WinDivert) — packet interception driver
* [Cygwin](https://cygwin.com/) — POSIX layer used by winws
* [WPF-UI](https://github.com/lepoco/wpfui) — Fluent controls
* [MicaSetup](https://github.com/LemonPrefect/MicaSetup) — installer skeleton
* [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) — interaction reference for the node list

Third-party licensing details, including LGPL obligations for WinDivert and cygwin1.dll, are in [NOTICE.md](NOTICE.md).

## License

Project code is MIT — see [LICENSE](LICENSE). Bundled kernel binaries keep their upstream licenses.

## Feedback

Open an [issue](https://github.com/AndySmithmao/netkit-l9x2/issues) for bugs or suggestions.
Please include the version, the page you were on, and the relevant lines from `data\logs\session-*.log`.

## Disclaimer

This project is a general-purpose network diagnostic and routing tool. It is not designed for, or directed at, any
particular country, region or network operator.

You are responsible for complying with the laws and regulations applicable in your jurisdiction, and with the terms of
service of your network operator, VPN or proxy provider. Do not use this tool to circumvent rules you are bound by.

The software is provided as is, without warranty of any kind. The authors accept no liability for any damage, service
interruption, account action or other loss arising from its use.
