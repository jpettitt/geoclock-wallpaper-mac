import AppKit
import Combine
import SwiftUI

extension Notification.Name {
  /// Settings → Displays' "Show panels" button posts this so
  /// the manager can re-summon panels the user closed via each
  /// panel's window-close button. Carries no userInfo.
  static let showPerDisplayPanels =
    Notification.Name("GeoClockWallpaper.showPerDisplayPanels")

  /// Posted by `PerDisplayPanelManager` when one of its panels
  /// is closed. `AppDelegate` listens for this and closes the
  /// Settings window so the cascade-close treats Settings + the
  /// floating panels as a single unit: any close affects all.
  static let closeSettingsWindow =
    Notification.Name("GeoClockWallpaper.closeSettingsWindow")
}

/// Owns one floating SwiftUI panel per enabled display while
/// `WallpaperConfig.perDisplayEnabled == true`. Each panel sits
/// in the top-right corner of its physical screen and lets the
/// user edit that screen's override slice of `perDisplaySettings`.
///
/// Panels are NSPanels (utility / floating), not full NSWindows,
/// so they don't show in the Dock or app switcher and they
/// don't steal focus when summoned.
///
/// Lifecycle reacts to two signals:
///   - `config.perDisplayEnabled` flip → open/close all panels
///   - screen reconfiguration (plug, unplug, layout change) →
///     re-pair panels with current `NSScreen.screens`
///   - `config.disabledDisplays` change → close panel for a
///     newly-disabled display (it'd be misleading otherwise:
///     the user can't see the wallpaper on a disabled monitor,
///     so a config panel for it would have nothing to preview)
final class PerDisplayPanelManager: NSObject {

  let store: ConfigStore
  let overlayState: OverlayState
  private var panelsByDisplay: [CGDirectDisplayID: NSWindow] = [:]
  private var screenObserver: NSObjectProtocol?
  private var showPanelsObserver: NSObjectProtocol?
  private var configObserver: AnyCancellable?
  private var settingsScreenObserver: AnyCancellable?
  /// Re-entrance guard. NSPanel property-setters that AppKit
  /// processes asynchronously (e.g. `level`, `collectionBehavior`)
  /// can spin the main run loop, and that has surfaced our
  /// own Combine publisher synchronously while we're still
  /// constructing the previous panel. Without a guard, refresh()
  /// would recurse forever before the first panel is fully
  /// configured.
  private var isRefreshing = false
  /// Set during `closeAll()` so the NSWindowDelegate hook
  /// doesn't recursively cascade-close (we're already closing
  /// everything; the per-panel `windowWillClose` would otherwise
  /// fire `closeAll` again for each panel in the loop).
  private var isClosingAll = false

  init(store: ConfigStore, overlayState: OverlayState) {
    self.store = store
    self.overlayState = overlayState
    super.init()

    // Initial pass once the run loop spins so any deferred
    // window operations don't race AppKit's screen registration.
    DispatchQueue.main.async { [weak self] in self?.refresh() }

    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.refresh() }

    showPanelsObserver = NotificationCenter.default.addObserver(
      forName: .showPerDisplayPanels,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.showAllPanels() }

    // React when the master toggle flips or the disabled set
    // changes. We don't react to changes inside per-display
    // settings themselves — those are what the panels EDIT, so
    // re-rendering the panel content is the SwiftUI binding's
    // job, not ours.
    // The compiler trips over a tuple in `removeDuplicates(by:)`,
    // so observe the two fields separately and let `refresh()`
    // de-dupe trivial calls by checking actual state.
    let enabledStream = store.$config
      .map(\.perDisplayEnabled)
      .removeDuplicates()
    let disabledStream = store.$config
      .map(\.disabledDisplays)
      .removeDuplicates()
    // @Published emits during `willSet`, before the property is
    // actually updated. If refresh() ran synchronously off the
    // sink it would still see the OLD value when reading
    // `store.config.perDisplayEnabled` — that's why a toggle off
    // appeared to "not stick" until the next toggle. Deferring
    // via `receive(on: DispatchQueue.main)` punts refresh to the
    // next runloop turn, after didSet has committed.
    configObserver = Publishers.Merge(
      enabledStream.map { _ in () },
      disabledStream.map { _ in () }
    )
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in self?.refresh() }

    // Whenever the user moves the Settings window between
    // monitors (or closes it), re-evaluate which displays
    // should have a floating panel. The display Settings is
    // currently on gets its panel suppressed — the "This
    // display" tab handles that screen instead. Same
    // willSet/didSet ordering caveat as the config observer
    // above; defer to the next runloop turn.
    settingsScreenObserver = overlayState.$settingsWindowDisplayUUID
      .removeDuplicates()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in self?.refresh() }
  }

  deinit {
    if let obs = screenObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    if let obs = showPanelsObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    closeAll()
  }

  /// Public hook used by Settings → Displays' "Show panels"
  /// button to re-open panels the user has individually closed
  /// via each panel's window-close button.
  func showAllPanels() {
    refresh(force: true)
  }

  // MARK: – Internal

  private func refresh(force: Bool = false) {
    if isRefreshing {
      Diagnostics.log("perDisplayPanels: refresh re-entered, ignoring")
      return
    }
    isRefreshing = true
    defer { isRefreshing = false }
    let cfg = store.config
    let settingsOpen = overlayState.settingsWindowDisplayUUID != nil
    Diagnostics.log(
      "perDisplayPanels: refresh enabled=\(cfg.perDisplayEnabled) settingsOpen=\(settingsOpen) force=\(force) existing=\(panelsByDisplay.count)")
    // Panels are scoped to "Settings is open" — they're the
    // per-display editing surface, so once Settings closes
    // there's nothing to edit. Toggling perDisplayEnabled off
    // also tears them down (the feature itself is off).
    if !cfg.perDisplayEnabled || !settingsOpen {
      closeAll()
      return
    }

    // Identify the screens we should be showing panels for:
    // every connected display that hasn't been disabled by the
    // user in the Displays tab AND that isn't currently hosting
    // the Settings window (its "This display" tab provides the
    // same controls — no need to duplicate them in a floating
    // panel).
    let disabled = Set(cfg.disabledDisplays)
    let occupiedBySettings = overlayState.settingsWindowDisplayUUID
    let activeScreens = NSScreen.screens.filter { s in
      guard let u = DisplayIdentity.uuidString(of: s) else { return false }
      if disabled.contains(u) { return false }
      if let occ = occupiedBySettings, u == occ { return false }
      return true
    }
    let activeIDs = Set(activeScreens.compactMap(DisplayIdentity.id))

    // Drop panels for displays that went away (unplugged or
    // newly disabled).
    for (id, panel) in panelsByDisplay where !activeIDs.contains(id) {
      panel.close()
      panelsByDisplay.removeValue(forKey: id)
    }

    Diagnostics.log(String(format:
      "perDisplayPanels: activeScreens=%d activeIDs=%d",
      activeScreens.count, activeIDs.count))

    // Add panels for any active screen that doesn't have one.
    // `force` re-opens panels that were closed individually by
    // the user — used by the Settings "Show panels" button.
    for screen in activeScreens {
      guard
        let id = DisplayIdentity.id(of: screen),
        let uuid = DisplayIdentity.uuidString(of: screen)
      else {
        Diagnostics.log("perDisplayPanels: skip screen '\(screen.localizedName)' — no id/uuid")
        continue
      }
      Diagnostics.log(String(format:
        "perDisplayPanels: considering '%@' id=%u hasPanel=%@",
        screen.localizedName, id,
        panelsByDisplay[id] != nil ? "yes" : "no"))
      if let existing = panelsByDisplay[id] {
        Diagnostics.log("perDisplayPanels: re-pinning existing for '\(screen.localizedName)'")
        existing.setFrame(
          Self.panelFrame(for: screen),
          display: false)
        if force {
          existing.orderFrontRegardless()
        }
        continue
      }
      Diagnostics.log("perDisplayPanels: about to makePanel for '\(screen.localizedName)'")
      let panel = makePanel(for: screen, uuid: uuid)
      Diagnostics.log("perDisplayPanels: makePanel returned for '\(screen.localizedName)'")
      panelsByDisplay[id] = panel
      panel.orderFrontRegardless()
      Diagnostics.log(String(format:
        "perDisplayPanels: opened '%@' at (%.0f,%.0f %.0fx%.0f) visible=%@",
        screen.localizedName,
        panel.frame.origin.x, panel.frame.origin.y,
        panel.frame.size.width, panel.frame.size.height,
        panel.isVisible ? "yes" : "no"))
    }
    Diagnostics.log("perDisplayPanels: refresh loop done, total=\(panelsByDisplay.count)")
  }

  private func makePanel(for screen: NSScreen, uuid: String) -> NSWindow {
    // Plain titled panel (no `.utilityWindow`): utility panels
    // are hidden by AppKit when the app's activation policy is
    // `.accessory`, which is exactly our case (LSUIElement=YES).
    // The `.nonactivatingPanel` style keeps clicks from
    // promoting us out of menu-bar mode while still letting the
    // panel show on top of everything.
    let panel = NSPanel(
      contentRect: Self.panelFrame(for: screen),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = "\(screen.localizedName) — display settings"
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = .floating
    // .moveToActiveSpace spins the runloop during Mission Control
    // setup and re-fires our Combine observers mid-makePanel —
    // we don't need it for an alpha. .canJoinAllSpaces alone is
    // enough to keep the panel on the user's current Space.
    panel.collectionBehavior = [.canJoinAllSpaces]
    panel.isReleasedWhenClosed = false
    panel.delegate = self

    let view = PerDisplayConfigView(
      displayUUID: uuid,
      displayName: screen.localizedName
    ).environmentObject(store)
    let host = NSHostingController(rootView: view)
    // Pin a sensible default size so the SwiftUI form (which
    // can be zero-height at first eval) doesn't shrink the
    // NSPanel down to 1×32 px. The user can still resize the
    // panel by dragging its edges.
    let defaultSize = NSSize(width: 420, height: 540)
    host.preferredContentSize = defaultSize
    panel.contentViewController = host
    panel.setContentSize(defaultSize)
    // contentViewController assignment can resize the window
    // again — re-pin the final frame against the target screen
    // so it lands top-right of THIS display.
    panel.setFrame(Self.panelFrame(for: screen), display: false)

    return panel
  }

  private func closeAll() {
    isClosingAll = true
    defer { isClosingAll = false }
    for panel in panelsByDisplay.values { panel.close() }
    panelsByDisplay.removeAll()
  }

  /// Top-right corner of the target screen, with a 40 pt
  /// breathing-room inset. Cocoa screen coords are bottom-left
  /// origin: x grows right, y grows up. So "top-right of
  /// screen" = max-x, max-y of `screen.frame`, then offset by
  /// (panelWidth, panelHeight) plus margins.
  private static func panelFrame(for screen: NSScreen) -> NSRect {
    let size = NSSize(width: 420, height: 540)
    let margin: CGFloat = 40
    let origin = NSPoint(
      x: screen.frame.maxX - size.width - margin,
      y: screen.frame.maxY - size.height - margin
    )
    return NSRect(origin: origin, size: size)
  }
}

// MARK: – NSWindowDelegate

extension PerDisplayPanelManager: NSWindowDelegate {

  /// Cascade-close. When the user clicks the X on any one
  /// per-display panel, close the rest too AND close the
  /// Settings window so the whole config surface dismisses as
  /// one unit. Programmatic closes via `closeAll()` set
  /// `isClosingAll` so we don't recurse.
  func windowWillClose(_ notification: Notification) {
    guard !isClosingAll else { return }
    closeAll()
    // Ask AppDelegate to close Settings too. Routed through a
    // notification because PerDisplayPanelManager doesn't
    // (and shouldn't) know about the Settings window directly.
    NotificationCenter.default.post(name: .closeSettingsWindow, object: nil)
  }
}
