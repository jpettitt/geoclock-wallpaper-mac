import AppKit
import CoreLocation
import SwiftUI

/// SwiftUI content drawn inside each `OverlayWindow`. Reads
/// `OverlayState` for everything time-or-config-dependent and
/// re-renders when any published field changes (markers, clock
/// config, centerLon, the 1 Hz `now` tick).
///
/// Three layers, painted bottom-to-top:
///   1. Home marker (dot + halo + optional label/time)
///   2. User markers (same shape, per-marker color)
///   3. Main clock readout (corner-anchored per ClockPosition)
///
/// Each marker is projected through `Projection` using the
/// current centerLon + aspect-fit + this view's screen size.
/// Off-screen markers are simply omitted by the projection
/// helper (returns nil), so we don't have to special-case
/// edge-cropped placements.
struct OverlayView: View {

  @ObservedObject var state: OverlayState
  let screen: NSScreen
  /// Display identity, resolved ONCE at view construction. The
  /// screen a given OverlayView serves never changes (OverlayLayer
  /// rebuilds the hosting view on reconfiguration), but the
  /// computed-property version of these re-ran
  /// CGDisplayCreateUUIDFromDisplayID + CFUUIDCreateString several
  /// times per body pass — at 1 Hz across every screen, all of it
  /// redundant CF round-tripping.
  private let displayID: CGDirectDisplayID?
  private let displayUUID: String?

  init(state: OverlayState, screen: NSScreen) {
    self.state = state
    self.screen = screen
    self.displayID = DisplayIdentity.id(of: screen)
    self.displayUUID = self.displayID.flatMap {
      DisplayIdentity.uuidString(forID: $0)
    }
  }

  /// Per-screen effective config. Folds any
  /// `perDisplaySettings[uuid]` overrides on top of the global
  /// `WallpaperConfig`. Read every field through this rather
  /// than `state.X` so the per-display system actually changes
  /// what this overlay renders. One struct fold per body pass
  /// (uuid pre-resolved at init).
  private var resolved: WallpaperConfig {
    state.config.resolved(forDisplay: displayUUID)
  }

  /// CenterLon for this screen's wallpaper render. Each
  /// display can have a different `centerMode` under
  /// per-display mode, so we look up the per-display value
  /// first and only fall back to the global one when this
  /// screen hasn't been rendered yet.
  private var centerLon: Double {
    if let id = displayID, let lon = state.centerLonsByDisplay[id] {
      return lon
    }
    return state.currentCenterLon
  }

  var body: some View {
    // Don't draw anything until a wallpaper render has committed
    // a centerLon — otherwise the overlay flashes markers at
    // lon=0 (Greenwich) for a beat before catching up.
    if state.hasInitialRender {
      ZStack(alignment: .topLeading) {
        wallpaperBackground
        // debugGrid   // magenta — pairs with the green SVG grid
        homeMarker
        userMarkers
        clockReadout
      }
      .frame(width: screen.frame.width, height: screen.frame.height)
      .allowsHitTesting(false)
    }
  }

  // MARK: – Debug grid

  /// 30° lat/lon mesh drawn directly in screen-space using
  /// `Projection.paintedRect` + the same viewBox→screen normalisation
  /// `Projection.screenPoint` uses. The card's SVG paints a green
  /// grid at the same step (see `WallpaperRenderer.injectDebugGridJS`).
  /// When both are on screen, any offset / scale / rotation between
  /// the two coordinate systems is the bug being chased.
  ///
  /// Drawn with Canvas so a single shape covers the entire mesh —
  /// SwiftUI's per-line View overhead doesn't compound across the
  /// ~20 lines we draw.
  @ViewBuilder
  private var debugGrid: some View {
    let ctx = Projection.ScreenContext(
      screen: screen.frame.size,
      imageSize: self.wallpaperImage?.size ?? screen.frame.size,
      aspect: resolved.aspectFit,
      menuBarHeight: state.menuBarHeight,
      bandVisible: resolved.showTimezoneBand
    )
    if let painted = Projection.paintedRect(in: ctx) {
      Canvas { context, _ in
        let mapW = Projection.mapW
        let mapH = Projection.mapH
        let totalH = Projection.totalH(bandVisible: resolved.showTimezoneBand)
        let yMin = Projection.yMin(bandVisible: resolved.showTimezoneBand)
        // SwiftUI Color has no .magenta — use RGB literal.
        let stroke = GraphicsContext.Shading.color(
          Color(red: 1, green: 0, blue: 1, opacity: 0.85))
        var path = Path()
        // Latitude lines.
        for lat in stride(from: -60.0, through: 60.0, by: 30.0) {
          let vbY = ((90 - lat) / 180) * mapH
          let normY = (vbY - yMin) / totalH
          let y = painted.y + normY * painted.h
          path.move(to: CGPoint(x: painted.x, y: y))
          path.addLine(to: CGPoint(x: painted.x + painted.w, y: y))
        }
        // Longitude lines.
        for lon in stride(from: -180.0, to: 180.0, by: 30.0) {
          let leftEdgeLon = centerLon - 180
          var lonE = (lon - leftEdgeLon)
            .truncatingRemainder(dividingBy: 360)
          if lonE < 0 { lonE += 360 }
          let vbX = (lonE / 360) * mapW
          let normX = vbX / mapW
          let x = painted.x + normX * painted.w
          // Span the full painted height (covers the hour band
          // through to the map bottom). The viewBox y range is
          // [yMin, mapH] which maps to [painted.y, painted.y +
          // painted.h] via the same normalisation.
          path.move(to: CGPoint(x: x, y: painted.y))
          path.addLine(to: CGPoint(x: x, y: painted.y + painted.h))
        }
        context.stroke(path, with: stroke, lineWidth: 2)
      }
      .frame(width: screen.frame.width, height: screen.frame.height)
      .allowsHitTesting(false)
    }
  }

  // MARK: – Wallpaper background

  /// The rendered map image, drawn as the bottom layer so
  /// every marker / clock element above it lives in the SAME
  /// coordinate space (the window's bounds). That makes the
  /// PNG ↔ overlay projection bug structurally impossible —
  /// markers project against `screen.frame`, the image fills
  /// `screen.frame`, both share the window's origin.
  ///
  /// `.resizable().scaledToFill()` mirrors the SVG's
  /// `preserveAspectRatio="xMidYMid slice"`: scale to cover,
  /// crop overflow on the constraining axis. Letterbox /
  /// stretch variants would need different modifiers — we
  /// leave that to a future revision once the single-mode
  /// case is verified.
  /// The rendered bitmap for THIS screen specifically. Each
  /// physical display has its own entry in
  /// `state.wallpaperImages` so we don't crop a 21:9 ultrawide
  /// render across a 16:9 secondary.
  private var wallpaperImage: NSImage? {
    guard let id = displayID else { return nil }
    return state.wallpaperImages[id]
  }

  @ViewBuilder
  private var wallpaperBackground: some View {
    if let image = wallpaperImage {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .scaledToFill()
        .frame(width: screen.frame.width, height: screen.frame.height)
        .clipped()
    } else {
      Color.black
    }
  }

  // MARK: – Home marker

  @ViewBuilder
  private var homeMarker: some View {
    // The "Show home marker" toggle is the user's explicit
    // choice and we honour it regardless of centerMode — the
    // home dot pins where the user actually IS (CoreLocation),
    // not where the map happens to be centered. Manual mode
    // centers on a different longitude, but the user can still
    // want to see their real location marked.
    //
    // Drawn at every wrap-tile position the location maps to
    // (typically 1; up to 3 in a letterbox bar layout where the
    // map repeats into the side bars).
    if resolved.showHomeMarker, let home = state.homeCoordinate {
      let ctx = screenContext(resolved)
      let pts = projectionPoints(
        lat: home.latitude, lon: home.longitude, in: ctx)
      ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
        MarkerDot(
          color: homeColor(at: home),
          haloOpacity: 0.35,
          label: state.showHomeName ? homeLabel : nil,
          time: homeTime,
          screenPoint: pt
        )
      }
    }
  }

  /// Day-vs-night home-marker fill. Uses the home coord and
  /// the same `Sun.isDaylight` predicate the user markers do so
  /// the home dot follows the terminator on its own.
  private func homeColor(at home: CLLocationCoordinate2D) -> Color {
    let inDay = Sun.isDaylight(
      lat: home.latitude, lon: home.longitude, at: state.now)
    let hex = inDay ? state.homeDayColor : state.homeNightColor
    return Color(hex: hex) ?? .orange
  }

  private var homeLabel: String {
    resolved.homeLabel.isEmpty ? "Home" : resolved.homeLabel
  }
  private var homeTime: String? {
    formatMarkerTime(
      in: state.homeTimezone ?? TimeZone.current,
      showTime: state.showHomeTime,
      showDate: state.showHomeDate
    )
  }

  // MARK: – User markers

  private var userMarkers: some View {
    // Skip markers that haven't had a real location set yet —
    // fresh rows default to lat=0/lon=0 (Gulf of Guinea, an
    // open-ocean spot the user almost certainly didn't intend)
    // and would otherwise render a stray dot the instant the
    // user clicks "Add marker" but before they type a place.
    //
    // Each marker is drawn once per visible wrap-tile copy so
    // a marker whose longitude appears twice on screen
    // (letterbox bars showing the wrapped day image) also
    // appears twice. Config + projection context resolved once
    // for the whole loop, not per marker.
    let cfg = resolved
    let ctx = screenContext(cfg)
    return ForEach(cfg.markers.filter {
      $0.latitude != 0 || $0.longitude != 0
    }) { m in
      let pts = projectionPoints(
        lat: m.latitude, lon: m.longitude, in: ctx)
      ForEach(Array(pts.enumerated()), id: \.offset) { _, pt in
        MarkerDot(
          color: markerColor(for: m),
          haloOpacity: 0.30,
          label: m.showLabel ? markerLabel(for: m) : nil,
          time: markerTime(for: m),
          screenPoint: pt
        )
      }
    }
  }

  /// Resolve a marker's fill colour. Per-marker day/night
  /// colours win when set; blank fields fall through to the
  /// global `markerDayColor` / `markerNightColor` defaults.
  /// `Sun.isDaylight` picks the side. Recomputes every 1 Hz
  /// tick via `state.now`, so the dot flips at sunrise/sunset
  /// without a re-render of the underlying wallpaper image.
  private func markerColor(for marker: Marker) -> Color {
    let inDay = Sun.isDaylight(
      lat: marker.latitude, lon: marker.longitude, at: state.now)
    let perMarker = inDay ? marker.dayColor : marker.nightColor
    let fallback = inDay ? state.markerDayColor : state.markerNightColor
    let hex = perMarker.isEmpty ? fallback : perMarker
    return Color(hex: hex) ?? .blue
  }

  /// Display label for a user marker. Falls back to the place-name
  /// query when the user hasn't typed a custom label, so a marker
  /// added by typing "Paris" reads "Paris" without manual labelling.
  private func markerLabel(for marker: Marker) -> String? {
    if !marker.label.isEmpty { return marker.label }
    if !marker.place.isEmpty { return marker.place }
    return nil
  }

  /// Live local time at the marker's lat/lon, formatted per the
  /// marker's own `showTime` / `showDate` flags. Uses the IANA
  /// timezone the geocoder resolved when the marker was added
  /// (`marker.tzid`); falls back to the device timezone for
  /// legacy markers that haven't been backfilled yet. Returns
  /// nil when both flags are off so the renderer can collapse
  /// the time row entirely.
  private func markerTime(for marker: Marker) -> String? {
    let tz = marker.tzid.flatMap { TimeZone(identifier: $0) }
      ?? TimeZone.current
    return formatMarkerTime(
      in: tz,
      showTime: marker.showTime,
      showDate: marker.showDate
    )
  }

  // MARK: – Clock

  @ViewBuilder
  private var clockReadout: some View {
    if resolved.clockPosition != .hidden {
      ClockBlock(state: state, resolved: resolved)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .position(clockAnchor)
    }
  }

  /// Where to anchor the clock VStack on screen. Insets the
  /// chosen corner by:
  ///   • the menu bar height at the top
  ///   • the Dock's extent on any edge it occupies (bottom,
  ///     left, or right — `NSScreen.visibleFrame` is the
  ///     authoritative source)
  ///   • plus a small breathing-room pad on every side so the
  ///     clock isn't pressed flush against the chrome
  ///
  /// When the Dock is set to auto-hide, visibleFrame == frame
  /// (modulo the menu bar), and the auto-hidden Dock will
  /// momentarily slide over the clock when shown — that's a
  /// macOS behavior we don't try to compensate for.
  private var clockAnchor: CGPoint {
    let frame = screen.frame
    let visible = screen.visibleFrame
    // Cocoa screen coords are bottom-left origin; SwiftUI
    // window coords are top-left. visible.minY in Cocoa is the
    // bottom of the visible region — measured from frame's
    // bottom — so the Dock-at-bottom inset is exactly
    // visible.minY - frame.minY.
    let dockLeft = visible.minX - frame.minX
    let dockRight = frame.maxX - visible.maxX
    let dockBottom = visible.minY - frame.minY

    let pad: CGFloat = 24
    let sideOffset: CGFloat = 110  // approx half the clock's natural width

    let topY = state.menuBarHeight + pad
    let bottomY = frame.height - dockBottom - pad
    let leftX = dockLeft + sideOffset
    let rightX = frame.width - dockRight - sideOffset

    switch resolved.clockPosition {
    case .hidden:      return .zero  // unused
    case .topLeft:     return CGPoint(x: leftX, y: topY)
    case .topRight:    return CGPoint(x: rightX, y: topY)
    case .bottomLeft:  return CGPoint(x: leftX, y: bottomY)
    case .bottomRight: return CGPoint(x: rightX, y: bottomY)
    }
  }

  // MARK: – Helpers

  /// Build this screen's projection context from an
  /// already-resolved config. Callers that project several
  /// points in one pass (the marker loops) build this ONCE and
  /// reuse it — re-resolving the config per marker per 1 Hz tick
  /// added up across screens.
  private func screenContext(_ cfg: WallpaperConfig) -> Projection.ScreenContext {
    Projection.ScreenContext(
      screen: screen.frame.size,
      imageSize: wallpaperImage?.size ?? screen.frame.size,
      aspect: cfg.aspectFit,
      menuBarHeight: state.menuBarHeight,
      bandVisible: cfg.showTimezoneBand
    )
  }

  /// Every on-screen position for a single (lat, lon), including
  /// wrap-tile copies that fall inside letterbox side-bars. The
  /// wallpaper image tiles the map at offsetPx and offsetPx-MAP_W,
  /// so a marker whose longitude is rendered twice on screen
  /// should be drawn twice too. Returns 1 point in the typical
  /// "single visible wrap" case (cropOverflow, or aspect matched).
  private func projectionPoints(
    lat: Double, lon: Double,
    in ctx: Projection.ScreenContext
  ) -> [CGPoint] {
    Projection.screenPoints(
      lat: lat, lon: lon,
      centerLon: centerLon,
      in: ctx
    )
  }

  private func formatTime(in tz: TimeZone) -> String {
    let f = FormatterCache.timeFormatter(for: tz)
    return f.string(from: state.now)
  }

  /// Compose the marker's secondary text from its show-time /
  /// show-date flags. Either, both, or neither may be present:
  ///   - both:    "3:50 PM Wed" (or "15:50 Wed" in 24h locales)
  ///   - time:    "3:50 PM"
  ///   - date:    "Wed"
  ///   - neither: nil (caller drops the row)
  /// Weekday is `EEE` — short, locale-aware (e.g. "mié." in es).
  /// Time is delegated to `formatTime(in:)` which uses
  /// `timeStyle = .short`, so 24h locales render 24h naturally.
  private func formatMarkerTime(
    in tz: TimeZone,
    showTime: Bool,
    showDate: Bool
  ) -> String? {
    var parts: [String] = []
    if showTime {
      parts.append(formatTime(in: tz))
    }
    if showDate {
      let f = FormatterCache.dayFormatter(for: tz)
      parts.append(f.string(from: state.now))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }
}

// MARK: – Formatter Cache

private struct FormatterCache {
  private static let lock = NSLock()
  private static var timeFormatters: [TimeZone: DateFormatter] = [:]
  private static var dayFormatters: [TimeZone: DateFormatter] = [:]

  static func timeFormatter(for tz: TimeZone) -> DateFormatter {
    lock.lock()
    defer { lock.unlock() }
    let currentLocale = Locale.current
    if let cached = timeFormatters[tz], cached.locale == currentLocale {
      return cached
    }
    let f = DateFormatter()
    f.locale = currentLocale
    f.timeZone = tz
    f.timeStyle = .short
    timeFormatters[tz] = f
    return f
  }

  static func dayFormatter(for tz: TimeZone) -> DateFormatter {
    lock.lock()
    defer { lock.unlock() }
    let currentLocale = Locale.current
    if let cached = dayFormatters[tz], cached.locale == currentLocale {
      return cached
    }
    let f = DateFormatter()
    f.locale = currentLocale
    f.timeZone = tz
    f.dateFormat = "EEE"
    dayFormatters[tz] = f
    return f
  }

  private static var secondsFormatters: [TimeZone: DateFormatter] = [:]
  private static var utcFormatter: DateFormatter?

  /// Seconds-precision wall-clock formatter for the main clock
  /// readout. `timeStyle = .medium` is the locale-aware "h:mm:ss"
  /// form — 24-hour locales (and the System Settings 24-hour
  /// override) render 24h automatically, unlike the hardcoded
  /// "h:mm:ss a" pattern this replaces.
  static func clockFormatter(for tz: TimeZone) -> DateFormatter {
    lock.lock()
    defer { lock.unlock() }
    let currentLocale = Locale.current
    if let cached = secondsFormatters[tz], cached.locale == currentLocale {
      return cached
    }
    let f = DateFormatter()
    f.locale = currentLocale
    f.timeZone = tz
    f.timeStyle = .medium
    secondsFormatters[tz] = f
    return f
  }

  /// Fixed-format UTC line. Locale-independent by design
  /// (en_US_POSIX), so one shared instance is safe forever.
  static func utcClockFormatter() -> DateFormatter {
    lock.lock()
    defer { lock.unlock() }
    if let f = utcFormatter { return f }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "HH:mm:ss 'UTC'"
    utcFormatter = f
    return f
  }
}

// MARK: – Marker dot + label

/// One marker — a coloured dot, a soft halo behind it, and
/// optional name+time text below. Each child is `.position`ed
/// directly at the projected screen point (or a known offset
/// from it) so the halo and dot land exactly on the lat/lon,
/// not at the top-left corner of the label bounding box.
private struct MarkerDot: View {
  let color: Color
  let haloOpacity: Double
  let label: String?
  let time: String?
  let screenPoint: CGPoint

  // Visual constants. Match the card's overlay markers so the
  // look is continuous between wallpaper and overlay sources.
  private let dotRadius: CGFloat = 6
  private let haloRadius: CGFloat = 16
  /// Distance below the dot's center where the label block's top
  /// edge sits. Calibrated to render flush below the dot — the
  /// `.shadow` modifiers on the label expand SwiftUI's measured
  /// frame, so a naively-computed `dotRadius + small gap` lands
  /// the top edge inside the dot. Bumping by ~2/3 of the dot
  /// diameter clears it.
  private let labelGap: CGFloat = 16

  /// Height of the rendered label+time block. Measured via
  /// preference key so we can anchor the block's TOP (not its
  /// center) at a fixed offset below the dot — `.position`
  /// targets the centre, so we add `height / 2` to compensate.
  @State private var labelBlockHeight: CGFloat = 0

  var body: some View {
    ZStack {
      // Halo — center on the projected point.
      Circle()
        .fill(color.opacity(haloOpacity))
        .frame(width: haloRadius * 2, height: haloRadius * 2)
        .position(screenPoint)

      // Dot — same anchor, drawn on top of the halo.
      Circle()
        .fill(color)
        .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1))
        .frame(width: dotRadius * 2, height: dotRadius * 2)
        .position(screenPoint)

      // Label + time. Its TOP sits at (screenPoint.y +
      // dotRadius + labelGap); we position the center, so add
      // half the measured block height.
      if label != nil || time != nil {
        VStack(spacing: 1) {
          if let label = label {
            Text(label)
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.white)
          }
          if let time = time {
            Text(time)
              .font(.system(size: 12, weight: .medium, design: .monospaced))
              .foregroundStyle(.white)
          }
        }
        .shadow(color: .black.opacity(0.9), radius: 2, x: 0, y: 1)
        .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 0)
        .fixedSize()
        .background(
          GeometryReader { geo in
            Color.clear.preference(
              key: MarkerLabelHeightKey.self,
              value: geo.size.height
            )
          }
        )
        .position(
          x: screenPoint.x,
          y: screenPoint.y + dotRadius + labelGap + labelBlockHeight / 2
        )
      }
    }
    .onPreferenceChange(MarkerLabelHeightKey.self) { labelBlockHeight = $0 }
  }
}

/// Preference key used by MarkerDot to measure the label+time
/// block's height so the block can be anchored by its top edge
/// rather than its center.
private struct MarkerLabelHeightKey: PreferenceKey {
  static var defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

// MARK: – Clock block

/// The main wall-clock readout that lives in one of the four
/// corners. HH:MM:SS in the user's locale-aware short style,
/// optional UTC line below.
private struct ClockBlock: View {
  @ObservedObject var state: OverlayState
  /// Per-screen effective config — passed in so the parent
  /// (`OverlayView`) decides which screen's overrides this
  /// clock block reads from. Without this, switching to a
  /// per-display clock position / source on a non-primary
  /// monitor wouldn't affect this block.
  let resolved: WallpaperConfig

  var body: some View {
    VStack(alignment: alignment, spacing: 2) {
      Text(formattedLocalTime)
        .font(.system(size: 30, weight: .semibold, design: .default))
        .foregroundStyle(.white)
        .monospacedDigit()
      if resolved.showUTC {
        Text(formattedUTC)
          .font(.system(size: 14, weight: .medium, design: .monospaced))
          .foregroundStyle(.yellow.opacity(0.85))
      }
    }
    .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
    .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 0)
  }

  private var alignment: HorizontalAlignment {
    switch resolved.clockPosition {
    case .topRight, .bottomRight: return .trailing
    default: return .leading
    }
  }

  /// Local time in the user's preferred tz, locale-aware
  /// (timeStyle .medium follows the 24-hour locale/System
  /// Settings preference, matching the marker times). Cached —
  /// the previous version allocated a fresh DateFormatter every
  /// 1 Hz tick on every screen, the most expensive Foundation
  /// object to construct.
  private var formattedLocalTime: String {
    let tz = resolveClockTimezone()
    return FormatterCache.clockFormatter(for: tz).string(from: state.now)
  }

  private var formattedUTC: String {
    FormatterCache.utcClockFormatter().string(from: state.now)
  }

  private func resolveClockTimezone() -> TimeZone {
    switch resolved.clockSource {
    case .matchCenter:
      return TimeZone.current   // TODO: resolve from centerLon
    case .device:
      return TimeZone.current
    case .manualTimezone:
      return TimeZone(identifier: resolved.manualTimezone) ?? .current
    }
  }
}
