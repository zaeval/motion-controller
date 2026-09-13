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

    struct PointerStatus: Equatable {
        var pressed = false
        var dragging = false
        var scrolling = false
        /// The index is bent toward the camera, so hand movement moves the cursor.
        var engaged = false
    }

    static let fixturesDirectory = URL.applicationSupportDirectory
        .appending(path: "MotionController/Fixtures", directoryHint: .isDirectory)
    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Pipeline")
    /// Where a box the user calibrated is kept between launches.
    private static let boxKey = "pointerBox"

    let camera = CameraService()
    @ObservationIgnored private let handSource = HandSource()
    @ObservationIgnored private var analyzer = GestureAnalyzer()
    @ObservationIgnored private var modeController = ModeController()
    @ObservationIgnored private var pointer = PointerController()
    @ObservationIgnored private let mouse = MouseEventPoster()
    @ObservationIgnored private var actionEvaluator = ActionEvaluator()
    @ObservationIgnored private var calibration: PointerCalibration?
    @ObservationIgnored private var onCalibrationEnd: (() -> Void)?
    @ObservationIgnored private let dispatcher = ActionDispatcher()
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    /// Keeps App Nap and automatic termination away while the camera runs; a windowless menu-bar app is otherwise eligible for both.
    @ObservationIgnored private var activity: NSObjectProtocol?

    private(set) var latestFrame: PoseFrame?
    private(set) var latestReading: GestureReading?
    private(set) var stats = Stats()
    private(set) var recentEvents: [MotionLogEntry] = []
    private(set) var swipeCounts: [SwipeDirection: Int] = [:]
    /// Short-lived text the overlay shows right after a motion gesture or click.
    private(set) var flash: String?
    /// Idle, gesture mode, or pointer mode where the hand drives the cursor.
    private(set) var mode: InteractionMode = .normal
    private(set) var pointerStatus = PointerStatus()
    /// The gesture-mode pose holding toward an action.
    private(set) var pendingAction: PendingAction?
    /// The screen corner the calibration is waiting to be pointed at; nil when it isn't running.
    private(set) var calibrationCorner: PointerCalibration.Corner?
    private(set) var calibrationProgress = 0.0
    private(set) var calibrationCount = 0
    /// Hold progress (0...1) of a fist toward gesture mode, for the overlay.
    private(set) var modeProgress = 0.0
    /// One index tap has landed; another switches to pointer mode.
    private(set) var awaitingSecondTap = false
    /// Someone is in front of the camera.
    private(set) var personPresent = false
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

    var preferredHand: Chirality = .right

    var handSourceMode: HandSourceMode = .bodyWithHands {
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
        camera.onFrame = { buffer, time in
            handSource.process(buffer, at: time)
        }
        handSource.setHandler { [weak self] output in
            Task { @MainActor in self?.receive(output) }
        }
        pointer.settings.screenAspect = MouseEventPoster.screenAspect
        // A box calibrated by pointing at the corners outlives the launch; without one the box fits the hand.
        if let data = UserDefaults.standard.data(forKey: Self.boxKey) {
            pointer.settings.box = try? JSONDecoder().decode(InteractionBox.self, from: data)
        }

        // A button that a crashed or killed instance left down would otherwise stay down.
        MouseEventPoster.postDefensiveRelease()
        // Never leave a button held across quitting or sleeping.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releasePointer() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releasePointer() }
        })
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
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Tracking hand gestures from the camera"
            )
            camera.start(deviceID: selectedDeviceID)
        }
    }

    func stop() {
        isRunning = false
        releasePointer()
        modeController = ModeController()
        mode = modeController.mode
        modeProgress = 0
        awaitingSecondTap = false
        personPresent = false
        lastPersonTime = -.infinity
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

    var isCalibrating: Bool { calibration != nil }

    /// Starts asking for the four screen corners. `onEnd` runs when the last one lands or it is cancelled, so the
    /// panel can go away.
    func startCalibration(onEnd: @escaping () -> Void) {
        releasePointer()
        onCalibrationEnd = onEnd
        let fresh = PointerCalibration()
        calibration = fresh
        calibrationCorner = fresh.corner
        calibrationProgress = 0
        calibrationCount = 0
        logMotion("🎯 커서 영역 보정 시작")
    }

    func cancelCalibration() {
        guard calibration != nil else { return }
        endCalibration()
        logMotion("🎯 보정 취소")
    }

    /// Back to the box fitted to the hand as it is seen.
    func clearCalibration() {
        pointer.settings.box = nil
        UserDefaults.standard.removeObject(forKey: Self.boxKey)
        logMotion("🎯 커서 영역 기본값")
    }

    /// The menu and debug-preview toggle.
    func setPointerMode(_ on: Bool) {
        guard isRunning, let newMode = modeController.set(on ? .pointer : .normal) else { return }
        switchMode(to: newMode)
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

        if calibration != nil {
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
            let status = PointerStatus(
                pressed: pointer.isPressed, dragging: pointer.isDragging, scrolling: pointer.isScrolling,
                engaged: reading?.isIndexBent == true
            )
            if status != pointerStatus {
                pointerStatus = status
            }

        case .normal:
            let actions = actionEvaluator.update(reading, swipe: analyzer.lastSwipe, at: time)
            let pending = actionEvaluator.pending(at: time).map {
                PendingAction(pose: $0.pose, action: $0.action, progress: $0.progress)
            }
            if pending != pendingAction {
                pendingAction = pending
            }
            if let swipe = analyzer.lastSwipe {
                swipeCounts[swipe, default: 0] += 1
                logMotion(swipe == .left ? "👋 ← 왼쪽 스와이프" : "👋 → 오른쪽 스와이프")
            }
            if let reading {
                logPinchWhenItEnds(reading)
            }
            dispatch(actions)

        case .idle:
            break
        }
    }

    /// Feeds one frame to the calibration and applies the box that the last corner completes.
    private func updateCalibration(_ reading: GestureReading?, at time: TimeInterval) {
        guard var current = calibration else { return }
        let finished = current.update(reading?.pointer, at: time)
        calibration = current
        calibrationCorner = current.corner
        calibrationProgress = current.progress
        calibrationCount = current.capturedCount
        guard let finished else { return }
        pointer.settings.box = finished
        if let data = try? JSONEncoder().encode(finished) {
            UserDefaults.standard.set(data, forKey: Self.boxKey)
        }
        Self.logger.notice("Calibrated box \(String(describing: finished), privacy: .public)")
        endCalibration()
        logMotion("🎯 커서 영역 보정 완료")
    }

    private func endCalibration() {
        calibration = nil
        calibrationCorner = nil
        calibrationProgress = 0
        calibrationCount = 0
        onCalibrationEnd?()
        onCalibrationEnd = nil
    }

    /// Posts what gesture mode asked for, or says why it couldn't.
    private func dispatch(_ actions: [GestureAction]) {
        guard !actions.isEmpty else { return }
        guard accessibilityTrusted else {
            logMotion("⚠️ 손쉬운 사용 권한 필요")
            if !promptedForAccessibility {
                promptedForAccessibility = true
                AccessibilityPermission.prompt()
            }
            return
        }
        let unsupported = dispatcher.apply(actions)
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
        mode = newMode
        let reason = modeController.lastChangeReason
        Self.logger.notice("Mode \(newMode.rawValue, privacy: .public) (\(reason?.rawValue ?? "-", privacy: .public))")
        let because = reason.map { " · \($0.displayName)" } ?? ""
        switch newMode {
        case .pointer: logMotion("☝️ 커서 모드" + because)
        case .normal: logMotion("✊ 제스처 모드" + because)
        case .idle: logMotion("💤 IDLE" + because)
        }
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
            case .rightClick:
                logMotion("✌️ 우클릭")
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
