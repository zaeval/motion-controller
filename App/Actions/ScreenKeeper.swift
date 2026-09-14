import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import os

/// Blacks the screen out once nobody has been in front of the camera for a while, and brings it back the moment
/// someone is, or touches the keyboard, mouse or trackpad.
///
/// The display itself never sleeps while recognition runs: `Pipeline` holds that for as long as the camera runs,
/// because the user asked (2026-09-14) that the Mac never power down on its own. While someone is seen, user activity
/// is declared every half minute too. Whether that holds off the screen saver is unverified: it left HIDIdleTime
/// running in a test.
///
/// Going dark scales every display's gamma rather than its backlight: no private API, external displays too, and
/// macOS puts the gamma back if the app quits or crashes while dark. Input is watched on its own clock while dark, so
/// a screen whose camera frames stop coming still comes back when touched.
@MainActor
final class ScreenKeeper {
    private struct Gamma {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Screen")
    private static let reason = "Motion Controller: someone is in front of the camera" as CFString
    /// Share of full brightness left while dimmed: none, as the user asked (2026-09-14).
    private static let dimmedLevel = 0.0
    /// While the Touch ID / password dialog is up: all the way back, because `LockBlurPanel` covers the desktop
    /// with frosted glass at the same time. Dimming the screen instead left the desktop readable through it, which
    /// the user objected to (2026-09-14).
    private static let dialogLevel = 1.0
    /// Under the shortest display-sleep setting macOS offers, one minute.
    private static let activityInterval: TimeInterval = 30

    /// Seconds since the last keyboard, mouse or trackpad input.
    static var secondsSinceInput: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }

    private(set) var isDimmed = false
    private var activity = IOPMAssertionID(0)
    private var activityDeclaredAt = -TimeInterval.infinity
    /// Each display's gamma from before dimming; empty while nothing is dimmed.
    private var originalGamma: [CGDirectDisplayID: Gamma] = [:]
    private var level = 1.0
    private var fadeTask: Task<Void, Never>?
    private var inputWatch: Task<Void, Never>?

    /// Every frame the screen should show: someone is there, or left too recently to be sure.
    func stayAwake(personPresent: Bool, at time: TimeInterval) {
        wake()
        if personPresent, time - activityDeclaredAt >= Self.activityInterval {
            activityDeclaredAt = time
            IOPMAssertionDeclareUserActivity(Self.reason, kIOPMUserActiveLocal, &activity)
        }
    }

    /// Nobody has been there a while: black the screen out until someone comes back, or touches something when
    /// `wakesOnInput` — a locked screen comes back only when `wake()` is called.
    func dim(wakesOnInput: Bool = true) {
        guard !isDimmed else { return }
        isDimmed = true
        activityDeclaredAt = -.infinity
        Self.logger.notice("Screen dimmed\(wakesOnInput ? "" : " and locked", privacy: .public)")
        fade(to: Self.dimmedLevel, over: 1)
        guard wakesOnInput else { return }
        inputWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                if Self.secondsSinceInput < 1 {
                    self.wake()
                }
            }
        }
    }

    /// Recognition turned off: full brightness now.
    func release() {
        isDimmed = false
        activityDeclaredAt = -.infinity
        inputWatch?.cancel()
        inputWatch = nil
        fadeTask?.cancel()
        fadeTask = nil
        restoreGamma()
    }

    /// The authentication dialog came up over the dark screen (true), or went away still locked (false).
    func showUnlockDialog(_ visible: Bool) {
        guard isDimmed else { return }
        fade(to: visible ? Self.dialogLevel : Self.dimmedLevel, over: visible ? 0.2 : 0.5)
    }

    func wake() {
        guard isDimmed else { return }
        isDimmed = false
        inputWatch?.cancel()
        inputWatch = nil
        Self.logger.notice("Screen awake")
        fade(to: 1, over: 0.3)
    }

    private func fade(to target: Double, over seconds: Double) {
        fadeTask?.cancel()
        if originalGamma.isEmpty {
            guard target < 1 else { return }
            captureGamma()
        }
        let start = level
        let steps = max(1, Int(seconds * 30))
        fadeTask = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !Task.isCancelled else { return }
                self.apply(start + (target - start) * Double(step) / Double(steps))
            }
            guard let self, !Task.isCancelled, target >= 1 else { return }
            self.restoreGamma()
        }
    }

    private func captureGamma() {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return }
        for display in displays.prefix(Int(count)) {
            let capacity = CGDisplayGammaTableCapacity(display)
            var red = [CGGammaValue](repeating: 0, count: Int(capacity))
            var green = red
            var blue = red
            var samples: UInt32 = 0
            guard CGGetDisplayTransferByTable(display, capacity, &red, &green, &blue, &samples) == .success,
                  samples > 0
            else { continue }
            let used = Int(samples)
            originalGamma[display] = Gamma(
                red: Array(red.prefix(used)), green: Array(green.prefix(used)), blue: Array(blue.prefix(used))
            )
        }
    }

    private func apply(_ newLevel: Double) {
        level = newLevel
        let scale = CGGammaValue(newLevel)
        for (display, gamma) in originalGamma {
            let red = gamma.red.map { $0 * scale }
            let green = gamma.green.map { $0 * scale }
            let blue = gamma.blue.map { $0 * scale }
            CGSetDisplayTransferByTable(display, UInt32(red.count), red, green, blue)
        }
    }

    private func restoreGamma() {
        level = 1
        guard !originalGamma.isEmpty else { return }
        originalGamma = [:]
        CGDisplayRestoreColorSyncSettings()
    }
}
