import AppKit
import GestureCore
import SwiftUI

/// The full-screen panel that asks for the four corners, twice round, and the small panel of buttons that moves it
/// along. The big one is click-through and above everything, like the status pill, so whatever is underneath keeps
/// working — the menu bar included — while the user points at the corners. The buttons have to be clickable, so they
/// live in their own small panel rather than turning the whole screen into a click trap.
@MainActor
final class CalibrationPanelController {
    private let panel: NSPanel
    private let buttons: NSPanel
    /// The buttons sit above the dimmed backdrop.
    private static let buttonsSize = CGSize(width: 520, height: 96)

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
        panel.contentView = NSHostingView(rootView: CalibrationView(pipeline: pipeline))

        buttons = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.buttonsSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        buttons.isOpaque = false
        buttons.backgroundColor = .clear
        buttons.hasShadow = false
        // Above the backdrop, and clickable: this panel is the only thing on screen that takes the mouse.
        buttons.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        buttons.isFloatingPanel = true
        buttons.becomesKeyOnlyIfNeeded = true
        buttons.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        buttons.hidesOnDeactivate = false
        buttons.isReleasedWhenClosed = false
        buttons.contentView = NSHostingView(rootView: CalibrationButtonsView(pipeline: pipeline))
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        let size = Self.buttonsSize
        buttons.setFrame(
            NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.minY + 120,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        buttons.orderFrontRegardless()
    }

    func hide() {
        buttons.orderOut(nil)
        panel.orderOut(nil)
    }
}

struct CalibrationView: View {
    let pipeline: Pipeline
    /// How far in from the screen edge the targets sit, so they are visible without being off-screen.
    private static let inset = 44.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.35)
                ForEach(PointerCalibration.Corner.allCases, id: \.self) { corner in
                    target(corner)
                        .position(point(for: corner, in: geometry.size))
                }
                instructions
            }
        }
        .ignoresSafeArea()
        // The panel ignores the mouse anyway; this keeps hit-testing off the SwiftUI side too.
        .allowsHitTesting(false)
    }

    private var instructions: some View {
        VStack(spacing: 10) {
            Text("커서 영역 보정")
                .font(.title2.bold())
            Text(prompt)
                .font(.title3)
                .multilineTextAlignment(.center)
            Text(counter)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var prompt: String {
        guard let state = pipeline.calibrationState, let corner = state.corner else { return "완료" }
        if state.awaitingConfirmation {
            return "\(corner.displayName) 모서리를 측정했어요 · 아래 버튼으로 계속하세요"
        }
        return "\(corner.displayName) 모서리를 검지로 가리키고 잠시 멈추세요"
    }

    private var counter: String {
        guard let state = pipeline.calibrationState else { return "" }
        let corners = PointerCalibration.Corner.allCases.count
        let inRound = state.capturedCount - (state.round - 1) * corners
        return "\(state.round)/\(PointerCalibration.rounds)회차 · \(inRound)/\(corners) 모서리 · 두 번 측정해 평균을 씁니다"
    }

    private func target(_ corner: PointerCalibration.Corner) -> some View {
        let state = pipeline.calibrationState
        let asking = state?.corner == corner
        let waiting = asking && state?.awaitingConfirmation == true
        let captures = state?.captures(of: corner) ?? 0
        return ZStack {
            Circle()
                .fill(fill(captures: captures, asking: asking, waiting: waiting))
                .frame(width: 34, height: 34)
            Circle()
                .trim(from: 0, to: asking ? (state?.progress ?? 0) : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 56, height: 56)
            Circle()
                .stroke(.white.opacity(asking ? 0.9 : 0.35), lineWidth: 2)
                .frame(width: 56, height: 56)
            // One tick per round already measured here.
            if captures > 0 {
                Text(String(repeating: "•", count: captures))
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(.white)
            }
        }
    }

    private func fill(captures: Int, asking: Bool, waiting: Bool) -> Color {
        if waiting { return .orange.opacity(0.85) }
        if captures >= PointerCalibration.rounds { return .green.opacity(0.8) }
        if asking { return .blue.opacity(0.5) }
        return .white.opacity(0.2)
    }

    private func point(for corner: PointerCalibration.Corner, in size: CGSize) -> CGPoint {
        let inset = Self.inset
        return switch corner {
        case .topLeft: CGPoint(x: inset, y: inset)
        case .topRight: CGPoint(x: size.width - inset, y: inset)
        case .bottomRight: CGPoint(x: size.width - inset, y: size.height - inset)
        case .bottomLeft: CGPoint(x: inset, y: size.height - inset)
        }
    }
}

/// The row of buttons: cancel while pointing, and after each capture the choice to keep it or measure again. The
/// user asked (2026-09-14) for a button between corners rather than being swept along by the timer.
struct CalibrationButtonsView: View {
    let pipeline: Pipeline

    var body: some View {
        HStack(spacing: 12) {
            if let state = pipeline.calibrationState, state.awaitingConfirmation {
                Button("다시 측정") { pipeline.redoCalibrationCorner() }
                    .controlSize(.large)
                Button(isLast(state) ? "완료" : "다음 모서리") { pipeline.confirmCalibrationCorner() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("모서리를 가리키고 멈추면 버튼이 나타납니다")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("취소") { pipeline.cancelCalibration() }
                .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .shadow(radius: 18, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isLast(_ state: PointerCalibration) -> Bool {
        state.capturedCount >= PointerCalibration.totalCaptures
    }
}
