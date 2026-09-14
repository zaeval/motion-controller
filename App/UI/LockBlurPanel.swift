import AppKit
import SwiftUI

/// Frosted glass over the whole screen while the Touch ID / password dialog is up.
///
/// The screen has to be visible for that dialog — you can't answer a prompt you can't see — and until now it was made
/// visible by turning the gamma part way back up, which showed whoever is standing there the actual desktop. The user
/// asked (2026-09-14) for it blurred instead, which is what the macOS lock screen does: the brightness comes all the
/// way back so the dialog is legible, and this panel sits between it and the desktop so there is nothing to read.
///
/// It sits one level below `.screenSaver`, because the authentication dialog's own window is at 1000 — the same level
/// our overlay panels use — and covering the dialog would strand whoever is trying to get in.
@MainActor
final class LockBlurPanelController {
    /// One per display: the brightness comes back on every screen, so every screen needs covering.
    private var panels: [NSPanel] = []

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        panel.contentView = blur

        // The blur alone still leaves large shapes and colours readable; the tint takes care of that.
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(tint)

        let message = NSHostingView(rootView: LockBlurMessage())
        message.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(message)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: blur.topAnchor),
            tint.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            message.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            // Above the middle: the dialog itself comes up in the centre of the screen.
            message.centerYAnchor.constraint(equalTo: blur.centerYAnchor, constant: -240),
        ])
        return panel
    }

    /// Covers every display, since the gamma this replaces came back on all of them.
    func show() {
        let screens = NSScreen.screens
        while panels.count < screens.count {
            panels.append(Self.makePanel())
        }
        for (panel, screen) in zip(panels, screens) {
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
        }
        for panel in panels.dropFirst(screens.count) {
            panel.orderOut(nil)
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
    }
}

private struct LockBlurMessage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40, weight: .semibold))
            Text("잠긴 화면")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            Text("Touch ID나 로그인 암호로 잠금을 해제하세요")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
    }
}
