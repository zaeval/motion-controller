import Foundation

/// Something the user just did that a tutorial mission can be cleared by.
public enum TutorialEvent: Equatable, Sendable {
    case mode(InteractionMode, because: ModeChangeReason?)
    case desktopSwitched
    case playPaused
    case zoomed(in: Bool)
    case volumeOrBrightness
    /// One frame of the cursor following a bent index.
    case cursorMoved
    case clicked
    case rightClicked
    case scrolled
    case dragged
    /// A face finished enrolling.
    case faceEnrolled
    /// All four cursor corners were captured.
    case cursorCalibrated
    /// The user left security mode on, or switched it off, in the tutorial.
    case securityModeChosen
    /// The same for owner mode.
    case ownerModeChosen
}

/// The tutorial's missions, in the order they're played: every gesture and mode, each cleared by actually doing it.
public enum TutorialStep: String, CaseIterable, Sendable {
    case enterGestures, playPause, zoom, volumeBrightness
    case enterDesktop, switchDesktop
    case enterCursor, moveCursor, click, rightClick, scroll, drag
    case backToGestures, park
    /// The things worth settling once, offered at the end rather than taught: enrolling and calibrating open their
    /// own panels, and security mode is a switch to understand and leave on or off.
    case enrollFace, securityMode, ownerMode, calibrateCursor

    /// The mode the mission's gesture works in; nil when it's the one that changes the mode, or when it isn't a
    /// gesture at all.
    public var requiredMode: InteractionMode? {
        switch self {
        case .playPause, .zoom, .volumeBrightness: .normal
        case .switchDesktop: .desktop
        case .moveCursor, .click, .rightClick, .scroll, .drag, .backToGestures: .pointer
        case .enterGestures, .enterDesktop, .enterCursor, .park, .enrollFace, .securityMode, .ownerMode, .calibrateCursor:
            nil
        }
    }

    /// Steps that open a panel of their own instead of waiting for a gesture.
    public var opensPanel: Bool {
        self == .enrollFace || self == .calibrateCursor
    }

    /// Missions that settle a setting instead of teaching a gesture.
    public var isSetup: Bool {
        opensPanel || self == .securityMode || self == .ownerMode
    }

    /// How many times the mission has to be done before it is cleared. Three, so a gesture is learnt rather than
    /// stumbled into once (the user's call, 2026-09-14); a setup mission is a button press, and pressing it three
    /// times would be nonsense.
    public var repetitions: Int {
        isSetup ? 1 : 3
    }
}

/// The user's way through the tutorial (asked for 2026-09-14: clear each feature by trying it). Pure, so which event
/// clears which mission can be tested without a camera.
public struct TutorialCourse: Equatable, Sendable {
    /// Frames of the cursor following the hand that clear moving it: half a second at 30 fps.
    public static let cursorFrames = 15

    public private(set) var index = 0
    public private(set) var skipped: Set<TutorialStep> = []
    public private(set) var zoomedIn = false
    public private(set) var zoomedOut = false
    public private(set) var cursorFrames = 0
    /// How many times the current mission has been done, out of `current?.repetitions`.
    public private(set) var done = 0

    public init() {}

    public var current: TutorialStep? {
        index < TutorialStep.allCases.count ? TutorialStep.allCases[index] : nil
    }

    public var isFinished: Bool { current == nil }

    /// Done by doing it rather than skipping.
    public func isCleared(_ step: TutorialStep) -> Bool {
        guard let position = TutorialStep.allCases.firstIndex(of: step) else { return false }
        return position < index && !skipped.contains(step)
    }

    /// Feeds one event. Returns the mission it cleared, if any; anything that isn't the current mission's is ignored.
    public mutating func record(_ event: TutorialEvent) -> TutorialStep? {
        guard let step = current else { return nil }
        let clears: Bool
        switch (step, event) {
        case (.enterGestures, .mode(.normal, because: .fist)), (.backToGestures, .mode(.normal, because: .fist)):
            clears = true
        case (.enterCursor, .mode(.pointer, because: .doubleTap)), (.park, .mode(.idle, because: .idleGesture)):
            clears = true
        case (.enterDesktop, .mode(.desktop, because: .palmHold)):
            clears = true
        case (.enrollFace, .faceEnrolled), (.calibrateCursor, .cursorCalibrated),
             (.securityMode, .securityModeChosen), (.ownerMode, .ownerModeChosen):
            clears = true
        case (.switchDesktop, .desktopSwitched), (.playPause, .playPaused), (.volumeBrightness, .volumeOrBrightness),
             (.click, .clicked), (.rightClick, .rightClicked), (.scroll, .scrolled), (.drag, .dragged):
            clears = true
        case (.zoom, .zoomed(let inward)):
            if inward { zoomedIn = true } else { zoomedOut = true }
            clears = zoomedIn && zoomedOut
        case (.moveCursor, .cursorMoved):
            cursorFrames += 1
            clears = cursorFrames >= Self.cursorFrames
        default:
            clears = false
        }
        guard clears else { return nil }
        // Each go resets what the mission counts, so the next one starts from scratch.
        zoomedIn = false
        zoomedOut = false
        cursorFrames = 0
        done += 1
        guard done >= step.repetitions else { return nil }
        done = 0
        index += 1
        return step
    }

    public mutating func skip() {
        guard let step = current else { return }
        skipped.insert(step)
        done = 0
        index += 1
    }
}
