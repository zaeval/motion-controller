import Foundation

/// Whether the camera can see well enough to be believed. The user's call (2026-09-14): when the light isn't
/// enough, the app stops acting on what it thinks it sees.
///
/// It matters most for the screen lock, because every presence decision runs backwards in the dark. A camera that
/// can't see the person in front of it reports nobody there, so an unlit room reads as an empty one: the screen
/// goes black and locks while the owner sits there, and their face — the way back in — is exactly what the camera
/// can't make out. So darkness must not decide anything. Whatever state the screen is in when the light goes is the
/// state it keeps: unlocked stays unlocked, locked stays locked, and Touch ID or the password still get in.
///
/// Holding state is also the only stable choice, because in a dim room the screen is most of what the camera sees.
/// Were darkness taken to mean "nobody can be seen, so assume someone is there", a blacked-out screen would wake
/// itself, light the room, find nobody, go dark, and start over.
///
/// The measure is the frame's mean luma, and the marks below are the ones this camera actually reads. It has to be
/// measured rather than reasoned about, because auto-exposure spends sensor gain to keep the picture mid-grey and a
/// dark room comes out brighter than it is. Checking the exposure the camera reached would settle it, but macOS
/// publishes no `iso` or `exposureDuration` on `AVCaptureDevice` (iOS only), so luma is what there is.
public struct SceneLight: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Mean luma at or below which the scene is too dark to judge, 0–1. The user's lit room measured 0.64–0.70
        /// on the built-in camera (2026-09-14), so this sits far enough below normal light to leave the app alone
        /// and only catch a genuinely unlit room or a covered lens. Erring low is the safe direction: not gating is
        /// the behaviour that was there before, while gating wrongly freezes the screen.
        public var darkLuma = 0.10
        /// Mean luma the scene has to come back to before the app acts again. Above `darkLuma` on purpose: a hand
        /// passing over the lens or a flickering light must not flap the gate.
        public var lightLuma = 0.16
        /// A reading has to disagree with the current verdict for this long to change it.
        public var dwell: TimeInterval = 1.5

        public init() {}
    }

    public var settings: Settings
    public private(set) var isDark = false
    /// The last frame's luma, for the log and the debug preview.
    public private(set) var luma: Double?
    /// When the current reading started disagreeing with `isDark`; nil while it agrees.
    private var disagreedSince: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feeds one frame's light (nil when there are no frames). Returns the new verdict on the frames it changes on,
    /// and nil otherwise — including for every frame with no camera, which holds the verdict rather than clearing it.
    public mutating func update(luma newLuma: Double?, at time: TimeInterval) -> Bool? {
        guard let newLuma else { return nil }
        luma = newLuma
        let disagrees = isDark ? newLuma >= settings.lightLuma : newLuma <= settings.darkLuma
        guard disagrees else {
            disagreedSince = nil
            return nil
        }
        let since = disagreedSince ?? time
        disagreedSince = since
        guard time - since >= settings.dwell else { return nil }
        isDark.toggle()
        disagreedSince = nil
        return isDark
    }

    /// Forgets the frames seen so far, without changing the verdict: the camera stopped, so nothing new is known.
    public mutating func reset() {
        disagreedSince = nil
        luma = nil
    }
}
