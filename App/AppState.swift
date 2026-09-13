import Foundation
import KeyboardShortcuts
import Observation

@MainActor
@Observable
final class AppState {
    let pipeline: Pipeline
    @ObservationIgnored private let overlay: OverlayPanelController
    @ObservationIgnored private let calibrationPanel: CalibrationPanelController
    /// Mirrors the pipeline's calibration state so the menu can offer to cancel it.
    private(set) var isCalibrating = false

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

        KeyboardShortcuts.onKeyUp(for: .toggleEnabled) { [weak self] in
            self?.isEnabled.toggle()
        }
        pipeline.start()
        overlay.show()

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
