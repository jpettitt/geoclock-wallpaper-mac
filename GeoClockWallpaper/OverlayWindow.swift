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

    // AppKit places borderless windows at the wrong global origin
    // when the `contentRect` passed to init describes a non-
    // primary screen — empirically the window ends up at (2x,2y)
    // of the secondary's screen.frame.origin, parked far off
    // screen. An explicit setFrame after init forces the correct
    // global position. Without this, only the primary monitor's
    // overlay shows on launch; the secondaries lurk off-screen
    // until something fires `didChangeScreenParametersNotification`
    // (e.g. opening Settings) and the rebuild path's own
    // setFrame call corrects them.
    window.setFrame(screen.frame, display: false)

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

    // Host the SwiftUI content. NSHostingView directly (rather
    // than extracting .view from an NSHostingController and
    // dropping the controller) — the view owns the SwiftUI graph
    // itself, so there's no reliance on the undocumented detail
    // that the orphaned controller's view keeps working.
    let root = OverlayView(state: state, screen: screen)
    let hosting = NSHostingView(rootView: AnyView(root))
    hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
    window.contentView = hosting

    return window
  }
}
