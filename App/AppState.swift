import Foundation
import GestureCore
import KeyboardShortcuts
import Observation

@MainActor
@Observable
final class AppState {
    let pipeline: Pipeline
    private let overlay: OverlayPanelController
    @ObservationIgnored private let calibrationPanel: CalibrationPanelController
    @ObservationIgnored private let enrollmentPanel: FaceEnrollmentPanelController
    @ObservationIgnored private let intruderAlert = IntruderAlertPanelController()
    @ObservationIgnored private let lockBlur = LockBlurPanelController()
    @ObservationIgnored private let tutorial: TutorialPanelController
    @ObservationIgnored private let desktopModePanel: DesktopModePanelController
    /// Follows `pipeline.mode` so the desktop-mode frame is up exactly while that mode is.
    @ObservationIgnored private var modeWatch: Task<Void, Never>?
    /// Mirrors the pipeline's calibration state so the menu can offer to cancel it.
    private(set) var isCalibrating = false
    private static let enrollmentOfferedKey = "faceEnrollmentOffered"
    private static let tutorialShownKey = "tutorialShown"

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                pipeline.start()
                overlay.show()
            } else {
                pipeline.stop()
                overlay.hide()
                desktopModePanel.hide()
            }
        }
    }

    /// Menu action, and the first launch.
    func showTutorial(onClose: (() -> Void)? = nil) {
        tutorial.show(onClose: onClose)
    }

    /// Menu actions — add a person, or enroll one again — and the first launch without an enrolled face.
    func showEnrollment(replacing face: EnrolledFace? = nil) {
        enrollmentPanel.show(replacing: face)
    }

    private func offerEnrollmentOnce() {
        guard pipeline.enrolledFaces.isEmpty, pipeline.faceUnlockAvailable,
              !UserDefaults.standard.bool(forKey: Self.enrollmentOfferedKey)
        else { return }
        UserDefaults.standard.set(true, forKey: Self.enrollmentOfferedKey)
        showEnrollment()
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
        tutorial = TutorialPanelController(pipeline: pipeline)
        desktopModePanel = DesktopModePanelController(pipeline: pipeline)
        pipeline.onIntruderPhotos = { [intruderAlert] count, latest in
            intruderAlert.show(count: count, latest: latest)
        }
        // The screen has to be legible for the Touch ID dialog; the desktop behind it does not.
        pipeline.onUnlockPrompt = { [lockBlur] asking in
            if asking {
                lockBlur.show()
            } else {
                lockBlur.hide()
            }
        }
        // The tutorial's last two missions are setup, not gestures: they open these panels.
        tutorial.onEnroll = { [weak self] in self?.showEnrollment() }
        tutorial.onCalibrate = { [weak self] in self?.toggleCalibration() }
        pipeline.onModeChange = { [weak self, desktopModePanel] mode in
            if mode == .desktop {
                desktopModePanel.show()
            } else {
                desktopModePanel.hide()
            }
            // Nothing is being recognized in IDLE, so the pill has nothing to say: the user asked (2026-09-14) for
            // it gone until a fist wakes recognition up.
            guard let self, isEnabled else { return }
            if mode == .idle {
                overlay.hide()
            } else {
                overlay.show()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleEnabled) { [weak self] in
            // Switching recognition off would unlock the screen for whoever pressed it.
            guard let self, !self.pipeline.isLocked else { return }
            self.isEnabled.toggle()
        }
        pipeline.start()
        overlay.show()
        pipeline.relockIfInterrupted()

        // The first launch shows the tutorial, then asks for a face if none is enrolled, each once; the menu has both.
        let lockTest = ProcessInfo.processInfo.environment["MC_LOCK_TEST"]
        if lockTest == nil {
            Task {
                try? await Task.sleep(for: .seconds(1))
                if UserDefaults.standard.bool(forKey: Self.tutorialShownKey) {
                    self.offerEnrollmentOnce()
                } else {
                    UserDefaults.standard.set(true, forKey: Self.tutorialShownKey)
                    self.showTutorial { [weak self] in self?.offerEnrollmentOnce() }
                }
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
