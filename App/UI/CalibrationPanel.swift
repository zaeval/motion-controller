import AppKit
import GestureCore
import SwiftUI

/// The full-screen panel that asks for the four corners. Click-through and above everything, like the status pill, so
/// whatever is underneath keeps working while the user points at the corners.
@MainActor
final class CalibrationPanelController {
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
        panel.contentView = NSHostingView(rootView: CalibrationView(pipeline: pipeline))
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
    }

    private var instructions: some View {
        VStack(spacing: 10) {
            Text("커서 영역 보정")
                .font(.title2.bold())
            Text(pipeline.calibrationCorner.map { "\($0.displayName) 모서리를 검지로 가리키고 잠시 멈추세요" } ?? "완료")
                .font(.title3)
            Text("\(pipeline.calibrationCount)/4 · 메뉴바에서 취소할 수 있습니다")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func target(_ corner: PointerCalibration.Corner) -> some View {
        let active = pipeline.calibrationCorner == corner
        // Corners are asked for in order, so the count says which ones are already in.
        let index = PointerCalibration.Corner.allCases.firstIndex(of: corner) ?? 0
        let done = index < pipeline.calibrationCount
        return ZStack {
            Circle()
                .fill(done ? Color.green.opacity(0.8) : active ? Color.blue.opacity(0.5) : Color.white.opacity(0.2))
                .frame(width: 34, height: 34)
            Circle()
                .trim(from: 0, to: active ? pipeline.calibrationProgress : 0)
                .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 56, height: 56)
            Circle()
                .stroke(.white.opacity(active ? 0.9 : 0.35), lineWidth: 2)
                .frame(width: 56, height: 56)
        }
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
