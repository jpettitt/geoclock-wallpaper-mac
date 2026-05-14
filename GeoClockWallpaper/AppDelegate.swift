import AppKit
import Combine
import CoreLocation
import SwiftUI

/// Owns the menu-bar status item and the wallpaper-update loop.
/// The app has no main window — everything is reachable from the
/// status item's dropdown menu and the SwiftUI Settings scene.
///
/// Wiring summary:
///   ConfigStore   ─┐
///       │         │ publishes user-config changes
///       ▼         ▼
///   WallpaperRenderer  ─→  PNG file URL
///       ▲                        │
///       │ trigger                ▼
///   Scheduler             WallpaperApplier (NSWorkspace)
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var statusItem: NSStatusItem!
  private let renderer = WallpaperRenderer()
  private let applier = WallpaperApplier()
  private var scheduler: Scheduler!
  private var cancellables: Set<AnyCancellable> = []
  private let config = ConfigStore.shared
  /// Live overlay state shared across every overlay window.
  /// `OverlayLayer` holds the NSWindows; we own the state so
  /// the AppDelegate's Combine subscriptions can drive it.
  private let overlayState = OverlayState()
  private var overlayLayer: OverlayLayer?
  /// Manages the per-display floating config panels (one panel
  /// per enabled display while `perDisplayEnabled` is true).
  private var perDisplayPanels: PerDisplayPanelManager?
  /// Held strong so the Settings window survives across opens.
  /// `isReleasedWhenClosed = false` would suffice if we recreated
  /// on every open, but keeping the same window preserves user
  /// edits-in-flight (form bindings) across close/reopen.
  private var settingsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupStatusItem()
    overlayLayer = OverlayLayer(state: overlayState)
    perDisplayPanels = PerDisplayPanelManager(
      store: config, overlayState: overlayState)

    // PerDisplayPanelManager posts this when any aux panel is
    // closed, so Settings dismisses with the rest of the
    // config surface instead of stranding the user with the
    // master window after they X'd a panel.
    NotificationCenter.default.addObserver(
      forName: .closeSettingsWindow,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.settingsWindow?.performClose(nil)
    }
    overlayState.menuBarHeight =
      Double(WallpaperRenderer.maxMenuBarHeight())

    scheduler = Scheduler(
      interval: TimeInterval(config.updateInterval),
      onFire: { [weak self] in self?.updateWallpaper() }
    )

    // Re-fire whenever the user changes the interval. The Combine
    // pipeline projects out individual fields from the typed
    // config so we only react to the field the scheduler cares
    // about, not every unrelated edit.
    config.$config
      .map(\.updateInterval)
      .removeDuplicates()
      .sink { [weak self] newValue in
        self?.scheduler.setInterval(TimeInterval(newValue))
      }
      .store(in: &cancellables)

    config.$config
      .map(\.paused)
      .removeDuplicates()
      .sink { [weak self] paused in
        if paused { self?.scheduler.pause() }
        else { self?.scheduler.resume() }
        self?.rebuildMenu()
      }
      .store(in: &cancellables)

    // Trigger an immediate re-render whenever the user edits any
    // render-affecting field. Debounce so typing into a marker
    // label or dragging the cadence slider doesn't fire a render
    // on every value; .removeDuplicates() skips redundant
    // emissions; the .filter guard prevents the change from
    // bypassing an explicit Pause.
    // 250 ms is enough to coalesce a slider drag or a multi-
    // keystroke text edit while still feeling immediate when
    // the user clicks a single checkbox.
    config.$config
      .dropFirst()
      .removeDuplicates()
      .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
      .filter { !$0.paused }
      .sink { [weak self] _ in
        self?.updateWallpaper()
      }
      .store(in: &cancellables)

    // Whenever Core Location hands us a new fix, the wallpaper
    // needs to redraw if the user picked "My location". We
    // re-render unconditionally — the renderer is cheap and the
    // alternative is plumbing centerMode awareness here just to
    // skip a sometimes-irrelevant render.
    LocationService.shared.$coordinate
      .dropFirst()
      .removeDuplicates(by: { $0?.latitude == $1?.latitude
                              && $0?.longitude == $1?.longitude })
      .sink { [weak self] _ in
        guard let self = self else { return }
        if self.config.config.centerMode == .myLocation {
          self.updateWallpaper()
        }
      }
      .store(in: &cancellables)

    // When the user flips centerMode to .myLocation, ask for
    // permission if we haven't yet. Putting this in a Combine
    // pipeline rather than a SwiftUI action keeps the request
    // logic in one place — Settings UI doesn't need to know
    // about CLLocationManager directly.
    config.$config
      .map(\.centerMode)
      .removeDuplicates()
      .sink { mode in
        if mode == .myLocation {
          LocationService.shared.requestAccessIfNeeded()
          LocationService.shared.requestRefresh()
        }
      }
      .store(in: &cancellables)

    // Reverse-geocode the home coordinate every time it changes
    // so the home-marker's clock reads the local wall time of
    // the user's actual location instead of the device's TZ.
    LocationService.shared.$coordinate
      .removeDuplicates(by: { $0?.latitude == $1?.latitude
                              && $0?.longitude == $1?.longitude })
      .sink { [weak self] coord in
        guard let self = self, let coord = coord else { return }
        TimezoneResolver.shared.reverse(
          lat: coord.latitude, lon: coord.longitude
        ) { [weak self] tzid in
          self?.overlayState.homeTimezone =
            tzid.flatMap { TimeZone(identifier: $0) }
        }
      }
      .store(in: &cancellables)

    // Backfill IANA tzids on any marker that has lat/lon but no
    // saved tzid — happens for markers from configs that pre-date
    // the tzid field, and as a safety net if a forward-geocode
    // didn't fully populate the marker. One reverse-geocode per
    // marker; serialised by TimezoneResolver.
    backfillMarkerTimezones()

    // Drive the Login Item registration from the config. Apply
    // the saved value once on launch (so a freshly installed app
    // registers itself the first time it runs given the default
    // `launchAtStartup: true`), then keep it in sync with any
    // later Settings toggles.
    LaunchAtLogin.setEnabled(config.config.launchAtStartup)
    config.$config
      .map(\.launchAtStartup)
      .removeDuplicates()
      .dropFirst()  // initial value already applied above
      .sink { LaunchAtLogin.setEnabled($0) }
      .store(in: &cancellables)

    // First wallpaper draw on launch — don't wait for the first
    // timer tick. Errors here just log; the next tick will retry.
    updateWallpaper()
    scheduler.start()
  }

  /// For every marker with a real coordinate but a missing tzid,
  /// fire a reverse-geocode and store the result back on the
  /// marker. Idempotent: markers that already have a tzid are
  /// skipped. Hits CLGeocoder serially — TimezoneResolver
  /// queues internally.
  private func backfillMarkerTimezones() {
    for marker in config.config.markers where marker.tzid == nil {
      // Skip uninitialised (0, 0) markers — that's the default
      // when a row is added but no place has been entered yet.
      guard marker.latitude != 0 || marker.longitude != 0 else { continue }
      let id = marker.id
      TimezoneResolver.shared.reverse(
        lat: marker.latitude, lon: marker.longitude
      ) { [weak self] tzid in
        guard let self = self, let tzid = tzid else { return }
        if let i = self.config.config.markers
          .firstIndex(where: { $0.id == id }) {
          self.config.config.markers[i].tzid = tzid
        }
      }
    }
  }

  // MARK: – Menu bar

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(
      withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      // Two-tone globe rendered as SF Symbol would be the most
      // native look, but globe.americas matches the brand close
      // enough for v0.1; we can drop a custom NSImage in later.
      button.image = NSImage(
        systemSymbolName: "globe.americas.fill",
        accessibilityDescription: "GeoClock Wallpaper"
      )
      button.image?.isTemplate = true   // tints with menu bar
    }
    rebuildMenu()
  }

  private func rebuildMenu() {
    let menu = NSMenu()

    let refresh = NSMenuItem(
      title: "Refresh Now",
      action: #selector(refreshNow),
      keyEquivalent: "r")
    refresh.target = self
    menu.addItem(refresh)

    let pauseTitle = config.paused ? "Resume Updates" : "Pause Updates"
    let pause = NSMenuItem(
      title: pauseTitle,
      action: #selector(togglePause),
      keyEquivalent: "")
    pause.target = self
    menu.addItem(pause)

    menu.addItem(.separator())

    let settings = NSMenuItem(
      title: "Settings…",
      action: #selector(openSettings),
      keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)

    menu.addItem(.separator())

    let about = NSMenuItem(
      title: "About GeoClock Wallpaper",
      action: #selector(showAbout),
      keyEquivalent: "")
    about.target = self
    menu.addItem(about)

    let quit = NSMenuItem(
      title: "Quit",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    menu.addItem(quit)

    statusItem.menu = menu
  }

  // MARK: – Menu actions

  @objc private func refreshNow() { updateWallpaper() }

  @objc private func togglePause() { config.paused.toggle() }

  @objc private func openSettings() {
    if settingsWindow == nil {
      // Build the window lazily on first open. Hosting controller
      // wraps the SwiftUI view; we inject the ConfigStore via
      // `.environmentObject` here so the bindings inside the form
      // resolve correctly.
      let hosting = NSHostingController(
        rootView: SettingsView()
          .environmentObject(config)
          .environmentObject(overlayState))
      let window = NSWindow(contentViewController: hosting)
      window.title = "GeoClock Wallpaper Settings"
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.isReleasedWhenClosed = false   // survive close → reopen
      window.center()
      window.setFrameAutosaveName("GeoClockWallpaperSettings")
      window.delegate = self
      settingsWindow = window
    }
    NSApp.setActivationPolicy(.regular)    // need .regular for the
                                            // window to take focus on
                                            // LSUIElement apps; we
                                            // flip back on close.
    NSApp.activate(ignoringOtherApps: true)
    settingsWindow?.makeKeyAndOrderFront(nil)
    publishSettingsWindowScreen()
    // Re-open any per-display panels the user closed manually.
    // Without this, after a close-all cascade the panels would
    // only come back on a toggle-off-then-on of the master
    // switch, which felt like a bug.
    perDisplayPanels?.showAllPanels()

    // Pre-warm the renderer while the user is finding their way
    // around Settings. By the time they tweak something, the
    // WKWebView is loaded + the card is parsed + the imagery
    // bundle is in WebKit's resource cache. Without this the
    // first edit pays the cold-start cost (~5 s) on top of the
    // debounce + snapshot.
    renderer.prewarm()
  }

  /// NSWindowDelegate hook: when the user closes the Settings
  /// window, drop activation policy back to `.accessory` so the
  /// app returns to menu-bar-only mode (no Dock icon).
  func windowWillClose(_ notification: Notification) {
    if let w = notification.object as? NSWindow, w === settingsWindow {
      NSApp.setActivationPolicy(.accessory)
      overlayState.settingsWindowDisplayUUID = nil
    }
  }

  /// NSWindowDelegate hook: the Settings window jumped to a
  /// different display. Re-publish the new display's UUID so
  /// the "This display" tab in Settings re-targets that screen
  /// and `PerDisplayPanelManager` closes the panel there
  /// (and reopens the panel for the screen Settings just left).
  func windowDidChangeScreen(_ notification: Notification) {
    guard
      let w = notification.object as? NSWindow,
      w === settingsWindow
    else { return }
    publishSettingsWindowScreen()
  }

  /// Resolve the Settings window's current display UUID and
  /// publish it on `overlayState`. Called on open and on
  /// `windowDidChangeScreen`.
  private func publishSettingsWindowScreen() {
    guard let screen = settingsWindow?.screen else {
      overlayState.settingsWindowDisplayUUID = nil
      return
    }
    overlayState.settingsWindowDisplayUUID =
      DisplayIdentity.uuidString(of: screen)
  }

  @objc private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(nil)
  }

  // MARK: – Render + apply

  /// Per-screen render target. We snapshot identity + size at
  /// the top of an update so the loop is unaffected by displays
  /// being attached/detached mid-iteration — the next update
  /// rebuilds the list.
  private struct ScreenRenderTarget {
    let displayID: CGDirectDisplayID
    let displayUUID: String
    let size: NSSize
    let label: String  // localizedName for logs
  }

  /// Render the wallpaper once per connected (and enabled)
  /// display, then hand each image to the overlay layer keyed
  /// by `CGDirectDisplayID`. Renders are serialised because the
  /// shared WKWebView can only do one snapshot at a time — the
  /// per-screen loop chains via the previous render's
  /// completion. Total wall-clock per update grows linearly with
  /// the number of enabled displays, but each screen's overlay
  /// flips to its new bitmap as soon as it lands so the user
  /// sees progressive updates instead of one long stall.
  private func updateWallpaper() {
    Diagnostics.log("updateWallpaper() called")
    // Apply the global config + the global centerLon up front
    // so single-screen callers (and tests of the legacy path)
    // still see something sensible. Per-display centerLons are
    // recorded as each target's render lands below.
    let globalPayload = config.buildWallpaperPayload()
    overlayState.updateCenterLon(globalPayload.centerLon)
    overlayState.applyConfig(config.config)
    overlayState.homeCoordinate = resolveHomeCoordinate()
    overlayState.menuBarHeight = Double(
      WallpaperRenderer.maxMenuBarHeight())

    // Build the per-screen render plan. Skip displays the user
    // has disabled in Settings; their overlay window stays
    // empty (black background) and no CLGeocoder / WKWebView
    // cost is paid for them.
    let disabled = Set(config.config.disabledDisplays)
    var targets: [ScreenRenderTarget] = []
    for screen in NSScreen.screens {
      guard
        let id = DisplayIdentity.id(of: screen),
        let uuid = DisplayIdentity.uuidString(forID: id)
      else { continue }
      if disabled.contains(uuid) {
        Diagnostics.log(String(format:
          "  screen '%@' (uuid=%@) disabled — skipping",
          screen.localizedName, uuid))
        continue
      }
      targets.append(ScreenRenderTarget(
        displayID: id,
        displayUUID: uuid,
        size: screen.frame.size,
        label: screen.localizedName))
    }

    // Garbage-collect images for displays that are no longer in
    // the render plan (unplugged, or freshly disabled). Keeps
    // overlayState.wallpaperImages from leaking across config
    // changes.
    let activeIDs = Set(targets.map(\.displayID))
    for staleID in overlayState.wallpaperImages.keys
                    where !activeIDs.contains(staleID) {
      overlayState.wallpaperImages.removeValue(forKey: staleID)
    }

    Diagnostics.log(String(format:
      "overlay: centerLon=%.4f, mode=%@, enabled-screens=%d, menubar=%.0f, perDisplay=%@",
      globalPayload.centerLon,
      String(describing: config.config.centerMode),
      targets.count,
      overlayState.menuBarHeight,
      config.config.perDisplayEnabled ? "on" : "off"))

    renderNextTarget(targets: targets, index: 0)
  }

  /// Recursive driver for the per-screen render loop. Pull the
  /// next target, build its own per-display payload (so each
  /// screen's `centerMode` / `aspectFit` / marker list takes
  /// effect), hand it to the renderer with its screen size, and
  /// on completion (success or failure) advance to the next
  /// target. Stops cleanly when the list is exhausted.
  private func renderNextTarget(
    targets: [ScreenRenderTarget],
    index: Int
  ) {
    guard index < targets.count else { return }
    let target = targets[index]

    // Build a payload for THIS display. When per-display mode
    // is off, this folds in nothing and equals the global
    // payload — same as the old code path.
    let payload = config.buildWallpaperPayload(
      forDisplay: target.displayUUID)
    overlayState.centerLonsByDisplay[target.displayID] = payload.centerLon

    Diagnostics.log(String(format:
      "render [%d/%d] '%@' (%.0fx%.0f) centerLon=%.4f",
      index + 1, targets.count, target.label,
      target.size.width, target.size.height,
      payload.centerLon))

    // The resolved config drives the SVG's preserveAspectRatio
    // injection inside the renderer, so we have to pass the
    // per-display resolved cfg too — not the global one.
    let resolvedCfg = config.config.resolved(forDisplay: target.displayUUID)

    renderer.render(
      forSize: target.size,
      config: resolvedCfg,
      payload: (payload.config, payload.hass)
    ) { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success(let output):
        Diagnostics.log(String(format:
          "  render done '%@' NSImage.size=%.0fx%.0f",
          target.label,
          output.image.size.width, output.image.size.height))
        self.overlayState.wallpaperImages[target.displayID] = output.image
      case .failure(let error):
        Diagnostics.log(
          "  render failed '\(target.label)' — \(error)")
      }
      // Advance whether the previous render succeeded or
      // failed — one bad display shouldn't block the others.
      self.renderNextTarget(
        targets: targets, index: index + 1)
    }
  }

  /// Resolve the user's home coordinate for the overlay layer.
  /// Same fall-through chain as the centerLatitude/Longitude
  /// resolver but always tied to "where the user actually is"
  /// regardless of centerMode — so a manual-centered map can
  /// still show a home dot in the right place.
  private func resolveHomeCoordinate() -> CLLocationCoordinate2D? {
    if let c = LocationService.shared.coordinate { return c }
    let tzid = TimeZone.current.identifier
    if let centroid = TimezoneCentroid.coordinate(forIANA: tzid) {
      return CLLocationCoordinate2D(
        latitude: centroid.lat, longitude: centroid.lon)
    }
    return nil
  }
}
