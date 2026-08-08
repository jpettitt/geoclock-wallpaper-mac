import ScreenSaver
import SwiftUI

/// GeoClock screensaver: shows the wallpaper app's most recent
/// rendered map frame for this display, with the SAME SwiftUI
/// overlay (live clock + markers) the app draws on the desktop.
///
/// Deliberately dumb: no web engine, no rendering of its own. The
/// GeoClockWallpaper app publishes clock-less/marker-less frames +
/// its config to /Users/Shared/GeoClockWallpaper (see SaverShared /
/// SaverFrameExporter); this view feeds them to the app's own
/// OverlayView, which composites map + overlay itself — the frame
/// goes into `OverlayState.wallpaperImages` exactly as the app's
/// render loop does. (OverlayView paints an opaque black fallback
/// when that dictionary has no entry for the display — do NOT try
/// to render the map as a ZStack sibling underneath it; it will be
/// covered. That cost a dozen debug builds to learn.)
///
/// Runs inside Apple's sandboxed legacyScreenSaver host — read-only
/// filesystem access is fine, writing anywhere is not. Never write
/// from this class.
private struct SaverRootView: View {
  @ObservedObject var state: OverlayState
  let screen: NSScreen

  var body: some View {
    ZStack {
      // OverlayView draws the map (from state.wallpaperImages) as
      // its own bottom layer, so markers/clock/map share one
      // coordinate space — identical to the app's desktop overlay.
      OverlayView(state: state, screen: screen)
      if state.wallpaperImages.isEmpty {
        Text("GeoClock has nothing to show yet.\n\nOpen the GeoClockWallpaper app once — it publishes the map this screensaver displays (Settings → Map → Screensaver).")
          .multilineTextAlignment(.center)
          .foregroundColor(.white)
          .frame(maxWidth: 500)
      }
    }
    .ignoresSafeArea()
  }
}

@objc(GeoClockSaverView)
final class GeoClockSaverView: ScreenSaverView {

  private let state = OverlayState()
  private var hostingView: NSView?
  private var configuredForScreen: NSScreen?
  private var lastConfigDate: Date?
  private var lastFrameDate: Date?
  private var ticksSinceCheck = 0

  override init?(frame: NSRect, isPreview: Bool) {
    super.init(frame: frame, isPreview: isPreview)
    commonInit()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    commonInit()
  }

  private func commonInit() {
    Diagnostics.log("saver: init, isPreview=\(isPreview)")
    animationTimeInterval = 1.0
  }

  // The window (and therefore the screen this instance serves) is
  // only known after attachment — screen-dependent setup waits for
  // it. Re-runs are cheap and idempotent.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    reloadIfNeeded(force: true)
  }

  override func startAnimation() {
    super.startAnimation()
    reloadIfNeeded(force: true)
  }

  override func animateOneFrame() {
    // OverlayState ticks its own 1 Hz `now` timer, which drives the
    // SwiftUI clock — nothing to do for time. We only poll the
    // shared files for newer content, and only every 15 s: a stat()
    // per second per display is pointless when the app refreshes
    // every few minutes.
    ticksSinceCheck += 1
    if ticksSinceCheck >= 15 {
      ticksSinceCheck = 0
      reloadIfNeeded(force: false)
    }
  }

  override var hasConfigureSheet: Bool { false }

  // MARK: – Loading

  private func targetScreen() -> NSScreen? {
    window?.screen ?? NSScreen.main
  }

  private func modificationDate(of url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  private func reloadIfNeeded(force: Bool) {
    guard let screen = targetScreen() else { return }

    // Match this screen's frame; fall back to ANY published frame
    // (a display the app hasn't rendered for — e.g. freshly plugged
    // in — still gets a map, just one rendered at another size).
    let uuid = DisplayIdentity.uuidString(of: screen)
    var frameURL = uuid.map(SaverShared.frameURL(forDisplayUUID:))
    var metaURL = uuid.map(SaverShared.frameMetaURL(forDisplayUUID:))
    if frameURL == nil
      || !FileManager.default.fileExists(atPath: frameURL!.path) {
      if let anyPNG = try? FileManager.default
        .contentsOfDirectory(
          at: SaverShared.framesDir, includingPropertiesForKeys: nil)
        .first(where: { $0.pathExtension == "png" }) {
        frameURL = anyPNG
        metaURL = anyPNG.deletingPathExtension().appendingPathExtension("json")
      }
    }

    guard
      let frameURL,
      let metaURL,
      FileManager.default.fileExists(atPath: frameURL.path)
    else {
      // No published frames: SaverRootView shows its hint. The tree
      // must exist for that.
      if hostingView == nil { rebuildOverlay(for: screen) }
      layoutOverlay(for: screen)
      return
    }

    let configDate = modificationDate(of: SaverShared.configURL)
    let frameDate = modificationDate(of: frameURL)
    let screenChanged = configuredForScreen !== screen
    guard force || screenChanged
      || configDate != lastConfigDate || frameDate != lastFrameDate
    else { return }
    lastConfigDate = configDate
    lastFrameDate = frameDate

    // Config → OverlayState, exactly as the app applies it. The
    // per-display resolution happens here (not in OverlayView) so a
    // display-specific marker list / clock position carries over.
    if
      let data = try? Data(contentsOf: SaverShared.configURL),
      let saved = try? SaverShared.makeDecoder()
        .decode(SaverShared.SaverConfig.self, from: data) {
      state.applyConfig(saved.config.resolved(forDisplay: uuid))
      if let lat = saved.homeLatitude, let lon = saved.homeLongitude {
        state.homeCoordinate = .init(latitude: lat, longitude: lon)
      } else {
        state.homeCoordinate = nil
      }
    }
    // Fullscreen saver — no menu bar to dodge.
    state.menuBarHeight = 0

    guard let displayID = DisplayIdentity.id(of: screen) else { return }

    if
      let metaData = try? Data(contentsOf: metaURL),
      let meta = try? SaverShared.makeDecoder()
        .decode(SaverShared.SaverFrameMeta.self, from: metaData) {
      state.centerLonsByDisplay[displayID] = meta.centerLon
      state.updateCenterLon(meta.centerLon)
    }

    // THE core hookup: the frame becomes the overlay's wallpaper
    // layer, exactly as AppDelegate commits render output. Decode
    // from memory (NSImage(contentsOf:) defers file reads to draw
    // time, which is fragile inside the sandboxed host).
    if let data = try? Data(contentsOf: frameURL),
       let image = NSImage(data: data) {
      state.wallpaperImages[displayID] = image
      Diagnostics.log(String(format:
        "saver: frame %@ → wallpaperImages[%u] (%.0fx%.0f)",
        frameURL.lastPathComponent, displayID,
        image.size.width, image.size.height))
    } else {
      Diagnostics.log("saver: frame \(frameURL.path) FAILED to read/decode")
    }

    if screenChanged || hostingView == nil {
      rebuildOverlay(for: screen)
    }
    layoutOverlay(for: screen)
  }

  /// The overlay projects marker/clock positions against the SCREEN
  /// size (OverlayView is written for a full-screen OverlayWindow).
  /// Host it at screen size and scale the layer down to our bounds —
  /// full-screen that's a 1:1 no-op, and in the System Settings
  /// preview thumbnail everything shrinks proportionally instead of
  /// clustering at the wrong coordinates.
  private func rebuildOverlay(for screen: NSScreen) {
    hostingView?.removeFromSuperview()
    let host = NSHostingView(rootView: SaverRootView(
      state: state, screen: screen))
    host.frame = CGRect(origin: .zero, size: screen.frame.size)
    host.wantsLayer = true
    addSubview(host)
    hostingView = host
    configuredForScreen = screen
  }

  private func layoutOverlay(for screen: NSScreen) {
    guard let host = hostingView, screen.frame.width > 0 else { return }
    let scale = bounds.width / screen.frame.width
    host.layer?.anchorPoint = .zero
    host.layer?.position = .zero
    host.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
  }

  override func resize(withOldSuperviewSize oldSize: NSSize) {
    super.resize(withOldSuperviewSize: oldSize)
    if let screen = configuredForScreen { layoutOverlay(for: screen) }
  }
}
