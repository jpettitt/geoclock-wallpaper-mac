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
  /// Held strong so the Settings window survives across opens.
  /// `isReleasedWhenClosed = false` would suffice if we recreated
  /// on every open, but keeping the same window preserves user
  /// edits-in-flight (form bindings) across close/reopen.
  private var settingsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupStatusItem()
    overlayLayer = OverlayLayer(state: overlayState)
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
        rootView: SettingsView().environmentObject(config))
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
    }
  }

  @objc private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(nil)
  }

  // MARK: – Render + apply

  /// Renders the wallpaper.html, snapshots it to PNG, and points
  /// every connected display at the resulting file. Idempotent —
  /// safe to call concurrently with a timer tick because both
  /// paths share the same renderer's serial queue.
  private func updateWallpaper() {
    Diagnostics.log("updateWallpaper() called")
    let payload = config.buildWallpaperPayload()
    // Tell the overlay layer the centerLon we're about to
    // render at — markers project against this, so the
    // overlay-drawn marker sits exactly over where the
    // wallpaper would have drawn it.
    overlayState.updateCenterLon(payload.centerLon)
    overlayState.applyConfig(config.config)
    overlayState.homeCoordinate = resolveHomeCoordinate()
    overlayState.menuBarHeight = Double(
      WallpaperRenderer.maxMenuBarHeight())
    Diagnostics.log(String(format:
      "overlay: centerLon=%.4f, mode=%@, screens=%d, menubar=%.0f",
      payload.centerLon,
      String(describing: config.config.centerMode),
      NSScreen.screens.count,
      overlayState.menuBarHeight))
    for screen in NSScreen.screens {
      Diagnostics.log(String(format:
        "  screen size=%.0fx%.0f aspect=%@",
        screen.frame.width, screen.frame.height,
        String(describing: config.config.aspectFit)))
    }
    let _imgSize = overlayState.wallpaperImage?.size
      ?? NSScreen.main?.frame.size ?? .zero
    Diagnostics.log(String(format:
      "  wallpaperImage size=%.0fx%.0f (used for projection)",
      _imgSize.width, _imgSize.height))
    for (i, m) in config.config.markers.enumerated() {
      let mainSize = NSScreen.main?.frame.size ?? .zero
      let ctx = Projection.ScreenContext(
        screen: mainSize,
        imageSize: _imgSize,
        aspect: config.config.aspectFit,
        menuBarHeight: overlayState.menuBarHeight,
        bandVisible: config.config.showTimezoneBand)
      let vb = Projection.viewBoxPoint(
        lat: m.latitude, lon: m.longitude,
        centerLon: payload.centerLon)
      let pt = Projection.screenPoint(
        viewBoxPoint: vb, in: ctx)
      Diagnostics.log(String(format:
        "  marker[%d] '%@' lat=%.2f lon=%.2f -> vb=(%.0f,%.0f) screen=%@",
        i, m.label, m.latitude, m.longitude, vb.x, vb.y,
        pt.map { String(format: "(%.0f,%.0f)", $0.x, $0.y) }
          ?? "OFFSCREEN"))
    }
    renderer.render(
      config: config.config,
      payload: (payload.config, payload.hass)
    ) { [weak self] result in
      switch result {
      case .success(let output):
        // Hand the bitmap to the overlay layer. The overlay
        // window paints it as its background and the marker
        // ZStack rides on top in the SAME view's coordinate
        // space — no more disagreement between the OS's
        // setDesktopImageURL crop/scale math and the
        // overlay's projection math.
        let label = output.fileURL?.lastPathComponent ?? "<in-memory>"
        Diagnostics.log(String(format:
          "render succeeded — %@ — NSImage.size=%.0fx%.0f reps=%d",
          label, output.image.size.width, output.image.size.height,
          output.image.representations.count))
        for rep in output.image.representations {
          Diagnostics.log(String(format:
            "  rep: pixelsWide=%d pixelsHigh=%d size=%.0fx%.0f",
            rep.pixelsWide, rep.pixelsHigh,
            rep.size.width, rep.size.height))
        }
        self?.overlayState.wallpaperImage = output.image
        // setDesktopImageURL was the old delivery path. We
        // keep `WallpaperApplier` compiled so flipping
        // `WallpaperRenderer.writePNGToDisk` back on (plus
        // re-enabling this call) restores the prior
        // "macOS owns the wallpaper" mode. For now the
        // overlay window IS the wallpaper.
        if let url = output.fileURL {
          let applyStart = Date()
          self?.applier.applyToAllScreens(imageURL: url)
          Diagnostics.log(String(format: "wallpaper applied (setDesktopImageURL took %.2f s)", Date().timeIntervalSince(applyStart)))
        }
      case .failure(let error):
        Diagnostics.log("render failed — \(error)")
      }
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
