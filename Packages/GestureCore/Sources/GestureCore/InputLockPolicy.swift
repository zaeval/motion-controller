import CoreGraphics
import Foundation

/// What happens to each keyboard, mouse or trackpad event while the dark screen is locked. Pure, so the rules that
/// decide whether anyone gets past the lock can be tested without an event tap.
///
/// - Locked: nothing gets through. A key or button press brings up Touch ID or the password; moving or scrolling
///   doesn't, so a bumped desk doesn't.
/// - Asking: only what the authentication dialog needs. Pointer events inside its windows, and keys only while they
///   go to the dialog — it is the frontmost app, or secure input is on as a focused password field turns it on — so
///   the password goes into the dialog and not into whatever app sits behind the dark screen.
/// - From an exempt app: everything gets through, in either state, and nothing asks. These are apps the owner ticked in
///   the menu, typing and clicking for someone who isn't at the Mac (KakaoWeb on the bot Mac, 2026-10-15); a person at
///   the keyboard is the hardware, never an exempt app, so they stay held back. While the dialog is up an exempt app's
///   keys go wherever focus is — the dialog — which only happens after someone pressed something.
public enum InputLockPolicy {
    public enum Event: Sendable {
        case keyDown, keyUp, modifiers
        case pointerMove, buttonDown, buttonUp
        case scroll
        /// Gestures, media keys, tablet events: never needed to unlock.
        case other
    }

    public struct Verdict: Equatable, Sendable {
        public var passes: Bool
        /// Bring up the authentication dialog.
        public var asksToUnlock: Bool

        public init(passes: Bool, asksToUnlock: Bool) {
            self.passes = passes
            self.asksToUnlock = asksToUnlock
        }
    }

    /// `dialogFrames` are the authentication dialog's windows in global display coordinates. None found means the
    /// dialog can't be told apart, and the pointer goes everywhere rather than leaving it unclickable.
    public static func verdict(
        for event: Event, at location: CGPoint, asking: Bool, keysReachDialog: Bool, dialogFrames: [CGRect],
        fromExemptApp: Bool = false
    ) -> Verdict {
        if fromExemptApp {
            return Verdict(passes: true, asksToUnlock: false)
        }
        guard asking else {
            return Verdict(passes: false, asksToUnlock: event == .keyDown || event == .buttonDown)
        }
        let passes = switch event {
        case .keyDown, .keyUp, .modifiers: keysReachDialog
        case .pointerMove, .buttonDown, .buttonUp: dialogFrames.isEmpty || dialogFrames.contains { $0.contains(location) }
        case .scroll, .other: false
        }
        return Verdict(passes: passes, asksToUnlock: false)
    }
}
