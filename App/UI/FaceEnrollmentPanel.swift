import AppKit
import SwiftUI

/// The window that enrolls the owner's face: a mirrored camera view, how far along it is, and what to do next.
/// Closing it before it finishes keeps the face enrolled before, if any.
@MainActor
final class FaceEnrollmentPanelController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let pipeline: Pipeline

    init(pipeline: Pipeline) {
        self.pipeline = pipeline
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        super.init()
        panel.title = "얼굴 등록"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FaceEnrollmentView(pipeline: pipeline) { [weak self] in
            self?.panel.close()
        })
    }

    func show() {
        pipeline.startEnrollment()
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
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            CameraPreview(session: pipeline.camera.session, deviceID: pipeline.selectedDeviceID)
                .aspectRatio(pipeline.frameAspect, contentMode: .fit)
                .frame(width: 400)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            switch pipeline.enrollmentStatus {
            case .saved:
                Text("등록 완료").font(.title3.bold())
                Text("까만 화면 잠금이 켜졌어요. 화면이 까매진 뒤에는 얼굴이 확인되거나 Touch ID·암호를 넣어야 풀려요. 메뉴에서 끌 수 있어요.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("닫기", action: close)
                    .keyboardShortcut(.defaultAction)
            case .collecting, .off:
                Text("카메라를 보고 잠시 있어 주세요").font(.title3.bold())
                ProgressView(value: pipeline.enrollmentProgress)
                Text(pipeline.enrollmentHint ?? "얼굴을 찾는 중…")
                    .foregroundStyle(.secondary)
                Text("사진은 저장하지 않아요. 얼굴에서 뽑은 숫자 512개만 이 Mac에 저장돼요.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                HStack {
                    Button("나중에", action: close)
                    Button("처음부터") { pipeline.startEnrollment() }
                }
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
}
