import AppKit

/// Applies a PNG file as the desktop wallpaper on every connected
/// display. Uses `NSWorkspace.setDesktopImageURL(_:for:options:)`
/// — the only API that works inside the App Sandbox.
///
/// macOS picks the scaling mode per display from System Settings
/// → Wallpaper. We pass `imageScaling: .scaleProportionallyUpOrDown`
/// + `allowClipping: true` as a sensible default, but the user's
/// per-display preference wins if they've configured one.
final class WallpaperApplier {
  /// Set `imageURL` as the wallpaper on every `NSScreen.screens`.
  /// macOS handles multi-display attach/detach without further
  /// intervention — when a screen joins or leaves we don't need
  /// to re-apply.
  func applyToAllScreens(imageURL: URL) {
    let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
      .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
      .allowClipping: true,
    ]
    for screen in NSScreen.screens {
      do {
        try NSWorkspace.shared.setDesktopImageURL(
          imageURL, for: screen, options: options)
      } catch {
        NSLog(
          "GeoClockWallpaper: setDesktopImageURL failed on screen %@ — %@",
          screen, error.localizedDescription)
      }
    }
  }
}
