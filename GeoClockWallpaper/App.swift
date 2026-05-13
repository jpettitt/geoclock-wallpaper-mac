import SwiftUI

/// SwiftUI entry point. The app is a menu-bar utility (`LSUIElement
/// = YES` in Info.plist) and has no main window — Settings is
/// presented imperatively from `AppDelegate.openSettings()` via an
/// `NSHostingController`, not through SwiftUI's `Settings` scene
/// (which doesn't reliably fire `showSettingsWindow:` under
/// LSUIElement on macOS 13–15).
///
/// SwiftUI's `App` protocol requires at least one Scene, so we
/// declare a degenerate `Settings` scene with an `EmptyView` — it
/// exists only to satisfy the protocol and is never invoked.
@main
struct GeoClockWallpaperApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Settings { EmptyView() }
  }
}
