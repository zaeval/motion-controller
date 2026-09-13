import Foundation

public enum StaticPose: String, Codable, CaseIterable, Sendable {
    case openPalm, backOfHand, fist, pointIndex, victory, threeFingers, pinch, thumbsUp, pinky
}

public enum GestureRules {
    /// Classifies one frame. `pinching` comes from `PinchTracker`, which carries the hysteresis, and wins
    /// over every other pose. Finger patterns are checked before the closed-hand read so a pointing hand,
    /// whose other tips sit on the palm, never reads as a fist.
    public static func classify(_ features: HandFeatures, pinching: Bool) -> StaticPose? {
        if pinching { return .pinch }

        if features.isOpenHand {
            return features.palmFacesCamera.map { $0 ? .openPalm : .backOfHand }
        }

        let up = Finger.allCases.map { features.isExtended($0) == true }
        switch (up[0], up[1], up[2], up[3]) {
        case (true, false, false, false): return .pointIndex
        case (true, true, false, false): return .victory
        case (true, true, true, false): return .threeFingers
        case (false, false, false, true) where features.isThumbExtended != true: return .pinky
        default: break
        }

        if features.isClosedHand {
            return features.thumbPointsUp ? .thumbsUp : .fist
        }
        return nil
    }
}
