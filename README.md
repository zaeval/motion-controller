# Motion Controller

웹캠으로 손 제스처를 읽어 macOS를 조작하는 메뉴바 앱. Apple Vision의 손·몸 포즈 인식만 쓰고,
영상은 메모리에서만 처리한다 (저장·전송 없음).

## 무엇을 할 수 있나

| 모드 | 들어가는 방법 | 할 수 있는 것 |
|---|---|---|
| IDLE | 사람이 안 보이면 자동 / 🖐→✊→뒤로 빼기 | 모드 전환 제스처만 인식 |
| 제스처 | ✊ 유지 | 좌우 스와이프 → 데스크톱 전환, 🖐 1.2초 → 재생/정지, ✌️✋(세 손가락) 0.4초 → ⌘Tab, 핀치 후 ↕ 볼륨 / ↔ 밝기 |
| 커서 | ☝️ 검지 두 번 톡톡 | 검지를 살짝 굽힌 동안에만 커서 이동, 톡 = 클릭, 톡톡 = 더블클릭, ✌️에서 검지 톡 = 우클릭, 핀치 = 드래그 |

스와이프는 손을 들 필요가 없고, 스트로크가 멈춘 뒤 약 0.3초 있다가 발동한다 (되돌아오는 손을
반대 방향으로 잘못 읽지 않으려고 일부러 기다린다).

## 빌드

XcodeGen이 필요하다. Xcode와 Apple ID(무료)만 있으면 된다.

```bash
brew install xcodegen
```

```bash
cd "motion controller" && xcodegen generate && xcodebuild -project MotionController.xcodeproj -scheme MotionController -configuration Debug -derivedDataPath build/DerivedData build
```

`project.yml`의 `DEVELOPMENT_TEAM`은 이 저장소 주인의 팀 ID다. **다른 컴퓨터에서는 본인 팀 ID로
바꿔야 한다** (Xcode > Settings > Accounts에서 확인, 또는 `security find-identity -v -p codesigning`).

빌드된 앱은 `build/DerivedData/Build/Products/Debug/MotionController.app`에 생긴다.

## 실행 — `open`으로만 켤 것

```bash
open "build/DerivedData/Build/Products/Debug/MotionController.app"
```

바이너리를 직접 실행하면 **손쉬운 사용 권한이 적용되지 않아 합성 이벤트가 조용히 전부 무시된다.**
커서도 데스크톱 전환도 아무 로그 없이 동작하지 않으니, 반드시 `open`으로 켠다.

처음 켜면 두 가지 권한을 직접 허용해야 한다.

1. **카메라** — 실행 직후 뜨는 대화상자
2. **손쉬운 사용** — 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 MotionController 추가

서명은 Apple Development 인증서로 고정돼 있다. ad-hoc 서명은 빌드마다 서명이 바뀌어서 손쉬운 사용
권한이 매번 초기화된다.

## 커서 영역 보정

메뉴바 > **커서 영역 보정…** 을 누르면 화면 네 모서리에 표적이 뜬다. 검지로 각 모서리를 가리키고
0.8초 멈추면 그 네 점으로 절대 좌표 매핑을 만든다. **커서 영역 기본값으로** 로 되돌린다.

## 개발

```bash
cd Packages/GestureCore && swift test
```

제스처 판정 로직은 전부 `Packages/GestureCore`에 순수 Swift로 있고, 사용자가 직접 녹화한 랜드마크
시퀀스(`Tests/GestureCoreTests/Fixtures/sequences`)로 회귀 검증한다. 디버그 프리뷰 창의 "3초 녹화"
버튼이 그 fixture를 만든다 — 좌표만 저장하고 영상은 저장하지 않는다.

녹화를 분석하는 환경변수들이 `Tests/GestureCoreTests/RecordingTraces.swift`에 있다.

```bash
cd Packages/GestureCore && SWIPE_RUNS=1 swift test --filter printSwipeRuns
```

```bash
cd Packages/GestureCore && SWIPE_COUNTS=1 swift test --filter printSwipeCounts
```

`PRINT_TRACES=<라벨>`은 프레임별 판정을, `RENDER_HANDS=<라벨>`은 랜드마크 그림을 뽑는다.

## private API

개인용이라 쓰지만 macOS 업데이트로 깨질 수 있다. 각각 없으면 그 기능만 꺼진다.

- 데스크톱 전환: Dock-swipe CGEvent의 비공개 필드 (합성 ⌃←/⌃→는 macOS가 무시한다)
- SkyLight `SLSCopyManagedDisplaySpaces`: 현재 Space 목록 읽기 전용
- 밝기 fallback: DisplayServices

차용한 코드의 라이선스 고지는 `THIRD_PARTY_NOTICES.md`에 있다.
