import AppKit
import GestureCore
import SwiftUI

/// The always-on status pill. Window flags follow Pawvis `OverlayController.swift:323-331`:
/// above everything, on every Space and over full-screen apps, and click-through so synthetic
/// clicks and window lookups land on whatever is underneath.
@MainActor
final class OverlayPanelController {
    private static let size = NSSize(width: 520, height: 60)

    private let panel: NSPanel

    init(pipeline: Pipeline) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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

        let host = NSHostingView(rootView: OverlayView(pipeline: pipeline))
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
    }

    func show() {
        positionOnMainScreen()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func positionOnMainScreen() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - Self.size.width / 2, y: visible.maxY - Self.size.height - 6))
    }
}

struct OverlayView: View {
    let pipeline: Pipeline

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(pipeline.mode.displayName)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .opacity(pipeline.mode == .idle ? 0.75 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dotColor: Color {
        // Not the mode's colour while the room is too dark: the mode isn't what's deciding anything.
        if pipeline.sceneIsDark { return .brown }
        switch pipeline.mode {
        case .idle: return .gray
        case .normal: return .green
        case .pointer: return pipeline.pointerStatus.pressed ? .orange : .blue
        case .desktop: return .purple
        }
    }

    private var detail: String {
        // Nothing else is true while the room is too dark: no gesture acts and the screen is left alone, so say that
        // rather than let it look broken.
        if pipeline.sceneIsDark {
            let luma = pipeline.sceneLuma.map { String(format: " (밝기 %.2f)", $0) } ?? ""
            // A locked screen stays locked; what the darkness takes away is the face check, so Touch ID or the
            // password is the way in. Worded so it can't be read as the lock having been let go.
            if pipeline.isLocked { return "🔒 잠김 · 조도 부족으로 얼굴 인식 불가 · Touch ID·암호로 해제" }
            return "🌑 조도 부족 · 제스처 인식 중지\(luma)"
        }
        guard pipeline.personPresent else { return pipeline.mode == .idle ? "사람 없음" : "사람 없음 · 곧 IDLE" }
        switch pipeline.mode {
        case .idle: return idleDetail
        case .normal: return gestureDetail
        case .pointer: return pointerDetail
        case .desktop: return desktopDetail
        }
    }

    private var desktopDetail: String {
        if let flash = pipeline.flash { return flash }
        if pipeline.awaitingSecondTap { return "☝️ 한 번 더 톡 → 커서 모드" }
        if pipeline.modeProgress > 0 { return "✊ 제스처 모드로 전환 \(progressBar(pipeline.modeProgress))" }
        return pipeline.swipeArmed ? "🖐 준비됨 · ← → 쓸기" : "🖐 손바닥을 잠시 멈추고 ← → 쓸기"
    }

    private var idleDetail: String {
        if let flash = pipeline.flash { return flash }
        if pipeline.awaitingSecondTap { return "☝️ 한 번 더 톡 → 커서 모드" }
        if pipeline.modeProgress > 0 { return "✊ 제스처 모드로 전환 \(progressBar(pipeline.modeProgress))" }
        return "✊ 제스처 · ☝️ 톡톡 커서"
    }

    private var pointerDetail: String {
        if !pipeline.accessibilityTrusted { return "⚠️ 손쉬운 사용 권한이 필요합니다" }
        let status = pipeline.pointerStatus
        if status.dragging { return "✊ 드래그 중" }
        if status.pressed { return "🤏 누름" }
        if let flash = pipeline.flash { return flash }
        guard pipeline.latestReading != nil else { return "손 없음" }
        if status.scrolling { return "✌️ 스크롤" }
        if status.zooming { return "🤟 ↑ 확대 · ↓ 축소" }
        if pipeline.modeProgress > 0 { return "✊ 제스처 모드로 전환 \(progressBar(pipeline.modeProgress))" }
        // What the other hand is holding, when there is one: it is the hand doing the clicking now.
        if let other = pipeline.secondHandPose {
            let says: String
            switch other {
            case .pointIndex: says = "☝️ 굽혔다 펴면 클릭"
            case .victory: says = "✌️ 검지 굽혔다 펴면 우클릭"
            case .fist: says = "✊ 누름 유지"
            case .openPalm, .backOfHand: says = "🖐 위아래로 스크롤"
            default: says = String(describing: other)
            }
            return "🤚 반대손 \(says)"
        }
        if status.engaged { return "👉 이동 중 · 검지 펴면 멈춤" }
        return "👉 굽혀 이동 · 반대손 ☝️ 굽혔다 펴기 = 클릭 · ✊ = 누름 · 🖐 = 스크롤"
    }

    private var gestureDetail: String {
        guard let reading = pipeline.latestReading else { return pipeline.flash ?? "손 없음" }
        // A live pinch outranks the flash so the running total never hides behind the previous drag's summary.
        if reading.isPinching {
            guard let axis = reading.pinchAxis else { return "🤏 ↕ 볼륨 / ↔ 밝기" }
            return reading.pinchTotal == 0 ? axis.displayName : "\(axis.displayName) \(reading.pinchTotal.signedText)"
        }
        if let flash = pipeline.flash { return flash }
        if let pending = pipeline.pendingAction, pending.progress >= 1 {
            return "\(pending.action.displayName) · 손을 내리면 실행"
        }
        if pipeline.swipeArmed {
            let hold = pipeline.pendingAction.map { " · 계속 들면 \($0.action.displayName) \(progressBar($0.progress))" } ?? ""
            return "🖐 ↔ 옆으로 쓸면 데스크톱 전환" + hold
        }
        if let pending = pipeline.pendingAction {
            return "\(pending.pose.displayName) → \(pending.action.displayName) \(progressBar(pending.progress))"
        }
        if reading.pose == .threeFingers { return "🤟 ↑ 확대 · ↓ 축소" }
        if pipeline.awaitingSecondTap { return "☝️ 한 번 더 톡 → 커서 모드" }
        return reading.pose?.displayName ?? "…"
    }

    private func progressBar(_ progress: Double) -> String {
        let filled = min(max(Int(progress * 5), 0), 5)
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: 5 - filled)
    }
}
