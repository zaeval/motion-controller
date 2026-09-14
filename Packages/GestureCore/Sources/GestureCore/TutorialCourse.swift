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
}

/// The tutorial's missions, in the order they're played: every gesture and mode, each cleared by actually doing it.
public enum TutorialStep: String, CaseIterable, Sendable {
    case enterGestures, switchDesktop, playPause, zoom, volumeBrightness
    case enterCursor, moveCursor, click, rightClick, scroll, drag
    case backToGestures, park

    /// The mode the mission's gesture works in; nil when it's the one that changes the mode.
    public var requiredMode: InteractionMode? {
        switch self {
        case .switchDesktop, .playPause, .zoom, .volumeBrightness: .normal
        case .moveCursor, .click, .rightClick, .scroll, .drag, .backToGestures: .pointer
        case .enterGestures, .enterCursor, .park: nil
        }
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
        index += 1
        return step
    }

    public mutating func skip() {
        guard let step = current else { return }
        skipped.insert(step)
        index += 1
    }
}
