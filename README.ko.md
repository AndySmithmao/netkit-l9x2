# VRChat Network Optimizer

[English](README.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md) · [Español](README.es.md)

VRChat의 네트워크 품질을 개선하는 Windows 데스크톱 도구입니다. winws(zapret의 DPI 우회)와
mihomo(Clash.Meta) 두 커널을 내장하고, 프록시 없이 동작하는 hosts 최적화 경로도 제공합니다.
WPF / .NET 10으로 만들었고 실행하려면 관리자 권한이 필요합니다.

현재 버전은 0.0.1-beta이며 기능과 설정은 변경될 수 있습니다.

## 해결하는 문제

VRChat의 연결 품질은 Photon 서버까지의 경로에 크게 좌우됩니다. 네트워크에 따라 다음과 같은 상황이 생깁니다.

- DNS가 반환한 IP의 품질이 낮아 지연과 패킷 손실이 커짐
- 국제 구간이 크게 우회하여 한 홉에서만 100 ms 이상 늘어남
- 경로 일부에서 DPI 간섭이 발생해 핸드셰이크 실패나 잦은 재연결이 일어남

앞의 두 경우에는 Cloudflare와 CloudFront 주소 대역을 스캔해 지연과 다운로드 속도를 측정한 뒤
성능이 좋은 IP를 hosts에 기록합니다. 세 번째 경우와 다른 지역을 경유해야 할 때는 프록시 커널이
규칙에 따라 분기합니다. 두 방식은 각각 또는 함께 사용할 수 있습니다.

## 다운로드

릴리스 자산 이름이 고정되어 있어 아래 링크는 항상 최신 빌드를 가리킵니다.

- 설치 패키지: `https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe`
- 포터블: `https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Portable.exe`

일부 네트워크에서는 github.com 접속이 불안정합니다. 미러 접두사를 붙일 수 있습니다.

```
https://ghproxy.net/https://github.com/AndySmithmao/netkit-l9x2/releases/latest/download/VRChat-Selector-Setup.exe
```

내장 업데이터도 같은 미러를 사용하며 ghproxy.net, gh-proxy.com, ghfast.top 순으로 시도합니다.

설치 패키지는 자체 서명이라 SmartScreen이 "알 수 없는 게시자"로 경고할 수 있습니다. "실행"을 선택하세요.
기본 설치 경로는 `C:\Program Files\VRChat优选工具`이고 시작 시 관리자 권한을 요청합니다
(hosts 쓰기, WinDivert 드라이버 로드, TUN 활성화에 필요).

## 세 가지 사용 방법

**hosts 최적화만 사용.** "원클릭"에서 시작을 누릅니다. 환경 점검, 전체 대역 스캔, 지연 측정,
다운로드 측정을 거쳐 후보 목록이 나오면 IP를 선택하고 hosts에 기록한 뒤 검증합니다.
프록시를 쓰고 싶지 않은 경우에 적합합니다.

**프록시 노드 사용.** "구독" 페이지에서 Clash 구독을 가져오고 "노드" 페이지에서 노드를 선택한 다음
"커널" 페이지에서 mihomo를 시작합니다. 모든 트래픽을 프록시로 보내려면 TUN을 켜고 mihomo를 재시작하세요.
노드를 고르기 전에 "Ping" 페이지에서 비교할 수 있습니다.

**winws로 DPI 우회.** "커널" 페이지에서 winws를 시작합니다. desync 설정은 내장된 값을 사용합니다.
이전 버전이 `VRChatBypass` 서비스를 등록했다면 먼저 "레거시 서비스 마이그레이션"을 실행하세요.
두 필터가 같은 핸들을 두고 경쟁합니다.

## 페이지 구성

왼쪽 내비게이션은 용도별로 묶여 있습니다. "원클릭"은 위의 자동 흐름, "운영"은 설치·제거·진단,
"워크플로"는 전체 스캔, 지연 측정, 다운로드 측정, 목록 선택의 네 단계를 개별적으로 제공합니다.

"커널 및 프록시"는 네 페이지입니다.

- 커널: winws와 mihomo의 시작·중지·재시작, 현재 버전, 진단, 레거시 서비스 마이그레이션
- 구독: 구독 URL 가져오기와 갱신. 저장하면 mihomo가 자동으로 시작됩니다
- 노드: 카드 형태 노드 목록, 클릭으로 전환, 일괄 지연 측정, TUN과 프록시 모드 전환
- Ping: 지정한 IP 또는 호스트에 대해 각 노드를 경유한 TCP + TLS 핸드셰이크를 수행하고 지연 오름차순으로 표시

설정 페이지에는 테마, UI 배율, 업데이트 항목이 있습니다.

## Ping이 ICMP를 쓰지 않는 이유

mihomo는 ICMP를 항상 DIRECT로 처리하므로 커널이 ICMP를 프록시로 넘길 수 없습니다.
미국·일본·홍콩 노드를 각각 거쳐 같은 IP를 ping해도 약 172 ms로 비슷하며, 이는 로컬 직결 경로입니다.
의미가 없어서 여기서의 "노드 Ping"은 TCP 핸드셰이크, 즉 443 포트에 대한 완전한 TLS 핸드셰이크로 측정합니다.
어떤 Google IP 기준 홍콩 87 ms, 일본 80 ms, 미국 551 ms로 차이가 충분합니다.

반대로 대상이 ICMP나 전용 UDP에만 응답하는 경우(Photon 게임 서버가 그렇습니다)에는
노드별 지연을 측정할 수 없고 직결 경로만 관찰할 수 있습니다.

## hosts 기록 방식

선택한 IP는 시스템 hosts에 한 쌍의 마커 사이에 기록되며 제거 시 마커 기준으로 정리됩니다.

```
# ===== VRChat-bypass BEGIN =====
104.18.26.36  example.com
# ===== VRChat-bypass END =====
```

후보 IP는 Cloudflare의 5956개 /24와 CloudFront의 16552개 /24에서 생성하고, ICMP와 TLS로 1차 선별한 뒤
여러 차례 지연 측정과 실제 다운로드 측정을 수행합니다.

## 커널을 Windows 서비스로 쓰지 않는 이유

초기 버전은 winws를 Windows 서비스로 등록했습니다. 그런데 `sc stop` 이후 WFP 필터 객체가 해제되지 않아
다음 시작이 `FWP_E_IN_USE 0x8032000A`로 실패했고 재부팅 외에는 복구할 수 없었습니다.
지금은 애플리케이션이 자식 프로세스로 관리하며 실행 파일 경로로 정리합니다.
중지와 시작을 세 번 연속 수행해도 문제가 없습니다.

- winws는 WinDivert로 패킷을 잡아 변조하며 내장 desync 설정을 사용합니다
- mihomo는 구독 노드와 규칙 분기를 담당하고 TUN 모드에는 관리자 권한이 필요합니다

## 실행 시 디렉터리

```
C:\Program Files\VRChat优选工具\
  tools\                    런타임 구성 요소 (winws.exe, WinDivert, cygwin1.dll)
  data\logs\session-*.log   세션 로그

C:\ProgramData\VrcTool\
  drivers\winws\            최초 실행 시 압축 해제
  drivers\mihomo\           mihomo, 설정, 구독 캐시, state.json
  logs\drivers.log          두 커널의 출력
```

앱을 닫으면 커널 프로세스도 함께 종료되어 백그라운드에 남지 않습니다.

## 업데이트

시작 후 약 5초 뒤에 앱과 두 커널의 버전을 확인하고 새 버전이 있으면 대화상자로 묻습니다.
"아니오"를 선택하면 이번 실행에서는 건너뜁니다. 설정 페이지에서 수동 확인도 가능합니다.

앱 업데이트는 설치 패키지를 내려받아 SHA256을 검증하고 실행한 뒤 스스로 종료합니다.
커널 업데이트는 기존 파일을 `.bak`으로 이름만 바꾼 뒤 교체하고, 시작을 시도해 실패하면 되돌립니다.

확인 결과는 6시간 동안 캐시됩니다. GitHub 익명 API는 시간당 60회이고 시작 시 확인에 3회를 쓰기 때문에
반복 실행하면 제한에 걸립니다. 수동 확인은 캐시를 무시합니다.

## 소스에서 빌드

.NET 10 SDK가 필요하고, 설치 패키지를 만들려면 Visual Studio 2022 또는 2026의 MSBuild도 필요합니다.

```
git clone https://github.com/AndySmithmao/netkit-l9x2.git
cd netkit-l9x2

dotnet build src\app\VrcTool.csproj -c Release

powershell -File src\setup\build-installer.ps1
```

빌드 스크립트는 먼저 `tools\verify.ps1`을 실행해 파일 인코딩(비 ASCII가 있으면 UTF-8 BOM 필요),
스크립트 문법, 두 스크립트 트리의 일치 여부, 하드코딩된 경로 잔존, 포함 리소스 목록,
버전 일관성을 검사합니다. 하나라도 실패하면 중단합니다.

### mihomo.exe는 별도로 준비

`src\drivers\mihomo.exe`는 약 61 MB라 저장소에 넣지 않았습니다. 빌드 전에 상류에서
`mihomo-windows-amd64-vX.Y.Z.zip`을 받아 `mihomo.exe`를 `src\drivers\`에 넣고
`mihomo.VERSION.txt`(예: `Mihomo Meta v1.19.32 windows amd64`)를 작성하세요. 업데이터가 이 값을 비교에 사용합니다.

winws.exe, cygwin1.dll, WinDivert 두 파일은 저장소에 포함되어 있습니다.

### 자주 만나는 빌드 문제

`error CS1566: WinDivert64.sys 리소스를 읽지 못함`은 실행 중인 winws가 파일을 잡고 있어서입니다.
winws를 중지하거나 `obj`, `bin`을 지우고 다시 빌드하세요.

`verify.ps1`이 BOM 누락을 보고하면 `tools\fix-bom.ps1`을 한 번 실행하세요.

설치 패키지가 2~3 MB라면 mica 패키징 단계에서 페이로드가 들어가지 않은 것입니다.
원인은 보통 버전 접미사(`0.0.1-beta` 형태)이며 makemica는 숫자 버전만 받습니다.
빌드 스크립트가 접미사를 자동으로 제거하지만 직접 호출할 때는 주의가 필요합니다.

## 알려진 문제

ICMP는 프록시할 수 없어 노드별 측정은 TCP 핸드셰이크에 의존하며, ICMP에만 응답하는 대상은 측정할 수 없습니다.

GitHub 익명 API는 시간당 60회이며 반복 실행 시 제한에 걸릴 수 있어 6시간 캐시로 완화합니다.

mihomo는 7891과 9097을 사용합니다. 다른 인스턴스가 실행 중이면 포트가 충돌하며
증상은 구독 가져오기는 성공하는데 노드 목록이 비어 있는 것입니다.

WinDivert와 WPF에 의존하므로 Windows x64만 지원합니다.

## 라이선스와 제3자 구성 요소

프로젝트 코드는 MIT이며 `LICENSE`를 참고하세요. 저장소에 포함된 커널 바이너리는 MIT가 아니라
각각 상류 라이선스를 따르며 자세한 내용은 `NOTICE.md`에 있습니다.
WinDivert는 LGPL-3.0과 GPL-2.0 이중 라이선스, cygwin1.dll은 LGPL-3.0과 링크 예외이며,
둘 다 별도 파일로 배포하고 정적 링크나 수정을 하지 않습니다.

주요 의존성:

- mihomo (Clash.Meta) — https://github.com/MetaCubeX/mihomo
- zapret / zapret-win-bundle — https://github.com/bol-van/zapret
- WinDivert — https://github.com/basil00/WinDivert
- Cygwin — https://cygwin.com/
- .NET 및 WPF — https://github.com/dotnet/wpf
- WPF-UI — https://github.com/lepoco/wpfui

## 면책 조항

이 프로젝트는 일반적인 네트워크 진단 및 경로 제어 도구이며, 특정 국가나 지역, 통신 사업자를
겨냥하지 않습니다.

이 소프트웨어는 hosts를 수정하고 커널 드라이버를 로드하며 TUN으로 전역 트래픽을 전환할 수 있습니다.
실행 전에 위험을 직접 평가하세요.

사용자는 자신이 속한 국가 또는 지역의 법규와 통신 사업자, VPN, 프록시 서비스의 이용 약관을
준수할 책임이 있습니다. 준수해야 할 규칙을 회피할 목적으로 이 도구를 사용하지 마세요.

저자는 이 소프트웨어를 있는 그대로 제공하며 어떠한 보증도 하지 않습니다.
사용으로 인한 손해, 서비스 중단, 계정 조치 등에 대해 책임지지 않습니다.
