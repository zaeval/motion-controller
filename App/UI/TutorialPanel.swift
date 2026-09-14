import AppKit
import GestureCore
import KeyboardShortcuts
import SwiftUI

/// Every gesture and shortcut, a page at a time: shown on the first launch (the user asked, 2026-09-14) and from the
/// menu. The bottom line shows what is being recognized right now, so each gesture can be tried while reading it.
@MainActor
final class TutorialPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let pipeline: Pipeline
    private var onClose: (() -> Void)?

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        super.init()
        panel.title = "Motion Controller 사용법"
        panel.level = .floating
        // A panel hides whenever its app isn't frontmost, and a menu-bar app often can't make itself frontmost:
        // the first-launch tutorial was created but never showed (2026-09-14).
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    /// `onClose` runs once the window goes away, however it was closed.
    func show(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        panel.contentView = NSHostingView(rootView: TutorialView(pipeline: pipeline) { [weak self] in
            self?.panel.close()
        })
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        let done = onClose
        onClose = nil
        done?()
    }
}

private struct TutorialItem: Identifiable {
    let symbol: String
    let gesture: String
    let result: String
    var id: String { symbol + gesture }
}

private struct TutorialPage {
    let title: String
    let intro: String
    let items: [TutorialItem]
    var note: String?
}

struct TutorialView: View {
    let pipeline: Pipeline
    let close: () -> Void
    @State private var page = 0

    private var toggleShortcut: String {
        KeyboardShortcuts.getShortcut(for: .toggleEnabled)?.description ?? "⌃⌥⌘G"
    }

    private var pages: [TutorialPage] {
        [
            TutorialPage(
                title: "손으로 Mac 조작하기",
                intro: "카메라가 손을 읽어요. 화면 위쪽의 알약 모양 오버레이가 지금 모드와 인식한 동작을 보여 줘요. 모드는 세 가지예요.",
                items: [
                    TutorialItem(symbol: "💤", gesture: "IDLE", result: "모드를 바꾸는 동작만 받아요. 손을 아무렇게나 움직여도 괜찮아요."),
                    TutorialItem(symbol: "✊", gesture: "제스처 모드", result: "데스크톱 전환, 재생/정지, 확대/축소, 볼륨·밝기"),
                    TutorialItem(symbol: "☝️", gesture: "커서 모드", result: "손이 마우스가 돼요. 이동, 클릭, 드래그, 스크롤"),
                    TutorialItem(symbol: "⌨️", gesture: toggleShortcut, result: "제스처 인식 전체 켜기/끄기"),
                ],
                note: "손을 너무 가까이 대지 말고, 가슴 앞쯤에서 카메라에 손 전체가 보이게 해 주세요."
            ),
            TutorialPage(
                title: "모드 바꾸기",
                intro: "어느 모드에 있든 이 동작으로 옮겨 가요.",
                items: [
                    TutorialItem(symbol: "✊", gesture: "주먹 쥐고 잠깐 유지", result: "제스처 모드로 (IDLE이나 커서 모드에서)"),
                    TutorialItem(symbol: "☝️", gesture: "검지 두 번 톡톡", result: "커서 모드로"),
                    TutorialItem(symbol: "✊↩︎", gesture: "주먹 쥔 채 뒤로 빼기", result: "IDLE로 (쉬고 싶을 때)"),
                    TutorialItem(symbol: "🚶", gesture: "5초 동안 아무도 안 보임", result: "저절로 IDLE로"),
                ]
            ),
            TutorialPage(
                title: "제스처 모드",
                intro: "✊ 주먹을 잠깐 유지해서 들어와요.",
                items: [
                    TutorialItem(symbol: "🖐↔︎", gesture: "손바닥 보이고 0.3초 멈춘 뒤 옆으로 쓸기", result: "데스크톱 전환 · 왼쪽으로 쓸면 다음, 오른쪽이면 이전. 오버레이에 '↔ 준비'가 뜨면 쓸면 돼요"),
                    TutorialItem(symbol: "🖐⏯", gesture: "손바닥 1.2초 들고 있다가 내리기", result: "재생/정지 · 내리기 전에 주먹을 쥐면 취소"),
                    TutorialItem(symbol: "🤟", gesture: "세 손가락 펴고 위/아래로", result: "화면 확대/축소"),
                    TutorialItem(symbol: "🤏↕︎", gesture: "엄지·검지 붙이고 위/아래로", result: "볼륨 올리기/내리기"),
                    TutorialItem(symbol: "🤏↔︎", gesture: "엄지·검지 붙이고 좌/우로", result: "밝기 올리기/내리기"),
                ]
            ),
            TutorialPage(
                title: "커서 모드",
                intro: "☝️ 검지를 두 번 톡톡 해서 들어와요.",
                items: [
                    TutorialItem(symbol: "👉", gesture: "검지를 살짝 굽힌 채 움직이기", result: "커서 이동 · 검지를 펴면 멈춰요"),
                    TutorialItem(symbol: "☝️", gesture: "검지 톡 / 톡톡", result: "클릭 / 더블클릭"),
                    TutorialItem(symbol: "✌️", gesture: "브이에서 검지만 톡", result: "우클릭"),
                    TutorialItem(symbol: "🤏", gesture: "엄지·검지 붙이고 움직이기", result: "누른 채 드래그"),
                    TutorialItem(symbol: "✌️↕︎", gesture: "브이 모양으로 위/아래", result: "스크롤"),
                    TutorialItem(symbol: "🤟", gesture: "세 손가락 위/아래", result: "확대/축소"),
                    TutorialItem(symbol: "✊", gesture: "주먹 유지", result: "제스처 모드로 돌아가기"),
                ],
                note: "커서가 화면 끝까지 안 가면 메뉴바 > 커서 영역 보정… 에서 네 모서리를 가리켜 맞춰요."
            ),
            TutorialPage(
                title: "자리를 비우면",
                intro: "인식이 켜져 있는 동안 Mac은 잠들지 않아요.",
                items: [
                    TutorialItem(symbol: "💤", gesture: "5초 동안 아무도 없음", result: "IDLE로 바뀌어요"),
                    TutorialItem(symbol: "🌙", gesture: "10초 동안 아무도 없음", result: "화면이 완전히 까매져요"),
                    TutorialItem(symbol: "🔒", gesture: "얼굴을 등록했다면", result: "까만 화면이 잠겨요. 등록된 얼굴이 보이거나 Touch ID·암호를 넣어야 풀려요"),
                    TutorialItem(symbol: "📸", gesture: "잠긴 동안 누가 키보드·마우스를 만지면", result: "사진을 찍어 두고, 다시 켜질 때 보여 줘요"),
                ],
                note: "잠금은 macOS 잠금 화면을 대신하지 않아요. 오래 자리를 비울 때는 ⌃⌘Q로 잠가 주세요."
            ),
            TutorialPage(
                title: "키보드 단축키와 메뉴",
                intro: "메뉴바의 ✋ 아이콘에서 모든 설정을 열 수 있어요.",
                items: [
                    TutorialItem(symbol: "⌨️", gesture: toggleShortcut, result: "제스처 인식 켜기/끄기 (화면이 잠긴 동안은 안 돼요)"),
                    TutorialItem(symbol: "🔍", gesture: "⌥⌘8", result: "화면 확대가 남아 있을 때 끄기 (macOS 확대/축소)"),
                    TutorialItem(symbol: "🔒", gesture: "⌃⌘Q", result: "macOS 화면 잠금"),
                    TutorialItem(symbol: "✋", gesture: "메뉴바 아이콘", result: "커서 모드, 커서 영역 보정, 까만 화면 잠금, 얼굴 추가, 찍힌 사진, 디버그 프리뷰, 사용법 다시 보기"),
                ],
                note: "확대/축소가 안 되면 시스템 설정 > 손쉬운 사용 > 확대/축소에서 '키보드 단축키를 사용하여 확대/축소'를 켜 주세요."
            ),
        ]
    }

    var body: some View {
        let pages = pages
        let current = pages[page]
        let last = pages.count - 1
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(current.title).font(.title2.bold())
                Spacer()
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
            }
            Text(current.intro)
                .foregroundStyle(.secondary)
                .wrapping()

            VStack(alignment: .leading, spacing: 11) {
                ForEach(current.items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.symbol)
                            .font(.title2)
                            .frame(width: 52, alignment: .center)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.gesture).font(.body.weight(.semibold))
                            Text(item.result).foregroundStyle(.secondary).wrapping()
                        }
                    }
                }
            }

            if let note = current.note {
                Text(note)
                    .font(.callout)
                    .wrapping()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
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
                if page < last {
                    Button("건너뛰기", action: close)
                }
                Spacer()
                Button("이전") { page -= 1 }
                    .disabled(page == 0)
                Button(page == last ? "시작하기" : "다음") {
                    if page == last { close() } else { page += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580, height: 600)
    }

    /// What recognition sees right now, to try the page's gestures against.
    private var liveText: String {
        guard pipeline.isRunning else { return "지금: 제스처 인식이 꺼져 있어요 (\(toggleShortcut)로 켜기)" }
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
