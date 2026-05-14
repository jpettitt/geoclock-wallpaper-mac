import Combine
import Foundation

/// Single source of truth for user preferences. Holds a typed
/// `WallpaperConfig` (not a JSON blob) and round-trips it through
/// UserDefaults on every change. The Settings UI binds to the
/// individual fields; `buildWallpaperPayload()` projects the model
/// into the `{ config, hass }` JSON shape the wallpaper page
/// consumes.
final class ConfigStore: ObservableObject {

  static let shared = ConfigStore()

  /// The canonical config. Mutations bind directly via SwiftUI's
  /// `$config.field` projection. `didSet` re-persists; cheap
  /// enough since the encoded payload is ~1–2 KB.
  @Published var config: WallpaperConfig {
    didSet { persist() }
  }

  /// Update interval as a read-through to `config.updateInterval`
  /// so AppDelegate's existing Combine subscription doesn't change
  /// shape. Same pattern for `paused`. These will go once we
  /// migrate the subscribers to observe `$config` directly.
  var updateInterval: Int {
    get { config.updateInterval }
    set { config.updateInterval = max(60, min(newValue, 3600)) }
  }

  @Published var paused: Bool {
    didSet {
      if paused != config.paused {
        config.paused = paused
      }
    }
  }

  // MARK: – Persistence

  private let defaults: UserDefaults
  private let key = "wallpaperConfig.v1"
  private var ignorePersistedChanges = false

  private init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let loaded = Self.load(from: defaults, key: "wallpaperConfig.v1")
    self.config = loaded
    self.paused = loaded.paused
  }

  /// Decode the persisted config from UserDefaults, or return the
  /// documented defaults if nothing's stored / the stored data is
  /// unparseable. Forward-compatible — fields that didn't exist in
  /// the persisted JSON inherit struct defaults via the synthesized
  /// `Decodable` init.
  private static func load(from defaults: UserDefaults, key: String) -> WallpaperConfig {
    guard
      let data = defaults.data(forKey: key)
    else {
      return .defaults
    }
    do {
      return try JSONDecoder().decode(WallpaperConfig.self, from: data)
    } catch {
      // Stored config exists but is malformed — log and fall back
      // rather than silently dropping it. The user might want
      // their non-trivial customizations restored when we fix the
      // bug, so don't overwrite immediately.
      NSLog("ConfigStore: failed to decode stored config: %@", "\(error)")
      return .defaults
    }
  }

  private func persist() {
    do {
      let data = try JSONEncoder().encode(config)
      defaults.set(data, forKey: key)
    } catch {
      NSLog("ConfigStore: failed to encode config: %@", "\(error)")
    }
  }

  /// Reset to the documented defaults. Wired to a button in
  /// Settings. "Reset" means literally clear: not just the
  /// typed config but also LocationService's cached
  /// last-known fix, otherwise the home marker keeps drawing
  /// at the previously-cached coordinate (especially obvious
  /// after the user switches off `centerMode = .manual` —
  /// the home dot keeps haunting the same spot). The next
  /// real CoreLocation fix will refill the coordinate.
  func resetToDefaults() {
    config = .defaults
    paused = false
    LocationService.shared.clearCachedFix()
  }

  // MARK: – Payload assembly

  /// Result of payload assembly. `centerLon` is the resolved
  /// longitude the card will center on for this render — used by
  /// the overlay layer to project markers against the same
  /// coordinate the wallpaper PNG was drawn with.
  struct WallpaperPayload {
    let config: [String: Any]
    let hass: [String: Any]
    let centerLon: Double
  }

  /// Build the `(config, hass)` payload the wallpaper page's
  /// `window.geoclockConfigure` expects. This is the single place
  /// the typed Swift model is projected onto the card's JSON
  /// schema (plus the wallpaper page's shortcut keys —
  /// `mainTimeZone`, inline-coord markers, etc.).
  ///
  /// We resolve every centering mode to a numeric centerLon
  /// Swift-side (including sun mode, via `Sun.subsolarPoint`)
  /// and hand the card the literal value via `center: 'longitude'`.
  /// That lets the overlay layer use the exact same value when
  /// projecting markers — they sit on top of where the
  /// underlying PNG would have drawn them.
  func buildWallpaperPayload(
    forDisplay uuid: String? = nil
  ) -> WallpaperPayload {
    // Fold per-display overrides into the config we project. nil
    // uuid (or per-display mode off) makes this the same as the
    // global config — the existing single-screen path.
    let cfg = config.resolved(forDisplay: uuid)
    var c: [String: Any] = [:]

    // Card-side visibility toggles. Clock-position-driven hiding
    // is layered on top via CSS injection in WallpaperRenderer —
    // we still set showUTC=false here when the user picked the
    // hidden position so the card doesn't bother computing it.
    c["showTimezoneBand"] = cfg.showTimezoneBand
    c["showTimezoneBoundaries"] = cfg.showTimezoneBoundaries
    c["showHomeMarker"] = cfg.showHomeMarker
    c["showHomeMarkerLabel"] = cfg.showHomeMarkerLabel
    c["showUTC"] = cfg.clockPosition != .hidden && cfg.showUTC
    c["markerColor"] = cfg.markerDefaultColor

    // Centering. We pre-resolve every mode to a numeric
    // (lat, lon) Swift-side so the Swift overlay can project
    // markers against the exact same longitude the rendered
    // image is centered on. Two routes into the card:
    //
    //   - Manual mode: drive the card's `center: 'longitude'`
    //     schema directly. We skip the `centerLatitude` /
    //     `centerLongitude` wallpaper shortcut here on purpose
    //     — that shortcut synthesizes a fake "home" entity at
    //     (centerLatitude, centerLongitude), which made the
    //     card draw a home-marker at the user's chosen
    //     centering point (visible through `overlayHidingCSS`
    //     gaps and impossible to hide). Manual mode is just
    //     "show me the world centered on longitude X" — no
    //     home implied.
    //
    //   - Every other mode: keep the existing `center: 'home'`
    //     path with a synthesized home so the card's IANA tz
    //     fallback for the clock still has somewhere sensible
    //     to land.
    let center = resolveCenterCoordinate(forDisplay: uuid)
    if cfg.centerMode == .manual {
      c["center"] = "longitude"
      c["centerLongitude"] = center.lon
    } else {
      c["center"] = "home"
      c["centerLatitude"] = center.lat
      c["centerLongitude"] = center.lon
    }

    // Clock source. matchCenter inherits centerMode's IANA tzid
    // (the card derives this from hass.config.time_zone, which
    // the page synthesizes via the mainTimeZone shortcut). For
    // v0 we only populate mainTimeZone in the manualTimezone
    // case; matchCenter + myLocation/timezoneGuess will gain
    // proper resolution once those services land.
    switch cfg.clockSource {
    case .matchCenter:
      // Card default mainTimeSource is "home"; the wallpaper page
      // falls through to the visitor's device tz when no
      // hass.config.time_zone is supplied. Acceptable v0
      // behavior — once we have a resolved center tzid, set
      // mainTimeZone here.
      break
    case .device:
      c["mainTimeSource"] = "device"
    case .manualTimezone:
      if !cfg.manualTimezone.isEmpty {
        c["mainTimeZone"] = cfg.manualTimezone
      }
    }

    // Markers. We pass the user's typed markers via the wallpaper
    // page's inline-coord shortcut so they don't need an HA hass
    // stub. Empty list → omit the key entirely (card defaults
    // to no markers).
    if !cfg.markers.isEmpty {
      c["markers"] = cfg.markers.map { m -> [String: Any] in
        var dict: [String: Any] = [
          "label": m.label,
          "latitude": m.latitude,
          "longitude": m.longitude,
        ]
        // The card's marker rendering is hidden by the overlay's
        // injected CSS, so this colour only matters for hover /
        // popup paths we also hide. We still emit the day-side
        // colour to keep the card config schema-consistent.
        if !m.dayColor.isEmpty { dict["color"] = m.dayColor }
        return dict
      }
    }

    // Hass stub is empty — the wallpaper page synthesizes
    // hass.states from the inline-coord markers, and we drive
    // `mainTimeZone` via the shortcut above. The card itself
    // works fine with hass = {}.
    return WallpaperPayload(
      config: c,
      hass: [:],
      centerLon: center.lon)
  }

  /// Resolve `(centerLatitude, centerLongitude)` for the
  /// requested display's effective centerMode. With per-display
  /// mode off (or no uuid), this is the global resolution.
  /// Falls through gracefully when a mode's preferred source is
  /// unavailable (CL not granted, tzid not in the centroid
  /// table, etc.) to the next option in the chain documented in
  /// TODO.md.
  func resolveCenterCoordinate(
    forDisplay uuid: String? = nil
  ) -> (lat: Double, lon: Double) {
    let cfg = config.resolved(forDisplay: uuid)
    switch cfg.centerMode {
    case .sun:
      let sub = Sun.subsolarPoint(at: Date())
      return (sub.lat, sub.lon)
    case .manual:
      // Latitude is irrelevant for equirectangular centering —
      // only longitude shifts which slice of the world is
      // on-screen. We zero it out (rather than reading the
      // ignored `cfg.manualLatitude`) to make the intent
      // explicit at the call site.
      return (0, cfg.manualLongitude)
    case .myLocation:
      if let c = LocationService.shared.coordinate {
        return (c.latitude, c.longitude)
      }
      return tzCentroidOrSun()
    case .timezoneGuess:
      return tzCentroidOrSun()
    }
  }

  /// Fall-through used by the location-derived modes when no
  /// real coordinates are available: pick the system tzid's
  /// centroid, or finally the subsolar point if the tzid
  /// isn't in the lookup table.
  private func tzCentroidOrSun() -> (lat: Double, lon: Double) {
    let tzid = TimeZone.current.identifier
    if let coord = TimezoneCentroid.coordinate(forIANA: tzid) {
      return (coord.lat, coord.lon)
    }
    let sub = Sun.subsolarPoint(at: Date())
    return (sub.lat, sub.lon)
  }
}
