import AppKit
import WebKit

/// Pipeline that loads geoclock.world/wallpaper.html in an
/// offscreen `WKWebView`, calls `window.geoclockConfigure(...)`
/// with the user's config, waits for the `geoclockReady` script
/// message, then snapshots the view to a PNG on disk.
///
/// The whole pipeline is single-flight: a second `render()` call
/// while the first is in-flight is dropped (logged + ignored).
/// That keeps the WKWebView from being torn apart by a fast timer
/// tick while it's mid-paint.
///
/// Threading: WKWebView APIs require the main actor. The class
/// internally serializes on the main queue; callers can invoke
/// `render()` from anywhere.
final class WallpaperRenderer: NSObject {

  /// Disk-PNG write toggle. The app now paints the rendered
  /// wallpaper directly into the overlay window (see
  /// `OverlayState.wallpaperImage`) and no longer needs the PNG
  /// to exist on disk for `NSWorkspace.setDesktopImageURL`. The
  /// write path is kept compiled so we can re-enable it for
  /// debugging or for sharing the rendered image externally —
  /// flip this to `true` and a fresh PNG appears under
  /// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/GeoClockWallpaper/`
  /// on every render again.
  static let writePNGToDisk = false

  /// What the render hands back on success: an in-memory
  /// `NSImage` is always present; the file URL is only present
  /// when `writePNGToDisk` is true.
  struct RenderOutput {
    let image: NSImage
    let fileURL: URL?
  }

  enum RenderError: Error {
    case alreadyInFlight
    case navigationFailed(Error)
    case readyTimedOut
    case snapshotFailed(Error?)
    case pngEncodeFailed
    case fileWriteFailed(Error)
  }

  // MARK: – Constants

  /// WKWebView frame size, in points. Set per-render from the
  /// main screen's logical size so the SVG paints into a region
  /// matching the screen's aspect ratio — Stage-2 scaling
  /// (`setDesktopImageURL` with slice fit) then becomes a near-
  /// identity transform, and the overlay's single-stage
  /// projection math agrees with where the PNG actually places
  /// each pixel. WKWebView's snapshot applies the system
  /// backing-scale factor (typically 2× on retina) on top of
  /// this, so the output PNG is `renderSize.{w,h} × scale`.
  ///
  /// Capped at 2048 pt wide so 5K / 6K screens don't blow the
  /// render + PNG-encode budget — at the cap, macOS upscales
  /// the wallpaper on the display side; the projection still
  /// agrees because the aspect ratio matches.
  private var renderSize = NSSize(width: 1920, height: 1080)

  /// Recompute `renderSize` from the main screen. Called at
  /// the top of every render so display reconfigurations
  /// (resolution change, monitor swap) are reflected on the
  /// next tick without restarting the app.
  private func updateRenderSize() {
    let main = NSScreen.main?.frame.size
      ?? NSSize(width: 1920, height: 1080)
    let maxWidth: CGFloat = 2048
    if main.width <= maxWidth {
      renderSize = main
    } else {
      let scale = maxWidth / main.width
      renderSize = NSSize(
        width: maxWidth,
        height: (main.height * scale).rounded())
    }
  }

  /// URL of the wallpaper page. The page is bundled into the app
  /// under `Contents/Resources/WebAssets/` and served via the
  /// custom `geoclock-app://` scheme by `BundledAssetHandler` —
  /// see that file for the rationale (avoids `file://` CORS /
  /// module-loading edge cases and decouples future
  /// asset-update strategies from the page itself).
  ///
  /// The page is scheme-aware (see wallpaper.html's ASSET_BASE
  /// logic): when loaded via geoclock-app:// it resolves card
  /// imports against sibling files in the bundle, so no network
  /// access is needed at runtime.
  private let wallpaperURL = URL(string: "geoclock-app:///wallpaper.html")!

  /// Hard timeout from `geoclockConfigure` call to `geoclockReady`
  /// message. The page typically signals within ~3 s on a warm
  /// CDN cache; cold fetches of the imagery layer can take ~8 s.
  /// 20 s gives healthy headroom without freezing the menu bar
  /// indefinitely if the network drops.
  private let readyTimeout: TimeInterval = 20

  // MARK: – State

  private var webView: WKWebView?
  /// True once the wallpaper.html page has fully loaded (the
  /// initial navigation completed). Subsequent renders reuse the
  /// loaded page — they just call geoclockConfigure on the
  /// existing context instead of doing a new full navigation,
  /// which drops a steady-state render cycle from ~5 s to ~1 s.
  private var webViewPageLoaded = false
  private var inFlight = false
  /// Wall-clock start of the current render cycle, captured at
  /// the top of beginRender. Used for the per-phase timings we
  /// NSLog so it's clear which step is the bottleneck.
  private var renderStartTime: Date = .distantPast
  private var readyTimeoutItem: DispatchWorkItem?
  private var pendingCompletion: ((Result<RenderOutput, RenderError>) -> Void)?
  /// CSS to inject into the card's shadow root after configure +
  /// before snapshot. Always set to `overlayHidingCSS` for now;
  /// kept as a stored property so future per-render overrides
  /// can layer in.
  private var cssOverridePayload: String?
  /// SVG `preserveAspectRatio` attribute value to set on the
  /// card's `<svg>` after mount. Mirrors the user's aspect-fit
  /// mode so the wallpaper PNG matches the overlay's
  /// projection math. nil → leave the card's default
  /// ("xMidYMid slice") alone.
  private var preserveAspectRatioOverride: String?

  // MARK: – Public API

  /// Render the wallpaper for a given typed `WallpaperConfig`.
  /// Internally projects the config onto the `(card, hass)`
  /// JSON shape, then drives the page through navigation →
  /// configure → ready → snapshot → file write. Posts the
  /// result on the main queue. If a previous call is still in
  /// flight, this one is dropped and the completion is invoked
  /// with `.alreadyInFlight`.
  func render(
    config: WallpaperConfig,
    payload: (config: [String: Any], hass: [String: Any]),
    completion: @escaping (Result<RenderOutput, RenderError>) -> Void
  ) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard !self.inFlight else {
        completion(.failure(.alreadyInFlight))
        return
      }
      self.inFlight = true
      self.pendingCompletion = completion
      // CSS hides the card's clock + markers (handled by the
      // Swift overlay) and removes the card's inline
      // aspect-ratio so the SVG can fill the card host.
      self.cssOverridePayload = Self.overlayHidingCSS
      // preserveAspectRatio is an SVG attribute, not CSS, so
      // we set it via JS to honour the user's chosen
      // aspect-fit mode.
      self.preserveAspectRatioOverride =
        Self.preserveAspectRatio(for: config.aspectFit)
      self.beginRender(config: payload.config, hass: payload.hass)
    }
  }

  /// Build the WKWebView and load wallpaper.html if they're not
  /// already up. No-op if the page is already loaded. Safe to
  /// call repeatedly. Used to amortise the cold-start cost
  /// (~5 s of page navigation + module parse + asset fetch from
  /// the bundle) by triggering it when the user opens Settings —
  /// by the time they tweak the first slider, the page is
  /// already mounted and the next `render()` takes the fast
  /// path.
  func prewarm() {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard self.webView == nil else { return }

      Diagnostics.log("prewarm — loading wallpaper page")
      let webView = self.makeWebView()
      self.webView = webView

      // Same handler wiring as the slow path in beginRender. We
      // intentionally don't arm the ready timeout here because
      // prewarm doesn't have a completion to fail; the next
      // real render's beginRender will arm one of its own.
      webView.configuration.userContentController.add(
        ReadyHandler { [weak self] in self?.didReceiveReady() },
        name: "geoclockReady"
      )

      let nav = WebViewNavigationDelegate { [weak self] error in
        guard let self = self else { return }
        if error == nil {
          self.webViewPageLoaded = true
          Diagnostics.log("prewarm — page loaded")
        } else {
          // Couldn't load. Tear down so the next render rebuilds
          // from scratch instead of stumbling over a half-state.
          self.webView = nil
          self.navigationDelegate = nil
          self.webViewPageLoaded = false
        }
      }
      self.navigationDelegate = nav
      webView.navigationDelegate = nav
      webView.load(URLRequest(url: self.wallpaperURL))
    }
  }

  // MARK: – Implementation

  private func beginRender(config: [String: Any], hass: [String: Any]) {
    armReadyTimeout()
    renderStartTime = Date()
    updateRenderSize()

    // Fast path: WebView exists and the wallpaper page is already
    // loaded. Just push the new config; the page tears down the
    // existing card, creates a new one, and re-fires the
    // `geoclockReady` script-message which our handler is still
    // wired to from the first render.
    if let webView = webView, webViewPageLoaded {
      // Resize if the screen changed since the last render.
      // 100vw/100vh CSS + the SVG's width:100%/height:100% make
      // the inner content adapt automatically.
      if webView.frame.size != renderSize {
        webView.frame = NSRect(origin: .zero, size: renderSize)
      }
      Diagnostics.log(String(format:
        "render fast-path (WebView reused) — size %.0fx%.0f",
        renderSize.width, renderSize.height))
      pushConfig(config: config, hass: hass)
      return
    }
    Diagnostics.log(String(format:
      "render slow-path (cold WebView) — size %.0fx%.0f",
      renderSize.width, renderSize.height))

    // Slow path (first render of the app's lifetime): build the
    // WebView, register handlers, navigate to the bundled page.
    let webView = makeWebView()
    self.webView = webView

    webView.configuration.userContentController.add(
      ReadyHandler { [weak self] in self?.didReceiveReady() },
      name: "geoclockReady"
    )

    let nav = WebViewNavigationDelegate { [weak self] error in
      guard let self = self else { return }
      if let error = error {
        self.finish(.failure(.navigationFailed(error)))
      } else {
        // First-render navigation completed — flag the WebView as
        // page-loaded so subsequent renders take the fast path.
        self.webViewPageLoaded = true
        // Hand it our config. The page's module script may not
        // have parsed by didFinish yet, so the inline poll in
        // pushConfig waits for window.geoclockConfigure to exist.
        self.pushConfig(config: config, hass: hass)
      }
    }
    self.navigationDelegate = nav  // retain
    webView.navigationDelegate = nav

    webView.load(URLRequest(url: wallpaperURL))
  }

  /// Arm the ready timeout. If the page doesn't postMessage
  /// "ready" within `readyTimeout`, the render fails. Called at
  /// the start of every render (fast path and slow path).
  private func armReadyTimeout() {
    readyTimeoutItem?.cancel()
    let timeout = DispatchWorkItem { [weak self] in
      self?.finish(.failure(.readyTimedOut))
    }
    self.readyTimeoutItem = timeout
    DispatchQueue.main.asyncAfter(
      deadline: .now() + readyTimeout, execute: timeout)
  }

  private func makeWebView() -> WKWebView {
    let prefs = WKWebpagePreferences()
    prefs.allowsContentJavaScript = true

    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences = prefs
    // The page doesn't need persistent storage; ephemeral keeps
    // cookies / localStorage out of ~/Library/WebKit.
    config.websiteDataStore = .nonPersistent()

    // Register the custom scheme so geoclock-app:// URLs resolve
    // to files in Bundle.main/WebAssets via BundledAssetHandler.
    // Must be set on the configuration before the WKWebView is
    // constructed — registering after the fact is a no-op.
    config.setURLSchemeHandler(
      BundledAssetHandler(),
      forURLScheme: BundledAssetHandler.scheme
    )

    let frame = NSRect(origin: .zero, size: renderSize)
    let webView = WKWebView(frame: frame, configuration: config)
    // Offscreen: not added to any window. WKWebView still
    // renders into its CALayer, which takeSnapshot can capture.
    return webView
  }

  /// Push the config into the page via evaluateJavaScript. We
  /// poll for `window.geoclockConfigure` (defined by the page's
  /// module script) because module imports finish AFTER
  /// didFinish for the document's main navigation.
  private func pushConfig(config: [String: Any], hass: [String: Any]) {
    guard let webView = webView else { return }

    let payload: [String: Any] = ["config": config, "hass": hass]
    guard
      let data = try? JSONSerialization.data(withJSONObject: payload),
      let json = String(data: data, encoding: .utf8)
    else {
      finish(.failure(.snapshotFailed(nil)))
      return
    }

    let script = """
      (function poll() {
        if (typeof window.geoclockConfigure === 'function') {
          window.geoclockConfigure(\(json));
        } else {
          setTimeout(poll, 50);
        }
      })();
      """
    webView.evaluateJavaScript(script) { _, _ in
      // Result is ignored; the `geoclockReady` script-message
      // is the real "we're done" signal.
    }
  }

  /// Triggered by the page's `webkit.messageHandlers.geoclockReady.postMessage('ready')`
  /// call inside wallpaper.html — meaning the card has mounted,
  /// laid out, and the .frame override is in place. We inject any
  /// CSS overrides (clock-position, future aspect-fit) into the
  /// card's shadow root, then give the SVG one more runloop tick
  /// to settle before snapshotting.
  private func didReceiveReady() {
    Diagnostics.log(String(format: "ready @ +%.2f s",
                            Date().timeIntervalSince(renderStartTime)))
    // Pad the top of the page by the menu-bar height so the
    // wallpaper's top edge (hour band) isn't hidden behind it.
    injectDocumentCSS(topPadding: Self.maxMenuBarHeight())
    if let css = cssOverridePayload, !css.isEmpty {
      injectShadowCSS(css)
    }
    if let par = preserveAspectRatioOverride {
      injectSVGAttribute(preserveAspectRatio: par)
    }
    // Debug-only: 30° lat/lon mesh painted into the card's SVG
    // (green). The Swift overlay paints a magenta mesh at the
    // same step against `Projection.paintedRect`. With the
    // image now drawn inside the overlay window, the two grids
    // should overlap pixel-perfect; any visible offset / scale
    // / rotation is exactly the bug we're chasing. Disabled in
    // normal use — re-enable both this call and OverlayView's
    // `debugGrid` ZStack entry together when chasing alignment.
    // injectDebugGridJS()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.takeSnapshot()
    }
  }

  /// Paint a 30° lat/lon grid into the card's SVG using the
  /// SAME projection math the card uses (`latLonToPx` in
  /// viewBox coords). Latitude lines are full-width horizontals;
  /// longitude lines are stepped polylines so the seam wrap
  /// doesn't draw a bogus diagonal across the map. centerLon
  /// is read from `hass.config.longitude` — the wallpaper page
  /// shortcut writes `centerLongitude` into that field, so it
  /// matches the value Swift uses for the overlay's projection.
  private func injectDebugGridJS() {
    guard let webView = webView else { return }
    let script = #"""
      (function() {
        const card = document.querySelector('geo-clock-card');
        if (!card || !card.shadowRoot) return;
        const svg = card.shadowRoot.querySelector('svg');
        if (!svg) return;
        const ns = 'http://www.w3.org/2000/svg';
        svg.querySelector('#debug-grid')?.remove();

        const MAP_W = 2048;
        const MAP_H = 1024;
        const STEP = 30;
        const wrap360 = (deg) => ((deg % 360) + 360) % 360;
        const centerLon = card.hass?.config?.longitude ?? 0;
        const leftEdgeLon = centerLon - 180;
        const lonX = (lon) => (wrap360(lon - leftEdgeLon) / 360) * MAP_W;
        const latY = (lat) => ((90 - lat) / 180) * MAP_H;

        const g = document.createElementNS(ns, 'g');
        g.id = 'debug-grid';
        g.setAttribute('pointer-events', 'none');

        const mkLine = (x1, y1, x2, y2) => {
          const l = document.createElementNS(ns, 'line');
          l.setAttribute('x1', x1);
          l.setAttribute('y1', y1);
          l.setAttribute('x2', x2);
          l.setAttribute('y2', y2);
          l.setAttribute('stroke', '#00ff66');
          l.setAttribute('stroke-width', '2');
          l.setAttribute('stroke-opacity', '0.85');
          g.appendChild(l);
        };
        const mkText = (x, y, label) => {
          const t = document.createElementNS(ns, 'text');
          t.setAttribute('x', x);
          t.setAttribute('y', y);
          t.setAttribute('fill', '#00ff66');
          t.setAttribute('font-size', '14');
          t.setAttribute('font-family', 'monospace');
          t.setAttribute('text-anchor', 'middle');
          t.textContent = label;
          g.appendChild(t);
        };

        // Latitude lines — full-width horizontals at each step.
        for (let lat = -60; lat <= 60; lat += STEP) {
          const y = latY(lat);
          mkLine(0, y, MAP_W, y);
          mkText(MAP_W / 2 + 200, y - 4, `lat ${lat}`);
        }
        // Longitude lines — verticals from top of map to bottom.
        // Drawn as a single vertical line in viewBox space; the
        // seam wrap is automatic because lonX wraps mod 360.
        for (let lon = -180; lon < 180; lon += STEP) {
          const x = lonX(lon);
          mkLine(x, 0, x, MAP_H);
          mkText(x, MAP_H / 2, `lon ${lon}`);
        }

        svg.appendChild(g);
      })();
      """#
    webView.evaluateJavaScript(script) { _, _ in }
  }

  /// Set the card's `<svg preserveAspectRatio="…">` attribute
  /// after mount. SVG attributes can't be set from CSS, so
  /// we reach into the shadow DOM with JS. Re-runs on every
  /// render — the card re-mounts the SVG on each geoclockConfigure
  /// call, so a one-shot set wouldn't survive remounts.
  private func injectSVGAttribute(preserveAspectRatio value: String) {
    guard let webView = webView else { return }
    let script = """
      (function() {
        const card = document.querySelector('geo-clock-card');
        if (!card || !card.shadowRoot) return;
        const svg = card.shadowRoot.querySelector('svg');
        if (svg) svg.setAttribute('preserveAspectRatio', '\(value)');
      })();
      """
    webView.evaluateJavaScript(script) { _, _ in }
  }

  /// SVG `preserveAspectRatio` value matching each aspect-fit
  /// mode. The first token is the alignment (always centered);
  /// the second is "meet" (fit inside, letterbox) or "slice"
  /// (fill, crop overflow). Stretch uses "none" — distort to
  /// fit, no aspect preservation at all.
  static func preserveAspectRatio(for mode: AspectFit) -> String {
    switch mode {
    case .stretch:      return "none"
    case .letterbox:    return "xMidYMid meet"
    case .cropOverflow: return "xMidYMid slice"
    }
  }

  /// Inject document-level CSS overrides — distinct from
  /// `injectShadowCSS` because the menu-bar padding has to live
  /// on `<body>` / `geo-clock-card` themselves, not inside the
  /// card's shadow DOM. Idempotent via a stable element id.
  private func injectDocumentCSS(topPadding: CGFloat) {
    guard let webView = webView else { return }
    let css = """
      html, body {
        margin: 0;
        padding: 0;
        background: #000;
        width: 100vw;
        height: 100vh;
        box-sizing: border-box;
      }
      body {
        padding-top: \(Int(topPadding))px !important;
      }
      geo-clock-card {
        display: block !important;
        width: 100% !important;
        height: 100% !important;
      }
      """
    let escaped = css
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "`", with: "\\`")
    let script = """
      (function() {
        let style = document.getElementById('wp-doc-overrides');
        if (!style) {
          style = document.createElement('style');
          style.id = 'wp-doc-overrides';
          document.head.appendChild(style);
        }
        style.textContent = `\(escaped)`;
      })();
      """
    webView.evaluateJavaScript(script) { _, _ in }
  }

  /// Largest menu-bar height across all connected displays. On
  /// notched MacBooks `safeAreaInsets.top` reports the full
  /// notch-aware menu bar height (~38 pt); on regular displays
  /// `safeAreaInsets.top` is 0 and we fall back to
  /// `NSStatusBar.thickness` (~24 pt). The wallpaper PNG is
  /// shared across displays, so we use the max so the hour band
  /// stays visible on every display the user has connected.
  static func maxMenuBarHeight() -> CGFloat {
    let heights = NSScreen.screens.map { screen -> CGFloat in
      if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0 {
        return screen.safeAreaInsets.top
      }
      return NSStatusBar.system.thickness
    }
    return heights.max() ?? NSStatusBar.system.thickness
  }

  /// Inject a CSS rule block into the card's shadow root by
  /// appending a <style> element. Idempotent — we tag the style
  /// node with a fixed id so repeat renders update the same
  /// element instead of stacking copies. The card's own styles
  /// are higher in the cascade order but our injected sheet
  /// appends AFTER them, so it wins on equal specificity.
  private func injectShadowCSS(_ css: String) {
    guard let webView = webView else { return }
    let escaped = css
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "`", with: "\\`")
    let script = """
      (function() {
        const card = document.querySelector('geo-clock-card');
        if (!card || !card.shadowRoot) return;
        let style = card.shadowRoot.getElementById('wp-overrides');
        if (!style) {
          style = document.createElement('style');
          style.id = 'wp-overrides';
          card.shadowRoot.appendChild(style);
        }
        style.textContent = `\(escaped)`;
      })();
      """
    webView.evaluateJavaScript(script) { _, _ in }
  }

  /// CSS the renderer always injects into the card's shadow
  /// root. Two jobs:
  ///
  /// 1. Hide the card's in-PNG clock readout, date, home
  ///    marker, and user markers — those are drawn by the
  ///    Swift overlay layer (OverlayView) at 1 Hz live
  ///    precision. Without the hide, the user would see two
  ///    copies of every clock / marker: one stale on the
  ///    PNG, one live in the overlay.
  ///
  /// 2. Override the card's `.frame` inline `aspect-ratio:
  ///    2048/1068` so the SVG actually fills the card host
  ///    instead of leaving empty space at the bottom. With
  ///    the constraint removed, SVG's
  ///    preserveAspectRatio="xMidYMid slice" does its
  ///    intended job: scale to fully cover, crop overflow on
  ///    the constraining axis. Crucially this means the
  ///    wallpaper PNG and the Swift overlay can agree on
  ///    where a (lat, lon) lands on screen — they share the
  ///    same slice math.
  ///
  /// The PNG still keeps: imagery, day/night terminator,
  /// twilight glow, hour band, TZ boundary lines. None of
  /// those are owned by the overlay.
  static let overlayHidingCSS = """
    .readout, .date {
      display: none !important;
    }
    .marker, .home-marker {
      display: none !important;
    }
    .frame {
      aspect-ratio: auto !important;
      height: 100% !important;
    }
    """

  private func takeSnapshot() {
    guard let webView = webView else { return }
    let snapshotConfig = WKSnapshotConfiguration()
    snapshotConfig.afterScreenUpdates = true
    snapshotConfig.rect = NSRect(origin: .zero, size: renderSize)
    let t0 = Date()
    webView.takeSnapshot(with: snapshotConfig) { [weak self] image, error in
      guard let self = self else { return }
      Diagnostics.log(String(format: "snapshot @ +%.2f s (took %.2f s)",
            Date().timeIntervalSince(self.renderStartTime),
            Date().timeIntervalSince(t0)))
      guard let image = image else {
        self.finish(.failure(.snapshotFailed(error)))
        return
      }
      // Disk write is opt-in via `writePNGToDisk`. The in-memory
      // NSImage is the primary output now — handed straight to
      // the overlay window's background layer.
      var fileURL: URL? = nil
      if Self.writePNGToDisk {
        do {
          let writeStart = Date()
          fileURL = try self.writePNG(image: image)
          Diagnostics.log(String(format: "PNG written @ +%.2f s (encode+write took %.2f s)",
                Date().timeIntervalSince(self.renderStartTime),
                Date().timeIntervalSince(writeStart)))
        } catch let err as RenderError {
          self.finish(.failure(err))
          return
        } catch {
          self.finish(.failure(.fileWriteFailed(error)))
          return
        }
      }
      self.finish(.success(RenderOutput(image: image, fileURL: fileURL)))
    }
  }

  /// Encode the snapshot to PNG and write it under the sandbox
  /// container's Application Support directory. Each render uses
  /// a unique timestamped filename so `setDesktopImageURL` always
  /// sees a new URL — the two-slot rotation we had previously
  /// was sometimes losing renders to macOS's wallpaper cache when
  /// re-applied with the same path. We sweep older files at the
  /// end so disk usage stays bounded (keep the most recent two).
  private func writePNG(image: NSImage) throws -> URL {
    guard
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let pngData = bitmap.representation(using: .png, properties: [:])
    else {
      throw RenderError.pngEncodeFailed
    }

    let fm = FileManager.default
    let supportDir = try fm.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("GeoClockWallpaper", isDirectory: true)
    try fm.createDirectory(
      at: supportDir, withIntermediateDirectories: true)

    let stamp = Int(Date().timeIntervalSince1970 * 1000)
    let url = supportDir.appendingPathComponent("wallpaper-\(stamp).png")

    do {
      try pngData.write(to: url, options: .atomic)
    } catch {
      throw RenderError.fileWriteFailed(error)
    }

    // Sweep older renders. Keep the just-written file (always)
    // plus one previous (in case macOS is still reading it for
    // the live display). Anything older is fair game.
    pruneOldRenders(in: supportDir, keep: 2, except: url)

    return url
  }

  private func pruneOldRenders(in dir: URL, keep: Int, except: URL) {
    let fm = FileManager.default
    guard
      let entries = try? fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return }
    let candidates = entries
      .filter { $0.lastPathComponent.hasPrefix("wallpaper-") }
      .filter { $0.pathExtension == "png" }
      .filter { $0 != except }
      .sorted { lhs, rhs in
        let ld = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rd = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return ld > rd  // newest first
      }
    // Keep the (keep-1) most-recent old files (we also have
    // `except` which is the brand-new one, totaling `keep`).
    let toDelete = candidates.dropFirst(max(0, keep - 1))
    for url in toDelete {
      try? fm.removeItem(at: url)
    }
  }

  // MARK: – Teardown

  private var navigationDelegate: WebViewNavigationDelegate?

  private func finish(_ result: Result<RenderOutput, RenderError>) {
    readyTimeoutItem?.cancel()
    readyTimeoutItem = nil

    let completion = pendingCompletion
    pendingCompletion = nil
    inFlight = false

    // We DON'T tear down the WebView between successful renders
    // anymore — keeping the loaded page around means the next
    // render only pays for a re-mount of the card, not a full
    // page navigation (drops steady-state cycles from ~5 s to
    // ~1 s). If navigation itself failed, drop the WebView so
    // the next render rebuilds from scratch.
    if case .failure(let err) = result {
      switch err {
      case .navigationFailed, .readyTimedOut:
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        navigationDelegate = nil
        webViewPageLoaded = false
      default:
        break
      }
    }

    completion?(result)
  }
}

// MARK: – Helpers

/// Bridges WKScriptMessageHandler back to a closure so we don't
/// need a separate class with a stored reference to the renderer.
private final class ReadyHandler: NSObject, WKScriptMessageHandler {
  private let action: () -> Void
  init(action: @escaping () -> Void) { self.action = action }
  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    action()
  }
}

/// Same idea for navigation events — completion is called once,
/// either with the error from didFail* or nil on didFinish.
private final class WebViewNavigationDelegate: NSObject, WKNavigationDelegate {
  private var completion: ((Error?) -> Void)?
  init(completion: @escaping (Error?) -> Void) {
    self.completion = completion
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    completion?(nil); completion = nil
  }
  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    completion?(error); completion = nil
  }
  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    completion?(error); completion = nil
  }
}
