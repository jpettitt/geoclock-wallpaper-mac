import AppKit
import SwiftUI

/// Helpers for building a desktop-level transparent overlay
/// window. We use plain `NSWindow` (not a subclass) — that
/// avoids the `init(contentRect:styleMask:backing:defer:)`
/// override Swift requires for subclasses and keeps the
/// window lifecycle plain. `OverlayLayer` calls
/// `OverlayWindowFactory.make(for:state:)` once per screen.
enum OverlayWindowFactory {

  /// Build a transparent, mouse-ignoring, desktop-level
  /// NSWindow that fills the given screen and hosts a SwiftUI
  /// `OverlayView` bound to the supplied state. Caller is
  /// responsible for retaining the returned window and
  /// ordering it on-screen.
  static func make(for screen: NSScreen, state: OverlayState) -> NSWindow {
    let window = NSWindow(
      contentRect: screen.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false,
      screen: screen
    )

    // Window level: above wallpaper, below user app windows
    // and Finder desktop icons. Bridge CGWindowLevel (Int32)
    // through NSWindow.Level's raw Int.
    window.level = NSWindow.Level(
      rawValue: Int(CGWindowLevelForKey(.desktopWindow)))

    // Transparency + click-through. The wallpaper / Finder
    // icons underneath stay fully interactive.
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.ignoresMouseEvents = true

    // `.canJoinAllSpaces` shows the window on every Space —
    // matches the wallpaper itself which is per-display.
    // `.stationary` keeps it from sliding during Space
    // transitions.
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]

    // Don't pollute the Window menu / Mission Control.
    window.isExcludedFromWindowsMenu = true
    window.hidesOnDeactivate = false

    // Host the SwiftUI content. We wrap in AnyView so the
    // hosting controller's generic type doesn't escape into
    // OverlayLayer's storage.
    let root = OverlayView(state: state, screen: screen)
    let hosting = NSHostingController(rootView: AnyView(root))
    hosting.view.frame = NSRect(origin: .zero, size: screen.frame.size)
    window.contentView = hosting.view

    return window
  }
}
