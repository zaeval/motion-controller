import Foundation

/// Takes out of a frame the hands that are part of the room rather than of a person: ones that have not moved for
/// seconds on end.
///
/// Found 2026-11-06, when the user walked away and the screen never locked. The hand request had returned two hands
/// on every sample for 70 minutes, the user there or not, and a tracked hand counts as someone being there (a raised
/// hand hides the face, 2026-09-13). One was a full 21-joint hand at the top centre of the frame, above the user's
/// head, with joint confidence 0.53–0.68 and size 0.22–0.24 of the frame. Those are a real hand's numbers, so neither
/// a confidence floor nor a size floor tells it apart. What does is that it never moves: its wrist stayed within 0.02
/// for the whole of every recording of it. Measured with this filter, the stillest of the user's own recorded hands
/// (`cursor-idle`, clicks) stay put for 1.5–2 s, so the mark sits at 5 s. That puts the absence lock about 15 s after
/// someone leaves instead of 10 (`ScreenPresence.dimAfter` counts from when the hand stops counting).
///
/// Positions are Vision-normalized, the units the measurements above were taken in.
public struct SceneryHands: Sendable {
    public struct Settings: Sendable, Equatable {
        /// How far a hand may wander and still count as not having moved.
        public var radius: Double = 0.02
        /// How long a hand has to stay put before it counts as part of the room.
        public var stillSeconds: TimeInterval = 5
        /// How long a still hand may go unseen and still be the same one. Vision returns at most two hands, and a
        /// third candidate takes the slot now and then, so a hand in the room drops out for a frame or a few.
        public var gap: TimeInterval = 1
        /// How far a hand may be from where a track was last seen to be the same hand on the next frame.
        public var followRadius: Double = 0.15

        public init() {}
    }

    private struct Track: Sendable {
        /// Where the hand was when it last moved: it is still for as long as it stays within `radius` of here.
        var anchor: Vec2
        var since: TimeInterval
        /// Where it was last seen, to follow it from frame to frame.
        var last: Vec2
        var lastSeen: TimeInterval
    }

    public var settings: Settings
    private var tracks: [Track] = []
    /// How many hands the last frame lost to this.
    public private(set) var removedCount = 0

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// The frame without the hands that have been in one place for `stillSeconds`. Bodies and their joints are left
    /// alone.
    public mutating func update(_ frame: PoseFrame) -> PoseFrame {
        let time = frame.timestamp
        tracks.removeAll { time - $0.lastSeen > settings.gap }
        let points = frame.allHands.map(Self.point)

        // Each hand follows on from the nearest track it could be, nearest pairs first, so two hands side by side
        // can't swap. A track is followed by where it was last seen, not by its anchor, so a hand moving to and fro
        // over one spot keeps re-anchoring instead of picking up an old track that has been sitting there.
        var claims: [(hand: Int, track: Int, distance: Double)] = []
        for (hand, point) in points.enumerated() {
            guard let point else { continue }
            for (track, candidate) in tracks.enumerated() {
                let distance = point.distance(to: candidate.last)
                if distance <= settings.followRadius {
                    claims.append((hand, track, distance))
                }
            }
        }
        claims.sort { $0.distance < $1.distance }
        var trackOf: [Int: Int] = [:]
        var claimed = Set<Int>()
        for claim in claims where trackOf[claim.hand] == nil && !claimed.contains(claim.track) {
            trackOf[claim.hand] = claim.track
            claimed.insert(claim.track)
        }

        var next = tracks.indices.filter { !claimed.contains($0) }.map { tracks[$0] }
        var scenery = [Bool](repeating: false, count: points.count)
        for (hand, point) in points.enumerated() {
            guard let point else { continue }
            var track = trackOf[hand].map { tracks[$0] } ?? Track(anchor: point, since: time, last: point, lastSeen: time)
            if point.distance(to: track.anchor) > settings.radius {
                track.anchor = point
                track.since = time
            }
            track.last = point
            track.lastSeen = time
            scenery[hand] = time - track.since >= settings.stillSeconds
            next.append(track)
        }
        tracks = next

        removedCount = scenery.filter { $0 }.count
        guard removedCount > 0 else { return frame }
        // `allHands` lists the bodies' hands first, left then right, then the loose ones: walk them in that order.
        var index = 0
        func keep(_ hand: HandFrame?) -> HandFrame? {
            guard let hand else { return nil }
            defer { index += 1 }
            return scenery[index] ? nil : hand
        }
        var out = frame
        for body in out.bodies.indices {
            out.bodies[body].leftHand = keep(out.bodies[body].leftHand)
            out.bodies[body].rightHand = keep(out.bodies[body].rightHand)
        }
        out.looseHands = out.looseHands.compactMap { keep($0) }
        return out
    }

    public mutating func reset() {
        tracks = []
        removedCount = 0
    }

    /// The wrist, or where the confident joints are when the wrist isn't; nil for a hand with no confident joint,
    /// which can't drive anything anyway.
    static func point(of hand: HandFrame) -> Vec2? {
        if let wrist = hand.normalizedPosition(of: .wrist) { return wrist }
        let joints = HandJoint.allCases.compactMap { hand.normalizedPosition(of: $0) }
        guard !joints.isEmpty else { return nil }
        let sum = joints.reduce(Vec2(0, 0)) { Vec2($0.x + $1.x, $0.y + $1.y) }
        return Vec2(sum.x / Double(joints.count), sum.y / Double(joints.count))
    }
}
