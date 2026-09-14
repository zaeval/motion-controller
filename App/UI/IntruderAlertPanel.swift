import AppKit
import SwiftUI

/// Shown when the screen comes back after someone tried to use the Mac while it was locked: the latest photo, how
/// many were saved, and the way to the folder.
@MainActor
final class IntruderAlertPanelController {
    private let panel: NSPanel

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.title = "잠긴 동안 입력 시도"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
    }

    func show(count: Int, latest: URL?) {
        panel.contentView = NSHostingView(rootView: IntruderAlertView(
            count: count,
            latest: latest,
            openFolder: { [weak self] in
                NSWorkspace.shared.open(Pipeline.intruderPhotosDirectory)
                self?.panel.close()
            },
            close: { [weak self] in self?.panel.close() }
        ))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct IntruderAlertView: View {
    let count: Int
    let latest: URL?
    let openFolder: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let latest, let image = NSImage(contentsOf: latest) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text("화면이 잠긴 동안 누군가 키보드나 마우스를 쓰려고 했어요")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("사진 \(count)장을 저장했어요.")
                .foregroundStyle(.secondary)
            HStack {
                Button("닫기", action: close)
                Button("사진 폴더 열기", action: openFolder)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
