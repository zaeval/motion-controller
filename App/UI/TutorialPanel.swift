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

/// The course under way, and the mission that was just cleared, shown for a moment.
@MainActor
@Observable
final class TutorialSession {
    private(set) var course = TutorialCourse()
    private(set) var justCleared: TutorialStep?
    @ObservationIgnored private var celebration: Task<Void, Never>?

    func record(_ event: TutorialEvent) {
        guard let step = course.record(event) else { return }
        NSSound(named: "Glass")?.play()
        justCleared = step
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
    }
}

extension TutorialStep {
    var symbol: String {
        switch self {
        case .enterGestures, .backToGestures: "✊"
        case .enterDesktop: "🖐"
        case .switchDesktop: "🖐↔︎"
        case .playPause: "🖐⏯"
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
        case .enrollFace: "얼굴을 등록하면 사람이 없을 때 화면이 까매지고 잠깁니다. 건너뛰어도 됩니다."
        case .calibrateCursor: "화면 네 모서리를 검지로 가리키면 커서가 손 위치에 정확히 붙습니다. 모서리마다 버튼을 눌러 넘어가고, 네 모서리를 두 번 돌아 평균을 씁니다."
        case .zoom: "세 손가락을 펴고 위로 올려 확대, 아래로 내려 축소해 보세요."
        case .volumeBrightness: "엄지와 검지를 붙인 채 위아래로 움직이면 볼륨, 좌우로 움직이면 밝기가 바뀌어요."
        case .enterCursor: "검지를 펴고 두 번 톡톡 굽혀 보세요."
        case .moveCursor: "검지를 카메라 쪽으로 살짝 굽힌 채 손을 움직여 보세요. 검지를 펴면 커서가 멈춰요."
        case .click: "검지를 한 번 톡 굽혔다 펴 보세요. 커서 아래가 클릭돼요."
        case .rightClick: "브이(✌️)를 만든 채 검지만 톡 굽혀 보세요."
        case .scroll: "브이(✌️) 모양으로 손을 위아래로 움직여 보세요."
        case .drag: "엄지와 검지를 붙이면 누른 상태가 돼요. 붙인 채 움직였다가 떼 보세요."
        case .park: "주먹을 쥔 채 손을 뒤로 빼 보세요."
        }
    }

    var tip: String? {
        switch self {
        case .enterGestures, .backToGestures: "오버레이의 '✊ 제스처 모드로 전환' 막대가 다 차면 돼요."
        case .enterDesktop: "이 모드에서는 좌우로 쓸기와 팡팡(재생/정지)만 인식해요. 나올 때는 주먹을 쥐거나 검지로 톡톡 하세요."
        case .switchDesktop: "오른쪽으로 쓸면 다음, 왼쪽으로 쓸면 이전 데스크톱이에요. 연속으로 할 때는 손을 멈췄다가(0.15초) 다시 쓸면 돼요."
        case .playPause: "손을 앞으로 쭉 내밀 필요는 없어요. 문을 두드리듯 가볍게 두 번이면 됩니다. 손을 펴면 취소되고, 주먹을 뒤로 뺀 채 가만히 있으면 IDLE이 돼요."
        case .enrollFace: "여러 번 등록하면 인식이 좋아져요. 메뉴에서 언제든 다시 할 수 있어요."
        case .calibrateCursor: "커서가 손끝을 따라가요. 측정이 이상하면 '다시 측정'을 누르면 돼요. 메뉴의 '커서 영역 보정'으로 언제든 다시 할 수 있어요."
        case .zoom: "새끼손가락은 꼭 접어 주세요 — 네 손가락이 다 펴지면 손바닥으로 읽혀서 데스크탑 전환 모드로 갑니다. 시스템 설정 > 손쉬운 사용 > 확대/축소에서 '키보드 단축키로 확대/축소 사용'이 꺼져 있으면 화면 대신 앱 확대(⌘+/⌘-)로 보냅니다."
        case .volumeBrightness: "어느 쪽이든 한 번 바뀌면 클리어예요."
        case .enterCursor: "한 번 톡 하면 오버레이에 '한 번 더 톡'이 떠요."
        case .moveCursor: "커서가 화면 끝까지 안 가면 나중에 메뉴바 > 커서 영역 보정… 에서 맞출 수 있어요."
        case .click: "두 번 연달아 톡톡 하면 더블클릭이에요."
        case .park: "5초 동안 아무도 안 보여도 저절로 IDLE이 돼요."
        case .rightClick, .scroll, .drag: nil
        }
    }
}

struct TutorialView: View {
    let pipeline: Pipeline
    let session: TutorialSession
    let onEnroll: () -> Void
    let onCalibrate: () -> Void
    let close: () -> Void

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
        }
    }

    private func mission(_ step: TutorialStep, course: TutorialCourse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cleared = session.justCleared {
                Text("✅ \(cleared.title) 클리어!")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(step.symbol).font(.system(size: 52))
            Text(step.title).font(.title.bold())
            Text(step.instruction).font(.title3).wrapping()
            if step == .zoom {
                HStack(spacing: 16) {
                    Text(course.zoomedIn ? "✅ 확대" : "⬜ 확대")
                    Text(course.zoomedOut ? "✅ 축소" : "⬜ 축소")
                }
                .font(.headline)
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
