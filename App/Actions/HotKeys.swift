import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Master on/off. macOS 15+ rejects ⌥-only chords in RegisterEventHotKey (-9868), so this uses ⌃⌥⌘.
    static let toggleEnabled = Self("toggleEnabled", initial: .init(.g, modifiers: [.control, .option, .command]))
}
