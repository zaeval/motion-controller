import Foundation

/// Reads the window server's desktop (Space) list through SkyLight, read-only, to tell whether a synthesized Dock
/// swipe actually moved the desktop. The symbols are private, so they are looked up with `dlsym` and everything
/// returns nil when a macOS update drops them (plan §9).
enum SpaceInfo {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> CFArray?

    /// The managed ids of the display's desktops, left to right, for reading the log after a switch.
    static func spaceIDs() -> [Int] {
        displays().first { $0["Current Space"] != nil }
            .flatMap { $0["Spaces"] as? [[String: Any]] }?
            .compactMap { $0["ManagedSpaceID"] as? Int } ?? []
    }

    /// The current desktop's managed id on the display that has one, or nil when SkyLight won't say.
    static func currentSpaceID() -> Int? {
        for display in displays() {
            guard let current = display["Current Space"] as? [String: Any],
                  let id = current["ManagedSpaceID"] as? Int
            else { continue }
            return id
        }
        return nil
    }

    private static func displays() -> [[String: Any]] {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let connectionSymbol = dlsym(handle, "SLSMainConnectionID"),
              let spacesSymbol = dlsym(handle, "SLSCopyManagedDisplaySpaces")
        else { return [] }
        let connection = unsafeBitCast(connectionSymbol, to: MainConnectionID.self)()
        return unsafeBitCast(spacesSymbol, to: CopyManagedDisplaySpaces.self)(connection) as? [[String: Any]] ?? []
    }
}
