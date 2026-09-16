import AppKit
import GestureCore
import KeyboardShortcuts
import Observation
import SwiftUI

/// The hands-on tutorial: every gesture and mode as a mission, cleared by actually doing it (the user asked,
/// 2026-09-14). Opens on the first launch and from the menu.
@MainActor
final class TutorialPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let pipeline: Pipeline
    private var session: TutorialSession?
    private var onClose: (() -> Void)?
    /// Set by the app: the last two missions open its enrollment and calibration panels.
    var onEnroll: (() -> Void)?
    var onCalibrate: (() -> Void)?

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        super.init()
        panel.title = "Motion Controller 사용법 체험"
        panel.level = .floating
        // A panel hides whenever its app isn't frontmost, and a menu-bar app often can't make itself frontmost:
        // the first-launch tutorial was created but never showed (2026-09-14).
        panel.hidesOnDeactivate = false
        // Switching desktops is one of the missions; the window has to be on the next one too.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    /// Starts the missions over; `onClose` runs once the window goes away, however it was closed.
    func show(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        let session = TutorialSession()
        self.session = session
        pipeline.parkForTutorial()
        pipeline.onTutorialEvent = { [weak session] event in
            // The zoom mission can't be passed while macOS's own zoom is switched off: without it the gesture reaches
            // the front app's ⌘+ at best, which isn't what the mission is teaching. It waits for the user to turn it
            // on and press 확인 (their design, 2026-09-14).
            if case .zoomed = event, session?.course.current == .zoom, !AccessibilityZoom.screenZoomAvailable {
                return
            }
            session?.record(event)
        }
        panel.contentView = NSHostingView(rootView: TutorialView(
            pipeline: pipeline,
            session: session,
            onEnroll: { [weak self] in self?.onEnroll?() },
            onCalibrate: { [weak self] in self?.onCalibrate?() },
            close: { [weak self] in self?.panel.close() }
        ))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        pipeline.onTutorialEvent = nil
        session = nil
        let done = onClose
        onClose = nil
        done?()
    }
}

/// The course under way, the mission just cleared and the go just completed — both worth saying something about
/// (the user asked for the praise, 2026-09-14).
@MainActor
@Observable
final class TutorialSession {
    private(set) var course = TutorialCourse()
    private(set) var justCleared: TutorialStep?
    /// A go that landed without finishing the mission: 1 or 2 of three.
    private(set) var justDid: Int?
    /// Counts every clear, so the praise moves along the list instead of repeating one line.
    private(set) var praised = 0
    @ObservationIgnored private var celebration: Task<Void, Never>?
    @ObservationIgnored private var nudge: Task<Void, Never>?

    func record(_ event: TutorialEvent) {
        let before = course.done
        guard let step = course.record(event) else {
            guard course.done > before else { return }
            NSSound(named: "Pop")?.play()
            justDid = course.done
            nudge?.cancel()
            nudge = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                self?.justDid = nil
            }
            return
        }
        NSSound(named: "Glass")?.play()
        justCleared = step
        justDid = nil
        praised += 1
        celebration?.cancel()
        celebration = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.justCleared = nil
        }
    }

    func skip() {
        course.skip()
        justCleared = nil
        justDid = nil
    }

    /// Said when a mission clears; a different one each time, so three missions in a row don't read as a form letter.
    static let praise = [
        "잘했어요! 🎉", "완벽해요! 👏", "손에 익었네요! 💪", "그거예요! ✨", "깔끔했어요! 🙌", "역시! 🔥",
    ]

    var praiseLine: String { Self.praise[max(praised - 1, 0) % Self.praise.count] }
}

extension TutorialStep {
    var symbol: String {
        switch self {
        case .enterGestures, .backToGestures: "✊"
        case .enterDesktop: "🖐"
        case .switchDesktop: "🖐↔︎"
        case .playPause: "🖐⏯"
        case .securityMode: "🛡"
        case .enrollFace: "🙂"
        case .calibrateCursor: "🎯"
        case .zoom: "🤟"
        case .volumeBrightness: "🤏"
        case .enterCursor: "☝️"
        case .moveCursor: "👉"
        case .click: "☝️"
        case .rightClick: "✌️"
        case .scroll: "✌️↕︎"
        case .drag: "🤏"
        case .park: "✊↩︎"
        }
    }

    var title: String {
        switch self {
        case .enterGestures: "제스처 모드 들어가기"
        case .enterDesktop: "데스크탑 전환 모드 들어가기"
        case .switchDesktop: "데스크톱 전환"
        case .playPause: "재생/정지"
        case .securityMode: "보안 모드"
        case .enrollFace: "얼굴 등록 (화면 잠금)"
        case .calibrateCursor: "커서 영역 보정"
        case .zoom: "확대/축소"
        case .volumeBrightness: "볼륨·밝기"
        case .enterCursor: "커서 모드 들어가기"
        case .moveCursor: "커서 움직이기"
        case .click: "클릭"
        case .rightClick: "우클릭"
        case .scroll: "스크롤"
        case .drag: "드래그"
        case .backToGestures: "제스처 모드로 돌아가기"
        case .park: "쉬기 (IDLE)"
        }
    }

    var instruction: String {
        switch self {
        case .enterGestures, .backToGestures: "주먹을 쥐고 잠깐 그대로 있어 보세요."
        case .enterDesktop: "손바닥을 카메라에 보여 보세요. 바로 화면에 보라색 테두리가 생깁니다."
        case .switchDesktop: "그대로 손을 옆으로 크게 쓸어 보세요."
        case .playPause: "주먹으로 카메라를 두 번 노크하듯 톡톡 내밀어 보세요."
        case .securityMode: "보안 모드를 켜 두면 등록되지 않은 얼굴이 카메라에 잡히는 순간 (다섯 번 연속, 약 2초) 화면이 바로 까매지고 잠깁니다. 사람이 없어지길 기다리지 않아요. 아래에서 켜고 끌 수 있고, 정한 뒤 확인을 누르면 다음으로 넘어갑니다."
        case .enrollFace: "얼굴을 등록하면 사람이 없을 때 화면이 까매지고 잠깁니다. 건너뛰어도 됩니다."
        case .calibrateCursor: "화면 네 모서리를 검지로 가리키면 커서가 손 위치에 정확히 붙습니다. 모서리마다 버튼을 눌러 넘어가고, 네 모서리를 두 번 돌아 평균을 씁니다."
        case .zoom: "세 손가락을 펴고 위로 올려 확대, 아래로 내려 축소해 보세요."
        case .volumeBrightness: "엄지와 검지를 붙인 채 위아래로 움직이면 볼륨, 좌우로 움직이면 밝기가 바뀌어요."
        case .enterCursor: "검지를 펴고 두 번 톡톡 굽혀 보세요."
        case .moveCursor: "검지를 카메라 쪽으로 살짝 굽힌 채 손을 움직여 보세요. 검지를 펴면 커서가 멈춰요. 이 손이 커서를 계속 잡고, 버튼은 반대손이 맡습니다."
        case .click: "커서 손은 그대로 두고, 반대손 검지를 올린 다음 그 검지를 굽혔다 펴 보세요. 커서 아래가 클릭돼요."
        case .rightClick: "반대손으로 브이(✌️)를 만든 다음, 그 검지를 굽혔다 펴 보세요."
        case .scroll: "반대손 손바닥을 펴서 위아래로 움직여 보세요."
        case .drag: "반대손을 주먹으로 쥐면 누른 상태가 돼요. 그대로 커서 손을 움직였다가 주먹을 펴 보세요."
        case .park: "주먹을 쥔 채 손을 뒤로 빼 보세요."
        }
    }

    var tip: String? {
        switch self {
        case .enterGestures, .backToGestures: "오버레이의 '✊ 제스처 모드로 전환' 막대가 다 차면 돼요."
        case .enterDesktop: "이 모드에서는 좌우로 쓸기와 팡팡(재생/정지)만 인식해요. 나올 때는 주먹을 쥐거나 검지로 톡톡 하세요."
        case .switchDesktop: "오른쪽으로 쓸면 다음, 왼쪽으로 쓸면 이전 데스크톱이에요. 연속으로 할 때는 손을 멈췄다가(0.15초) 다시 쓸면 돼요."
        case .playPause: "손을 앞으로 쭉 내밀 필요는 없어요. 문을 두드리듯 가볍게 두 번이면 됩니다. 손을 펴면 취소되고, 주먹을 뒤로 뺀 채 가만히 있으면 IDLE이 돼요."
        case .securityMode: "등록된 얼굴이 보이면 잠기지 않아요. 얼굴이 안 보이거나 너무 멀거나 방이 어두우면 그냥 둡니다. Touch ID·암호로 푼 뒤 2분간은 얼굴로 다시 잠그지 않아요. 메뉴바에서 언제든 켜고 끌 수 있어요."
        case .enrollFace: "여러 번 등록하면 인식이 좋아져요. 메뉴에서 언제든 다시 할 수 있어요."
        case .calibrateCursor: "커서가 손끝을 따라가요. 측정이 이상하면 '다시 측정'을 누르면 돼요. 메뉴의 '커서 영역 보정'으로 언제든 다시 할 수 있어요."
        case .zoom: "새끼손가락은 꼭 접어 주세요 — 네 손가락이 다 펴지면 손바닥으로 읽혀서 데스크탑 전환 모드로 갑니다. 확대가 남으면 ⌥⌘8로 끄세요."
        case .volumeBrightness: "어느 쪽이든 한 번 바뀌면 클리어예요."
        case .enterCursor: "한 번 톡 하면 오버레이에 '한 번 더 톡'이 떠요."
        case .moveCursor: "커서가 화면 끝까지 안 가면 나중에 메뉴바 > 커서 영역 보정… 에서 맞출 수 있어요."
        case .click: "손을 올리는 것만으로는 클릭이 안 돼요 — 올린 뒤 굽혔다 펴야 클릭입니다. 자리를 잡는 건 명령이 아니니까요. 빠르게 두 번 하면 더블클릭. 한 손으로 하려면 커서 손 검지를 톡 굽혔다 펴도 됩니다."
        case .rightClick: "한 손으로 하려면 커서 손으로 ✌️를 만든 채 검지만 톡 굽혀도 됩니다."
        case .scroll: "한 손으로 하려면 커서 손을 브이(✌️)로 만들어 위아래로 움직여도 됩니다."
        case .drag: "한 손으로 하려면 커서 손에서 엄지와 검지를 붙인 채 움직였다가 떼도 됩니다. 반대손 주먹은 커서를 흔들지 않아서 더 쉬워요."
        case .park: "5초 동안 아무도 안 보여도 저절로 IDLE이 돼요."
        }
    }
}

struct TutorialView: View {
    let pipeline: Pipeline
    let session: TutorialSession
    let onEnroll: () -> Void
    let onCalibrate: () -> Void
    let close: () -> Void
    /// Bumped by the 확인 button so the setting is read again; `AccessibilityZoom` has no way to tell us itself.
    @State private var zoomChecks = 0
    /// 확인 was pressed and the setting was still off, so the panel can say so rather than look like it did nothing.
    @State private var zoomStillOff = false

    private var toggleShortcut: String {
        KeyboardShortcuts.getShortcut(for: .toggleEnabled)?.description ?? "⌃⌥⌘G"
    }

    var body: some View {
        let course = session.course
        let total = TutorialStep.allCases.count
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("사용법 체험").font(.title2.bold())
                Spacer()
                Text("\(TutorialStep.allCases.filter(course.isCleared).count)/\(total) 클리어")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(course.index), total: Double(total))

            HStack(alignment: .top, spacing: 20) {
                checklist(course)
                    .frame(width: 190, alignment: .leading)
                if let step = course.current {
                    mission(step, course: course)
                } else {
                    finished(course)
                }
            }

            Spacer(minLength: 0)

            Text(liveText)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                if course.isFinished {
                    Spacer()
                    Button("완료", action: close)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("이 단계 건너뛰기") { session.skip() }
                    Spacer()
                    Button("나중에 하기", action: close)
                }
            }
        }
        .padding(24)
        .frame(width: 700, height: 620)
    }

    private func checklist(_ course: TutorialCourse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(TutorialStep.allCases, id: \.self) { step in
                let mark = course.isCleared(step) ? "✅" : course.skipped.contains(step) ? "⏭" : step == course.current ? "▶️" : "⬜"
                HStack(spacing: 6) {
                    Text(mark)
                    Text(step.title)
                        .fontWeight(step == course.current ? .semibold : .regular)
                        .foregroundStyle(step == course.current ? .primary : .secondary)
                }
                .font(.callout)
            }
        }
    }

    /// The last two missions aren't gestures: they open a panel. Enrolling needs the face model, so when there
    /// isn't one the mission offers to install it (a button, since 2026-09-14) instead of a button that could only
    /// fail.
    @ViewBuilder
    private func setup(_ step: TutorialStep) -> some View {
        if step == .enrollFace, !pipeline.faceUnlockAvailable {
            FaceModelInstallView(pipeline: pipeline) { session.skip() }
        } else if step == .enrollFace {
            Button("얼굴 등록 시작") { onEnroll() }
                .controlSize(.large)
        } else if step == .calibrateCursor {
            Button("커서 영역 보정 시작") { onCalibrate() }
                .controlSize(.large)
        } else if step == .securityMode {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("보안 모드 켜기", isOn: Binding(
                    get: { pipeline.securityMode },
                    set: { pipeline.securityMode = $0 }
                ))
                .toggleStyle(.switch)
                .disabled(!pipeline.lockEnabled || pipeline.enrolledFaces.isEmpty)
                if !pipeline.lockEnabled || pipeline.enrolledFaces.isEmpty {
                    Text("얼굴을 등록하고 '까만 화면 잠금'이 켜져 있어야 동작해요. 지금은 켜 둬도 잠기지 않아요.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .wrapping()
                }
                Button("이대로 할게요") { pipeline.confirmSecurityChoice() }
                    .controlSize(.large)
            }
        }
    }

    /// Whether macOS will actually zoom the screen. Re-read whenever `zoomChecks` changes, which is what the 확인
    /// button is for: this app can't be told when a System Settings checkbox is ticked.
    private var zoomReady: Bool {
        _ = zoomChecks
        return pipeline.screenZoomAvailable
    }

    /// The gate on the zoom mission: screen zoom is a 손쉬운 사용 feature, both of its switches are off until someone
    /// turns them on, and nothing this app does can turn them on. So the mission explains it, opens the pane, and
    /// waits to be told to look again (the user's design, 2026-09-14).
    @ViewBuilder
    private var zoomGate: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("먼저 macOS의 화면 확대를 켜 주세요")
                .font(.headline)
            Text("확대/축소는 손쉬운 사용의 기능이라, 꺼져 있으면 어떤 앱도 화면을 확대할 수 없어요 (⌃ + 스크롤이 안 되는 것도 같은 이유예요). 아래 버튼으로 설정을 열고 **'스크롤 제스처와 보조 키를 함께 사용하여 확대/축소'** 또는 **'키보드 단축키로 확대/축소 사용'** 중 하나를 켜 주세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .wrapping()
            HStack {
                Button("설정 열기") { pipeline.openZoomSettings() }
                    .buttonStyle(.borderedProminent)
                Button("켰어요 · 확인") {
                    zoomChecks += 1
                    zoomStillOff = !pipeline.screenZoomAvailable
                }
                Button("건너뛰기") { session.skip() }
            }
            if zoomStillOff {
                Text("아직 꺼져 있어요. 설정에서 체크박스를 켠 다음 다시 확인을 눌러 주세요.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .wrapping()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Once it is on: which of the two it will use, since they behave differently.
    private var zoomReadyNote: some View {
        HStack(spacing: 8) {
            Text("✅ \(pipeline.zoomStyle.displayName) 사용 중")
                .font(.callout.weight(.semibold))
            Button("설정 열기") { pipeline.openZoomSettings() }
                .buttonStyle(.link)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func mission(_ step: TutorialStep, course: TutorialCourse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cleared = session.justCleared {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.praiseLine) \(cleared.title) 클리어!")
                        .font(.headline)
                    Text(course.isFinished ? "전부 끝났어요. 이제 손으로 쓰면 됩니다." : "다음 미션으로 갈게요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.green)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            } else if let did = session.justDid, let step = course.current {
                Text("좋아요! \(did)/\(step.repetitions) · \(step.repetitions - did)번 더")
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(step.symbol).font(.system(size: 52))
            Text(step.title).font(.title.bold())
            Text(step.instruction).font(.title3).wrapping()
            if step.repetitions > 1 {
                HStack(spacing: 6) {
                    ForEach(0..<step.repetitions, id: \.self) { index in
                        Image(systemName: index < course.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(index < course.done ? .green : .secondary)
                    }
                    Text("\(step.repetitions)번 하면 넘어가요")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.title3)
            }
            if step == .zoom {
                if zoomReady {
                    HStack(spacing: 16) {
                        Text(course.zoomedIn ? "✅ 확대" : "⬜ 확대")
                        Text(course.zoomedOut ? "✅ 축소" : "⬜ 축소")
                    }
                    .font(.headline)
                    zoomReadyNote
                } else {
                    zoomGate
                }
            }
            if step == .moveCursor {
                ProgressView(value: Double(min(course.cursorFrames, TutorialCourse.cursorFrames)), total: Double(TutorialCourse.cursorFrames))
            }
            if step.opensPanel {
                setup(step)
            }
            if let tip = step.tip {
                Text(tip).font(.callout).foregroundStyle(.secondary).wrapping()
            }
            if let hint = modeHint(for: step) {
                Text(hint)
                    .font(.callout)
                    .wrapping()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func finished(_ course: TutorialCourse) -> some View {
        let skipped = course.skipped.count
        return VStack(alignment: .leading, spacing: 10) {
            if let cleared = session.justCleared {
                Text("✅ \(cleared.title) 클리어!").font(.headline).foregroundStyle(.green)
            }
            Text("🎉 모든 단계를 마쳤어요").font(.title.bold())
            if skipped > 0 {
                Text("건너뛴 \(skipped)단계는 메뉴바 > 사용법 보기… 에서 다시 해 볼 수 있어요.")
                    .foregroundStyle(.secondary)
                    .wrapping()
            }
            Divider()
            Text("알아 두면 좋은 것").font(.headline)
            reference("⌨️", toggleShortcut, "제스처 인식 켜기/끄기")
            reference("🔍", "⌥⌘8", "확대가 남아 있을 때 끄기")
            reference("💤", "5초 동안 아무도 없음", "IDLE로 바뀌어요")
            reference("🌙", "10초 동안 아무도 없음", "화면이 까매져요. 얼굴을 등록했다면 잠겨서 등록된 얼굴이나 Touch ID·암호로만 풀려요")
            reference("📸", "잠긴 동안 누가 만지면", "사진을 찍어 두고 다시 켜질 때 보여 줘요")
            reference("✋", "메뉴바 아이콘", "커서 영역 보정, 까만 화면 잠금, 얼굴 추가, 디버그 프리뷰, 사용법 보기")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func reference(_ symbol: String, _ gesture: String, _ result: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(symbol).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(gesture).font(.callout.weight(.semibold))
                Text(result).font(.callout).foregroundStyle(.secondary).wrapping()
            }
        }
    }

    /// How to get into the mode the mission needs, when the user isn't in it.
    private func modeHint(for step: TutorialStep) -> String? {
        guard pipeline.isRunning else { return "제스처 인식이 꺼져 있어요. \(toggleShortcut)로 켜 주세요." }
        let mode = pipeline.mode
        switch step.requiredMode {
        case .normal? where mode != .normal:
            return "지금은 \(mode.displayName) 모드예요. 먼저 ✊ 주먹을 잠깐 유지해 제스처 모드로 들어오세요."
        case .pointer? where mode != .pointer:
            return "지금은 \(mode.displayName) 모드예요. 먼저 ☝️ 검지를 두 번 톡톡 해 커서 모드로 들어오세요."
        case .desktop? where mode != .desktop:
            return "지금은 \(mode.displayName) 모드예요. 먼저 🖐 손바닥을 카메라에 보여 데스크탑 전환 모드로 들어오세요."
        default:
            break
        }
        switch (step, mode) {
        case (.playPause, .pointer), (.playPause, .idle):
            return "재생/정지는 제스처 모드나 데스크탑 전환 모드에서 돼요. ✊ 주먹을 잠깐 유지해 보세요."
        case (.enterGestures, .normal): return "이미 제스처 모드예요. ✊ 주먹을 쥔 채 뒤로 빼 IDLE로 갔다가 다시 해 보세요."
        case (.enterCursor, .pointer): return "이미 커서 모드예요. ✊ 주먹을 유지해 나갔다가 다시 해 보세요."
        case (.park, .idle): return "이미 IDLE이에요. ✊ 주먹을 유지해 제스처 모드로 들어왔다가 다시 해 보세요."
        default: return nil
        }
    }

    /// What recognition sees right now.
    private var liveText: String {
        guard pipeline.isRunning else { return "지금: 제스처 인식이 꺼져 있어요" }
        let hand = pipeline.latestReading.map { $0.pose?.displayName ?? "손 보임" } ?? "손 없음"
        let flash = pipeline.flash.map { " · \($0)" } ?? ""
        return "지금: \(pipeline.mode.displayName) 모드 · \(hand)\(flash)"
    }
}

private extension View {
    /// Wraps onto as many lines as it needs instead of truncating.
    func wrapping() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}
