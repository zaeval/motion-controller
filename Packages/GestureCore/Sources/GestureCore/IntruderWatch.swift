import Foundation

/// Decides when to photograph someone trying to use the Mac while the dark screen is locked, and whether the photos
/// stay. Pure, so who ends up photographed can be tested without a camera.
///
/// Held-back input starts an attempt and takes a photo right away; faces that aren't the owner's take a few more. The
/// owner getting in soon after (face, Touch ID or password) means it was them, and the photos go. The dialog closing
/// still locked, the lock ending some other way, or nobody getting in for a while keeps them.
public struct IntruderWatch: Sendable {
    public enum Event: Equatable, Sendable {
        /// Keyboard, mouse or trackpad input the lock held back.
        case inputHeldBack
        /// A face check while locked: the largest face's similarity to the owner, nil when there was no face.
        case faceChecked(similarity: Double?)
        case dialogShown
        case dialogClosedStillLocked
        case unlocked(byOwner: Bool)
        /// Time passing while locked, so an attempt nobody answers still ends.
        case tick
    }

    public enum Command: Equatable, Sendable {
        case takePhoto
        /// The attempt was someone else's: save its photos.
        case keepPhotos
        /// The attempt was the owner's: throw its photos away.
        case discardPhotos
    }

    public struct Settings: Codable, Equatable, Sendable {
        /// An attempt nobody unlocks within this long keeps its photos. Covers the owner coming back in the dark and
        /// reaching for Touch ID.
        public var graceSeconds: TimeInterval = 15
        public var maxPhotos = 3
        public var photoInterval: TimeInterval = 1
        /// A face at or above this is the owner's and isn't photographed; the same bar `FaceVerification` unlocks at.
        public var ownerThreshold = FaceVerification.Settings().threshold
        /// After photos are kept, input this soon doesn't start another attempt, so someone hammering keys doesn't
        /// fill the disk.
        public var cooldownSeconds: TimeInterval = 30

        public init() {}
    }

    public var settings: Settings
    private var attemptStart: TimeInterval?
    private var photos = 0
    private var lastPhoto = -TimeInterval.infinity
    private var lastKept = -TimeInterval.infinity
    private var dialogUp = false

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// An attempt is open, its photos not yet kept or thrown away.
    public var isWatching: Bool { attemptStart != nil }

    public mutating func update(_ event: Event, at time: TimeInterval) -> [Command] {
        var commands: [Command] = []
        switch event {
        case .inputHeldBack:
            if attemptStart == nil, time - lastKept >= settings.cooldownSeconds {
                attemptStart = time
                photos = 0
                commands += photograph(at: time)
            }
        case .faceChecked(let similarity):
            if attemptStart != nil, let similarity, similarity < settings.ownerThreshold {
                commands += photograph(at: time)
            }
        case .dialogShown:
            dialogUp = true
        case .dialogClosedStillLocked:
            dialogUp = false
            if attemptStart != nil {
                commands.append(finish(keeping: true, at: time))
            }
        case .unlocked(let byOwner):
            dialogUp = false
            if attemptStart != nil {
                commands.append(finish(keeping: !byOwner, at: time))
            }
        case .tick:
            break
        }
        // An open dialog decides for itself when it closes.
        if let start = attemptStart, !dialogUp, time - start >= settings.graceSeconds {
            commands.append(finish(keeping: true, at: time))
        }
        return commands
    }

    private mutating func photograph(at time: TimeInterval) -> [Command] {
        guard photos < settings.maxPhotos, time - lastPhoto >= settings.photoInterval else { return [] }
        photos += 1
        lastPhoto = time
        return [.takePhoto]
    }

    private mutating func finish(keeping: Bool, at time: TimeInterval) -> Command {
        attemptStart = nil
        if keeping {
            lastKept = time
        }
        return keeping ? .keepPhotos : .discardPhotos
    }
}
