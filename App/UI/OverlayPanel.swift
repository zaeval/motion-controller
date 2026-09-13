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
        switch pipeline.mode {
        case .idle: .gray
        case .normal: .green
        case .pointer: pipeline.pointerStatus.pressed ? .orange : .blue
        }
    }

    private var detail: String {
        guard pipeline.personPresent else { return pipeline.mode == .idle ? "사람 없음" : "사람 없음 · 곧 IDLE" }
        switch pipeline.mode {
        case .idle: return idleDetail
        case .normal: return gestureDetail
        case .pointer: return pointerDetail
        }
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
        if pipeline.modeProgress > 0 { return "✊ 제스처 모드로 전환 \(progressBar(pipeline.modeProgress))" }
        if status.engaged { return "👉 이동 중 · 검지 펴면 멈춤" }
        return "👉 굽혀 이동 · ☝️ 톡 클릭 · ✌️ 톡 우클릭 · 🤏 드래그 · ✊ 끝"
    }

    private var gestureDetail: String {
        guard let reading = pipeline.latestReading else { return pipeline.flash ?? "손 없음" }
        // A live pinch outranks the flash so the running total never hides behind the previous drag's summary.
        if reading.isPinching {
            guard let axis = reading.pinchAxis else { return "🤏 ↕ 볼륨 / ↔ 밝기" }
            return reading.pinchTotal == 0 ? axis.displayName : "\(axis.displayName) \(reading.pinchTotal.signedText)"
        }
        if let flash = pipeline.flash { return flash }
        if let pending = pipeline.pendingAction {
            return "\(pending.pose.displayName) → \(pending.action.displayName) \(progressBar(pending.progress))"
        }
        if pipeline.awaitingSecondTap { return "☝️ 한 번 더 톡 → 커서 모드" }
        return reading.pose?.displayName ?? "…"
    }

    private func progressBar(_ progress: Double) -> String {
        let filled = min(max(Int(progress * 5), 0), 5)
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: 5 - filled)
    }
}
