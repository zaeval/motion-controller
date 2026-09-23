import GestureCore
import SwiftUI

@main
struct MotionControllerApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(appState: appState)
        } label: {
            Image(systemName: appState.isEnabled ? "hand.raised.fill" : "hand.raised.slash")
        }

        Window("디버그 프리뷰", id: DebugPreviewView.windowID) {
            DebugPreviewView(pipeline: appState.pipeline)
        }
        .defaultSize(width: 720, height: 820)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct MenuContent: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("제스처 인식", isOn: $appState.isEnabled)
        Text("켜기/끄기: ⌃⌥⌘G · 꺼도 얼굴 인식·잠금은 그대로")
        Toggle("커서 모드", isOn: Binding(
            get: { appState.pipeline.mode == .pointer },
            set: { appState.pipeline.setPointerMode($0) }
        ))
        .disabled(!appState.isEnabled)
        Button(appState.isCalibrating ? "커서 영역 보정 취소" : "커서 영역 보정…") { appState.toggleCalibration() }
            .disabled(!appState.isEnabled)
        Button("커서 영역 기본값으로") { appState.pipeline.clearCalibration() }
        Divider()
        // On without an enrolled face too: Touch ID or the password is the way in, and a face only adds one that
        // needs no touching.
        Toggle("까만 화면 잠금 (Touch ID·얼굴로 해제)", isOn: Binding(
            get: { appState.pipeline.lockEnabled },
            set: { appState.pipeline.lockEnabled = $0 }
        ))
        Toggle("보안 모드 (모르는 얼굴이면 바로 잠금)", isOn: Binding(
            get: { appState.pipeline.securityMode },
            set: { appState.pipeline.securityMode = $0 }
        ))
        .disabled(!appState.pipeline.lockEnabled || appState.pipeline.enrolledFaces.isEmpty)
        Toggle("주인만 인식 (다른 사람 동작 무시)", isOn: Binding(
            get: { appState.pipeline.ownerMode },
            set: { appState.pipeline.ownerMode = $0 }
        ))
        .disabled(appState.pipeline.enrolledFaces.isEmpty || !appState.pipeline.faceUnlockAvailable)
        // Not disabled without the model any more: the panel offers to install it.
        Button(appState.pipeline.enrolledFaces.isEmpty ? "얼굴 등록…" : "얼굴 추가…") { appState.showEnrollment() }
            .disabled(!appState.pipeline.isRunning)
        if !appState.pipeline.enrolledFaces.isEmpty {
            Menu("등록된 얼굴 \(appState.pipeline.enrolledFaces.faces.count)명") {
                ForEach(appState.pipeline.enrolledFaces.faces) { face in
                    Menu(face.name) {
                        Button("다시 등록…") { appState.showEnrollment(replacing: face) }
                            .disabled(!appState.pipeline.isRunning || !appState.pipeline.faceUnlockAvailable)
                        Button("삭제") { appState.pipeline.removeFace(id: face.id) }
                    }
                }
            }
        }
        if appState.pipeline.intruderPhotoCount > 0 {
            Button("📸 잠긴 동안 찍힌 사진 \(appState.pipeline.intruderPhotoCount)장 보기…") {
                appState.pipeline.revealIntruderPhotos()
            }
        }
        if !appState.pipeline.accessibilityTrusted {
            Button("손쉬운 사용 권한 설정 열기…") { appState.pipeline.openAccessibilitySettings() }
        }
        Divider()
        Button("사용법 보기…") { appState.showTutorial() }
        Button("디버그 프리뷰 열기…") {
            openWindow(id: DebugPreviewView.windowID)
            NSApp.activate()
        }
        Divider()
        Button("종료") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
