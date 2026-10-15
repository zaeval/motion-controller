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

    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Screen")
    private static let key = "lockExemptApps"
    /// Ticked from the start where they're installed: what the list was made for.
    private static let defaultBundleIDs = ["com.internal.kakaoweb"]

    private(set) var apps: [App] = []
    /// Exempt apps, then apps held back during a lock, then everything else running that isn't part of macOS.
    private(set) var choices: [Choice] = []
    private var heldBack: [String: (name: String, url: URL?)] = [:]
    /// Per process, for the length of a lock: the first event pays for the signature check (~50ms), the rest don't.
    @ObservationIgnored private var verdicts: [pid_t: Bool] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([App].self, from: data) {
            apps = saved
        } else {
            // Not saved until one is found, so installing KakaoWeb after this app still ticks it.
            apps = Self.defaultBundleIDs.compactMap { bundleID in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map(Self.app(at:))
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
        for process in NSWorkspace.shared.runningApplications
        where apps.contains(where: { $0.bundleID == process.bundleIdentifier }) {
            _ = allows(process.processIdentifier)
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
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for process in NSWorkspace.shared.runningApplications {
            guard process.processIdentifier != ownPID, process.activationPolicy != .prohibited,
                  let bundleID = process.bundleIdentifier, !bundleID.hasPrefix("com.apple."),
                  let url = process.bundleURL
            else { continue }
            rows[bundleID] = Choice(
                bundleID: bundleID, name: process.localizedName ?? Self.name(of: url), url: url,
                isExempt: false, wasHeldBack: false
            )
        }
        for (bundleID, process) in heldBack {
            rows[bundleID] = Choice(
                bundleID: bundleID, name: process.name, url: process.url, isExempt: false, wasHeldBack: true
            )
        }
        for app in apps {
            rows[app.bundleID, default: Choice(
                bundleID: app.bundleID, name: app.name, url: nil, isExempt: true, wasHeldBack: false
            )].isExempt = true
        }
        choices = rows.values.sorted { left, right in
            if left.isExempt != right.isExempt { return left.isExempt }
            if left.wasHeldBack != right.wasHeldBack { return left.wasHeldBack }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    private func check(_ pid: pid_t) -> Bool {
        // The hardware, this app's own events, and processes that aren't apps.
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier,
              let process = NSRunningApplication(processIdentifier: pid), let bundleID = process.bundleIdentifier
        else { return false }
        let path = process.bundleURL?.path ?? bundleID
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            noteHeldBack(process, bundleID: bundleID)
            return false
        }
        guard let requirement = app.requirement else { return true }
        let status = Self.validate(pid: pid, bundleURL: process.bundleURL, requirement: requirement)
        guard status == errSecSuccess else {
            Self.logger.notice("\(path, privacy: .public)(pid \(pid))는 예외 앱 서명이 아니라 잠금에서 막음 (\(status))")
            noteHeldBack(process, bundleID: bundleID)
            return false
        }
        Self.logger.notice("\(path, privacy: .public)(pid \(pid))는 예외 앱이라 잠금을 통과")
        return true
    }

    private func noteHeldBack(_ process: NSRunningApplication, bundleID: String) {
        guard heldBack[bundleID] == nil else { return }
        let url = process.bundleURL
        heldBack[bundleID] = (process.localizedName ?? url.map(Self.name(of:)) ?? bundleID, url)
        refresh()
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
