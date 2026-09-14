import AppKit
import Carbon.HIToolbox
import CoreGraphics
import GestureCore
import LocalAuthentication
import os

/// Holds keyboard, mouse and trackpad input back while the dark screen is locked, and lets the owner back in with
/// Touch ID or the login password. Recognizing the owner's face, which unlocks without touching anything, is
/// `Pipeline`'s.
///
/// Failing open is deliberate. The tap runs on the main run loop, so a hung main thread gets it timed out by macOS
/// and input flows again; quitting or crashing takes the tap with it; and anything that stops authentication working
/// (no password, a dialog that never shows) unlocks rather than stranding the owner at their own Mac. This is a
/// screen that stays dark for strangers, not a replacement for the macOS lock screen.
@MainActor
final class ScreenLock {
    enum State: Equatable {
        case unlocked
        case locked
        /// The Touch ID / password dialog is up.
        case asking
    }

    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Screen")
    /// A dialog nobody answers goes away after this long, and the screen goes back to black.
    private static let askTimeout: TimeInterval = 30
    /// After a dialog closes still locked, the next key or click brings it back no sooner than this.
    private static let askCooldown: TimeInterval = 1
    /// Dialogs the system closes this quickly this many times in a row can't be answered: unlock instead.
    private static let unanswerableSeconds: TimeInterval = 1
    private static let unanswerableLimit = 3
    /// Processes that draw the authentication dialog; the pointer works inside their windows.
    private static let dialogOwners = ["coreautha", "SecurityAgent", "LocalAuthentication"]

    /// Whether Touch ID or the login password can be asked for at all.
    static var canAuthenticate: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    private(set) var state = State.unlocked
    /// Touch ID or the password proved it's the owner.
    var onAuthenticated: (() -> Void)?
    /// The dialog came up (true) or went away still locked (false), so the screen can show it.
    var onAskingChanged: ((Bool) -> Void)?
    /// Authentication can't work: the lock has to go rather than strand whoever is at the Mac.
    var onUnusable: ((String) -> Void)?
    /// Input was held back: someone is trying to use the Mac. A few times a second at most.
    var onHeldBack: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var context: LAContext?
    private var dialogFrames: [CGRect] = []
    /// The authentication dialog is the frontmost app, so keys typed now go to it.
    private var dialogIsFrontmost = false
    private var lastHeldBackNotice = -TimeInterval.infinity
    private var dialogWatch: Task<Void, Never>?
    private var askTimeoutTask: Task<Void, Never>?
    private var askStartedAt = -TimeInterval.infinity
    private var askEndedAt = -TimeInterval.infinity
    private var unansweredInARow = 0
    private var swallowed = 0

    /// Starts holding input back. False, with nothing held, when the tap can't be made.
    func lock() -> Bool {
        guard state == .unlocked else { return true }
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask.max,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let lock = Unmanaged<ScreenLock>.fromOpaque(userInfo).takeUnretainedValue()
                let location = event.location
                // Added to the main run loop below, so this is always the main thread.
                let passes = MainActor.assumeIsolated { lock.handle(type, at: location) }
                return passes ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            Self.logger.error("Input lock unavailable: the event tap couldn't be created")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        state = .locked
        swallowed = 0
        unansweredInARow = 0
        Self.logger.notice("Input locked")
        return true
    }

    /// Lets input through again and closes any dialog: the owner was recognized, or the lock was switched off.
    func unlock() {
        guard state != .unlocked else { return }
        state = .unlocked
        endAsking()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        Self.logger.notice("Input unlocked after holding back \(self.swallowed) events")
    }

    /// Decides one event inside the tap callback, which must return right away.
    private func handle(_ type: CGEventType, at location: CGPoint) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, state != .unlocked {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            Self.logger.notice("Input tap re-enabled after \(type == .tapDisabledByTimeout ? "a timeout" : "user input", privacy: .public)")
            return true
        }
        guard state != .unlocked else { return true }
        let event = Self.kind(of: type)
        let asking = state == .asking
        let keyboard = event == .keyDown || event == .keyUp || event == .modifiers
        let verdict = InputLockPolicy.verdict(
            for: event,
            at: location,
            asking: asking,
            keysReachDialog: asking && keyboard && (dialogIsFrontmost || IsSecureEventInputEnabled()),
            dialogFrames: dialogFrames
        )
        if !verdict.passes {
            swallowed += 1
            let now = ProcessInfo.processInfo.systemUptime
            if event != .other, now - lastHeldBackNotice >= 0.25 {
                lastHeldBackNotice = now
                Task { [weak self] in self?.onHeldBack?() }
            }
        }
        if verdict.asksToUnlock, ProcessInfo.processInfo.systemUptime - askEndedAt >= Self.askCooldown {
            state = .asking
            Task { [weak self] in self?.ask() }
        }
        return verdict.passes
    }

    private func ask() {
        guard state == .asking, context == nil else { return }
        let context = LAContext()
        context.localizedCancelTitle = "취소"
        self.context = context
        askStartedAt = ProcessInfo.processInfo.systemUptime
        Self.logger.notice("Asking for Touch ID or the password after holding back \(self.swallowed) events")
        onAskingChanged?(true)
        watchDialog()
        askTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.askTimeout))
            guard !Task.isCancelled else { return }
            Self.logger.notice("Nobody answered the dialog: closing it")
            self?.context?.invalidate()
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "까만 화면 잠금 해제") { @Sendable [weak self] success, error in
            let code = (error as? LAError)?.code
            Task { @MainActor in self?.finishAsking(success: success, code: code) }
        }
    }

    private func finishAsking(success: Bool, code: LAError.Code?) {
        let lasted = ProcessInfo.processInfo.systemUptime - askStartedAt
        endAsking()
        guard state == .asking else { return }
        if success {
            Self.logger.notice("Authenticated with Touch ID or the password")
            onAuthenticated?()
            return
        }
        let codeText = code.map { String($0.rawValue) } ?? "none"
        switch code {
        case .userCancel?, .authenticationFailed?, .appCancel?:
            unansweredInARow = 0
        case .systemCancel?:
            unansweredInARow = lasted < Self.unanswerableSeconds ? unansweredInARow + 1 : 0
        default:
            Self.logger.error("Authentication can't work (code \(codeText, privacy: .public)): unlocking")
            onUnusable?("인증을 쓸 수 없음")
            return
        }
        guard unansweredInARow < Self.unanswerableLimit else {
            Self.logger.error("The dialog closed by itself \(self.unansweredInARow) times in a row: unlocking")
            onUnusable?("인증 창이 뜨지 않음")
            return
        }
        Self.logger.notice("Dialog closed still locked (code \(codeText, privacy: .public), \(lasted, format: .fixed(precision: 1))s)")
        state = .locked
        onAskingChanged?(false)
    }

    private func endAsking() {
        askEndedAt = ProcessInfo.processInfo.systemUptime
        context?.invalidate()
        context = nil
        askTimeoutTask?.cancel()
        askTimeoutTask = nil
        dialogWatch?.cancel()
        dialogWatch = nil
        dialogFrames = []
        dialogIsFrontmost = false
    }

    /// The dialog's windows show up a moment after asking and can move, so they're looked up again while it's up.
    private func watchDialog() {
        dialogWatch?.cancel()
        dialogWatch = Task { [weak self] in
            var logged = false
            while !Task.isCancelled {
                guard let self else { return }
                let windows = Self.onScreenWindows()
                self.dialogFrames = windows.filter { window in
                    Self.dialogOwners.contains { window.owner.localizedCaseInsensitiveContains($0) }
                }.map(\.frame)
                let front = NSWorkspace.shared.frontmostApplication
                let frontName = [front?.bundleIdentifier, front?.localizedName, front?.bundleURL?.lastPathComponent]
                    .compactMap { $0 }
                self.dialogIsFrontmost = frontName.contains { name in
                    Self.dialogOwners.contains { name.localizedCaseInsensitiveContains($0) }
                }
                if !logged, ProcessInfo.processInfo.systemUptime - self.askStartedAt > 1 {
                    logged = true
                    let raised = windows.filter { $0.layer != 0 }.map { "\($0.owner)@\($0.layer)" }
                    Self.logger.notice(
                        """
                        Dialog windows \(self.dialogFrames.description, privacy: .public), frontmost \
                        \(frontName.description, privacy: .public), secure input \(IsSecureEventInputEnabled(), privacy: .public), \
                        raised windows \(raised.description, privacy: .public)
                        """
                    )
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func onScreenWindows() -> [(owner: String, layer: Int, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }
        // The kCGWindow… keys spelled out, because the imported globals aren't concurrency-safe.
        return list.compactMap { info in
            guard let owner = info["kCGWindowOwnerName"] as? String,
                  let bounds = info["kCGWindowBounds"] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return (owner, info["kCGWindowLayer"] as? Int ?? 0, frame)
        }
    }

    private static func kind(of type: CGEventType) -> InputLockPolicy.Event {
        switch type {
        case .keyDown: .keyDown
        case .keyUp: .keyUp
        case .flagsChanged: .modifiers
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: .pointerMove
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: .buttonDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: .buttonUp
        case .scrollWheel: .scroll
        default: .other
        }
    }
}
