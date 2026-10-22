# VRChat Network Optimizer

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md) · [Español](README.es.md)

A Windows desktop tool that improves VRChat's network quality. It ships two kernels — winws (zapret's DPI desync)
and mihomo (Clash.Meta) — plus a proxy-free path that optimizes DNS/hosts resolution. Built with WPF on .NET 10,
runs with administrator privileges.

Version 0.0.1-beta. APIs and UI may still change.

## What it addresses

VRChat's connection quality depends on the route to Photon servers. In some networks you run into one or more of:

- DNS returns poorly performing IPs, causing high latency or packet loss;
- international transit takes a long detour, where a single backbone hop can add well over 100 ms;
- parts of the path are subject to DPI interference, showing up as failed handshakes or frequent reconnects.

For the first two, the tool scans Cloudflare and CloudFront address ranges, measures latency and download throughput,
and writes the best-performing IPs into the hosts file. For the third, and for cases where traffic needs to leave through
a different region, a proxy kernel routes matching traffic by rule. The two approaches work independently or together.

## Download

Release assets use fixed filenames, so these links always point at the newest build:

- Installer: `https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe`
- Portable: `https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Portable.exe`

GitHub downloads can be unreliable on some networks. A mirror prefix can be prepended:

```
https://ghproxy.net/https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe
```

The built-in updater uses the same mirrors, trying ghproxy.net, gh-proxy.com and ghfast.top in order.

The installer is self-signed, so SmartScreen may warn about an unknown publisher; choose "Run anyway".
Default install path is `C:\Program Files\VRChat优选工具`. The app requests administrator rights at startup —
writing hosts, loading the WinDivert driver and enabling TUN all require it.

## Three ways to use it

**hosts optimization only.** Open "One-click" and press start. The tool runs an environment check, a full range scan,
latency measurement, download benchmarking, then shows a candidate list; pick an IP and it writes and verifies it.
Suited to setups where no proxy is wanted.

**With proxy nodes.** Paste a Clash subscription on the Subscription page, pick a node on the Nodes page,
then start mihomo on the Kernel page. Enable TUN on the Nodes page (and restart mihomo) if you want all traffic proxied.
The Ping page helps compare nodes before choosing.

**DPI desync with winws.** Start winws on the Kernel page; it uses the bundled desync profile.
If an older version once registered a `VRChatBypass` service, run "Migrate legacy service" first,
otherwise two filters will compete for the same handle.

## Pages

The left navigation is grouped by purpose. One-click is the automated flow described above.
Ops holds install, uninstall and diagnostics. Workflow has the four individual steps — full scan, latency test,
download test, pick from list — if you only want one of them.

Kernel & Proxy has four pages:

- Kernel: start, stop and restart each of winws and mihomo, current version, diagnostics, legacy service migration
- Subscription: import and update subscription URLs; saving starts mihomo automatically
- Nodes: card-style node list, click to switch, batch latency test, TUN and proxy-mode toggles
- Ping: for a given IP or hostname, perform a TCP + TLS handshake through each node, sorted by latency

Settings covers theme, UI scale and the application update entry point.

## Why Ping is not ICMP

mihomo handles ICMP with an unconditional DIRECT, so the core cannot hand ICMP to a proxy.
Measuring the same IP through US, Japanese and Hong Kong nodes returned roughly 172 ms every time,
which is the local direct path, so the number carries no information. "Node Ping" here is therefore a TCP handshake —
a full TLS handshake against port 443 to obtain real round-trip time. Measured against one Google IP:
Hong Kong 87 ms, Japan 80 ms, United States 551 ms, which separates nodes well enough.

The converse also holds: if a target only answers ICMP or a proprietary UDP protocol — Photon game servers behave
this way — per-node latency cannot be measured, and only the direct route is observable.

## How hosts entries are written

Selected IPs are written into the system hosts file between a pair of markers, which uninstall removes:

```
# ===== VRChat-bypass BEGIN =====
104.18.26.36  example.com
# ===== VRChat-bypass END =====
```

Candidate IPs come from 5956 Cloudflare /24 ranges and 16552 CloudFront /24 ranges, pre-filtered with ICMP and TLS,
then measured with multiple latency rounds plus a real download benchmark.

## Why the kernels are not Windows services

Earlier builds registered winws as a Windows service. After `sc stop` the WFP filter objects were not released,
and the next start failed with `FWP_E_IN_USE 0x8032000A`, recoverable only by rebooting.
The kernel now runs as an application-managed child process, cleaned up by executable path;
three consecutive stop/start cycles complete without error.

How the kernels run:

- winws captures and rewrites packets through WinDivert using the bundled desync profile
- mihomo handles subscription nodes and rule-based routing; TUN mode needs administrator rights

## Runtime directories

```
C:\Program Files\VRChat优选工具\
  tools\                    runtime components (winws.exe, WinDivert, cygwin1.dll)
  data\logs\session-*.log   session logs

C:\ProgramData\VrcTool\
  drivers\winws\            extracted on first start
  drivers\mihomo\           mihomo, config, subscription cache, state.json
  logs\drivers.log          output of both kernels
```

Closing the application stops the kernel processes, leaving nothing running in the background.

## Updates

About five seconds after startup the app checks the application and both kernels, and asks before updating;
declining skips this session. The settings page also exposes a manual check.

An application update downloads the installer, verifies its SHA256, launches it and exits.
A kernel update renames the old files to `.bak` first, replaces them, then tries to start the new binary,
rolling back if it fails.

Results are cached for six hours. GitHub's anonymous API allows 60 requests per hour, and one startup check costs
three requests, so repeated launches would otherwise hit the rate limit. A manual check forces a refresh.

## Building from source

Requires the .NET 10 SDK; producing the installer additionally needs MSBuild from Visual Studio 2022 or 2026.

```
git clone https://github.com/AndySmithmao/netkit-l9x2.git
cd netkit-l9x2

dotnet build src\app\VrcTool.csproj -c Release

powershell -File src\setup\build-installer.ps1
```

The build script first runs `tools\verify.ps1`, which checks file encodings (anything containing non-ASCII must be
UTF-8 with BOM), script syntax, duplication between the two script trees, leftover hardcoded paths,
the embedded resource list and version consistency. Any failure aborts the build.

### mihomo.exe must be supplied

`src\drivers\mihomo.exe` is about 61 MB and is not committed. Before building, download
`mihomo-windows-amd64-vX.Y.Z.zip` from upstream, extract `mihomo.exe` into `src\drivers\`, and write
`mihomo.VERSION.txt` (the updater compares against it), for example `Mihomo Meta v1.19.32 windows amd64`.

winws.exe, cygwin1.dll and both WinDivert files are included in the repository.

### Build problems you may hit

`error CS1566: failed to read resource WinDivert64.sys` means the file is locked by a running winws.
Stop it, or delete `obj` and `bin` and rebuild.

If `verify.ps1` reports a missing BOM, run `tools\fix-bom.ps1` once.

An installer of only two or three megabytes means the mica packaging step did not embed the payload.
The usual cause is a version string with a suffix (`0.0.1-beta`): makemica accepts numeric versions only.
The build script strips the suffix automatically, so be careful when invoking it by hand.

## Known issues

ICMP cannot be proxied, so per-node testing relies on TCP handshakes and targets that answer only ICMP cannot be measured.

GitHub's anonymous API allows 60 requests per hour; repeated launches may hit the limit, mitigated by the six-hour cache.

mihomo binds ports 7891 and 9097. If another instance is already running, the ports conflict and the symptom is
a successful subscription import followed by an empty node list.

Windows x64 only, due to WinDivert and WPF.

## License and third-party components

Project code is MIT, see `LICENSE`. Kernel binaries shipped with the repository are not MIT; each follows its
upstream license, detailed in `NOTICE.md`. WinDivert is dual-licensed LGPL-3.0 or GPL-2.0, cygwin1.dll is LGPL-3.0
with a linking exception; both are distributed as separate files, without static linking or modification.

Main dependencies:

- mihomo (Clash.Meta) — https://github.com/MetaCubeX/mihomo
- zapret / zapret-win-bundle — https://github.com/bol-van/zapret
- WinDivert — https://github.com/basil00/WinDivert
- Cygwin — https://cygwin.com/
- .NET and WPF — https://github.com/dotnet/wpf
- WPF-UI — https://github.com/lepoco/wpfui

## Disclaimer

This project is a general-purpose network diagnostic and routing tool. It is not designed for, or directed at,
any particular country, region or network operator.

The software modifies the system hosts file, loads a kernel driver and may enable TUN, which redirects machine-wide
traffic. Evaluate the risks yourself before running it.

You are responsible for complying with the laws and regulations applicable in your jurisdiction, and with the terms
of service of your network operator, VPN or proxy provider. Do not use this tool to circumvent rules you are bound by.

The authors provide the software as is, without warranty of any kind, and accept no liability for any damage,
service interruption, account action or other loss arising from its use.
