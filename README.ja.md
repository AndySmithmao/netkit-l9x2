<div align="center">

<h1>VRChat Network Optimizer</h1>

<p>VRChat の通信品質を改善する Windows 用ツール — hosts 最適化と、オプションの winws（DPI 回避）/ mihomo（Clash.Meta）カーネル。</p>

<a href="https://github.com/AndySmithmao/netkit-l9x2/releases"><img alt="Release" src="https://img.shields.io/github/v/release/AndySmithmao/netkit-l9x2?style=flat-square&color=1E9BFA"></a>
<a href="https://github.com/AndySmithmao/netkit-l9x2/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/AndySmithmao/netkit-l9x2/total?style=flat-square&color=1E9BFA"></a>
<img alt="Platform" src="https://img.shields.io/badge/platform-Windows%2010%2F11%20x64-1E9BFA?style=flat-square">
<img alt="License" src="https://img.shields.io/badge/license-MIT-green?style=flat-square">

</div>

<div align="center">

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md) · [Español](README.es.md)

</div>
VRChat の通信品質を改善する Windows 用デスクトップツールです。winws（zapret の DPI 回避）と
mihomo（Clash.Meta）の 2 つのカーネルを内蔵し、プロキシを使わない hosts 最適化も提供します。
WPF / .NET 10 製で、実行には管理者権限が必要です。

現在のバージョンは 0.0.4-beta で、機能と設定は変更される可能性があります。

## 解決する課題

VRChat の接続品質は Photon サーバーまでの経路に左右されます。ネットワークによっては次のような状況が発生します。

- DNS が返す IP の品質が悪く、遅延やパケットロスが増える
- 国際経路が大きく迂回し、1 ホップで 100 ms 以上増えることがある
- 経路の一部で DPI による干渉があり、ハンドシェイク失敗や頻繁な再接続が起きる

前者 2 つに対しては、Cloudflare と CloudFront のアドレス範囲を走査し、遅延とダウンロード速度を実測して
成績の良い IP を hosts に書き込みます。3 つ目や、別地域から出入りしたい場合には、プロキシカーネルが
ルールに従って振り分けます。両者は単独でも併用でも構いません。

## ダウンロード

Release のファイル名は固定なので、次のリンクは常に最新版を指します。

- インストーラー: `https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe`
- ポータブル版: `https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Portable.exe`

一部のネットワークでは github.com への接続が不安定です。ミラーを前置できます。

```
https://ghproxy.net/https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe
```

内蔵のアップデーターも同じミラーを使い、ghproxy.net、gh-proxy.com、ghfast.top の順に試します。

インストーラーは自己署名のため、SmartScreen が「不明な発行元」と警告する場合があります。
「実行」を選んでください。既定のインストール先は `C:\Program Files\VRChat优选工具` で、
起動時に管理者権限を要求します（hosts の書き込み、WinDivert ドライバーの読み込み、TUN の有効化に必要）。

## 3 つの使い方

**hosts 最適化のみ。** 「ワンクリック」を開いて開始します。環境チェック、全範囲スキャン、遅延測定、
ダウンロード計測のあと候補一覧が表示されるので、IP を選ぶと hosts に書き込んで検証します。
プロキシを入れたくない場合に向いています。

**プロキシノードを使う。** 「購読」ページで Clash の購読 URL を読み込み、「ノード」ページでノードを選び、
「カーネル」ページで mihomo を起動します。全通信をプロキシ経由にする場合は TUN を有効にして
mihomo を再起動してください。ノード選びの前に「Ping」ページで比較できます。

**winws で DPI を回避する。** 「カーネル」ページで winws を起動します。desync 設定は内蔵のものを使用します。
以前のバージョンが `VRChatBypass` サービスを登録している場合は、先に「旧サービスを移行」を実行してください。
2 つのフィルターが同じハンドルを奪い合います。

## 画面構成

左のナビゲーションは用途別に分かれています。「ワンクリック」は上記の自動フロー、
「運用」はインストール・アンインストール・診断、「ワークフロー」は全範囲スキャン、遅延測定、
ダウンロード計測、一覧からの選択という 4 つの個別ステップです。

「カーネルとプロキシ」は 4 ページあります。

- カーネル: winws と mihomo の開始・停止・再起動、現在のバージョン、診断、旧サービス移行
- 購読: 購読 URL の読み込みと更新。保存すると mihomo が自動で起動します
- ノード: カード形式のノード一覧。クリックで切り替え、一括遅延測定、TUN とプロキシモードの切り替え
- Ping: 指定した IP またはホスト名に対し、各ノード経由で TCP + TLS ハンドシェイクを実行し、遅延の昇順で表示

設定ページにはテーマ、UI スケール、アップデートの入口があります。

## Ping が ICMP を使わない理由

mihomo は ICMP を常に DIRECT で処理するため、カーネルは ICMP をプロキシに渡せません。
米国・日本・香港のノード経由で同じ IP を ping しても約 172 ms で並び、これはローカルの直結経路です。
数値に意味がないため、ここでの「ノード Ping」は TCP ハンドシェイク、すなわち 443 番ポートへの
完全な TLS ハンドシェイクで実測しています。ある Google の IP では香港 87 ms、日本 80 ms、米国 551 ms と
十分に差が出ます。

逆に、対象が ICMP か専用の UDP のみに応答する場合（Photon のゲームサーバーが該当）、
ノードごとの遅延は測れず、直結経路しか観測できません。

## hosts の書き込み方

選択した IP はシステムの hosts に一対のマーカーで囲んで書き込み、アンインストール時に削除します。

```
# ===== VRChat-bypass BEGIN =====
104.18.26.36  example.com
# ===== VRChat-bypass END =====
```

候補 IP は Cloudflare の 5956 個の /24 と CloudFront の 16552 個の /24 から生成し、
ICMP と TLS で一次選別したうえで、複数回の遅延測定と実ダウンロード計測を行います。

## カーネルを Windows サービスにしていない理由

初期のバージョンは winws を Windows サービスとして登録していましたが、`sc stop` の後で
WFP フィルターオブジェクトが解放されず、次の起動が `FWP_E_IN_USE 0x8032000A` で失敗し、
再起動するしかありませんでした。現在はアプリが子プロセスとして管理し、実行ファイルのパスで後始末します。
停止と起動を 3 回連続で行っても問題ありません。

- winws は WinDivert でパケットを取得・書き換え、内蔵の desync 設定を使用
- mihomo は購読ノードとルール分流を担当。TUN モードには管理者権限が必要

## 実行時のディレクトリ

```
C:\Program Files\VRChat优选工具\
  tools\                    実行時コンポーネント（winws.exe、WinDivert、cygwin1.dll）
  data\logs\session-*.log   セッションログ

C:\ProgramData\VrcTool\
  drivers\winws\            初回起動時に展開
  drivers\mihomo\           mihomo、設定、購読キャッシュ、state.json
  logs\drivers.log          各カーネルの出力
```

アプリを閉じるとカーネルプロセスも停止し、バックグラウンドに残りません。

## アップデート

起動から約 5 秒後にアプリと 2 つのカーネルのバージョンを確認し、新しければダイアログで確認します。
「いいえ」を選ぶと今回のセッションではスキップします。設定ページから手動確認もできます。

アプリの更新はインストーラーをダウンロードし、SHA256 を検証して起動し、自身は終了します。
カーネルの更新は旧ファイルを `.bak` に退避してから置き換え、起動を試みて失敗すればロールバックします。

結果は 6 時間キャッシュされます。GitHub の匿名 API は 1 時間 60 回で、起動時の確認に 3 リクエスト使うため、
繰り返し起動すると制限に達します。手動確認ではキャッシュを無視します。

## ソースからビルド

.NET 10 SDK が必要です。インストーラーの生成には Visual Studio 2022 または 2026 の MSBuild も必要です。

```
git clone https://github.com/AndySmithmao/netkit-l9x2.git
cd netkit-l9x2

dotnet build src\app\VrcTool.csproj -c Release

powershell -File src\setup\build-installer.ps1
```

ビルドスクリプトは最初に `tools\verify.ps1` を実行し、ファイルのエンコーディング（非 ASCII を含むものは
UTF-8 BOM 付き）、スクリプト構文、2 系統のスクリプトの一致、ハードコードされたパスの残存、
埋め込みリソースの一覧、バージョンの整合性を検査します。いずれかが失敗すると中止します。

### mihomo.exe は別途用意

`src\drivers\mihomo.exe` は約 61 MB のためリポジトリに含めていません。ビルド前に上流から
`mihomo-windows-amd64-vX.Y.Z.zip` を取得し、`mihomo.exe` を `src\drivers\` に置き、
`mihomo.VERSION.txt`（例: `Mihomo Meta v1.19.32 windows amd64`）を書き込みます。アップデーターはこの値で比較します。

winws.exe、cygwin1.dll、WinDivert の 2 ファイルはリポジトリに含まれています。

### 起こりやすいビルドの問題

`error CS1566: 読み取り WinDivert64.sys 失敗` は、実行中の winws がファイルを掴んでいるためです。
winws を停止するか、`obj` と `bin` を削除してから再ビルドしてください。

`verify.ps1` が BOM 不足を報告したら `tools\fix-bom.ps1` を実行します。

インストーラーが 2〜3 MB しかない場合、mica のパッケージ手順でペイロードが入っていません。
原因はバージョン番号の接尾辞（`0.0.1-beta` など）で、makemica は数値のみ受け付けます。
ビルドスクリプトは接尾辞を自動で外しますが、手動で実行するときは注意してください。

## 既知の問題

ICMP はプロキシできないため、ノード単位の計測は TCP ハンドシェイクに依存し、ICMP のみに応答する対象は測れません。

GitHub の匿名 API は 1 時間 60 回で、繰り返し起動すると制限に達する場合があります。6 時間のキャッシュで緩和しています。

mihomo は 7891 と 9097 を使用します。別のインスタンスが動いているとポートが衝突し、
購読の読み込みは成功するのにノード一覧が空になります。

WinDivert と WPF に依存するため Windows x64 のみ対応です。

## ライセンスと第三者コンポーネント

プロジェクトのコードは MIT（`LICENSE`）。同梱のカーネルバイナリは MIT ではなく、それぞれ上流の
ライセンスに従います。詳細は `NOTICE.md` を参照してください。WinDivert は LGPL-3.0 と GPL-2.0 の
デュアルライセンス、cygwin1.dll は LGPL-3.0 とリンク例外で、いずれも独立したファイルとして配布し、
静的リンクや改変は行っていません。

主な依存:

- mihomo（Clash.Meta）— https://github.com/MetaCubeX/mihomo
- zapret / zapret-win-bundle — https://github.com/bol-van/zapret
- WinDivert — https://github.com/basil00/WinDivert
- Cygwin — https://cygwin.com/
- .NET と WPF — https://github.com/dotnet/wpf
- WPF-UI — https://github.com/lepoco/wpfui

## 免責事項

本プロジェクトは汎用的なネットワーク診断・経路制御ツールであり、特定の国、地域、通信事業者を
対象としたものではありません。

本ソフトウェアは hosts の変更、カーネルドライバーの読み込み、TUN による全通信の転送を行う場合があります。
実行前にご自身でリスクを評価してください。

利用者は、自らが所在する国または地域の法令、ならびに通信事業者、VPN、プロキシサービスの利用規約を
遵守する責任を負います。遵守すべき規則を回避する目的で本ツールを使用しないでください。

作者は本ソフトウェアを現状のまま提供し、いかなる保証も行いません。利用に起因する損害、サービス停止、
アカウント措置その他の不利益について責任を負いません。

