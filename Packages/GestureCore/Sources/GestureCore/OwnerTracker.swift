import Foundation

/// Which person in front of the camera is the owner, so that only their gestures count (the user's call,
/// 2026-09-21). A face check pins the owner to the body whose head it belongs to; between checks that body is
/// followed by where it just was, and the pin goes stale if no face confirms it for a while.
///
/// Nobody pinned is not the same as nobody allowed: with one person in view there is nobody to confuse them with,
/// so their hands count as they always did. A second person is what makes a hand ambiguous, and then only the
/// owner's count — or none at all, until a face says which is which.
public struct OwnerTracker: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// A face belongs to the body whose head is within this of its middle, in image heights.
        public var faceToHead = 0.3
        /// How far the owner's head can move between frames and still be them.
        public var maxJump = 0.25
        /// Without a face confirming them again, the followed body stays the owner for this long.
        public var graceSeconds: TimeInterval = 10
        /// A hand attached to no body counts as the owner's if their head is the nearest one to it and no further
        /// than this: a hand raised close to the camera loses its shoulders, and with them its body.
        public var looseRadius = 0.6

        public init() {}
    }

    public var settings: Settings
    /// Where the owner's head was last seen, in image heights.
    public private(set) var head: Vec2?
    private var confirmedAt = -TimeInterval.infinity

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// The owner's face was recognized at `faceCenter`: pins them to the nearest head. Returns that body's index.
    @discardableResult
    public mutating func sawOwner(faceCenter: Vec2, heads: [Vec2?], at time: TimeInterval) -> Int? {
        guard let best = nearest(to: faceCenter, among: heads), best.distance <= settings.faceToHead else {
            return nil
        }
        head = best.point
        confirmedAt = time
        return best.index
    }

    /// Follows the owner into this frame. Nil when they can't be made out, or when no face has confirmed them for
    /// longer than the grace period.
    public mutating func follow(heads: [Vec2?], at time: TimeInterval) -> Int? {
        guard let anchor = head, time - confirmedAt <= settings.graceSeconds else {
            head = nil
            return nil
        }
        guard let best = nearest(to: anchor, among: heads), best.distance <= settings.maxJump else { return nil }
        head = best.point
        return best.index
    }

    /// The owner is pinned and the pin is still fresh.
    public func isFollowing(at time: TimeInterval) -> Bool {
        head != nil && time - confirmedAt <= settings.graceSeconds
    }

    /// The hands allowed to drive anything this frame. `owner` is what `follow` just returned.
    public func allowedHands(in frame: PoseFrame, owner: Int?) -> [HandFrame] {
        guard let owner, frame.bodies.indices.contains(owner) else {
            // One person is unambiguous whoever they are; two make every hand a question.
            return frame.bodies.count >= 2 ? [] : frame.allHands
        }
        let heads = frame.bodies.map { $0[.nose] ?? $0[.neck] }
        let anchor = heads[owner] ?? head
        let loose = frame.looseHands.filter { hand in
            guard let anchor, let wrist = hand[.wrist] else { return false }
            let toOwner = wrist.distance(to: anchor)
            // Nearer to the owner than to anybody else, and near enough to be theirs at all.
            let nearerToSomeoneElse = heads.enumerated().contains { index, other in
                index != owner && other.map { wrist.distance(to: $0) < toOwner } ?? false
            }
            return toOwner <= settings.looseRadius && !nearerToSomeoneElse
        }
        return frame.bodies[owner].hands + loose
    }

    public mutating func reset() {
        head = nil
        confirmedAt = -.infinity
    }

    private func nearest(to point: Vec2, among heads: [Vec2?]) -> (index: Int, point: Vec2, distance: Double)? {
        heads.enumerated()
            .compactMap { index, head in head.map { (index: index, point: $0, distance: $0.distance(to: point)) } }
            .min { $0.distance < $1.distance }
    }
}
