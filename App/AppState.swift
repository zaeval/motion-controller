import Foundation
import KeyboardShortcuts
import Observation

@MainActor
@Observable
final class AppState {
    let pipeline: Pipeline
    @ObservationIgnored private let overlay: OverlayPanelController
    @ObservationIgnored private let calibrationPanel: CalibrationPanelController
    @ObservationIgnored private let enrollmentPanel: FaceEnrollmentPanelController
    @ObservationIgnored private let intruderAlert = IntruderAlertPanelController()
    /// Mirrors the pipeline's calibration state so the menu can offer to cancel it.
    private(set) var isCalibrating = false
    private static let enrollmentOfferedKey = "faceEnrollmentOffered"

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                pipeline.start()
                overlay.show()
            } else {
                pipeline.stop()
                overlay.hide()
            }
        }
    }

    /// Menu action, and the first launch without an enrolled face.
    func showEnrollment() {
        enrollmentPanel.show()
    }

    /// Menu action: ask for the four screen corners, or stop asking.
    func toggleCalibration() {
        guard !pipeline.isCalibrating else {
            pipeline.cancelCalibration()
            return
        }
        calibrationPanel.show()
        isCalibrating = true
        pipeline.startCalibration { [weak self] in
            self?.calibrationPanel.hide()
            self?.isCalibrating = false
        }
    }

    init() {
        let pipeline = Pipeline()
        self.pipeline = pipeline
        overlay = OverlayPanelController(pipeline: pipeline)
        calibrationPanel = CalibrationPanelController(pipeline: pipeline)
        enrollmentPanel = FaceEnrollmentPanelController(pipeline: pipeline)
        pipeline.onIntruderPhotos = { [intruderAlert] count, latest in
            intruderAlert.show(count: count, latest: latest)
        }

        KeyboardShortcuts.onKeyUp(for: .toggleEnabled) { [weak self] in
            // Switching recognition off would unlock the screen for whoever pressed it.
            guard let self, !self.pipeline.isLocked else { return }
            self.isEnabled.toggle()
        }
        pipeline.start()
        overlay.show()

        // The first launch without an enrolled face asks for it, once; the menu can ask again later.
        let lockTest = ProcessInfo.processInfo.environment["MC_LOCK_TEST"]
        if lockTest == nil, pipeline.faceTemplate == nil, pipeline.faceUnlockAvailable,
           !UserDefaults.standard.bool(forKey: Self.enrollmentOfferedKey) {
            UserDefaults.standard.set(true, forKey: Self.enrollmentOfferedKey)
            Task {
                try? await Task.sleep(for: .seconds(1))
                self.showEnrollment()
            }
        }

        // MC_LOCK_TEST=<seconds> locks at launch for that long, then lets go by itself (at most a minute).
        if let lockTest, let seconds = Double(lockTest) {
            Task {
                try? await Task.sleep(for: .seconds(3))
                pipeline.testLock(for: min(seconds, 60))
            }
        }

        // MC_DESKTOP_TEST=1 checks that the private Dock-swipe fields still switch desktops on this macOS: one
        // desktop over and back again, without needing a gesture.
        if ProcessInfo.processInfo.environment["MC_DESKTOP_TEST"] != nil {
            Task {
                try? await Task.sleep(for: .seconds(2))
                await DesktopSwitcher.runSelfTest()
            }
        }
    }
}
