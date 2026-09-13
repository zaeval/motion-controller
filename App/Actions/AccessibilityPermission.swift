import AppKit
import ApplicationServices

/// The Accessibility permission, which posting synthetic mouse and keyboard events requires.
enum AccessibilityPermission {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system dialog that leads to System Settings; macOS shows it at most once per app identity.
    static func prompt() {
        // The value of kAXTrustedCheckOptionPrompt, spelled out because the imported global isn't concurrency-safe.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
