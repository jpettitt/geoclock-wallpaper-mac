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
  /// Settings.
  func resetToDefaults() {
    config = .defaults
    paused = false
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
  func buildWallpaperPayload() -> WallpaperPayload {
    var c: [String: Any] = [:]

    // Card-side visibility toggles. Clock-position-driven hiding
    // is layered on top via CSS injection in WallpaperRenderer —
    // we still set showUTC=false here when the user picked the
    // hidden position so the card doesn't bother computing it.
    c["showTimezoneBand"] = config.showTimezoneBand
    c["showTimezoneBoundaries"] = config.showTimezoneBoundaries
    c["showHomeMarker"] = config.showHomeMarker
    c["showHomeMarkerLabel"] = config.showHomeMarkerLabel
    c["showUTC"] = config.clockPosition != .hidden && config.showUTC
    c["markerColor"] = config.markerDefaultColor

    // Centering. We pre-resolve every mode to a numeric
    // (lat, lon) Swift-side and use the wallpaper page's
    // centerLatitude/centerLongitude shortcut so both the card
    // and the overlay see the same value. Sun mode uses the
    // current subsolar point; everything else is config- or
    // Location-derived.
    let resolved = resolveCenterCoordinate()
    c["center"] = "home"
    c["centerLatitude"] = resolved.lat
    c["centerLongitude"] = resolved.lon

    // Clock source. matchCenter inherits centerMode's IANA tzid
    // (the card derives this from hass.config.time_zone, which
    // the page synthesizes via the mainTimeZone shortcut). For
    // v0 we only populate mainTimeZone in the manualTimezone
    // case; matchCenter + myLocation/timezoneGuess will gain
    // proper resolution once those services land.
    switch config.clockSource {
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
      if !config.manualTimezone.isEmpty {
        c["mainTimeZone"] = config.manualTimezone
      }
    }

    // Markers. We pass the user's typed markers via the wallpaper
    // page's inline-coord shortcut so they don't need an HA hass
    // stub. Empty list → omit the key entirely (card defaults
    // to no markers).
    if !config.markers.isEmpty {
      c["markers"] = config.markers.map { m -> [String: Any] in
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
      centerLon: resolved.lon)
  }

  /// Resolve `(centerLatitude, centerLongitude)` for the
  /// current `centerMode`. Falls through gracefully when a
  /// mode's preferred source is unavailable (CL not granted,
  /// tzid not in the centroid table, etc.) to the next
  /// option in the chain documented in TODO.md.
  func resolveCenterCoordinate() -> (lat: Double, lon: Double) {
    switch config.centerMode {
    case .sun:
      let sub = Sun.subsolarPoint(at: Date())
      return (sub.lat, sub.lon)
    case .manual:
      return (config.manualLatitude, config.manualLongitude)
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
