import AppKit
import GestureCore
import SwiftUI

/// Says, unmistakably, that the next sideways sweep switches desktops. The status pill alone wasn't enough — the
/// user (2026-09-14) couldn't tell the mode was on from a strip at the top of the screen — so this frames the whole
/// display and puts a badge in the middle of it.
///
/// It is click-through and on every Space, like the pill: the frame has to stay put while the desktop slides out
/// from under it, or it would vanish at the moment it is describing.
@MainActor
final class DesktopModePanelController {
    private let panel: NSPanel

    init(pipeline: Pipeline) {
        panel = NSPanel(
            contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: DesktopModeView(pipeline: pipeline))
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct DesktopModeView: View {
    let pipeline: Pipeline
    /// The frame sits inside the screen edge so it reads as a border rather than a cropped window.
    private static let inset = 6.0

    var body: some View {
        ZStack {
            frame
            // Middle of the screen, not the bottom: the user couldn't see it down there (2026-09-14).
            badge
        }
        .ignoresSafeArea()
        // Nothing here is ever clickable, and the panel already ignores the mouse; this keeps hit-testing off the
        // SwiftUI side too.
        .allowsHitTesting(false)
    }

    /// A glow around the whole display: visible from the corner of the eye without covering anything.
    private var frame: some View {
        RoundedRectangle(cornerRadius: 22)
            .strokeBorder(
                LinearGradient(
                    colors: [.purple.opacity(0.95), .indigo.opacity(0.75), .purple.opacity(0.95)],
                    startPoint: .leading, endPoint: .trailing
                ),
                lineWidth: 8
            )
            .shadow(color: .purple.opacity(0.6), radius: 18)
            .padding(Self.inset)
    }

    private var badge: some View {
        HStack(spacing: 20) {
            arrow("chevron.left", caption: "이전", lit: pipeline.lastSwipe == .left)
            VStack(spacing: 6) {
                Text("🖐 데스크탑 전환 모드")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text(hint)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            arrow("chevron.right", caption: "다음", lit: pipeline.lastSwipe == .right)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay(
            RoundedRectangle(cornerRadius: 26).strokeBorder(.purple.opacity(0.55), lineWidth: 2)
        )
        .shadow(radius: 24, y: 8)
    }

    private var hint: String {
        return pipeline.swipeArmed ? "준비됨 · 손을 옆으로 쓸어 주세요" : "손을 멈추면 곧 준비됩니다"
    }

    /// The arrow on the side the hand just swept toward lights up, so a sweep that worked is visibly answered. Its
    /// caption says which desktop that sweep goes to: the hand points at the desktop it wants, so sweeping right
    /// goes to the next one. That is the opposite of the trackpad's three-finger swipe, and it is the user's own
    /// call — made on 2026-09-13 and made again on 2026-09-14 when a build shipped the trackpad direction.
    private func arrow(_ symbol: String, caption: String, lit: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .heavy))
            Text(caption)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(lit ? AnyShapeStyle(.purple) : AnyShapeStyle(.tertiary))
        .scaleEffect(lit ? 1.15 : 1)
        .animation(.snappy(duration: 0.25), value: lit)
    }
}
