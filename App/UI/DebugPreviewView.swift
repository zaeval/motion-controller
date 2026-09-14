import AVFoundation
import GestureCore
import SwiftUI

struct DebugPreviewView: View {
    static let windowID = "debug-preview"

    @Bindable var pipeline: Pipeline
    @State private var label = ""

    var body: some View {
        // Scrolls because the full panel is taller than a 14" display; the bottom rows used to end up off-screen.
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    CameraPreview(session: pipeline.camera.session, deviceID: pipeline.selectedDeviceID)
                    SkeletonOverlay(frame: pipeline.latestFrame)
                }
                .aspectRatio(pipeline.frameAspect, contentMode: .fit)
                .frame(maxWidth: 560)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity)

                if pipeline.cameraAuthorized == false {
                    Text("카메라 권한이 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 카메라에서 허용해 주세요.")
                        .foregroundStyle(.red)
                }

                HStack {
                    Picker("카메라", selection: $pipeline.selectedDeviceID) {
                        Text("기본 (내장)").tag(String?.none)
                        ForEach(pipeline.devices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    Picker("HandSource", selection: $pipeline.handSourceMode) {
                        Text("(A) body + detectsHands").tag(HandSourceMode.bodyWithHands)
                        Text("(B) hand pose + body 10fps").tag(HandSourceMode.handsPlusBody)
                    }
                }

                Text(statsLine)
                    .font(.system(.body, design: .monospaced))
                Text(lockLine)
                    .font(.system(.body, design: .monospaced))

                if let visionError = pipeline.visionError {
                    Text("Vision 오류 (\(pipeline.visionErrorCount)회): \(visionError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Toggle("커서 모드", isOn: Binding(
                        get: { pipeline.mode == .pointer },
                        set: { pipeline.setPointerMode($0) }
                    ))
                    .disabled(!pipeline.isRunning)
                    Text(pointerLine)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    if !pipeline.accessibilityTrusted {
                        Button("손쉬운 사용 권한 열기…") { pipeline.openAccessibilitySettings() }
                    }
                }

                recordingControls

                if let reading = pipeline.latestReading {
                    ReadingPanel(reading: reading)
                } else {
                    Text("추적 중인 손 없음").foregroundStyle(.secondary)
                }

                GroupBox("움직임 제스처") {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("스와이프  ← \(pipeline.swipeCounts[.left, default: 0])   → \(pipeline.swipeCounts[.right, default: 0])")
                                .font(.system(.title3, design: .monospaced))
                            Button("카운터 초기화") { pipeline.resetSwipeCounts() }
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(pipeline.recentEvents) { entry in
                                Text("\(entry.date.formatted(date: .omitted, time: .standard))  \(entry.text)")
                                    .font(.caption.monospaced())
                            }
                        }
                        .frame(width: 260, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("라벨 (예: swipe-left)", text: $label)
                Button("현재 프레임 저장") { pipeline.saveSnapshot(label: label) }
                    .disabled(pipeline.latestFrame == nil)
                Button(pipeline.isRecording ? "녹화 중…" : "3초 녹화") { pipeline.recordSequence(label: label) }
                    .disabled(pipeline.isRecording || !pipeline.isRunning)
                Button("폴더 열기") { pipeline.revealFixtures() }
            }
            Group {
                if pipeline.isRecording {
                    Text("● 녹화 중 · \(pipeline.recordingFrameCount)프레임").foregroundStyle(.red)
                } else if !pipeline.isRunning {
                    Text("제스처 인식이 꺼져 있어 녹화할 수 없습니다. 메뉴바에서 켜 주세요.").foregroundStyle(.orange)
                } else if let error = pipeline.lastError {
                    Text("저장 실패: \(error)").foregroundStyle(.red)
                } else if let url = pipeline.lastSavedURL {
                    Text("저장됨 (\(pipeline.savedFileCount)개): \(url.lastPathComponent)").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private var statsLine: String {
        let stats = pipeline.stats
        return String(
            format: "FPS %.1f · Vision %.1f ms · 사람 %d · 손 %d (몸에 안 붙은 손 %d)",
            stats.fps, stats.processingMilliseconds, stats.bodies, stats.hands, stats.looseHands
        )
    }

    private var lockLine: String {
        let face = pipeline.faceTemplate == nil ? "얼굴 미등록" : "얼굴 등록됨"
        let lock = pipeline.isLocked ? "🔒 잠김" : pipeline.lockEnabled ? "잠금 켜짐" : "잠금 꺼짐"
        let similarity = pipeline.lastFaceSimilarity.map { String(format: " · 유사도 %.2f", $0) } ?? ""
        return "\(lock) · \(face)\(similarity)"
    }

    private var pointerLine: String {
        let access = pipeline.accessibilityTrusted ? "손쉬운 사용 허용됨" : "손쉬운 사용 권한 필요"
        let person = pipeline.personPresent ? "사람 있음" : "사람 없음"
        guard pipeline.mode == .pointer else { return "\(pipeline.mode.displayName) · \(person) · \(access)" }
        let status = pipeline.pointerStatus
        let state = status.dragging ? "드래그" : status.pressed ? "누름" : status.scrolling ? "스크롤" : status.zooming ? "확대/축소" : status.engaged ? "이동" : "멈춤"
        return "커서 · \(person) · \(access) · \(state)"
    }
}

private struct ReadingPanel: View {
    let reading: GestureReading

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("포즈")
                Text(reading.pose?.displayName ?? "—").bold()
            }
            GridRow {
                Text("손가락 엄지→새끼")
                Text(reading.extendedFingers.map { $0 ? "●" : "○" }.joined(separator: " "))
            }
            GridRow {
                Text("손바닥 방향")
                Text(palmText)
            }
            GridRow {
                Text("펼침")
                Text(reading.openness.map { String(format: "%.2f", $0) } ?? "—")
            }
            GridRow {
                Text("핀치")
                Text(pinchText)
            }
            GridRow {
                Text("손 속도")
                Text(String(format: "%.2f /s", reading.palmSpeed) + (reading.isSweeping ? " · 휘두르는 중" : "") + (reading.isStill ? " · 정지" : ""))
            }
            GridRow {
                Text("주먹 · 톡")
                Text((reading.isFist ? "주먹" : "—") + " · " + (reading.isTapDipping ? "검지 굽히는 중" : "—"))
            }
            GridRow {
                Text("검지 굽힘")
                Text(bendText)
            }
        }
        .font(.system(.body, design: .monospaced))
    }

    /// Reach along the palm in knuckle spans against the straight reach: bent below 86% of it, straight above 92%.
    private var bendText: String {
        let reach = reading.indexReachAlongPalm.map { String(format: "%.2f", $0) } ?? "—"
        guard let straight = reading.straightIndexReach else { return "\(reach) · 편 검지 측정 중" }
        let percent = reading.indexReachAlongPalm.map { String(format: " (%.0f%%)", $0 / straight * 100) } ?? ""
        let state = reading.isIndexBent ? "굽힘 → 커서 이동" : "폄 → 멈춤"
        return "\(reach) / 폈을 때 \(String(format: "%.2f", straight))\(percent) · \(state)"
    }

    private var palmText: String {
        let hand = switch reading.chirality {
        case .left: "왼손"
        case .right: "오른손"
        case .unknown: "?"
        }
        let facing = switch reading.palmFacesCamera {
        case true?: "손바닥"
        case false?: "손등"
        case nil: "—"
        }
        return "\(hand) · \(facing)"
    }

    private var pinchText: String {
        guard reading.isPinching else { return "아니오" }
        switch reading.pinchAxis {
        case .vertical?: return "예 · 세로 고정 (볼륨) · \(reading.pinchTotal.signedText)"
        case .horizontal?: return "예 · 가로 고정 (밝기) · \(reading.pinchTotal.signedText)"
        case nil: return "예 · 축 결정 전"
        }
    }
}

/// Mirrored so it reads like a mirror; Vision itself always gets the un-mirrored buffer.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    /// Only here so a camera switch re-applies mirroring to the new connection.
    let deviceID: String?

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(session: session)
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { view.applyMirroring() }
    }

    final class PreviewView: NSView {
        private let previewLayer = AVCaptureVideoPreviewLayer()
        /// Written once in init and read in deinit, where main-actor isolation isn't available.
        nonisolated(unsafe) private var observer: NSObjectProtocol?

        init(session: AVCaptureSession) {
            super.init(frame: .zero)
            previewLayer.session = session
            previewLayer.videoGravity = .resizeAspectFill
            layer = previewLayer
            wantsLayer = true
            observer = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyMirroring() }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func layout() {
            super.layout()
            applyMirroring()
        }

        func applyMirroring() {
            guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}

private struct SkeletonOverlay: View {
    let frame: PoseFrame?

    private static let handChains: [[HandJoint]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
        [.indexMCP, .middleMCP, .ringMCP, .littleMCP],
    ]

    private static let bodyChains: [[BodyJoint]] = [
        [.leftWrist, .leftElbow, .leftShoulder, .rightShoulder, .rightElbow, .rightWrist],
        [.nose, .neck],
    ]

    var body: some View {
        Canvas { context, size in
            guard let frame else { return }
            for (index, person) in frame.bodies.enumerated() {
                drawBody(person, index: index, in: context, size: size)
                for hand in person.hands {
                    drawHand(hand, color: hand.chirality == .left ? .orange : .cyan, in: context, size: size)
                }
            }
            for hand in frame.looseHands {
                drawHand(hand, color: .gray, in: context, size: size)
            }
        }
    }

    /// Vision (origin bottom-left, un-mirrored) → view (origin top-left, mirrored like the preview).
    private func viewPoint(_ point: Vec2, _ size: CGSize) -> CGPoint {
        CGPoint(x: (1 - point.x) * size.width, y: (1 - point.y) * size.height)
    }

    private func drawBody(_ person: GestureCore.Body, index: Int, in context: GraphicsContext, size: CGSize) {
        for chain in Self.bodyChains {
            stroke(chain.map { person.normalizedPosition(of: $0) }, color: .white.opacity(0.7), width: 3, in: context, size: size)
        }
        if let anchor = person.normalizedPosition(of: .nose) ?? person.normalizedPosition(of: .neck) {
            let point = viewPoint(anchor, size)
            context.draw(Text("#\(index)").font(.headline).foregroundStyle(.white), at: CGPoint(x: point.x, y: point.y - 18))
        }
    }

    private func drawHand(_ hand: HandFrame, color: Color, in context: GraphicsContext, size: CGSize) {
        for chain in Self.handChains {
            stroke(chain.map { hand.normalizedPosition(of: $0) }, color: color, width: 2, in: context, size: size)
        }
        for joint in HandJoint.allCases {
            guard let position = hand.normalizedPosition(of: joint) else { continue }
            let point = viewPoint(position, size)
            context.fill(Path(ellipseIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)), with: .color(color))
        }
        if let wrist = hand.normalizedPosition(of: .wrist) {
            let label = switch hand.chirality {
            case .left: "Left"
            case .right: "Right"
            case .unknown: "?"
            }
            let point = viewPoint(wrist, size)
            context.draw(Text(label).font(.caption.bold()).foregroundStyle(color), at: CGPoint(x: point.x, y: point.y + 14))
        }
    }

    /// Draws consecutive segments, skipping any whose endpoints are missing.
    private func stroke(_ points: [Vec2?], color: Color, width: CGFloat, in context: GraphicsContext, size: CGSize) {
        var path = Path()
        for (from, to) in zip(points, points.dropFirst()) {
            guard let from, let to else { continue }
            path.move(to: viewPoint(from, size))
            path.addLine(to: viewPoint(to, size))
        }
        context.stroke(path, with: .color(color), lineWidth: width)
    }
}
