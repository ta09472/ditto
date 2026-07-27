# Ditto

**2000년대 디지털카메라의 화질을 색 보정이 아니라 신호 경로 재현으로 만들어내는 iOS 카메라 앱.**

뉴진스 『Ditto』 뮤직비디오로 다시 유행한 캠코더·디카 감성을, 촬영이 끝난 뒤 보정하는 대신 **뷰파인더에서 그대로 보면서** 찍습니다.

<!-- 스크린샷/데모 GIF는 실기기 촬영본 정리 후 추가 예정 -->

![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![iOS](https://img.shields.io/badge/iOS-17.0%2B-blue)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-green)
![Metal](https://img.shields.io/badge/GPU-Metal%20CIKernel-lightgrey)

---

## 왜 만들었나

레트로 카메라 앱 대부분은 필터를 **결과물의 색을 흉내내는 방식**으로 만듭니다. 채도를 낮추고 그레인을 얹는 식이죠. 그렇게 만든 사진은 "필터를 씌운 요즘 사진"처럼 보이지, 그 시절 기기로 찍은 사진처럼 보이지 않습니다.

그래서 접근을 뒤집었습니다. **실제 기기가 왜 그런 사진을 만들어냈는지**를 조사해서 — 센서 해상도, 렌즈 수차, JPEG 압축 방식, 인카메라 샤프닝, 제조사별 색 튜닝 성향 — 그 신호 경로를 같은 순서로 셰이더에 옮겼습니다. 룩이 효과로 얹히는 게 아니라 파이프라인의 결과로 도출됩니다.

## 기능

- **필터 6종** — 원본 / Ditto(캠코더) / 디카 / 레시피 / Dither / E-ink, 전부 실시간 프리뷰
- **디지털카메라 7기종** — 케녹스 Cyber-410, 캐논 IXUS 90·IXUS 20, 소니 사이버샷 W81, 카시오 엑슬림 Z2300, 니콘 쿨픽스 S3700, 캐논 파워샷 G9. 기종마다 해상도·프레임레이트·색·샤프닝·노이즈가 실스펙 기반으로 다릅니다
- **레시피 프리셋 12종** — 필름·VSCO·Foodie 계열 보정 레시피를 자체 그레이딩 커널로 재구성
- **촬영** — 사진/영상, 전후면 전환, 광각(0.5x), 화면비 9:16·3:4·1:1, 핀치 줌, 도트 폰트 날짜 스탬프
- 사진·영상·프리뷰가 **완전히 동일한 필터 결과**를 공유합니다

## 기술적 도전

<details>
<summary><b>1. 실기기의 신호 경로를 역설계해 룩을 도출하기</b></summary>

<br>

초기 구현은 채도를 낮추고 그레인을 얹는 방식이었고, 결과는 "원본 위에 효과를 덧씌운 티"가 났습니다.

방향을 바꿔 실기종 스펙과 당시 리뷰를 조사한 뒤, 화질 열화의 **원인별로** 파이프라인을 다시 짰습니다. 순서가 핵심이었습니다 — 실기기에서 언샤프마스크는 센서 노이즈가 생긴 **뒤에** 적용되므로 노이즈까지 함께 날카로워지는데, 이 순서를 지켜야 특유의 아티팩트가 재현됩니다.

```
렌즈 색수차·비네팅 → 센서 해상도 다운샘플 → JPEG 4:2:0 크로마 서브샘플링
→ 센서 노이즈 → 언샤프마스크(제조사별 강도) → 색 튜닝 → 다이내믹 레인지 압축
```

기여도가 가장 큰 요인은 노이즈가 아니라 **해상도 체인과 크로마 서브샘플링**이었습니다. 덕분에 노이즈를 거의 넣지 않고도 저화질 질감이 나옵니다.

</details>

<details>
<summary><b>2. 프리뷰·녹화·사진 세 경로의 일관성과 화질 양립</b></summary>

<br>

프리뷰와 녹화는 같은 `CIImage` 결과를 공유하게 만들어, 사용자가 뷰파인더에서 본 화면과 저장된 영상이 정확히 일치합니다.

문제는 사진이었습니다. 영상 프레임을 그대로 저장하면 경로는 단순하지만 Deep Fusion·Smart HDR 같은 멀티프레임 합성을 전혀 받지 못해 해상도와 저조도 화질이 떨어집니다. 그래서 사진만 `AVCapturePhotoOutput`으로 분리해, 순정 파이프라인이 처리한 고화질 원본에 동일한 필터를 후처리로 적용하는 이원 구조로 바꿨습니다. 필터가 결정론적 픽셀 연산이라 적용 시점이 달라도 결과가 같다는 점이 근거였습니다.

</details>

<details>
<summary><b>3. 기종·프리셋 확장에 셰이더 중복 없애기</b></summary>

<br>

기종별로 커널을 따로 두면 19개(기종 7 + 프리셋 12)의 셰이더가 필요하고, 공통 로직을 고칠 때마다 전부 손대야 합니다.

커널은 **연산 순서만** 정의하고 기기 특성은 파라미터로 주입하는 구조를 택했습니다. 기종 하나가 `videoWidth·fps·saturation·rGain·bGain·sharpen·noise·bloom` 값의 집합이 되면서, 새 기종·프리셋 추가가 데이터 한 줄로 끝납니다.

```swift
.init(name: "POWERSHOT G9", videoWidth: 640, halfFps: false,
      saturation: 0.95, rGain: 1.00, bGain: 1.00,
      sharpen: 0.55, noise: 0.01, bloom: 0.6)  // 채도 절제 + 인카메라 오버샤프닝
```

</details>

<details>
<summary><b>4. 실사용 안정성</b></summary>

<br>

카메라 앱에서 가장 흔한 실사용 장애는 통화 수신 등으로 세션이 중단된 뒤 복구되지 않는 것입니다. `AVCaptureSession`의 인터럽션·런타임 에러 알림을 관찰해, 중단 시점에 녹화를 안전하게 종료·저장하고 인터럽션이 끝나면 세션을 자동 재개하도록 처리했습니다.

이 외에 프레임레이트 고정(min/max 양쪽), 손떨림 보정, 녹화 비트레이트 명시 등 기본기를 함께 맞췄습니다.

</details>

## 빌드

> **실기기가 필요합니다.** 시뮬레이터에는 카메라가 없어 프리뷰가 동작하지 않습니다.

**요구사항** — Xcode 15 이상(Xcode 26.5에서 개발), iOS 17.0+ 기기, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
brew install xcodegen
git clone git@github.com:ta09472/ditto.git
cd ditto
xcodegen generate
open Ditto.xcodeproj
```

`project.yml`의 `DEVELOPMENT_TEAM`을 본인 팀 ID로 바꾼 뒤 실기기를 선택해 실행하면 됩니다.

Xcode 26 이상에서 Metal 셰이더 컴파일 오류가 나면 툴체인을 먼저 내려받아야 합니다.

```bash
xcodebuild -downloadComponent MetalToolchain
```

## 구조

외부 의존성 없이 표준 프레임워크만 사용합니다 (약 1,300줄).

```
Ditto/
├── DittoApp.swift          앱 진입점
├── ContentView.swift       카메라 바디 UI, 필터·기종 다이얼
├── CameraManager.swift     캡처 세션, 녹화, 사진, 줌·비율·렌즈 제어
├── MetalPreviewView.swift  MTKView 실시간 프리뷰
├── Filters.swift           필터 정의, 기종·프리셋 파라미터, 타임스탬프
└── Kernels.ci.metal        5종 GPU 커널 (Metal CIKernel)

docs/research.md            기기 스펙·화질 특성 리서치 노트
```

`docs/research.md`에 각 기종의 파라미터를 어떤 근거로 정했는지 — 어디까지가 리뷰 인용이고 어디부터가 동세대 유추인지 — 기록해 두었습니다.
