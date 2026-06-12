import Foundation

/// Top-level user-editable configuration for the wallpaper app.
///
/// This is the schema the Settings UI binds to and the persistence
/// layer round-trips through UserDefaults. `ConfigStore` holds the
/// canonical instance; `buildWallpaperPayload` projects it into the
/// `{ config, hass }` JSON the bundled wallpaper.html consumes.
///
/// Keep this struct stable across versions — we persist by encoding
/// to JSON, so renamed fields will silently lose values. Add new
/// fields with safe defaults; never rename or repurpose old ones.
struct WallpaperConfig: Codable, Equatable {

  // MARK: – Map

  /// How the map's centerLon is chosen each render cycle. Order
  /// listed in the enum reflects the documented fallback chain in
  /// TODO.md ("Center mode resolution chain").
  var centerMode: CenterMode = .myLocation

  /// Used when `centerMode == .manual`. Lat/lon in signed degrees.
  /// Lat ignored by the card (which only uses longitude for
  /// centering), kept here so the user has a coherent "home"
  /// concept to point markers / clock at.
  var manualLatitude: Double = 0
  var manualLongitude: Double = 0

  /// How the SVG fits the user's display when the map's natural
  /// 2048×1068 aspect doesn't match.
  var aspectFit: AspectFit = .cropOverflow

  /// Visible-overlay toggles for the card layers we keep on the
  /// wallpaper PNG (clock + markers move to the overlay window —
  /// see TODO.md "Live overlay layer").
  var showTimezoneBand: Bool = true
  var showTimezoneBoundaries: Bool = true

  // MARK: – Clock (main wall-clock readout)

  /// Which corner of the map the main clock readout sits in (or
  /// `.hidden` to remove it entirely). Defaults to the card's own
  /// bottom-left position so users get a familiar look out of the
  /// box.
  var clockPosition: ClockPosition = .bottomLeft

  /// Where the main clock readout's time-zone comes from. Only
  /// consulted when `clockPosition != .hidden`.
  var clockSource: ClockSource = .matchCenter

  /// Used when `clockSource == .manualTimezone`. Canonical IANA
  /// tzid, e.g. "America/Los_Angeles".
  var manualTimezone: String = ""

  /// Render a UTC line under the main clock. Ignored when the
  /// clock itself is hidden.
  var showUTC: Bool = true

  // MARK: – Markers

  /// User-placed location markers — rendered in the overlay layer
  /// (v2) or as inline-coord markers on the wallpaper PNG (v1).
  var markers: [Marker] = []

  /// Render a dot at the resolved home location.
  var showHomeMarker: Bool = true

  /// Add the home name + current local time under the home marker.
  /// Kept for legacy decode only — the rendering path reads the
  /// finer-grained `showHomeName` / `showHomeTime` instead. When a
  /// pre-split config loads, this value seeds both new fields.
  var showHomeMarkerLabel: Bool = false

  /// Draw "Home" (or the resolved location name) under the dot.
  var showHomeName: Bool = false

  /// Draw the home location's local time under the dot. Splits
  /// the old combined "name + time" toggle so users can show
  /// just the clock without the label cluttering the corner.
  var showHomeTime: Bool = false

  /// Draw the abbreviated weekday alongside the home time.
  /// Independent of `showHomeTime` so the user can show just the
  /// day-of-week without a clock under the dot.
  var showHomeDate: Bool = false

  /// Text drawn under the home dot when `showHomeName` is on.
  /// Defaults to "Home" but the user can change it — the marker
  /// actually pins the current device location, which may not be
  /// the user's home (e.g. when travelling). Empty falls back to
  /// the default at render time.
  var homeLabel: String = "Home"

  /// Home-marker fills, split into day and night the same way
  /// the user markers are. Defaults pair with the HA card's
  /// `--geo-home-marker` accent so the wallpaper recognises
  /// "you, here" without the user having to configure it.
  var homeDayColor: String = "#ff7a3d"
  var homeNightColor: String = "#ff7a3d"

  /// Default fill color for markers that don't override `color`.
  /// Kept around so configs persisted before the day/night split
  /// still decode cleanly; the rendering path no longer reads it.
  var markerDefaultColor: String = "#3da9fc"

  /// Default fill for markers whose location is currently in
  /// daylight (solar altitude > 0°). Hex `#RRGGBB`. Per-marker
  /// `color` overrides this in both day and night.
  var markerDayColor: String = "#ff9933"

  /// Default fill for markers whose location is currently in
  /// night (solar altitude ≤ 0°). Hex `#RRGGBB`. Per-marker
  /// `color` overrides this in both day and night.
  var markerNightColor: String = "#3da9fc"

  // MARK: – Schedule

  /// Seconds between wallpaper refresh cycles. Clamped 60–3600 by
  /// the Scheduler — the slider in Settings already respects the
  /// range, this is belt + braces.
  var updateInterval: Int = 300

  /// User-paused. Independent of the auto-pause behaviors (sleep,
  /// screensaver — TODO) so resuming after auto-pause doesn't
  /// override an explicit user pause.
  var paused: Bool = false

  /// Whether the app should register as a Login Item so it
  /// launches automatically when the user signs in. Backed by
  /// `SMAppService.mainApp` (macOS 13+). On by default so the
  /// wallpaper "just works" after install without the user
  /// having to revisit Settings.
  var launchAtStartup: Bool = true

  /// Display UUIDs the user has explicitly disabled the
  /// wallpaper on. Empty by default = render every connected
  /// display. UUID rather than CGDirectDisplayID because the
  /// numeric ID can shuffle when monitors are replugged; the
  /// UUID is stable per-display across reboots.
  var disabledDisplays: [String] = []

  /// Master switch for the per-display override system. When
  /// off (default), every display renders the same global
  /// config. When on, `perDisplaySettings[uuid]` (if present)
  /// overrides individual fields for that display — see
  /// `resolved(forDisplay:)`.
  var perDisplayEnabled: Bool = false

  /// Per-display setting overrides, keyed by display UUID
  /// string. Missing keys = inherit the global config wholesale.
  /// Present keys override only the fields the user explicitly
  /// set on that display (every override field is `Optional`).
  var perDisplaySettings: [String: PerDisplaySettings] = [:]

  /// Reset everything to the documented defaults. Used by the
  /// "Reset to defaults" button in Settings.
  static let defaults = WallpaperConfig()

  // MARK: – Codable

  enum CodingKeys: String, CodingKey {
    case centerMode, manualLatitude, manualLongitude, aspectFit
    case showTimezoneBand, showTimezoneBoundaries
    case clockPosition, clockSource, manualTimezone, showUTC
    case markers, showHomeMarker, showHomeMarkerLabel
    case showHomeName, showHomeTime, showHomeDate, homeLabel
    case homeDayColor, homeNightColor
    case markerDefaultColor, markerDayColor, markerNightColor
    case updateInterval, paused, launchAtStartup, disabledDisplays
    case perDisplayEnabled, perDisplaySettings
  }

  init() {}

  /// Custom decoder so adding a new field doesn't reset every
  /// existing user's saved config. Each property falls back to
  /// its struct default when the persisted JSON lacks the key —
  /// users who haven't seen the new feature yet keep their
  /// centerMode / clockPosition / aspect-fit choices intact.
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = WallpaperConfig()
    self.centerMode = try c.decodeIfPresent(CenterMode.self, forKey: .centerMode) ?? d.centerMode
    self.manualLatitude = try c.decodeIfPresent(Double.self, forKey: .manualLatitude) ?? d.manualLatitude
    self.manualLongitude = try c.decodeIfPresent(Double.self, forKey: .manualLongitude) ?? d.manualLongitude
    self.aspectFit = try c.decodeIfPresent(AspectFit.self, forKey: .aspectFit) ?? d.aspectFit
    self.showTimezoneBand = try c.decodeIfPresent(Bool.self, forKey: .showTimezoneBand) ?? d.showTimezoneBand
    self.showTimezoneBoundaries = try c.decodeIfPresent(Bool.self, forKey: .showTimezoneBoundaries) ?? d.showTimezoneBoundaries
    self.clockPosition = try c.decodeIfPresent(ClockPosition.self, forKey: .clockPosition) ?? d.clockPosition
    self.clockSource = try c.decodeIfPresent(ClockSource.self, forKey: .clockSource) ?? d.clockSource
    self.manualTimezone = try c.decodeIfPresent(String.self, forKey: .manualTimezone) ?? d.manualTimezone
    self.showUTC = try c.decodeIfPresent(Bool.self, forKey: .showUTC) ?? d.showUTC
    self.markers = try c.decodeIfPresent([Marker].self, forKey: .markers) ?? d.markers
    self.showHomeMarker = try c.decodeIfPresent(Bool.self, forKey: .showHomeMarker) ?? d.showHomeMarker
    self.showHomeMarkerLabel = try c.decodeIfPresent(Bool.self, forKey: .showHomeMarkerLabel) ?? d.showHomeMarkerLabel
    // Pre-split configs only had `showHomeMarkerLabel` (name +
    // time together). Apply it to both new fields on first load
    // so existing users keep their prior visibility choice.
    self.showHomeName = try c.decodeIfPresent(Bool.self, forKey: .showHomeName) ?? self.showHomeMarkerLabel
    self.showHomeTime = try c.decodeIfPresent(Bool.self, forKey: .showHomeTime) ?? self.showHomeMarkerLabel
    self.showHomeDate = try c.decodeIfPresent(Bool.self, forKey: .showHomeDate) ?? self.showHomeMarkerLabel
    self.homeLabel = try c.decodeIfPresent(String.self, forKey: .homeLabel) ?? d.homeLabel
    self.homeDayColor = try c.decodeIfPresent(String.self, forKey: .homeDayColor) ?? d.homeDayColor
    self.homeNightColor = try c.decodeIfPresent(String.self, forKey: .homeNightColor) ?? d.homeNightColor
    self.markerDefaultColor = try c.decodeIfPresent(String.self, forKey: .markerDefaultColor) ?? d.markerDefaultColor
    self.markerDayColor = try c.decodeIfPresent(String.self, forKey: .markerDayColor) ?? d.markerDayColor
    self.markerNightColor = try c.decodeIfPresent(String.self, forKey: .markerNightColor) ?? d.markerNightColor
    self.updateInterval = try c.decodeIfPresent(Int.self, forKey: .updateInterval) ?? d.updateInterval
    self.paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
    self.launchAtStartup = try c.decodeIfPresent(Bool.self, forKey: .launchAtStartup) ?? d.launchAtStartup
    self.disabledDisplays = try c.decodeIfPresent([String].self, forKey: .disabledDisplays) ?? d.disabledDisplays
    self.perDisplayEnabled = try c.decodeIfPresent(Bool.self, forKey: .perDisplayEnabled) ?? d.perDisplayEnabled
    self.perDisplaySettings = try c.decodeIfPresent([String: PerDisplaySettings].self, forKey: .perDisplaySettings) ?? d.perDisplaySettings
  }

  /// Build the effective config for a particular display by
  /// folding `perDisplaySettings[uuid]` overrides on top of `self`.
  /// When per-display mode is off, or the display has no entry,
  /// returns `self` unchanged. Pass nil for the global view (Settings
  /// UI's "Global" tab uses this to show what unmodified displays will see).
  ///
  /// Each Optional override field that's non-nil replaces its
  /// counterpart on the resolved config; nil falls through. `markers`
  /// is the exception — when a per-display entry exists, its markers
  /// list REPLACES the global one entirely (since the user asked for
  /// "separate marker list for each display", not a filter).
  func resolved(forDisplay uuid: String?) -> WallpaperConfig {
    guard
      perDisplayEnabled,
      let uuid = uuid,
      let pd = perDisplaySettings[uuid]
    else { return self }

    var out = self
    if let v = pd.centerMode { out.centerMode = v }
    if let v = pd.manualLatitude { out.manualLatitude = v }
    if let v = pd.manualLongitude { out.manualLongitude = v }
    if let v = pd.aspectFit { out.aspectFit = v }
    if let v = pd.showTimezoneBand { out.showTimezoneBand = v }
    if let v = pd.showTimezoneBoundaries { out.showTimezoneBoundaries = v }
    if let v = pd.clockPosition { out.clockPosition = v }
    if let v = pd.clockSource { out.clockSource = v }
    if let v = pd.manualTimezone { out.manualTimezone = v }
    if let v = pd.showUTC { out.showUTC = v }
    if let v = pd.showHomeMarker { out.showHomeMarker = v }
    if let v = pd.homeLabel { out.homeLabel = v }
    // Markers follow the same Optional semantics as every other
    // field: nil inherits the global list; non-nil replaces it
    // entirely — INCLUDING the explicit empty list, which means
    // "no markers on this screen". (Markers used to be
    // non-optional here, and any unrelated override silently
    // wiped the display's markers when the settings entry was
    // first materialized.)
    if let v = pd.markers { out.markers = v }
    return out
  }
}

// MARK: – Enums

/// Which strategy picks the map's centerLon (and home location).
/// The actual resolution chain lives in app code; this enum just
/// names the user's chosen strategy.
enum CenterMode: String, Codable, CaseIterable, Identifiable {
  /// Core Location → lat/lon. Falls back through the chain if the
  /// user denies permission or the OS can't fix a location.
  case myLocation
  /// Look up the system's IANA timezone's geographic centroid.
  /// Always available; coarse but never wrong-by-an-ocean.
  case timezoneGuess
  /// User-typed lat/lon in Settings.
  case manual
  /// Subsolar drift — daylit hemisphere stays centered.
  case sun

  var id: String { rawValue }

  /// Human-readable label for the UI.
  var displayName: String {
    switch self {
    case .myLocation: return "My location"
    case .timezoneGuess: return "Guess from time zone"
    case .manual: return "Manual coordinates"
    case .sun: return "Follow the sun"
    }
  }
}

/// How the wallpaper PNG fits the screen when aspects don't match.
/// Names map directly onto the wallpaper page's CSS / SVG settings.
enum AspectFit: String, Codable, CaseIterable, Identifiable {
  /// Distort the map to fully fill the screen. Geographically
  /// dishonest but pixel-fills.
  case stretch
  /// Preserve aspect, allow black bars top/bottom or sides.
  case letterbox
  /// Preserve aspect, crop spillover. Default — matches what the
  /// card's SVG already does via `preserveAspectRatio="xMidYMid slice"`.
  case cropOverflow

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .stretch: return "Stretch to fill"
    case .letterbox: return "Letterbox"
    case .cropOverflow: return "Crop overflow"
    }
  }
}

/// Where the main clock readout sources its tzid. Independent of
/// the map's center mode — a user can center the map on Tokyo
/// while still showing local time.
enum ClockSource: String, Codable, CaseIterable, Identifiable {
  /// Inherit from `centerMode` (e.g. if center=my-location, clock
  /// uses the IANA zone at that lat/lon).
  case matchCenter
  /// This Mac's current IANA timezone.
  case device
  /// User-typed IANA tzid (e.g. "Europe/London").
  case manualTimezone

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .matchCenter: return "Match map center"
    case .device: return "This Mac's time zone"
    case .manualTimezone: return "Specific time zone…"
    }
  }
}

/// Where the main clock readout sits on the map (or whether it
/// renders at all). Implemented by injecting CSS overrides into
/// the bundled wallpaper page's shadow root — see
/// `WallpaperRenderer.clockPositionCSS`. Selecting any non-default
/// corner also hides the card's date readout so it can't clobber
/// the clock when they collide (e.g. clock moved to bottom-right,
/// where the date normally lives).
enum ClockPosition: String, Codable, CaseIterable, Identifiable {
  case hidden
  case bottomLeft
  case bottomRight
  case topLeft
  case topRight

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .hidden: return "Hidden"
    case .bottomLeft: return "Bottom-left"
    case .bottomRight: return "Bottom-right"
    case .topLeft: return "Top-left"
    case .topRight: return "Top-right"
    }
  }
}

// MARK: – Marker

/// A user-placed marker. `id` is stable per-row so SwiftUI's
/// ForEach can diff edits; not serialized (we encode the rest of
/// the struct, regenerate UUIDs on load). Color persisted as hex
/// because UIColor/NSColor aren't trivially Codable across
/// platforms and hex is what we hand to the card config anyway.
struct Marker: Codable, Equatable, Identifiable, Hashable {
  var id: UUID = UUID()
  var label: String = ""
  var latitude: Double = 0
  var longitude: Double = 0
  /// Hex `#RRGGBB`. Empty falls back to the global
  /// `markerDayColor` / `markerNightColor` defaults at render
  /// time. Two-field split lets the same marker read e.g.
  /// "orange when the sun is up at that city, dim red at night"
  /// without the user managing terminator crossings manually.
  var dayColor: String = ""
  var nightColor: String = ""
  /// Place-name query the user typed ("Paris", "Tokyo, Japan").
  /// Drives a forward-geocode that fills `latitude`, `longitude`,
  /// and `tzid` in one round-trip. Kept around so we can show the
  /// user-entered string back in the row, and so re-submitting
  /// the same string is idempotent.
  var place: String = ""
  /// IANA timezone identifier resolved from the geocode (e.g.
  /// `"America/Los_Angeles"`). Nil for newly-added markers and
  /// for legacy markers from configs that pre-date this field —
  /// the launch-time backfill in `AppDelegate` resolves those
  /// via reverse-geocode of the saved lat/lon.
  var tzid: String? = nil

  /// Whether to draw the marker's label (`label` or, falling
  /// back, the `place` query) under the dot. Per-marker so the
  /// user can hide the name on a dense map without dropping
  /// the marker entirely.
  var showLabel: Bool = true

  /// Whether to draw the marker's local time below the label.
  /// Independent of `showLabel` — a marker can show name only,
  /// time only, both, or neither (in which case it's just a dot).
  var showTime: Bool = true

  /// Whether to draw the abbreviated weekday ("Wed") alongside
  /// the time. Independent of `showTime`: a marker can show just
  /// "Wed" (e.g. a reminder of which day it is in Sydney) without
  /// the clock, or just the clock without the weekday.
  var showDate: Bool = true

  enum CodingKeys: String, CodingKey {
    case label, latitude, longitude, dayColor, nightColor, place, tzid
    case showLabel, showTime, showDate
    /// Legacy single-colour key. Read on decode and used to seed
    /// both day and night colours when a config from before the
    /// split is loaded; never written by `encode(to:)`.
    case color
  }

  init(
    id: UUID = UUID(),
    label: String = "",
    latitude: Double = 0,
    longitude: Double = 0,
    dayColor: String = "",
    nightColor: String = "",
    place: String = "",
    tzid: String? = nil,
    showLabel: Bool = true,
    showTime: Bool = true,
    showDate: Bool = true
  ) {
    self.id = id
    self.label = label
    self.latitude = latitude
    self.longitude = longitude
    self.dayColor = dayColor
    self.nightColor = nightColor
    self.place = place
    self.tzid = tzid
    self.showLabel = showLabel
    self.showTime = showTime
    self.showDate = showDate
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.id = UUID()
    self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    self.latitude = try c.decodeIfPresent(Double.self, forKey: .latitude) ?? 0
    self.longitude = try c.decodeIfPresent(Double.self, forKey: .longitude) ?? 0
    // Migration path: pre-split configs only had `color`. If the
    // user has not yet seen the day/night UI we apply their old
    // colour to both — preserves the look they had before.
    let legacy = try c.decodeIfPresent(String.self, forKey: .color) ?? ""
    self.dayColor = try c.decodeIfPresent(String.self, forKey: .dayColor) ?? legacy
    self.nightColor = try c.decodeIfPresent(String.self, forKey: .nightColor) ?? legacy
    self.place = try c.decodeIfPresent(String.self, forKey: .place) ?? ""
    self.tzid = try c.decodeIfPresent(String.self, forKey: .tzid)
    self.showLabel = try c.decodeIfPresent(Bool.self, forKey: .showLabel) ?? true
    self.showTime = try c.decodeIfPresent(Bool.self, forKey: .showTime) ?? true
    self.showDate = try c.decodeIfPresent(Bool.self, forKey: .showDate) ?? true
  }

  /// Custom encoder so the legacy `color` key isn't echoed back
  /// into the persisted JSON — it'd quietly drift out of sync
  /// with the day / night fields after the user edits one.
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(label, forKey: .label)
    try c.encode(latitude, forKey: .latitude)
    try c.encode(longitude, forKey: .longitude)
    try c.encode(dayColor, forKey: .dayColor)
    try c.encode(nightColor, forKey: .nightColor)
    try c.encode(place, forKey: .place)
    try c.encodeIfPresent(tzid, forKey: .tzid)
    try c.encode(showLabel, forKey: .showLabel)
    try c.encode(showTime, forKey: .showTime)
    try c.encode(showDate, forKey: .showDate)
  }
}
