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
        Text("켜기/끄기: ⌃⌥⌘G")
        Toggle("커서 모드", isOn: Binding(
            get: { appState.pipeline.mode == .pointer },
            set: { appState.pipeline.setPointerMode($0) }
        ))
        .disabled(!appState.isEnabled)
        Button(appState.isCalibrating ? "커서 영역 보정 취소" : "커서 영역 보정…") { appState.toggleCalibration() }
            .disabled(!appState.isEnabled)
        Button("커서 영역 기본값으로") { appState.pipeline.clearCalibration() }
        if !appState.pipeline.accessibilityTrusted {
            Button("손쉬운 사용 권한 설정 열기…") { appState.pipeline.openAccessibilitySettings() }
        }
        Divider()
        Button("디버그 프리뷰 열기…") {
            openWindow(id: DebugPreviewView.windowID)
            NSApp.activate()
        }
        Divider()
        Button("종료") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
