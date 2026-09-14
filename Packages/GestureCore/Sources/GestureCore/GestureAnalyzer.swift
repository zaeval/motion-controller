import Foundation

/// Everything the analyzer concluded about the tracked hand on one frame.
public struct GestureReading: Sendable {
    public var timestamp: TimeInterval
    public var chirality: Chirality
    public var pose: StaticPose?
    public var isPinching: Bool
    public var pinchAxis: PinchAxisControl.Axis?
    /// Net volume/brightness steps per target since the current pinch engaged.
    public var pinchTotals: [ContinuousTarget: Int]
    public var palmSpeed: Double
    public var isSweeping: Bool
    public var isStill: Bool
    public var inActiveRegion: Bool
    public var openness: Double?
    public var palmFacesCamera: Bool?
    /// Thumb, index, middle, ring, little.
    public var extendedFingers: [Bool]
    public var steps: [PinchAxisControl.Step]
    /// A zoom step that fired on this frame: +1 in, -1 out, 0 none.
    public var zoomStep: Int
    /// Wrist–middle-knuckle midpoint in Vision-normalized coordinates (un-mirrored, y up): the point the cursor rides.
    public var pointer: Vec2?
    /// Hand size in image heights.
    public var handScale: Double
    /// Source image width / height.
    public var imageAspect: Double
    /// A closed hand with the index tucked in; a pinch never reads as one.
    public var isFist: Bool
    /// An index tap that completed on this frame.
    public var tap: FingerTap?
    /// The index is bending for a tap.
    public var isTapDipping: Bool
    /// A fist pulled back, completed on this frame.
    public var idleGesture: Bool
    /// The index is held bent toward the camera: the hand moves the cursor.
    public var isIndexBent: Bool
    /// Index tip → knuckle along the palm, in knuckle spans, and how far it reaches when straight; for tuning the bend.
    public var indexReachAlongPalm: Double?
    public var straightIndexReach: Double?

    /// Net steps on the current axis since the pinch engaged.
    public var pinchTotal: Int {
        pinchAxis.map { pinchTotals[$0.target, default: 0] } ?? 0
    }
}

/// Turns one tracked hand per frame into poses and motion events. Pure and deterministic,
/// so recorded sequences replay identically in tests.
public struct GestureAnalyzer: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        public var thresholds = PoseThresholds()
        public var pinch = PinchTracker.Settings()
        public var swipe = SwipeDetector.Settings()
        public var continuous = PinchAxisControl.Settings()
        public var tap = TapDetector.Settings()
        public var idle = IdleGestureDetector.Settings()
        public var bend = IndexBendDetector.Settings()
        public var zoom = ZoomControl.Settings()
        /// Only a hand whose anchor is above this (Vision-normalized y) counts as raised. Off: the user asked
        /// (2026-09-12) that nothing require raising the hand.
        public var activeRegionMinY = 0.0
        /// Above this palm speed (image heights/s) a pinch can't start and holds restart (Pawvis `pressEngageMaxSpeed`).
        public var sweepSpeed = 1.0
        /// Below this palm speed a static pose's hold advances.
        public var stillSpeed = 0.3
        /// Above this palm speed a pinch takes longer to release, because blur smears the thumb and index apart.
        public var movingSpeed = 0.5
        /// A hand missing this long drops pinch and axis state. Matches the pointer's tracking-loss grace, so a drag
        /// that survives a fast-motion dropout still has its pinch when the hand returns.
        public var handLostReset: TimeInterval = 0.5

        public init() {}
    }

    public var settings: Settings {
        didSet { applySettings() }
    }

    private var palmMotion = PalmMotion()
    private var pinch = PinchTracker()
    private var swipe = SwipeDetector()
    private var axisControl = PinchAxisControl()
    private var taps = TapDetector()
    private var idle = IdleGestureDetector()
    private var indexBend = IndexBendDetector()
    private var zoom = ZoomControl()
    private var lastHandTime: TimeInterval = -.infinity

    /// The swipe that completed on the frame just fed, if any. It sits outside `GestureReading` because a swipe fires
    /// a short moment after the stroke stops and fast strokes end with the hand blurred out of tracking, so the
    /// frame it lands on often has no hand — and a reading on such a frame would read as a hand being present.
    public private(set) var lastSwipe: SwipeDirection?

    /// The palm has held still, and sweeping it sideways now switches desktops.
    public var isSwipeArmed: Bool { swipe.isArmed }

    public init(settings: Settings = Settings()) {
        self.settings = settings
        applySettings()
    }

    /// Feeds one frame's tracked hand, or nil when none was found.
    public mutating func update(hand: HandFrame?, at time: TimeInterval) -> GestureReading? {
        guard let hand, let features = HandFeatures(hand, thresholds: settings.thresholds), let anchor = features.anchor else {
            lastSwipe = swipe.update(nil, at: time)
            _ = taps.update(nil, at: time)
            _ = idle.update(nil, at: time)
            _ = indexBend.update(nil, at: time)
            zoom.reset()
            if time - lastHandTime > settings.handLostReset {
                pinch.reset()
                axisControl.reset()
                palmMotion.reset()
            }
            return nil
        }
        lastHandTime = time

        palmMotion.update(anchor: anchor, at: time)
        let sweeping = palmMotion.speed > settings.sweepSpeed
        let inActiveRegion = anchor.y >= settings.activeRegionMinY
        let pinching = pinch.update(pinchRatio: features.pinchRatio, sweeping: sweeping, moving: palmMotion.speed > settings.movingSpeed)
        let isFist = features.isFist
        let pose = GestureRules.classify(features, pinching: pinching)
        // Both modes zoom from here, so the steps are the same whichever one the hand is in.
        let zoomStep = zoom.update(
            active: pose == .threeFingers && inActiveRegion, anchor: anchor, handSize: features.scale, at: time
        )

        let swipeSample = SwipeDetector.Sample(
            anchor: anchor,
            flatHand: Finger.allCases.filter { features.isExtended($0) == true }.count >= 3,
            pinching: pinching,
            fist: isFist,
            palmFacesCamera: features.palmFacesCamera,
            imageAspect: hand.imageAspect
        )
        lastSwipe = swipe.update(swipeSample, at: time)
        // A fist that happens to close the thumb onto the index is not a volume drag.
        let steps = axisControl.update(pinching: pinching && inActiveRegion && !isFist, anchor: anchor, handSize: features.scale)
        let tap = taps.update(
            TapDetector.Sample(
                indexReach: features.reach(.index),
                middleReach: features.reach(.middle),
                middleExtended: features.isExtended(.middle),
                pinching: pinching,
                palm: anchor,
                handScale: features.scale,
                palmSpeed: palmMotion.speed
            ),
            at: time
        )
        // A tap dips further than any bend for a few frames; those frames don't count toward one. Taps aren't gated on
        // the bend in turn: learned from a pointed ☝️, a ✌️'s index or a relaxed resting one reads as bent, and
        // recorded right clicks and double taps were lost to that.
        let indexReachAlongPalm = features.reachAlongPalm(.index)
        let isIndexBent = indexBend.update(indexReachAlongPalm, at: time, holding: taps.isDipping)
        let idleGesture = idle.update(
            IdleGestureDetector.Sample(fist: isFist, handScale: features.scale),
            at: time
        )

        let pointer = hand.normalizedPosition(of: .wrist).flatMap { wrist in
            hand.normalizedPosition(of: .middleMCP).map { wrist.midpoint(with: $0) }
        }

        return GestureReading(
            timestamp: time,
            chirality: hand.chirality,
            pose: pose,
            isPinching: pinching,
            pinchAxis: axisControl.axis,
            pinchTotals: axisControl.totals,
            palmSpeed: palmMotion.speed,
            isSweeping: sweeping,
            isStill: palmMotion.speed < settings.stillSpeed,
            inActiveRegion: inActiveRegion,
            openness: features.openness,
            palmFacesCamera: features.palmFacesCamera,
            extendedFingers: features.extendedFingers,
            steps: steps,
            zoomStep: zoomStep,
            pointer: pointer,
            handScale: features.scale,
            imageAspect: hand.imageAspect,
            isFist: isFist,
            tap: tap,
            isTapDipping: taps.isDipping,
            idleGesture: idleGesture,
            isIndexBent: isIndexBent,
            indexReachAlongPalm: indexReachAlongPalm,
            straightIndexReach: indexBend.straightReach
        )
    }

    public mutating func reset() {
        lastSwipe = nil
        palmMotion.reset()
        pinch.reset()
        swipe.reset()
        axisControl.reset()
        taps.reset()
        idle.reset()
        indexBend.reset()
        zoom.reset()
        lastHandTime = -.infinity
    }

    private mutating func applySettings() {
        pinch.settings = settings.pinch
        swipe.settings = settings.swipe
        axisControl.settings = settings.continuous
        taps.settings = settings.tap
        idle.settings = settings.idle
        indexBend.settings = settings.bend
        zoom.settings = settings.zoom
    }
}
