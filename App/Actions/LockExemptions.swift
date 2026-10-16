import AppKit
import Observation
import Security
import UniformTypeIdentifiers
import os

/// The apps whose clicks and keys get through the dark-screen lock, ticked in the menu's checklist (the user's call,
/// 2026-10-15): KakaoWeb on the bot Mac clicks KakaoTalk for operators who aren't at the Mac, and the lock was
/// swallowing those clicks.
///
/// An app is known by its bundle ID and by the designated requirement its bundle carried when it was ticked, so
/// another app claiming the same bundle ID doesn't get through. An unsigned app has no requirement and is known by
/// its bundle ID alone. Input from the hardware — whoever sits at the Mac — never comes from an exempt app.
///
/// Processes are told apart by the app bundle their executable sits in, not by NSRunningApplication: that only knows
/// what LaunchServices launched, and on the bot Mac KakaoWeb is a launchd job it returns nil for (found 2026-10-16),
/// so KakaoWeb neither showed up in the list nor got through when ticked.
@MainActor
@Observable
final class LockExemptions {
    struct App: Codable, Equatable {
        var bundleID: String
        var name: String
        /// The designated requirement the bundle carried when it was ticked; nil for an unsigned app.
        var requirement: String?
    }

    /// One row of the menu's checklist.
    struct Choice: Identifiable, Equatable {
        var bundleID: String
        var name: String
        var url: URL?
        var isExempt: Bool
        /// Its input was held back during a lock since this app started.
        var wasHeldBack: Bool
        var id: String { bundleID }

        var label: String {
            switch (isExempt, wasHeldBack) {
            // Ticked but refused: it was signed by someone else since. Ticking it again takes the new signature.
            case (true, true): "\(name) — 서명이 달라 막힘, 껐다 다시 체크"
            case (false, true): "\(name) — 잠금 중 막힘"
            default: name
            }
        }
    }

    /// The app a process belongs to: the outermost bundle its executable sits in, so a helper counts as its app.
    struct Sender: Equatable {
        var bundleID: String
        var name: String
        var url: URL?
    }

    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Screen")
    private static let key = "lockExemptApps"
    /// Ticked from the start where they're installed: what the list was made for.
    private static let defaultBundleIDs = ["com.internal.kakaoweb"]

    private(set) var apps: [App] = []
    /// Exempt apps, then apps held back during a lock, then everything else running that isn't part of macOS.
    private(set) var choices: [Choice] = []
    private var heldBack: [String: Sender] = [:]
    /// Per process, for the length of a lock: the first event pays for the signature check (~50ms), the rest don't.
    @ObservationIgnored private var verdicts: [pid_t: Bool] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([App].self, from: data) {
            apps = saved
        } else {
            // Not saved until one is found, so installing KakaoWeb after this app still ticks it.
            let running = Self.runningApps()
            apps = Self.defaultBundleIDs.compactMap { bundleID in
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                    ?? running.first { $0.sender.bundleID == bundleID }?.sender.url
                return url.map(Self.app(at:))
            }
            if !apps.isEmpty { save() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .processIdentifier
                MainActor.assumeIsolated {
                    // A pid can be handed to a new process: never let it inherit a verdict.
                    if let pid { self?.verdicts[pid] = nil }
                    self?.refresh()
                }
            })
        }
        refresh()
        // Apps launchd starts post no workspace notification, so the list also looks again every few seconds.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                self?.refresh()
            }
        }
    }

    /// Whether input sent by process `pid` gets through the lock. Called from the event tap, so it must stay quick.
    func allows(_ pid: pid_t) -> Bool {
        if let known = verdicts[pid] { return known }
        let verdict = check(pid)
        verdicts[pid] = verdict
        return verdict
    }

    /// Starts a lock with no verdicts, and checks the exempt apps already running before their first click arrives.
    func prepareForLock() {
        verdicts = [:]
        for (pid, sender) in Self.runningApps() where apps.contains(where: { $0.bundleID == sender.bundleID }) {
            _ = allows(pid)
        }
    }

    /// The menu's checkbox.
    func setExempt(_ choice: Choice, _ exempt: Bool) {
        if exempt {
            guard let url = choice.url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: choice.bundleID)
            else { return }
            add(url)
        } else {
            apps.removeAll { $0.bundleID == choice.bundleID }
            Self.logger.notice("Lock exempt app removed: \(choice.bundleID, privacy: .public)")
            changed()
        }
    }

    /// The menu's "다른 앱 추가…", for an app that isn't running.
    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.message = "잠긴 동안에도 클릭·키 입력을 통과시킬 앱을 고르세요"
        panel.prompt = "예외로 추가"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }

    private func add(_ url: URL) {
        let app = Self.app(at: url)
        apps.removeAll { $0.bundleID == app.bundleID }
        apps.append(app)
        heldBack[app.bundleID] = nil
        Self.logger.notice(
            "Lock exempt app added: \(app.bundleID, privacy: .public), \(app.requirement ?? "unsigned", privacy: .public)"
        )
        changed()
    }

    private func changed() {
        save()
        verdicts = [:]
        refresh()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(apps) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func refresh() {
        var rows: [String: Choice] = [:]
        for (_, sender) in Self.runningApps() {
            guard let url = sender.url, !sender.bundleID.hasPrefix("com.apple."),
                  sender.bundleID != Bundle.main.bundleIdentifier
            else { continue }
            rows[sender.bundleID] = Choice(
                bundleID: sender.bundleID, name: sender.name, url: url, isExempt: false, wasHeldBack: false
            )
        }
        for (bundleID, sender) in heldBack {
            rows[bundleID] = Choice(
                bundleID: bundleID, name: sender.name, url: sender.url, isExempt: false, wasHeldBack: true
            )
        }
        for app in apps {
            rows[app.bundleID, default: Choice(
                bundleID: app.bundleID, name: app.name, url: nil, isExempt: true, wasHeldBack: false
            )].isExempt = true
        }
        let sorted = rows.values.sorted { left, right in
            if left.isExempt != right.isExempt { return left.isExempt }
            if left.wasHeldBack != right.wasHeldBack { return left.wasHeldBack }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        if sorted != choices { choices = sorted }
    }

    private func check(_ pid: pid_t) -> Bool {
        // The hardware, this app's own events, and processes that aren't apps.
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier, let sender = Self.sender(of: pid) else {
            return false
        }
        let path = sender.url?.path ?? sender.bundleID
        guard let app = apps.first(where: { $0.bundleID == sender.bundleID }) else {
            noteHeldBack(sender)
            return false
        }
        guard let requirement = app.requirement else { return true }
        let bundleURL = sender.url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: sender.bundleID)
        let status = Self.validate(pid: pid, bundleURL: bundleURL, requirement: requirement)
        guard status == errSecSuccess else {
            Self.logger.notice("\(path, privacy: .public)(pid \(pid))는 예외 앱 서명이 아니라 잠금에서 막음 (\(status))")
            noteHeldBack(sender)
            return false
        }
        Self.logger.notice("\(path, privacy: .public)(pid \(pid))는 예외 앱이라 잠금을 통과")
        return true
    }

    /// Only apps: the list has nothing to tick for a bare tool or a system process.
    private func noteHeldBack(_ sender: Sender) {
        guard sender.url != nil, heldBack[sender.bundleID] == nil else { return }
        heldBack[sender.bundleID] = sender
        refresh()
    }

    /// Every running process whose executable sits in an app bundle. A few milliseconds for ~800 processes.
    private static func runningApps() -> [(pid: pid_t, sender: Sender)] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(count, 0)).compactMap { pid in
            guard pid > 0, let path = executablePath(of: pid), let url = appBundle(containing: path),
                  let bundleID = Bundle(url: url)?.bundleIdentifier
            else { return nil }
            return (pid, Sender(bundleID: bundleID, name: name(of: url), url: url))
        }
    }

    /// From the executable's path, or from its code signature when the path can't be had.
    private static func sender(of pid: pid_t) -> Sender? {
        if let path = executablePath(of: pid), let url = appBundle(containing: path),
           let bundleID = Bundle(url: url)?.bundleIdentifier {
            return Sender(bundleID: bundleID, name: name(of: url), url: url)
        }
        var code: SecCode?
        var info: CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code)
            == errSecSuccess, let code,
            SecCodeCopySigningInformation(
                unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSDynamicInformation), &info
            ) == errSecSuccess,
            let dict = info as? [String: Any], let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        else { return nil }
        let url = (dict[kSecCodeInfoMainExecutable as String] as? URL).flatMap { appBundle(containing: $0.path) }
        return Sender(bundleID: identifier, name: url.map(name(of:)) ?? identifier, url: url)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    /// The outermost `.app` on the path, when the path is an app's executable or something inside one.
    private static func appBundle(containing path: String) -> URL? {
        guard let range = path.range(of: ".app/") else { return nil }
        return URL(filePath: String(path[..<range.lowerBound]) + ".app", directoryHint: .isDirectory)
    }

    /// `errSecSuccess` when the running process satisfies `requirement`.
    ///
    /// An app replaced on disk while it runs fails the plain check with errSecCSStaticCodeChanged (-67034): the check
    /// compares the running code with files that aren't its own any more. kakao-web deploys do exactly that without
    /// restarting KakaoWeb, so from 2026-10-14 every click it sent while locked was swallowed. Then it's enough that
    /// the kernel still holds the running code valid and the bundle it runs from is signed by the same identity.
    private static func validate(pid: pid_t, bundleURL: URL?, requirement text: String) -> OSStatus {
        var requirement: SecRequirement?
        var status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            logger.error("Exempt app requirement doesn't parse (\(status)): \(text, privacy: .public)")
            return status
        }
        var code: SecCode?
        status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else { return status }
        status = SecCodeCheckValidity(code, [], requirement)
        guard status == OSStatus(errSecCSStaticCodeChanged), let bundleURL else { return status }
        var info: CFDictionary?
        // A SecCode is a SecStaticCode as far as this call goes; Swift just doesn't know it.
        guard SecCodeCopySigningInformation(
            unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSDynamicInformation), &info
        ) == errSecSuccess,
            let flags = (info as? [String: Any])?[kSecCodeInfoStatus as String] as? NSNumber,
            SecCodeStatus(rawValue: flags.uint32Value).contains(.valid)
        else { return status }
        var onDisk: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &onDisk) == errSecSuccess, let onDisk else {
            return status
        }
        return SecStaticCodeCheckValidity(onDisk, [], requirement)
    }

    private static func app(at url: URL) -> App {
        let bundle = Bundle(url: url)
        return App(
            bundleID: bundle?.bundleIdentifier ?? url.path,
            name: name(of: url),
            requirement: designatedRequirement(of: url)
        )
    }

    private static func name(of url: URL) -> String {
        let bundle = Bundle(url: url)
        let info = bundle?.localizedInfoDictionary ?? [:]
        let base = bundle?.infoDictionary ?? [:]
        return (info["CFBundleDisplayName"] ?? info["CFBundleName"] ?? base["CFBundleDisplayName"] ?? base["CFBundleName"])
            as? String ?? url.deletingPathExtension().lastPathComponent
    }

    private static func designatedRequirement(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            return nil
        }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
}
