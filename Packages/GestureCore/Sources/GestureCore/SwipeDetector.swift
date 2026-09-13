import Foundation

public enum SwipeDirection: String, Codable, Sendable {
    /// The hand travelled toward the user's left.
    case left
    /// The hand travelled toward the user's right.
    case right

    public var opposite: SwipeDirection { self == .left ? .right : .left }
}

/// Left/right hand swipes, judged one *run* at a time: a stretch of palm travel that holds its direction until the
/// hand turns around or stops. Recorded swipes (Tests/GestureCoreTests/Fixtures/sequences) forced that shape on the
/// detector three times over.
///
/// First, the palm turns away from the camera mid-swipe, so showing the palm isn't required; a swipe starts from a
/// hand held still and arcs downward, so there is no deceleration check and the axis ratio is loose; and a
/// comfortable swipe often starts below the pinch gestures' active region.
///
/// Second, travel alone can't tell a swipe from everything else the hand does: the gentlest recorded swipe crossed
/// 0.046 frame widths while a cursor move crossed 0.332. What separates them is the hand's shape held over time —
/// recorded swipes keep three fingers or more out for 3–30 frames in a row, while scroll flicks, taps and cursor
/// moves never manage one — plus the run's mean speed, which is 0.16–1.54 frame widths per second for a real stroke
/// and 0.01–0.11 for the flat-handed drift of the parking gesture. Measuring speed over the whole run is what makes
/// that gap exist: a 0.4 s sliding window finds a fast slice inside a slow drift and fires on it.
///
/// Third, travel can't tell *which way* the swipe went either. Every recorded swipe begins with a wind-up in the
/// opposite direction, and a third of the clips switched the wrong desktop because the wind-up qualified first. So a
/// qualifying run waits out `grace` before it fires and an opposing run can take its place while it waits — but only
/// on the right terms, because a *return* stroke is also an opposing run and travels just as far (up to 1.25× the
/// stroke it undoes). The tell is size: wind-ups measured 0.043–0.125 frame widths and strokes 0.151–0.591, so a run
/// still under `strokeTravel` is treated as a wind-up and yields to any larger run, while one past it is a real
/// stroke that only a clearly dominant run can displace. Everything after the first swipe is a return stroke, which
/// `oppositeSuppression` swallows.
public struct SwipeDetector: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Horizontal travel a run needs, in frame widths. The gentlest recorded swipe crossed 0.046.
        public var minTravel = 0.04
        /// The run's mean horizontal speed, in frame widths per second. The slowest recorded stroke managed 0.16 and
        /// the fastest flat-handed non-swipe run 0.11.
        public var minSpeed = 0.14
        /// A run longer than this is a drift, not a swipe. The slowest recorded stroke took 1.10 s.
        public var maxDuration: TimeInterval = 1.2
        /// Horizontal travel must be at least this multiple of the vertical, both in image heights. The gentlest
        /// recorded swipe, taken across the body, managed 1.3.
        public var axisRatio = 1.2
        /// A swipe must start at least this high in the frame (Vision-normalized y). Off: the user asked (2026-09-12)
        /// that nothing require raising the hand, so a resting or typing hand can swipe too.
        public var minStartHeight = 0.0
        /// Frames in a row that must show a flat hand (three fingers or more out). Recorded swipes held 3–30 in a
        /// row; the one mistracked cursor move that flickered into shape held 1.
        public var minFlatRun = 3
        /// The flat run may be found this long before the run began. A quick stroke spans only 3 flat frames itself,
        /// but the hand was already flat while winding up.
        public var flatLookback: TimeInterval = 0.5
        /// A run that is a control pinch for at least this much of its length is a volume or brightness drag rather
        /// than a swipe.
        public var maxPinchShare = 0.75
        /// Travel that marks a run as a real stroke rather than a wind-up, in frame widths.
        public var strokeTravel = 0.14
        /// How much farther an opposing run must travel to displace a waiting stroke. Return strokes reached 1.25× at
        /// most, and the stroke that follows a stroke-sized wind-up reached 2.0×.
        public var dominance = 1.3
        /// How long a run waits after it ends before firing, so the stroke that follows a wind-up can take its place.
        /// The tightest case needed 0.235 s to out-travel its wind-up.
        public var grace: TimeInterval = 0.3
        /// A run ends when the hand stops making progress for this long, not just when it turns around. Recorded
        /// strokes stall mid-flight for up to 0.24 s, and a shorter settle split one in two and rejected both
        /// halves. Strokes almost always end by turning around or losing tracking, so this rarely delays a swipe.
        public var settle: TimeInterval = 0.3
        /// Jitter smaller than this doesn't turn a run around, in frame widths. At 30 fps a single stroke otherwise
        /// splits into several.
        public var hysteresis = 0.01
        /// No second swipe in the same direction this soon. Recorded consecutive swipes put their strokes 0.73–1.06 s
        /// apart, so anything longer swallows the repeats the user asked for.
        public var refractory: TimeInterval = 0.35
        /// Whether swiping the same way twice requires the hand to have come back in between — a run that qualifies
        /// as a stroke in the other direction. Swiping twice means physically returning, and every recorded repeat
        /// has that return in it, while a single swipe whose hand drifts back slowly does not: it was firing twice.
        public var repeatNeedsReturn = true
        /// No swipe in the opposite direction this soon: the return stroke, which ends 0.22–0.70 s after the stroke
        /// it undoes and travels just as far.
        public var oppositeSuppression: TimeInterval = 0.9
        /// Tracking gaps up to this long don't break a run. A fast swipe blurs the hand out of tracking for up to
        /// five frames at 30 fps, and at 0.15 s that gap cut recorded strokes in half and lost them both.
        public var dropoutTolerance: TimeInterval = 0.3
        public var invert = false

        public init() {}
    }

    public struct Sample: Sendable {
        /// Palm anchor in image-height units.
        public var anchor: Vec2
        /// Three fingers or more out: what a swiping hand looks like, however the palm is turned.
        public var flatHand: Bool
        /// A volume or brightness drag holds a pinch the whole way and is never a swipe. A swiping hand reads as
        /// pinched for most of a stroke — the thumb tucks against an outstretched index, and `PinchTracker` holds on
        /// for four more frames once it engages — so what disqualifies a run is a pinch on a hand that *isn't* held
        /// flat, and then only if it covers most of the run.
        public var pinching: Bool
        public var imageAspect: Double

        public init(anchor: Vec2, flatHand: Bool = true, pinching: Bool = false, imageAspect: Double = 16.0 / 9) {
            self.anchor = anchor
            self.flatHand = flatHand
            self.pinching = pinching
            self.imageAspect = imageAspect
        }

        /// A pinch worth taking for a control drag: the hand is pinched and not held flat.
        var isControlPinch: Bool { pinching && !flatHand }
    }

    /// One stretch of travel that has held its direction. Positions are in frame widths across, image heights up.
    private struct Run: Sendable {
        var start: Vec2
        var startTime: TimeInterval
        /// The farthest point reached so far in `sign`'s direction: where the run is measured to, and where the next
        /// run begins when this one turns around.
        var extreme: Vec2
        var extremeTime: TimeInterval
        /// Which way the run is going: +1 toward the user's left (image x grows that way), -1 their right, 0 until
        /// the hand has moved past the jitter threshold.
        var sign: Double

        var travel: Double { abs(extreme.x - start.x) }
        var duration: TimeInterval { extremeTime - startTime }
        var direction: SwipeDirection { extreme.x > start.x ? .left : .right }
    }

    /// A finished run that qualified as a swipe and is waiting out its grace.
    private struct Candidate: Sendable {
        var direction: SwipeDirection
        var travel: Double
        /// When the run behind it ended. The grace runs from here.
        var endedAt: TimeInterval

        /// How far an opposing run must travel to take this one's place. A run still short of a real stroke is a
        /// wind-up, and any longer run beats it.
        func bar(_ settings: Settings) -> Double {
            travel < settings.strokeTravel ? travel : settings.dominance * travel
        }
    }

    public var settings: Settings
    private var run: Run?
    private var history: [(time: TimeInterval, flat: Bool, pinching: Bool)] = []
    private var lastSample: TimeInterval = -.infinity
    private var lastFire: (direction: SwipeDirection, time: TimeInterval)?
    /// The finished run waiting to fire, and the finished runs behind it. A run that loses a contest is dropped, but
    /// one that merely arrives while another is waiting has to queue: consecutive swipes put a stroke's end only
    /// 0.06 s after the return before it stopped waiting, and discarding it lost every second swipe.
    private var head: Candidate?
    private var queued: [Candidate] = []
    /// Whether a stroke in the other direction has arrived since the last swipe fired — the hand coming back.
    private var handCameBack = false
    /// The frame's aspect ratio, kept so a run's travel can be compared against its rise in the same units.
    private var sampleAspect = 16.0 / 9

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public var isTracking: Bool { run != nil }

    /// Feeds one frame (nil when no hand was seen). Returns the swipe that completed on this frame, if any.
    public mutating func update(_ sample: Sample?, at time: TimeInterval) -> SwipeDirection? {
        if time - lastSample > settings.dropoutTolerance {
            // A stroke that ends with the hand blurred out of tracking still ended — end it, or its swipe waits for
            // a grace that never starts.
            endRun(at: time)
            history.removeAll()
        }
        if let sample {
            lastSample = time
            history.append((time, sample.flatHand, sample.isControlPinch))
            history.removeAll { time - $0.time > settings.maxDuration + settings.flatLookback }
            sampleAspect = sample.imageAspect
            advance(to: Vec2(sample.anchor.x / sample.imageAspect, sample.anchor.y), at: time)
            // A run still under way can only take a waiting swipe's place, never fire: it fires when it ends.
            if let run, let stroke = qualify(run, at: time) {
                contest(stroke)
            }
        }
        return resolve(at: time)
    }

    public mutating func reset() {
        run = nil
        history.removeAll()
        head = nil
        queued.removeAll()
        handCameBack = false
    }

    /// Closes the open run, if there is one, so a swipe waiting behind it can start its grace.
    private mutating func endRun(at time: TimeInterval) {
        if let open = run { end(open, at: time) }
        run = nil
    }

    /// Extends the open run, or ends it and starts the next one where this one turned around.
    private mutating func advance(to point: Vec2, at time: TimeInterval) {
        guard var open = run else {
            run = Run(start: point, startTime: time, extreme: point, extremeTime: time, sign: 0)
            return
        }
        let step = point.x - open.extreme.x
        if open.sign == 0 {
            guard abs(step) > settings.hysteresis else {
                // Still where it started: keep the start fresh so a long pause doesn't count as part of the stroke.
                open.start = point
                open.startTime = time
                open.extreme = point
                open.extremeTime = time
                run = open
                return
            }
            open.sign = step > 0 ? 1 : -1
            open.extreme = point
            open.extremeTime = time
            run = open
        } else if step * open.sign > 0 {
            open.extreme = point
            open.extremeTime = time
            run = open
        } else if abs(step) > settings.hysteresis || time - open.extremeTime > settings.settle {
            end(open, at: time)
            // The turn-around point is where the next run begins, so no travel is lost between them.
            run = Run(
                start: open.extreme, startTime: open.extremeTime, extreme: point, extremeTime: time,
                sign: abs(step) > settings.hysteresis ? (step > 0 ? 1 : -1) : 0
            )
        }
    }

    /// A finished run joins the queue if it was a swipe.
    private mutating func end(_ finished: Run, at time: TimeInterval) {
        guard let stroke = qualify(finished, at: finished.extremeTime) else { return }
        if let lastFire, stroke.direction != lastFire.direction {
            handCameBack = true
        }
        if head == nil {
            head = stroke
        } else {
            queued.append(stroke)
            // Only the last few matter; anything older has been waiting longer than a swipe stays meaningful.
            if queued.count > 4 { queued.removeFirst() }
        }
    }

    /// The run as a swipe, if it passes every threshold.
    private func qualify(_ run: Run, at time: TimeInterval) -> Candidate? {
        guard run.sign != 0, run.start.y >= settings.minStartHeight else { return nil }
        let delta = run.extreme - run.start
        let travel = run.travel
        guard run.duration > 0, run.duration <= settings.maxDuration, travel >= settings.minTravel,
              travel / run.duration >= settings.minSpeed,
              // The axis ratio is in image heights, the units it was measured in.
              abs(delta.x) * sampleAspect >= settings.axisRatio * abs(delta.y),
              isFlatEnough(from: run.startTime - settings.flatLookback, to: time),
              pinchShare(from: run.startTime, to: run.extremeTime) < settings.maxPinchShare
        else { return nil }
        let direction: SwipeDirection = (run.direction == .left) != settings.invert ? .left : .right
        return Candidate(direction: direction, travel: travel, endedAt: run.extremeTime)
    }

    /// Lets the run under way take the waiting swipe's place, which is how a stroke beats the wind-up in front of
    /// it. An opposing run that doesn't clear the bar is a return stroke and changes nothing here; it gets its own
    /// turn when it ends, and `oppositeSuppression` is what swallows it.
    private mutating func contest(_ stroke: Candidate) {
        guard let waiting = head, waiting.direction != stroke.direction,
              stroke.travel > waiting.bar(settings)
        else { return }
        head = queued.isEmpty ? nil : queued.removeFirst()
    }

    /// Fires the waiting swipe once its grace has run out. A swipe that suppression swallows doesn't hold up the one
    /// behind it, so the loop keeps going until something fires or the queue is still waiting.
    private mutating func resolve(at time: TimeInterval) -> SwipeDirection? {
        while let waiting = head, time - waiting.endedAt >= settings.grace {
            head = queued.isEmpty ? nil : queued.removeFirst()
            if let lastFire {
                let elapsed = time - lastFire.time
                let sameWay = waiting.direction == lastFire.direction
                if elapsed < (sameWay ? settings.refractory : settings.oppositeSuppression) { continue }
                if sameWay, settings.repeatNeedsReturn, !handCameBack { continue }
            }
            lastFire = (waiting.direction, time)
            handCameBack = false
            return waiting.direction
        }
        return nil
    }

    /// Whether the hand held its shape through the motion: frames in a row rather than a share of them, because
    /// mistracked fingers flicker into shape and a swiping hand doesn't.
    private func isFlatEnough(from start: TimeInterval, to end: TimeInterval) -> Bool {
        flatStreak(from: start, to: end) >= settings.minFlatRun
    }

    /// How much of the run was a control pinch: pinched, on a hand that wasn't flat.
    private func pinchShare(from start: TimeInterval, to end: TimeInterval) -> Double {
        let frames = history.filter { $0.time >= start && $0.time <= end }
        guard !frames.isEmpty else { return 0 }
        return Double(frames.filter(\.pinching).count) / Double(frames.count)
    }

    private func flatStreak(from start: TimeInterval, to end: TimeInterval) -> Int {
        var streak = 0, longest = 0
        for frame in history where frame.time >= start && frame.time <= end {
            streak = frame.flat ? streak + 1 : 0
            longest = max(longest, streak)
        }
        return longest
    }
}
