// Click, drag and scroll behavior adapted from Pawvis (MIT, © 2026 Alexandria Redmon):
// Sources/PawvisCore/Gestures/GestureEngine.swift and GestureConfig.swift for the tap window and drag thresholds,
// the jitter deadbands, double-click chaining, the tracking-loss grace, the scroll anchor and the hand-sized
// interaction box; Sources/PawvisCore/Geometry/CoordinateMapper.swift for the mirrored box mapping.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// The part of the camera frame that spans the screen, as margins (frame fractions) of the mirrored view the user
/// sees. It maps a hand onto the screen and measures scroll travel.
public struct InteractionBox: Codable, Equatable, Sendable {
    public var left: Double
    public var right: Double
    public var top: Double
    public var bottom: Double

    public init(left: Double, right: Double, top: Double, bottom: Double) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }

    /// Pawvis's hand-sized box. A near (big) hand gets wider margins so its fingers stay in frame with the cursor at
    /// a screen edge; the top margin is the largest because the fingers reach well above the palm the cursor rides.
    public static func fitted(toHandScale scale: Double) -> InteractionBox {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), high) }
        let side = clamp(0.60 * scale + 0.05, 0.08, 0.40)
        return InteractionBox(
            left: side,
            right: side,
            top: clamp(1.35 * scale + 0.05, 0.10, 0.48),
            bottom: clamp(0.50 * scale + 0.05, 0.08, 0.30)
        )
    }

    /// Vision-normalized camera point (un-mirrored, y up) → screen fraction (x right, y down). Unclamped, so a scroll
    /// keeps counting past the box.
    public func screenPoint(forCamera point: Vec2) -> Vec2 {
        Vec2(
            (1 - point.x - left) / max(1 - left - right, 1e-6),
            (1 - point.y - top) / max(1 - top - bottom, 1e-6)
        )
    }

    /// Pulls the margins back symmetrically until the box spans at least this much each way, so a bad calibration
    /// can't leave the cursor with no room to move.
    func widened(toSpan span: Double) -> InteractionBox {
        func fix(_ low: Double, _ high: Double) -> (Double, Double) {
            let current = 1 - low - high
            guard current < span else { return (low, high) }
            let pull = (span - current) / 2
            return (low - pull, high - pull)
        }
        let (left, right) = fix(left, right)
        let (top, bottom) = fix(top, bottom)
        return InteractionBox(left: left, right: right, top: top, bottom: bottom)
    }

    func moved(toward target: InteractionBox, by fraction: Double) -> InteractionBox {
        func step(_ from: Double, _ to: Double) -> Double { from + (to - from) * fraction }
        return InteractionBox(
            left: step(left, target.left),
            right: step(right, target.right),
            top: step(top, target.top),
            bottom: step(bottom, target.bottom)
        )
    }
}

public enum PointerCommand: Equatable, Sendable {
    /// Positions are screen fractions, origin top-left.
    case move(Vec2)
    case buttonDown(Vec2, clickCount: Int)
    case drag(Vec2)
    case buttonUp(Vec2, clickCount: Int)
    case rightClick(Vec2)
    /// Screen heights of travel; positive scrolls up, like a wheel rolled away from you.
    case scroll(Double)
}

/// Drives the cursor from one hand. The interaction box maps onto the screen, so the cursor goes where the hand is:
/// the user's choice on 2026-09-13, after trying the trackpad-like `Mapping.relative`, which nudges the cursor from
/// wherever it is and zeroes the hand whenever tracking starts over. Either way the cursor only follows an index held
/// bent toward the camera; a straight index is a finger lifted off the pad and parks the cursor where it is, so under
/// absolute mapping it goes to the hand when the index bends again. The cursor rides the palm, which taps and pinches
/// barely move.
///
/// - An index tap clicks, and two in quick succession double-click; a tap with the middle finger up right-clicks.
/// - A pinch presses where the cursor is: moving while pinched drags, a quick pinch clicks, holding still presses.
///   The button only goes down once the pinch proves to be one, so a fist closing through a pinch sends nothing.
/// - The V sign parks the cursor and turns vertical hand travel into scrolling.
/// - Three fingers park it too, while `ZoomControl` in the analyzer turns their travel into zoom steps.
public struct PointerController: Sendable {
    public enum Mapping: String, Codable, Sendable {
        /// The interaction box maps onto the screen: the cursor is wherever the hand is.
        case absolute
        /// Like a trackpad: hand movement nudges the cursor from where it is, and faster hands move it further.
        case relative
    }

    /// A pose that parks the cursor and turns vertical hand travel into something else.
    public enum Travel: Sendable, Equatable {
        case scroll, zoom
    }

    public struct Settings: Codable, Equatable, Sendable {
        /// How a hand position becomes a cursor position.
        public var mapping = Mapping.absolute
        /// Only an index held bent toward the camera moves the cursor; otherwise any tracked hand moves it.
        public var moveOnlyWhileBent = true
        public var filter = OneEuroFilter.Params.cursor
        /// A fixed box for measuring scroll travel, or nil to fit the box to the hand as it is seen.
        public var box: InteractionBox?
        /// Fraction of the gap to the fitted box closed per frame (about 2 s to refit at 30 fps).
        public var boxDrift = 0.05
        /// EMA weight on the measured hand size the box is fitted to.
        public var handScaleSmoothing = 0.1
        /// Relative mapping only: screen widths of cursor travel per hand size of hand travel, for a slow and a fast
        /// hand; speeds are hand sizes per second. Between them the gain eases, like pointer acceleration.
        public var slowGain = 0.12
        public var fastGain = 0.36
        public var slowSpeed = 1.0
        public var fastSpeed = 6.0
        /// Relative mapping only: main display width over height, so the hand moves the cursor as far up as sideways.
        public var screenAspect = 1.6
        /// Relative mapping only: hand travel (hand sizes) that doesn't move the cursor, so a still hand can't wander.
        public var stillDeadband = 0.03
        /// A tracking gap longer than this zeroes the hand again where it comes back (relative mapping).
        public var rezeroGap: TimeInterval = 0.25
        /// After a pinch the cursor stays pinned this long unless the hand clearly flicks, and a pinch held still this
        /// long presses the button.
        public var tapWindow: TimeInterval = 0.30
        /// Travel (screen fractions) inside the tap window that starts a drag at once.
        public var dragIntentDistance = 0.030
        /// Travel after the tap window that starts a drag.
        public var dragActivationDistance = 0.010
        /// Minimum travel between emitted drag positions; plain moves use half.
        public var jitterDeadband = 0.004
        public var doubleClickInterval: TimeInterval = 0.5
        public var doubleClickSlop = 0.025
        /// A hand missing this long lets go of the button; shorter dropouts keep a drag alive. Recorded fast-motion
        /// dropouts last up to 0.4 s.
        public var trackingLossGrace: TimeInterval = 0.5
        /// Consecutive frames needed to start or stop scrolling or zooming.
        public var scrollDebounceFrames = 3
        public var invertScroll = false

        public init() {}

        /// Screen widths per hand size for a hand moving `speed` hand sizes per second.
        public func gain(forSpeed speed: Double) -> Double {
            guard fastSpeed > slowSpeed else { return slowGain }
            let t = min(max((speed - slowSpeed) / (fastSpeed - slowSpeed), 0), 1)
            return slowGain + (fastGain - slowGain) * t * t * (3 - 2 * t)
        }
    }

    public struct Sample: Sendable {
        /// Vision-normalized pointer point (un-mirrored, y up).
        public var point: Vec2
        /// Hand size in image heights.
        public var handScale: Double
        /// Source image width / height.
        public var imageAspect: Double
        public var pinching: Bool
        public var scrollPose: Bool
        /// Three fingers: vertical travel zooms.
        public var zoomPose: Bool
        /// An index tap that completed on this frame.
        public var tap: FingerTap?
        /// A finger is bending for a tap: the cursor holds still.
        public var holdStill: Bool
        public var fist: Bool
        /// The index is held bent toward the camera, so the hand moves the cursor. A held pinch drags either way.
        public var engaged: Bool

        public init(
            point: Vec2, handScale: Double, imageAspect: Double = 1, pinching: Bool = false, scrollPose: Bool = false,
            zoomPose: Bool = false, tap: FingerTap? = nil, holdStill: Bool = false, fist: Bool = false, engaged: Bool = true
        ) {
            self.point = point
            self.handScale = handScale
            self.imageAspect = imageAspect
            self.pinching = pinching
            self.scrollPose = scrollPose
            self.zoomPose = zoomPose
            self.tap = tap
            self.holdStill = holdStill
            self.fist = fist
            self.engaged = engaged
        }
    }

    private struct Press: Sendable {
        var downAt: Vec2
        var downTime: TimeInterval
        var clickCount: Int
        /// Absolute mapping only: cursor minus the hand's mapped position when the press began, so a drag that starts
        /// from a parked cursor follows the hand's travel instead of leaping to wherever the hand drifted.
        var offset: Vec2
        /// Whether the button-down has gone out.
        var sent = false
        var dragging = false
        /// Held by the other hand's fist rather than by this hand's pinch, so the pinch logic leaves it alone.
        var external = false
    }

    public var settings: Settings
    /// The last position sent to the screen, or where the cursor was when the hand was zeroed.
    public private(set) var cursor: Vec2?
    public private(set) var box: InteractionBox
    /// What vertical hand travel is doing instead of moving the cursor, if anything.
    public private(set) var travel: Travel?
    public var isScrolling: Bool { travel == .scroll }
    public var isZooming: Bool { travel == .zoom }
    /// A pinch is in progress, whether or not the button has gone down yet.
    public var isPressed: Bool { press != nil }
    /// The button is down.
    public var isHoldingButton: Bool { press?.sent ?? false }
    public var isDragging: Bool { press?.dragging ?? false }

    private var filter: OneEuroFilter2D
    private var press: Press?
    /// Where the hand puts the cursor; `cursor` follows it past the jitter and drag deadbands.
    private var target: Vec2?
    /// The filtered camera point the hand was last measured from.
    private var reference: (point: Vec2, time: TimeInterval)?
    /// Whether the previous frame was pinching; nil until a frame arrives, so a pinch already held never clicks.
    private var wasPinching: Bool?
    /// A tap already clicked for the pinch being held.
    private var pinchSpent = false
    private var travelFrames = 0
    private var travelAnchor: Double?
    private var smoothedScale: Double?
    private var lastSampleTime: TimeInterval?
    private var lastClick: (time: TimeInterval, at: Vec2, clickCount: Int)?

    public init(settings: Settings = Settings()) {
        self.settings = settings
        box = settings.box ?? .fitted(toHandScale: 0.15)
        filter = OneEuroFilter2D(params: settings.filter)
    }

    /// Feeds one frame, nil when no hand was tracked. `systemCursor` (screen fraction) is where the cursor starts
    /// whenever the hand is zeroed.
    public mutating func update(_ sample: Sample?, at time: TimeInterval, systemCursor: Vec2? = nil) -> [PointerCommand] {
        guard let sample else {
            guard let last = lastSampleTime, time - last > settings.trackingLossGrace else { return [] }
            // The hand is really gone: let go where the button was last sent, and start fresh when it returns.
            let commands = forceRelease()
            forgetHand()
            return commands
        }
        if let last = lastSampleTime, time - last > settings.rezeroGap {
            reference = nil
            target = nil
        }
        lastSampleTime = time
        var commands: [PointerCommand] = []

        if target == nil {
            // Zero the hand here. The cursor is picked up where it is now, unless a pinch is holding it.
            if press == nil {
                cursor = systemCursor ?? cursor ?? Vec2(0.5, 0.5)
            }
            target = cursor
        }

        let wasTravelling = travel != nil
        updateTravelPose(sample)
        let point = filter.filter(sample.point, at: time)
        let mapped = box.screenPoint(forCamera: point)

        if let travel {
            // A zoom only parks the cursor here; its steps come from `ZoomControl`.
            if travel == .scroll, let anchor = travelAnchor {
                let distance = mapped.y - anchor
                if abs(distance) >= settings.jitterDeadband {
                    travelAnchor = mapped.y
                    // A rising hand shrinks screen y, which scrolls up.
                    commands.append(.scroll(settings.invertScroll ? distance : -distance))
                }
            } else {
                travelAnchor = mapped.y
            }
            reference = nil
        } else if wasTravelling || (press == nil && (sample.holdStill || sample.fist
            || (settings.moveOnlyWhileBent && !sample.engaged))) {
            // A scroll or zoom just ended, a finger is bending for a tap, or the index isn't bent toward the camera: the
            // cursor parks where it is. Relative mapping also zeroes the hand again once it moves on.
            reference = nil
        } else {
            switch settings.mapping {
            case .absolute: target = Self.clamped(mapped + (press?.offset ?? .zero))
            case .relative: advanceTarget(to: point, sample, at: time)
            }
            emitMovement(into: &commands, at: time)
        }

        handlePinch(sample, mapped: mapped, at: time, into: &commands)
        handleTap(sample, at: time, into: &commands)
        fitBox(toHandScale: sample.handScale)
        return commands
    }

    /// Applies what the other hand asked for (`SecondHandControl`). The press lives in here rather than beside it, so
    /// that cursor movement while it is down is a drag, and so a lost hand, a mode change or quitting lets go of it
    /// the way they let go of a pinch.
    public mutating func apply(_ intent: SecondHandIntent, at time: TimeInterval) -> [PointerCommand] {
        let at = cursor ?? Vec2(0.5, 0.5)
        switch intent {
        case .click:
            guard press == nil else { return [] }
            return click(at: at, clickCount: chainedClickCount(at: at, time: time), time: time)
        case .rightClick:
            guard press == nil else { return [] }
            return [.rightClick(at)]
        case .press:
            guard press == nil else { return [] }
            // Down at once and dragging from the start: a fist is a press, not a pinch that might turn out to be one.
            // The offset keeps a parked cursor where it is until the hand moves, as a pinch's does.
            press = Press(
                downAt: at, downTime: time, clickCount: 1, offset: at - (target ?? at), sent: true, dragging: true,
                external: true
            )
            return [.buttonDown(at, clickCount: 1)]
        case .release:
            return forceRelease()
        case .scroll(let travel):
            guard press == nil else { return [] }
            // Image y grows upward, and a positive scroll goes up, so the travel carries straight over.
            return [.scroll(settings.invertScroll ? -travel : travel)]
        }
    }

    /// Lets go of a held button without chaining into a double-click: mode changes, a lost hand, shutting down.
    /// A pinch whose button never went down just ends.
    public mutating func forceRelease() -> [PointerCommand] {
        guard let current = press else { return [] }
        press = nil
        lastClick = nil
        return current.sent ? [.buttonUp(cursor ?? current.downAt, clickCount: current.clickCount)] : []
    }

    /// Clears everything except the fitted box. Call `forceRelease()` first if a button may be down.
    public mutating func reset() {
        press = nil
        cursor = nil
        lastClick = nil
        pinchSpent = false
        forgetHand()
    }

    private mutating func forgetHand() {
        filter.reset()
        wasPinching = nil
        travel = nil
        travelFrames = 0
        travelAnchor = nil
        smoothedScale = nil
        lastSampleTime = nil
        reference = nil
        target = nil
    }

    private mutating func advanceTarget(to point: Vec2, _ sample: Sample, at time: TimeInterval) {
        guard let reference, let target else {
            self.reference = (point, time)
            return
        }
        let scale = max(sample.handScale, 1e-6)
        // Hand sizes; image-right and up are positive.
        let dx = (point.x - reference.point.x) * sample.imageAspect / scale
        let dy = (point.y - reference.point.y) / scale
        let travel = (dx * dx + dy * dy).squareRoot()
        guard travel >= settings.stillDeadband else { return }
        let gain = settings.gain(forSpeed: travel / max(time - reference.time, 1e-3))
        // Image-right is the user's left, and screen y grows downward.
        self.target = Vec2(
            min(max(target.x - dx * gain, 0), 1),
            min(max(target.y - dy * gain * settings.screenAspect, 0), 1)
        )
        self.reference = (point, time)
    }

    private mutating func emitMovement(into commands: inout [PointerCommand], at time: TimeInterval) {
        guard let target else { return }
        guard var current = press else {
            if cursor.map({ target.distance(to: $0) >= settings.jitterDeadband / 2 }) ?? true {
                cursor = target
                commands.append(.move(target))
            }
            return
        }
        let threshold = time - current.downTime < settings.tapWindow ? settings.dragIntentDistance : settings.dragActivationDistance
        guard current.dragging || target.distance(to: current.downAt) >= threshold else { return }
        if !current.sent {
            current.sent = true
            commands.append(.buttonDown(current.downAt, clickCount: current.clickCount))
        }
        current.dragging = true
        press = current
        // Measured from the last emitted position, so the release lands where the drag was last sent.
        if target.distance(to: cursor ?? current.downAt) >= settings.jitterDeadband {
            cursor = target
            commands.append(.drag(target))
        }
    }

    private mutating func handlePinch(
        _ sample: Sample, mapped: Vec2, at time: TimeInterval, into commands: inout [PointerCommand]
    ) {
        let started = sample.pinching && wasPinching == false
        wasPinching = sample.pinching
        if !sample.pinching { pinchSpent = false }

        if started, press == nil, travel == nil, !pinchSpent, let at = cursor {
            press = Press(
                downAt: at, downTime: time, clickCount: chainedClickCount(at: at, time: time), offset: at - mapped
            )
            target = at
            return
        }
        guard var current = press, !current.external else { return }
        if !sample.pinching {
            press = nil
            if current.sent {
                let at = cursor ?? current.downAt
                commands.append(.buttonUp(at, clickCount: current.clickCount))
                lastClick = (time, at, current.clickCount)
            } else if !sample.fist {
                commands += click(at: current.downAt, clickCount: current.clickCount, time: time)
            }
            if !current.dragging {
                // The wobble of a pinch opening is not movement.
                target = current.downAt
            }
            return
        }
        // Held still past the tap window: a real press — unless the hand is closing into a fist.
        if !current.sent, time - current.downTime >= settings.tapWindow, !sample.fist {
            current.sent = true
            commands.append(.buttonDown(current.downAt, clickCount: current.clickCount))
            press = current
        }
    }

    private mutating func handleTap(_ sample: Sample, at time: TimeInterval, into commands: inout [PointerCommand]) {
        guard let tap = sample.tap, let at = cursor, !isHoldingButton else { return }
        if press != nil {
            // The tap closed into a pinch: that pinch is this click.
            press = nil
            pinchSpent = true
        }
        switch tap {
        case .left:
            commands += click(at: at, clickCount: chainedClickCount(at: at, time: time), time: time)
        case .right:
            commands.append(.rightClick(at))
        }
    }

    private mutating func click(at point: Vec2, clickCount: Int, time: TimeInterval) -> [PointerCommand] {
        lastClick = (time, point, clickCount)
        return [.buttonDown(point, clickCount: clickCount), .buttonUp(point, clickCount: clickCount)]
    }

    private func chainedClickCount(at point: Vec2, time: TimeInterval) -> Int {
        guard let lastClick, time - lastClick.time <= settings.doubleClickInterval,
              point.distance(to: lastClick.at) <= settings.doubleClickSlop, lastClick.clickCount < 3
        else { return 1 }
        return lastClick.clickCount + 1
    }

    private mutating func updateTravelPose(_ sample: Sample) {
        let free = !sample.pinching && press == nil
        let wanted: Travel? = !free ? nil : sample.scrollPose ? .scroll : sample.zoomPose ? .zoom : nil
        guard wanted != travel else {
            travelFrames = 0
            return
        }
        travelFrames += 1
        guard travelFrames >= settings.scrollDebounceFrames else { return }
        travelFrames = 0
        travel = wanted
        travelAnchor = nil
    }

    private static func clamped(_ point: Vec2) -> Vec2 {
        Vec2(min(max(point.x, 0), 1), min(max(point.y, 0), 1))
    }

    private mutating func fitBox(toHandScale scale: Double) {
        if let fixed = settings.box {
            box = fixed
            return
        }
        guard scale > 0 else { return }
        let smoothed = smoothedScale.map { $0 + (scale - $0) * settings.handScaleSmoothing } ?? scale
        smoothedScale = smoothed
        // Never under a held button, a scroll or a zoom: shifting the mapping would scroll or zoom by itself.
        guard press == nil, travel == nil else { return }
        box = box.moved(toward: .fitted(toHandScale: smoothed), by: settings.boxDrift)
    }
}
