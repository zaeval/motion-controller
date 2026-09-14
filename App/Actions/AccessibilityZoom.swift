import AppKit
import CoreFoundation
import Foundation
import os

/// What macOS will actually do with a zoom gesture, and how to let the user switch it on.
///
/// Zooming the *screen* is a feature of System Settings > 손쉬운 사용 > 확대/축소, and both of its triggers are off
/// until someone turns them on. That is why the gesture looked broken on this Mac (2026-09-14): the actions were
/// firing, ⌥⌘= was going out, and macOS had nothing listening — the user's own ⌃-scroll did nothing either, which is
/// the same feature.
///
/// So the app asks for whichever one is switched on, and falls back to the zoom that needs no setting at all.
enum AccessibilityZoom {
    enum Style: Equatable {
        /// ⌃ + scroll: the screen zoom, and smooth. Needs "스크롤 제스처와 보조 키를 함께 사용하여 확대/축소".
        case scroll
        /// ⌥⌘= / ⌥⌘-: the screen zoom in fixed steps. Needs "키보드 단축키로 확대/축소 사용".
        case keys
        /// ⌘+ / ⌘-: the app in front zooms its own content. Needs nothing, works nowhere else.
        case app

        var displayName: String {
            switch self {
            case .scroll: "화면 확대 (⌃ 스크롤)"
            case .keys: "화면 확대 (⌥⌘ 단축키)"
            case .app: "앱 확대 (⌘+/⌘-)"
            }
        }
    }

    private static let domainName = "com.apple.universalaccess"
    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Zoom")

    /// "스크롤 제스처와 보조 키를 함께 사용하여 확대/축소".
    static var scrollEnabled: Bool { flag("closeViewScrollWheelToggle") }
    /// "키보드 단축키로 확대/축소 사용".
    static var keysEnabled: Bool { flag("closeViewHotkeysEnabled") }

    /// Smooth screen zoom if it is on, stepped screen zoom if that is, else the app's own zoom.
    static var style: Style {
        if scrollEnabled { return .scroll }
        if keysEnabled { return .keys }
        return .app
    }

    /// Opens the pane with those two checkboxes. The tutorial offers this rather than explaining a path, because
    /// nothing the app can do turns them on for the user.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Seeing_Zoom") else { return }
        NSWorkspace.shared.open(url)
        logger.notice("Opened the zoom settings pane")
    }

    /// Read straight from the other app's preferences, synchronized first: the user may have ticked the box a second
    /// ago, and this has to notice without a relaunch.
    private static func flag(_ key: String) -> Bool {
        let domain = domainName as CFString
        CFPreferencesAppSynchronize(domain)
        guard let value = CFPreferencesCopyAppValue(key as CFString, domain) else { return false }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
