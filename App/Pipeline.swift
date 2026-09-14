import AppKit
import GestureCore
import Observation
import os

/// Camera → Vision → gesture analysis and pointer control, plus the live stats, motion log and fixture recording
/// the debug preview and overlay read.
@MainActor
@Observable
final class Pipeline {
    struct Stats {
        var fps = 0.0
        var processingMilliseconds = 0.0
        var bodies = 0
        var hands = 0
        var looseHands = 0
    }

    struct MotionLogEntry: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
    }

    /// A static pose holding toward its action, for the overlay's progress bar.
    struct PendingAction: Equatable {
        var pose: StaticPose
        var action: GestureAction
        var progress: Double
    }

    enum EnrollmentStatus: Equatable {
        case off
        case collecting
        case saved
    }

    struct PointerStatus: Equatable {
        var pressed = false
        var dragging = false
        var scrolling = false
        var zooming = false
        /// The index is bent toward the camera, so hand movement moves the cursor.
        var engaged = false
    }

    static let fixturesDirectory = URL.applicationSupportDirectory
        .appending(path: "MotionController/Fixtures", directoryHint: .isDirectory)
    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Pipeline")
    /// Where a box the user calibrated is kept between launches.
    /// Bumped for the index-tip pointer (2026-09-14): a box calibrated against the palm midpoint puts the tip's
    /// corners somewhere else entirely, and a silently wrong box is worse than asking for the four corners again.
    private static let boxKey = "pointerBox2"
    /// Whether the dark screen locks, once a face is enrolled.
    private static let lockKey = "screenLock"
    /// Photos of whoever tried to use the Mac while it was locked.
    static let intruderPhotosDirectory = URL.applicationSupportDirectory
        .appending(path: "MotionController/Intruders", directoryHint: .isDirectory)
    /// Everyone enrolled: names and face embeddings, never an image.
    static let facesURL = URL.applicationSupportDirectory
        .appending(path: "MotionController/faces.json", directoryHint: .notDirectory)
    /// The single face enrolled before more than one person could be (2026-09-14); read once and moved into `facesURL`.
    private static let legacyFaceURL = URL.applicationSupportDirectory
        .appending(path: "MotionController/owner-face.json", directoryHint: .notDirectory)

    let camera = CameraService()
    @ObservationIgnored private let handSource = HandSource()
    @ObservationIgnored private var analyzer = GestureAnalyzer()
    @ObservationIgnored private var modeController = ModeController()
    @ObservationIgnored private var pointer = PointerController()
    @ObservationIgnored private let mouse = MouseEventPoster()
    @ObservationIgnored private var actionEvaluator = ActionEvaluator()
    @ObservationIgnored private var onCalibrationEnd: (() -> Void)?
    @ObservationIgnored private let dispatcher = ActionDispatcher()
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    /// Keeps App Nap and automatic termination away while the camera runs; a windowless menu-bar app is otherwise eligible for both.
    /// It keeps display and system sleep away too: the user asked (2026-09-14) that the Mac never power down while this runs.
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// Blacks the screen out once nobody has been in front of the camera for a while.
    @ObservationIgnored private let screen = ScreenKeeper()
    @ObservationIgnored private var screenPresence = ScreenPresence()
    @ObservationIgnored private var sceneLight = SceneLight()
    /// MC_LIGHT_TEST=dark holds the app in the too-dark state from launch, so the hold can be checked without
    /// turning the lights off.
    @ObservationIgnored private let forcedDark = ProcessInfo.processInfo.environment["MC_LIGHT_TEST"] == "dark"
    /// Set while the screen is locked and cleared when it is let go, so a kill or a crash while locked comes back
    /// locked instead of handing the Mac over.
    private static let wasLockedKey = "screenWasLocked"
    /// Holds input back while the dark screen is locked, and asks for Touch ID or the password.
    @ObservationIgnored private let screenLock = ScreenLock()
    @ObservationIgnored private let faceSource = FaceSource()
    @ObservationIgnored private var faceVerification = FaceVerification()
    @ObservationIgnored private var enrollment: FaceEnrollment?
    /// The person being enrolled: a new id, or the id of the one being enrolled again.
    @ObservationIgnored private var enrollingID: UUID?
    @ObservationIgnored private let snapshots = SnapshotTaker()
    @ObservationIgnored private var intruderWatch = IntruderWatch()
    /// Numbers intruder attempts; photos carry theirs, so one that arrives late still lands in the right attempt.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var attemptPhotos: [Data] = []
    @ObservationIgnored private var keptAttempts: Set<Int> = []
    /// Kept since the screen last came back: the alert shows them then.
    @ObservationIgnored private var unseenIntruderPhotos: [URL] = []
    /// While the tutorial is open: what the user just did, to clear its missions with.
    @ObservationIgnored var onTutorialEvent: ((TutorialEvent) -> Void)?
    /// Shows the alert for photos kept while locked, once the screen is back.
    @ObservationIgnored var onIntruderPhotos: ((Int, URL?) -> Void)?
    /// Called on every mode change, so the app can put up the panel that belongs to a mode.
    @ObservationIgnored var onModeChange: ((InteractionMode) -> Void)?
    /// The screen is locked, or isn't any more: the blurred cover goes up and down with it. Tied to the lock rather
    /// than to the dialog, because the dialog's brightness fades out over half a second and a cover that left with
    /// the dialog showed the desktop, fully lit and unblurred, for that whole half second (the user caught it
    /// cancelling the dialog, 2026-09-14).
    @ObservationIgnored var onLockCover: ((Bool) -> Void)?
    /// The frame time analysis last ran at, for things that happen between frames.
    @ObservationIgnored private var lastAnalyzedTime: TimeInterval = 0
    /// `MC_LOCK_TEST_NO_FACE`: the self-test lock ignores the owner's face, so what happens to someone else can be
    /// checked with the owner sitting there.
    @ObservationIgnored private var faceUnlockSuspended = false
    /// The macOS lock screen is up, or another user's session is: this app's lock stays out of its way.
    @ObservationIgnored private var systemScreenLocked = false

    private(set) var latestFrame: PoseFrame?
    private(set) var latestReading: GestureReading?
    private(set) var stats = Stats()
    private(set) var recentEvents: [MotionLogEntry] = []
    private(set) var swipeCounts: [SwipeDirection: Int] = [:]
    /// The way the last sweep went, for the desktop-mode panel's arrows. Cleared a moment later so the arrow lights
    /// up per sweep rather than staying on.
    private(set) var lastSwipe: SwipeDirection?
    @ObservationIgnored private var lastSwipeClear: Task<Void, Never>?
    /// Short-lived text the overlay shows right after a motion gesture or click.
    private(set) var flash: String?
    /// Idle, gesture mode, or pointer mode where the hand drives the cursor.
    private(set) var mode: InteractionMode = .normal
    private(set) var pointerStatus = PointerStatus()
    /// The gesture-mode pose holding toward an action.
    private(set) var pendingAction: PendingAction?
    /// The calibration under way: the corner it wants, the round, how far the hold has come and whether it is
    /// waiting for the panel's button. nil when it isn't running.
    private(set) var calibrationState: PointerCalibration?
    /// Hold progress (0...1) of a fist toward gesture mode, for the overlay.
    private(set) var modeProgress = 0.0
    /// One index tap has landed; another switches to pointer mode.
    private(set) var awaitingSecondTap = false
    /// Gesture mode's palm has held still: sweeping it sideways now switches desktops.
    private(set) var swipeArmed = false
    /// Someone is in front of the camera.
    private(set) var personPresent = false
    /// Too little light to believe the camera: the screen is left exactly as it is and no gesture acts. See
    /// `SceneLight`.
    private(set) var sceneIsDark = false
    /// Mean luma of the last frame, for the debug preview.
    private(set) var sceneLuma: Double?
    private(set) var accessibilityTrusted = AccessibilityPermission.isTrusted
    /// The latest Vision failure, cleared after two seconds without one.
    private(set) var visionError: String?
    private(set) var visionErrorCount = 0
    private(set) var devices: [CameraService.Device] = []
    private(set) var cameraAuthorized: Bool?
    private(set) var isRunning = false
    private(set) var isRecording = false
    private(set) var recordingFrameCount = 0
    private(set) var savedFileCount = 0
    private(set) var lastSavedURL: URL?
    private(set) var lastError: String?
    /// The dark screen is locked: input is held back until the owner's face or Touch ID / the password lets it go.
    private(set) var isLocked = false
    /// Everyone whose face unlocks the screen.
    private(set) var enrolledFaces = EnrolledFaces()
    private(set) var enrollmentStatus = EnrollmentStatus.off
    /// Who the enrollment under way, or the one just saved, is for.
    private(set) var enrollingName: String?
    private(set) var enrollmentProgress = 0.0
    private(set) var enrollmentHint: String?
    /// The latest face check's similarity to the closest enrolled person while locked, and who that was, for the
    /// debug preview.
    private(set) var lastFaceSimilarity: Double?
    private(set) var lastFaceMatch: String?
    /// Photos saved of people trying to use the Mac while it was locked.
    private(set) var intruderPhotoCount = 0

    /// What a zoom gesture will ask macOS for, and whether that is the screen or just the app in front. Read when
    /// the tutorial shows it, since the user can change it in System Settings while this runs.
    var zoomStyle: AccessibilityZoom.Style { AccessibilityZoom.style }

    /// macOS will zoom the screen: the tutorial's zoom mission waits for this.
    var screenZoomAvailable: Bool { AccessibilityZoom.screenZoomAvailable }

    func openZoomSettings() {
        AccessibilityZoom.openSettings()
    }

    /// The face model is loaded, so enrollment and face unlock can work. Observable rather than computed, because
    /// `FaceModelInstaller` can turn it on while the app runs.
    private(set) var faceUnlockAvailable = false
    /// How the model download is going, for the panels that offer it.
    private(set) var faceModelInstall = FaceModelInstaller.Step.idle

    /// The menu's opt-in. Locking also needs an enrolled face, the Accessibility permission and a way to authenticate.
    var lockEnabled = UserDefaults.standard.bool(forKey: Pipeline.lockKey) {
        didSet {
            UserDefaults.standard.set(lockEnabled, forKey: Self.lockKey)
            if !lockEnabled {
                endLock("🔓 화면 잠금 끔")
            }
        }
    }

    var preferredHand: Chirality = .right

    /// (B) by default: the hand request keeps tracking a hand held over the user's own face or chest, which (A)
    /// loses along with the body observation.
    var handSourceMode: HandSourceMode = .handsPlusBody {
        didSet {
            handSource.mode = handSourceMode
            visionError = nil
            visionErrorCount = 0
        }
    }

    /// nil means the built-in camera.
    var selectedDeviceID: String? {
        didSet {
            if isRunning { camera.start(deviceID: selectedDeviceID) }
        }
    }

    @ObservationIgnored private var recentOutputs: [(time: TimeInterval, milliseconds: Double)] = []
    @ObservationIgnored private var lastVisionErrorTime: TimeInterval?
    @ObservationIgnored private var lastStatsLog: TimeInterval = -.infinity
    @ObservationIgnored private var recordedFrames: [PoseFrame] = []
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var recordingLabel = ""
    /// Per-target totals of the pinch in progress, logged once it ends.
    @ObservationIgnored private var activePinchTotals: [ContinuousTarget: Int]?
    @ObservationIgnored private var promptedForAccessibility = false
    @ObservationIgnored private var lastAccessibilityCheck: TimeInterval = -.infinity
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let handSource = handSource
        let faceSource = faceSource
        let snapshots = snapshots
        camera.onFrame = { buffer, time in
            handSource.process(buffer, at: time)
            faceSource.process(buffer, at: time)
            snapshots.process(buffer, at: time)
        }
        camera.onLight = { [weak self] luma, time in
            Task { @MainActor in self?.receiveLight(luma, at: time) }
        }
        snapshots.setHandler { [weak self] tag, data in
            Task { @MainActor in self?.receivePhoto(data, attempt: tag) }
        }
        intruderPhotoCount = (try? FileManager.default.contentsOfDirectory(atPath: Self.intruderPhotosDirectory.path))?
            .filter { $0.hasSuffix(".jpg") }.count ?? 0
        handSource.setHandler { [weak self] output in
            Task { @MainActor in self?.receive(output) }
        }
        faceSource.setHandler { [weak self] output in
            Task { @MainActor in self?.receiveFace(output) }
        }
        sceneIsDark = forcedDark
        faceUnlockAvailable = faceSource.isAvailable
        loadFaces()
        screenLock.onAuthenticated = { [weak self] in
            self?.endLock("🔓 Touch ID·암호로 잠금 해제", byOwner: true)
        }
        screenLock.onAskingChanged = { [weak self] asking in
            self?.screen.showUnlockDialog(asking)
            self?.watchIntruders(asking ? .dialogShown : .dialogClosedStillLocked)
        }
        screenLock.onHeldBack = { [weak self] in
            self?.watchIntruders(.inputHeldBack)
        }
        screenLock.onUnusable = { [weak self] why in
            self?.endLock("⚠️ \(why) · 잠금 해제")
        }
        pointer.settings.screenAspect = MouseEventPoster.screenAspect
        // A box calibrated by pointing at the corners outlives the launch; without one the box fits the hand.
        if let data = UserDefaults.standard.data(forKey: Self.boxKey) {
            pointer.settings.box = try? JSONDecoder().decode(InteractionBox.self, from: data)
        }

        // A button that a crashed or killed instance left down would otherwise stay down.
        MouseEventPoster.postDefensiveRelease()
        // Never leave a button held across quitting or sleeping, nor the screen dimmed after quitting.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.releasePointer()
                self?.screenLock.unlock()
                self?.screen.release()
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releasePointer() }
        })
        // The macOS lock screen or another user's session has to be seen and typed into: never dark or held back.
        let systemLockNotices: [(NotificationCenter, Notification.Name, Bool)] = [
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), true),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), false),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification, true),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        for (center, name, locked) in systemLockNotices {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemLockChanged(locked) }
            })
        }
    }

    /// Locks again at launch when the last run ended while locked — killed, crashed, or quit — so that isn't a way
    /// in. Skipped when nothing can authenticate, which would stand someone in front of a screen they can't clear.
    func relockIfInterrupted() {
        guard UserDefaults.standard.bool(forKey: Self.wasLockedKey), lockEnabled else { return }
        guard ScreenLock.canAuthenticate, AccessibilityPermission.isTrusted, engageLock() else {
            UserDefaults.standard.set(false, forKey: Self.wasLockedKey)
            Self.logger.notice("Last run ended locked, but locking isn't possible now: letting it go")
            return
        }
        screen.dim(wakesOnInput: false)
        logMotion("🔒 잠긴 채로 종료됨 · 다시 잠금")
        Self.logger.notice("Last run ended locked: locked again")
    }

    var frameAspect: Double { latestFrame?.imageAspect ?? 16.0 / 9.0 }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            let granted = await CameraService.requestAccess()
            cameraAuthorized = granted
            guard granted, isRunning else {
                isRunning = false
                return
            }
            devices = CameraService.availableDevices()
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleDisplaySleepDisabled],
                reason: "Tracking hand gestures from the camera"
            )
            camera.start(deviceID: selectedDeviceID)
        }
    }

    func stop() {
        isRunning = false
        releasePointer()
        endLock(nil)
        cancelEnrollment()
        modeController = ModeController()
        mode = modeController.mode
        modeProgress = 0
        awaitingSecondTap = false
        personPresent = false
        lastPersonTime = -.infinity
        screen.release()
        screenPresence = ScreenPresence()
        sceneLight = SceneLight()
        sceneIsDark = forcedDark
        sceneLuma = nil
        actionEvaluator.reset()
        pendingAction = nil
        camera.stop()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        analyzer.reset()
        if isRecording {
            Self.logger.notice("Recording '\(self.recordingLabel, privacy: .public)' discarded: pipeline stopped")
            recordingTask?.cancel()
            recordedFrames = []
            isRecording = false
        }
        latestFrame = nil
        latestReading = nil
        activePinchTotals = nil
        flash = nil
        stats = Stats()
        recentOutputs = []
    }

    var isCalibrating: Bool { calibrationState != nil }

    /// Starts asking for the four screen corners, twice round. `onEnd` runs when the last capture is confirmed or it
    /// is cancelled, so the panel can go away.
    func startCalibration(onEnd: @escaping () -> Void) {
        releasePointer()
        onCalibrationEnd = onEnd
        calibrationState = PointerCalibration()
        logMotion("🎯 커서 영역 보정 시작 · \(PointerCalibration.rounds)회 측정")
    }

    func cancelCalibration() {
        guard calibrationState != nil else { return }
        endCalibration()
        logMotion("🎯 보정 취소")
    }

    /// The panel's button: keep the capture that just landed and move on, or finish. Nothing is measured between the
    /// capture and this, so the hand on its way to the next corner isn't mistaken for pointing at it.
    func confirmCalibrationCorner() {
        guard var current = calibrationState, current.awaitingConfirmation else { return }
        let finished = current.confirm()
        calibrationState = current
        guard let finished else { return }
        applyCalibratedBox(finished)
    }

    /// The panel's other button: that capture was wrong, ask for the same corner again.
    func redoCalibrationCorner() {
        guard var current = calibrationState, current.awaitingConfirmation else { return }
        current.redo()
        calibrationState = current
        logMotion("🎯 다시 측정")
    }

    /// Back to the box fitted to the hand as it is seen.
    func clearCalibration() {
        pointer.settings.box = nil
        UserDefaults.standard.removeObject(forKey: Self.boxKey)
        logMotion("🎯 커서 영역 기본값")
    }

    /// The menu and debug-preview toggle.
    /// The tutorial starts from IDLE, so its first mission is entering gesture mode.
    func parkForTutorial() {
        guard isRunning, !isLocked, let newMode = modeController.set(.idle) else { return }
        switchMode(to: newMode)
    }

    func setPointerMode(_ on: Bool) {
        guard isRunning, let newMode = modeController.set(on ? .pointer : .normal) else { return }
        switchMode(to: newMode)
    }

    /// Starts collecting `name`'s face, as a new person or in place of the one enrolled as `id`; the enrollment window
    /// shows how far along it is.
    func startEnrollment(name: String, replacing id: UUID? = nil) {
        guard !isLocked else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        enrollingName = trimmed.isEmpty ? "이름 없음" : trimmed
        enrollingID = id ?? UUID()
        enrollment = FaceEnrollment()
        enrollmentStatus = .collecting
        enrollmentProgress = 0
        enrollmentHint = nil
        updateFaceChecks()
        logMotion("🙂 \(enrollingName ?? "") 얼굴 등록 시작")
    }

    /// Starts the same person's enrollment over.
    func restartEnrollment() {
        guard let enrollingName else { return }
        startEnrollment(name: enrollingName, replacing: enrollingID)
    }

    /// The window closed: stop collecting. Faces enrolled before stay.
    func cancelEnrollment() {
        guard enrollment != nil || enrollmentStatus != .off else { return }
        enrollment = nil
        enrollingID = nil
        enrollingName = nil
        enrollmentStatus = .off
        enrollmentProgress = 0
        enrollmentHint = nil
        updateFaceChecks()
    }

    func removeFace(id: UUID) {
        guard let face = enrolledFaces.faces.first(where: { $0.id == id }) else { return }
        var updated = enrolledFaces
        updated.remove(id: id)
        do {
            try saveFaces(updated)
        } catch {
            Self.logger.error("Removing a face failed: \(String(describing: error), privacy: .public)")
            return
        }
        enrolledFaces = updated
        updateFaceChecks()
        logMotion("🙂 \(face.name) 얼굴 삭제")
    }

    /// `MC_LOCK_TEST`: locks now, whoever is there, and lets go after `seconds` whatever happens, so the tap and the
    /// Touch ID / password dialog can be checked without the room emptying and without risking a lockout.
    func testLock(for seconds: TimeInterval) {
        Self.logger.notice(
            """
            Lock self-test for \(seconds)s: accessibility \(self.accessibilityTrusted, privacy: .public), \
            authentication \(ScreenLock.canAuthenticate, privacy: .public), faces \(self.enrolledFaces.faces.count, privacy: .public)
            """
        )
        faceUnlockSuspended = ProcessInfo.processInfo.environment["MC_LOCK_TEST_NO_FACE"] != nil
        guard ScreenLock.canAuthenticate, engageLock() else {
            Self.logger.error("Lock self-test couldn't lock")
            return
        }
        screen.dim(wakesOnInput: false)
        logMotion("🔒 잠금 테스트")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.endLock("🔓 잠금 테스트 끝")
        }
    }

    func revealIntruderPhotos() {
        try? FileManager.default.createDirectory(at: Self.intruderPhotosDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.intruderPhotosDirectory)
    }

    func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }

    func resetSwipeCounts() {
        swipeCounts = [:]
    }

    func saveSnapshot(label: String) {
        guard let latestFrame else { return }
        save(latestFrame, kind: "frames", label: label)
    }

    /// Collects every analyzed frame for `seconds` of wall-clock time, then saves them as one sequence.
    func recordSequence(label: String, seconds: TimeInterval = 3) {
        guard !isRecording else { return }
        recordedFrames = []
        recordingFrameCount = 0
        recordingLabel = label
        isRecording = true
        Self.logger.notice("Recording '\(label, privacy: .public)' started for \(seconds)s")
        recordingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finishRecording()
        }
    }

    func revealFixtures() {
        try? FileManager.default.createDirectory(at: Self.fixturesDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.fixturesDirectory)
    }

    /// The hand to analyze until the operator lock exists: the preferred side if visible, else the largest hand.
    static func trackedHand(in frame: PoseFrame, preferring side: Chirality) -> HandFrame? {
        let hands = frame.allHands
            .filter { $0.handSize != nil }
            .sorted { ($0.handSize ?? 0) > ($1.handSize ?? 0) }
        return hands.first { $0.chirality == side } ?? hands.first
    }

    private func receive(_ output: HandSource.Output) {
        guard isRunning else { return }
        let frame = output.frame
        latestFrame = frame
        updateStats(with: output)
        trackVisionError(output.error, at: frame.timestamp)
        analyze(frame)
        record(frame)
    }

    /// Enrollment collects faces; a locked screen compares them with the owner's.
    private func receiveFace(_ output: FaceSource.Output) {
        guard isRunning else { return }
        if var current = enrollment {
            guard let embedding = output.embedding else {
                enrollmentHint = "얼굴이 보이지 않아요"
                return
            }
            switch current.add(embedding, faceHeight: output.faceHeight, at: output.time) {
            case .tooSmall: enrollmentHint = "조금 더 가까이 와 주세요"
            case .inconsistent: enrollmentHint = "화면에 한 사람만 있어야 해요"
            case .added, .tooSoon, .complete: enrollmentHint = "좋아요 · 고개를 살짝 좌우로 돌려 보세요"
            }
            enrollment = current
            enrollmentProgress = current.progress
            if let template = current.template {
                finishEnrollment(template)
            }
            return
        }
        guard isLocked, !enrolledFaces.isEmpty else { return }
        // Any enrolled person unlocks, and none of them is photographed: compare with whoever is closest.
        let match = output.embedding.flatMap { enrolledFaces.bestMatch(for: $0) }
        let similarity = match?.similarity
        lastFaceSimilarity = similarity
        lastFaceMatch = match?.face.name
        watchIntruders(.faceChecked(similarity: similarity))
        if let match {
            Self.logger.notice(
                "Face similarity \(match.similarity, format: .fixed(precision: 3)) to \(match.face.name, privacy: .private) (\(output.milliseconds, format: .fixed(precision: 0)) ms)"
            )
        }
        if !faceUnlockSuspended, faceVerification.update(similarity: similarity, at: output.time) {
            endLock("🔓 \(match?.face.name ?? "") 얼굴 확인 · 잠금 해제", byOwner: true)
        }
    }

    private func finishEnrollment(_ template: FaceTemplate) {
        let wasEmpty = enrolledFaces.isEmpty
        let face = EnrolledFace(id: enrollingID ?? UUID(), name: enrollingName ?? "이름 없음", template: template)
        var updated = enrolledFaces
        updated.save(face)
        do {
            try saveFaces(updated)
        } catch {
            Self.logger.error("Saving the enrolled face failed: \(String(describing: error), privacy: .public)")
            enrollmentHint = "저장하지 못했어요: \(error.localizedDescription)"
            enrollment = FaceEnrollment()
            enrollmentProgress = 0
            return
        }
        let selfSimilarity = template.embeddings.map { template.similarity(to: $0) }
        Self.logger.notice(
            "Face enrolled from \(template.embeddings.count) samples, similarity to the template \(selfSimilarity.min() ?? 0, format: .fixed(precision: 3))...\(selfSimilarity.max() ?? 0, format: .fixed(precision: 3))"
        )
        enrolledFaces = updated
        enrollment = nil
        enrollingID = nil
        enrollmentStatus = .saved
        enrollmentHint = nil
        updateFaceChecks()
        onTutorialEvent?(.faceEnrolled)
        // The first face turns the lock on, as enrolling was for; later ones leave the menu's choice alone.
        if wasEmpty {
            lockEnabled = true
        }
        logMotion("🙂 \(face.name) 얼굴 등록 완료" + (wasEmpty ? " · 화면 잠금 켜짐" : ""))
    }

    private func loadFaces() {
        let outlierBelow = FaceEnrollment.Settings().outlierBelow
        if let data = try? Data(contentsOf: Self.facesURL),
           let saved = try? JSONDecoder().decode(EnrolledFaces.self, from: data) {
            enrolledFaces = saved.droppingOutliers(below: outlierBelow)
        } else if let data = try? Data(contentsOf: Self.legacyFaceURL),
                  let template = try? JSONDecoder().decode(FaceTemplate.self, from: data) {
            // Enrollments from before bad frames were dropped can still hold one.
            let migrated = EnrolledFaces(faces: [EnrolledFace(name: "나", template: template.droppingOutliers(below: outlierBelow))])
            do {
                try saveFaces(migrated)
                Self.logger.notice("Moved the single enrolled face into \(Self.facesURL.lastPathComponent, privacy: .public)")
            } catch {
                Self.logger.error("Moving the enrolled face failed: \(String(describing: error), privacy: .public)")
            }
            enrolledFaces = migrated
        }
    }

    private func saveFaces(_ faces: EnrolledFaces) throws {
        try FileManager.default.createDirectory(at: Self.facesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(faces).write(to: Self.facesURL, options: .atomic)
    }

    /// Downloads and compiles the face model, then loads it — the user asked (2026-09-14) for a button instead of
    /// commands to paste, and pasting them was only half the job anyway: a model in the source tree does nothing
    /// until the app is built again.
    func installFaceModel() {
        switch faceModelInstall {
        case .downloading, .compiling: return
        default: break
        }
        faceModelInstall = .downloading(nil)
        logMotion("⬇️ 얼굴 모델 내려받기")
        Task { [weak self] in
            do {
                try await FaceModelInstaller.install { step in
                    Task { @MainActor in self?.faceModelInstall = step }
                }
                guard let self else { return }
                faceSource.reload()
                faceUnlockAvailable = faceSource.isAvailable
                updateFaceChecks()
                faceModelInstall = faceUnlockAvailable ? .installed : .failed("설치했지만 모델을 불러오지 못했습니다")
                Self.logger.notice("Face model install finished: available \(self.faceUnlockAvailable, privacy: .public)")
                logMotion(faceUnlockAvailable ? "🙂 얼굴 모델 설치 완료 · 얼굴 등록 가능" : "⚠️ 얼굴 모델을 불러오지 못함")
            } catch {
                Self.logger.error("Face model install failed: \(String(describing: error), privacy: .public)")
                self?.faceModelInstall = .failed(error.localizedDescription)
                self?.logMotion("⚠️ 얼굴 모델 설치 실패")
            }
        }
    }

    /// Face checks run only while something needs them, and never in a room too dark to recognize a face in: a
    /// locked screen then waits for Touch ID or the password instead (`ScreenLock`, which darkness never touches),
    /// and no embedding of a near-black frame gets to be compared with anyone's.
    private func updateFaceChecks() {
        faceSource.wanted = isRunning && !sceneIsDark && (enrollment != nil || (isLocked && !enrolledFaces.isEmpty))
    }

    /// Locks input and parks recognition. False, with nothing locked, when locking can't work right now.
    private func engageLock() -> Bool {
        guard !isLocked else { return true }
        guard !systemScreenLocked, screenLock.lock() else { return false }
        isLocked = true
        UserDefaults.standard.set(true, forKey: Self.wasLockedKey)
        onLockCover?(true)
        faceVerification.reset()
        lastFaceSimilarity = nil
        cancelCalibration()
        cancelEnrollment()
        releasePointer()
        if let newMode = modeController.set(.idle, because: .screenLocked) {
            switchMode(to: newMode)
        }
        updateFaceChecks()
        return true
    }

    /// Lets input go and the screen come back, with the absence clock starting over. `text` goes to the motion log;
    /// `byOwner` is true when the owner's face, Touch ID or password did it.
    private func endLock(_ text: String?, byOwner: Bool = false) {
        guard isLocked else { return }
        watchIntruders(.unlocked(byOwner: byOwner))
        faceUnlockSuspended = false
        isLocked = false
        UserDefaults.standard.set(false, forKey: Self.wasLockedKey)
        onLockCover?(false)
        screenLock.unlock()
        _ = screenPresence.unlock(at: lastAnalyzedTime)
        screen.wake()
        updateFaceChecks()
        if let text {
            logMotion(text)
        }
        if !unseenIntruderPhotos.isEmpty {
            onIntruderPhotos?(unseenIntruderPhotos.count, unseenIntruderPhotos.last)
            unseenIntruderPhotos = []
        }
    }

    /// Takes, keeps or throws away photos of someone trying to use the locked Mac. All on one clock, since input and
    /// face checks don't share frame times.
    private func watchIntruders(_ event: IntruderWatch.Event) {
        let wasWatching = intruderWatch.isWatching
        for command in intruderWatch.update(event, at: ProcessInfo.processInfo.systemUptime) {
            switch command {
            case .takePhoto:
                if !wasWatching {
                    attempt += 1
                    attemptPhotos = []
                }
                snapshots.request(tag: attempt)
            case .keepPhotos:
                keptAttempts.insert(attempt)
                Self.logger.notice("Keeping \(self.attemptPhotos.count) photos of attempt \(self.attempt) on the locked screen")
                attemptPhotos.forEach(saveIntruderPhoto)
                attemptPhotos = []
            case .discardPhotos:
                Self.logger.notice("The owner got in: \(self.attemptPhotos.count) photos of attempt \(self.attempt) thrown away")
                attemptPhotos = []
            }
        }
    }

    private func receivePhoto(_ data: Data, attempt tag: Int) {
        if keptAttempts.contains(tag) {
            saveIntruderPhoto(data)
        } else if tag == attempt, intruderWatch.isWatching {
            attemptPhotos.append(data)
        }
    }

    private func saveIntruderPhoto(_ data: Data) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = Self.intruderPhotosDirectory.appending(path: formatter.string(from: .now) + ".jpg")
        do {
            try FileManager.default.createDirectory(at: Self.intruderPhotosDirectory, withIntermediateDirectories: true)
            try data.write(to: url)
            intruderPhotoCount += 1
            unseenIntruderPhotos.append(url)
            Self.logger.notice("Saved a photo of an attempt on the locked screen: \(url.lastPathComponent, privacy: .public)")
        } catch {
            Self.logger.error("Saving an intruder photo failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func systemLockChanged(_ locked: Bool) {
        systemScreenLocked = locked
        Self.logger.notice("macOS screen \(locked ? "locked" : "unlocked", privacy: .public)")
        if locked {
            endLock("macOS 잠금 화면")
        }
    }

    private func trackVisionError(_ error: String?, at time: TimeInterval) {
        if let error {
            visionError = error
            visionErrorCount += 1
            lastVisionErrorTime = time
        } else if let last = lastVisionErrorTime, time - last > 2 {
            visionError = nil
            lastVisionErrorTime = nil
        }
    }

    /// Takes one frame's light. Crossing into the dark holds the screen where it is; coming back out starts the
    /// absence clock over, because `ScreenPresence` was not fed while dark and still remembers whoever was last
    /// seen before the lights went — without this, the first lit frame reads as a long absence and dims and locks
    /// the screen just as someone sits down.
    ///
    /// Going dark also lets go of anything the pointer is holding. Nothing feeds `PointerController` while dark, and
    /// the release that a lost hand would trigger lives in that same path, so a pinch drag under way when the lights
    /// went out would leave the mouse button down until they came back.
    private func receiveLight(_ luma: Double, at time: TimeInterval) {
        sceneLuma = luma
        guard let dark = sceneLight.update(luma: luma, at: time), !forcedDark else { return }
        sceneIsDark = dark
        if dark {
            releasePointer()
        } else {
            _ = screenPresence.unlock(at: time)
        }
        // A face the camera can't make out can't unlock anything; while dark, Touch ID and the password are the way in.
        updateFaceChecks()
        logMotion(dark ? "🌑 조도 부족 · 일시 중지" + (isLocked ? " · Touch ID로 해제" : "") : "💡 조도 회복 · 다시 인식")
        Self.logger.notice("""
            Scene \(dark ? "dark" : "lit", privacy: .public) at luma \
            \(luma, format: .fixed(precision: 3), privacy: .public)
            """)
    }

    /// When a body was last detected. HandSource (B) runs body pose slower than hand pose, so presence holds briefly.
    @ObservationIgnored private var lastPersonTime: TimeInterval = -.infinity

    private func analyze(_ frame: PoseFrame) {
        let time = frame.timestamp
        let reading = analyzer.update(hand: Self.trackedHand(in: frame, preferring: preferredHand), at: time)
        latestReading = reading
        refreshAccessibility(at: time)
        // A tracked hand is proof enough that someone is there: a raised hand often hides the face from the camera.
        if frame.hasPerson || reading != nil {
            lastPersonTime = time
        }
        let present = time - lastPersonTime < 0.5
        if present != personPresent {
            personPresent = present
            Self.logger.notice("Person \(present ? "present" : "absent", privacy: .public)")
        }

        lastAnalyzedTime = time

        // A locked screen stays dark whoever shows up or touches anything; only the owner's face or Touch ID / the
        // password (receiveFace, ScreenLock) end it. Nothing else is recognized meanwhile.
        guard !isLocked else {
            watchIntruders(.tick)
            return
        }

        // Too little light to believe any of it: whatever the screen is doing, it keeps doing. An unlit room reads
        // as an empty one, so acting on it would black out and lock the screen of someone sitting right there,
        // whose face is the way back in and is exactly what the camera can't make out. Nothing is dimmed, locked or
        // woken until the light is back, which also means the Mac's own idle and sleep timers apply again meanwhile.
        // A screen already dark and locked when the light went stays that way, and the lock itself is untouched by
        // any of this: the input tap, the Touch ID / password dialog and the photos all run as usual, because that is
        // the one way back in when the camera can't see a face (user's call, 2026-09-14).
        if sceneIsDark {
            return
        }

        // Whatever the mode, calibration included: dark once nobody has been there a while. Typing or using the mouse
        // counts as being there too, so someone the camera misses isn't left in front of a black screen.
        let screenPresent = present || ScreenKeeper.secondsSinceInput < 2
        let screenChange = screenPresence.update(personPresent: screenPresent, at: time)
        if screenPresence.state == .dimmed {
            if screenChange != nil {
                // Touch ID or the password is the floor; an enrolled face only adds a way in that needs no
                // touching. Without that floor a dark screen was just a screensaver anyone could clear with a
                // keypress, which is what the user objected to (2026-09-14).
                let locked = lockEnabled && accessibilityTrusted && ScreenLock.canAuthenticate && engageLock()
                screen.dim(wakesOnInput: !locked)
                logMotion(locked ? "🔒 사람 없음 · 화면 잠금" : "🌙 사람 없음 · 화면 어둡게")
            }
        } else {
            screen.stayAwake(personPresent: present, at: time)
        }

        if calibrationState != nil {
            updateCalibration(reading, at: time)
            return
        }

        // Fed every frame, hand or not: losing the hand or the person is what parks or falls back.
        let newMode = modeController.update(reading, personPresent: present, holdingButton: pointer.isHoldingButton, at: time)
        if let newMode {
            switchMode(to: newMode)
        }
        let progress = modeController.transitionProgress(at: time)
        if progress != modeProgress {
            modeProgress = progress
        }
        let awaiting = modeController.awaitingSecondTap && mode != .pointer
        if awaiting != awaitingSecondTap {
            awaitingSecondTap = awaiting
        }
        // The frame that switched modes was the trigger — the second tap, the held fist — not also a click or a gesture.
        guard newMode == nil else { return }

        switch mode {
        case .pointer:
            let sample = reading.flatMap { reading in
                reading.pointer.map {
                    PointerController.Sample(
                        point: $0,
                        handScale: reading.handScale,
                        imageAspect: reading.imageAspect,
                        pinching: reading.isPinching,
                        scrollPose: reading.pose == .victory,
                        zoomPose: reading.pose == .threeFingers,
                        tap: reading.tap,
                        holdStill: reading.isTapDipping,
                        fist: reading.isFist,
                        engaged: reading.isIndexBent
                    )
                }
            }
            let commands = pointer.update(sample, at: time, systemCursor: MouseEventPoster.cursorFraction())
            mouse.apply(commands)
            logClicks(commands)
            // Zoom steps come from the analyzer, the same as in gesture mode.
            if let zoomStep = reading?.zoomStep, zoomStep != 0 {
                dispatch([.keyCombo(zoomStep > 0 ? .zoomIn : .zoomOut)])
            }
            let status = PointerStatus(
                pressed: pointer.isPressed, dragging: pointer.isDragging, scrolling: pointer.isScrolling,
                zooming: pointer.isZooming,
                engaged: reading?.isIndexBent == true
            )
            if status != pointerStatus {
                pointerStatus = status
            }
            if let onTutorialEvent {
                if status.engaged, !status.scrolling, !status.dragging { onTutorialEvent(.cursorMoved) }
                if status.scrolling { onTutorialEvent(.scrolled) }
                if status.dragging { onTutorialEvent(.dragged) }
            }

        case .normal:
            // Swipes belong to desktop mode now, so the palm this mode watches for is only on its way there.
            let actions = actionEvaluator.update(reading, at: time)
            let pending = actionEvaluator.pending(at: time).map {
                PendingAction(pose: $0.pose, action: $0.action, progress: $0.progress)
            }
            if pending != pendingAction {
                pendingAction = pending
            }
            if let reading {
                logPinchWhenItEnds(reading)
            }
            dispatch(actions)

        case .desktop:
            if analyzer.isSwipeArmed != swipeArmed {
                swipeArmed = analyzer.isSwipeArmed
            }
            // Left and right, nothing else: no poses, no pinch drags, no zoom, and no play/pause either (the user's
            // call, 2026-09-14). The pump is a fist now, and a fist in this mode is on its way to gesture mode.
            guard let swipe = analyzer.lastSwipe else { break }
            swipeCounts[swipe, default: 0] += 1
            logMotion(swipe == .left ? "👋 ← 왼쪽 스와이프" : "👋 → 오른쪽 스와이프")
            lastSwipe = swipe
            lastSwipeClear?.cancel()
            lastSwipeClear = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                self?.lastSwipe = nil
            }
            dispatch(actionEvaluator.update(nil, swipe: swipe, at: time))

        case .idle:
            break
        }
    }

    /// Feeds one frame to the calibration. A capture that lands only puts the panel's button up; `confirm` is what
    /// moves on, so this never finishes the calibration by itself.
    private func updateCalibration(_ reading: GestureReading?, at time: TimeInterval) {
        guard var current = calibrationState else { return }
        let captured = current.update(reading?.pointer, at: time)
        calibrationState = current
        guard captured, let corner = current.corner else { return }
        logMotion("🎯 \(corner.displayName) \(current.round)회차 측정 · 버튼을 눌러 계속")
    }

    private func applyCalibratedBox(_ box: InteractionBox) {
        onTutorialEvent?(.cursorCalibrated)
        pointer.settings.box = box
        if let data = try? JSONEncoder().encode(box) {
            UserDefaults.standard.set(data, forKey: Self.boxKey)
        }
        Self.logger.notice("Calibrated box \(String(describing: box), privacy: .public)")
        endCalibration()
        logMotion("🎯 커서 영역 보정 완료")
    }

    private func endCalibration() {
        calibrationState = nil
        onCalibrationEnd?()
        onCalibrationEnd = nil
    }

    /// Posts what gesture mode asked for, or says why it couldn't.
    private func dispatch(_ actions: [GestureAction]) {
        guard !actions.isEmpty else { return }
        // The gesture was made whether or not macOS lets the action through, and that's what the tutorial checks.
        if let onTutorialEvent {
            for action in actions {
                switch action {
                case .desktop: onTutorialEvent(.desktopSwitched)
                case .media(.playPause): onTutorialEvent(.playPaused)
                case .media(.volumeUp), .media(.volumeDown), .media(.brightnessUp), .media(.brightnessDown):
                    onTutorialEvent(.volumeOrBrightness)
                case .keyCombo(let combo) where combo == .zoomIn: onTutorialEvent(.zoomed(in: true))
                case .keyCombo(let combo) where combo == .zoomOut: onTutorialEvent(.zoomed(in: false))
                default: break
                }
            }
        }
        guard accessibilityTrusted else {
            logMotion("⚠️ 손쉬운 사용 권한 필요")
            if !promptedForAccessibility {
                promptedForAccessibility = true
                AccessibilityPermission.prompt()
            }
            return
        }
        let unsupported = dispatcher.apply(actions)
        // Which zoom was asked for, so the log says why the screen did or didn't scale.
        if actions.contains(where: { $0 == .keyCombo(.zoomIn) || $0 == .keyCombo(.zoomOut) }) {
            Self.logger.notice("Zoom sent as \(AccessibilityZoom.style.displayName, privacy: .public)")
        }
        // Volume and brightness steps are summed up when the pinch ends instead.
        for action in actions where !action.isContinuousStep {
            logMotion(action.displayName)
            Self.logger.notice("Action \(action.displayName, privacy: .public)")
        }
        if !unsupported.isEmpty {
            logMotion("⚠️ 이 macOS에서는 데스크톱 전환을 지원하지 않음")
        }
    }

    private func switchMode(to newMode: InteractionMode) {
        // Every change lets go: pointer mode's pinch is a drag, gesture mode's is volume and brightness.
        mouse.apply(pointer.forceRelease())
        pointer.reset()
        pointerStatus = PointerStatus()
        activePinchTotals = nil
        actionEvaluator.reset()
        pendingAction = nil
        swipeArmed = false
        mode = newMode
        let reason = modeController.lastChangeReason
        onTutorialEvent?(.mode(newMode, because: reason))
        Self.logger.notice("Mode \(newMode.rawValue, privacy: .public) (\(reason?.rawValue ?? "-", privacy: .public))")
        let because = reason.map { " · \($0.displayName)" } ?? ""
        switch newMode {
        case .pointer: logMotion("☝️ 커서 모드" + because)
        case .normal: logMotion("✊ 제스처 모드" + because)
        case .desktop: logMotion("🖐 데스크탑 전환 모드" + because)
        case .idle: logMotion("💤 IDLE" + because)
        }
        if newMode != .desktop, swipeArmed {
            swipeArmed = false
        }
        onModeChange?(newMode)
        guard newMode == .pointer else { return }
        accessibilityTrusted = AccessibilityPermission.isTrusted
        if !accessibilityTrusted, !promptedForAccessibility {
            promptedForAccessibility = true
            AccessibilityPermission.prompt()
        }
    }

    /// Lets go of any held button now and waits for the event to go out: stopping, quitting, sleeping.
    private func releasePointer() {
        mouse.apply(pointer.forceRelease())
        mouse.flush()
        pointer.reset()
        pointerStatus = PointerStatus()
    }

    /// Picks up a permission granted in System Settings without a relaunch.
    private func refreshAccessibility(at time: TimeInterval) {
        guard !accessibilityTrusted, time - lastAccessibilityCheck >= 1 else { return }
        lastAccessibilityCheck = time
        accessibilityTrusted = AccessibilityPermission.isTrusted
    }

    /// One log line per click, so taps can be checked against what the screen did.
    private func logClicks(_ commands: [PointerCommand]) {
        for (index, command) in commands.enumerated() {
            switch command {
            case .buttonDown(_, let clickCount):
                // A down with its up in the same frame is a click; a down on its own starts a drag or a hold.
                guard index + 1 < commands.count, case .buttonUp = commands[index + 1] else { continue }
                logMotion(clickCount >= 2 ? "👆👆 더블클릭" : "👆 클릭")
                onTutorialEvent?(.clicked)
            case .rightClick:
                logMotion("✌️ 우클릭")
                onTutorialEvent?(.rightClicked)
            default:
                continue
            }
        }
    }

    /// The overlay shows the running total while pinching; the log gets one line per pinch, when it ends.
    private func logPinchWhenItEnds(_ reading: GestureReading) {
        if reading.isPinching {
            if !reading.pinchTotals.isEmpty {
                activePinchTotals = reading.pinchTotals
            }
        } else if let totals = activePinchTotals {
            activePinchTotals = nil
            let parts = [ContinuousTarget.volume, .brightness].compactMap { target -> String? in
                guard let total = totals[target], total != 0 else { return nil }
                return "\(target.displayName) \(total.signedText)"
            }
            if !parts.isEmpty {
                logMotion(parts.joined(separator: " · "))
            }
        }
    }

    private func logMotion(_ text: String) {
        recentEvents.insert(MotionLogEntry(date: .now, text: text), at: 0)
        if recentEvents.count > 12 {
            recentEvents.removeLast(recentEvents.count - 12)
        }
        flash = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    private func record(_ frame: PoseFrame) {
        guard isRecording else { return }
        recordedFrames.append(frame)
        recordingFrameCount = recordedFrames.count
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        let frames = recordedFrames
        recordedFrames = []
        Self.logger.notice("Recording '\(self.recordingLabel, privacy: .public)' captured \(frames.count) frames")
        guard !frames.isEmpty else {
            lastError = "녹화하는 동안 카메라 프레임이 하나도 들어오지 않았습니다"
            return
        }
        save(frames, kind: "sequences", label: recordingLabel)
    }

    private func updateStats(with output: HandSource.Output) {
        // Every five seconds: what the Vision mode costs and whether hands are actually being found, readable off the
        // log after the fact. The debug preview shows the same numbers live.
        if output.frame.timestamp - lastStatsLog >= 5 {
            lastStatsLog = output.frame.timestamp
            Self.logger.notice("Vision \(self.handSourceMode.rawValue, privacy: .public) \(self.stats.fps, format: .fixed(precision: 1), privacy: .public) fps \(output.processingMilliseconds, format: .fixed(precision: 1), privacy: .public) ms · bodies \(output.frame.bodies.count, privacy: .public) hands \(output.frame.allHands.count, privacy: .public) (loose \(output.frame.looseHands.count, privacy: .public))")
        }
        recentOutputs.append((output.frame.timestamp, output.processingMilliseconds))
        if recentOutputs.count > 60 {
            recentOutputs.removeFirst(recentOutputs.count - 60)
        }
        let span = (recentOutputs.last?.time ?? 0) - (recentOutputs.first?.time ?? 0)
        stats = Stats(
            fps: span > 0 ? Double(recentOutputs.count - 1) / span : 0,
            processingMilliseconds: recentOutputs.map(\.milliseconds).reduce(0, +) / Double(recentOutputs.count),
            bodies: output.frame.bodies.count,
            hands: output.frame.allHands.count,
            looseHands: output.frame.looseHands.count
        )
    }

    private func save(_ value: some Encodable, kind: String, label: String) {
        let directory = Self.fixturesDirectory.appending(path: kind, directoryHint: .isDirectory)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let cleanLabel = label.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let name = formatter.string(from: .now) + (cleanLabel.isEmpty ? "" : "-\(cleanLabel)") + ".json"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let url = directory.appending(path: name)
            try encoder.encode(value).write(to: url)
            lastSavedURL = url
            lastError = nil
            savedFileCount += 1
            Self.logger.notice("Saved \(url.path, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            Self.logger.error("Saving \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
