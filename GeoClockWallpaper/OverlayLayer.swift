import AppKit
import Combine
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
///
/// Displays the user has opted out of in Settings
/// (`state.disabledDisplays`, keyed by display UUID) get no
/// window at all — the system wallpaper underneath stays
/// untouched on those monitors.
final class OverlayLayer {

  let state: OverlayState

  /// Maps NSScreen displayID → its overlay window. We can't
  /// key directly by NSScreen because NSScreen instances are
  /// reissued across reconfiguration; displayID is stable for
  /// the same physical/virtual display.
  private var windowsByDisplay: [CGDirectDisplayID: NSWindow] = [:]
  private var screenObserver: NSObjectProtocol?
  private var disabledObserver: AnyCancellable?

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
    // Rebuild when the user flips a per-display toggle in
    // Settings — the disabled set is observed off the same
    // OverlayState that drives the views. `receive(on:)`
    // defers to the next runloop turn so the @Published's
    // willSet-time emission lets the property finish writing
    // before rebuildWindows reads `state.disabledDisplays`.
    disabledObserver = state.$disabledDisplays
      .removeDuplicates()
      .dropFirst()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.rebuildWindows() }
  }

  deinit {
    if let obs = screenObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    for w in windowsByDisplay.values { w.orderOut(nil) }
  }

  /// (Re)create windows so there's exactly one per currently
  /// **enabled** `NSScreen`. Existing windows for still-attached
  /// enabled displays stay (their frame is re-set in case the
  /// resolution changed); windows for removed OR newly-disabled
  /// displays are torn down.
  private func rebuildWindows() {
    let enabledScreens = NSScreen.screens.filter { screen in
      guard let uuid = DisplayIdentity.uuidString(of: screen)
      else { return true }  // unknown identity → render anyway
      return !state.disabledDisplays.contains(uuid)
    }
    let enabledIDs: [CGDirectDisplayID] =
      enabledScreens.compactMap(Self.displayID(of:))

    // Drop windows for displays that no longer exist OR that
    // the user has just disabled.
    let staleIDs = windowsByDisplay.keys.filter { !enabledIDs.contains($0) }
    for id in staleIDs {
      if let win = windowsByDisplay[id] {
        win.orderOut(nil)
        windowsByDisplay.removeValue(forKey: id)
      }
    }

    // Add or refresh windows for current enabled screens. For a
    // refresh we rebuild the SwiftUI hosting view because the
    // OverlayView captures the screen size — a resolution
    // change needs a fresh view, not just a new frame.
    for screen in enabledScreens {
      guard let id = Self.displayID(of: screen) else { continue }
      let win: NSWindow
      if let existing = windowsByDisplay[id] {
        existing.setFrame(screen.frame, display: true)
        // NSHostingView directly — the view owns the SwiftUI
        // graph, no orphaned controller (see OverlayWindowFactory).
        let host = NSHostingView(
          rootView: AnyView(OverlayView(state: state, screen: screen)))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        existing.contentView = host
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
