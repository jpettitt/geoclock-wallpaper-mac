import AppKit
import SwiftUI

/// Manages the desktop-level transparent windows that draw the
/// live overlay (clock + home + user markers) on top of the
/// wallpaper PNG.
///
/// One window per `NSScreen`, recreated whenever the system's
/// screen configuration changes (display attached/detached,
/// resolution change, etc.). All windows share a single
/// `OverlayState` so config changes redraw everywhere
/// simultaneously.
final class OverlayLayer {

  let state: OverlayState

  /// Maps NSScreen displayID → its overlay window. We can't
  /// key directly by NSScreen because NSScreen instances are
  /// reissued across reconfiguration; displayID is stable for
  /// the same physical/virtual display.
  private var windowsByDisplay: [CGDirectDisplayID: NSWindow] = [:]
  private var screenObserver: NSObjectProtocol?

  init(state: OverlayState) {
    self.state = state
    rebuildWindows()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.rebuildWindows()
    }
  }

  deinit {
    if let obs = screenObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    for w in windowsByDisplay.values { w.orderOut(nil) }
  }

  /// (Re)create windows so there's exactly one per current
  /// `NSScreen`. Existing windows for still-attached displays
  /// stay (their frame is re-set in case the resolution
  /// changed); orphaned windows for removed displays are torn
  /// down.
  private func rebuildWindows() {
    let currentIDs: [CGDirectDisplayID] =
      NSScreen.screens.compactMap(Self.displayID(of:))

    // Drop windows for displays that no longer exist.
    for (id, win) in windowsByDisplay where !currentIDs.contains(id) {
      win.orderOut(nil)
      windowsByDisplay.removeValue(forKey: id)
    }

    // Add or refresh windows for current screens. For a
    // refresh we rebuild the SwiftUI hosting view because the
    // OverlayView captures the screen size — a resolution
    // change needs a fresh view, not just a new frame.
    for screen in NSScreen.screens {
      guard let id = Self.displayID(of: screen) else { continue }
      let win: NSWindow
      if let existing = windowsByDisplay[id] {
        existing.setFrame(screen.frame, display: true)
        let host = NSHostingController(
          rootView: AnyView(OverlayView(state: state, screen: screen)))
        host.view.frame = NSRect(origin: .zero, size: screen.frame.size)
        existing.contentView = host.view
        win = existing
      } else {
        win = OverlayWindowFactory.make(for: screen, state: state)
        windowsByDisplay[id] = win
      }
      win.orderFrontRegardless()
      Diagnostics.log(String(format:
        "overlay window: screen.frame=(%.0f,%.0f %.0fx%.0f) visibleFrame=(%.0f,%.0f %.0fx%.0f) backingScale=%.2f window.frame=(%.0f,%.0f %.0fx%.0f)",
        screen.frame.origin.x, screen.frame.origin.y,
        screen.frame.width, screen.frame.height,
        screen.visibleFrame.origin.x, screen.visibleFrame.origin.y,
        screen.visibleFrame.width, screen.visibleFrame.height,
        screen.backingScaleFactor,
        win.frame.origin.x, win.frame.origin.y,
        win.frame.width, win.frame.height))
    }

    Diagnostics.log(
      "overlay layer: managing \(windowsByDisplay.count) window(s)")
  }

  /// Pull the unique `CGDirectDisplayID` out of an NSScreen.
  /// Returns nil for fully-headless screens (vanishingly rare).
  private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    let key = NSDeviceDescriptionKey("NSScreenNumber")
    return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
  }
}
