# Motion Controller

웹캠으로 손 제스처를 읽어 macOS를 조작하는 메뉴바 앱. Apple Vision의 손·몸 포즈 인식만 쓰고,
영상은 메모리에서만 처리하고 전송하지 않는다. 얼굴을 등록하면 얼굴 특징 벡터를, 잠긴 화면에서 누군가 입력을
시도하면 그 사진을 이 Mac에 저장한다.

## 무엇을 할 수 있나

| 모드 | 들어가는 방법 | 할 수 있는 것 |
|---|---|---|
| IDLE | 사람이 5초 안 보이면 자동 / ✊ 뒤로 빼기 | 모드 전환 제스처만 인식 |
| 제스처 | ✊ 유지 | 🖐 손바닥 보이고 0.3초 멈췄다가 옆으로 쓸기 → 데스크톱 전환, 🖐 1.2초 들었다 내리기 → 재생/정지 (내리기 전에 ✊로 접으면 취소), 🤟 세 손가락 위/아래 → 확대/축소, 핀치 후 ↕ 볼륨 / ↔ 밝기 |
| 커서 | ☝️ 검지 두 번 톡톡 | 검지를 살짝 굽힌 동안에만 커서 이동, 톡 = 클릭, 톡톡 = 더블클릭, ✌️에서 검지 톡 = 우클릭, 핀치 = 드래그, ✌️ 위/아래 = 스크롤, 🤟 세 손가락 위/아래 = 확대/축소 |

🤟 확대/축소는 커서·제스처 모드 모두에서 macOS 손쉬운 사용의 화면 확대를 단축키(⌥⌘= / ⌥⌘−)로 한 단계씩 부른다. 시스템 설정 >
손쉬운 사용 > 확대/축소에서 "키보드 단축키를 사용하여 확대/축소"를 켜야 동작한다. 합성한 트랙패드
핀치와 ⌃+스크롤은 macOS 26.5에서 아무것도 확대하지 못해서 쓰지 않는다.

데스크톱 전환은 손바닥을 카메라에 보인 채 0.3초 멈추면 준비되고 (오버레이에 "↔ 옆으로 쓸면 데스크톱 전환"),
그 자리에서 옆으로 화면 폭의 13% 이상을 0.8초 안에 쓸면 발동한다. 방향은 멈췄던 자리 기준이라 반대쪽으로 살짝
당기는 준비 동작에 속지 않는다. 한 번 전환하면 다시 멈춰야 다음 전환이 되고, 1초 안의 반대 방향은 무시한다
(되돌아오는 손). 멈춤 없이 움직이는 손, 주먹 뒤로 빼기, 손등이 보이는 손은 전환하지 않는다. 왼쪽으로 쓸면
다음 데스크톱, 오른쪽으로 쓸면 이전 데스크톱.

제스처 인식이 켜져 있는 동안 Mac은 디스플레이도 시스템도 잠들지 않는다. 5초 동안 아무도 안 보이면
IDLE로 바뀌고, 10초가 되면 화면이 완전히 까매진다. 화면 보호기 설정이 '안 함'이 아니면 그 시간이 지나
화면 보호기와 잠금이 뜰 수도 있다 (확인하지 못함).

## 까만 화면 잠금

얼굴을 등록하면 까매진 화면이 잠긴다. 잠긴 동안에는 키보드·마우스·트랙패드 입력이 앱에 전달되지 않고,
앞에 사람이 와도 화면이 돌아오지 않는다. 풀리는 방법은 두 가지다.

1. **얼굴** — 등록한 사람 중 누구든 카메라에 1초 안팎으로 여러 번 확인되면 저절로 풀린다.
2. **Touch ID·로그인 암호** — 키를 누르거나 클릭하면 인증 창이 뜨고 화면이 35% 밝기로 올라온다.
   지문이 등록돼 있지 않으면 암호 창이 뜬다. 30초 동안 아무도 답하지 않으면 창이 닫히고 다시 까매진다.
   인증 창이 떠 있는 동안에는 창 안의 클릭과 암호 칸에 치는 키만 통과하게 했다. 암호 칸의 키가 막히지 않는지는
   아직 직접 확인하지 못했다 (보안 입력이 켜졌는지로 판단한다).

처음 실행하면 얼굴 등록 창이 한 번 뜨고, 첫 얼굴을 등록하면 잠금이 켜진다. 여러 사람을 이름을 붙여 등록할 수
있다. 메뉴바 > **얼굴 추가…** 로 사람을 더하고, **등록된 얼굴 N명** 에서 사람마다 **다시 등록…** 이나 **삭제** 를
고른다. **까만 화면 잠금** 으로 켜고 끈다. 사진은 저장하지 않고, 이름과 얼굴에서 뽑은 512차원 숫자 벡터만
`~/Library/Application Support/MotionController/faces.json`에 저장한다. 등록된 사람은 잠긴 동안 사진도 찍히지
않는다.

잠긴 동안 누군가 키보드·마우스·트랙패드를 건드리면 카메라 사진을 찍는다. 그 순간 한 장, 이후 등록되지 않은
얼굴이 보일 때마다 1초 간격으로 최대 두 장 더 찍는다. 15초 안에 등록된 사람의 얼굴이나 Touch ID·암호로 풀리면
주인이었던 것으로 보고 버린다. 아무도 못 풀거나 인증 창이 잠긴 채 닫히면 저장한다. 저장한 뒤 30초 동안은 새로 찍지 않는다.
사진은 `~/Library/Application Support/MotionController/Intruders/`에 쌓이고, 화면이 다시 돌아오면 마지막 사진과
장수를 보여 주는 창이 뜬다. 메뉴바 > **잠긴 동안 찍힌 사진 N장 보기…** 로도 연다.

macOS 잠금 화면을 대신하지 않는다.

- 사진·영상을 들이대면 통과할 수 있다 (눈 깜빡임 같은 생체 확인이 없다).
- 앱을 강제 종료하거나 앱이 죽으면 입력 차단과 까만 화면이 같이 풀린다. 앱이 멈춰도 macOS가 입력 차단을 끈다.
- 화면이 켜져 있는 10초 사이에 다른 사람이 앉으면 막지 않는다.
- 어두운 방에서는 화면이 까매서 얼굴이 잘 안 보인다. 그때는 Touch ID·암호를 쓴다.
- macOS 잠금 화면이 뜨거나 다른 사용자로 전환되면 이 잠금은 비켜난다.

얼굴 인식 모델은 저장소에 없다. 빌드 전에 받아 둔다 (약 44MB, 코드 MIT, 가중치는 학습 데이터 WebFace4M
때문에 비상업용).

```bash
curl -L -o /tmp/AdaFace_IR18.mlpackage.zip https://github.com/john-rocky/CoreML-Models/releases/download/adaface-v1/AdaFace_IR18.mlpackage.zip
```

```bash
mkdir -p App/Vision/Models && unzip -o /tmp/AdaFace_IR18.mlpackage.zip -d App/Vision/Models && xcodegen generate
```

모델이 없어도 빌드는 되고, 얼굴 등록 메뉴와 잠금만 꺼진다.

잠금 동작을 확인할 때는 `open --env MC_LOCK_TEST=20 MotionController.app` 으로 켠다. 3초 뒤 누가 있든 잠그고,
20초 (최대 60초) 뒤 저절로 푼다.

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

처음 실행하면 체험형 사용법이 뜬다. 제스처 모드 들어가기부터 데스크톱 전환, 재생/정지, 확대/축소, 볼륨·밝기,
커서 모드의 이동·클릭·우클릭·스크롤·드래그, IDLE로 쉬기까지 13단계를 차례로 직접 해 보고, 그 동작이 실제로
인식돼야 클리어된다. 단계에 맞는 모드가 아니면 어떻게 들어가는지 알려 주고, 단계마다 건너뛸 수 있다. 시작할 때
IDLE로 바뀐다. 마지막에 키보드 단축키와 자리 비움·잠금 동작을 정리해 보여 준다. 메뉴바 > **사용법 보기…** 로
다시 연다.

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
