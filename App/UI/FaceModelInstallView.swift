import AppKit
import GestureCore
import SwiftUI

/// The offer to install the face model, shown wherever enrollment would otherwise be impossible: the tutorial's
/// enrollment mission and the enrollment panel itself.
///
/// It used to be a block of shell commands with a "copy" button. The user (2026-09-14) asked for a button that just
/// installs it — and they were right twice over, because pasting the commands downloaded the model into the source
/// tree, where it did nothing until the app was built again. The commands are kept as a fallback for when the
/// download fails.
struct FaceModelInstallView: View {
    let pipeline: Pipeline
    /// The tutorial offers a way past this mission; the enrollment panel passes nil and closes instead.
    var onSkip: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("얼굴 인식 모델이 아직 없어요")
                .font(.headline)
            Text("라이선스 때문에 앱에 넣어 둘 수 없는 파일이라 한 번만 내려받으면 됩니다 (약 44MB). 설치가 끝나면 다시 빌드하거나 앱을 켰다 끌 필요 없이 바로 얼굴을 등록할 수 있어요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            state
            if case .failed(let why) = pipeline.faceModelInstall {
                Text("⚠️ \(why)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                manual
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    @ViewBuilder
    private var state: some View {
        switch pipeline.faceModelInstall {
        case .idle, .failed:
            HStack {
                Button(retrying ? "다시 시도" : "모델 설치 (약 44MB)") { pipeline.installFaceModel() }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                if let onSkip {
                    Button("건너뛰기", action: onSkip)
                }
            }
        case .downloading(let fraction):
            if let fraction {
                ProgressView(value: fraction) {
                    Text("내려받는 중 \(Int(fraction * 100))%")
                }
                .frame(maxWidth: 320)
            } else {
                ProgressView { Text("내려받는 중…") }
            }
        case .compiling:
            ProgressView { Text("모델 준비 중… (잠깐 걸려요)") }
        case .installed:
            Text("✅ 설치 완료 · 이제 얼굴을 등록할 수 있어요")
                .font(.callout)
                .foregroundStyle(.green)
        }
    }

    private var retrying: Bool {
        if case .failed = pipeline.faceModelInstall { return true }
        return false
    }

    /// The README's steps 2 and 3 for when the download can't work — behind a disclosure so the button stays the
    /// obvious thing to do. No `#` comments in the block: zsh doesn't take them at an interactive prompt, so a
    /// commented line pasted in becomes `cd: too many arguments` and everything after it runs in the wrong place.
    private var manual: some View {
        DisclosureGroup("터미널로 설치하기") {
            VStack(alignment: .leading, spacing: 6) {
                Text("첫 줄의 경로는 project.yml이 있는 폴더로 바꿔 주세요. 이 방법은 마지막에 앱을 다시 빌드해야 합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.commands)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                Button("명령 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.commands, forType: .string)
                }
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    static let commands = """
        cd "$HOME/motion controller"
        curl -L -o /tmp/AdaFace_IR18.mlpackage.zip https://github.com/john-rocky/CoreML-Models/releases/download/adaface-v1/AdaFace_IR18.mlpackage.zip
        mkdir -p App/Vision/Models && unzip -o /tmp/AdaFace_IR18.mlpackage.zip -d App/Vision/Models
        xcodegen generate && xcodebuild -project MotionController.xcodeproj -scheme MotionController -configuration Debug -derivedDataPath build/DerivedData build
        """
}
