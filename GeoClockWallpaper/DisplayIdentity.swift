import AppKit
import CoreGraphics

/// macOS hands us two different display identifiers, neither
/// ideal on its own:
///
///   - `CGDirectDisplayID` (UInt32): the runtime handle every
///     CGDisplay / NSScreen API takes. Stable while the display
///     is attached but can change across reboots / unplug /
///     replug, especially when more than one display is
///     connected.
///   - Display UUID (CFUUID → string): the persistent identity
///     for a given physical / virtual display. Survives reboots
///     and reconnections; what we should persist if we want a
///     setting ("hide wallpaper on this monitor") to stick.
///
/// We use `CGDirectDisplayID` to key runtime state (per-screen
/// rendered images, overlay windows) and the UUID string to
/// persist user preferences. This enum is the single hop
/// between them.
enum DisplayIdentity {

  /// `CGDirectDisplayID` for the given `NSScreen`. The value
  /// lives under `NSDeviceDescriptionKey("NSScreenNumber")` —
  /// undocumented but the canonical way for years.
  static func id(of screen: NSScreen) -> CGDirectDisplayID? {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
  }

  /// Stable UUID string for the display behind `id`. We round-
  /// trip through CFUUID because CGDisplayCreateUUIDFromDisplayID
  /// hands back a retained CF type — Swift handles the retain
  /// release via `takeRetainedValue()`.
  static func uuidString(forID id: CGDirectDisplayID) -> String? {
    guard let cfUUID = CGDisplayCreateUUIDFromDisplayID(id)?
            .takeRetainedValue()
    else { return nil }
    return CFUUIDCreateString(nil, cfUUID) as String?
  }

  /// Convenience: NSScreen → persistent UUID string in one hop.
  static func uuidString(of screen: NSScreen) -> String? {
    guard let id = id(of: screen) else { return nil }
    return uuidString(forID: id)
  }
}
