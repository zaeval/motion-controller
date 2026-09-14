import AppKit
import GestureCore
import SwiftUI

/// The window that enrolls a face: who it is, a mirrored camera view, how far along it is, and what to do next.
/// Closing it before it finishes keeps every face enrolled before.
@MainActor
final class FaceEnrollmentPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let pipeline: Pipeline

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        super.init()
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
    }

    /// A new person when `face` is nil, otherwise that person enrolled again under the same name.
    func show(replacing face: EnrolledFace?) {
        pipeline.cancelEnrollment()
        panel.title = face.map { "\($0.name) 얼굴 다시 등록" } ?? "얼굴 등록"
        let name = face?.name ?? (pipeline.enrolledFaces.isEmpty ? "나" : "")
        panel.contentView = NSHostingView(rootView: FaceEnrollmentView(
            pipeline: pipeline, replacing: face?.id, initialName: name
        ) { [weak self] in
            self?.panel.close()
        })
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        pipeline.cancelEnrollment()
    }
}

struct FaceEnrollmentView: View {
    let pipeline: Pipeline
    let replacing: UUID?
    let close: () -> Void
    @State private var name: String

    init(pipeline: Pipeline, replacing: UUID?, initialName: String, close: @escaping () -> Void) {
        self.pipeline = pipeline
        self.replacing = replacing
        self.close = close
        _name = State(initialValue: initialName)
    }

    private var canStart: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 14) {
            CameraPreview(session: pipeline.camera.session, deviceID: pipeline.selectedDeviceID)
                .aspectRatio(pipeline.frameAspect, contentMode: .fit)
                .frame(width: 400)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            switch pipeline.enrollmentStatus {
            case .off:
                Text("누구의 얼굴인가요?").font(.title3.bold())
                TextField("이름", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit(start)
                let others = pipeline.enrolledFaces.faces.filter { $0.id != replacing }.map(\.name)
                if !others.isEmpty {
                    Text("등록된 사람: \(others.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("취소", action: close)
                    Button("등록 시작", action: start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canStart)
                }
            case .collecting:
                Text("\(pipeline.enrollingName ?? name) · 카메라를 보고 잠시 있어 주세요").font(.title3.bold())
                ProgressView(value: pipeline.enrollmentProgress)
                Text(pipeline.enrollmentHint ?? "얼굴을 찾는 중…")
                    .foregroundStyle(.secondary)
                Text("사진은 저장하지 않아요. 얼굴에서 뽑은 숫자 512개만 이 Mac에 저장돼요.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack {
                    Button("나중에", action: close)
                    Button("처음부터") { pipeline.restartEnrollment() }
                }
            case .saved:
                Text("\(pipeline.enrollingName ?? name) 등록 완료").font(.title3.bold())
                Text("등록된 사람 누구의 얼굴이든 까만 화면 잠금을 풀 수 있어요. 더 추가하거나 지우는 건 메뉴의 '등록된 얼굴'에서 해요.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("닫기", action: close)
                    .keyboardShortcut(.defaultAction)
            }

            if !pipeline.isRunning {
                Text("제스처 인식이 꺼져 있어 카메라가 멈춰 있어요. 메뉴바에서 켜 주세요.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func start() {
        guard canStart else { return }
        pipeline.startEnrollment(name: name, replacing: replacing)
    }
}
