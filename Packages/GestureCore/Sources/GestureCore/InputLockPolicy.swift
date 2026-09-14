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
        for event: Event, at location: CGPoint, asking: Bool, keysReachDialog: Bool, dialogFrames: [CGRect]
    ) -> Verdict {
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
